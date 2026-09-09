local orbit = require("orbit")

return {
  ["Structure view options default to enabled"] = function()
    assert(orbit.config.structure_view.group_by_type == true)
    assert(orbit.config.structure_view.show_ddl == true)
    assert(orbit.config.structure_view.show_dml == true)
    assert(orbit.config.structure_view.show_other == true)
    assert(orbit.config.structure_view.show_select == true)
    assert(orbit.config.structure_view.sort_alphabetically == true)
  end,

  ["Structure icons have semantic defaults and support the legacy query key"] = function()
    assert(orbit.config.icons.clause == "󰅪")
    assert(orbit.config.icons.cte == "󰌷")
    assert(orbit.config.icons.query_block == "󰆋")
    assert(orbit.config.icons.schema == "")
    assert(orbit.config.icons.statement_ddl == "󰒓")
    assert(orbit.config.icons.statement_dml == "󰏫")
    assert(orbit.config.icons.statement_other == "󰌋")
    assert(orbit.config.icons.statement_select == "󰍉")
    assert(orbit.config.icons.with == "󰙅")

    local previous_query = orbit.config.icons.query
    local previous_query_block = orbit.config.icons.query_block
    local setup_ok = pcall(orbit.setup, {
      icons = { query_block = "not-applied" },
      saved_query_dirs = "invalid",
    })
    assert(not setup_ok)
    orbit.setup({ icons = { query = "legacy-query" } })
    assert(orbit.config.icons.query_block == "legacy-query")
    orbit.setup({ icons = { query = "legacy-query", query_block = "query-block" } })
    assert(orbit.config.icons.query_block == "query-block")
    orbit.setup({ icons = { query = "later-legacy-query" } })
    assert(orbit.config.icons.query_block == "query-block")
    orbit.setup({ icons = { query = previous_query, query_block = previous_query_block } })
  end,

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
