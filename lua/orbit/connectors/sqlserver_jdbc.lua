-- Structured SQL Server transport backed by an Orbit-owned Java helper and jTDS.
local M = {}

local protocol = "ORBIT/1"
local maximum_response_bytes = 128 * 1024 * 1024

local function default_database(options)
	return type(options.database) == "table" and options.database[1] or options.database
end

local function non_empty_string(value)
	return type(value) == "string" and value ~= ""
end

local function is_absolute_path(value)
	local prefix = value:sub(1, 2)
	return value:sub(1, 1) == "/"
		or prefix == "//"
		or prefix == "\\\\"
		or value:sub(2, 3) == ":/"
		or value:sub(2, 3) == ":\\"
end

local function is_integer(value, minimum, maximum)
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

local function validate_schema_patterns(profile_name, patterns)
	if patterns == nil then
		return true
	end
	if type(patterns) ~= "table" or not vim.islist(patterns) or #patterns == 0 then
		return nil, string.format("profile %q options.schema_patterns must be a non-empty array", profile_name)
	end
	for _, pattern in ipairs(patterns) do
		if not non_empty_string(pattern) then
			return nil, string.format("profile %q options.schema_patterns must contain non-empty strings", profile_name)
		end
	end
	return true
end

function M.selected(options)
	return options.transport == "jdbc"
end

-- Validate only the fields that can be translated into the fixed jTDS
-- connection contract; arbitrary URL and driver properties are intentionally absent.
function M.validate_options(profile_name, options)
	local allowed = {
		authentication = true,
		confirm_mutations = true,
		database = true,
		driver = true,
		driver_path = true,
		host = true,
		instance = true,
		java_executable = true,
		port = true,
		schema_patterns = true,
		transport = true,
		trust_server_certificate = true,
	}
	for name in pairs(options) do
		if not allowed[name] then
			return nil, string.format("profile %q has unsupported SQL Server JDBC option %q", profile_name, name)
		end
	end
	if options.transport ~= "jdbc" then
		return nil, string.format("profile %q options.transport must be %q", profile_name, "jdbc")
	end
	if options.driver ~= "jtds" then
		return nil, string.format("profile %q options.driver must be %q", profile_name, "jtds")
	end
	if not non_empty_string(options.driver_path) then
		return nil, string.format("profile %q requires options.driver_path", profile_name)
	end
	if not is_absolute_path(options.driver_path) then
		return nil, string.format(
			"profile %q options.driver_path must be an absolute path; profile values are not expanded",
			profile_name
		)
	end
	if options.java_executable ~= nil and not non_empty_string(options.java_executable) then
		return nil, string.format("profile %q options.java_executable must be a non-empty string", profile_name)
	end
	if not non_empty_string(options.host) then
		return nil, string.format("profile %q requires options.host", profile_name)
	end
	-- The host is the only profile value placed in the JDBC URL. Reject URL
	-- delimiters so it cannot inject unvalidated jTDS properties.
	if options.host:find("[/%s;]") then
		return nil, string.format("profile %q options.host contains an unsupported JDBC URL character", profile_name)
	end
	if type(options.database) == "table" then
		if not vim.islist(options.database) or #options.database == 0 then
			return nil, string.format("profile %q options.database must be a non-empty string or array", profile_name)
		end
		local seen = {}
		for _, database in ipairs(options.database) do
			if not non_empty_string(database) then
				return nil, string.format("profile %q options.database must contain non-empty strings", profile_name)
			end
			local normalized = database:lower()
			if seen[normalized] then
				return nil, string.format("profile %q options.database must not contain duplicates", profile_name)
			end
			seen[normalized] = true
		end
	elseif options.database ~= nil and not non_empty_string(options.database) then
		return nil, string.format("profile %q options.database must be a non-empty string or array", profile_name)
	end
	if options.instance ~= nil and not non_empty_string(options.instance) then
		return nil, string.format("profile %q options.instance must be a non-empty string", profile_name)
	end
	if options.port ~= nil and not is_integer(options.port, 1, 65535) then
		return nil, string.format("profile %q options.port must be an integer between 1 and 65535", profile_name)
	end
	if options.port ~= nil and options.instance ~= nil then
		return nil, string.format("profile %q options.port and options.instance are mutually exclusive", profile_name)
	end
	for _, name in ipairs({ "confirm_mutations", "trust_server_certificate" }) do
		if options[name] ~= nil and type(options[name]) ~= "boolean" then
			return nil, string.format("profile %q options.%s must be a boolean", profile_name, name)
		end
	end
	local valid, err = validate_schema_patterns(profile_name, options.schema_patterns)
	if not valid then
		return nil, err
	end

	local authentication = options.authentication
	if type(authentication) ~= "table" or vim.islist(authentication) then
		return nil, string.format("profile %q requires options.authentication", profile_name)
	end
	local auth_allowed = { type = true, domain = true, user = true, password = true, password_env = true }
	for name in pairs(authentication) do
		if not auth_allowed[name] then
			return nil, string.format("profile %q has unsupported SQL Server JDBC authentication option %q", profile_name, name)
		end
	end
	if authentication.type ~= "sql_password" and authentication.type ~= "domain_password" then
		return nil, string.format(
			"profile %q options.authentication.type must be %q or %q",
			profile_name,
			"sql_password",
			"domain_password"
		)
	end
	if not non_empty_string(authentication.user) then
		return nil, string.format("profile %q requires options.authentication.user", profile_name)
	end
	if authentication.type == "domain_password" and not non_empty_string(authentication.domain) then
		return nil, string.format("profile %q requires options.authentication.domain", profile_name)
	end
	if authentication.type == "sql_password" and authentication.domain ~= nil then
		return nil, string.format("profile %q options.authentication.domain requires domain_password authentication", profile_name)
	end
	for _, name in ipairs({ "password", "password_env" }) do
		if authentication[name] ~= nil and not non_empty_string(authentication[name]) then
			return nil, string.format("profile %q options.authentication.%s must be a non-empty string", profile_name, name)
		end
	end
	if (authentication.password == nil) == (authentication.password_env == nil) then
		return nil, string.format(
			"profile %q requires exactly one of options.authentication.password or options.authentication.password_env",
			profile_name
		)
	end
	return true
