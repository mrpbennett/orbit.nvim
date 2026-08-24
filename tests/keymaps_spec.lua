local quarry = require("quarry")

return {
  ["default keymaps can be overridden or disabled"] = function()
    local original = vim.api.nvim_get_current_buf()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    vim.bo[buffer].filetype = "sql"
    quarry.setup()

    assert(vim.fn.maparg("<leader>E", "n", false, true).rhs == "<Cmd>QuarryExecute<CR>")
    assert(vim.fn.maparg("<leader>E", "x", false, true).rhs == ":<C-u>'<,'>QuarryExecute<CR>")
    assert(vim.fn.maparg("<leader>B", "n", false, true).rhs == "<Cmd>QuarryBrowse<CR>")
    assert(vim.fn.maparg("<leader>X", "n", false, true).rhs == "<Cmd>QuarryCancel<CR>")
    assert(vim.fn.maparg("<leader>P", "n", false, true).rhs == "<Cmd>QuarrySelectProfile<CR>")
    assert(vim.fn.maparg("<leader>D", "n", false, true).rhs == "<Cmd>QuarryWorkspace<CR>")

    quarry.setup({ keymaps = { browse = false, execute = "<leader>x", workspace = false } })

    local custom_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(custom_buffer)
    vim.bo[custom_buffer].filetype = "sql"

    assert(vim.fn.maparg("<leader>x", "n", false, true).rhs == "<Cmd>QuarryExecute<CR>")
    assert(vim.fn.maparg("<leader>x", "x", false, true).rhs == ":<C-u>'<,'>QuarryExecute<CR>")
    assert(not vim.fn.maparg("<leader>B", "n", false, true).rhs)
    assert(not vim.fn.maparg("<leader>D", "n", false, true).rhs)

    vim.api.nvim_set_current_buf(original)
  end,
}
