local structure = require("orbit.structure")

local function line_number(buffer, text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line:find(text, 1, true) then
      return index
    end
  end
end

local function node_line(state, kind, label)
  for line, selected in pairs(state.nodes) do
    if selected.node.kind == kind and (not label or selected.node.label == label) then
      return line
    end
  end
end

return {
  ["Structure panel renders and navigates to statements"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_window = vim.api.nvim_get_current_win()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "SELECT 1;",
      "UPDATE users SET active = 1;",
    })

    local state = structure.toggle({ structure_width = 40 })
    local ok, err = xpcall(function()
      assert(state and vim.bo[state.buffer].filetype == "orbit-structure")
      assert(line_number(state.buffer, "SELECT"))
      assert(line_number(state.buffer, "UPDATE users"))
      assert(not line_number(state.buffer, "DML"))
      assert(vim.api.nvim_get_current_win() == state.window)
      assert(vim.wo[state.window].winfixwidth)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == line_number(state.buffer, "SELECT 1"))

      vim.api.nvim_win_set_cursor(state.window, { assert(line_number(state.buffer, "UPDATE users")), 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      assert(vim.api.nvim_get_current_win() == source_window)
      assert(vim.api.nvim_win_get_cursor(source_window)[1] == 2)
    end, debug.traceback)
    structure.close(tabpage)
    vim.cmd("tabclose")
    assert(ok, err)
  end,

  ["Structure panel expands and traverses CTE trees with h and l"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_window = vim.api.nvim_get_current_win()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "WITH crm AS (SELECT id FROM users)",
      "SELECT count(*) FROM crm;",
    })
    local state = structure.toggle({ structure_width = 60 })

    local ok, err = xpcall(function()
      local root_line = assert(node_line(state, "statement"))
      assert(not node_line(state, "with", "WITH"))

      vim.api.nvim_win_set_cursor(state.window, { root_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      local with_line = assert(node_line(state, "with", "WITH"))
      assert(not node_line(state, "cte", "crm"))

      vim.api.nvim_win_set_cursor(state.window, { with_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(node_line(state, "cte", "crm"))
      assert(not node_line(state, "query", "SELECT id FROM users"))

      vim.api.nvim_feedkeys("h", "mx", false)
      assert(not node_line(state, "cte", "crm"))

      vim.api.nvim_buf_set_lines(source_buffer, 0, 1, false, { "WITH crm AS (SELECT id FROM users) " })
      structure.changed(source_buffer)
      assert(vim.wait(100, function()
        return not state.refresh_pending
      end))
      assert(not node_line(state, "cte", "crm"))

      vim.api.nvim_feedkeys("l", "mx", false)
      with_line = assert(node_line(state, "with", "WITH"))
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == with_line)
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == node_line(state, "cte", "crm"))
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(node_line(state, "query", "SELECT id FROM users"))
      vim.api.nvim_buf_set_lines(source_buffer, 0, 1, false, { "WITH crm AS (SELECT id FROM users)  " })
      structure.changed(source_buffer)
      assert(vim.wait(100, function()
        return not state.refresh_pending
      end))
      assert(node_line(state, "query", "SELECT id FROM users"))
      vim.api.nvim_win_set_cursor(state.window, { assert(node_line(state, "cte", "crm")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == node_line(state, "query", "SELECT id FROM users"))
      vim.api.nvim_feedkeys("h", "mx", false)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == node_line(state, "cte", "crm"))
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      assert(vim.api.nvim_get_current_win() == source_window)
      assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_window), { 1, 13 }))
    end, debug.traceback)
    structure.close(tabpage)
    vim.cmd("tabclose")
    assert(ok, err)
  end,

  ["Structure filter retains ancestors and traverses visible children"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "WITH crm AS MATERIALIZED (SELECT id FROM users)",
      "SELECT count(*) FROM crm;",
    })
    local state = structure.toggle({ structure_width = 60 })
    local original_input = vim.ui.input

    local ok, err = xpcall(function()
      vim.ui.input = function(_, callback)
        callback("crm")
      end
      vim.api.nvim_feedkeys("/", "mx", false)
      local root_line = assert(node_line(state, "statement"))
      local with_line = assert(node_line(state, "with", "WITH"))
      local cte_line = assert(node_line(state, "cte", "crm"))
      assert(not node_line(state, "query", "SELECT id FROM users"))

      vim.api.nvim_win_set_cursor(state.window, { root_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == with_line)
      vim.api.nvim_feedkeys("h", "mx", false)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == root_line)
      vim.api.nvim_win_set_cursor(state.window, { cte_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == cte_line)

      vim.ui.input = function(_, callback)
        callback("materialized")
      end
      vim.api.nvim_feedkeys("/", "mx", false)
      assert(node_line(state, "statement"))

      vim.ui.input = function(_, callback)
        callback("users")
      end
      vim.api.nvim_feedkeys("/", "mx", false)
      assert(node_line(state, "statement"))
      assert(node_line(state, "with", "WITH"))
      assert(node_line(state, "cte", "crm"))
      assert(node_line(state, "query", "SELECT id FROM users"))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "mx", false)
      assert(node_line(state, "statement"))
      assert(not node_line(state, "with", "WITH"))
    end, debug.traceback)
    vim.ui.input = original_input
    structure.close(tabpage)
    vim.cmd("tabclose")
    assert(ok, err)
  end,

  ["Structure panel tracks edits and filters without closing"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "SELECT 1;" })
    local state = structure.toggle({ structure_width = 40 })
    local original_input = vim.ui.input

    local ok, err = xpcall(function()
      vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "SELECT 1;", "VACUUM;" })
      structure.changed(source_buffer)
      assert(vim.wait(100, function()
        return line_number(state.buffer, "VACUUM") ~= nil
      end))

      vim.ui.input = function(_, callback)
        callback("vac")
      end
      vim.api.nvim_set_current_win(state.window)
      vim.api.nvim_feedkeys("/", "mx", false)
      assert(line_number(state.buffer, "VACUUM"))
      assert(not line_number(state.buffer, "SELECT 1"))
      assert(structure._state(tabpage) == state)

      structure.source_gone(source_buffer)
      assert(line_number(state.buffer, "No query buffer"))
    end, debug.traceback)
    vim.ui.input = original_input
    structure.close(tabpage)
    vim.cmd("tabclose")
    assert(ok, err)
  end,

  ["OrbitStructure toggles one panel per tabpage"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.bo.filetype = "sql"
    local state = structure.toggle({ structure_width = 40 })
    assert(state)
    vim.api.nvim_set_current_win(state.source_window)
    assert(structure.toggle({ structure_width = 40 }) == nil)
    assert(structure._state(tabpage) == nil)
    vim.cmd("tabclose")
  end,
}
