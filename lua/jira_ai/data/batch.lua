
local M = {}

-- Batch get issue details for multiple keys
function M.get_multiple_issues(issue_keys, callback, options)
	if not issue_keys or #issue_keys == 0 then
		local log = require("jira_ai.log")
		log.info("No issue keys provided for batch retrieval", "data.batch")
		callback({})
		return
	end
	end
	
	local log = require("jira_ai.log")
	local data_utils = require("jira_ai.data")
	local error_handling = require("jira_ai.error_handling")

	log.info("Starting batch retrieval for " .. #issue_keys .. " issues", "data.batch")
	options = options or {}
	local fields = options.fields or data_utils.FIELD_SETS.tickets
	local expand = options.expand or data_utils.EXPAND_SETS.tickets_full
	local batch_size = options.batch_size or 100

	-- Split into batches to avoid URL length limits
	local batches = {}
	for i = 1, #issue_keys, batch_size do
		local batch = {}
		for j = i, math.min(i + batch_size - 1, #issue_keys) do
			table.insert(batch, issue_keys[j])
		end
		table.insert(batches, batch)
	end

	log.info("Split into " .. #batches .. " batches for processing", "data.batch")
	local all_issues = {}
	local completed_batches = 0
	local failed_batches = {}

	for _, batch in ipairs(batches) do
		local jql = data_utils.build_jql({ key = batch })

		local params = {
			jql = jql,
			fields = fields,
			expand = expand,
			maxResults = batch_size,
		}

		-- Add timeout and retry for each batch
		error_handling.safe_async(function(safe_callback)
			data_utils.jira_api_request_async(
				"/rest/api/2/search", 
				data_utils.build_query_params(params), 
				safe_callback, 
				45000 -- 45 second timeout
			)
		end, function(response, error)
			if error then
				log.warn("Failed to get issue batch: " .. error, "data.batch")
				table.insert(failed_batches, { batch = batch, error = error })
			else
				local issues = response and response.issues or {}
				log.info("Successfully retrieved " .. #issues .. " issues from batch", "data.batch")
				for _, issue in ipairs(issues) do
					table.insert(all_issues, issue)
				end

			completed_batches = completed_batches + 1
			if completed_batches == #batches then
				if #failed_batches > 0 then
					log.warn(
						"Batch retrieval completed with " .. #failed_batches .. " failed batches out of " .. #batches,
						"data.batch"
					)
				else
					log.info("Batch retrieval completed successfully: " .. #all_issues .. " total issues", "data.batch")
				end
				callback(all_issues)
			end
		end, "data.batch")
	end
end

-- Batch get user details for multiple account IDs
function M.get_multiple_users(account_ids, callback)
	if not account_ids or #account_ids == 0 then
		callback({})
		return
	end

	local data_utils = require("jira_ai.data")

	-- Create batch requests
	local requests = {}
	for _, account_id in ipairs(account_ids) do
		table.insert(requests, {
			endpoint = "/rest/api/3/user",
			query = { accountId = account_id },
			account_id = account_id,
		})
	end

	data_utils.batch_requests(requests, function(results, error)
		if error then
			callback(nil, error)
			return
		end

		local users = {}
		for _, result in ipairs(results or {}) do
			local response = result.response
			if response then
				table.insert(users, {
					account_id = response.accountId,
					display_name = response.displayName,
					email = response.emailAddress,
					active = response.active ~= false,
					avatar_url = response.avatarUrls and response.avatarUrls["48x48"] or nil,
				})
			end
		end

		callback(users)
	end)
end

-- Batch get sprint details for multiple sprint IDs
function M.get_multiple_sprints(sprint_ids, callback)
	if not sprint_ids or #sprint_ids == 0 then
		callback({})
		return
	end

	local data_utils = require("jira_ai.data")

	-- Create batch requests
	local requests = {}
	for _, sprint_id in ipairs(sprint_ids) do
		table.insert(requests, {
			endpoint = "/rest/agile/1.0/sprint/" .. sprint_id,
			sprint_id = sprint_id,
		})
	end

	data_utils.batch_requests(requests, function(results, error)
		if error then
			callback(nil, error)
			return
		end

		local sprints = {}
		for _, result in ipairs(results or {}) do
			local response = result.response
			if response then
				table.insert(sprints, {
					id = response.id,
					name = response.name,
					state = response.state,
					start_date = response.startDate,
					end_date = response.endDate,
					complete_date = response.completeDate,
					goal = response.goal,
					origin_board_id = response.originBoardId,
				})
			end
		end

		callback(sprints)
	end)
end

-- Get all data for multiple projects efficiently
function M.get_project_data_batch(project_keys, callback, options)
	if not project_keys or #project_keys == 0 then
		callback({})
		return
	end

	local log = require("jira_ai.log")

	options = options or {}
	local include_issues = options.include_issues ~= false
	local include_epics = options.include_epics ~= false
	local include_sprints = options.include_sprints ~= false

	local project_data = {}
	local completed_projects = 0
	local total_projects = #project_keys

	for _, project_key in ipairs(project_keys) do
		local data = { project_key = project_key }
		local completed_operations = 0
		local total_operations = 0

		-- Count operations we need to do
		if include_issues then
			total_operations = total_operations + 1
		end
		if include_epics then
			total_operations = total_operations + 1
		end
		if include_sprints then
			total_operations = total_operations + 1
		end

		local function check_completion()
			completed_operations = completed_operations + 1
			if completed_operations == total_operations then
				table.insert(project_data, data)
				completed_projects = completed_projects + 1
				if completed_projects == total_projects then
					callback(project_data)
				end
			end
		end

		-- Get issues
		if include_issues then
			local issues = require("jira_ai.data.issues")
			issues.get_project_issues(project_key, function(project_issues, error)
				if error then
					log.warn("Failed to get issues for " .. project_key .. ": " .. error, "data.batch")
					project_issues = {}
				end
				data.issues = project_issues or {}
				check_completion()
			end, options.issues_options)
		end

		-- Get epics
		if include_epics then
			local epics = require("jira_ai.data.epics")
			epics.get_project_epics(project_key, function(project_epics, error)
				if error then
					log.warn("Failed to get epics for " .. project_key .. ": " .. error, "data.batch")
					project_epics = {}
				end
				data.epics = project_epics or {}
				check_completion()
			end, options.epics_options)
		end

		-- Get sprints
		if include_sprints then
			local sprints = require("jira_ai.data.sprints")
			sprints.get_project_sprints(project_key, function(project_sprints, error)
				if error then
					log.warn("Failed to get sprints for " .. project_key .. ": " .. error, "data.batch")
					project_sprints = {}
				end
				data.sprints = project_sprints or {}
				check_completion()
			end, options.sprints_options)
		end

		-- Handle case where no operations are requested
		if total_operations == 0 then
			table.insert(project_data, data)
			completed_projects = completed_projects + 1
			if completed_projects == total_projects then
				callback(project_data)
			end
		end
	end
end

-- Get comprehensive data for a single project
function M.get_complete_project_data(project_key, callback, options)
	options = options or {}

	local log = require("jira_ai.log")

	local project_data = { project_key = project_key }
	local completed_operations = 0
	local total_operations = 4 -- issues, epics, sprints, current_sprint

	local function check_completion()
		completed_operations = completed_operations + 1
		if completed_operations == total_operations then
			callback(project_data)
		end
	end

	-- Get project issues
	local issues = require("jira_ai.data.issues")
	issues.get_project_issues(project_key, function(project_issues, error)
		if error then
			log.warn("Failed to get issues for " .. project_key .. ": " .. error, "data.batch")
			project_issues = {}
		end
		project_data.issues = project_issues or {}
		check_completion()
	end, options.issues_options)

	-- Get project epics
	local epics = require("jira_ai.data.epics")
	epics.get_project_epics(project_key, function(project_epics, error)
		if error then
			log.warn("Failed to get epics for " .. project_key .. ": " .. error, "data.batch")
			project_epics = {}
		end
		project_data.epics = project_epics or {}
		check_completion()
	end, options.epics_options)

	-- Get project sprints
	local sprints = require("jira_ai.data.sprints")
	sprints.get_project_sprints(project_key, function(project_sprints, error)
		if error then
			log.warn("Failed to get sprints for " .. project_key .. ": " .. error, "data.batch")
			project_sprints = {}
		end
		project_data.sprints = project_sprints or {}
		check_completion()
	end, options.sprints_options)

	-- Get current sprint
	sprints.get_current_sprint(project_key, function(current_sprint, error)
		if error then
			log.warn("Failed to get current sprint for " .. project_key .. ": " .. error, "data.batch")
		end
		project_data.current_sprint = current_sprint
		check_completion()
	end)
end

-- Get changed data since last sync (incremental sync)
function M.get_incremental_data(since_date, callback, project_keys, options)
	options = options or {}

	local log = require("jira_ai.log")

	local incremental_data = {
		since_date = since_date,
		updated_issues = {},
		updated_epics = {},
		all_sprints = {}, -- Sprints don't have reliable update tracking, so get all
	}

	local completed_operations = 0
	local total_operations = 3

	local function check_completion()
		completed_operations = completed_operations + 1
		if completed_operations == total_operations then
			callback(incremental_data)
		end
	end

	-- Get updated issues
	local issues = require("jira_ai.data.issues")
	issues.get_updated_issues(since_date, function(updated_issues, error)
		if error then
			log.warn("Failed to get updated issues: " .. error, "data.batch")
			updated_issues = {}
		end
		incremental_data.updated_issues = updated_issues or {}
		check_completion()
	end, project_keys, options.issues_options)

	-- Get updated epics
	local epics = require("jira_ai.data.epics")
	epics.get_recently_updated_epics(30, function(updated_epics, error) -- Last 30 days for epics
		if error then
			log.warn("Failed to get updated epics: " .. error, "data.batch")
			updated_epics = {}
		end
		incremental_data.updated_epics = updated_epics or {}
		check_completion()
	end, project_keys, options.epics_options)

	-- Get all sprints (they don't have reliable update tracking)
	local sprints = require("jira_ai.data.sprints")
	sprints.get_all_project_sprints(function(all_sprints, error)
		if error then
			log.warn("Failed to get sprints: " .. error, "data.batch")
			all_sprints = {}
		end
		incremental_data.all_sprints = all_sprints or {}
		check_completion()
	end)
end

return M
