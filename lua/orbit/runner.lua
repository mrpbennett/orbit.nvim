-- orbit/runner.lua
--
-- This module is the entry point for actually running a SQL statement against
-- a database. It does not know how to talk to any particular database itself
-- (that logic lives in the connector returned by `orbit.adapters`, e.g. the
-- postgres/sqlite/trino connectors) -- instead it decides *how* to invoke the
-- connector:
--   * "one-shot" connectors (like Trino) spawn a fresh CLI process per
--     statement and parse its stdout when it exits.
--   * "session" connectors (e.g. psql/sqlite3) keep a single long-lived CLI
--     process open and pipe statements through it one at a time; that queuing
--     and process lifecycle is handled by `orbit.session`, which this module
--     delegates to.
-- Callers (see `orbit.query`) call `M.run(...)` to execute a statement and get
-- rows back asynchronously via a callback, `M.cancel(...)` to stop an
-- in-flight run, and `M.close`/`M.connected` to manage/query a profile's
-- persistent session.
--
-- Exports (the module table `M`):
--   M.run(profile, statement, callback, connector) -> process handle or nil
--   M.cancel(process)
--   M.close(profile_name)
--   M.connected(profile_name) -> boolean

local adapters = require("orbit.adapters")
local session = require("orbit.session")

local M = {}

-- Turn raw CLI output text into a list of row tables.
-- `connector` may define its own `parse` (some CLIs need bespoke parsing);
-- otherwise we fall back to the generic parser in `orbit.adapters`.
-- Returns: rows (table) and/or an error string, same contract as
-- connector.parse/adapters.parse.
local function parse(connector, output)
	return connector.parse and connector.parse(output) or adapters.parse(output)
end

-- Run a single statement by spawning a brand-new CLI process for it
-- (used for connectors that don't support a persistent session, e.g. Trino).
-- Parameters:
--   profile   - the connection profile table; must have a `profile.options`
--               table with connector-specific settings (host, db path, etc).
--   connector - the adapter table for this database kind; must provide
--               `connector.prepare(options, statement)` to build a shell
--               command.
--   statement - the SQL text to run (must be a non-empty string).
--   callback  - function(rows, err) called exactly once with either the
--               parsed rows or an error message.
-- Returns: the process handle from vim.system (so the caller can cancel it),
--          or nil if the run could not even be started (bad input, no
--          command, or spawn failure) -- in all of those "nil" cases the
--          callback is still invoked (asynchronously) with the error.
-- Side effects: spawns an external process via vim.system; all callback
-- invocations are wrapped in vim.schedule(...) so they run on Neovim's main
-- event loop, which is required because vim.* APIs are not safe to call from
-- arbitrary callback/thread contexts.
local function run_once(profile, connector, statement, callback)
  -- Always deliver completion on Neovim's loop, including command construction and spawn failures.
	if type(profile) ~= "table" or type(profile.options) ~= "table" then
		vim.schedule(function()
			callback(nil, "profile options are required")
		end)
		return nil
	end
	if type(statement) ~= "string" or statement == "" then
		vim.schedule(function()
			callback(nil, "statement is required")
		end)
		return nil
	end

	-- Ask the connector to turn the SQL statement into an actual shell command
	-- (e.g. { "psql", "-c", statement, ... }). This can fail if options are
	-- invalid, in which case there is nothing to run.
	local command, command_err = connector.prepare(profile.options, statement)
  if not command then
    vim.schedule(function()
      callback(nil, command_err)
    end)
    return nil
  end

  -- vim.system spawns `command` as a child process and calls the given
  -- function asynchronously once it exits. `text = true` asks Neovim to give
  -- us stdout/stderr as plain strings instead of raw bytes. This call can
  -- itself throw (e.g. if the executable path is malformed), so it's wrapped
  -- in pcall; `ok` tells us whether the process was actually started, and
  -- `process` is either the process handle or the pcall error message.
  local ok, process = pcall(vim.system, command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        -- Non-zero exit code means the CLI itself reported an error (bad SQL,
        -- connection refused, etc); surface its stderr to the caller.
        callback(nil, string.format("command failed (%d): %s", result.code, vim.trim(result.stderr)))
        return
      end

			local rows, parse_err = parse(connector, result.stdout)
      if not rows then
        callback(nil, parse_err)
        return
      end
      callback(rows)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback(nil, "cannot start CLI: " .. process)
    end)
    return nil
  end

  return process
end

-- Run one SQL statement against a profile's database, asynchronously.
-- This is the main public entry point that the rest of the plugin (see
-- `orbit.query`) calls to execute whatever the user typed.
-- Parameters:
--   profile   - connection profile table (name, kind, options, ...).
--   statement - SQL text to execute.
--   callback  - function(rows, err) invoked once with results or an error.
--   connector - optional pre-resolved adapter; if omitted, it is looked up
--               from `profile` via `adapters.connector`. Callers that already
--               have the connector (e.g. because they inspected it) can pass
--               it in to avoid resolving it twice.
-- Returns: whatever run_once/session.run return -- a handle that can later be
-- passed to M.cancel, or nil if nothing was started.
-- Side effects: may spawn a process (one-shot) or enqueue work on a shared
-- session process (see orbit.session); callback is always invoked
-- eventually, asynchronously.
function M.run(profile, statement, callback, connector)
	if not connector then
		local err
		connector, err = adapters.connector(profile)
		if not connector then
			vim.schedule(function()
				callback(nil, err)
			end)
			return nil
		end
	end
  -- Trino uses one-shot processes; supported connectors retain a serialized CLI session.
	if not connector.session_command then
		return run_once(profile, connector, statement, callback)
  end
	return session.run(profile, connector, statement, function(output, run_err)
    if run_err then
      callback(nil, run_err)
      return
    end
		local rows, parse_err = parse(connector, output)
    callback(rows, parse_err)
  end)
end

-- Cancel an in-flight run started by M.run.
-- Parameter: `process` - the value M.run returned (either a vim.system
-- process handle, or an opaque session "request" table).
-- Side effects: sends SIGTERM (15) to a one-shot process, or asks
-- orbit.session to cancel/remove a queued or active session request.
-- Safe to call with nil (does nothing).
function M.cancel(process)
  if not process then
    return
  end
  if process.kill then
    -- One-shot vim.system handles expose kill; session requests are opaque queue entries.
    process:kill(15)
  else
    session.cancel(process)
  end
end

-- Close the persistent CLI session (if any) for the given profile name.
-- Side effects: kills the underlying process and fails any pending requests
-- on that session (see orbit.session.close).
function M.close(profile_name)
  session.close(profile_name)
end

-- Check whether a profile currently has a live, connected session process.
-- Returns: boolean.
function M.connected(profile_name)
  return session.connected(profile_name)
end

return M
