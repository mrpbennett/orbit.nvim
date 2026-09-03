-- orbit/editable_result.lua
--
-- This module implements an in-memory, undo-able "editable result set" --
-- the data model behind letting a user edit a query's result grid directly
-- (insert new rows, edit cell values, delete rows) before those changes are
-- turned into SQL statements and sent to the database (that SQL-generation
-- step happens elsewhere; this module only tracks *what changed*).
--
-- A "result" here is a plain table (not a class/metatable) with:
--   result.rows    - ordered list of row tables, each shaped like:
--                       { id = <int>, original = <values or nil>,
--                         state = "unchanged"|"modified"|"inserted"|"deleted",
--                         values = <table of column -> value> }
--                     `original` holds the pristine values from the query so
--                     a "modified" row can be diffed against them; it is nil
--                     for freshly inserted rows (there is no "original").
--   result.next_id - counter used to hand out unique row ids as rows are
--                     inserted, so ids stay stable even as rows are
--                     reordered/deleted.
--   result.history - a stack of snapshots (see `snapshot`/`record`) used to
--                     implement M.undo.
--
-- Deleted rows are NOT removed from `result.rows` immediately unless they
-- were only just inserted (see M.delete) -- they're kept with state =
-- "deleted" so they can still be undone and so M.changes can report them;
-- callers should use M.visible_rows to get the rows a user should actually
-- see rendered in the grid.
--
-- Exports (module table M): new, visible_rows, row, insert, insert_before,
-- delete, set_value, undo, changed, changes.

local M = {}

-- Deep-copy a value so stored snapshots/rows don't alias tables that the
-- caller (or this module itself) might mutate later.
local function copy(value)
  return vim.deepcopy(value)
end

-- Build one row entry for the internal `result.rows` list.
-- Parameters:
--   id     - unique row id (see result.next_id).
--   values - table of column name -> value for this row.
--   state  - one of "unchanged" (default when nil), "modified", "inserted",
--            "deleted".
-- Returns: a new row table (see module comment above for its shape). Note
-- `original` is deep-copied from `values` for every state except
-- "inserted" rows, which have no original state to diff against.
local function make_row(id, values, state)
  return {
    id = id,
    original = state == "inserted" and nil or copy(values),
    state = state or "unchanged",
    values = copy(values),
  }
end

-- Capture just enough of `result` to be able to restore it later: the row
-- id counter and a deep copy of the current rows list. (History does not
-- need to snapshot anything else since nothing else in `result` changes.)
local function snapshot(result)
  return {
    next_id = result.next_id,
    rows = copy(result.rows),
  }
end

-- Push a snapshot of the current state onto `result.history`. Every
-- mutating operation (insert/delete/set_value) calls this FIRST, before
-- making its change, so M.undo can always pop back to the state just
-- before the most recent mutation.
local function record(result)
  table.insert(result.history, snapshot(result))
end

-- Find a row by its id. Parameters: result - the result table; id - row id
-- to look for. Returns: the row table, or nil if no row with that id
-- exists (e.g. it was permanently removed, or the id was never valid).
local function row_at(result, id)
  for _, row in ipairs(result.rows) do
    if row.id == id then
      return row
    end
  end
end

-- Create a fresh editable result from a plain list of query result rows
-- (e.g. the raw_rows produced elsewhere from a query, as column -> value
-- tables). Every row starts out with state "unchanged" and gets a unique,
-- sequential id.
-- Parameters: rows - list of plain { column = value, ... } tables.
-- Returns: a new result table (see module comment for its shape). No side
-- effects beyond allocating new tables.
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

-- Get the rows that should actually be shown to the user right now, i.e.
-- everything except rows marked "deleted" (which are kept internally only
-- so they remain undo-able and are still reported by M.changes).
-- Returns: a new list (not a reference into result.rows) of row tables, in
-- the same order they appear in result.rows.
function M.visible_rows(result)
  local rows = {}
  for _, row in ipairs(result.rows) do
    if row.state ~= "deleted" then
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- Look up a single row by its id. Returns the row table or nil if not
-- found. Thin public wrapper around the internal row_at helper.
function M.row(result, id)
  return row_at(result, id)
