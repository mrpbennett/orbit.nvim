local cache = require("orbit.schema_cache")
local profiles = require("orbit.profiles")
local adapters = require("orbit.adapters")
local tokenizer = require("orbit.sql.tokenizer")
local scope = require("orbit.sql.scope")

local M = {}

local function item(word, kind, detail)
	return {
		abbr = word,
		kind = kind,
		menu = detail,
		word = word,
	}
end

local function sorted(items)
	table.sort(items, function(left, right)
		return left.word < right.word
	end)
	return items
end

-- Alphabetical, but candidates that exactly prefix-match what's already
-- typed sort first; omnifunc is the only caller that knows `base`.
local function prefix_first(items, base)
	if base == "" then
		return sorted(items)
	end
	table.sort(items, function(left, right)
		local left_match = left.word:sub(1, #base) == base
		local right_match = right.word:sub(1, #base) == base
		if left_match ~= right_match then
			return left_match
		end
		return left.word < right.word
	end)
	return items
end

-- Table/view/schema completion for a `FROM`-family position. `raw_prefix` is
-- the literal qualifier text the user typed (used to build the connector's
-- dialect-correct completion word); filtering against `qualifier_segments`
-- always uses each row's own unqualified (empty-prefix) canonical form, so
-- the depth/membership check stays generic instead of assuming a fixed
-- number of dialect-specific segments.
local function table_items(profile, connector, qualifier_segments, raw_prefix)
	local items = {}
	local next_segments = {}
	for _, row in ipairs(cache.tables(profile)) do
		local canonical = tokenizer.split_qualified(assert(connector.completion_word(profile.options, row, "")))
		local matches = #qualifier_segments <= #canonical
		for index, segment in ipairs(qualifier_segments) do
			if canonical[index] ~= segment then
				matches = false
				break
			end
		end
		if matches then
			local word = assert(connector.completion_word(profile.options, row, raw_prefix))
			table.insert(items, item(word, row.type == "view" and "View" or "Table", profile.name))
			if #canonical > #qualifier_segments + 1 then
				next_segments[canonical[#qualifier_segments + 1]] = true
			end
		end
	end
	-- Only offer the next qualifier level as its own suggestion when it's
	-- genuinely ambiguous (2+ distinct values) — additive, never a
	-- replacement for the direct table listing above.
	local distinct = 0
	for _ in pairs(next_segments) do
		distinct = distinct + 1
	end
	if distinct > 1 then
		for segment in pairs(next_segments) do
			table.insert(items, item(segment, "Schema", profile.name))
		end
	end
	return sorted(items)
end

local function column_items(profile, table_name, prefix, source)
	local items = {}
	for _, column in ipairs(cache.columns(profile, table_name)) do
		table.insert(items, item(prefix .. column.name, "Column", source or column.type or ""))
	end
	return sorted(items)
end

-- The connection between an alias-scope entry's `name`/`schema`/`catalog`
-- and the schema_cache's own dotted `catalog.schema.name` key: find the
-- matching cached table row, if any, then hand that row's identity back to
-- the cache using the exact same key shape `schema_cache.object_name` uses.
-- ipairs over a literal table stops at the first nil, so catalog/schema
-- being absent (common) must be checked individually, not via a shared loop.
local function object_name(row)
	local parts = {}
	if row.catalog and row.catalog ~= "" then
		table.insert(parts, row.catalog)
	end
	if row.schema and row.schema ~= "" then
		table.insert(parts, row.schema)
	end
	if row.name and row.name ~= "" then
		table.insert(parts, row.name)
	end
	return table.concat(parts, ".")
end

local function resolve_table_row(profile, entry)
	for _, row in ipairs(cache.tables(profile)) do
		if
			row.name == entry.name
			and (entry.schema == nil or row.schema == entry.schema)
			and (entry.catalog == nil or row.catalog == entry.catalog)
		then
			return row
		end
	end
	return nil
end

local function find_scope_entry(alias_scope, name)
	for _, entry in ipairs(alias_scope) do
		if entry.alias and entry.alias == name then
			return entry
		end
	end
	for _, entry in ipairs(alias_scope) do
		if not entry.alias and entry.name == name then
			return entry
		end
	end
	return nil
end

local function qualified_column_items(profile, alias_scope, qualifier_segments, raw_prefix)
	if #qualifier_segments ~= 1 then
		return {}
	end
	local name = qualifier_segments[1]
	if #alias_scope == 0 then
		-- No FROM clause yet to resolve against; fall back to treating the
		-- qualifier as a bare table name, matching pre-tokenizer behavior.
		return column_items(profile, name, raw_prefix)
	end
	local entry = find_scope_entry(alias_scope, name)
	if not entry or entry.kind ~= "table" then
		return {}
	end
	local row = resolve_table_row(profile, entry)
	if not row then
		return {}
	end
	return column_items(profile, object_name(row), raw_prefix)
end

local function unqualified_column_items(profile, alias_scope)
	local items = {}
	for _, entry in ipairs(alias_scope) do
		if entry.kind == "table" then
			local row = resolve_table_row(profile, entry)
			if row then
				local source = entry.alias or entry.name
				for _, column in ipairs(column_items(profile, object_name(row), "", source)) do
					table.insert(items, column)
				end
			end
		end
		if entry.alias then
			table.insert(items, item(entry.alias, "Alias", entry.name))
		end
	end
	return sorted(items)
end

local function single_target_column_items(profile, alias_scope)
	for _, entry in ipairs(alias_scope) do
		if entry.kind == "table" then
			local row = resolve_table_row(profile, entry)
			if row then
				return column_items(profile, object_name(row), "")
			end
		end
	end
	return {}
end

function M.items(profile, lines, row, col)
	local connector = adapters.connector(profile)
	if not connector then
		return {}
	end

	local tokens = tokenizer.tokenize(lines)
	local statement_tokens, cursor_index, touching = scope.statement_at(tokens, row, col)
	local analysis = scope.analyze(statement_tokens, cursor_index, touching)
	local qualifier = analysis.qualifier

	if analysis.clause == "from_family" then
		return table_items(profile, connector, qualifier.segments, qualifier.raw)
	elseif
		analysis.clause == "select_list"
		or analysis.clause == "where"
		or analysis.clause == "on"
		or analysis.clause == "group_by"
		or analysis.clause == "order_by"
	then
		if #qualifier.segments > 0 then
			return qualified_column_items(profile, analysis.alias_scope, qualifier.segments, qualifier.raw)
		end
		return unqualified_column_items(profile, analysis.alias_scope)
	elseif analysis.clause == "insert_columns" or analysis.clause == "update_set" then
		return single_target_column_items(profile, analysis.alias_scope)
	end
	return {}
end

local function profile_for_buffer(buffer)
	local orbit = require("orbit")
	local document = profiles.load(orbit.config.profile_path)
	if not document then
		return nil
	end
	local name = vim.b[buffer].orbit_profile
	return profiles.find(document, name)
end

M._profile_for_buffer = profile_for_buffer

function M.omnifunc(findstart, base)
	local position = vim.api.nvim_win_get_cursor(0)
	local row, cursor = position[1], position[2]
	local line = vim.api.nvim_get_current_line()
	if findstart == 1 then
		-- Neovim supplies a byte column; Lua's byte-oriented string indexing matches it here.
		local word = line:sub(1, cursor):match("[%w_%.\"]*$") or ""
		return cursor - #word
	end
	local profile = M._profile_for_buffer(vim.api.nvim_get_current_buf())
	if not profile then
		return {}
	end
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local items = M.items(profile, lines, row, cursor)
	return prefix_first(items, base)
end

function M.attach(buffer)
	vim.bo[buffer].omnifunc = "v:lua.OrbitComplete"
end

function M.prewarm(profile)
	cache.load_tables(profile)
end

return M
