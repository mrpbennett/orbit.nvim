local M = {}
local status_winbar = "%{luaeval(\"require('orbit').status()\")}"

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
		collapsed = ">",
		column = "󰠵",
		expanded = "󰘖",
		folder = "󰉋",
		index = "",
		key = "",
		profile = "󰆼",
		query = "󰆋",
		result = "󰎟",
		saved_query = "󰆼",
		table = "󰓫",
		view = "󰈈",
		workspace = "󱓞",
	},
	profile_path = vim.fn.expand("~/.local/share/orbit.nvim/profiles.json"),
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
	-- Ex command ranges are inclusive, 1-based buffer rows, matching statements.target's contract.
	if command.range == 0 then
		return nil
	end
	return { start_row = command.line1, end_row = command.line2 }
end

local function create_commands()
	local query = require("orbit.query")
	local browser = require("orbit.browser")
	local workspace = require("orbit.workspace")

	vim.api.nvim_create_user_command("OrbitExecute", function(command)
		query.execute(vim.api.nvim_get_current_buf(), M.config, visual_selection(command))
	end, { range = true, desc = "Execute the selected Orbit statement" })
	vim.api.nvim_create_user_command("OrbitCancel", function()
		query.cancel(vim.api.nvim_get_current_buf())
	end, { desc = "Cancel the current Orbit statement" })
	vim.api.nvim_create_user_command("OrbitDisconnect", function()
		query.disconnect(vim.api.nvim_get_current_buf())
	end, { desc = "Close the current Orbit connection" })
	vim.api.nvim_create_user_command("OrbitSelectProfile", function()
		query.select_profile(vim.api.nvim_get_current_buf(), M.config)
	end, { desc = "Select the Orbit profile for this buffer" })
	vim.api.nvim_create_user_command("OrbitProfile", function()
		query.select_profile(vim.api.nvim_get_current_buf(), M.config)
	end, { desc = "Search and bind an Orbit profile" })
	vim.api.nvim_create_user_command("OrbitBrowse", function(command)
		if command.bang and workspace.focus_filter() then
			return
		end
		browser.open(M.config, command.args ~= "" and command.args or nil, vim.api.nvim_get_current_buf(), command.bang)
	end, { bang = true, nargs = "?", desc = "Browse an Orbit schema" })
	vim.api.nvim_create_user_command("OrbitProfiles", function()
		local profiles = require("orbit.profiles")
		local ok, err = profiles.ensure(M.config.profile_path)
		if not ok then
			vim.notify(err, vim.log.levels.ERROR)
			return
		end
		vim.cmd.edit(M.config.profile_path)
	end, { desc = "Edit Orbit connection profiles" })
	vim.api.nvim_create_user_command("OrbitWorkspace", function()
		workspace.open(M.config)
	end, { desc = "Open Orbit workspace" })
	vim.api.nvim_create_user_command("OrbitWorkspaceClose", function()
		workspace.close()
	end, { desc = "Close Orbit workspace" })
end

local function define_highlights()
	local links = {
		OrbitError = "DiagnosticError",
		OrbitHeader = "Title",
		OrbitHint = "Comment",
		OrbitLoading = "Comment",
		OrbitNull = "Special",
		OrbitProfile = "Identifier",
		OrbitColumn = "Type",
		OrbitTable = "Function",
		OrbitView = "Constant",
	}
	for group, target in pairs(links) do
		vim.api.nvim_set_hl(0, group, { default = true, link = target })
	end
end

local function apply_keymaps(buffer)
	local keymaps = M.config.keymaps
	-- Do not duplicate buffer-local mappings when setup or FileType runs again.
	if type(keymaps) ~= "table" or vim.b[buffer].orbit_keymaps then
		return
	end
	local commands = {
		browse = "OrbitBrowse",
		cancel = "OrbitCancel",
		execute = "OrbitExecute",
		select_profile = "OrbitSelectProfile",
		workspace = "OrbitWorkspace",
	}
	for action, lhs in pairs(keymaps) do
		local command = commands[action]
		if command and type(lhs) == "string" then
			local options = {
				buffer = buffer,
				desc = "Orbit " .. action:gsub("_", " "),
				silent = true,
			}
			vim.keymap.set("n", lhs, "<Cmd>" .. command .. "<CR>", options)
			if action == "execute" then
				-- Visual execution passes the selected line range through the Ex command.
				vim.keymap.set("x", lhs, ":<C-u>'<,'>" .. command .. "<CR>", options)
			end
		end
	end
	vim.b[buffer].orbit_keymaps = true
end

local function apply_completion(buffer)
	if vim.b[buffer].orbit_profile then
		require("orbit.completion").attach(buffer)
	end
end

local function configure_ux()
	define_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("OrbitHighlights", { clear = true }),
		callback = define_highlights,
	})
	vim.api.nvim_create_autocmd("FileType", {
		group = vim.api.nvim_create_augroup("OrbitKeymaps", { clear = true }),
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
		group = vim.api.nvim_create_augroup("OrbitWinbar", { clear = true }),
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
		-- Reconfiguration must not leave the previous global mapping behind.
		if workspace_mapping and workspace_mapping ~= keymaps.workspace then
			pcall(vim.keymap.del, "n", workspace_mapping)
		end
		vim.keymap.set("n", keymaps.workspace, "<Cmd>OrbitWorkspace<CR>", {
			desc = "Orbit workspace",
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
		vim.notify(
			"Orbit removed default_profile; bind each query buffer explicitly",
			vim.log.levels.WARN,
			{ title = "Orbit" }
		)
		default_profile_warned = true
	end
	M.config = vim.tbl_deep_extend("force", M.config, options or {})
	M.config.default_profile = nil
	if not configured then
		-- Commands and autocommands are registered once; current SQL buffers are updated below.
		_G.OrbitComplete = function(findstart, base)
			return require("orbit.completion").omnifunc(findstart, base)
		end
		create_commands()
		configure_ux()
		configured = true
	end
	apply_ux_to_buffers()
	apply_workspace_keymap()
end

function M.status(buffer)
	return require("orbit.query").status(buffer or vim.api.nvim_get_current_buf(), M.config)
end

return M
