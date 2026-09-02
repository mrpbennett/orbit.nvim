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

return {
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
	end,

	["a multi-line statement resolves aliases across lines"] = function()
		local lines = { "SELECT u.", "FROM users u" }
		local analysis = analyze_at(lines, 1, #"SELECT u.")
		assert(vim.deep_equal(names(analysis.alias_scope), { "u" }))
		assert(analysis.qualifier.segments[1] == "u")
	end,
}
