-- Structural analysis of tokens produced by orbit.sql.tokenizer: which
-- statement the cursor sits in, which clause it's in, the qualifier being
-- typed, and the table/alias scope visible at that point. Pure functions of
-- tokens + cursor position; no schema-cache/connector/dialect knowledge.
--
-- WHAT "SCOPE" MEANS HERE (for readers new to SQL-aware completion):
-- When a user is typing a SQL statement and the completion engine is asked
-- "what can go here?", the answer depends on *where* "here" is:
--   - Which SQL clause is the cursor inside? (SELECT list, FROM/JOIN list,
--     WHERE, ON, GROUP BY, ORDER BY, an INSERT column list, a SET clause...)
--     This module calls this the "clause".
--   - If the cursor is right after `some_alias.`, which table/alias is
--     `some_alias` referring to? This module calls this the "qualifier".
--   - Which tables, derived subqueries, and CTEs (Common Table Expressions,
--     i.e. `WITH name AS (...)` blocks used as temporary named result sets)
--     are visible from the cursor's position, and what aliases do they have?
--     This module calls this the "alias_scope".
-- Figuring out these three things — clause, qualifier, and alias_scope — is
-- what "scope" refers to throughout this file. orbit/completion.lua (the
-- module that actually builds completion candidates) calls M.statement_at
-- and M.analyze to get this information, then decides what to suggest
-- (table names, column names, aliases, etc.) based on the result.
--
-- This module never talks to a database connection, schema cache, or SQL
-- dialect connector — it only looks at the token stream and cursor
-- position. That keeps it easy to reason about and test in isolation.
local tokenizer = require("orbit.sql.tokenizer")

local M = {}

-- Maps a leading keyword (found while scanning backward from the cursor, see
-- classify_clause below) to the name of the SQL clause it introduces. The
-- keyword itself must be at the same paren-nesting "depth" as the cursor for
-- the match to count — see `depth` on tokens, produced by the tokenizer.
-- Several distinct keywords collapse to the same clause name because, for
-- completion purposes, they need the same kind of suggestions: e.g. FROM,
-- JOIN, INTO, and UPDATE all introduce "a table name goes here" positions,
-- so they all map to "from_family".
local CLAUSE_KEYWORDS = {
	SELECT = "select_list",
	FROM = "from_family",
	JOIN = "from_family",
	INTO = "from_family",
	UPDATE = "from_family",
	WHERE = "where",
	ON = "on",
	GROUP = "group_by",
	ORDER = "order_by",
	SET = "update_set",
}

-- Keywords that begin a "FROM-family" region: the part of a statement where
-- a list of tables (with optional JOINs, aliases, etc.) is expected. Used by
-- resolve_alias_scope to find where such a region starts.
local FROM_START_WORDS = {
	FROM = true,
	INTO = true,
	UPDATE = true,
}

-- Keywords that decorate a JOIN (or introduce one) without themselves being
-- a table/alias. These are skipped over rather than parsed as identifiers
-- when walking a FROM-family region, and they also mark "this isn't part of
-- the previous table's alias" and "this ends an ON condition".
local JOIN_NOISE_WORDS = {
	JOIN = true,
	INNER = true,
	LEFT = true,
	RIGHT = true,
	FULL = true,
	CROSS = true,
	OUTER = true,
	NATURAL = true,
}

-- Keywords that end a statement's clause region without introducing a new
-- one this module knows how to offer completions for (LIMIT/OFFSET/FETCH's
-- row count, HAVING's aggregate filter, or a UNION/INTERSECT/EXCEPT
-- boundary between SELECTs). Without this, classify_clause's backward scan
-- (below) would skip straight past one of these and match an earlier,
-- no-longer-relevant clause keyword instead -- e.g. a cursor sitting right
-- after `LIMIT 10` would otherwise still resolve to that same statement's
-- `FROM` clause, offering table names in a position where nothing should be
-- suggested at all.
local CLAUSE_TERMINATORS = {
	LIMIT = true,
	OFFSET = true,
	FETCH = true,
	HAVING = true,
	UNION = true,
	INTERSECT = true,
	EXCEPT = true,
}

