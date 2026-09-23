-- Redis Connector. Orbit invokes one redis-cli process per Statement and
-- keeps credentials out of argv by supplying REDISCLI_AUTH in a clean child
-- environment.
local M = {}

local function append(values, additions)
	for _, value in ipairs(additions) do
		values[#values + 1] = value
	end
end

local escapes = {
	a = "\a",
	b = "\b",
	n = "\n",
	r = "\r",
	t = "\t",
}

local function positive_integer(value)
	return type(value) == "number" and value % 1 == 0 and value > 0
end

function M.validate_options(profile_name, options)
	local allowed = {
		cacert = true,
		cacertdir = true,
		cert = true,
		confirm_mutations = true,
		database = true,
		executable = true,
		host = true,
		key = true,
		key_limit = true,
		key_pattern = true,
		password_env = true,
		port = true,
		scan_count = true,
		sni = true,
		tls = true,
		user = true,
	}
	for name in pairs(options) do
		if not allowed[name] then
			return nil, string.format("profile %q has unsupported Redis option %q", profile_name, name)
		end
	end
	for _, name in ipairs({ "host", "user", "password_env", "key_pattern" }) do
		if options[name] ~= nil and (type(options[name]) ~= "string" or options[name] == "") then
			return nil, string.format("profile %q options.%s must be a non-empty string", profile_name, name)
		end
	end
	if options.port ~= nil and (not positive_integer(options.port) or options.port > 65535) then
		return nil, string.format("profile %q options.port must be an integer from 1 through 65535", profile_name)
	end
	if options.database ~= nil and (type(options.database) ~= "number" or options.database % 1 ~= 0 or options.database < 0) then
		return nil, string.format("profile %q options.database must be a non-negative integer", profile_name)
	end
	if options.user and not options.password_env then
		return nil, string.format("profile %q options.user requires options.password_env", profile_name)
	end
	for _, name in ipairs({ "key_limit", "scan_count" }) do
		if options[name] ~= nil and not positive_integer(options[name]) then
			return nil, string.format("profile %q options.%s must be a positive integer", profile_name, name)
		end
	end
	if options.tls ~= nil and type(options.tls) ~= "boolean" then
		return nil, string.format("profile %q options.tls must be a boolean", profile_name)
	end
	local tls_fields = { "cacert", "cacertdir", "cert", "key", "sni" }
	for _, name in ipairs(tls_fields) do
		if options[name] ~= nil and (type(options[name]) ~= "string" or options[name] == "") then
			return nil, string.format("profile %q options.%s must be a non-empty string", profile_name, name)
		end
		if options[name] ~= nil and options.tls ~= true then
			return nil, string.format("profile %q options.tls must be true when options.%s is set", profile_name, name)
		end
	end
	if options.cacert and options.cacertdir then
		return nil, string.format("profile %q options.cacert and options.cacertdir are mutually exclusive", profile_name)
	end
	if (options.cert == nil) ~= (options.key == nil) then
		return nil, string.format("profile %q options.cert and options.key must be set together", profile_name)
	end
	return true
end

-- Split one Statement with redis-cli's quoting rules. Passing the resulting
-- argv directly to vim.system avoids involving a shell.
function M.arguments(statement)
	if type(statement) ~= "string" or statement == "" then
		return nil, "Redis statement is required"
	end
	if statement:find("[\r\n]") then
		return nil, "Redis statements must contain exactly one line"
	end
	local arguments = {}
	local index = 1
	while index <= #statement do
		while index <= #statement and statement:sub(index, index):match("%s") do
			index = index + 1
		end
		if index > #statement then
			break
		end
		local value = {}
		local quoted = false
		while index <= #statement do
			local character = statement:sub(index, index)
			if character:match("%s") then
				break
			elseif character == '"' or character == "'" then
				local quote = character
				quoted = true
				index = index + 1
				local closed = false
				while index <= #statement do
					character = statement:sub(index, index)
					if character == quote then
						closed = true
						index = index + 1
						break
					elseif character == "\\" and index < #statement then
						local next_character = statement:sub(index + 1, index + 1)
						if quote == '"' and next_character == "x"
							and statement:sub(index + 2, index + 3):match("^%x%x$")
						then
							local hex = statement:sub(index + 2, index + 3)
							value[#value + 1] = string.char(tonumber(hex, 16))
							index = index + 4
						elseif quote == '"' then
							value[#value + 1] = escapes[next_character] or next_character
							index = index + 2
						elseif next_character == "'" then
							value[#value + 1] = next_character
							index = index + 2
						else
							value[#value + 1] = character
							index = index + 1
						end
					else
						value[#value + 1] = character
						index = index + 1
					end
				end
				if not closed then
					return nil, "Redis statement contains an unterminated quote"
				end
				if index <= #statement and not statement:sub(index, index):match("%s") then
					return nil, "Redis quoted arguments must be followed by whitespace"
				end
			else
				value[#value + 1] = character
				index = index + 1
			end
		end
		if #value > 0 or quoted then
			arguments[#arguments + 1] = table.concat(value)
		end
	end
	if #arguments == 0 then
		return nil, "Redis statement is required"
	end
	return arguments
end

function M.sanitize_environment(options, inherited)
	local environment = vim.deepcopy(inherited or vim.fn.environ())
	environment.REDISCLI_AUTH = nil
	if options.password_env then environment[options.password_env] = nil end
	return environment
end

local function environment(options)
	local inherited = vim.fn.environ()
	local password = options.password_env and inherited[options.password_env] or nil
	local environment = M.sanitize_environment(options, inherited)
	if options.password_env then
		if type(password) ~= "string" or password == "" then
			return nil, string.format("Redis password environment %s is empty", options.password_env)
		end
		environment.REDISCLI_AUTH = password
	end
	return environment
end

function M.quote_argument(value)
	if value ~= "" and not value:find("[%s%z\1-\31\127\"'\\]") then
		return value
	end
	local quoted = { '"' }
	for index = 1, #value do
		local byte = value:byte(index)
		if byte == 34 or byte == 92 then
			quoted[#quoted + 1] = "\\" .. string.char(byte)
		elseif byte == 10 then
			quoted[#quoted + 1] = "\\n"
		elseif byte == 13 then
			quoted[#quoted + 1] = "\\r"
		elseif byte == 9 then
			quoted[#quoted + 1] = "\\t"
		elseif byte < 32 or byte == 127 then
			quoted[#quoted + 1] = string.format("\\x%02x", byte)
		else
			quoted[#quoted + 1] = string.char(byte)
		end
	end
	quoted[#quoted + 1] = '"'
	return table.concat(quoted)
end

-- Return the completed arguments and the token currently being edited. This
-- parser is deliberately tolerant of an unfinished quote because completion
-- runs while the user is still typing.
function M.completion_context(line, col)
	local prefix = (line or ""):sub(1, col)
	local token_start
	local quote
	local index = 1
	while index <= #prefix do
		local character = prefix:sub(index, index)
		if quote then
			if character == "\\" and index < #prefix then
				index = index + 2
			elseif character == quote then
				quote = nil
				index = index + 1
			else
				index = index + 1
			end
		elseif character:match("%s") then
			token_start = nil
			index = index + 1
		else
			token_start = token_start or index
			if character == '"' or character == "'" then
				quote = character
			end
			index = index + 1
		end
	end

	local completed_text = token_start and prefix:sub(1, token_start - 1) or prefix
	local completed = {}
	if not completed_text:match("^%s*$") then
		local err
		completed, err = M.arguments(completed_text)
		if not completed then
			return nil, err
		end
	end
	local partial = ""
	local start_col = #prefix
	if token_start then
		local raw = prefix:sub(token_start)
		start_col = token_start - 1
		local parsed = M.arguments(raw)
		if not parsed and (raw:sub(1, 1) == '"' or raw:sub(1, 1) == "'") then
			parsed = M.arguments(raw .. raw:sub(1, 1))
		end
		partial = parsed and parsed[1] or raw
	end
	local full_arguments = M.arguments(line or "")
	return {
		arguments = completed,
		partial = partial,
		replace_start_col = start_col,
		token_index = #completed + 1,
		total_arguments = full_arguments and math.max(0, #full_arguments - 1) or math.max(0, #completed),
	}
end

function M.prepare(options, statement)
	local arguments, argument_err = M.arguments(statement)
	if not arguments then
		return nil, argument_err
	end
	local child_environment, environment_err = environment(options)
	if not child_environment then
		return nil, environment_err
	end
	local command = {
		options.executable or "redis-cli",
		"-h", options.host,
		"-p", tostring(options.port or 6379),
	}
	if options.user then
		append(command, { "--user", options.user })
	end
	if options.tls then
		command[#command + 1] = "--tls"
		for _, option in ipairs({ "cacert", "cacertdir", "cert", "key", "sni" }) do
			if options[option] then
				append(command, { "--" .. option, options[option] })
			end
		end
	end
	append(command, {
		"-n", tostring(options.database or 0),
		"--json", "--show-pushes", "no", "-e",
	})
	append(command, arguments)
	return command, nil, { clear_env = true, env = child_environment }
end

local function display_value(value)
	if type(value) == "table" then
		return vim.json.encode(value)
	end
	return value
end

-- Format validated redis-cli JSON without decoding it a second time. Walking
-- the source preserves array and object-key order while adding readable space.
local function pretty_json(json)
	local output = {}
	local indent = 0
	local in_string = false
	local escaped = false
	local empty = {}
	local function append(value)
		output[#output + 1] = value
	end
	local function newline()
		append("\n" .. string.rep("  ", indent))
	end
	local function next_non_space(index)
		for next_index = index + 1, #json do
			local character = json:sub(next_index, next_index)
			if not character:match("%s") then
				return character
			end
		end
	end

	for index = 1, #json do
		local character = json:sub(index, index)
		if in_string then
			append(character)
			if escaped then
				escaped = false
			elseif character == "\\" then
				escaped = true
			elseif character == '"' then
				in_string = false
			end
		elseif character == '"' then
			in_string = true
			append(character)
		elseif character == "{" or character == "[" then
			append(character)
			local closing = character == "{" and "}" or "]"
			empty[#empty + 1] = next_non_space(index) == closing and "empty" or "nonempty"
			if empty[#empty] == "nonempty" then
				indent = indent + 1
				newline()
			end
		elseif character == "}" or character == "]" then
			local container = table.remove(empty)
			if container == "nonempty" then
				indent = indent - 1
				newline()
			end
			append(character)
		elseif character == "," then
			append(character)
			newline()
		elseif character == ":" then
			append(": ")
		elseif not character:match("%s") then
			append(character)
		end
	end

	return table.concat(output)
end

-- redis-cli --json preserves the decoded reply for metadata consumers while
-- the result window receives the same native structure as a JSON document.
function M.parse(output)
	local trimmed = vim.trim(output or "")
	if trimmed == "" then
		return {}, nil, {
			columns = { "value" },
			document = { syntax = "json", lines = { "null" } },
			redis_reply = vim.NIL,
		}
	end
	local ok, reply = pcall(vim.json.decode, trimmed)
	if not ok then
		return nil, "redis-cli output is not valid JSON"
	end
	local document_json = trimmed
	if type(reply) == "string" then
		local inner = vim.trim(reply)
		local opening = inner:sub(1, 1)
		if opening == "{" or opening == "[" then
			local inner_ok, inner_value = pcall(vim.json.decode, inner)
			if inner_ok and type(inner_value) == "table" then
				document_json = inner
			end
		end
	end
	local rows = {}
	local columns = { "value" }
	if type(reply) ~= "table" then
		rows[1] = { value = reply }
	elseif trimmed:sub(1, 1) == "[" then
		for _, value in ipairs(reply) do
			rows[#rows + 1] = { value = display_value(value) }
		end
	else
		columns = { "key", "value" }
		local keys = vim.tbl_keys(reply)
		table.sort(keys)
		for _, key in ipairs(keys) do
			rows[#rows + 1] = { key = key, value = display_value(reply[key]) }
		end
	end
	return rows, nil, {
		columns = columns,
		document = { syntax = "json", lines = vim.split(pretty_json(document_json), "\n", { plain = true }) },
		redis_reply = reply,
	}
end

function M.requires_confirmation(statement, profile)
	local arguments = M.arguments(statement)
	if not arguments then
		return true
	end
	local command = require("orbit.redis_cache").command(profile, arguments[1])
	return not (command and command.readonly)
end

return M
