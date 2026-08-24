local profiles = require("quarry.profiles")
local diagnostics = require("quarry.diagnostics")
local feedback = require("quarry.feedback")
local results = require("quarry.results")
local runner = require("quarry.runner")
local statements = require("quarry.statements")

local M = {}
local running = {}

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

local function requires_confirmation(statement)
  local without_comments = statement:gsub("^%s*%-%-[^\n]*\n", ""):gsub("^%s*/%*.-%*/", "")
  local keyword = without_comments:lower():match("^%s*([%a]+)")
  local semicolons = select(2, without_comments:gsub(";", ""))
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

local function stop_timer(state)
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

function M.profile_for_buffer(buffer, config)
  local document, load_err = profiles.load(config.profile_path)
  if not document then
    return nil, load_err
  end
  local name = vim.b[buffer].quarry_profile
  if not name then
    return nil, "select a connection profile first"
  end
  local profile = profiles.find(document, name)
  if not profile then
    return nil, string.format("connection profile %q does not exist", name)
  end
  return profile
end

function M.select_profile(buffer, config, on_select)
  require("quarry.workspace").select_profile(config, buffer, on_select)
end

function M.bind_profile(buffer, profile)
  vim.b[buffer].quarry_profile = profile.name
  require("quarry.completion").attach(buffer)
  require("quarry.completion").prewarm(profile)
  vim.notify("Quarry profile: " .. profile.name)
end

function M.execute(buffer, config, selection)
  local profile, profile_err = M.profile_for_buffer(buffer, config)
  if not profile then
    vim.notify(profile_err, vim.log.levels.ERROR)
    M.select_profile(buffer, config, function()
      M.execute(buffer, config, selection)
    end)
    return
  end

  local statement, statement_err = statements.target({
    lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    selection = selection,
  })
  if not statement then
    vim.notify(statement_err, vim.log.levels.ERROR)
    return
  end

  if config.confirm_mutations and profile.options.confirm_mutations ~= false and requires_confirmation(statement) then
    local choice = vim.fn.confirm("Execute mutating statement?", "&Execute\n&Cancel", 2)
    if choice ~= 1 then
      return
    end
  end

  if running[buffer] then
    vim.notify("A Quarry statement is already running in this buffer", vim.log.levels.WARN)
    return
  end

  local notice = feedback.start("Connecting to " .. profile.name .. "...")
  local state = {
    cancelled = false,
    profile_name = profile.name,
    started_at = vim.uv.hrtime(),
    tabpage = vim.api.nvim_get_current_tabpage(),
    window = vim.api.nvim_get_current_win(),
    notice = notice,
  }
  running[buffer] = state
  state.timer = vim.uv.new_timer()
  state.timer:start(0, 1000, vim.schedule_wrap(function()
    vim.cmd.redrawstatus()
  end))
  vim.cmd.redrawstatus()
  state.process = runner.run(profile, statement, function(rows, run_err)
    if running[buffer] ~= state then
      return
    end
    running[buffer] = nil
    stop_timer(state)
    vim.cmd.redrawstatus()
    if state.cancelled then
      feedback.finish(state.notice, "Query cancelled: " .. profile.name, vim.log.levels.WARN)
      return
    end
    if run_err then
      feedback.finish(state.notice, "Query failed: " .. profile.name, vim.log.levels.ERROR)
      vim.notify(run_err, vim.log.levels.ERROR)
      diagnostics.open(run_err)
      return
    end
    local result_options = {
      height = config.result_height,
      limit = config.result_limit,
      max_cell_width = config.max_cell_width,
      focus = config.focus_results,
      profile_name = profile.name,
      source_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":t") ~= "" and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":t") or "[No Name]",
      source_window = state.window,
      tabpage = state.tabpage,
      elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000),
    }
    local workspace = require("quarry.workspace")
    if workspace.is_workspace(state.tabpage) then
      workspace.open_results(rows, result_options)
    else
      results.open(rows, result_options)
    end
    feedback.finish(state.notice, string.format("Query finished: %d rows in %ds", #rows, math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)))
  end)
end

function M.cancel(buffer)
  if not running[buffer] then
    vim.notify("No Quarry statement is running in this buffer", vim.log.levels.INFO)
    return
  end
  running[buffer].cancelled = true
  feedback.finish(running[buffer].notice, "Cancelling query...")
  runner.cancel(running[buffer].process)
end

function M.status(buffer, config)
  local state = running[buffer]
  local profile_name = state and state.profile_name or vim.b[buffer].quarry_profile
  if not profile_name then
    return "Quarry: no profile"
  end
  if state then
    local elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
    return string.format("Quarry: %s [%ds]", profile_name, elapsed)
  end
  return "Quarry: " .. profile_name
end

return M
