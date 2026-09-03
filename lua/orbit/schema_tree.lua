-- orbit/schema_tree.lua
--
-- This module owns the state and rendering logic for the collapsible
-- database-schema tree shown in the Orbit workspace sidebar (the panel that
-- lists schemas -> tables/views -> columns/keys/indexes for a connection
-- profile). It is the sidebar's model + view-builder, but not its
-- controller: it does not touch buffers/windows directly (that's done by
-- `orbit.workspace`, which calls M.lines() and writes the result into a
-- buffer, and calls M.toggle()/M.set_metadata() etc. in response to user
-- keypresses).
--
-- A "tree" here is a plain state table created by M.new() with:
--   expanded         - set (table used as a set) of "node keys" (strings)
--                       for which nodes are currently expanded/open.
--   loading_metadata - set of metadata-node keys currently being fetched
--                       (e.g. while an async "list columns" call is
--                       in-flight), so the UI can show "loading...".
--   metadata         - metadata-node key -> list of already-fetched
--                       metadata entries (e.g. column definitions). A
--                       missing key means "not fetched yet"; an empty list
--                       means "fetched, but there are none".
--   tables           - the flat list of table/view rows for this profile,
--                       as previously loaded from the database (grouped
--                       into schemas/tables/views by `orbit.schema.group`
--                       when rendering).
--
-- "Nodes" are lightweight, disposable description tables (not stored
-- long-term) representing one line of the tree: a schema, a group (the
-- "tables"/"views" bucket under a schema), a table/view, or a metadata
-- category (e.g. "columns" under a specific table). Each node kind maps to
-- a unique string key (see node_key) used to look up/store its
-- expanded/loading/metadata state, since the nodes themselves are
-- recreated fresh every time M.lines() runs.
--
-- Exports (module table M): new, reset, set_tables, object_name,
-- is_expanded, toggle, is_metadata_loaded, is_metadata_loading,
-- set_metadata_loading, set_metadata, lines.

local schema = require("orbit.schema")
local adapters = require("orbit.adapters")

local M = {}

-- Create a fresh, empty schema tree state table (see module comment for
-- the shape). Called once per profile the first time its sidebar section
-- is shown.
function M.new()
  return {
    expanded = {},
    loading_metadata = {},
    metadata = {},
    tables = {},
  }
end

-- Wipe all state on a tree back to empty, e.g. when the user reconnects a
-- profile or its schema should be reloaded from scratch. Discards
-- expanded/collapsed state, any cached metadata, and the table/view list.
-- Side effects: mutates `tree` in place.
function M.reset(tree)
  tree.expanded = {}
  tree.loading_metadata = {}
  tree.metadata = {}
  tree.tables = {}
end

-- Store the flat list of table/view rows fetched for this profile (e.g.
-- from a "list tables" query). Called by the workspace once that async
-- fetch completes.
-- Side effects: mutates tree.tables.
function M.set_tables(tree, rows)
  tree.tables = rows
end

-- Build a dotted, fully-qualified display name for a table/view row, e.g.
-- "catalog.schema.table_name", omitting any of those parts that are
-- missing/empty (some databases don't have catalogs, or the row is a
-- plain table with no schema concept).
-- Parameter: row - a table/view row with optional .catalog/.schema and
-- required .name fields.
-- Returns: the joined string. Used both for display and as part of the
-- unique keys that track expanded/metadata state per object.
function M.object_name(row)
  return table.concat(vim.tbl_filter(function(value)
    return value and value ~= ""
  end, { row.catalog, row.schema, row.name }), ".")
end

-- Build the unique state-tracking key for a "group" node (the
-- "tables"/"views" bucket displayed under a schema).
-- Parameters: schema_name - the schema's name; kind - "tables" or "views".
local function group_key(schema_name, kind)
  -- NUL delimiters keep adjacent schema, object, and category names from colliding.
  return "group\0" .. schema_name .. "\0" .. kind
end

-- Build the unique state-tracking key for a metadata category node (e.g.
-- "columns" for a specific table).
-- Parameters: row - the table/view row this metadata belongs to;
-- category_id - the metadata category id (e.g. "columns", "primary_keys").
local function metadata_key(row, category_id)
  return "metadata\0" .. M.object_name(row) .. "\0" .. category_id
end

