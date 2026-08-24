local M = {}
local status_winbar = "%{luaeval(\"require('quarry').status()\")}"

M.config = {
  confirm_mutations = true,
  focus_results = false,
  max_cell_width = 48,
  keymaps = {
    browse = "<leader>B",
    cancel = "<leader>X",
    execute = "<leader>E",
    select_profile = "<leader>P",
    workspace = "<leader>D",
  },
  icons = {
    collapsed = "",
    column = "󰘧",
    expanded = "",
    folder = "󰉋",
    profile = "󰆼",
    query = "󰆋",
    result = "󰎟",
    saved_query = "󰆼",
    table = "󰓫",
    view = "󰈈",
    workspace = "󱓞",
  },
  profile_path = vim.fn.expand("~/.local/share/quarry.nvim/profiles.json"),
  result_height = 15,
  result_limit = 200,
  saved_query_dir = nil,
  schema_width = 36,
  winbar = false,
  workspace_result_ratio = 0.30,
  workspace_sidebar_width = 32,
}

local configured = false
local default_profile_warned = false
local workspace_mapping = nil

local function visual_selection(command)
  if command.range == 0 then
    return nil
  end
  return { start_row = command.line1, end_row = command.line2 }
end

local function create_commands()
  local query = require("quarry.query")
  local browser = require("quarry.browser")
  local workspace = require("quarry.workspace")

  vim.api.nvim_create_user_command("QuarryExecute", function(command)
    query.execute(vim.api.nvim_get_current_buf(), M.config, visual_selection(command))
  end, { range = true, desc = "Execute the selected Quarry statement" })
  vim.api.nvim_create_user_command("QuarryCancel", function()
    query.cancel(vim.api.nvim_get_current_buf())
  end, { desc = "Cancel the current Quarry statement" })
  vim.api.nvim_create_user_command("QuarrySelectProfile", function()
    query.select_profile(vim.api.nvim_get_current_buf(), M.config)
  end, { desc = "Select the Quarry profile for this buffer" })
  vim.api.nvim_create_user_command("QuarryProfile", function()
    query.select_profile(vim.api.nvim_get_current_buf(), M.config)
  end, { desc = "Search and bind a Quarry profile" })
  vim.api.nvim_create_user_command("QuarryBrowse", function(command)
    if command.bang and workspace.focus_filter() then
      return
    end
    browser.open(M.config, command.args ~= "" and command.args or nil, vim.api.nvim_get_current_buf(), command.bang)
  end, { bang = true, nargs = "?", desc = "Browse a Quarry schema" })
  vim.api.nvim_create_user_command("QuarryProfiles", function()
    local profiles = require("quarry.profiles")
    local ok, err = profiles.ensure(M.config.profile_path)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    vim.cmd.edit(M.config.profile_path)
  end, { desc = "Edit Quarry connection profiles" })
  vim.api.nvim_create_user_command("QuarryWorkspace", function()
    workspace.open(M.config)
  end, { desc = "Open Quarry workspace" })
  vim.api.nvim_create_user_command("QuarryWorkspaceClose", function()
    workspace.close()
  end, { desc = "Close Quarry workspace" })
end

local function define_highlights()
  local links = {
    QuarryError = "DiagnosticError",
    QuarryHeader = "Title",
    QuarryHint = "Comment",
    QuarryLoading = "Comment",
    QuarryNull = "Special",
    QuarryProfile = "Identifier",
    QuarryColumn = "Type",
    QuarryTable = "Function",
    QuarryView = "Constant",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { default = true, link = target })
  end
end

local function apply_keymaps(buffer)
  local keymaps = M.config.keymaps
  if type(keymaps) ~= "table" or vim.b[buffer].quarry_keymaps then
    return
  end
  local commands = {
    browse = "QuarryBrowse",
    cancel = "QuarryCancel",
    execute = "QuarryExecute",
    select_profile = "QuarrySelectProfile",
    workspace = "QuarryWorkspace",
  }
  for action, lhs in pairs(keymaps) do
    local command = commands[action]
    if command and type(lhs) == "string" then
      local options = {
        buffer = buffer,
        desc = "Quarry " .. action:gsub("_", " "),
        silent = true,
      }
      vim.keymap.set("n", lhs, "<Cmd>" .. command .. "<CR>", options)
      if action == "execute" then
        vim.keymap.set("x", lhs, ":<C-u>'<,'>" .. command .. "<CR>", options)
      end
    end
  end
  vim.b[buffer].quarry_keymaps = true
end

local function apply_completion(buffer)
  if vim.b[buffer].quarry_profile then
    require("quarry.completion").attach(buffer)
  end
end

local function configure_ux()
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("QuarryHighlights", { clear = true }),
    callback = define_highlights,
  })
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("QuarryKeymaps", { clear = true }),
    pattern = "sql",
    callback = function(event)
      apply_keymaps(event.buf)
      apply_completion(event.buf)
      if M.config.winbar then
        vim.wo.winbar = status_winbar
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = vim.api.nvim_create_augroup("QuarryWinbar", { clear = true }),
    callback = function()
      if M.config.winbar and vim.bo.filetype == "sql" then
        vim.wo.winbar = status_winbar
      end
    end,
  })
end

local function apply_ux_to_buffers()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buffer].filetype == "sql" then
      apply_keymaps(buffer)
      apply_completion(buffer)
      if M.config.winbar then
        for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
          vim.wo[window].winbar = status_winbar
        end
      end
    end
  end
end

local function apply_workspace_keymap()
  local keymaps = M.config.keymaps
  if type(keymaps) == "table" and type(keymaps.workspace) == "string" then
    if workspace_mapping and workspace_mapping ~= keymaps.workspace then
      pcall(vim.keymap.del, "n", workspace_mapping)
    end
    vim.keymap.set("n", keymaps.workspace, "<Cmd>QuarryWorkspace<CR>", {
      desc = "Quarry workspace",
      silent = true,
    })
    workspace_mapping = keymaps.workspace
  elseif workspace_mapping then
    pcall(vim.keymap.del, "n", workspace_mapping)
    workspace_mapping = nil
  end
end

function M.setup(options)
  if options and options.default_profile and not default_profile_warned then
    vim.notify("Quarry removed default_profile; bind each query buffer explicitly", vim.log.levels.WARN, { title = "Quarry" })
    default_profile_warned = true
  end
  M.config = vim.tbl_deep_extend("force", M.config, options or {})
  M.config.default_profile = nil
  if not configured then
    _G.QuarryComplete = function(findstart, base)
      return require("quarry.completion").omnifunc(findstart, base)
    end
    create_commands()
    configure_ux()
    configured = true
  end
  apply_ux_to_buffers()
  apply_workspace_keymap()
end

function M.status(buffer)
  return require("quarry.query").status(buffer or vim.api.nvim_get_current_buf(), M.config)
end

return M
