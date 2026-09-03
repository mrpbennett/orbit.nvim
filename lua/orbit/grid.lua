-- orbit/grid.lua
--
-- This module turns raw query result rows (plain Lua tables of column ->
-- value, as produced by the connectors/parsers) into the text-based table
-- that is shown in the results buffer, plus the bookkeeping needed to let a
-- user navigate that text grid with the cursor and know which underlying
-- cell/row they are looking at.
--
-- It is purely about *rendering and coordinate math* -- it does not know
-- about buffers, windows, or Neovim APIs at all (that's handled by whatever
-- displays the buffer, e.g. `orbit.workspace`/`orbit.query`). Given rows it
-- produces:
--   1. `M.render` -- a "grid" struct: columns, display-truncated cell text,
--      and the original untouched values (raw_rows) for copy/inspect.
--   2. `M.layout` -- turns that grid into an array of plain-text lines
--      (what actually gets put in the buffer) plus each column's pixel/char
--      width.
--   3. `M.cell_at` / `M.move` / `M.cursor_for` -- convert between a cursor
--      position (line, column) in that rendered text and a logical
--      {row, column} cell reference, so keymaps can do things like "move
--      right one cell" or "what cell is the cursor on".
--
-- Exports (module table M): serialize, render, layout, cell_at, move,
-- cursor_for.

local M = {}

-- Convert an arbitrary Lua value coming back from a query into a string
-- suitable for copying or inspecting in full (i.e. NOT truncated for
-- display -- see `display()` below for the truncated version used in the
-- grid itself).
-- Parameters: value - any Lua value a database driver might hand back:
--   nil, vim.NIL (the JSON/msgpack "explicit null" sentinel Neovim uses),
--   a table (e.g. JSON object/array from the driver), or anything else
--   (numbers, strings, booleans).
-- Returns: a string representation:
--   nil          -> ""
--   vim.NIL      -> "NULL"
--   table        -> JSON-encoded if possible, else vim.inspect() fallback
--   otherwise    -> tostring(value)
function M.serialize(value)
  -- This raw representation is used for copy/inspect and must not inherit display truncation.
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

