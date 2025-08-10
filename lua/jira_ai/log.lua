-- Logging system for jira-ai plugin
local M = {}

-- Log levels
M.LEVELS = {
	ERROR = 1,
	WARN = 2,
	INFO = 3,
}

M.LEVEL_NAMES = {
	[1] = "ERROR",
	[2] = "WARN",
	[3] = "INFO",
}

-- Get log file path
local function get_log_path()
	local config = require("jira_ai.config").options
	local dir = config.cache_dir or os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
	local log_dir = dir .. "/nvim/jira-ai"
	if vim.fn.isdirectory(log_dir) == 0 then
		vim.fn.mkdir(log_dir, "p")
	end
	return log_dir .. "/jira-ai.log"
end

-- Get current log level from config
local function get_log_level()
	local config = require("jira_ai.config")
	local level_name = config.options.log_level or "WARN"
	
	-- Convert string to number
	for level_num, name in pairs(M.LEVEL_NAMES) do
		if name == level_name:upper() then
			return level_num
		end
	end
	
	return M.LEVELS.WARN -- Default to WARN if invalid
end

-- Format log message
local function format_message(level, message, context)
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local level_name = M.LEVEL_NAMES[level] or "UNKNOWN"
	local prefix = string.format("[%s] [%s] [jira-ai]", timestamp, level_name)
	
	if context then
		prefix = prefix .. " [" .. context .. "]"
	end
	
	return prefix .. " " .. message
end

-- Write to log file
local function write_to_file(formatted_message)
	local log_path = get_log_path()
	local file = io.open(log_path, "a")
	if file then
		file:write(formatted_message .. "\n")
		file:close()
	else
		-- Fallback to stderr if we can't write to log file
		io.stderr:write("jira-ai: Failed to write to log file: " .. log_path .. "\n")
		io.stderr:write("jira-ai: " .. formatted_message .. "\n")
	end
end

-- Core logging function
local function log(level, message, context)
	local current_level = get_log_level()
	
	if level <= current_level then
		local formatted = format_message(level, message, context)
		write_to_file(formatted)
		
		-- Also notify for errors
		if level == M.LEVELS.ERROR then
			vim.schedule(function()
				vim.notify("[jira-ai] " .. message, vim.log.levels.ERROR)
			end)
		end
	end
end

-- Public logging functions
function M.error(message, context)
	log(M.LEVELS.ERROR, message, context)
end

function M.warn(message, context)
	log(M.LEVELS.WARN, message, context)
end

function M.info(message, context)
	log(M.LEVELS.INFO, message, context)
end

-- User notification function (separate from error logging)
function M.notify(message, level, context)
	level = level or vim.log.levels.INFO
	local display_message = "[jira-ai]"
	
	if context then
		display_message = display_message .. " [" .. context .. "]"
	end
	
	display_message = display_message .. " " .. message
	
	vim.schedule(function()
		vim.notify(display_message, level)
	end)
end

-- Convenience functions for notifications
function M.notify_info(message, context)
	M.notify(message, vim.log.levels.INFO, context)
end

function M.notify_warn(message, context)
	M.notify(message, vim.log.levels.WARN, context)
end

function M.notify_error(message, context)
	M.notify(message, vim.log.levels.ERROR, context)
end

-- Get log file contents (for debugging)
function M.get_recent_logs(lines)
	lines = lines or 100
	local log_path = get_log_path()
	
	if vim.fn.filereadable(log_path) == 0 then
		return {}
	end
	
	local file = io.open(log_path, "r")
	if not file then
		return {}
	end
	
	local all_lines = {}
	for line in file:lines() do
		table.insert(all_lines, line)
	end
	file:close()
	
	-- Return last N lines
	local start_idx = math.max(1, #all_lines - lines + 1)
	local recent_lines = {}
	for i = start_idx, #all_lines do
		table.insert(recent_lines, all_lines[i])
	end
	
	return recent_lines
end

-- Clear log file
function M.clear_logs()
	local log_path = get_log_path()
	local file = io.open(log_path, "w")
	if file then
		file:close()
		M.info("Log file cleared")
		return true
	end
	return false
end

-- Get log file path for external access
function M.get_log_file_path()
	return get_log_path()
end

-- Log system information
function M.log_system_info()
	M.info("=== Jira AI System Information ===")
	M.info("Neovim version: " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)
	M.info("OS: " .. vim.loop.os_uname().sysname)
	M.info("Log level: " .. (M.LEVEL_NAMES[get_log_level()] or "UNKNOWN"))
	M.info("Log file: " .. get_log_path())
	
	local config = require("jira_ai.config").options
	M.info("Configured projects: " .. table.concat(config.jira_projects or {}, ", "))
	M.info("Base URL: " .. (config.jira_base_url or "not configured"))
end

return M