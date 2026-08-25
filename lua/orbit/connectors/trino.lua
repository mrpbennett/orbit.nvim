local M = {}

local function append(arguments, values)
  for _, value in ipairs(values) do
    table.insert(arguments, value)
  end
end

local function literal(value)
  -- SQL literals and identifiers use distinct escaping rules and must never be interchangeable.
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
    schema_patterns = true,
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
  if options.schema_patterns ~= nil then
    if type(options.schema_patterns) ~= "table" or vim.islist(options.schema_patterns) then
      return nil, string.format("profile %q options.schema_patterns must map catalogs to schema arrays", profile_name)
    end
    for catalog, schemas in pairs(options.schema_patterns) do
      if type(catalog) ~= "string" or catalog == "" or type(schemas) ~= "table" or not vim.islist(schemas) then
        return nil, string.format("profile %q options.schema_patterns must map catalog names to schema arrays", profile_name)
      end
      for _, schema in ipairs(schemas) do
        if type(schema) ~= "string" or schema == "" then
          return nil, string.format("profile %q options.schema_patterns must contain non-empty schema names", profile_name)
        end
      end
    end
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

function M.qualified_name(options, row)
  return table.concat({
    identifier(row.catalog or options.catalog),
    identifier(row.schema or options.schema),
    identifier(row.name),
  }, ".")
end

function M.completion_word(options, row, prefix)
  if prefix ~= "" then
    return prefix .. row.name
  end
  local parts = row.schema and { row.schema, row.name } or { row.name }
  if row.catalog and row.catalog ~= options.catalog then
    table.insert(parts, 1, row.catalog)
  end
  return table.concat(parts, ".")
end

function M.schema_of(_, qualifier)
  return qualifier:gsub("%.$", "")
end

function M.schema_statement(options, node)
  if node.type == "tables" then
    if options.schema_patterns then
      -- Patterns are catalog-to-schema maps, so each catalog needs its own information_schema query.
      local statements = {}
      for catalog, schemas in pairs(options.schema_patterns) do
        local clauses = {
          "SELECT " .. literal(catalog) .. " AS catalog, table_schema AS schema, table_name AS name, table_type AS type",
          "FROM " .. identifier(catalog) .. ".information_schema.tables",
          "WHERE table_schema <> 'information_schema'",
        }
        if #schemas > 0 then
          local values = {}
          for _, schema in ipairs(schemas) do
            table.insert(values, literal(schema))
          end
          table.insert(clauses, "AND table_schema IN (" .. table.concat(values, ", ") .. ")")
        end
        table.insert(statements, table.concat(clauses, " "))
      end
      return table.concat(statements, " UNION ALL ") .. " ORDER BY catalog, schema, name"
    end
    local clauses = {
      "SELECT table_catalog AS catalog, table_schema AS schema, table_name AS name, table_type AS type",
      "FROM information_schema.tables",
      "WHERE table_catalog = " .. literal(options.catalog),
      "AND table_schema <> 'information_schema'",
    }
    if options.schema and options.schema ~= "" then
      table.insert(clauses, "AND table_schema = " .. literal(options.schema))
    end
    table.insert(clauses, "ORDER BY catalog, schema, name")
    return table.concat(clauses, " ")
  end
  if node.type == "columns" and node.name then
    local schema = node.schema or options.schema
    local catalog = node.catalog or options.catalog
    if not schema or schema == "" then
      return nil, "schema is required to load Trino columns"
    end
    return table.concat({
      "SELECT column_name AS name, data_type AS type",
      "FROM " .. identifier(catalog) .. ".information_schema.columns",
      "WHERE table_catalog = " .. literal(catalog),
      "AND table_schema = " .. literal(schema),
      "AND table_name = " .. literal(node.name),
      "ORDER BY ordinal_position",
    }, " ")
  end
  return nil, "unsupported schema node"
end

function M.metadata_categories()
  return { { id = "columns", label = "columns" } }
end

function M.object_actions(options, row, limit)
  local schema = row.schema or options.schema
  if not schema or schema == "" then
    return nil, "schema is required for Trino schema object actions"
  end
  local qualified = table.concat({ identifier(row.catalog or options.catalog), identifier(schema), identifier(row.name) }, ".")
  -- A discovered object may live outside the configured default catalog or schema.
  local columns = assert(M.schema_statement(options, {
    type = "columns",
    name = row.name,
    schema = schema,
    catalog = row.catalog,
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
