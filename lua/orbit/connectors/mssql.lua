-- Microsoft SQL Server connector with profile-selected transports.
local M = {
	sql_dialect = "mssql",
	-- Each transport returns a complete child environment, not an overlay.
	inherit_environment = false,
}

local metadata = require("orbit.connectors.metadata")
local jdbc = require("orbit.connectors.mssql_jdbc")
local sqlcmd = require("orbit.connectors.mssql_sqlcmd")
local schema_pattern = require("orbit.connectors.utils.schema_pattern")
local tokenizer = require("orbit.sql.tokenizer")

-- Select once at the Connector seam so transport lifecycle details do not leak
-- into shared MSSQL behavior.
local function transport(options)
	return jdbc.selected(options or {}) and jdbc or sqlcmd
end

local function default_database(options)
	return type(options.database) == "table" and options.database[1] or options.database
end

local function literal(value)
	return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function identifier(value)
	return "[" .. tostring(value):gsub("]", "]]") .. "]"
end

local function qualified(options, row)
	local name = identifier(row.schema or "dbo") .. "." .. identifier(row.name)
	if type(options.database) == "table" then
		return identifier(row.catalog or default_database(options)) .. "." .. name
	end
	return name
end

function M.validate_options(profile_name, options)
	return transport(options).validate_options(profile_name, options)
end

function M.session_command(options)
	return transport(options).session_command(options)
end

-- Return the selected transport's complete child environment. The retained
-- Session must replace, rather than merge, this table.
function M.environment(options, inherited)
	return transport(options).environment(options, inherited)
end

-- Preserve the selected transport's fatal diagnostics when a retained process
-- exits before it completes its frame.
function M.session_exit_error(stdout, stderr, options)
	return transport(options).session_exit_error(stdout, stderr, options)
end

function M.session_request(statement, marker, options)
	if tokenizer.has_mssql_batch_separator(vim.split(statement, "\n", { plain = true })) then
		return nil, "MSSQL statements containing a GO batch separator are not supported"
	end
	return transport(options).session_request(statement, marker, options)
end

function M.session_output(output, marker, options)
	return transport(options).session_output(output, marker, options)
end

function M.parse(output, options)
	return transport(options).parse(output, options)
end

function M.qualified_name(options, row)
	return qualified(options, row)
end

function M.completion_word(options, row)
	return qualified(options, row)
end

function M.completion_path(options, row)
	if type(options.database) == "table" then
		return { row.catalog or default_database(options), row.schema or "dbo", row.name }
	end
	return { row.schema or "dbo", row.name }
end

function M.completion_namespaces(options, rows, qualifier_segments)
	if type(options.database) == "table" then
		if #qualifier_segments == 0 then
			local result = {}
			for _, database in ipairs(options.database) do
				result[#result + 1] = { name = identifier(database), kind = "Database" }
			end
			return result, false
		end
		if #qualifier_segments > 1 then
			return {}, false
		end
		local requested = qualifier_segments[1]:lower()
		local database
		for _, candidate in ipairs(options.database) do
			if candidate:lower() == requested then
				database = candidate
				break
			end
		end
		if not database then
			return nil, false
		end
		local schemas = {}
		for _, row in ipairs(rows) do
			if row.catalog and row.catalog:lower() == database:lower() then
				schemas[row.schema or "dbo"] = true
			end
		end
		local result = {}
		for schema in pairs(schemas) do
			result[#result + 1] = { name = identifier(schema), kind = "Schema" }
		end
		return result, true
	end
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
		if type(options.database) == "table" then
			local branches = {}
			local database_filter = schema_pattern.sql_clause("schemas.name", options.schema_patterns)
			for _, database in ipairs(options.database) do
				local catalog = "N" .. literal(database)
				local source = identifier(database) .. ".sys."
				local tables = {
					"SELECT " .. catalog .. " AS catalog, schemas.name COLLATE DATABASE_DEFAULT AS schema_name,",
					"tables.name COLLATE DATABASE_DEFAULT AS object_name, 'table' AS object_type",
					"FROM " .. source .. "tables AS tables",
					"JOIN " .. source .. "schemas AS schemas ON schemas.schema_id = tables.schema_id",
					"WHERE tables.is_ms_shipped = 0",
				}
				local views = {
					"SELECT " .. catalog .. " AS catalog, schemas.name COLLATE DATABASE_DEFAULT AS schema_name,",
					"views.name COLLATE DATABASE_DEFAULT AS object_name, 'view' AS object_type",
					"FROM " .. source .. "views AS views",
					"JOIN " .. source .. "schemas AS schemas ON schemas.schema_id = views.schema_id",
					"WHERE views.is_ms_shipped = 0",
				}
				if database_filter then
					tables[#tables + 1] = "AND " .. database_filter
					views[#views + 1] = "AND " .. database_filter
				end
				branches[#branches + 1] = table.concat(tables, " ")
				branches[#branches + 1] = table.concat(views, " ")
			end
			local clauses = {
				"SELECT catalog, schema_name AS [schema], object_name AS name, object_type AS type",
				"FROM (" .. table.concat(branches, " UNION ALL ") .. ") AS objects",
			}
			clauses[#clauses + 1] = "ORDER BY catalog, schema_name, object_name"
			return table.concat(clauses, " ")
		end
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
		local source = "sys."
		if type(options.database) == "table" then
			source = identifier(node.catalog or default_database(options)) .. ".sys."
		end
		return table.concat({
			"SELECT columns.name AS name, types.name AS type",
			"FROM " .. source .. "columns AS columns",
			"JOIN " .. source .. "types AS types ON types.user_type_id = columns.user_type_id",
			"JOIN " .. source .. "objects AS objects ON objects.object_id = columns.object_id",
			"JOIN " .. source .. "schemas AS schemas ON schemas.schema_id = objects.schema_id",
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
			statement = string.format("SELECT TOP (%d) *\nFROM %s;", limit, qualified(options, row)),
		},
		{
			id = "columns",
			kind = "statement",
			label = "Columns",
			statement = assert(M.schema_statement(options, {
				type = "columns",
				catalog = row.catalog,
				schema = row.schema,
				name = row.name,
			})),
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
