-- Sprint data retrieval

local M = {}

-- Get board ID for a project (needed for sprint operations)
function M.get_project_board_id(project_key, callback)
	local data_utils = require("jira_ai.data")
	
	local params = {
		projectKeyOrId = project_key,
	}

	data_utils.jira_api_request_async(
		"/rest/agile/1.0/board",
		data_utils.build_query_params(params),
		function(response, error)
			if error then
				callback(nil, error)
				return
			end

			local boards = response and response.values or {}
			if #boards == 0 then
				callback(nil, "No boards found for project: " .. project_key)
				return
			end

			-- Return the first board (most projects have one main board)
			callback(boards[1].id, nil, boards[1])
		end
	)
end

-- Get all sprints for a board
function M.get_board_sprints(board_id, callback, state_filter)
	local data_utils = require("jira_ai.data")
	
	local params = {
		maxResults = 50,
	}

	if state_filter then
		params.state = state_filter -- "active", "closed", "future"
	end

	data_utils.paginated_request("/rest/agile/1.0/board/" .. board_id .. "/sprint", params, function(sprints, error)
		if error then
			callback(nil, error)
			return
		end

		-- Transform to our expected format
		local transformed_sprints = {}
		for _, sprint in ipairs(sprints or {}) do
			table.insert(transformed_sprints, {
				id = sprint.id,
				name = sprint.name,
				state = sprint.state,
				start_date = sprint.startDate,
				end_date = sprint.endDate,
				complete_date = sprint.completeDate,
				goal = sprint.goal,
				board_id = board_id,
			})
		end

		callback(transformed_sprints)
	end, {
		max_results = 50,
		max_pages = 20, -- Reasonable limit for sprint history
	})
end

-- Get sprints for a project
function M.get_project_sprints(project_key, callback, state_filter)
	M.get_project_board_id(project_key, function(board_id, error)
		if error then
			callback(nil, error)
			return
		end

		M.get_board_sprints(board_id, function(sprints, error)
			if error then
				callback(nil, error)
				return
			end

			-- Add project_key to each sprint
			for _, sprint in ipairs(sprints) do
				sprint.project_key = project_key
			end

			callback(sprints)
		end, state_filter)
	end)
end

-- Get current/active sprint for a project
function M.get_current_sprint(project_key, callback)
	M.get_project_sprints(project_key, function(sprints, error)
		if error then
			callback(nil, error)
			return
		end

		-- Find active sprint
		for _, sprint in ipairs(sprints or {}) do
			if sprint.state == "active" then
				callback(sprint)
				return
			end
		end

		-- No active sprint found
		callback(nil)
	end, "active")
end

-- Get current sprints for all configured projects
function M.get_all_current_sprints(callback)
	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	if #project_keys == 0 then
		callback({})
		return
	end

	local current_sprints = {}
	local completed = 0
	local total = #project_keys

	for _, project_key in ipairs(project_keys) do
		M.get_current_sprint(project_key, function(sprint, error)
			if error then
				vim.notify("Failed to get current sprint for " .. project_key .. ": " .. error, vim.log.levels.WARN)
			elseif sprint then
				current_sprints[project_key] = sprint
			end

			completed = completed + 1
			if completed == total then
				callback(current_sprints)
			end
		end)
	end
end

-- Get sprint by ID with details
function M.get_sprint_details(sprint_id, callback)
	local data_utils = require("jira_ai.data")
	
	data_utils.jira_api_request_async("/rest/agile/1.0/sprint/" .. sprint_id, nil, function(response, error)
		if error then
			callback(nil, error)
			return
		end

		if not response then
			callback(nil, "Sprint not found: " .. sprint_id)
			return
		end

		callback({
			id = response.id,
			name = response.name,
			state = response.state,
			start_date = response.startDate,
			end_date = response.endDate,
			complete_date = response.completeDate,
			goal = response.goal,
			origin_board_id = response.originBoardId,
		})
	end)
