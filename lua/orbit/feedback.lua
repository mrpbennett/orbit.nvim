local M = {}

local function notify(message, level, options)
  return vim.notify(message, level, vim.tbl_extend("force", { title = "Orbit" }, options or {}))
end

local function progress(state)
  local elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
  vim.api.nvim_echo({ { string.format("%s (%ds)", state.message, elapsed), "None" } }, false, {})
end

function M.start(message)
  -- Echo supplies in-place progress while the command runs; completion emits a bounded notification.
  local state = { message = message, started_at = vim.uv.hrtime() }
  progress(state)
  state.timer = vim.uv.new_timer()
  state.timer:start(1000, 1000, vim.schedule_wrap(function()
    if state.done then
      return
    end
    progress(state)
  end))
  return state
end

function M.finish(state, message, level)
  if state and state.timer then
    state.done = true
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  local options = { timeout = level == vim.log.levels.ERROR and 8000 or 3000 }
  if state and state.id then
    options.replace = state.id
  end
  notify(message, level or vim.log.levels.INFO, options)
end

return M
