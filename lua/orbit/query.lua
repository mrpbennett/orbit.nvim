-- orbit/query.lua
--
-- This module is the "query lifecycle" layer of Orbit. Where lua/orbit/init.lua
-- wires up user commands and keymaps, this module contains the actual logic that
-- runs when a user asks Orbit to execute some SQL.
--
-- In this codebase, a "query" is not a persisted object with its own file or
-- table -- it's the SQL text currently under the cursor/selection in a SQL
-- buffer, plus the runtime state around running it once. Concretely, a query
-- execution involves:
--   * figuring out which connection profile (see lua/orbit/profiles.lua) is
--     bound to the current buffer (M.profile_for_buffer / M.bind_profile),
--   * extracting the SQL text to run from the buffer, either the whole buffer
--     or a visual selection (delegated to require("orbit.statements").target),
--   * choosing where the result goes: the Workspace result window when the
--     buffer lives in a Workspace, otherwise a standalone result window,
--   * handing all of that to Statement execution (require("orbit.execution")),
--     which confirms, locks, runs, cancels, and delivers the result.
--
-- This module exports a single table `M` with the functions below. It does not
-- export any data structures of its own; per-buffer profile bindings live as
-- buffer-local vim variables (vim.b[buffer].orbit_profile), and "is something
-- running in this buffer" lives in Statement execution, keyed by buffer.
local profiles = require("orbit.profiles")
local adapters = require("orbit.adapters")
local execution = require("orbit.execution")
local results = require("orbit.results")
local runner = require("orbit.runner")
local statements = require("orbit.statements")

local M = {}

local function set_buffer_kind(buffer, profile)
	local filetype = profile.kind == "redis" and "redis" or "sql"
	if vim.bo[buffer].filetype ~= filetype then
		-- FileType may have already installed SQL-only mappings on this query
		-- buffer. Let Orbit's autocmd rebuild mappings for the new backend.
		vim.b[buffer].orbit_keymaps = nil
		if filetype == "redis" then
			require("orbit.structure").close_for_buffer(buffer)
			local structure = require("orbit").config.keymaps and require("orbit").config.keymaps.structure
			if type(structure) == "string" then
				for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
					if mapping.rhs == "<Cmd>OrbitStructure<CR>" and mapping.desc == "Orbit structure" then
						pcall(vim.keymap.del, "n", mapping.lhs, { buffer = buffer })
						break
					end
				end
			end
		end
		vim.bo[buffer].filetype = filetype
	end
end

local function set_buffer_dialect(buffer, profile)
	local connector = adapters.connector(profile)
	local dialect = connector and connector.sql_dialect or nil
	if vim.b[buffer].orbit_sql_dialect == dialect then
		return
	end
	vim.b[buffer].orbit_sql_dialect = dialect
	-- Profile edits can change lexical rules without changing the SQL text.
	require("orbit.structure").changed(buffer)
end

-- Looks up which connection profile (see lua/orbit/profiles.lua) is currently
-- bound to a given buffer, loading the profiles file from disk in the
-- process.
--
-- Parameters:
--   buffer (number): a Neovim buffer handle/number, e.g. from
--     vim.api.nvim_get_current_buf().
--   config (table): Orbit's config table (M.config from lua/orbit/init.lua),
--     used here for config.profile_path -- the path to the JSON file that
--     stores all saved connection profiles.
--
-- Returns:
--   On success: the profile table (as decoded from JSON) whose `name` matches
--     the buffer's bound profile.
--   On failure: nil, plus a string describing what went wrong (couldn't load
--     the profiles file, no profile bound to this buffer yet, or the bound
--     profile name doesn't exist in the file anymore).
--
-- Side effects: reads and JSON-decodes the profiles file from disk via
-- profiles.load (file I/O). Also reads vim.b[buffer].orbit_profile, a
-- buffer-local variable that M.bind_profile (below) sets when the user picks
-- a profile for this buffer.
function M.profile_for_buffer(buffer, config)
	local document, load_err = profiles.load(config.profile_path)
	if not document then
		return nil, load_err
	end
	local name = vim.b[buffer].orbit_profile
	if not name then
		return nil, "select a connection profile first"
	end
	local profile = profiles.find(document, name)
	if not profile then
		return nil, string.format("connection profile %q does not exist", name)
	end
	set_buffer_dialect(buffer, profile)
	set_buffer_kind(buffer, profile)
	return profile
end

-- Opens the interactive profile picker (owned by lua/orbit/workspace.lua) so
-- the user can choose which saved connection profile to bind to a buffer.
--
-- Parameters:
--   buffer (number): the buffer the chosen profile will be bound to.
--   config (table): Orbit's config table, forwarded so the picker knows where
--     to load profiles from (config.profile_path) and other UI settings.
--   on_select (function|nil): optional callback invoked once the user has
--     picked a profile. Used by M.execute below to retry execution
--     automatically after the user selects a profile.
--
-- Returns: nothing directly; the actual profile selection happens
-- asynchronously through workspace.select_profile's own UI (e.g. a picker
-- window), and on_select is invoked once that completes.
--
-- Side effects: delegates to require("orbit.workspace").select_profile, which
-- opens Neovim UI (a picker/prompt) and later mutates buffer state (see
-- M.bind_profile) once a choice is made.
function M.select_profile(buffer, config, on_select)
	require("orbit.workspace").select_profile(config, buffer, on_select)
