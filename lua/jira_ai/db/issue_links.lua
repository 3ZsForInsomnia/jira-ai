-- Issue link operations (blocking relationships, etc.)

local M = {}

-- Add an issue link
function M.add(db, link_data)
	link_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")
	local query = require("jira_ai.db.query")
	return query.upsert_row(db, "issue_links", link_data, { "source_key", "target_key", "link_type" })
end

-- Add multiple issue links
function M.add_batch(db, links)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		for _, link in ipairs(links) do
			local success = M.add(db, link)
			if not success then
				error(
					"Failed to add issue link: "
						.. (link.source_key or "unknown")
						.. " -> "
						.. (link.target_key or "unknown")
				)
			end
		end
		return true
	end)
end

-- Get links for a ticket (both inward and outward)
function M.get_by_ticket(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			il.*,
			'outward' as direction,
			t.summary as target_summary,
			t.status as target_status
		FROM issue_links il
		JOIN tickets t ON il.target_key = t.key
		WHERE il.source_key = ?
		
		UNION ALL
		
		SELECT 
			il.*,
			'inward' as direction,
			t.summary as target_summary,
			t.status as target_status
		FROM issue_links il
		JOIN tickets t ON il.source_key = t.key
		WHERE il.target_key = ?
		
		ORDER BY link_type, target_summary
	]]

	return query.safe_execute(db, "get_issue_links", function()
		return db:select(sql, { ticket_key, ticket_key })
	end)
end

-- Get blocking relationships for a ticket
function M.get_blockers(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			il.*,
			t.summary as blocker_summary,
			t.status as blocker_status,
			t.assignee_id as blocker_assignee
		FROM issue_links il
		JOIN tickets t ON il.source_key = t.key
		WHERE il.target_key = ? 
		AND il.link_type = 'blocks'
		ORDER BY t.summary
	]]

	return query.safe_execute(db, "get_blockers", function()
		return db:select(sql, { ticket_key })
	end)
end

-- Get tickets blocked by this ticket
function M.get_blocked_tickets(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			il.*,
			t.summary as blocked_summary,
			t.status as blocked_status,
			t.assignee_id as blocked_assignee
		FROM issue_links il
		JOIN tickets t ON il.target_key = t.key
		WHERE il.source_key = ? 
		AND il.link_type = 'blocks'
		ORDER BY t.summary
	]]

	return query.safe_execute(db, "get_blocked_tickets", function()
		return db:select(sql, { ticket_key })
	end)
end

-- Get all blocked tickets in a project
function M.get_all_blocked(db, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			t.key,
			t.summary,
			t.status,
			t.assignee_id,
			COUNT(il.source_key) as blocker_count
		FROM tickets t
		JOIN issue_links il ON t.key = il.target_key AND il.link_type = 'blocks'
		WHERE t.project_key = ?
		GROUP BY t.key, t.summary, t.status, t.assignee_id
		ORDER BY blocker_count DESC, t.summary
	]]

	return query.safe_execute(db, "get_all_blocked_tickets", function()
		return db:select(sql, { project_key })
	end)
end

-- Update ticket blocked status based on current links
function M.update_blocked_status(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	local blockers = M.get_blockers(db, ticket_key)
	local is_blocked = blockers and #blockers > 0

	return query.update_where(db, "tickets", {
		is_blocked = is_blocked and 1 or 0,
		synced_at = os.date("%Y-%m-%d %H:%M:%S"),
	}, { key = ticket_key })
end

-- Remove issue link
function M.remove(db, source_key, target_key, link_type)
	local query = require("jira_ai.db.query")
	
	return query.delete_where(db, "issue_links", {
		source_key = source_key,
		target_key = target_key,
		link_type = link_type,
	})
end

-- Remove all links for a ticket
function M.remove_all_for_ticket(db, ticket_key)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		-- Remove as source
		query.delete_where(db, "issue_links", { source_key = ticket_key })

		-- Remove as target
		query.delete_where(db, "issue_links", { target_key = ticket_key })

		return true
	end)
end

-- Get dependency chain (tickets that depend on this one)
function M.get_dependency_chain(db, root_ticket_key, max_depth)
	max_depth = max_depth or 5

	local function get_dependencies(ticket_key, depth, visited)
		if depth > max_depth or visited[ticket_key] then
			return {}
		end

		visited[ticket_key] = true
		local dependencies = {}

		-- Get tickets blocked by this one
		local blocked = M.get_blocked_tickets(db, ticket_key)
		if blocked then
			for _, link in ipairs(blocked) do
				local dep = {
					key = link.target_key,
					summary = link.blocked_summary,
					status = link.blocked_status,
					assignee_id = link.blocked_assignee,
					depth = depth,
					dependencies = get_dependencies(link.target_key, depth + 1, visited),
				}
				table.insert(dependencies, dep)
			end
		end

		return dependencies
	end

	return get_dependencies(root_ticket_key, 0, {})
end

-- Get blocking chain (tickets this one depends on)
function M.get_blocking_chain(db, root_ticket_key, max_depth)
	max_depth = max_depth or 5

	local function get_blockers_recursive(ticket_key, depth, visited)
		if depth > max_depth or visited[ticket_key] then
			return {}
		end

		visited[ticket_key] = true
		local blocking_chain = {}

		-- Get tickets blocking this one
		local blockers = M.get_blockers(db, ticket_key)
		if blockers then
			for _, link in ipairs(blockers) do
				local blocker = {
					key = link.source_key,
					summary = link.blocker_summary,
					status = link.blocker_status,
					assignee_id = link.blocker_assignee,
					depth = depth,
					blockers = get_blockers_recursive(link.source_key, depth + 1, visited),
				}
				table.insert(blocking_chain, blocker)
			end
		end

		return blocking_chain
	end

	return get_blockers_recursive(root_ticket_key, 0, {})
end

-- Get link statistics for reporting
function M.get_link_stats(db, project_key)
	local query = require("jira_ai.db.query")
	
	local sql = [[
		SELECT 
			il.link_type,
			COUNT(*) as count
		FROM issue_links il
		JOIN tickets t1 ON il.source_key = t1.key
		JOIN tickets t2 ON il.target_key = t2.key
		WHERE t1.project_key = ? OR t2.project_key = ?
		GROUP BY il.link_type
		ORDER BY count DESC
	]]

	return query.safe_execute(db, "get_link_stats", function()
		return db:select(sql, { project_key, project_key })
	end)
end

return M
