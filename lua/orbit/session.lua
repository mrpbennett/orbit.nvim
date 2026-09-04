--[[
  orbit/session.lua

  This module manages long-lived, "session-based" database CLI connections
  (e.g. `psql`, `sqlite3` running interactively) -- as opposed to the
  one-shot processes `orbit.runner` spawns for connectors like Trino that
  don't support a persistent interactive session.

  Why this exists: some database CLIs are much faster/cheaper to keep open
  across multiple statements (avoiding reconnect overhead) rather than
  spawning a brand-new process per query. But a single interactive process
  can only handle one statement at a time and its stdout is one continuous
  stream with no built-in message framing. So this module:
    * keeps one persistent child process per connection profile name, in
      the module-local `sessions` table (profile name -> session state).
    * queues incoming statements (FIFO) and only ever has one "active"
      request being written/read from the process at a time.
    * asks the connector to inject a unique, unlikely-to-collide "marker"
      string into each request (via connector.session_request) and then
      watches accumulated stdout for that marker (via
      connector.session_output) to know when a statement's output is
      complete -- this is the framing mechanism that makes it possible to
      tell "where does this response end" in a raw stdout stream.

  `orbit.runner` is the only caller of this module; it delegates to
  M.run/M.cancel/M.close/M.connected for any connector that defines
  `session_command`.

  Exports (module table M):
    M.run(profile, connector, statement, callback) -> request handle
    M.cancel(request)
    M.close(profile_name)
    M.connected(profile_name) -> boolean
--]]
local M = {}
-- profile name -> session state table. Each session state has:
--   profile, connector - what was passed to session_for.
--   process            - the vim.system process handle, or nil if not yet
--                        started (or if it died and needs restarting).
--   queue              - FIFO list of pending request tables.
--   active             - the request currently being processed (written
--                        to stdin, waiting for its marker in stdout), or
--                        nil if nothing is in flight.
--   signature          - a serialization of the profile's kind+options,
--                        used to detect when the profile was edited and
--                        the process needs to be restarted (see
--                        session_for).
--   sequence           - monotonically increasing counter used to build
--                        unique markers.
local sessions = {}

-- Complete a request's callback exactly once, no matter how it finishes.
-- Parameters: request - a request table (see M.run); output - the result
-- string to pass on success; err - an error message (or nil on success).
-- Side effects: sets request.done = true; schedules request.callback to
-- run on Neovim's main loop via vim.schedule (required because this is
-- typically called from a raw libuv callback context where vim.* APIs
-- would not be safe to call directly).
local function finish(request, output, err)
	-- Process exit, cancellation, and marker detection can race; complete a request exactly once.
	if request.done then
		return
	end
	request.done = true
	vim.schedule(function()
		request.callback(output, err)
	end)
end

-- Fail an entire session: since all requests share one CLI process, if
-- that process dies or errors we can't know which request (if any) it was
-- still working on correctly, so everything outstanding is failed with the
-- same error rather than risk returning wrong data.
-- Parameters: session - the session state table; err - error message to
-- report to every outstanding request.
-- Side effects: clears session.active/session.process (so a future M.run
-- call will start a fresh process); finishes (with the given error) the
-- active request and every queued request; empties session.queue.
local function fail(session, err)
	-- One shared CLI cannot safely continue after failure, so fail its active and queued requests.
	local active = session.active
	session.active = nil
	session.process = nil
	if active then
		finish(active, nil, err)
	end
	for _, request in ipairs(session.queue) do
		finish(request, nil, err)
	end
	session.queue = {}
end

-- Pop the next queued request (if any) and start it running: lazily spawn
-- the session's CLI process if it isn't already running, then write the
-- request's SQL (with its marker) to the process's stdin.
-- Parameters: session - the session state table to advance.
-- Returns: nothing; this function's effect is entirely through mutating
-- `session` and eventually calling request callbacks.
-- Side effects: may spawn a new child process via vim.system (with stdin
-- piping enabled and stdout/stderr callbacks); writes to the process's
-- stdin; recurses into itself (directly, or via the stdout callback below)
-- to keep draining the queue one request at a time.
local function start_next(session)
	-- The session is single-flight FIFO: stdout accumulates until this request's marker is observed.
	if session.active or #session.queue == 0 then
		return
	end
	if not session.process then
		-- No process yet (first request ever, or the previous one died) --
		-- ask the connector to build the shell command to start an
		-- interactive CLI session (e.g. `psql ...` with no single `-c`
		-- statement attached).
		local command, command_err = session.connector.session_command(session.profile.options)
		if not command then
			fail(session, command_err)
			return
		end
		local environment = session.connector.environment and session.connector.environment(session.profile.options)
			or {}
		local options = {
			-- stdin = true tells vim.system to open a pipe we can write() to
			-- later, since we need to send each statement interactively rather
			-- than passing it as a command-line argument.
			stdin = true,
			-- This callback fires every time the process writes to stdout. We
			-- can't assume one call = one complete response (output can arrive
			-- in arbitrary chunks), so we accumulate everything into
			-- session.active.output and ask the connector whether the unique
			-- marker for the active request has appeared yet -- only then do we
			-- know the CLI has finished printing this statement's result.
			stdout = function(err, data)
				if err or not data or not session.active then
					return
				end
				session.active.output = session.active.output .. data
				local output = session.connector.session_output(session.active.output, session.active.marker)
				if output then
					local request = session.active
					session.active = nil
					finish(request, output, request.stderr ~= "" and vim.trim(request.stderr) or nil)
					-- This request is done; immediately try to start whatever's
					-- next in the queue on the same still-open process.
					start_next(session)
				end
			end,
			-- Accumulate stderr separately so it can be attached as a warning
			-- alongside successful output (e.g. NOTICE/WARNING messages some
			-- CLIs print outside of stdout).
			stderr = function(_, data)
				if data and session.active then
					session.active.stderr = session.active.stderr .. data
				end
			end,
			text = true,
		}
		if next(environment) then
			options.env = vim.tbl_extend("force", vim.fn.environ(), environment)
		end
		-- The final callback here fires when the CLI process exits entirely
		-- (not per-statement) -- i.e. the session ended, whether cleanly or
		-- due to a crash/kill. pcall guards against vim.system itself
		-- throwing (e.g. invalid command).
		local ok, process = pcall(vim.system, command, options, function(result)
			-- Guard against a stale/replaced session: if `M.close` or
			-- `session_for` already swapped in a different session object under
			-- this profile name, this exit callback belongs to an old process
			-- and must not fail the new session.
			if sessions[session.profile.name] == session then
				fail(
					session,
					result.code == 0 and "connection closed"
						or string.format("connection closed (%d): %s", result.code, vim.trim(result.stderr or ""))
				)
			end
		end)
		if not ok then
			fail(session, "cannot start CLI: " .. process)
			return
		end
		session.process = process
	end

	local request = table.remove(session.queue, 1)
	session.active = request
	-- Ask the connector to format the statement plus the unique marker into
	-- whatever text needs to be sent to the CLI's stdin (e.g. "SELECT ...;
	-- \echo __orbit_marker__").
	local input, input_err = session.connector.session_request(request.statement, request.marker)
	if not input then
		session.active = nil
		finish(request, nil, input_err)
		start_next(session)
		return
	end
	session.process:write(input)
