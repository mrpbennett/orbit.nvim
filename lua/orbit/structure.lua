-- ============================================================================
-- Structure panel
-- ============================================================================
-- Owns the Neovim-facing half of the Structure panel. The pure SQL model in
-- `orbit.sql.structure` turns query-buffer lines into a tree; this module keeps
-- one panel per tabpage, renders that tree into a scratch buffer, and translates
-- panel actions back into source-buffer navigation.
--
-- Keeping parsing out of this module is intentional. Window callbacks can ask
-- for a fresh outline without knowing SQL grammar, while parser tests can cover
-- SQL behavior without creating Neovim windows.
-- ============================================================================
local outline = require("orbit.sql.structure")

local M = {}

-- Panel state is keyed by tabpage because a user may keep independent Structure
-- panels open in several tabs. Each state owns its panel window/buffer, tracks
-- one visible SQL source buffer, and stores the rendered line lookup tables used
-- by keyboard navigation.
local states = {}
-- Neovim buffer attachments are channel-wide and should only be installed once
-- per source buffer. Their callbacks do not capture panel state; they fan buffer
-- changes out through M.changed so every tab showing that buffer can refresh.
local attached_buffers = {}

-- DataGrip-compatible statement categories have a fixed presentation order.
-- Keeping that order here also gives unrecognized SQL a predictable final group.
local category_order = { "DDL", "DML", "SELECT", "Other" }

-- Select a semantic icon independently from the disclosure marker. Statement
-- categories need distinct icons because category grouping can be disabled.
local function icon_for(node, icons)
	if node.kind == "group" then
		return icons.folder
	end
	if node.kind == "statement" then
		return icons["statement_" .. node.category:lower()]
	end
	if node.kind == "query" then
		return icons.query_block
	end
	return icons[node.kind]
end

-- Return whether a possibly-nil window handle still names a live Neovim window.
-- Centralizing this guard keeps stale handles from reaching stricter API calls.
local function valid_window(window)
	return window and vim.api.nvim_win_is_valid(window)
end

-- Resolve the Structure state for a tabpage and discard it if the user removed
-- or repurposed the panel outside Orbit (for example with `:close` or `:buffer`).
--
-- Params: tabpage - Neovim tabpage handle.
-- Returns: the live state table, or nil when no usable panel remains.
-- Side effects: removes stale entries from the module-local `states` table.
local function state_for(tabpage)
	local state = states[tabpage]
	if state and not vim.api.nvim_tabpage_is_valid(tabpage) then
		states[tabpage] = nil
		return nil
	end
	if state and state.window and not valid_window(state.window) then
		states[tabpage] = nil
		return nil
	end
	if
		state
		and state.buffer
		and (not vim.api.nvim_buf_is_valid(state.buffer) or vim.api.nvim_win_get_buf(state.window) ~= state.buffer)
	then
		states[tabpage] = nil
		return nil
	end
	return state
end

-- Fit fixed panel chrome into a display width without splitting a multibyte character.
-- `strcharpart` counts characters while `strdisplaywidth` accounts for glyphs
-- that occupy more than one terminal cell. Widths of three or less use only
-- dots because a full three-character ellipsis suffix would not fit.
--
-- Params: text - rendered text; width - available terminal cells.
-- Returns: text unchanged when it fits, otherwise a display-safe abbreviation.
local function truncate(text, width)
	if width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	if width <= 3 then
		return string.rep(".", width)
	end
	local length = math.max(width - 3, 0)
	while length > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, length)) > width - 3 do
		length = length - 1
	end
	return vim.fn.strcharpart(text, 0, length) .. "..."
end

-- Find the deepest outline node containing the source window's cursor. A source
-- buffer can be displayed in more than one window, so the remembered source
-- window is part of state and must still show the remembered source buffer.
--
-- Params: state - live Structure panel state.
-- Returns: an outline node, or nil when no usable source cursor exists.
local function source_cursor(state)
	if not valid_window(state.source_window) or vim.api.nvim_win_get_buf(state.source_window) ~= state.source_buffer then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(state.source_window)
	return outline.at(state.entries, cursor[1], cursor[2])
