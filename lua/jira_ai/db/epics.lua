
local M = {}

-- Get all epics
function M.get_all(db, project_key, status_filter)
	local query = require("jira_ai.db.query")
	
	local where_conditions = {}
	if project_key then
		where_conditions.project_key = project_key
	end
	if status_filter then
		where_conditions.status = status_filter
	end

	return query.select_where(db, "epics", where_conditions, {
		order_by = "created_date DESC",
	})
end

-- Get epic by key
function M.get_by_key(db, epic_key)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "epics", { key = epic_key })
	return result and result[1] or nil
end

-- Get epics with ticket counts and progress
function M.get_with_progress(db, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			e.*,
			COUNT(t.key) as total_tickets,
			SUM(CASE WHEN t.status = 'done' THEN 1 ELSE 0 END) as completed_tickets,
			SUM(COALESCE(t.story_points, 0)) as total_points,
			SUM(CASE WHEN t.status = 'done' THEN COALESCE(t.story_points, 0) ELSE 0 END) as completed_points
		FROM epics e
		LEFT JOIN tickets t ON e.key = t.epic_key
	]]

	local params = {}
	if project_key then
		sql = sql .. " WHERE e.project_key = ?"
		params = { project_key }
	end

	sql = sql
		.. [[
		GROUP BY e.key, e.project_key, e.summary, e.status, e.assignee_id, 
				 e.description, e.created_date, e.resolved_date, e.synced_at
		ORDER BY e.created_date DESC
	]]

	return query.safe_execute(db, "get_epics_with_progress", function()
		return db:select(sql, params)
	end)
end

-- Get active epics (not done/closed)
function M.get_active(db, project_key)
	local query = require("jira_ai.db.query")
	
	local where_conditions = { status = { "In Progress", "To Do", "Open" } }
	if project_key then
		where_conditions.project_key = project_key
	end

	return query.select_where(db, "epics", where_conditions, {
		order_by = "created_date DESC",
	})
end

-- Insert or update epic
function M.upsert(db, epic_data)
	local query = require("jira_ai.db.query")
	
	-- Add synced_at timestamp
	epic_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")
	return query.upsert_row(db, "epics", epic_data, { "key" })
end

-- Insert or update multiple epics
function M.upsert_batch(db, epics)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		for _, epic in ipairs(epics) do
			local success = M.upsert(db, epic)
			if not success then
				error("Failed to upsert epic: " .. (epic.key or "unknown"))
			end
		end
		return true
	end)
end

-- Get epic with full ticket hierarchy
function M.get_with_stories(db, epic_key)
	local tickets = require("jira_ai.db.tickets")
	
	local epic = M.get_by_key(db, epic_key)
	if not epic then
		return nil
	end

	-- Get all tickets in this epic
	local epic_tickets = tickets.get_by_epic(db, epic_key)

	if not epic_tickets then
		epic.stories = {}
		return epic
	end

	-- Build hierarchy: organize by parent/child relationships
	local stories = {}
	local tickets_by_key = {}

	-- First pass: index all tickets
	for _, ticket in ipairs(epic_tickets) do
		tickets_by_key[ticket.key] = ticket
		ticket.children = {}
	end

	-- Second pass: build hierarchy
	for _, ticket in ipairs(epic_tickets) do
		if ticket.parent_key and tickets_by_key[ticket.parent_key] then
			-- This is a subtask
			table.insert(tickets_by_key[ticket.parent_key].children, ticket)
		else
			-- This is a top-level story
			table.insert(stories, ticket)
		end
	end

	epic.stories = stories
	return epic
end

-- Get epic statistics
function M.get_stats(db, epic_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			t.status,
			COUNT(*) as count,
			SUM(COALESCE(t.story_points, 0)) as points
		FROM tickets t
		WHERE t.epic_key = ?
		GROUP BY t.status
	]]

	local result = query.safe_execute(db, "get_epic_stats", function()
		return db:select(sql, { epic_key })
	end)

	local stats = {
		total_tickets = 0,
		total_points = 0,
		by_status = {},
	}

	if result then
		for _, row in ipairs(result) do
			stats.by_status[row.status] = {
				count = row.count,
				points = row.points,
			}
			stats.total_tickets = stats.total_tickets + row.count
			stats.total_points = stats.total_points + row.points
		end
	end

	return stats
end

-- Mark epic as resolved
function M.mark_resolved(db, epic_key, resolved_date)
	resolved_date = resolved_date or os.date("%Y-%m-%d %H:%M:%S")

	local query = require("jira_ai.db.query")

	return query.update_where(db, "epics", {
		status = "Done",
		resolved_date = resolved_date,
		synced_at = os.date("%Y-%m-%d %H:%M:%S"),
	}, { key = epic_key })
end

return M
