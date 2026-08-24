local quarry = require("quarry")

return {
  ["execute mapping passes visual selections to QuarryExecute"] = function()
    local original = vim.api.nvim_get_current_buf()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    vim.bo[buffer].filetype = "sql"
    quarry.setup({ keymaps = { execute = "<leader>E" } })

    local mapping = vim.fn.maparg("<leader>E", "x", false, true)

    assert(mapping.rhs == ":<C-u>'<,'>QuarryExecute<CR>")
    vim.api.nvim_set_current_buf(original)
  end,
}
