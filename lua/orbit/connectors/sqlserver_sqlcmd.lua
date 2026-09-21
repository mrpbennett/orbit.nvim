-- SQL Server transport backed by Microsoft's Go sqlcmd.
local M = {}

local tokenizer = require("orbit.sql.tokenizer")

local separator = string.char(31)
local default_port = 1433

local function default_database(options)
	return type(options.database) == "table" and options.database[1] or options.database
end

local function literal(value)
	return "'" .. tostring(value):gsub("'", "''") .. "'"
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
	if options.transport ~= nil and options.transport ~= "sqlcmd" then
		return nil, string.format("profile %q has unsupported SQL Server transport %q", profile_name, tostring(options.transport))
	end
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
		transport = true,
		user = true,
	}
	for name in pairs(options) do
		if not allowed[name] then
			return nil, string.format("profile %q has unsupported SQL Server option %q", profile_name, name)
		end
	end
	if options.executable ~= nil and (type(options.executable) ~= "string" or options.executable == "") then
		return nil, string.format("profile %q options.executable must be a non-empty string", profile_name)
	end
	if options.confirm_mutations ~= nil and type(options.confirm_mutations) ~= "boolean" then
		return nil, string.format("profile %q options.confirm_mutations must be a boolean", profile_name)
	end
	for _, name in ipairs({ "host", "user" }) do
		if type(options[name]) ~= "string" or options[name] == "" then
			return nil, string.format("profile %q requires options.%s", profile_name, name)
		end
	end
	if type(options.database) == "table" then
		if not vim.islist(options.database) or #options.database == 0 then
			return nil, string.format("profile %q options.database must be a non-empty string or array", profile_name)
		end
		local seen = {}
		for _, database in ipairs(options.database) do
			if type(database) ~= "string" or database == "" then
				return nil, string.format("profile %q options.database must contain non-empty strings", profile_name)
			end
			local normalized = database:lower()
			if seen[normalized] then
				return nil, string.format("profile %q options.database must not contain duplicates", profile_name)
			end
			seen[normalized] = true
		end
	elseif type(options.database) ~= "string" or options.database == "" then
		return nil, string.format("profile %q requires options.database", profile_name)
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
	local resolved = options.password
	if options.password_env then
		resolved = vim.env[options.password_env]
		if resolved == nil or resolved == "" then
			return nil, string.format("environment variable %q does not contain an SQL Server password", options.password_env)
		end
	end
	if resolved == nil or resolved == "" then
		return nil, "SQL Server password is required through options.password or options.password_env"
	end
	return resolved
end