end

local function password(options)
	local authentication = options.authentication
	local resolved = authentication.password
	if authentication.password_env then
		resolved = vim.env[authentication.password_env]
		if resolved == nil or resolved == "" then
			return nil, string.format(
				"environment variable %q does not contain an SQL Server JDBC password",
				authentication.password_env
			)
		end
	end
	return resolved
end

-- Resolve the source helper from runtimepath, with a source-checkout fallback
-- for headless tests that load modules directly through package.path.
function M.helper_path()
	local matches = vim.api.nvim_get_runtime_file("cmd/orbit-sqlserver/OrbitSqlServer.java", false)
	if matches[1] then
		return matches[1]
	end
	-- Tests and direct source checkouts may load Lua through package.path before
	-- adding the repository to runtimepath, so derive the plugin root as a fallback.
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source:sub(2)))))
		return vim.fs.joinpath(root, "cmd", "orbit-sqlserver", "OrbitSqlServer.java")
	end
	return nil
end

-- Start Java in source-file mode with exactly one user-provided driver JAR.
function M.session_command(options)
	local resolved, err = password(options)
	if not resolved then
		return nil, err
	end
	local helper = M.helper_path()
	if not helper then
		return nil, "cannot locate the Orbit SQL Server Java helper"
	end
	return {
		options.java_executable or "java",
		"--class-path",
		options.driver_path,
		helper,
	}
end

-- Keep the activated Java PATH and basic OS/locale settings while excluding
-- credentials and process-injection variables before the protocol starts.
function M.sanitize_environment(options, inherited)
	local password_env = options.authentication.password_env
	local allowed = {
		COMSPEC = true,
		HOME = true,
		JAVA_HOME = true,
		LANG = true,
		LC_ALL = true,
		LOGNAME = true,
		PATH = true,
		PATHEXT = true,
		SYSTEMROOT = true,
		TEMP = true,
		TMP = true,
		TMPDIR = true,
		TZ = true,
		USER = true,
		WINDIR = true,
	}
	local environment = {}
	for name, value in pairs(inherited or vim.fn.environ()) do
		local normalized = tostring(name):upper()
		local is_password_source = password_env and normalized == password_env:upper()
		if not is_password_source and (allowed[normalized] or normalized:match("^LC_")) then
			environment[name] = value
		end
	end
	return environment
end

function M.environment(options, inherited)
	local _, err = password(options)
	if err then
		return nil, err
	end
	return M.sanitize_environment(options, inherited)
end

function M.session_exit_error(_, stderr)
	return stderr and vim.trim(stderr) ~= "" and vim.trim(stderr) or nil
end

