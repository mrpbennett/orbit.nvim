-- SQL completion candidate builder for orbit.nvim.
--
-- This module is the bridge between "what SQL structure is the cursor
-- sitting in" (figured out by orbit.sql.scope, using tokens produced by
-- orbit.sql.tokenizer) and "what schema information do we actually have"
-- (fetched from orbit.schema_cache, which caches table/column metadata
-- pulled through a database connector — see orbit.adapters). Given those
-- two things, it produces a flat list of completion candidates: table
-- names, column names, schema names, and alias names.
--
-- High-level flow (see M.items, the main entry point):
--   1. Tokenize the buffer's SQL (orbit.sql.tokenizer.tokenize).
--   2. Find the statement + cursor position within it
--      (orbit.sql.scope.statement_at).
--   3. Analyze that statement to learn which clause the cursor is in, what
--      qualifier (e.g. `alias.`) has been typed, and which tables/aliases
--      are visible (orbit.sql.scope.analyze).
--   4. Based on the clause, decide what KIND of thing to suggest (tables
--      after FROM, columns after SELECT/WHERE/ON/etc., columns of a single
--      target table after INSERT's column list or UPDATE's SET), and look
--      those up via orbit.schema_cache.
--
-- What it returns / how it plugs into a completion engine:
--   - M.items(profile, lines, row, col) returns a plain list of candidate
--     tables, shaped like { abbr, kind, menu, word } (see the `item` helper
--     below). This shape is intentionally generic/engine-agnostic.
--   - M.omnifunc adapts M.items to Neovim's built-in 'omnifunc' completion
--     mechanism (see :help complete-functions) — the format Vim's native
--     insert-mode completion (i_CTRL-X_CTRL-O) expects, with `abbr`/`word`/
--     `kind`/`menu` fields understood directly by Vim's popup menu.
--   - orbit.blink.lua wraps M.items (and M._profile_for_buffer) again to
--     adapt these candidates to the blink.cmp completion-engine plugin's
--     own item shape ({ label, insertText, kind, detail }). See
--     lua/orbit/blink.lua for that adapter.
--   So this module itself has no dependency on any particular completion
--   engine (no nvim-cmp/blink.cmp requires here) — it only knows Neovim's
--   buffer/cursor APIs and orbit's own modules.
local cache = require("orbit.schema_cache")
local profiles = require("orbit.profiles")
local adapters = require("orbit.adapters")
local tokenizer = require("orbit.sql.tokenizer")
local scope = require("orbit.sql.scope")

local M = {}

