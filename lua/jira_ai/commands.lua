local core = require("jira_ai.core")
local service = require("jira_ai.service")

local M = {}

function M.setup()
	vim.api.nvim_create_user_command("JiraAISnapshot", function()
		core.sprint_snapshot()
	end, { desc = "Show Jira sprint status snapshot in buffer" })

	vim.api.nvim_create_user_command("JiraAIAttention", function()
		core.attention_items()
	end, { desc = "Show Jira attention items in buffer" })

	vim.api.nvim_create_user_command("JiraAIEpicStoryMap", function(opts)
		local epic_key = opts.args
		if not epic_key or epic_key == "" then
			vim.notify("Please provide an epic key.")
			return
		end
		core.epic_story_map(epic_key)
	end, {
		nargs = 1,
		desc = "Show Jira epic/story map in buffer",
	})

	vim.api.nvim_create_user_command("JiraAISyncCache", function()
		service.get_projects(function()
			vim.notify("Jira AI cache sync triggered.")
		end)
	end, { desc = "Sync Jira AI local cache" })

	vim.api.nvim_create_user_command("JiraAIUserStats", function()
		service.get_users(function(users)
			local user_names = {}
			for _, user in ipairs(users) do
				table.insert(user_names, user.displayName)
			end
			vim.ui.select(user_names, { prompt = "Select user for stats:" }, function(selected)
				if selected then
					core.user_stats(selected)
				end
			end)
		end)
	end, { desc = "Show Jira user stats in buffer" })
end

return M
