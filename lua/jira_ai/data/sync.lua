
local M = {}

-- Full sync of all configured project data
function M.full_sync(callback, options)
	options = options or {}

	-- Lazy load to avoid circular dependencies
	local log = require("jira_ai.log")
	local error_handling = require("jira_ai.error_handling")

	-- Validate configuration before starting
	local config_valid, config_error = error_handling.validate_config()
	if not config_valid then
		log.error("Cannot start sync: " .. config_error.message, "data.sync")
		callback(nil, config_error)
		return
	end

	-- Health check Jira API
	error_handling.health_check_jira_api(function(api_healthy, health_error)
		if not api_healthy then
			log.error("Jira API health check failed: " .. health_error.message, "data.sync")
			callback(nil, health_error)
			return
		end

		M._execute_full_sync(callback, options)
	end)
end

-- Internal full sync execution (after validation)
function M._execute_full_sync(callback, options)
	local log = require("jira_ai.log")
	local projects = require("jira_ai.data.projects")
	local users = require("jira_ai.data.users")
	local batch = require("jira_ai.data.batch")
	
	log.info("Starting full Jira data sync", "data.sync")
	local start_time = os.time()

	local sync_data = {
		projects = {},
		users = {},
		all_project_data = {},
		sync_timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		sync_type = "full",
		errors = {},
	}

	local completed_phases = 0
	local total_phases = 3 -- projects, users, project_data
	local critical_errors = {}

	local function check_completion()
		completed_phases = completed_phases + 1
		if completed_phases == total_phases then
			local duration = os.time() - start_time

			if #critical_errors > 0 then
				log.error(
					string.format(
						"Full sync completed with %d critical errors in %d seconds",
						#critical_errors,
						duration
					),
					"data.sync"
				)
				sync_data.errors = critical_errors
				callback(nil, sync_data)
			else
				log.info(string.format("Full sync completed successfully in %d seconds", duration), "data.sync")
				callback(sync_data)
			end
		end
	end

	-- Phase 1: Get projects
	projects.get_configured_projects_details(function(project_details, error)
		if error then
			log.error("Failed to get project details: " .. error, "data.sync")
			table.insert(critical_errors, { phase = "projects", error = error })
			sync_data.projects = {} -- Continue with empty projects
		else
			log.info("Phase 1 complete: Retrieved " .. #(project_details or {}) .. " project details", "data.sync")
			sync_data.projects = project_details or {}
		end
		check_completion()
	end)

	-- Phase 2: Get users
	users.get_all_users(function(all_users, error)
		if error then
			log.error("Failed to get users: " .. error, "data.sync")
			table.insert(critical_errors, { phase = "users", error = error })
			sync_data.users = {} -- Continue with empty users
		else
			log.info("Phase 2 complete: Retrieved " .. #(all_users or {}) .. " users", "data.sync")
			sync_data.users = all_users or {}
		end
		check_completion()
	end)

	-- Phase 3: Get comprehensive project data
	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	batch.get_project_data_batch(project_keys, function(project_data, error)
		if error then
			log.error("Failed to get project data: " .. error, "data.sync")
			table.insert(critical_errors, { phase = "project_data", error = error })
			sync_data.all_project_data = {} -- Continue with empty project data
		else
			log.info("Phase 3 complete: Retrieved data for " .. #(project_data or {}) .. " projects", "data.sync")
			sync_data.all_project_data = project_data or {}
		end
		check_completion()
	end, {
		include_issues = true,
		include_epics = true,
		include_sprints = true,
		issues_options = options.issues_options,
		epics_options = options.epics_options,
		sprints_options = options.sprints_options,
	})
end

-- Incremental sync (only changed data since last sync)
function M.incremental_sync(since_date, callback, options)
	options = options or {}

	local batch = require("jira_ai.data.batch")

	vim.notify("Starting incremental Jira data sync since " .. since_date, vim.log.levels.INFO)
	local start_time = os.time()

	local sync_data = {
		since_date = since_date,
		sync_timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		sync_type = "incremental",
		updated_data = {},
	}

	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	batch.get_incremental_data(since_date, function(incremental_data, error)
		if error then
			vim.notify("Failed to get incremental data: " .. error, vim.log.levels.ERROR)
			callback(nil, error)
			return
		end

		sync_data.updated_data = incremental_data

		local duration = os.time() - start_time
		vim.notify(string.format("Incremental sync completed in %d seconds", duration), vim.log.levels.INFO)
		callback(sync_data)
	end, project_keys, options)
end

-- Quick sync (current sprints and recent data only)
function M.quick_sync(callback, options)
	options = options or {}

	local log = require("jira_ai.log")
	local sprints = require("jira_ai.data.sprints")
	local issues = require("jira_ai.data.issues")
	local epics = require("jira_ai.data.epics")

	log.info("Starting quick Jira data sync", "data.sync")
	local start_time = os.time()

	local sync_data = {
		current_sprints = {},
		recent_issues = {},
		active_epics = {},
		sync_timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		sync_type = "quick",
	}

	local completed_phases = 0
	local total_phases = 3

	local function check_completion()
		completed_phases = completed_phases + 1
		if completed_phases == total_phases then
			local duration = os.time() - start_time
			log.info(string.format("Quick sync completed in %d seconds", duration), "data.sync")
			callback(sync_data)
		end
	end

	-- Get current sprints
	sprints.get_all_current_sprints(function(current_sprints, error)
		if error then
			vim.notify("Failed to get current sprints: " .. error, vim.log.levels.WARN)
			sync_data.current_sprints = {}
		else
			sync_data.current_sprints = current_sprints or {}
		end
		check_completion()
	end)

	-- Get recent issues (last 7 days)
	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	issues.get_recently_active_issues(7, function(recent_issues, error)
		if error then
			vim.notify("Failed to get recent issues: " .. error, vim.log.levels.WARN)
			sync_data.recent_issues = {}
		else
			sync_data.recent_issues = recent_issues or {}
		end
		check_completion()
	end, project_keys, options.issues_options)

	-- Get active epics
	local all_active_epics = {}
	local completed_projects = 0
	local total_projects = #project_keys

	if total_projects == 0 then
		sync_data.active_epics = {}
		check_completion()
	else
		for _, project_key in ipairs(project_keys) do
			epics.get_active_epics(project_key, function(active_epics, error)
				if error then
					vim.notify("Failed to get active epics for " .. project_key .. ": " .. error, vim.log.levels.WARN)
					active_epics = {}
				end

				all_active_epics[project_key] = active_epics or {}

				completed_projects = completed_projects + 1
				if completed_projects == total_projects then
					sync_data.active_epics = all_active_epics
					check_completion()
				end
			end, options.epics_options)
		end
	end
end

-- Sync specific to attention items (stale, blocked, etc.)
function M.attention_sync(callback, options)
	options = options or {}

	local issues = require("jira_ai.data.issues")

	vim.notify("Starting attention items sync...", vim.log.levels.INFO)

	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	local attention_data = {
		stale_issues = {},
		blocked_issues = {},
		high_priority_issues = {},
		qa_issues = {},
		overdue_issues = {},
		sync_timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		sync_type = "attention",
	}

	local completed_operations = 0
	local total_operations = 5

	local function check_completion()
		completed_operations = completed_operations + 1
		if completed_operations == total_operations then
			vim.notify("Attention items sync completed", vim.log.levels.INFO)
			callback(attention_data)
		end
	end

	-- Get stale issues
	local stale_days = config.stale_days or 3
	issues.get_stale_issues(stale_days, function(stale_issues, error)
		if error then
			vim.notify("Failed to get stale issues: " .. error, vim.log.levels.WARN)
			attention_data.stale_issues = {}
		else
			attention_data.stale_issues = stale_issues or {}
		end
		check_completion()
	end, project_keys, options.issues_options)

	-- Get blocked issues
	issues.get_blocked_issues(project_keys, function(blocked_issues, error)
		if error then
			vim.notify("Failed to get blocked issues: " .. error, vim.log.levels.WARN)
			attention_data.blocked_issues = {}
		else
			attention_data.blocked_issues = blocked_issues or {}
		end
		check_completion()
	end, options.issues_options)

	-- Get high priority issues
	issues.get_high_priority_issues(function(high_priority_issues, error)
		if error then
			vim.notify("Failed to get high priority issues: " .. error, vim.log.levels.WARN)
			attention_data.high_priority_issues = {}
		else
			attention_data.high_priority_issues = high_priority_issues or {}
		end
		check_completion()
	end, project_keys, options.issues_options)

	-- Get QA issues
	issues.get_qa_issues(function(qa_issues, error)
		if error then
			vim.notify("Failed to get QA issues: " .. error, vim.log.levels.WARN)
			attention_data.qa_issues = {}
		else
			attention_data.qa_issues = qa_issues or {}
		end
		check_completion()
	end, project_keys, options.issues_options)

	-- Get overdue issues
	issues.get_overdue_issues(function(overdue_issues, error)
		if error then
			vim.notify("Failed to get overdue issues: " .. error, vim.log.levels.WARN)
			attention_data.overdue_issues = {}
		else
			attention_data.overdue_issues = overdue_issues or {}
		end
		check_completion()
	end, project_keys, options.issues_options)
end

-- Sync user-specific data for user stats
function M.user_stats_sync(user_account_id, callback, options)
	options = options or {}

	local issues = require("jira_ai.data.issues")
	local sprints = require("jira_ai.data.sprints")

	vim.notify("Starting user stats sync for " .. user_account_id, vim.log.levels.INFO)

	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	local user_data = {
		user_account_id = user_account_id,
		assigned_issues = {},
		recent_sprints_data = {},
		sync_timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		sync_type = "user_stats",
	}

	local completed_operations = 0
	local total_operations = 2

	local function check_completion()
		completed_operations = completed_operations + 1
		if completed_operations == total_operations then
			vim.notify("User stats sync completed", vim.log.levels.INFO)
			callback(user_data)
		end
	end

	-- Get all issues assigned to user
	issues.get_user_issues(user_account_id, function(assigned_issues, error)
		if error then
			vim.notify("Failed to get user issues: " .. error, vim.log.levels.WARN)
			user_data.assigned_issues = {}
		else
			user_data.assigned_issues = assigned_issues or {}
		end
		check_completion()
	end, options.issues_options)

	-- Get recent sprints data for velocity calculation
	local sprint_lookback = config.sprint_lookback or 5
	local all_sprint_data = {}
	local completed_projects = 0
	local total_projects = #project_keys

	if total_projects == 0 then
		user_data.recent_sprints_data = {}
		check_completion()
	else
		for _, project_key in ipairs(project_keys) do
			sprints.get_recent_completed_sprints(project_key, sprint_lookback, function(recent_sprints, error)
				if error then
					vim.notify("Failed to get recent sprints for " .. project_key .. ": " .. error, vim.log.levels.WARN)
					recent_sprints = {}
				end

				all_sprint_data[project_key] = recent_sprints or {}

				completed_projects = completed_projects + 1
				if completed_projects == total_projects then
					user_data.recent_sprints_data = all_sprint_data
					check_completion()
				end
			end)
		end
	end
end

-- Validate configuration and API access
function M.validate_access(callback)
	local data_utils = require("jira_ai.data")
	local projects = require("jira_ai.data.projects")

	vim.notify("Validating Jira API access...", vim.log.levels.INFO)

	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	if #project_keys == 0 then
		callback(false, "No projects configured")
		return
	end

	local validation_results = {
		api_accessible = false,
		valid_projects = {},
		invalid_projects = {},
		user_permissions = {},
	}

	-- Test basic API access
	data_utils.jira_api_request_async("/rest/api/2/myself", nil, function(response, error)
		if error then
			validation_results.api_accessible = false
			callback(false, "Cannot access Jira API: " .. error, validation_results)
			return
		end

		validation_results.api_accessible = true
		validation_results.current_user = {
			account_id = response.accountId,
			display_name = response.displayName,
			email = response.emailAddress,
		}

		-- Test each configured project
		local completed_projects = 0
		local total_projects = #project_keys

		for _, project_key in ipairs(project_keys) do
			projects.validate_project_access(project_key, function(is_valid, details_or_error)
				if is_valid then
					table.insert(validation_results.valid_projects, {
						key = project_key,
						details = details_or_error,
					})
				else
					table.insert(validation_results.invalid_projects, {
						key = project_key,
						error = details_or_error,
					})
				end

				completed_projects = completed_projects + 1
				if completed_projects == total_projects then
					local success = #validation_results.valid_projects > 0
					callback(
						success,
						success and "Validation successful" or "No valid projects found",
						validation_results
					)
				end
			end)
		end
	end)
end

return M
