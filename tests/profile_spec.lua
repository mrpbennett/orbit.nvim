local adapters = require("orbit.adapters")
local profiles = require("orbit.profiles")
local query = require("orbit.query")

local function write_profiles(document)
  local path = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(document) }, path)
  assert(vim.uv.fs_chmod(path, 384))
  return path
end

local function assert_equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
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

  ["adapters.prepare builds an interactive Trino command"] = function()
    local command = assert(adapters.prepare({
      kind = "trino",
      options = {
        server = "https://trino.example.test:8443",
        user = "orbit",
        catalog = "hive",
        schema = "default",
      },
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

  ["adapters.prepare builds a JSON SQLite command"] = function()
    local command = assert(adapters.prepare({
      kind = "sqlite",
      options = { path = "/tmp/local.db" },
    }, "SELECT 1"))

    assert_equal(command, { "sqlite3", "-json", "/tmp/local.db", "SELECT 1" })
  end,

  ["adapters.parse accepts JSON arrays and JSON lines"] = function()
    local array = assert(adapters.parse('[{"id":1}]'))
    local lines = assert(adapters.parse('{"id":1}\n{"id":2}\n'))

    assert_equal(array, { { id = 1 } })
    assert_equal(lines, { { id = 1 }, { id = 2 } })
  end,

  ["adapters build backend-specific schema statements"] = function()
    local statement = assert(adapters.schema_statement({
      kind = "trino",
      options = { catalog = "hive", schema = "default" },
    }, { type = "columns", name = "events" }))

    assert(statement:match("information_schema%.columns"))
    assert(statement:match("table_name = 'events'"))
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
    local statement = assert(adapters.schema_statement({
      kind = "trino",
      options = { catalog = "gridhive" },
    }, { type = "tables" }))

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

    loaded, err = invalid_options({ confirm_mutations = "false" })
    assert(loaded == nil)
    assert(err:match("options.confirm_mutations must be a boolean"))
  end,
}
