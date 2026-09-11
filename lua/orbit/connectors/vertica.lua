-- Vertica connector backed by the vsql command-line client.
local M = {}
-- A process-local sentinel makes collision with a real cell value negligible;
-- a fixed public sentinel would silently convert that literal value to NULL.
local null_marker = "__ORBIT_NULL_" .. tostring(vim.uv.hrtime()) .. tostring({}):gsub("[^%w]", "") .. "__"

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

local schema_pattern = require("orbit.connectors.utils.schema_pattern")
local metadata = require("orbit.connectors.metadata")
local entities = require("orbit.connectors.utils.entities")

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
  local marker_at = output:find(">" .. marker .. "</td>", 1, true)
  if not marker_at then
    return nil
  end
  local start = output:sub(1, marker_at):match(".*()<table[%s>]")
  if not start or not output:sub(start, marker_at):match("<th[^>]*>__orbit_marker</th>") then
    return nil
  end
  local _, table_end = output:find("</table>", marker_at, true)
  if not table_end then
    return nil
  end
  local line_ending = output:sub(table_end + 1):match("^\r?\n")
  if not line_ending then
    return nil
  end
  return output:sub(1, start - 1), table_end + #line_ending
end

function M.environment(options)
  return options.password and { VSQL_PASSWORD = options.password } or {}
end

function M.qualified_name(_, row)
  return qualified(row)
end

function M.completion_word(_, row)
  return qualified(row)
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
  local categories = { metadata.category("columns") }
  if row.type == "table" then
    append(categories, {
      metadata.category("primary_keys"),
      metadata.category("foreign_keys"),
      metadata.category("projections"),
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
  return entities.decode(value, "Vertica HTML")
end

function M.parse(output)
  local trimmed = vim.trim(output or "")
  if trimmed == "" then
    return {}
  end
  local table_start, table_end, table_output = trimmed:find("^<table[^>]*>(.*)</table>$")
  if not table_start or table_end ~= #trimmed then
    return nil, "invalid Vertica HTML output"
  end

  local records, offset = {}, 1
  while offset <= #table_output do
    local whitespace = table_output:sub(offset):match("^%s*") or ""
    offset = offset + #whitespace
    if offset > #table_output then
      break
    end
    local row_start, row_open_end = table_output:sub(offset):find("^<tr[^>]*>")
    if not row_start then
      return nil, "invalid Vertica HTML row"
    end
    row_start, row_open_end = offset + row_start - 1, offset + row_open_end - 1
    local row_close, row_close_end = table_output:find("</tr>", row_open_end + 1, true)
    if not row_close then
      return nil, "incomplete Vertica HTML row"
    end
    local row_body = table_output:sub(row_open_end + 1, row_close - 1)
    local record, cell_offset = {}, 1
    while cell_offset <= #row_body do
      local cell_whitespace = row_body:sub(cell_offset):match("^%s*") or ""
      cell_offset = cell_offset + #cell_whitespace
      if cell_offset > #row_body then
        break
      end
      local cell_start, cell_open_end, tag = row_body:sub(cell_offset):find("^<(t[hd])[^>]*>")
      if not cell_start then
        return nil, "invalid Vertica HTML cell"
      end
      cell_start, cell_open_end = cell_offset + cell_start - 1, cell_offset + cell_open_end - 1
      local cell_close, cell_close_end = row_body:find("</" .. tag .. ">", cell_open_end + 1, true)
      if not cell_close then
        return nil, "incomplete Vertica HTML cell"
      end
      local encoded = row_body:sub(cell_open_end + 1, cell_close - 1)
      if encoded:find("<", 1, true) then
        return nil, "invalid Vertica HTML cell value"
      end
      local value, value_err = unescape(encoded)
      if value == nil then
        return nil, value_err
      end
      table.insert(record, { tag = tag, value = value })
      cell_offset = cell_close_end + 1
    end
    if #record == 0 then
      return nil, "Vertica HTML rows must contain cells"
    end
    table.insert(records, record)
    offset = row_close_end + 1
  end
  if #records == 0 then
    return nil, "Vertica HTML output has no header row"
  end

  local headers, seen_headers = records[1], {}
  for _, header in ipairs(headers) do
    if header.tag ~= "th" then
      return nil, "Vertica HTML header row must contain only headings"
    end
    if header.value == "" then
      return nil, "Vertica HTML column names must not be empty"
    end
    if seen_headers[header.value] then
      return nil, "duplicate Vertica HTML column " .. string.format("%q", header.value)
    end
    seen_headers[header.value] = true
  end

  local rows = {}
  for row_index = 2, #records do
    if #records[row_index] ~= #headers then
      return nil, string.format("Vertica HTML row %d has %d cells; expected %d", row_index - 1, #records[row_index], #headers)
    end
    local row = {}
    for column_index, header in ipairs(headers) do
      local cell = records[row_index][column_index]
      if cell.tag ~= "td" then
        return nil, "Vertica HTML data rows must contain only cells"
      end
      if cell.value == null_marker then
        row[header.value] = vim.NIL
      else
        row[header.value] = cell.value
      end
    end
    table.insert(rows, row)
  end
  return rows
end

return M
