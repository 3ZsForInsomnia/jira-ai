local cache = require("jira_ai.cache")
local data = require("jira_ai.data")
local os_time = os.time

local M = {}

local function cache_is_fresh(group)
	local config = require("jira_ai.config").options

	local cache_data = cache.read_cache()
	local now = os_time()
	if not cache_data or not cache_data.last_synced then
		return false
	end
	local last = cache_data.last_synced
	local ttl = group == "long" and config.cache_ttl_long or config.cache_ttl_short
	return (
		now
		- os.time({
			year = last:sub(1, 4),
			month = last:sub(6, 7),
			day = last:sub(9, 10),
			hour = last:sub(12, 13),
			min = last:sub(15, 16),
			sec = last:sub(18, 19),
		})
	) < ttl
end

function M.get_projects(callback)
	if not cache_is_fresh("long") then
		cache.sync_long(function()
			callback(cache.get_projects())
		end)
	else
		callback(cache.get_projects())
	end
end

function M.get_users(callback)
	if not cache_is_fresh("long") then
		cache.sync_long(function()
			callback(cache.get_users())
		end)
	else
		callback(cache.get_users())
	end
end

function M.get_epics(callback)
	if not cache_is_fresh("short") then
		cache.sync_short(function()
			callback(cache.get_epics())
		end)
	else
		callback(cache.get_epics())
	end
end

function M.get_sprints(callback)
	if not cache_is_fresh("short") then
		cache.sync_short(function()
			callback(cache.get_sprints())
		end)
	else
		callback(cache.get_sprints())
	end
end

function M.get_current_sprints(callback)
	if not cache_is_fresh("short") then
		cache.sync_short(function()
			callback(cache.get_current_sprints())
		end)
	else
		callback(cache.get_current_sprints())
	end
end

function M.get_issue_changelog(issue_key, callback)
	data.get_issue_changelog(issue_key, callback)
end

return M
