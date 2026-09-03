-- orbit.nvim - main entrypoint module
--
-- This file (lua/orbit/init.lua) is the *public API* of the plugin. It is the
-- module users get back when they call `require("orbit")`, and it is where
-- `require("orbit").setup(...)` lives. Everything a user does to configure
-- orbit.nvim from their own Neovim config goes through this module.
--
-- Typical user config looks like:
--
--     require("orbit").setup({
--         keymaps = { execute = "<leader>e" },
--         winbar = true,
--     })
--
-- `setup()` is safe to call more than once (e.g. if a user's config is
-- re-sourced) - see the comments on `M.setup` below for exactly what is
-- one-time vs. what is re-applied on every call.
--
-- This module does not implement SQL execution, connection handling, the
-- results grid, the workspace sidebar, or completion itself. Instead it acts
-- as a coordinator/"glue" layer: it owns the shared `M.config` table, wires
-- up Neovim user commands (`:OrbitExecute`, `:OrbitWorkspace`, etc.),
-- keymaps, autocommands, and highlight groups, and then delegates the actual
-- work to other `orbit.*` modules via `require(...)`, passing `M.config`
-- along so those modules know how the user wants things to behave. Based on
-- what this file requires and calls, the other modules it coordinates are:
--
--   * orbit.query      - runs/cancels SQL statements against a buffer's bound
--                         connection profile, reports buffer status, and lets
--                         a buffer bind/select a profile.
--   * orbit.workspace   - the sidebar UI (browsing profiles/schemas/saved
--                          queries) shown by `:OrbitWorkspace`.
--   * orbit.profiles    - reads/writes/validates the profiles.json file that
--                          stores saved database connection profiles.
--   * orbit.completion  - SQL omnifunc/completion-source logic, attached to
--                          SQL buffers when `M.config.completion` is enabled.
--
-- M.config fields (all of these have defaults below and can be overridden by
-- the table passed to `setup()`):
--   completion              - boolean; whether to attach orbit's completion
--                              source to SQL buffers.
--   confirm_mutations       - boolean; whether statements that look like they
--                              mutate data (INSERT/UPDATE/DELETE/etc.) should
--                              prompt for confirmation before running.
--   focus_results           - boolean; whether the results window should be
--                              focused automatically after a query runs.
--   max_cell_width          - number; max width (in columns) for a single
--                              cell when rendering the results grid.
--   keymaps                 - table mapping action names ("cancel",
--                              "execute", "select_profile", "workspace") to
--                              the key sequence that should trigger the
--                              matching `:Orbit*` command. Any action can be
--                              set to a non-string (or removed) to disable
--                              that particular mapping.
--   icons                   - table of icon strings used when rendering the
--                              workspace sidebar (folders, tables, columns,
--                              etc).
--   profile_path            - string; filesystem path to the JSON file where
--                              connection profiles are stored.
--   result_height           - number; height (in rows) of the results
--                              window.
--   result_limit            - number; max number of rows fetched/shown for a
--                              query result.
--   saved_query_dirs        - array of `{ [name] = path }` single-entry
--                              tables describing named directories of saved
--                              `.sql` files shown in the workspace sidebar.
--                              Normalized/validated by `setup()` - see
--                              `normalize_saved_query_dirs` below.
--   winbar                  - boolean; whether SQL buffers should show
--                              orbit's status winbar (connection/profile
--                              info) at the top of the window.
--   workspace_result_ratio  - number (0-1); fraction of the workspace
--                              tabpage's height given to a results window
--                              versus the main sidebar/query area.
--   workspace_sidebar_width - number; width (in columns) of the workspace
--                              sidebar window.
--
-- Note: an old `default_profile` option and a `saved_query_dir` (singular)
-- option existed in earlier versions of orbit.nvim. `saved_query_dir` is now
-- a hard error (renamed to `saved_query_dirs`), and `default_profile` is
-- accepted but ignored with a one-time warning - see `M.setup` below.

