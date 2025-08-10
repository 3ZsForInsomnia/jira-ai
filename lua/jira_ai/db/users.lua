-- User operations

local M = {}

-- Get all users
function M.get_all(db, active_only)
	local query = require("jira_ai.db.query")
	
	local where_conditions = active_only and { active = 1 } or nil
	return query.select_where(db, "users", where_conditions, {
		order_by = "display_name",
	})
end

-- Get user by account ID
function M.get_by_id(db, account_id)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "users", { account_id = account_id })
	return result and result[1] or nil
end

-- Get user by display name
function M.get_by_display_name(db, display_name)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "users", { display_name = display_name })
	return result and result[1] or nil
end

-- Insert or update user
function M.upsert(db, user_data)
	local query = require("jira_ai.db.query")
	
	-- Add synced_at timestamp
	user_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")
	return query.upsert_row(db, "users", user_data, { "account_id" })
end

-- Insert or update multiple users
function M.upsert_batch(db, users)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		for _, user in ipairs(users) do
			local success = M.upsert(db, user)
			if not success then
				error("Failed to upsert user: " .. (user.account_id or "unknown"))
			end
		end
		return true
	end)
end

-- Mark user as inactive
function M.deactivate(db, account_id)
	local query = require("jira_ai.db.query")
	
	return query.update_where(
		db,
		"users",
		{ active = 0, synced_at = os.date("%Y-%m-%d %H:%M:%S") },
		{ account_id = account_id }
	)
end

-- Get user activity statistics
function M.get_activity_stats(db, account_id, project_key)
	local query = require("jira_ai.db.query")
	
	local where_conditions = { assignee_id = account_id }
	if project_key then
		where_conditions.project_key = project_key
	end

	local stats = {}

	-- Count tickets by status
	local result = query.select_where(db, "tickets", where_conditions, {
		columns = "status, COUNT(*) as count, SUM(COALESCE(story_points, 0)) as points",
	})

	stats.tickets_by_status = {}
	stats.points_by_status = {}

	if result then
		for _, row in ipairs(result) do
			stats.tickets_by_status[row.status] = row.count
			stats.points_by_status[row.status] = row.points or 0
		end
	end

	-- Count total tickets assigned
	stats.total_tickets = query.count_where(db, "tickets", where_conditions)

	-- Count completed tickets
	local completed_where = vim.tbl_extend("force", where_conditions, { status = "done" })
	stats.completed_tickets = query.count_where(db, "tickets", completed_where)

	return stats
end

-- Get users with their current workload
function M.get_with_workload(db, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			u.account_id,
			u.display_name,
			u.email,
			COUNT(t.key) as active_tickets,
			SUM(COALESCE(t.story_points, 0)) as active_points
		FROM users u
		LEFT JOIN tickets t ON u.account_id = t.assignee_id 
			AND t.status IN ('not_started', 'in_progress', 'qa')
	]]

	local params = {}
	if project_key then
		sql = sql .. " AND t.project_key = ?"
		params = { project_key }
	end

	sql = sql .. [[
		WHERE u.active = 1
		GROUP BY u.account_id, u.display_name, u.email
		ORDER BY u.display_name
	]]

	return query.safe_execute(db, "get_users_with_workload", function()
		return db:select(sql, params)
	end)
end

return M
