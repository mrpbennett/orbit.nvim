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

local function qualified(row)
  return table.concat({ identifier(row.schema or "public"), identifier(row.name) }, ".")
end

local function schema_filter(schemas)
  if not schemas then
    return nil
  end
  local values = {}
  for _, schema in ipairs(schemas) do
    table.insert(values, literal(schema))
  end
  return "AND table_schema IN (" .. table.concat(values, ", ") .. ")"
end

function M.validate_options(profile_name, options)
  local allowed = {
    arguments = true,
    confirm_mutations = true,
    database = true,
    executable = true,
    host = true,
    password = true,
    port = true,
    sslmode = true,
    schema_patterns = true,
    user = true,
  }
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported PostgreSQL option %q", profile_name, name)
    end
  end
  for _, name in ipairs({ "host", "password", "sslmode", "user" }) do
    if options[name] ~= nil and type(options[name]) ~= "string" then
      return nil, string.format("profile %q options.%s must be a string", profile_name, name)
    end
  end
  if options.port ~= nil and (type(options.port) ~= "number" or options.port % 1 ~= 0 or options.port < 1 or options.port > 65535) then
    return nil, string.format("profile %q options.port must be an integer between 1 and 65535", profile_name)
  end
  return true
end

function M.prepare(options, statement)
  local command = { options.executable or "psql" }
  append(command, options.arguments or {})
  append(command, { "--dbname", options.database })
  if options.host then
    append(command, { "--host", options.host })
  end
  if options.port then
    append(command, { "--port", tostring(options.port) })
  end
  if options.user then
    append(command, { "--username", options.user })
  end
  append(command, {
    "--csv",
    "--no-psqlrc",
    "--pset", "footer=off",
    "--set", "ON_ERROR_STOP=on",
    "--command", statement,
  })
  return command
end

function M.session_command(options)
  local command = { options.executable or "psql" }
  append(command, options.arguments or {})
  append(command, { "--dbname", options.database })
  if options.host then
    append(command, { "--host", options.host })
  end
  if options.port then
    append(command, { "--port", tostring(options.port) })
  end
  if options.user then
    append(command, { "--username", options.user })
  end
  append(command, {
    "--csv",
    "--no-psqlrc",
    "--pset", "footer=off",
    "--set", "ON_ERROR_STOP=off",
  })
  return command
end

function M.session_request(statement, marker)
  return statement .. ";\nSELECT '" .. marker .. "' AS __orbit_marker;\n"
end

function M.session_output(output, marker)
  local marker_at = output:find(marker, 1, true)
  if not marker_at then
    return nil
  end
  local start = output:sub(1, marker_at):match(".*()__orbit_marker")
  if not start then
    return nil
  end
  return output:sub(1, start - 1)
end

function M.environment(options)
  local environment = {}
  if options.password then
    environment.PGPASSWORD = options.password
  end
  if options.sslmode then
    environment.PGSSLMODE = options.sslmode
  end
  return environment
end

