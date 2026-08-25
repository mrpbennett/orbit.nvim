local M = {}

local function copy(value)
  return vim.deepcopy(value)
end

local function make_row(id, values, state)
  return {
    id = id,
    original = state == "inserted" and nil or copy(values),
    state = state or "unchanged",
    values = copy(values),
  }
end

local function snapshot(result)
  return {
    next_id = result.next_id,
    rows = copy(result.rows),
  }
end

local function record(result)
  table.insert(result.history, snapshot(result))
end

local function row_at(result, id)
  for _, row in ipairs(result.rows) do
    if row.id == id then
      return row
    end
  end
end

function M.new(rows)
  local result = {
    history = {},
    next_id = 1,
    rows = {},
  }
  for _, values in ipairs(rows) do
    result.rows[#result.rows + 1] = make_row(result.next_id, values)
    result.next_id = result.next_id + 1
  end
  return result
end

function M.visible_rows(result)
  local rows = {}
  for _, row in ipairs(result.rows) do
    if row.state ~= "deleted" then
      rows[#rows + 1] = row
    end
  end
  return rows
end

function M.row(result, id)
  return row_at(result, id)
end

function M.insert(result, visible_index)
  record(result)
  local at = #result.rows + 1
  if visible_index then
    local visible = M.visible_rows(result)
    local after = visible[visible_index]
    if after then
      for index, row in ipairs(result.rows) do
        if row.id == after.id then
          at = index + 1
          break
        end
      end
    end
  end
  local row = make_row(result.next_id, {}, "inserted")
  result.next_id = result.next_id + 1
  table.insert(result.rows, at, row)
  return row
end

function M.insert_before(result, visible_index)
  record(result)
  local at = #result.rows + 1
  local visible = M.visible_rows(result)
  local before = visible[visible_index]
  if before then
    for index, row in ipairs(result.rows) do
      if row.id == before.id then
        at = index
        break
      end
    end
  end
  local row = make_row(result.next_id, {}, "inserted")
  result.next_id = result.next_id + 1
  table.insert(result.rows, at, row)
  return row
end

function M.delete(result, ids)
  record(result)
  local selected = {}
  for _, id in ipairs(ids) do
    selected[id] = true
  end
  local retained = {}
  for _, row in ipairs(result.rows) do
    if selected[row.id] then
      if row.state ~= "inserted" then
        row.state = "deleted"
        retained[#retained + 1] = row
      end
    else
      retained[#retained + 1] = row
    end
  end
  result.rows = retained
end

function M.set_value(result, id, column, value)
  local row = row_at(result, id)
  if not row or row.state == "deleted" then
    return false
  end
  record(result)
  row.values[column] = value
  if row.state ~= "inserted" then
    row.state = vim.deep_equal(row.values, row.original) and "unchanged" or "modified"
  end
  return true
end

function M.undo(result)
  local previous = table.remove(result.history)
  if not previous then
    return false
  end
  result.next_id = previous.next_id
  result.rows = previous.rows
  return true
end

function M.changed(result)
  for _, row in ipairs(result.rows) do
    if row.state ~= "unchanged" then
      return true
    end
  end
  return false
end

function M.changes(result)
  local changes = { deleted = {}, inserted = {}, modified = {} }
  for _, row in ipairs(result.rows) do
    if row.state ~= "unchanged" then
      changes[row.state][#changes[row.state] + 1] = row
    end
  end
  return changes
end

return M
