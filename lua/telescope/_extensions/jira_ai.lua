local has_telescope = pcall(require, "telescope")
if not has_telescope then
	error("This extension requires telescope.nvim")
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local picker_utils = require("jira_ai.picker_utils")

local function show_files_with_telescope(files, title, project)
	local prompt_title = title
	if project then
		prompt_title = title .. " - " .. project
	end
	
	pickers
		.new({}, {
			prompt_title = prompt_title,
			finder = finders.new_table({
				results = files,
				entry_maker = function(entry)
					-- Files are already formatted by picker_utils
					return {
						value = entry,
						display = entry.display,
						ordinal = entry.name,
						path = entry.path,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.cat.new({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						picker_utils.open_file(selection.path)
					end
				end)
				return true
			end,
		})
		:find()
end

local function browse_all_files(project)
	if project then
		local files = picker_utils.get_files_by_project_for_picker(project)
		if #files == 0 then
			vim.notify("No Jira AI files found for " .. project, vim.log.levels.INFO)
			return
		end
		show_files_with_telescope(files, "Jira AI Files", project)
	else
		-- Show project selector using vim.ui.select (telescope will use its UI)
		picker_utils.select_project(function(selected_project)
			browse_all_files(selected_project)
		end, { prompt = "Select project to browse files" })
	end
end

local function browse_snapshots(project)
	if project then
		local files = picker_utils.get_files_by_project_and_type_for_picker(project, "snapshots")
		if #files == 0 then
			vim.notify("No snapshot files found for " .. project, vim.log.levels.INFO)
			return
		end
		show_files_with_telescope(files, "Jira AI Snapshots", project)
	else
		picker_utils.select_project(function(selected_project)
			browse_snapshots(selected_project)
		end, { prompt = "Select project to browse snapshots" })
	end
end

local function browse_attention(project)
	if project then
		local files = picker_utils.get_files_by_project_and_type_for_picker(project, "needs-attention")
		if #files == 0 then
			vim.notify("No attention files found for " .. project, vim.log.levels.INFO)
			return
		end
		show_files_with_telescope(files, "Jira AI Attention Items", project)
	else
		picker_utils.select_project(function(selected_project)
			browse_attention(selected_project)
		end, { prompt = "Select project to browse attention items" })
	end
end

local function browse_epics(project)
	if project then
		local files = picker_utils.get_files_by_project_and_type_for_picker(project, "epic-maps")
		if #files == 0 then
			vim.notify("No epic files found for " .. project, vim.log.levels.INFO)
			return
		end
		show_files_with_telescope(files, "Jira AI Epic Story Maps", project)
	else
		picker_utils.select_project(function(selected_project)
			browse_epics(selected_project)
		end, { prompt = "Select project to browse epics" })
	end
end

local function browse_user_stats(project)
	if project then
		local files = picker_utils.get_files_by_project_and_type_for_picker(project, "user-stats")
		if #files == 0 then
			vim.notify("No user stats files found for " .. project, vim.log.levels.INFO)
			return
		end
		show_files_with_telescope(files, "Jira AI User Stats", project)
	else
		picker_utils.select_project(function(selected_project)
			browse_user_stats(selected_project)
		end, { prompt = "Select project to browse user stats" })
	end
end

return require("telescope").register_extension({
	setup = function(ext_config, config)
		-- Register telescope commands when extension is loaded
		vim.api.nvim_create_user_command("TelescopeJiraAIBrowse", function(opts)
			local project = opts.args ~= "" and opts.args or nil
			browse_all_files(project)
		end, {
			nargs = "?",
			desc = "Browse all Jira AI files with Telescope [project]",
			complete = function()
				return require("jira_ai.files").get_configured_projects()
			end,
		})

		vim.api.nvim_create_user_command("TelescopeJiraAISnapshots", function(opts)
			local project = opts.args ~= "" and opts.args or nil
			browse_snapshots(project)
		end, {
			nargs = "?",
			desc = "Browse Jira AI snapshot files with Telescope [project]",
			complete = function()
				return require("jira_ai.files").get_configured_projects()
			end,
		})

		vim.api.nvim_create_user_command("TelescopeJiraAIAttention", function(opts)
			local project = opts.args ~= "" and opts.args or nil
			browse_attention(project)
		end, {
			nargs = "?",
			desc = "Browse Jira AI attention item files with Telescope [project]",
			complete = function()
				return require("jira_ai.files").get_configured_projects()
			end,
		})

		vim.api.nvim_create_user_command("TelescopeJiraAIEpics", function(opts)
			local project = opts.args ~= "" and opts.args or nil
			browse_epics(project)
		end, {
			nargs = "?",
			desc = "Browse Jira AI epic story map files with Telescope [project]",
			complete = function()
				return require("jira_ai.files").get_configured_projects()
			end,
		})

		vim.api.nvim_create_user_command("TelescopeJiraAIUserStats", function(opts)
			local project = opts.args ~= "" and opts.args or nil
			browse_user_stats(project)
		end, {
			nargs = "?",
			desc = "Browse Jira AI user stats files with Telescope [project]",
			complete = function()
				return require("jira_ai.files").get_configured_projects()
			end,
		})
	end,
	exports = {
		browse_all = browse_all_files,
		browse_snapshots = browse_snapshots,
		browse_attention = browse_attention,
		browse_epics = browse_epics,
		browse_user_stats = browse_user_stats,
	},
})
