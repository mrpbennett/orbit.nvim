-- orbit/blink.lua
--
-- blink.cmp source — Orbit's only completion engine integration (there is
-- no native/omnifunc fallback; without this wired up, Orbit offers no SQL
-- completion at all). blink.cmp has no runtime provider-registration API
-- (github.com/Saghen/blink.cmp/issues/475 is still open), so this module is
-- never auto-registered; wiring it in is one line in the user's own
-- blink.cmp config (see README). This file has no require-time dependency
-- on blink.cmp itself, so it's safe to load and test even without it.
--
-- What this module is: an adapter that lets Orbit's own SQL completion logic
-- (lua/orbit/completion.lua, which knows how to tokenize SQL and figure out
-- what to suggest -- tables, columns, keywords, etc. for a given profile)
-- plug into the blink.cmp completion plugin's "source" interface. blink.cmp
-- expects a source object with `new`, `enabled`, `get_trigger_characters`,
-- and `get_completions` methods (this is blink.cmp's documented source
-- contract, not something Orbit invented) -- this file implements exactly
-- that contract and simply translates Orbit's completion items into the
-- shape blink.cmp wants.
--
-- Exports:
--   A "source" class (a plain table used as an OOP-style prototype via
--   `__index`). Call `source.new()` to construct an instance; that's what
--   the user's blink.cmp config passes in as their SQL completion provider.
local completion = require("orbit.completion")

