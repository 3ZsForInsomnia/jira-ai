local M = {}

local function get_xdg_state_home()
	return os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
end

local function get_jira_ai_dir()
	local config = require("jira_ai.config").options

	local dir = config.output_dir or (get_xdg_state_home() .. "/nvim/jira-ai")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	return dir
end

local function get_timestamp()
	return os.date("%Y%m%d-%H")
end

function M.file_handler(markdown, project)
	local config = require("jira_ai.config").options

	local dir = get_jira_ai_dir()
	local fname = string.format(config.file_name_format, dir, project, get_timestamp())
	local f = io.open(fname, "w")
	if f then
		f:write(markdown)
		f:close()
		if config.notify then
			vim.notify("Jira AI output written to: " .. fname)
		end
		return fname
	else
		error("Failed to write Jira AI output to file: " .. fname)
	end
end

function M.buffer_handler(markdown, name)
	vim.cmd("enew")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(markdown, "\n"))
	if name then
		vim.api.nvim_buf_set_name(0, name)
	end
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, line in ipairs(lines) do
		-- Highlight issue key
		local s, e = line:find("%([A-Z0-9%-]+%)")
		if s then
			vim.api.nvim_buf_add_highlight(buf, -1, "Identifier", i - 1, s - 1, e)
		end
		-- Highlight type
		local ts, te = line:find(": %w+ ")
		if ts then
			vim.api.nvim_buf_add_highlight(buf, -1, "Type", i - 1, ts, te)
		end
		-- Highlight points
		local ps, pe = line:find("%d+ Points")
		if ps then
			vim.api.nvim_buf_add_highlight(buf, -1, "Number", i - 1, ps - 1, pe)
		end
		-- Highlight QA bounces
		local qs, qe = line:find("%d+ Bounce%-backs from QA")
		if qs then
			vim.api.nvim_buf_add_highlight(buf, -1, "WarningMsg", i - 1, qs - 1, qe)
		end
		-- Highlight comments
		if line:find("^%s*Comment:") then
			vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i - 1, 0, -1)
		end
	end
	vim.notify("Jira AI output written to new buffer" .. (name and (" [" .. name .. "]") or ""))
end

function M.register_handler(markdown, reg)
	local config = require("jira_ai.config").options

	reg = reg or config.default_register or '"'
	vim.fn.setreg(reg, markdown)
	vim.notify("Jira AI output yanked to register: " .. reg)
end

return M