-- Length-prefix every UTF-8 field so credentials and arbitrary SQL remain on
-- stdin without becoming ambiguous or appearing in process metadata.
function M.session_request(statement, marker, options)
	local resolved, err = password(options)
	if not resolved then
		return nil, err
	end
	local authentication = options.authentication
	local fields = {
		options.host,
		options.instance or "",
		default_database(options) or "",
		authentication.domain or "",
		authentication.user,
		resolved,
		statement,
	}
	local lengths = {}
	for index, field in ipairs(fields) do
		lengths[index] = #field
	end
	local port = options.port or (options.instance and 0 or 1433)
	local header = table.concat({
		protocol,
		marker,
		lengths[1],
		port,
		lengths[2],
		lengths[3],
		authentication.type == "domain_password" and "D" or "S",
		lengths[4],
		lengths[5],
		lengths[6],
		lengths[7],
		options.trust_server_certificate and "1" or "0",
	}, " ")
	return header .. "\n" .. table.concat(fields)
end

local function decode_envelope(payload)
	local ok, envelope = pcall(vim.json.decode, payload)
	if not ok or type(envelope) ~= "table" or vim.islist(envelope) or type(envelope.ok) ~= "boolean" then
		return nil, "SQL Server JDBC helper returned malformed JSON"
	end
	if not envelope.ok then
		if type(envelope.fatal) ~= "boolean" or not non_empty_string(envelope.error) then
			return nil, "SQL Server JDBC helper returned a malformed error response"
		end
		return envelope
	end
	if envelope.fatal ~= nil or type(envelope.columns) ~= "table" or not vim.islist(envelope.columns) then
		return nil, "SQL Server JDBC helper returned malformed result columns"
	end
	if type(envelope.rows) ~= "table" or not vim.islist(envelope.rows) then
		return nil, "SQL Server JDBC helper returned malformed result rows"
	end
	local seen = {}
	for index, column in ipairs(envelope.columns) do
		if not non_empty_string(column) then
			return nil, string.format("SQL Server JDBC result column %d label must not be empty", index)
		end
		if seen[column] then
			return nil, "SQL Server JDBC result has duplicate label " .. string.format("%q", column)
		end
		seen[column] = true
	end
	for row_index, values in ipairs(envelope.rows) do
		if type(values) ~= "table" or not vim.islist(values) or #values ~= #envelope.columns then
			return nil, string.format("SQL Server JDBC result row %d has an invalid width", row_index)
		end
		for index, value in ipairs(values) do
			if type(value) ~= "string" and value ~= vim.NIL then
				return nil, string.format("SQL Server JDBC result row %d column %d is not text or NULL", row_index, index)
			end
		end
	end
	return envelope
end

-- Consume one exact helper response. A malformed or fatal envelope is returned
-- as a framing error so Session invalidates the complete process generation.
function M.session_output(output, marker)
	local prefix = protocol .. " " .. marker .. " "
	local newline = output:find("\n", 1, true)
	if not newline then
		if #output > 256 or (prefix:sub(1, #output) ~= output and output:sub(1, #prefix) ~= prefix) then
			return nil, nil, "SQL Server JDBC helper returned a malformed frame header"
		end
		return nil
	end
	if newline > 256 or output:sub(1, #prefix) ~= prefix then
		return nil, nil, "SQL Server JDBC helper returned a malformed frame header"
	end
	local length_text = output:sub(#prefix + 1, newline - 1)
	if not length_text:match("^%d+$") then
		return nil, nil, "SQL Server JDBC helper returned a malformed frame length"
	end
	local length = tonumber(length_text)
	if not length or length > maximum_response_bytes then
		return nil, nil, "SQL Server JDBC helper response is too large"
	end
	local consumed = newline + length
	if #output < consumed then
		return nil
	end
	local payload = output:sub(newline + 1, consumed)
	local envelope, decode_err = decode_envelope(payload)
	if not envelope then
		return nil, nil, decode_err
	end
	if envelope.fatal == true then
		return nil, nil, type(envelope.error) == "string" and envelope.error or "SQL Server JDBC connection failed"
	end
	return payload, consumed
end

-- Convert the already-validated ordered row arrays into Orbit's row-map model.
function M.parse(output)
	local envelope, err = decode_envelope(output)
	if not envelope then
		return nil, err
	end
	if not envelope.ok then
		return nil, type(envelope.error) == "string" and envelope.error or "SQL Server JDBC statement failed"
	end
	local rows = {}
	for row_index, values in ipairs(envelope.rows) do
		local row = {}
		for index, value in ipairs(values) do
			row[envelope.columns[index]] = value
		end
		rows[row_index] = row
	end
	local metadata = #envelope.columns > 0 and { columns = envelope.columns } or nil
	return rows, nil, metadata
end

return M
