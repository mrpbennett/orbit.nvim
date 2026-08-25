local grid_model = require("orbit.grid")
local editable_result = require("orbit.editable_result")
local adapters = require("orbit.adapters")
local runner = require("orbit.runner")

local M = {}
local tab_results = {}
local result_sequence = 0

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
    title = " Orbit Value ",
    title_pos = "center",
    width = width,
  })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(window, true)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit value" })
  vim.keymap.set("n", "y", function()
    vim.fn.setreg('"', contents)
    vim.notify("Orbit value copied")
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Orbit value" })
end

function M.open(rows, options)
  options = options or {}
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
    -- Each tabpage keeps one reusable result grid rather than accumulating result splits.
    buffer = state.buffer
    window = state.window
  else
    buffer = vim.api.nvim_create_buf(false, true)
    vim.cmd("botright new")
    window = vim.api.nvim_get_current_win()
    placeholder = vim.api.nvim_win_get_buf(window)
    tab_results[tabpage] = { buffer = buffer, window = window }
  end
  for _, lhs in ipairs({ "i", "o", "O", "dd", "d", "V", "<Esc>", "u", "gg", "G" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buffer })
  end
  pcall(vim.api.nvim_clear_autocmds, { group = "OrbitResults" .. buffer, buffer = buffer })
  local model = options.editable and editable_result.new(rows) or nil
  local grid
  local widths
  local source
  local selection_anchor
  local visual = false
  local saving = false
  local inline_edit
  local function current_cell()
    return selected_cell(window, grid, widths)
  end
  local function selected_ids()
    local cell = current_cell()
    if not cell then
      return {}
    end
    local visible = editable_result.visible_rows(model)
    if not visual or not selection_anchor then
      return { visible[cell.row].id }
    end
    local first = math.min(selection_anchor, cell.row)
    local last = math.max(selection_anchor, cell.row)
    local ids = {}
    for index = first, last do
      ids[#ids + 1] = visible[index].id
    end
    return ids
  end
  local function render(cursor)
    local visible = model and editable_result.visible_rows(model) or rows
    grid = M.render(vim.tbl_map(function(row)
      return model and row.values or row
    end, visible), vim.tbl_extend("force", options, { columns = options.columns }))
    local row_count = #grid.rows
    local truncation = grid.limited and "+" or ""
    local elapsed = options.elapsed and string.format(" | %ds", options.elapsed) or ""
    local modified = model and editable_result.changed(model)
    source = string.format("%s / %s%s | %d%s rows%s", options.profile_name or "unknown profile", options.source_name or "[No Name]", modified and " [+]" or "", row_count, truncation, elapsed)
    local footer = model
        and "[Add Row] [Delete] [Save] [Rollback]  o/O add  dd delete  V select  :w save  :e! reload"
      or options.read_only_reason
      or "Read-only: open a Schema browser table sample to edit.  q close  y copy  <CR> inspect"
    local lines
    lines, widths = grid_model.layout(grid, source, footer)
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].modified = modified or false
    vim.api.nvim_buf_clear_namespace(buffer, -1, 0, -1)
    vim.api.nvim_buf_add_highlight(buffer, -1, "OrbitHeader", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buffer, -1, "OrbitHeader", 2, 0, -1)
    vim.api.nvim_buf_add_highlight(buffer, -1, "OrbitHint", #lines - 1, 0, -1)
    if model then
      local selected = {}
      for _, id in ipairs(selected_ids()) do
        selected[id] = true
      end
      for index, row in ipairs(editable_result.visible_rows(model)) do
        local group = row.state == "inserted" and "DiffAdd" or selected[row.id] and "Visual" or nil
        if group then
          vim.api.nvim_buf_add_highlight(buffer, -1, group, index + 4, 0, -1)
        end
      end
    end
    if cursor and #grid.rows > 0 then
      vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, cursor))
    end
  end
  render()
  if model then
    result_sequence = result_sequence + 1
    vim.bo[buffer].buftype = "acwrite"
    vim.api.nvim_buf_set_name(buffer, "orbit://results/" .. result_sequence)
  else
    vim.bo[buffer].buftype = "nofile"
  end
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "orbit-results"
  vim.api.nvim_win_set_buf(window, buffer)
  render({ row = 1, column = 1 })
  -- Only delete the split's listed placeholder, never an arbitrary user buffer.
  if placeholder and vim.api.nvim_buf_is_valid(placeholder) and vim.bo[placeholder].buflisted then
    vim.api.nvim_buf_delete(placeholder, { force = true })
  end
  vim.api.nvim_win_set_height(window, options.height or 15)
  vim.wo[window].winbar = ""
  vim.keymap.set("n", "q", function()
    if model and editable_result.changed(model) then
      vim.cmd("quit")
      return
    end
    if options.on_quit then
      options.on_quit(window, source_window)
      return
    end
    vim.api.nvim_win_close(window, true)
    if tab_results[tabpage] and tab_results[tabpage].window == window then
      tab_results[tabpage] = nil
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit results" })
  local function edit_cell()
    local cell = selected_cell(window, grid, widths)
    if not model then
      inspect(cell and grid.raw_rows[cell.row][cell.column])
      return
    end
    if not cell then
      return
    end
    local row = editable_result.visible_rows(model)[cell.row]
    local column = grid.columns[cell.column]
    local line, start = unpack(grid_model.cursor_for(widths, cell))
    local finish = start + widths[cell.column]

    -- The formatted grid remains model-owned; expose only this cell while inserting.
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_text(buffer, line - 1, start, line - 1, finish, { grid_model.serialize(row.values[column]) })
    local namespace = vim.api.nvim_create_namespace("OrbitInlineResultEdit")
    inline_edit = {
      cell = cell,
      column = column,
      finish = vim.api.nvim_buf_set_extmark(buffer, namespace, line - 1, start + #grid_model.serialize(row.values[column]), {
        right_gravity = true,
      }),
      namespace = namespace,
      row_id = row.id,
      start = vim.api.nvim_buf_set_extmark(buffer, namespace, line - 1, start, { right_gravity = false }),
    }
    vim.api.nvim_win_set_cursor(window, { line, start })
    vim.cmd("startinsert")
  end
  vim.keymap.set("n", "<CR>", edit_cell, { buffer = buffer, silent = true, nowait = true, desc = "Edit Orbit cell" })
  vim.keymap.set("n", "y", function()
    local cell = selected_cell(window, grid, widths)
    local value = cell and grid.raw_rows[cell.row][cell.column]
    if value ~= nil then
      vim.fn.setreg('"', grid_model.serialize(value))
      vim.notify("Orbit value copied")
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Orbit value" })
  vim.keymap.set("n", "h", function()
    move_cell(window, grid, widths, 0, -1)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell left" })
  vim.keymap.set("n", "j", function()
    move_cell(window, grid, widths, 1, 0)
    if model and visual then
      render(current_cell())
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell down" })
  vim.keymap.set("n", "k", function()
    move_cell(window, grid, widths, -1, 0)
    if model and visual then
      render(current_cell())
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell up" })
  vim.keymap.set("n", "l", function()
    move_cell(window, grid, widths, 0, 1)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell right" })
  if model then
    vim.keymap.set("n", "i", function()
      edit_cell()
    end, { buffer = buffer, silent = true, nowait = true, desc = "Edit Orbit cell" })
    vim.keymap.set("n", "o", function()
      local cell = current_cell()
      local row = editable_result.insert(model, cell and cell.row)
      local visible = editable_result.visible_rows(model)
      for index, candidate in ipairs(visible) do
        if candidate.id == row.id then
          render({ row = index, column = cell and cell.column or 1 })
          return
        end
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Insert Orbit row below" })
    vim.keymap.set("n", "O", function()
      local cell = current_cell()
      local row = editable_result.insert_before(model, cell and cell.row)
      local visible = editable_result.visible_rows(model)
      for index, candidate in ipairs(visible) do
        if candidate.id == row.id then
          render({ row = index, column = cell and cell.column or 1 })
          return
        end
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Insert Orbit row above" })
    vim.keymap.set("n", "dd", function()
      local cell = current_cell()
      local ids = selected_ids()
      editable_result.delete(model, ids)
      visual = false
      selection_anchor = nil
      local remaining = editable_result.visible_rows(model)
      render(#remaining > 0 and { row = math.min(cell.row, #remaining), column = cell.column } or nil)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Delete Orbit row" })
    vim.keymap.set("n", "d", function()
      if visual then
        vim.api.nvim_feedkeys("dd", "m", false)
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Delete selected Orbit rows" })
    vim.keymap.set("n", "V", function()
      local cell = current_cell()
      if cell then
        visual = true
        selection_anchor = cell.row
        render(cell)
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Select Orbit rows" })
    vim.keymap.set("n", "<Esc>", function()
      visual = false
      selection_anchor = nil
      local cell = current_cell()
      render(cell)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Clear Orbit row selection" })
    vim.keymap.set("n", "u", function()
      local cell = current_cell()
      if editable_result.undo(model) then
        render(cell)
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Undo Orbit edit" })
    vim.keymap.set("n", "gg", function()
      local cell = current_cell()
      if cell then
        vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, { row = 1, column = cell.column }))
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Go to first Orbit row" })
    vim.keymap.set("n", "G", function()
      local cell = current_cell()
      if cell and #grid.rows > 0 then
        vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, { row = #grid.rows, column = cell.column }))
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Go to last Orbit row" })
    local function reload(callback)
      callback = type(callback) == "function" and callback or function() end
      if not options.reload then
        callback()
        return
      end
      options.reload(function(reloaded, reload_err)
        if reload_err then
          vim.notify(reload_err, vim.log.levels.ERROR)
          model = editable_result.new(vim.tbl_map(function(row)
            return row.values
          end, editable_result.visible_rows(model)))
          render({ row = 1, column = 1 })
          callback(reload_err)
          return
        end
        model = editable_result.new(reloaded)
        visual = false
        selection_anchor = nil
        render({ row = 1, column = 1 })
        callback()
      end)
    end
    local function save()
      if saving or not editable_result.changed(model) then
        return
      end
      local statement, statement_err = adapters.mutation_statement(options.profile, options.editable, editable_result.changes(model))
      if not statement then
        vim.notify(statement_err, vim.log.levels.ERROR)
        return
      end
      if options.confirm_mutations ~= false and options.profile.options.confirm_mutations ~= false then
        if vim.fn.confirm("Write pending Orbit database changes?", "&Write\n&Cancel", 2) ~= 1 then
          return
        end
      end
      saving = true
      local completed = false
      runner.run(options.profile, statement, function(_, save_err)
        saving = false
        if save_err then
          vim.notify(save_err, vim.log.levels.ERROR)
          completed = true
          return
        end
        reload(function()
          completed = true
        end)
      end)
      if not vim.wait(30000, function()
        return completed
      end, 10) then
        vim.notify("Orbit write is still running; local changes remain pending", vim.log.levels.WARN)
      end
    end
    local group = vim.api.nvim_create_augroup("OrbitResults" .. buffer, { clear = true })
    vim.api.nvim_create_autocmd("InsertLeave", {
      buffer = buffer,
      group = group,
      callback = function()
        if not inline_edit then
          return
        end
        local edit = inline_edit
        inline_edit = nil
        local start = vim.api.nvim_buf_get_extmark_by_id(buffer, edit.namespace, edit.start, {})
        local finish = vim.api.nvim_buf_get_extmark_by_id(buffer, edit.namespace, edit.finish, {})
        vim.api.nvim_buf_clear_namespace(buffer, edit.namespace, 0, -1)
        if #start == 0 or #finish == 0 or start[1] ~= finish[1] then
          render(edit.cell)
          return
        end
        local value = vim.api.nvim_buf_get_text(buffer, start[1], start[2], finish[1], finish[2], {})[1]
        if value == "NULL" then
          value = vim.NIL
        end
        editable_result.set_value(model, edit.row_id, edit.column, value)
        render(edit.cell)
      end,
    })
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buffer,
      group = group,
      callback = save,
    })
    vim.api.nvim_create_autocmd("BufReadCmd", {
      buffer = buffer,
      group = group,
      callback = reload,
    })
  end

  if options.focus then
    vim.api.nvim_set_current_win(window)
  elseif vim.api.nvim_win_is_valid(original_window) and vim.api.nvim_tabpage_is_valid(original_tabpage) then
    -- Prefer the caller's context, falling back to the source window after tab changes.
    vim.api.nvim_set_current_tabpage(original_tabpage)
    vim.api.nvim_set_current_win(original_window)
  elseif vim.api.nvim_win_is_valid(source_window) then
    vim.api.nvim_set_current_win(source_window)
  end
  return { buffer = buffer, window = window, grid = grid }
end

return M
