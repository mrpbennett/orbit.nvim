-- ============================================================================
-- SQL Structure model
-- ============================================================================
-- Converts query-buffer lines into source-ordered statement trees for the
-- Structure panel. This module is pure: it knows SQL tokens and source ranges,
-- but nothing about Neovim windows, rendering, mappings, or expansion state.
--
-- Every node has a stable source-derived ID, a display label, an end-exclusive
-- source range, and zero or more children. Query blocks expose their major SQL
-- clauses and recursively bounded parenthesized SELECT/WITH blocks. WITH
-- statements also add CTE declarations, body-query branches, and an outer query.
-- Malformed/incomplete WITH syntax falls back to a navigable statement root
-- rather than exposing a partially trusted hierarchy or raising an error.
-- ============================================================================
local tokenizer = require("orbit.sql.tokenizer")

local M = {}

local categories = {
	ALTER = "DDL",
	CREATE = "DDL",
	DROP = "DDL",
	TRUNCATE = "DDL",
	DELETE = "DML",
	INSERT = "DML",
	MERGE = "DML",
	REPLACE = "DML",
	UPDATE = "DML",
	SELECT = "SELECT",
}

-- Remove comments and statement terminators when grammar decisions need only
-- meaningful SQL tokens. Original tokens remain available for label building.
local function significant(tokens)
	local result = {}
	for _, token in ipairs(tokens) do
		if token.type ~= "comment" and token.type ~= "semicolon" then
			table.insert(result, token)
		end
	end
	return result
end

-- Classify a statement for semantic metadata retained on statement roots.
-- WITH statements are classified by the outer operation after the final CTE.
local function classify(tokens)
	local first = tokens[1]
	if not first or first.type ~= "identifier" then
		return "Other"
	end
	local word = first.text:upper()
	if word ~= "WITH" then
		return categories[word] or "Other"
	end

	for index = 2, #tokens do
		local token = tokens[index]
		local previous = tokens[index - 1]
		if token.type == "identifier" and previous.text == ")" and previous.depth == 0 then
			local category = categories[token.text:upper()]
			if category then
				return category
			end
		end
	end
	return "Other"
end

-- Build a map from 1-based source rows to 1-based offsets in the newline-joined
-- source string. Token columns remain 0-based, matching Neovim cursor columns.
local function line_offsets(lines)
	local offsets = {}
	local offset = 1
	for row, line in ipairs(lines) do
		offsets[row] = offset
		offset = offset + #line + 1
	end
	return offsets
end

-- Produce a compact display label for an exact token range. Comment spans are
-- removed using their source coordinates before whitespace is normalized, so
-- comment text never leaks into labels while quoted content remains untouched.
local function label(lines, tokens, first, last)
	local source = table.concat(lines, "\n")
	local offsets = line_offsets(lines)
	local start_offset = offsets[first.row] + first.start_col
	local end_offset = offsets[last.end_row] + last.end_col
	local parts = {}
	local cursor = start_offset
	for _, token in ipairs(tokens) do
		if token.type == "comment" then
			local comment_start = offsets[token.row] + token.start_col
			local comment_end = offsets[token.end_row] + token.end_col
			if comment_start >= start_offset and comment_start < end_offset then
				table.insert(parts, source:sub(cursor, comment_start - 1))
				table.insert(parts, " ")
				cursor = math.min(comment_end, end_offset)
			end
		end
	end
	table.insert(parts, source:sub(cursor, end_offset - 1))
	return table.concat(parts):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
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

-- Test whether a cursor is inside a node's end-exclusive source range.
local function contains(node, row, col)
	local after_start = row > node.start_row or (row == node.start_row and col >= node.start_col)
	local before_end = row < node.end_row or (row == node.end_row and col < node.end_col)
	return after_start and before_end
end

-- Construct the common node shape in one place so every node kind obeys the
-- same ID, label, range, and children invariants.
local function make_node(lines, tokens, options)
	return {
		id = options.id,
		kind = options.kind,
		label = options.label or label(lines, tokens, options.first, options.last),
		category = options.category,
		clause = options.clause,
		start_row = options.first.row,
		start_col = options.first.start_col,
		end_row = options.last.end_row,
		end_col = options.last.end_col,
		children = options.children or {},
	}
end

-- Find the closing parenthesis paired with one opening token. The tokenizer
-- stamps an opening parenthesis with its new depth and its matching close with
-- one less, allowing nested subqueries to be skipped without parsing them.
local function closing_paren(tokens, opening)
	local opening_depth = tokens[opening].depth
	for index = opening + 1, #tokens do
		if tokens[index].text == ")" and tokens[index].depth == opening_depth - 1 then
			return index
		end
	end
	return nil
