local cache = require("orbit.schema_cache")
local completion = require("orbit.completion")
local runner = require("orbit.runner")

local function words(items)
  local result = {}
  for _, item in ipairs(items) do
    table.insert(result, item.word)
  end
  return result
end

local function with_acquisition(profile, rows, acquire, callback)
  local original_run = runner.run
  runner.run = function(received, _, done)
    assert(received == profile)
    done(rows)
  end
  local ok, err = xpcall(function()
    local acquired, acquisition_err
    acquire(function(result, result_err)
      acquired, acquisition_err = result, result_err
    end)
    assert(vim.deep_equal(acquired, rows))
    assert(acquisition_err == nil)
    callback()
  end, debug.traceback)
  runner.run = original_run
  assert(ok, err)
end

return {
  ["completion suggests cached tables after FROM"] = function()
    local profile = { name = "completion-tables", kind = "trino", options = { catalog = "hive", schema = "public" } }
    local rows = {
      { name = "orders", type = "table" },
      { name = "active_users", type = "view" },
    }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local line = "SELECT * FROM "
      assert(vim.deep_equal(words(completion.items(profile, line, #line)), {
        "active_users",
        "orders",
      }))
    end)
  end,

  ["completion suggests cached columns after a table qualifier"] = function()
    local profile = { name = "completion-columns", kind = "trino", options = { catalog = "hive", schema = "public" } }
    local rows = {
      { name = "id", type = "BIGINT" },
      { name = "created_at", type = "TIMESTAMP" },
    }
    with_acquisition(profile, rows, function(done)
      cache.load_columns(profile, { name = "orders", type = "table" }, {}, done)
    end, function()
      local line = "SELECT orders."
      assert(vim.deep_equal(words(completion.items(profile, line, #line)), {
        "orders.created_at",
        "orders.id",
      }))
    end)
  end,

  ["PostgreSQL completion accepts quoted and unquoted schema prefixes"] = function()
    local profile = { name = "completion-postgres", kind = "postgres", options = { database = "orbit" } }
    local rows = { { schema = "Sales", name = "Order", type = "table" } }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local tables = completion.items(profile, "SELECT * FROM ", #"SELECT * FROM ")
      local schema_tables = completion.items(profile, 'SELECT * FROM "Sales".', #'SELECT * FROM "Sales".')
      local unquoted_schema_tables = completion.items(profile, "SELECT * FROM Sales.", #"SELECT * FROM Sales.")

      assert(tables[1].word == '"Sales"."Order"')
      assert(schema_tables[1].word == '"Sales"."Order"')
      assert(unquoted_schema_tables[1].word == '"Sales"."Order"')
    end)
  end,

  ["PostgreSQL omnifunc replaces quoted qualified identifiers"] = function()
    local line = 'SELECT * FROM "Sales".'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(0, { 1, #line })

    assert(completion.omnifunc(1, "") == #"SELECT * FROM ")
  end,
}
