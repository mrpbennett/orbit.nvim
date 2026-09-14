-- Microsoft SQL Server connector backed by Microsoft's Go sqlcmd.
local M = {
	sql_dialect = "mssql",
	-- The environment returned below is complete, not an overlay. Session can
	-- honor this flag to keep inherited SQLCMD configuration out of the child.
	inherit_environment = false,
}

local metadata = require("orbit.connectors.metadata")
local schema_pattern = require("orbit.connectors.utils.schema_pattern")
local tokenizer = require("orbit.sql.tokenizer")

local separator = string.char(31)
local default_port = 1433

local function literal(value)
	return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function identifier(value)
	return "[" .. tostring(value):gsub("]", "]]") .. "]"
end

local function qualified(row)
	return identifier(row.schema or "dbo") .. "." .. identifier(row.name)
end

local function is_integer(value, minimum, maximum)
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
		and (minimum == nil or value >= minimum)
		and (maximum == nil or value <= maximum)
end

function M.validate_options(profile_name, options)
	local allowed = {
		confirm_mutations = true,
		database = true,
		executable = true,
		host = true,
		password = true,
		password_env = true,
		port = true,
		schema_patterns = true,
		trust_server_certificate = true,
		user = true,
	}
	for name in pairs(options) do
		if not allowed[name] then
			return nil, string.format("profile %q has unsupported MSSQL option %q", profile_name, name)
		end
	end
	if options.executable ~= nil and (type(options.executable) ~= "string" or options.executable == "") then
		return nil, string.format("profile %q options.executable must be a non-empty string", profile_name)
	end
	if options.confirm_mutations ~= nil and type(options.confirm_mutations) ~= "boolean" then
		return nil, string.format("profile %q options.confirm_mutations must be a boolean", profile_name)
	end
	for _, name in ipairs({ "host", "database", "user" }) do
		if type(options[name]) ~= "string" or options[name] == "" then
			return nil, string.format("profile %q requires options.%s", profile_name, name)
		end
	end
	for _, name in ipairs({ "password", "password_env" }) do
		if options[name] ~= nil and (type(options[name]) ~= "string" or options[name] == "") then
			return nil, string.format("profile %q options.%s must be a non-empty string", profile_name, name)
		end
	end
	if options.password ~= nil and options.password_env ~= nil then
		return nil, string.format("profile %q options.password and options.password_env are mutually exclusive", profile_name)
	end
	if options.port ~= nil and not is_integer(options.port, 1, 65535) then
		return nil, string.format("profile %q options.port must be an integer between 1 and 65535", profile_name)
	end
	if options.trust_server_certificate ~= nil and type(options.trust_server_certificate) ~= "boolean" then
		return nil, string.format("profile %q options.trust_server_certificate must be a boolean", profile_name)
	end
	if options.schema_patterns ~= nil then
		if type(options.schema_patterns) ~= "table" or not vim.islist(options.schema_patterns) or #options.schema_patterns == 0 then
			return nil, string.format("profile %q options.schema_patterns must be a non-empty array", profile_name)
		end
		for _, pattern in ipairs(options.schema_patterns) do
			if type(pattern) ~= "string" or pattern == "" then
				return nil, string.format("profile %q options.schema_patterns must contain non-empty strings", profile_name)
			end
		end
	end
	return true
end

local function password(options)
	local password = options.password
	if options.password_env then
		password = vim.env[options.password_env]
		if password == nil or password == "" then
			return nil, string.format("environment variable %q does not contain an MSSQL password", options.password_env)
		end
	end
	if password == nil or password == "" then
		return nil, "MSSQL password is required through options.password or options.password_env"
	end
	return password
end

