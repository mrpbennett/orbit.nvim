local M = {}

-- This is the normalized connector boundary; backend capabilities are optional by design.
local connectors = {
	postgres = require("orbit.connectors.postgres"),
	sqlite = require("orbit.connectors.sqlite"),
	trino = require("orbit.connectors.trino"),
}

function M.connector(profile)
	local connector = connectors[profile and profile.kind]
	if connector then
		return connector
	end
	return nil, "unsupported profile kind: " .. tostring(profile and profile.kind)
end

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
	if profile.kind ~= "trino" and options.schema_patterns ~= nil then
		if type(options.schema_patterns) ~= "table" or not vim.islist(options.schema_patterns) or #options.schema_patterns == 0 then
			return nil, string.format("profile %q options.schema_patterns must be a non-empty array", profile.name)
		end
		for _, schema in ipairs(options.schema_patterns) do
			if type(schema) ~= "string" or schema == "" then
				return nil, string.format("profile %q options.schema_patterns must contain non-empty strings", profile.name)
			end
		end
	end

	local connector, err = M.connector(profile)
	if not connector then
		return nil, err
	end
	return connector.validate_options(profile.name, options)
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

return M
