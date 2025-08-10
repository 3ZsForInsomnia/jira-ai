# File Picking and Browsing

Jira AI provides flexible file browsing capabilities through a modular picker system. Telescope is now optional, and you can use the built-in vim.ui.select picker or integrate with any picker you prefer.

## Built-in Commands

These commands work out of the box using vim.ui.select:

- `:JiraAIBrowse` - Browse all Jira AI files
- `:JiraAIBrowseSnapshots` - Browse snapshot files
- `:JiraAIBrowseAttention` - Browse attention item files  
- `:JiraAIBrowseEpics` - Browse epic story map files
- `:JiraAIBrowseUserStats` - Browse user stats files

## Telescope Extension (Optional)

For a better browsing experience with previews and advanced filtering, install the optional Telescope extension:

### Installation

Add the telescope extension to your Telescope setup:

```lua
require('telescope').load_extension('jira_ai')
```

### Usage

Once loaded, you can use these telescope commands:

```vim
" Direct telescope commands (auto-registered when extension loads)
:TelescopeJiraAIBrowse
:TelescopeJiraAISnapshots
:TelescopeJiraAIAttention
:TelescopeJiraAIEpics
:TelescopeJiraAIUserStats
```

Or use the telescope command interface:

```lua
:Telescope jira_ai browse_all
:Telescope jira_ai browse_snapshots
:Telescope jira_ai browse_attention
:Telescope jira_ai browse_epics
:Telescope jira_ai browse_user_stats
```

## Custom Picker Integration

You can create your own picker integration using the `picker_utils` module:

### Basic Usage

```lua
local picker_utils = require("jira_ai.picker_utils")

-- Get all files formatted for display
local files = picker_utils.get_all_files_for_picker()

-- Get files by type
local snapshots = picker_utils.get_files_by_type_for_picker("snapshots")

-- Open a file
picker_utils.open_file("/path/to/file.md")
```

### Available Functions

- `get_all_files_for_picker()` - Returns all files formatted for picker display
- `get_files_by_type_for_picker(type)` - Returns files of specific type formatted for picker display
- `format_file_entry(file)` - Formats a single file entry for display
- `open_file(path)` - Opens a file in the editor
- `simple_picker(items, opts, callback)` - Basic vim.ui.select picker

### File Entry Format

Each file entry contains:

```lua
{
  display = "[snapshots] PROJECT-20241201-14.md",  -- Formatted display string
  path = "/full/path/to/file.md",                  -- Full file path
  name = "PROJECT-20241201-14.md",                 -- File name
  type = "snapshots",                              -- File type/category
  mtime = 1701435600                               -- Modification time (unix timestamp)
}
```

### Example: FZF Integration

See help documentation for examples of integrating with other picker frameworks.

## File Types

The following file types are available:

- `snapshots` - Sprint status snapshots
- `attention` - Attention items reports
- `epics` - Epic story maps
- `user-stats` - User statistics reports

Each type corresponds to a subdirectory in your configured output directory.