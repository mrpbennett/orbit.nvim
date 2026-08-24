local M = {}

function M.open(message)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(message, "\n", { plain = true }))
  vim.bo[buffer].filetype = "orbit-diagnostic"
  vim.bo[buffer].modifiable = false

  vim.cmd("botright new")
  local window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(window, buffer)
  vim.api.nvim_win_set_height(window, math.min(10, math.max(3, #vim.api.nvim_buf_get_lines(buffer, 0, -1, false))))
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(window, true)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit diagnostic" })
end

return M
