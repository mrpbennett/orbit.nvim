local blink_source = require("orbit.blink")
local completion = require("orbit.completion")
local cache = require("orbit.schema_cache")
local runner = require("orbit.runner")

return {
	["get_completions resolves the buffer's profile and maps items to blink's shape"] = function()
		local profile = { name = "blink-completion", kind = "sqlite", options = { path = "orbit.db" } }
		local rows = { { name = "orders", type = "table" } }

		local original_run = runner.run
		runner.run = function(received, _, done)
			assert(received == profile)
			done(rows)
		end
		local original_profile_for_buffer = completion._profile_for_buffer
		completion._profile_for_buffer = function()
			return profile
		end

		local ok, err = xpcall(function()
			local loaded
			cache.load_tables(profile, {}, function(result)
				loaded = result
			end)
			assert(vim.deep_equal(loaded, rows))

			vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT * FROM " })
			local line = "SELECT * FROM "

			local source = blink_source.new()
			assert(source:enabled())
			assert(vim.deep_equal(source:get_trigger_characters(), { ".", " " }))

			local payload
			source:get_completions({ bufnr = 0, cursor = { 1, #line } }, function(result)
				payload = result
			end)

			assert(payload)
			assert(#payload.items == 1)
			assert(payload.items[1].label == "orders")
			assert(payload.items[1].insertText == "orders")
			assert(payload.items[1].kind == "Table")
		end, debug.traceback)

		runner.run = original_run
		completion._profile_for_buffer = original_profile_for_buffer
		assert(ok, err)
	end,

	["get_completions returns no items when the buffer has no bound profile"] = function()
		local original_profile_for_buffer = completion._profile_for_buffer
		completion._profile_for_buffer = function()
			return nil
		end

		local ok, err = xpcall(function()
			local source = blink_source.new()
			local payload
			source:get_completions({ bufnr = 0, cursor = { 1, 0 } }, function(result)
				payload = result
			end)
			assert(payload)
			assert(#payload.items == 0)
		end, debug.traceback)

		completion._profile_for_buffer = original_profile_for_buffer
		assert(ok, err)
	end,
}
