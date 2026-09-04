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
      assert(vim.deep_equal(words(completion.items(profile, { line }, 1, #line)), {
        "active_users",
        "hive.",
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
      assert(vim.deep_equal(words(completion.items(profile, { line }, 1, #line)), {
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
      local tables = completion.items(profile, { "SELECT * FROM " }, 1, #"SELECT * FROM ")
      local schema_tables = completion.items(profile, { 'SELECT * FROM "Sales".' }, 1, #'SELECT * FROM "Sales".')
      local unquoted_schema_tables =
        completion.items(profile, { "SELECT * FROM Sales." }, 1, #"SELECT * FROM Sales.")

      assert(tables[1].word == '"Sales"."Order"')
      assert(schema_tables[1].word == '"Sales"."Order"')
      assert(unquoted_schema_tables[1].word == '"Sales"."Order"')
    end)
  end,

  ["PostgreSQL completion narrows to the typed schema across multiple schemas"] = function()
    local profile = { name = "completion-postgres-schemas", kind = "postgres", options = { database = "orbit" } }
    local rows = {
      { schema = "sales", name = "orders", type = "table" },
      { schema = "reporting", name = "orders_summary", type = "table" },
    }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local sales_tables = completion.items(profile, { "SELECT * FROM sales." }, 1, #"SELECT * FROM sales.")
      assert(#sales_tables == 1)
      assert(sales_tables[1].word == '"sales"."orders"')
    end)
  end,

  ["Vertica completion always inserts the canonical quoted name, ignoring the typed prefix"] = function()
    local profile = { name = "completion-vertica", kind = "vertica", options = { database = "warehouse" } }
    local rows = { { schema = "Sales", name = "Order", type = "table" } }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local tables = completion.items(profile, { "SELECT * FROM " }, 1, #"SELECT * FROM ")
      local unquoted_schema_tables =
        completion.items(profile, { "SELECT * FROM Sales." }, 1, #"SELECT * FROM Sales.")

      assert(tables[1].word == '"Sales"."Order"')
      -- Must not mix the user's unquoted typed prefix with a quoted name
      -- (e.g. `Sales."Order"`) -- the canonical quoted form replaces it.
      assert(unquoted_schema_tables[1].word == '"Sales"."Order"')
    end)
  end,

  ["aliased column completion resolves the alias to its table"] = function()
    local profile = { name = "completion-alias", kind = "sqlite", options = { path = "orbit.db" } }
    local columns = {
      { name = "id", type = "INTEGER" },
      { name = "email", type = "TEXT" },
    }
    with_acquisition(profile, { { name = "users", type = "table" } }, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      with_acquisition(profile, columns, function(done)
        cache.load_columns(profile, { name = "users", type = "table" }, {}, done)
      end, function()
        local line = "SELECT u. FROM users u"
        local cursor = #"SELECT u."
        assert(vim.deep_equal(words(completion.items(profile, { line }, 1, cursor)), {
          "u.email",
          "u.id",
        }))
      end)
    end)
  end,

  ["unqualified column completion unions every joined table, annotated by source"] = function()
    local profile = { name = "completion-join", kind = "sqlite", options = { path = "orbit.db" } }
    local orders_columns = { { name = "id", type = "INTEGER" } }
    local users_columns = { { name = "id", type = "INTEGER" }, { name = "name", type = "TEXT" } }
    with_acquisition(profile, { { name = "orders", type = "table" }, { name = "users", type = "table" } }, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      with_acquisition(profile, orders_columns, function(done)
        cache.load_columns(profile, { name = "orders", type = "table" }, {}, done)
      end, function()
        with_acquisition(profile, users_columns, function(done)
          cache.load_columns(profile, { name = "users", type = "table" }, {}, done)
        end, function()
          local line = "SELECT  FROM orders o JOIN users u ON o.user_id = u.id"
          local cursor = #"SELECT "
          local items = completion.items(profile, { line }, 1, cursor)

          local by_word = {}
          for _, it in ipairs(items) do
            by_word[it.word] = it
          end
          -- Both tables' "id" column are offered as separate items, not
          -- collapsed into one, each annotated with the alias it came from.
          local ids = {}
          for _, it in ipairs(items) do
            if it.word == "id" then
              table.insert(ids, it.menu)
            end
          end
          table.sort(ids)
          assert(vim.deep_equal(ids, { "o", "u" }))

          assert(by_word["o"] and by_word["o"].kind == "Alias")
          assert(by_word["u"] and by_word["u"].kind == "Alias")
        end)
      end)
    end)
  end,

  ["completion resolves comma-style joins"] = function()
    local profile = { name = "completion-comma-join", kind = "sqlite", options = { path = "orbit.db" } }
    local columns = { { name = "id", type = "INTEGER" } }
    with_acquisition(profile, { { name = "a", type = "table" }, { name = "b", type = "table" } }, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      with_acquisition(profile, columns, function(done)
        cache.load_columns(profile, { name = "b", type = "table" }, {}, done)
      end, function()
        local line = "SELECT b. FROM a, b"
        local cursor = #"SELECT b."
        assert(vim.deep_equal(words(completion.items(profile, { line }, 1, cursor)), { "b.id" }))
      end)
    end)
  end,

  ["completion is clause-aware across WHERE, ON, GROUP BY, and ORDER BY"] = function()
    local profile = { name = "completion-clauses", kind = "sqlite", options = { path = "orbit.db" } }
    local columns = { { name = "id", type = "INTEGER" } }
    with_acquisition(profile, { { name = "orders", type = "table" } }, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      with_acquisition(profile, columns, function(done)
        cache.load_columns(profile, { name = "orders", type = "table" }, {}, done)
      end, function()
        for _, clause in ipairs({
          "SELECT * FROM orders WHERE ",
          "SELECT * FROM orders GROUP BY ",
          "SELECT * FROM orders ORDER BY ",
        }) do
          assert(vim.deep_equal(words(completion.items(profile, { clause }, 1, #clause)), { "id" }))
        end

        local on_line = "SELECT * FROM orders o JOIN orders p ON "
        -- Two tables in scope for the ON condition; "id" comes from both.
        local ids = 0
        for _, it in ipairs(completion.items(profile, { on_line }, 1, #on_line)) do
          if it.word == "id" then
            ids = ids + 1
          end
        end
        assert(ids == 2)
      end)
    end)
  end,

  ["INSERT and UPDATE column-list completion targets the single named table"] = function()
    local profile = { name = "completion-dml", kind = "sqlite", options = { path = "orbit.db" } }
    local columns = { { name = "id", type = "INTEGER" }, { name = "email", type = "TEXT" } }
    with_acquisition(profile, { { name = "users", type = "table" } }, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      with_acquisition(profile, columns, function(done)
        cache.load_columns(profile, { name = "users", type = "table" }, {}, done)
      end, function()
        local insert_line = "INSERT INTO users ("
        assert(vim.deep_equal(words(completion.items(profile, { insert_line }, 1, #insert_line)), {
          "email",
          "id",
        }))

        local update_line = "UPDATE users SET "
        assert(vim.deep_equal(words(completion.items(profile, { update_line }, 1, #update_line)), {
          "email",
          "id",
        }))
      end)
    end)
  end,

  ["a derived table alias offers no columns instead of erroring"] = function()
    local profile = { name = "completion-derived", kind = "sqlite", options = { path = "orbit.db" } }
    local line = "SELECT sub. FROM (SELECT 1) sub"
    local cursor = #"SELECT sub."
    assert(vim.deep_equal(words(completion.items(profile, { line }, 1, cursor)), {}))
  end,

  ["a CTE reference offers no columns instead of erroring"] = function()
    local profile = { name = "completion-cte", kind = "sqlite", options = { path = "orbit.db" } }
    local line = "WITH recent AS (SELECT 1) SELECT recent. FROM recent"
    local cursor = #"WITH recent AS (SELECT 1) SELECT recent."
    assert(vim.deep_equal(words(completion.items(profile, { line }, 1, cursor)), {}))
  end,

  ["completion tolerates malformed SQL elsewhere in the buffer"] = function()
    local profile = { name = "completion-malformed", kind = "sqlite", options = { path = "orbit.db" } }
    local columns = { { name = "id", type = "INTEGER" } }
    with_acquisition(profile, { { name = "orders", type = "table" } }, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      with_acquisition(profile, columns, function(done)
        cache.load_columns(profile, { name = "orders", type = "table" }, {}, done)
      end, function()
        local lines = { "SELECT * FROM x))) WHERE 1=1;", "SELECT * FROM orders WHERE " }
        local ok, result = pcall(completion.items, profile, lines, 2, #lines[2])
        assert(ok, "completion.items must not raise on malformed input elsewhere in the buffer")
        assert(vim.deep_equal(words(result), { "id" }))
      end)
    end)
  end,

  ["Trino qualifier depth is connector-driven across catalogs"] = function()
    local profile = {
      name = "completion-trino-catalog",
      kind = "trino",
      options = {
        catalog = "hive",
        schema = "public",
        schema_patterns = { hive = { "public" }, kafka = { "public" } },
      },
    }
    local rows = {
      { name = "orders", type = "table", schema = "public", catalog = "hive" },
      { name = "events", type = "table", schema = "public", catalog = "kafka" },
    }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local line = "SELECT * FROM "
      local items = completion.items(profile, { line }, 1, #line)
      local by_word = {}
      for _, it in ipairs(items) do
        by_word[it.word] = it
      end
      -- Same-catalog table completes to its 2-part name directly.
      assert(by_word["public.orders"] and by_word["public.orders"].kind == "Table")
      -- Configured catalogs are progressive namespace entries alongside the
      -- existing direct relation suggestions.
      assert(by_word["hive."] and by_word["hive."].kind == "Catalog")
      assert(by_word["kafka."] and by_word["kafka."].kind == "Catalog")

      local schema_line = "SELECT * FROM public."
      assert(vim.deep_equal(words(completion.items(profile, { schema_line }, 1, #schema_line)), {
        "public.orders",
      }))
    end)
  end,

  ["Trino completion traverses configured catalogs, schemas, and relations"] = function()
    local profile = {
      name = "completion-trino-hierarchy",
      kind = "trino",
      options = {
        catalog = "gridhive",
        schema_patterns = {
          gridhive = { "sales", "empty" },
          iceberg = {},
        },
      },
    }
    local rows = {
      { name = "orders", type = "table", schema = "sales", catalog = "gridhive" },
      { name = "events", type = "view", schema = "cleanroom", catalog = "iceberg" },
    }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local unqualified = completion.items(profile, { "SELECT * FROM " }, 1, #"SELECT * FROM ")
      local by_word = {}
      for _, it in ipairs(unqualified) do
        by_word[it.word] = it
      end
      assert(by_word["sales.orders"] and by_word["sales.orders"].kind == "Table")
      assert(by_word["iceberg.cleanroom.events"] and by_word["iceberg.cleanroom.events"].kind == "View")
      assert(by_word["gridhive."] and by_word["gridhive."].kind == "Catalog")
      assert(by_word["iceberg."] and by_word["iceberg."].kind == "Catalog")

      local catalog_line = "SELECT * FROM gridhive."
      assert(vim.deep_equal(words(completion.items(profile, { catalog_line }, 1, #catalog_line)), {
        "gridhive.empty.",
        "gridhive.sales.",
      }))

      local partial_schema_line = "SELECT * FROM gridhive.sa"
      assert(vim.deep_equal(words(completion.items(profile, { partial_schema_line }, 1, #partial_schema_line)), {
        "gridhive.sales.",
      }))

      local schema_line = "SELECT * FROM gridhive.sales."
      assert(vim.deep_equal(words(completion.items(profile, { schema_line }, 1, #schema_line)), {
        "gridhive.sales.orders",
      }))

      local derived_schema_line = "SELECT * FROM iceberg."
      assert(vim.deep_equal(words(completion.items(profile, { derived_schema_line }, 1, #derived_schema_line)), {
        "iceberg.cleanroom.",
      }))
    end)
  end,

  ["Trino completion falls back to the profile's default catalog and schema"] = function()
    local profile = {
      name = "completion-trino-fallback",
      kind = "trino",
      options = { catalog = "gridhive", schema = "public" },
    }
    with_acquisition(profile, {}, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local from_line = "SELECT * FROM "
      assert(vim.deep_equal(words(completion.items(profile, { from_line }, 1, #from_line)), { "gridhive." }))

      local catalog_line = "SELECT * FROM gridhive."
      assert(vim.deep_equal(words(completion.items(profile, { catalog_line }, 1, #catalog_line)), {
        "gridhive.public.",
      }))

      local unknown_line = "SELECT * FROM iceberg."
      assert(vim.deep_equal(words(completion.items(profile, { unknown_line }, 1, #unknown_line)), {}))
    end)
  end,

  ["completion narrows FROM suggestions to the typed prefix, case-insensitively"] = function()
    local profile = { name = "completion-prefix", kind = "sqlite", options = { path = "orbit.db" } }
    local rows = {
      { name = "archive", type = "table" },
      { name = "order_items", type = "table" },
      { name = "orders", type = "table" },
    }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local line = "SELECT * FROM OR"
      assert(vim.deep_equal(words(completion.items(profile, { line }, 1, #line)), {
        "order_items",
        "orders",
      }))
    end)
  end,
}
