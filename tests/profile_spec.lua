local adapters = require("orbit.adapters")
local profiles = require("orbit.profiles")
local query = require("orbit.query")
local runner = require("orbit.runner")

local function write_profiles(document)
  local path = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(document) }, path)
  assert(vim.uv.fs_chmod(path, 384))
  return path
end

local function assert_equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function connector(kind)
  return assert(adapters.connector({ kind = kind }))
end

return {
  ["profiles.load returns validated profiles"] = function()
    local path = write_profiles({
      version = 1,
      profiles = {
        {
          name = "analytics",
          kind = "trino",
          options = {
            server = "https://trino.example.test:8443",
            user = "orbit",
            catalog = "hive",
            schema = "default",
            schema_patterns = { hive = { "default", "reporting" } },
          },
        },
        {
          name = "local",
          kind = "sqlite",
          options = { path = "/tmp/local.db" },
        },
      },
    })

    local loaded = assert(profiles.load(path))

    assert_equal(loaded.profiles[1].name, "analytics")
    assert_equal(loaded.profiles[2].kind, "sqlite")
  end,

  ["adapters resolve supported connector kinds and reject unknown kinds"] = function()
    assert(adapters.connector({ kind = "sqlite" }) == connector("sqlite"))
    assert(adapters.connector({ kind = "postgres" }) == connector("postgres"))
    assert(adapters.connector({ kind = "trino" }) == connector("trino"))
    assert(adapters.connector({ kind = "vertica" }) == connector("vertica"))
    local unknown, err = adapters.connector({ kind = "unknown" })
    assert(unknown == nil)
    assert(err == "unsupported profile kind: unknown")
  end,

	["runner reports an unsupported profile kind"] = function()
		local run_err
		runner.run({ kind = "unknown", options = {} }, "SELECT 1", function(_, err)
			run_err = err
		end)
		assert(vim.wait(100, function()
			return run_err ~= nil
		end))
		assert(run_err == "unsupported profile kind: unknown")
	end,

  ["profiles.load rejects removed Trino HTTP transport options"] = function()
    for name, value in pairs({ transport = "http", password_env = "ANALYTICS_TRINO_PASSWORD" }) do
      local path = write_profiles({
        version = 1,
        profiles = {
          {
            name = "analytics",
            kind = "trino",
            options = vim.tbl_extend("force", {
              server = "https://trino.example.test:8443",
              user = "orbit",
              catalog = "hive",
            }, { [name] = value }),
          },
        },
      })

      local loaded, err = profiles.load(path)
      assert(loaded == nil)
      assert(err:match("unsupported Trino option"))
    end
  end,

  ["profiles.find resolves an exact connection profile name"] = function()
    local document = {
      profiles = {
        { name = "analytics", kind = "trino", options = {} },
        { name = "local", kind = "sqlite", options = {} },
      },
    }

    assert(profiles.find(document, "local") == document.profiles[2])
    assert(profiles.find(document, "Local") == nil)
    assert(profiles.find(document, "missing") == nil)
  end,

  ["profiles.load rejects unsupported versions"] = function()
    local path = write_profiles({ version = 2, profiles = {} })
    local loaded, err = profiles.load(path)

    assert(loaded == nil)
    assert(err:match("unsupported profile file version"))
  end,

  ["profiles.load requires a profiles array"] = function()
    local path = write_profiles({ version = 1, profiles = { analytics = {} } })
    local loaded, err = profiles.load(path)

    assert(loaded == nil)
    assert(err:match("profiles array"))
  end,

  ["profiles.load rejects profile files readable by other users"] = function()
    local path = write_profiles({ version = 1, profiles = {} })
    assert(vim.uv.fs_chmod(path, 420))

    local loaded, err = profiles.load(path)

    assert(loaded == nil)
    assert(err:match("owner%-only"))
  end,

  ["unbound query buffers require an explicit profile"] = function()
    local path = vim.fn.tempname()
    assert(profiles.write(path, { version = 1, profiles = {} }))
    local buffer = vim.api.nvim_create_buf(false, true)

    local profile, err = query.profile_for_buffer(buffer, { profile_path = path })

    assert(profile == nil)
    assert(err:match("select a connection profile"))
  end,

  ["bound query buffers resolve their connection profile"] = function()
    local path = write_profiles({
      version = 1,
      profiles = { { name = "local", kind = "sqlite", options = { path = "/tmp/local.db" } } },
    })
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.b[buffer].orbit_profile = "local"

    local profile = assert(query.profile_for_buffer(buffer, { profile_path = path }))

    assert(profile.name == "local")
  end,

  ["profiles.write creates an owner-only profile file"] = function()
    local directory = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(directory, 448))
    local path = directory .. "/profiles.json"

    assert(profiles.write(path, { version = 1, profiles = {} }))

    local stat = assert(vim.uv.fs_stat(path))
    assert(bit.band(stat.mode, 511) == 384, "profile file must use mode 0600")
    assert(profiles.load(path))
  end,

  ["Trino connector builds an interactive command"] = function()
    local command = assert(connector("trino").prepare({
        server = "https://trino.example.test:8443",
        user = "orbit",
        catalog = "hive",
        schema = "default",
		}, "SELECT 1"))

    assert_equal(command, {
      "trino",
      "--server", "https://trino.example.test:8443",
      "--user", "orbit",
      "--catalog", "hive",
      "--schema", "default",
      "--no-progress",
      "--output-format", "JSON",
      "--execute", "SELECT 1",
    })
  end,

  ["connectors own object naming"] = function()
    local sqlite = connector("sqlite")
    local postgres = connector("postgres")
    local trino = connector("trino")

    assert(sqlite.qualified_name({}, { name = 'a"b' }) == '"a""b"')
    assert(sqlite.completion_word({}, { name = "sessions" }, "") == "sessions")

    assert(postgres.qualified_name({}, { schema = "Sales", name = 'Order"Item' }) == '"Sales"."Order""Item"')
    assert(postgres.completion_word({}, { schema = "Sales", name = "Order" }, '"Sales".') == '"Sales"."Order"')

    assert(trino.qualified_name({}, { catalog = "iceberg", schema = "cleanroom", name = "events" }) == '"iceberg"."cleanroom"."events"')
    assert(trino.completion_word({ catalog = "hive", schema = "default" }, { catalog = "hive", schema = "default", name = "events" }, "") == "default.events")
    assert(trino.completion_word({ catalog = "hive" }, { catalog = "iceberg", schema = "cleanroom", name = "events" }, "") == "iceberg.cleanroom.events")
    assert(trino.completion_word({}, { name = "events" }, "cleanroom.") == "cleanroom.events")
  end,

	["SQLite connector builds a JSON command"] = function()
		local command = assert(connector("sqlite").prepare({ path = "/tmp/local.db" }, "SELECT 1"))

    assert_equal(command, { "sqlite3", "-json", "/tmp/local.db", "SELECT 1" })
	end,

	["PostgreSQL connector builds a CSV command"] = function()
		local command = assert(connector("postgres").prepare({
				database = "orbit",
				host = "postgres.example.test",
				port = 5432,
				user = "alice",
				sslmode = "require",
			}, "SELECT 1"))

		assert_equal(command, {
			"psql",
			"--dbname", "orbit",
			"--host", "postgres.example.test",
			"--port", "5432",
			"--username", "alice",
			"--csv",
			"--no-psqlrc",
			"--pset", "footer=off",
			"--set", "ON_ERROR_STOP=on",
			"--command", "SELECT 1",
		})
	end,

	["PostgreSQL profiles pass passwords only through the process environment"] = function()
		local postgres = connector("postgres")
		local environment = postgres.environment({ database = "orbit", password = "secret" })
		assert_equal(environment, { PGPASSWORD = "secret" })
		assert(not vim.inspect(assert(postgres.prepare({ database = "orbit", password = "secret" }, "SELECT 1"))):match("secret"))
	end,

  ["PostgreSQL CSV output is normalized into rows"] = function()
		local rows = assert(connector("postgres").parse('id,name,note,missing,empty\n1,Alice,"hello, world",,""\n2,Bob,"two\nlines",,""\n'))
		assert_equal(rows, {
			{ id = "1", name = "Alice", note = "hello, world", missing = vim.NIL, empty = "" },
			{ id = "2", name = "Bob", note = "two\nlines", missing = vim.NIL, empty = "" },
		})
	end,

  ["adapters.parse accepts JSON arrays and JSON lines"] = function()
    local array = assert(adapters.parse('[{"id":1}]'))
    local lines = assert(adapters.parse('{"id":1}\n{"id":2}\n'))

    assert_equal(array, { { id = 1 } })
    assert_equal(lines, { { id = 1 }, { id = 2 } })
  end,

  ["Vertica connector builds secure vsql commands and parses HTML output"] = function()
    local vertica = connector("vertica")
    local options = {
      database = "warehouse",
      host = "vertica.example.test",
      port = 5433,
      user = "alice",
      password = "secret",
      sslmode = "require",
    }

    assert_equal(vertica.prepare(options, "SELECT 1"), {
      "vsql", "--dbname", "warehouse", "--host", "vertica.example.test", "--username", "alice",
      "--port", "5433", "--sslmode", "require", "--html", "--quiet", "--pset", "footer=off",
      "--pset", "null=__ORBIT_NULL__", "--command", "SELECT 1",
    })
    assert_equal(vertica.environment(options), { VSQL_PASSWORD = "secret" })
    assert(not vim.inspect(vertica.prepare(options, "SELECT 1")):match("secret"))
    assert_equal(vertica.parse([[<table border="1">
<tr><th>name</th><th>note</th><th>missing</th></tr>
<tr><td>Ada &amp; Bob</td><td>&lt;line&gt;&#10;next</td><td>__ORBIT_NULL__</td></tr>
</table>]]), {
      { name = "Ada & Bob", note = "<line>\nnext", missing = vim.NIL },
    })
    assert(vertica.session_output("<table><tr><td>one</td></tr></table><table><tr><td>__orbit_marker__</td></tr></table>", "__orbit_marker__") == "<table><tr><td>one</td></tr></table>")
  end,

  ["Vertica profiles require connection coordinates and expose catalog metadata"] = function()
    local missing = write_profiles({
      version = 1,
      profiles = { { name = "warehouse", kind = "vertica", options = { database = "warehouse", host = "vertica.example.test" } } },
    })
    local loaded, err = profiles.load(missing)
    assert(loaded == nil)
    assert(err:match("options.user"))

    local vertica = connector("vertica")
    local options = { database = "warehouse", host = "vertica.example.test", user = "alice" }
    local tables = vertica.schema_statement(vim.tbl_extend("force", options, { schema_patterns = { "sales" } }), { type = "tables" })
    assert(select(2, tables:gsub("table_schema IN", "")) == 2)
    assert(vertica.schema_statement(options, { type = "primary_keys", name = "orders", schema = "sales" }):match("v_catalog%.primary_keys"))
    assert(vertica.schema_statement(options, { type = "foreign_keys", name = "orders", schema = "sales" }):match("reference_column_name AS \"to\""))
    assert(vertica.schema_statement(options, { type = "projections", name = "orders", schema = "sales" }):match("v_catalog%.projections"))
    assert(vim.deep_equal(vertica.metadata_categories(options, { type = "table" }), {
      { id = "columns", label = "columns" },
      { id = "primary_keys", label = "primary keys" },
      { id = "foreign_keys", label = "foreign keys" },
      { id = "projections", label = "projections" },
    }))
    local actions = vertica.object_actions(options, { type = "view", schema = "sales", name = "monthly_orders" }, 25)
    assert(actions[#actions].id == "definition")
    assert(actions[#actions].statement:match("v_catalog%.views"))
  end,

  ["Trino connector builds schema statements"] = function()
    local statement = assert(connector("trino").schema_statement({ catalog = "hive", schema = "default" }, { type = "columns", name = "events" }))

    assert(statement:match("information_schema%.columns"))
    assert(statement:match("table_name = 'events'"))
  end,

  ["schema_patterns limit relational schema discovery"] = function()
		local trino = assert(connector("trino").schema_statement({ catalog = "gridhive", schema_patterns = { gridhive = { "cleanroom", "report" }, iceberg = {} } }, { type = "tables" }))
		local postgres = assert(connector("postgres").schema_statement({ database = "orbit", schema_patterns = { "app" } }, { type = "tables" }))
		local sqlite = assert(connector("sqlite").schema_statement({ path = "/tmp/local.db", schema_patterns = { "other" } }, { type = "tables" }))

    assert(trino:match('FROM "gridhive"%.information_schema%.tables'))
    assert(trino:match("table_schema IN %('cleanroom', 'report'%)"))
    assert(trino:match('FROM "iceberg"%.information_schema%.tables'))
    assert(postgres:match("table_schema IN %('app'%)"))
    assert(sqlite:match("WHERE 1 = 0"))
  end,

  ["connectors expose schema object actions"] = function()
    local sqlite_actions = assert(connector("sqlite").object_actions({ path = "/tmp/local.db" }, { schema = "main", name = "sessions", type = "table" }, 25))
    local action_ids = {}
    for _, action in ipairs(sqlite_actions) do
      action_ids[action.id] = action
    end

    assert(action_ids.sample.kind == "query_buffer")
    assert(action_ids.sample.statement:match('FROM "sessions"'))
    assert(action_ids.columns.statement:match("PRAGMA table_info"))
    assert(action_ids.primary_keys.statement:match("pragma_table_info"))
    assert(action_ids.indexes.statement:match("PRAGMA index_list"))
    assert(action_ids.foreign_keys.statement:match("PRAGMA foreign_key_list"))
    assert(action_ids.definition.statement:match("sqlite_master"))

		local trino_actions = assert(connector("trino").object_actions({ catalog = "hive", schema = "analytics" }, { schema = "analytics", name = "events", type = "table" }, 25))

    assert(#trino_actions == 2)
    assert(trino_actions[1].id == "sample")
    assert(trino_actions[2].id == "columns")
    assert(trino_actions[2].statement:match("information_schema%.columns"))

		local cross_catalog_actions = assert(connector("trino").object_actions({ catalog = "hive" }, { catalog = "iceberg", schema = "cleanroom", name = "events", type = "table" }, 25))
    assert(cross_catalog_actions[1].statement:match('FROM "iceberg"%."cleanroom"%."events"'))
    assert(cross_catalog_actions[2].statement:match('FROM "iceberg"%.information_schema%.columns'))
  end,

	["connectors expose metadata categories by object kind"] = function()
    local sqlite_categories = connector("sqlite").metadata_categories({ path = "/tmp/local.db" }, { type = "table" })
    local view_categories = connector("sqlite").metadata_categories({ path = "/tmp/local.db" }, { type = "view" })
		local trino_categories = connector("trino").metadata_categories({ catalog = "hive" }, { type = "table" })
		local postgres_categories = connector("postgres").metadata_categories({ database = "orbit" }, { type = "table" })

    assert(vim.deep_equal(sqlite_categories, {
      { id = "columns", label = "columns" },
      { id = "primary_keys", label = "primary keys" },
      { id = "foreign_keys", label = "foreign keys" },
      { id = "indexes", label = "indexes" },
    }))
    assert(vim.deep_equal(view_categories, { { id = "columns", label = "columns" } }))
		assert(vim.deep_equal(trino_categories, { { id = "columns", label = "columns" } }))
		assert(vim.deep_equal(postgres_categories, {
			{ id = "columns", label = "columns" },
			{ id = "primary_keys", label = "primary keys" },
			{ id = "foreign_keys", label = "foreign keys" },
			{ id = "indexes", label = "indexes" },
		}))
	end,

	["PostgreSQL profiles validate required and connector-specific options"] = function()
		local missing_path = write_profiles({
			version = 1,
			profiles = { { name = "local", kind = "postgres", options = {} } },
		})
		local loaded, err = profiles.load(missing_path)
		assert(loaded == nil)
		assert(err:match("options.database"))

		local invalid_path = write_profiles({
			version = 1,
			profiles = { { name = "local", kind = "postgres", options = { database = "orbit", port = "5432" } } },
		})
		loaded, err = profiles.load(invalid_path)
		assert(loaded == nil)
		assert(err:match("options.port"))
	end,

	["PostgreSQL schema statements use shared metadata fields and ordered foreign keys"] = function()
		local primary_keys = assert(connector("postgres").schema_statement({ database = "orbit" }, {
			type = "primary_keys",
			name = "orders",
			schema = "app",
		}))
		local foreign_keys = assert(connector("postgres").schema_statement({ database = "orbit" }, {
			type = "foreign_keys",
			name = "orders",
			schema = "app",
		}))
		assert(primary_keys:match("ordinal_position AS pk"))
		assert(foreign_keys:match('AS "from"'))
		assert(foreign_keys:match('AS "table"'))
		assert(foreign_keys:match('AS "to"'))
		assert(foreign_keys:match("WITH ORDINALITY"))
		assert(foreign_keys:match("target_key%.position = source_key%.position"))
	end,

  ["profiles.load accepts a catalog-level Trino profile"] = function()
    local path = write_profiles({
      version = 1,
      profiles = {
        {
          name = "gridhive",
          kind = "trino",
          options = {
            server = "https://trino.example.test:8443",
            user = "orbit",
            catalog = "gridhive",
          },
        },
      },
    })

    assert(profiles.load(path))
  end,

  ["Trino catalog discovery does not force a schema"] = function()
    local statement = assert(connector("trino").schema_statement({ catalog = "gridhive" }, { type = "tables" }))

    assert(statement:match("table_catalog = 'gridhive'"))
    assert(not statement:match("table_schema ="))
  end,

  ["profiles.load validates backend-specific option names and values"] = function()
    local function invalid_options(options)
      local path = write_profiles({
        version = 1,
        profiles = {
          {
            name = "analytics",
            kind = "trino",
            options = vim.tbl_extend("force", {
              server = "https://trino.example.test:8443",
              user = "orbit",
              catalog = "hive",
            }, options),
          },
        },
      })
      return profiles.load(path)
    end

    local loaded, err = invalid_options({ unknown = true })
    assert(loaded == nil)
    assert(err:match("unsupported Trino option"))

    loaded, err = invalid_options({ schema = 1 })
    assert(loaded == nil)
    assert(err:match("options.schema must be a string"))

    loaded, err = invalid_options({ schema_patterns = { hive = { "" } } })
    assert(loaded == nil)
    assert(err:match("options.schema_patterns must contain non%-empty schema names"))

    loaded, err = invalid_options({ confirm_mutations = "false" })
    assert(loaded == nil)
    assert(err:match("options.confirm_mutations must be a boolean"))
  end,

	["SQLite connector generates primary-key mutations in one transaction"] = function()
		local statement = assert(connector("sqlite").mutation_statement({}, {
      name = "users",
      primary_keys = { "id" },
    }, {
      deleted = { { original = { id = "2" } } },
      inserted = { { values = { name = "Ada" } } },
      modified = { { original = { id = "1", name = "Alice" }, values = { id = "1", name = "Ada" } } },
    }))

    assert(statement:match("BEGIN IMMEDIATE"))
    assert(statement:match('DELETE FROM "users" WHERE "id" = \'2\''))
    assert(statement:match('UPDATE "users" SET "name" = \'Ada\' WHERE "id" = \'1\''))
    assert(statement:match('INSERT INTO "users" %("name"%) VALUES %(\'Ada\'%)'))
    assert(statement:match("COMMIT"))
  end,
}
