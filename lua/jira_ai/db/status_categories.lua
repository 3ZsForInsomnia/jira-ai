-- Status category operations

local M = {}

-- Get all status categories
function M.get_all(db)
	local query = require("jira_ai.db.query")
	
	return query.select_where(db, "status_categories", nil, {
		order_by = "category, status_name",
	})
end

-- Get status category for a status name
function M.get_category(db, status_name)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "status_categories", { status_name = status_name })
	return result and result[1] and result[1].category or nil
end

-- Get statuses by category
function M.get_by_category(db, category)
	local query = require("jira_ai.db.query")
	
	return query.select_where(db, "status_categories", { category = category }, {
		order_by = "status_name",
	})
end

-- Initialize status categories from config
function M.init_from_config(db)
	local query = require("jira_ai.db.query")
	
	local config = require("jira_ai.config").options
	local status_mappings = config.status_mappings
		or {
			not_started = { "Open", "Backlog", "To Do", "New" },
			in_progress = { "In Progress", "In Development", "In Code Review" },
			qa = { "In QA", "Testing", "Ready for QA", "QA Review" },
			done = { "Done", "Released", "Closed", "Resolved" },
		}

	return query.transaction(db, function()
		-- Clear existing mappings
		query.delete_where(db, "status_categories", {})

		-- Insert new mappings
		for category, statuses in pairs(status_mappings) do
			for _, status_name in ipairs(statuses) do
				local success = query.insert_rows(db, "status_categories", {
					status_name = status_name,
					category = category,
					synced_at = os.date("%Y-%m-%d %H:%M:%S"),
				})

				if not success then
					error("Failed to insert status mapping: " .. status_name .. " -> " .. category)
				end
			end
		end

		return true
	end)
end

-- Add or update a status category mapping
function M.upsert(db, status_name, category)
	local query = require("jira_ai.db.query")
	
	return query.upsert_row(db, "status_categories", {
		status_name = status_name,
		category = category,
		synced_at = os.date("%Y-%m-%d %H:%M:%S"),
	}, { "status_name" })
end

-- Translate raw Jira status to our category
function M.translate_status(db, raw_status)
	if not raw_status then
		return "not_started" -- Default for null/empty status
	end

	local category = M.get_category(db, raw_status)
	if category then
		return category
	end

	-- Fallback: try to guess based on common patterns
	local lower_status = raw_status:lower()

	if
		lower_status:match("done")
		or lower_status:match("closed")
		or lower_status:match("resolved")
		or lower_status:match("released")
	then
		return "done"
	elseif lower_status:match("qa") or lower_status:match("test") or lower_status:match("review") then
		return "qa"
	elseif
		lower_status:match("progress")
		or lower_status:match("development")
		or lower_status:match("coding")
		or lower_status:match("implement")
	then
		return "in_progress"
	else
		return "not_started"
	end
end

-- Get unmapped statuses (statuses in tickets table not in status_categories)
function M.get_unmapped_statuses(db, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT DISTINCT t.raw_status
		FROM tickets t
		LEFT JOIN status_categories sc ON t.raw_status = sc.status_name
		WHERE sc.status_name IS NULL 
		AND t.raw_status IS NOT NULL
	]]

	local params = {}
	if project_key then
		sql = sql .. " AND t.project_key = ?"
		params = { project_key }
	end

	sql = sql .. " ORDER BY t.raw_status"

	return query.safe_execute(db, "get_unmapped_statuses", function()
		return db:select(sql, params)
	end)
end

-- Update all tickets to use translated status
function M.update_ticket_statuses(db, project_key)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		local sql = [[
			UPDATE tickets 
			SET status = ?
			WHERE raw_status = ?
		]]

		local params = {}
		if project_key then
			sql = sql .. " AND project_key = ?"
		end

		-- Get all unique raw statuses
		local status_sql = "SELECT DISTINCT raw_status FROM tickets WHERE raw_status IS NOT NULL"
		if project_key then
			status_sql = status_sql .. " AND project_key = ?"
			params = { project_key }
		end

		local statuses = query.safe_execute(db, "get_raw_statuses", function()
			return db:select(status_sql, params)
		end)

		if not statuses then
			return false
		end

		-- Update each status
		for _, row in ipairs(statuses) do
			local translated = M.translate_status(db, row.raw_status)
			local update_params = { translated, row.raw_status }

			if project_key then
				table.insert(update_params, project_key)
			end

			query.safe_execute(db, "update_ticket_status", function()
				return db:execute(sql, update_params)
			end)
		end

		return true
	end)
end

-- Get status distribution for reporting
function M.get_status_distribution(db, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			sc.category,
			COUNT(t.key) as ticket_count,
			SUM(COALESCE(t.story_points, 0)) as total_points
		FROM status_categories sc
		LEFT JOIN tickets t ON sc.status_name = t.raw_status
	]]

	local params = {}
	if project_key then
		sql = sql .. " WHERE t.project_key = ? OR t.project_key IS NULL"
		params = { project_key }
	end

	sql = sql
		.. [[
		GROUP BY sc.category
		ORDER BY 
			CASE sc.category 
				WHEN 'not_started' THEN 1
				WHEN 'in_progress' THEN 2  
				WHEN 'qa' THEN 3
				WHEN 'done' THEN 4
			END
	]]

	return query.safe_execute(db, "get_status_distribution", function()
		return db:select(sql, params)
	end)
end

return M
