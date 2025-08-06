local M = {}

local function section(title)
	return string.format("## %s\n", title)
end

local function issue_line(issue)
	local type_str = issue.type or ""
	local points_str = string.format("%s Points", issue.storyPoints or 0)
	local qa_str = issue.qa_bounces and string.format("%s Bounce-backs from QA", issue.qa_bounces) or ""
	local line = string.format("(%s): %s %s\n    %s   %s\n", issue.key, type_str, issue.summary, points_str, qa_str)
	if issue.comments and #issue.comments > 0 then
		for _, comment in ipairs(issue.comments) do
			line = line .. "    Comment: " .. comment .. "\n"
		end
	end
	return line .. "\n"
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
	local lines = { "# Sprint Status Snapshot\n" }
	if data.sprint_name then
		table.insert(lines, string.format("**Sprint:** %s\n", data.sprint_name))
	end
	table.insert(lines, section("Epics"))
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
		table.insert(
			lines,
			string.format(
				"- %s (%s): %d/%d tickets, %d/%d pts",
				epic.summary,
				epic.key,
				done,
				total,
				pts_done,
				pts_total
			)
		)
	end

	table.insert(lines, section("Epics"))
	for _, epic in ipairs(data.epics or {}) do
		table.insert(lines, string.format("- %s (%s)", epic.summary, epic.key))
	end
	table.insert(lines, section("Issues by Assignee"))
	for assignee, issues in pairs(data.issues_by_assignee or {}) do
		table.insert(lines, string.format("### %s", assignee))
		local by_status = {}
		for _, issue in ipairs(issues) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, "  " .. status)
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, "    " .. issue_line(issue))
			end
		end
	end
	table.insert(lines, section("Unassigned Issues"))
	for _, issue in ipairs(data.unassigned_issues or {}) do
		table.insert(lines, issue_line(issue))
	end
	return table.concat(lines, "\n")
end

function M.attention_items(data)
	local lines = { "# Attention Items\n" }
	local by_status = {}
	for _, issue in ipairs(data.attention or {}) do
		by_status[issue.status] = by_status[issue.status] or {}
		table.insert(by_status[issue.status], issue)
	end
	for _, status in ipairs(ordered_statuses(by_status)) do
		table.insert(lines, "## " .. status)
		for _, issue in ipairs(by_status[status]) do
			table.insert(lines, issue_line(issue))
			if issue.latest_comment then
				table.insert(lines, "  - Latest comment: " .. issue.latest_comment)
			end
			if issue.blockers then
				table.insert(lines, "  - Blocked by: " .. table.concat(issue.blockers, ", "))
			end
		end
	end
	return table.concat(lines, "\n")
end

local function render_story_tree(story, depth)
	local prefix = string.rep("  ", depth or 0) .. "- "
	local lines = { prefix .. string.format("[%s] %s (%s)", story.key, story.summary, story.status) }
	for _, sub in ipairs(story.children or {}) do
		vim.list_extend(lines, render_story_tree(sub, (depth or 0) + 1))
	end
	return lines
end

function M.epic_story_map(data)
	local lines = { "# Epic/Story Map\n" }
	for _, epic in ipairs(data.epics or {}) do
		table.insert(lines, string.format("## %s (%s)", epic.summary, epic.key))
		for _, story in ipairs(epic.stories or {}) do
			vim.list_extend(lines, render_story_tree(story, 1))
		end
	end
	return table.concat(lines, "\n")
end

function M.user_stats(data)
	local lines = { "# User Stats\n" }
	for _, user in ipairs(data.users or {}) do
		table.insert(lines, string.format("## %s", user.name))
		table.insert(lines, "Velocity per sprint:")
		for sprint, v in pairs(user.velocity or {}) do
			table.insert(lines, string.format("  - %s: %d pts, %d tickets", sprint, v.points, v.tickets))
		end
		table.insert(lines, "Average time in status:")
		for status, days in pairs(user.avg_status_times or {}) do
			table.insert(lines, string.format("  - %s: %.1f days", status, days))
		end
		table.insert(lines, string.format("QA bounces: %d", user.qa_bounces or 0))
		table.insert(lines, string.format("Comments per ticket: %.2f", user.avg_comments or 0))
		table.insert(lines, section("Recent Tickets"))
		local by_status = {}
		for _, issue in ipairs(user.recent_issues or {}) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, "  " .. status)
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, "    " .. issue_line(issue))
			end
		end
	end
	return table.concat(lines, "\n")
end

function M.epic_progress(data)
	local lines = { "# Epic Progress\n" }
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
		table.insert(
			lines,
			string.format(
				"## %s (%s): %d/%d tickets, %d/%d pts",
				epic.summary,
				epic.key,
				done,
				total,
				pts_done,
				pts_total
			)
		)
		local by_status = {}
		for _, issue in ipairs(epic.issues or {}) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, "  " .. status)
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, "    " .. issue_line(issue))
			end
		end
	end
	return table.concat(lines, "\n")
end

function M.sprint_status(data)
	local lines = { "# Sprint Status\n" }
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
			lines,
			string.format("## %s: %d/%d tickets, %d/%d pts", sprint.name, done, total, pts_done, pts_total)
		)
		local by_status = {}
		for _, issue in ipairs(sprint.issues or {}) do
			by_status[issue.status] = by_status[issue.status] or {}
			table.insert(by_status[issue.status], issue)
		end
		for _, status in ipairs(ordered_statuses(by_status)) do
			table.insert(lines, "  " .. status)
			for _, issue in ipairs(by_status[status]) do
				table.insert(lines, "    " .. issue_line(issue))
			end
		end
	end
	return table.concat(lines, "\n")
end

return M
