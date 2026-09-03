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
--   * optionally asking for confirmation before running statements that look
--     like they mutate data (requires_confirmation),
--   * kicking off the actual database call via require("orbit.runner").run,
--     which runs asynchronously and calls back with rows or an error,
--   * tracking "is a query currently running in this buffer" state (the
--     `running` table) so a second execute in the same buffer doesn't stomp on
--     an in-flight one, and so M.cancel/M.status have something to inspect,
--   * once results come back, handing them off to either the results grid
--     (require("orbit.results")) or the workspace UI
--     (require("orbit.workspace")) for display.
--
-- This module exports a single table `M` with the functions below. It does not
-- export any data structures of its own; per-buffer profile bindings live as
-- buffer-local vim variables (vim.b[buffer].orbit_profile), and per-buffer
-- "is something running" state lives in the private `running` table here.
local profiles = require("orbit.profiles")
local diagnostics = require("orbit.diagnostics")
local feedback = require("orbit.feedback")
local results = require("orbit.results")
local runner = require("orbit.runner")
local schema_cache = require("orbit.schema_cache")
local statements = require("orbit.statements")

local M = {}
-- Keyed by buffer number. When a query is executing in a buffer, running[buffer]
-- holds a small state table (see M.execute) describing that in-flight run; the
-- entry is removed once the run finishes, fails, or is cancelled.
local running = {}
-- Keyed by buffer number. A monotonically increasing counter per buffer, bumped
-- every time M.execute is called for that buffer. This lets a slow, in-flight
-- schema lookup (schema_cache.load_columns, below) detect that a *newer* query
-- has since started in the same buffer and bail out instead of rendering stale
-- results on top of the new ones.
local result_generation = {}

-- Lowercased first keywords of SQL statements that are considered "mutating"
-- (i.e. they can change data or schema, as opposed to just reading it). Note
-- that requires_confirmation below actually implements this check the other
-- way around (it whitelists read-only keywords), so this table is currently
-- not referenced by that function; it is kept here as a reference list of
-- which keywords count as mutating.
local mutating = {
	alter = true,
	create = true,
	delete = true,
	drop = true,
	insert = true,
	merge = true,
	replace = true,
	truncate = true,
	update = true,
}

-- Decides whether a SQL statement is risky enough to ask the user "are you
-- sure?" before running it.
--
-- Parameters:
--   statement (string): the raw SQL text about to be executed.
--
-- Returns:
--   boolean: true if Orbit should prompt for confirmation before running this
--   statement, false if it looks safely read-only.
--
-- How it decides: this is NOT a real SQL parser. It strips a single leading
-- line comment (`-- ...`) or block comment (`/* ... */`) if the statement
-- starts with one, then looks at the first word to see if it's one of a small
-- set of known read-only keywords (select, show, explain, etc). It also counts
-- semicolons to make sure the buffer/selection contains at most one statement
-- (a single trailing semicolon is allowed) -- if there's more than one
-- statement, we can't be sure every one of them is read-only, so this treats
-- it as requiring confirmation. Because this check is "deliberately
-- conservative", any statement it isn't sure about (empty/unrecognized
-- keyword, multiple statements, comment it doesn't fully strip, etc.) is
-- treated as mutating -- i.e. ambiguity always falls on the side of asking for
-- confirmation rather than silently running something destructive.
local function requires_confirmation(statement)
	-- This deliberately conservative lexical check is not a SQL parser: ambiguity is treated as mutable.
	local without_comments = statement:gsub("^%s*%-%-[^\n]*\n", ""):gsub("^%s*/%*.-%*/", "")
	local keyword = without_comments:lower():match("^%s*([%a]+)")
	-- select(2, ...) discards the modified string from gsub and keeps only the
	-- second return value, which is the number of semicolons that were removed
	-- -- i.e. how many semicolons are in the statement.
	local semicolons = select(2, without_comments:gsub(";", ""))
	-- "One statement" means either no semicolons at all, or exactly one
	-- semicolon and it's the very last non-whitespace character (a normal
	-- trailing terminator), not a semicolon separating two statements.
	local one_statement = semicolons == 0 or (semicolons == 1 and without_comments:match(";%s*$"))
	local read_only = {
		describe = true,
		explain = true,
		select = true,
		show = true,
		use = true,
		values = true,
	}
	return not (one_statement and keyword and read_only[keyword])
end

