local M = {}

local function safe_field(field, key)
	if field == nil or field == vim.NIL then
		return nil
	end
	if key and type(field) == "table" then
		return field[key]
	end
	return field
end

local function parse_jira_datetime(dt)
	if not dt or dt == vim.NIL then
		return nil
	end
	local y, m, d, h, min, s = dt:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
	if y then
		return os.time({ year = y, month = m, day = d, hour = h, min = min, sec = s })
	end
	return nil
end

function M.get_all_comments(raw)
	local comments = raw.fields.comment and raw.fields.comment.comments or {}
	local out = {}
	for _, c in ipairs(comments) do
		if c.body then
			table.insert(out, c.body)
		end
	end
	return out
end

function M.filter_ignored_users(issues, ignored_users)
	local filtered = {}
	ignored_users = ignored_users or {}
	for _, issue in ipairs(issues) do
		local assignee = issue.assignee or "Unassigned"
		if assignee ~= "Unassigned" and not vim.tbl_contains(ignored_users, assignee) then
			table.insert(filtered, issue)
		end
	end
	return filtered
end

function M.extract_qa_bounces(changelog)
	local count = 0
	for _, entry in ipairs(changelog or {}) do
		if entry.field == "status" and (entry.toString == "In QA" or entry.fromString == "In QA") then
			count = count + 1
		end
	end
	return count
end

function M.calculate_stale_days(updated)
	local updated_ts = parse_jira_datetime(updated)
	if updated_ts then
		return math.floor((os.time() - updated_ts) / 86400)
	end
	return nil
end

function M.clean_issue(raw, changelog)
	local updated = safe_field(raw.fields.updated)
	local stale_days = M.calculate_stale_days(updated)
	local qa_bounces = changelog and M.extract_qa_bounces(changelog) or 0
	local blocked = M.is_blocked(raw)
	local comments = M.get_all_comments(raw)

	local highlight = nil
	if blocked then
		highlight = "Error"
	elseif stale_days and stale_days > 3 then
		highlight = "WarningMsg"
	elseif qa_bounces and qa_bounces > 3 then
		highlight = "Todo"
	end

	return {
		key = raw.key,
		summary = safe_field(raw.fields.summary),
		status = safe_field(raw.fields.status, "name"),
		assignee = safe_field(raw.fields.assignee, "displayName") or "Unassigned",
		storyPoints = safe_field(raw.fields.storyPoints) or safe_field(raw.fields.customfield_10016),
		blocked = blocked,
		blockers = M.get_blockers(raw),
		latest_comment = M.get_latest_comment(raw),
		epic_key = safe_field(raw.fields.epic, "key") or safe_field(raw.fields.epic),
		issuelinks = safe_field(raw.fields.issuelinks) or {},
		subtasks = safe_field(raw.fields.subtasks) or {},
		qa_bounces = qa_bounces,
		stale_days = stale_days,
		updated = updated,
		highlight = highlight,
		comments = comments,
	}
end

function M.clean_epic(raw)
	return {
		key = raw.key,
		summary = safe_field(raw.fields.summary),
	}
end

function M.is_blocked(raw)
	for _, link in ipairs(safe_field(raw.fields.issuelinks) or {}) do
		if safe_field(link.type, "name") == "Blocks" and link.inwardIssue then
			return true
		end
	end
	return false
end

function M.get_blockers(raw)
	local blockers = {}
	for _, link in ipairs(safe_field(raw.fields.issuelinks) or {}) do
		if safe_field(link.type, "name") == "Blocks" and link.inwardIssue then
			table.insert(blockers, link.inwardIssue.key)
		end
	end
	return blockers
end

function M.get_latest_comment(raw)
	local comments = safe_field(safe_field(raw.fields.comment), "comments") or {}
	return #comments > 0 and safe_field(comments[#comments], "body") or nil
end

