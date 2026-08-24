local profiles = require("quarry.profiles")
local schema = require("quarry.schema")
local cache = require("quarry.schema_cache")
local feedback = require("quarry.feedback")

local M = {}
local tab_browsers = {}

local function object_name(row)
  return row.schema and row.schema .. "." .. row.name or row.name
end

local function set_lines(state, lines)
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
  vim.api.nvim_buf_add_highlight(state.buffer, -1, "QuarryHeader", 1, 0, -1)
end

local function refresh(state, force)
  state.generation = state.generation + 1
  local generation = state.generation
  local notice = feedback.start("Loading schema for " .. state.profile.name .. "...")
  cache.load_tables(state.profile, { refresh = force }, function(rows, run_err)
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
    vim.notify("Unknown Quarry profile: " .. state.profile.name, vim.log.levels.ERROR)
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

local function sample_statement(state, row)
  local quoted = '"' .. row.name:gsub('"', '""') .. '"'
  if row.schema then
    quoted = '"' .. row.schema:gsub('"', '""') .. '".' .. quoted
  end
  vim.cmd("new")
  vim.bo.filetype = "sql"
  vim.b.quarry_profile = state.profile.name
  require("quarry.completion").attach(0)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "SELECT *",
    "FROM " .. quoted,
    "LIMIT " .. tostring(state.config.result_limit) .. ";",
  })
end

local function copy_name(state, row)
  local name = row.name
  if state.profile.kind == "trino" then
    name = table.concat({ state.profile.options.catalog, row.schema or state.profile.options.schema, row.name }, ".")
  end
  vim.fn.setreg('"', name)
  vim.notify("Quarry name copied")
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
    "Quarry Schema Browser",
    "",
    "h/l collapse/expand  <CR> expand  s sample statement  y copy name",
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
    title = " Quarry Help ",
    title_pos = "center",
    width = 72,
  })
  for _, key in ipairs({ "q", "?", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(window, true)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Close Quarry help" })
  end
end

local function create_browser(profile, config)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].filetype = "quarry-schema"
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
  end, { buffer = buffer, silent = true, nowait = true, desc = "Filter Quarry schema" })
  vim.keymap.set("i", "<Esc>", function()
    state.filtering = false
    vim.bo[buffer].modifiable = false
    return "<Esc>"
  end, { buffer = buffer, expr = true, silent = true, desc = "Finish Quarry filter" })
  vim.keymap.set("n", "r", function()
    refresh_profile(state)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Refresh Quarry schema" })
  vim.keymap.set("n", "h", function()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row and state.expanded[object_name(row)] then
      toggle_columns(state, row)
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Collapse Quarry columns" })
  local function expand_current_row()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row and not state.expanded[object_name(row)] then
      toggle_columns(state, row)
    end
  end
  vim.keymap.set("n", "l", expand_current_row, { buffer = buffer, silent = true, nowait = true, desc = "Expand Quarry columns" })
  vim.keymap.set("n", "<CR>", expand_current_row, { buffer = buffer, silent = true, nowait = true, desc = "Expand Quarry columns" })
  vim.keymap.set("n", "s", function()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row then
      sample_statement(state, row)
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Open Quarry sample statement" })
  vim.keymap.set("n", "y", function()
    local row = state.rows_by_line[vim.api.nvim_win_get_cursor(window)[1]]
    if row then
      copy_name(state, row)
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Quarry object name" })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(window, true)
    tab_browsers[tabpage] = nil
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Quarry schema" })
  vim.keymap.set("n", "?", show_help, { buffer = buffer, silent = true, nowait = true, desc = "Show Quarry help" })
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
  name = name or vim.b[buffer or vim.api.nvim_get_current_buf()].quarry_profile or config.default_profile
  if not name then
    vim.ui.select(document.profiles, {
      prompt = "Browse Quarry profile",
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
    vim.notify("Unknown Quarry profile: " .. name, vim.log.levels.ERROR)
    return
  end
  local tabpage = vim.api.nvim_get_current_tabpage()
  local state = tab_browsers[tabpage]
  if state and vim.api.nvim_win_is_valid(state.window) and state.profile.name == profile.name then
    vim.api.nvim_set_current_win(state.window)
  elseif state and vim.api.nvim_win_is_valid(state.window) then
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
