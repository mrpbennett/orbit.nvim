local orbit = require("orbit")

return {
  ["default keymaps can be overridden or disabled"] = function()
    local original = vim.api.nvim_get_current_buf()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    vim.bo[buffer].filetype = "sql"
    orbit.setup()

    assert(vim.fn.maparg("<leader>E", "n", false, true).rhs == "<Cmd>OrbitExecute<CR>")
    assert(vim.fn.maparg("<leader>E", "x", false, true).rhs == ":<C-u>'<,'>OrbitExecute<CR>")
    assert(vim.fn.maparg("<leader>B", "n", false, true).rhs == "<Cmd>OrbitBrowse<CR>")
    assert(vim.fn.maparg("<leader>X", "n", false, true).rhs == "<Cmd>OrbitCancel<CR>")
    assert(vim.fn.maparg("<leader>P", "n", false, true).rhs == "<Cmd>OrbitSelectProfile<CR>")
    assert(vim.fn.maparg("<leader>D", "n", false, true).rhs == "<Cmd>OrbitWorkspace<CR>")

    orbit.setup({ keymaps = { browse = false, execute = "<leader>x", workspace = false } })

    local custom_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(custom_buffer)
    vim.bo[custom_buffer].filetype = "sql"

    assert(vim.fn.maparg("<leader>x", "n", false, true).rhs == "<Cmd>OrbitExecute<CR>")
    assert(vim.fn.maparg("<leader>x", "x", false, true).rhs == ":<C-u>'<,'>OrbitExecute<CR>")
    assert(not vim.fn.maparg("<leader>B", "n", false, true).rhs)
    assert(not vim.fn.maparg("<leader>D", "n", false, true).rhs)

    vim.api.nvim_set_current_buf(original)
  end,
}
