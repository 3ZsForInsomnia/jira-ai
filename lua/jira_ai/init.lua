local cache = require("jira_ai.cache")
local commands = require("jira_ai.commands")
local log = require("jira_ai.log")

local M = {}

function M.setup(user_opts)
	local config = require("jira_ai.config")

	config.setup(user_opts)
	
	-- Log system initialization
	log.log_system_info()
	log.info("Jira AI plugin initialized", "init")
	
	commands.setup()
	cache.setup_autosync()
end

return M
