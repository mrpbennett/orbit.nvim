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
    catalog = true,
    confirm_mutations = true,
    executable = true,
    schema = true,
    server = true,
    user = true,
  }
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported Trino option %q", profile_name, name)
    end
  end
  if options.schema ~= nil and type(options.schema) ~= "string" then
    return nil, string.format("profile %q options.schema must be a string", profile_name)
  end
  return true
end

function M.prepare(options, statement)
  local command = { options.executable or "trino" }
  append(command, options.arguments or {})
  append(command, {
    "--server", options.server,
    "--user", options.user,
    "--catalog", options.catalog,
  })
  if options.schema and options.schema ~= "" then
    append(command, { "--schema", options.schema })
  end
  append(command, {
    "--no-progress",
    "--output-format", "JSON",
    "--execute", statement,
  })
  return command
end

function M.schema_statement(options, node)
  if node.type == "tables" then
    local clauses = {
      "SELECT table_schema AS schema, table_name AS name, table_type AS type",
      "FROM information_schema.tables",
      "WHERE table_catalog = " .. literal(options.catalog),
      "AND table_schema <> 'information_schema'",
    }
    if options.schema and options.schema ~= "" then
      table.insert(clauses, "AND table_schema = " .. literal(options.schema))
    end
    table.insert(clauses, "ORDER BY table_schema, table_name")
    return table.concat(clauses, " ")
  end
  if node.type == "columns" and node.name then
    local schema = node.schema or options.schema
    if not schema or schema == "" then
      return nil, "schema is required to load Trino columns"
    end
    return table.concat({
      "SELECT column_name AS name, data_type AS type",
      "FROM information_schema.columns",
      "WHERE table_catalog = " .. literal(options.catalog),
      "AND table_schema = " .. literal(schema),
      "AND table_name = " .. literal(node.name),
      "ORDER BY ordinal_position",
    }, " ")
  end
  return nil, "unsupported schema node"
end

function M.object_actions(options, row, limit)
  local schema = row.schema or options.schema
  if not schema or schema == "" then
    return nil, "schema is required for Trino schema object actions"
  end
  local qualified = table.concat({ identifier(schema), identifier(row.name) }, ".")
  local columns = assert(M.schema_statement(options, {
    type = "columns",
    name = row.name,
    schema = schema,
  }))
  return {
    {
      id = "sample",
      kind = "query_buffer",
      label = "Open sample statement",
      statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", qualified, limit),
    },
    {
      id = "columns",
      kind = "statement",
      label = "Columns",
      statement = columns,
    },
  }
end

return M