-- Compute the unique string key used to track expand/collapse (and, for
-- metadata nodes, loading/loaded) state for any kind of tree node. Nodes
-- are throwaway tables rebuilt fresh each time M.lines() runs, so this key
-- is what lets the same logical node (e.g. "the public schema") keep its
-- expanded state across re-renders.
-- Parameter: node - a node table with a `.kind` field of "schema", "group",
-- "table", or "metadata", plus kind-specific fields (see M.lines for how
-- each kind is constructed).
-- Returns: a string key, or nil if node.kind isn't one of the recognized
-- kinds (defensive fallback -- shouldn't normally happen).
local function node_key(node)
  if node.kind == "schema" then
    return "schema\0" .. node.name
  end
  if node.kind == "group" then
    return group_key(node.schema, node.group)
  end
  if node.kind == "table" then
    return "table\0" .. M.object_name(node.row)
  end
  if node.kind == "metadata" then
    return metadata_key(node.row, node.category.id)
  end
end

-- Check whether a given node is currently expanded in the tree.
-- Returns: boolean (false for nodes with no recognized key, or that have
-- never been toggled open).
function M.is_expanded(tree, node)
  local key = node_key(node)
  return key ~= nil and tree.expanded[key] or false
end

-- Flip a node's expanded/collapsed state (called when the user
-- activates/presses Enter on a tree line).
-- Parameters: tree - the tree state; node - the node to toggle.
-- Returns: the node's new expanded state (boolean), or false if the node
-- has no valid key (nothing was toggled).
-- Side effects: mutates tree.expanded. Note the `or nil` trick: setting a
-- table key to `false` in Lua is different from removing it, but here we
-- explicitly want to store `nil` (remove the key) rather than `false` when
-- collapsing, keeping the `expanded` table small/tidy (only ever contains
-- keys for nodes that are actually expanded).
function M.toggle(tree, node)
  local key = node_key(node)
  if not key then
    return false
  end
  tree.expanded[key] = not tree.expanded[key] or nil
  return tree.expanded[key] or false
end

-- Has this metadata category (e.g. "columns" for a table) already been
-- fetched (successfully or with zero results) for this row?
-- Returns: boolean. True even if the fetch came back empty -- distinguish
-- "empty" from "never fetched" (nil) using is_metadata_loaded, not by
-- checking the metadata table's contents directly.
function M.is_metadata_loaded(tree, row, category_id)
  return tree.metadata[metadata_key(row, category_id)] ~= nil
end

-- Is this metadata category currently being fetched (an async call is
-- in-flight)? Used by M.lines to show a "loading ..." placeholder line.
function M.is_metadata_loading(tree, row, category_id)
  return tree.loading_metadata[metadata_key(row, category_id)] or false
end

-- Record whether a metadata fetch is in progress for this row/category.
-- Parameters: value - true to mark loading, false/nil to clear it.
-- Side effects: mutates tree.loading_metadata. Called by the workspace
-- right before starting an async metadata fetch (true) and again once it
-- completes (false/nil).
function M.set_metadata_loading(tree, row, category_id, value)
  tree.loading_metadata[metadata_key(row, category_id)] = value
end

-- Store the fetched metadata entries (e.g. column definitions) for a
-- row/category, once an async fetch completes.
-- Parameters: entries - list of metadata rows (shape depends on
-- category_id; see metadata_label below for what fields each category
-- expects).
-- Side effects: mutates tree.metadata.
function M.set_metadata(tree, row, category_id, entries)
  tree.metadata[metadata_key(row, category_id)] = entries
end

-- Format a single metadata entry (e.g. one column, one foreign key) as a
-- human-readable label for display in the tree.
-- Parameters: category - the metadata category id string (e.g. "columns",
-- "primary_keys", "foreign_keys", "indexes", "projections"); row - the metadata entry's
-- own data (shape depends on category, as returned by the connector's
-- metadata-fetching query).
-- Returns: a display string. Falls back to vim.inspect(row) (a generic
-- Lua-table-to-string dump) for any category this function doesn't
-- specifically know how to format.
local function metadata_label(category, row)
  if category == "columns" then
    return string.format("%s  %s", row.name, row.type or "")
  end
  if category == "primary_keys" then
    return string.format("primary key #%s (%s)", row.pk, row.name)
  end
  if category == "foreign_keys" then
    return string.format("foreign key #%s (%s) -> %s (%s)", row.id, row["from"], row.table, row.to)
  end
  if category == "indexes" then
    return row.name
  end
  if category == "projections" then
    return row.name
  end
  return vim.inspect(row)
end

-- Pick which icon (from the plugin's configured `icons` table, see
-- M.config.icons in orbit/init.lua) to show next to a metadata entry line,
-- based on its category.
-- Parameters: icons - the icons table from plugin config; category - the
-- metadata category id.
-- Returns: an icon string. Falls back to icons.folder for key/index
-- categories that don't have their own dedicated icon configured, and to
-- icons.result as a generic fallback for unrecognized categories.
local function metadata_entry_icon(icons, category)
  if category == "columns" then
    return icons.column
  end
  if category == "primary_keys" or category == "foreign_keys" then
    return icons.key or icons.folder
  end
  if category == "indexes" then
    return icons.index or icons.folder
  end
  return icons.result
end

