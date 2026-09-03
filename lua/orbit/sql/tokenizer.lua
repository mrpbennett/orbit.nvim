-- ============================================================================
-- SQL tokenizer (lexer)
-- ============================================================================
-- Pure, dialect-agnostic SQL lexer. Never errors: unterminated strings, quoted
-- identifiers, and block comments close implicitly at end of input instead of
-- raising, because the buffer is routinely mid-edit when completion runs.
--
-- What a "tokenizer" (a.k.a. lexer) is, for anyone who hasn't written one:
-- it's the first stage of turning raw source text into something a program
-- can reason about. Instead of every downstream feature re-scanning the raw
-- buffer text character by character to figure out "is the cursor inside a
-- string literal right now? is this word a keyword or an identifier? where
-- does this statement end?", this module walks the text once and chops it
-- up into a flat list of "tokens" — small tagged chunks like
-- { type = "identifier", text = "users", row = 3, start_col = 7, end_col = 12 }
-- or { type = "punct", text = "(", ... }. Everything after this module
-- works with that clean token list instead of raw characters.
--
-- Internally, tokenizing is implemented as a state machine: a loop that
-- looks at "what character am I on, and what mode am I currently in
-- (plain code? inside a quoted string? inside a comment?)" and decides what
-- to do next based on that. Occasionally it needs to peek at the *next*
-- character before deciding (e.g. seeing if a "-" is followed by another
-- "-" to recognize a "--" comment) — that's called "lookahead", and the
-- `char(offset)` helper below exists specifically to support it.
--
-- Who consumes the token stream this module produces: primarily
-- lua/orbit/sql/scope.lua (which figures out what SQL clause/scope the
-- cursor is currently in, e.g. "inside a SELECT list" vs "inside a WHERE
-- clause") and the completion source (lua/orbit/completion.lua and
-- friends), which uses that scope plus the tokens themselves to decide what
-- completion candidates (table names, column names, keywords, ...) make
-- sense at the cursor position.
--
-- What this module exports: a table `M` with two functions -
--   M.tokenize(lines)      - turns a buffer's lines into a token array.
--   M.split_qualified(text) - splits a dotted, possibly-quoted identifier
--                              chain (e.g. `"my schema".users`) into parts.
-- ============================================================================
local M = {}

-- Character-class helpers used while scanning: each one answers "does this
-- single character belong to category X?" `c` may be nil (meaning "past the
-- end of the input"), which all three treat as "no, not in this class" so
-- callers don't need their own nil-checks everywhere they're used.

-- Digits 0-9. Used to recognize numeric literals (see the is_digit branch
-- in M.tokenize).
local function is_digit(c)
	return c ~= nil and c >= "0" and c <= "9"
end

-- Letters or underscore: the set of characters allowed to *start* an
-- identifier (e.g. a table/column/keyword name). SQL identifiers can't
-- start with a digit, which is what distinguishes this from is_ident_char
-- below.
local function is_ident_start(c)
	return c ~= nil and c:match("[%a_]") ~= nil
end

-- Letters, digits, or underscore: characters allowed *after* the first
-- character of an identifier.
local function is_ident_char(c)
	return c ~= nil and c:match("[%w_]") ~= nil
end

