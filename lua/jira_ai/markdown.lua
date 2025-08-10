local M = {}

local function issue_header_and_content(issue, base_url)
	local url = base_url and string.format("%s/browse/%s", base_url, issue.key) or nil
	local header_line = url and string.format("### [%s](%s)", issue.key, url) or string.format("### %s", issue.key)
	
	local type_str = issue.type or ""
	local points_str = string.format("%s Points", issue.storyPoints or 0)
	local qa_str = issue.qa_bounces and string.format("%s Bounce-backs from QA", issue.qa_bounces) or ""
	
	local lines = { header_line, "" } -- Add newline after header
	
	if not url then
		table.insert(lines, string.format("**URL:** %s/browse/%s", base_url or "JIRA_BASE_URL", issue.key))
		table.insert(lines, "")
	end
	
	table.insert(lines, string.format("**Type:** %s", type_str))
	table.insert(lines, string.format("**Summary:** %s", issue.summary or ""))
	table.insert(lines, string.format("**Points:** %s", points_str))
	
	if qa_str ~= "" then
		table.insert(lines, string.format("**QA Bounces:** %s", qa_str))
	end
	
	if issue.comments and #issue.comments > 0 then
		table.insert(lines, "**Comments:**")
		for _, comment in ipairs(issue.comments) do
			table.insert(lines, string.format("- %s", comment))
		end
	end
	
	table.insert(lines, "") -- Add space after issue
	return table.concat(lines, "\n")
end

local function ordered_statuses(by_status)
	local config = require("jira_ai.config").options

	local status_order = config.status_order or {}
	local ordered = {}
	local seen = {}
	for _, status in ipairs(status_order) do
		if by_status[status] then
			table.insert(ordered, status)
			seen[status] = true
		end
	end
	for status, _ in pairs(by_status) do
		if not seen[status] then
			table.insert(ordered, status)
		end
	end
	return ordered
end

function M.sprint_snapshot(data)
	local config = require("jira_ai.config").options
	local base_url = config.jira_base_url
	
	local lines = { "# Sprint Status Snapshot", "" }
	
	if data.sprint_name then
		table.insert(lines, string.format("**Sprint:** %s", data.sprint_name))
		table.insert(lines, "")
	end
	
	-- Single epics section with progress
	table.insert(lines, "## Epic Progress")
	table.insert(lines, "")
	
	for _, epic in ipairs(data.epics or {}) do
		local done, total, pts_done, pts_total = 0, 0, 0, 0
		for _, issue in ipairs(epic.issues or {}) do
			total = total + 1
			pts_total = pts_total + (issue.storyPoints or 0)
			if issue.status == "Done" then
				done = done + 1
				pts_done = pts_done + (issue.storyPoints or 0)
			end
		end
		table.insert(lines, string.format("- **%s** (%s): %d/%d tickets, %d/%d pts", 
			epic.summary or "Unknown Epic", epic.key, done, total, pts_done, pts_total))
	end
	table.insert(lines, "")

	table.insert(lines, "## Issues by Assignee")
	table.insert(lines, "")
	
	for assignee, issues in pairs(data.issues_by_assignee or {}) do
		table.insert(lines, string.format("### %s", assignee))
		table.insert(lines, "")
		
		local by_status = {}
		for _, issue in ipairs(issues) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, string.format("#### %s", status))
			table.insert(lines, "")
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, issue_header_and_content(issue, base_url))
			end
		end
	end
	
	table.insert(lines, "## Unassigned Issues")
	table.insert(lines, "")
	for _, issue in ipairs(data.unassigned_issues or {}) do
		table.insert(lines, issue_header_and_content(issue, base_url))
	end
	
	return table.concat(lines, "\n")
end

function M.attention_items(data)
	local config = require("jira_ai.config").options
	local base_url = config.jira_base_url
	
	local lines = { "# Attention Items", "" }
	local by_status = {}
	for _, issue in ipairs(data.attention or {}) do
		by_status[issue.status] = by_status[issue.status] or {}
		table.insert(by_status[issue.status], issue)
	end
	for _, status in ipairs(ordered_statuses(by_status)) do
		table.insert(lines, "## " .. status)
		table.insert(lines, "")
		for _, issue in ipairs(by_status[status]) do
			table.insert(lines, issue_header_and_content(issue, base_url))
			if issue.latest_comment then
				table.insert(lines, "**Latest comment:** " .. issue.latest_comment)
				table.insert(lines, "")
			end
			if issue.blockers then
				table.insert(lines, "**Blocked by:** " .. table.concat(issue.blockers, ", "))
				table.insert(lines, "")
			end
		end
	end
	return table.concat(lines, "\n")
