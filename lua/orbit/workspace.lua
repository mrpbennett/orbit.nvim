local profiles = require("orbit.profiles")
local schema_tree = require("orbit.schema_tree")
local cache = require("orbit.schema_cache")
local feedback = require("orbit.feedback")
local results = require("orbit.results")
local adapters = require("orbit.adapters")
local runner = require("orbit.runner")

local M = {}
local workspaces = {}
local fallback_icons = {
  collapsed = ">",
  column = ":",
  expanded = "v",
  folder = "+",
  profile = "@",
  query = "+",
  result = "=",
  saved_query = "#",
  table = "#",
  view = "~",
  workspace = "*",
}

local function set_content(state, lines)
  -- on_lines must distinguish this redraw from an edit to the filter input.
  state.rendering = true
  vim.bo[state.sidebar].modifiable = true
  vim.api.nvim_buf_set_lines(state.sidebar, 2, -1, false, lines)
  if not state.filtering then
    vim.bo[state.sidebar].modifiable = false
  end
  state.rendering = false
end

local function filter_text(state)
  local line = vim.api.nvim_buf_get_lines(state.sidebar, 1, 2, false)[1] or "Filter: "
  return line:sub(#"Filter: " + 1)
end

local object_name = schema_tree.object_name

local function discover_saved_queries(directory)
  local function scan(path)
    local handle = vim.uv.fs_scandir(path)
    if not handle then
      return {}
    end

    local entries = {}
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local entry_path = path .. "/" .. name
      if kind == "directory" then
        local children = scan(entry_path)
        -- Empty directories add no actionable node, while directories sort before SQL files.
        if #children > 0 then
          table.insert(entries, { kind = "saved_directory", name = name, path = entry_path, children = children })
        end
      elseif kind == "file" and name:lower():sub(-4) == ".sql" then
        table.insert(entries, { kind = "saved_query", name = name, path = entry_path })
      end
    end
    table.sort(entries, function(left, right)
      if left.kind ~= right.kind then
        return left.kind == "saved_directory"
      end
      return left.name:lower() < right.name:lower()
    end)
    return entries
  end

  return scan(directory)
end

local function saved_query_matches(node, filter)
  if filter == "" or node.name:lower():find(filter:lower(), 1, true) then
    return true
  end
  for _, child in ipairs(node.children or {}) do
    if saved_query_matches(child, filter) then
      return true
    end
  end
  return false
end

local function render(state)
  local icons = vim.tbl_extend("force", fallback_icons, state.config.icons or {})
  local lines = {
    "press ? to toggle help",
    "Filter: " .. state.filter,
    icons.workspace .. " Orbit Workspace",
    "",
    "Profiles:",
  }
  local highlights = { { group = "OrbitHeader", line = 2 } }
  -- Nodes are keyed by rendered buffer line so mappings can resolve the cursor without parsing text.
  state.nodes = {}
  for _, profile in ipairs(state.profiles) do
    local expanded = state.schema_profile == profile.name
    local profile_matches = state.filter == "" or profile.name:lower():find(state.filter:lower(), 1, true) or profile.kind:lower():find(state.filter:lower(), 1, true)
    local tree_lines, tree_nodes, tree_highlights, has_matches = {}, {}, {}, false
    if expanded then
      tree_lines, tree_nodes, tree_highlights, has_matches = schema_tree.lines(state.tree, profile, profile_matches and "" or state.filter, { icons = icons, loading = state.loading })
    end
    if profile_matches or (expanded and has_matches) then
      table.insert(lines, string.format("  %s %s %s (%s)", expanded and icons.expanded or icons.collapsed, icons.profile, profile.name, profile.kind))
      state.nodes[#lines] = { kind = "profile", profile = profile }
      table.insert(highlights, { group = "OrbitProfile", line = #lines })
    end
    if expanded and (profile_matches or has_matches) then
      local base = #lines
      for _, line in ipairs(tree_lines) do
        table.insert(lines, "    " .. line)
      end
      for line_number, node in pairs(tree_nodes) do
        state.nodes[base + line_number] = node
      end
      for _, highlight in ipairs(tree_highlights) do
        table.insert(highlights, { group = highlight.group, line = base + highlight.line })
      end
    end
  end
  if state.saved_query_dir then
    table.insert(lines, "")
    table.insert(lines, "Saved queries:")
    local root = {
      children = state.saved_queries,
      kind = "saved_directory",
      name = vim.fn.fnamemodify(state.saved_query_dir, ":t"),
      path = state.saved_query_dir,
    }
    local function render_saved(node, depth)
      if not saved_query_matches(node, state.filter) then
        return
      end
      if node.kind == "saved_directory" then
        local expanded = state.expanded_saved_dirs[node.path] or state.filter ~= ""
        table.insert(lines, string.format("%s%s %s %s", string.rep("  ", depth), expanded and icons.expanded or icons.collapsed, icons.folder, node.name))
        state.nodes[#lines] = node
        if expanded then
          if #node.children == 0 then
            table.insert(lines, string.rep("  ", depth + 1) .. "No saved SQL files")
          else
            for _, child in ipairs(node.children) do
              render_saved(child, depth + 1)
            end
          end
        end
      else
        table.insert(lines, string.format("%s%s %s", string.rep("  ", depth), icons.saved_query, node.name))
        state.nodes[#lines] = node
      end
    end
    render_saved(root, 1)
  end
  set_content(state, vim.list_slice(lines, 3, #lines))
  vim.api.nvim_buf_clear_namespace(state.sidebar, -1, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.sidebar, -1, highlight.group, highlight.line - 1, 0, -1)
  end
end

local function ensure_query_window(state)
  if vim.api.nvim_win_is_valid(state.query_window) then
    return state.query_window
  end
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    local buffer = vim.api.nvim_win_get_buf(window)
    if window ~= state.sidebar_window and vim.bo[buffer].filetype ~= "orbit-results" then
      state.query_window = window
      return window
    end
  end
  -- A workspace can survive after its query split closes, so recreate it only as a fallback.
  vim.api.nvim_set_current_win(state.sidebar_window)
  vim.cmd("rightbelow vsplit")
  state.query_window = vim.api.nvim_get_current_win()
  return state.query_window
end

local function load_schema(state, profile, force)
  if state.schema_notice then
    feedback.finish(state.schema_notice, "Schema load replaced", vim.log.levels.DEBUG)
  end
  state.generation = state.generation + 1
  local generation = state.generation
  local changed_profile = state.schema_profile ~= profile.name
  state.selected = profile
  state.schema_profile = profile.name
  if changed_profile then
    schema_tree.reset(state.tree)
  end
  state.loading = true
  render(state)
  state.schema_notice = feedback.start("Loading schema for " .. profile.name .. "...")
  cache.load_tables(profile, { refresh = force }, function(rows, err)
    -- Ignore callbacks from replaced loads and from a workspace that has been closed.
    if state.generation ~= generation or not vim.api.nvim_buf_is_valid(state.sidebar) then
      return
    end
    feedback.finish(state.schema_notice, err and "Schema load failed: " .. profile.name or string.format("Schema loaded: %d objects", #rows), err and vim.log.levels.ERROR or vim.log.levels.INFO)
    state.schema_notice = nil
    state.loading = false
    if not err then
      if force then
        schema_tree.reset(state.tree)
      end
      schema_tree.set_tables(state.tree, rows)
    end
    render(state)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    end
  end)
end

local function collapse_schema_tree(state)
  if not state.schema_profile then
    return
  end
  state.schema_profile = nil
  schema_tree.reset(state.tree)
  render(state)
end

local function reload_profiles(state)
  local document, load_err = profiles.load(state.config.profile_path)
  if not document then
    vim.notify(load_err, vim.log.levels.ERROR)
    return nil
  end
  state.profiles = document.profiles
  if state.selected then
    state.selected = profiles.find(document, state.selected.name)
  end
  if state.schema_profile and not profiles.find(document, state.schema_profile) then
    state.schema_profile = nil
    schema_tree.reset(state.tree)
  end
  return document
end

local function load_metadata(state, profile, row, category, show_progress)
  -- Loaded and loading are distinct: the latter coalesces requests, the former permits empty results.
  if schema_tree.is_metadata_loaded(state.tree, row, category.id) or schema_tree.is_metadata_loading(state.tree, row, category.id) then
    return
  end
  local generation = state.generation
  schema_tree.set_metadata_loading(state.tree, row, category.id, true)
  local notice = show_progress and feedback.start("Loading " .. category.label .. " for " .. object_name(row) .. "...")
  cache.load_metadata(profile, row, category.id, {}, function(entries, err)
    if state.generation ~= generation or not vim.api.nvim_buf_is_valid(state.sidebar) then
      return
    end
    schema_tree.set_metadata_loading(state.tree, row, category.id, nil)
    schema_tree.set_metadata(state.tree, row, category.id, err and {} or entries)
    if notice then
      feedback.finish(notice, err and category.label .. " load failed: " .. object_name(row) or string.format("%s loaded: %d", category.label, #entries), err and vim.log.levels.ERROR or vim.log.levels.INFO)
    end
    render(state)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    end
  end)
end

local function expand_metadata(state, profile, row, category)
  schema_tree.toggle(state.tree, { category = category, kind = "metadata", profile = profile, row = row })
  render(state)
  load_metadata(state, profile, row, category, true)
end

local function new_query(state)
  if not state.selected then
    vim.notify("Expand an Orbit profile before creating a query", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd("vnew")
  vim.bo.filetype = "sql"
  require("orbit.query").bind_profile(0, state.selected)
  vim.b.orbit_workspace_tab = state.tabpage
  vim.keymap.set("n", "/", function()
    M.focus_filter()
  end, { buffer = 0, silent = true, nowait = true, desc = "Filter Orbit workspace" })
end

local function configure_query_buffer(state, buffer)
  -- Workspace tagging routes later results back here and makes / target the sidebar filter.
  vim.b[buffer].orbit_workspace_tab = state.tabpage
  require("orbit.completion").attach(buffer)
  vim.keymap.set("n", "/", function()
    M.focus_filter()
  end, { buffer = buffer, silent = true, nowait = true, desc = "Filter Orbit workspace" })
end

local function open_generated_query(state, profile, statement, table)
  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd("new")
  local buffer = vim.api.nvim_get_current_buf()
  vim.bo[buffer].filetype = "sql"
  configure_query_buffer(state, buffer)
  require("orbit.query").bind_profile(buffer, profile)
  if table and table.type == "table" then
    vim.b[buffer].orbit_table = vim.deepcopy(table)
    vim.b[buffer].orbit_table_statement = statement
  end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(statement, "\n", { plain = true }))
end

local function run_object_action(state, profile, connector, row, action)
  if action.kind == "query_buffer" then
    -- Generated statements are editable; metadata actions execute immediately into the result grid.
    open_generated_query(state, profile, action.statement, row)
    return
  end
  local notice = feedback.start("Loading " .. action.label:lower() .. " for " .. object_name(row) .. "...")
	runner.run(profile, action.statement, function(rows, err)
    if workspaces[state.tabpage] ~= state or not vim.api.nvim_tabpage_is_valid(state.tabpage) then
      feedback.finish(notice, "Schema action discarded", vim.log.levels.DEBUG)
      return
    end
    if err then
      feedback.finish(notice, "Schema action failed: " .. action.label, vim.log.levels.ERROR)
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    feedback.finish(notice, string.format("Loaded %s: %d rows", action.label:lower(), #rows))
    M.open_results(rows, {
      limit = state.config.result_limit,
      max_cell_width = state.config.max_cell_width,
      profile_name = profile.name,
      source_name = action.label .. " / " .. object_name(row),
      source_window = state.query_window,
      tabpage = state.tabpage,
    })
	end, connector)
end

local function select_object_action(state, profile, row)
	local connector, err = adapters.connector(profile)
	if not connector then
		vim.notify(err, vim.log.levels.ERROR)
		return
	end
	local actions
	if connector.object_actions then
		actions, err = connector.object_actions(profile.options, row, state.config.result_limit)
	else
		err = "schema object actions are not supported for profile kind: " .. tostring(profile.kind)
	end
  if not actions then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  vim.ui.select(actions, {
    prompt = "Orbit action for " .. object_name(row),
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
			run_object_action(state, profile, connector, row, action)
    end
  end)
end

local function copy_object_name(profile, row)
  -- Connector-specific qualification produces an identifier that can be pasted back into SQL.
	local connector, err = adapters.connector(profile)
	if not connector then
		vim.notify(err, vim.log.levels.ERROR)
		return
	end
	local name = connector.qualified_name(profile.options, row)
  vim.fn.setreg('"', name)
  vim.notify("Orbit name copied")
end

local function open_saved_query(state, node)
  if not state.selected then
    vim.notify("Expand an Orbit profile before opening a saved query", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd.edit(vim.fn.fnameescape(node.path))
  local buffer = vim.api.nvim_get_current_buf()
  vim.bo[buffer].filetype = "sql"
  configure_query_buffer(state, buffer)
  require("orbit.query").bind_profile(buffer, state.selected)
end

local function preview_saved_query(node)
  local lines = vim.fn.readfile(node.path)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].filetype = "sql"
  vim.bo[buffer].modifiable = false
  local width = math.min(math.max(40, vim.o.columns - 8), 100)
  local height = math.min(math.max(3, #lines), math.max(3, vim.o.lines - 6))
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    col = math.floor((vim.o.columns - width) / 2),
    height = height,
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    title = " " .. node.name .. " ",
    title_pos = "center",
    width = width,
  })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(window, true)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit saved query preview" })
  end
end

local function focus_filter(state)
  vim.api.nvim_set_current_win(state.sidebar_window)
  state.filtering = true
  vim.bo[state.sidebar].modifiable = true
  vim.api.nvim_win_set_cursor(state.sidebar_window, { 2, #"Filter: " + #state.filter })
  vim.api.nvim_feedkeys("a", "n", false)
end

local function show_help(state)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Orbit Workspace",
    "",
    "Sidebar: <CR> bind/open, h/l collapse/expand, Z collapse schema, n new query, r refresh",
    "Table: s sample, a actions, y copy name. Saved query: P preview. / filter, q close",
    "Results: h/j/k/l cells, y copy, <CR> inspect, <C-d>/<C-u> page",
    "Use your normal Neovim window mappings to move between panels.",
  })
  vim.bo[buffer].modifiable = false
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    col = math.floor((vim.o.columns - 72) / 2),
    height = 5,
    relative = "editor",
    row = math.floor((vim.o.lines - 7) / 2),
    style = "minimal",
    title = " Orbit Help ",
    title_pos = "center",
    width = 72,
  })
  for _, key in ipairs({ "q", "?", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(window, true)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit help" })
  end
end

local function configure_sidebar(state)
  vim.api.nvim_buf_attach(state.sidebar, false, {
    on_lines = function()
      -- Only user edits to the first two lines update the filter and schedule a redraw.
      if vim.bo[state.sidebar].modifiable and not state.rendering then
        state.filter = filter_text(state)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(state.sidebar) then
            render(state)
          end
        end)
      end
    end,
  })
  vim.keymap.set("n", "/", function()
    focus_filter(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Filter Orbit workspace" })
  vim.keymap.set("i", "<Esc>", function()
    state.filtering = false
    vim.bo[state.sidebar].modifiable = false
    return "<Esc>"
  end, { buffer = state.sidebar, expr = true, silent = true, desc = "Finish Orbit filter" })
  local function current_node()
    return state.nodes[vim.api.nvim_win_get_cursor(state.sidebar_window)[1]]
  end
  local function current_expanded()
    local node = current_node()
    if not node then
      return false
    end
    if node.kind == "profile" then
      return state.schema_profile == node.profile.name
    end
    if node.kind == "saved_directory" then
      return state.expanded_saved_dirs[node.path]
    end
    return schema_tree.is_expanded(state.tree, node)
  end
  local function collapse_current()
    local node = current_node()
    if not node then
      return
    end
    if node.kind == "profile" and state.schema_profile == node.profile.name then
      state.schema_profile = nil
      schema_tree.reset(state.tree)
      render(state)
    elseif node.kind == "saved_directory" and state.expanded_saved_dirs[node.path] then
      state.expanded_saved_dirs[node.path] = nil
      render(state)
    elseif schema_tree.is_expanded(state.tree, node) then
      schema_tree.toggle(state.tree, node)
      render(state)
    end
  end
  local function expand_current()
    local node = current_node()
    if not node then
      return
    end
    if node.kind == "profile" and state.schema_profile ~= node.profile.name then
      load_schema(state, node.profile)
    elseif node.kind == "saved_directory" and not state.expanded_saved_dirs[node.path] then
      state.expanded_saved_dirs[node.path] = true
      render(state)
    elseif node.kind == "table" and not schema_tree.is_expanded(state.tree, node) then
      schema_tree.toggle(state.tree, node)
      render(state)
			local connector = adapters.connector(node.profile)
			for _, category in ipairs(connector and connector.metadata_categories and connector.metadata_categories(node.profile.options, node.row) or {}) do
        load_metadata(state, node.profile, node.row, category, false)
      end
    elseif node.kind == "metadata" and not schema_tree.is_expanded(state.tree, node) then
      expand_metadata(state, node.profile, node.row, node.category)
    elseif (node.kind == "schema" or node.kind == "group") and not schema_tree.is_expanded(state.tree, node) then
      schema_tree.toggle(state.tree, node)
      render(state)
    end
  end
  local function activate_current()
    local node = current_node()
    if node and node.kind == "profile" then
      state.selected = node.profile
      local target = state.binding_target or vim.api.nvim_win_get_buf(ensure_query_window(state))
      require("orbit.query").bind_profile(target, node.profile)
      local callback = state.binding_callback
      state.binding_target = nil
      state.binding_callback = nil
      if callback then
        callback(node.profile)
      end
    elseif node and node.kind == "saved_query" then
      open_saved_query(state, node)
    end
  end
  vim.keymap.set("n", "h", collapse_current, { buffer = state.sidebar, silent = true, nowait = true, desc = "Collapse Orbit node" })
  vim.keymap.set("n", "l", expand_current, { buffer = state.sidebar, silent = true, nowait = true, desc = "Expand Orbit node" })
  vim.keymap.set("n", "<CR>", activate_current, { buffer = state.sidebar, silent = true, nowait = true, desc = "Bind Orbit profile" })
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local position = vim.fn.getmousepos()
    if position.winid == state.sidebar_window and position.line > 0 then
      vim.api.nvim_win_set_cursor(state.sidebar_window, { position.line, 0 })
      local node = current_node()
      if node and node.kind == "profile" then
        -- Profile double-click both binds the profile and toggles its schema tree.
        activate_current()
      end
      if current_expanded() then
        collapse_current()
      else
        expand_current()
      end
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Activate Orbit node" })
  vim.keymap.set("n", "r", function()
    local node = current_node()
    if node and node.kind == "profile" then
      local document = reload_profiles(state)
      local profile = document and profiles.find(document, node.profile.name)
      if profile then
        load_schema(state, profile, true)
      elseif document then
        render(state)
      end
    elseif node and node.kind == "saved_directory" then
      state.saved_queries = discover_saved_queries(state.saved_query_dir)
      render(state)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Refresh Orbit profile" })
  vim.keymap.set("n", "n", function()
    new_query(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "New Orbit query" })
  vim.keymap.set("n", "Z", function()
    collapse_schema_tree(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Collapse Orbit schema tree" })
  vim.keymap.set("n", "s", function()
    local node = current_node()
    if node and node.kind == "table" then
			local connector, err = adapters.connector(node.profile)
			if not connector then
				vim.notify(err, vim.log.levels.ERROR)
				return
			end
			local actions
			if connector.object_actions then
				actions, err = connector.object_actions(node.profile.options, node.row, state.config.result_limit)
			else
				err = "schema object actions are not supported for profile kind: " .. tostring(node.profile.kind)
			end
			if not actions then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end
      for _, action in ipairs(actions) do
        if action.id == "sample" then
				run_object_action(state, node.profile, connector, node.row, action)
          return
        end
      end
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Open Orbit sample statement" })
  vim.keymap.set("n", "a", function()
    local node = current_node()
    if node and node.kind == "table" then
      select_object_action(state, node.profile, node.row)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Select Orbit schema object action" })
  vim.keymap.set("n", "y", function()
    local node = current_node()
    if node and node.kind == "table" then
      copy_object_name(node.profile, node.row)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Copy Orbit object name" })
  vim.keymap.set("n", "P", function()
    local node = current_node()
    if node and node.kind == "saved_query" then
      preview_saved_query(node)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Preview Orbit saved query" })
  vim.keymap.set("n", "?", function()
    show_help(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Show Orbit help" })
  vim.keymap.set("n", "q", function()
    M.close(state.tabpage)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Close Orbit workspace" })
end

local function toggle_sidebar(state)
  if vim.api.nvim_win_is_valid(state.sidebar_window) then
    vim.api.nvim_win_close(state.sidebar_window, false)
    return
  end

  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd("topleft vsplit")
  state.sidebar_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.sidebar_window, state.sidebar)
  vim.api.nvim_win_set_width(state.sidebar_window, state.config.workspace_sidebar_width or 32)
end

local function existing_workspace()
  -- Orbit intentionally keeps one workspace tabpage, reopening it instead of creating duplicates.
  for tabpage, state in pairs(workspaces) do
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.api.nvim_set_current_tabpage(tabpage)
      return state
    end
  end
end

function M.open(config)
  local state = existing_workspace()
  if state then
    toggle_sidebar(state)
    return state
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local query_window = vim.api.nvim_get_current_win()
  vim.bo.filetype = "sql"
  local sidebar = vim.api.nvim_create_buf(false, true)
  vim.cmd("topleft vsplit")
  local sidebar_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sidebar_window, sidebar)
  vim.api.nvim_win_set_width(sidebar_window, config.workspace_sidebar_width or 32)
  vim.bo[sidebar].filetype = "orbit-workspace"
  vim.api.nvim_set_current_win(query_window)

  local document = profiles.load(config.profile_path)
  local state = {
    config = config,
    expanded_saved_dirs = {},
    filter = "",
    filtering = false,
    generation = 0,
    loading = false,
    nodes = {},
    profiles = document and document.profiles or {},
    query_window = query_window,
    saved_queries = {},
    schema_profile = nil,
    selected = nil,
    sidebar = sidebar,
    sidebar_window = sidebar_window,
    tabpage = tabpage,
    tree = schema_tree.new(),
  }
  if type(config.saved_query_dir) == "string" and config.saved_query_dir ~= "" then
    state.saved_query_dir = vim.fn.fnamemodify(vim.fn.expand(config.saved_query_dir), ":p")
    state.saved_queries = discover_saved_queries(state.saved_query_dir)
    state.expanded_saved_dirs[state.saved_query_dir] = true
  end
  workspaces[tabpage] = state
  configure_query_buffer(state, vim.api.nvim_win_get_buf(query_window))
  vim.bo[sidebar].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar, 0, -1, false, { "press ? to toggle help", "Filter: " })
  vim.bo[sidebar].modifiable = false
  configure_sidebar(state)
  render(state)
  if not document then
    vim.notify("Orbit workspace opened without profiles", vim.log.levels.WARN)
  end
  return state
end

function M.open_results(rows, options)
  local state = workspaces[options.tabpage]
  options.height = math.max(6, math.floor(vim.o.lines * ((state and state.config.workspace_result_ratio) or 0.30)))
  options.on_quit = function(_, source_window)
    -- The workspace owns result geometry and returns focus to the originating query split.
    if vim.api.nvim_win_is_valid(source_window) then
      vim.api.nvim_set_current_win(source_window)
    end
  end
  return results.open(rows, options)
end

function M.close(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local state = workspaces[tabpage]
  if not state then
    return
  end
  workspaces[tabpage] = nil
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabclose")
  end
end

function M.is_workspace(tabpage)
  return workspaces[tabpage or vim.api.nvim_get_current_tabpage()] ~= nil
end

function M.focus_filter()
  local state = workspaces[vim.api.nvim_get_current_tabpage()]
  if state then
    focus_filter(state)
    return true
  end
  return false
end

function M.select_profile(config, buffer, on_select)
  local state = existing_workspace() or M.open(config)
  local document = reload_profiles(state)
  if document then
    render(state)
  end
  state.binding_target = buffer
  -- Binding is deferred until the profile node is activated in the shared workspace picker.
  state.binding_callback = on_select
  focus_filter(state)
end

return M