end

local with_children
local query_node
local query_nodes

-- Recognize clause boundaries only at the query block's own parenthesis depth.
-- Keywords inside functions, CASE expressions, and nested queries therefore
-- remain part of the clause that owns them.
local function clause_at(content, index, depth, current_clause)
	local token = content[index]
	if not token or token.type ~= "identifier" or token.depth ~= depth then
		return nil
	end
	local word = token.text:upper()
	if word == "SELECT" or word == "FROM" or word == "WHERE" or word == "HAVING" then
		return word
	end
	if word == "WINDOW" then
		local name = content[index + 1]
		local as_token = content[index + 2]
		if
			name
			and (name.type == "identifier" or name.type == "quoted_identifier")
			and name.depth == depth
			and as_token
			and as_token.type == "identifier"
			and as_token.depth == depth
			and as_token.text:upper() == "AS"
		then
			return word
		end
		return nil
	end
	if word == "LIMIT" or word == "OFFSET" then
		local previous = content[index - 1]
		local next_token = content[index + 1]
		local next_word = next_token and next_token.type == "identifier" and next_token.text:upper() or nil
		if current_clause == "SELECT" and previous and (previous.type == "identifier" or previous.type == "quoted_identifier") then
			return nil
		end
		if
			previous
			and (
				(previous.type == "identifier" and (previous.text:upper() == "AS" or previous.text:upper() == "SELECT"))
				or (previous.type == "punct" and previous.text ~= ")")
			)
		then
			return nil
		end
		if next_word == "AS" or next_word == "JOIN" or next_word == "ON" then
			return nil
		end
		if next_token and next_token.depth == depth and (next_token.text == "," or next_word == "FROM" or next_word == "WHERE" or next_word == "GROUP" or next_word == "HAVING" or next_word == "WINDOW" or next_word == "ORDER" or next_word == "LIMIT" or next_word == "OFFSET") then
			return nil
		end
		return word
	end
	if word == "GROUP" or word == "ORDER" then
		local next_token = content[index + 1]
		if next_token and next_token.type == "identifier" and next_token.depth == depth and next_token.text:upper() == "BY" then
			return word .. " BY"
		end
	end
	return nil
end

-- Find parenthesized SELECT/WITH blocks inside one clause. Ordinary grouping
-- and function calls are traversed but do not create nodes; once a real query
-- is found, its complete range is handed recursively to `query_node`.
local function nested_queries(lines, tokens, content, first_index, last_index, id_prefix)
	local children = {}
	local index = first_index
	while index <= last_index do
		local opening = content[index]
		if opening.text == "(" then
			local closing = closing_paren(content, index)
			local first = content[index + 1]
			local word = first and first.type == "identifier" and first.text:upper() or nil
			if closing and closing <= last_index + 1 and first and first.depth == opening.depth and (word == "SELECT" or word == "WITH") then
				local id = string.format("%s:query:%d:%d", id_prefix, first.row, first.start_col)
				local queries = query_nodes(lines, tokens, content, index + 1, closing - 1, id, first.depth)
				for _, query in ipairs(queries or {}) do
					table.insert(children, query)
				end
				index = closing + 1
			else
				index = index + 1
			end
		else
			index = index + 1
		end
	end
	return children
end

-- Split one SELECT query block into its major source-ordered clauses. Each
-- clause retains its complete text and owns any scalar or derived subqueries
-- nested within that range.
local function query_clauses(lines, tokens, content, first_index, last_index, id_prefix)
	local starts = {}
	local depth = content[first_index].depth
	local current_clause
	for index = first_index, last_index do
		local clause = clause_at(content, index, depth, current_clause)
		if clause then
			table.insert(starts, { index = index, clause = clause })
			current_clause = clause
		end
	end
	if not starts[1] or starts[1].clause ~= "SELECT" then
		return {}
	end

	local children = {}
	for position, start in ipairs(starts) do
		local clause_last = starts[position + 1] and starts[position + 1].index - 1 or last_index
		local first = content[start.index]
		local id = string.format("%s:clause:%s:%d:%d", id_prefix, start.clause:lower():gsub(" ", "_"), first.row, first.start_col)
		table.insert(children, make_node(lines, tokens, {
			id = id,
			kind = "clause",
			clause = start.clause,
			first = first,
			last = content[clause_last],
			children = nested_queries(lines, tokens, content, start.index, clause_last, id),
		}))
	end
	return children
