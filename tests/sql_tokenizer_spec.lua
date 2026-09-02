local tokenizer = require("orbit.sql.tokenizer")

local function types(tokens)
	local result = {}
	for _, tok in ipairs(tokens) do
		table.insert(result, tok.type)
	end
	return result
end

local function texts(tokens)
	local result = {}
	for _, tok in ipairs(tokens) do
		table.insert(result, tok.text)
	end
	return result
end

return {
	["tokenizes identifiers, punct, and semicolons"] = function()
		local tokens = tokenizer.tokenize({ "SELECT a.b FROM t;" })
		assert(vim.deep_equal(types(tokens), {
			"identifier",
			"identifier",
			"punct",
			"identifier",
			"identifier",
			"identifier",
			"semicolon",
		}))
	end,

	["tokenizes string and quoted-identifier literals with escaping"] = function()
		local tokens = tokenizer.tokenize({ [[SELECT 'it''s', "Sales"]] })
		assert(tokens[2].type == "string")
		assert(tokens[2].text == [['it''s']])
		assert(tokens[4].type == "quoted_identifier")
		assert(tokens[4].text == [["Sales"]])
	end,

	["tokenizes line and block comments"] = function()
		local tokens = tokenizer.tokenize({ "SELECT 1 -- trailing comment", "/* block */ SELECT 2" })
		assert(vim.deep_equal(types(tokens), { "identifier", "number", "comment", "comment", "identifier", "number" }))
	end,

	["tracks paren depth across a multi-line statement"] = function()
		local tokens = tokenizer.tokenize({ "SELECT * FROM (", "  SELECT 1", ") sub" })
		local by_text = {}
		for _, tok in ipairs(tokens) do
			by_text[tok.text] = tok.depth
		end
		assert(by_text["("] == 1)
		assert(by_text[")"] == 0)
		assert(by_text["sub"] == 0)
	end,

	["assigns row/col matching nvim cursor semantics"] = function()
		local tokens = tokenizer.tokenize({ "SELECT a", "FROM t" })
		local from_tok = tokens[3]
		assert(from_tok.text == "FROM")
		assert(from_tok.row == 2)
		assert(from_tok.start_col == 0)
		assert(from_tok.end_col == 4)
	end,

	["never throws on unterminated string, quoted identifier, or block comment"] = function()
		local cases = {
			{ "SELECT 'unterminated" },
			{ [[SELECT "unterminated]] },
			{ "SELECT 1 /* unterminated" },
			{ "SELECT )" },
		}
		for _, lines in ipairs(cases) do
			local ok, tokens = pcall(tokenizer.tokenize, lines)
			assert(ok, "tokenizer raised on malformed input")
			assert(type(tokens) == "table")
		end
	end,

	["split_qualified unquotes dotted quoted identifiers"] = function()
		assert(vim.deep_equal(tokenizer.split_qualified([["Sales"."Order"]]), { "Sales", "Order" }))
		assert(vim.deep_equal(tokenizer.split_qualified("orders"), { "orders" }))
		assert(vim.deep_equal(tokenizer.split_qualified("catalog.schema.name"), { "catalog", "schema", "name" }))
	end,
}
