-- orbit/process.lua
--
-- The process port: the one place Orbit starts a child process (a database
-- CLI such as psql, sqlite3, trino, redis-cli, or the SQL Server Java helper).
--
-- orbit/runner.lua (one-shot CLIs) and orbit/session.lua (retained CLIs) never
-- call vim.system directly. They call a `spawn` function, which defaults to
-- M.spawn below and can be replaced per call through a `deps.spawn` argument.
-- Two adapters satisfy this port:
--   * M.spawn            - the real adapter, backed by vim.system.
--   * tests/support/fake_process.lua - a fake that records writes and lets a
--     test push stdout/stderr chunks and exit codes by hand.
--
-- The port's interface (what every adapter must honour):
--
--   spawn(command, options, on_exit) -> handle
--     command  - list of strings: the executable followed by its arguments.
--     options  - table, all fields optional:
--                  stdin     = true to open a pipe the caller writes to,
--                  stdout    = function(err, data) called per output chunk,
--                  stderr    = function(err, data) called per error chunk,
--                  env       = table of environment variables,
--                  clear_env = true to start from an empty environment,
--                  text      = true to receive strings rather than bytes.
--                Chunks arrive in arbitrary sizes: one response may be split
--                across calls, and one call may carry several responses.
--     on_exit  - function(result) called once when the process exits, with
--                result = { code = number, stdout = string?, stderr = string? }.
--                stdout/stderr hold output not already streamed to callbacks.
--   handle:write(data) - send text to stdin (only when options.stdin = true).
--   handle:kill(signal) - ask the process to stop (Orbit sends 15, SIGTERM).
--
-- spawn may throw when the command cannot start (e.g. executable not found);
-- callers wrap it in pcall and report "cannot start CLI: ...".
local M = {}

-- The real adapter. vim.system already has exactly this shape.
function M.spawn(command, options, on_exit)
	return vim.system(command, options, on_exit)
end

return M
