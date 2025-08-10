-- User data retrieval

local M = {}

-- Get all users (paginated)
function M.get_all_users(callback)
	local data_utils = require("jira_ai.data")
	
	local params = {
		maxResults = 50
	}
	
	data_utils.paginated_request("/rest/api/3/users/search", params, function(users, error)
		if error then
			vim.notify("Failed to fetch users: " .. error, vim.log.levels.ERROR)
			callback(nil, error)
			return
		end
		
		-- Transform to our expected format
		local transformed_users = {}
		for _, user in ipairs(users or {}) do
			table.insert(transformed_users, {
				account_id = user.accountId,
				display_name = user.displayName,
				email = user.emailAddress,
				active = user.active ~= false, -- Default to true if not specified
				avatar_url = user.avatarUrls and user.avatarUrls["48x48"] or nil
			})
		end
		
		callback(transformed_users)
	end, {
		max_results = 50,
		max_pages = 50 -- Reasonable limit for user count
	})
end

-- Get active users only
function M.get_active_users(callback)
	M.get_all_users(function(users, error)
		if error then
			callback(nil, error)
			return
		end
		
		-- Filter to only active users
		local active_users = {}
		for _, user in ipairs(users or {}) do
			if user.active then
				table.insert(active_users, user)
			end
		end
		
		callback(active_users)
	end)
end

-- Get user by account ID
function M.get_user_by_id(account_id, callback)
	local data_utils = require("jira_ai.data")
	
	data_utils.jira_api_request_async("/rest/api/3/user", "accountId=" .. account_id, function(response, error)
		if error then
			callback(nil, error)
			return
		end
		
		if not response then
			callback(nil, "User not found: " .. account_id)
			return
		end
		
		callback({
			account_id = response.accountId,
			display_name = response.displayName,
			email = response.emailAddress,
			active = response.active ~= false,
			avatar_url = response.avatarUrls and response.avatarUrls["48x48"] or nil
		})
	end)
end

-- Search users by display name or email
function M.search_users(query, callback, max_results)
	max_results = max_results or 20
	
	local data_utils = require("jira_ai.data")
	
	local params = {
		query = query,
		maxResults = max_results
	}
	
	local query_string = data_utils.build_query_params(params)
	
	data_utils.jira_api_request_async("/rest/api/3/user/search", query_string, function(response, error)
		if error then
			callback(nil, error)
			return
		end
		
		-- Transform to our expected format
		local transformed_users = {}
		for _, user in ipairs(response or {}) do
			table.insert(transformed_users, {
				account_id = user.accountId,
				display_name = user.displayName,
				email = user.emailAddress,
				active = user.active ~= false,
				avatar_url = user.avatarUrls and user.avatarUrls["48x48"] or nil
			})
		end
		
		callback(transformed_users)
	end)
end

-- Get users who have been assignees in configured projects
function M.get_project_assignees(project_keys, callback)
	if not project_keys or #project_keys == 0 then
		callback({})
		return
	end
	
	local data_utils = require("jira_ai.data")
	
	-- Build JQL to find all assignees in these projects
	local project_condition = data_utils.build_jql({ project = project_keys })
	local jql = project_condition .. " AND assignee is not EMPTY"
	
	local params = {
		jql = jql,
		fields = "assignee",
		maxResults = 1000 -- We just want the assignees, not the full issues
	}
	
	data_utils.paginated_request("/rest/api/2/search", params, function(issues, error)
		if error then
			callback(nil, error)
			return
		end
		
		-- Extract unique assignees
		local assignees = {}
		local seen_assignees = {}
		
		for _, issue in ipairs(issues or {}) do
			local assignee = issue.fields and issue.fields.assignee
			if assignee and assignee.accountId and not seen_assignees[assignee.accountId] then
				seen_assignees[assignee.accountId] = true
				table.insert(assignees, {
					account_id = assignee.accountId,
					display_name = assignee.displayName,
					email = assignee.emailAddress,
					active = assignee.active ~= false,
					avatar_url = assignee.avatarUrls and assignee.avatarUrls["48x48"] or nil
				})
			end
		end
		
		callback(assignees)
	end, {
		max_results = 100,
		max_pages = 10 -- Reasonable limit for finding assignees
	})
end

-- Get users with their recent activity (issues assigned/created)
function M.get_users_with_activity(project_keys, days_back, callback)
	days_back = days_back or 30
	
	if not project_keys or #project_keys == 0 then
		callback({})
		return
	end
	
	local data_utils = require("jira_ai.data")
	
	local date_filter = string.format("updated >= -%dd", days_back)
	local project_condition = data_utils.build_jql({ project = project_keys })
	local jql = project_condition .. " AND " .. date_filter .. " AND (assignee is not EMPTY OR reporter is not EMPTY)"
	
	local params = {
		jql = jql,
		fields = "assignee,reporter",
		maxResults = 1000
	}
	
	data_utils.paginated_request("/rest/api/2/search", params, function(issues, error)
		if error then
			callback(nil, error)
			return
		end
		
		-- Extract unique users from assignees and reporters
		local active_users = {}
		local seen_users = {}
		
		local function add_user(user_data)
			if user_data and user_data.accountId and not seen_users[user_data.accountId] then
				seen_users[user_data.accountId] = true
				table.insert(active_users, {
					account_id = user_data.accountId,
					display_name = user_data.displayName,
					email = user_data.emailAddress,
					active = user_data.active ~= false,
					avatar_url = user_data.avatarUrls and user_data.avatarUrls["48x48"] or nil
				})
			end
		end
		
		for _, issue in ipairs(issues or {}) do
			local fields = issue.fields or {}
			add_user(fields.assignee)
			add_user(fields.reporter)
		end
		
		callback(active_users)
	end, {
		max_results = 100,
		max_pages = 10
	})
end

-- Get user permissions for a project (to check access)
function M.get_user_project_permissions(account_id, project_key, callback)
	local data_utils = require("jira_ai.data")
	
	local params = {
		accountId = account_id,
		projectKey = project_key
	}
	
	local query_string = data_utils.build_query_params(params)
	
	data_utils.jira_api_request_async("/rest/api/3/user/permission/search", query_string, function(response, error)
		if error then
			callback(nil, error)
			return
		end
		
		-- Extract permission names
		local permissions = {}
		for _, permission in ipairs(response or {}) do
			table.insert(permissions, permission.key)
		end
		
		callback(permissions)
	end)
end

return M