-- Keywords that can never legally be a table alias. Without this list, code
-- that guesses "the next bare identifier after a table name is its alias"
-- (no AS keyword) would wrongly swallow the start of the next clause, e.g.
-- treating the WHERE in `FROM orders WHERE ...` as if it were an alias for
-- `orders`.
local ALIAS_STOP_WORDS = {
	ON = true,
	USING = true,
	WHERE = true,
	GROUP = true,
	ORDER = true,
	SET = true,
	VALUES = true,
	WHEN = true,
	UNION = true,
	INTERSECT = true,
	EXCEPT = true,
	LIMIT = true,
	HAVING = true,
	["FOR"] = true,
	JOIN = true,
	INNER = true,
	LEFT = true,
	RIGHT = true,
	FULL = true,
	CROSS = true,
	OUTER = true,
	NATURAL = true,
}

-- Keywords that end a FROM-family region (i.e. the table list is over and a
-- different clause has begun). Used both by resolve_alias_scope to know when
-- to stop consuming tokens as "more tables", and by skip_on_condition to know
-- when an ON/USING condition has run out even without hitting a comma or
-- another JOIN.
local FROM_REGION_STOP_WORDS = {
	WHERE = true,
	GROUP = true,
	ORDER = true,
	SET = true,
	VALUES = true,
	UNION = true,
	INTERSECT = true,
	EXCEPT = true,
	LIMIT = true,
	HAVING = true,
}

-- True for any token that can act as a name: a bare identifier (`orders`) or
-- a double-quoted identifier (`"Orders"`). Used everywhere below instead of
-- checking `tok.type == "identifier"` directly, since quoted identifiers
-- must be treated the same way syntactically (they can be table names,
-- aliases, column names, keywords typed in a weird case via quoting, etc.).
local function is_ident(tok)
	return tok ~= nil and (tok.type == "identifier" or tok.type == "quoted_identifier")
end

-- Returns a token's textual name with quoting removed, e.g. the token for
-- `"My Table"` becomes `My Table`. tokenizer.split_qualified is reused here
-- purely for its unquoting behavior; taking [1] discards the dot-splitting
-- part since a single token is never itself a dotted chain.
local function word(tok)
	return tokenizer.split_qualified(tok.text)[1]
end

-- Returns a token's name upper-cased, for case-insensitive keyword
-- comparisons (SQL keywords like FROM/from/From are all equivalent). Returns
-- nil for non-identifier tokens so callers can use it directly as a table
-- key lookup (e.g. `CLAUSE_KEYWORDS[upper(tok)]`) without a separate
-- is_ident guard.
local function upper(tok)
	return is_ident(tok) and word(tok):upper() or nil
end

-- True if `tok` ends at or before the given cursor position. Tokens compare
-- by row first, then by end_col on the same row. This is the basic building
-- block for "walk backward from the cursor" logic throughout this file:
-- anything not before_cursor is either under the cursor or further ahead in
-- the buffer, and should not be treated as "already typed".
local function before_cursor(tok, row, col)
	return tok.row < row or (tok.row == row and tok.end_col <= col)
end

