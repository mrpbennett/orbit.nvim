-- ============================================================================
-- SQL statement segmentation
-- ============================================================================
-- The single definition of where one Statement ends and the next begins.
-- Execution targeting (orbit.statements), the default and SQL Server Mutating
-- statement checks, and the Structure panel (orbit.sql.structure) all read
-- their boundaries from here so they can never disagree about "the statement".
--
-- Boundaries come from tokenizer output rather than raw text, so a `;` inside
-- a string literal, quoted identifier, comment, or dollar-quoted body is never
-- mistaken for a separator. Recognized procedural forms (compound CREATE
-- FUNCTION/PROCEDURE/TRIGGER and BEGIN ATOMIC) keep their body semicolons
-- inside one statement.
--
-- Completion (orbit.sql.scope.statement_at) deliberately does NOT use this:
-- inside a procedure body it wants the individual body statement around the
-- cursor, not the whole compound statement.
--
-- This module is pure: no Neovim API calls beyond vim.split, no I/O.
-- ============================================================================
local tokenizer = require("orbit.sql.tokenizer")

local M = {}

-- Remove comments and statement terminators, leaving only the tokens that
-- carry SQL meaning. Grammar decisions (first keyword, compound detection)
-- look at these; the original token list is kept for source ranges/labels.
--
-- Params: tokens - an array of tokenizer tokens.
-- Returns: a new array holding only the non-comment, non-semicolon tokens.
function M.significant(tokens)
	local result = {}
	for _, token in ipairs(tokens) do
		if token.type ~= "comment" and token.type ~= "semicolon" then
			table.insert(result, token)
		end
	end
	return result
end

-- Identify statement forms whose internal semicolons are not top-level
-- separators. This intentionally recognizes only forms Orbit can bound
-- conservatively: compound CREATE statements and BEGIN ATOMIC blocks.
local function is_compound(tokens)
	local words = {}
	for _, token in ipairs(tokens) do
		if token.type == "identifier" and token.depth == 0 then
			table.insert(words, token.text:upper())
		end
	end
	if words[1] == "BEGIN" and words[2] == "ATOMIC" then
		return true
	end
	if words[1] ~= "CREATE" then
		return false
	end
	local index = 2
	if words[index] == "OR" and words[index + 1] == "REPLACE" then
		index = index + 2
	end
	if words[index] == "TEMP" or words[index] == "TEMPORARY" then
		index = index + 1
	end
	return words[index] == "TRIGGER" or words[index] == "FUNCTION" or words[index] == "PROCEDURE"
end

-- Split a token stream into statements.
--
-- Ordinary depth-zero semicolons finish a statement. For recognized procedural
-- forms, BEGIN/CASE/IF/LOOP and END maintain a small block-depth counter so body
-- semicolons stay inside one statement. `END IF` and `END LOOP` do not reopen
-- a block because `previous_word` records the preceding END. An explicit
-- DECLARE section may contain separators before its eventual BEGIN.
--
-- Params: tokens - tokenizer output for a whole buffer or selection.
-- Returns: an array of statements in source order. Runs that hold only
-- comments or stray semicolons are omitted, so `#result` is the number of real
-- statements. Each statement is:
--   tokens    - every original token in the run, including comments and the
--               terminating semicolon (needed for exact source ranges/labels).
--   content   - M.significant(tokens); never empty.
--   separator - the terminating semicolon token, or nil for a final statement
--               with no terminator.
--   compound  - true when the statement is a procedural body whose internal
--               grammar callers should not try to interpret.
-- Side effects: none.
function M.split(tokens)
	local statements = {}
	local current = {}
	local compound = false
	local compound_body = false
	local block_depth = 0
	local previous_word

	local function finish(separator)
		local content = M.significant(current)
		if #content > 0 then
			table.insert(statements, {
				tokens = current,
				content = content,
				separator = separator,
				compound = compound_body,
			})
		end
		current = {}
		compound = false
		compound_body = false
		block_depth = 0
		previous_word = nil
	end

	-- Once DECLARE appears in a recognized compound declaration, semicolons are
	-- declarations rather than statement boundaries until BEGIN starts the body.
	local function has_declarations()
		for _, token in ipairs(current) do
			if token.type == "identifier" and token.depth == 0 and token.text:upper() == "DECLARE" then
				return true
			end
		end
		return false
	end

	for _, token in ipairs(tokens) do
		table.insert(current, token)
		-- Compound detection only needs the statement's opening words, so stop
		-- re-checking after a dozen tokens to keep long statements linear.
		if not compound and #current <= 12 then
			local content = M.significant(current)
			compound = is_compound(content)
			if compound and content[1].text:upper() == "BEGIN" then
				compound_body = true
				block_depth = 1
			end
		end
		if compound and token.type == "identifier" and token.depth == 0 then
			local word = token.text:upper()
			if word == "BEGIN" then
				block_depth = block_depth + 1
				compound_body = true
			elseif compound_body and (word == "CASE" or ((word == "IF" or word == "LOOP") and previous_word ~= "END")) then
				block_depth = block_depth + 1
			elseif word == "END" and block_depth > 0 then
				block_depth = block_depth - 1
			end
			previous_word = word
		end
		local awaiting_body = compound and not compound_body and has_declarations()
		if token.type == "semicolon" and token.depth == 0 and not awaiting_body and (not compound_body or block_depth == 0) then
			finish(token)
		end
	end
	finish(nil)
	return statements
end

-- Convenience wrapper: tokenize text and split it into statements.
--
-- Params: text - either an array of lines or a single (possibly multi-line)
-- string; dialect - optional connector-selected tokenizer mode ("mysql",
-- "mssql", or nil for the default lexer).
-- Returns: the same array as M.split.
function M.statements(text, dialect)
	local lines = type(text) == "string" and vim.split(text, "\n", { plain = true }) or text
	return M.split(tokenizer.tokenize(lines, dialect))
end

return M