end

-- Build one query node and recursively deepen the SQL constructs Orbit can
-- bound reliably. A nested WITH reuses the same all-or-nothing parser as a
-- statement-level WITH; ordinary SELECT blocks expose clause nodes.
query_node = function(lines, tokens, content, first_index, last_index, id)
	local first = content[first_index]
	local word = first and first.type == "identifier" and first.text:upper() or nil
	local children = {}
	if word == "WITH" then
		local query_content = content
		if first_index ~= 1 or last_index ~= #content then
			query_content = {}
			for index = first_index, last_index do
				table.insert(query_content, content[index])
			end
		end
		children = with_children(lines, tokens, query_content, id)
		if #children == 0 then
			return nil
		end
	elseif word == "SELECT" then
		children = query_clauses(lines, tokens, content, first_index, last_index, id)
	end
	return make_node(lines, tokens, {
		id = id,
		kind = "query",
		first = first,
		last = content[last_index],
		children = children,
	})
end

-- Split one query range into top-level set-operation branches. UNION,
-- INTERSECT, and EXCEPT delimit siblings only at the CTE body's own depth, so a
-- SELECT nested inside a WHERE expression stays part of its owning branch.
-- ALL and DISTINCT are separator modifiers and are omitted from both labels.
local function query_branches(lines, tokens, content, first_index, last_index, id_prefix, depth)
	local branches = {}
	local branch_start = first_index
	local index = first_index
	local function add_branch(last)
		if branch_start <= last then
			local first = content[branch_start]
			local id = string.format("%s:query:%d:%d", id_prefix, first.row, first.start_col)
			local branch = query_node(lines, tokens, content, branch_start, last, id)
			if not branch then
				return false
			end
			table.insert(branches, branch)
		end
		return true
	end
	while index <= last_index do
		local token = content[index]
		local word = token.type == "identifier" and token.text:upper() or nil
		if token.depth == depth and (word == "UNION" or word == "INTERSECT" or word == "EXCEPT") then
			if branch_start == index then
				return nil
			end
			if not add_branch(index - 1) then
				return nil
			end
			index = index + 1
			local modifier = content[index]
			if
				modifier
				and modifier.depth == depth
				and modifier.type == "identifier"
				and (modifier.text:upper() == "ALL" or modifier.text:upper() == "DISTINCT")
			then
				index = index + 1
			end
			if index > last_index then
				return nil
			end
			branch_start = index
		else
			index = index + 1
		end
	end
	if not add_branch(last_index) then
		return nil
	end
	return branches
end

-- Keep the established ID for an unsplit query while assigning source-derived
-- branch IDs when a set operation creates multiple sibling query nodes.
query_nodes = function(lines, tokens, content, first_index, last_index, single_id, depth)
	local branches = query_branches(lines, tokens, content, first_index, last_index, single_id, depth)
	if not branches then
		return nil
	end
	if #branches == 1 then
		local query = query_node(lines, tokens, content, first_index, last_index, single_id)
		return query and { query } or nil
	end
	return branches
end

