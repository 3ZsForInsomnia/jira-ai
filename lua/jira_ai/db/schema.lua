-- Database schema definitions
local M = {}

-- Table creation statements
local CREATE_STATEMENTS = {
	projects = [[
		CREATE TABLE IF NOT EXISTS projects (
			key TEXT PRIMARY KEY,
			name TEXT,
			active BOOLEAN DEFAULT 1,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	]],

	users = [[
		CREATE TABLE IF NOT EXISTS users (
			account_id TEXT PRIMARY KEY,
			display_name TEXT NOT NULL,
			email TEXT,
			active BOOLEAN DEFAULT 1,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	]],

	sprints = [[
		CREATE TABLE IF NOT EXISTS sprints (
			id INTEGER PRIMARY KEY,
			project_key TEXT NOT NULL,
			name TEXT NOT NULL,
			state TEXT NOT NULL,
			start_date DATETIME,
			end_date DATETIME,
			goal TEXT,
			active BOOLEAN DEFAULT 1,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (project_key) REFERENCES projects(key)
		)
	]],

	epics = [[
		CREATE TABLE IF NOT EXISTS epics (
			key TEXT PRIMARY KEY,
			project_key TEXT NOT NULL,
			summary TEXT NOT NULL,
			status TEXT NOT NULL,
			assignee_id TEXT,
			description TEXT,
			created_date DATETIME,
			resolved_date DATETIME,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (project_key) REFERENCES projects(key),
			FOREIGN KEY (assignee_id) REFERENCES users(account_id)
		)
	]],

	status_categories = [[
		CREATE TABLE IF NOT EXISTS status_categories (
			status_name TEXT PRIMARY KEY,
			category TEXT NOT NULL CHECK (category IN ('not_started', 'in_progress', 'qa', 'done')),
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	]],

	tickets = [[
		CREATE TABLE IF NOT EXISTS tickets (
			key TEXT PRIMARY KEY,
			project_key TEXT NOT NULL,
			epic_key TEXT,
			parent_key TEXT,
			summary TEXT NOT NULL,
			description TEXT,
			issue_type TEXT NOT NULL,
			status TEXT NOT NULL CHECK (status IN ('not_started', 'in_progress', 'qa', 'done')),
			raw_status TEXT,
			priority TEXT,
			assignee_id TEXT,
			reporter_id TEXT,
			story_points INTEGER,
			created_date DATETIME,
			updated_date DATETIME,
			resolved_date DATETIME,
			due_date DATETIME,
			is_blocked BOOLEAN DEFAULT 0,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (project_key) REFERENCES projects(key),
			FOREIGN KEY (epic_key) REFERENCES epics(key),
			FOREIGN KEY (parent_key) REFERENCES tickets(key),
			FOREIGN KEY (assignee_id) REFERENCES users(account_id),
			FOREIGN KEY (reporter_id) REFERENCES users(account_id)
		)
	]],

	ticket_sprints = [[
		CREATE TABLE IF NOT EXISTS ticket_sprints (
			ticket_key TEXT NOT NULL,
			sprint_id INTEGER NOT NULL,
			added_date DATETIME,
			removed_date DATETIME,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (ticket_key, sprint_id),
			FOREIGN KEY (ticket_key) REFERENCES tickets(key),
			FOREIGN KEY (sprint_id) REFERENCES sprints(id)
		)
	]],

	issue_links = [[
		CREATE TABLE IF NOT EXISTS issue_links (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			source_key TEXT NOT NULL,
			target_key TEXT NOT NULL,
			link_type TEXT NOT NULL,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (source_key) REFERENCES tickets(key),
			FOREIGN KEY (target_key) REFERENCES tickets(key),
			UNIQUE(source_key, target_key, link_type)
		)
	]],

	comments = [[
		CREATE TABLE IF NOT EXISTS comments (
			id TEXT PRIMARY KEY,
			ticket_key TEXT NOT NULL,
			author_id TEXT NOT NULL,
			body TEXT NOT NULL,
			created_date DATETIME NOT NULL,
			updated_date DATETIME,
			is_latest BOOLEAN DEFAULT 0,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (ticket_key) REFERENCES tickets(key),
			FOREIGN KEY (author_id) REFERENCES users(account_id)
		)
	]],

	status_changes = [[
		CREATE TABLE IF NOT EXISTS status_changes (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			ticket_key TEXT NOT NULL,
			from_status TEXT,
			to_status TEXT NOT NULL CHECK (to_status IN ('not_started', 'in_progress', 'qa', 'done')),
			changed_by_id TEXT NOT NULL,
			changed_date DATETIME NOT NULL,
			synced_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (ticket_key) REFERENCES tickets(key),
			FOREIGN KEY (changed_by_id) REFERENCES users(account_id)
		)
	]],
}

-- Index creation statements for performance
local INDEX_STATEMENTS = {
	[[CREATE INDEX IF NOT EXISTS idx_projects_active ON projects(active)]],
	[[CREATE INDEX IF NOT EXISTS idx_sprints_active ON sprints(active)]],
	[[CREATE INDEX IF NOT EXISTS idx_sprints_project ON sprints(project_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_epics_project ON epics(project_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_epics_status ON epics(status)]],
	[[CREATE INDEX IF NOT EXISTS idx_tickets_project ON tickets(project_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_tickets_epic ON tickets(epic_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_tickets_assignee ON tickets(assignee_id)]],
	[[CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status)]],
	[[CREATE INDEX IF NOT EXISTS idx_tickets_parent ON tickets(parent_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_ticket_sprints_sprint ON ticket_sprints(sprint_id)]],
	[[CREATE INDEX IF NOT EXISTS idx_ticket_sprints_ticket ON ticket_sprints(ticket_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_issue_links_source ON issue_links(source_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_issue_links_target ON issue_links(target_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_comments_ticket ON comments(ticket_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_comments_latest ON comments(is_latest) WHERE is_latest = 1]],
	[[CREATE INDEX IF NOT EXISTS idx_status_changes_ticket ON status_changes(ticket_key)]],
	[[CREATE INDEX IF NOT EXISTS idx_status_changes_date ON status_changes(changed_date)]],
}

-- Get all table creation statements
function M.get_create_statements()
	local statements = {}
	for _, sql in pairs(CREATE_STATEMENTS) do
		table.insert(statements, sql)
	end
	return statements
end

-- Get all index creation statements
function M.get_index_statements()
	return INDEX_STATEMENTS
end

-- Get table names
function M.get_table_names()
	local names = {}
	for name, _ in pairs(CREATE_STATEMENTS) do
		table.insert(names, name)
	end
	return names
end

-- Get index names (extracted from CREATE INDEX statements)
function M.get_index_names()
	local names = {}
	for _, sql in ipairs(INDEX_STATEMENTS) do
		local name = sql:match("CREATE INDEX IF NOT EXISTS (%w+)")
		if name then
			table.insert(names, name)
		end
	end
	return names
end

-- Get specific table creation statement
function M.get_table_create_statement(table_name)
	return CREATE_STATEMENTS[table_name]
end

-- Get specific index creation statement by name
function M.get_index_create_statement(index_name)
	for _, sql in ipairs(INDEX_STATEMENTS) do
		if sql:match("CREATE INDEX IF NOT EXISTS " .. index_name) then
			return sql
		end
	end
	return nil
end

return M