end

-- Register every parent node discovered by a parse. A node is collapsed only
-- the first time its stable ID appears; IDs already known to this source keep
-- the user's expanded/collapsed choice across live refreshes. Tracking known
-- IDs separately matters because `collapsed[id] == nil` means explicitly
-- expanded as well as unseen.
--
-- Params: state - panel state; reset - true when attaching a different source.
-- Returns: nothing.
-- Side effects: updates `state.collapsed` and `state.known_parents`.
local function register_parents(state, reset)
	if reset then
		state.collapsed = {}
		state.known_parents = {}
	end
	local function visit(node)
		if #node.children > 0 then
			if not state.known_parents[node.id] then
				state.known_parents[node.id] = true
				state.collapsed[node.id] = true
			end
			for _, child in ipairs(node.children) do
				visit(child)
			end
		end
	end
	for _, entry in ipairs(state.entries) do
		visit(entry)
	end
end

-- Build the top-level rows selected by the Structure view options. Parser nodes
-- remain untouched; category nodes exist only so the renderer can reuse its
-- normal tree traversal and expansion behavior for grouped statements.
local function view_entries(state)
	local visible = {}
	for _, entry in ipairs(state.entries) do
		if state.show_categories[entry.category] then
			table.insert(visible, entry)
		end
	end
	if state.sort_alphabetically then
		table.sort(visible, function(left, right)
			local left_label = left.label:lower()
			local right_label = right.label:lower()
			if left_label == right_label then
				return left.start_row < right.start_row
			end
			return left_label < right_label
		end)
	end
	if not state.group_by_type then
		return visible
	end

	local groups = {}
	for _, category in ipairs(category_order) do
		groups[category] = {}
	end
	for _, entry in ipairs(visible) do
		table.insert(groups[entry.category], entry)
	end
	local grouped = {}
	for _, category in ipairs(category_order) do
		if #groups[category] > 0 then
			table.insert(grouped, {
				id = "structure-group:" .. category,
				kind = "group",
				label = category,
				category = category,
				children = groups[category],
			})
		end
	end
	return grouped
end

