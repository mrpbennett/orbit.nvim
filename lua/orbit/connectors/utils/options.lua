-- orbit/connectors/utils/options.lua
--
-- Small validation helpers shared by Connector `validate_options` functions,
-- so every Connector words the same mistake the same way.
local M = {}

-- Checks that each named option is a non-empty string.
-- Parameters: profile_name (string), options (table), fields (list of names).
-- Returns: true, or nil and "profile "<name>" requires options.<field>".
function M.require_strings(profile_name, options, fields)
	for _, field in ipairs(fields) do
		local value = options[field]
		if type(value) ~= "string" or value == "" then
			return nil, string.format("profile %q requires options.%s", profile_name, field)
		end
	end
	return true
end

-- Checks the list form of `schema_patterns` used by relational Connectors:
-- absent, or a non-empty array of non-empty strings. (Trino validates its
-- own catalog -> patterns map instead.)
-- Returns: true, or nil and an error message.
function M.schema_patterns(profile_name, options)
	local patterns = options.schema_patterns
	if patterns == nil then
		return true
	end
	if type(patterns) ~= "table" or not vim.islist(patterns) or #patterns == 0 then
		return nil, string.format("profile %q options.schema_patterns must be a non-empty array", profile_name)
	end
	for _, pattern in ipairs(patterns) do
		if type(pattern) ~= "string" or pattern == "" then
			return nil, string.format("profile %q options.schema_patterns must contain non-empty strings", profile_name)
		end
	end
	return true
end

return M
