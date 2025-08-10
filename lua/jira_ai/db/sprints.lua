-- Sprint operations

local M = {}

-- Get all sprints
function M.get_all(db, project_key, active_only)
	local query = require("jira_ai.db.query")
	
	local where_conditions = {}
	if project_key then
		where_conditions.project_key = project_key
	end
	if active_only then
		where_conditions.active = 1
	end

	return query.select_where(db, "sprints", where_conditions, {
		order_by = "start_date DESC",
	})
end

-- Get sprint by ID
function M.get_by_id(db, sprint_id)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "sprints", { id = sprint_id })
	return result and result[1] or nil
end

-- Get current/active sprints by project
function M.get_current_by_project(db)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT * FROM sprints 
		WHERE active = 1 AND state = 'active'
		ORDER BY project_key, start_date DESC
	]]

	local result = query.safe_execute(db, "get_current_sprints", function()
		return db:select(sql)
	end)

	-- Group by project
	local by_project = {}
	if result then
		for _, sprint in ipairs(result) do
			by_project[sprint.project_key] = sprint
		end
	end

	return by_project
end

-- Get sprints for a project within date range
function M.get_by_date_range(db, project_key, start_date, end_date)
	local query = require("jira_ai.db.query")
	
	local where_conditions = { project_key = project_key }
	local sql = [[
		SELECT * FROM sprints 
		WHERE project_key = ? 
		AND ((start_date >= ? AND start_date <= ?) 
		OR (end_date >= ? AND end_date <= ?)
		OR (start_date <= ? AND end_date >= ?))
		ORDER BY start_date DESC
	]]

	return query.safe_execute(db, "get_sprints_by_date_range", function()
		return db:select(sql, { project_key, start_date, end_date, start_date, end_date, start_date, end_date })
	end)
end

-- Insert or update sprint
function M.upsert(db, sprint_data)
	local query = require("jira_ai.db.query")
	
	-- Add synced_at timestamp
	sprint_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")
	return query.upsert_row(db, "sprints", sprint_data, { "id" })
end

-- Insert or update multiple sprints
function M.upsert_batch(db, sprints)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		for _, sprint in ipairs(sprints) do
			local success = M.upsert(db, sprint)
			if not success then
				error("Failed to upsert sprint: " .. (sprint.id or "unknown"))
			end
		end
		return true
	end)
end

-- Mark sprint as inactive
function M.deactivate(db, sprint_id)
	local query = require("jira_ai.db.query")
	
	return query.update_where(
		db,
		"sprints",
		{ active = 0, synced_at = os.date("%Y-%m-%d %H:%M:%S") },
		{ id = sprint_id }
	)
end

-- Get sprint with ticket statistics
function M.get_with_stats(db, sprint_id)
	local query = require("jira_ai.db.query")
	
	local sprint = M.get_by_id(db, sprint_id)
	if not sprint then
		return nil
	end

	-- Get ticket counts by status
	local sql = [[
		SELECT 
			t.status,
			COUNT(*) as count,
			SUM(COALESCE(t.story_points, 0)) as points
		FROM tickets t
		JOIN ticket_sprints ts ON t.key = ts.ticket_key
		WHERE ts.sprint_id = ?
		GROUP BY t.status
	]]

	local stats = query.safe_execute(db, "get_sprint_ticket_stats", function()
		return db:select(sql, { sprint_id })
	end)

	sprint.ticket_stats = {}
	if stats then
		for _, stat in ipairs(stats) do
			sprint.ticket_stats[stat.status] = {
				count = stat.count,
				points = stat.points,
			}
		end
	end

	return sprint
end

-- Get recent sprints for velocity calculation
function M.get_recent_completed(db, project_key, limit)
	limit = limit or 5

	local query = require("jira_ai.db.query")

	local where_conditions = {
		project_key = project_key,
		state = "closed",
	}

	return query.select_where(db, "sprints", where_conditions, {
		order_by = "end_date DESC",
		limit = limit,
	})
end

-- Add ticket to sprint
function M.add_ticket(db, sprint_id, ticket_key, added_date)
	added_date = added_date or os.date("%Y-%m-%d %H:%M:%S")

	local query = require("jira_ai.db.query")

	return query.upsert_row(db, "ticket_sprints", {
		sprint_id = sprint_id,
		ticket_key = ticket_key,
		added_date = added_date,
		synced_at = os.date("%Y-%m-%d %H:%M:%S"),
	}, { "sprint_id", "ticket_key" })
end

-- Remove ticket from sprint
function M.remove_ticket(db, sprint_id, ticket_key, removed_date)
	removed_date = removed_date or os.date("%Y-%m-%d %H:%M:%S")

	local query = require("jira_ai.db.query")

	return query.update_where(db, "ticket_sprints", {
		removed_date = removed_date,
		synced_at = os.date("%Y-%m-%d %H:%M:%S"),
	}, {
		sprint_id = sprint_id,
		ticket_key = ticket_key,
	})
end

return M
