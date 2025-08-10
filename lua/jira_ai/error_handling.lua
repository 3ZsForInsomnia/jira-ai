local data_utils = require("jira_ai.data")
local log = require("jira_ai.log")

local M = {}

-- Error types
M.ERROR_TYPES = {
	NETWORK = "NETWORK",
	AUTH = "AUTH",
	API = "API",
	DATABASE = "DATABASE",
	CONFIG = "CONFIG",
	TIMEOUT = "TIMEOUT",
	PARSE = "PARSE",
	VALIDATION = "VALIDATION",
}

-- Create standardized error object
function M.create_error(error_type, message, context, details)
	return {
		type = error_type,
		message = message,
		context = context or "unknown",
		details = details or {},
		timestamp = os.time(),
	}
end

-- Safe function wrapper with retry logic
function M.with_retry(fn, max_retries, delay_ms, context)
	max_retries = max_retries or 3
	delay_ms = delay_ms or 1000
	context = context or "unknown"

	local function attempt(retry_count)
		local success, result, error_info = pcall(fn)

		if success then
			if retry_count > 1 then
				log.info(string.format("Operation succeeded after %d retries", retry_count - 1), context)
			end
			return result, nil
		end

		local error_msg = tostring(result)
		log.warn(string.format("Attempt %d failed: %s", retry_count, error_msg), context)

		if retry_count >= max_retries then
			local error_obj = M.create_error(M.ERROR_TYPES.API, error_msg, context, {
				attempts = retry_count,
				max_retries = max_retries,
			})
			log.error(string.format("Operation failed after %d attempts: %s", max_retries, error_msg), context)
			return nil, error_obj
		end

		-- Wait before retry
		vim.defer_fn(function() end, delay_ms)
		return attempt(retry_count + 1)
	end

	return attempt(1)
end

-- Safe async wrapper for callbacks
function M.safe_async(fn, callback, context)
	context = context or "unknown"

	local function safe_callback(...)
		local args = { ... }
		local success, err = pcall(function()
			callback(unpack(args))
		end)

		if not success then
			log.error("Callback execution failed: " .. tostring(err), context)
		end
	end

	local success, err = pcall(function()
		fn(safe_callback)
	end)

	if not success then
		log.error("Async function failed: " .. tostring(err), context)
		local error_obj = M.create_error(M.ERROR_TYPES.API, tostring(err), context)
		safe_callback(nil, error_obj)
	end
end

-- Validate required configuration
function M.validate_config()
	local config = require("jira_ai.config").options
	local errors = {}

	local required_fields = {
		"jira_base_url",
		"jira_email_address",
		"jira_api_token",
		"jira_projects",
	}

	for _, field in ipairs(required_fields) do
		if not config[field] then
			table.insert(errors, "Missing required config: " .. field)
		elseif field == "jira_projects" and type(config[field]) == "table" and #config[field] == 0 then
			table.insert(errors, "jira_projects cannot be empty")
		elseif field == "jira_base_url" and not config[field]:match("^https?://") then
			table.insert(errors, "jira_base_url must be a valid URL")
		end
	end

	if #errors > 0 then
		local error_obj = M.create_error(M.ERROR_TYPES.CONFIG, "Configuration validation failed", "config", {
			errors = errors,
		})
		return nil, error_obj
	end

	return true, nil
end

-- Network error detection and classification
function M.classify_network_error(error_message)
	local msg = tostring(error_message):lower()

	if msg:match("timeout") or msg:match("timed out") then
		return M.ERROR_TYPES.TIMEOUT
	elseif msg:match("unauthorized") or msg:match("401") or msg:match("authentication") then
		return M.ERROR_TYPES.AUTH
	elseif msg:match("network") or msg:match("connection") or msg:match("host") then
		return M.ERROR_TYPES.NETWORK
	elseif msg:match("json") or msg:match("parse") or msg:match("decode") then
		return M.ERROR_TYPES.PARSE
	else
		return M.ERROR_TYPES.API
	end
end

-- Database error detection and recovery
function M.handle_db_error(error_message, context)
	local msg = tostring(error_message):lower()
	context = context or "database"

	-- Common SQLite errors and recovery strategies
	if msg:match("database is locked") then
		log.warn("Database is locked, will retry", context)
		return M.create_error(M.ERROR_TYPES.DATABASE, "Database locked", context, {
			recoverable = true,
			retry_delay = 500,
		})
	elseif msg:match("no such table") then
		log.warn("Missing database table detected", context)
		return M.create_error(M.ERROR_TYPES.DATABASE, "Missing table", context, {
			recoverable = true,
			requires_repair = true,
		})
	elseif msg:match("disk full") or msg:match("no space") then
		log.error("Insufficient disk space for database operations", context)
		return M.create_error(M.ERROR_TYPES.DATABASE, "Disk space exhausted", context, {
			recoverable = false,
		})
	elseif msg:match("permission denied") or msg:match("readonly") then
		log.error("Database permission error", context)
		return M.create_error(M.ERROR_TYPES.DATABASE, "Permission denied", context, {
			recoverable = false,
		})
	else
		return M.create_error(M.ERROR_TYPES.DATABASE, error_message, context, {
			recoverable = false,
		})
	end
