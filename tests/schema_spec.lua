local schema = require("orbit.schema")
local cache = require("orbit.schema_cache")
local runner = require("orbit.runner")

return {
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
      cache.store_tables(profile.name, stale)
      local results = {}

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
      assert(vim.deep_equal(cache.tables(profile.name), fresh))
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
