local schema = require("orbit.schema")
local cache = require("orbit.schema_cache")
local runner = require("orbit.runner")

local function assert_queued_refresh(load, ordinary_rows, refreshed_rows, assert_cached)
  local original_run = runner.run
  local callbacks = {}
  runner.run = function(_, _, callback)
    callbacks[#callbacks + 1] = callback
  end

  local ok, err = xpcall(function()
    local ordinary_result, refreshed_result
    load({}, function(rows)
      ordinary_result = rows
    end)
    load({ refresh = true }, function(rows)
      refreshed_result = rows
    end)

    assert(#callbacks == 1)
    callbacks[1](ordinary_rows)
    assert(vim.deep_equal(ordinary_result, ordinary_rows))
    assert(refreshed_result == nil)
    assert(#callbacks == 2)

    callbacks[2](refreshed_rows)
    assert(vim.deep_equal(refreshed_result, refreshed_rows))
    assert_cached()
  end, debug.traceback)
  runner.run = original_run
  assert(ok, err)
end

return {
  ["schema acquisition treats unsupported table metadata as empty"] = function()
    local original_run = runner.run
    runner.run = function()
      error("unsupported metadata must not execute a statement")
    end

    local ok, err = xpcall(function()
      local rows, acquisition_err
      cache.load_metadata({
        name = "trino-capabilities",
        kind = "trino",
        options = { catalog = "hive", server = "https://trino.example" },
      }, { catalog = "hive", schema = "default", name = "orders", type = "table" }, "primary_keys", {}, function(result, result_err)
        rows, acquisition_err = result, result_err
      end)

      assert(vim.wait(20, function()
        return rows ~= nil or acquisition_err ~= nil
      end), "timed out waiting for unsupported metadata")
      assert(vim.deep_equal(rows, {}))
      assert(acquisition_err == nil)
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

  ["schema acquisition treats unsupported columns as empty"] = function()
    local connector = require("orbit.connectors.trino")
    local original_categories = connector.metadata_categories
    local original_run = runner.run
    connector.metadata_categories = function()
      return {}
    end
    runner.run = function()
      error("unsupported columns must not execute a statement")
    end

    local ok, err = xpcall(function()
      local rows, acquisition_err
      cache.load_metadata({
        name = "trino-columns-capability",
        kind = "trino",
        options = { catalog = "hive", server = "https://trino.example" },
      }, { catalog = "hive", schema = "default", name = "orders", type = "table" }, "columns", {}, function(result, result_err)
        rows, acquisition_err = result, result_err
      end)

      assert(vim.wait(20, function()
        return rows ~= nil or acquisition_err ~= nil
      end), "timed out waiting for unsupported columns")
      assert(vim.deep_equal(rows, {}))
      assert(acquisition_err == nil)
    end, debug.traceback)
    connector.metadata_categories = original_categories
    runner.run = original_run
    assert(ok, err)
  end,

  ["schema acquisition rejects unknown table metadata"] = function()
    local acquisition_err
    cache.load_metadata({
      name = "unknown-metadata",
      kind = "sqlite",
      options = { path = ":memory:" },
    }, { schema = "main", name = "orders", type = "table" }, "triggers", {}, function(_, err)
      acquisition_err = err
    end)

    assert(vim.wait(20, function()
      return acquisition_err ~= nil
    end), "timed out waiting for unknown metadata")
    assert(acquisition_err == "unknown table metadata category: triggers")
  end,

  ["schema acquisition isolates in-flight connection-profile identities"] = function()
    local original_run = runner.run
    local callbacks = {}
    local runs = 0
    runner.run = function(profile, _, callback)
      runs = runs + 1
      callbacks[profile.options.path] = callback
    end

    local ok, err = xpcall(function()
      local first = { name = "identity-change", kind = "sqlite", options = { path = "/tmp/first.db" } }
      local second = { name = "identity-change", kind = "sqlite", options = { path = "/tmp/second.db" } }
      local first_rows, second_rows

      cache.load_tables(first, {}, function(rows)
        first_rows = rows
      end)
      cache.load_tables(second, {}, function(rows)
        second_rows = rows
      end)

      assert(runs == 2)
      callbacks[second.options.path]({ { name = "second", type = "table" } })
      callbacks[first.options.path]({ { name = "first", type = "table" } })

      assert(first_rows[1].name == "first")
      assert(second_rows[1].name == "second")
      assert(cache.tables(second)[1].name == "second")

      local third = { name = "identity-change", kind = "sqlite", options = { path = "/tmp/third.db" } }
      local third_err
      cache.load_tables(third, {}, function(_, acquisition_err)
        third_err = acquisition_err
      end)
      callbacks[third.options.path](nil, "unavailable")
      assert(third_err == "unavailable")
      assert(vim.deep_equal(cache.tables(third), {}))
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

  ["schema acquisition preserves refresh intent during an ordinary acquisition"] = function()
    local original_run = runner.run
    local callbacks = {}
    runner.run = function(_, _, callback)
      callbacks[#callbacks + 1] = callback
    end

    local ok, err = xpcall(function()
      local profile = { name = "queued-refresh", kind = "sqlite", options = { path = "/tmp/refresh.db" } }
      local ordinary_rows, refreshed_rows, joined_refresh_rows, reentrant_refresh_rows
      cache.load_tables(profile, {}, function(rows)
        ordinary_rows = rows
        cache.load_tables(profile, { refresh = true }, function(reentrant_rows)
          reentrant_refresh_rows = reentrant_rows
        end)
      end)
      cache.load_tables(profile, { refresh = true }, function(rows)
        refreshed_rows = rows
      end)
      cache.load_tables(profile, { refresh = true }, function(rows)
        joined_refresh_rows = rows
      end)

      assert(#callbacks == 1)
      callbacks[1]({ { name = "ordinary", type = "table" } })
      assert(ordinary_rows[1].name == "ordinary")
      assert(refreshed_rows == nil)
      assert(#callbacks == 2)

      callbacks[2]({ { name = "refreshed", type = "table" } })
      assert(refreshed_rows[1].name == "refreshed")
      assert(joined_refresh_rows[1].name == "refreshed")
      assert(reentrant_refresh_rows[1].name == "refreshed")
      assert(cache.tables(profile)[1].name == "refreshed")
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

  ["schema acquisition preserves column refresh intent"] = function()
    local profile = { name = "column-refresh", kind = "sqlite", options = { path = "/tmp/columns.db" } }
    local row = { schema = "main", name = "orders", type = "table" }
    assert_queued_refresh(function(options, callback)
      cache.load_columns(profile, row, options, callback)
    end, { { name = "old_id", type = "INTEGER" } }, { { name = "id", type = "INTEGER" } }, function()
      assert(cache.columns(profile, "main.orders")[1].name == "id")
    end)
  end,

  ["schema acquisition preserves table metadata refresh intent"] = function()
    local profile = { name = "metadata-refresh", kind = "sqlite", options = { path = "/tmp/metadata.db" } }
    local row = { schema = "main", name = "orders", type = "table" }
    assert_queued_refresh(function(options, callback)
      cache.load_metadata(profile, row, "primary_keys", options, callback)
    end, { { name = "old_id" } }, { { name = "id" } }, function()
      local cached_rows
      cache.load_metadata(profile, row, "primary_keys", {}, function(rows)
        cached_rows = rows
      end)
      assert(vim.wait(20, function()
        return cached_rows ~= nil
      end), "timed out waiting for cached metadata")
      assert(cached_rows[1].name == "id")
    end)
  end,

  ["schema.filter matches table and view names case-insensitively"] = function()
    local matches = schema.filter({
      { name = "user_settings", type = "table" },
      { name = "AuditLog", type = "view" },
    }, "audit")

    assert(vim.deep_equal(matches, { { name = "AuditLog", type = "view" } }))
  end,

  ["schema cache shares acquisition until an explicit refresh"] = function()
    local original_run = runner.run
    local runs = 0
    runner.run = function(profile, _, callback, connector)
      runs = runs + 1
			assert(connector == require("orbit.adapters").connector(profile))
      callback({ { name = "events", type = "table" } })
    end

    local ok, err = xpcall(function()
      local profile = { name = "cache-lifecycle", kind = "sqlite", options = { path = "/tmp/cache.db" } }
      cache.load_tables(profile, {}, function(rows)
        assert(rows[1].name == "events")
      end)
      cache.load_tables(profile, {}, function(rows)
        assert(rows[1].name == "events")
      end)
      vim.wait(20)
      assert(runs == 1)

      cache.load_tables(profile, { refresh = true }, function(rows)
        assert(rows[1].name == "events")
      end)
      assert(runs == 2)
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

  ["schema cache joins a refresh and retains successful data after failure"] = function()
    local original_run = runner.run
    local callback
    runner.run = function(_, _, next_callback)
      callback = next_callback
    end

    local ok, err = xpcall(function()
      local profile = { name = "refresh-generation", kind = "sqlite", options = { path = "/tmp/refresh.db" } }
      local stale = { { name = "stale", type = "table" } }
      local fresh = { { name = "fresh", type = "table" } }
      local results = {}

      cache.load_tables(profile, {}, function(rows, run_err)
        results.initial = { rows, run_err }
      end)
      assert(callback)
      callback(stale)
      assert(vim.deep_equal(results.initial[1], stale))

      cache.load_tables(profile, { refresh = true }, function(rows, run_err)
        results.refresh = { rows, run_err }
      end)
      cache.load_tables(profile, {}, function(rows, run_err)
        results.normal = { rows, run_err }
      end)
      assert(callback)
      assert(results.normal == nil)
      callback(fresh)
      assert(vim.deep_equal(results.refresh[1], fresh))
      assert(vim.deep_equal(results.normal[1], fresh))

      cache.load_tables(profile, { refresh = true }, function(rows, run_err)
        results.failed = { rows, run_err }
      end)
      callback(nil, "unavailable")
      assert(results.failed[2] == "unavailable")
      assert(vim.deep_equal(cache.tables(profile), fresh))
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

  ["schema.group organizes objects under their schemas and kinds"] = function()
    local groups = schema.group({
      { schema = "analytics", name = "events", type = "table" },
      { schema = "analytics", name = "active_events", type = "view" },
      { schema = "staging", name = "imports", type = "table" },
    })

    assert(vim.deep_equal(groups, {
      {
        name = "analytics",
        tables = { { schema = "analytics", name = "events", type = "table" } },
        views = { { schema = "analytics", name = "active_events", type = "view" } },
      },
      {
        name = "staging",
        tables = { { schema = "staging", name = "imports", type = "table" } },
        views = {},
      },
    }))
  end,
}
