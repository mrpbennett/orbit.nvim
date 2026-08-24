local browser = require("orbit.browser")
local profiles = require("orbit.profiles")
local runner = require("orbit.runner")

return {
  ["schema browser expands the table under the cursor"] = function()
    local original_run = runner.run
    local path = vim.fn.tempname()
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "local", kind = "sqlite", options = { path = "/tmp/orbit-browser.db" } } },
    }))
    runner.run = function(_, statement, callback)
      if statement:match("sqlite_master") then
        callback({ { schema = "main", name = "sessions", type = "table" } })
      else
        callback({ { name = "id", type = "integer" } })
      end
    end

    local ok, err = xpcall(function()
      browser.open({ profile_path = path, schema_width = 36, result_limit = 200 }, "local")
      local window = vim.api.nvim_get_current_win()
      local buffer = vim.api.nvim_win_get_buf(window)
      assert(vim.wait(100, function()
        return #vim.api.nvim_buf_get_lines(buffer, 0, -1, false) >= 4
      end))
      vim.api.nvim_win_set_cursor(window, { 4, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)

      assert(vim.api.nvim_buf_get_lines(buffer, 4, 5, false)[1]:match("id%s+integer"))
      vim.api.nvim_feedkeys("q", "mx", false)
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,

  ["schema browser runs the selected connector object action"] = function()
    local original_run = runner.run
    local original_select = vim.ui.select
    local path = vim.fn.tempname()
    local action_callback
    assert(profiles.write(path, {
      version = 1,
      profiles = { { name = "local", kind = "sqlite", options = { path = "/tmp/orbit-browser.db" } } },
    }))
    runner.run = function(_, statement, callback)
      if statement:match("sqlite_master") then
        callback({ { schema = "main", name = "sessions", type = "table" } })
      elseif statement:match("index_list") then
        action_callback = callback
      else
        callback({})
      end
    end
    vim.ui.select = function(items, _, callback)
      for _, item in ipairs(items) do
        if item.id == "indexes" then
          callback(item)
          return
        end
      end
      error("Indexes action missing")
    end

    local ok, err = xpcall(function()
      browser.open({ profile_path = path, schema_width = 36, result_height = 8, result_limit = 200, max_cell_width = 48 }, "local")
      local window = vim.api.nvim_get_current_win()
      local buffer = vim.api.nvim_win_get_buf(window)
      assert(vim.wait(100, function()
        return #vim.api.nvim_buf_get_lines(buffer, 0, -1, false) >= 4
      end))
      vim.api.nvim_win_set_cursor(window, { 4, 0 })
      vim.api.nvim_feedkeys("a", "mx", false)
      assert(action_callback)
      local browser_tabpage = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local other_tabpage = vim.api.nvim_get_current_tabpage()
      action_callback({ { name = "sessions_created_at", unique = 0 } })

      assert(vim.wait(100, function()
        for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(browser_tabpage)) do
          local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(candidate), 0, -1, false)
          if table.concat(lines, "\n"):match("sessions_created_at") then
            return true
          end
        end
        return false
      end))
      vim.api.nvim_win_close(window, true)
      for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(browser_tabpage)) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(candidate)) == "" and vim.bo[vim.api.nvim_win_get_buf(candidate)].filetype == "orbit-results" then
          vim.api.nvim_win_close(candidate, true)
          break
        end
      end
      vim.api.nvim_set_current_tabpage(other_tabpage)
      vim.cmd("tabclose")
    end, debug.traceback)
    vim.ui.select = original_select
    runner.run = original_run
    assert(ok, err)
  end,
}
