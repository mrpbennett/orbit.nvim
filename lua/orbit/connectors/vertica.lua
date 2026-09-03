-- Vertica connector backed by the vsql command-line client.
local M = {}
local null_marker = "__ORBIT_NULL__"

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

local schema_pattern = require("orbit.connectors.schema_pattern")

local function schema_filter(schemas)
  local clause = schema_pattern.sql_clause("table_schema", schemas)
  return clause and ("AND " .. clause) or nil
end

local function command(options)
  local result = { options.executable or "vsql" }
  append(result, options.arguments or {})
  append(result, {
    "--dbname", options.database,
    "--host", options.host,
    "--username", options.user,
  })
  if options.port then
    append(result, { "--port", tostring(options.port) })
  end
  if options.sslmode then
    append(result, { "--sslmode", options.sslmode })
  end
  -- HTML is vsql's only structured output format; its entities preserve cell delimiters.
  append(result, { "--html", "--quiet", "--pset", "footer=off", "--pset", "null=" .. null_marker })
  return result
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
    schema_patterns = true,
    sslmode = true,
    user = true,
  }
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported Vertica option %q", profile_name, name)
    end
  end
  for _, name in ipairs({ "database", "host", "password", "sslmode", "user" }) do
    if options[name] ~= nil and type(options[name]) ~= "string" then
      return nil, string.format("profile %q options.%s must be a string", profile_name, name)
    end
  end
  if options.port ~= nil and (type(options.port) ~= "number" or options.port % 1 ~= 0 or options.port < 1 or options.port > 65535) then
    return nil, string.format("profile %q options.port must be an integer between 1 and 65535", profile_name)
  end
  if options.sslmode and not vim.tbl_contains({ "allow", "disable", "prefer", "require" }, options.sslmode) then
    return nil, string.format("profile %q options.sslmode must be allow, disable, prefer, or require", profile_name)
  end
  return true
end

function M.prepare(options, statement)
  local result = command(options)
  append(result, { "--command", statement })
  return result
end

function M.session_command(options)
  return command(options)
end

function M.session_request(statement, marker)
  return statement .. ";\nSELECT '" .. marker .. "' AS __orbit_marker;\n"
end

function M.session_output(output, marker)
  local marker_at = output:find(marker, 1, true)
  if not marker_at then
    return nil
  end
  local start = output:sub(1, marker_at):match(".*()<table[%s>]")
  return start and output:sub(1, start - 1) or nil
end

function M.environment(options)
  return options.password and { VSQL_PASSWORD = options.password } or {}
end

function M.qualified_name(_, row)
  return qualified(row)
end

function M.completion_word(_, row, prefix)
  return prefix ~= "" and prefix .. identifier(row.name) or qualified(row)
end

function M.schema_of(_, qualifier)
  local value = qualifier:gsub("%.$", "")
  if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
    return value:sub(2, -2):gsub('""', '"')
  end
  return value
end

