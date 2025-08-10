local M = {}

local function get_xdg_state_home()
	return os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
end

local function get_jira_ai_base_dir()
	local config = require("jira_ai.config").options

	local dir = config.output_dir or (get_xdg_state_home() .. "/nvim/jira-ai")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	return dir
end

local function get_output_dir(output_type)
	local base_dir = get_jira_ai_base_dir()
	local type_dir = base_dir .. "/" .. output_type
	if vim.fn.isdirectory(type_dir) == 0 then
		vim.fn.mkdir(type_dir, "p")
	end
	return type_dir
end

local function get_project_output_dir(project, output_type)
	local base_dir = get_jira_ai_base_dir()
	local project_dir = base_dir .. "/" .. project .. "/" .. output_type
	if vim.fn.isdirectory(project_dir) == 0 then
		vim.fn.mkdir(project_dir, "p")
	end
	return project_dir
end

local function get_timestamp()
	return os.date("%Y%m%d-%H")
end

function M.output_handler(markdown, output_type, project)
	if not project or project == "" then
		-- Try to get a default project from config
		local config = require("jira_ai.config").options
		local configured_projects = config.jira_projects or {}
		if #configured_projects > 0 then
			project = configured_projects[1]
			vim.notify("No project specified, using default: " .. project, vim.log.levels.WARN)
		else
			error("Project parameter is required for output_handler and no default projects configured")
			return
		end
	end
	
	local timestamp = get_timestamp()
	local dir = get_project_output_dir(project, output_type)
	
	-- Use consistent timestamp-based naming
	local filename = string.format("%s.md", timestamp)
	local filepath = dir .. "/" .. filename

	-- Add "My Notes" section at the end
	local content = markdown .. "\n\n## My Notes\n\n<!-- Add your notes here -->\n"

	-- Write to file
	local f = io.open(filepath, "w")
	if not f then
		error("Failed to write Jira AI output to file: " .. filepath)
		return
	end
	f:write(content)
	f:close()

	-- Create new buffer and load content
	vim.cmd("enew")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
	vim.api.nvim_buf_set_name(0, filepath)
	vim.cmd("write")

	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

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
	vim.notify("Jira AI output saved to: " .. filepath)
	return filepath
end

-- Legacy functions - use jira_ai.files module instead
function M.get_all_jira_files()
	return require("jira_ai.files").get_all_files()
end

function M.get_files_by_type(output_type)
	return require("jira_ai.files").get_files_by_type(output_type)
end

return M
