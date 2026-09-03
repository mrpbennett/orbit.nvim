-- Shared editable-target decision and mutation SQL generation, used by
-- every connector whose backend supports writing results-grid edits back
-- to a real table (currently postgres and sqlite).
local M = {}

-- Decides whether a result row can be edited in the results grid, and if
-- so, what information is needed to write changes back to the database.
-- Editing requires knowing the row's unique identity, which is only
-- possible when the row came from an actual table (not a view or an
-- arbitrary SELECT) and that table has at least one primary key column.
-- Params:
--   row - metadata about the source of the result set (row.type is
--     "table", "view", etc, plus .name/.schema).
--   primary_keys - a Lua array of primary key column names already
--     discovered for this table (empty if none, or if not a table).
-- Returns: on success, an Editable target {name, schema, primary_keys}; on
--   failure, `nil, error_message` explaining why the result can't be edited.
function M.editable_table(row, primary_keys)
  if row.type ~= "table" or #primary_keys == 0 then
    return nil, "Result is read-only: unable to determine a unique database row."
  end
  return { name = row.name, schema = row.schema, primary_keys = primary_keys }
end

-- Turns a set of edits made in the results grid into a single SQL script
-- that applies all of them atomically.
-- Params:
--   name_sql - the target table's already-quoted, backend-qualified name
--     (e.g. postgres passes `"schema"."table"`, sqlite passes `"table"`).
--   identifier_fn - the connector's identifier-quoting function.
--   literal_fn - the connector's string-literal-quoting function.
--   begin_stmt - the connector's transaction-start statement, e.g. "BEGIN"
--     or "BEGIN IMMEDIATE".
--   primary_keys - the Editable target's primary key column names.
--   changes - a table with three arrays: .deleted, .modified, .inserted.
--     Each entry in .deleted/.modified has `.original` (the row's values as
--     last read from the database) and, for .modified, `.values` (the
--     edited values). Each entry in .inserted has just `.values`.
-- Returns: on success, one big SQL string containing "<begin_stmt>; ...;
--   COMMIT;" wrapping all the generated statements, so they run as a single
--   transaction. On failure (e.g. a row can't be uniquely identified),
--   returns `nil, error_message` and no SQL is generated.
function M.build(name_sql, identifier_fn, literal_fn, begin_stmt, primary_keys, changes)
  -- vim.NIL is Neovim's sentinel for a real SQL NULL (as opposed to Lua's
  -- `nil`, which just means "no key"), so it must map to the literal
  -- keyword NULL rather than being quoted like a string.
  local function value_sql(value)
    return value == vim.NIL and "NULL" or literal_fn(value)
  end

  local statements = { begin_stmt }

  -- Deleted rows: build "DELETE FROM <table> WHERE pk1 = v1 AND pk2 = v2
  -- ..." using the row's *original* (pre-edit) primary key values, since
  -- that's what still identifies the row in the database.
  for _, row in ipairs(changes.deleted) do
    local conditions = {}
    for _, column in ipairs(primary_keys) do
      local value = row.original[column]
      -- A NULL primary key value can never uniquely identify a row (NULL
      -- isn't equal to anything, including itself, in SQL), so refuse
      -- rather than generating a WHERE clause that would match nothing or
      -- everything.
      if value == nil or value == vim.NIL then
        return nil, "Cannot delete a row with a NULL primary key."
      end
      conditions[#conditions + 1] = identifier_fn(column) .. " = " .. value_sql(value)
    end
    statements[#statements + 1] = "DELETE FROM " .. name_sql .. " WHERE " .. table.concat(conditions, " AND ")
  end

  -- Modified rows: for each column, compare the edited value against the
  -- original; only columns that actually changed get an assignment, so an
  -- UPDATE only touches what the user actually edited.
  for _, row in ipairs(changes.modified) do
    local assignments, conditions = {}, {}
    for column, value in pairs(row.values) do
      if not vim.deep_equal(value, row.original[column]) then
        -- Refuse to change a primary key value through an UPDATE: doing so
        -- would change the row's identity mid-statement, which is exactly
        -- the kind of edit this simple SQL-generation approach can't safely
        -- express (it would need to be a delete-and-reinsert instead).
        for _, primary_key in ipairs(primary_keys) do
          if column == primary_key then
            return nil, "Editing primary key values is not supported."
          end
        end
        assignments[#assignments + 1] = identifier_fn(column) .. " = " .. value_sql(value)
      end
    end
    -- The WHERE clause always uses the row's *original* primary key values
    -- (its identity before this edit), same reasoning as the delete case
    -- above.
    for _, column in ipairs(primary_keys) do
      local value = row.original[column]
      if value == nil or value == vim.NIL then
        return nil, "Cannot update a row with a NULL primary key."
      end
      conditions[#conditions + 1] = identifier_fn(column) .. " = " .. value_sql(value)
    end
    -- Skip emitting a no-op UPDATE when nothing actually changed for this
    -- row (e.g. the row was marked modified but the values ended up equal).
    if #assignments > 0 then
      statements[#statements + 1] = "UPDATE " .. name_sql .. " SET " .. table.concat(assignments, ", ") .. " WHERE " .. table.concat(conditions, " AND ")
    end
  end

  -- Inserted rows: only include columns the user actually gave a
  -- (non-nil) value for, so unset columns fall back to the table's own
  -- defaults (e.g. DEFAULT, a sequence, etc) instead of being forced to
  -- NULL explicitly.
  for _, row in ipairs(changes.inserted) do
    local columns = {}
    for column, value in pairs(row.values) do
      if value ~= nil then
        columns[#columns + 1] = column
      end
    end
    -- Lua's `pairs()` iteration order over a table is not guaranteed, so
    -- without sorting, the generated column order (and thus the SQL text)
    -- could vary between runs even for identical input; sorting keeps
    -- output deterministic. Sorting the raw (unquoted) names, rather than
    -- quoted identifiers, means the sort order can't be affected by a
    -- backend's quoting characters.
    table.sort(columns)
    if #columns == 0 then
      -- Every column was left unset: fall back to the "INSERT INTO x
      -- DEFAULT VALUES" form, since "INSERT INTO x () VALUES ()" isn't
      -- valid syntax.
      statements[#statements + 1] = "INSERT INTO " .. name_sql .. " DEFAULT VALUES"
    else
      local identifiers, values = {}, {}
      for _, column in ipairs(columns) do
        identifiers[#identifiers + 1] = identifier_fn(column)
        values[#values + 1] = value_sql(row.values[column])
      end
      statements[#statements + 1] = "INSERT INTO " .. name_sql .. " (" .. table.concat(identifiers, ", ") .. ") VALUES (" .. table.concat(values, ", ") .. ")"
    end
  end

  statements[#statements + 1] = "COMMIT"
  return table.concat(statements, ";\n") .. ";"
end

return M