end

-- Binds a connection profile to a buffer, making it "the" profile that
-- OrbitExecute and friends will use for that buffer from now on.
--
-- Parameters:
--   buffer (number): the buffer to bind the profile to.
--   profile (table): a profile table (as returned by profiles.find), must
--     have at least a `name` field.
--
-- Returns: nothing.
--
-- Side effects:
--   * Sets vim.b[buffer].orbit_profile = profile.name -- a buffer-local
--     variable that M.profile_for_buffer (and other Orbit code) reads later
--     to know which profile this buffer is connected to.
--   * If completion is enabled in the global config, "prewarms" the new
--     profile (pre-fetches its schema info in the background) so the first
--     completion request through orbit.blink doesn't have to wait on it.
--   * Calls vim.notify to show the user a short message confirming which
--     profile got bound.
function M.bind_profile(buffer, profile)
	vim.b[buffer].orbit_profile = profile.name
	set_buffer_dialect(buffer, profile)
	set_buffer_kind(buffer, profile)
	if require("orbit").config.completion then
		require("orbit.completion").prewarm(profile)
	end
	vim.notify("Orbit profile: " .. profile.name)
end

-- The main entry point for running a SQL statement: this is what
-- OrbitExecute (wired up in lua/orbit/init.lua) ultimately calls. This
-- function only answers the query-buffer questions -- which profile, which
-- statement, where the result goes -- and then hands the run to Statement
-- execution (lua/orbit/execution.lua), which owns confirmation, the lock,
-- cancellation, feedback, and the Editable target decision.
--
-- Parameters:
--   buffer (number): the buffer containing the SQL to run.
--   config (table): Orbit's config table (M.config from init.lua), used for
--     things like config.confirm_mutations, config.result_height,
--     config.result_limit, config.max_cell_width, config.focus_results, and
--     config.profile_path (indirectly, via M.profile_for_buffer).
--   selection (table|nil): an optional inclusive whole-line range or exact
--     end-exclusive source range. When nil, statements.target considers the
--     whole buffer.
--   context (table|nil): optional source/trigger windows and tabpage when an
--     Orbit panel initiated execution for a separate query buffer.
--
-- Returns: nothing. The database work happens asynchronously.
--
-- Side effects: reads buffer lines and the current window/tabpage; may open
-- the profile picker (and retry once a profile is chosen); starts a
-- Statement execution, which may prompt, notify, and open a result window.
function M.execute(buffer, config, selection, context)
	context = context or {}
	if
		context.source_changedtick
		and (
			not vim.api.nvim_buf_is_valid(buffer)
			or context.source_changedtick ~= vim.api.nvim_buf_get_changedtick(buffer)
		)
	then
		vim.notify("Query buffer changed or closed; select the Structure element again", vim.log.levels.WARN)
		return
	end
	local profile, profile_err = M.profile_for_buffer(buffer, config)
	if not profile then
		-- No profile bound yet (or it's missing/invalid): tell the user, then
		-- open the profile picker and re-run M.execute automatically once they
		-- pick one, so the user doesn't have to press "execute" twice.
		vim.notify(profile_err, vim.log.levels.ERROR)
		M.select_profile(buffer, config, function()
			if
				context.trigger_window
				and vim.api.nvim_win_is_valid(context.trigger_window)
				and context.tabpage
				and vim.api.nvim_tabpage_is_valid(context.tabpage)
			then
				vim.api.nvim_set_current_tabpage(context.tabpage)
				vim.api.nvim_set_current_win(context.trigger_window)
			end
			M.execute(buffer, config, selection, context)
		end)
		return
	end
	local connector = assert(adapters.connector(profile))

	-- Ask the statements module to figure out the actual SQL text to run:
	-- either the given visual selection, or whatever statement the cursor is
	-- currently inside/near, based on the buffer's current lines.
	local statement, statement_err = statements.target({
		lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
		selection = selection,
		dialect = connector.sql_dialect,
		kind = profile.kind,
		row = vim.api.nvim_win_get_cursor(context.source_window and vim.api.nvim_win_is_valid(context.source_window)
			and context.source_window or vim.api.nvim_get_current_win())[1],
	})
	if not statement then
		vim.notify(statement_err, vim.log.levels.ERROR)
		return
	end

	-- Remember which tabpage/window the query was started from: results arrive
	-- asynchronously, by which time the user may have moved elsewhere.
	local tabpage = context.tabpage and vim.api.nvim_tabpage_is_valid(context.tabpage) and context.tabpage
		or vim.api.nvim_get_current_tabpage()
	local window = context.source_window and vim.api.nvim_win_is_valid(context.source_window) and context.source_window
		or vim.api.nvim_get_current_win()
	local file_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":t")

	-- vim.b[buffer].orbit_table is set by the Workspace's "browse table" flow
	-- when this buffer's statement was generated to browse one schema object.
	-- While the statement still matches the generated one (whitespace
	-- trimmed), the result is a table browse and may be editable.
	local browsed = vim.b[buffer].orbit_table
	if not (browsed and vim.trim(statement) == vim.trim(vim.b[buffer].orbit_table_statement or "")) then
		browsed = nil
	end

	-- Results started inside a Workspace return to its result window, even if
	-- focus has moved; otherwise they open a standalone result window.
	local sink = require("orbit.workspace").result_sink(tabpage) or results.sink()
	execution.run({
		key = buffer,
		profile = profile,
		statement = statement,
		confirm_mutations = config.confirm_mutations,
		table = browsed,
		result_options = {
			confirm_mutations = config.confirm_mutations,
			height = config.result_height,
			limit = config.result_limit,
			max_cell_width = config.max_cell_width,
			focus = config.focus_results,
			profile_name = profile.name,
			source_name = browsed and browsed.name or (file_name ~= "" and file_name or "[No Name]"),
			source_window = window,
			tabpage = tabpage,
		},
	}, sink)
