local runner = require("orbit.runner")
local session = require("orbit.session")
local fake_process = require("tests.support.fake_process")

-- A fake process port whose one-shot children exit immediately with `stdout`.
local function exiting_with(stdout)
	return fake_process.new({
		on_spawn = function(child)
			child:exit(0, stdout, "")
		end,
	})
end

return {
	["runner applies one-shot Connector process options"] = function()
		local fake = exiting_with("")
		local completed
		local connector = {
			prepare = function()
				return { "fake" }, nil, { clear_env = true, env = { TOKEN = "secret" } }
			end,
			parse = function() return {} end,
		}

		runner.run({ name = "options", options = {} }, "GET key", function(rows, err)
			completed = rows and not err
		end, connector, fake.deps)
		assert(vim.wait(100, function() return completed ~= nil end))
		local received_options = fake.last().options
		assert(received_options.text == true and received_options.clear_env == true)
		assert(vim.deep_equal(received_options.env, { TOKEN = "secret" }))
	end,

	["runner preserves optional Connector execution metadata"] = function()
		local fake = exiting_with("wire")
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

		runner.run({ name = "metadata", kind = "fake", options = {} }, "SELECT 1", function(rows, err, execution)
			received = { rows = rows, err = err, metadata = execution }
		end, connector, fake.deps)
		assert(vim.wait(100, function() return received ~= nil end))
		assert(received.err == nil and received.rows[1].first == 1)
		assert(received.metadata == metadata)
	end,

	["runner keeps the existing two-value parse contract"] = function()
		local fake = exiting_with("wire")
		local received
		local connector = {
			prepare = function() return { "fake" } end,
			parse = function() return { { value = 1 } } end,
		}

		runner.run({ name = "legacy", kind = "fake", options = {} }, "SELECT 1", function(rows, err, metadata)
			received = { rows, err, metadata }
		end, connector, fake.deps)
		assert(vim.wait(100, function() return received ~= nil end))
		assert(received[1][1].value == 1 and received[2] == nil and received[3] == nil)
	end,

	["runner reports a one-shot CLI that cannot start"] = function()
		local fake = fake_process.new({ fail = "ENOENT: no such file or directory" })
		local received
		local process = runner.run({ name = "missing", kind = "fake", options = {} }, "SELECT 1", function(rows, err)
			received = { rows = rows, err = err }
		end, { prepare = function() return { "missing-cli" } end }, fake.deps)
		assert(process == nil)
		assert(vim.wait(100, function() return received ~= nil end))
		assert(received.rows == nil and received.err == "cannot start CLI: ENOENT: no such file or directory")
	end,

	["runner reports a failing one-shot CLI and cancels by killing it"] = function()
		local fake = fake_process.new()
		local received
		local connector = { prepare = function() return { "fake" } end }
		local process = runner.run({ name = "failing", kind = "fake", options = {} }, "GET key", function(rows, err)
			received = { rows = rows, err = err }
		end, connector, fake.deps)
		assert(process == fake.last())
		runner.cancel(process)
		assert(process.killed == 15)
		-- redis-cli reports some errors on stdout, so stdout is the fallback.
		process:exit(1, "ERR unknown command", "")
		assert(vim.wait(100, function() return received ~= nil end))
		assert(received.rows == nil and received.err == "command failed (1): ERR unknown command")
	end,

	["runner preserves metadata parsed from retained session output"] = function()
		local fake = fake_process.new()
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
			end, connector, fake.deps)
			local child = fake.last()
			assert(child.options.stdin == true)
			local marker = child.writes[1]:match("|([^|]+)|$")
			child:stdout("payload<" .. marker .. ">\n")
			assert(vim.wait(100, function() return received ~= nil end))
			assert(received.err == nil and received.rows[1].value == 1)
			assert(received.metadata == metadata)
		end, debug.traceback)
		session.close(profile.name)
		assert(ok, test_err)
	end,
}
