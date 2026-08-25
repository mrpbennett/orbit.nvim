local M = {}

-- This is the normalized connector boundary; backend capabilities are optional by design.
local connectors = {
	postgres = require("orbit.connectors.postgres"),
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

function M.parse_profile(profile, output)
	local connector = connectors[profile.kind]
	if connector and connector.parse then
		return connector.parse(output)
	end
	return M.parse(output)
end

function M.environment(profile)
	local connector = connectors[profile.kind]
	if connector and connector.environment then
		return connector.environment(profile.options)
	end
	return {}
end

function M.supports_session(profile)
  local connector = connectors[profile.kind]
  return connector ~= nil and connector.session_command ~= nil
end

function M.session_command(profile)
  local connector = connectors[profile.kind]
  if connector and connector.session_command then
    return connector.session_command(profile.options)
  end
  return nil, "persistent sessions are not supported for profile kind: " .. tostring(profile.kind)
end

function M.session_request(profile, statement, marker)
  local connector = connectors[profile.kind]
  if connector and connector.session_request then
    return connector.session_request(statement, marker)
  end
  return nil, "persistent sessions are not supported for profile kind: " .. tostring(profile.kind)
end

function M.session_output(profile, output, marker)
  local connector = connectors[profile.kind]
  if connector and connector.session_output then
    return connector.session_output(output, marker)
  end
end

function M.schema_statement(profile, node)
	node = node or { type = "tables" }
	local connector = connectors[profile.kind]
	if connector then
		return connector.schema_statement(profile.options, node)
	end
  return nil, "unsupported profile kind: " .. tostring(profile.kind)
end

function M.metadata_categories(profile, row)
  local connector = connectors[profile.kind]
  if connector and connector.metadata_categories then
    return connector.metadata_categories(profile.options, row)
  end
  return {}
end

function M.object_actions(profile, row, limit)
  local connector = connectors[profile.kind]
  if connector and connector.object_actions then
    return connector.object_actions(profile.options, row, limit)
  end
  return nil, "schema object actions are not supported for profile kind: " .. tostring(profile.kind)
end

function M.editable_table(profile, row, primary_keys)
  local connector = connectors[profile.kind]
  if connector and connector.editable_table then
    return connector.editable_table(profile.options, row, primary_keys)
  end
  return nil, "Result is read-only: editing is not supported by this connection profile."
end

function M.mutation_statement(profile, table, changes)
  local connector = connectors[profile.kind]
  if connector and connector.mutation_statement then
    return connector.mutation_statement(profile.options, table, changes)
  end
  return nil, "Result is read-only: editing is not supported by this connection profile."
end

return M
