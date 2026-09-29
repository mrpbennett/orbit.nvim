-- Statement execution is tested through its interface only: a fake runner,
-- fake metadata, and a recording sink. No windows, buffers, or vim.wait.
local execution = require("orbit.execution")

-- Builds a fresh fake world for one test. Everything the module touches is
-- recorded in `world` so assertions can read it back.
local function fake_world(overrides)
	local world = {
		runs = {},
		cancelled = {},
		delivered = {},
		finishes = {},
		notifications = {},
		diagnostics = {},
		prompts = 0,
		clock = 0,
		alive = true,
		accept = true,
		connector = { sql_dialect = "sqlite" },
	}
	world.sink = {
		alive = function() return world.alive end,
		deliver = function(rows, options)
			world.delivered[#world.delivered + 1] = { rows = rows, options = options }
			return world.alive
		end,
	}
	world.deps = {
		connectors = { connector = function() return world.connector end },
		runner = {
			connected = function() return false end,
			run = function(profile, statement, callback)
				local process = { statement = statement }
				world.runs[#world.runs + 1] = { profile = profile, statement = statement, callback = callback, process = process }
				return process
			end,
			cancel = function(process) world.cancelled[#world.cancelled + 1] = process end,
		},
		feedback = {
			start = function(message) return { message = message } end,
			finish = function(_, message, level)
				world.finishes[#world.finishes + 1] = { message = message, level = level }
			end,
		},
		diagnostics = { open = function(err) world.diagnostics[#world.diagnostics + 1] = err end },
		notify = function(message, level)
			world.notifications[#world.notifications + 1] = { message = message, level = level }
		end,
		confirm = function()
			world.prompts = world.prompts + 1
			return world.accept
		end,
		now = function() return world.clock end,
		ticker = function() return function() end end,
	}
	for name, value in pairs(overrides or {}) do
		world.deps[name] = value
	end
	return world
end

local function request(key, fields)
	local value = {
		key = key,
		profile = { name = "local", kind = "sqlite", options = {} },
		statement = "SELECT 1",
		result_options = { source_name = "scratch.sql" },
	}
	for name, field in pairs(fields or {}) do
		value[name] = field
	end
	return value
end

local function last_finish(world)
	return world.finishes[#world.finishes]
end

return {
	["Statement execution delivers rows with elapsed time and releases its lock"] = function()
		local world = fake_world()
		assert(execution.run(request("exec-deliver"), world.sink, world.deps))
		assert(execution.status("exec-deliver").profile_name == "local")
		world.clock = 3 * 1000000000
		world.runs[1].callback({ { id = 1 } }, nil, { columns = { "id" } })
		assert(#world.delivered == 1)
		local options = world.delivered[1].options
		assert(options.source_name == "scratch.sql" and options.elapsed == 3)
		assert(vim.deep_equal(options.columns, { "id" }))
		assert(last_finish(world).message == "Query finished: 1 rows in 3s")
		assert(execution.status("exec-deliver") == nil)
	end,

	["Statement execution rejects a second run for the same key only"] = function()
		local world = fake_world()
		assert(execution.run(request("exec-busy"), world.sink, world.deps))
		assert(not execution.run(request("exec-busy"), world.sink, world.deps))
		assert(world.notifications[1].message == "An Orbit statement is already running in this buffer")
		assert(world.notifications[1].level == vim.log.levels.WARN)
		assert(execution.run(request("exec-busy-other"), world.sink, world.deps))
		assert(#world.runs == 2)
		world.runs[1].callback({})
		world.runs[2].callback({})
		assert(execution.run(request("exec-busy"), world.sink, world.deps))
		world.runs[3].callback({})
	end,

	["Statement execution discards rows when its sink has gone away"] = function()
		local world = fake_world()
		execution.run(request("exec-discard"), world.sink, world.deps)
		world.alive = false
		world.runs[1].callback({ { id = 1 } })
		assert(#world.delivered == 0)
		assert(last_finish(world).message == "Statement result discarded: Workspace closed")
		assert(last_finish(world).level == vim.log.levels.DEBUG)
		assert(execution.status("exec-discard") == nil)
	end,

	["Statement execution reports failures and keeps late failures out of diagnostics"] = function()
		local world = fake_world()
		execution.run(request("exec-fail"), world.sink, world.deps)
		world.runs[1].callback(nil, "no such table")
		assert(last_finish(world).message == "Query failed: local")
		assert(world.notifications[1].message == "no such table")
		assert(vim.deep_equal(world.diagnostics, { "no such table" }))

		execution.run(request("exec-fail"), world.sink, world.deps)
		world.alive = false
		world.runs[2].callback(nil, "late failure")
		assert(last_finish(world).message == "late failure")
		assert(last_finish(world).level == vim.log.levels.ERROR)
		assert(#world.diagnostics == 1)
	end,

	["Statement execution cancels through the runner and releases on completion"] = function()
		local world = fake_world()
		assert(not execution.cancel("exec-cancel", world.deps))
		execution.run(request("exec-cancel"), world.sink, world.deps)
		assert(execution.cancel("exec-cancel", world.deps))
		assert(world.cancelled[1] == world.runs[1].process)
		assert(execution.status("exec-cancel") ~= nil)
		world.runs[1].callback(nil, "query cancelled")
		assert(last_finish(world).message == "Query cancelled: local")
		assert(#world.delivered == 0 and #world.diagnostics == 0)
		assert(execution.status("exec-cancel") == nil)
	end,

	["Statement execution confirms Mutating statements unless the profile opts out"] = function()
		local world = fake_world()
		world.accept = false
		local mutating = request("exec-confirm", { statement = "DELETE FROM items", confirm_mutations = true })
		assert(not execution.run(mutating, world.sink, world.deps))
		assert(world.prompts == 1 and #world.runs == 0)

		world.accept = true
		assert(execution.run(mutating, world.sink, world.deps))
		assert(world.prompts == 2 and #world.runs == 1)
		world.runs[1].callback({})

		local opted_out = request("exec-confirm", { statement = "DELETE FROM items", confirm_mutations = true })
		opted_out.profile.options.confirm_mutations = false
		assert(execution.run(opted_out, world.sink, world.deps))
		assert(world.prompts == 2)
		world.runs[2].callback({})

		assert(execution.run(request("exec-confirm", { confirm_mutations = true }), world.sink, world.deps))
		assert(world.prompts == 2)
		world.runs[3].callback({})
	end,

	["Statement execution decides the Editable target before delivering a table browse"] = function()
		local metadata_calls = {}
		local world = fake_world({
			metadata = {
				load_metadata = function(_, object, category, _, callback)
					metadata_calls[#metadata_calls + 1] = { object = object, category = category, callback = callback }
				end,
				load_columns = function(_, _, _, callback)
					metadata_calls[#metadata_calls + 1] = { category = "columns", callback = callback }
				end,
			},
		})
		world.connector.editable_table = function(_, object, keys)
			return { name = object.name, primary_keys = keys }
		end
		local object = { schema = "main", name = "items", type = "table" }
		execution.run(request("exec-editable", { table = object }), world.sink, world.deps)
		world.runs[1].callback({ { id = 1 } })
		assert(#world.delivered == 0)
		assert(metadata_calls[1].category == "primary_keys" and metadata_calls[1].object == object)
		-- The lock is held until the result is delivered.
		assert(not execution.run(request("exec-editable"), world.sink, world.deps))
		metadata_calls[1].callback({ { name = "id" } })
		metadata_calls[2].callback({ { name = "id" }, { name = "label" } })
		local options = world.delivered[1].options
		assert(vim.deep_equal(options.editable, { name = "items", primary_keys = { "id" } }))
		assert(options.profile.name == "local")
		assert(vim.deep_equal(options.columns, { "id", "label" }))
		options.reload(function() end)
		assert(world.runs[2].statement == "SELECT 1")
		assert(execution.status("exec-editable") == nil)
	end,

	["Statement execution explains read-only table browses and discards when the sink closes"] = function()
		local pending
		local world = fake_world({
			metadata = {
				load_metadata = function(_, _, _, _, callback) pending = callback end,
				load_columns = function(_, _, _, callback) callback({}) end,
			},
		})
		local object = { schema = "main", name = "items", type = "view" }
		execution.run(request("exec-readonly", { table = object }), world.sink, world.deps)
		world.runs[1].callback({})
		pending({})
		assert(world.delivered[1].options.read_only_reason:match("read%-only"))

		execution.run(request("exec-readonly", { table = object }), world.sink, world.deps)
		world.runs[2].callback({})
		world.alive = false
		pending({})
		assert(#world.delivered == 1)
		assert(last_finish(world).message == "Statement result discarded: Workspace closed")
		assert(execution.status("exec-readonly") == nil)
	end,

	["Statement execution releases its lock when showing the result fails"] = function()
		local world = fake_world()
		world.sink.deliver = function() error("E36: Not enough room") end
		execution.run(request("exec-throw"), world.sink, world.deps)
		world.runs[1].callback({ { id = 1 } })
		assert(execution.status("exec-throw") == nil)
		assert(last_finish(world).message == "Query failed: local")
		assert(world.notifications[#world.notifications].message:match("E36"))
		assert(execution.run(request("exec-throw"), world.sink, world.deps))
		world.runs[2].callback(nil, "ignored")
	end,

	["Statement execution cancels at once while only table metadata is pending"] = function()
		local pending
		local world = fake_world({
			metadata = {
				load_metadata = function(_, _, _, _, callback) pending = callback end,
				load_columns = function(_, _, _, callback) callback({}) end,
			},
		})
		local object = { schema = "main", name = "items", type = "table" }
		execution.run(request("exec-cancel-metadata", { table = object, messages = { cancelled = "Action cancelled" } }), world.sink, world.deps)
		world.runs[1].callback({ { id = 1 } })
		assert(execution.cancel("exec-cancel-metadata", world.deps))
		assert(execution.status("exec-cancel-metadata") == nil)
		assert(last_finish(world).message == "Action cancelled")
		assert(#world.cancelled == 0)
		-- The late metadata answer is ignored.
		pending({ { name = "id" } })
		assert(#world.delivered == 0)
		assert(last_finish(world).message == "Action cancelled")
	end,

	["Statement execution can keep a failure out of the diagnostics window"] = function()
		local world = fake_world()
		execution.run(request("exec-no-diagnostics", { diagnostics = false }), world.sink, world.deps)
		world.runs[1].callback(nil, "permission denied")
		assert(#world.diagnostics == 0)
		assert(world.notifications[1].message == "permission denied")
	end,
}
