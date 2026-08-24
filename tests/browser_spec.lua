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
      vim.api.nvim_win_set_cursor(window, { 4, 0 })
      vim.api.nvim_feedkeys("l", "mx", false)

      assert(vim.api.nvim_buf_get_lines(buffer, 4, 5, false)[1]:match("id%s+integer"))
      vim.api.nvim_feedkeys("q", "mx", false)
    end, debug.traceback)
    runner.run = original_run
    assert(ok, err)
  end,
}
