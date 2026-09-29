-- orbit/connectors/contract.lua
--
-- The Connector interface, written down in one place.
--
-- A Connector (see docs/agents/CONTEXT.md) is the backend-specific module a
-- connection profile's `kind` selects, e.g. lua/orbit/connectors/postgres.lua.
-- This file lists every member a Connector may export, grouped by how callers
-- may rely on it, and supplies defaults for the members that have a sensible
-- one. A contract spec (tests/connectors_spec.lua) checks every registered
-- Connector against these lists, so a misspelt hook (say `session_eror`)
-- fails a test instead of being silently skipped at runtime.
--
-- Callers never nil-check a *defaulted* member: M.with_defaults(connector)
-- returns a view of the Connector where those members are always present.
-- *Optional* members have no safe default; callers check for them because
-- their absence means the backend genuinely lacks that capability.
local M = {}

-- Must be implemented by every Connector.
M.required = {
	-- validate_options(profile_name, options) -> true | nil, err
	-- Owns every kind-specific rule, including required fields.
	"validate_options",
}

-- Always present after M.with_defaults; a Connector overrides as needed.
M.defaulted = {
	-- parse(output, options, statement) -> rows, err, metadata
	"parse",
	-- requires_confirmation(statement, profile) -> boolean (Mutating statement rule)
	"requires_confirmation",
	-- environment(options, inherited) -> table | nil, err  (extra child env vars)
	"environment",
	-- inherit_environment (boolean): false = child env is *only* `environment`
	"inherit_environment",
	-- session_error(stderr) -> err | nil  (turn retained-session stderr into an error)
	"session_error",
	-- session_exit_error(stdout, stderr, options) -> message | nil
	"session_exit_error",
	-- version_args (list): arguments that make the CLI print its version (Doctor)
	"version_args",
}

-- May be absent. Absence means "this backend cannot do that".
M.optional = {
	-- Execution: a one-shot CLI implements prepare; a retained CLI implements
	-- the three session_* members (orbit/session.lua). Some implement both.
	"prepare",
	"session_command",
	"session_request",
	"session_output",
	-- Tokenizer dialect for statement boundaries and completion.
	"sql_dialect",
	-- Doctor: the CLI a profile runs, the environment for its version probe,
	-- or a complete replacement diagnosis (SQL Server transports).
	"executable",
	"version_environment",
	"diagnose",
	-- Schema acquisition and the Schema browser.
	"schema_statement",
	"metadata_categories",
	"object_actions",
	-- Qualified names and completion.
	"qualified_name",
	"completion_word",
	"completion_path",
	"completion_namespaces",
	-- Editable result grids.
	"editable_table",
	"mutation_statement",
	-- Redis-only helpers used directly by orbit/redis_cache.lua and
	-- orbit/completion.lua.
	"arguments",
	"completion_context",
	"quote_argument",
	"sanitize_environment",
}

-- Defaults for M.defaulted. Each receives the raw Connector so a default can
-- depend on its other members (e.g. the confirmation rule on sql_dialect).
local defaults = {
	parse = function()
		return function(output)
			return require("orbit.connectors.utils.json").parse(output)
		end
	end,
	requires_confirmation = function(connector)
		return function(statement)
			return require("orbit.statements").requires_confirmation(statement, connector.sql_dialect)
		end
	end,
	environment = function()
		return function()
			return {}
		end
	end,
	inherit_environment = function()
		return true
	end,
	session_error = function()
		return function(stderr)
			return stderr
		end
	end,
	session_exit_error = function()
		return function()
			return nil
		end
	end,
	version_args = function()
		return { "--version" }
	end,
}

-- One view per Connector table, so resolving the same Connector twice
-- returns the same object (callers and tests may compare them). Keys are weak
-- so the tables never keep a Connector alive on their own account.
local views = setmetatable({}, { __mode = "k" })
-- The set of views themselves, so a view passed back in is returned as is.
local is_view = setmetatable({}, { __mode = "k" })

-- Returns a view of `connector` in which every M.defaulted member is present.
--
-- The view reads through to the real module on every access (it copies
-- nothing), so a member replaced on the module later -- e.g. by a test -- is
-- still seen. Passing a view back in returns that same view.
--
-- Parameters: connector (table) - a Connector module or test double.
-- Returns: the view table.
function M.with_defaults(connector)
	if is_view[connector] then
		return connector
	end
	if views[connector] then
		return views[connector]
	end
	local filled = {}
	local view = setmetatable({}, {
		__index = function(_, key)
			local value = connector[key]
			if value ~= nil then
				return value
			end
			if defaults[key] then
				-- Build each default once per Connector, on first use.
				if filled[key] == nil then
					filled[key] = defaults[key](connector)
				end
				return filled[key]
			end
			return nil
		end,
	})
	views[connector] = view
	is_view[view] = true
	return view
end

return M