-- Build the truncated, single-line display text for one cell.
-- Parameters: value - the raw cell value (see M.serialize); max_width - the
-- maximum number of characters allowed for this cell's text.
-- Returns: a string with any newlines/carriage returns collapsed to spaces
-- (so a single cell can never break the table's line-based layout), and
-- truncated with a trailing "..." if it's longer than max_width.
local function display(value, max_width)
  local text = M.serialize(value):gsub("[\r\n]+", " ")
  if #text > max_width then
    return text:sub(1, math.max(1, max_width - 3)) .. "..."
  end
  return text
end

-- Figure out the full set of column names across all rows, since different
-- rows are not guaranteed to have exactly the same keys (e.g. sparse JSON
-- results). Parameters: rows - list of row tables (column name -> value).
-- Returns: a sorted list of column names, so column order is stable and
-- deterministic across renders.
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

-- Build a "grid" data structure from raw query result rows, ready to be
-- turned into text by M.layout. This is the main entry point callers (e.g.
-- orbit.query / orbit.workspace) use after a query finishes.
-- Parameters:
--   rows    - list of row tables (column name -> value), as produced by a
--             connector's parser.
--   options - optional table:
--     limit          - max number of rows to actually render (default 200);
--                       protects against huge result sets making the buffer
--                       unusable.
--     max_cell_width - max characters per cell before truncating with "..."
--                       (default 48).
--     columns        - explicit column list/order to use instead of
--                       inferring it from the rows.
-- Returns a grid table with:
--   columns  - ordered list of column names.
--   rows     - display-ready (string, possibly truncated) rows, capped at
--              `limit`.
--   raw_rows - the same rows but with untouched original values, aligned by
--              index with `rows`/`columns`, so features like "yank raw
--              value" or "inspect" can get back the real value.
--   limited  - true if `rows` (input) had more rows than `limit`, i.e. some
--              rows were cut off.
function M.render(rows, options)
  options = options or {}
  local limit = options.limit or 200
  local max_cell_width = options.max_cell_width or 48
  local count = math.min(#rows, limit)
  local columns = options.columns or columns_for(rows)
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

-- Turn a grid (from M.render) into plain text lines for display in a
-- results buffer, drawn as an ASCII table with "|" column separators and a
-- "-" header separator row, similar to a markdown table.
-- Parameters:
--   grid   - a grid table as returned by M.render.
--   source - a short label describing where the results came from (e.g. the
--            profile name), shown in the title line.
--   footer - optional custom footer/help text line; defaults to the
--            standard keymap hint line for the results buffer.
-- Returns:
--   lines  - list of strings, one per buffer line, ready to be set directly
--            into a buffer (e.g. via vim.api.nvim_buf_set_lines).
--   widths - list of column character-widths (index-aligned with
--            grid.columns), used later by M.cell_at/M.cursor_for to convert
--            between text columns and logical grid cells. Empty table when
--            there are no columns (nothing to navigate).
--
-- IMPORTANT: the fixed structure of the header here (title, blank line,
-- header row, separator row = 4 lines before the first data row) is exactly
-- what M.cell_at below assumes when mapping a cursor line back to a row
-- index -- if this layout changes, M.cell_at's offset must change too.
function M.layout(grid, source, footer)
  footer = footer or "q close  y copy raw value  <CR> inspect  <C-d>/<C-u> page  zh/zl scroll"
  if #grid.columns == 0 then
    return { "Orbit Results: " .. source, "No rows returned.", footer }, {}
  end

  -- Each column's width is the widest of its header text or any cell in
  -- that column, so nothing gets clipped when padded into a fixed-width
  -- table column.
  local widths = {}
  for index, column in ipairs(grid.columns) do
    widths[index] = #column
  end
  for _, row in ipairs(grid.rows) do
    for index, cell in ipairs(row) do
      widths[index] = math.max(widths[index], #cell)
    end
  end

  -- Render one row (a list of cell strings) as a single "| a | b | c |"
  -- line, padding each cell with spaces out to its column's fixed width.
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
    "",
    row_line(grid.columns),
    "|-" .. table.concat(separator, "-|-") .. "-|",
  }
  for _, row in ipairs(grid.rows) do
    table.insert(lines, row_line(row))
  end
  if grid.limited then
    table.insert(lines, string.format("Showing the first %d rows.", #grid.rows))
  end
  table.insert(lines, "")
  table.insert(lines, footer)
  return lines, widths
end

-- Given a cursor position in the rendered buffer (1-based line number and
-- 0-based byte column, matching Neovim's cursor() conventions), figure out
-- which logical grid cell (data row + column index) that position is over.
-- Parameters:
--   grid   - the grid table from M.render (used for raw_rows bounds).
--   widths - column widths from M.layout.
--   line   - 1-based buffer line number of the cursor.
--   column - 0-based character column of the cursor on that line.
-- Returns: { column = <column index>, row = <data row index> } if the
-- cursor is over an actual data cell, or nil if it's on the title, header,
-- separator, footer, or past the last row/column (e.g. in the padding
-- between cells or on the border "|" characters).
function M.cell_at(grid, widths, line, column)
  -- Grid navigation shares layout's fixed four-line title/header offset.
  local row = line - 4
  if row < 1 or not grid.raw_rows[row] then
    return nil
  end
  -- Walk each column's character range (accounting for the "| " prefix and
  -- " | " separators between columns, each 3 characters) to find which
  -- column the cursor's byte column falls inside.
  local start = 2
  for index, width in ipairs(widths) do
    if column >= start and column < start + width then
      return { column = index, row = row }
    end
    start = start + width + 3
  end
end

-- Compute a new cell position after moving by some number of rows/columns
-- from a given cell, clamping to the grid's bounds (so you can't move past
-- the first/last row or column).
-- Parameters:
--   grid        - grid table (used for row count via raw_rows).
--   widths      - column widths (used for column count).
--   cell        - the starting { row, column } cell, or nil.
--   row_delta   - rows to move by (negative = up, positive = down).
--   column_delta- columns to move by (negative = left, positive = right).
-- Returns: the new clamped { row, column } cell, or nil if `cell` was nil
-- (nothing to move from, e.g. cursor wasn't over a cell to begin with).
function M.move(grid, widths, cell, row_delta, column_delta)
  if not cell then
    return nil
  end
  return {
    column = math.max(1, math.min(#widths, cell.column + column_delta)),
    row = math.max(1, math.min(#grid.raw_rows, cell.row + row_delta)),
  }
end

-- Inverse of M.cell_at: given a logical {row, column} cell, compute the
-- buffer cursor position (1-based line, 0-based column) that should be used
-- to move the cursor onto that cell, e.g. via vim.api.nvim_win_set_cursor.
-- Parameters: widths - column widths from M.layout; cell - { row, column }.
-- Returns: { line, column } cursor position, using the same "+4 lines of
-- header" and "2 + width+3 per column" offsets as M.layout/M.cell_at.
function M.cursor_for(widths, cell)
  local start = 2
  for index = 1, cell.column - 1 do
    start = start + widths[index] + 3
  end
  return { cell.row + 4, start }
end

return M