function M.get_recent_comments(raw, n)
	local comments = safe_field(safe_field(raw.fields.comment), "comments") or {}
	local out = {}
	for i = math.max(1, #comments - n + 1), #comments do
		table.insert(out, safe_field(comments[i], "body"))
	end
	return out
end

function M.group_by_assignee(issues)
	local grouped = {}
	for _, issue in ipairs(issues) do
		local assignee = issue.assignee or "Unassigned"
		grouped[assignee] = grouped[assignee] or {}
		table.insert(grouped[assignee], issue)
	end
	return grouped
end

function M.group_issues_by_epic(issues)
	local grouped = {}
	for _, issue in ipairs(issues) do
		local epic = issue.epic_key or "No Epic"
		grouped[epic] = grouped[epic] or {}
		table.insert(grouped[epic], issue)
	end
	return grouped
end

function M.find_unassigned_issues(issues)
	local unassigned = {}
	for _, issue in ipairs(issues) do
		if not issue.assignee or issue.assignee == "Unassigned" then
			table.insert(unassigned, issue)
		end
	end
	return unassigned
end

function M.build_story_tree(issues, parent_key)
	local tree = {}
	for _, issue in ipairs(issues) do
		if issue.parent_key == parent_key then
			local node = vim.deepcopy(issue)
			node.children = M.build_story_tree(issues, issue.key)
			table.insert(tree, node)
		end
	end
	return tree
end

function M.summarize_user_stats(issues, changelogs)
	local stats = {}
	for _, issue in ipairs(issues) do
		local assignee = issue.assignee or "Unassigned"
		stats[assignee] = stats[assignee]
			or {
				completed_count = 0,
				total_days = 0,
				qa_bounces = 0,
				recent_issues = {},
				status_times = {},
				comment_counts = {},
				sprint_points = {},
				sprint_tickets = {},
			}
		local sprint = issue.sprint or "Unknown"
		local points = issue.storyPoints or 0
		local comments = issue.comments and #issue.comments or 0

		if issue.status == "Done" then
			stats[assignee].completed_count = stats[assignee].completed_count + 1
			local days = M.calculate_time_in_status(changelogs[issue.key] or {}, "Done")
			stats[assignee].total_days = stats[assignee].total_days + (days or 0)
			stats[assignee].sprint_points[sprint] = (stats[assignee].sprint_points[sprint] or 0) + points
			stats[assignee].sprint_tickets[sprint] = (stats[assignee].sprint_tickets[sprint] or 0) + 1
		end

		stats[assignee].qa_bounces = stats[assignee].qa_bounces + (issue.qa_bounces or 0)
		stats[assignee].comment_counts[issue.key] = comments
		stats[assignee].recent_issues[#stats[assignee].recent_issues + 1] = issue

		-- Average time in each status
		for _, entry in ipairs(changelogs[issue.key] or {}) do
			if entry.field == "status" then
				local status = entry.toString
				local created = entry.created
				local pattern = "(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)"
				local y, m, d, h, min, s = created:match(pattern)
				if y then
					local entered_time = os.time({ year = y, month = m, day = d, hour = h, min = min, sec = s })
					stats[assignee].status_times[status] = stats[assignee].status_times[status] or {}
					table.insert(stats[assignee].status_times[status], entered_time)
				end
			end
		end
	end

	local users = {}
	for name, s in pairs(stats) do
		local avg_status_times = {}
		for status, times in pairs(s.status_times) do
			if #times > 1 then
				local total = 0
				for i = 2, #times do
					total = total + (times[i] - times[i - 1])
				end
				avg_status_times[status] = total / (#times - 1) / 86400
			end
		end
		local velocity = {}
		for sprint, pts in pairs(s.sprint_points) do
			velocity[sprint] = { points = pts, tickets = s.sprint_tickets[sprint] }
		end
		local avg_comments = 0
		local comment_count = 0
		for _, c in pairs(s.comment_counts) do
			avg_comments = avg_comments + c
			comment_count = comment_count + 1
		end
		users[#users + 1] = {
			name = name,
			completed_count = s.completed_count,
			avg_completion_days = s.completed_count > 0 and (s.total_days / s.completed_count) or 0,
			qa_bounces = s.qa_bounces,
			velocity = velocity,
			avg_status_times = avg_status_times,
			avg_comments = comment_count > 0 and (avg_comments / comment_count) or 0,
			recent_issues = s.recent_issues,
		}
	end
	return users
end

function M.find_attention_issues(issues, config)
	local attention = {}
	for _, issue in ipairs(issues) do
		local is_stale = issue.stale_days and issue.stale_days > (config.stale_days or 3)
		if issue.blocked or is_stale or (issue.qa_bounces and issue.qa_bounces > (config.qa_bounce_threshold or 3)) then
			table.insert(attention, issue)
		end
	end
	return attention
end

function M.calculate_time_in_status(changelog, status_name)
	local last_entered = nil
	for _, entry in ipairs(changelog or {}) do
		if entry.field == "status" and entry.toString == status_name then
			last_entered = entry.created
		end
	end
	if last_entered then
		local pattern = "(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)"
		local y, m, d, h, min, s = last_entered:match(pattern)
		if y then
			local entered_time = os.time({ year = y, month = m, day = d, hour = h, min = min, sec = s })
			return (os.time() - entered_time) / 86400
		end
	end
	return nil
end

function M.users(raw_users)
	local out = {}
	for _, user in ipairs(raw_users or {}) do
		table.insert(out, {
			accountId = user.accountId,
			displayName = user.displayName,
		})
	end
	return out
end

function M.epics(raw_epics)
	local out = {}
	for _, epic in ipairs(raw_epics or {}) do
		local status = epic.fields and epic.fields.status and epic.fields.status.name
		if status == "In Progress" or status == "To Do" then
			table.insert(out, {
				key = epic.key,
				summary = epic.fields.summary,
				status = status,
			})
		end
	end
	return out
end

function M.sprint(raw)
	if not raw then
		return nil
	end
	return {
		id = raw.id,
		name = raw.name,
		state = raw.state,
		startDate = raw.startDate,
		endDate = raw.endDate,
	}
end

function M.sprints(raw_sprints)
	local out = {}
	for k, v in pairs(raw_sprints or {}) do
		out[k] = M.sprint(v)
	end
	return out
end

function M.epics_by_project(raw_epics)
	local out = {}
	for k, v in pairs(raw_epics or {}) do
		out[k] = M.epics(v)
	end
	return out
end

return M
