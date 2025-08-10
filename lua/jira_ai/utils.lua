local service = require("jira_ai.service")

local M = {}

function M.get_configured_projects(callback)
	local config = require("jira_ai.config").options
	local configured = config.jira_projects or {}

	service.get_projects(function(all_projects)
		local filtered = {}
		for _, project in ipairs(all_projects) do
			if vim.tbl_contains(configured, project) then
				table.insert(filtered, project)
			end
		end
		callback(filtered)
	end)
end

return M