end

-- Insert a new, empty row (state "inserted") right AFTER the row currently
-- at `visible_index` in the visible list (or at the very end if
-- visible_index is nil/not found).
-- Parameters:
--   result        - the result table to mutate.
--   visible_index - 1-based index into M.visible_rows(result) identifying
--                   the row to insert after, or nil to append at the end.
-- Returns: the newly created row table.
-- Side effects: mutates result.rows and result.next_id; pushes an undo
-- snapshot via record(result) before making the change.
function M.insert(result, visible_index)
  record(result)
  local at = #result.rows + 1
  if visible_index then
    local visible = M.visible_rows(result)
    local after = visible[visible_index]
    if after then
      -- `visible_index` refers to a position in the *visible* rows list,
      -- which skips deleted rows -- so we have to re-locate that same row's
      -- real position in the full result.rows list (which includes deleted
      -- rows) before we know where to actually splice the new row in.
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

-- Same as M.insert, but inserts the new row BEFORE the row at
-- `visible_index` instead of after it (used e.g. when the user wants a new
-- blank row above the current one).
-- Parameters/Returns/Side effects: same as M.insert.
function M.insert_before(result, visible_index)
  record(result)
  local at = #result.rows + 1
  local visible = M.visible_rows(result)
  local before = visible[visible_index]
  if before then
    -- Same visible-index-to-real-index translation as in M.insert, but
    -- landing "at" the target row's own index (so the new row takes its
    -- place and the target row shifts down), rather than index + 1.
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

-- Mark the rows with the given ids as deleted (or, if a row had only just
-- been "inserted" and never saved, remove it outright since there's
-- nothing in the database to delete and no reason to keep it around for
-- undo/diffing purposes).
-- Parameters: result - the result table; ids - list of row ids to delete.
-- Side effects: mutates result.rows in place (rebuilds it); pushes an undo
-- snapshot first.
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
        -- Never-saved rows just disappear; previously-existing rows are
        -- kept (marked "deleted") so a later M.changes/save step knows to
        -- issue a DELETE, and so this can still be undone.
        row.state = "deleted"
        retained[#retained + 1] = row
      end
    else
      retained[#retained + 1] = row
    end
  end
  result.rows = retained
end

-- Edit a single cell's value on an existing row.
-- Parameters:
--   result - the result table.
--   id     - id of the row to edit.
--   column - column name to change.
--   value  - new value for that column.
-- Returns: true if the edit was applied, false if the row doesn't exist or
-- has already been deleted (deleted rows can't be edited).
-- Side effects: mutates the row's values table; pushes an undo snapshot
-- first; recomputes the row's state by comparing its new values against
-- its `original` snapshot -- if they're equal again (e.g. user typed a
-- change and then typed it back), the row reverts to "unchanged" rather
-- than staying marked "modified". Inserted rows never get downgraded this
-- way since they have no `original` to compare against.
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

-- Revert the most recent mutation (insert/insert_before/delete/set_value)
-- by popping the last snapshot off result.history and restoring
-- result.next_id/result.rows from it.
-- Returns: true if something was undone, false if there was no history
-- left (nothing more to undo).
-- Side effects: mutates result.rows/result.next_id; mutates result.history
-- (removes the popped snapshot).
function M.undo(result)
  local previous = table.remove(result.history)
  if not previous then
    return false
  end
  result.next_id = previous.next_id
  result.rows = previous.rows
  return true
end

-- Check whether ANY row currently has unsaved changes (i.e. state is not
-- "unchanged"). Used to decide e.g. whether to warn the user before
-- closing a results buffer with pending edits.
-- Returns: boolean.
function M.changed(result)
  for _, row in ipairs(result.rows) do
    if row.state ~= "unchanged" then
      return true
    end
  end
  return false
end

-- Collect all pending changes, grouped by kind, so a caller can generate
-- the appropriate INSERT/UPDATE/DELETE SQL for each.
-- Returns: a table { deleted = {...}, inserted = {...}, modified = {...} },
-- each a list of the row tables in that state (unchanged rows are
-- omitted entirely).
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