-- Render the current outline into the panel scratch buffer.
--
-- The renderer builds three lookup tables in one pass:
--   * `nodes[line]` maps a visible panel line to its node and visible parent.
--   * `id_to_line[id]` lets h/l restore or move selection by stable node ID.
--   * `parents[id]` includes hidden descendants, allowing the source highlight
--     to fall back to the nearest visible ancestor of a collapsed node.
--
-- Filtering ignores collapse state and keeps every matching node plus its
-- ancestors. Children that do not match are omitted, which prevents a matching
-- statement preview from flooding the panel with its entire subtree.
--
-- Params:
--   state       - live Structure panel state.
--   selected_id - optional node ID whose panel selection should survive redraw.
-- Returns: nothing.
-- Side effects: rewrites/highlights the scratch buffer and may move its cursor.
local function render(state, selected_id)
	if not vim.api.nvim_buf_is_valid(state.buffer) then
		return
	end
	local lines = {
		truncate("Structure", state.width),
		truncate(state.filter == "" and "Filter: /" or "Filter: " .. state.filter, state.width),
		"",
	}
	local nodes = {}
	local highlights = {
		{ line = 1, group = "OrbitHeader" },
		{ line = 2, group = "OrbitHint" },
	}
	local current = source_cursor(state)
	local current_id = current and current.id or nil
	local id_to_line = {}
	local parents = {}
	if not state.source_buffer or not vim.api.nvim_buf_is_valid(state.source_buffer) then
		table.insert(lines, "No query buffer")
		table.insert(highlights, { line = #lines, group = "OrbitHint" })
	elseif #state.entries == 0 then
		table.insert(lines, "No statements")
		table.insert(highlights, { line = #lines, group = "OrbitHint" })
	else
		local filter = state.filter:lower()
		-- A node remains visible when it or any descendant matches. This recursive
		-- test is what preserves the path from a matching CTE back to its statement.
		local function matches(node)
			-- Category groups are presentation controls, not statement labels. They
			-- preserve matching paths but never satisfy the text filter themselves.
			local direct = node.kind ~= "group" and node.label:lower():find(filter, 1, true)
			if filter == "" or direct then
				return true
			end
			for _, child in ipairs(node.children) do
				if matches(child) then
					return true
				end
			end
			return false
		end
		-- Record the complete parent graph before rendering. Collapsed descendants
		-- are absent from `nodes`, but source-cursor fallback still needs their path.
		local function index_parents(node, parent_id)
			parents[node.id] = parent_id
			for _, child in ipairs(node.children) do
				index_parents(child, node.id)
			end
		end
		-- Flatten one visible subtree into buffer lines. Collapse state applies only
		-- without a filter; filtered results are always expanded enough to reveal
		-- every matching path.
		local function add_node(node, depth, parent_id, statement)
			if not matches(node) then
				return
			end
			if node.kind == "statement" then
				statement = node
			end
			local has_children = #node.children > 0
			local collapsed = filter == "" and state.collapsed[node.id]
			local marker = "  "
			if has_children then
				marker = collapsed and state.icons.collapsed or state.icons.expanded
				marker = marker .. " "
			end
			local prefix = string.rep("  ", depth) .. marker .. icon_for(node, state.icons) .. " "
			-- Keep SQL labels intact; nowrap plus horizontal scrolling makes content
			-- inspectable without changing the panel's configured geometry.
			table.insert(lines, prefix .. node.label)
			nodes[#lines] = { node = node, parent_id = parent_id, statement = statement }
			id_to_line[node.id] = #lines
			if has_children and not collapsed then
				for _, child in ipairs(node.children) do
					add_node(child, depth + 1, node.id, statement)
				end
			end
		end
		for _, entry in ipairs(view_entries(state)) do
			index_parents(entry, nil)
			add_node(entry, 0, nil, nil)
		end
		if next(nodes) == nil then
			table.insert(lines, "No matches")
			table.insert(highlights, { line = #lines, group = "OrbitHint" })
		end
	end

	state.nodes = nodes
	state.id_to_line = id_to_line
	state.parents = parents
	vim.bo[state.buffer].modifiable = true
	vim.api.nvim_buf_set_lines(state.buffer, 0, -1, false, lines)
	vim.bo[state.buffer].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.buffer, -1, 0, -1)
	for _, highlight in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(state.buffer, -1, highlight.group, highlight.line - 1, 0, -1)
	end
	-- If the deepest source node is hidden by a collapsed parent, highlight that
	-- nearest visible parent instead of losing source position feedback entirely.
	local highlight_id = current_id
	while highlight_id and not id_to_line[highlight_id] do
		highlight_id = parents[highlight_id]
	end
	if highlight_id then
		vim.api.nvim_buf_add_highlight(state.buffer, -1, "OrbitStructureCurrent", id_to_line[highlight_id] - 1, 0, -1)
	end
	-- Explicit tree actions preserve their selected node. Ordinary refreshes track
	-- the source cursor, matching the panel's role as an outline of that buffer.
	local target_id = selected_id or highlight_id
	if target_id and valid_window(state.window) then
		vim.api.nvim_win_set_cursor(state.window, { id_to_line[target_id], 0 })
	end
end

-- Coalesce multiple source edits into one scheduled parse/render cycle. Neovim
-- can report several line changes during one operation; reparsing synchronously
-- for each callback would waste work and visibly churn the panel.
--
-- Params: state - live Structure panel state.
-- Returns: nothing.
-- Side effects: schedules an outline rebuild and panel redraw.
local function refresh(state)
	if state.refresh_pending then
		return
	end
	state.refresh_pending = true
	vim.schedule(function()
		state.refresh_pending = false
		if not state_for(state.tabpage) then
			return
		end
		if state.source_buffer and vim.api.nvim_buf_is_valid(state.source_buffer) then
			state.entries = outline.extract(vim.api.nvim_buf_get_lines(state.source_buffer, 0, -1, false), vim.b[state.source_buffer].orbit_sql_dialect)
			state.source_changedtick = vim.api.nvim_buf_get_changedtick(state.source_buffer)
			register_parents(state, false)
		else
			state.entries = {}
			state.source_buffer = nil
			state.source_window = nil
		end
		render(state)
	end)
end

-- Make a SQL buffer the panel's source and ensure Orbit observes API-driven as
-- well as interactive edits. Reattaching the same source only updates which
-- source window receives navigation, preserving the already-built model.
--
-- Params:
--   state  - live Structure panel state.
--   buffer - SQL buffer handle to parse and watch.
--   window - window currently showing that buffer.
-- Returns: nothing.
-- Side effects: updates state, may attach Neovim buffer callbacks, and redraws.
local function attach_source(state, buffer, window)
	if state.source_buffer == buffer then
		state.source_window = window
		render(state)
		return
	end
	state.source_buffer = buffer
	state.source_window = window
	state.entries = outline.extract(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), vim.b[buffer].orbit_sql_dialect)
	state.source_changedtick = vim.api.nvim_buf_get_changedtick(buffer)
	register_parents(state, true)
	if not attached_buffers[buffer] then
		attached_buffers[buffer] = true
		vim.api.nvim_buf_attach(buffer, false, {
			on_lines = function(_, changed_buffer)
				M.changed(changed_buffer)
			end,
			on_detach = function(_, detached_buffer)
				attached_buffers[detached_buffer] = nil
				M.source_gone(detached_buffer)
			end,
		})
	end
	render(state)
end

-- Find a window suitable for navigation back to the source buffer. Prefer the
-- remembered window, then another window already showing the source. As a last
-- resort, reuse an ordinary editor window but never replace Orbit's panel,
-- result grid, or Workspace schema browser.
--
-- Params: state - live Structure panel state.
-- Returns: a valid source/editor window handle, or nil when none is available.
-- Side effects: the fallback path may place the source buffer into a window.
local function source_window(state)
	if valid_window(state.source_window) and vim.api.nvim_win_get_buf(state.source_window) == state.source_buffer then
		return state.source_window
	end
	for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
		if window ~= state.window and vim.api.nvim_win_get_buf(window) == state.source_buffer then
			return window
		end
	end
	for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
		local filetype = vim.bo[vim.api.nvim_win_get_buf(window)].filetype
		if window ~= state.window and filetype ~= "orbit-results" and filetype ~= "orbit-workspace" then
			vim.api.nvim_win_set_buf(window, state.source_buffer)
			return window
		end
	end
	return nil
end

-- Navigate from the selected panel node to that element's first meaningful SQL
-- token. Rendered text is never parsed; `state.nodes` carries the source range
-- produced by the pure outline model.
--
-- Params: state - live Structure panel state.
-- Returns: nothing.
-- Side effects: focuses a source window, moves its cursor, and redraws the panel.
local function navigate(state)
	local row = vim.api.nvim_win_get_cursor(state.window)[1]
	local selected = state.nodes[row]
	if
		not selected
		or selected.node.kind == "group"
		or not state.source_buffer
		or not vim.api.nvim_buf_is_valid(state.source_buffer)
	then
		return
	end
	local window = source_window(state)
	if not window then
		return
	end
	state.source_window = window
	vim.api.nvim_set_current_win(window)
	vim.api.nvim_win_set_cursor(window, { selected.node.start_row, selected.node.start_col })
	render(state)
end

-- Execute the source range represented by the selected Structure row. Complete
-- statements, query blocks, and SELECT clauses keep their exact parser range;
-- navigation-only rows fall back to the statement that owns them.
local function execute(state, config)
	local selected = state.nodes[vim.api.nvim_win_get_cursor(state.window)[1]]
	if not selected or not state.source_buffer or not vim.api.nvim_buf_is_valid(state.source_buffer) then
		return
	end
	if state.source_changedtick ~= vim.api.nvim_buf_get_changedtick(state.source_buffer) then
		local selected_id = selected.node.id
		state.entries = outline.extract(vim.api.nvim_buf_get_lines(state.source_buffer, 0, -1, false), vim.b[state.source_buffer].orbit_sql_dialect)
		state.source_changedtick = vim.api.nvim_buf_get_changedtick(state.source_buffer)
		register_parents(state, false)
		local still_present = false
		local function find(node)
			still_present = still_present or node.id == selected_id
			for _, child in ipairs(node.children) do
				find(child)
			end
		end
		for _, entry in ipairs(state.entries) do
			find(entry)
		end
		if not still_present then
			render(state)
			vim.notify("Structure changed; select an element again", vim.log.levels.WARN)
			return
		end
		render(state)
		local selected_line = state.id_to_line[selected_id]
		if not selected_line then
			vim.notify("Structure changed; select an element again", vim.log.levels.WARN)
			return
		end
		vim.api.nvim_win_set_cursor(state.window, { selected_line, 0 })
		selected = state.nodes[selected_line]
	end
	local node = selected.node
	if node.kind ~= "statement" and node.kind ~= "query" and not (node.kind == "clause" and node.clause == "SELECT") then
		node = selected.statement
	end
	local window = source_window(state)
	if not node or not window then
		return
	end
	state.source_window = window
	require("orbit.query").execute(
		state.source_buffer,
		config,
		{
			start_row = node.start_row,
			start_col = node.start_col,
			end_row = node.end_row,
			end_col = node.end_col,
		},
		{
			source_changedtick = state.source_changedtick,
			source_window = window,
			tabpage = state.tabpage,
			trigger_window = state.window,
		}
	)
end

-- Move the panel cursor to a currently visible stable node ID.
-- Missing IDs are expected while filtering and are therefore a no-op.
local function move_to(state, id)
	local line = state.id_to_line[id]
	if line and valid_window(state.window) then
		vim.api.nvim_win_set_cursor(state.window, { line, 0 })
	end
end

-- Implement the tree's `l` action. A collapsed node expands in place; an
-- expanded node moves to its first *visible* child. Looking through rendered
-- lines rather than raw children matters during filtering, where non-matching
-- children are intentionally absent.
local function expand(state)
	local selected = state.nodes[vim.api.nvim_win_get_cursor(state.window)[1]]
	if not selected or #selected.node.children == 0 then
		return
	end
	if state.filter == "" and state.collapsed[selected.node.id] then
		state.collapsed[selected.node.id] = nil
		render(state, selected.node.id)
	else
		for line = vim.api.nvim_win_get_cursor(state.window)[1] + 1, vim.api.nvim_buf_line_count(state.buffer) do
			local child = state.nodes[line]
			if child and child.parent_id == selected.node.id then
				move_to(state, child.node.id)
				break
			end
		end
	end
end

-- Implement the tree's `h` action. An expanded node collapses in place; a leaf
-- or already-collapsed node moves to its parent. Filtering forces matching paths
-- open, so `h` only moves upward while a filter is active.
local function collapse(state)
	local selected = state.nodes[vim.api.nvim_win_get_cursor(state.window)[1]]
	if not selected then
		return
	end
	if #selected.node.children > 0 and not state.collapsed[selected.node.id] and state.filter == "" then
		state.collapsed[selected.node.id] = true
		render(state, selected.node.id)
	elseif selected.parent_id then
		move_to(state, selected.parent_id)
	end
end

-- Prompt for a case-insensitive substring filter and redraw when the user
-- accepts it. A nil value means the prompt was cancelled and changes nothing.
local function prompt_filter(state)
	vim.ui.input({ prompt = "Structure filter: ", default = state.filter }, function(value)
		if value == nil or not state_for(state.tabpage) then
			return
		end
		state.filter = value
		render(state)
	end)
end

-- Close one tabpage's Structure panel and return focus to its source window when
-- that window still exists.
--
-- Params: tabpage - optional handle; defaults to the current tabpage.
-- Returns: nothing.
-- Side effects: removes state, closes the panel window, and may move focus.
function M.close(tabpage)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	local state = state_for(tabpage)
	if not state then
		return
	end
	states[tabpage] = nil
	local return_window = valid_window(state.source_window) and state.source_window or nil
	if valid_window(state.window) then
		vim.api.nvim_win_close(state.window, true)
	end
	if return_window and vim.api.nvim_get_current_tabpage() == tabpage then
		vim.api.nvim_set_current_win(return_window)
	end
end

-- Toggle the current tabpage's Structure panel. Opening is valid only from a
-- SQL query buffer; an existing panel closes regardless of current buffer so
-- `:OrbitStructure` also works while focus is inside the panel itself.
--
-- Params: config - Orbit's live configuration table.
-- Returns: the new panel state when opened, otherwise nil.
-- Side effects: creates/configures a far-right split and buffer-local mappings.
function M.toggle(config)
	local tabpage = vim.api.nvim_get_current_tabpage()
	local existing = state_for(tabpage)
	if existing then
		M.close(tabpage)
		return nil
	end
	local source_buffer = vim.api.nvim_get_current_buf()
	if vim.bo[source_buffer].filetype ~= "sql" then
		vim.notify("OrbitStructure requires a query buffer", vim.log.levels.WARN)
		return nil
	end

	local width = math.max(1, tonumber(config.structure_width) or 40)
	local view = config.structure_view or {}
	local state = {
		tabpage = tabpage,
		source_buffer = nil,
		source_window = nil,
		entries = {},
		filter = "",
		nodes = {},
		id_to_line = {},
		parents = {},
		collapsed = {},
		known_parents = {},
		group_by_type = view.group_by_type ~= false,
		show_categories = {
			DDL = view.show_ddl ~= false,
			DML = view.show_dml ~= false,
			Other = view.show_other ~= false,
			SELECT = view.show_select ~= false,
		},
		sort_alphabetically = view.sort_alphabetically ~= false,
		icons = {
			clause = config.icons and config.icons.clause or "󰅪",
			collapsed = config.icons and config.icons.collapsed or ">",
			cte = config.icons and config.icons.cte or "󰌷",
			expanded = config.icons and config.icons.expanded or "v",
			folder = config.icons and config.icons.folder or "󰉋",
			query_block = config.icons and (config.icons.query_block or config.icons.query) or "󰆋",
			statement_ddl = config.icons and config.icons.statement_ddl or "󰒓",
			statement_dml = config.icons and config.icons.statement_dml or "󰏫",
			statement_other = config.icons and config.icons.statement_other or "󰌋",
			statement_select = config.icons and config.icons.statement_select or "󰍉",
			with = config.icons and config.icons.with or "󰙅",
		},
		width = width,
	}
	local initial_source_window = vim.api.nvim_get_current_win()
	states[tabpage] = state
	vim.cmd("botright " .. width .. "vsplit")
	state.window = vim.api.nvim_get_current_win()
	state.buffer = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(state.window, state.buffer)
	vim.bo[state.buffer].buftype = "nofile"
	vim.bo[state.buffer].bufhidden = "wipe"
	vim.bo[state.buffer].swapfile = false
	vim.bo[state.buffer].filetype = "orbit-structure"
	vim.bo[state.buffer].modifiable = false
	vim.wo[state.window].number = false
	vim.wo[state.window].relativenumber = false
	vim.wo[state.window].signcolumn = "no"
	vim.wo[state.window].wrap = false
	vim.wo[state.window].winfixwidth = true
	vim.keymap.set("n", "<CR>", function()
		navigate(state)
	end, { buffer = state.buffer, silent = true, desc = "Navigate to statement" })
	vim.keymap.set("n", "/", function()
		prompt_filter(state)
	end, { buffer = state.buffer, silent = true, desc = "Filter statements" })
	vim.keymap.set("n", "l", function()
		expand(state)
	end, { buffer = state.buffer, silent = true, desc = "Expand Structure node" })
	vim.keymap.set("n", "h", function()
		collapse(state)
	end, { buffer = state.buffer, silent = true, desc = "Collapse Structure node" })
	vim.keymap.set("n", "q", function()
		M.close(state.tabpage)
	end, { buffer = state.buffer, silent = true, desc = "Close Structure panel" })
	vim.keymap.set("n", "<Esc>", function()
		if state.filter ~= "" then
			state.filter = ""
			render(state)
		else
			M.close(state.tabpage)
		end
	end, { buffer = state.buffer, silent = true, desc = "Clear filter or close Structure panel" })
	-- A configured action takes precedence if the user intentionally reuses one
	-- of the panel's fixed navigation keys.
	if config.keymaps and type(config.keymaps.execute) == "string" then
		vim.keymap.set("n", config.keymaps.execute, function()
			execute(state, config)
		end, { buffer = state.buffer, silent = true, desc = "Execute Structure element" })
	end
	attach_source(state, source_buffer, initial_source_window)
	return state
end

-- Follow the SQL buffer entered in the current tabpage. Entering the panel or a
-- non-SQL window leaves the last visible query buffer selected. If that source
-- is no longer displayed, the panel transitions to its `No query buffer` state.
--
-- Params: buffer - buffer handle supplied by BufEnter/WinEnter.
-- Returns: nothing.
-- Side effects: may change the tracked source and redraw the panel.
function M.track(buffer)
	local state = state_for(vim.api.nvim_get_current_tabpage())
	if not state or not state.buffer then
		return
	end
	if state.source_buffer and vim.api.nvim_buf_is_valid(state.source_buffer) then
		local visible = false
		for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
			visible = visible or vim.api.nvim_win_get_buf(window) == state.source_buffer
		end
		if not visible then
			state.source_buffer = nil
			state.source_window = nil
			state.entries = {}
			render(state)
		end
	end
	if buffer == state.buffer or vim.bo[buffer].filetype ~= "sql" then
		return
	end
	attach_source(state, buffer, vim.api.nvim_get_current_win())
end

-- Synchronize the highlighted tree node with cursor movement in the tracked
-- source window. Called for both normal and Insert-mode cursor movement.
function M.cursor_moved(buffer)
	local state = state_for(vim.api.nvim_get_current_tabpage())
	if state and state.source_buffer == buffer then
		state.source_window = vim.api.nvim_get_current_win()
		render(state)
	end
end

-- Refresh every tabpage whose Structure panel tracks the changed buffer. This
-- is called by TextChanged events and by the one channel-level buffer attachment
-- installed in `attach_source`, so programmatic edits are covered too.
function M.changed(buffer)
	for tabpage, state in pairs(states) do
		if vim.api.nvim_tabpage_is_valid(tabpage) and state.source_buffer == buffer then
			refresh(state)
		end
	end
end

-- Detach a deleted/wiped source buffer from every panel that tracked it. Panels
-- remain open and render `No query buffer`, ready to follow the next SQL buffer.
function M.source_gone(buffer)
	for tabpage, state in pairs(states) do
		if vim.api.nvim_tabpage_is_valid(tabpage) and state.source_buffer == buffer then
			state.source_buffer = nil
			state.source_window = nil
			state.entries = {}
			render(state)
		end
	end
end

-- Remove state for tabpages or panel windows closed outside this module. Cleanup
-- runs after TabClosed/WinClosed so Neovim has finished invalidating handles.
function M.cleanup()
	for tabpage, state in pairs(states) do
		if not vim.api.nvim_tabpage_is_valid(tabpage) or (state.window and not valid_window(state.window)) then
			states[tabpage] = nil
		end
	end
end

-- Test seam for inspecting one tabpage's live state without exposing mutable
-- state as part of Orbit's documented interface.
function M._state(tabpage)
	return state_for(tabpage or vim.api.nvim_get_current_tabpage())
end

return M
