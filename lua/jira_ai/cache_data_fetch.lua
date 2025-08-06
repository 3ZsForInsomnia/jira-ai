local data = require("jira_ai.data")

local M = {}

function M.fetch_long_lived_metadata(callback)
	data.get_projects(function(projects)
		data.get_all_users(function(users_resp)
			callback({
				projects = projects,
				users = users_resp or {},
			})
		end)
	end)
end

function M.fetch_short_lived_metadata(callback)
	data.get_projects(function(projects)
		local epics = {}
		local sprints = {}
		local current_sprints = {}
		local remaining = #projects

		if remaining == 0 then
			callback({
				epics = epics,
				sprints = sprints,
				current_sprints = current_sprints,
			})
			return
		end

		for _, project in ipairs(projects) do
			data.get_epics(project, function(raw_epics)
				epics[project] = raw_epics

				local function after_sprint(sprint)
					if sprint then
						sprints[project] = sprint
					end
					data.find_current_sprint(sprints[project] and { sprints[project] } or {}, function(current)
						current_sprints[project] = current
						remaining = remaining - 1
						if remaining == 0 then
							callback({
								epics = epics,
								sprints = sprints,
								current_sprints = current_sprints,
							})
						end
					end)
				end

				data.get_active_sprint(project, after_sprint)
			end)
		end
	end)
end

return M
