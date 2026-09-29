-- A fake adapter for the process port (lua/orbit/process.lua).
--
-- Usage in a spec:
--   local fake = require("tests.support.fake_process").new()
--   runner.run(profile, "SELECT 1", callback, connector, { spawn = fake.spawn })
--   local child = fake.last()          -- the most recently spawned process
--   child:stdout("partial output")      -- deliver one stdout chunk
--   child:exit(0, "final stdout")       -- finish the process
--   assert(child.writes[1]:match(...))  -- what Orbit wrote to stdin
--
-- Nothing global is replaced, so there is nothing to restore after a test.
local M = {}

function M.new(options)
	options = options or {}
	local fake = { spawned = {} }

	-- Satisfies the port's spawn(command, options, on_exit) -> handle.
	-- `options.fail` makes spawning throw, like a missing executable does.
	function fake.spawn(command, spawn_options, on_exit)
		if options.fail then
			error(options.fail, 0)
		end
		local child = {
			command = command,
			options = spawn_options or {},
			on_exit = on_exit,
			writes = {},
			killed = nil,
			exited = false,
		}
		-- Port methods Orbit calls.
		function child:write(data)
			self.writes[#self.writes + 1] = data
		end
		function child:kill(signal)
			self.killed = signal
		end
		-- Test controls.
		function child:stdout(data)
			if self.options.stdout then
				self.options.stdout(nil, data)
			end
		end
		function child:stderr(data)
			if self.options.stderr then
				self.options.stderr(nil, data)
			end
		end
		function child:exit(code, stdout, stderr)
			self.exited = true
			if self.on_exit then
				self.on_exit({ code = code or 0, stdout = stdout, stderr = stderr })
			end
		end
		fake.spawned[#fake.spawned + 1] = child
		if options.on_spawn then
			options.on_spawn(child)
		end
		return child
	end

	function fake.last()
		return fake.spawned[#fake.spawned]
	end

	-- The dependency table runner.run / session.run accept.
	fake.deps = { spawn = fake.spawn }

	return fake
end

return M
