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
    vim.api.nvim_win_set_cursor(state.sidebar_window, { 6, 0 })
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
      vim.api.nvim_win_set_cursor(state.sidebar_window, { 6, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      vim.api.nvim_feedkeys("l", "mx", false)

      assert(vim.wait(100, function()
        return (vim.api.nvim_buf_get_lines(state.sidebar, 6, 7, false)[1] or ""):match("main")
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
      return { winid = state and state.sidebar_window or 0, line = 6 }
    end

    local ok, err = xpcall(function()
      state = workspace.open({ profile_path = path, workspace_result_ratio = 0.30, workspace_sidebar_width = 32 })
      vim.api.nvim_set_current_win(state.sidebar_window)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<2-LeftMouse>", true, false, true), "mx", false)

    assert(vim.b[vim.api.nvim_win_get_buf(state.query_window)].orbit_profile == "double-click")
      assert(vim.wait(100, function()
        return (vim.api.nvim_buf_get_lines(state.sidebar, 6, 7, false)[1] or ""):match("main")
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
      vim.api.nvim_win_set_cursor(state.sidebar_window, { 6, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.api.nvim_buf_get_lines(state.sidebar, 6, 7, false)[1]:match("main"))

      vim.api.nvim_win_set_cursor(state.sidebar_window, { 7, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.api.nvim_buf_get_lines(state.sidebar, 7, 8, false)[1]:match("tables 1"))

      vim.api.nvim_win_set_cursor(state.sidebar_window, { 8, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)
      assert(vim.api.nvim_buf_get_lines(state.sidebar, 8, 9, false)[1]:match("sessions"))
      workspace.close()
      vim.api.nvim_set_current_tabpage(original_tabpage)
    end, debug.traceback)
    runner.run = original_run
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

  ["workspace filter preserves the first typed character"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    local state = workspace.open({ profile_path = vim.fn.tempname() })

    assert(workspace.focus_filter())
    vim.api.nvim_feedkeys("gridh", "xt", false)
    vim.wait(20)

    local line = vim.api.nvim_buf_get_lines(state.sidebar, 1, 2, false)[1]
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
        saved_query_dir = directory,
        workspace_result_ratio = 0.30,
        workspace_sidebar_width = 32,
       })
       vim.api.nvim_set_current_win(state.sidebar_window)
       vim.api.nvim_win_set_cursor(state.sidebar_window, { 6, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)

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
}
