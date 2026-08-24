local results = require("quarry.results")
local workspace = require("quarry.workspace")
local grid = require("quarry.grid")

local function assert_equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

return {
  ["results.render bounds rows and formats cell values"] = function()
    local grid = results.render({
      { id = 1, note = vim.NIL },
      { id = 2, note = "a long value" },
      { id = 3, note = "unseen" },
    }, { limit = 2, max_cell_width = 9 })

    assert_equal(grid.columns, { "id", "note" })
    assert_equal(grid.rows, {
      { "1", "NULL" },
      { "2", "a long..." },
    })
    assert(grid.limited)
  end,

  ["results.render serializes structured values"] = function()
    local grid = results.render({ { metadata = { source = "trino" } } })

    assert(grid.rows[1][1] == '{"source":"trino"}')
  end,

  ["result grid geometry maps and moves logical cells"] = function()
    local model = grid.render({ { id = 1, name = "Quarry" }, { id = 22, name = "Q" } })
    local lines, widths = grid.layout(model, "local")

    assert(lines[2] == "| id | name   |")
    assert(vim.deep_equal(widths, { 2, 6 }))
    assert(vim.deep_equal(grid.cell_at(model, widths, 4, 2), { row = 1, column = 1 }))
    assert(vim.deep_equal(grid.move(model, widths, { row = 1, column = 1 }, 1, 1), { row = 2, column = 2 }))
    assert(vim.deep_equal(grid.cursor_for(widths, { row = 2, column = 2 }), { 5, 7 }))
  end,

  ["results.open reuses one result window per tabpage"] = function()
    local first = results.open({ { id = 1 } }, { height = 3 })
    local second = results.open({ { id = 2 } }, { height = 3 })

    assert(first.window == second.window)
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(second.window), { 4, 2 }))
    vim.api.nvim_win_close(second.window, true)
  end,

  ["results.open keeps column headers in the result grid"] = function()
    local opened = results.open({ { account_id = 1, account_name = "Quarry" } }, { height = 3 })

    assert(vim.wo[opened.window].winbar == "")
    assert(vim.api.nvim_buf_get_lines(opened.buffer, 1, 2, false)[1]:match("account_id"))

    vim.api.nvim_win_close(opened.window, true)
  end,

  ["results.open does not leave a listed placeholder buffer"] = function()
    local listed_before = {}
    for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
      listed_before[info.bufnr] = true
    end

    local opened = results.open({ { id = 1 } }, { height = 3 })

    for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
      assert(listed_before[info.bufnr], "result opening created a listed placeholder buffer")
    end
    vim.api.nvim_win_close(opened.window, true)
  end,

  ["workspace result grids return to the query window without closing"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local state = workspace.open({ profile_path = vim.fn.tempname(), workspace_result_ratio = 0.30 })
    local opened = workspace.open_results({ { id = 1 } }, {
      focus = true,
      source_window = state.query_window,
      tabpage = state.tabpage,
    })

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "mx", false)

    assert(vim.api.nvim_get_current_win() == state.query_window)
    assert(vim.api.nvim_win_is_valid(opened.window))
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,
}