end

-- Cancels whatever query is currently running in a buffer, if any. This is
-- what OrbitCancel calls from a query buffer.
--
-- Parameters:
--   buffer (number): the buffer whose in-flight query should be cancelled.
--
-- Returns: nothing.
--
-- Side effects: asks Statement execution to cancel the buffer's run, or tells
-- the user nothing is running.
function M.cancel(buffer)
	if not execution.cancel(buffer) then
		vim.notify("No Orbit statement is running in this buffer", vim.log.levels.INFO)
	end
end

-- Closes the underlying database connection for the profile bound to a
-- buffer. This is what OrbitDisconnect calls.
--
-- Parameters:
--   buffer (number): the buffer whose bound profile's connection should be
--     closed.
--
-- Returns: nothing.
--
-- Side effects: reads vim.b[buffer].orbit_profile to find which profile is
-- bound; calls runner.close(profile_name) to actually tear down the
-- connection (network/subprocess teardown); shows a vim.notify message. Note
-- this does not unbind the profile from the buffer -- the buffer stays
-- associated with the same profile name, it's just disconnected, and a later
-- query will reconnect automatically.
function M.disconnect(buffer)
	local profile_name = vim.b[buffer].orbit_profile
	if not profile_name then
		vim.notify("No Orbit profile is bound to this buffer", vim.log.levels.INFO)
		return
	end
	runner.close(profile_name)
	require("orbit.redis_cache").cancel(profile_name)
	vim.notify("Orbit disconnected: " .. profile_name)
end

-- Produces a short human-readable status string describing this buffer's
-- Orbit state, e.g. for display in a winbar/statusline (see
-- lua/orbit/init.lua's M.status and status_winbar).
--
-- Parameters:
--   buffer (number): the buffer to report status for.
--   config (table): Orbit's config table; accepted for a consistent function
--     signature with the rest of this module but not actually used in the
--     current implementation.
--
-- Returns (string): one of:
--   "Orbit: no profile" -- no profile bound to this buffer at all.
--   "Orbit: <profile> [<N>s]" -- a query is currently running, with elapsed
--     seconds since it started.
--   "Orbit: <profile> [connected]" / "Orbit: <profile> [bound]" -- no query
--     running right now; "connected" means the runner still has an open
--     connection for this profile, "bound" means the buffer references the
--     profile but there's currently no live connection.
function M.status(buffer, config)
	local state = execution.status(buffer)
	local profile_name = state and state.profile_name or vim.b[buffer].orbit_profile
	if not profile_name then
		return "Orbit: no profile"
	end
	if state then
		return string.format("Orbit: %s [%ds]", profile_name, state.elapsed)
	end
	return string.format("Orbit: %s [%s]", profile_name, runner.connected(profile_name) and "connected" or "bound")
end

return M
