-- orbit/execution.lua
--
-- Statement execution: one run of a statement through a connection profile's
-- Connector, from Mutating statement confirmation to its outcome in a result
-- window (see docs/agents/CONTEXT.md).
--
-- Every path that runs a statement for the user goes through M.run: statements
-- executed from a query buffer (lua/orbit/query.lua) and schema browser actions
-- such as "sample rows" or "show definition" (lua/orbit/workspace.lua). Callers
-- resolve *which* profile and *which* statement to run; this module owns
-- everything after that:
--   * the Mutating statement confirmation prompt,
--   * the per-key lock (one statement at a time per query buffer/Workspace),
--   * cancellation,
--   * the "Querying on ..." feedback and the statusline redraw ticker,
--   * deciding the Editable target when a result browses a schema object,
--   * handing rows to a result sink, or discarding them when the sink is gone.
--
-- A *result sink* is the seam where results leave this module. It is a table
-- with two functions:
--   sink.alive()                       -> boolean
--     false once the place the result would be shown has gone away (e.g. the
--     Workspace tabpage closed). Late outcomes are then discarded here.
--   sink.deliver(rows, result_options) -> truthy when the result was shown
--     opens the result window. A falsy return is treated as "discarded".
-- Two sinks exist: workspace.result_sink (the Workspace result window) and
-- results.sink (a standalone result window). Tests pass their own.
--
-- Dependencies (runner, metadata, confirm, ...) are looked up when M.run is
-- called, not when this file loads, so tests may pass a `deps` table or keep
-- patching module fields such as `runner.run`.
local M = {}

-- Lock table. Keyed by the request's `key` (a query buffer number, or a
-- Workspace key string). While a statement execution is in flight its state
-- table lives here; the entry is removed only once the outcome has been
-- delivered, discarded, cancelled, or failed. Holding the lock for the whole
-- run (including the Editable target lookups) means no two runs for the same
-- key can ever overlap, so no "which run is newer?" counter is needed.
local running = {}

-- Nanoseconds -> whole seconds. vim.uv.hrtime() returns nanoseconds.
local function seconds(nanoseconds)
	return math.floor(nanoseconds / 1000000000)
end

-- Starts the repeating statusline redraw that keeps "Orbit: profile [Ns]"
-- ticking while a statement runs (see M.status).
-- Returns: a function that stops and frees the timer. Safe to call twice.
local function start_ticker()
	local timer = vim.uv.new_timer()
	-- libuv callbacks run outside Neovim's main loop; schedule_wrap moves the
	-- redraw back onto it, where vim.cmd is safe to call.
	timer:start(0, 1000, vim.schedule_wrap(function()
		vim.cmd.redrawstatus()
	end))
	vim.cmd.redrawstatus()
	return function()
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
	end
end

-- Builds the dependency table for one run: the real modules, overridden by
-- whatever the caller passed in `deps`. The caller's table is never mutated.
local function resolve_deps(deps)
	local resolved = {
		connectors = require("orbit.adapters"),
		statements = require("orbit.statements"),
		diagnostics = require("orbit.diagnostics"),
		feedback = require("orbit.feedback"),
		metadata = require("orbit.schema_cache"),
		runner = require("orbit.runner"),
		now = vim.uv.hrtime,
		notify = vim.notify,
		ticker = start_ticker,
		-- Returns true only when the user picks "Execute"; <Esc> returns 0.
		confirm = function(message)
			return vim.fn.confirm(message, "&Execute\n&Cancel", 2) == 1
		end,
	}
	for name, value in pairs(deps or {}) do
		resolved[name] = value
	end
	return resolved
end

-- Default user-facing messages. A request may override any of them through
-- `request.messages` (schema browser actions use their own wording).
local function resolve_messages(request, connected)
	local name = request.profile.name
	local messages = {
		busy = "An Orbit statement is already running in this buffer",
		start = (connected and "Running on " or "Querying on ") .. name .. "...",
		failed = "Query failed: " .. name,
		cancelled = "Query cancelled: " .. name,
		finished = function(count, elapsed)
			return string.format("Query finished: %d rows in %ds", count, elapsed)
		end,
	}
	for field, value in pairs(request.messages or {}) do
		messages[field] = value
	end
	return messages
end


