-- Common data retrieval utilities and base functionality
local Job = require("plenary.job")

local M = {}

-- URL encoding utility
local function urlencode(str)
	return str:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

-- Core API request function
function M.jira_api_request_async(endpoint, query, callback, timeout_ms)
	timeout_ms = timeout_ms or 30000 -- 30 second default timeout

	-- Lazy load to avoid circular dependencies
	local error_handling = require("jira_ai.error_handling")

	-- Wrap with timeout
	local timeout_wrapper = error_handling.with_timeout(function(cb)
		M._jira_api_request_internal(endpoint, query, cb)
	end, timeout_ms, "data.api")

	timeout_wrapper(callback)
end

-- Internal API request function (without timeout wrapper)
function M._jira_api_request_internal(endpoint, query, callback)
	-- Lazy load to avoid circular dependencies
	local log = require("jira_ai.log")
	local error_handling = require("jira_ai.error_handling")
	
	-- Validate configuration first
	local config_valid, config_error = error_handling.validate_config()
	if not config_valid then
		log.error("Configuration validation failed: " .. config_error.message, "data.api")
		callback(nil, config_error.message)
		return
	end

	local config = require("jira_ai.config").options
	local url = config.jira_base_url .. endpoint

	if query then
		url = url .. "?" .. query
	end

	log.info("Making API request to: " .. endpoint, "data.api")

	-- Check circuit breaker
	local breaker = error_handling.circuit_breaker("jira_api", 5, 60000)
	if not breaker.can_execute() then
		local error_msg = "Jira API circuit breaker is OPEN"
		log.error(error_msg, "data.api")
		callback(nil, error_msg)
		return
	end

	local auth = config.jira_email_address .. ":" .. config.jira_api_token

	Job
		:new({
			command = "curl",
			args = { "-s", "-u", auth, "-H", "Accept: application/json", url },
			on_exit = function(j, return_val)
				if return_val ~= 0 then
					log.error(
						"HTTP request failed with code: " .. return_val .. " for endpoint: " .. endpoint,
						"data.api"
					)
					breaker.record_failure()
					local error_type = error_handling.classify_network_error("HTTP " .. return_val)
					local error_obj = error_handling.create_error(
						error_type,
						"HTTP request failed with code: " .. return_val,
						"data.api"
					)
					vim.schedule(function()
						callback(nil, error_obj.message)
					end)
					return
				end

				local result = table.concat(j:result(), "\n")
				log.info("Received response from: " .. endpoint .. " (length: " .. #result .. ")", "data.api")
				vim.schedule(function()
					local ok, decoded = pcall(vim.fn.json_decode, result)
					if ok and decoded then
						-- Validate the response
						local validated_response, validation_error =
							error_handling.validate_jira_response(decoded, nil, "data.api")
						if validation_error then
							breaker.record_failure()
							callback(nil, validation_error.message)
							return
						end

						breaker.record_success()
						log.info("Successfully decoded JSON response from: " .. endpoint, "data.api")
						callback(decoded, nil)
					else
						breaker.record_failure()
						log.error("Failed to decode JSON response from: " .. endpoint, "data.api")
						callback(nil, "Failed to decode JSON response")
					end
				end)
			end,
		})
		:start()
end

-- Build JQL query string
function M.build_jql(conditions)
	local parts = {}
	for key, value in pairs(conditions) do
		if type(value) == "table" then
			-- Handle IN clause
			local quoted_values = {}
			for _, v in ipairs(value) do
				table.insert(quoted_values, '"' .. v .. '"')
			end
			table.insert(parts, key .. " IN (" .. table.concat(quoted_values, ", ") .. ")")
		elseif type(value) == "string" then
			table.insert(parts, key .. '="' .. value .. '"')
		else
			table.insert(parts, key .. "=" .. tostring(value))
		end
	end
	return table.concat(parts, " AND ")
end

-- Build query parameters
function M.build_query_params(params)
	local query_parts = {}
	for key, value in pairs(params) do
		if key == "jql" then
			table.insert(query_parts, "jql=" .. urlencode(value))
		elseif type(value) == "table" then
			table.insert(query_parts, key .. "=" .. urlencode(table.concat(value, ",")))
		else
			table.insert(query_parts, key .. "=" .. urlencode(tostring(value)))
		end
	end
	return table.concat(query_parts, "&")
end

-- Paginated request handler
function M.paginated_request(endpoint, base_params, callback, options)
	options = options or {}
	local max_results = options.max_results or 50
	local max_pages = options.max_pages or 100 -- Safety limit

	log.info(
		"Starting paginated request to: "
			.. endpoint
			.. " (max_results: "
			.. max_results
			.. ", max_pages: "
			.. max_pages
			.. ")",
		"data.pagination"
	)
	local all_results = {}
	local start_at = 0
	local pages_fetched = 0

	local function fetch_page()
		if pages_fetched >= max_pages then
			log.warn("Reached maximum page limit (" .. max_pages .. ") for endpoint: " .. endpoint, "data.pagination")
			callback(all_results, "Too many pages, possible infinite loop")
			return
		end

		local params = vim.tbl_extend("force", base_params, {
			startAt = start_at,
			maxResults = max_results,
		})

		local query = M.build_query_params(params)

		M.jira_api_request_async(endpoint, query, function(response, error)
			if error then
				log.error("Paginated request failed for " .. endpoint .. ": " .. error, "data.pagination")
				callback(nil, error)
				return
			end

			if not response then
				log.info(
					"Paginated request completed for " .. endpoint .. " (total results: " .. #all_results .. ")",
					"data.pagination"
				)
				callback(all_results)
				return
			end

			-- Handle different response formats
			local items = response.issues or response.values or response
			if not items then
				log.info(
					"No more items in paginated response for " .. endpoint .. " (total results: " .. #all_results .. ")",
					"data.pagination"
				)
				callback(all_results)
				return
			end

			-- Add items to results
			for _, item in ipairs(items) do
				table.insert(all_results, item)
			end

			pages_fetched = pages_fetched + 1
			log.info(
				"Fetched page "
					.. pages_fetched
					.. " for "
					.. endpoint
					.. " ("
					.. #items
					.. " items, "
					.. #all_results
					.. " total)",
				"data.pagination"
			)

			-- Check if we need more pages
			local total = response.total
			if #items < max_results or (total and start_at + #items >= total) then
				log.info(
					"Paginated request completed for " .. endpoint .. " (total results: " .. #all_results .. ")",
					"data.pagination"
				)
				callback(all_results)
			else
				start_at = start_at + max_results
				fetch_page()
			end
		end)
	end

	fetch_page()
end

-- Batch request helper for multiple endpoints
function M.batch_requests(requests, callback)
	local results = {}
	local completed = 0
	local total = #requests
	local has_error = false

	if total == 0 then
		callback({})
		return
	end

	for i, request in ipairs(requests) do
		local endpoint = request.endpoint
		local query = request.query and M.build_query_params(request.query) or nil

		M.jira_api_request_async(endpoint, query, function(response, error)
			if has_error then
				return -- Don't process if we already have an error
			end

			if error then
				has_error = true
				callback(nil, error)
				return
			end

			results[i] = {
				request = request,
				response = response,
			}

			completed = completed + 1
			if completed == total then
				callback(results)
			end
		end)
	end
end

-- Standard field sets for different entity types
M.FIELD_SETS = {
	projects = "key,name,projectTypeKey",

	users = "accountId,displayName,emailAddress,active",

	epics = "key,summary,status,assignee,description,created,resolutiondate,project",

	tickets = table.concat({
		"key",
		"summary",
		"status",
		"assignee",
		"reporter",
		"priority",
		"description",
		"issuetype",
		"created",
		"updated",
		"resolutiondate",
		"duedate",
		"parent",
		"epic",
		"comment",
		"issuelinks",
		"subtasks",
	}, ","),

	sprints = "id,name,state,startDate,endDate,goal",
}

-- Standard expand sets
M.EXPAND_SETS = {
	tickets_with_changelog = "changelog",
	tickets_with_comments = "comment",
	tickets_full = "changelog,comment",
}

return M