local M = {}
-- Expression used as `vim.wo.winbar` for SQL buffers when `M.config.winbar`
-- is enabled. `luaeval(...)` is a Vimscript function that evaluates a Lua
-- expression and converts the result to a Vim value; embedding it in a
-- winbar string means Neovim re-evaluates `require('orbit').status()` (see
-- `M.status` below) every time the winbar is redrawn, so the winbar always
-- shows live status text without orbit having to manually refresh it.
local status_winbar = "%{luaeval(\"require('orbit').status()\")}"

-- Default configuration. `setup()` deep-merges the user's options on top of
-- this table (see `M.setup`), so any field a user does not override keeps
-- its default value here. This table is also the *live* config object that
-- gets read by every other orbit module (they are handed `M.config`
-- directly, not a copy), so mutating fields on `M.config` after setup takes
-- effect immediately for anything that reads it afterwards.
M.config = {
	completion = true,
	confirm_mutations = true,
	focus_results = false,
	max_cell_width = 48,
	keymaps = {
		cancel = "<leader>X",
		execute = "<leader>E",
		select_profile = "<leader>P",
		workspace = "<leader>D",
	},
	icons = {
		collapsed = ">",
		column = "󰠵",
		expanded = "󰘖",
		folder = "󰉋",
		index = "",
		key = "",
		profile = "󰆼",
		query = "󰆋",
		result = "󰎟",
		saved_query = "󰆼",
		table = "󰓫",
		view = "󰈈",
		workspace = "󱓞",
	},
	profile_path = vim.fn.expand("~/.local/share/orbit.nvim/profiles.json"),
	result_height = 15,
	result_limit = 200,
	saved_query_dirs = {},
	winbar = false,
	workspace_result_ratio = 0.30,
	workspace_sidebar_width = 32,
}

-- `configured` tracks whether `M.setup` has already run its one-time setup
-- (registering `:Orbit*` user commands and autocommands). Those must only be
-- created once even if `setup()` is called again, otherwise Neovim would
-- accumulate duplicate commands/autocommand groups on every re-source of the
-- user's config.
local configured = false
-- `default_profile_warned` ensures the removed-option warning notification
-- (see `M.setup`) is only shown the first time a user passes the old
-- `default_profile` option, instead of nagging on every `setup()` call.
local default_profile_warned = false
-- Tracks the key sequence (if any) currently bound to `:OrbitWorkspace` via
-- `apply_workspace_keymap`, so that a later call to `setup()` with a
-- different/absent `keymaps.workspace` value can clean up the previous
-- mapping instead of leaving a stale one behind.
local workspace_mapping = nil

