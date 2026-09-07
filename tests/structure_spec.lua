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

local function node_text(state, kind, label)
  local line = assert(node_line(state, kind, label))
  return vim.api.nvim_buf_get_lines(state.buffer, line - 1, line, false)[1]
end

local function statement_line(state, category)
  for line, selected in pairs(state.nodes) do
    if selected.node.kind == "statement" and selected.node.category == category then
      return line
    end
  end
end

return {
  ["Structure panel executes exact SELECT elements and containing statements"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_window = vim.api.nvim_get_current_win()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "SELECT users.id",
      "FROM users;",
    })
    local config = { keymaps = { execute = "<F8>" }, structure_width = 40 }
    local state = structure.toggle(config)
    local query = require("orbit.query")
    local original_execute = query.execute
    local executions = {}

    local ok, err = xpcall(function()
      query.execute = function(buffer, received_config, selection, context)
        table.insert(executions, {
          buffer = buffer,
          config = received_config,
          selection = selection,
          context = context,
          current_window = vim.api.nvim_get_current_win(),
        })
      end

      vim.api.nvim_feedkeys("l", "mx", false)
      local query_line = assert(node_line(state, "query", "SELECT users.id FROM users"))
      vim.api.nvim_win_set_cursor(state.window, { query_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F8>", true, false, true), "mx", false)
      assert(#executions == 1)
      assert(vim.deep_equal(executions[1].selection, {
        start_row = 1,
        start_col = 0,
        end_row = 2,
        end_col = 10,
      }))
      vim.api.nvim_feedkeys("l", "mx", false)

      local select_line = assert(node_line(state, "clause", "SELECT users.id"))
      vim.api.nvim_win_set_cursor(state.window, { select_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F8>", true, false, true), "mx", false)
      assert(#executions == 2)
      assert(executions[2].buffer == source_buffer)
      assert(executions[2].config == config)
      assert(executions[2].context.source_window == source_window)
      assert(executions[2].context.source_changedtick == vim.api.nvim_buf_get_changedtick(source_buffer))
      assert(executions[2].context.trigger_window == state.window)
      assert(executions[2].context.tabpage == tabpage)
      assert(executions[2].current_window == state.window)
      assert(vim.deep_equal(executions[2].selection, {
        start_row = 1,
        start_col = 0,
        end_row = 1,
        end_col = 15,
      }))

      local from_line = assert(node_line(state, "clause", "FROM users"))
      vim.api.nvim_win_set_cursor(state.window, { from_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F8>", true, false, true), "mx", false)
      assert(#executions == 3)
      assert(vim.deep_equal(executions[3].selection, {
        start_row = 1,
        start_col = 0,
        end_row = 2,
        end_col = 11,
      }))
    end, debug.traceback)
    query.execute = original_execute
    structure.close(tabpage)
    vim.cmd("tabclose")
    assert(ok, err)
  end,

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
      assert(line_number(state.buffer, "DML"))
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

  ["Structure panel preserves complete labels beyond its width"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    local sql = "SELECT jsonb_pretty(jsonb_build_object('database', current_database())) AS database_structure;"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { sql })
    local state = structure.toggle({ structure_width = 20 })

    local ok, err = xpcall(function()
      local statement_line = assert(node_line(state, "statement", sql))
      assert(vim.api.nvim_buf_get_lines(state.buffer, statement_line - 1, statement_line, false)[1] == "  > 󰍉 " .. sql)
      assert(vim.wo[state.window].wrap == false)
    end, debug.traceback)
    structure.close(tabpage)
    vim.cmd("tabclose")
    assert(ok, err)
  end,

  ["Structure panel applies statement view options"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "UPDATE zebra SET active = 1;",
      "SELECT zebra;",
      "CREATE TABLE zebra (id int);",
      "DELETE FROM alpha;",
      "SELECT alpha;",
      "VACUUM;",
    })
    local state = structure.toggle({ structure_width = 50 })
    local original_input = vim.ui.input

    local ok, err = xpcall(function()
      local ddl = assert(node_line(state, "group", "DDL"))
      local dml = assert(node_line(state, "group", "DML"))
      local select_group = assert(node_line(state, "group", "SELECT"))
      local other = assert(node_line(state, "group", "Other"))
      assert(ddl < dml and dml < select_group and select_group < other)
      assert(node_line(state, "statement", "DELETE FROM alpha;") < node_line(state, "statement", "UPDATE zebra SET active = 1;"))
      assert(node_line(state, "statement", "SELECT alpha;") < node_line(state, "statement", "SELECT zebra;"))
      assert(not state.collapsed["structure-group:SELECT"])
      assert(not node_line(state, "query"))

      vim.ui.input = function(_, callback)
        callback("ddl")
      end
      vim.api.nvim_feedkeys("/", "mx", false)
      assert(not node_line(state, "group", "DDL"))
      assert(line_number(state.buffer, "No matches"))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "mx", false)

      structure.close(tabpage)
      vim.api.nvim_set_current_buf(source_buffer)
      state = structure.toggle({
        structure_view = {
          group_by_type = true,
          show_ddl = false,
          show_dml = true,
          show_other = false,
          show_select = false,
          sort_alphabetically = false,
        },
        structure_width = 50,
      })
      assert(node_line(state, "group", "DML"))
      assert(not node_line(state, "group", "DDL"))
      assert(not node_line(state, "group", "SELECT"))
      assert(not node_line(state, "group", "Other"))
      assert(not node_line(state, "statement", "CREATE TABLE zebra (id int);"))
      assert(not node_line(state, "statement", "SELECT alpha;"))
      assert(not node_line(state, "statement", "VACUUM;"))
      assert(node_line(state, "statement", "UPDATE zebra SET active = 1;") < node_line(state, "statement", "DELETE FROM alpha;"))

      structure.close(tabpage)
      vim.api.nvim_set_current_buf(source_buffer)
      state = structure.toggle({
        structure_view = { group_by_type = false },
        structure_width = 50,
      })
      assert(not node_line(state, "group"))
      assert(node_line(state, "statement", "CREATE TABLE zebra (id int);") < node_line(state, "statement", "DELETE FROM alpha;"))
      assert(node_line(state, "statement", "DELETE FROM alpha;") < node_line(state, "statement", "SELECT alpha;"))
      assert(node_line(state, "statement", "SELECT zebra;") < node_line(state, "statement", "UPDATE zebra SET active = 1;"))
    end, debug.traceback)
    vim.ui.input = original_input
    structure.close(tabpage)
    vim.cmd("tabclose")
    assert(ok, err)
  end,

  ["Structure panel icons distinguish categories and structural roles"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "CREATE TABLE widgets (id int);",
      "UPDATE widgets SET id = 1;",
      "WITH crm AS (SELECT id FROM users) SELECT count(*) FROM crm;",
      "VACUUM;",
    })
    local icons = {
      clause = "L",
      collapsed = "+",
      cte = "C",
      expanded = "-",
      folder = "G",
      query = "Q",
      statement_ddl = "D",
      statement_dml = "M",
      statement_other = "O",
      statement_select = "S",
      with = "W",
    }
    local state = structure.toggle({ icons = icons, structure_width = 60 })

    local ok, err = xpcall(function()
      assert(node_text(state, "group", "DDL"):find("G DDL", 1, true))
      assert(node_text(state, "group", "DML"):find("G DML", 1, true))
      assert(node_text(state, "group", "SELECT"):find("G SELECT", 1, true))
      assert(node_text(state, "group", "Other"):find("G Other", 1, true))
      assert(node_text(state, "statement", "CREATE TABLE widgets (id int);"):find("D CREATE", 1, true))
      assert(node_text(state, "statement", "UPDATE widgets SET id = 1;"):find("M UPDATE", 1, true))
      assert(node_text(state, "statement", "VACUUM;"):find("O VACUUM", 1, true))

      local select_statement = assert(statement_line(state, "SELECT"))
      assert(vim.api.nvim_buf_get_lines(state.buffer, select_statement - 1, select_statement, false)[1]:find("S WITH", 1, true))
      vim.api.nvim_win_set_cursor(state.window, { select_statement, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(node_text(state, "with", "WITH"):find("W WITH", 1, true))
      assert(node_text(state, "query", "SELECT count(*) FROM crm"):find("Q SELECT", 1, true))

      local with_line = assert(node_line(state, "with", "WITH"))
      vim.api.nvim_win_set_cursor(state.window, { with_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(node_text(state, "cte", "crm"):find("C crm", 1, true))
      local cte_line = assert(node_line(state, "cte", "crm"))
      vim.api.nvim_win_set_cursor(state.window, { cte_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(node_text(state, "query", "SELECT id FROM users"):find("Q SELECT", 1, true))
      local query_line = assert(node_line(state, "query", "SELECT id FROM users"))
      vim.api.nvim_win_set_cursor(state.window, { query_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(node_text(state, "clause", "FROM users"):find("L FROM", 1, true))

      structure.close(tabpage)
      vim.api.nvim_set_current_buf(source_buffer)
      state = structure.toggle({
        icons = icons,
        structure_view = { group_by_type = false },
        structure_width = 60,
      })
      assert(not node_line(state, "group"))
      assert(node_text(state, "statement", "CREATE TABLE widgets (id int);"):find("D CREATE", 1, true))
      assert(node_text(state, "statement", "UPDATE widgets SET id = 1;"):find("M UPDATE", 1, true))
      assert(node_text(state, "statement", "WITH crm AS (SELECT id FROM users) SELECT count(*) FROM crm;"):find("S WITH", 1, true))
      assert(node_text(state, "statement", "VACUUM;"):find("O VACUUM", 1, true))
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

  ["Structure panel filters and navigates nested query clauses"] = function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local source_window = vim.api.nvim_get_current_win()
    local source_buffer = vim.api.nvim_get_current_buf()
    vim.bo[source_buffer].filetype = "sql"
    vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "SELECT users.id",
      "FROM users",
      "WHERE EXISTS (",
      "  SELECT 1",
      "  FROM sessions",
      "  WHERE sessions.user_id = users.id",
      ");",
    })
    local state = structure.toggle({ structure_width = 40 })
    local original_input = vim.ui.input

    local ok, err = xpcall(function()
      assert(not node_line(state, "query"))
      vim.api.nvim_feedkeys("l", "mx", false)
      local query_line = assert(node_line(state, "query"))
      assert(not node_line(state, "clause"))
      vim.api.nvim_win_set_cursor(state.window, { query_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(node_line(state, "clause", "FROM users"))

      vim.api.nvim_buf_set_lines(source_buffer, 0, 1, false, { "SELECT users.id " })
      structure.changed(source_buffer)
      assert(vim.wait(100, function()
        return not state.refresh_pending
      end))
      assert(node_line(state, "clause", "FROM users"))

      vim.ui.input = function(_, callback)
        callback("sessions")
      end
      vim.api.nvim_feedkeys("/", "mx", false)
      local nested_from = assert(node_line(state, "clause", "FROM sessions"))
      vim.api.nvim_set_current_win(source_window)
      vim.api.nvim_win_set_cursor(source_window, { 5, 2 })
      structure.cursor_moved(source_buffer)
      assert(vim.api.nvim_win_get_cursor(state.window)[1] == nested_from)
      vim.api.nvim_set_current_win(state.window)
      vim.api.nvim_win_set_cursor(state.window, { nested_from, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      assert(vim.api.nvim_get_current_win() == source_window)
      assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_window), { 5, 2 }))
    end, debug.traceback)
    vim.ui.input = original_input
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
