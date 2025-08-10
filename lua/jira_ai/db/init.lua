local sqlite = require("sqlite")

local M = {}

-- Get database path
local function get_db_path()
	local config = require("jira_ai.config").options
	local dir = config.cache_dir or os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
	local db_dir = dir .. "/nvim/jira-ai"
	if vim.fn.isdirectory(db_dir) == 0 then
		vim.fn.mkdir(db_dir, "p")
	end
	return db_dir .. "/jira_ai.db"
end

-- Internal function to create database connection (used by retry logic)
function M._create_db_connection(db_path)
	local log = require("jira_ai.log")
	
	-- Ensure directory exists and is writable
	local dir = vim.fn.fnamemodify(db_path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		local mkdir_success = vim.fn.mkdir(dir, "p")
		if mkdir_success == 0 then
			error("Failed to create database directory: " .. dir)
		end
	end

	-- Test directory write permissions
	local test_file = dir .. "/.write_test"
	local test_write = io.open(test_file, "w")
	if test_write then
		test_write:close()
		os.remove(test_file)
	else
		error("Database directory is not writable: " .. dir)
	end

	-- Create database connection
	local db = sqlite.new(db_path, {
		open_mode = "rwc", -- read, write, create
		lazy = false,
	})

	if not db then
		error("Failed to create SQLite connection")
	end

	return db
end

-- Initialize database connection
function M.get_db()
	if M._db then
		local log = require("jira_ai.log")
		log.info("Reusing existing database connection", "db.init")
		return M._db
	end

	local log = require("jira_ai.log")
	local error_handling = require("jira_ai.error_handling")
	
	local db_path = get_db_path()
	log.info("Creating new database connection to: " .. db_path, "db.init")

	-- Use error handling with retry for database initialization
	local db_result, db_error = error_handling.with_retry(function()
		return M._create_db_connection(db_path)
	end, 3, 1000, "db.init")

	if db_error then
		local classified_error = error_handling.handle_db_error(db_error.message, "db.init")
		log.error("Failed to create database connection after retries: " .. classified_error.message, "db.init")
		error("Failed to create database connection: " .. classified_error.message)
	end

	M._db = db_result
	log.info("Database connection created successfully", "db.init")

	return M._db
end

-- Close database connection
function M.close_db()
	if M._db then
		local log = require("jira_ai.log")
		log.info("Closing database connection", "db.init")
		M._db:close()
		M._db = nil
	else
		log.warn("Attempted to close database connection but none was open", "db.init")
	end
end

-- Initialize database with all tables
function M.init_db()
	local log = require("jira_ai.log")
	local schema = require("jira_ai.db.schema")
	
	log.info("Initializing database schema", "db.init")
	local db = M.get_db()

	local tables_created = 0
	local indexes_created = 0

	-- Create all tables
	for _, create_sql in ipairs(schema.get_create_statements()) do
		local success = db:execute(create_sql)
		if not success then
			log.error("Failed to create database table: " .. create_sql, "db.init")
			error("Failed to create database table: " .. create_sql)
		else
			tables_created = tables_created + 1
		end
	end

	-- Create indexes
	for _, index_sql in ipairs(schema.get_index_statements()) do
		local success = db:execute(index_sql)
		if not success then
			log.warn("Failed to create index: " .. index_sql, "db.init")
		else
			indexes_created = indexes_created + 1
		end
	end

	log.info(
		string.format("Database initialization complete: %d tables, %d indexes", tables_created, indexes_created),
		"db.init"
	)
	return true
end

-- Health check for database
function M.health_check()
	local log = require("jira_ai.log")
	local schema = require("jira_ai.db.schema")
	
	log.info("Running database health check", "db.init")
	local db = M.get_db()

	local health = {
		db_exists = false,
		tables_exist = {},
		indexes_exist = {},
		writable = false,
		readable = false,
	}

	-- Check if database file exists and is accessible
	local db_path = get_db_path()
	if vim.fn.filereadable(db_path) == 1 then
		health.db_exists = true
		log.info("Database file exists and is readable", "db.init")
	else
		log.warn("Database file does not exist or is not readable: " .. db_path, "db.init")
	end

	-- Check if tables exist
	local tables = schema.get_table_names()
	local missing_tables = {}
	for _, table_name in ipairs(tables) do
		local result = db:select("SELECT name FROM sqlite_master WHERE type='table' AND name=?", { table_name })
		health.tables_exist[table_name] = #result > 0
		if not health.tables_exist[table_name] then
			table.insert(missing_tables, table_name)
		end
	end

	if #missing_tables > 0 then
		log.warn("Missing tables: " .. table.concat(missing_tables, ", "), "db.init")
	else
		log.info("All required tables exist", "db.init")
	end

	-- Check if indexes exist
	local indexes = schema.get_index_names()
	local missing_indexes = {}
	for _, index_name in ipairs(indexes) do
		local result = db:select("SELECT name FROM sqlite_master WHERE type='index' AND name=?", { index_name })
		health.indexes_exist[index_name] = #result > 0
		if not health.indexes_exist[index_name] then
			table.insert(missing_indexes, index_name)
		end
	end

	if #missing_indexes > 0 then
		log.warn("Missing indexes: " .. table.concat(missing_indexes, ", "), "db.init")
	else
		log.info("All required indexes exist", "db.init")
	end

	-- Test write capability
	local test_result = db:execute("CREATE TEMP TABLE test_write (id INTEGER)")
	if test_result then
		health.writable = true
		log.info("Database is writable", "db.init")
		db:execute("DROP TABLE test_write")
	else
		log.error("Database is not writable", "db.init")
	end

	-- Test read capability
	local read_result = db:select("SELECT 1 as test")
	health.readable = #read_result > 0 and read_result[1].test == 1
	if health.readable then
		log.info("Database is readable", "db.init")
	else
		log.error("Database is not readable", "db.init")
	end

	return health
end

-- Repair database by recreating missing tables/indexes
function M.repair_db()
	local log = require("jira_ai.log")
	local error_handling = require("jira_ai.error_handling")
	
	log.info("Starting database repair", "db.init")

	-- Use error handling for repair operations
	local repair_result, repair_error = error_handling.with_retry(function()
		return M._execute_repair()
	end, 2, 2000, "db.init.repair")

	if repair_error then
		log.error("Database repair failed after retries: " .. repair_error.message, "db.init")
		return false
	end

	log.info(
		string.format(
			"Database repair complete: %d tables repaired, %d indexes repaired",
			repair_result.tables_repaired,
			repair_result.indexes_repaired
		),
		"db.init"
	)

	return true
end

-- Internal repair execution function
function M._execute_repair()
	local log = require("jira_ai.log")
	local schema = require("jira_ai.db.schema")
	
	local health = M.health_check()
	local db = M.get_db()

	local tables_repaired = 0
	local indexes_repaired = 0

	-- Recreate missing tables
	for table_name, exists in pairs(health.tables_exist) do
		if not exists then
			log.info("Recreating missing table: " .. table_name, "db.init")
			local create_sql = schema.get_table_create_statement(table_name)
			if create_sql then
				local success = db:execute(create_sql)
				if not success then
					error("Failed to recreate table: " .. table_name)
				else
					tables_repaired = tables_repaired + 1
					log.info("Successfully recreated table: " .. table_name, "db.init")
				end
			end
		end
	end

	-- Recreate missing indexes (non-critical, continue on failure)
	for index_name, exists in pairs(health.indexes_exist) do
		if not exists then
			log.info("Recreating missing index: " .. index_name, "db.init")
			local index_sql = schema.get_index_create_statement(index_name)
			if index_sql then
				local success = db:execute(index_sql)
				if success then
					indexes_repaired = indexes_repaired + 1
					log.info("Successfully recreated index: " .. index_name, "db.init")
				else
					log.warn("Failed to recreate index: " .. index_name, "db.init")
				end
			end
		end
	end

	return {
		tables_repaired = tables_repaired,
		indexes_repaired = indexes_repaired,
	}
end

return M
