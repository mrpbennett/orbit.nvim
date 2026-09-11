-- MySQL 8.x connector backed by Oracle MySQL or MariaDB command-line clients.
local M = { sql_dialect = "mysql" }

local mutation_sql = require("orbit.connectors.utils.mutation_sql")
local metadata = require("orbit.connectors.metadata")
local entities = require("orbit.connectors.utils.entities")

local function append(target, values)
	for _, value in ipairs(values) do
		target[#target + 1] = value
	end
end

local function literal(value)
	local bytes = tostring(value):gsub(".", function(character)
		return string.format("%02X", string.byte(character))
	end)
	-- Hex text is independent of NO_BACKSLASH_ESCAPES and cannot terminate the
	-- generated literal, unlike either MySQL string-escaping mode.
	return "CONVERT(X'" .. bytes .. "' USING utf8mb4)"
end

local function identifier(value)
	return "`" .. tostring(value):gsub("`", "``") .. "`"
end

local function qualified(options, row)
	return identifier(row.schema or options.database) .. "." .. identifier(row.name)
end

local function client_family(options)
	return options.client_family or "mysql"
end

-- Translate Orbit's stable TLS vocabulary to one client family's flags. The
-- validator rejects modes without an exact family-specific meaning, so this
-- function never silently strengthens or weakens the requested policy.
local function tls_arguments(options)
	if not options.sslmode then
		return {}
	end
	if client_family(options) == "mysql" then
		return { "--ssl-mode=" .. options.sslmode:upper() }
	end
	if options.sslmode == "disabled" then
		return { "--skip-ssl" }
	elseif options.sslmode == "preferred" then
		return { "--ssl", "--skip-ssl-verify-server-cert" }
	end
	return { "--ssl", "--ssl-verify-server-cert" }
end

local function command(options)
	local family = client_family(options)
	local result = { options.executable or (family == "mariadb" and "mariadb" or "mysql") }
	-- User-managed credential options come first; Orbit-owned connection and
	-- machine-output flags come later so an option file cannot corrupt framing.
	append(result, options.arguments or {})
	if options.socket then
		append(result, { "--socket", options.socket, "--protocol=socket" })
	else
		if options.host then
			append(result, { "--host", options.host })
		end
		if options.port then
			append(result, { "--port", tostring(options.port) })
		end
		if options.user then
			append(result, { "--user", options.user })
		end
		result[#result + 1] = "--protocol=tcp"
	end
	append(result, tls_arguments(options))
	append(result, {
		"--xml",
		"--unbuffered",
		"--skip-force",
		"--binary-mode",
		"--skip-reconnect",
		"--default-character-set=utf8mb4",
		options.database,
	})
	return result
end

function M.validate_options(profile_name, options)
	local allowed = {
		arguments = true,
		client_family = true,
		confirm_mutations = true,
		database = true,
		executable = true,
		host = true,
		port = true,
		schema_patterns = true,
		socket = true,
		sslmode = true,
		user = true,
	}
	for name in pairs(options) do
		if not allowed[name] then
			return nil, string.format("profile %q has unsupported MySQL option %q", profile_name, name)
		end
	end
	for _, name in ipairs({ "database", "host", "socket", "user" }) do
		if options[name] ~= nil and (type(options[name]) ~= "string" or options[name] == "") then
			return nil, string.format("profile %q options.%s must be a non-empty string", profile_name, name)
		end
	end
	if options.port ~= nil and (type(options.port) ~= "number" or options.port % 1 ~= 0 or options.port < 1 or options.port > 65535) then
		return nil, string.format("profile %q options.port must be an integer between 1 and 65535", profile_name)
	end
	if options.socket and (options.host or options.port) then
		return nil, string.format("profile %q options.socket cannot be combined with options.host or options.port", profile_name)
	end
	if options.socket and options.sslmode then
		return nil, string.format("profile %q options.sslmode cannot be used with options.socket", profile_name)
	end
	local family = client_family(options)
	if family ~= "mysql" and family ~= "mariadb" then
		return nil, string.format('profile %q options.client_family must be "mysql" or "mariadb"', profile_name)
	end
	local modes = { disabled = true, preferred = true, required = true, verify_ca = true, verify_identity = true }
	if options.sslmode ~= nil and (type(options.sslmode) ~= "string" or not modes[options.sslmode]) then
		return nil, string.format("profile %q options.sslmode is invalid", profile_name)
	end
	if family == "mariadb" and options.sslmode and options.sslmode ~= "disabled" and options.sslmode ~= "preferred" and options.sslmode ~= "verify_identity" then
		return nil, string.format("profile %q MariaDB client does not support sslmode %q", profile_name, options.sslmode)
	end
	return true
end

function M.prepare(options, statement)
	local result = command(options)
	append(result, { "--execute", statement })
	return result
end

function M.session_command(options)
	return command(options)
end

function M.session_request(statement, marker)
	-- A beginning marker, server identity row, diagnostics, and ending marker
	-- make each request recognizable inside one continuous XML stream.
	return table.concat({
		"SELECT " .. literal(marker .. ":BEGIN") .. " AS __orbit_frame;",
		"SELECT CONCAT(@@version, '|', @@version_comment) AS __orbit_server;",
		-- A delimiter on its own line cannot be swallowed by a trailing comment.
		statement .. "\n;",
		"SHOW WARNINGS;",
		"SELECT " .. literal(marker .. ":END") .. " AS __orbit_frame;",
		"",
	}, "\n")
end

function M.session_output(output, marker)
	-- A marker value alone is not a complete frame: wait through the enclosing
	-- resultset so no trailing XML can be attributed to the next request.
	local marker_field = '<field name="__orbit_frame">' .. marker .. ":END</field>"
	local marker_at = output:find(marker_field, 1, true)
	if not marker_at then
		return nil
	end
	local document_at = output:sub(1, marker_at):match(".*()<%?xml")
	local _, result_end = output:find("</resultset>", marker_at, true)
	if not document_at or not result_end then
		return nil
	end
	local line_ending = output:sub(result_end + 1):match("^\r?\n")
	if not line_ending then
		return nil
	end
	return output:sub(1, document_at - 1), result_end + #line_ending
end

function M.session_error(stderr)
	-- Both clients print advisory warnings on stderr for otherwise valid
	-- sessions. SQL failures terminate the no-force client and are handled by
	-- the process exit path; retain any explicit error emitted before a marker.
	return stderr and stderr:lower():find("error", 1, true) and stderr or nil
end

function M.qualified_name(options, row)
	return qualified(options, row)
end

function M.completion_word(options, row)
	return qualified(options, row)
end

local function schema_filter(options)
	local clauses = { "table_schema = DATABASE()" }
	local exact, patterns = {}, {}
	for _, pattern in ipairs(options.schema_patterns or {}) do
		if pattern:find("[%*%?]") then
			local escaped = pattern:gsub("[%%_\\]", "\\%0"):gsub("%*", "%%"):gsub("%?", "_")
			patterns[#patterns + 1] = "table_schema LIKE " .. literal(escaped) .. " ESCAPE X'5C'"
		else
			exact[#exact + 1] = literal(pattern)
		end
	end
	if #exact > 0 then
		clauses[#clauses + 1] = "table_schema IN (" .. table.concat(exact, ", ") .. ")"
	end
	append(clauses, patterns)
	return "(" .. table.concat(clauses, " OR ") .. ")"
end

function M.schema_statement(options, node)
	if node.type == "tables" then
		return table.concat({
			"SELECT table_schema AS `schema`, table_name AS name,",
			"CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS type",
			"FROM information_schema.tables",
			"WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')",
			"AND " .. schema_filter(options),
			"AND table_type IN ('BASE TABLE', 'VIEW')",
			"ORDER BY table_schema, table_name",
		}, " ")
	end
	local schema = literal(node.schema or options.database)
	local name = node.name and literal(node.name)
	if node.type == "columns" and name then
		return "SELECT column_name AS name, column_type AS type FROM information_schema.columns WHERE table_schema = " .. schema .. " AND table_name = " .. name .. " ORDER BY ordinal_position"
	elseif node.type == "primary_keys" and name then
		return "SELECT column_name AS name, seq_in_index AS pk FROM information_schema.statistics WHERE table_schema = " .. schema .. " AND table_name = " .. name .. " AND index_name = 'PRIMARY' ORDER BY seq_in_index"
	elseif node.type == "foreign_keys" and name then
		return "SELECT constraint_name AS id, column_name AS `from`, referenced_table_name AS `table`, referenced_column_name AS `to` FROM information_schema.key_column_usage WHERE table_schema = " .. schema .. " AND table_name = " .. name .. " AND referenced_table_name IS NOT NULL ORDER BY constraint_name, ordinal_position"
	elseif node.type == "indexes" and name then
		return "SELECT index_name AS name, CASE WHEN non_unique = 0 THEN 'unique' ELSE 'index' END AS type, GROUP_CONCAT(column_name ORDER BY seq_in_index) AS columns FROM information_schema.statistics WHERE table_schema = " .. schema .. " AND table_name = " .. name .. " GROUP BY index_name, non_unique ORDER BY index_name"
	end
	return nil, "unsupported schema node"
end

function M.metadata_categories(_, row)
	local categories = { metadata.category("columns") }
	if row.type == "table" then
		append(categories, {
			metadata.category("primary_keys"),
			metadata.category("foreign_keys"),
			metadata.category("indexes"),
		})
	end
	return categories
end

function M.object_actions(options, row, limit)
	local actions = {
		{ id = "sample", kind = "query_buffer", label = "Open sample statement", statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", qualified(options, row), limit) },
		{ id = "columns", kind = "statement", label = "Columns", statement = assert(M.schema_statement(options, { type = "columns", schema = row.schema, name = row.name })) },
	}
	if row.type == "table" then
		for _, category in ipairs({ "primary_keys", "foreign_keys", "indexes" }) do
			actions[#actions + 1] = {
				id = category,
				kind = "statement",
				label = category:gsub("_", " "):gsub("^%l", string.upper),
				statement = assert(M.schema_statement(options, { type = category, schema = row.schema, name = row.name })),
			}
		end
	else
		actions[#actions + 1] = {
			id = "definition",
			kind = "statement",
			label = "Definition",
			statement = "SELECT view_definition AS definition FROM information_schema.views WHERE table_schema = " .. literal(row.schema or options.database) .. " AND table_name = " .. literal(row.name),
		}
	end
	return actions
end

M.editable_table = function(_, row, primary_keys)
	return mutation_sql.editable_table(row, primary_keys)
end

function M.mutation_statement(options, target, changes)
	local statement, err = mutation_sql.build(qualified(options, target), identifier, literal, "START TRANSACTION", target.primary_keys, changes)
	if not statement then
		return nil, err
	end
	-- MySQL spells the standard empty-row insert as an empty column/value list.
	return statement:gsub(" DEFAULT VALUES", " () VALUES ()")
end

local function unescape(value)
	return entities.decode(value, "MySQL XML")
end

-- Decode one flat client-XML row while preserving the distinction between a
-- self-closing SQL NULL field and an ordinary empty element.
local function parse_row(xml)
	local parsed, names = {}, {}
	local offset = 1
	while offset <= #xml do
		local whitespace = xml:sub(offset):match("^%s*") or ""
		offset = offset + #whitespace
		if offset > #xml then
			break
		end
		local start_at, end_at, attributes = xml:sub(offset):find("^<field%s+([^>]*)>")
		if not start_at then
			return nil, nil, "invalid MySQL XML field"
		end
		start_at, end_at = offset + start_at - 1, offset + end_at - 1
		local encoded_name = attributes:match('name="(.-)"')
		if not encoded_name then
			return nil, nil, "MySQL XML field has no name"
		end
		local name, name_err = unescape(encoded_name)
		if not name then
			return nil, nil, name_err
		end
		if name == "" then
			return nil, nil, "MySQL XML field name must not be empty"
		end
		if parsed[name] ~= nil then
			return nil, nil, "duplicate MySQL XML field " .. string.format("%q", name)
		end
		local value
		if attributes:match("/%s*$") then
			value = attributes:match('xsi:nil="true"') and vim.NIL or ""
			offset = end_at + 1
		else
			local close_at, close_end = xml:find("</field>", end_at + 1, true)
			if not close_at then
				return nil, nil, "incomplete MySQL XML field"
			end
			local encoded_value = xml:sub(end_at + 1, close_at - 1)
			if encoded_value:find("<", 1, true) then
				return nil, nil, "invalid MySQL XML field value"
			end
			local value_err
			value, value_err = unescape(encoded_value)
			if value == nil then
				return nil, nil, value_err
			end
			offset = close_end + 1
		end
		parsed[name] = value
		table.insert(names, name)
	end
	if #names == 0 then
		return nil, nil, "MySQL XML rows must contain fields"
	end
	return parsed, names
end

local function skip_whitespace(value, offset)
	local whitespace = value:sub(offset):match("^%s*") or ""
	return offset + #whitespace
end

function M.parse(output)
	-- The clients emit one XML document per result set. Internal framing,
	-- identity, and diagnostics documents are consumed here so callers receive
	-- the same single array-of-rows shape as every other connector.
	if not output or output:match("^%s*$") then
		return {}
	end
	local documents, offset = {}, 1
	while true do
		offset = skip_whitespace(output, offset)
		if offset > #output then
			break
		end
		if output:sub(offset, offset + 4) == "<?xml" then
			local declaration_end = output:find("?>", offset + 5, true)
			if not declaration_end then
				return nil, "incomplete MySQL XML declaration"
			end
			offset = skip_whitespace(output, declaration_end + 2)
		end
		local open_start, open_end = output:sub(offset):find("^<resultset%s*[^>]*>")
		if not open_start then
			return nil, "invalid MySQL XML output"
		end
		open_start, open_end = offset + open_start - 1, offset + open_end - 1
		local close_start, close_end = output:find("</resultset>", open_end + 1, true)
		if not close_start then
			return nil, "incomplete MySQL XML resultset"
		end
		local body = output:sub(open_end + 1, close_start - 1)
		local rows, body_offset, expected_names = {}, 1, nil
		while true do
			body_offset = skip_whitespace(body, body_offset)
			if body_offset > #body then
				break
			end
			local row_start, row_open_end = body:sub(body_offset):find("^<row>")
			if not row_start then
				return nil, "invalid MySQL XML row"
			end
			row_start, row_open_end = body_offset + row_start - 1, body_offset + row_open_end - 1
			local row_close, row_close_end = body:find("</row>", row_open_end + 1, true)
			if not row_close then
				return nil, "incomplete MySQL XML row"
			end
			local row, names, row_err = parse_row(body:sub(row_open_end + 1, row_close - 1))
			if not row then
				return nil, row_err
			end
			local shape = table.concat(names, "\0")
			if expected_names and shape ~= expected_names then
				return nil, "MySQL XML rows have inconsistent columns"
			end
			expected_names = expected_names or shape
			table.insert(rows, row)
			body_offset = row_close_end + 1
		end
		table.insert(documents, rows)
		offset = close_end + 1
	end
	if #documents == 0 then
		return nil, "invalid MySQL XML output"
	end

	local first = documents[1][1]
	local framed = first
		and type(first.__orbit_frame) == "string"
		and first.__orbit_frame:sub(-6) == ":BEGIN"
	local result_sets = {}
	if framed then
		-- Framing has a fixed order: begin, server, zero or more user results,
		-- diagnostics. Position, rather than user-controlled column names or SQL
		-- text, identifies protocol documents.
		local server = documents[2] and documents[2][1]
		local identity = server and tostring(server.__orbit_server) or ""
		if identity:lower():find("mariadb", 1, true) then
			return nil, "MariaDB servers are not supported by the MySQL connector"
		end
		if not identity:match("^8%.") then
			return nil, "MySQL connector requires a MySQL 8.x server"
		end
		for _, warning in ipairs(documents[#documents]) do
			if warning.Level == "Error" then
				return nil, string.format("MySQL error %s: %s", tostring(warning.Code), tostring(warning.Message))
			end
		end
		for index = 3, #documents - 1 do
			result_sets[#result_sets + 1] = documents[index]
		end
	else
		result_sets = documents
	end
	if #result_sets > 1 then
		return nil, "MySQL statements returning multiple result sets are not supported"
	end
	return result_sets[1] or {}
end

return M