end

-- Find (or lazily create) the session state for a given profile.
-- Parameters: profile - connection profile table; connector - adapter to
-- use for this profile's kind.
-- Returns: the session state table for this profile name.
-- Side effects: may close and replace an existing session (killing its
-- process) if the profile's settings changed since that session was
-- created; may create a brand-new entry in the module-local `sessions`
-- table.
local function session_for(profile, connector)
	local signature = vim.json.encode({ kind = profile.kind, options = profile.options })
	local session = sessions[profile.name]
	if session and session.signature ~= signature then
		-- Profile edits require a new process so no request uses stale connection settings.
		M.close(profile.name)
		session = nil
	end
	if not session then
		session = {
			profile = profile,
			connector = connector,
			queue = {},
			signature = signature,
			sequence = 0,
		}
		sessions[profile.name] = session
	end
	return session
end

-- Queue a statement to run on the persistent session for `profile`,
-- starting/reusing that session's CLI process as needed.
-- Parameters:
--   profile   - connection profile table (must have .name, .kind, .options).
--   connector - adapter table; must provide session_command,
--               session_request, session_output (and may provide
--               environment).
--   statement - SQL text to run.
--   callback  - function(output, err) invoked exactly once when this
--               statement's result is ready (or it fails/is cancelled).
-- Returns: the request table (used as an opaque handle by M.cancel).
-- Side effects: mutates the session's queue; may start a new CLI process
-- (see start_next).
function M.run(profile, connector, statement, callback)
	local session = session_for(profile, connector)
	session.sequence = session.sequence + 1
	local request = {
		callback = callback,
		-- The unique sentinel delimits one response in a long-lived CLI output stream.
		marker = string.format("__orbit_%s_%d_%d", profile.name:gsub("[^%w]", "_"), vim.uv.hrtime(), session.sequence),
		output = "",
		stderr = "",
		statement = statement,
	}
	table.insert(session.queue, request)
	start_next(session)
	return request
end

-- Cancel a request previously returned by M.run.
-- Parameter: request - the request table to cancel (or nil, in which case
-- nothing happens).
-- Side effects: if the request is the one currently active on its
-- session, this kills the whole shared CLI process (there is no way to
-- interrupt just one in-flight statement without killing the process the
-- other queued requests also depend on -- those queued requests will then
-- fail via the process-exit handler in start_next, and a new process will
-- be spawned on the next M.run). If the request is only queued (not yet
-- started), it's simply removed from the queue and failed with "query
-- cancelled", without disturbing anything already running.
-- Does nothing if the request has already completed (request.done).
function M.cancel(request)
	if not request or request.done then
		return
	end
	for _, session in pairs(sessions) do
		if session.active == request then
			-- Cancelling active work kills its shared process; queued work is removed independently.
			if session.process then
				session.process:kill(15)
			end
			return
		end
		for index, queued in ipairs(session.queue) do
			if queued == request then
				table.remove(session.queue, index)
				finish(request, nil, "query cancelled")
				return
			end
		end
	end
end

-- Permanently close the session for a given profile (e.g. user ran
-- :OrbitDisconnect, or the profile is being removed/edited).
-- Parameter: profile_name - name of the profile whose session to close.
-- Side effects: removes the session from the module-local `sessions`
-- table immediately (so a concurrent process-exit callback won't try to
-- fail it again -- see the `sessions[session.profile.name] == session`
-- guard in start_next); fails any active/queued requests with "connection
-- closed"; sends SIGTERM (15) to the underlying process if one was
-- running. Does nothing if there's no session for that profile.
function M.close(profile_name)
	local session = sessions[profile_name]
	if not session then
		return
	end
	sessions[profile_name] = nil
	local process = session.process
	fail(session, "connection closed")
	if process then
		process:kill(15)
	end
end

-- Check whether the profile currently has a live CLI process running.
-- Returns: boolean (false if there's no session at all, or the session
-- exists but hasn't started/has lost its process).
function M.connected(profile_name)
	return sessions[profile_name] and sessions[profile_name].process ~= nil
end

return M
