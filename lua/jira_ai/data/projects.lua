-- Project and board data retrieval

local M = {}

-- Get all projects
function M.get_projects(callback)
	local log = require("jira_ai.log")
	local error_handling = require("jira_ai.error_handling")
	local data_utils = require("jira_ai.data")
	
	log.info("Fetching all projects from Jira", "data.projects")
	
	error_handling.safe_async(function(safe_callback)
		data_utils.jira_api_request_async("/rest/api/2/project", nil, safe_callback)
	end, function(response, error)
		if error then
			log.error("Failed to fetch projects: " .. error, "data.projects")
			callback(nil, error)
			return
		end

		if not response then
			log.warn("No projects returned from Jira API", "data.projects")
			callback({})
			return
		end

		-- Validate response structure
		if type(response) ~= "table" then
			log.error("Invalid projects response format", "data.projects")
			callback(nil, "Invalid response format")
			return
		end
		
		log.info("Successfully fetched " .. #response .. " projects", "data.projects")
		-- Transform to our expected format
		local projects = {}
		for _, project in ipairs(response) do
			-- Validate required project fields
			if project.key and project.name then
				table.insert(projects, {
					key = project.key,
					name = project.name,
					project_type = project.projectTypeKey,
					active = 1 -- Default to active, will be managed in DB
				})
			else
				log.warn("Skipping project with missing key or name: " .. vim.inspect(project), "data.projects")
			end
		end

		callback(projects)
	end, "data.projects")
end

-- Get project by key with additional details
function M.get_project_details(project_key, callback)
	local data_utils = require("jira_ai.data")
	
	data_utils.jira_api_request_async("/rest/api/2/project/" .. project_key, nil, function(response, error)
		if error then
			callback(nil, error)
			return
		end

		if not response then
			callback(nil, "Project not found: " .. project_key)
			return
		end

		callback({
			key = response.key,
			name = response.name,
			description = response.description,
			project_type = response.projectTypeKey,
			lead = response.lead and response.lead.accountId or nil,
			active = 1,
		})
	end)
end

-- Get boards for a project
function M.get_project_boards(project_key, callback)
	local data_utils = require("jira_ai.data")
	
	local params = {
		projectKeyOrId = project_key,
		type = "scrum,kanban",
	}

	data_utils.paginated_request("/rest/agile/1.0/board", params, function(boards, error)
		if error then
			callback(nil, error)
			return
		end

		-- Transform to our expected format
		local transformed_boards = {}
		for _, board in ipairs(boards or {}) do
			table.insert(transformed_boards, {
				id = board.id,
				name = board.name,
				type = board.type,
				project_key = project_key,
			})
		end

		callback(transformed_boards)
	end)
end

-- Get all configured projects with their details
function M.get_configured_projects_details(callback)
	local log = require("jira_ai.log")
	local error_handling = require("jira_ai.error_handling")
	
	local config = require("jira_ai.config").options
	local configured_projects = config.jira_projects or {}

	log.info("Fetching details for " .. #configured_projects .. " configured projects", "data.projects")
	if #configured_projects == 0 then
		log.warn("No projects configured in jira_projects", "data.projects")
		callback({})
		return
	end

	local project_details = {}
	local completed = 0
	local total = #configured_projects
	local errors = {}

	for _, project_key in ipairs(configured_projects) do
		-- Add timeout and error handling per project
		local get_details_with_fallback = error_handling.with_fallback(
			M.get_project_details,
			function(key, cb)
				-- Fallback: create minimal project details
				log.info("Using fallback project details for " .. key, "data.projects")
				cb({
					key = key,
					name = key,
					active = 1
				}, nil)
			end,
			"data.projects"
		)
		
		get_details_with_fallback(project_key, function(details, error)
			if error then
				log.warn("Failed to get details for project " .. project_key .. ": " .. error, "data.projects")
				table.insert(errors, {project = project_key, error = error})
			end

			if details then
				table.insert(project_details, details)
			end
			
			completed = completed + 1

			if completed == total then
				log.info("Successfully fetched details for " .. #project_details .. " projects", "data.projects")
				if #errors > 0 then
					log.warn("Encountered " .. #errors .. " errors while fetching project details", "data.projects")
				end
				callback(project_details)
			end
		end)
	end
end

-- Check if project exists and is accessible
function M.validate_project_access(project_key, callback)
	M.get_project_details(project_key, function(details, error)
		if error then
			callback(false, error)
		else
			callback(true, details)
		end
	end)
end

-- Get project statuses (for building status category mappings)
function M.get_project_statuses(project_key, callback)
	local data_utils = require("jira_ai.data")
	
	data_utils.jira_api_request_async(
		"/rest/api/2/project/" .. project_key .. "/statuses",
		nil,
		function(response, error)
			if error then
				callback(nil, error)
				return
			end

			if not response then
				callback({})
				return
			end

			-- Extract unique status names across all issue types
			local statuses = {}
			local seen = {}

			for _, issue_type in ipairs(response) do
				if issue_type.statuses then
					for _, status in ipairs(issue_type.statuses) do
						if not seen[status.name] then
							seen[status.name] = true
							table.insert(statuses, {
								name = status.name,
								description = status.description,
								category_name = status.statusCategory and status.statusCategory.name or nil,
								category_key = status.statusCategory and status.statusCategory.key or nil,
							})
						end
					end
				end
			end

			callback(statuses)
		end
	)
end

-- Get all statuses across configured projects
function M.get_all_project_statuses(callback)
	local config = require("jira_ai.config").options
	local configured_projects = config.jira_projects or {}

	if #configured_projects == 0 then
		callback({})
		return
	end

	local all_statuses = {}
	local seen = {}
	local completed = 0
	local total = #configured_projects

	for _, project_key in ipairs(configured_projects) do
		M.get_project_statuses(project_key, function(statuses, error)
			if error then
				vim.notify("Failed to get statuses for project " .. project_key .. ": " .. error, vim.log.levels.WARN)
			else
				for _, status in ipairs(statuses or {}) do
					if not seen[status.name] then
						seen[status.name] = true
						table.insert(all_statuses, status)
					end
				end
			end

			completed = completed + 1
			if completed == total then
				callback(all_statuses)
			end
		end)
	end
end

return M