-- Is this statement a Mutating statement? The Connector may supply its own
-- rule; otherwise the default lexical rule in orbit.statements applies.
local function mutating(connector, request, deps)
	if connector.requires_confirmation then
		return connector.requires_confirmation(request.statement, request.profile)
	end
	return deps.statements.requires_confirmation(request.statement, connector.sql_dialect)
end

-- Decides the Editable target for a result that browses one schema object
-- (`request.table`), then calls `done()`. It fills `result_options` in place:
--   editable + profile       when the Connector accepts the primary keys,
--   read_only_reason         when it explains why editing is unavailable,
--   columns                  from table metadata when the run supplied none.
-- `alive()` is re-checked because each metadata lookup is asynchronous and
-- the result window may have gone away in between. `discard()` is called
-- instead of `done()` in that case. `guard(fn)` wraps each asynchronous
-- callback so an error inside it still ends the run (see M.run).
local function editable_target(request, connector, result_options, deps, alive, done, discard, guard)
	local profile, object = request.profile, request.table
	deps.metadata.load_metadata(profile, object, "primary_keys", {}, guard(function(primary_keys, metadata_err)
		if not alive() then
			discard()
			return
		end
		if metadata_err then
			-- Without primary keys the grid is simply read-only; still show rows.
			deps.notify(metadata_err, vim.log.levels.WARN)
		else
			local names = vim.tbl_map(function(primary_key)
				return primary_key.name
			end, primary_keys)
			local editable, editable_err
			if connector.editable_table then
				editable, editable_err = connector.editable_table(profile.options, object, names)
			else
				editable_err = "Result is read-only: editing is not supported by this connection profile."
			end
			if editable then
				result_options.editable = editable
				result_options.profile = profile
			elseif editable_err then
				result_options.read_only_reason = editable_err
			end
		end
		deps.metadata.load_columns(profile, object, {}, guard(function(columns)
			if columns and not result_options.columns then
				result_options.columns = vim.tbl_map(function(column)
					return column.name
				end, columns)
			end
			done()
		end))
	end))
end

