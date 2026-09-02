local orbit = require("orbit")

return {
  ["setup normalizes and replaces named saved query locations"] = function()
    local root = vim.fn.getcwd()
    orbit.setup({
      saved_query_dirs = {
        { Work = "queries/work" },
        { Personal = "~/queries/personal" },
      },
    })

    assert(#orbit.config.saved_query_dirs == 2)
    assert(orbit.config.saved_query_dirs[1].name == "Work")
    assert(orbit.config.saved_query_dirs[1].path == root .. "/queries/work")
    assert(orbit.config.saved_query_dirs[2].name == "Personal")
    assert(orbit.config.saved_query_dirs[2].path == vim.fn.expand("~/queries/personal"))

    orbit.setup({ saved_query_dirs = { { Archive = "queries/archive" } } })
    assert(#orbit.config.saved_query_dirs == 1)
    assert(orbit.config.saved_query_dirs[1].name == "Archive")
  end,

  ["setup rejects malformed or duplicate saved query locations"] = function()
    local invalid = {
      { value = "queries", message = "must be an array" },
      { value = { "queries" }, message = "must be an object" },
      { value = { {} }, message = "must contain one" },
      { value = { { Work = "one", Personal = "two" } }, message = "must contain one" },
      { value = { { [1] = "one" } }, message = "non%-empty string name and path" },
      { value = { { Work = "one" }, { Work = "two" } }, message = "duplicate name" },
      { value = { { Work = "queries" }, { Personal = "./queries" } }, message = "duplicate path" },
      { value = { { Work = "queries/work" }, { Personal = "queries/archive/../work" } }, message = "duplicate path" },
    }

    for _, case in ipairs(invalid) do
      local ok, err = pcall(orbit.setup, { saved_query_dirs = case.value })
      assert(not ok)
      assert(tostring(err):match(case.message), err)
    end

    local ok, err = pcall(orbit.setup, { saved_query_dir = "queries" })
    assert(not ok)
    assert(tostring(err):match("saved_query_dir was removed"), err)
  end,
}
