local orbit = require("orbit")

return {
  ["OrbitWorkspace toggles the Workspace tabpage"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    orbit.setup({ profile_path = vim.fn.tempname() })

    vim.cmd("OrbitWorkspace")
    local workspace_tabpage = vim.api.nvim_get_current_tabpage()
    assert(require("orbit.workspace").is_workspace(workspace_tabpage))

    vim.api.nvim_set_current_tabpage(original)
    vim.cmd("OrbitWorkspace")
    assert(not vim.api.nvim_tabpage_is_valid(workspace_tabpage))
    assert(vim.api.nvim_get_current_tabpage() == original)
  end,

  ["OrbitWorkspace toggles off when it is the last tabpage"] = function()
    local original = vim.api.nvim_get_current_tabpage()
    orbit.setup({ profile_path = vim.fn.tempname() })
    vim.cmd("OrbitWorkspace")
    local workspace_tabpage = vim.api.nvim_get_current_tabpage()

    vim.api.nvim_set_current_tabpage(original)
    vim.cmd("tabclose")
    assert(#vim.api.nvim_list_tabpages() == 1)

    vim.cmd("OrbitWorkspace")
    assert(not vim.api.nvim_tabpage_is_valid(workspace_tabpage))
    assert(#vim.api.nvim_list_tabpages() == 1)
    assert(not require("orbit.workspace").is_workspace())
  end,

  ["default keymaps can be overridden or disabled"] = function()
    local original = vim.api.nvim_get_current_buf()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    vim.bo[buffer].filetype = "sql"
    orbit.setup()

    assert(vim.fn.exists(":OrbitSave") == 2)
    assert(vim.fn.exists(":OrbitWorkspace") == 2)
    assert(vim.fn.exists(":OrbitWorkspaceClose") == 0)
    assert(vim.fn.maparg("<leader>E", "n", false, true).rhs == "<Cmd>OrbitExecute<CR>")
    assert(vim.fn.maparg("<leader>E", "x", false, true).rhs == ":<C-u>'<,'>OrbitExecute<CR>")
    assert(vim.fn.maparg("<leader>X", "n", false, true).rhs == "<Cmd>OrbitCancel<CR>")
    assert(vim.fn.maparg("<leader>P", "n", false, true).rhs == "<Cmd>OrbitSelectProfile<CR>")
    assert(vim.fn.maparg("<leader>D", "n", false, true).rhs == "<Cmd>OrbitWorkspace<CR>")

    orbit.setup({ keymaps = { execute = "<leader>x", structure = "<leader>s", workspace = false } })

    local custom_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(custom_buffer)
    vim.bo[custom_buffer].filetype = "sql"

    assert(vim.fn.maparg("<leader>x", "n", false, true).rhs == "<Cmd>OrbitExecute<CR>")
    assert(vim.fn.maparg("<leader>x", "x", false, true).rhs == ":<C-u>'<,'>OrbitExecute<CR>")
    assert(vim.fn.maparg("<leader>s", "n", false, true).rhs == "<Cmd>OrbitStructure<CR>")
    assert(not vim.fn.maparg("<leader>D", "n", false, true).rhs)

		local redis_buffer = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(redis_buffer)
		vim.bo[redis_buffer].filetype = "redis"
		assert(vim.fn.maparg("<leader>x", "n", false, true).rhs == "<Cmd>OrbitExecute<CR>")
		assert(vim.fn.maparg("<leader>s", "n", false, true).rhs == nil)

    vim.api.nvim_set_current_buf(original)
  end,
}
