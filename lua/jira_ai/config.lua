local M = {}

M.defaults = {
	qa_status = "In QA",
	days_in_sprint_remaining = 3,
	stuck_threshold_days = 3, -- in days
	qa_bounce_threshold = 3,
	stale_days = 3, -- days before marking as stale
	sprint_lookback = 3, -- in sprints
	file_name_format = "%s/%s-%s.md", -- dir, project, timestamp
	output_dir = nil, -- if set, overrides XDG
	cache_dir = nil, -- if set, overrides XDG
	header_template = string.rep("=", 60) .. "\nJira AI summary for project: %s\n" .. string.rep("=", 60) .. "\n",
	notify = true,
	default_register = '"', -- Default register for yank (unnamed register)
	jira_api_token = nil,
	jira_projects = nil,
	jira_base_url = nil,
	jira_email_address = nil,
	ignore_changelog_statuses = { "Done", "Released", "Awaiting Release", "Open" },
	always_ignore_statuses = { "Cancelled", "Closed", "Resolved" },
	status_order = { "Open", "Blocked", "In Progress", "Code Review", "In QA", "Done" },
	ignored_users = { "Unassigned" },
	cache_ttl_long = 60 * 60 * 24 * 5,
	cache_ttl_short = 60 * 60 * 12,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})

	local required = { "jira_projects", "jira_base_url", "jira_email_address", "jira_api_token" }

	for _, key in ipairs(required) do
		if not M.options[key] or (type(M.options[key]) == "table" and vim.tbl_isempty(M.options[key])) then
			error("jira-ai: config option '" .. key .. "' is required")
		end
	end
end

return M
