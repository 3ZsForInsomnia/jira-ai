
local M = {}

-- Safe database operation wrapper
function M.safe_execute(db, operation_name, operation_fn)
	local log = require("jira_ai.log")
	local error_handling = require("jira_ai.error_handling")
	
	log.info("Executing database operation: " .. operation_name, "db.query")

	local function attempt_operation()
		return operation_fn()
	end

	local result, error_obj = error_handling.with_retry(
		attempt_operation,
		3, -- max retries
		500, -- delay between retries
		"db.query." .. operation_name
	)

	if error_obj then
		-- Check if this is a recoverable database error
		local db_error = error_handling.handle_db_error(error_obj.message, "db.query")

		if db_error.details.requires_repair then
			log.warn("Database repair may be required for operation: " .. operation_name, "db.query")
			-- Attempt to repair database
			local db_init = require("jira_ai.db")
			local repair_success = pcall(db_init.repair_db)
			if repair_success then
				log.info("Database repair completed, retrying operation", "db.query")
				-- Try once more after repair
				local final_result, final_error = pcall(operation_fn)
				if final_result then
					log.info("Database operation succeeded after repair: " .. operation_name, "db.query")
					return final_error
				end
			end
		end

		log.error(string.format("Database operation '%s' failed: %s", operation_name, error_obj.message), "db.query")
		return nil
	end

	log.info("Database operation completed successfully: " .. operation_name, "db.query")
	return result
end

-- Generic select with WHERE conditions
function M.select_where(db, table_name, where_conditions, options)
	options = options or {}

	local sql = "SELECT "

	-- Handle column selection
	if options.columns then
		if type(options.columns) == "table" then
			sql = sql .. table.concat(options.columns, ", ")
		else
			sql = sql .. options.columns
		end
	else
		sql = sql .. "*"
	end

	sql = sql .. " FROM " .. table_name

	local params = {}

	-- Build WHERE clause
	if where_conditions and next(where_conditions) then
		local where_parts = {}
		for key, value in pairs(where_conditions) do
			if type(value) == "table" then
				-- Handle IN clause for arrays
				local placeholders = {}
				for _, v in ipairs(value) do
					table.insert(placeholders, "?")
					table.insert(params, v)
				end
				table.insert(where_parts, key .. " IN (" .. table.concat(placeholders, ", ") .. ")")
			elseif type(value) == "string" and value:match("^[<>=!]+") then
				-- Handle operators like "<", ">=", etc.
				local operator, val = value:match("^([<>=!]+)%s*(.+)")
				table.insert(where_parts, key .. " " .. operator .. " ?")
				table.insert(params, val)
			else
				-- Handle equality
				table.insert(where_parts, key .. " = ?")
				table.insert(params, value)
			end
		end
		sql = sql .. " WHERE " .. table.concat(where_parts, " AND ")
	end

	-- Handle ORDER BY
	if options.order_by then
		sql = sql .. " ORDER BY " .. options.order_by
	end

	-- Handle LIMIT
	if options.limit then
		sql = sql .. " LIMIT " .. options.limit
	end

	return M.safe_execute(db, "select_where", function()
		return db:select(sql, params)
	end)
end

-- Generic insert operation
function M.insert_rows(db, table_name, rows)
	if not rows or #rows == 0 then
		return true
	end

	-- Handle single row
	if not vim.tbl_islist(rows) then
		rows = { rows }
	end

	return M.safe_execute(db, "insert_rows", function()
		return db:insert(table_name, rows)
	end)
end

-- Generic update operation
function M.update_where(db, table_name, set_values, where_conditions)
	local sql = "UPDATE " .. table_name .. " SET "
	local params = {}

	-- Build SET clause
	local set_parts = {}
	for key, value in pairs(set_values) do
		table.insert(set_parts, key .. " = ?")
		table.insert(params, value)
	end
	sql = sql .. table.concat(set_parts, ", ")

	-- Build WHERE clause
	if where_conditions and next(where_conditions) then
		local where_parts = {}
		for key, value in pairs(where_conditions) do
			table.insert(where_parts, key .. " = ?")
			table.insert(params, value)
		end
		sql = sql .. " WHERE " .. table.concat(where_parts, " AND ")
	end

	return M.safe_execute(db, "update_where", function()
		return db:execute(sql, params)
	end)
end

-- Generic delete operation
function M.delete_where(db, table_name, where_conditions)
	local sql = "DELETE FROM " .. table_name
	local params = {}

	-- Build WHERE clause
	if where_conditions and next(where_conditions) then
		local where_parts = {}
		for key, value in pairs(where_conditions) do
			if type(value) == "table" then
				-- Handle IN clause for arrays
				local placeholders = {}
				for _, v in ipairs(value) do
					table.insert(placeholders, "?")
					table.insert(params, v)
				end
				table.insert(where_parts, key .. " IN (" .. table.concat(placeholders, ", ") .. ")")
			else
				table.insert(where_parts, key .. " = ?")
				table.insert(params, value)
			end
		end
		sql = sql .. " WHERE " .. table.concat(where_parts, " AND ")
	end

	return M.safe_execute(db, "delete_where", function()
		return db:execute(sql, params)
	end)
end

-- Upsert operation (insert or update if exists)
function M.upsert_row(db, table_name, row, conflict_columns)
	if not conflict_columns then
		-- Default to INSERT OR REPLACE
		return M.safe_execute(db, "upsert_row", function()
			return db:replace(table_name, row)
		end)
	end

	-- Use INSERT ... ON CONFLICT for more control
	local columns = {}
	local placeholders = {}
	local values = {}

	for key, value in pairs(row) do
		table.insert(columns, key)
		table.insert(placeholders, "?")
		table.insert(values, value)
	end

	local sql = string.format(
		"INSERT INTO %s (%s) VALUES (%s) ON CONFLICT(%s) DO UPDATE SET ",
		table_name,
		table.concat(columns, ", "),
		table.concat(placeholders, ", "),
		table.concat(conflict_columns, ", ")
	)

	-- Build UPDATE SET clause for conflict resolution
	local update_parts = {}
	for _, column in ipairs(columns) do
		if not vim.tbl_contains(conflict_columns, column) then
			table.insert(update_parts, column .. " = excluded." .. column)
		end
	end
	sql = sql .. table.concat(update_parts, ", ")

	return M.safe_execute(db, "upsert_row", function()
		return db:execute(sql, values)
	end)
end

-- Get count with WHERE conditions
function M.count_where(db, table_name, where_conditions)
	local result = M.select_where(db, table_name, where_conditions, { columns = "COUNT(*) as count" })
	return result and result[1] and result[1].count or 0
end

-- Check if row exists
function M.exists(db, table_name, where_conditions)
	return M.count_where(db, table_name, where_conditions) > 0
end

-- Transaction wrapper
function M.transaction(db, operation_fn)
	return M.safe_execute(db, "transaction", function()
		db:execute("BEGIN TRANSACTION")
		local ok, result = pcall(operation_fn)
		if ok then
			db:execute("COMMIT")
			return result
		else
			db:execute("ROLLBACK")
			error(result)
		end
	end)
end

return M
