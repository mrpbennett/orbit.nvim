-- orbit/feedback.lua
--
-- Responsible for giving the user quick, low-friction feedback about
-- long-running Orbit operations (mainly: running a SQL query). It has two
-- jobs:
--   1. Show a "still working..." progress message with an elapsed-time
--      counter while something is in flight (M.start / the internal
--      `progress` helper).
--   2. Show a final success/error notification when the operation finishes
--      (M.finish), replacing the in-progress message so the user doesn't end
--      up with two separate messages for one operation.
--
-- Other modules (like the query runner) call M.start(...) right before
-- kicking off an async operation, keep the returned `state` table around,
-- and call M.finish(state, ...) once the operation completes or fails. This
-- module has no knowledge of SQL or connections -- it's purely a small UX
-- helper built on top of vim.notify / vim.api.nvim_echo / vim.uv (Neovim's
-- libuv bindings, used here for timers and high-resolution timestamps).
--
-- Exports:
--   M.start(message)  -> state table (opaque handle, pass it to M.finish)
--   M.finish(state, message, level) -> nothing
local M = {}

-- Thin wrapper around vim.notify that always tags the notification with the
-- title "Orbit", so every message the plugin shows looks consistent and is
-- easy to recognize among notifications from other plugins.
--
-- Parameters:
--   message (string) - the text to show in the notification.
--   level (number|nil) - one of the vim.log.levels.* constants (INFO, WARN,
--     ERROR, ...). Controls how the notification is styled/prioritized.
--   options (table|nil) - extra options forwarded to vim.notify (e.g.
--     `timeout`, `replace`). `title` is always forced to "Orbit" even if the
--     caller passed a different title.
--
-- Returns: whatever vim.notify returns (implementation-defined; often a
-- notification handle/id depending on the notification backend/plugin).
--
-- Side effects: calls vim.notify, which may draw UI (a popup, a message in
-- the message history, etc.) depending on the user's notification setup.
local function notify(message, level, options)
  -- vim.tbl_extend("force", a, b) merges table `b` into `a`, with `b`'s keys
  -- winning on conflicts ("force"). Here that guarantees `title = "Orbit"`
  -- always wins even if `options` also had a `title` key.
  return vim.notify(message, level, vim.tbl_extend("force", { title = "Orbit" }, options or {}))
end

-- Renders one frame of the "still working" progress indicator using
-- vim.api.nvim_echo, which prints directly to the command-line area (like
-- typing `:echo` would) instead of creating a persistent notification. This
-- is intentional: echoed messages are cheap to overwrite every second
-- without piling up a new notification each time.
--
-- Parameters:
--   state (table) - the state created by M.start, expected to have:
--     state.message (string) - the label describing what's running.
--     state.started_at (number) - a vim.uv.hrtime() timestamp (nanoseconds)
--       captured when the operation began.
--
-- Returns: nothing.
--
-- Side effects: writes to Neovim's command-line/message area via
-- nvim_echo. Does not add to :messages history (the third argument `{}`
-- with no `history` flag keeps it transient).
local function progress(state)
  -- vim.uv.hrtime() returns a monotonic clock reading in nanoseconds, so
  -- subtracting the start time and dividing by 1e9 converts that to whole
  -- elapsed seconds.
  local elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
  vim.api.nvim_echo({ { string.format("%s (%ds)", state.message, elapsed), "None" } }, false, {})
end

-- Begins showing progress feedback for a long-running operation and starts a
-- repeating timer that refreshes the elapsed-time counter once per second.
-- Callers keep the returned `state` and pass it to M.finish() when the
-- operation is done.
--
-- Parameters:
--   message (string) - a short description of what's running, e.g.
--     "Running query".
--
-- Returns: state (table) - an opaque handle containing the message, start
-- time, and the running libuv timer. Treat it as a black box; only pass it
-- back into M.finish.
--
-- Side effects:
--   - Immediately echoes a first "0s" progress line via nvim_echo.
--   - Creates and starts a libuv timer (vim.uv.new_timer()) that fires every
--     1000ms and re-echoes the progress line with the updated elapsed time.
--     The timer keeps running until M.finish stops/closes it, so callers
--     MUST eventually call M.finish or the timer will tick forever.
function M.start(message)
  -- Echo supplies in-place progress while the command runs; completion emits a bounded notification.
  local state = { message = message, started_at = vim.uv.hrtime() }
  progress(state)
  state.timer = vim.uv.new_timer()
  -- vim.uv timers run their callback on libuv's event loop, not on Neovim's
  -- main "fast" event context, so touching the UI (nvim_echo) from inside it
  -- directly would be unsafe. vim.schedule_wrap defers the callback to run
  -- safely on Neovim's main loop instead.
  state.timer:start(1000, 1000, vim.schedule_wrap(function()
    -- `state.done` is set by M.finish once the operation has completed; if
    -- the timer fires after that point (a race is possible since the timer
    -- is only stopped, not instantly prevented from firing again) we must
    -- skip re-echoing, otherwise a stale "still running" message could
    -- overwrite the final result message.
    if state.done then
      return
    end
    progress(state)
  end))
  return state
end

-- Stops the progress timer (if any) and shows the final result as a proper
-- notification (as opposed to the transient echo used while in progress).
--
-- Parameters:
--   state (table|nil) - the value returned by M.start for this operation.
--     May be nil if the caller never started a progress indicator (e.g. an
--     instant failure before any async work began); in that case this
--     function just notifies without trying to stop a timer.
--   message (string) - the final message to show the user.
--   level (number|nil) - one of vim.log.levels.* ; defaults to INFO if not
--     given. ERROR-level messages are shown for longer (8s vs 3s) since
--     they're more important to notice.
--
-- Returns: nothing.
--
-- Side effects:
--   - Stops and closes the libuv timer stored on `state` (if present) and
--     marks state.done = true so any already-scheduled tick is a no-op.
--   - Calls vim.notify (via the local `notify` helper) to show the final
--     message. If the notification backend supports it, `options.replace`
--     tells it to replace the previous notification with this id
--     (`state.id`) rather than stacking a new one -- this only works if the
--     caller / notify plugin populates state.id; this module does not set it
--     itself.
function M.finish(state, message, level)
  if state and state.timer then
    -- Mark done first so a timer tick that's already been scheduled (queued
    -- via vim.schedule_wrap right before we stop it) will see state.done and
    -- bail out instead of re-echoing a stale progress line.
    state.done = true
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  -- Errors stay on screen longer (8s) than routine info messages (3s) since
  -- they're more likely to need the user's full attention.
  local options = { timeout = level == vim.log.levels.ERROR and 8000 or 3000 }
  if state and state.id then
    options.replace = state.id
  end
  notify(message, level or vim.log.levels.INFO, options)
end

return M
