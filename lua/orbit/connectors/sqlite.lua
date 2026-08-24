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

function M.schema_statement(_, node)
  if node.type == "tables" then
    return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
  end
  if node.type == "columns" and node.name then
    return "PRAGMA table_info(" .. literal(node.name) .. ")"
  end
  return nil, "unsupported schema node"
end

function M.object_actions(_, row, limit)
  local name = literal(row.name)
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
