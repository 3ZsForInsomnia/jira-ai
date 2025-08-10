local files = require("jira_ai.files")

local M = {}

-- Format a file entry for display
function M.format_file_entry(file)
	return {
		display = string.format("[%s/%s] %s", file.project or "unknown", file.type, file.name),
		path = file.path,
		name = file.name,
		project = file.project,
		type = file.type,
		mtime = file.mtime,
	}
end

-- Get all files formatted for picker display
function M.get_all_files_for_picker()
	local all_files = files.get_all_files()
	local formatted = {}
	for _, file in ipairs(all_files) do
		table.insert(formatted, M.format_file_entry(file))
	end
	return formatted
end

-- Get files by type formatted for picker display
function M.get_files_by_type_for_picker(output_type)
	local type_files = files.get_files_by_type(output_type)
	local formatted = {}
	for _, file in ipairs(type_files) do
		table.insert(formatted, M.format_file_entry(file))
	end
	return formatted
end

-- Get files by project formatted for picker display
function M.get_files_by_project_for_picker(project)
	local project_files = files.get_files_by_project(project)
	local formatted = {}
	for _, file in ipairs(project_files) do
		table.insert(formatted, M.format_file_entry(file))
	end
	return formatted
end

-- Get files by project and type formatted for picker display
function M.get_files_by_project_and_type_for_picker(project, output_type)
	local project_type_files = files.get_files_by_project_and_type(project, output_type)
	local formatted = {}
	for _, file in ipairs(project_type_files) do
		table.insert(formatted, M.format_file_entry(file))
	end
	return formatted
end

-- Open file in editor
function M.open_file(file_path)
	vim.cmd("edit " .. file_path)
end

-- Simple vim.ui.select based picker fallback
function M.simple_picker(items, opts, on_choice)
	opts = opts or {}
	local title = opts.prompt or "Select file"

	if #items == 0 then
		vim.notify(opts.empty_message or "No files found", vim.log.levels.INFO)
		return
	end

	local choices = {}
	for _, item in ipairs(items) do
		table.insert(choices, item.display)
	end

	vim.ui.select(choices, {
		prompt = title .. ":",
		format_item = function(item)
			return item
		end,
	}, function(choice, idx)
		if choice and idx then
			on_choice(items[idx])
		end
	end)
end

-- Project selector with callback
function M.select_project(callback, opts)
	opts = opts or {}
	local configured_projects = files.get_configured_projects()
	local projects_with_files = files.get_projects_with_files()

	-- Combine configured projects with projects that have files, prioritizing configured ones
	local all_projects = {}
	local seen = {}

	-- Add configured projects first
	for _, project in ipairs(configured_projects) do
		table.insert(all_projects, project)
		seen[project] = true
	end

	-- Add projects with files that aren't configured
	for _, project in ipairs(projects_with_files) do
		if not seen[project] then
			table.insert(all_projects, project)
		end
	end

	if #all_projects == 0 then
		vim.notify("No projects found", vim.log.levels.INFO)
		return
	end

	vim.ui.select(all_projects, {
		prompt = opts.prompt or "Select project:",
		format_item = function(project)
			local is_configured = vim.tbl_contains(configured_projects, project)
			local has_files = vim.tbl_contains(projects_with_files, project)
			local suffix = ""
			if is_configured and has_files then
				suffix = " ✓"
			elseif is_configured then
				suffix = " (configured)"
			elseif has_files then
				suffix = " (has files)"
			end
			return project .. suffix
		end,
	}, function(choice)
		if choice then
			callback(choice)
		end
	end)
end

-- Browse all files with simple picker
function M.browse_all_files(project)
	if project then
		local items = M.get_files_by_project_for_picker(project)
		M.simple_picker(items, {
			prompt = "Jira AI Files for " .. project,
			empty_message = "No files found for " .. project,
		}, function(selected)
			M.open_file(selected.path)
		end)
	else
		M.select_project(function(selected_project)
			M.browse_all_files(selected_project)
		end, { prompt = "Select project to browse files" })
	end
end

-- Browse snapshots with simple picker
function M.browse_snapshots(project)
	if project then
		local items = M.get_files_by_project_and_type_for_picker(project, "snapshots")
		M.simple_picker(items, {
			prompt = "Jira AI Snapshots for " .. project,
			empty_message = "No snapshot files found for " .. project,
		}, function(selected)
			M.open_file(selected.path)
		end)
	else
		M.select_project(function(selected_project)
			M.browse_snapshots(selected_project)
		end, { prompt = "Select project to browse snapshots" })
	end
end

-- Browse attention items with simple picker
function M.browse_attention(project)
	if project then
		local items = M.get_files_by_project_and_type_for_picker(project, "needs-attention")
		M.simple_picker(items, {
			prompt = "Jira AI Attention Items for " .. project,
			empty_message = "No attention files found for " .. project,
		}, function(selected)
			M.open_file(selected.path)
		end)
	else
		M.select_project(function(selected_project)
			M.browse_attention(selected_project)
		end, { prompt = "Select project to browse attention items" })
	end
end

-- Browse epics with simple picker
function M.browse_epics(project)
	if project then
		local items = M.get_files_by_project_and_type_for_picker(project, "epic-maps")
		M.simple_picker(items, {
			prompt = "Jira AI Epic Story Maps for " .. project,
			empty_message = "No epic files found for " .. project,
		}, function(selected)
			M.open_file(selected.path)
		end)
	else
		M.select_project(function(selected_project)
			M.browse_epics(selected_project)
		end, { prompt = "Select project to browse epics" })
	end
end

-- Browse user stats with simple picker
function M.browse_user_stats(project)
	if project then
		local items = M.get_files_by_project_and_type_for_picker(project, "user-stats")
		M.simple_picker(items, {
			prompt = "Jira AI User Stats for " .. project,
			empty_message = "No user stats files found for " .. project,
		}, function(selected)
			M.open_file(selected.path)
		end)
	else
		M.select_project(function(selected_project)
			M.browse_user_stats(selected_project)
		end, { prompt = "Select project to browse user stats" })
	end
end

return M
