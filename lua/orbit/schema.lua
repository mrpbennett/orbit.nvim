-- orbit/schema.lua
--
-- Responsible for taking the flat list of schema objects (tables/views, one
-- row per object, as returned by a database connector's introspection query)
-- and turning it into what the workspace sidebar UI actually wants to
-- render: either a filtered flat list (M.filter, used for simple
-- search-as-you-type over object names) or a list of schema "groups" each
-- containing their own tables/views, sorted alphabetically (M.group, used to
-- build the tree view in the sidebar).
--
-- This module does no I/O and knows nothing about Neovim's UI or about how
-- the rows were fetched -- it's a pure data-shaping layer sitting between a
-- connector (lua/orbit/connectors/*) and the workspace sidebar
-- (lua/orbit/workspace.lua).
--
-- Each `row` is expected to look like:
--   { name = "users", type = "table" | "view", schema = "public", catalog = nil|"my_catalog" }
--
-- Exports:
--   M.filter(rows, query) -> array of rows whose name matches `query`
--   M.group(rows, query)  -> array of { name, tables = {...}, views = {...} }
local M = {}

-- Filters a flat list of schema object rows down to only the ones whose
-- name contains `query` (case-insensitive substring match). Used for simple
-- "type to narrow down the list" filtering, without any grouping by schema.
--
-- Parameters:
--   rows (table) - array of row tables, each with at least a `name` field.
--   query (string|nil) - the search text typed by the user. nil/empty means
--     "no filter", so every row is returned unchanged.
--
-- Returns:
--   array of rows. If `query` is empty, the *same* `rows` table reference is
--   returned as-is; otherwise a *new* array containing only matching rows.
--
-- Side effects: none (pure function).
function M.filter(rows, query)
	query = vim.trim(query or ""):lower()
	if query == "" then
		return rows
	end

	local matches = {}
	for _, row in ipairs(rows) do
		if row.name:lower():find(query, 1, true) then
			table.insert(matches, row)
		end
	end
	return matches
end

-- Groups a flat list of schema object rows into per-schema buckets of
-- tables and views, applying an optional search filter, and returns the
-- result sorted alphabetically. This is the shape the workspace sidebar
-- renders as its tree: one top-level node per schema, each with a "tables"
-- and a "views" sub-list.
--
-- Parameters:
--   rows (table) - array of row tables as described at the top of this
--     file (name, type, schema, catalog).
--   query (string|nil) - optional search text. When non-empty, a row is
--     kept if either its schema name matches OR its own object name
--     matches (so searching for a schema name pulls in every object inside
--     it, and searching for a table name still surfaces just that table's
--     schema).
--
-- Returns:
--   array of group tables: { name = <schema label>, tables = {...rows...},
--   views = {...rows...} }, sorted by group name; within each group,
--   `tables` and `views` are each sorted by row name.
--
-- Side effects: none (pure function; builds and returns new tables).
function M.group(rows, query)
	query = vim.trim(query or ""):lower()
	local by_schema = {}
	for _, row in ipairs(rows) do
    -- Catalog is part of a Trino schema's identity; matching a schema includes all of its objects.
    -- (Postgres/sqlite rows have no catalog, so this just falls back to the schema name, or "main"
    -- when even the schema is unknown -- sqlite in particular has a single implicit schema.)
    local schema_name = row.catalog and row.catalog .. "." .. (row.schema or "main") or row.schema or "main"
		-- `find(needle, 1, true)` does a *plain* substring search starting at
		-- position 1 -- the trailing `true` disables Lua pattern matching so
		-- that characters like "." or "%" in schema/table names are treated
		-- literally instead of as pattern metacharacters.
		local schema_matches = query == "" or schema_name:lower():find(query, 1, true)
		local object_matches = query == "" or row.name:lower():find(query, 1, true)
		if schema_matches or object_matches then
			-- Reuse the group for this schema if we've already started one,
			-- otherwise create it lazily on first sight.
			local group = by_schema[schema_name] or { name = schema_name, tables = {}, views = {} }
			by_schema[schema_name] = group
			-- Route the row into "views" or "tables" depending on its type;
			-- indexing group[...] with a computed key avoids writing out an
			-- if/else branch for the two cases.
			table.insert(group[row.type == "view" and "views" or "tables"], row)
		end
	end
	local groups = {}
	for _, group in pairs(by_schema) do
		-- Sort each group's tables/views alphabetically so the sidebar tree
		-- renders in a stable, predictable order rather than hash order.
		table.sort(group.tables, function(left, right)
			return left.name < right.name
		end)
		table.sort(group.views, function(left, right)
			return left.name < right.name
		end)
		table.insert(groups, group)
	end
	-- Same reasoning as above: sort the top-level schema groups alphabetically.
	table.sort(groups, function(left, right)
		return left.name < right.name
	end)
	return groups
end

return M