-- Validates and normalizes the user-supplied `saved_query_dirs` option into
-- a plain array of `{ name = ..., path = ... }` tables.
-- Parameters:
--   value - whatever the user passed as `options.saved_query_dirs` to
--           `setup()`. Expected shape: an array (list) of small tables, each
--           with exactly one key/value pair, e.g. `{ work = "~/sql/work" }`.
-- Returns: an array of `{ name = <string>, path = <absolute normalized
--          string> }` tables, one per input entry, in the same order.
-- Side effects: none (pure function) other than raising a Lua `error()` if
-- the input is malformed. Errors use level `3` so the reported source
-- location points at the caller of `setup()` (the user's config), which is
-- more useful to them than pointing inside this helper.
local function normalize_saved_query_dirs(value)
	if type(value) ~= "table" or not vim.islist(value) then
		error("saved_query_dirs must be an array", 3)
	end

	local locations = {}
	-- Used below to detect duplicate names/paths across entries.
	local names = {}
	local paths = {}
	for index, entry in ipairs(value) do
		if type(entry) ~= "table" then
			error(string.format("saved_query_dirs[%d] must be an object with one name and path", index), 3)
		end
		local name, path
		local count = 0
		-- Each entry is expected to be a single-key table like `{ work = "~/sql" }`.
		-- Looping over `pairs` and counting keys is how we both extract the
		-- one name/path pair *and* detect if the user accidentally supplied
		-- more than one key in the same entry.
		for key, entry_path in pairs(entry) do
			name, path = key, entry_path
			count = count + 1
		end
		if count ~= 1 or type(name) ~= "string" or name == "" or type(path) ~= "string" or path == "" then
			error(string.format("saved_query_dirs[%d] must contain one non-empty string name and path", index), 3)
		end
		-- `vim.fn.expand` resolves `~` and environment variables in the path,
		-- `vim.fn.fnamemodify(..., ":p")` turns it into a full absolute path,
		-- and `vim.fs.normalize` cleans up separators/redundant segments so
		-- that two different-looking paths to the same directory compare
		-- equal below.
		path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
		-- Reject duplicate names/paths early so the workspace sidebar never
		-- has to deal with ambiguous saved-query locations.
		if names[name] then
			error("saved_query_dirs contains duplicate name: " .. name, 3)
		end
		if paths[path] then
			error("saved_query_dirs contains duplicate path: " .. path, 3)
		end
		names[name] = true
		paths[path] = true
		table.insert(locations, { name = name, path = path })
	end
	return locations
end

-- Converts a Neovim user-command "command table" (the argument Neovim passes
-- to a user command's callback when it was declared with `range = true`)
-- into the plain `{ start_row, end_row }` shape that `orbit.query.execute`
-- expects for an explicit selection.
-- Parameters:
--   command - the table Neovim hands to a `nvim_create_user_command`
--             callback. `command.range` is `0` when the command was invoked
--             without a range (e.g. plain `:OrbitExecute`), `1` for a single
--             line, or `2` for a `line1,line2` range. `command.line1`/
--             `command.line2` are the (inclusive, 1-based) start/end buffer
--             lines of that range.
-- Returns: `nil` if no range was given (meaning "run the statement under the
--          cursor" is left up to `orbit.query.execute`), otherwise a table
--          `{ start_row = command.line1, end_row = command.line2 }`.
-- Side effects: none.
local function visual_selection(command)
	-- Ex command ranges are inclusive, 1-based buffer rows, matching statements.target's contract.
	if command.range == 0 then
		return nil
	end
	return { start_row = command.line1, end_row = command.line2 }
end

-- Registers all of orbit's `:Orbit*` user commands with Neovim.
-- `vim.api.nvim_create_user_command(name, callback, opts)` is the Neovim API
-- for defining a new Ex command; `callback` runs whenever the user types
-- `:Name` (or maps a key to it), and `opts` configures things like whether
-- it accepts a range (`range = true`) and its help description (`desc`).
-- Parameters: none.
-- Returns: nothing.
-- Side effects: creates the `OrbitExecute`, `OrbitCancel`, `OrbitDisconnect`,
-- `OrbitSelectProfile`, `OrbitProfile`, `OrbitProfiles`, `OrbitWorkspace`,
-- and `OrbitWorkspaceClose` user commands. Called once from `M.setup` (via
-- `configure_ux`), guarded by the `configured` flag, so calling `setup()`
-- again does not try to redefine these commands.
local function create_commands()
	local query = require("orbit.query")
	local workspace = require("orbit.workspace")

	vim.api.nvim_create_user_command("OrbitExecute", function(command)
		query.execute(vim.api.nvim_get_current_buf(), M.config, visual_selection(command))
	end, { range = true, desc = "Execute the selected Orbit statement" })
	vim.api.nvim_create_user_command("OrbitCancel", function()
		query.cancel(vim.api.nvim_get_current_buf())
	end, { desc = "Cancel the current Orbit statement" })
	vim.api.nvim_create_user_command("OrbitDisconnect", function()
		query.disconnect(vim.api.nvim_get_current_buf())
	end, { desc = "Close the current Orbit connection" })
	vim.api.nvim_create_user_command("OrbitSelectProfile", function()
		query.select_profile(vim.api.nvim_get_current_buf(), M.config)
	end, { desc = "Select the Orbit profile for this buffer" })
	vim.api.nvim_create_user_command("OrbitProfile", function()
		query.select_profile(vim.api.nvim_get_current_buf(), M.config)
	end, { desc = "Search and bind an Orbit profile" })
	vim.api.nvim_create_user_command("OrbitProfiles", function()
		local profiles = require("orbit.profiles")
		local ok, err = profiles.ensure(M.config.profile_path)
		if not ok then
			vim.notify(err, vim.log.levels.ERROR)
			return
		end
		vim.cmd.edit(M.config.profile_path)
	end, { desc = "Edit Orbit connection profiles" })
	vim.api.nvim_create_user_command("OrbitWorkspace", function()
		workspace.open(M.config)
	end, { desc = "Open Orbit workspace" })
	vim.api.nvim_create_user_command("OrbitWorkspaceClose", function()
		workspace.close()
	end, { desc = "Close Orbit workspace" })
end

-- Defines (or re-defines) orbit's highlight groups by linking each one to a
-- sensible builtin/theme highlight group, so orbit's UI (errors, headers,
-- hints, nulls in results, profile/column/table/view names, etc.) picks up
-- colors from whatever colorscheme the user has active.
-- `vim.api.nvim_set_hl(namespace, name, opts)` defines a highlight group;
-- namespace `0` means "the global highlight namespace". `link = target`
-- makes `name` visually identical to `target`, and `default = true` means
-- this link only takes effect if the user (or their colorscheme) hasn't
-- already defined that group themselves - so orbit's defaults never
-- override a user's own customization.
-- Parameters: none.
-- Returns: nothing.
-- Side effects: calls `vim.api.nvim_set_hl` for every group in `links`.
-- Registered to run once at setup time and again on every `ColorScheme`
-- autocommand (see `configure_ux`), since switching colorschemes can clear
-- previously linked groups.
local function define_highlights()
	local links = {
		OrbitError = "DiagnosticError",
		OrbitHeader = "Title",
		OrbitHint = "Comment",
		OrbitLoading = "Comment",
		OrbitNull = "Special",
		OrbitProfile = "Identifier",
		OrbitColumn = "Type",
		OrbitTable = "Function",
		OrbitView = "Constant",
	}
	for group, target in pairs(links) do
		vim.api.nvim_set_hl(0, group, { default = true, link = target })
	end
end

-- Sets up orbit's buffer-local keymaps (cancel/execute/select_profile/
-- workspace) on a single SQL buffer, based on the key sequences configured
-- in `M.config.keymaps`.
-- Parameters:
--   buffer - the buffer number (as returned by e.g.
--            `vim.api.nvim_get_current_buf()`) to attach the keymaps to.
-- Returns: nothing.
-- Side effects: calls `vim.keymap.set` to create buffer-local normal-mode
-- (and, for "execute", visual-mode) mappings that run the matching
-- `:Orbit*` command; sets the buffer-local variable `vim.b[buffer].
-- orbit_keymaps = true` as a marker so this never runs twice for the same
-- buffer.
local function apply_keymaps(buffer)
	local keymaps = M.config.keymaps
	-- Do not duplicate buffer-local mappings when setup or FileType runs again.
	if type(keymaps) ~= "table" or vim.b[buffer].orbit_keymaps then
		return
	end
	-- Maps each configurable "action" name to the Ex command it should run.
	local commands = {
		cancel = "OrbitCancel",
		execute = "OrbitExecute",
		select_profile = "OrbitSelectProfile",
		workspace = "OrbitWorkspace",
	}
	for action, lhs in pairs(keymaps) do
		local command = commands[action]
		-- Only wire up actions we recognize, and only when the user gave an
		-- actual key-sequence string (a user can disable a default mapping
		-- by setting its value to `false` or removing it).
		if command and type(lhs) == "string" then
			local options = {
				buffer = buffer,
				desc = "Orbit " .. action:gsub("_", " "),
				silent = true,
			}
			-- Normal-mode mapping: `<Cmd>...<CR>` runs the Ex command without
			-- moving the cursor or triggering other side effects a literal
			-- `:` + Enter might.
			vim.keymap.set("n", lhs, "<Cmd>" .. command .. "<CR>", options)
			if action == "execute" then
				-- Visual execution passes the selected line range through the Ex command.
				vim.keymap.set("x", lhs, ":<C-u>'<,'>" .. command .. "<CR>", options)
			end
		end
	end
	vim.b[buffer].orbit_keymaps = true
end

-- Attaches orbit's SQL completion source to a buffer, if completion is
-- enabled and the buffer already has a profile bound to it.
-- Parameters:
--   buffer - the buffer number to attach completion to.
-- Returns: nothing.
-- Side effects: delegates to `require("orbit.completion").attach(buffer)`,
-- which is responsible for actually wiring up the buffer's completion
-- source/omnifunc. `vim.b[buffer].orbit_profile` is set elsewhere (by
-- `orbit.query`) once a connection profile has been bound to the buffer;
-- until then completion is skipped since there is no schema to complete
-- against.
local function apply_completion(buffer)
	if M.config.completion and vim.b[buffer].orbit_profile then
		require("orbit.completion").attach(buffer)
	end
end

-- One-time initialization of orbit's "ambient" editor UX: highlight groups
-- plus the autocommands that keep keymaps/completion/winbar applied to SQL
-- buffers as the user opens new ones or switches colorschemes.
-- `vim.api.nvim_create_autocmd(event, opts)` registers a callback to run
-- whenever the given Neovim event fires; `opts.group` (created via
-- `vim.api.nvim_create_augroup(name, { clear = true })`) namespaces the
-- autocommand so re-running this function would replace rather than
-- duplicate it (`clear = true` wipes any previous autocommands in that
-- group first). `opts.pattern` restricts the autocommand to matching
-- values (here, the `FileType` event only fires this callback for the
-- `sql` filetype).
-- Parameters: none.
-- Returns: nothing.
-- Side effects:
--   * Calls `define_highlights()` immediately.
--   * Creates the `OrbitHighlights` augroup/autocmd, which re-applies
--     highlight links whenever the user's colorscheme changes.
--   * Creates the `OrbitKeymaps` augroup/autocmd, which applies buffer-local
--     keymaps, completion, and (if enabled) the winbar to any buffer as soon
--     as its filetype becomes `sql`.
--   * Creates the `OrbitWinbar` augroup/autocmd, which (re)applies the
--     winbar expression whenever the user enters a window showing a `sql`
--     buffer - this covers windows/splits that existed before `winbar` was
--     turned on, or before the `FileType` event had a chance to fire.
-- Called once from `M.setup`, guarded by the `configured` flag.
local function configure_ux()
	define_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("OrbitHighlights", { clear = true }),
		callback = define_highlights,
	})
	vim.api.nvim_create_autocmd("FileType", {
		group = vim.api.nvim_create_augroup("OrbitKeymaps", { clear = true }),
		pattern = "sql",
		callback = function(event)
			apply_keymaps(event.buf)
			apply_completion(event.buf)
			if M.config.winbar then
				-- `vim.wo` is the window-local options table for the
				-- *current* window; since this callback runs for the
				-- `FileType` event on the buffer being entered/loaded, the
				-- current window is the one showing it.
				vim.wo.winbar = status_winbar
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinEnter", {
		group = vim.api.nvim_create_augroup("OrbitWinbar", { clear = true }),
		callback = function()
			if M.config.winbar and vim.bo.filetype == "sql" then
				vim.wo.winbar = status_winbar
			end
		end,
	})
