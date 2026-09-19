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
}
