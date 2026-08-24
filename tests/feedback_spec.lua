local feedback = require("orbit.feedback")

return {
  ["feedback keeps progress out of notifications"] = function()
    local original_echo = vim.api.nvim_echo
    local original_notify = vim.notify
    local echoes = {}
    local notifications = {}
    vim.api.nvim_echo = function(chunks)
      table.insert(echoes, chunks[1][1])
    end
    vim.notify = function(message)
      table.insert(notifications, message)
    end

    local ok, err = xpcall(function()
      local state = feedback.start("Loading schema")
      assert(echoes[1] == "Loading schema (0s)")
      assert(#notifications == 0)

      feedback.finish(state, "Schema loaded: 3 objects")
      assert(notifications[1] == "Schema loaded: 3 objects")
    end, debug.traceback)
    vim.api.nvim_echo = original_echo
    vim.notify = original_notify
    assert(ok, err)
  end,
}