function M.schema_statement(options, node)
  if node.type == "tables" then
    local clauses = {
      "SELECT table_schema AS schema, table_name AS name,",
      "CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS type",
      "FROM information_schema.tables",
      "WHERE table_schema <> 'information_schema' AND table_schema NOT LIKE 'pg_%'",
      "AND table_type IN ('BASE TABLE', 'VIEW')",
    }
    local filter = schema_filter(options.schema_patterns)
    if filter then
      table.insert(clauses, filter)
    end
    table.insert(clauses, "ORDER BY table_schema, table_name")
    return table.concat(clauses, " ")
  end
  if node.type == "columns" and node.name then
    return table.concat({
      "SELECT column_name AS name, data_type AS type",
      "FROM information_schema.columns",
      "WHERE table_schema = " .. literal(node.schema or "public"),
      "AND table_name = " .. literal(node.name),
      "ORDER BY ordinal_position",
    }, " ")
  end
  if node.type == "primary_keys" and node.name then
    return table.concat({
      "SELECT kcu.column_name AS name, kcu.ordinal_position AS pk, tc.constraint_name",
      "FROM information_schema.table_constraints tc",
      "JOIN information_schema.key_column_usage kcu",
      "ON tc.constraint_name = kcu.constraint_name",
      "AND tc.table_schema = kcu.table_schema AND tc.table_name = kcu.table_name",
      "WHERE tc.constraint_type = 'PRIMARY KEY'",
      "AND tc.table_schema = " .. literal(node.schema or "public"),
      "AND tc.table_name = " .. literal(node.name),
      "ORDER BY kcu.ordinal_position",
    }, " ")
  end
  if node.type == "foreign_keys" and node.name then
    return table.concat({
      "SELECT constraint_row.conname AS id, source_column.attname AS \"from\",",
      "target_table.relname AS \"table\", target_column.attname AS \"to\"",
      "FROM pg_constraint constraint_row",
      "JOIN pg_class source_table ON source_table.oid = constraint_row.conrelid",
      "JOIN pg_namespace source_schema ON source_schema.oid = source_table.relnamespace",
      "JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY",
      "AS source_key(attnum, position) ON true",
      "JOIN pg_attribute source_column",
      "ON source_column.attrelid = source_table.oid AND source_column.attnum = source_key.attnum",
      "JOIN pg_class target_table ON target_table.oid = constraint_row.confrelid",
      "JOIN LATERAL unnest(constraint_row.confkey) WITH ORDINALITY",
      "AS target_key(attnum, position) ON target_key.position = source_key.position",
      "JOIN pg_attribute target_column",
      "ON target_column.attrelid = target_table.oid AND target_column.attnum = target_key.attnum",
      "WHERE constraint_row.contype = 'f'",
      "AND source_schema.nspname = " .. literal(node.schema or "public"),
      "AND source_table.relname = " .. literal(node.name),
      "ORDER BY constraint_row.conname, source_key.position",
    }, " ")
  end
  if node.type == "indexes" and node.name then
    return table.concat({
      "SELECT indexname AS name, indexdef AS definition",
      "FROM pg_indexes",
      "WHERE schemaname = " .. literal(node.schema or "public"),
      "AND tablename = " .. literal(node.name),
      "ORDER BY indexname",
    }, " ")
  end
  return nil, "unsupported schema node"
end

function M.metadata_categories(_, row)
  local categories = { { id = "columns", label = "columns" } }
  if row.type == "table" then
    table.insert(categories, { id = "primary_keys", label = "primary keys" })
    table.insert(categories, { id = "foreign_keys", label = "foreign keys" })
    table.insert(categories, { id = "indexes", label = "indexes" })
  end
  return categories
end

function M.object_actions(_, row, limit)
  local actions = {
    {
      id = "sample",
      kind = "query_buffer",
      label = "Open sample statement",
      statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", qualified(row), limit),
    },
    {
      id = "columns",
      kind = "statement",
      label = "Columns",
      statement = assert(M.schema_statement(nil, { type = "columns", name = row.name, schema = row.schema })),
    },
  }
  if row.type == "table" then
    for _, category in ipairs({ "primary_keys", "foreign_keys", "indexes" }) do
      table.insert(actions, {
        id = category,
        kind = "statement",
        label = category:gsub("_", " "):gsub("^%l", string.upper),
        statement = assert(M.schema_statement(nil, { type = category, name = row.name, schema = row.schema })),
      })
    end
  else
    table.insert(actions, {
      id = "definition",
      kind = "statement",
      label = "Definition",
      statement = "SELECT pg_get_viewdef(" .. literal(qualified(row)) .. "::regclass, true) AS definition;",
    })
  end
  return actions
end

function M.parse(output)
  local records, record, field = {}, {}, {}
  local quoted, in_quotes, index = false, false, 1
  local function finish_field()
    table.insert(record, { value = table.concat(field), quoted = quoted })
    field, quoted = {}, false
  end
  local function finish_record()
    finish_field()
    table.insert(records, record)
    record = {}
  end

  while index <= #output do
    local character = output:sub(index, index)
    if in_quotes then
      if character == '"' and output:sub(index + 1, index + 1) == '"' then
        table.insert(field, '"')
        index = index + 1
      elseif character == '"' then
        in_quotes = false
      else
        table.insert(field, character)
      end
    elseif character == '"' and #field == 0 then
      quoted, in_quotes = true, true
    elseif character == "," then
      finish_field()
    elseif character == "\n" then
      finish_record()
    elseif character ~= "\r" then
      table.insert(field, character)
    end
    index = index + 1
  end
  if #field > 0 or quoted or #record > 0 then
    finish_record()
  end
  if #records == 0 then
    return {}
  end

  local headers, rows = records[1], {}
  for record_index = 2, #records do
    local row = {}
    for column_index, header in ipairs(headers) do
      local field_value = records[record_index][column_index] or {}
      row[header.value] = field_value.value == "" and not field_value.quoted and vim.NIL or field_value.value or ""
    end
    table.insert(rows, row)
  end
  return rows
end

return M
