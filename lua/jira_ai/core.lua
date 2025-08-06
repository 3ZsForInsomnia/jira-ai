local service = require("jira_ai.service")
local transform = require("jira_ai.transform")
local markdown = require("jira_ai.markdown")
local output = require("jira_ai.output")

local M = {}

local function is_kanban(project, callback)
	service.get_current_sprints(function(current_sprints)
		callback(not current_sprints[project])
	end)
end

local function should_ignore_changelog(status)
	local config = require("jira_ai.config").options

	return vim.tbl_contains(config.ignore_changelog_statuses, status)
end

local function should_always_ignore(status)
	local config = require("jira_ai.config").options

	return vim.tbl_contains(config.always_ignore_statuses, status)
end

function M.sprint_snapshot()
	local config = require("jira_ai.config").options

	service.get_projects(function(projects)
		service.get_current_sprints(function(current_sprints)
			for _, project in ipairs(projects) do
				is_kanban(project, function(is_kanban_result)
					local issues = {}
					local jql = nil
					local sprint_name = nil
					if not is_kanban_result then
						local sprint = current_sprints[project]
						if sprint then
							jql = string.format("Sprint=%d", sprint.id)
							sprint_name = sprint.name
						else
							vim.notify("No active sprint found for project: " .. project)
						end
					else
						jql = string.format("project=%s", project)
					end
					if jql then
						service.get_issues_with_changelogs(jql, function(raw_issues)
							for _, raw in ipairs(raw_issues) do
								local status = raw.fields.status and raw.fields.status.name or ""
								if not should_always_ignore(status) then
									local changelog = not should_ignore_changelog(status)
											and raw.changelog
											and raw.changelog.histories
										or nil
									table.insert(issues, transform.clean_issue(raw, changelog))
								end
							end
							service.get_epics(function(epics_by_project)
								local epics = {}
								for _, raw_epic in ipairs(epics_by_project[project] or {}) do
									local epic = transform.clean_epic(raw_epic)
									local epic_issues = {}
									for _, issue in ipairs(issues) do
										if issue.epic_key == epic.key then
											table.insert(epic_issues, issue)
										end
									end
									epic.issues = epic_issues
									table.insert(epics, epic)
								end
								local filtered_issues = transform.filter_ignored_users(issues, config.ignored_users)
								local issues_by_assignee = transform.group_by_assignee(filtered_issues)
								local unassigned_issues = transform.find_unassigned_issues(issues)
								local snapshot_data = {
									sprint_name = sprint_name,
									epics = epics,
									issues_by_assignee = issues_by_assignee,
									unassigned_issues = unassigned_issues,
								}
								output.buffer_handler(markdown.sprint_snapshot(snapshot_data), project)
							end)
						end)
					end
				end)
			end
		end)
	end)
end

function M.attention_items()
	local config = require("jira_ai.config").options

	service.get_projects(function(projects)
		service.get_current_sprints(function(current_sprints)
			for _, project in ipairs(projects) do
				is_kanban(project, function(is_kanban_result)
					local issues = {}
					local jql = nil
					if is_kanban_result then
						jql = string.format("project=%s", project)
					else
						local sprint = current_sprints[project]
						if sprint then
							jql = string.format("Sprint=%d", sprint.id)
						else
							vim.notify("No active sprint found for project: " .. project)
						end
					end
					if jql then
						service.get_issues_with_changelogs(jql, function(raw_issues)
							for _, raw in ipairs(raw_issues) do
								local status = raw.fields.status and raw.fields.status.name or ""
								if not should_always_ignore(status) then
									local changelog = not should_ignore_changelog(status)
											and raw.changelog
											and raw.changelog.histories
										or nil
									table.insert(issues, transform.clean_issue(raw, changelog))
								end
							end
							local filtered_issues = transform.filter_ignored_users(issues, config.ignored_users)
							local attention = transform.find_attention_issues(filtered_issues, config)
							output.buffer_handler(markdown.attention_items({ attention = attention }), project)
						end)
					end
				end)
			end
		end)
	end)
end

function M.epic_story_map(epic_key)
	service.get_projects(function(projects)
		service.get_epics(function(epics_by_project)
			for _, project in ipairs(projects) do
				local epics = epics_by_project[project] or {}
				for _, raw_epic in ipairs(epics) do
					if raw_epic.key == epic_key then
						local epic = transform.clean_epic(raw_epic)
						local jql = string.format('cf[10008]="%s"', epic_key)
						service.get_issues_with_changelogs(jql, function(raw_issues)
							local issues = {}
							local function handle_issue(idx)
								if idx > #raw_issues then
									epic.stories = transform.build_story_tree(issues, epic_key)
									output.buffer_handler(markdown.epic_story_map({ epics = { epic } }), project)
									return
								end
								local raw = raw_issues[idx]
								service.get_issue_changelog(raw.key, function(changelog)
									table.insert(issues, transform.clean_issue(raw, changelog))
									handle_issue(idx + 1)
								end)
							end
							handle_issue(1)
						end)
						return
					end
				end
			end
			vim.notify("Epic not found: " .. epic_key)
		end)
	end)
end

function M.user_stats(user_name)
	service.get_projects(function(projects)
		local all_issues = {}
		local all_changelogs = {}
		local function process_project(idx)
			if idx > #projects then
				local users_stats = transform.summarize_user_stats(all_issues, all_changelogs)
				output.buffer_handler(markdown.user_stats({ users = users_stats }), "JiraAI-UserStats-" .. user_name)
				return
			end
			local project = projects[idx]
			service.get_sprints(function(sprints_by_project)
				local sprints = sprints_by_project[project] or {}
				local function process_sprint(sidx)
					if sidx > #sprints then
						process_project(idx + 1)
						return
					end
					local sprint = sprints[sidx]
					local sprint_obj = sprint
					if sprint_obj then
						local jql = string.format("Sprint=%d", sprint_obj.id)
						service.get_issues_with_changelogs(jql, function(raw_issues)
							local function handle_issue(iidx)
								if iidx > #raw_issues then
									process_sprint(sidx + 1)
									return
								end
								local raw = raw_issues[iidx]
								local issue = transform.clean_issue(raw)
								if issue.assignee == user_name then
									table.insert(all_issues, issue)
									service.get_issue_changelog(raw.key, function(changelog)
										all_changelogs[raw.key] = changelog
										handle_issue(iidx + 1)
									end)
								else
									handle_issue(iidx + 1)
								end
							end
							handle_issue(1)
						end)
					else
						process_sprint(sidx + 1)
					end
				end
				process_sprint(1)
			end)
		end
		process_project(1)
	end)
end

return M