-- Stops and releases the redraw timer associated with an in-flight query's
-- state table (see M.execute), if one exists.
--
-- Parameters:
--   state (table): the per-run state table created in M.execute. Expected to
--   have an optional `timer` field, which is a libuv timer handle
--   (vim.uv.new_timer()) used to periodically redraw the statusline while the
--   query is running.
--
-- Returns: nothing.
--
-- Side effects: stops the timer (state.timer:stop()) and closes/frees its
-- underlying handle (state.timer:close()), then clears state.timer to nil so
-- this function is safe to call more than once on the same state (e.g. once
-- the query finishes, and again if cancel is called afterward).
local function stop_timer(state)
	if state.timer then
		state.timer:stop()
		state.timer:close()
		state.timer = nil
	end
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
	if require("orbit").config.completion then
		require("orbit.completion").prewarm(profile)
	end
	vim.notify("Orbit profile: " .. profile.name)
end

-- The main entry point for running a SQL statement: this is what
-- OrbitExecute (wired up in lua/orbit/init.lua) ultimately calls. It figures
-- out what to run, whether to ask for confirmation, kicks off the async
-- database call, and wires up how the eventual results get displayed.
--
-- Parameters:
--   buffer (number): the buffer containing the SQL to run.
--   config (table): Orbit's config table (M.config from init.lua), used for
--     things like config.confirm_mutations, config.result_height,
--     config.result_limit, config.max_cell_width, config.focus_results, and
--     config.profile_path (indirectly, via M.profile_for_buffer).
--   selection (table|nil): an optional { start_row, end_row } describing a
--     1-based, inclusive visual selection range (see
--     lua/orbit/init.lua's visual_selection()). When nil, the whole buffer is
--     considered and statements.target decides what to run (e.g. the
--     statement under the cursor).
--
-- Returns: nothing. This function is fire-and-forget from the caller's
-- perspective -- the actual work (talking to the database) happens
-- asynchronously via runner.run's callback.
--
-- Side effects (many): reads buffer lines and the current window/tabpage via
-- vim.api.*; may prompt the user with vim.fn.confirm(...) before running a
-- mutating statement; starts a libuv timer to redraw the statusline while the
-- query runs; calls out to the runner module to actually execute SQL against
-- the database (network/subprocess I/O); on completion, opens a results grid
-- or updates the workspace UI; shows vim.notify messages and diagnostics on
-- error.
function M.execute(buffer, config, selection)
	-- Bump this buffer's "generation" counter before doing anything else. Any
	-- async callback from a previous, still-in-flight execute in this same
	-- buffer will capture the *old* generation number and can compare against
	-- this new one later to notice it's now stale (see the schema_cache.load_columns
	-- callback further down) and avoid overwriting newer results.
	result_generation[buffer] = (result_generation[buffer] or 0) + 1
	local profile, profile_err = M.profile_for_buffer(buffer, config)
	if not profile then
		-- No profile bound yet (or it's missing/invalid): tell the user, then
		-- open the profile picker and re-run M.execute automatically once they
		-- pick one, so the user doesn't have to press "execute" twice.
		vim.notify(profile_err, vim.log.levels.ERROR)
		M.select_profile(buffer, config, function()
			M.execute(buffer, config, selection)
		end)
		return
	end

	-- Ask the statements module (not shown in this file) to figure out the
	-- actual SQL text to run: either the given visual selection, or whatever
	-- statement the cursor is currently inside/near, based on the buffer's
	-- current lines.
	local statement, statement_err = statements.target({
		lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
		selection = selection,
	})
	if not statement then
		vim.notify(statement_err, vim.log.levels.ERROR)
		return
	end

	-- Confirmation is gated on three independent things all being true: the
	-- global config allows it, this specific profile hasn't opted out via
	-- options.confirm_mutations = false, and the lexical check above thinks
	-- this statement looks mutating. vim.fn.confirm shows a native "modal"
	-- prompt with the given buttons; choice 1 is "&Execute", anything else
	-- (including cancelling with <Esc>, which returns 0) aborts the run.
	if config.confirm_mutations and profile.options.confirm_mutations ~= false and requires_confirmation(statement) then
		local choice = vim.fn.confirm("Execute mutating statement?", "&Execute\n&Cancel", 2)
		if choice ~= 1 then
			return
		end
	end

	-- Only one statement may run per buffer at a time; if one is already
	-- tracked in `running`, refuse to start a second and just warn the user.
	if running[buffer] then
		vim.notify("An Orbit statement is already running in this buffer", vim.log.levels.WARN)
		return
	end

	-- Show a transient "Running on <profile>..." / "Querying on <profile>..."
	-- message via the feedback module (distinguishing an already-open
	-- connection from one that still needs to connect). `notice` is a handle
	-- that feedback.finish (below) later uses to replace this message with a
	-- final result.
	local notice =
		feedback.start((runner.connected(profile.name) and "Running on " or "Querying on ") .. profile.name .. "...")
	-- This `state` table is the single source of truth for "a query is
	-- running in this buffer" while it's in flight. It's stored in `running`
	-- keyed by buffer, and captured by closures below (the runner.run
	-- callback and the timer callback) so they can check whether they're
	-- still the "current" run for this buffer.
	local state = {
		cancelled = false,
		profile_name = profile.name,
		-- vim.uv.hrtime() is a high-resolution monotonic clock (nanoseconds),
		-- used purely for measuring elapsed time, not wall-clock time.
		started_at = vim.uv.hrtime(),
		-- Remember which tabpage/window the query was started from, since by
		-- the time results arrive (async) the user may have switched windows;
		-- results should still show up relative to where the query began.
		tabpage = vim.api.nvim_get_current_tabpage(),
		window = vim.api.nvim_get_current_win(),
		notice = notice,
		result_generation = result_generation[buffer],
	}
	running[buffer] = state
	-- Start a repeating libuv timer (fires once immediately at 0ms, then every
	-- 1000ms) purely to force the statusline to redraw periodically, so that a
	-- winbar/statusline showing "Orbit: profile [Ns]" (see M.status) keeps
	-- ticking while the query runs. vim.schedule_wrap defers the callback onto
	-- Neovim's main event loop, since libuv timer callbacks otherwise run
	-- outside the context where it's safe to call vim.cmd/vim.api functions.
	state.timer = vim.uv.new_timer()
	state.timer:start(
		0,
		1000,
		vim.schedule_wrap(function()
			vim.cmd.redrawstatus()
		end)
	)
	vim.cmd.redrawstatus()
	-- Kick off the actual query asynchronously. runner.run is expected to talk
	-- to the database connector for this profile (postgres/sqlite/trino) and
	-- eventually invoke the callback below with either (rows, nil) on success
	-- or (nil, error_message) on failure. `state.process` stores whatever
	-- handle runner.run returns so M.cancel can later ask the runner to abort
	-- it.
	state.process = runner.run(profile, statement, function(rows, run_err)
		-- A previous completion must not clear or render over a newer run in this buffer.
		if running[buffer] ~= state then
			return
		end
		running[buffer] = nil
		stop_timer(state)
		vim.cmd.redrawstatus()
		if state.cancelled then
			-- M.cancel sets state.cancelled = true and asks the runner to abort,
			-- but the runner's callback still fires afterward; treat that as a
			-- "cancelled" outcome rather than a normal success/failure.
			feedback.finish(state.notice, "Query cancelled: " .. profile.name, vim.log.levels.WARN)
			return
		end
		if run_err then
			feedback.finish(state.notice, "Query failed: " .. profile.name, vim.log.levels.ERROR)
			vim.notify(run_err, vim.log.levels.ERROR)
			-- diagnostics.open likely renders the raw database error in a
			-- dedicated diagnostics window/panel so long error text isn't lost.
			diagnostics.open(run_err)
			return
		end
		-- Options passed through to whichever UI ends up rendering the result
		-- rows (either the standalone results grid or the workspace's results
		-- panel).
		local result_options = {
			confirm_mutations = config.confirm_mutations,
			height = config.result_height,
			limit = config.result_limit,
			max_cell_width = config.max_cell_width,
			focus = config.focus_results,
			profile_name = profile.name,
			source_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":t") ~= ""
					and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":t")
				or "[No Name]",
			source_window = state.window,
			tabpage = state.tabpage,
			-- Nanoseconds -> seconds: hrtime() returns nanoseconds, and there are
			-- 1_000_000_000 of them per second.
			elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000),
		}
		-- vim.b[buffer].orbit_table is set elsewhere (e.g. by the workspace's
		-- "browse table" flow) when this buffer's statement was generated to
		-- browse a specific table/view rather than typed freely by the user.
		-- If the statement we just ran still matches the one that was
		-- generated for that table browse (compared with whitespace trimmed),
		-- this is a "table browse" query, and we can enrich the results with
		-- extra table-aware metadata (editability, primary keys, column
		-- names) instead of just showing raw rows.
		local table = vim.b[buffer].orbit_table
		if table and vim.trim(statement) == vim.trim(vim.b[buffer].orbit_table_statement or "") then
			result_options.source_name = table.name
			-- Give the results grid a way to re-run this same query later (e.g.
			-- a manual "refresh" action) without needing to know how it was
			-- originally built.
			result_options.reload = function(callback)
				runner.run(profile, statement, callback)
			end
			-- Look up this table's primary key columns (from the schema cache,
			-- which may itself hit the database) to figure out whether rows in
			-- the grid can be edited in place.
			schema_cache.load_metadata(profile, table, "primary_keys", {}, function(primary_keys, metadata_err)
				if metadata_err then
					vim.notify(metadata_err, vim.log.levels.WARN)
				else
					local names = vim.tbl_map(function(primary_key)
						return primary_key.name
					end, primary_keys)
					local connector, connector_err = require("orbit.adapters").connector(profile)
					local editable, editable_err
					if connector and connector.editable_table then
						-- Ask the profile's connector (postgres/sqlite/trino adapter)
						-- whether it actually supports editing this table given its
						-- primary key columns; not every connector/table combination
						-- does.
						editable, editable_err = connector.editable_table(profile.options, table, names)
					else
						editable_err = connector_err
							or "Result is read-only: editing is not supported by this connection profile."
					end
					if editable then
						result_options.editable = editable
						result_options.profile = profile
					elseif editable_err then
						result_options.read_only_reason = editable_err
					end
				end
				-- Also fetch column metadata (names) for this table, again from
				-- the schema cache.
				schema_cache.load_columns(profile, table, {}, function(columns)
					-- By the time this async callback fires, a newer M.execute call
					-- for this same buffer may have already started (bumping
					-- result_generation[buffer]). If so, this callback is for a
					-- stale run and must not render its (now outdated) results.
					if result_generation[buffer] ~= state.result_generation then
						return
					end
					if columns then
						result_options.columns = vim.tbl_map(function(column)
							return column.name
						end, columns)
					end
					local workspace = require("orbit.workspace")
					if workspace.is_workspace(state.tabpage) then
						workspace.open_results(rows, result_options)
					else
						results.open(rows, result_options)
					end
				end)
			end)
			feedback.finish(
				state.notice,
				string.format(
					"Query finished: %d rows in %ds",
					#rows,
					math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
				)
			)
			return
		end
		local workspace = require("orbit.workspace")
		if workspace.is_workspace(state.tabpage) then
			-- Workspace-owned grids preserve its fixed result region and close behavior.
			workspace.open_results(rows, result_options)
		else
			results.open(rows, result_options)
		end
		feedback.finish(
			state.notice,
			string.format(
				"Query finished: %d rows in %ds",
				#rows,
				math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
			)
		)
	end)