-- Splits every semicolon-delimited statement, returning the tokens of
-- whichever one contains the cursor (or the trailing one if the cursor sits
-- past the last semicolon). Never refuses, unlike statements.lua's
-- ambiguity rule, which is an execution-safety concern, not a parsing one.
--
-- Params:
--   tokens      - the full token list for the buffer, from tokenizer.tokenize.
--   cursor_row  - 1-indexed line number of the cursor (matches token.row).
--   cursor_col  - 0-indexed byte column of the cursor (matches token.end_col).
-- Returns three values:
--   chosen       - the list of tokens belonging to the statement the cursor
--                  is inside (comments and semicolons stripped out).
--   cursor_index - the index into `chosen` of the last token that is fully
--                  before the cursor (0 if the cursor is before every token
--                  in the statement, i.e. nothing has been typed yet).
--   touching     - true if the cursor sits exactly at the end of
--                  chosen[cursor_index] (no whitespace between them), which
--                  matters for deciding whether that last token is a
--                  finished word or a word still being typed (see
--                  extract_qualifier below).
function M.statement_at(tokens, cursor_row, cursor_col)
	-- First pass: break the whole buffer's tokens into one group per
	-- semicolon-delimited statement. `boundaries` remembers the semicolon
	-- token that ended each group (except the last, trailing group, which
	-- has no closing semicolon yet).
	local groups, boundaries = {}, {}
	local current = {}
	for _, tok in ipairs(tokens) do
		if tok.type == "semicolon" then
			table.insert(groups, current)
			table.insert(boundaries, tok)
			current = {}
		elseif tok.type ~= "comment" then
			-- Comments are dropped entirely; they never affect clause/scope
			-- analysis and would only get in the way of the token-walking
			-- logic elsewhere in this file.
			table.insert(current, tok)
		end
	end
	table.insert(groups, current)

	-- Second pass: find which group the cursor is inside by walking the
	-- semicolon boundaries in order. Default to the last (trailing) group,
	-- which covers "cursor is after the final semicolon" and "there are no
	-- semicolons at all".
	local chosen = groups[#groups]
	for i, boundary in ipairs(boundaries) do
		if before_cursor(boundary, cursor_row, cursor_col) then
			-- Cursor is past this terminator; keep looking at later groups.
		else
			chosen = groups[i]
			break
		end
	end

	-- Within the chosen statement, find the last token before the cursor.
	-- Tokens are in source order, so as soon as we hit one that is NOT
	-- before the cursor, everything after it is irrelevant and we stop.
	local cursor_index = 0
	local touching = false
	for i, tok in ipairs(chosen) do
		if before_cursor(tok, cursor_row, cursor_col) then
			cursor_index = i
			touching = tok.row == cursor_row and tok.end_col == cursor_col
		else
			break
		end
	end

	return chosen, cursor_index, touching
end

-- Figures out what "qualifier" the user has typed just before the cursor,
-- e.g. for `SELECT u.na|` (cursor at `|`) the qualifier is `u.` with partial
-- word `na`; for `SELECT o.customer_id.| ` it would walk back the whole
-- dotted chain `o.customer_id.`. This is what lets completion.lua know
-- "the user is asking for columns of alias `u`" rather than "table names".
--
-- Params:
--   tokens       - the statement's tokens (as returned by M.statement_at).
--   cursor_index - index of the last token before the cursor (0 if none).
--   touching     - whether the cursor sits directly against that token with
--                  no gap, meaning it's a word still being typed rather than
--                  a finished, separate token.
-- Returns a table with:
--   segments - unquoted names of each completed qualifier part, e.g.
--              { "o", "customer" } for `o.customer.`. Used for structural
--              comparisons (matching against alias names, schema names...).
--   partial  - the in-progress word after the last dot, unquoted, e.g. "na"
--              for `u.na|`. Empty string if the cursor isn't touching a
--              partial word (e.g. right after a dot, or with a space before
--              the cursor).
--   raw      - the literal typed text of the completed segments including
--              their original quoting and trailing dot (e.g. `o.customer.`
--              or `"My Alias".`), for passing through unchanged to a
--              connector's schema_of/completion_word functions, which need
--              the dialect's real quoting rather than a normalized form.
local function extract_qualifier(tokens, cursor_index, touching)
	local idx = cursor_index
	local partial = ""

	-- If the cursor is glued to the last token and that token is an
	-- identifier, it's an in-progress word (the "na" in "u.na|"), not a
	-- finished qualifier segment. Consume it as `partial` and step back one
	-- token before looking for dotted segments.
	if touching and is_ident(tokens[idx]) then
		partial = word(tokens[idx])
		idx = idx - 1
	end

	-- Walk backward consuming `identifier "." identifier "." ...` pairs.
	-- Each iteration consumes one dot and the identifier before it, and
	-- segments are inserted at position 1 so the final list is in the
	-- original left-to-right order (since we're walking right-to-left).
	local segments, raw_segments = {}, {}
	while tokens[idx] and tokens[idx].type == "punct" and tokens[idx].text == "." and is_ident(tokens[idx - 1]) do
		table.insert(segments, 1, word(tokens[idx - 1]))
		table.insert(raw_segments, 1, tokens[idx - 1].text)
		idx = idx - 2
	end

	local raw = table.concat(raw_segments, ".")
	if #raw_segments > 0 then
		-- Re-append the trailing dot that table.concat's separator doesn't
		-- add after the last segment, so callers get e.g. "o." not "o".
		raw = raw .. "."
	end

	return { segments = segments, partial = partial, raw = raw }
end

-- Walks backward from `from_index` to find the "(" that directly encloses
-- it, using a running balance of ")" seen vs "(" seen (standard bracket
-- matching, done backward). Returns the index of that "(" token, or nil if
-- `from_index` isn't actually inside any parens (shouldn't normally happen
-- when called with a token whose own `depth` is > 0, since depth already
-- tracks paren nesting from the tokenizer).
local function enclosing_open_paren(tokens, from_index)
	local balance = 0
	for k = from_index, 1, -1 do
		local tok = tokens[k]
		if tok.type == "punct" and tok.text == ")" then
			-- A ")" seen while scanning backward means we've entered a
			-- *nested* pair that closes before reaching from_index; note it
			-- so its matching "(" doesn't get mistaken for our enclosing one.
			balance = balance + 1
		elseif tok.type == "punct" and tok.text == "(" then
			if balance == 0 then
				return k
			end
			balance = balance - 1
		end
	end
	return nil
end

-- "(" opens an INSERT INTO t (...) column list when it's immediately
-- preceded by a (possibly dotted) table name, then INTO, then INSERT.
-- This distinguishes `INSERT INTO orders (id, total) VALUES (...)`'s first
-- parenthesized group (a column list — offer column-name completions) from
-- any other parenthesized construct (subquery, function call, etc.).
local function is_insert_columns_paren(tokens, open_index)
	local k = open_index - 1
	if not is_ident(tokens[k]) then
		return false
	end
	k = k - 1
	-- Skip back over the rest of a dotted table name, e.g. `schema.orders`.
	while tokens[k] and tokens[k].type == "punct" and tokens[k].text == "." and is_ident(tokens[k - 1]) do
		k = k - 2
	end
	return tokens[k] and upper(tokens[k]) == "INTO" and tokens[k - 1] and upper(tokens[k - 1]) == "INSERT"
end

-- Determines which SQL clause the cursor is currently inside, e.g.
-- "select_list", "from_family", "where", "insert_columns", etc. (see
-- CLAUSE_KEYWORDS for the full mapping, plus the "insert_columns" special
-- case handled directly in this function).
--
-- Params:
--   tokens       - the statement's tokens.
--   cursor_index - index of the last token before the cursor (0 if none).
-- Returns two values:
--   clause_name  - one of the CLAUSE_KEYWORDS values, "insert_columns", or
--                  "unknown" if no recognizable clause keyword was found
--                  (e.g. the cursor is before any keyword at all).
--   depth        - the paren-nesting depth the clause keyword (or the
--                  cursor itself, for "insert_columns"/"unknown") was found
--                  at. Callers use this to know which nesting level of the
--                  statement the cursor's clause belongs to, since a
--                  subquery has its own independent SELECT/FROM/WHERE at a
--                  deeper depth.
local function classify_clause(tokens, cursor_index)
	local cursor_depth = cursor_index > 0 and tokens[cursor_index].depth or 0

	-- Special case: if the cursor is inside parens, check whether those
	-- parens are specifically an INSERT's column list, which isn't
	-- introduced by any of the CLAUSE_KEYWORDS keywords and needs its own
	-- detection via is_insert_columns_paren.
	if cursor_index > 0 and cursor_depth > 0 then
		local open_index = enclosing_open_paren(tokens, cursor_index)
		if open_index and is_insert_columns_paren(tokens, open_index) then
			return "insert_columns", cursor_depth
		end
	end

	-- General case: scan backward from the cursor looking for the nearest
	-- clause keyword that sits at the SAME paren depth as the cursor. When a
	-- token with a *smaller* depth is encountered, the cursor's enclosing
	-- parenthesized group has been exited (e.g. stepped out of a subquery),
	-- so `depth` is lowered to match and the search continues one level up —
	-- this is what makes a cursor inside `(SELECT ... FROM inner)` resolve
	-- against the inner statement's own clauses rather than the outer one's.
	local depth = cursor_depth
	for k = cursor_index, 1, -1 do
		local tok = tokens[k]
		if tok.depth < depth then
			depth = tok.depth
		elseif tok.depth == depth and is_ident(tok) then
			local word_upper = upper(tok)
			if CLAUSE_TERMINATORS[word_upper] then
				-- The cursor is past this clause's terminator (e.g. after
				-- `LIMIT 10`): stop here rather than matching an earlier
				-- clause keyword that no longer applies to the cursor.
				return "unknown", depth
			end
			local mapped = CLAUSE_KEYWORDS[word_upper]
			if mapped then
				return mapped, depth
			end
		end
	end
	return "unknown", cursor_depth
