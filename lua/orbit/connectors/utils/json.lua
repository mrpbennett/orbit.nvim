-- orbit/connectors/utils/json.lua
--
-- The default Connector output parser: turns a database CLI's JSON output
-- into a list of row tables. The Connector registry (orbit/connectors/init.lua)
-- uses M.parse for every Connector that does not define its own `parse`
-- (e.g. SQLite, whose sqlite3 client prints JSON), and Trino's JSON output
-- format calls it directly.
--
-- Exports:
--   M.parse(output) -> rows (array of tables), nil | nil, error_message
local normalize = require("orbit.connectors.utils.rows").normalize

local M = {}

-- Reject duplicate JSON object keys before vim.json.decode overwrites them.
-- Syntax validation still belongs to the decoder; this scan only preserves
-- information that would otherwise be lost during decoding.
local function validate_json_objects(input)
	local stack = {}
	local index = 1
	while index <= #input do
		local character = input:sub(index, index)
		if character:match("%s") then
			index = index + 1
		elseif character == '"' then
			local start_at = index
			index = index + 1
			while index <= #input do
				local current = input:sub(index, index)
				if current == "\\" then
					index = index + 2
				elseif current == '"' then
					break
				else
					index = index + 1
				end
			end
			if index > #input then
				return true -- The JSON decoder reports the syntax error.
			end
			local parent = stack[#stack]
			if parent and parent.kind == "object" and parent.expect_key then
				local raw = input:sub(start_at, index)
				local ok, key = pcall(vim.json.decode, raw)
				if ok then
					if key == "" and parent.row then
						return nil, "CLI output is not valid JSON: column names must not be empty"
					end
					if parent.keys[key] then
						return nil, "CLI output is not valid JSON: duplicate property " .. string.format("%q", key)
					end
					parent.keys[key] = true
				end
				parent.expect_key = false
			end
			index = index + 1
		elseif character == "{" then
			local parent = stack[#stack]
			if parent and parent.kind == "array" and parent.root and parent.expect_value then
				parent.expect_value = false
			end
			table.insert(stack, { kind = "object", keys = {}, expect_key = true })
			index = index + 1
		elseif character == "[" then
			local parent = stack[#stack]
			if parent and parent.kind == "array" and parent.root and parent.expect_value then
				return nil, "CLI output is not valid JSON: rows must be objects"
			end
			table.insert(stack, { kind = "array", root = #stack == 0, expect_value = true })
			index = index + 1
		elseif character == "}" or character == "]" then
			table.remove(stack)
			index = index + 1
		elseif character == "," then
			local parent = stack[#stack]
			if parent then
				if parent.kind == "object" then
					parent.expect_key = true
				elseif parent.root then
					parent.expect_value = true
				end
			end
			index = index + 1
		else
			local parent = stack[#stack]
			if parent and parent.kind == "array" and parent.root and parent.expect_value then
				if character ~= "]" then
					return nil, "CLI output is not valid JSON: rows must be objects"
				end
				parent.expect_value = false
			end
			index = index + 1
		end
	end
	return true
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
	local valid, validation_err = validate_json_objects(output)
	if not valid then
		return nil, validation_err
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
		if output:sub(1, 1) == "[" then
			return normalize(decoded)
		end
		return normalize({ decoded })
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
	return normalize(rows)
end

return M
