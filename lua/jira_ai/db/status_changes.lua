-- Status change operations

local M = {}

-- Add a status change record
function M.add(db, change_data)
	change_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")
	local query = require("jira_ai.db.query")
	return query.insert_rows(db, "status_changes", change_data)
end

-- Add multiple status changes
function M.add_batch(db, changes)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		for _, change in ipairs(changes) do
			local success = M.add(db, change)
			if not success then
				error("Failed to add status change for ticket: " .. (change.ticket_key or "unknown"))
			end
		end
		return true
	end)
end

-- Get status changes for a ticket
function M.get_by_ticket(db, ticket_key, limit)
	local query = require("jira_ai.db.query")
	
	local options = { order_by = "changed_date DESC" }
	if limit then
		options.limit = limit
	end

	return query.select_where(db, "status_changes", { ticket_key = ticket_key }, options)
end

-- Get QA bounces for a ticket
function M.get_qa_bounces(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT * FROM status_changes 
		WHERE ticket_key = ? 
		AND (to_status = 'qa' OR from_status = 'qa')
		ORDER BY changed_date ASC
	]]

	local changes = query.safe_execute(db, "get_qa_bounces", function()
		return db:select(sql, { ticket_key })
	end)

	if not changes then
		return 0, {}
	end

	-- Count transitions to QA (each is a potential bounce)
	local bounce_count = 0
	local bounce_details = {}

	for _, change in ipairs(changes) do
		if change.to_status == "qa" then
			bounce_count = bounce_count + 1
			table.insert(bounce_details, {
				date = change.changed_date,
				changed_by = change.changed_by_id,
				from_status = change.from_status,
			})
		end
	end

	return bounce_count, bounce_details
end

-- Get time spent in each status for a ticket
function M.get_time_in_status(db, ticket_key)
	local changes = M.get_by_ticket(db, ticket_key)
	if not changes or #changes == 0 then
		return {}
	end

	-- Sort by date ascending
	table.sort(changes, function(a, b)
		return a.changed_date < b.changed_date
	end)

	local time_in_status = {}
	local current_status = nil
	local status_start_time = nil

	for _, change in ipairs(changes) do
		-- Calculate time spent in previous status
		if current_status and status_start_time then
			local end_time = change.changed_date
			local duration = os.difftime(
				os.time(M._parse_datetime(end_time)),
				os.time(M._parse_datetime(status_start_time))
			) / (24 * 60 * 60) -- Convert to days

			time_in_status[current_status] = (time_in_status[current_status] or 0) + duration
		end

		-- Update current status
		current_status = change.to_status
		status_start_time = change.changed_date
	end

	-- Handle current status (if ticket is still active)
	if current_status and status_start_time then
		local now = os.date("%Y-%m-%d %H:%M:%S")
		local duration = os.difftime(os.time(M._parse_datetime(now)), os.time(M._parse_datetime(status_start_time)))
			/ (24 * 60 * 60)

		time_in_status[current_status] = (time_in_status[current_status] or 0) + duration
	end

	return time_in_status
end

-- Get average time in status for a user across multiple tickets
function M.get_avg_time_in_status(db, assignee_id, project_key, date_range_start, date_range_end)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			sc.to_status,
			AVG(julianday(sc2.changed_date) - julianday(sc.changed_date)) as avg_days
		FROM status_changes sc
		JOIN status_changes sc2 ON sc.ticket_key = sc2.ticket_key 
			AND sc2.changed_date > sc.changed_date
		JOIN tickets t ON sc.ticket_key = t.key
		WHERE t.assignee_id = ?
	]]

	local params = { assignee_id }

	if project_key then
		sql = sql .. " AND t.project_key = ?"
		table.insert(params, project_key)
	end

	if date_range_start then
		sql = sql .. " AND sc.changed_date >= ?"
		table.insert(params, date_range_start)
	end

	if date_range_end then
		sql = sql .. " AND sc.changed_date <= ?"
		table.insert(params, date_range_end)
	end

	sql = sql .. " GROUP BY sc.to_status"

	local result = query.safe_execute(db, "get_avg_time_in_status", function()
		return db:select(sql, params)
	end)

	local avg_times = {}
	if result then
		for _, row in ipairs(result) do
			avg_times[row.to_status] = row.avg_days
		end
	end

	return avg_times
end

-- Helper function to parse datetime string
function M._parse_datetime(datetime_str)
	local year, month, day, hour, min, sec = datetime_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
	return {
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(min),
		sec = tonumber(sec),
	}
end

-- Get tickets with frequent status changes (potential thrashing)
function M.get_thrashing_tickets(db, project_key, min_changes, days_window)
	min_changes = min_changes or 5
	days_window = days_window or 14

	local query = require("jira_ai.db.query")

	local cutoff_date = os.date("%Y-%m-%d %H:%M:%S", os.time() - (days_window * 24 * 60 * 60))

	local sql = [[
		SELECT 
			sc.ticket_key,
			COUNT(*) as change_count,
			t.summary,
			t.assignee_id,
			t.status
		FROM status_changes sc
		JOIN tickets t ON sc.ticket_key = t.key
		WHERE sc.changed_date >= ?
	]]

	local params = { cutoff_date }

	if project_key then
		sql = sql .. " AND t.project_key = ?"
		table.insert(params, project_key)
	end

	sql = sql
		.. [[
		GROUP BY sc.ticket_key, t.summary, t.assignee_id, t.status
		HAVING COUNT(*) >= ?
		ORDER BY change_count DESC
	]]

	table.insert(params, min_changes)

	return query.safe_execute(db, "get_thrashing_tickets", function()
		return db:select(sql, params)
	end)
end

return M