end

-- Get recent completed sprints for velocity analysis
function M.get_recent_completed_sprints(project_key, count, callback)
	count = count or 5

	M.get_project_sprints(project_key, function(sprints, error)
		if error then
			callback(nil, error)
			return
		end

		-- Filter and sort completed sprints
		local completed_sprints = {}
		for _, sprint in ipairs(sprints or {}) do
			if sprint.state == "closed" and sprint.complete_date then
				table.insert(completed_sprints, sprint)
			end
		end

		-- Sort by completion date, most recent first
		table.sort(completed_sprints, function(a, b)
			return (a.complete_date or "") > (b.complete_date or "")
		end)

		-- Return only the requested count
		local result = {}
		for i = 1, math.min(count, #completed_sprints) do
			table.insert(result, completed_sprints[i])
		end

		callback(result)
	end, "closed")
end

-- Get sprint issues (tickets in a sprint)
function M.get_sprint_issues(sprint_id, callback, include_fields)
	local data_utils = require("jira_ai.data")
	
	local fields = include_fields or data_utils.FIELD_SETS.tickets
	local expand = "changelog" -- Always include changelog for sprint analysis

	local params = {
		fields = fields,
		expand = expand,
		maxResults = 100,
	}

	data_utils.paginated_request("/rest/agile/1.0/sprint/" .. sprint_id .. "/issue", params, function(issues, error)
		if error then
			callback(nil, error)
			return
		end

		callback(issues or {})
	end, {
		max_results = 100,
		max_pages = 10, -- Most sprints shouldn't have more than 1000 issues
	})
end

-- Check if project uses sprints (vs kanban)
function M.is_project_sprint_based(project_key, callback)
	M.get_current_sprint(project_key, function(sprint, error)
		if error then
			-- If we can't get sprints, assume it's kanban/not sprint-based
			callback(false)
		else
			-- If we found a current sprint, it's sprint-based
			callback(sprint ~= nil)
		end
	end)
end

-- Get all sprints for configured projects
function M.get_all_project_sprints(callback, state_filter)
	local config = require("jira_ai.config").options
	local project_keys = config.jira_projects or {}

	if #project_keys == 0 then
		callback({})
		return
	end

	local all_sprints = {}
	local completed = 0
	local total = #project_keys

	for _, project_key in ipairs(project_keys) do
		M.get_project_sprints(project_key, function(sprints, error)
			if error then
				vim.notify("Failed to get sprints for " .. project_key .. ": " .. error, vim.log.levels.WARN)
				sprints = {}
			end

			-- Add to results with project grouping
			all_sprints[project_key] = sprints or {}

			completed = completed + 1
			if completed == total then
				callback(all_sprints)
			end
		end, state_filter)
	end
end

-- Get sprint velocity data (for completed sprints)
function M.get_sprint_velocity(sprint_id, callback)
	M.get_sprint_issues(sprint_id, function(issues, error)
		if error then
			callback(nil, error)
			return
		end

		local velocity_data = {
			sprint_id = sprint_id,
			total_issues = #issues,
			completed_issues = 0,
			total_points = 0,
			completed_points = 0,
			issues_by_status = {},
		}

		for _, issue in ipairs(issues) do
			local fields = issue.fields or {}
			local status = fields.status and fields.status.name or "Unknown"
			local points = fields.customfield_10016 or fields.storyPoints or 0 -- Common story points field

			velocity_data.total_points = velocity_data.total_points + points

			-- Count by status
			velocity_data.issues_by_status[status] = (velocity_data.issues_by_status[status] or 0) + 1

			-- Check if completed (this will need status category mapping)
			if status == "Done" or status == "Closed" or status == "Resolved" then
				velocity_data.completed_issues = velocity_data.completed_issues + 1
				velocity_data.completed_points = velocity_data.completed_points + points
			end
		end

		callback(velocity_data)
	end)
end

return M
