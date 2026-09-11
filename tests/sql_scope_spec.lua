local tokenizer = require("orbit.sql.tokenizer")
local scope = require("orbit.sql.scope")

local function analyze_at(lines, row, col)
	local tokens = tokenizer.tokenize(lines)
	local statement_tokens, cursor_index, touching = scope.statement_at(tokens, row, col)
	return scope.analyze(statement_tokens, cursor_index, touching)
end

local function names(alias_scope)
	local result = {}
	for _, entry in ipairs(alias_scope) do
		table.insert(result, entry.alias or entry.name)
	end
	return result
end

local function analyze_marked(sql)
	local marker = assert(sql:find("|", 1, true))
	local line = sql:sub(1, marker - 1) .. sql:sub(marker + 1)
	return analyze_at({ line }, 1, marker - 1)
end

return {
	["quoted set-operation names do not split query blocks"] = function()
		local analysis = analyze_marked('SELECT x.| AS "UNION" FROM tab x')
		assert(vim.deep_equal(names(analysis.alias_scope), { "x" }), vim.inspect(analysis.alias_scope))
	end,

	["non-LATERAL derived tables cannot see outer aliases"] = function()
		local analysis = analyze_marked("SELECT * FROM outer_table o JOIN (SELECT i.| FROM inner_table i) d ON d.id = o.id")
		assert(vim.deep_equal(names(analysis.alias_scope), { "i" }), vim.inspect(analysis.alias_scope))
		local incomplete = analyze_marked("SELECT * FROM outer_table o JOIN (o.|")
		assert(vim.deep_equal(names(incomplete.alias_scope), {}), vim.inspect(incomplete.alias_scope))
	end,

	["scalar subqueries after expression commas retain correlation"] = function()
		local analysis = analyze_marked("SELECT coalesce(1, (SELECT i.| FROM inner_table i WHERE i.id = o.id)) FROM outer_table o")
		assert(vim.deep_equal(names(analysis.alias_scope), { "i", "o" }), vim.inspect(analysis.alias_scope))
	end,

	["LATERAL derived tables see only preceding outer aliases"] = function()
		local analysis = analyze_marked(
			"SELECT * FROM outer_table o JOIN LATERAL (SELECT i.| FROM inner_table i) d JOIN later_table l ON true"
		)
		assert(vim.deep_equal(names(analysis.alias_scope), { "i", "o" }), vim.inspect(analysis.alias_scope))
		local commented = analyze_marked(
			"SELECT * FROM outer_table o JOIN LATERAL /* keep correlation */ (SELECT i.| FROM inner_table i) d"
		)
		assert(vim.deep_equal(names(commented.alias_scope), { "i", "o" }), vim.inspect(commented.alias_scope))
		local isolated = analyze_marked(
			"SELECT * FROM outer_table o JOIN /* no correlation */ (SELECT i.| FROM inner_table i) d ON true"
		)
		assert(vim.deep_equal(names(isolated.alias_scope), { "i" }), vim.inspect(isolated.alias_scope))
	end,

	["JOIN conditions cannot see tables introduced by later joins"] = function()
		local analysis = analyze_marked(
			"SELECT * FROM first_table f JOIN second_table s ON s.id = f.| JOIN later_table l ON l.id = s.id"
		)
		assert(vim.deep_equal(names(analysis.alias_scope), { "f", "s" }), vim.inspect(analysis.alias_scope))
		local correlated = analyze_marked(
			"SELECT * FROM first_table f JOIN second_table s ON EXISTS (SELECT i.| FROM inner_table i WHERE i.id = s.id) JOIN later_table l ON true"
		)
		assert(vim.deep_equal(names(correlated.alias_scope), { "i", "f", "s" }), vim.inspect(correlated.alias_scope))
	end,

	["compound ORDER BY does not expose a branch's table aliases"] = function()
		local analysis = analyze_marked(
			"SELECT l.id FROM left_table l UNION SELECT r.id FROM right_table r ORDER BY |"
		)
		assert(vim.deep_equal(names(analysis.alias_scope), {}), vim.inspect(analysis.alias_scope))
		local sibling = analyze_marked(
			"SELECT (SELECT a.id FROM alpha a UNION SELECT b.id FROM beta b), (SELECT c.id FROM gamma c ORDER BY |)"
		)
		assert(vim.deep_equal(names(sibling.alias_scope), { "c" }), vim.inspect(sibling.alias_scope))
	end,

	["statement_at isolates the statement containing the cursor"] = function()
		local tokens = tokenizer.tokenize({ "SELECT 1; SELECT a FROM b; SELECT 3" })
		local statement_tokens = scope.statement_at(tokens, 1, #"SELECT 1; SELECT a FROM ")
		local texts = {}
		for _, tok in ipairs(statement_tokens) do
			table.insert(texts, tok.text)
		end
		assert(vim.deep_equal(texts, { "SELECT", "a", "FROM", "b" }))
	end,

	["alias scope from an earlier statement never leaks into a later one"] = function()
		local lines = { "SELECT x FROM t1 AS a;", "SELECT y FROM t2 b WHERE " }
		local analysis = analyze_at(lines, 2, #"SELECT y FROM t2 b WHERE ")
		assert(vim.deep_equal(names(analysis.alias_scope), { "b" }))
	end,

	["implicit and explicit aliases both resolve"] = function()
		local line = "SELECT * FROM users AS u, orders o WHERE "
		local analysis = analyze_at({ line }, 1, #line)
		assert(vim.deep_equal(names(analysis.alias_scope), { "u", "o" }))
		assert(analysis.alias_scope[1].name == "users")
		assert(analysis.alias_scope[1].kind == "table")
		assert(analysis.alias_scope[2].name == "orders")
	end,

	["clause detection covers SELECT, WHERE, ON, GROUP BY, ORDER BY"] = function()
		local cases = {
			{ line = "SELECT ", clause = "select_list" },
			{ line = "SELECT * FROM t WHERE ", clause = "where" },
			{ line = "SELECT * FROM a JOIN b ON ", clause = "on" },
			{ line = "SELECT * FROM t GROUP BY ", clause = "group_by" },
			{ line = "SELECT * FROM t ORDER BY ", clause = "order_by" },
			{ line = "SELECT * FROM ", clause = "from_family" },
			{ line = "UPDATE t SET ", clause = "update_set" },
		}
		for _, case in ipairs(cases) do
			local analysis = analyze_at({ case.line }, 1, #case.line)
			assert(analysis.clause == case.clause, case.line .. " -> " .. analysis.clause)
		end
	end,

	["INSERT INTO t (...) is clause-aware as insert_columns"] = function()
		local line = "INSERT INTO orders ("
		local analysis = analyze_at({ line }, 1, #line)
		assert(analysis.clause == "insert_columns")
		assert(vim.deep_equal(names(analysis.alias_scope), { "orders" }))
	end,

	["a CTE name is recognized without leaking its body's own bindings"] = function()
		local line = "WITH recent AS (SELECT id FROM raw) SELECT * FROM recent WHERE "
		local analysis = analyze_at({ line }, 1, #line)
		assert(analysis.clause == "where")
		assert(vim.deep_equal(names(analysis.alias_scope), { "recent" }))
		assert(analysis.alias_scope[1].kind == "cte")
	end,

	["a derived table is captured with only its alias"] = function()
		local line = "SELECT * FROM (SELECT 1) sub WHERE "
		local analysis = analyze_at({ line }, 1, #line)
		assert(vim.deep_equal(names(analysis.alias_scope), { "sub" }))
		assert(analysis.alias_scope[1].kind == "derived")
	end,

	["qualifier extraction reports the typed segments and raw text"] = function()
		local line = 'SELECT "Sales".'
		local analysis = analyze_at({ line }, 1, #line)
		assert(vim.deep_equal(analysis.qualifier.segments, { "Sales" }))
		assert(analysis.qualifier.raw == '"Sales".')
		assert(analysis.qualifier.partial == "")
		assert(analysis.qualifier.typed == '"Sales".')
		assert(analysis.qualifier.start_row == 1)
		assert(analysis.qualifier.start_col == #"SELECT ")
	end,

	["a multi-line statement resolves aliases across lines"] = function()
		local lines = { "SELECT u.", "FROM users u" }
		local analysis = analyze_at(lines, 1, #"SELECT u.")
		assert(vim.deep_equal(names(analysis.alias_scope), { "u" }))
		assert(analysis.qualifier.segments[1] == "u")
	end,

	["set-operation aliases stay local to their UNION and INTERSECT branches"] = function()
		local union_left = analyze_marked("SELECT l.| FROM left_table l UNION SELECT r.id FROM right_table r")
		assert(vim.deep_equal(names(union_left.alias_scope), { "l" }))

		local union_right = analyze_marked("SELECT l.id FROM left_table l UNION SELECT r.| FROM right_table r")
		assert(vim.deep_equal(names(union_right.alias_scope), { "r" }))

		local intersect_right =
			analyze_marked("SELECT a.id FROM alpha a INTERSECT SELECT b.| FROM beta b")
		assert(vim.deep_equal(names(intersect_right.alias_scope), { "b" }))
	end,

	["sibling subqueries do not share aliases but retain their outer correlation"] = function()
		local analysis = analyze_marked(
			"SELECT * FROM outer_table o WHERE EXISTS (SELECT 1 FROM first_table f WHERE f.id = o.id) "
				.. "AND EXISTS (SELECT s.| FROM second_table s WHERE s.id = o.id)"
		)
		assert(vim.deep_equal(names(analysis.alias_scope), { "s", "o" }))
	end,

	["nested correlation includes every intermediate query block nearest-first"] = function()
		local analysis = analyze_marked(
			"SELECT * FROM outer_table o WHERE EXISTS (SELECT 1 FROM middle_table m WHERE EXISTS "
				.. "(SELECT i.| FROM inner_table i WHERE i.middle_id = m.id AND m.outer_id = o.id))"
		)
		assert(vim.deep_equal(names(analysis.alias_scope), { "i", "m", "o" }))
	end,

	["nearest aliases preserve shadowing across correlated query blocks"] = function()
		local analysis = analyze_marked(
			"SELECT * FROM outer_table x WHERE EXISTS (SELECT 1 FROM middle_table x WHERE EXISTS "
				.. "(SELECT x.| FROM inner_table x))"
		)
		assert(vim.deep_equal(names(analysis.alias_scope), { "x", "x", "x" }))
		assert(analysis.alias_scope[1].name == "inner_table")
		assert(analysis.alias_scope[2].name == "middle_table")
		assert(analysis.alias_scope[3].name == "outer_table")
	end,

	["malformed and incomplete set branches remain isolated"] = function()
		local malformed = analyze_marked(
			"SELECT * FROM left_table l UNION SELECT * FROM right_table r WHERE (r.|"
		)
		assert(vim.deep_equal(names(malformed.alias_scope), { "r" }))

		local incomplete = analyze_marked("SELECT * FROM left_table l INTERSECT SELECT * FROM |")
		assert(vim.deep_equal(names(incomplete.alias_scope), {}))
	end,
}