end

local function render_story_tree(story, depth)
	local config = require("jira_ai.config").options
	local base_url = config.jira_base_url
	local url = base_url and string.format("%s/browse/%s", base_url, story.key) or nil
	local prefix = string.rep("  ", depth or 0) .. "- "
	local story_link = url and string.format("[%s](%s)", story.key, url) or story.key
	local lines = { prefix .. string.format("%s %s (%s)", story_link, story.summary, story.status) }
	for _, sub in ipairs(story.children or {}) do
		vim.list_extend(lines, render_story_tree(sub, (depth or 0) + 1))
	end
	return lines
end

function M.epic_story_map(data)
	local lines = { "# Epic/Story Map", "" }
	for _, epic in ipairs(data.epics or {}) do
		table.insert(lines, string.format("## %s (%s)", epic.summary, epic.key))
		table.insert(lines, "")
		for _, story in ipairs(epic.stories or {}) do
			vim.list_extend(lines, render_story_tree(story, 1))
		end
		table.insert(lines, "")
	end
	return table.concat(lines, "\n")
end

function M.user_stats(data)
	local config = require("jira_ai.config").options
	local base_url = config.jira_base_url
	
	local lines = { "# User Stats", "" }
	for _, user in ipairs(data.users or {}) do
		table.insert(lines, string.format("## %s", user.name))
		table.insert(lines, "")
		table.insert(lines, "Velocity per sprint:")
		for sprint, v in pairs(user.velocity or {}) do
			table.insert(lines, string.format("- %s: %d pts, %d tickets", sprint, v.points, v.tickets))
		end
		table.insert(lines, "")
		table.insert(lines, "Average time in status:")
		for status, days in pairs(user.avg_status_times or {}) do
			table.insert(lines, string.format("- %s: %.1f days", status, days))
		end
		table.insert(lines, "")
		table.insert(lines, string.format("QA bounces: %d", user.qa_bounces or 0))
		table.insert(lines, string.format("Comments per ticket: %.2f", user.avg_comments or 0))
		table.insert(lines, "")
		table.insert(lines, "### Recent Tickets")
		table.insert(lines, "")
		local by_status = {}
		for _, issue in ipairs(user.recent_issues or {}) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, "#### " .. status)
			table.insert(lines, "")
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, issue_header_and_content(issue, base_url))
			end
		end
	end
	return table.concat(lines, "\n")
end

function M.epic_progress(data)
	local config = require("jira_ai.config").options
	local base_url = config.jira_base_url
	
	local lines = { "# Epic Progress", "" }
	for _, epic in ipairs(data.epics or {}) do
		local done, total, pts_done, pts_total = 0, 0, 0, 0
		for _, issue in ipairs(epic.issues or {}) do
			total = total + 1
			pts_total = pts_total + (issue.storyPoints or 0)
			if issue.status == "Done" then
				done = done + 1
				pts_done = pts_done + (issue.storyPoints or 0)
			end
		end
		table.insert(lines, string.format("## %s (%s): %d/%d tickets, %d/%d pts",
			epic.summary, epic.key, done, total, pts_done, pts_total))
		table.insert(lines, "")
		local by_status = {}
		for _, issue in ipairs(epic.issues or {}) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, "### " .. status)
			table.insert(lines, "")
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, issue_header_and_content(issue, base_url))
			end
		end
	end
	return table.concat(lines, "\n")
end

function M.sprint_status(data)
	local config = require("jira_ai.config").options
	local base_url = config.jira_base_url
	
	local lines = { "# Sprint Status", "" }
	for _, sprint in ipairs(data.sprints or {}) do
		local done, total, pts_done, pts_total = 0, 0, 0, 0
		for _, issue in ipairs(sprint.issues or {}) do
			total = total + 1
			pts_total = pts_total + (issue.storyPoints or 0)
			if issue.status == "Done" then
				done = done + 1
				pts_done = pts_done + (issue.storyPoints or 0)
			end
		end
		table.insert(
		table.insert(lines, "")
			lines,
			string.format("## %s: %d/%d tickets, %d/%d pts", sprint.name, done, total, pts_done, pts_total)
		)
		local by_status = {}
		for _, issue in ipairs(sprint.issues or {}) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, "### " .. status)
			table.insert(lines, "")
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, issue_header_and_content(issue, base_url))
			end
		end
	end
	return table.concat(lines, "\n")
end

return M
