local statements = require("quarry.statements")

return {
  ["statements.target prefers an explicit selection"] = function()
    local target = assert(statements.target({
      lines = { "SELECT 1;", "SELECT 2;" },
      selection = { start_row = 2, end_row = 2 },
    }))

    assert(target == "SELECT 2;")
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
}
