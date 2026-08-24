local grid_model = require("quarry.grid")

local M = {}
local tab_results = {}

function M.render(rows, options)
  return grid_model.render(rows, options)
end

local function selected_cell(window, grid, widths)
  local cursor = vim.api.nvim_win_get_cursor(window)
  return grid_model.cell_at(grid, widths, cursor[1], cursor[2])
end

local function move_cell(window, grid, widths, row_delta, column_delta)
  local cell = selected_cell(window, grid, widths)
  if not cell then
    return
  end
  local target = grid_model.move(grid, widths, cell, row_delta, column_delta)
  vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, target))
end

local function inspect(value)
  if value == nil then
    return
  end
  local contents = grid_model.serialize(value)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(contents, "\n", { plain = true }))
  if pcall(vim.json.decode, contents) then
    vim.bo[buffer].filetype = "json"
  end
  vim.bo[buffer].modifiable = false

  local width = math.min(math.max(40, vim.o.columns - 8), 100)
  local height = math.min(math.max(3, #vim.api.nvim_buf_get_lines(buffer, 0, -1, false)), math.max(3, vim.o.lines - 6))
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    col = math.floor((vim.o.columns - width) / 2),
    height = height,
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    title = " Quarry Value ",
    title_pos = "center",
    width = width,
  })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(window, true)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Quarry value" })
  vim.keymap.set("n", "y", function()
    vim.fn.setreg('"', contents)
    vim.notify("Quarry value copied")
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Quarry value" })
end

function M.open(rows, options)
  options = options or {}
  local grid = M.render(rows, options)
  local original_window = vim.api.nvim_get_current_win()
  local original_tabpage = vim.api.nvim_get_current_tabpage()
  local tabpage = options.tabpage or original_tabpage
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    vim.api.nvim_set_current_tabpage(tabpage)
  else
    tabpage = vim.api.nvim_get_current_tabpage()
  end
  local source_window = options.source_window
  if not source_window or not vim.api.nvim_win_is_valid(source_window) then
    source_window = vim.api.nvim_get_current_win()
  end
  local state = tab_results[tabpage]
  local buffer
  local window
  local placeholder
  if state and vim.api.nvim_win_is_valid(state.window) and vim.api.nvim_buf_is_valid(state.buffer) then
    buffer = state.buffer
    window = state.window
  else
    buffer = vim.api.nvim_create_buf(false, true)
    vim.cmd("botright new")
    window = vim.api.nvim_get_current_win()
    placeholder = vim.api.nvim_win_get_buf(window)
    tab_results[tabpage] = { buffer = buffer, window = window }
  end
  local row_count = #grid.rows
  local truncation = grid.limited and "+" or ""
  local elapsed = options.elapsed and string.format(" | %ds", options.elapsed) or ""
  local source = string.format("%s / %s | %d%s rows%s", options.profile_name or "unknown profile", options.source_name or "[No Name]", row_count, truncation, elapsed)
  local lines, widths = grid_model.layout(grid, source)
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = "quarry-results"
  vim.api.nvim_win_set_buf(window, buffer)
  if placeholder and vim.api.nvim_buf_is_valid(placeholder) and vim.bo[placeholder].buflisted then
    vim.api.nvim_buf_delete(placeholder, { force = true })
  end
  vim.api.nvim_win_set_height(window, options.height or 15)
  vim.wo[window].winbar = ""
  if #grid.rows > 0 then
    vim.api.nvim_win_set_cursor(window, { 4, 2 })
  end
  vim.api.nvim_buf_clear_namespace(buffer, -1, 0, -1)
  vim.api.nvim_buf_add_highlight(buffer, -1, "QuarryHeader", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buffer, -1, "QuarryHeader", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buffer, -1, "QuarryHint", #lines - 1, 0, -1)

  vim.keymap.set("n", "q", function()
    if options.on_quit then
      options.on_quit(window, source_window)
      return
    end
    vim.api.nvim_win_close(window, true)
    if tab_results[tabpage] and tab_results[tabpage].window == window then
      tab_results[tabpage] = nil
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Quarry results" })
  vim.keymap.set("n", "<CR>", function()
    local cell = selected_cell(window, grid, widths)
    inspect(cell and grid.raw_rows[cell.row][cell.column])
  end, { buffer = buffer, silent = true, nowait = true, desc = "Inspect Quarry value" })
  vim.keymap.set("n", "y", function()
    local cell = selected_cell(window, grid, widths)
    local value = cell and grid.raw_rows[cell.row][cell.column]
    if value ~= nil then
      vim.fn.setreg('"', grid_model.serialize(value))
      vim.notify("Quarry value copied")
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Quarry value" })
  vim.keymap.set("n", "h", function()
    move_cell(window, grid, widths, 0, -1)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Quarry cell left" })
  vim.keymap.set("n", "j", function()
    move_cell(window, grid, widths, 1, 0)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Quarry cell down" })
  vim.keymap.set("n", "k", function()
    move_cell(window, grid, widths, -1, 0)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Quarry cell up" })
  vim.keymap.set("n", "l", function()
    move_cell(window, grid, widths, 0, 1)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Quarry cell right" })

  if options.focus then
    vim.api.nvim_set_current_win(window)
  elseif vim.api.nvim_win_is_valid(original_window) and vim.api.nvim_tabpage_is_valid(original_tabpage) then
    vim.api.nvim_set_current_tabpage(original_tabpage)
    vim.api.nvim_set_current_win(original_window)
  elseif vim.api.nvim_win_is_valid(source_window) then
    vim.api.nvim_set_current_win(source_window)
  end
  return { buffer = buffer, window = window, grid = grid }
end

return M
