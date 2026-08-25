local M = {}

local function append(arguments, values)
  for _, value in ipairs(values) do
    table.insert(arguments, value)
  end
end

local function literal(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function identifier(value)
  return '"' .. tostring(value):gsub('"', '""') .. '"'
end

function M.validate_options(profile_name, options)
  local allowed = {
    arguments = true,
    confirm_mutations = true,
    executable = true,
    path = true,
    schema_patterns = true,
  }
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported SQLite option %q", profile_name, name)
    end
  end
  return true
end

function M.prepare(options, statement)
  local command = { options.executable or "sqlite3" }
  append(command, options.arguments or {})
  append(command, { "-json", options.path, statement })
  return command
end

function M.session_command(options)
  local command = { options.executable or "sqlite3" }
  append(command, options.arguments or {})
  -- Abort the CLI on SQL errors so an uncommitted transaction rolls back on disconnect.
  append(command, { "-bail", "-json", options.path })
  return command
end

function M.editable_table(_, row, primary_keys)
  if row.type ~= "table" or #primary_keys == 0 then
    return nil, "Result is read-only: unable to determine a unique database row."
  end
  return { name = row.name, schema = row.schema, primary_keys = primary_keys }
end

function M.mutation_statement(_, target, changes)
  local name = identifier(target.name)
  local primary_keys = target.primary_keys
  local function value_sql(value)
    return value == vim.NIL and "NULL" or literal(value)
  end
  local statements = { "BEGIN IMMEDIATE" }
  for _, row in ipairs(changes.deleted) do
    local conditions = {}
    for _, column in ipairs(primary_keys) do
      local value = row.original[column]
      if value == nil or value == vim.NIL then
        return nil, "Cannot delete a row with a NULL primary key."
      end
      conditions[#conditions + 1] = identifier(column) .. " = " .. value_sql(value)
    end
    statements[#statements + 1] = "DELETE FROM " .. name .. " WHERE " .. table.concat(conditions, " AND ")
  end
  for _, row in ipairs(changes.modified) do
    local assignments, conditions = {}, {}
    for column, value in pairs(row.values) do
      if not vim.deep_equal(value, row.original[column]) then
        for _, primary_key in ipairs(primary_keys) do
          if column == primary_key then
            return nil, "Editing primary key values is not supported."
          end
        end
        assignments[#assignments + 1] = identifier(column) .. " = " .. value_sql(value)
      end
    end
    for _, column in ipairs(primary_keys) do
      local value = row.original[column]
      if value == nil or value == vim.NIL then
        return nil, "Cannot update a row with a NULL primary key."
      end
      conditions[#conditions + 1] = identifier(column) .. " = " .. value_sql(value)
    end
    if #assignments > 0 then
      statements[#statements + 1] = "UPDATE " .. name .. " SET " .. table.concat(assignments, ", ") .. " WHERE " .. table.concat(conditions, " AND ")
    end
  end
  for _, row in ipairs(changes.inserted) do
    local columns, values = {}, {}
    for column, value in pairs(row.values) do
      if value ~= nil then
        columns[#columns + 1] = identifier(column)
        values[#values + 1] = value_sql(value)
      end
    end
    table.sort(columns)
    if #columns == 0 then
      statements[#statements + 1] = "INSERT INTO " .. name .. " DEFAULT VALUES"
    else
      local ordered_values = {}
      for _, column in ipairs(columns) do
        local raw = column:sub(2, -2):gsub('""', '"')
        ordered_values[#ordered_values + 1] = value_sql(row.values[raw])
      end
      statements[#statements + 1] = "INSERT INTO " .. name .. " (" .. table.concat(columns, ", ") .. ") VALUES (" .. table.concat(ordered_values, ", ") .. ")"
    end
  end
  statements[#statements + 1] = "COMMIT"
  return table.concat(statements, ";\n") .. ";"
end

function M.session_request(statement, marker)
  -- The marker query delimits one JSON response in SQLite's persistent stdout stream.
  return statement .. ";\nSELECT '" .. marker .. "' AS __orbit_marker;\n"
end

function M.session_output(output, marker)
  local marker_at = output:find(marker, 1, true)
  if not marker_at then
    return nil
  end
  local start = output:sub(1, marker_at):match(".*()%[")
  if not start then
    return nil
  end
  return output:sub(1, start - 1)
end

function M.schema_statement(options, node)
  if node.type == "tables" then
    if options.schema_patterns then
      -- SQLite exposes only main here; filters without it intentionally acquire no rows.
      for _, schema in ipairs(options.schema_patterns) do
        if schema == "main" then
          return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
        end
      end
      return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE 1 = 0"
    end
    return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
  end
  if node.type == "columns" and node.name then
    return "PRAGMA table_info(" .. literal(node.name) .. ")"
  end
  if node.type == "primary_keys" and node.name then
    return "SELECT name, type, pk FROM pragma_table_info(" .. literal(node.name) .. ") WHERE pk > 0 ORDER BY pk"
  end
  if node.type == "foreign_keys" and node.name then
    return "PRAGMA foreign_key_list(" .. literal(node.name) .. ")"
  end
  if node.type == "indexes" and node.name then
    return "PRAGMA index_list(" .. literal(node.name) .. ")"
  end
  return nil, "unsupported schema node"
end

function M.metadata_categories(_, row)
  local categories = {
    { id = "columns", label = "columns" },
  }
  if row.type == "table" then
    table.insert(categories, { id = "primary_keys", label = "primary keys" })
    table.insert(categories, { id = "foreign_keys", label = "foreign keys" })
    table.insert(categories, { id = "indexes", label = "indexes" })
  end
  return categories
end

function M.object_actions(_, row, limit)
  local name = literal(row.name)
  -- PRAGMAs take string literals, while generated sample SQL needs an escaped identifier.
  return {
    {
      id = "sample",
      kind = "query_buffer",
      label = "Open sample statement",
      statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", identifier(row.name), limit),
    },
    {
      id = "columns",
      kind = "statement",
      label = "Columns",
      statement = "PRAGMA table_info(" .. name .. ");",
    },
    {
      id = "primary_keys",
      kind = "statement",
      label = "Primary keys",
      statement = "SELECT name, type, pk FROM pragma_table_info(" .. name .. ") WHERE pk > 0 ORDER BY pk;",
    },
    {
      id = "indexes",
      kind = "statement",
      label = "Indexes",
      statement = "PRAGMA index_list(" .. name .. ");",
    },
    {
      id = "foreign_keys",
      kind = "statement",
      label = "Foreign keys",
      statement = "PRAGMA foreign_key_list(" .. name .. ");",
    },
    {
      id = "definition",
      kind = "statement",
      label = "Definition",
      statement = "SELECT sql FROM sqlite_master WHERE name = " .. name .. " AND type IN ('table', 'view');",
    },
  }
end

return M
