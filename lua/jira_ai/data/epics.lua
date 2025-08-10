
local M = {}

-- Get all epics for a project
function M.get_project_epics(project_key, callback, options)
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.epics

	local jql = string.format("project = %s AND issuetype = Epic", project_key)

	local params = {
		jql = jql,
		fields = fields,
		maxResults = options.max_results or 50,
	}

	data_utils.paginated_request("/rest/api/2/search", params, function(epics, error)
		if error then
			callback(nil, error)
			return
		end

		callback(epics or {})
	end, {
		max_results = options.max_results or 50,
		max_pages = options.max_pages or 10,
	})
end

-- Get all epics for configured projects
function M.get_all_project_epics(callback, options)
	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	if #project_keys == 0 then
		callback({})
		return
	end

	local all_epics = {}
	local completed = 0
	local total = #project_keys

	for _, project_key in ipairs(project_keys) do
		M.get_project_epics(project_key, function(epics, error)
			if error then
				vim.notify("Failed to get epics for " .. project_key .. ": " .. error, vim.log.levels.WARN)
				epics = {}
			end

			all_epics[project_key] = epics or {}

			completed = completed + 1
			if completed == total then
				callback(all_epics)
			end
		end, options)
	end
end

-- Get active epics (not done/closed)
function M.get_active_epics(project_key, callback, options)
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.epics

	local jql = string.format(
		"project = %s AND issuetype = Epic AND status not in (Done, Closed, Resolved, Cancelled)",
		project_key
	)

	local params = {
		jql = jql,
		fields = fields,
		maxResults = options.max_results or 50,
	}

	data_utils.paginated_request("/rest/api/2/search", params, function(epics, error)
		if error then
			callback(nil, error)
			return
		end

		callback(epics or {})
	end, {
		max_results = options.max_results or 50,
		max_pages = options.max_pages or 5,
	})
end

-- Get epic by key with full details
function M.get_epic_details(epic_key, callback, options)
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.epics
	local expand = options.expand or "changelog"

	local query_params = data_utils.build_query_params({
		fields = fields,
		expand = expand,
	})

	data_utils.jira_api_request_async("/rest/api/2/issue/" .. epic_key, query_params, function(response, error)
		if error then
			callback(nil, error)
			return
		end

		if not response then
			callback(nil, "Epic not found: " .. epic_key)
			return
		end

		callback(response)
	end)
end

-- Get epic with all its stories/issues
function M.get_epic_with_stories(epic_key, callback, options)
	local issues = require("jira_ai.data.issues")
	
	-- First get the epic details
	M.get_epic_details(epic_key, function(epic, error)
		if error then
			callback(nil, error)
			return
		end

		-- Then get all issues in the epic
		issues.get_epic_issues(epic_key, function(stories, error)
			if error then
				callback(nil, error)
				return
			end

			-- Attach stories to epic
			epic.stories = stories or {}
			callback(epic)
		end, options)
	end, options)
end

-- Get epics with progress information
function M.get_epics_with_progress(project_key, callback, options)
	local issues = require("jira_ai.data.issues")
	
	M.get_project_epics(project_key, function(epics, error)
		if error then
			callback(nil, error)
			return
		end

		if not epics or #epics == 0 then
			callback({})
			return
		end

		-- For each epic, get its issues to calculate progress
		local epics_with_progress = {}
		local completed = 0
		local total = #epics

		for _, epic in ipairs(epics) do
			local epic_with_progress = vim.deepcopy(epic)

			-- Get issues for this epic
			issues.get_epic_issues(epic.key, function(stories, error)
				if error then
					vim.notify("Failed to get stories for epic " .. epic.key .. ": " .. error, vim.log.levels.WARN)
					stories = {}
				end

				-- Calculate progress
				local total_stories = #stories
				local completed_stories = 0
				local total_points = 0
				local completed_points = 0

				for _, story in ipairs(stories) do
					local fields = story.fields or {}
					local status = fields.status and fields.status.name or ""
					local points = fields.customfield_10016 or fields.storyPoints or 0

					total_points = total_points + points

					if status == "Done" or status == "Closed" or status == "Resolved" then
						completed_stories = completed_stories + 1
						completed_points = completed_points + points
					end
				end

				epic_with_progress.progress = {
					total_stories = total_stories,
					completed_stories = completed_stories,
					total_points = total_points,
					completed_points = completed_points,
					completion_percentage = total_stories > 0 and (completed_stories / total_stories * 100) or 0,
				}

				table.insert(epics_with_progress, epic_with_progress)

				completed = completed + 1
				if completed == total then
					callback(epics_with_progress)
				end
			end, { max_results = 200 }) -- Get more stories per epic
		end
	end, options)
end

-- Search epics by name/summary
function M.search_epics(search_term, callback, project_keys, options)
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.epics

	local jql_parts = {
		"issuetype = Epic",
		string.format("(summary ~ '%s' OR description ~ '%s')", search_term, search_term),
	}

	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end

	local jql = table.concat(jql_parts, " AND ")

	local params = {
		jql = jql,
		fields = fields,
		maxResults = options.max_results or 20,
	}

	data_utils.paginated_request("/rest/api/2/search", params, function(epics, error)
		if error then
			callback(nil, error)
			return
		end

		callback(epics or {})
	end, {
		max_results = options.max_results or 20,
		max_pages = 3,
	})
end

-- Get recently updated epics
function M.get_recently_updated_epics(days_back, callback, project_keys, options)
	days_back = days_back or 30
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.epics

	local date_filter = string.format("updated >= -%dd", days_back)
	local jql_parts = { "issuetype = Epic", date_filter }

	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end

	local jql = table.concat(jql_parts, " AND ")

	local params = {
		jql = jql,
		fields = fields,
		maxResults = options.max_results or 50,
	}

	data_utils.paginated_request("/rest/api/2/search", params, function(epics, error)
		if error then
			callback(nil, error)
			return
		end

		callback(epics or {})
	end, {
		max_results = options.max_results or 50,
		max_pages = 5,
	})
end

-- Get epics by assignee
function M.get_epics_by_assignee(assignee_account_id, callback, project_keys, options)
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.epics

	local jql_parts = {
		"issuetype = Epic",
		"assignee = " .. assignee_account_id,
	}

	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end

	local jql = table.concat(jql_parts, " AND ")

	local params = {
		jql = jql,
		fields = fields,
		maxResults = options.max_results or 50,
	}

	data_utils.paginated_request("/rest/api/2/search", params, function(epics, error)
		if error then
			callback(nil, error)
			return
		end

		callback(epics or {})
	end, {
		max_results = options.max_results or 50,
		max_pages = 5,
	})
end

-- Get epic hierarchy (epic -> stories -> subtasks)
function M.get_epic_hierarchy(epic_key, callback, options)
	local issues = require("jira_ai.data.issues")
	
	M.get_epic_with_stories(epic_key, function(epic, error)
		if error then
			callback(nil, error)
			return
		end

		-- For each story, get its subtasks
		local stories = epic.stories or {}
		if #stories == 0 then
			callback(epic)
			return
		end

		local completed = 0
		local total = #stories

		for i, story in ipairs(stories) do
			issues.get_subtasks(story.key, function(subtasks, error)
				if error then
					vim.notify("Failed to get subtasks for " .. story.key .. ": " .. error, vim.log.levels.WARN)
					subtasks = {}
				end

				stories[i].subtasks = subtasks or {}

				completed = completed + 1
				if completed == total then
					callback(epic)
				end
			end, options)
		end
	end, options)
end

return M