end

-- Skips a JOIN's "ON <condition>" so its tokens aren't re-parsed as more
-- table entries; stops at the next comma/join keyword/region stop word.
-- e.g. for `FROM a JOIN b ON a.id = b.a_id JOIN c ON ...`, after parsing
-- table `b`'s ON condition this returns the index of the next `JOIN`
-- keyword, so parse_from_list can continue on to table `c` without
-- mistaking `a.id = b.a_id` for more table entries.
--
-- Params:
--   tokens     - the statement's tokens.
--   from_index - index of the first token of the condition (just after ON).
--   j          - the last index this function is allowed to look at (the
--                end of the enclosing FROM-family region).
-- Returns the index of the first token AFTER the condition (i.e. where the
-- caller should resume parsing).
local function skip_on_condition(tokens, from_index, j)
	local k = from_index
	local balance = 0
	while k <= j do
		local tok = tokens[k]
		if tok.type == "punct" and tok.text == "(" then
			-- Parens inside the condition (e.g. `ON (a.x = b.y)` or a
			-- function call) must not let a comma or keyword *inside* them
			-- be mistaken for the end of the condition.
			balance = balance + 1
		elseif tok.type == "punct" and tok.text == ")" then
			if balance == 0 then
				break
			end
			balance = balance - 1
		elseif balance == 0 then
			if tok.type == "punct" and tok.text == "," then
				break
			end
			if is_ident(tok) then
				local u = upper(tok)
				if JOIN_NOISE_WORDS[u] or FROM_REGION_STOP_WORDS[u] then
					break
				end
			end
		end
		k = k + 1
	end
	return k