end

-- Re-applies keymaps/completion/winbar to every *currently open* SQL buffer
-- (and, for the winbar, every window currently showing one). This is needed
-- because `configure_ux`'s `FileType` autocommand only fires for buffers
-- opened/re-typed *after* it is registered - buffers that were already open
-- SQL files before `setup()` ran (or before `winbar`/`keymaps` changed on a
-- later `setup()` call) need to be updated explicitly.
-- Parameters: none.
-- Returns: nothing.
-- Side effects: for each loaded buffer whose filetype is `sql`, calls
-- `apply_keymaps` and `apply_completion`; if `M.config.winbar` is enabled,
-- also sets `winbar` on every window currently displaying that buffer via
-- `vim.fn.win_findbuf(buffer)` (a Vim function that returns the list of
-- window IDs showing a given buffer).
local function apply_ux_to_buffers()
	for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[buffer].filetype == "sql" then
			apply_keymaps(buffer)
			apply_completion(buffer)
			if M.config.winbar then
				for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
					vim.wo[window].winbar = status_winbar
				end
			end
		end
	end
end

-- Applies (or removes) the single *global* normal-mode keymap for
-- `:OrbitWorkspace`, based on `M.config.keymaps.workspace`. This is separate
-- from `apply_keymaps` because the workspace toggle is meant to work from
-- any buffer (not just SQL ones), so it is a global mapping rather than a
-- buffer-local one, and therefore needs its own bookkeeping
-- (`workspace_mapping`) to avoid leaving stale global mappings behind when
-- the user changes or removes this option across `setup()` calls.
-- Parameters: none.
-- Returns: nothing.
-- Side effects: may call `vim.keymap.set`/`vim.keymap.del` (wrapped in
-- `pcall` so deleting a mapping that no longer exists cannot error) and
-- updates the module-local `workspace_mapping` variable to track the
-- currently-active key sequence.
local function apply_workspace_keymap()
	local keymaps = M.config.keymaps
	if type(keymaps) == "table" and type(keymaps.workspace) == "string" then
		-- Reconfiguration must not leave the previous global mapping behind.
		if workspace_mapping and workspace_mapping ~= keymaps.workspace then
			pcall(vim.keymap.del, "n", workspace_mapping)
		end
		vim.keymap.set("n", keymaps.workspace, "<Cmd>OrbitWorkspace<CR>", {
			desc = "Orbit workspace",
			silent = true,
		})
		workspace_mapping = keymaps.workspace
	elseif workspace_mapping then
		-- The user removed/disabled the workspace keymap on this setup()
		-- call; clean up the previously-registered global mapping.
		pcall(vim.keymap.del, "n", workspace_mapping)
		workspace_mapping = nil
	end
