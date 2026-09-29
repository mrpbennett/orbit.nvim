-- orbit/connectors/init.lua  (require("orbit.connectors"))
--
-- The Connector registry: the one place that knows which connection-profile
-- kinds exist and which Connector module serves each one.
--
-- Everything outside lua/orbit/connectors/ reaches a Connector through here:
--   M.kinds()           -> the supported kinds, in display order
--   M.resolve(profile)  -> the profile's Connector, with every defaulted
--                          member present (see connectors/contract.lua)
--   M.validate(profile) -> the only profile validator: kind, the options
--                          shared by every Connector, then the Connector's
--                          own validate_options (which owns required fields)
--   M.normalize(rows)   -> the Result row guard applied after every parse
--
-- Adding a backend means adding one Connector file and one entry in `kinds`
-- below; profiles.lua, doctor.lua, and the runner need no changes.
local contract = require("orbit.connectors.contract")

local M = {}

-- Ordered so Doctor reports kinds in a stable order.
local kinds = {
	{ kind = "sqlserver", module = "orbit.connectors.sqlserver" },
	{ kind = "mysql", module = "orbit.connectors.mysql" },
	{ kind = "postgres", module = "orbit.connectors.postgres" },
	{ kind = "redis", module = "orbit.connectors.redis" },
	{ kind = "sqlite", module = "orbit.connectors.sqlite" },
	{ kind = "trino", module = "orbit.connectors.trino" },
	{ kind = "vertica", module = "orbit.connectors.vertica" },
}

local modules = {}
for _, entry in ipairs(kinds) do
	modules[entry.kind] = entry.module
end

M.normalize = require("orbit.connectors.utils.rows").normalize

-- Returns: a fresh list of kind strings, e.g. { "sqlserver", "mysql", ... }.
function M.kinds()
	return vim.tbl_map(function(entry)
		return entry.kind
	end, kinds)
end

-- Looks up the Connector for `profile.kind`.
--
-- Parameters: profile (table|nil) - only `profile.kind` is read.
-- Returns: the Connector view (defaulted members always present), or
--   nil, "unsupported profile kind: <kind>".
-- Side effects: none. Repeated calls return the same view per kind.
function M.resolve(profile)
	local module = modules[profile and profile.kind]
	if not module then
		return nil, "unsupported profile kind: " .. tostring(profile and profile.kind)
	end
	return contract.with_defaults(require(module))
end

-- Validates one connection profile's kind and options.
--
-- Only the options every Connector interprets the same way are checked here
-- (`executable`, `arguments`, `confirm_mutations`); everything else, including
-- which fields are required and each field's shape, is the Connector's call.
--
-- Parameters: profile (table) - needs `name`, `kind`, and `options`.
-- Returns: true, or nil and a message naming the profile and the field.
-- Side effects: none.
function M.validate(profile)
	if not modules[profile.kind] then
		return nil, string.format("profile %q has unsupported kind %q", profile.name, tostring(profile.kind))
	end
	local options = profile.options
	if type(options) ~= "table" then
		return nil, string.format("profile %q requires options", profile.name)
	end
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
	return M.resolve(profile).validate_options(profile.name, options)
end

return M
