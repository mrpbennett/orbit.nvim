local cache = require("orbit.schema_cache")
local completion = require("orbit.completion")

local function words(items)
  local result = {}
  for _, item in ipairs(items) do
    table.insert(result, item.word)
  end
  return result
end

return {
  ["completion suggests cached tables after FROM"] = function()
    cache.store_tables("analytics", {
      { name = "orders", type = "table" },
      { name = "active_users", type = "view" },
    })

    local line = "SELECT * FROM "
    assert(vim.deep_equal(words(completion.items({ name = "analytics", kind = "trino", options = { schema = "public" } }, line, #line)), {
      "active_users",
      "orders",
    }))
  end,

  ["completion suggests cached columns after a table qualifier"] = function()
    cache.store_columns("analytics", "orders", {
      { name = "id", type = "BIGINT" },
      { name = "created_at", type = "TIMESTAMP" },
    })

    local line = "SELECT orders."
    assert(vim.deep_equal(words(completion.items({ name = "analytics", kind = "trino", options = { schema = "public" } }, line, #line)), {
      "orders.created_at",
      "orders.id",
    }))
  end,

  ["PostgreSQL completion accepts quoted and unquoted schema prefixes"] = function()
    cache.store_tables("postgres", {
      { schema = "Sales", name = "Order", type = "table" },
    })
    local profile = { name = "postgres", kind = "postgres", options = { database = "orbit" } }

    local tables = completion.items(profile, "SELECT * FROM ", #"SELECT * FROM ")
    local schema_tables = completion.items(profile, 'SELECT * FROM "Sales".', #'SELECT * FROM "Sales".')
    local unquoted_schema_tables = completion.items(profile, "SELECT * FROM Sales.", #"SELECT * FROM Sales.")

    assert(tables[1].word == '"Sales"."Order"')
    assert(schema_tables[1].word == '"Sales"."Order"')
    assert(unquoted_schema_tables[1].word == '"Sales"."Order"')
  end,

  ["PostgreSQL omnifunc replaces quoted qualified identifiers"] = function()
    local line = 'SELECT * FROM "Sales".'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(0, { 1, #line })

    assert(completion.omnifunc(1, "") == #"SELECT * FROM ")
  end,
}
