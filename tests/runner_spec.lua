local runner = require("orbit.runner")
local session = require("orbit.session")

return {
	["runner preserves optional Connector execution metadata"] = function()
		local original_system = vim.system
		vim.system = function(_, _, callback)
			callback({ code = 0, stdout = "wire", stderr = "" })
			return { kill = function() end }
		end
		local received
		local metadata = {
			columns = { "second", "first" },
		}
		local connector = {
			prepare = function() return { "fake" } end,
			parse = function(output)
				assert(output == "wire")
				return { { first = 1, second = 2 } }, nil, metadata
			end,
		}

		local ok, test_err = xpcall(function()
			runner.run({ name = "metadata", kind = "fake", options = {} }, "SELECT 1", function(rows, err, execution)
				received = { rows = rows, err = err, metadata = execution }
			end, connector)
			assert(vim.wait(100, function() return received ~= nil end))
			assert(received.err == nil and received.rows[1].first == 1)
			assert(received.metadata == metadata)
		end, debug.traceback)
		vim.system = original_system
		assert(ok, test_err)
	end,

	["runner keeps the existing two-value parse contract"] = function()
		local original_system = vim.system
		vim.system = function(_, _, callback)
			callback({ code = 0, stdout = "wire", stderr = "" })
			return { kill = function() end }
		end
		local received
		local connector = {
			prepare = function() return { "fake" } end,
			parse = function() return { { value = 1 } } end,
		}

		runner.run({ name = "legacy", kind = "fake", options = {} }, "SELECT 1", function(rows, err, metadata)
			received = { rows, err, metadata }
		end, connector)
		assert(vim.wait(100, function() return received ~= nil end))
		assert(received[1][1].value == 1 and received[2] == nil and received[3] == nil)
		vim.system = original_system
	end,

	["runner preserves metadata parsed from retained session output"] = function()
		local original_system = vim.system
		local stdout_callback
		local written
		vim.system = function(_, options)
			stdout_callback = options.stdout
			return {
				write = function(_, input) written = input end,
				kill = function() end,
			}
		end
		local profile = { name = "retained-metadata", kind = "fake", options = {} }
		local metadata = { columns = { "value" } }
		local connector = {
			session_command = function() return { "fake" } end,
			session_request = function(statement, marker) return statement .. "|" .. marker .. "|" end,
			session_output = function(output, marker)
				local frame = "<" .. marker .. ">\n"
				local start_at, finish = output:find(frame, 1, true)
				return start_at and output:sub(1, start_at - 1) or nil, finish
			end,
			parse = function(output)
				assert(output == "payload")
				return { { value = 1 } }, nil, metadata
			end,
		}
		local received

		local ok, test_err = xpcall(function()
			runner.run(profile, "SELECT 1", function(rows, err, execution)
				received = { rows = rows, err = err, metadata = execution }
			end, connector)
			local marker = written:match("|([^|]+)|$")
			stdout_callback(nil, "payload<" .. marker .. ">\n")
			assert(vim.wait(100, function() return received ~= nil end))
			assert(received.err == nil and received.rows[1].value == 1)
			assert(received.metadata == metadata)
		end, debug.traceback)
		session.close(profile.name)
		vim.system = original_system
		assert(ok, test_err)
	end,
}
