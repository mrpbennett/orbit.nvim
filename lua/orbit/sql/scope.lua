-- Structural analysis of tokens produced by orbit.sql.tokenizer: which
-- statement the cursor sits in, which clause it's in, the qualifier being
-- typed, and the table/alias scope visible at that point. Pure functions of
-- tokens + cursor position; no schema-cache/connector/dialect knowledge.
local tokenizer = require("orbit.sql.tokenizer")

local M = {}

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

local FROM_START_WORDS = {
	FROM = true,
	INTO = true,
	UPDATE = true,
}

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

local function is_ident(tok)
	return tok ~= nil and (tok.type == "identifier" or tok.type == "quoted_identifier")
end

local function word(tok)
	return tokenizer.split_qualified(tok.text)[1]
end

local function upper(tok)
	return is_ident(tok) and word(tok):upper() or nil
end

local function before_cursor(tok, row, col)
	return tok.row < row or (tok.row == row and tok.end_col <= col)
end

-- Splits every semicolon-delimited statement, returning the tokens of
-- whichever one contains the cursor (or the trailing one if the cursor sits
-- past the last semicolon). Never refuses, unlike statements.lua's
-- ambiguity rule, which is an execution-safety concern, not a parsing one.
function M.statement_at(tokens, cursor_row, cursor_col)
	local groups, boundaries = {}, {}
	local current = {}
	for _, tok in ipairs(tokens) do
		if tok.type == "semicolon" then
			table.insert(groups, current)
			table.insert(boundaries, tok)
			current = {}
		elseif tok.type ~= "comment" then
			table.insert(current, tok)
		end
	end
	table.insert(groups, current)

	local chosen = groups[#groups]
	for i, boundary in ipairs(boundaries) do
		if before_cursor(boundary, cursor_row, cursor_col) then
			-- Cursor is past this terminator; keep looking at later groups.
		else
			chosen = groups[i]
			break
		end
	end

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

-- Walks backward from the cursor collecting a dotted identifier chain
-- (segments already typed, plus any in-progress partial word). Returns both
-- the unquoted segments (for structural comparisons) and the literal typed
-- text (for feeding connector.schema_of/completion_word unchanged).
local function extract_qualifier(tokens, cursor_index, touching)
	local idx = cursor_index
	local partial = ""

	if touching and is_ident(tokens[idx]) then
		partial = word(tokens[idx])
		idx = idx - 1
	end

	local segments, raw_segments = {}, {}
	while tokens[idx] and tokens[idx].type == "punct" and tokens[idx].text == "." and is_ident(tokens[idx - 1]) do
		table.insert(segments, 1, word(tokens[idx - 1]))
		table.insert(raw_segments, 1, tokens[idx - 1].text)
		idx = idx - 2
	end

	local raw = table.concat(raw_segments, ".")
	if #raw_segments > 0 then
		raw = raw .. "."
	end

	return { segments = segments, partial = partial, raw = raw }
end

local function enclosing_open_paren(tokens, from_index)
	local balance = 0
	for k = from_index, 1, -1 do
		local tok = tokens[k]
		if tok.type == "punct" and tok.text == ")" then
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
local function is_insert_columns_paren(tokens, open_index)
	local k = open_index - 1
	if not is_ident(tokens[k]) then
		return false
	end
	k = k - 1
	while tokens[k] and tokens[k].type == "punct" and tokens[k].text == "." and is_ident(tokens[k - 1]) do
		k = k - 2
	end
	return tokens[k] and upper(tokens[k]) == "INTO" and tokens[k - 1] and upper(tokens[k - 1]) == "INSERT"
end

local function classify_clause(tokens, cursor_index)
	local cursor_depth = cursor_index > 0 and tokens[cursor_index].depth or 0

	if cursor_index > 0 and cursor_depth > 0 then
		local open_index = enclosing_open_paren(tokens, cursor_index)
		if open_index and is_insert_columns_paren(tokens, open_index) then
			return "insert_columns", cursor_depth
		end
	end

	local depth = cursor_depth
	for k = cursor_index, 1, -1 do
		local tok = tokens[k]
		if tok.depth < depth then
			depth = tok.depth
		elseif tok.depth == depth and is_ident(tok) then
			local mapped = CLAUSE_KEYWORDS[upper(tok)]
			if mapped then
				return mapped, depth
			end
		end
	end
	return "unknown", cursor_depth
end

-- Skips a JOIN's "ON <condition>" so its tokens aren't re-parsed as more
-- table entries; stops at the next comma/join keyword/region stop word.
local function skip_on_condition(tokens, from_index, j)
	local k = from_index
	local balance = 0
	while k <= j do
		local tok = tokens[k]
		if tok.type == "punct" and tok.text == "(" then
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
local function parse_from_list(tokens, i, j, cte_names)
	local entries = {}
	local k = i
	while k <= j do
		local tok = tokens[k]
		if tok.type == "identifier" and JOIN_NOISE_WORDS[upper(tok)] then
			k = k + 1
		elseif tok.type == "punct" and tok.text == "," then
			k = k + 1
		elseif tok.type == "punct" and tok.text == "(" then
			-- Find the matching close by forward paren balance (enclosing_open_paren
			-- only scans backward, which isn't what we need here).
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
			if tokens[after] and (upper(tokens[after]) == "ON" or upper(tokens[after]) == "USING") then
				after = skip_on_condition(tokens, after + 1, j)
			end
			k = after
		elseif is_ident(tok) then
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

			local name = parts[#parts]
			local schema = parts[#parts - 1]
			local catalog = parts[#parts - 2]
			local kind = "table"
			if not schema and cte_names[name:upper()] then
				kind = "cte"
			end
			table.insert(entries, { name = name, schema = schema, catalog = catalog, alias = alias, kind = kind })
			if tokens[after] and (upper(tokens[after]) == "ON" or upper(tokens[after]) == "USING") then
				after = skip_on_condition(tokens, after + 1, j)
			end
			k = after
		else
			k = k + 1
		end
	end
	return entries
end

-- Finds every FROM-family keyword at exactly `depth` within [from_i, to_j]
-- and parses the region up to its next same-depth stop word.
local function resolve_alias_scope(tokens, from_i, to_j, depth, cte_names)
	local entries = {}
	local k = from_i
	while k <= to_j do
		local tok = tokens[k]
		if tok.depth == depth and is_ident(tok) and FROM_START_WORDS[upper(tok)] then
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
local function scan_ctes(tokens)
	local cte_names = {}
	if not (is_ident(tokens[1]) and upper(tokens[1]) == "WITH") then
		return cte_names, 1
	end
	local k = 2
	while true do
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
		if tokens[k] and tokens[k].type == "punct" and tokens[k].text == "," then
			k = k + 1
		else
			break
		end
	end
	return cte_names, k
end

function M.analyze(statement_tokens, cursor_index, touching)
	local cte_names, body_start = scan_ctes(statement_tokens)
	local qualifier = extract_qualifier(statement_tokens, cursor_index, touching)
	local clause, clause_depth = classify_clause(statement_tokens, cursor_index)

	local alias_scope = resolve_alias_scope(statement_tokens, body_start, #statement_tokens, 0, cte_names)
	if clause_depth and clause_depth ~= 0 then
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