-- Builds one completion candidate in this module's generic shape.
-- Params:
--   word   - the actual text to insert if this candidate is chosen.
--   kind   - a short human-readable category shown in the completion menu,
--            e.g. "Table", "View", "Column", "Schema", "Alias".
--   detail - extra context shown alongside the candidate (e.g. the
--            profile/connection name, or a column's data type).
-- Returns a table shaped for both Vim's omnifunc (`abbr`/`word`) and, via
-- orbit.blink.lua's translation, blink.cmp's item shape.
local function item(word, kind, detail)
	return {
		abbr = word,
		kind = kind,
		menu = detail,
		word = word,
	}
end

-- Sorts a list of candidates alphabetically by their inserted text, in
-- place, and returns it (for chaining). Plain alphabetical order is the
-- default; prefix_first (below) is used instead when the user has already
-- typed a partial word to match against.
local function sorted(items)
	table.sort(items, function(left, right)
		return left.word < right.word
	end)
	return items
end

-- Alphabetical, but candidates that exactly prefix-match what's already
-- typed sort first; omnifunc is the only caller that knows `base`.
--
-- Params:
--   items - the candidate list to sort (mutated in place, then returned).
--   base  - the partial word Vim's omnifunc says the user has already
--           typed (e.g. "cu" if they've typed "cu" before invoking
--           completion). Vim's own completion popup does its own
--           filtering by this prefix too, but ordering the list so exact
--           prefix matches come first makes the most relevant items appear
--           at the top even before any additional filtering narrows things
--           down, and helps if the popup is displaying unfiltered.
local function prefix_first(items, base)
	if base == "" then
		return sorted(items)
	end
	local lower_base = base:lower()
	table.sort(items, function(left, right)
		local left_match = left.word:sub(1, #base):lower() == lower_base
		local right_match = right.word:sub(1, #base):lower() == lower_base
		if left_match ~= right_match then
			-- Exactly one of the two is a prefix match: it should sort
			-- first regardless of alphabetical order.
			return left_match
		end
		-- Both (or neither) match the prefix: fall back to plain
		-- alphabetical order between them.
		return left.word < right.word
	end)
	return items
end

-- Case-insensitive prefix test used to narrow candidates down to whatever
-- partial word the user has already typed (e.g. "gr" typed after `FROM `).
-- An empty `partial` always matches, so callers can pass "" to mean "no
-- filtering" (the historical, unfiltered behavior that omnifunc still
-- relies on — see M.items' `opts.filter_partial`).
local function partial_matches(name, partial)
	if partial == "" then
		return true
	end
	return name:sub(1, #partial):lower() == partial:lower()
end

-- Case-insensitive equality for unquoted SQL identifiers (schema/table/
-- catalog/alias names) so that one person typing `FROM orders o` and
-- another typing `FROM ORDERS O` (or any mix) both resolve against the same
-- schema-cache rows and the same alias -- unquoted identifiers are
-- case-insensitive by SQL convention, and this codebase's own database
-- connections are the only source of "canonical" casing anyway (identifiers
-- typed by the user are compared against schema-cache rows/each other here,
-- never used to build the final inserted text, so folding case for the
-- comparison doesn't change what gets inserted). nil is only ever equal to
-- nil, matching the exact-equality behavior this replaces.
local function ci_equals(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a:lower() == b:lower()
end

-- Table/view/schema completion for a `FROM`-family position. `raw_prefix` is
-- the literal qualifier text the user typed (used to build the connector's
-- dialect-correct completion word); filtering against `qualifier_segments`
-- always uses each row's own unqualified (empty-prefix) canonical form, so
-- the depth/membership check stays generic instead of assuming a fixed
-- number of dialect-specific segments.
--
-- Params:
--   profile             - the connection profile (has .name, .options, etc;
--                          see orbit.profiles).
--   connector           - the dialect-specific connector for this profile
--                          (postgres/sqlite/trino — see orbit.adapters). Its
--                          completion_word(options, row, prefix) builds the
--                          text to insert for a schema row, formatted the
--                          way that SQL dialect expects (quoting rules,
--                          which parts of catalog/schema/name to include,
--                          etc.), given whatever the user has already typed
--                          as `prefix`.
--   qualifier_segments  - unquoted qualifier segments already typed before
--                          the cursor, e.g. { "myschema" } for
--                          `FROM myschema.|`. Empty if nothing was typed
--                          yet (plain `FROM |`).
--   raw_prefix          - the literal (still-quoted) qualifier text typed
--                          so far, passed through to completion_word so the
--                          inserted text keeps the user's original quoting.
--   partial             - the in-progress word after the last completed
--                          qualifier segment (see extract_qualifier in
--                          orbit.sql.scope), or "" to disable this filter.
--                          Checked against whichever segment the user is
--                          currently typing — the next one after
--                          `qualifier_segments` — not the row's final name,
--                          since that segment may be a schema, not the
--                          table itself (e.g. typing `FROM grid` should only
--                          match rows whose next segment starts with
--                          "grid", whether that's a schema or a table).
-- Returns a sorted list of "Table"/"View" candidates (and, when
-- ambiguous, "Schema" candidates — see below), one per matching row in the
-- schema cache.
local function table_items(profile, connector, qualifier_segments, raw_prefix, partial)
	local items = {}
	local next_segments = {}
	for _, row in ipairs(cache.tables(profile)) do
		-- Ask the connector for this row's fully-qualified name with an
		-- empty prefix, then split it into segments, to get a normalized,
		-- dialect-independent form to compare against what was typed.
		local canonical = tokenizer.split_qualified(assert(connector.completion_word(profile.options, row, "")))
		-- The row is a candidate only if every already-typed qualifier
		-- segment matches the row's own name at that position, e.g. typing
		-- `myschema.` should only match rows whose schema is "myschema".
		local matches = #qualifier_segments <= #canonical
		for index, segment in ipairs(qualifier_segments) do
			if not ci_equals(canonical[index], segment) then
				matches = false
				break
			end
		end
		if matches and partial ~= "" then
			local next_segment = canonical[#qualifier_segments + 1]
			matches = next_segment ~= nil and partial_matches(next_segment, partial)
		end
		if matches then
			local word = assert(connector.completion_word(profile.options, row, raw_prefix))
			table.insert(items, item(word, row.type == "view" and "View" or "Table", profile.name))
			-- If this row has an additional qualifier segment beyond what
			-- was typed (e.g. user typed nothing, row is
			-- catalog.schema.table), remember that next segment as a
			-- candidate "schema name" suggestion too.
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

-- Column completion for one specific table. `table_name` is the schema
-- cache's own dotted key for a table (see the `object_name` helper below,
-- which builds this key from an alias-scope entry's identity). `prefix` is
-- prepended to every inserted column name (used to also complete a partial
-- word the user's already typed, when called from `qualified_column_items`
-- with a raw qualifier prefix); `source` overrides what's shown in the
-- completion menu's detail column (falls back to the column's declared SQL
-- type when not given, e.g. when the caller wants to show the alias/table
-- name that column comes from instead). `partial` narrows to columns whose
-- name starts with the in-progress word (case-insensitive), or "" to
-- disable this filter (see partial_matches).
local function column_items(profile, table_name, prefix, source, partial)
	local items = {}
	for _, column in ipairs(cache.columns(profile, table_name)) do
		if partial_matches(column.name, partial) then
			table.insert(items, item(prefix .. column.name, "Column", source or column.type or ""))
		end
	end
	return sorted(items)
end

-- The connection between an alias-scope entry's `name`/`schema`/`catalog`
-- and the schema_cache's own dotted `catalog.schema.name` key: find the
-- matching cached table row, if any, then hand that row's identity back to
-- the cache using the exact same key shape `schema_cache.object_name` uses.
-- ipairs over a literal table stops at the first nil, so catalog/schema
-- being absent (common) must be checked individually, not via a shared loop.
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

-- Finds the schema-cache row (as returned by cache.tables) matching an
-- alias-scope entry (as returned by orbit.sql.scope, i.e. something the
-- user wrote in a FROM/JOIN clause). Schema/catalog are only checked when
-- the entry actually specified them (a bare `FROM orders` should still
-- match a cached row that happens to have a schema, since the user didn't
-- rule that out by typing one).
-- Returns the matching row, or nil if the table isn't in the schema cache
-- (e.g. schema not loaded yet, or the name doesn't exist).
local function resolve_table_row(profile, entry)
	for _, row in ipairs(cache.tables(profile)) do
		if
			ci_equals(row.name, entry.name)
			and (entry.schema == nil or ci_equals(row.schema, entry.schema))
			and (entry.catalog == nil or ci_equals(row.catalog, entry.catalog))
		then
			return row
		end
	end
	return nil
end

-- Looks up an alias-scope entry by the name the user typed as a qualifier,
-- e.g. for `o.` this looks for an entry whose alias (or, failing that,
-- table name) is "o". Aliases are checked first because in valid SQL an
-- alias shadows the bare table name it's short for — if a query wrote
-- `FROM orders o`, only `o.column` should resolve, not `orders.column`
-- (real databases reject the latter too), so preferring alias matches
-- keeps this consistent with what actually parses.
-- Returns the matching entry, or nil if `name` doesn't match anything in
-- scope.
local function find_scope_entry(alias_scope, name)
	for _, entry in ipairs(alias_scope) do
		if entry.alias and ci_equals(entry.alias, name) then
			return entry
		end
	end
	for _, entry in ipairs(alias_scope) do
		if not entry.alias and ci_equals(entry.name, name) then
			return entry
		end
	end
	return nil
end

-- Column completion for a qualified position, i.e. the user has typed
-- exactly one qualifier segment before the cursor (like `o.` or `orders.`)
-- and now wants that table/alias's columns. `qualifier_segments`/
-- `raw_prefix` come from orbit.sql.scope's qualifier analysis.
-- Returns {} for anything that isn't a single, resolvable table qualifier
-- (derived tables and CTEs have no schema-cache columns to offer here, and
-- more than one segment, e.g. `catalog.schema.`, isn't a table alias
-- position at all).
local function qualified_column_items(profile, alias_scope, qualifier_segments, raw_prefix, partial)
	if #qualifier_segments ~= 1 then
		return {}
	end
	local name = qualifier_segments[1]
	if #alias_scope == 0 then
		-- No FROM clause yet to resolve against; fall back to treating the
		-- qualifier as a bare table name, matching pre-tokenizer behavior.
		return column_items(profile, name, raw_prefix, nil, partial)
	end
	local entry = find_scope_entry(alias_scope, name)
	if not entry or entry.kind ~= "table" then
		return {}
	end
	local row = resolve_table_row(profile, entry)
	if not row then
		return {}
	end
	return column_items(profile, object_name(row), raw_prefix, nil, partial)
end

-- Column completion for an UNqualified position (no `alias.` typed yet),
-- e.g. cursor right after `SELECT ` with several tables in scope. Offers
-- every column of every real table in scope (each tagged with its
-- alias/table name as the "source" shown in the menu, so the user can tell
-- which table a same-named column came from when several tables are
-- joined), plus every alias itself as its own candidate (so typing an alias
-- and then a dot is easy to discover). CTEs and derived tables are skipped
-- for column listing (schema_cache has no column info for them), but if
-- they have an alias, that alias is still offered.
local function unqualified_column_items(profile, alias_scope, partial)
	local items = {}
	for _, entry in ipairs(alias_scope) do
		if entry.kind == "table" then
			local row = resolve_table_row(profile, entry)
			if row then
				local source = entry.alias or entry.name
				for _, column in ipairs(column_items(profile, object_name(row), "", source, partial)) do
					table.insert(items, column)
				end
			end
		end
		if entry.alias and partial_matches(entry.alias, partial) then
			table.insert(items, item(entry.alias, "Alias", entry.name))
		end
	end
	return sorted(items)
end

-- Column completion for positions that only make sense with a single
-- unambiguous target table: an INSERT statement's column list
-- (`INSERT INTO orders (|`) or an UPDATE's SET clause
-- (`UPDATE orders SET |`). Both only ever have exactly one target table, so
-- this returns as soon as it finds the first "table" entry with a resolved
-- schema-cache row — there is no alias/source column needed since there's
-- nothing to disambiguate. Returns {} if no such table can be resolved.
local function single_target_column_items(profile, alias_scope, partial)
	for _, entry in ipairs(alias_scope) do
		if entry.kind == "table" then
			local row = resolve_table_row(profile, entry)
			if row then
				return column_items(profile, object_name(row), "", nil, partial)
			end
		end
	end
	return {}
end

-- Main entry point: computes the full list of completion candidates for a
-- cursor position in a SQL buffer. This is what both M.omnifunc (Vim's
-- native completion) and orbit.blink.lua (the blink.cmp adapter) call.
--
-- Params:
--   profile - the connection profile to complete against (determines which
--             dialect connector and which schema cache to use).
--   lines   - all lines of the buffer, as a list of strings (e.g. from
--             vim.api.nvim_buf_get_lines). The whole buffer is re-tokenized
--             on every call; SQL files are small enough that this is cheap,
--             and it keeps this module stateless between completions.
--   row     - 1-indexed cursor line number.
--   col     - 0-indexed byte column of the cursor on that line.
--   opts    - optional table. `opts.filter_partial = true` narrows results
--             to candidates matching (case-insensitive prefix) the
--             in-progress word already typed before the cursor. Default
--             (nil/false) returns every candidate for the clause, unfiltered
--             — the historical behavior that M.omnifunc relies on, since
--             Vim's own popup does its own filtering/narrowing as the user
--             keeps typing. Completion engines that apply their own fuzzy
--             matching over the *unfiltered* universe (e.g. blink.cmp, see
--             orbit.blink) should pass `filter_partial = true` so that
--             fuzzy/typo-tolerant matching doesn't pull in irrelevant
--             candidates that merely share scattered letters with what was
--             typed.
-- Returns a flat list of candidates (see the `item` helper), or {} if
-- there's no connector for this profile or nothing sensible to suggest at
-- this position (e.g. clause is "unknown").
function M.items(profile, lines, row, col, opts)
	local connector = adapters.connector(profile)
	if not connector then
		return {}
	end

	-- Delegate all the SQL-structure understanding to orbit.sql.tokenizer
	-- and orbit.sql.scope: tokenize the buffer, find which statement the
	-- cursor is in, then analyze that statement for its clause/qualifier/
	-- alias-scope. This module only decides what KIND of candidates to
	-- build for each clause and fetches them from the schema cache.
	local tokens = tokenizer.tokenize(lines)
	local statement_tokens, cursor_index, touching = scope.statement_at(tokens, row, col)
	local analysis = scope.analyze(statement_tokens, cursor_index, touching)
	local qualifier = analysis.qualifier
	local partial = (opts and opts.filter_partial) and qualifier.partial or ""

	if analysis.clause == "from_family" then
		-- Right after FROM/JOIN/INTO/UPDATE: suggest tables/views (and
		-- schema names when a qualifier is ambiguous).
		return table_items(profile, connector, qualifier.segments, qualifier.raw, partial)
	elseif
		analysis.clause == "select_list"
		or analysis.clause == "where"
		or analysis.clause == "on"
		or analysis.clause == "group_by"
		or analysis.clause == "order_by"
	then
		-- These clauses all reference columns (and possibly qualify them
		-- with an alias/table name), so they share the same decision: if a
		-- qualifier was typed, resolve columns of just that one table;
		-- otherwise offer columns from every table in scope plus the
		-- aliases themselves.
		if #qualifier.segments > 0 then
			return qualified_column_items(profile, analysis.alias_scope, qualifier.segments, qualifier.raw, partial)
		end
		return unqualified_column_items(profile, analysis.alias_scope, partial)
	elseif analysis.clause == "insert_columns" or analysis.clause == "update_set" then
		-- Both of these clauses can only ever target one table, so use the
		-- simpler single-table column lookup instead of scanning all
		-- aliases in scope.
		return single_target_column_items(profile, analysis.alias_scope, partial)
	end
	-- Cursor is somewhere this module doesn't have a specific completion
	-- strategy for (e.g. clause "unknown", or mid-keyword) — offer nothing
	-- rather than guessing.
	return {}
end

-- Looks up which connection profile a given buffer is associated with. Each
-- SQL buffer gets an `orbit_profile` buffer-local variable (set elsewhere
-- when a buffer is attached to a connection) naming which profile in the
-- user's profiles file it should use; this reads that variable and resolves
-- it to the actual profile definition.
-- Returns the profile table, or nil if there's no profiles document or no
-- buffer-local profile name set / matching profile found.
local function profile_for_buffer(buffer)
	local orbit = require("orbit")
	local document = profiles.load(orbit.config.profile_path)
	if not document then
		return nil
	end
	local name = vim.b[buffer].orbit_profile
	return profiles.find(document, name)
end

-- Exposed so other completion-engine adapters (currently orbit.blink.lua)
-- can reuse the same buffer -> profile resolution logic instead of
-- duplicating it.
M._profile_for_buffer = profile_for_buffer

-- Implements Neovim's 'omnifunc' completion function contract (see :help
-- complete-functions and :help i_CTRL-X_CTRL-O). Neovim calls this twice
-- per completion request:
--   1. With findstart == 1: this function must return the byte column
--      where the word being completed starts (so Vim knows how much of the
--      current line to replace with whatever candidate the user picks).
--   2. With findstart == 0 (and `base` set to the text between that column
--      and the cursor): this function must return the actual list of
--      completion candidates.
-- This function is wired up as `v:lua.OrbitComplete`'s Lua half; see
-- M.attach for where 'omnifunc' is pointed at it.
function M.omnifunc(findstart, base)
	local position = vim.api.nvim_win_get_cursor(0)
	local row, cursor = position[1], position[2]
	local line = vim.api.nvim_get_current_line()
	if findstart == 1 then
		-- Neovim supplies a byte column; Lua's byte-oriented string indexing matches it here.
		-- Match the run of identifier/dot/quote characters immediately
		-- before the cursor to find where the current word starts; this is
		-- intentionally a simple regex rather than using the tokenizer,
		-- since Vim only needs a start column here, not full SQL structure.
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

-- Turns on omni-completion for a buffer by pointing Neovim's 'omnifunc'
-- option at M.omnifunc. `v:lua.OrbitComplete` is expected to be a global
-- Lua function (set up elsewhere in the plugin, likely in orbit/init.lua)
-- that simply forwards to M.omnifunc — 'omnifunc' must name a Vim-callable
-- function, not a Lua table field directly, hence the indirection.
-- Side effect: sets the buffer-local 'omnifunc' option.
function M.attach(buffer)
	vim.bo[buffer].omnifunc = "v:lua.OrbitComplete"
end

-- Kicks off loading (and caching) this profile's table list ahead of time,
-- so the first real completion request doesn't have to wait on a live
-- database round-trip. Fire-and-forget: any error is handled wherever
-- schema_cache.load_tables reports it, not here.
function M.prewarm(profile)
	cache.load_tables(profile)
end

return M