function M.session_command(options)
	local _, err = password(options)
	if err then return nil, err end
	local command = {
		options.executable or "sqlcmd",
		"-S", string.format("tcp:%s,%d", options.host, options.port or default_port),
		"-d", default_database(options),
		"-U", options.user,
		"-N", "mandatory",
	}
	if options.trust_server_certificate then command[#command + 1] = "-C" end
	vim.list_extend(command, { "-s", separator, "-w", "65535", "-y", "8000", "-Y", "8000", "-x" })
	return command
end

-- Remove ambient SQLCMD settings before any child process starts. Diagnostic
-- commands do not need a password, while retained sessions add it separately.
local function sanitized_environment(options, inherited)
	local environment = {}
	for name, value in pairs(inherited or vim.fn.environ()) do
		local normalized = tostring(name):upper()
		if not normalized:match("^SQLCMD") and normalized ~= tostring(options.password_env or ""):upper() then
			environment[name] = value
		end
	end
	return environment
end

-- Diagnostics do not need the user's complete process environment. Keep only
-- basic OS and locale settings so sqlcmd cannot inherit process-injection
-- variables while checking its version.
local function diagnostic_environment(options, inherited)
	local allowed = {
		COMSPEC = true,
		HOME = true,
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
	for name, value in pairs(sanitized_environment(options, inherited)) do
		local normalized = tostring(name):upper()
		if allowed[normalized] or normalized:match("^LC_") then
			environment[name] = value
		end
	end
	return environment
end

-- Return a complete child environment with every inherited SQLCMD setting removed.
function M.environment(options, inherited)
	local resolved, err = password(options)
	if not resolved then return nil, err end
	local environment = sanitized_environment(options, inherited)
	environment.SQLCMDPASSWORD = resolved
	return environment
end

-- Diagnose the sqlcmd transport without opening a database connection. The
-- caller supplies runtime operations so Doctor and its tests cross the same
-- transport seam without this module reaching into Neovim process state.
function M.diagnose(options, runtime, callback)
	local has_profile = options ~= nil
	options = options or {}
	local override = options.executable
	local executable = override or "sqlcmd"
	local resolved = runtime.executable(executable) and runtime.exepath(executable) or ""
	if resolved == "" and runtime.executable(executable) then
		resolved = executable
	end
	local credential
	if not has_profile then
		credential = nil
	elseif options.password_env then
		local value = runtime.getenv(options.password_env)
		credential = { environment = options.password_env, present = value ~= nil and value ~= "" }
	elseif type(options.password) == "string" and options.password ~= "" then
		credential = { configured = true }
	else
		credential = { missing = true }
	end
	local facts = {
		credential = credential,
		executable = { found = resolved ~= "", source = override and "override" or "PATH", value = resolved ~= "" and resolved or executable },
	}
	if resolved == "" then
		facts.findings = { { error = "executable not found", name = "version" } }
		callback(facts)
		return
	end
	runtime.run({ resolved, "--version" }, function(result)
		local version = (result.stdout or ""):match("[Vv]ersion:%s*([^\r\n]+)")
		local stderr = vim.trim(((result.stderr or ""):match("[^\r\n]*") or ""))
		facts.result = result.code == 0 and version and { name = "version", value = version }
			or { error = stderr ~= "" and stderr or "cannot identify Microsoft Go sqlcmd", name = "version" }
		callback(facts)
	end, { clear_env = true, env = diagnostic_environment(options, runtime.environ()) })
end

-- sqlcmd interprets client commands only when they appear in executable SQL
-- rows. The tokenizer prevents string literals and comments from being refused.
local function sqlcmd_control(statement)
	local bare_commands = { ED = true, EXIT = true, QUIT = true, RESET = true }
	local statement_lines = vim.split(statement, "\n", { plain = true })
	local eligible = tokenizer.sqlserver_command_rows(statement_lines)
	for row, line in ipairs(statement_lines) do
		local command = line:match("^%s*(.-)%s*$")
		local upper = command:upper()
		if eligible[row] and (command:sub(1, 1) == ":" or command:sub(1, 2) == "!!") then return command:match("^%S+") end
		for name in pairs(bare_commands) do
			if eligible[row] and (upper == name or upper:match("^" .. name .. "[ \t]") or (name == "EXIT" and upper:match("^EXIT[ \t]*%("))) then
				return name
			end
		end
		if eligible[row] and (upper == "ON ERROR" or upper:match("^ON[ \t]+ERROR[ \t]")) then return "ON ERROR" end
	end
	return nil
end

-- Preserve fatal sqlcmd diagnostics when the process exits before its end marker.
function M.session_exit_error(stdout, stderr)
	stdout = stdout or ""
	local start_at = stdout:find("Msg %d+,") or stdout:find("[Ss]qlcmd:")
	local details = {}
	if start_at then details[#details + 1] = vim.trim(stdout:sub(start_at)) end
	if stderr and vim.trim(stderr) ~= "" then details[#details + 1] = vim.trim(stderr) end
	return #details > 0 and table.concat(details, "\n") or nil
end

function M.session_request(statement, marker)
	-- Framing sends marker result sets before and after user SQL. Session removes
	-- both complete records so adjacent retained requests cannot consume each other.
	local control = sqlcmd_control(statement)
	if control then return nil, "SQL Server sqlcmd control command " .. string.format("%q", control) .. " is not supported" end
	return table.concat({
		"SET NOCOUNT ON;", "SELECT " .. literal(marker .. ":BEGIN") .. " AS [__orbit_frame];", "GO", statement, "GO",
		"SET NOCOUNT ON;", "SELECT " .. literal(marker .. ":END") .. " AS [__orbit_frame];", "GO", "",
	}, "\n")
end

local function lines(output)
	local result, start_at = {}, 1
	while true do
		local newline = output:find("\n", start_at, true)
		if not newline then break end
		local text = output:sub(start_at, newline - 1)
		if text:sub(-1) == "\r" then text = text:sub(1, -2) end
		result[#result + 1] = { text = text, start_at = start_at, finish = newline }
		start_at = newline + 1
	end
	return result
end

-- sqlcmd's tabular frame has a heading, underline, value, and blank separator.
-- Match all four records so a marker-shaped cell cannot complete a request.
local function marker_record(records, marker, suffix, first)
	for index = first or 1, #records - 3 do
		local heading, underline, value = vim.trim(records[index].text), vim.trim(records[index + 1].text), vim.trim(records[index + 2].text)
		if heading == "__orbit_frame" and underline ~= "" and underline:match("^%-+$") and value == marker .. suffix and records[index + 3].text == "" then
			return index
		end
	end
end

function M.session_output(output, marker)
	local records = lines(output)
	local begin = marker_record(records, marker, ":BEGIN")
	if not begin then return nil end
	local ending = marker_record(records, marker, ":END", begin + 4)
	if not ending then return nil end
	return output:sub(records[begin + 3].finish + 1, records[ending].start_at - 1), records[ending + 3].finish
end

local function split_fields(line)
	return vim.split(line, separator, { plain = true })
end

local function message_line(line)
	local value = vim.trim(line)
	return value:match("^Msg %d+,") or value:match("^[Ss]qlcmd:") or value:match("^%(%d+ row affected%)$")
		or value:match("^%(%d+ rows affected%)$") or value:match("^Changed database context to ")
end

-- sqlcmd output is human-formatted and therefore intentionally strict here:
-- reject every detectable ambiguity rather than return an incorrect Result row.
function M.parse(output)
	if type(output) ~= "string" then return nil, "SQL Server output is required" end
	output = output:gsub("\r\n", "\n")
	if output:find("\r", 1, true) then return nil, "SQL Server output contains an unexpected carriage return" end
	local blocks, block = {}, {}
	for line in (output .. "\n"):gmatch("(.-)\n") do
		if line == "" then
			if #block > 0 then blocks[#blocks + 1], block = block, {} end
		else
			block[#block + 1] = line
		end
	end
	if #blocks == 0 then return {} end
	local result, columns
	for block_index, current in ipairs(blocks) do
		if message_line(current[1]) then return nil, "SQL Server output contains a server message:\n" .. table.concat(current, "\n") end
		if #current < 2 then return nil, string.format("SQL Server output block %d is a message or malformed result: %s", block_index, current[1]) end
		local headings, underlines = split_fields(current[1]), split_fields(current[2])
		if #underlines ~= #headings then return nil, string.format("SQL Server result %d underline has %d fields for %d headings", block_index, #underlines, #headings) end
		for index, underline in ipairs(underlines) do
			if vim.trim(underline) == "" or not vim.trim(underline):match("^%-+$") then return nil, string.format("SQL Server result %d has a malformed underline for column %d", block_index, index) end
		end
		if columns then return nil, "SQL Server output contains multiple tabular results" end
		columns, result = {}, {}
		local seen = {}
		for index, heading in ipairs(headings) do
			heading = vim.trim(heading)
			if heading == "" then return nil, string.format("SQL Server result %d column %d heading must not be empty", block_index, index) end
			if seen[heading] then return nil, "SQL Server result has duplicate heading " .. string.format("%q", heading) end
			seen[heading], columns[index] = true, heading
		end
		for row_index = 3, #current do
			if row_index < #current then
				local possible_underlines, all_underlines = split_fields(current[row_index + 1]), true
				all_underlines = #possible_underlines == #columns
				for _, underline in ipairs(possible_underlines) do all_underlines = all_underlines and vim.trim(underline) ~= "" and vim.trim(underline):match("^%-+$") ~= nil end
				if all_underlines then return nil, "SQL Server output contains multiple tabular results" end
			end
			if message_line(current[row_index]) then return nil, string.format("SQL Server output contains a server message at result %d row %d:\n%s", block_index, row_index - 2, table.concat(vim.list_slice(current, row_index), "\n")) end
			local values = split_fields(current[row_index])
			if #values ~= #columns then return nil, string.format("SQL Server result %d row %d has %d fields for %d headings", block_index, row_index - 2, #values, #columns) end
			local row = {}
			for index, value in ipairs(values) do row[columns[index]] = vim.trim(value) end
			result[#result + 1] = row
		end
	end
	return result, nil, { columns = columns }
end

return M
