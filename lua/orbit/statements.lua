local M = {}

local function selected_lines(lines, selection)
  if not selection then
    return nil
  end
  if type(selection.start_row) ~= "number" or type(selection.end_row) ~= "number" then
    return nil, "selection requires start_row and end_row"
  end

  local start_row = math.max(1, selection.start_row)
  local end_row = math.min(#lines, selection.end_row)
  if start_row > end_row then
    return nil, "selection is empty"
  end
  return table.concat(vim.list_slice(lines, start_row, end_row), "\n")
end

function M.target(request)
  if type(request) ~= "table" or type(request.lines) ~= "table" then
    return nil, "buffer lines are required"
  end

  local explicit, selection_err = selected_lines(request.lines, request.selection)
  if selection_err then
    return nil, selection_err
  end
  if explicit then
    if explicit:match("^%s*$") then
      return nil, "selection is empty"
    end
    return explicit
  end

  local contents = table.concat(request.lines, "\n")
  if contents:match("^%s*$") then
    return nil, "buffer is empty"
  end

  local semicolons = select(2, contents:gsub(";", ""))
  -- This is intentionally a safety rule, not SQL parsing: ambiguous buffers require a selection.
  if semicolons > 1 or (semicolons == 1 and not contents:match(";%s*$")) then
    return nil, "statement is ambiguous; select the statement explicitly"
  end

  return contents
end

return M
