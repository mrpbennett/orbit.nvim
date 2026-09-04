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
			assert(vim.deep_equal(payload.items[1].textEdit, {
				newText = "orders",
				range = {
					start = { line = 0, character = #line },
					["end"] = { line = 0, character = #line },
				},
			}))
			-- kind must be blink.cmp's numeric CompletionItemKind (Class = 7)
			-- for blink to render the right highlight group; kind_name/
			-- kind_icon carry Orbit's own label and icon override.
			assert(payload.items[1].kind == 7)
			assert(payload.items[1].kind_name == "Table")
			assert(payload.items[1].kind_icon == "󰆼")
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

	["PostgreSQL completions replace the typed qualifier exactly"] = function()
		local profile = { name = "blink-postgres", kind = "postgres", options = { database = "orbit" } }
		local rows = { { schema = "public", name = "orders", type = "table" } }
		local original_run = runner.run
		local original_profile_for_buffer = completion._profile_for_buffer
		runner.run = function(_, _, done)
			done(rows)
		end
		completion._profile_for_buffer = function()
			return profile
		end

		local ok, err = xpcall(function()
			cache.load_tables(profile, {}, function() end)
			for _, suffix in ipairs({ "public", "public." }) do
				local line = "SELECT * FROM " .. suffix
				vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })

				local payload
				blink_source.new():get_completions({ bufnr = 0, cursor = { 1, #line } }, function(result)
					payload = result
				end)

				assert(#payload.items == 1)
				assert(payload.items[1].insertText == nil)
				assert(vim.deep_equal(payload.items[1].textEdit, {
					newText = '"public"."orders"',
					range = {
						start = { line = 0, character = #"SELECT * FROM " },
						["end"] = { line = 0, character = #line },
					},
				}))
			end
		end, debug.traceback)

		runner.run = original_run
		completion._profile_for_buffer = original_profile_for_buffer
		assert(ok, err)
	end,
}