function M.schema_statement(options, node)
  if node.type == "tables" then
    local filter = schema_filter(options.schema_patterns)
    local clauses = {
      'SELECT table_schema AS "schema", table_name AS name, \'table\' AS type FROM v_catalog.tables',
      "WHERE NOT is_system_table",
    }
    if filter then
      table.insert(clauses, filter)
    end
    table.insert(clauses, 'UNION ALL SELECT table_schema AS "schema", table_name AS name, \'view\' AS type FROM v_catalog.views WHERE 1 = 1')
    if filter then
      table.insert(clauses, filter)
    end
    table.insert(clauses, 'ORDER BY "schema", name')
    return table.concat(clauses, " ")
  end
  if node.type == "columns" and node.name then
    return table.concat({
      "SELECT column_name AS name, data_type AS type FROM v_catalog.columns",
      "WHERE table_schema = " .. literal(node.schema or "public"),
      "AND table_name = " .. literal(node.name),
      "ORDER BY ordinal_position",
    }, " ")
  end
  if node.type == "primary_keys" and node.name then
    return table.concat({
      "SELECT column_name AS name, ordinal_position AS pk FROM v_catalog.primary_keys",
      "WHERE table_schema = " .. literal(node.schema or "public"),
      "AND table_name = " .. literal(node.name),
      "ORDER BY ordinal_position",
    }, " ")
  end
  if node.type == "foreign_keys" and node.name then
    return table.concat({
      'SELECT constraint_name AS id, column_name AS "from", reference_table_name AS "table", reference_column_name AS "to" FROM v_catalog.foreign_keys',
      "WHERE table_schema = " .. literal(node.schema or "public"),
      "AND table_name = " .. literal(node.name),
      "ORDER BY constraint_name, ordinal_position",
    }, " ")
  end
  if node.type == "projections" and node.name then
    return table.concat({
      "SELECT p.projection_name AS name, p.projection_basename AS basename, p.create_type, p.is_up_to_date",
      "FROM v_catalog.projections p JOIN v_catalog.tables t ON t.table_id = p.anchor_table_id",
      "WHERE t.table_schema = " .. literal(node.schema or "public"),
      "AND t.table_name = " .. literal(node.name),
      "ORDER BY p.projection_name",
    }, " ")
  end
  return nil, "unsupported schema node"
end

function M.metadata_categories(_, row)
  local categories = { { id = "columns", label = "columns" } }
  if row.type == "table" then
    append(categories, {
      { id = "primary_keys", label = "primary keys" },
      { id = "foreign_keys", label = "foreign keys" },
      { id = "projections", label = "projections" },
    })
  end
  return categories
end

function M.object_actions(options, row, limit)
  local actions = {
    { id = "sample", kind = "query_buffer", label = "Open sample statement", statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", qualified(row), limit) },
    { id = "columns", kind = "statement", label = "Columns", statement = assert(M.schema_statement(options, { type = "columns", name = row.name, schema = row.schema })) },
  }
  if row.type == "table" then
    for _, category in ipairs({ "primary_keys", "foreign_keys", "projections" }) do
      table.insert(actions, {
        id = category,
        kind = "statement",
        label = category:gsub("_", " "):gsub("^%l", string.upper),
        statement = assert(M.schema_statement(options, { type = category, name = row.name, schema = row.schema })),
      })
    end
  else
    table.insert(actions, {
      id = "definition",
      kind = "statement",
      label = "Definition",
      statement = "SELECT view_definition AS definition FROM v_catalog.views WHERE table_schema = " .. literal(row.schema or "public") .. " AND table_name = " .. literal(row.name),
    })
  end
  return actions
end

local function unescape(value)
  value = value:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
  value = value:gsub("&#x([%x]+);", function(number)
    return vim.fn.nr2char(tonumber(number, 16))
  end):gsub("&#(%d+);", function(number)
    return vim.fn.nr2char(tonumber(number))
  end)
  return value:gsub("&amp;", "&")
end

function M.parse(output)
  local table_output = output:match("<table[^>]*>(.-)</table>")
  if not table_output then
    return {}
  end
  local records = {}
  for row in table_output:gmatch("<tr[^>]*>(.-)</tr>") do
    local record = {}
    local tag = row:find("<th[^>]*>") and "th" or "td"
    for value in row:gmatch("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">") do
      table.insert(record, { tag = tag, value = unescape(value) })
    end
    if #record > 0 then
      table.insert(records, record)
    end
  end
  if #records == 0 or records[1][1].tag ~= "th" then
    return {}
  end
  local rows = {}
  for row_index = 2, #records do
    local row = {}
    for column_index, header in ipairs(records[1]) do
      local value = records[row_index][column_index] and records[row_index][column_index].value
      if value == nil or value == null_marker then
        row[header.value] = vim.NIL
      else
        row[header.value] = value
      end
    end
    table.insert(rows, row)
  end
  return rows
end

return M
