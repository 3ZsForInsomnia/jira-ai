local data = require("jira_ai.data")
local transform = require("jira_ai.transform")
local cache_data_fetch = require("jira_ai.cache_data_fetch")

local M = {}

function M.get_projects()
	local cache_data = M.read_cache()
	return cache_data and cache_data.projects or {}
end

function M.get_users()
	local cache_data = M.read_cache()
	return cache_data and cache_data.users or {}
end

function M.get_epics()
	local cache_data = M.read_cache()
	return cache_data and cache_data.epics or {}
end

function M.get_sprints()
	local cache_data = M.read_cache()
	return cache_data and cache_data.sprints or {}
end

function M.get_current_sprints()
	local cache_data = M.read_cache()
	return cache_data and cache_data.current_sprints or {}
end

local function get_cache_path()
	local config = require("jira_ai.config").options
	local dir = config.cache_dir or os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
	local cache_dir = dir .. "/nvim/jira-ai"
	if vim.fn.isdirectory(cache_dir) == 0 then
		vim.fn.mkdir(cache_dir, "p")
	end
	return cache_dir .. "/cache.json"
end

local function save_cache(cache_data)
	local cache_path = get_cache_path()
	local f = io.open(cache_path, "w")
	if f then
		f:write(vim.fn.json_encode(cache_data))
		f:close()
		return true
	end
	return false
end

function M.sync(callback)
	vim.notify("Syncing Jira cache...", vim.log.levels.INFO)
	cache_data_fetch.fetch_long_lived_metadata(function(raw_long)
		cache_data_fetch.fetch_short_lived_metadata(function(raw_short)
			local cache_data = {
				projects = raw_long.projects,
				users = transform.users(raw_long.users),
				epics = transform.epics_by_project(raw_short.epics or {}),
				sprints = transform.sprints(raw_short.sprints or {}),
				current_sprints = raw_short.current_sprints or {},
				last_synced = os.date("%Y-%m-%d %H:%M:%S"),
			}
			local ok = save_cache(cache_data)
			if not ok then
				vim.notify("Failed to save Jira cache!", vim.log.levels.ERROR)
			else
				vim.notify("Jira cache synced successfully!", vim.log.levels.INFO)
			end
			if callback then
				callback(cache_data)
			end
		end)
	end)
end

function M.sync_background()
	M.sync(function()
		vim.notify("Jira AI cache sync complete (background).", vim.log.levels.INFO)
	end)
end

function M.setup_autosync()
	vim.defer_fn(function()
		M.sync_background()
	end, 2.5 * 1000)
end

function M.cache_populate(callback)
	data.fetch_cache_metadata(function(raw)
		local cache_data = {
			projects = raw.projects,
			boards = transform.boards(raw.boards),
			sprints = transform.sprints(raw.sprints or {}),
			epics = transform.epics_by_project(raw.epics),
			users = transform.users(raw.users),
			last_synced = os.date("%Y-%m-%d %H:%M:%S"),
		}
		save_cache(cache_data)
		callback(cache_data)
	end)
end

function M.read_cache()
	local cache_path = get_cache_path()
	local f = io.open(cache_path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	local ok, decoded = pcall(vim.fn.json_decode, content)
	return ok and decoded or nil
end

function M.sync_long(callback)
	cache_data_fetch.fetch_long_lived_metadata(function(raw)
		local cache_data = M.read_cache() or {}
		cache_data.projects = raw.projects
		cache_data.users = transform.users(raw.users)
		cache_data.last_synced = os.date("%Y-%m-%d %H:%M:%S")
		save_cache(cache_data)
		callback(cache_data)
	end)
end

function M.sync_short(callback)
	cache_data_fetch.fetch_short_lived_metadata(function(raw)
		local cache_data = M.read_cache() or {}
		cache_data.epics = transform.epics_by_project(raw.epics)
		cache_data.sprints = transform.sprints(raw.sprints or {})
		cache_data.current_sprints = raw.current_sprints
		cache_data.last_synced = os.date("%Y-%m-%d %H:%M:%S")
		save_cache(cache_data)
		callback(cache_data)
	end)
end

return M
