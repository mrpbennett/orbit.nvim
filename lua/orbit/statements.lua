-- orbit/statements.lua
--
-- Responsible for figuring out *which SQL text* should actually be sent to
-- the database when the user runs ":OrbitExecute". The tricky part isn't
-- running the query -- it's deciding what "the statement" means: if the
-- user has an explicit visual selection, use that; otherwise fall back to
-- the whole buffer, but only if the buffer is unambiguously a single
-- statement (this module deliberately does NOT do real SQL parsing -- see
-- the comment inside M.target for why).
--
-- This module is called by the query runner (lua/orbit/query.lua) which
-- builds the `request` table (buffer lines + optional selection) from the
-- current buffer and command range, then uses the returned SQL text (or
-- error) to decide whether to run the query or show an error to the user.
-- This module does no Neovim API calls or I/O itself -- it's pure text
-- logic, which keeps it easy to unit test.
--
-- Exports:
--   M.target(request) -> sql_text, nil   OR   nil, error_message
local M = {}

-- Extracts the text of an explicit visual selection from `lines`, if one
-- was given. This is the "explicit" path: when the caller passed a
-- selection, we trust it completely rather than guessing.
--
-- Parameters:
--   lines (table) - array of buffer line strings (1-indexed, as Neovim
--     buffer lines normally are).
--   selection (table|nil) - either nil (no selection was made) or a table
--     with `start_row` and `end_row` (1-based, inclusive line numbers).
--
-- Returns:
--   On no selection: nil (meaning "caller should fall back to the whole
--     buffer").
--   On a valid selection: the joined text of the selected lines (string).
--   On an invalid/malformed selection object: nil, error_message (string).
--   On an empty range (start after end, once clamped): nil, error_message.
--
-- Side effects: none (pure function).
local function selected_lines(lines, selection)
  if not selection then
    return nil
  end
  if type(selection.start_row) ~= "number" or type(selection.end_row) ~= "number" then
    return nil, "selection requires start_row and end_row"
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
--     request.selection (table|nil) - optional { start_row, end_row }, as
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
    return explicit
  end

  -- No usable selection was given, so fall back to treating the entire
  -- buffer as the statement.
  local contents = table.concat(request.lines, "\n")
  if contents:match("^%s*$") then
    return nil, "buffer is empty"
  end

  -- `contents:gsub(";", "")` returns two values: the string with all `;`
  -- removed, and (as the second return value, captured here via
  -- `select(2, ...)`) the *count* of substitutions made -- i.e. how many
  -- semicolons the buffer contains.
  local semicolons = select(2, contents:gsub(";", ""))
  -- This is intentionally a safety rule, not SQL parsing: ambiguous buffers require a selection.
  -- Rationale for the two conditions below:
  --   - More than one semicolon anywhere means the buffer very likely holds
  --     multiple statements, and picking "the" statement to run would be a
  --     guess -- so refuse and ask the user to select explicitly.
  --   - Exactly one semicolon is only considered safe if it's the very last
  --     non-whitespace character in the buffer (i.e. one statement,
  --     properly terminated); one semicolon anywhere else in the middle of
  --     the buffer suggests a second statement follows it, so it's treated
  --     as ambiguous too.
  if semicolons > 1 or (semicolons == 1 and not contents:match(";%s*$")) then
    return nil, "statement is ambiguous; select the statement explicitly"
  end

  return contents
end

return M
