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
  ["PostgreSQL acquisition and completion distinguish objects with the same dotted label"] = function()
    local profile = { name = "completion-object-identity", kind = "postgres", options = { database = "orbit" } }
    local rows = {
      { schema = "a.b", name = "c", type = "table" },
      { schema = "a", name = "b.c", type = "table" },
    }
    local first_columns = { { name = "first_id", type = "integer" } }
    local second_columns = { { name = "second_id", type = "text" } }
    with_acquisition(profile, rows, function(done)
      cache.load_tables(profile, {}, done)
    end, function()
      local original_run = runner.run
      local pending, results = {}, {}
      runner.run = function(received, statement, done)
        assert(received == profile)
        table.insert(pending, { statement = statement, done = done })
      end
      local ok, err = xpcall(function()
        local function received(label)
          return function(result, result_err)
            assert(result_err == nil)
            results[label] = result
          end
        end
        cache.load_columns(profile, rows[1], {}, received("first"))
        -- Equivalent row values join the request, independent of Lua table identity.
        cache.load_columns(profile, { catalog = "", schema = "a.b", name = "c", type = "table" }, {}, received("joined"))
        cache.load_columns(profile, rows[2], {}, received("second"))
        assert(#pending == 2, "distinct schema objects must start distinct column statements")
        assert(next(results) == nil)
        assert(pending[1].statement ~= pending[2].statement)
        assert(pending[1].statement:find("table_schema = 'a.b'", 1, true))
        assert(pending[1].statement:find("table_name = 'c'", 1, true))
        assert(pending[2].statement:find("table_schema = 'a'", 1, true))
        assert(pending[2].statement:find("table_name = 'b.c'", 1, true))
        pending[2].done(second_columns)
        assert(vim.deep_equal(results.second, second_columns))
        assert(results.first == nil and results.joined == nil)
        pending[1].done(first_columns)
        assert(vim.deep_equal(results.first, first_columns))
        assert(vim.deep_equal(results.joined, first_columns))
        assert(vim.deep_equal(cache.columns(profile, rows[1]), first_columns))
        assert(vim.deep_equal(cache.columns(profile, rows[2]), second_columns))
        cache.load_columns(profile, rows[1], {}, received("cached_first"))
        cache.load_columns(profile, rows[2], {}, received("cached_second"))
        assert(results.cached_first == nil and results.cached_second == nil)
        assert(vim.wait(1000, function()
          return results.cached_first ~= nil and results.cached_second ~= nil
        end))
        assert(vim.deep_equal(results.cached_first, first_columns))
        assert(vim.deep_equal(results.cached_second, second_columns))
        assert(#pending == 2, "cached columns must not start new statements")

        for _, case in ipairs({
          { 'SELECT x. FROM "a.b"."c" x', #"SELECT x.", { "x.first_id" } },
          { 'SELECT y. FROM "a"."b.c" y', #"SELECT y.", { "y.second_id" } },
          { 'SELECT  FROM "a.b"."c"', #"SELECT ", { "first_id" } },
          { 'SELECT  FROM "a"."b.c"', #"SELECT ", { "second_id" } },
          { 'INSERT INTO "a.b"."c" (', nil, { "first_id" } },
          { 'INSERT INTO "a"."b.c" (', nil, { "second_id" } },
          { 'UPDATE "a.b"."c" SET ', nil, { "first_id" } },
          { 'UPDATE "a"."b.c" SET ', nil, { "second_id" } },
          -- Without FROM, the qualifier remains a bare-object cache read, not name resolution.
          { "SELECT c.", nil, {} },
        }) do
          assert(vim.deep_equal(words(completion.items(profile, { case[1] }, 1, case[2] or #case[1])), case[3]), case[1])
        end
      end, debug.traceback)
      runner.run = original_run
      assert(ok, err)
    end)
  end,

  ["PostgreSQL metadata acquisition isolates colliding objects and categories"] = function()
    local profile = { name = "completion-metadata-identity", kind = "postgres", options = { database = "orbit" } }
    local first = { schema = "a.b", name = "c", type = "table" }
    local second = { schema = "a", name = "b.c", type = "table" }
    local cases = {
      { row = first, category = "primary_keys", rows = {} },
      { row = second, category = "primary_keys", rows = { { name = "second_id", pk = 1 } } },
      { row = first, category = "indexes", rows = { { name = "first_index" } } },
      { row = second, category = "indexes", rows = { { name = "second_index" } } },
    }
    local original_run = runner.run
    local pending, results, cached = {}, {}, {}
    runner.run = function(received, statement, done)
      assert(received == profile)
      table.insert(pending, { statement = statement, done = done })
    end
    local ok, err = xpcall(function()
      for index, case in ipairs(cases) do
        cache.load_metadata(profile, case.row, case.category, {}, function(result, result_err)
          assert(result_err == nil)
          results[index] = result
        end)
      end
      local joined
      cache.load_metadata(profile, vim.deepcopy(first), "primary_keys", {}, function(result, result_err)
        assert(result_err == nil)
        joined = result
      end)
      assert(#pending == 4, "only the same object and category may share a statement")
      assert(next(results) == nil and joined == nil)
      assert(pending[1].statement:find("tc.table_schema = 'a.b'", 1, true))
      assert(pending[1].statement:find("tc.table_name = 'c'", 1, true))
      assert(pending[2].statement:find("tc.table_schema = 'a'", 1, true))
      assert(pending[2].statement:find("tc.table_name = 'b.c'", 1, true))
      assert(pending[3].statement:find("FROM pg_indexes", 1, true))
      assert(pending[3].statement:find("schemaname = 'a.b'", 1, true))
      assert(pending[3].statement:find("tablename = 'c'", 1, true))
      assert(pending[4].statement:find("schemaname = 'a'", 1, true))
      assert(pending[4].statement:find("tablename = 'b.c'", 1, true))
      for index, case in ipairs(cases) do
        pending[index].done(case.rows)
        assert(vim.deep_equal(results[index], case.rows))
        cache.load_metadata(profile, case.row, case.category, {}, function(result, result_err)
          assert(result_err == nil)
          cached[index] = result
        end)
      end
      assert(vim.deep_equal(joined, {}))
      assert(next(cached) == nil)
      assert(vim.wait(1000, function()
        return #cached == #cases
      end))
      for index, case in ipairs(cases) do
        assert(vim.deep_equal(cached[index], case.rows))
      end
      assert(#pending == 4, "cached metadata, including empty rows, must not run statements")
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

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