-- Turns a Neovim buffer's lines (a Lua array of line strings, as returned
-- by e.g. vim.api.nvim_buf_get_lines) into a flat array of SQL tokens. This
-- is the main entry point of the tokenizer and the core state machine
-- described in the module comment above.
--
-- Params: lines - a Lua array of strings, one per buffer line, with no
--   trailing "\n" on each (Neovim's own line-splitting convention).
-- Returns: a Lua array of token tables, each shaped like:
--   { type = <string>, text = <string>, row = <1-based line number>,
--     start_col = <0-based column where the token starts>,
--     end_col = <0-based column just past the token>,
--     depth = <current paren nesting depth> }
--   `type` is one of: "comment", "quoted_identifier", "string", "number",
--   "identifier", "semicolon", "punct".
-- Side effects: none — this function only reads `lines` and builds/returns
--   a new table; it does not mutate the buffer or any external state.
--
-- All three connectors agree on '...' strings ('' escaping) and "..." quoted
-- identifiers ("" escaping); see connectors/{postgres,sqlite,trino}.lua.
function M.tokenize(lines)
	-- Joining all lines with "\n" lets the scanner walk one flat string with
	-- a single index `i`, instead of juggling a separate index per line. The
	-- injected "\n" characters are treated specially in `advance()` below so
	-- they still correctly bump `row`/reset `col` without becoming tokens.
	local content = table.concat(lines, "\n")
	local length = #content
	local tokens = {}
	-- Tracks how many "(" we're currently nested inside, incremented/decremented
	-- as "(" and ")" tokens are emitted below. Stored on every emitted token so
	-- downstream code (e.g. scope.lua) can tell, just from the token list,
	-- whether e.g. a comma belongs to a function-call argument list vs. a
	-- top-level column list.
	local depth = 0
	-- `row` (1-based line number) and `col` (0-based column) track the
	-- scanner's current position in "buffer coordinates", separately from
	-- `i` which is the scanner's position as a plain 1-based index into the
	-- flattened `content` string.
	local row, col = 1, 0
	local i = 1

	-- Looks at a character without consuming it ("lookahead"). Passing no
	-- offset (or 0) returns the current character; offset 1 returns the
	-- next one, etc. This is what lets the scanner make decisions like "is
	-- this '-' actually the start of a '--' comment?" by checking the
	-- following character before committing to advance past it.
	-- Returns: the single character at that position, or nil if it's
	--   outside the bounds of `content` (i.e. before the start or past the
	--   end of input).
	local function char(offset)
		local pos = i + (offset or 0)
		if pos < 1 or pos > length then
			return nil
		end
		return content:sub(pos, pos)
	end

	-- Advances past exactly one source byte, keeping row/col in sync. The
	-- injected "\n" separators are consumed here too, resetting col without
	-- ever producing a token, matching the original per-line byte columns.
	local function advance()
		local c = char()
		if c == "\n" then
			row = row + 1
			col = 0
		else
			col = col + 1
		end
		i = i + 1
	end

	-- Appends a finished token to the `tokens` list being built up.
	-- Params:
	--   type_ - the token's type string (e.g. "identifier", "string").
	--   start_row, start_col - where the token began (captured by the
	--     caller before it started advancing past the token's characters).
	--   text - the token's literal text, when useful downstream (comments
	--     and numbers currently emit "" here since their exact text isn't
	--     needed by consumers; identifiers/strings/etc carry the real text).
	-- Note: `end_col` is read from the *current* `col` at the moment of the
	-- call, i.e. wherever the scanner has advanced to by the time `emit` is
	-- called — so callers must call this only after fully advancing past
	-- the token.
	-- Side effects: mutates the enclosing `tokens` array.
	local function emit(type_, start_row, start_col, text)
		table.insert(tokens, {
			type = type_,
			text = text,
			row = start_row,
			start_col = start_col,
			end_col = col,
			depth = depth,
		})
	end

	-- Scans a delimited/quoted run of text, such as a '...' string literal
	-- or a "..." quoted identifier, starting at the current position (which
	-- must be sitting exactly on the opening `quote` character). Handles
	-- SQL's standard doubled-quote escaping rule: two quote characters in a
	-- row inside the literal represent one literal quote character in the
	-- value (e.g. 'it''s' is the string `it's`), rather than ending the
	-- literal.
	-- Params:
	--   quote - the single-character delimiter, either '"' or "'".
	--   escape - accepted but currently unused; every caller relies on the
	--     doubled-quote rule built into this function rather than passing a
	--     distinct escape character.
	-- Returns: start_row, start_col (where the literal began, for use in
	--   emit()), and the literal's full text including its surrounding
	--   quote characters (with any doubled quotes preserved verbatim, not
	--   collapsed to one).
	-- Note: if the input ends before a closing quote is found, this simply
	--   stops at end-of-input rather than raising an error — per the module
	--   comment, unterminated literals must not crash the tokenizer, since
	--   the buffer is frequently mid-edit while completion is running.
	local function scan_delimited(quote, escape)
		local start_row, start_col = row, col
		local text = { quote }
		advance() -- opening quote
		while true do
			local c = char()
			if not c then
				-- Ran off the end of input without a closing quote: stop
				-- here (see the note above) rather than erroring.
				break
			end
			if c == quote then
				if char(1) == quote then
					-- Doubled quote: it's an escaped literal quote
					-- character inside the value, not the end of the
					-- literal. Keep both characters and continue scanning.
					table.insert(text, quote)
					table.insert(text, quote)
					advance()
					advance()
				else
					-- A single quote not followed by another: this closes
					-- the literal.
					table.insert(text, quote)
					advance()
					break
				end
			else
				table.insert(text, c)
				advance()
			end
		end
		return start_row, start_col, table.concat(text)
	end

	-- Main scanning loop: this is the state machine's "dispatch" step. On
	-- each iteration we look at the current character (and sometimes one
	-- character of lookahead) to decide which kind of token we're about to
	-- scan, then hand off to the matching branch below. Each branch is
	-- responsible for fully consuming its token (advancing `i`/row/col past
	-- all of the token's characters) and calling `emit` exactly once before
	-- the loop continues. The branches are checked in order and the first
	-- match wins, so ordering matters (e.g. "--" must be checked before the
	-- generic punctuation fallback, or it would be tokenized as two
	-- separate "-" punct tokens instead of one comment).
	while i <= length do
		local c = char()

		if c == "\n" or c == " " or c == "\t" or c == "\r" then
			-- Whitespace carries no meaning for SQL parsing/completion, so
			-- it's simply skipped rather than emitted as a token.
			advance()
		elseif c == "-" and char(1) == "-" then
			-- Line comment: "--" through to (but not including) the next
			-- newline, or end of input if there isn't one. The comment's
			-- text isn't kept (emitted as ""), since nothing downstream
			-- needs the comment's contents — only that a comment occupies
			-- this span, so it can be skipped when analyzing SQL structure.
			local start_row, start_col = row, col
			while char() and char() ~= "\n" do
				advance()
			end
			emit("comment", start_row, start_col, "")
		elseif c == "/" and char(1) == "*" then
			-- Block comment: "/* ... */", which (unlike the line comment
			-- above) can span multiple lines. Consume the opening "/*",
			-- then scan forward until the closing "*/" or end of input.
			local start_row, start_col = row, col
			advance()
			advance()
			-- Non-nested block comments are an accepted v1 simplification.
			while char() and not (char() == "*" and char(1) == "/") do
				advance()
			end
			if char() then
				-- Found a closing "*/": consume both of its characters.
				-- If we instead hit end of input (the `if char()` above is
				-- false), we simply stop, matching this module's
				-- never-error policy for unterminated constructs.
				advance()
				advance()
			end
			emit("comment", start_row, start_col, "")
		elseif c == '"' then
			-- Quoted identifier, e.g. "My Table". See scan_delimited above
			-- for the escaping rules.
			local start_row, start_col, text = scan_delimited('"')
			emit("quoted_identifier", start_row, start_col, text)
		elseif c == "'" then
			-- String literal, e.g. 'hello'. Same escaping rules as quoted
			-- identifiers, just with a different delimiter character.
			local start_row, start_col, text = scan_delimited("'")
			emit("string", start_row, start_col, text)
		elseif is_digit(c) then
			-- Numeric literal: one or more digits, optionally followed by a
			-- "." and more digits (a decimal point) — but only if that "."
			-- is actually followed by a digit. This distinguishes a decimal
			-- number like "1.5" from a plain integer "1" immediately
			-- followed by unrelated punctuation, such as the "." in
			-- "1.column" (which shouldn't be swallowed into the number).
			local start_row, start_col = row, col
			while is_digit(char()) do
				advance()
			end
			if char() == "." and is_digit(char(1)) then
				advance()
				while is_digit(char()) do
					advance()
				end
			end
			emit("number", start_row, start_col, "")
		elseif is_ident_start(c) then
			-- Identifier or keyword (e.g. `select`, `users`, `my_column`).
			-- The tokenizer doesn't try to distinguish keywords from plain
			-- identifiers here — everything that looks like a word is
			-- emitted as type "identifier", and it's left to downstream
			-- consumers (scope.lua/completion) to recognize specific
			-- keyword text if they care to.
			local start_row, start_col = row, col
			local text = {}
			while is_ident_char(char()) do
				table.insert(text, char())
				advance()
			end
			emit("identifier", start_row, start_col, table.concat(text))
		elseif c == ";" then
			-- Statement separator. Kept as its own token type (rather than
			-- falling into the generic "punct" bucket) because it's an
			-- important structural marker: it's how downstream code knows
			-- where one SQL statement ends and the next begins.
			local start_row, start_col = row, col
			advance()
			emit("semicolon", start_row, start_col, ";")
		elseif c == "(" then
			-- Opening paren: emit it, then increase the nesting `depth`
			-- counter that gets stamped onto every subsequently emitted
			-- token (see the `depth` comment near the top of this
			-- function), so consumers can tell they're inside e.g. a
			-- function call's argument list or a subquery.
			local start_row, start_col = row, col
			advance()
			depth = depth + 1
			emit("punct", start_row, start_col, "(")
		elseif c == ")" then
			-- Closing paren: decrease `depth` back down, clamped at 0 so
			-- an extra/unbalanced ")" in a mid-edit buffer can't drive the
			-- depth negative.
			local start_row, start_col = row, col
			advance()
			depth = math.max(depth - 1, 0)
			emit("punct", start_row, start_col, ")")
		else
			-- Fallback: any other single character (commas, operators like
			-- =, <, >, +, -, *, etc, and any character not otherwise
			-- recognized) becomes its own one-character "punct" token.
			local start_row, start_col = row, col
			advance()
			emit("punct", start_row, start_col, c)
		end
	end

	return tokens
end

-- Splits a possibly quoted, dot-separated identifier chain (either what the
-- user typed, or a connector's completion_word/qualified_name output) into
-- unquoted segments. The only place dot-splitting/unquoting logic lives.
--
-- This is a separate, standalone mini-scanner from M.tokenize above (not
-- built on top of it) because its job is different: M.tokenize breaks a
-- whole SQL buffer into many tokens of many types, while this function
-- takes one already-isolated identifier-chain string, such as
-- `"my schema".users` or `public.orders`, and just splits it on the dots
-- that separate schema/table/column parts — while still respecting the
-- same doubled-quote escaping rule, so a dot *inside* a quoted segment
-- (e.g. `"weird.name"`) isn't mistaken for a separator.
--
-- Params: text - the identifier chain string to split, e.g. `public.orders`
--   or `"My Schema"."My Table"`.
-- Returns: a Lua array of unquoted segment strings, e.g. { "public",
--   "orders" } or { "My Schema", "My Table" }. There is always at least one
--   segment (a chain with no dots returns a single-element array).
function M.split_qualified(text)
	local segments = {}
	local buffer = {}
	local i = 1
	local n = #text
	while i <= n do
		local c = text:sub(i, i)
		if c == '"' then
			-- Enter a quoted segment: consume characters verbatim
			-- (un-escaping doubled quotes back to one) until the closing
			-- quote, without treating '.' specially while inside it.
			i = i + 1
			while i <= n do
				local d = text:sub(i, i)
				if d == '"' then
					if text:sub(i + 1, i + 1) == '"' then
						-- Doubled quote inside the quoted segment: a
						-- literal '"' character in the name, not the end
						-- of the segment.
						table.insert(buffer, '"')
						i = i + 2
					else
						-- Single quote: closes this quoted segment.
						i = i + 1
						break
					end
				else
					table.insert(buffer, d)
					i = i + 1
				end
			end
		elseif c == "." then
			-- Unquoted dot: this is a real separator between chain
			-- segments (e.g. schema.table). Close off the current segment
			-- and start a new one.
			table.insert(segments, table.concat(buffer))
			buffer = {}
			i = i + 1
		else
			-- Ordinary character, just part of the current (unquoted)
			-- segment's text.
			table.insert(buffer, c)
			i = i + 1
		end
	end
	-- The loop above only closes a segment when it hits a '.'; the final
	-- segment (after the last dot, or the whole string if there were no
	-- dots) has no trailing dot to trigger that, so it's appended here.
	table.insert(segments, table.concat(buffer))
	return segments
end

return M
