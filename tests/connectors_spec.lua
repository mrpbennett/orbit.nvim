-- The Connector contract (lua/orbit/connectors/contract.lua) checked against
-- every registered Connector, plus the registry's own behaviour.
local connectors = require("orbit.connectors")
local contract = require("orbit.connectors.contract")
local json = require("orbit.connectors.utils.json")

local function assert_equal(actual, expected)
	assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

-- Every member name the contract allows, as a set.
local function allowed_members()
	local allowed = {}
	for _, group in ipairs({ contract.required, contract.defaulted, contract.optional }) do
		for _, name in ipairs(group) do
			allowed[name] = true
		end
	end
	return allowed
end

-- The raw module for a kind (not the defaulted view), so we see exactly what
-- the Connector file exports.
local function module_for(kind)
	return require("orbit.connectors." .. kind)
end

return {
	["every Connector exports only members the contract declares"] = function()
		local allowed = allowed_members()
		for _, kind in ipairs(connectors.kinds()) do
			for name in pairs(module_for(kind)) do
				assert(allowed[name], string.format("%s Connector exports undeclared member %q", kind, name))
			end
		end
	end,

	["every Connector implements the required members and one execution path"] = function()
		for _, kind in ipairs(connectors.kinds()) do
			local connector = module_for(kind)
			for _, name in ipairs(contract.required) do
				assert(type(connector[name]) == "function", kind .. " is missing " .. name)
			end
			local session = connector.session_command and connector.session_request and connector.session_output
			assert(connector.prepare or session, kind .. " needs prepare or the session_* members")
			if connector.session_command or connector.session_request or connector.session_output then
				assert(session, kind .. " implements only part of the session_* members")
			end
		end
	end,

	["every Connector can be diagnosed by Doctor"] = function()
		for _, kind in ipairs(connectors.kinds()) do
			local connector = assert(connectors.resolve({ kind = kind }))
			if not connector.diagnose then
				local executable = connector.executable({})
				assert(type(executable) == "string" and executable ~= "", kind .. " has no default executable")
				assert(connector.executable({ executable = "/opt/custom" }) == "/opt/custom", kind .. " ignores executable")
				assert(vim.islist(connector.version_args), kind .. " has no version_args")
			end
		end
	end,

	["every Connector rejects a profile without its required options"] = function()
		for _, kind in ipairs(connectors.kinds()) do
			local valid, err = connectors.validate({ name = "empty", kind = kind, options = {} })
			assert(valid == nil and err:match('^profile "empty" requires options%.'), kind .. ": " .. tostring(err))
		end
	end,

	["the registry resolves every kind to one defaulted view and rejects unknown kinds"] = function()
		assert_equal(connectors.kinds(), { "sqlserver", "mysql", "postgres", "redis", "sqlite", "trino", "vertica" })
		for _, kind in ipairs(connectors.kinds()) do
			local connector = assert(connectors.resolve({ kind = kind }))
			assert(connector == connectors.resolve({ kind = kind }), kind .. " resolves to different views")
			for _, name in ipairs(contract.defaulted) do
				assert(connector[name] ~= nil, kind .. " view is missing defaulted " .. name)
			end
		end
		local unknown, err = connectors.resolve({ kind = "unknown" })
		assert(unknown == nil)
		assert(err == "unsupported profile kind: unknown")
	end,

	["the registry validates shared options before the Connector's own rules"] = function()
		local base = { name = "shared", kind = "sqlite", options = { path = "/tmp/orbit.db" } }
		assert(connectors.validate(base))
		local missing, missing_err = connectors.validate({ name = "shared", kind = "sqlite" })
		assert(missing == nil and missing_err == 'profile "shared" requires options')
		local cases = {
			{ { kind = "unknown", options = {} }, 'unsupported kind "unknown"' },
			{ { options = { path = "/tmp/orbit.db", executable = "" } }, "options.executable must be a non%-empty string" },
			{ { options = { path = "/tmp/orbit.db", arguments = "-x" } }, "options.arguments must be an array" },
			{ { options = { path = "/tmp/orbit.db", arguments = { 1 } } }, "options.arguments must contain strings" },
			{ { options = { path = "/tmp/orbit.db", confirm_mutations = "no" } }, "options.confirm_mutations must be a boolean" },
			{ { options = { path = "/tmp/orbit.db", schema_patterns = {} } }, "options.schema_patterns must be a non%-empty array" },
		}
		for _, case in ipairs(cases) do
			local profile = vim.tbl_extend("force", base, case[1])
			local valid, err = connectors.validate(profile)
			assert(valid == nil and err:match(case[2]), tostring(err))
		end
	end,

	["contract defaults fill missing hooks and keep a Connector's own"] = function()
		local raw = { sql_dialect = "postgres", session_error = function() return "custom" end }
		local view = contract.with_defaults(raw)
		assert(contract.with_defaults(raw) == view and contract.with_defaults(view) == view)
		assert(view.session_error("ignored") == "custom")
		assert_equal(view.environment({}, {}), {})
		assert(view.inherit_environment == true)
		assert(view.session_exit_error("out", "err", {}) == nil)
		assert_equal(view.version_args, { "--version" })
		assert_equal(view.parse('[{"id":1}]'), { { id = 1 } })
		assert(view.requires_confirmation("SELECT 1") == false)
		assert(view.requires_confirmation("DELETE FROM items") == true)
		-- Absent optional members stay absent.
		assert(view.editable_table == nil and view.prepare == nil)
		-- The view reads through, so later changes to the module are seen.
		raw.inherit_environment = false
		assert(view.inherit_environment == false)
	end,

	["the default JSON parser accepts JSON arrays and JSON lines"] = function()
		assert_equal(assert(json.parse('[{"id":1}]')), { { id = 1 } })
		assert_equal(assert(json.parse('{"id":1}\n{"id":2}\n')), { { id = 1 }, { id = 2 } })
		assert_equal(json.parse("  "), {})
	end,

	["the default JSON parser rejects lossy or non-row JSON"] = function()
		for _, output in ipairs({ '[1]', '[[1]]', '{"":1}', '{"id":1,"id":2}', '{"nested":{"id":1,"id":2}}' }) do
			local rows, err = json.parse(output)
			assert(rows == nil and err, output)
		end
		local rows, err = json.parse('{"id":1}\n2\n')
		assert(rows == nil and err)
		assert_equal(assert(json.parse('[{"payload":{"":"value"}}]')), { { payload = { [""] = "value" } } })
	end,
}
