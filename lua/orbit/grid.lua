local M = {}

function M.serialize(value)
  if value == nil then
    return ""
  end
  if value == vim.NIL then
    return "NULL"
  end
  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    return ok and encoded or vim.inspect(value)
  end
  return tostring(value)
end

local function display(value, max_width)
  local text = M.serialize(value):gsub("[\r\n]+", " ")
  if #text > max_width then
    return text:sub(1, math.max(1, max_width - 3)) .. "..."
  end
  return text
end

local function columns_for(rows)
  local present = {}
  for _, row in ipairs(rows) do
    for column in pairs(row) do
      present[column] = true
    end
  end

  local columns = vim.tbl_keys(present)
  table.sort(columns)
  return columns
end

function M.render(rows, options)
  options = options or {}
  local limit = options.limit or 200
  local max_cell_width = options.max_cell_width or 48
  local count = math.min(#rows, limit)
  local columns = columns_for(rows)
  local rendered = {}
  local raw_rows = {}

  for index = 1, count do
    local row = {}
    local raw = {}
    for column_index, column in ipairs(columns) do
      local value = rows[index][column]
      row[column_index] = display(value, max_cell_width)
      raw[column_index] = value
    end
    rendered[index] = row
    raw_rows[index] = raw
  end

  return {
    columns = columns,
    rows = rendered,
    raw_rows = raw_rows,
    limited = #rows > limit,
  }
end

function M.layout(grid, source)
  if #grid.columns == 0 then
    return { "Orbit Results: " .. source, "No rows returned.", "q close  y copy  <CR> inspect" }, {}
  end

  local widths = {}
  for index, column in ipairs(grid.columns) do
    widths[index] = #column
  end
  for _, row in ipairs(grid.rows) do
    for index, cell in ipairs(row) do
      widths[index] = math.max(widths[index], #cell)
    end
  end

  local function row_line(row)
    local cells = {}
    for index, cell in ipairs(row) do
      cells[index] = cell .. string.rep(" ", widths[index] - #cell)
    end
    return "| " .. table.concat(cells, " | ") .. " |"
  end

  local separator = {}
  for index, width in ipairs(widths) do
    separator[index] = string.rep("-", width)
  end
  local lines = {
    "Orbit Results: " .. source,
    row_line(grid.columns),
    "|-" .. table.concat(separator, "-|-") .. "-|",
  }
  for _, row in ipairs(grid.rows) do
    table.insert(lines, row_line(row))
  end
  if grid.limited then
    table.insert(lines, string.format("Showing the first %d rows.", #grid.rows))
  end
  table.insert(lines, "q close  y copy raw value  <CR> inspect  <C-d>/<C-u> page  zh/zl scroll")
  return lines, widths
end

function M.cell_at(grid, widths, line, column)
  local row = line - 3
  if row < 1 or not grid.raw_rows[row] then
    return nil
  end
  local start = 2
  for index, width in ipairs(widths) do
    if column >= start and column < start + width then
      return { column = index, row = row }
    end
    start = start + width + 3
  end
end

function M.move(grid, widths, cell, row_delta, column_delta)
  if not cell then
    return nil
  end
  return {
    column = math.max(1, math.min(#widths, cell.column + column_delta)),
    row = math.max(1, math.min(#grid.raw_rows, cell.row + row_delta)),
  }
end

function M.cursor_for(widths, cell)
  local start = 2
  for index = 1, cell.column - 1 do
    start = start + widths[index] + 3
  end
  return { cell.row + 3, start }
end

return M
