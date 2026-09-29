-- orbit/sidebar_tree.lua
--
-- The Workspace sidebar's model and view-builder: everything under the fixed
-- "Filter:" header -- the title, the "Profiles:" section (with the one
-- expanded profile's Schema browser or Redis key status spliced in), and the
-- "Saved queries:" section. It also owns the rules for which nodes are
-- expanded.
--
-- This module is pure: it never touches buffers, windows, or the database.
-- orbit.workspace writes the returned lines into the sidebar buffer, paints
-- the highlights, and performs any loading an expansion needs (schema
-- acquisition, metadata). orbit.schema_tree remains the model for the
-- Schema browser portion; this module composes it with the rest.
--
-- A "model" is any table with these fields (the Workspace state table is
-- one, which is why the names match its fields):
--   profiles              - array of connection profiles to list.
--   selected              - the Selected profile, or nil.
--   filter                - current filter text ("" shows everything).
--   loading               - true while the expanded profile's schema loads.
--   schema_profile        - name of the one profile whose schema is expanded,
--                           or nil. Only one profile can be expanded.
--   tree                  - orbit.schema_tree state for that profile.
--   saved_query_locations - array of { name, path, children } entries, with
--                           children from orbit.saved_queries.discover.
--   expanded_saved_dirs   - set of M.saved_directory_key(node) -> true.
--
-- Exports: lines, saved_directory_key, is_expanded, expand, collapse,
-- open_schema, close_schema.
local schema_tree = require("orbit.schema_tree")

local M = {}

-- Node kinds that can be opened and closed. Everything else (saved query
-- files, metadata entries such as individual columns) is a leaf.
local expandable = {
	profile = true,
	saved_directory = true,
	catalog = true,
	schema = true,
	group = true,
	table = true,
	metadata = true,
}

-- Case-insensitive plain-substring match ("" matches everything).
local function matches(text, filter)
	return filter == "" or text:lower():find(filter:lower(), 1, true) ~= nil
end

-- Build a stable, unique key for a "saved_directory" node so its expanded
-- state survives re-renders (nodes are rebuilt fresh every time, so the node
-- table itself can't be the key). Combining root_path and path with a NUL
-- separator, which can't appear in a real path, keeps two saved query
-- locations that share a relative path from colliding.
--
-- Params: node - any table with `root_path` and `path`.
-- Returns: the key string.
function M.saved_directory_key(node)
	return node.root_path .. "\0" .. node.path
end

-- A saved-query file or directory is shown when its own name matches the
-- filter, or (for directories) when any descendant matches -- so a parent
-- folder stays visible while something inside it still matches.
local function saved_query_matches(node, filter)
	if matches(node.name, filter) then
		return true
	end
	for _, child in ipairs(node.children or {}) do
		if saved_query_matches(child, filter) then
			return true
		end
	end
	return false
end

-- Label for the expanded Redis profile's key index line, from a
-- redis_cache-style status table ({ loading, error, loaded, count, truncated }).
local function redis_label(status, loading)
	if loading or status.loading then
		return "Redis keys: loading"
	end
	if status.error then
		return "Redis keys: unavailable"
	end
	if status.loaded then
		return string.format("Redis keys: %d%s", status.count, status.truncated and " (truncated)" or "")
	end
	return "Redis keys: not loaded"
end

-- Render the sidebar body.
--
-- Params:
--   model   - see the module comment.
--   options - {
--     icons        = fully resolved icon table (user icons merged over defaults),
--     redis_status = optional function(profile) -> status table, used for the
--                    expanded Redis profile's key index line; omitted means
--                    "not loaded".
--   }
-- Returns three values, all numbered from 1 = the title line (the caller
-- offsets them below any fixed header lines it keeps itself):
--   lines      - array of strings.
--   nodes      - line number -> node table, for lines the user can act on.
--   highlights - array of { group, line, col_start?, col_end? }; entries
--                without columns highlight the whole line.
-- Side effects: none. (schema_tree may lazily cache object labels on the tree.)
function M.lines(model, options)
	local icons = options.icons
	local filter = model.filter
	local title = model.selected and model.selected.name or "Orbit Workspace"
	local title_icon = model.selected and icons.profile or icons.workspace
	local lines = { title_icon .. " " .. title, "", "Profiles:" }
	local nodes = {}
	local highlights = {
		{
			group = model.selected and "OrbitIconProfile" or "OrbitIconWorkspace",
			line = 1,
			col_start = 0,
			col_end = #title_icon,
		},
	}

	for _, profile in ipairs(model.profiles) do
		local expanded = model.schema_profile == profile.name
		local profile_matches = matches(profile.name, filter) or matches(profile.kind, filter)
		local tree_lines, tree_nodes, tree_highlights, has_matches = {}, {}, {}, false
		if expanded then
			if profile.kind == "redis" then
				local status = options.redis_status and options.redis_status(profile) or {}
				local label = redis_label(status, model.loading)
				tree_lines = { label }
				has_matches = profile_matches or matches(label, filter)
			else
				-- Relational Connectors delegate their complete hierarchy to
				-- schema_tree. When the profile itself matches, show its whole
				-- tree rather than filtering inside it.
				tree_lines, tree_nodes, tree_highlights, has_matches = schema_tree.lines(
					model.tree,
					profile,
					profile_matches and "" or filter,
					{ icons = icons, loading = model.loading }
				)
			end
		end
		-- Show the profile line if it matches directly, OR if it's expanded and
		-- something inside its filtered tree matched -- otherwise a profile
		-- containing a matching table would wrongly disappear.
		if profile_matches or (expanded and has_matches) then
			local marker = expanded and icons.expanded or icons.collapsed
			local prefix = "  " .. marker .. " "
			table.insert(lines, string.format("%s%s %s (%s)", prefix, icons.profile, profile.name, profile.kind))
			nodes[#lines] = { kind = "profile", profile = profile }
			table.insert(highlights, { group = "OrbitProfile", line = #lines })
			table.insert(highlights, {
				group = "OrbitIconProfile",
				line = #lines,
				col_start = #prefix,
				col_end = #prefix + #icons.profile,
			})
		end
		if expanded and (profile_matches or has_matches) then
			-- schema_tree numbers its lines from 1 and knows nothing about the
			-- 4-space indent under a profile, so shift every line number by
			-- `base` and every highlight column by the indent width.
			local base = #lines
			for _, line in ipairs(tree_lines) do
				table.insert(lines, "    " .. line)
			end
			for line_number, node in pairs(tree_nodes) do
				nodes[base + line_number] = node
			end
			for _, highlight in ipairs(tree_highlights) do
				table.insert(highlights, {
					group = highlight.group,
					line = base + highlight.line,
					col_start = highlight.col_start and highlight.col_start + 4 or nil,
					col_end = highlight.col_end and highlight.col_end + 4 or nil,
				})
			end
		end
	end

	if #model.saved_query_locations > 0 then
		table.insert(lines, "")
		table.insert(lines, "Saved queries:")
		-- Recursively render one saved-query node and its children, indented
		-- by `depth` levels of two spaces.
		local function render_saved(node, depth)
			-- Skipping non-matching subtrees hides empty branches while
			-- filtering, not just non-matching leaves.
			if not saved_query_matches(node, filter) then
				return
			end
			local indent = string.rep("  ", depth)
			if node.kind == "saved_directory" then
				-- Directories auto-expand while filtering so matches inside
				-- them are visible without opening them by hand.
				local expanded = model.expanded_saved_dirs[M.saved_directory_key(node)] or filter ~= ""
				local prefix = indent .. (expanded and icons.expanded or icons.collapsed) .. " "
				table.insert(lines, prefix .. icons.folder .. " " .. node.name)
				nodes[#lines] = node
				table.insert(highlights, {
					group = "OrbitIconFolder",
					line = #lines,
					col_start = #prefix,
					col_end = #prefix + #icons.folder,
				})
				if expanded then
					if #node.children == 0 then
						table.insert(lines, string.rep("  ", depth + 1) .. "No saved query files")
					else
						for _, child in ipairs(node.children) do
							render_saved(child, depth + 1)
						end
					end
				end
			else
				table.insert(lines, string.format("%s%s %s", indent, icons.saved_query, node.name))
				nodes[#lines] = node
				table.insert(highlights, {
					group = "OrbitIconQuery",
					line = #lines,
					col_start = #indent,
					col_end = #indent + #icons.saved_query,
				})
			end
		end
		for _, location in ipairs(model.saved_query_locations) do
			-- Each configured location renders as a synthetic top-level
			-- directory whose path is also its own root_path.
			render_saved({
				children = location.children,
				kind = "saved_directory",
				name = location.name,
				path = location.path,
				root_path = location.path,
			}, 1)
		end
	end

	return lines, nodes, highlights
end

-- Is this node currently open? Leaf nodes are never open.
--
-- Note: while filtering, saved-query directories *render* expanded even when
-- this returns false; this reports the remembered user choice, not the view.
function M.is_expanded(model, node)
	if node.kind == "profile" then
		return model.schema_profile == node.profile.name
	end
	if node.kind == "saved_directory" then
		return model.expanded_saved_dirs[M.saved_directory_key(node)] == true
	end
	return expandable[node.kind] == true and schema_tree.is_expanded(model.tree, node)
end

-- Make `name` the one profile whose schema is expanded. Switching to a
-- different profile discards the previous profile's tree state (expanded
-- nodes, tables, metadata), since it describes another database.
--
-- Returns: true if the expanded profile changed.
function M.open_schema(model, name)
	if model.schema_profile == name then
		return false
	end
	model.schema_profile = name
	schema_tree.reset(model.tree)
	return true
end

-- Collapse whichever profile's schema is expanded, discarding its tree state.
--
-- Returns: true if a profile was expanded.
function M.close_schema(model)
	if not model.schema_profile then
		return false
	end
	model.schema_profile = nil
	schema_tree.reset(model.tree)
	return true
end

-- Open a closed node's view state. A profile only becomes the expanded
-- profile here; loading its schema is the caller's job.
--
-- Returns: true if anything changed (false for leaves and already-open nodes).
function M.expand(model, node)
	if not expandable[node.kind] or M.is_expanded(model, node) then
		return false
	end
	if node.kind == "profile" then
		return M.open_schema(model, node.profile.name)
	end
	if node.kind == "saved_directory" then
		model.expanded_saved_dirs[M.saved_directory_key(node)] = true
		return true
	end
	schema_tree.toggle(model.tree, node)
	return true
end

-- Close an open node. Collapsing a profile discards its schema tree state.
--
-- Returns: true if anything changed (false for leaves and already-closed nodes).
function M.collapse(model, node)
	if not M.is_expanded(model, node) then
		return false
	end
	if node.kind == "profile" then
		return M.close_schema(model)
	end
	if node.kind == "saved_directory" then
		model.expanded_saved_dirs[M.saved_directory_key(node)] = nil
		return true
	end
	schema_tree.toggle(model.tree, node)
	return true
end

return M
