
local M = {}

-- Get all tickets
function M.get_all(db, project_key, status_filter)
	local query = require("jira_ai.db.query")
	
	local where_conditions = {}
	if project_key then
		where_conditions.project_key = project_key
	end
	if status_filter then
		if type(status_filter) == "table" then
			where_conditions.status = status_filter
		else
			where_conditions.status = status_filter
		end
	end

	return query.select_where(db, "tickets", where_conditions, {
		order_by = "updated_date DESC",
	})
end

-- Get ticket by key
function M.get_by_key(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "tickets", { key = ticket_key })
	return result and result[1] or nil
end

-- Get tickets in a sprint
function M.get_by_sprint(db, sprint_id, include_removed)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT t.*, ts.added_date, ts.removed_date
		FROM tickets t
		JOIN ticket_sprints ts ON t.key = ts.ticket_key
		WHERE ts.sprint_id = ?
	]]

	local params = { sprint_id }
	if not include_removed then
		sql = sql .. " AND ts.removed_date IS NULL"
	end

	sql = sql .. " ORDER BY t.updated_date DESC"

	return query.safe_execute(db, "get_tickets_by_sprint", function()
		return db:select(sql, params)
	end)
end

-- Get tickets by epic
function M.get_by_epic(db, epic_key)
	local query = require("jira_ai.db.query")
	
	return query.select_where(db, "tickets", { epic_key = epic_key }, {
		order_by = "created_date ASC",
	})
end

-- Get tickets assigned to user
function M.get_by_assignee(db, assignee_id, project_key, status_filter)
	local query = require("jira_ai.db.query")
	
	local where_conditions = { assignee_id = assignee_id }
	if project_key then
		where_conditions.project_key = project_key
	end
	if status_filter then
		where_conditions.status = status_filter
	end

	return query.select_where(db, "tickets", where_conditions, {
		order_by = "updated_date DESC",
	})
end

-- Get unassigned tickets
function M.get_unassigned(db, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = "SELECT * FROM tickets WHERE assignee_id IS NULL"
	local params = {}

	if project_key then
		sql = sql .. " AND project_key = ?"
		params = { project_key }
	end

	sql = sql .. " ORDER BY created_date DESC"

	return query.safe_execute(db, "get_unassigned_tickets", function()
		return db:select(sql, params)
	end)
end

-- Get blocked tickets
function M.get_blocked(db, project_key)
	local query = require("jira_ai.db.query")
	
	local where_conditions = { is_blocked = 1 }
	if project_key then
		where_conditions.project_key = project_key
	end

	return query.select_where(db, "tickets", where_conditions, {
		order_by = "updated_date DESC",
	})
end

-- Get stale tickets (not updated recently)
function M.get_stale(db, project_key, days_threshold)
	days_threshold = days_threshold or 3
	local query = require("jira_ai.db.query")
	
	local cutoff_date = os.date("%Y-%m-%d %H:%M:%S", os.time() - (days_threshold * 24 * 60 * 60))

	local sql = [[
		SELECT * FROM tickets 
		WHERE updated_date < ? 
		AND status IN ('not_started', 'in_progress', 'qa')
	]]

	local params = { cutoff_date }
	if project_key then
		sql = sql .. " AND project_key = ?"
		table.insert(params, project_key)
	end

	sql = sql .. " ORDER BY updated_date ASC"

	return query.safe_execute(db, "get_stale_tickets", function()
		return db:select(sql, params)
	end)
end

-- Insert or update ticket
function M.upsert(db, ticket_data)
	local query = require("jira_ai.db.query")
	
	-- Add synced_at timestamp
	ticket_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")
	return query.upsert_row(db, "tickets", ticket_data, { "key" })
end

-- Insert or update multiple tickets
function M.upsert_batch(db, tickets)
	local log = require("jira_ai.log")
	local query = require("jira_ai.db.query")
	
	log.info("Upserting batch of " .. #tickets .. " tickets", "db.tickets")
	return query.transaction(db, function()
		for _, ticket in ipairs(tickets) do
			local success = M.upsert(db, ticket)
			if not success then
				error("Failed to upsert ticket: " .. (ticket.key or "unknown"))
			end
		end
		return true
	end)
end

-- Update ticket status and record status change
function M.update_status(db, ticket_key, new_status, changed_by_id, changed_date)
	local query = require("jira_ai.db.query")
	local status_changes = require("jira_ai.db.status_changes")
	
	return query.transaction(db, function()
		-- Get current status
		local current_ticket = M.get_by_key(db, ticket_key)
		if not current_ticket then
			error("Ticket not found: " .. ticket_key)
		end

		local old_status = current_ticket.status

		-- Update ticket status
		local success = query.update_where(db, "tickets", {
			status = new_status,
			synced_at = os.date("%Y-%m-%d %H:%M:%S"),
		}, { key = ticket_key })

		if not success then
			error("Failed to update ticket status")
		end

		-- Record status change
		return status_changes.add(db, {
			ticket_key = ticket_key,
			from_status = old_status,
			to_status = new_status,
			changed_by_id = changed_by_id,
			changed_date = changed_date or os.date("%Y-%m-%d %H:%M:%S"),
		})
	end)
end

-- Get tickets with their latest comments
function M.get_with_latest_comments(db, where_conditions)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			t.*,
			c.body as latest_comment,
			c.created_date as latest_comment_date,
			c.author_id as latest_comment_author
		FROM tickets t
		LEFT JOIN comments c ON t.key = c.ticket_key AND c.is_latest = 1
	]]

	local params = {}

	-- Build WHERE clause if conditions provided
	if where_conditions and next(where_conditions) then
		local where_parts = {}
		for key, value in pairs(where_conditions) do
			table.insert(where_parts, "t." .. key .. " = ?")
			table.insert(params, value)
		end
		sql = sql .. " WHERE " .. table.concat(where_parts, " AND ")
	end

	sql = sql .. " ORDER BY t.updated_date DESC"

	return query.safe_execute(db, "get_tickets_with_comments", function()
		return db:select(sql, params)
	end)
end

-- Get ticket hierarchy (parent/child relationships)
function M.get_hierarchy(db, root_ticket_key)
	local query = require("jira_ai.db.query")
	
	local function get_children(parent_key, depth)
		if depth > 10 then -- Prevent infinite recursion
			return {}
		end

		local children = query.select_where(db, "tickets", { parent_key = parent_key })
		if not children then
			return {}
		end

		for _, child in ipairs(children) do
			child.children = get_children(child.key, depth + 1)
		end

		return children
	end

	local root = M.get_by_key(db, root_ticket_key)
	if root then
		root.children = get_children(root_ticket_key, 0)
	end

	return root
end

-- Get velocity data for tickets completed in date range
function M.get_velocity_data(db, assignee_id, start_date, end_date, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			COUNT(*) as tickets_completed,
			SUM(COALESCE(story_points, 0)) as points_completed,
			AVG(julianday(resolved_date) - julianday(created_date)) as avg_cycle_time
		FROM tickets
		WHERE assignee_id = ?
		AND status = 'done'
		AND resolved_date >= ? AND resolved_date <= ?
	]]

	local params = { assignee_id, start_date, end_date }

	if project_key then
		sql = sql .. " AND project_key = ?"
		table.insert(params, project_key)
	end

	local result = query.safe_execute(db, "get_velocity_data", function()
		return db:select(sql, params)
	end)

	return result and result[1] or {
		tickets_completed = 0,
		points_completed = 0,
		avg_cycle_time = 0,
	}
end

return M