end

-- Parses tokens[i..j] (one FROM-family region at `depth`) into alias-scope
-- entries: comma-joins split into separate entries, derived tables/CTEs
-- captured with only their alias (contents skipped as a unit).
--
-- This is the heart of "figure out which tables/aliases are visible here".
-- Given something like `FROM orders o JOIN customers AS c ON o.customer_id
-- = c.id`, this returns entries describing both `orders` (aliased `o`) and
-- `customers` (aliased `c`).
--
-- Params:
--   tokens    - the statement's tokens.
--   i, j      - inclusive start/end indices of the region to parse (one
--               FROM-family region, e.g. everything between FROM and the
--               next WHERE/GROUP BY/etc., at a single paren depth).
--   cte_names - a set (map of NAME -> true) of CTE names defined by a
--               leading WITH clause (see scan_ctes), used to tell a real
--               table apart from a reference to a CTE with the same kind of
--               bare name.
-- Returns a list of entries, each one of:
--   { kind = "table", name = ..., schema = ..., catalog = ..., alias = ... }
--     A real (or CTE) table reference. `schema`/`catalog` are nil unless
--     the name was written dotted, e.g. `myschema.orders`.
--   { kind = "cte", name = ..., alias = ... }
--     Same shape as "table" but recognized as referring to a CTE name
--     instead of a database table (so completion.lua knows not to look it
--     up in the schema cache the same way).
--   { kind = "derived", alias = ... }
--     A parenthesized derived table / inline subquery used as a FROM
--     source, e.g. `FROM (SELECT ...) sub`. Its *contents* are not parsed
--     here (whatever tables that subquery reads from are out of scope for
--     the outer statement) — only its alias is kept, since that's the name
--     other parts of the outer statement can qualify columns with.
local function parse_from_list(tokens, i, j, cte_names)
	local entries = {}
	local k = i
	while k <= j do
		local tok = tokens[k]
		if tok.type == "identifier" and JOIN_NOISE_WORDS[upper(tok)] then
			-- Skip bare JOIN-decorating words (JOIN, LEFT, INNER, ...); the
			-- actual table name that follows is handled by a later branch.
			k = k + 1
		elseif tok.type == "punct" and tok.text == "," then
			-- Comma-separated FROM list (old-style implicit join syntax);
			-- just move past the comma to the next table reference.
			k = k + 1
		elseif tok.type == "punct" and tok.text == "(" then
			-- A derived table / subquery used as a FROM source, e.g.
			-- `FROM (SELECT id FROM orders) sub`. Find its matching ")" by
			-- counting nested parens forward (enclosing_open_paren only
			-- scans backward, which is the wrong direction for this case).
			local balance = 0
			local m = k
			while m <= j do
				if tokens[m].type == "punct" and tokens[m].text == "(" then
					balance = balance + 1
				elseif tokens[m].type == "punct" and tokens[m].text == ")" then
					balance = balance - 1
					if balance == 0 then
						break
					end
				end
				m = m + 1
			end
			-- Everything inside the parens is intentionally NOT recursed
			-- into; only what comes right after the closing ")" — an
			-- optional AS, then the alias — is relevant to the outer
			-- statement's scope.
			local after = m + 1
			if tokens[after] and upper(tokens[after]) == "AS" then
				after = after + 1
			end
			local alias = nil
			if is_ident(tokens[after]) and not ALIAS_STOP_WORDS[upper(tokens[after]) or ""] then
				alias = word(tokens[after])
				after = after + 1
			end
			table.insert(entries, { kind = "derived", alias = alias })
			-- The derived table may itself be JOINed with an ON/USING
			-- condition, e.g. `... JOIN (SELECT ...) sub ON sub.id = o.id`;
			-- skip that condition so it isn't misread as another table.
			if tokens[after] and (upper(tokens[after]) == "ON" or upper(tokens[after]) == "USING") then
				after = skip_on_condition(tokens, after + 1, j)
			end
			k = after
		elseif is_ident(tok) then
			-- An ordinary (possibly dotted) table/CTE reference, e.g.
			-- `catalog.schema.orders` or just `orders`. Collect every
			-- dot-joined identifier part first.
			local parts = { word(tok) }
			local m = k + 1
			while
				tokens[m]
				and tokens[m].type == "punct"
				and tokens[m].text == "."
				and is_ident(tokens[m + 1])
			do
				table.insert(parts, word(tokens[m + 1]))
				m = m + 2
			end

			-- After the name, look for an alias: either explicit (`AS
			-- alias`) or implicit (a bare identifier immediately following,
			-- as long as it isn't actually the start of the next clause —
			-- see ALIAS_STOP_WORDS). `AS` with nothing usable after it
			-- (e.g. cursor sitting right after AS while still typing) is
			-- tolerated: alias just stays nil.
			local after = m
			local alias = nil
			if tokens[after] and upper(tokens[after]) == "AS" then
				after = after + 1
				if is_ident(tokens[after]) then
					alias = word(tokens[after])
					after = after + 1
				end
			elseif is_ident(tokens[after]) and not ALIAS_STOP_WORDS[upper(tokens[after]) or ""] then
				alias = word(tokens[after])
				after = after + 1
			end

			-- Dotted parts are read right-to-left: the last part is always
			-- the table name itself, the one before it (if any) is the
			-- schema, and the one before that is the catalog/database.
			local name = parts[#parts]
			local schema = parts[#parts - 1]
			local catalog = parts[#parts - 2]
			local kind = "table"
			-- A bare (unschema-qualified) name that matches one of the
			-- statement's own CTE definitions refers to that CTE, not to a
			-- real database table — completion.lua must not try to look up
			-- CTE columns in the schema cache.
			if not schema and cte_names[name:upper()] then
				kind = "cte"
			end
			table.insert(entries, { name = name, schema = schema, catalog = catalog, alias = alias, kind = kind })
			-- As with derived tables, an ON/USING condition after this
			-- table reference belongs to the JOIN, not to another table.
			if tokens[after] and (upper(tokens[after]) == "ON" or upper(tokens[after]) == "USING") then
				after = skip_on_condition(tokens, after + 1, j)
			end
			k = after
		else
			-- Anything else (stray punctuation, etc.) is skipped; it isn't
			-- expected to appear here but shouldn't stall the loop.
			k = k + 1
		end
	end
	return entries
end

-- Finds every FROM-family keyword at exactly `depth` within [from_i, to_j]
-- and parses the region up to its next same-depth stop word.
--
-- A statement can have more than one FROM-family region at the same depth
-- (e.g. an UPDATE with a FROM clause, or a statement containing a UNION
-- where both sides have their own FROM), so this scans the whole range
-- rather than stopping after the first FROM/INTO/UPDATE keyword found.
--
-- Params:
--   tokens    - the statement's tokens.
--   from_i, to_j - inclusive range to search within.
--   depth     - only keywords/regions at this exact paren depth count; this
--               is what keeps a subquery's FROM from being treated as part
--               of the outer statement's table list.
--   cte_names - passed through to parse_from_list.
-- Returns a flat list of alias-scope entries (same shape as
-- parse_from_list's return value) gathered from every matching region.
local function resolve_alias_scope(tokens, from_i, to_j, depth, cte_names)
	local entries = {}
	local k = from_i
	while k <= to_j do
		local tok = tokens[k]
		if tok.depth == depth and is_ident(tok) and FROM_START_WORDS[upper(tok)] then
			-- Found a FROM/INTO/UPDATE keyword at the target depth; the
			-- region to parse starts right after it and runs until either a
			-- same-depth stop word (WHERE, GROUP BY, ...) or a drop in
			-- depth (meaning we've exited the enclosing parens entirely).
			local region_start = k + 1
			local m = region_start
			while m <= to_j do
				local candidate = tokens[m]
				if candidate.depth == depth and is_ident(candidate) and FROM_REGION_STOP_WORDS[upper(candidate)] then
					break
				end
				if candidate.depth < depth then
					break
				end
				m = m + 1
			end
			for _, entry in ipairs(parse_from_list(tokens, region_start, m - 1, cte_names)) do
				table.insert(entries, entry)
			end
			k = m
		else
			k = k + 1
		end
	end
	return entries
end

-- Skips a leading `WITH name AS (...) [, name2 AS (...)]` block, returning
-- the set of CTE names and the index the real statement body starts at.
--
-- A CTE ("Common Table Expression") is a temporary, named result set
-- defined at the top of a statement with `WITH name AS (subquery)`, which
-- can then be referred to by name later in the statement as if it were a
-- table, e.g. `WITH recent AS (SELECT ...) SELECT * FROM recent`. This
-- function's job is just to recognize and skip over the WITH block itself
-- (its subquery bodies are not analyzed — a CTE's own internal FROM clause
-- is its own separate scope), while recording every name it defines so
-- later code (parse_from_list) can tell "this is a reference to a CTE" apart
-- from "this is a reference to a real database table".
--
-- Params:
--   tokens - the statement's tokens.
-- Returns two values:
--   cte_names  - a set (map of NAME -> true, upper-cased) of every CTE name
--                defined by the WITH block. Empty if the statement doesn't
--                start with WITH.
--   body_start - the index of the first token after the WITH block (i.e.
--                where the "real" statement, such as the SELECT/UPDATE/
--                INSERT, begins). Equals 1 if there is no WITH block.
local function scan_ctes(tokens)
	local cte_names = {}
	if not (is_ident(tokens[1]) and upper(tokens[1]) == "WITH") then
		return cte_names, 1
	end
	local k = 2
	while true do
		-- Expect a CTE name here; if there isn't one, the WITH block is
		-- malformed/still being typed, so stop and treat what we've found
		-- so far as complete.
		if not is_ident(tokens[k]) then
			break
		end
		cte_names[upper(tokens[k])] = true
		k = k + 1
		if is_ident(tokens[k]) and upper(tokens[k]) == "AS" then
			k = k + 1
		end
		if not (tokens[k] and tokens[k].type == "punct" and tokens[k].text == "(") then
			break
		end
		-- Skip the whole `(...)` subquery body by paren balance, without
		-- looking at what's inside — a CTE's own FROM/WHERE/etc. belong to
		-- that CTE's own scope, not the outer statement's.
		local balance = 0
		while tokens[k] do
			if tokens[k].type == "punct" and tokens[k].text == "(" then
				balance = balance + 1
			elseif tokens[k].type == "punct" and tokens[k].text == ")" then
				balance = balance - 1
				if balance == 0 then
					k = k + 1
					break
				end
			end
			k = k + 1
		end
		-- A comma means another `name AS (...)` CTE follows; anything else
		-- (e.g. the real statement's leading keyword) ends the WITH block.
		if tokens[k] and tokens[k].type == "punct" and tokens[k].text == "," then
			k = k + 1
		else
			break
		end
	end
	return cte_names, k
end

-- The main entry point for this module (alongside M.statement_at): given the
-- tokens of a single statement and the cursor's position within it (as
-- returned by M.statement_at), works out everything orbit/completion.lua
-- needs to decide what to suggest: which clause the cursor is in, what
-- qualifier text has been typed, and which tables/aliases/CTEs are visible.
--
-- Params:
--   statement_tokens - tokens of one statement (from M.statement_at).
--   cursor_index      - index of the last token before the cursor, within
--                        statement_tokens (from M.statement_at).
--   touching          - whether the cursor is glued to that token (from
--                        M.statement_at).
-- Returns a table with:
--   clause      - the clause name from classify_clause (e.g. "select_list",
--                 "from_family", "where", "insert_columns", "unknown").
--   qualifier   - the qualifier table from extract_qualifier
--                 ({ segments, partial, raw }).
--   alias_scope - the list of visible table/CTE/derived-table entries, as
--                 produced by resolve_alias_scope / parse_from_list.
function M.analyze(statement_tokens, cursor_index, touching)
	local cte_names, body_start = scan_ctes(statement_tokens)
	local qualifier = extract_qualifier(statement_tokens, cursor_index, touching)
	local clause, clause_depth = classify_clause(statement_tokens, cursor_index)

	-- Always resolve the outermost (depth 0) FROM-family tables — those are
	-- visible everywhere in the statement (e.g. from inside a subquery's
	-- WHERE clause, an outer table can still be referenced — this is what
	-- SQL calls a "correlated subquery").
	local alias_scope = resolve_alias_scope(statement_tokens, body_start, #statement_tokens, 0, cte_names)
	if clause_depth and clause_depth ~= 0 then
		-- The cursor is inside a nested subquery (clause_depth > 0): also
		-- resolve that subquery's OWN FROM-family tables at its depth, and
		-- put them first in the list. Order matters to callers like
		-- find_scope_entry in completion.lua, which take the first
		-- matching alias — so if an inner table's alias happens to shadow
		-- an outer one, the inner (more locally relevant) table wins.
		local inner = resolve_alias_scope(statement_tokens, body_start, #statement_tokens, clause_depth, cte_names)
		local merged = {}
		for _, entry in ipairs(inner) do
			table.insert(merged, entry)
		end
		for _, entry in ipairs(alias_scope) do
			table.insert(merged, entry)
		end
		alias_scope = merged
	end

	return { clause = clause, qualifier = qualifier, alias_scope = alias_scope }
end

return M
