-- Comment operations

local M = {}

-- Add a comment
function M.add(db, comment_data)
	comment_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")

	local query = require("jira_ai.db.query")

	return query.transaction(db, function()
		-- First, unmark any existing latest comments for this ticket
		query.update_where(db, "comments", { is_latest = 0 }, { ticket_key = comment_data.ticket_key, is_latest = 1 })

		-- Insert the new comment
		local success = query.upsert_row(db, "comments", comment_data, { "id" })

		if success and comment_data.is_latest then
			-- This is the latest comment, make sure it's marked as such
			query.update_where(db, "comments", { is_latest = 1 }, { id = comment_data.id })
		end

		return success
	end)
end

-- Add multiple comments
function M.add_batch(db, comments)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		for _, comment in ipairs(comments) do
			local success = M.add(db, comment)
			if not success then
				error("Failed to add comment: " .. (comment.id or "unknown"))
			end
		end
		return true
	end)
end

-- Get comments for a ticket
function M.get_by_ticket(db, ticket_key, limit)
	local query = require("jira_ai.db.query")
	
	local options = { order_by = "created_date DESC" }
	if limit then
		options.limit = limit
	end

	return query.select_where(db, "comments", { ticket_key = ticket_key }, options)
end

-- Get latest comment for a ticket
function M.get_latest(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "comments", { ticket_key = ticket_key, is_latest = 1 }, { limit = 1 })
	return result and result[1] or nil
end

-- Get comments by author
function M.get_by_author(db, author_id, project_key, limit)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT c.*, t.project_key, t.summary as ticket_summary
		FROM comments c
		JOIN tickets t ON c.ticket_key = t.key
		WHERE c.author_id = ?
	]]

	local params = { author_id }

	if project_key then
		sql = sql .. " AND t.project_key = ?"
		table.insert(params, project_key)
	end

	sql = sql .. " ORDER BY c.created_date DESC"

	if limit then
		sql = sql .. " LIMIT " .. limit
	end

	return query.safe_execute(db, "get_comments_by_author", function()
		return db:select(sql, params)
	end)
end

-- Get recent comments across projects/tickets
function M.get_recent(db, project_key, days, limit)
	days = days or 7
	limit = limit or 50

	local query = require("jira_ai.db.query")

	local cutoff_date = os.date("%Y-%m-%d %H:%M:%S", os.time() - (days * 24 * 60 * 60))

	local sql = [[
		SELECT 
			c.*,
			t.summary as ticket_summary,
			t.project_key,
			u.display_name as author_name
		FROM comments c
		JOIN tickets t ON c.ticket_key = t.key
		JOIN users u ON c.author_id = u.account_id
		WHERE c.created_date >= ?
	]]

	local params = { cutoff_date }

	if project_key then
		sql = sql .. " AND t.project_key = ?"
		table.insert(params, project_key)
	end

	sql = sql .. " ORDER BY c.created_date DESC LIMIT " .. limit

	return query.safe_execute(db, "get_recent_comments", function()
		return db:select(sql, params)
	end)
end

-- Update latest comment flags for a ticket
function M.update_latest_for_ticket(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		-- First, unmark all comments for this ticket
		query.update_where(db, "comments", { is_latest = 0 }, { ticket_key = ticket_key })

		-- Find the most recent comment
		local latest = query.select_where(
			db,
			"comments",
			{ ticket_key = ticket_key },
			{ order_by = "created_date DESC", limit = 1 }
		)

		if latest and latest[1] then
			-- Mark it as latest
			query.update_where(db, "comments", { is_latest = 1 }, { id = latest[1].id })
		end

		return true
	end)
end

-- Get comment statistics for a user
function M.get_user_stats(db, author_id, project_key, date_range_start, date_range_end)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			COUNT(*) as total_comments,
			COUNT(DISTINCT c.ticket_key) as tickets_commented,
			AVG(LENGTH(c.body)) as avg_comment_length
		FROM comments c
		JOIN tickets t ON c.ticket_key = t.key
		WHERE c.author_id = ?
	]]

	local params = { author_id }

	if project_key then
		sql = sql .. " AND t.project_key = ?"
		table.insert(params, project_key)
	end

	if date_range_start then
		sql = sql .. " AND c.created_date >= ?"
		table.insert(params, date_range_start)
	end

	if date_range_end then
		sql = sql .. " AND c.created_date <= ?"
		table.insert(params, date_range_end)
	end

	local result = query.safe_execute(db, "get_comment_user_stats", function()
		return db:select(sql, params)
	end)

	return result and result[1] or {
		total_comments = 0,
		tickets_commented = 0,
		avg_comment_length = 0,
	}
end

-- Search comments by content
function M.search(db, search_term, project_key, limit)
	limit = limit or 100

	local query = require("jira_ai.db.query")

	local sql = [[
		SELECT 
			c.*,
			t.summary as ticket_summary,
			t.project_key,
			u.display_name as author_name
		FROM comments c
		JOIN tickets t ON c.ticket_key = t.key
		JOIN users u ON c.author_id = u.account_id
		WHERE c.body LIKE ?
	]]

	local params = { "%" .. search_term .. "%" }

	if project_key then
		sql = sql .. " AND t.project_key = ?"
		table.insert(params, project_key)
	end

	sql = sql .. " ORDER BY c.created_date DESC LIMIT " .. limit

	return query.safe_execute(db, "search_comments", function()
		return db:select(sql, params)
	end)
end

return M