-- Runs one statement execution.
--
-- Parameters:
--   request (table):
--     key               - lock key (required). One run per key at a time.
--     profile           - the resolved connection profile table (required).
--     statement         - the exact statement text to run (required).
--     confirm_mutations - boolean; the global gate for the Mutating statement
--                         prompt. The profile can still opt out with
--                         options.confirm_mutations = false.
--     table             - optional schema object the statement browses. When
--                         set, the result gets an Editable target decision
--                         and a `reload` function.
--     result_options    - optional table copied into the options handed to
--                         sink.deliver (height, limit, source_name, ...).
--     diagnostics       - optional; false keeps a failure out of the
--                         diagnostics window (schema browser actions only
--                         notify, so the Workspace layout is left alone).
--     messages          - optional overrides for the feedback messages:
--                         busy, start, failed, cancelled (strings) and
--                         finished (function(row_count, elapsed_seconds)).
--   sink (table): the result sink; see the header comment.
--   deps (table|nil): optional dependency overrides (runner, metadata,
--     connectors, statements, feedback, diagnostics, confirm, notify, now,
--     ticker). Missing entries use the real modules.
--
-- Returns: true when the statement was started; false when it was refused
-- (unknown Connector, confirmation declined, or the key is already running).
--
-- Side effects: may prompt, spawns the statement through the runner, shows
-- feedback, and eventually calls sink.deliver. Every outcome releases the lock.
function M.run(request, sink, deps)
	deps = resolve_deps(deps)
	local profile = request.profile
	local connector, connector_err = deps.connectors.connector(profile)
	if not connector then
		deps.notify(connector_err, vim.log.levels.ERROR)
		return false
	end
	local messages = resolve_messages(request, deps.runner.connected(profile.name))

	-- Refuse before prompting: confirming a statement that cannot start would
	-- only waste the user's answer.
	if running[request.key] then
		deps.notify(messages.busy, vim.log.levels.WARN)
		return false
	end
	if request.confirm_mutations and profile.options.confirm_mutations ~= false and mutating(connector, request, deps) then
		if not deps.confirm("Execute mutating statement?") then
			return false
		end
	end

	-- `state` is this run's entry in the lock table. Closures below compare
	-- against it so a callback can never act on somebody else's run.
	local state = {
		cancelled = false,
		profile_name = profile.name,
		started_at = deps.now(),
		-- Kept so M.status measures with the same clock the run started on.
		now = deps.now,
		notice = deps.feedback.start(messages.start),
	}
	running[request.key] = state
	state.stop_ticker = deps.ticker()

	-- Every outcome passes through here: release the lock, stop the ticker,
	-- then replace the feedback notice with the final message. Only the first
	-- call counts; `state.done` makes any later outcome (a late callback after
	-- a cancel, say) a no-op.
	local function finish(message, level)
		if state.done then
			return
		end
		state.done = true
		if running[request.key] == state then
			running[request.key] = nil
		end
		state.stop_ticker()
		vim.cmd.redrawstatus()
		deps.feedback.finish(state.notice, message, level)
	end
	-- M.cancel ends a run itself while only metadata lookups are pending.
	state.finish = finish
	state.cancelled_message = messages.cancelled
	-- Wraps an asynchronous callback so an error raised inside it (e.g. the
	-- result window cannot open: "E36: Not enough room") still ends the run
	-- and releases the lock, instead of leaving the key busy forever.
	local function guard(callback)
		return function(...)
			local ok, err = pcall(callback, ...)
			if not ok then
				finish(messages.failed, vim.log.levels.ERROR)
				deps.notify(tostring(err), vim.log.levels.ERROR)
			end
		end
	end
	local function discard()
		finish("Statement result discarded: Workspace closed", vim.log.levels.DEBUG)
	end
	local function elapsed()
		return seconds(deps.now() - state.started_at)
	end

	state.process = deps.runner.run(profile, request.statement, guard(function(rows, run_err, metadata)
		if state.done then
			return
		end
		if state.cancelled then
			finish(messages.cancelled, vim.log.levels.WARN)
			return
		end
		if run_err then
			if not sink.alive() then
				-- Nowhere to show diagnostics; keep the error visible as feedback.
				finish(run_err, vim.log.levels.ERROR)
				return
			end
			finish(messages.failed, vim.log.levels.ERROR)
			deps.notify(run_err, vim.log.levels.ERROR)
			if request.diagnostics ~= false then
				deps.diagnostics.open(run_err)
			end
			return
		end
		if not sink.alive() then
			discard()
			return
		end

		metadata = metadata or {}
		local result_options = vim.tbl_extend("force", {}, request.result_options or {}, {
			columns = metadata.columns,
			document = metadata.document,
			elapsed = elapsed(),
		})
		local function deliver()
			-- M.cancel may already have ended the run during the lookups.
			if state.done then
				return
			end
			if state.cancelled then
				finish(messages.cancelled, vim.log.levels.WARN)
				return
			end
			if not sink.deliver(rows, result_options) then
				discard()
				return
			end
			finish(messages.finished(#rows, elapsed()))
		end

		if not request.table then
			deliver()
			return
		end
		-- Let the result grid re-run the same statement after a save.
		result_options.reload = function(callback)
			deps.runner.run(profile, request.statement, callback, connector)
		end
		-- The statement itself has finished; only metadata lookups remain, so
		-- a cancel from here on ends the run at once (see M.cancel).
		state.awaiting_metadata = true
		editable_target(request, connector, result_options, deps, sink.alive, deliver, discard, guard)
	end), connector)
	return true
end

-- Cancels the statement execution running under `key`, if any.
-- Returns: true when a run was found and asked to stop; false otherwise.
-- Side effects: marks the run cancelled, updates its feedback notice, and asks
-- the runner to abort the process. The lock is released when the runner
-- reports back -- or immediately, when the statement already finished and
-- only the Editable target lookups are pending (their results are ignored).
function M.cancel(key, deps)
	local state = running[key]
	if not state then
		return false
	end
	if state.awaiting_metadata then
		state.cancelled = true
		state.finish(state.cancelled_message, vim.log.levels.WARN)
		return true
	end
	deps = resolve_deps(deps)
	state.cancelled = true
	deps.feedback.finish(state.notice, "Cancelling query...")
	deps.runner.cancel(state.process)
	return true
end

-- Reports the run in flight under `key`.
-- Returns: nil when idle, otherwise { profile_name = string, elapsed = seconds }.
function M.status(key)
	local state = running[key]
	if not state then
		return nil
	end
	return {
		profile_name = state.profile_name,
		elapsed = seconds(state.now() - state.started_at),
	}
end

return M
