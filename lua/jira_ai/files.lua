local M = {}

local function get_xdg_data_home()
	return os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
end

local function get_jira_ai_base_dir()
	local config = require("jira_ai.config").options
	local dir = config.output_dir or (get_xdg_data_home() .. "/nvim/jira-ai")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	return dir
end

function M.get_all_files()
	local base_dir = get_jira_ai_base_dir()
	local files = {}

	-- Get all project directories
	local handle = vim.loop.fs_scandir(base_dir)
	if handle then
		local name, type = vim.loop.fs_scandir_next(handle)
		while name do
			if type == "directory" then
				local project_dir = base_dir .. "/" .. name
				local project_handle = vim.loop.fs_scandir(project_dir)
				if project_handle then
					local type_name, type_type = vim.loop.fs_scandir_next(project_handle)
					while type_name do
						if type_type == "directory" then
							local type_dir = project_dir .. "/" .. type_name
							local type_handle = vim.loop.fs_scandir(type_dir)
							if type_handle then
								local file_name, file_type = vim.loop.fs_scandir_next(type_handle)
								while file_name do
									if file_type == "file" and file_name:match("%.md$") then
										local filepath = type_dir .. "/" .. file_name
										local stat = vim.loop.fs_stat(filepath)
										table.insert(files, {
											path = filepath,
											name = file_name,
											project = name,
											type = type_name,
											mtime = stat.mtime.sec,
										})
									end
									file_name, file_type = vim.loop.fs_scandir_next(type_handle)
								end
							end
						end
						type_name, type_type = vim.loop.fs_scandir_next(project_handle)
					end
				end
			end
			name, type = vim.loop.fs_scandir_next(handle)
		end
	end

	-- Sort by modification time (newest first)
	table.sort(files, function(a, b)
		return a.mtime > b.mtime
	end)
	return files
end

function M.get_files_by_type(output_type)
	local files = M.get_all_files()
	local filtered = {}
	for _, file in ipairs(files) do
		if file.type == output_type then
			table.insert(filtered, file)
		end
	end
	return filtered
end

function M.get_files_by_project(project)
	local files = M.get_all_files()
	local filtered = {}
	for _, file in ipairs(files) do
		if file.project == project then
			table.insert(filtered, file)
		end
	end
	return filtered
end

function M.get_files_by_project_and_type(project, output_type)
	local files = M.get_all_files()
	local filtered = {}
	for _, file in ipairs(files) do
		if file.project == project and file.type == output_type then
			table.insert(filtered, file)
		end
	end
	return filtered
end

function M.get_configured_projects()
	local config = require("jira_ai.config").options
	return config.jira_projects or {}
end

function M.get_projects_with_files()
	local files = M.get_all_files()
	local projects = {}
	local seen = {}
	
	for _, file in ipairs(files) do
		if file.project and not seen[file.project] then
			seen[file.project] = true
			table.insert(projects, file.project)
		end
	end
	
	table.sort(projects)
	return projects
end

function M.get_file_paths()
	local files = M.get_all_files()
	local paths = {}
	for _, file in ipairs(files) do
		table.insert(paths, file.path)
	end
	return paths
end

function M.get_file_paths_by_type(output_type)
	local files = M.get_files_by_type(output_type)
	local paths = {}
	for _, file in ipairs(files) do
		table.insert(paths, file.path)
	end
	return paths
end

return M