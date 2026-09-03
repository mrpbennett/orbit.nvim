-- orbit/adapters.lua
--
-- Responsible for two things that sit at the boundary between a connection
-- "profile" (the user-facing config describing a database connection --
-- kind, options, etc., typically loaded from profiles.json by
-- lua/orbit/profiles.lua) and the actual per-database-kind connector
-- modules (lua/orbit/connectors/postgres.lua, sqlite.lua, trino.lua):
--
--   1. Looking up which connector module handles a given profile's `kind`
--      (M.connector), so callers elsewhere in the plugin (e.g. the query
--      runner) don't need to know about the connectors table themselves.
--   2. Validating a profile's `options` table (M.validate_options) before
--      it's ever used to run a query, catching user config mistakes early
--      with a clear error message instead of failing deep inside a
--      connector or a shelled-out CLI process.
--
-- It also provides M.parse, a small helper for turning a database CLI's
-- text output (expected to be JSON, one object per line, or a JSON array)
-- into a Lua array of row tables -- this is the shape connectors hand back
-- after running a query via an external command-line client.
--
-- Exports:
--   M.connector(profile) -> connector_module, nil | nil, error_message
--   M.validate_options(profile) -> true, nil | nil, error_message
--   M.parse(output) -> rows (array of tables), nil | nil, error_message
local M = {}

-- This is the normalized connector boundary; backend capabilities are optional by design.
-- Each entry maps a profile "kind" string (as written by the user in their
-- profiles.json) to the Lua module responsible for actually talking to that
-- kind of database. Adding support for a new database kind means adding one
-- more connector module and one more entry here.
local connectors = {
	postgres = require("orbit.connectors.postgres"),
	sqlite = require("orbit.connectors.sqlite"),
	trino = require("orbit.connectors.trino"),
	vertica = require("orbit.connectors.vertica"),
}

-- Looks up the connector module responsible for a given profile, based on
-- its `kind` field (e.g. "postgres", "sqlite", "trino").
--
-- Parameters:
--   profile (table|nil) - a connection profile table; only `profile.kind`
--     is read here. May be nil or missing `kind`, in which case lookup
--     simply fails (see Returns).
--
-- Returns:
--   On success: the connector module (table), nil.
--   On failure (unknown/missing kind): nil, error_message (string).
--
-- Side effects: none.
function M.connector(profile)
	local connector = connectors[profile and profile.kind]
	if connector then
		return connector
	end
	return nil, "unsupported profile kind: " .. tostring(profile and profile.kind)
end

-- Validates the `options` table of a connection profile, checking the
-- fields that are common across all connector kinds (executable,
-- arguments, confirm_mutations, schema_patterns) before delegating to the
-- specific connector's own `validate_options` for anything backend-specific
-- (e.g. host/port/database fields). Meant to be called once, e.g. when
-- profiles are loaded or edited, so bad config is caught with a clear
-- message rather than surfacing as a confusing runtime failure later.
--
-- Parameters:
--   profile (table) - a connection profile; expected to have `profile.name`
--     (string, used in error messages), `profile.kind` (string, used to
--     find the connector), and `profile.options` (table, the settings being
--     validated here).
--
-- Returns:
--   On success: whatever the connector's own validate_options returns for
--     the success case (by convention here, `true, nil`).
--   On failure: nil, error_message (string) describing exactly which field
--     is invalid and why.
--
-- Side effects: none (pure validation; does not mutate `profile`).
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
	-- schema_patterns is only meaningful for connectors that need to be told
	-- which schemas to introspect via glob-like patterns; Trino discovers
	-- catalogs/schemas on its own, so this field is validated only for the
	-- other connector kinds (postgres, sqlite).
	if profile.kind ~= "trino" and options.schema_patterns ~= nil then
		if
			type(options.schema_patterns) ~= "table"
			or not vim.islist(options.schema_patterns)
			or #options.schema_patterns == 0
		then
			return nil, string.format("profile %q options.schema_patterns must be a non-empty array", profile.name)
		end
		for _, schema in ipairs(options.schema_patterns) do
			if type(schema) ~= "string" or schema == "" then
				return nil,
					string.format("profile %q options.schema_patterns must contain non-empty strings", profile.name)
			end
		end
	end

	local connector, err = M.connector(profile)
	if not connector then
		return nil, err
	end
	return connector.validate_options(profile.name, options)
end

-- Parses the raw text output of a database CLI client into an array of row
-- tables. Connectors shell out to command-line clients (e.g. psql, sqlite3,
-- trino-cli) and expect them to print results as JSON; this helper copes
-- with the different shapes that JSON output can come in (a single JSON
-- array, a single JSON object, or NDJSON/JSON-Lines with one JSON object
-- per line), since different CLI tools/flags produce different shapes.
--
-- Parameters:
--   output (string|nil) - the raw stdout text captured from running a CLI
--     command. nil is treated the same as an empty string.
--
-- Returns:
--   On success: rows (array of tables), nil. Returns an empty array `{}`
--     for blank/whitespace-only output (i.e. "the query produced no rows"
--     rather than an error).
--   On failure: nil, error_message (string) -- when the output isn't valid
--     JSON in any of the shapes this function understands.
--
-- Side effects: none (pure parsing function). vim.json.decode calls here
-- can be relatively expensive for large output, but they don't touch any
-- global state.
function M.parse(output)
	output = vim.trim(output or "")
	if output == "" then
		return {}
	end

	-- First, try decoding the whole output as one JSON value. pcall is used
	-- because vim.json.decode raises a Lua error (rather than returning
	-- nil) on invalid JSON, and we want to fall back to the line-by-line
	-- attempt below instead of crashing.
	local ok, decoded = pcall(vim.json.decode, output)
	if ok and type(decoded) == "table" then
		-- vim.islist checks whether the decoded table is a proper
		-- sequential array (as opposed to a JSON object decoded into a
		-- Lua table with string keys). A JSON array of rows is returned
		-- as-is; a single JSON object is wrapped in a one-element array so
		-- callers always get a list of rows regardless of which shape the
		-- CLI produced.
		if vim.islist(decoded) then
			return decoded
		end
		return { decoded }
	end

	-- The whole-output parse failed (e.g. because the output is
	-- newline-delimited JSON: one independent JSON object per line, which
	-- is not valid JSON as a single document). Fall back to decoding each
	-- non-empty line individually.
	local rows = {}
	for line in vim.gsplit(output, "\n", { trimempty = true }) do
		local line_ok, row = pcall(vim.json.decode, line)
		-- If any line fails to decode, or decodes to something that isn't
		-- a table (e.g. a bare number or string), we can't trust the
		-- output format at all, so bail out with an error rather than
		-- silently returning partial/garbage rows.
		if not line_ok or type(row) ~= "table" then
			return nil, "CLI output is not valid JSON"
		end
		table.insert(rows, row)
	end
	return rows
end

return M
