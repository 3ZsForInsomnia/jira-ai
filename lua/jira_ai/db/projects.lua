-- Project operations

local M = {}

-- Get all projects
function M.get_all(db, active_only)
	local query = require("jira_ai.db.query")
	
	local where_conditions = active_only and { active = 1 } or nil
	return query.select_where(db, "projects", where_conditions, {
		order_by = "key",
	})
end

-- Get project by key
function M.get_by_key(db, project_key)
	local query = require("jira_ai.db.query")
	
	local result = query.select_where(db, "projects", { key = project_key })
	return result and result[1] or nil
end

-- Insert or update project
function M.upsert(db, project_data)
	local query = require("jira_ai.db.query")
	
	-- Add synced_at timestamp
	project_data.synced_at = os.date("%Y-%m-%d %H:%M:%S")
	return query.upsert_row(db, "projects", project_data, { "key" })
end

-- Insert or update multiple projects
function M.upsert_batch(db, projects)
	local log = require("jira_ai.log")
	local query = require("jira_ai.db.query")
	
	log.info("Upserting batch of " .. #projects .. " projects", "db.projects")
	return query.transaction(db, function()
		for _, project in ipairs(projects) do
			local success = M.upsert(db, project)
			if not success then
				error("Failed to upsert project: " .. (project.key or "unknown"))
			end
		end
		return true
	end)
end

-- Mark project as inactive
function M.deactivate(db, project_key)
	local query = require("jira_ai.db.query")
	
	return query.update_where(
		db,
		"projects",
		{ active = 0, synced_at = os.date("%Y-%m-%d %H:%M:%S") },
		{ key = project_key }
	)
end

-- Delete project and all related data
function M.delete_cascade(db, project_key)
	local query = require("jira_ai.db.query")
	
	return query.transaction(db, function()
		-- Delete in order to respect foreign key constraints
		-- Delete comments for tickets in this project
		db:execute(
			[[
			DELETE FROM comments 
			WHERE ticket_key IN (SELECT key FROM tickets WHERE project_key = ?)
		]],
			{ project_key }
		)

		-- Delete status changes for tickets in this project
		db:execute(
			[[
			DELETE FROM status_changes 
			WHERE ticket_key IN (SELECT key FROM tickets WHERE project_key = ?)
		]],
			{ project_key }
		)

		-- Delete issue links for tickets in this project
		db:execute(
			[[
			DELETE FROM issue_links 
			WHERE source_key IN (SELECT key FROM tickets WHERE project_key = ?)
			   OR target_key IN (SELECT key FROM tickets WHERE project_key = ?)
		]],
			{ project_key, project_key }
		)

		-- Delete ticket-sprint relationships
		db:execute(
			[[
			DELETE FROM ticket_sprints 
			WHERE ticket_key IN (SELECT key FROM tickets WHERE project_key = ?)
		]],
			{ project_key }
		)

		-- Delete tickets
		query.delete_where(db, "tickets", { project_key = project_key })

		-- Delete epics
		query.delete_where(db, "epics", { project_key = project_key })

		-- Delete sprints
		query.delete_where(db, "sprints", { project_key = project_key })

		-- Delete project
		query.delete_where(db, "projects", { key = project_key })

		return true
	end)
end

-- Get project statistics
function M.get_stats(db, project_key)
	local query = require("jira_ai.db.query")
	
	local stats = {}

	-- Count epics
	stats.epic_count = query.count_where(db, "epics", { project_key = project_key })

	-- Count tickets by status
	local ticket_counts = query.select_where(db, "tickets", { project_key = project_key }, {
		columns = "status, COUNT(*) as count",
	})
	stats.tickets_by_status = {}
	if ticket_counts then
		for _, row in ipairs(ticket_counts) do
			stats.tickets_by_status[row.status] = row.count
		end
	end

	-- Count sprints
	stats.sprint_count = query.count_where(db, "sprints", { project_key = project_key })
	stats.active_sprint_count = query.count_where(db, "sprints", {
		project_key = project_key,
		active = 1,
	})

	return stats
end

return M