end

-- Circuit breaker pattern for failing services
local circuit_breakers = {}

function M.circuit_breaker(service_name, failure_threshold, timeout_ms)
	failure_threshold = failure_threshold or 5
	timeout_ms = timeout_ms or 60000 -- 1 minute

	if not circuit_breakers[service_name] then
		circuit_breakers[service_name] = {
			failures = 0,
			last_failure = 0,
			state = "CLOSED", -- CLOSED, OPEN, HALF_OPEN
		}
	end

	local breaker = circuit_breakers[service_name]
	local now = os.time() * 1000

	-- Check if we should transition from OPEN to HALF_OPEN
	if breaker.state == "OPEN" and (now - breaker.last_failure) > timeout_ms then
		breaker.state = "HALF_OPEN"
		log.info("Circuit breaker transitioning to HALF_OPEN for " .. service_name, "error_handling")
	end

	return {
		can_execute = function()
			return breaker.state ~= "OPEN"
		end,

		record_success = function()
			breaker.failures = 0
			if breaker.state == "HALF_OPEN" then
				breaker.state = "CLOSED"
				log.info("Circuit breaker CLOSED for " .. service_name, "error_handling")
			end
		end,

		record_failure = function()
			breaker.failures = breaker.failures + 1
			breaker.last_failure = now

			if breaker.failures >= failure_threshold then
				breaker.state = "OPEN"
				log.warn(
					string.format("Circuit breaker OPEN for %s after %d failures", service_name, breaker.failures),
					"error_handling"
				)
			end
		end,

		get_state = function()
			return breaker.state
		end,
	}
end

-- Graceful degradation helpers
function M.with_fallback(primary_fn, fallback_fn, context)
	context = context or "unknown"

	return function(...)
		local args = { ... }
		local callback = args[#args]

		-- Try primary function
		primary_fn(unpack(args, 1, #args - 1), function(result, error)
			if error then
				log.warn("Primary function failed, trying fallback: " .. tostring(error.message), context)

				-- Try fallback function
				fallback_fn(unpack(args, 1, #args - 1), function(fallback_result, fallback_error)
					if fallback_error then
						log.error("Both primary and fallback functions failed", context)
						callback(nil, error) -- Return original error
					else
						log.info("Fallback function succeeded", context)
						callback(fallback_result, nil)
					end
				end)
			else
				callback(result, nil)
			end
		end)
	end
end

-- Data validation helpers
function M.validate_jira_response(response, expected_fields, context)
	context = context or "api_response"

	if not response then
		return nil, M.create_error(M.ERROR_TYPES.API, "Empty response from Jira", context)
	end

	-- Check for Jira error response
	if response.errorMessages and #response.errorMessages > 0 then
		local error_msg = table.concat(response.errorMessages, ", ")
		return nil, M.create_error(M.ERROR_TYPES.API, "Jira API error: " .. error_msg, context)
	end

	-- Validate expected fields if provided
	if expected_fields then
		for _, field in ipairs(expected_fields) do
			if response[field] == nil then
				log.warn("Missing expected field in response: " .. field, context)
			end
		end
	end

	return response, nil
end

-- Timeout wrapper for long-running operations
function M.with_timeout(fn, timeout_ms, context)
	timeout_ms = timeout_ms or 30000 -- 30 seconds default
	context = context or "unknown"

	return function(...)
		local args = { ... }
		local callback = args[#args]
		local completed = false

		-- Set timeout
		local timer = vim.defer_fn(function()
			if not completed then
				completed = true
				local error_obj = M.create_error(M.ERROR_TYPES.TIMEOUT, "Operation timed out", context, {
					timeout_ms = timeout_ms,
				})
				log.error(string.format("Operation timed out after %dms", timeout_ms), context)
				callback(nil, error_obj)
			end
		end, timeout_ms)

		-- Execute function with wrapped callback
		local wrapped_callback = function(...)
			if not completed then
				completed = true
				timer:close()
				callback(...)
			end
		end

		args[#args] = wrapped_callback
		fn(unpack(args))
	end
end

-- Health check for external dependencies
function M.health_check_jira_api(callback)
	M.with_timeout(function(cb)
		data_utils.jira_api_request_async("/rest/api/2/myself", nil, function(response, error)
			if error then
				local error_type = M.classify_network_error(error)
				cb(false, M.create_error(error_type, error, "health_check"))
			else
				cb(true, nil)
			end
		end)
	end, 10000, "health_check")(callback)
end

return M
