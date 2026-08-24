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
}
