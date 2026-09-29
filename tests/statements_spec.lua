local statements = require("orbit.statements")

return {
	["statements.target selects exactly one Redis command line"] = function()
		local target = assert(statements.target({
			lines = { "KEYS *", "", [[GET "capture:one"]] },
			kind = "redis",
			row = 3,
		}))
		assert(target == [[GET "capture:one"]])

		local selected = assert(statements.target({
			lines = { "KEYS *", "GET capture:one" },
			kind = "redis",
			selection = { start_row = 2, end_row = 2 },
		}))
		assert(selected == "GET capture:one")

		local rejected, err = statements.target({
			lines = { "KEYS *", "GET capture:one" },
			kind = "redis",
			selection = { start_row = 1, end_row = 2 },
		})
		assert(rejected == nil and err:match("one line"), tostring(err))
	end,

	["statements.target prefers an explicit selection"] = function()
    local target = assert(statements.target({
      lines = { "SELECT 1;", "SELECT 2;" },
      selection = { start_row = 2, end_row = 2 },
    }))

    assert(target == "SELECT 2;")
  end,

  ["statements.target extracts an exact end-exclusive selection"] = function()
    local target = assert(statements.target({
      lines = { "SELECT users.id", "FROM users; SELECT hidden" },
      selection = { start_row = 1, start_col = 7, end_row = 2, end_col = 10 },
    }))

    assert(target == "users.id\nFROM users")

    target = assert(statements.target({
      lines = { "SELECT users.id FROM users" },
      selection = { start_row = 1, start_col = 7, end_row = 1, end_col = 15 },
    }))
    assert(target == "users.id")
  end,

  ["statements.target accepts one trailing statement terminator"] = function()
    local target = assert(statements.target({
      lines = { "SELECT", "  *", "FROM users;" },
    }))

    assert(target == "SELECT\n  *\nFROM users;")
  end,

  ["statements.target rejects ambiguous multiple statements"] = function()
    local target, err = statements.target({
      lines = { "SELECT 1; SELECT 2;" },
    })

    assert(target == nil)
    assert(err:match("select the statement explicitly"))
  end,

	["statements.target applies SQL Server lexical splitting and rejects GO"] = function()
		local target = assert(statements.target({
			lines = { "SELECT '[semi;]' AS [semi;column]; -- trailing ;" },
			dialect = "mssql",
		}))
		assert(target:match("semi;column"))

		local rejected, err = statements.target({ lines = { "SELECT 1", "GO" }, dialect = "mssql" })
		assert(rejected == nil and err:match("GO batch separators"))
		assert(statements.target({ lines = { "SELECT 'GO' AS value" }, dialect = "mssql" }))
	end,

	["statements.target ignores semicolons inside literals and comments for every dialect"] = function()
		for _, dialect in ipairs({ "postgres", "mysql" }) do
			-- postgres is not a tokenizer mode; it exercises the default lexer.
			local mode = dialect == "mysql" and "mysql" or nil
			assert(statements.target({ lines = { "SELECT 'a;b' AS x" }, dialect = mode }), dialect)
			assert(statements.target({ lines = { "SELECT 1; -- done;" }, dialect = mode }), dialect)
			assert(statements.target({ lines = { "SELECT 1 /* ; */;" }, dialect = mode }), dialect)
			assert(statements.target({ lines = { [[SELECT "semi;colon" FROM t;]] }, dialect = mode }), dialect)
		end
		assert(statements.target({ lines = { "SELECT `semi;colon` FROM t;" }, dialect = "mysql" }))
		assert(statements.target({ lines = { "SELECT $$a;b$$;" } }))

		local rejected, err = statements.target({ lines = { "SELECT 'a;b'; SELECT 2" } })
		assert(rejected == nil and err:match("ambiguous"), tostring(err))
	end,

	["statements.target runs one compound statement whose body contains semicolons"] = function()
		local lines = {
			"CREATE PROCEDURE touch()",
			"BEGIN",
			"  UPDATE items SET seen = 1;",
			"  DELETE FROM stale;",
			"END;",
		}
		assert(statements.target({ lines = lines, dialect = "mysql" }))

		local rejected = statements.target({ lines = vim.list_extend(vim.deepcopy(lines), { "SELECT 1;" }), dialect = "mysql" })
		assert(rejected == nil)
	end,

	["statements.requires_confirmation only skips single read-only statements"] = function()
		local read_only = {
			"SELECT 1",
			"select * from t;",
			"-- leading note\n/* block */ SELECT 'DROP TABLE t;' AS text; -- trailing;",
			"SHOW TABLES",
			"EXPLAIN SELECT 1",
		}
		for _, statement in ipairs(read_only) do
			assert(not statements.requires_confirmation(statement), statement)
		end
		local mutating = {
			"UPDATE t SET a = 1",
			"SELECT 1; DELETE FROM t",
			"WITH x AS (SELECT 1) DELETE FROM t",
			"-- only a comment",
			"",
			"CREATE FUNCTION f() BEGIN SELECT 1; END",
		}
		for _, statement in ipairs(mutating) do
			assert(statements.requires_confirmation(statement), statement)
		end
		assert(not statements.requires_confirmation("SELECT `a;b` FROM t", "mysql"))
	end,
}