function M.session_command(options)
	local _, err = password(options)
	if err then
		return nil, err
	end
	local command = {
		options.executable or "sqlcmd",
		"-S", string.format("tcp:%s,%d", options.host, options.port or default_port),
		"-d", options.database,
		"-U", options.user,
		"-N", "mandatory",
	}
	if options.trust_server_certificate then
		command[#command + 1] = "-C"
	end
	vim.list_extend(command, { "-s", separator, "-w", "65535", "-y", "8000", "-Y", "8000", "-x" })
	return command
end

-- Return a complete child environment with every inherited SQLCMD setting
-- removed. The retained Session must replace, rather than merge, this table.
function M.environment(options, inherited)
	local resolved, err = password(options)
	if not resolved then
		return nil, err
	end
	local environment = {}
	for name, value in pairs(inherited or vim.fn.environ()) do
		local normalized = tostring(name):upper()
		if not normalized:match("^SQLCMD") and normalized ~= tostring(options.password_env or ""):upper() then
			environment[name] = value
		end
	end
	environment.SQLCMDPASSWORD = resolved
	return environment
end

local function sqlcmd_control(statement)
	local bare_commands = {
		ED = true,
		EXIT = true,
		QUIT = true,
		RESET = true,
	}
	local statement_lines = vim.split(statement, "\n", { plain = true })
	local eligible = tokenizer.mssql_command_rows(statement_lines)
	for row, line in ipairs(statement_lines) do
		local command = line:match("^%s*(.-)%s*$")
		local upper = command:upper()
		if eligible[row] and (command:sub(1, 1) == ":" or command:sub(1, 2) == "!!") then
			return command:match("^%S+")
		end
		for name in pairs(bare_commands) do
			if eligible[row]
				and (upper == name or upper:match("^" .. name .. "[ \t]") or (name == "EXIT" and upper:match("^EXIT[ \t]*%("))) then
				return name
			end
		end
		if eligible[row] and (upper == "ON ERROR" or upper:match("^ON[ \t]+ERROR[ \t]")) then
			return "ON ERROR"
		end
	end
	return nil
end

-- Preserve fatal sqlcmd diagnostics when the process exits before its end
-- marker. Ordinary SQL errors remain inside complete framed stdout responses.
function M.session_exit_error(stdout, stderr)
	stdout = stdout or ""
	local start_at = stdout:find("Msg %d+,") or stdout:find("[Ss]qlcmd:")
	local details = {}
	if start_at then
		details[#details + 1] = vim.trim(stdout:sub(start_at))
	end
	if stderr and vim.trim(stderr) ~= "" then
		details[#details + 1] = vim.trim(stderr)
	end
	return #details > 0 and table.concat(details, "\n") or nil
end

function M.session_request(statement, marker)
	if tokenizer.has_mssql_batch_separator(vim.split(statement, "\n", { plain = true })) then
		return nil, "MSSQL statements containing a GO batch separator are not supported"
	end
	local control = sqlcmd_control(statement)
	if control then
		return nil, "MSSQL sqlcmd control command " .. string.format("%q", control) .. " is not supported"
	end
	return table.concat({
		"SET NOCOUNT ON;",
		"SELECT " .. literal(marker .. ":BEGIN") .. " AS [__orbit_frame];",
		"GO",
		statement,
		"GO",
		"SET NOCOUNT ON;",
		"SELECT " .. literal(marker .. ":END") .. " AS [__orbit_frame];",
		"GO",
		"",
	}, "\n")
end

local function lines(output)
	local result, start_at = {}, 1
	while true do
		local newline = output:find("\n", start_at, true)
		if not newline then
			break
	end
		local text = output:sub(start_at, newline - 1)
		if text:sub(-1) == "\r" then
			text = text:sub(1, -2)
		end
		result[#result + 1] = { text = text, start_at = start_at, finish = newline }
		start_at = newline + 1
	end
	return result
end

local function marker_record(records, marker, suffix, first)
	for index = first or 1, #records - 3 do
		local heading = vim.trim(records[index].text)
		local underline = vim.trim(records[index + 1].text)
		local value = vim.trim(records[index + 2].text)
		if heading == "__orbit_frame"
			and underline ~= ""
			and underline:match("^%-+$")
			and value == marker .. suffix
			and records[index + 3].text == ""
		then
			return index
		end
	end
	return nil
end

function M.session_output(output, marker)
	local records = lines(output)
	local begin = marker_record(records, marker, ":BEGIN")
	if not begin then
		return nil
	end
	local ending = marker_record(records, marker, ":END", begin + 4)
	if not ending then
		return nil
	end
	local payload_start = records[begin + 3].finish + 1
	local payload_finish = records[ending].start_at - 1
	return output:sub(payload_start, payload_finish), records[ending + 3].finish
end

local function split_fields(line)
	return vim.split(line, separator, { plain = true })
end

local function message_line(line)
	local value = vim.trim(line)
	return value:match("^Msg %d+,")
		or value:match("^[Ss]qlcmd:")
		or value:match("^%(%d+ row affected%)$")
		or value:match("^%(%d+ rows affected%)$")
		or value:match("^Changed database context to ")
end

function M.parse(output)
	if type(output) ~= "string" then
		return nil, "MSSQL output is required"
	end
	output = output:gsub("\r\n", "\n")
	if output:find("\r", 1, true) then
		return nil, "MSSQL output contains an unexpected carriage return"
	end
	local blocks, block = {}, {}
	for line in (output .. "\n"):gmatch("(.-)\n") do
		if line == "" then
			if #block > 0 then
				blocks[#blocks + 1] = block
				block = {}
			end
		else
			block[#block + 1] = line
		end
	end
	if #blocks == 0 then
		return {}
	end

	local result, columns
	for block_index, current in ipairs(blocks) do
		if message_line(current[1]) then
			return nil, "MSSQL output contains a server message:\n" .. table.concat(current, "\n")
		end
		if #current < 2 then
			return nil, string.format("MSSQL output block %d is a message or malformed result: %s", block_index, current[1])
		end
		local headings = split_fields(current[1])
		local underlines = split_fields(current[2])
		if #underlines ~= #headings then
			return nil, string.format("MSSQL result %d underline has %d fields for %d headings", block_index, #underlines, #headings)
		end
		for index, underline in ipairs(underlines) do
			underline = vim.trim(underline)
			if underline == "" or not underline:match("^%-+$") then
				return nil, string.format("MSSQL result %d has a malformed underline for column %d", block_index, index)
			end
		end
		if columns then
			return nil, "MSSQL output contains multiple tabular results"
		end
		columns, result = {}, {}
		local seen = {}
		for index, heading in ipairs(headings) do
			heading = vim.trim(heading)
			if heading == "" then
				return nil, string.format("MSSQL result %d column %d heading must not be empty", block_index, index)
			end
			if seen[heading] then
				return nil, "MSSQL result has duplicate heading " .. string.format("%q", heading)
			end
			seen[heading] = true
			columns[index] = heading
		end
		for row_index = 3, #current do
			if row_index < #current then
				local possible_underlines = split_fields(current[row_index + 1])
				local all_underlines = #possible_underlines == #columns
				for _, underline in ipairs(possible_underlines) do
					underline = vim.trim(underline)
					all_underlines = all_underlines and underline ~= "" and underline:match("^%-+$") ~= nil
				end
				if all_underlines then
					return nil, "MSSQL output contains multiple tabular results"
				end
			end
			if message_line(current[row_index]) then
				return nil, string.format("MSSQL output contains a server message at result %d row %d:\n%s", block_index, row_index - 2, table.concat(vim.list_slice(current, row_index), "\n"))
			end
			local values = split_fields(current[row_index])
			if #values ~= #columns then
				return nil, string.format("MSSQL result %d row %d has %d fields for %d headings", block_index, row_index - 2, #values, #columns)
			end
			local row = {}
			for index, value in ipairs(values) do
				value = vim.trim(value)
				row[columns[index]] = value
			end
			result[#result + 1] = row
		end
	end
	return result, nil, { columns = columns }
end

function M.qualified_name(_, row)
	return qualified(row)
end

function M.completion_word(_, row)
	return qualified(row)
end

function M.completion_path(_, row)
	return { row.schema or "dbo", row.name }
end

function M.completion_namespaces(_, rows, qualifier_segments)
	if #qualifier_segments > 0 then
		return {}, false
	end
	local schemas = {}
	for _, row in ipairs(rows) do
		schemas[row.schema or "dbo"] = true
	end
	local result = {}
	for schema in pairs(schemas) do
		result[#result + 1] = { name = identifier(schema), kind = "Schema" }
	end
	return result, false
end

function M.schema_statement(options, node)
	if node.type == "tables" then
		local filter = schema_pattern.sql_clause("schema_name", options.schema_patterns)
		local clauses = {
			"SELECT schema_name AS [schema], object_name AS name, object_type AS type",
			"FROM (",
			"SELECT schemas.name AS schema_name, tables.name AS object_name, 'table' AS object_type",
			"FROM sys.tables AS tables JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id",
			"WHERE tables.is_ms_shipped = 0",
			"UNION ALL",
			"SELECT schemas.name AS schema_name, views.name AS object_name, 'view' AS object_type",
			"FROM sys.views AS views JOIN sys.schemas AS schemas ON schemas.schema_id = views.schema_id",
			"WHERE views.is_ms_shipped = 0",
			") AS objects",
		}
		if filter then
			clauses[#clauses + 1] = "WHERE " .. filter
		end
		clauses[#clauses + 1] = "ORDER BY schema_name, object_name"
		return table.concat(clauses, " ")
	end
	if node.type == "columns" and node.name then
		return table.concat({
			"SELECT columns.name AS name, types.name AS type",
			"FROM sys.columns AS columns",
			"JOIN sys.types AS types ON types.user_type_id = columns.user_type_id",
			"JOIN sys.objects AS objects ON objects.object_id = columns.object_id",
			"JOIN sys.schemas AS schemas ON schemas.schema_id = objects.schema_id",
			"WHERE schemas.name = " .. literal(node.schema or "dbo"),
			"AND objects.name = " .. literal(node.name),
			"AND objects.type IN ('U', 'V') AND objects.is_ms_shipped = 0",
			"ORDER BY columns.column_id",
		}, " ")
	end
	return nil, "unsupported schema node"
end

function M.metadata_categories()
	return { metadata.category("columns") }
end

function M.object_actions(options, row, limit)
	return {
		{
			id = "sample",
			kind = "query_buffer",
			label = "Open sample statement",
			statement = string.format("SELECT TOP (%d) *\nFROM %s;", limit, qualified(row)),
		},
		{
			id = "columns",
			kind = "statement",
			label = "Columns",
			statement = assert(M.schema_statement(options, { type = "columns", schema = row.schema, name = row.name })),
		},
	}
end

local function effective_verb(tokens)
	local first
	for index, token in ipairs(tokens) do
		if token.type ~= "comment" and token.type ~= "semicolon" then
			first = index
			break
		end
	end
	if not first or tokens[first].type ~= "identifier" then
		return nil, first
	end
	if tokens[first].text:upper() ~= "WITH" then
		return tokens[first].text:upper(), first
	end
	-- CTE query bodies have depth > 0. The first identifier after the final
	-- top-level closing parenthesis is the operation applied by the statement.
	local saw_close = false
	for index = first + 1, #tokens do
		local token = tokens[index]
		if token.type == "punct" and token.text == ")" and token.depth == 0 then
			saw_close = true
		elseif saw_close and token.depth == 0 then
			if token.type == "punct" and token.text == "," then
				saw_close = false
			elseif token.type == "identifier" then
				return token.text:upper(), index
			end
		end
	end
	return nil
end

function M.requires_confirmation(statement)
	local tokens = tokenizer.tokenize(vim.split(statement, "\n", { plain = true }), "mssql")
	local semicolons, last_code = 0, nil
	for _, token in ipairs(tokens) do
		if token.type ~= "comment" then
			last_code = token
		end
		if token.type == "semicolon" then
			semicolons = semicolons + 1
		end
	end
	if semicolons > 1 or (semicolons == 1 and (not last_code or last_code.type ~= "semicolon")) then
		return true
	end
	local verb, verb_index = effective_verb(tokens)
	if verb ~= "SELECT" then
		return true
	end
	for index = (verb_index or 0) + 1, #tokens do
		local token = tokens[index]
		if token.depth == 0 and token.type == "identifier" then
			local keyword = token.text:upper()
			if keyword == "INTO" or keyword == "INSERT" or keyword == "UPDATE" or keyword == "DELETE"
				or keyword == "MERGE" or keyword == "CREATE" or keyword == "ALTER" or keyword == "DROP"
				or keyword == "TRUNCATE" or keyword == "EXEC" or keyword == "EXECUTE" then
				return true
			end
		end
	end
	return false
end

return M
