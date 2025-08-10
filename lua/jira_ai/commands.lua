local core = require("jira_ai.core")
local service = require("jira_ai.service")
local picker_utils = require("jira_ai.picker_utils")
local log = require("jira_ai.log")
local error_handling = require("jira_ai.error_handling")

local M = {}

function M.setup()
	vim.api.nvim_create_user_command("JiraAISnapshot", function()
		log.info("User initiated snapshot command", "commands")

		-- Validate configuration before executing
		local config_valid, config_error = error_handling.validate_config()
		if not config_valid then
			log.notify_error("Configuration error: " .. config_error.message)
			return
		end

		log.notify_info("Generating sprint snapshot...")

		-- Wrap in error handling
		local success, result = pcall(core.sprint_snapshot)
		if not success then
			log.error("Sprint snapshot command failed: " .. tostring(result), "commands")
			log.notify_error("Failed to generate sprint snapshot. Check logs for details.")
		end
	end, { desc = "Show Jira sprint status snapshot in buffer" })

	vim.api.nvim_create_user_command("JiraAIAttention", function()
		log.info("User initiated attention items command", "commands")

		-- Validate configuration before executing
		local config_valid, config_error = error_handling.validate_config()
		if not config_valid then
			log.notify_error("Configuration error: " .. config_error.message)
			return
		end

		log.notify_info("Generating attention items...")

		-- Wrap in error handling
		local success, result = pcall(core.attention_items)
		if not success then
			log.error("Attention items command failed: " .. tostring(result), "commands")
			log.notify_error("Failed to generate attention items. Check logs for details.")
		end
	end, { desc = "Show Jira attention items in buffer" })

	vim.api.nvim_create_user_command("JiraAIEpicStoryMap", function(opts)
		local epic_key = opts.args
		if not epic_key or epic_key == "" then
			log.notify_error("Please provide an epic key.")
			return
		end
		log.info("User initiated epic story map for: " .. epic_key, "commands")
		log.notify_info("Generating epic story map for " .. epic_key .. "...")
		core.epic_story_map(epic_key)
	end, {
		nargs = 1,
		desc = "Show Jira epic/story map in buffer",
	})

	vim.api.nvim_create_user_command("JiraAISyncCache", function()
		log.info("User initiated cache sync", "commands")
		log.notify_info("Syncing Jira cache...")
		service.get_projects(function()
			log.notify_info("Jira AI cache sync completed")
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

	-- File browsing commands using vim.ui.select (install telescope extension for better experience)
	vim.api.nvim_create_user_command("JiraAIBrowse", function(opts)
		local project = opts.args ~= "" and opts.args or nil
		picker_utils.browse_all_files(project)
	end, {
		nargs = "?",
		desc = "Browse all Jira AI files [project]",
		complete = function()
			return require("jira_ai.files").get_configured_projects()
		end,
	})

	vim.api.nvim_create_user_command("JiraAIBrowseSnapshots", function(opts)
		local project = opts.args ~= "" and opts.args or nil
		picker_utils.browse_snapshots(project)
	end, {
		nargs = "?",
		desc = "Browse Jira AI snapshot files [project]",
		complete = function()
			return require("jira_ai.files").get_configured_projects()
		end,
	})

	vim.api.nvim_create_user_command("JiraAIBrowseAttention", function(opts)
		local project = opts.args ~= "" and opts.args or nil
		picker_utils.browse_attention(project)
	end, {
		nargs = "?",
		desc = "Browse Jira AI attention item files [project]",
		complete = function()
			return require("jira_ai.files").get_configured_projects()
		end,
	})

	vim.api.nvim_create_user_command("JiraAIBrowseEpics", function(opts)
		local project = opts.args ~= "" and opts.args or nil
		picker_utils.browse_epics(project)
	end, {
		nargs = "?",
		desc = "Browse Jira AI epic story map files [project]",
		complete = function()
			return require("jira_ai.files").get_configured_projects()
		end,
	})

	vim.api.nvim_create_user_command("JiraAIBrowseUserStats", function(opts)
		local project = opts.args ~= "" and opts.args or nil
		picker_utils.browse_user_stats(project)
	end, {
		nargs = "?",
		desc = "Browse Jira AI user stats files [project]",
		complete = function()
			return require("jira_ai.files").get_configured_projects()
		end,
	})

	-- Debug commands
	vim.api.nvim_create_user_command("JiraAILogs", function()
		local log_path = log.get_log_file_path()
		vim.cmd("edit " .. log_path)
		log.info("User opened log file", "commands")
	end, { desc = "Open Jira AI log file" })

	vim.api.nvim_create_user_command("JiraAIClearLogs", function()
		if log.clear_logs() then
			log.notify_info("Log file cleared")
		else
			log.notify_error("Failed to clear log file")
		end
	end, { desc = "Clear Jira AI log file" })
end

return M
