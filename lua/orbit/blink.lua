-- Optional blink.cmp source. blink.cmp has no runtime provider-registration
-- API (github.com/Saghen/blink.cmp/issues/475 is still open), so this module
-- is never auto-registered; wiring it in is one line in the user's own
-- blink.cmp config (see README). This file has no require-time dependency
-- on blink.cmp itself, so it's safe to load and test even without it.
local completion = require("orbit.completion")

local source = {}
source.__index = source

function source.new()
	return setmetatable({}, source)
end

function source:enabled()
	return require("orbit").config.completion == true
end

function source:get_trigger_characters()
	return { ".", " " }
end

function source:get_completions(ctx, callback)
	local buffer = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
	local profile = completion._profile_for_buffer(buffer)
	if not profile then
		callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
		return function() end
	end

	local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
	local row, col = ctx.cursor[1], ctx.cursor[2]
	local items = completion.items(profile, lines, row, col)

	local blink_items = {}
	for _, entry in ipairs(items) do
		table.insert(blink_items, {
			label = entry.word,
			insertText = entry.word,
			kind = entry.kind,
			detail = entry.menu,
		})
	end

	callback({ items = blink_items, is_incomplete_forward = false, is_incomplete_backward = false })
	return function() end
end

return source
