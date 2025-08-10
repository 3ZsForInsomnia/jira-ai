local Job = require("plenary.job")

local M = {}

local function urlencode(str)
	return str:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

local function jira_api_request_async(endpoint, query, callback)
	local config = require("jira_ai.config").options

	local url = config.jira_base_url .. endpoint

	if query then
		url = url .. "?" .. query
	end

	local auth = config.jira_email_address .. ":" .. config.jira_api_token

	Job:new({
		command = "curl",
		args = { "-s", "-u", auth, "-H", "Accept: application/json", url },
		on_exit = function(j, return_val)
			local result = table.concat(j:result(), "\n")
			vim.schedule(function()
				local ok, decoded = pcall(vim.fn.json_decode, result)
				callback(ok and decoded or nil)
			end)
		end,
	}):start()
end

function M.find_current_sprint(sprints, callback)
	local now = os.time()
	for _, sprint in ipairs(sprints) do
		if sprint.state == "active" and sprint.startDate and sprint.endDate then
			local pattern = "(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)"
			local sy, sm, sd, sh, smin, ss = sprint.startDate:match(pattern)
			local ey, em, ed, eh, emin, es = sprint.endDate:match(pattern)
			if sy and ey then
				local start_ts = os.time({ year = sy, month = sm, day = sd, hour = sh, min = smin, sec = ss })
				local end_ts = os.time({ year = ey, month = em, day = ed, hour = eh, min = emin, sec = es })
				if now >= start_ts and now <= end_ts then
					callback(sprint)
					return
				end
			end
		end
	end
	callback(nil)
end

function M.get_projects(callback)
	jira_api_request_async("/rest/api/2/project", nil, function(resp)
		if not resp then
			vim.notify("Failed to fetch projects from Jira API", vim.log.levels.ERROR)
			callback({})
			return
		end
		local projects = {}
		for _, project in ipairs(resp) do
			table.insert(projects, project.key)
		end
		callback(projects)
	end)
end

function M.get_issues_with_changelogs(jql, callback)
	local query = "jql="
		.. urlencode(jql)
		.. "&fields=key,summary,status,assignee,storyPoints,issuelinks,epic,issuetype,comment&expand=changelog"
	jira_api_request_async("/rest/api/2/search", query, function(resp)
		callback(resp and resp.issues or {})
	end)
end

function M.get_issues_for_sprint(sprint_id, callback)
	local issues = {}
	local start_at = 0
	local max_results = 50
	local function fetch_page()
		jira_api_request_async(
			string.format("/rest/agile/1.0/sprint/%d/issue", sprint_id),
			string.format(
				"fields=key,summary,status,assignee,storyPoints,issuelinks,epic&startAt=%d&maxResults=%d",
				start_at,
				max_results
			),
			function(resp)
				if not resp or not resp.issues then
					callback(issues)
					return
				end
				for _, issue in ipairs(resp.issues) do
					table.insert(issues, issue)
				end
				if #resp.issues < max_results then
					callback(issues)
				else
					start_at = start_at + max_results
					fetch_page()
				end
			end
		)
	end
	fetch_page()
end

function M.get_epics(project, callback)
	local jql = string.format("project=%s AND issuetype=Epic", project)
	jira_api_request_async(
		"/rest/api/2/search",
		"jql=" .. urlencode(jql) .. "&fields=key,summary,status",
		function(resp)
			callback(resp and resp.issues or {})
		end
	)
end

function M.get_issue_changelog(issue_key, callback)
	jira_api_request_async(string.format("/rest/api/2/issue/%s", issue_key), "expand=changelog", function(resp)
		callback(resp and resp.changelog and resp.changelog.histories or {})
	end)
end

function M.get_board_issues(project, callback)
	jira_api_request_async("/rest/agile/1.0/board", "projectKeyOrId=" .. project, function(boards)
		if not boards or not boards.values or #boards.values == 0 then
			callback({})
			return
		end
		local board_id = boards.values[1].id
		local issues = {}
		local start_at = 0
		local max_results = 50
		local function fetch_page()
			jira_api_request_async(
				string.format("/rest/agile/1.0/board/%d/issue", board_id),
				string.format(
					"fields=key,summary,status,assignee,storyPoints,issuelinks,epic&startAt=%d&maxResults=%d",
					start_at,
					max_results
				),
				function(resp)
					if not resp or not resp.issues then
						callback(issues)
						return
					end
					for _, issue in ipairs(resp.issues) do
						table.insert(issues, issue)
					end
					if #resp.issues < max_results then
						callback(issues)
					else
						start_at = start_at + max_results
						fetch_page()
					end
				end
			)
		end
		fetch_page()
	end)
end

function M.get_all_users(callback)
	local users = {}
	local start_at = 0
	local max_results = 50
	local function fetch_page()
		jira_api_request_async(
			"/rest/api/3/users/search",
			string.format("startAt=%d&maxResults=%d", start_at, max_results),
			function(resp)
				if not resp or #resp == 0 then
					callback(users)
					return
				end
				for _, user in ipairs(resp) do
					table.insert(users, user)
				end
				if #resp < max_results then
					callback(users)
				else
					start_at = start_at + max_results
					fetch_page()
				end
			end
		)
	end
	fetch_page()
end

function M.get_active_sprint(project, callback)
	-- Try to get boards from cache asynchronously (lazy load to avoid circular dependency)
	local cache_data = nil
	local cache_ok, cache_module = pcall(require, "jira_ai.cache")
	if cache_ok then
		cache_data = cache_module.read_cache()
	end
	local boards = cache_data and cache_data.boards or {}

	local function handle_board(board_id)
		jira_api_request_async(
			string.format("/rest/agile/1.0/board/%d/sprint", board_id),
			"state=active",
			function(sprints_resp)
				if not sprints_resp or not sprints_resp.values or #sprints_resp.values == 0 then
					callback(nil)
					return
				end
				callback(sprints_resp.values[1])
			end
		)
	end

	if boards[project] and boards[project].id then
		handle_board(boards[project].id)
	else
		jira_api_request_async("/rest/agile/1.0/board", "projectKeyOrId=" .. project, function(boards_resp)
			if not boards_resp or not boards_resp.values or #boards_resp.values == 0 then
				callback(nil)
				return
			end
			handle_board(boards_resp.values[1].id)
		end)
	end
end

return M
