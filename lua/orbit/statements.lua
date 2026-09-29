--[[
 
  orbit/statements.lua

  Responsible for figuring out *which SQL text* should actually be sent to
  the database when the user runs ":OrbitExecute". The tricky part isn't
  running the query -- it's deciding what "the statement" means: if the
  user has an explicit visual selection, use that; otherwise fall back to
  the whole buffer, but only if the buffer is unambiguously a single
  statement (this module deliberately does NOT do real SQL parsing -- see
  the comment inside M.target for why). It also owns the default lexical
  Mutating statement check (M.requires_confirmation). Both read statement
  boundaries from orbit.sql.segment.

  This module is called by the query runner (lua/orbit/query.lua) which
  builds the `request` table (buffer lines + optional selection) from the
  current buffer and command range, then uses the returned SQL text (or
  error) to decide whether to run the query or show an error to the user.
  This module does no Neovim API calls or I/O itself -- it's pure text
  logic, which keeps it easy to unit test.

  Extracts the text of an explicit visual selection from `lines`, if one
  was given. This is the "explicit" path: when the caller passed a
  selection, we trust it completely rather than guessing.

  Parameters:
    lines (table) - array of buffer line strings (1-indexed, as Neovim
      buffer lines normally are).
    selection (table|nil) - either nil (no selection was made), an inclusive
      whole-line range, or an exact range with 0-based `start_col` and
      end-exclusive `end_col` values.

  Returns:
    On no selection: nil (meaning "caller should fall back to the whole
      buffer").
    On a valid selection: the joined text of the selected lines (string).
    On an invalid/malformed selection object: nil, error_message (string).
    On an empty range (start after end, once clamped): nil, error_message.
--]]

-- Exports:
--   M.target(request) -> sql_text, nil   OR   nil, error_message
--   M.requires_confirmation(statement, dialect) -> boolean
local M = {}
local segment = require("orbit.sql.segment")
local tokenizer = require("orbit.sql.tokenizer")

-- Side effects: none (pure function).
local function selected_lines(lines, selection)
	if not selection then
		return nil
	end
	if type(selection.start_row) ~= "number" or type(selection.end_row) ~= "number" then
		return nil, "selection requires start_row and end_row"
	end
	local has_columns = selection.start_col ~= nil or selection.end_col ~= nil
	if has_columns then
		if type(selection.start_col) ~= "number" or type(selection.end_col) ~= "number" then
			return nil, "exact selection requires start_col and end_col"
		end
		local start_row = selection.start_row
		local end_row = selection.end_row
		local start_col = selection.start_col
		local end_col = selection.end_col
		if
			start_row % 1 ~= 0
			or end_row % 1 ~= 0
			or start_col % 1 ~= 0
			or end_col % 1 ~= 0
			or start_row < 1
			or start_row > #lines
			or end_row < 1
			or end_row > #lines
			or start_row > end_row
			or start_col < 0
			or end_col < 0
			or start_col > #lines[start_row]
			or end_col > #lines[end_row]
			or (start_row == end_row and start_col >= end_col)
		then
			return nil, "selection is empty or outside the buffer"
		end

		local selected = vim.list_slice(lines, start_row, end_row)
		selected[1] = selected[1]:sub(start_col + 1)
		selected[#selected] = selected[#selected]:sub(1, end_col - (start_row == end_row and start_col or 0))
		return table.concat(selected, "\n")
	end

	-- Clamp the requested range to the buffer's actual bounds. This protects
	-- against out-of-range row numbers (e.g. a stale selection from before
	-- lines were deleted) rather than erroring or indexing out of bounds.
	local start_row = math.max(1, selection.start_row)
	local end_row = math.min(#lines, selection.end_row)
	if start_row > end_row then
		return nil, "selection is empty"
	end
	-- vim.list_slice(lines, start_row, end_row) pulls out just the selected
	-- lines (inclusive on both ends), and table.concat with "\n" glues them
	-- back into one multi-line SQL string.
	return table.concat(vim.list_slice(lines, start_row, end_row), "\n")
end

-- Determines the SQL text to execute for a given "execute" request: an
-- explicit visual selection if one was provided, otherwise the whole
-- buffer -- but only when the whole buffer looks unambiguous (see below).
--
-- Parameters:
--   request (table) - expected shape:
--     request.lines (table) - array of buffer line strings (required).
--     request.selection (table|nil) - optional whole-line or exact range, as
--       consumed by `selected_lines` above.
--
-- Returns:
--   On success: sql_text (string), nil.
--   On failure: nil, error_message (string) -- e.g. missing lines, an
--     invalid/empty selection, an empty buffer, or an "ambiguous" buffer
--     (see below).
--
-- Side effects: none (pure function; the caller is responsible for
-- reporting the returned error to the user).
function M.target(request)
	if type(request) ~= "table" or type(request.lines) ~= "table" then
		return nil, "buffer lines are required"
	end

	local explicit, selection_err = selected_lines(request.lines, request.selection)
	if selection_err then
		return nil, selection_err
	end
	if explicit then
		-- A selection that is present but consists only of whitespace isn't
		-- useful to run, so treat it the same as "no statement to execute".
		if explicit:match("^%s*$") then
			return nil, "selection is empty"
		end
		if request.kind == "redis" and explicit:find("[\r\n]") then
			return nil, "Redis execution requires a selection on exactly one line"
		end
		if request.dialect == "mssql" and tokenizer.has_sqlserver_batch_separator(vim.split(explicit, "\n", { plain = true })) then
			return nil, "SQL Server GO batch separators are not supported"
		end
		return explicit
	end
	if request.kind == "redis" then
		if type(request.row) ~= "number" or request.row % 1 ~= 0 or not request.lines[request.row] then
			return nil, "Redis execution requires a cursor line"
		end
		local line = request.lines[request.row]
		if line:match("^%s*$") then
			return nil, "Redis statement line is empty"
		end
		return line
	end

	-- No usable selection was given, so fall back to treating the entire
	-- buffer as the statement.
	local contents = table.concat(request.lines, "\n")
	if contents:match("^%s*$") then
		return nil, "buffer is empty"
	end

	-- This is intentionally a safety rule: a buffer holding more than one
	-- statement requires an explicit selection, because picking "the"
	-- statement to run would be a guess. Boundaries come from orbit.sql.segment
	-- (tokenizer-based), so a `;` inside a string literal or comment, or inside
	-- a recognized procedural body, never counts as a second statement. A
	-- single trailing terminator (or none at all) is one statement.
	if #segment.statements(request.lines, request.dialect) > 1 then
		return nil, "statement is ambiguous; select the statement explicitly"
	end
	if request.dialect == "mssql" and tokenizer.has_sqlserver_batch_separator(request.lines) then
		return nil, "SQL Server GO batch separators are not supported"
	end

	return contents
end

-- First words of statements that only read data. Anything else (including
-- WITH, whose outer operation could be a write) is treated as mutating.
local read_only = {
	describe = true,
	explain = true,
	select = true,
	show = true,
	use = true,
	values = true,
}

-- The default Mutating statement check, used by Connectors that do not
-- provide their own `requires_confirmation`.
--
-- This is deliberately conservative lexical analysis, not SQL parsing: the
-- text must be exactly one statement (per orbit.sql.segment, so comments and
-- quoted `;` are handled) whose first word is a known read-only keyword.
-- Anything else -- several statements, only comments, an unknown first word --
-- asks for confirmation, so ambiguity always falls on the safe side.
--
-- Parameters:
--   statement (string) - the exact text about to be executed.
--   dialect (string|nil) - the Connector's tokenizer mode (connector.sql_dialect).
-- Returns: true if Orbit should confirm before running the statement.
-- Side effects: none (pure function).
function M.requires_confirmation(statement, dialect)
	local found = segment.statements(statement, dialect)
	if #found ~= 1 then
		return true
	end
	local first = found[1].content[1]
	return not (first.type == "identifier" and read_only[first.text:lower()])
end

return M
