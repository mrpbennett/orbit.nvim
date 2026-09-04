local workspace = require("orbit.workspace")
local profiles = require("orbit.profiles")
local runner = require("orbit.runner")

local function line_number(buffer, text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line:find(text, 1, true) then
      return index
    end
  end
end

local function line_count(buffer, text)
  local count = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line:find(text, 1, true) then
      count = count + 1
    end
  end
  return count
end

return {
  ["workspace.open creates a dedicated tabpage"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local state = workspace.open({ profile_path = vim.fn.tempname() })

    assert(state)
    assert(vim.api.nvim_tabpage_is_valid(state.tabpage))
    assert(state.tabpage ~= original)
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
      assert(vim.bo[vim.api.nvim_win_get_buf(window)].filetype ~= "orbit-results")
    end
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(state.query_window), function()
      assert(vim.fn.maparg("/", "n") ~= "")
    end)

    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace.open toggles the profile and schema browser"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local state = workspace.open({ profile_path = vim.fn.tempname() })

    workspace.open({ profile_path = vim.fn.tempname() })
    assert(not vim.api.nvim_win_is_valid(state.sidebar_window))
    assert(vim.api.nvim_win_is_valid(state.query_window))

    workspace.open({ profile_path = vim.fn.tempname() })
    assert(vim.api.nvim_win_is_valid(state.sidebar_window))
    assert(vim.api.nvim_win_get_buf(state.sidebar_window) == state.sidebar)

    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace expands the profile displayed under the cursor"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "profile-binding", kind = "sqlite", options = { path = "/tmp/orbit-test.db" } } },
    }))
    local state = workspace.open({ profile_path = path, workspace_result_ratio = 0.30, workspace_sidebar_width = 32 })

    vim.api.nvim_set_current_win(state.sidebar_window)
    vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "profile-binding")), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)

    assert(vim.b[vim.api.nvim_win_get_buf(state.query_window)].orbit_profile == "profile-binding")
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace expands a profile after it is selected"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "selected-then-expanded", kind = "sqlite", options = { path = "/tmp/orbit-test.db" } } },
    }))
    runner.run = function(_, _, callback)
      callback({ { schema = "main", name = "sessions", type = "table" } })
    end

    local state
    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path, workspace_result_ratio = 0.30, workspace_sidebar_width = 32 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "selected-then-expanded")), 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      vim.api.nvim_feedkeys("l", "mx", false)

      assert(vim.wait(100, function()
        return line_number(state.sidebar, "main") ~= nil
      end))
    end, debug.traceback)
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    if vim.api.nvim_tabpage_is_valid(original_tabpage) then
      vim.api.nvim_set_current_tabpage(original_tabpage)
    end
    runner.run = original_run
    assert(ok, err)
  end,

  ["workspace double click activates the clicked sidebar profile"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "double-click", kind = "sqlite", options = { path = "/tmp/orbit-test.db" } } },
    }))
    runner.run = function(_, _, callback)
      callback({ { schema = "main", name = "sessions", type = "table" } })
    end
    local state
    local getmousepos = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = state and state.sidebar_window or 0, line = state and line_number(state.sidebar, "double-click") or 0 }
    end

    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path, workspace_result_ratio = 0.30, workspace_sidebar_width = 32 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<2-LeftMouse>", true, false, true), "mx", false)

    assert(vim.b[vim.api.nvim_win_get_buf(state.query_window)].orbit_profile == "double-click")
      assert(vim.wait(100, function()
        return line_number(state.sidebar, "main") ~= nil
      end))
    end, debug.traceback)
    vim.fn.getmousepos = getmousepos
    runner.run = original_run
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    if vim.api.nvim_tabpage_is_valid(original) then
      vim.api.nvim_set_current_tabpage(original)
    end
    assert(ok, err)
  end,

  ["workspace double click toggles schema and table nodes"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local original_getmousepos = vim.fn.getmousepos
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "double-click-tree", kind = "sqlite", options = { path = "/tmp/orbit-test.db" } } },
    }))
    runner.run = function(_, statement, callback)
      if statement:match("PRAGMA table_info") then
        callback({ { name = "id", type = "INTEGER" } })
      else
        callback({ { schema = "main", name = "sessions", type = "table" } })
      end
    end
    local state
    local mouse_line
    vim.fn.getmousepos = function()
      return { winid = state and state.sidebar_window or 0, line = mouse_line }
    end

    local function double_click(text)
      mouse_line = assert(line_number(state.sidebar, text))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<2-LeftMouse>", true, false, true), "mx", false)
    end

    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path })
      vim.api.nvim_set_current_win(state.sidebar_window)
      mouse_line = assert(line_number(state.sidebar, "double-click-tree"))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<2-LeftMouse>", true, false, true), "mx", false)
      assert(vim.wait(100, function()
        return line_number(state.sidebar, "main") ~= nil
      end))

      double_click("main")
      assert(line_number(state.sidebar, "tables 1"))
      double_click("tables 1")
      assert(line_number(state.sidebar, "sessions"))
      double_click("sessions")
      assert(line_number(state.sidebar, "columns"))
      double_click("sessions")
      assert(not line_number(state.sidebar, "columns"))
      double_click("main")
      assert(not line_number(state.sidebar, "tables 1"))
    end, debug.traceback)
    vim.fn.getmousepos = original_getmousepos
    runner.run = original_run
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    if vim.api.nvim_tabpage_is_valid(original) then
      vim.api.nvim_set_current_tabpage(original)
    end
    assert(ok, err)
  end,

  ["workspace renders schemas before object groups"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "tree-structure", kind = "sqlite", options = { path = "/tmp/orbit-tree.db" } } },
    }))
    runner.run = function(_, _, callback)
      callback({
        { schema = "main", name = "sessions", type = "table" },
        { schema = "main", name = "active_sessions", type = "view" },
      })
    end

    local ok, err = xpcall(function()
      local state = workspace.open({ profile_path = path, workspace_result_ratio = 0.30, workspace_sidebar_width = 32 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "tree-structure")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
		assert(vim.api.nvim_buf_get_lines(state.sidebar, 3, 4, false)[1] == "@ tree-structure")
      assert(vim.wait(100, function()
        return line_number(state.sidebar, "main") ~= nil
      end))

      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "main")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "tables 1")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(line_number(state.sidebar, "sessions"))
      workspace.close()
      vim.api.nvim_set_current_tabpage(original_tabpage)
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

  ["workspace displays SQLite metadata below expanded tables"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "metadata-tree", kind = "sqlite", options = { path = "/tmp/orbit-metadata.db" } } },
    }))
    runner.run = function(_, statement, callback)
      if statement:match("PRAGMA table_info") then
        callback({ { name = "id", type = "INTEGER" } })
      else
        callback({ { schema = "main", name = "sessions", type = "table" } })
      end
    end
    local state
    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "metadata-tree")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "main")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "tables 1")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "sessions")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(line_number(state.sidebar, "columns"))

      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "columns")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.wait(100, function()
        return line_number(state.sidebar, "id  INTEGER") ~= nil
      end))
    end, debug.traceback)
    runner.run = original_run
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    vim.api.nvim_set_current_tabpage(original_tabpage)
    assert(ok, err)
  end,

  ["workspace profile selection reloads the profile file"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "local", kind = "sqlite", options = { path = "/tmp/orbit-test.db" } } },
    }))
    local config = { profile_path = path, workspace_result_ratio = 0.30, workspace_sidebar_width = 32 }
    local state = workspace.open(config)
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "staging", kind = "sqlite", options = { path = "/tmp/orbit-staging.db" } } },
    }))

    workspace.select_profile(config, state.query_window)

    assert(state.profiles[1].name == "staging")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "mx", false)
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace spaces its header and titles the selected profile"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "local", kind = "sqlite", options = { path = "/tmp/orbit-test.db" } } },
    }))
    local state = workspace.open({ profile_path = path })

    local lines = vim.api.nvim_buf_get_lines(state.sidebar, 0, 7, false)
    assert(vim.deep_equal(lines, {
      "press ? to toggle help",
      "",
      "Filter: ",
      "* Orbit Workspace",
      "",
      "Profiles:",
      "  > @ local (sqlite)",
    }), vim.inspect(lines))

    vim.api.nvim_set_current_win(state.sidebar_window)
    vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "local")), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)

		assert(vim.api.nvim_buf_get_lines(state.sidebar, 3, 4, false)[1] == "@ local")
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace restores its title when the selected profile is removed"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "temporary", kind = "sqlite", options = { path = "/tmp/orbit-test.db" } } },
    }))
    local state = workspace.open({ profile_path = path })
    vim.api.nvim_set_current_win(state.sidebar_window)
    vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "temporary")), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    assert(profiles.write(path, { version = 1, profiles = {} }))

    vim.api.nvim_feedkeys("r", "mx", false)

    assert(vim.api.nvim_buf_get_lines(state.sidebar, 3, 4, false)[1] == "* Orbit Workspace")
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace filter preserves the first typed character"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local state = workspace.open({ profile_path = vim.fn.tempname() })

    assert(workspace.focus_filter())
    vim.api.nvim_feedkeys("gridh", "xt", false)
    vim.wait(20)

    local line = vim.api.nvim_buf_get_lines(state.sidebar, 2, 3, false)[1]
    assert(line == "Filter: gridh", vim.inspect(line))
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace renders one filter line"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local state = workspace.open({ profile_path = vim.fn.tempname() })
    local filters = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(state.sidebar, 0, -1, false)) do
      if line:match("^Filter:") then
        filters = filters + 1
      end
    end

    assert(filters == 1)
    assert(vim.api.nvim_buf_get_lines(state.sidebar, 0, 1, false)[1] == "press ? to toggle help")
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace keeps keybinding hints in help"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local state = workspace.open({ profile_path = vim.fn.tempname() })
    local lines = vim.api.nvim_buf_get_lines(state.sidebar, 0, -1, false)

    assert(not table.concat(lines, "\n"):match("new query"))
    vim.api.nvim_set_current_win(state.sidebar_window)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("?", true, false, true), "mx", false)
    assert(vim.api.nvim_get_current_win() ~= state.sidebar_window)

    vim.cmd("close")
    workspace.close()
    vim.api.nvim_set_current_tabpage(original)
  end,

  ["workspace opens recursive saved queries with a selected profile"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local profile_path = vim.fn.tempname()
    local directory = vim.fn.tempname()
    local nested = directory .. "/reports"
    assert(vim.uv.fs_mkdir(directory, 448))
    assert(vim.fn.mkdir(nested, "p") == 1)
    vim.fn.writefile({ "SELECT 'daily';" }, directory .. "/daily.sql")
    vim.fn.writefile({ "SELECT 'weekly';" }, nested .. "/weekly.sql")
    vim.fn.writefile({ "not a query" }, nested .. "/notes.txt")
    assert(profiles.write(profile_path, {
      version = 1,
      profiles = { { name = "local", kind = "sqlite", options = { path = "/tmp/orbit-saved.db" } } },
    }))
    local state
    local ok, err = xpcall(function()
      state = workspace.open({
        profile_path = profile_path,
        saved_query_dirs = { { name = "Team queries", path = directory } },
        workspace_result_ratio = 0.30,
        workspace_sidebar_width = 32,
       })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "local")), 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)

      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "Team queries")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      local reports_line = assert(line_number(state.sidebar, "reports"))
      vim.api.nvim_win_set_cursor(state.sidebar_window, { reports_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      local weekly_line = assert(line_number(state.sidebar, "weekly.sql"))
      vim.api.nvim_win_set_cursor(state.sidebar_window, { weekly_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)

      local buffer = vim.api.nvim_get_current_buf()
      assert(vim.api.nvim_buf_get_name(buffer) == nested .. "/weekly.sql")
      assert(vim.bo[buffer].filetype == "sql")
      assert(vim.b[buffer].orbit_profile == "local")
      assert(vim.b[buffer].orbit_workspace_tab == state.tabpage)
      assert(vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == "SELECT 'weekly';")
    end, debug.traceback)
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    vim.api.nvim_set_current_tabpage(original_tabpage)
    assert(ok, err)
  end,

  ["workspace collapses the open schema tree with Z"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "collapse-tree", kind = "sqlite", options = { path = "/tmp/orbit-tree.db" } } },
    }))
    runner.run = function(_, _, callback)
      callback({ { schema = "main", name = "sessions", type = "table" } })
    end
    local state
    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path, result_limit = 25 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "collapse-tree")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.wait(100, function()
        return state.schema_profile == "collapse-tree"
      end))
      vim.api.nvim_feedkeys("Z", "mx", false)
      assert(state.schema_profile == nil)
      assert(state.selected.name == "collapse-tree")
    end, debug.traceback)
    runner.run = original_run
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    vim.api.nvim_set_current_tabpage(original_tabpage)
    assert(ok, err)
  end,

  ["workspace table mappings use connector actions"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local original_select = vim.ui.select
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = {
        { name = "table-actions", kind = "sqlite", options = { path = "/tmp/orbit-actions.db" } },
        { name = "other-profile", kind = "sqlite", options = { path = "/tmp/orbit-other.db" } },
      },
    }))
    local column_profile
    runner.run = function(profile, statement, callback)
      if statement:match("PRAGMA table_info") then
        column_profile = profile.name
        callback({ { name = "id", type = "INTEGER" } })
        return
      end
      if statement:match("WHERE name =") then
        callback({ { sql = "CREATE TABLE sessions (id INTEGER)" } })
      else
        callback({ { schema = "main", name = "sessions", type = "table" } })
      end
    end
    vim.ui.select = function(items, _, callback)
      for _, action in ipairs(items) do
        if action.id == "definition" then
          callback(action)
          return
        end
      end
    end
    local state
    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path, result_limit = 25 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "table-actions")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.wait(100, function()
        return line_number(state.sidebar, "main") ~= nil
      end))
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "main")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "tables 1")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "other-profile")), 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      assert(state.selected.name == "other-profile")
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "sessions")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "columns")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.wait(100, function()
        return column_profile ~= nil
      end))
      assert(column_profile == "table-actions")
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "sessions")), 0 })
      vim.api.nvim_feedkeys("y", "mx", false)
      assert(vim.fn.getreg('"') == '"sessions"')

      vim.api.nvim_feedkeys("s", "mx", false)
      local buffer = vim.api.nvim_get_current_buf()
      assert(vim.b[buffer].orbit_profile == "table-actions")
      assert(vim.api.nvim_buf_get_lines(buffer, 0, 2, false)[1] == "SELECT *")
      assert(vim.api.nvim_buf_get_lines(buffer, 1, 2, false)[1]:match("FROM"))

      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "sessions")), 0 })
      vim.api.nvim_feedkeys("a", "mx", false)
      assert(vim.wait(100, function()
        for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
          if vim.bo[vim.api.nvim_win_get_buf(window)].filetype == "orbit-results" then
            return true
          end
        end
        return false
      end))
    end, debug.traceback)
    runner.run = original_run
    vim.ui.select = original_select
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    vim.api.nvim_set_current_tabpage(original_tabpage)
    assert(ok, err)
  end,

  ["workspace actions return results to the Workspace tabpage after focus changes"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local original_select = vim.ui.select
    local path = vim.fn.tempname()
    local action_callback
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "action-tabpage", kind = "sqlite", options = { path = "/tmp/orbit-action-tabpage.db" } } },
    }))
    runner.run = function(_, statement, callback)
      if statement:match("WHERE name =") then
        action_callback = callback
      else
        callback({ { schema = "main", name = "sessions", type = "table" } })
      end
    end
    vim.ui.select = function(items, _, callback)
      for _, item in ipairs(items) do
        if item.id == "definition" then
          callback(item)
          return
        end
      end
      error("Definition action missing")
    end

    local state
    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path, result_limit = 25 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "action-tabpage")), 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.wait(100, function()
        return line_number(state.sidebar, "main") ~= nil
      end))
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "main")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "tables 1")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "sessions")), 0 })
      vim.api.nvim_feedkeys("a", "mx", false)
      assert(action_callback)

      vim.cmd("tabnew")
      action_callback({ { sql = "CREATE TABLE sessions (id INTEGER)" } })
      assert(vim.wait(100, function()
        for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
          local buffer = vim.api.nvim_win_get_buf(window)
          if vim.bo[buffer].filetype == "orbit-results" then
            return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"):match("CREATE TABLE sessions") ~= nil
          end
        end
        return false
      end))
      vim.cmd("tabclose")
    end, debug.traceback)
    runner.run = original_run
    vim.ui.select = original_select
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    if vim.api.nvim_tabpage_is_valid(original_tabpage) then
      vim.api.nvim_set_current_tabpage(original_tabpage)
    end
    assert(ok, err)
  end,

  ["workspace previews saved queries without binding a query buffer"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local directory = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(directory, 448))
    vim.fn.writefile({ "SELECT 'preview';" }, directory .. "/preview.sql")
    local state
    local ok, err = xpcall(function()
      state = workspace.open({
        profile_path = vim.fn.tempname(),
        saved_query_dirs = { { name = "Preview queries", path = directory } },
      })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "Preview queries")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "preview.sql")), 0 })
      vim.api.nvim_feedkeys("P", "mx", false)
      local buffer = vim.api.nvim_get_current_buf()
      assert(vim.bo[buffer].filetype == "sql")
      assert(vim.b[buffer].orbit_profile == nil)
      assert(vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == "SELECT 'preview';")
      vim.api.nvim_feedkeys("q", "mx", false)
    end, debug.traceback)
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    vim.api.nvim_set_current_tabpage(original)
    assert(ok, err)
  end,

  ["workspace collapses named saved query locations by default and refreshes one root"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local first = vim.fn.tempname()
    local second = vim.fn.tempname()
    local unavailable = vim.fn.tempname()
    local nested = first .. "/nested"
    assert(vim.fn.mkdir(nested, "p") == 1)
    assert(vim.uv.fs_mkdir(second, 448))
    vim.fn.writefile({ "SELECT 1;" }, nested .. "/first.sql")
    vim.fn.writefile({ "SELECT 2;" }, second .. "/second.sql")
    assert(vim.uv.fs_symlink(second .. "/second.sql", first .. "/linked.sql"))
    assert(vim.uv.fs_symlink(second, first .. "/linked-directory"))
    local state
    local ok, err = xpcall(function()
      state = workspace.open({
        profile_path = vim.fn.tempname(),
        saved_query_dirs = {
          { name = "Work SQL", path = first },
          { name = "Personal SQL", path = second },
          { name = "Nested SQL", path = nested },
          { name = "Offline SQL", path = unavailable },
        },
      })
      local work_line = assert(line_number(state.sidebar, "Work SQL"))
      local personal_line = assert(line_number(state.sidebar, "Personal SQL"))
      local nested_root_line = assert(line_number(state.sidebar, "Nested SQL"))
      assert(work_line < personal_line)
      local offline_line = assert(line_number(state.sidebar, "Offline SQL"))
      assert(personal_line < nested_root_line and nested_root_line < offline_line)
      assert(not line_number(state.sidebar, "No saved SQL files"))
      assert(not line_number(state.sidebar, "nested"))
      assert(not line_number(state.sidebar, "second.sql"))
      assert(not line_number(state.sidebar, "first.sql"))

      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { work_line, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(line_number(state.sidebar, "nested"))
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "Personal SQL")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(line_number(state.sidebar, "second.sql"))
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "Nested SQL")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(line_count(state.sidebar, "first.sql") == 1)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "Offline SQL")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(line_number(state.sidebar, "No saved SQL files"))
      assert(not line_number(state.sidebar, "linked.sql"))
      assert(not line_number(state.sidebar, "linked-directory"))

      vim.fn.writefile({ "SELECT 3;" }, nested .. "/added-work.sql")
      vim.fn.writefile({ "SELECT 4;" }, second .. "/added-personal.sql")
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "nested")), 0 })
      vim.api.nvim_feedkeys("r", "mx", false)

      vim.api.nvim_feedkeys("l", "mx", false)
      assert(line_number(state.sidebar, "added-work.sql"))
      assert(not line_number(state.sidebar, "added-personal.sql"))
      assert(line_count(state.sidebar, "first.sql") == 2)
      vim.api.nvim_feedkeys("h", "mx", false)
      assert(line_count(state.sidebar, "first.sql") == 1)
    end, debug.traceback)
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    vim.api.nvim_set_current_tabpage(original)
    assert(ok, err)
  end,

  ["workspace discards a completed action after it closes"] = function()
    local original_tabpage = vim.api.nvim_get_current_tabpage()
    local original_run = runner.run
    local original_select = vim.ui.select
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "discard-action", kind = "sqlite", options = { path = "/tmp/orbit-discard.db" } } },
    }))
    local action_callback
    runner.run = function(_, statement, callback)
      if statement:match("WHERE name =") then
        action_callback = callback
      else
        callback({ { schema = "main", name = "sessions", type = "table" } })
      end
    end
    vim.ui.select = function(items, _, callback)
      for _, action in ipairs(items) do
        if action.id == "definition" then
          callback(action)
          return
        end
      end
    end
    local state
    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path, result_limit = 25 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "discard-action")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.wait(100, function()
        return line_number(state.sidebar, "main") ~= nil
      end))
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "main")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "tables 1")), 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      vim.api.nvim_win_set_cursor(state.sidebar_window, { assert(line_number(state.sidebar, "sessions")), 0 })
      vim.api.nvim_feedkeys("a", "mx", false)
      assert(action_callback)
      workspace.close(state.tabpage)
      action_callback({ { sql = "CREATE TABLE sessions (id INTEGER)" } })
      for _, window in ipairs(vim.api.nvim_tabpage_list_wins(original_tabpage)) do
        assert(vim.bo[vim.api.nvim_win_get_buf(window)].filetype ~= "orbit-results")
      end
    end, debug.traceback)
    runner.run = original_run
    vim.ui.select = original_select
    if state and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      workspace.close(state.tabpage)
    end
    vim.api.nvim_set_current_tabpage(original_tabpage)
    assert(ok, err)
  end,
}
