local schema = require("orbit.schema")
local cache = require("orbit.schema_cache")
local schema_tree = require("orbit.schema_tree")

-- Drives a load function through an ordinary acquisition followed by a
-- queued refresh. `load(options, callback)` receives options that already
-- carry the fake executor, so no real database process is ever started.
local function assert_queued_refresh(load, ordinary_rows, refreshed_rows, assert_cached)
  local callbacks = {}
  -- Fake executor: capture each statement's callback so the test decides
  -- when (and with which rows) every acquisition completes.
  local function execute(_, _, callback)
    callbacks[#callbacks + 1] = callback
  end

  local ordinary_result, refreshed_result
  load({ execute = execute }, function(rows)
    ordinary_result = rows
  end)
  load({ refresh = true, execute = execute }, function(rows)
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
end

return {
	["SQL Server schema acquisition keeps schema identity for tables and columns"] = function()
		local profile = { name = "mssql-schema", kind = "sqlserver", options = { host = "sql.example", database = "warehouse", user = "orbit" } }
		local statements = {}
		-- Fake executor: answers the first statement with a table and the
		-- second with a column, recording each statement for inspection.
		local function execute(received, statement, callback, connector)
			assert(received == profile and connector == require("orbit.connectors.sqlserver"))
			statements[#statements + 1] = statement
			if #statements == 1 then
				callback({ { schema = "sales", name = "orders", type = "table" } })
			else
				callback({ { name = "id", type = "bigint" } })
			end
		end
		local tables, columns
		cache.load_tables(profile, { execute = execute }, function(rows) tables = rows end)
		cache.load_columns(profile, { schema = "sales", name = "orders", type = "table" }, { execute = execute }, function(rows) columns = rows end)
		assert(tables[1].schema == "sales" and columns[1].name == "id")
		assert(statements[1]:find("sys.tables", 1, true))
		assert(statements[2]:find("schemas.name = 'sales'", 1, true))
	end,
	["schema acquisition accepts an arbitrary Connector-declared metadata category"] = function()
		local connector = require("orbit.connectors.sqlite")
		local original_categories = connector.metadata_categories
		local original_statement = connector.schema_statement
		connector.metadata_categories = function()
			return { { id = "triggers", label = "triggers", presentation = {} } }
		end
		connector.schema_statement = function(_, node)
			if node.type == "triggers" then return "SELECT name FROM sqlite_master WHERE type = 'trigger'" end
			return original_statement({}, node)
		end
		-- Fake executor: only the connector-declared trigger query may run.
		local function execute(_, statement, callback)
			assert(statement:match("sqlite_master"))
			callback({ { name = "audit_orders" } })
		end
		local ok, err = xpcall(function()
			local rows, acquisition_err
			cache.load_metadata({ name = "custom-metadata", kind = "sqlite", options = { path = ":memory:" } },
				{ schema = "main", name = "orders", type = "table" }, "triggers", { execute = execute }, function(result, result_err)
					rows, acquisition_err = result, result_err
				end)
			assert(vim.deep_equal(rows, { { name = "audit_orders" } }))
			assert(acquisition_err == nil)
		end, debug.traceback)
		-- The connector module is shared global state, so always restore it.
		connector.metadata_categories = original_categories
		connector.schema_statement = original_statement
		assert(ok, err)
	end,

  ["schema acquisition treats unsupported table metadata as empty"] = function()
    -- Fake executor: reaching it at all means the capability check failed.
    local function execute()
      error("unsupported metadata must not execute a statement")
    end

    local rows, acquisition_err
    cache.load_metadata({
      name = "trino-capabilities",
      kind = "trino",
      options = { catalog = "hive", server = "https://trino.example" },
    }, { catalog = "hive", schema = "default", name = "orders", type = "table" }, "primary_keys", { execute = execute }, function(result, result_err)
      rows, acquisition_err = result, result_err
    end)

    assert(vim.wait(20, function()
      return rows ~= nil or acquisition_err ~= nil
    end), "timed out waiting for unsupported metadata")
    assert(vim.deep_equal(rows, {}))
    assert(acquisition_err == nil)
  end,

  ["schema acquisition treats unsupported columns as empty"] = function()
    local connector = require("orbit.connectors.trino")
    local original_categories = connector.metadata_categories
    connector.metadata_categories = function()
      return {}
    end
    -- Fake executor: reaching it at all means the capability check failed.
    local function execute()
      error("unsupported columns must not execute a statement")
    end

    local ok, err = xpcall(function()
      local rows, acquisition_err
      cache.load_metadata({
        name = "trino-columns-capability",
        kind = "trino",
        options = { catalog = "hive", server = "https://trino.example" },
      }, { catalog = "hive", schema = "default", name = "orders", type = "table" }, "columns", { execute = execute }, function(result, result_err)
        rows, acquisition_err = result, result_err
      end)

      assert(vim.wait(20, function()
        return rows ~= nil or acquisition_err ~= nil
      end), "timed out waiting for unsupported columns")
      assert(vim.deep_equal(rows, {}))
      assert(acquisition_err == nil)
    end, debug.traceback)
    -- The connector module is shared global state, so always restore it.
    connector.metadata_categories = original_categories
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
    local callbacks = {}
    local runs = 0
    -- Fake executor: key each pending callback by database path so the test
    -- can complete the two profiles' loads in reverse order.
    local function execute(profile, _, callback)
      runs = runs + 1
      callbacks[profile.options.path] = callback
    end

    local first = { name = "identity-change", kind = "sqlite", options = { path = "/tmp/first.db" } }
    local second = { name = "identity-change", kind = "sqlite", options = { path = "/tmp/second.db" } }
    local first_rows, second_rows

    cache.load_tables(first, { execute = execute }, function(rows)
      first_rows = rows
    end)
    cache.load_tables(second, { execute = execute }, function(rows)
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
    cache.load_tables(third, { execute = execute }, function(_, acquisition_err)
      third_err = acquisition_err
    end)
    callbacks[third.options.path](nil, "unavailable")
    assert(third_err == "unavailable")
    assert(vim.deep_equal(cache.tables(third), {}))
  end,

  ["schema acquisition preserves refresh intent during an ordinary acquisition"] = function()
    local callbacks = {}
    -- Fake executor: capture callbacks so the test controls completion order.
    local function execute(_, _, callback)
      callbacks[#callbacks + 1] = callback
    end

    local profile = { name = "queued-refresh", kind = "sqlite", options = { path = "/tmp/refresh.db" } }
    local ordinary_rows, refreshed_rows, joined_refresh_rows, reentrant_refresh_rows
    cache.load_tables(profile, { execute = execute }, function(rows)
      ordinary_rows = rows
      cache.load_tables(profile, { refresh = true, execute = execute }, function(reentrant_rows)
        reentrant_refresh_rows = reentrant_rows
      end)
    end)
    cache.load_tables(profile, { refresh = true, execute = execute }, function(rows)
      refreshed_rows = rows
    end)
    cache.load_tables(profile, { refresh = true, execute = execute }, function(rows)
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
  end,

  ["schema acquisition preserves column refresh intent"] = function()
    local profile = { name = "column-refresh", kind = "sqlite", options = { path = "/tmp/columns.db" } }
    local row = { schema = "main", name = "orders", type = "table" }
    assert_queued_refresh(function(options, callback)
      cache.load_columns(profile, row, options, callback)
    end, { { name = "old_id", type = "INTEGER" } }, { { name = "id", type = "INTEGER" } }, function()
      assert(cache.columns(profile, row)[1].name == "id")
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
    local runs = 0
    -- Fake executor: answers immediately and counts how often it is reached.
    local function execute(profile, _, callback, connector)
      runs = runs + 1
			assert(connector == require("orbit.adapters").connector(profile))
      callback({ { name = "events", type = "table" } })
    end

    local profile = { name = "cache-lifecycle", kind = "sqlite", options = { path = "/tmp/cache.db" } }
    cache.load_tables(profile, { execute = execute }, function(rows)
      assert(rows[1].name == "events")
    end)
    cache.load_tables(profile, { execute = execute }, function(rows)
      assert(rows[1].name == "events")
    end)
    vim.wait(20)
    assert(runs == 1)

    cache.load_tables(profile, { refresh = true, execute = execute }, function(rows)
      assert(rows[1].name == "events")
    end)
    assert(runs == 2)
  end,

  ["schema cache joins a refresh and retains successful data after failure"] = function()
    local callback
    -- Fake executor: keep only the latest pending callback; each phase of
    -- the test completes the acquisition it just started.
    local function execute(_, _, next_callback)
      callback = next_callback
    end

    local profile = { name = "refresh-generation", kind = "sqlite", options = { path = "/tmp/refresh.db" } }
    local stale = { { name = "stale", type = "table" } }
    local fresh = { { name = "fresh", type = "table" } }
    local results = {}

    cache.load_tables(profile, { execute = execute }, function(rows, run_err)
      results.initial = { rows, run_err }
    end)
    assert(callback)
    callback(stale)
    assert(vim.deep_equal(results.initial[1], stale))

    cache.load_tables(profile, { refresh = true, execute = execute }, function(rows, run_err)
      results.refresh = { rows, run_err }
    end)
    cache.load_tables(profile, { execute = execute }, function(rows, run_err)
      results.normal = { rows, run_err }
    end)
    assert(callback)
    assert(results.normal == nil)
    callback(fresh)
    assert(vim.deep_equal(results.refresh[1], fresh))
    assert(vim.deep_equal(results.normal[1], fresh))

    cache.load_tables(profile, { refresh = true, execute = execute }, function(rows, run_err)
      results.failed = { rows, run_err }
    end)
    callback(nil, "unavailable")
    assert(results.failed[2] == "unavailable")
    assert(vim.deep_equal(cache.tables(profile), fresh))
  end,

  ["schema.group organizes objects under their schemas and kinds"] = function()
    local groups = schema.group({
      { schema = "analytics", name = "events", type = "table" },
      { schema = "analytics", name = "active_events", type = "view" },
      { schema = "staging", name = "imports", type = "table" },
    })

    local visible_groups = vim.tbl_map(function(group)
      return { name = group.name, tables = group.tables, views = group.views }
    end, groups)
    assert(vim.deep_equal(visible_groups, {
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

  ["schema.group separates colliding namespaces and keeps labels stable through filtering"] = function()
    local rows = {
      { catalog = "a.b", schema = "c", name = "first", type = "table" },
      { catalog = "a", schema = "b.c", name = "second", type = "view" },
      { schema = "public", name = "ordinary", type = "table" },
    }
    local groups = schema.group(rows)
    assert(#groups == 3, "distinct catalog/schema segments must not merge")
    assert(groups[1].name == '"a"."b.c"')
    assert(groups[1].views[1] == rows[2])
    assert(groups[2].name == '"a.b"."c"')
    assert(groups[2].tables[1] == rows[1])
    assert(groups[3].name == "public")
    assert(groups[1].key ~= groups[2].key)

    local filtered = schema.group(rows, "FIRST")
    assert(#filtered == 1 and filtered[1].name == '"a.b"."c"')
    assert(filtered[1].key == groups[2].key)
    assert(#schema.group(rows, "a.b.c") == 2, "ordinary dotted search must still work")
    assert(#schema.group(rows, "missing") == 0)
  end,

  ["schema identity remains fast for large Trino schema snapshots"] = function()
    local rows = {}
    for schema_index = 1, 100 do
      for object_index = 1, 1000 do
        table.insert(rows, {
          catalog = "hive",
          schema = "schema_" .. schema_index,
          name = "table_" .. object_index,
          type = "table",
        })
      end
    end

    local started_at = vim.uv.hrtime()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, rows)
    local lines = schema_tree.lines(tree, {
      kind = "trino",
      name = "large-trino-schema",
      options = { catalog = "hive" },
    }, "", {
      icons = { collapsed = ">", column = "C", expanded = "v", folder = "F", result = "R", schema = "S", table = "T", view = "V" },
    })
    local elapsed_ms = (vim.uv.hrtime() - started_at) / 1e6

    assert(#lines == 100)
    assert(elapsed_ms < 500, string.format("grouping 100,000 Trino objects took %.0fms", elapsed_ms))
  end,
}
