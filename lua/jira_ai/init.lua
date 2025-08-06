local cache = require("jira_ai.cache")
local commands = require("jira_ai.commands")

local M = {}

function M.setup(user_opts)
	local config = require("jira_ai.config")

	config.setup(user_opts)
	commands.setup()
	cache.setup_autosync()
end

return M