-- Parse a leading WITH clause into the hierarchy consumed by the panel.
--
-- The parser supports RECURSIVE, optional CTE column lists, and PostgreSQL's
-- [NOT] MATERIALIZED modifier. Each CTE owns one query node per top-level set-
-- operation branch; deeper parenthesized SELECT clauses stay inside their
-- owning branch. The outer operation becomes a sibling of the WITH branch.
--
-- This parser is deliberately all-or-nothing. Any missing name, AS keyword,
-- opening parenthesis, or matching close returns an empty child list. The
-- statement root still remains usable while a user is midway through editing.
with_children = function(lines, tokens, content, statement_id)
	if not (content[1] and content[1].type == "identifier" and content[1].text:upper() == "WITH") then
		return {}
	end
	local index = 2
	if content[index] and content[index].type == "identifier" and content[index].text:upper() == "RECURSIVE" then
		index = index + 1
	end
	local ctes = {}
	local last_cte
	while content[index] do
		local name = content[index]
		if name.type ~= "identifier" and name.type ~= "quoted_identifier" then
			return {}
		end
		index = index + 1
		if content[index] and content[index].text == "(" then
			local columns_end = closing_paren(content, index)
			if not columns_end then
				return {}
			end
			index = columns_end + 1
		end
		if not (content[index] and content[index].type == "identifier" and content[index].text:upper() == "AS") then
			return {}
		end
		index = index + 1
		if content[index] and content[index].type == "identifier" and content[index].text:upper() == "NOT" then
			index = index + 1
			if not (content[index] and content[index].type == "identifier" and content[index].text:upper() == "MATERIALIZED") then
				return {}
			end
			index = index + 1
		elseif content[index] and content[index].type == "identifier" and content[index].text:upper() == "MATERIALIZED" then
			index = index + 1
		end
		if not (content[index] and content[index].text == "(") then
			return {}
		end
		local body_start = index + 1
		local body_end = closing_paren(content, index)
		if not body_end then
			return {}
		end
		if body_start == body_end then
			return {}
		end
		local cte_id = string.format("%s:cte:%d:%d", statement_id, name.row, name.start_col)
		local body_children = query_branches(lines, tokens, content, body_start, body_end - 1, cte_id, content[index].depth)
		if not body_children then
			return {}
		end
		last_cte = content[body_end]
		table.insert(ctes, make_node(lines, tokens, {
			id = cte_id,
			kind = "cte",
			label = name.text,
			first = name,
			last = last_cte,
			children = body_children,
		}))
		index = body_end + 1
		if content[index] and content[index].text == "," then
			index = index + 1
			if not content[index] then
				return {}
			end
		else
			break
		end
	end
	if #ctes == 0 or not last_cte then
		return {}
	end
	local children = {
		make_node(lines, tokens, {
			id = statement_id .. ":with",
			kind = "with",
			label = "WITH",
			first = content[1],
			last = last_cte,
			children = ctes,
		}),
	}
	if not content[index] then
		return {}
	end
	local outer_queries = query_nodes(
		lines,
		tokens,
		content,
		index,
		#content,
		statement_id .. ":query",
		content[index].depth
	)
	if not outer_queries then
		return {}
	end
	for _, query in ipairs(outer_queries) do
		table.insert(children, query)
	end
	return children
end

-- Turn one semicolon-delimited token run into a statement root. Empty/comment-
-- only runs return nil. Compound bodies are categorized as Other because their
-- internal grammar is intentionally represented as one conservative node.
local function make_entry(lines, tokens, separator, force_other)
	local content = significant(tokens)
	if #content == 0 then
		return nil
	end
	local first = content[1]
	local last = separator or content[#content]
	local id = string.format("statement:%d:%d", first.row, first.start_col)
	local children = with_children(lines, tokens, content, id)
	if #children == 0 and first.type == "identifier" and first.text:upper() == "SELECT" then
		children = query_nodes(lines, tokens, content, 1, #content, id .. ":query", first.depth) or {}
	end
	return make_node(lines, tokens, {
		id = id,
		kind = "statement",
		category = force_other and "Other" or classify(content),
		first = first,
		last = last,
		children = children,
	})
end

-- Extract every top-level statement and its supported hierarchy.
--
-- Ordinary depth-zero semicolons finish a statement. For recognized procedural
-- forms, BEGIN/CASE/IF/LOOP and END maintain a small block-depth counter so body
-- semicolons stay inside one coarse entry. `END IF` and `END LOOP` do not reopen
-- a block because `previous_word` records the preceding END. An explicit
-- DECLARE section may contain separators before its eventual BEGIN.
--
-- Params: lines - query-buffer lines without newline terminators.
-- Returns: an array of statement-root nodes in source order.
-- Side effects: none.
function M.extract(lines)
	local entries = {}
	local current = {}
	local compound = false
	local compound_body = false
	local block_depth = 0
	local previous_word

	local function finish(separator)
		local entry = make_entry(lines, current, separator, compound_body)
		if entry then
			table.insert(entries, entry)
		end
		current = {}
		compound = false
		compound_body = false
		block_depth = 0
		previous_word = nil
	end

	local tokens = tokenizer.tokenize(lines)
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
		if not compound and #current <= 12 then
			local content = significant(current)
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
	return entries
end

-- Return the deepest tree node containing a source cursor. Searching children
-- before returning their parent makes a cursor inside a CTE body select its
-- query node, while punctuation between children falls back to the statement.
--
-- Params: entries - statement roots from M.extract; row/col - Neovim cursor.
-- Returns: the deepest containing node, or nil outside all statement ranges.
function M.at(entries, row, col)
	local function deepest(nodes)
		for _, node in ipairs(nodes) do
			if contains(node, row, col) then
				return deepest(node.children) or node
			end
		end
		return nil
	end
	return deepest(entries)
end

return M