end

-- The plugin's public entrypoint. Users call this from their Neovim config
-- (typically once, e.g. inside a `lazy.nvim`/`packer` plugin spec's
-- `config = function() require("orbit").setup({ ... }) end`) to configure
-- and activate orbit.nvim. It is also safe to call again later (e.g. to
-- change options at runtime), which is why it carefully separates "do this
-- only the very first time" logic from "always re-apply this" logic.
-- Parameters:
--   options - an optional table of config overrides, using the same field
--             names documented in the `M.config` comment near the top of
--             this file (e.g. `{ winbar = true, keymaps = { execute =
--             "<leader>e" } }`). May be `nil` to just (re-)apply the current
--             `M.config` as-is.
-- Returns: nothing.
-- Side effects (see inline comments below for details):
--   * May raise an error if a removed option is used.
--   * May show a one-time `vim.notify` warning for another removed option.
--   * Merges `options` into `M.config` (mutating the module's shared config
--     table that every other orbit module reads).
--   * On the first call only: defines the global `_G.OrbitComplete`
--     function (Vim's classic `omnifunc`/completion mechanism looks up
--     completion functions by *global* function name, so orbit has to
--     expose one even though the actual logic lives in `orbit.completion`),
--     registers all `:Orbit*` user commands, and sets up highlight groups +
--     autocommands.
--   * On every call: re-applies keymaps/completion/winbar to already-open
--     SQL buffers, and (re)applies the global workspace keymap.
function M.setup(options)
	-- `saved_query_dir` (singular) was replaced by `saved_query_dirs`
	-- (plural, supports multiple named directories). Rather than silently
	-- ignoring it or guessing what the user meant, fail loudly so old
	-- configs get fixed instead of quietly losing this feature.
	if options and options.saved_query_dir ~= nil then
		error("saved_query_dir was removed; use saved_query_dirs", 2)
	end
	-- `default_profile` used to let a single profile apply to all buffers;
	-- it was removed in favor of explicitly binding a profile per buffer.
	-- This is only a warning (not an error) since the option can simply be
	-- dropped without breaking anything, and the warning is only shown once
	-- per Neovim session so it doesn't nag on every `setup()` re-run.
	if options and options.default_profile and not default_profile_warned then
		vim.notify(
			"Orbit removed default_profile; bind each query buffer explicitly",
			vim.log.levels.WARN,
			{ title = "Orbit" }
		)
		default_profile_warned = true
	end
	-- Deep-copy the user's options table so later mutations below (e.g.
	-- clearing `options.saved_query_dirs`) never affect a table the caller
	-- might still hold a reference to.
	options = vim.deepcopy(options or {})
	local saved_query_dirs
	if options.saved_query_dirs ~= nil then
		-- Validate/normalize separately, then remove it from `options`
		-- before the generic merge below, because `saved_query_dirs` needs
		-- list-replace semantics (handled explicitly further down) rather
		-- than the deep-merge behavior `vim.tbl_deep_extend` would apply to
		-- a plain field.
		saved_query_dirs = normalize_saved_query_dirs(options.saved_query_dirs)
		options.saved_query_dirs = nil
	end
	-- `vim.tbl_deep_extend("force", M.config, options)` recursively merges
	-- `options` on top of the existing `M.config`, with `options`'s values
	-- winning on conflicts ("force"). This means a user can override just
	-- `keymaps.execute` without having to re-specify every other keymap or
	-- config field - anything they don't mention keeps its previous value.
	M.config = vim.tbl_deep_extend("force", M.config, options)
	if saved_query_dirs then
		-- Lists replace previous setup values instead of being merged index by index.
		M.config.saved_query_dirs = saved_query_dirs
	end
	-- Always scrub this out, even though it's deprecated/ignored above - it
	-- must never linger in `M.config` where other modules might see it.
	M.config.default_profile = nil
	if not configured then
		-- Commands and autocommands are registered once; current SQL buffers are updated below.
		_G.OrbitComplete = function(findstart, base)
			return require("orbit.completion").omnifunc(findstart, base)
		end
		create_commands()
		configure_ux()
		configured = true
	end
	apply_ux_to_buffers()
	apply_workspace_keymap()
end

-- Returns a short status string for a buffer, used as the content of
-- orbit's winbar (see `status_winbar` near the top of this file, which
-- calls this function through `luaeval`). Also usable directly by other
-- code/UI that wants to display a buffer's current orbit status (e.g. bound
-- profile, connection state).
-- Parameters:
--   buffer - optional buffer number to report status for; defaults to the
--            current buffer (`vim.api.nvim_get_current_buf()`) when omitted.
-- Returns: whatever `orbit.query.status(buffer, config)` returns - a string
-- describing the buffer's current profile/connection status.
-- Side effects: none beyond the underlying `orbit.query.status` call
-- (delegates entirely; does not itself mutate any state).
function M.status(buffer)
	return require("orbit.query").status(buffer or vim.api.nvim_get_current_buf(), M.config)
end

return M
