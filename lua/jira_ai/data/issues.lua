-- Issue/ticket data retrieval with comprehensive field sets

local M = {}

-- Get issues with comprehensive field set and changelog
function M.get_issues_with_changelogs(jql, callback, options)
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.tickets
	local expand = options.expand or data_utils.EXPAND_SETS.tickets_full
	
	local params = {
		jql = jql,
		fields = fields,
		expand = expand,
		maxResults = options.max_results or 100
	}
	
	data_utils.paginated_request("/rest/api/2/search", params, function(issues, error)
		if error then
			callback(nil, error)
			return
		end
		
		callback(issues or {})
	end, {
		max_results = options.max_results or 100,
		max_pages = options.max_pages or 50
	})
end

-- Get issues for a specific sprint
function M.get_sprint_issues(sprint_id, callback, options)
	local jql = "Sprint = " .. sprint_id
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues for a project
function M.get_project_issues(project_key, callback, options)
	local jql = "project = " .. project_key
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues for an epic
function M.get_epic_issues(epic_key, callback, options)
	-- Epic link field can vary, try common ones
	local jql = string.format('cf[10008] = "%s" OR "Epic Link" = "%s"', epic_key, epic_key)
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues assigned to a user
function M.get_user_issues(assignee_account_id, callback, options)
	local jql = "assignee = " .. assignee_account_id
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues updated since a specific date
function M.get_updated_issues(since_date, callback, project_keys, options)
	local data_utils = require("jira_ai.data")
	
	local jql_parts = { "updated >= '" .. since_date .. "'" }
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get unassigned issues
function M.get_unassigned_issues(project_keys, callback, options)
	local data_utils = require("jira_ai.data")
	
	local jql_parts = { "assignee is EMPTY" }
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get blocked issues (issues with blocking links)
function M.get_blocked_issues(project_keys, callback, options)
	local jql_parts = { "issueFunction in linkedIssuesOf('project = {0} and issueType != Epic', 'is blocked by')" }
	
	if project_keys and #project_keys > 0 then
		jql_parts[1] = string.format(jql_parts[1], table.concat(project_keys, ", "))
	else
		-- Fallback for all projects
		jql_parts = { "issueFunction in linkedIssuesOf('issueType != Epic', 'is blocked by')" }
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues with recent activity (comments, status changes)
function M.get_recently_active_issues(days_back, callback, project_keys, options)
	days_back = days_back or 7
	local data_utils = require("jira_ai.data")
	
	local date_filter = string.format("updated >= -%dd", days_back)
	local jql_parts = { date_filter }
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get stale issues (not updated recently)
function M.get_stale_issues(days_threshold, callback, project_keys, options)
	days_threshold = days_threshold or 14
	local data_utils = require("jira_ai.data")
	
	local date_filter = string.format("updated <= -%dd", days_threshold)
	local status_filter = "status not in (Done, Closed, Resolved, Cancelled)"
	local jql_parts = { date_filter, status_filter }
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get single issue with full details
function M.get_issue_details(issue_key, callback, options)
	options = options or {}
	local data_utils = require("jira_ai.data")
	local fields = options.fields or data_utils.FIELD_SETS.tickets
	local expand = options.expand or data_utils.EXPAND_SETS.tickets_full
	
	local query_params = data_utils.build_query_params({
		fields = fields,
		expand = expand
	})
	
	data_utils.jira_api_request_async("/rest/api/2/issue/" .. issue_key, query_params, function(response, error)
		if error then
			callback(nil, error)
			return
		end
		
		callback(response)
	end)
end

-- Get issue changelog only (for cases where we just need status history)
function M.get_issue_changelog(issue_key, callback)
	local data_utils = require("jira_ai.data")
	
	data_utils.jira_api_request_async("/rest/api/2/issue/" .. issue_key, "expand=changelog", function(response, error)
		if error then
			callback(nil, error)
			return
		end
		
		local changelog = response and response.changelog and response.changelog.histories or {}
		callback(changelog)
	end)
end

-- Batch get changelogs for multiple issues (more efficient than individual calls)
function M.get_multiple_changelogs(issue_keys, callback)
	if not issue_keys or #issue_keys == 0 then
		callback({})
		return
	end
	
	local data_utils = require("jira_ai.data")
	
	-- Split into batches to avoid URL length limits
	local batch_size = 50
	local batches = {}
	
	for i = 1, #issue_keys, batch_size do
		local batch = {}
		for j = i, math.min(i + batch_size - 1, #issue_keys) do
			table.insert(batch, issue_keys[j])
		end
		table.insert(batches, batch)
	end
	
	local all_changelogs = {}
	local completed_batches = 0
	
	for _, batch in ipairs(batches) do
		local jql = data_utils.build_jql({ key = batch })
		
		local params = {
			jql = jql,
			fields = "key", -- We only need the key, changelog is in expand
			expand = "changelog",
			maxResults = batch_size
		}
		
		data_utils.jira_api_request_async("/rest/api/2/search", data_utils.build_query_params(params), function(response, error)
			if error then
				vim.notify("Failed to get changelog batch: " .. error, vim.log.levels.WARN)
			else
				local issues = response and response.issues or {}
				for _, issue in ipairs(issues) do
					all_changelogs[issue.key] = issue.changelog and issue.changelog.histories or {}
				end
			end
			
			completed_batches = completed_batches + 1
			if completed_batches == #batches then
				callback(all_changelogs)
			end
		end)
	end
end

-- Get issues with specific status
function M.get_issues_by_status(status_names, callback, project_keys, options)
	local data_utils = require("jira_ai.data")
	
	local status_condition = data_utils.build_jql({ status = status_names })
	local jql_parts = { status_condition }
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues in QA (for bounce detection)
function M.get_qa_issues(callback, project_keys, options)
	-- This will need to be updated once we have status category mapping
	local qa_statuses = { "In QA", "Testing", "Ready for QA", "QA Review", "Code Review" }
	return M.get_issues_by_status(qa_statuses, callback, project_keys, options)
end

-- Get subtasks for a parent issue
function M.get_subtasks(parent_key, callback, options)
	local jql = "parent = " .. parent_key
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues with excessive comments (potential discussion issues)
function M.get_issues_with_many_comments(min_comments, callback, project_keys, options)
	min_comments = min_comments or 10
	
	local data_utils = require("jira_ai.data")
	
	-- This uses a JQL function that may not be available in all Jira instances
	local jql_parts = { string.format("comment ~ '.' AND comment ~ '.' AND comment ~ '.'") } -- Rough approximation
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get issues by priority (for risk assessment)
function M.get_issues_by_priority(priority_names, callback, project_keys, options)
	local data_utils = require("jira_ai.data")
	
	local priority_condition = data_utils.build_jql({ priority = priority_names })
	local jql_parts = { priority_condition }
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

-- Get high priority issues
function M.get_high_priority_issues(callback, project_keys, options)
	local high_priorities = { "Highest", "High", "Critical", "Blocker" }
	return M.get_issues_by_priority(high_priorities, callback, project_keys, options)
end

-- Get overdue issues (past due date)
function M.get_overdue_issues(callback, project_keys, options)
	local today = os.date("%Y-%m-%d")
	local data_utils = require("jira_ai.data")
	
	local jql_parts = { "due < '" .. today .. "'" }
	
	if project_keys and #project_keys > 0 then
		table.insert(jql_parts, data_utils.build_jql({ project = project_keys }))
	end
	
	local jql = table.concat(jql_parts, " AND ")
	return M.get_issues_with_changelogs(jql, callback, options)
end

return M