-- Maps Orbit's own generic candidate `kind` strings (see orbit/completion.lua's
-- `item` helper) to blink.cmp's numeric LSP CompletionItemKind, so blink
-- renders the highlight group/icon it actually understands instead of
-- silently falling back to its "Unknown" default (previously visible as a
-- generic tag-like glyph, since Orbit was passing the kind STRING straight
-- through as `kind`, which never matches any of blink's numeric kinds).
-- Values are blink.cmp.types.CompletionItemKind numbers (Class=7, Field=5,
-- Module=9, Variable=6 -- see blink.cmp/lua/blink/cmp/types.lua).
local KIND_TO_LSP = {
	Table = 7,
	View = 7,
	Column = 5,
	Catalog = 9,
	Schema = 9,
	Alias = 6,
}

-- A single, consistent "database" glyph (Nerd Font: nf-md-database) for
-- every Orbit candidate, set directly via blink.cmp's per-item `kind_icon`
-- override -- overriding the default per-kind icon blink would otherwise
-- look up from `appearance.kind_icons` (Field's icon, which renders as a
-- tag-like glyph, was the default Orbit's items fell back to).
local DATABASE_ICON = "󰆼"

-- `source` is used as a class/prototype: methods are defined with `:` sugar
-- (source:enabled(), etc.), and setmetatable({}, source) below makes any
-- instance created by source.new() look up missing keys (i.e. its methods)
-- on `source` via __index. This is a common lightweight OOP pattern in Lua.
local source = {}
source.__index = source

-- Constructs a new blink.cmp source instance. blink.cmp calls this itself
-- when the user registers Orbit as a completion provider in their config.
--
-- Parameters: none.
--
-- Returns: a new source instance (an empty table whose metatable points
-- back at `source`, so it inherits all of `source`'s methods).
--
-- Side effects: none.
function source.new()
	return setmetatable({}, source)
end

-- Tells blink.cmp whether this source should currently offer completions at
-- all. blink.cmp calls this before invoking get_completions.
--
-- Parameters: none (the method receives `self` implicitly via `:`).
--
-- Returns: boolean - true only when the user has explicitly turned on Orbit
-- completion via `require("orbit").setup({ completion = true })` (the
-- default). requiring "orbit" here (rather than at the top of the file)
-- avoids a hard dependency ordering issue and just reads the live config
-- table each time it's asked.
--
-- Side effects: none.
function source:enabled()
	return require("orbit").config.completion == true
end

-- Tells blink.cmp which characters, when typed, should trigger completion
-- to re-run automatically (in addition to the usual manual trigger).
--
-- Parameters: none.
--
-- Returns: array of single-character strings. "." triggers completion after
-- typing a qualifier separator (e.g. "users." to suggest its columns), and
-- " " triggers it after a space (e.g. after typing "FROM " to suggest table
-- names).
--
-- Side effects: none.
function source:get_trigger_characters()
	return { ".", " " }
end

-- The main entry point blink.cmp calls to actually fetch completion
-- suggestions for the current cursor position. Looks up which Orbit profile
-- (database connection) is bound to the current buffer, asks Orbit's
-- completion engine for suggestions based on the buffer text and cursor
-- position, and reports them back to blink.cmp via `callback` in the shape
-- it expects.
--
-- Parameters:
--   ctx (table) - blink.cmp's completion context for this request. Notable
--     fields used here: `ctx.bufnr` (the buffer being completed in) and
--     `ctx.cursor` (a {row, col} pair for the current cursor position).
--   callback (function) - blink.cmp's callback to deliver results through.
--     Must be called with a table shaped like
--     { items = {...}, is_incomplete_forward = bool, is_incomplete_backward = bool }.
--     The `is_incomplete_*` flags tell blink.cmp whether it should ask again
--     as the user keeps typing without re-requesting fully; Orbit always
--     reports both as false, since each call recomputes fresh
--     tokenizer-based results rather than incrementally filtering.
--
-- Returns: a cancellation function (blink.cmp's convention: sources return a
-- function that blink.cmp can call to cancel/cleanup an in-flight request).
-- Since this implementation resolves everything synchronously before
-- calling `callback`, there's nothing to cancel, so it returns a no-op
-- function.
--
-- Side effects:
--   - Reads the buffer's lines via vim.api.nvim_buf_get_lines (a
--     synchronous call into Neovim's buffer text).
--   - Falls back to vim.api.nvim_get_current_buf() if ctx doesn't supply a
--     buffer number, so it always operates on *some* real buffer.
--   - Invokes `callback`, handing control back to blink.cmp.
function source:get_completions(ctx, callback)
	local buffer = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
	-- Orbit completion is scoped per-buffer: a buffer only gets suggestions
	-- if it has previously been bound to a connection profile. If not, we
	-- report "no items" rather than erroring, so blink.cmp just shows
	-- nothing instead of failing.
	local profile = completion._profile_for_buffer(buffer)
	if not profile then
		callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
		return function() end
	end

	-- Grab the full buffer text as a list of lines (0 to -1 = start to end)
	-- and the cursor position blink.cmp gave us, then hand both to Orbit's
	-- completion engine (lua/orbit/completion.lua) to compute suggestions
	-- appropriate for where the cursor currently sits. completion.items
	-- already narrows results to the in-progress word typed before the
	-- cursor, so blink's own fuzzy pass only has genuinely relevant
	-- candidates left to score/sort, rather than every table/column in the
	-- schema cache.
	local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
	local row, col = ctx.cursor[1], ctx.cursor[2]
	local items = completion.items(profile, lines, row, col)

	-- Translate Orbit's generic completion item shape (`word`, `kind`,
	-- `menu`) into the field names blink.cmp expects. An explicit text edit is
	-- required because Blink only recommends inferred insertText ranges for
	-- exclusively alphanumeric text; SQL qualifiers contain dots and quotes.
	-- `kind_name`/`kind_icon` are blink.cmp's own per-item
	-- override fields (see blink.cmp/lua/blink/cmp/completion/windows/render/context.lua),
	-- used here to get correct highlighting despite `kind` needing to be
	-- blink's numeric CompletionItemKind rather than Orbit's descriptive
	-- string, and to always show the database icon.
	local blink_items = {}
	for _, entry in ipairs(items) do
		table.insert(blink_items, {
			label = entry.word,
			textEdit = {
				newText = entry.word,
				range = {
					start = { line = entry.replace_start_row - 1, character = entry.replace_start_col },
					["end"] = { line = row - 1, character = col },
				},
			},
			kind = KIND_TO_LSP[entry.kind],
			kind_name = entry.kind,
			kind_icon = DATABASE_ICON,
			detail = entry.menu,
		})
	end

	callback({ items = blink_items, is_incomplete_forward = false, is_incomplete_backward = false })
	return function() end
end

return source