end

-- Cancels whatever query is currently running in a buffer, if any. This is
-- what OrbitCancel calls.
--
-- Parameters:
--   buffer (number): the buffer whose in-flight query should be cancelled.
--
-- Returns: nothing.
--
-- Side effects: marks the buffer's `running` state as cancelled (so the
-- runner.run callback in M.execute treats the eventual completion as a
-- cancellation rather than success/failure), updates the feedback notice to
-- say "Cancelling query...", and asks the runner module to actually abort the
-- underlying process/connection (runner.cancel). Note the `running[buffer]`
-- entry itself is only cleared later, inside the runner's completion
-- callback, once the cancellation has actually taken effect.
function M.cancel(buffer)
	if not running[buffer] then
		vim.notify("No Orbit statement is running in this buffer", vim.log.levels.INFO)
		return
	end
	running[buffer].cancelled = true
	feedback.finish(running[buffer].notice, "Cancelling query...")
	runner.cancel(running[buffer].process)
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
	local state = running[buffer]
	local profile_name = state and state.profile_name or vim.b[buffer].orbit_profile
	if not profile_name then
		return "Orbit: no profile"
	end
	if state then
		local elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
		return string.format("Orbit: %s [%ds]", profile_name, elapsed)
	end
	return string.format("Orbit: %s [%s]", profile_name, runner.connected(profile_name) and "connected" or "bound")
end

return M
