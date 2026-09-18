local feedback = require("orbit.feedback")
local profiles = require("orbit.profiles")
local query = require("orbit.query")
local results = require("orbit.results")
local runner = require("orbit.runner")
local workspace = require("orbit.workspace")

return {
	["disconnect cancels Redis metadata with the bound profile session"] = function()
		local redis_cache = require("orbit.redis_cache")
		local original_close = runner.close
		local original_cancel = redis_cache.cancel
		local original_notify = vim.notify
		local closed, cancelled
		runner.close = function(name) closed = name end
		redis_cache.cancel = function(name) cancelled = name end
		vim.notify = function() end
		local buffer = vim.api.nvim_create_buf(false, true)
		vim.b[buffer].orbit_profile = "cache"
		local ok, err = xpcall(function()
			query.disconnect(buffer)
			assert(closed == "cache" and cancelled == "cache")
		end, debug.traceback)
		runner.close = original_close
		redis_cache.cancel = original_cancel
		vim.notify = original_notify
		if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
		assert(ok, err)
	end,

	["binding Redis profiles selects the Redis filetype and prewarms completion"] = function()
		local completion = require("orbit.completion")
		local structure = require("orbit.structure")
		local original_prewarm = completion.prewarm
		local original_close_for_buffer = structure.close_for_buffer
		local original_notify = vim.notify
		local warmed, closed_structure
		completion.prewarm = function(profile) warmed = profile end
		structure.close_for_buffer = function(buffer) closed_structure = buffer end
		vim.notify = function() end
		local buffer = vim.api.nvim_create_buf(false, true)
		local profile = { name = "cache", kind = "redis", options = { host = "localhost" } }
		local ok, err = xpcall(function()
			query.bind_profile(buffer, profile)
			assert(vim.bo[buffer].filetype == "redis")
			assert(warmed == profile)
			assert(closed_structure == buffer)
			query.bind_profile(buffer, { name = "db", kind = "sqlite", options = { path = ":memory:" } })
			assert(vim.bo[buffer].filetype == "sql")
		end, debug.traceback)
		completion.prewarm = original_prewarm
		structure.close_for_buffer = original_close_for_buffer
		vim.notify = original_notify
		if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
		assert(ok, err)
	end,

	["MSSQL mutation confirmation follows CTE verbs and SELECT INTO semantics"] = function()
		local confirm = require("orbit.connectors.mssql").requires_confirmation
		local read_only = {
			"SELECT * FROM [sales].[orders]",
			"WITH recent AS (SELECT * FROM orders) SELECT * FROM recent",
			"SELECT 'INTO', [OUTPUT] FROM words; -- MERGE",
		}
		local mutating = {
			"WITH recent AS (SELECT id FROM orders) UPDATE orders SET active = 1 OUTPUT inserted.id",
			"WITH one AS (SELECT 1 AS id), two AS (SELECT id FROM one) DELETE FROM orders OUTPUT deleted.id",
			"SELECT * INTO archive FROM orders",
			"SELECT 1\nDELETE FROM orders",
			"EXEC dbo.rebuild_cache",
			"MERGE target USING source ON target.id = source.id WHEN MATCHED THEN UPDATE SET value = source.value",
			"CREATE TABLE dbo.items (id int)",
			"DROP VIEW dbo.old_view",
		}
		for _, statement in ipairs(read_only) do
			assert(not confirm(statement), statement)
		end
		for _, statement in ipairs(mutating) do
			assert(confirm(statement), statement)
		end
	end,
	["query propagates ordered Connector columns to rendering"] = function()
		local original = {
			connected = runner.connected,
			finish = feedback.finish,
			notify = vim.notify,
			open = results.open,
			run = runner.run,
			start = feedback.start,
			workspace = workspace.is_workspace,
		}
		local path = vim.fn.tempname()
		assert(profiles.write(path, {
			version = 1,
			profiles = { { name = "metadata-query", kind = "sqlite", options = { path = ":memory:" } } },
		}))
		local buffer = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(0, buffer)
		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "SELECT 1" })
		vim.b[buffer].orbit_profile = "metadata-query"
		local rendered, completion
		local notifications = {}
		local metadata = {
			columns = { "zeta", "alpha" },
		}

		runner.connected = function() return false end
		runner.run = function(_, _, callback)
			callback({}, nil, metadata)
			return {}
		end
		feedback.start = function() return {} end
		feedback.finish = function(_, message) completion = message end
		results.open = function(rows, options) rendered = { rows = rows, options = options } end
		workspace.is_workspace = function() return false end
		vim.notify = function(message) table.insert(notifications, message) end

		local ok, test_err = xpcall(function()
			query.execute(buffer, {
				confirm_mutations = false,
				focus_results = false,
				profile_path = path,
				result_height = 5,
				result_limit = 20,
				max_cell_width = 40,
			})
			assert(rendered and #rendered.rows == 0)
			assert(vim.deep_equal(rendered.options.columns, { "zeta", "alpha" }))
			assert(vim.deep_equal(notifications, {}))
			assert(completion:match("0 rows in 0s"), completion)
		end, debug.traceback)

		runner.connected = original.connected
		runner.run = original.run
		feedback.start = original.start
		feedback.finish = original.finish
		results.open = original.open
		workspace.is_workspace = original.workspace
		vim.notify = original.notify
		if vim.api.nvim_buf_is_valid(buffer) then
			vim.api.nvim_buf_delete(buffer, { force = true })
		end
		assert(ok, test_err)
	end,
	["superseded Table metadata finishes the earlier Statement feedback"] = function()
		local original = {
			connected = runner.connected,
			finish = feedback.finish,
			open = results.open,
			run = runner.run,
			start = feedback.start,
		}
		local path = vim.fn.tempname()
		assert(profiles.write(path, {
			version = 1,
			profiles = { { name = "superseded", kind = "sqlite", options = { path = ":memory:" } } },
		}))
		local buffer = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(0, buffer)
		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "SELECT * FROM items" })
		vim.b[buffer].orbit_profile = "superseded"
		vim.b[buffer].orbit_table = { schema = "main", name = "items", type = "table" }
		vim.b[buffer].orbit_table_statement = "SELECT * FROM items"
		local statement_callbacks = {}
		local metadata_callbacks = {}
		local finishes = {}
		runner.connected = function() return false end
		runner.run = function(_, statement, callback)
			if statement == "SELECT * FROM items" then
				statement_callbacks[#statement_callbacks + 1] = callback
			else
				metadata_callbacks[#metadata_callbacks + 1] = callback
			end
			return {}
		end
		feedback.start = function() return {} end
		feedback.finish = function(_, message, level)
			finishes[#finishes + 1] = { message = message, level = level }
		end
		results.open = function() return {} end

		local ok, test_err = xpcall(function()
			local config = { confirm_mutations = false, profile_path = path }
			query.execute(buffer, config)
			statement_callbacks[1]({ { id = "old" } })
			metadata_callbacks[1]({ { name = "id" } })
			assert(metadata_callbacks[2])
			vim.b[buffer].orbit_table = nil
			vim.b[buffer].orbit_table_statement = nil
			query.execute(buffer, config)
			statement_callbacks[2]({ { id = "new" } })
			metadata_callbacks[2]({ { name = "id" } })
			local superseded = 0
			for _, finish in ipairs(finishes) do
				if finish.message == "Statement result superseded" then
					assert(finish.level == vim.log.levels.DEBUG)
					superseded = superseded + 1
				end
			end
			assert(superseded == 1)
		end, debug.traceback)
		runner.connected = original.connected
		runner.run = original.run
		feedback.start = original.start
		feedback.finish = original.finish
		results.open = original.open
		if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
		assert(ok, test_err)
	end,
}
