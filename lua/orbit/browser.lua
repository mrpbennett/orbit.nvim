local profiles = require("orbit.profiles")
local schema = require("orbit.schema")
local cache = require("orbit.schema_cache")
local feedback = require("orbit.feedback")
local adapters = require("orbit.adapters")
local results = require("orbit.results")
local runner = require("orbit.runner")

local M = {}
local tab_browsers = {}

local function object_name(row)
  return table.concat(vim.tbl_filter(function(value)
    return value and value ~= ""
  end, { row.catalog, row.schema, row.name }), ".")
end

local function postgres_name(row)
  local quote = function(value)
    return '"' .. value:gsub('"', '""') .. '"'
  end
  return table.concat({ quote(row.schema or "public"), quote(row.name) }, ".")
end

local function set_lines(state, lines)
  -- Ignore this programmatic redraw in the attached filter-edit callback.
  state.rendering = true
  vim.bo[state.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(state.buffer, 1, -1, false, lines)
  if not state.filtering then
    vim.bo[state.buffer].modifiable = false
  end
  state.rendering = false
end

local function filter_text(state)
  local line = vim.api.nvim_buf_get_lines(state.buffer, 0, 1, false)[1] or "Filter: "
  return line:sub(#"Filter: " + 1)
end

local function render(state)
  local lines = {
    "Filter: " .. state.filter,
    state.profile.name .. " (" .. state.profile.kind .. ")",
    "Tables and views:",
  }
  state.rows_by_line = {}
  local matches = schema.filter(state.tables, state.filter)
  if #matches == 0 then
    table.insert(lines, "  No matching tables or views")
  end
  for _, row in ipairs(matches) do
    local name = object_name(row)
    local expanded = state.expanded[name]
    local marker = expanded and "[-]" or "[+]"
    table.insert(lines, string.format("  %s %s  %s", marker, row.type or "table", name))
    state.rows_by_line[#lines] = row
    if expanded then
      local columns = state.columns[name]
      if columns then
        for _, column in ipairs(columns) do
          table.insert(lines, string.format("      %s  %s", column.name, column.type or ""))
        end
      else
        table.insert(lines, "      loading columns...")
      end
    end
  end
  set_lines(state, vim.list_slice(lines, 2, #lines))
  vim.api.nvim_buf_add_highlight(state.buffer, -1, "OrbitHeader", 1, 0, -1)
end

local function refresh(state, force)
  state.generation = state.generation + 1
  local generation = state.generation
  local notice = feedback.start("Loading schema for " .. state.profile.name .. "...")
  cache.load_tables(state.profile, { refresh = force }, function(rows, run_err)
    -- A refresh or closed buffer makes older acquisitions irrelevant.
    if not vim.api.nvim_buf_is_valid(state.buffer) or state.generation ~= generation then
      return
    end
    if run_err then
      feedback.finish(notice, "Schema load failed: " .. state.profile.name, vim.log.levels.ERROR)
      render(state)
      vim.notify(run_err, vim.log.levels.ERROR)
      return
    end
    feedback.finish(notice, string.format("Schema loaded: %d objects", #rows))
    state.tables = rows
    if force then
      state.columns = {}
      state.expanded = {}
    end
    render(state)
  end)
end

local function refresh_profile(state)
  local document, load_err = profiles.load(state.config.profile_path)
  if not document then
    vim.notify(load_err, vim.log.levels.ERROR)
    return
  end
  local profile = profiles.find(document, state.profile.name)
  if not profile then
    vim.notify("Unknown Orbit profile: " .. state.profile.name, vim.log.levels.ERROR)
    return
  end
  state.profile = profile
  refresh(state, true)
end

local function toggle_columns(state, row)
  local name = object_name(row)
  if state.expanded[name] then
    state.expanded[name] = nil
    render(state)
    return
  end
  state.expanded[name] = true
  -- Expand first so the UI can show loading; completion also requires the node remain open.
  if state.columns[name] then
    render(state)
    return
  end
  render(state)
  local notice = feedback.start("Loading columns for " .. name .. "...")
  local generation = state.generation
  cache.load_columns(state.profile, row, {}, function(columns, run_err)
    if not vim.api.nvim_buf_is_valid(state.buffer) or state.generation ~= generation or not state.expanded[name] then
      return
    end
    state.columns[name] = run_err and {} or columns
    feedback.finish(notice, run_err and "Column load failed: " .. name or string.format("Columns loaded: %d", #columns), run_err and vim.log.levels.ERROR or vim.log.levels.INFO)
    render(state)
    if run_err then
      vim.notify(run_err, vim.log.levels.ERROR)
    end
  end)
end

local function open_statement(state, statement)
  vim.cmd("new")
  vim.bo.filetype = "sql"
  vim.b.orbit_profile = state.profile.name
  require("orbit.completion").attach(0)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(statement, "\n", { plain = true }))
end

local function run_action(state, row, action)
  if action.kind == "query_buffer" then
    open_statement(state, action.statement)
    return
  end
  local source_window = state.window
  -- Capture the origin before asynchronous work so results return to the correct tab/window.
  local tabpage = vim.api.nvim_get_current_tabpage()
  local notice = feedback.start("Loading " .. action.label:lower() .. " for " .. object_name(row) .. "...")
  runner.run(state.profile, action.statement, function(rows, run_err)
    if run_err then
      feedback.finish(notice, "Schema action failed: " .. action.label, vim.log.levels.ERROR)
      vim.notify(run_err, vim.log.levels.ERROR)
      return
    end
    feedback.finish(notice, string.format("Loaded %s: %d rows", action.label:lower(), #rows))
    results.open(rows, {
      height = state.config.result_height,
      limit = state.config.result_limit,
      max_cell_width = state.config.max_cell_width,
      profile_name = state.profile.name,
      source_name = action.label .. " / " .. object_name(row),
      source_window = source_window,
      tabpage = tabpage,
    })
  end)
end

local function select_action(state, row)
  local actions, action_err = adapters.object_actions(state.profile, row, state.config.result_limit)
  if not actions then
    vim.notify(action_err, vim.log.levels.ERROR)
    return
  end
  vim.ui.select(actions, {
    prompt = "Orbit action for " .. object_name(row),
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
      run_action(state, row, action)
    end
  end)
end

local function copy_name(state, row)
  local name = row.name
  if state.profile.kind == "trino" then
    name = table.concat({ row.catalog or state.profile.options.catalog, row.schema or state.profile.options.schema, row.name }, ".")
  elseif state.profile.kind == "postgres" then
    name = postgres_name(row)
  end
  vim.fn.setreg('"', name)
  vim.notify("Orbit name copied")
end

local function focus_filter(state)
  vim.api.nvim_set_current_win(state.window)
  state.filtering = true
  vim.bo[state.buffer].modifiable = true
  vim.api.nvim_win_set_cursor(state.window, { 1, #"Filter: " + #state.filter })
  vim.api.nvim_feedkeys("a", "n", false)
end

local function show_help()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Orbit Schema Browser",
    "",
    "h/l collapse/expand  <CR> expand  a actions  s sample statement  y copy name",
    "r refresh  / filter  q close",
  })
  vim.bo[buffer].modifiable = false
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    col = math.floor((vim.o.columns - 72) / 2),
    height = 4,
    relative = "editor",
    row = math.floor((vim.o.lines - 6) / 2),
    style = "minimal",
    title = " Orbit Help ",
    title_pos = "center",
    width = 72,
  })
  for _, key in ipairs({ "q", "?", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(window, true)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit help" })
  end
end

local function create_browser(profile, config)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].filetype = "orbit-schema"
  vim.cmd("topleft vsplit")
  local window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(window, buffer)
  vim.api.nvim_win_set_width(window, config.schema_width or 36)

  local state = {
    buffer = buffer,
    columns = {},
    config = config,
    expanded = {},
    filter = "",
    filtering = false,
    generation = 0,
    profile = profile,
    rows_by_line = {},
    tables = {},
    window = window,
  }
  local tabpage = vim.api.nvim_get_current_tabpage()
  tab_browsers[tabpage] = state

  vim.api.nvim_buf_attach(buffer, false, {
    on_lines = function()
      -- Only edits made by filter mode update state; render writes are ignored above.
      if vim.bo[buffer].modifiable and not state.rendering then
        state.filter = filter_text(state)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buffer) then
            render(state)
          end
        end)
      end
    end,
  })
  vim.keymap.set("n", "/", function()
    focus_filter(state)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Filter Orbit schema" })
  vim.keymap.set("i", "<Esc>", function()
    state.filtering = false
    vim.bo[buffer].modifiable = false
    return "<Esc>"
  end, { buffer = buffer, expr = true, silent = true, desc = "Finish Orbit filter" })
  vim.keymap.set("n", "r", function()
    refresh_profile(state)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Refresh Orbit schema" })
  vim.keymap.set("n", "h", function()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row and state.expanded[object_name(row)] then
      toggle_columns(state, row)
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Collapse Orbit columns" })
  local function expand_current_row()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row and not state.expanded[object_name(row)] then
      toggle_columns(state, row)
    end
  end
  vim.keymap.set("n", "l", expand_current_row, { buffer = buffer, silent = true, nowait = true, desc = "Expand Orbit columns" })
  vim.keymap.set("n", "<CR>", expand_current_row, { buffer = buffer, silent = true, nowait = true, desc = "Expand Orbit columns" })
  vim.keymap.set("n", "s", function()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row then
      local actions, action_err = adapters.object_actions(state.profile, row, state.config.result_limit)
      if not actions then
        vim.notify(action_err, vim.log.levels.ERROR)
        return
      end
      for _, action in ipairs(actions) do
        if action.id == "sample" then
          run_action(state, row, action)
          return
        end
      end
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Open Orbit sample statement" })
  vim.keymap.set("n", "a", function()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row then
      select_action(state, row)
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Select Orbit schema object action" })
  vim.keymap.set("n", "y", function()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row then
      copy_name(state, row)
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Orbit object name" })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(window, true)
    tab_browsers[tabpage] = nil
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit schema" })
  vim.keymap.set("n", "?", show_help, { buffer = buffer, silent = true, nowait = true, desc = "Show Orbit help" })
  state.rendering = true
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Filter: " })
  vim.bo[buffer].modifiable = false
  state.rendering = false
  return state
end

function M.open(config, name, buffer, search)
  local document, load_err = profiles.load(config.profile_path)
  if not document then
    vim.notify(load_err, vim.log.levels.ERROR)
    return
  end
  name = name or vim.b[buffer or vim.api.nvim_get_current_buf()].orbit_profile or config.default_profile
  if not name then
    vim.ui.select(document.profiles, {
      prompt = "Browse Orbit profile",
      format_item = function(profile)
        return profile.name .. " (" .. profile.kind .. ")"
      end,
    }, function(profile)
      if profile then
        M.open(config, profile.name, buffer, search)
      end
    end)
    return
  end

  local profile = profiles.find(document, name)
  if not profile then
    vim.notify("Unknown Orbit profile: " .. name, vim.log.levels.ERROR)
    return
  end
  local tabpage = vim.api.nvim_get_current_tabpage()
  local state = tab_browsers[tabpage]
  if state and vim.api.nvim_win_is_valid(state.window) and state.profile.name == profile.name then
    vim.api.nvim_set_current_win(state.window)
  elseif state and vim.api.nvim_win_is_valid(state.window) then
    -- Each tabpage owns one browser; changing profiles resets its display and invalidates callbacks.
    state.profile = profile
    state.tables = {}
    state.columns = {}
    state.expanded = {}
    state.filter = ""
    state.generation = state.generation + 1
    vim.api.nvim_set_current_win(state.window)
    vim.bo[state.buffer].modifiable = true
    vim.api.nvim_buf_set_lines(state.buffer, 0, 1, false, { "Filter: " })
    vim.bo[state.buffer].modifiable = false
    refresh(state)
  else
    state = create_browser(profile, config)
    refresh(state)
  end
  if search then
    focus_filter(state)
  end
end

return M
