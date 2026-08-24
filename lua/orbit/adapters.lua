local M = {}

local connectors = {
	sqlite = require("orbit.connectors.sqlite"),
	trino = require("orbit.connectors.trino"),
}

function M.validate_options(profile)
	local options = profile.options
	if options.executable ~= nil and (type(options.executable) ~= "string" or options.executable == "") then
		return nil, string.format("profile %q options.executable must be a non-empty string", profile.name)
	end
	if options.arguments ~= nil and (type(options.arguments) ~= "table" or not vim.islist(options.arguments)) then
		return nil, string.format("profile %q options.arguments must be an array", profile.name)
	end
	for _, argument in ipairs(options.arguments or {}) do
		if type(argument) ~= "string" then
			return nil, string.format("profile %q options.arguments must contain strings", profile.name)
		end
	end
	if options.confirm_mutations ~= nil and type(options.confirm_mutations) ~= "boolean" then
		return nil, string.format("profile %q options.confirm_mutations must be a boolean", profile.name)
	end

	local connector = connectors[profile.kind]
	if connector then
		return connector.validate_options(profile.name, options)
	end
	return nil, "unsupported profile kind: " .. tostring(profile.kind)
end

function M.prepare(profile, statement)
	if type(profile) ~= "table" or type(profile.options) ~= "table" then
		return nil, "profile options are required"
	end
	if type(statement) ~= "string" or statement == "" then
		return nil, "statement is required"
	end

	local connector = connectors[profile.kind]
	if connector then
		return connector.prepare(profile.options, statement)
	end

	return nil, "unsupported profile kind: " .. tostring(profile.kind)
end

function M.parse(output)
	output = vim.trim(output or "")
	if output == "" then
		return {}
	end

	local ok, decoded = pcall(vim.json.decode, output)
	if ok and type(decoded) == "table" then
		if vim.islist(decoded) then
			return decoded
		end
		return { decoded }
	end

	local rows = {}
	for line in vim.gsplit(output, "\n", { trimempty = true }) do
		local line_ok, row = pcall(vim.json.decode, line)
		if not line_ok or type(row) ~= "table" then
			return nil, "CLI output is not valid JSON"
		end
		table.insert(rows, row)
	end
	return rows
end

function M.schema_statement(profile, node)
	node = node or { type = "tables" }
	local connector = connectors[profile.kind]
	if connector then
		return connector.schema_statement(profile.options, node)
	end
	return nil, "unsupported profile kind: " .. tostring(profile.kind)
end

return M