-- Render the entire schema tree (for one profile) into plain text lines,
-- ready to be written into the sidebar buffer. This is the main entry
-- point the workspace calls on every redraw (e.g. after a toggle, a filter
-- keystroke, or new data arriving).
-- Parameters:
--   tree    - the tree state table (see M.new/module comment).
--   profile - the connection profile being displayed; used to look up its
--             connector for metadata categories, and stamped onto "table"/
--             "metadata" nodes so later user actions know which profile
--             a click applies to.
--   filter  - a (possibly empty) search string typed by the user to filter
--             which schemas/tables/views are shown (see orbit.schema.group).
--   options - table with:
--     icons   - the plugin's icon table (see M.config.icons in
--               orbit/init.lua) used for expand/collapse markers and
--               table/view/column glyphs.
--     loading - true if the table/view list itself is still being fetched
--               (shows a "loading schema..." line instead of any groups).
-- Returns four values:
--   lines      - list of strings, one per buffer line.
--   nodes      - array parallel to `lines`: nodes[i] is the node table
--                describing what line `i` represents (or nil for lines
--                that don't correspond to a clickable node, e.g. the
--                "loading..." message), so the workspace can map a cursor
--                line back to "what did the user just press Enter/toggle
--                on".
--   highlights - list of { group = <highlight group name>, line = <line
--                number> } used to apply syntax highlighting (e.g.
--                "OrbitTable"/"OrbitView"/"OrbitColumn") to specific lines
--                via extmarks/matchadd in the workspace.
--   (4th value) - boolean, true if there was at least one group to show
--                (i.e. the filter matched something) -- lets the caller
--                distinguish "showing real results" from "nothing
--                matched"/"still loading".
function M.lines(tree, profile, filter, options)
	local connector = adapters.connector(profile)
  local icons = options.icons
  local lines = {}
  local nodes = {}
  local highlights = {}

  local groups = schema.group(tree.tables, filter)
  if options.loading then
    table.insert(lines, "loading schema...")
  elseif #groups == 0 then
    table.insert(lines, "No matching tables or views")
  end
  for _, schema_group in ipairs(groups) do
    local schema_node = { kind = "schema", name = schema_group.name }
    -- Filtering reveals matching ancestors without changing the user's saved expansion state.
    local schema_expanded = M.is_expanded(tree, schema_node) or filter ~= ""
    table.insert(lines, string.format("%s %s", schema_expanded and icons.expanded or icons.collapsed, schema_group.name))
    nodes[#lines] = schema_node
    for _, kind in ipairs({ "tables", "views" }) do
      local objects = schema_group[kind]
      if schema_expanded and #objects > 0 then
        local group_node = { kind = "group", schema = schema_group.name, group = kind }
        local group_expanded = M.is_expanded(tree, group_node) or filter ~= ""
        table.insert(lines, string.format("  %s %s %d", group_expanded and icons.expanded or icons.collapsed, kind, #objects))
        nodes[#lines] = group_node
        if group_expanded then
          for _, row in ipairs(objects) do
            local object_kind = row.type == "view" and "view" or "table"
            local table_node = { kind = "table", profile = profile, row = row }
            local table_expanded = M.is_expanded(tree, table_node)
            table.insert(lines, string.format("    %s %s %s", table_expanded and icons.expanded or icons.collapsed, icons[object_kind], row.name))
            nodes[#lines] = table_node
            table.insert(highlights, { group = object_kind == "view" and "OrbitView" or "OrbitTable", line = #lines })
            if table_expanded then
              -- Ask the connector which metadata categories apply to this
              -- particular row (e.g. postgres may offer columns/primary
              -- keys/foreign keys/indexes; sqlite might differ) -- not
              -- every connector/table combination supports every
              -- category, so this can't be a fixed list.
						for _, category in ipairs(connector and connector.metadata_categories and connector.metadata_categories(profile.options, row) or {}) do
                local metadata_node = { category = category, kind = "metadata", profile = profile, row = row }
                local metadata_expanded = M.is_expanded(tree, metadata_node)
                local entries = tree.metadata[metadata_key(row, category.id)]
                -- nil is not loaded yet; an empty table is a completed lookup with no entries.
                local label = entries and string.format("%s %d", category.label, #entries) or category.label
                table.insert(lines, string.format("      %s %s %s", metadata_expanded and icons.expanded or icons.collapsed, icons.folder, label))
                nodes[#lines] = metadata_node
                if metadata_expanded then
                  if entries then
                    for _, entry in ipairs(entries) do
                      table.insert(lines, string.format("        %s %s", metadata_entry_icon(icons, category.id), metadata_label(category.id, entry)))
                      table.insert(highlights, { group = category.id == "columns" and "OrbitColumn" or "OrbitTable", line = #lines })
                    end
                  else
                    -- entries is nil here: the category has been expanded
                    -- but its data hasn't arrived yet (the workspace
                    -- should be triggering an async fetch for it).
                    table.insert(lines, "        loading " .. category.label .. "...")
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return lines, nodes, highlights, #groups > 0
end

return M
