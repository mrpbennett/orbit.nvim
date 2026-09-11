local runner = require("orbit.runner")
local session = require("orbit.session")
local adapters = require("orbit.adapters")

return {
	["session preserves residual stdout until the next complete frame"] = function()
		local original_system = vim.system
		local stdout_callback
		local writes = {}
		vim.system = function(_, options)
			stdout_callback = options.stdout
			return {
				write = function(_, input)
					table.insert(writes, input)
				end,
				kill = function() end,
			}
		end

		local profile = { name = "framing", kind = "fake", options = {} }
		local ok, test_err = xpcall(function()
			local connector = {
				session_command = function() return { "fake" } end,
				session_request = function(statement, marker) return statement .. "|" .. marker .. "|" end,
				session_output = function(output, marker)
					local frame = "<" .. marker .. ">\n"
					local start_at, end_at = output:find(frame, 1, true)
					return start_at and output:sub(1, start_at - 1) or nil, end_at
				end,
			}
			local first, second
			session.run(profile, connector, "first", function(output, err) first = { output, err } end)
			session.run(profile, connector, "second", function(output, err) second = { output, err } end)
			assert(#writes == 1)
			local first_marker = writes[1]:match("|([^|]+)|$")
			stdout_callback(nil, "first-output<" .. first_marker .. ">")
			assert(#writes == 1 and first == nil)
			stdout_callback(nil, "\nnext-prefix")
			assert(#writes == 2)
			local second_marker = writes[2]:match("|([^|]+)|$")
			stdout_callback(nil, "second-output<" .. second_marker .. ">\n")
			assert(vim.wait(100, function() return first and second end))
			assert(first[1] == "first-output" and first[2] == nil)
			assert(second[1] == "next-prefixsecond-output" and second[2] == nil)
		end, debug.traceback)
		session.close(profile.name)
		vim.system = original_system
		assert(ok, test_err)
	end,

	["retained Connectors wait for every complete marker record"] = function()
		local marker = "__orbit_marker__"
		local cases = {
			{
				connector = assert(adapters.connector({ kind = "sqlite" })),
				output = '[{"value":1}]\n[{"__orbit_marker":"' .. marker .. '"}]\n',
				payload = '[{"value":1}]\n',
			},
			{
				connector = assert(adapters.connector({ kind = "postgres" })),
				output = "value\n1\n__orbit_marker\n" .. marker .. "\n",
				payload = "value\n1\n",
			},
			{
				connector = assert(adapters.connector({ kind = "mysql" })),
				output = '<?xml version="1.0"?>\n<resultset><row><field name="value">1</field></row></resultset>\n'
					.. '<?xml version="1.0"?>\n<resultset><row><field name="__orbit_frame">' .. marker .. ':END</field></row></resultset>\n',
				payload = '<?xml version="1.0"?>\n<resultset><row><field name="value">1</field></row></resultset>\n',
			},
			{
				connector = assert(adapters.connector({ kind = "vertica" })),
				output = "<table><tr><th>value</th></tr><tr><td>1</td></tr></table>\n"
					.. "<table><tr><th>__orbit_marker</th></tr><tr><td>" .. marker .. "</td></tr></table>\n",
				payload = "<table><tr><th>value</th></tr><tr><td>1</td></tr></table>\n",
			},
		}
		for _, case in ipairs(cases) do
			for length = 1, #case.output - 1 do
				assert(case.connector.session_output(case.output:sub(1, length), marker) == nil, length)
			end
			local payload, consumed = case.connector.session_output(case.output, marker)
			assert(payload == case.payload, vim.inspect({ payload, case.payload }))
			assert(consumed == #case.output)
		end
	end,

  ["runner reuses one SQLite connection for queued requests"] = function()
    local profile = {
      name = "session-reuse",
      kind = "sqlite",
      options = { path = ":memory:" },
    }
    local created, rows, create_err, select_err

    runner.run(profile, "CREATE TEMP TABLE orbit_session_test (value INTEGER); INSERT INTO orbit_session_test VALUES (7)", function(_, err)
      created, create_err = true, err
    end)
    runner.run(profile, "SELECT value FROM orbit_session_test", function(result, err)
      rows, select_err = result, err
    end)

    assert(vim.wait(1000, function()
      return created and (rows or select_err)
    end), "timed out waiting for retained SQLite session")
    assert(create_err == nil, create_err)
    assert(select_err == nil, select_err)
    assert(rows[1].value == 7)
    assert(session.connected(profile.name))
    session.close(profile.name)
  end,

  ["closing a session fails active requests and allows reconnecting"] = function()
    local profile = {
      name = "session-close",
      kind = "sqlite",
      options = { path = ":memory:" },
    }
    local closed_err, rows, select_err

    local request = runner.run(profile, "SELECT 1", function(_, err)
      closed_err = err
    end)
    session.close(profile.name)
    assert(vim.wait(1000, function()
      return closed_err ~= nil
    end), "timed out waiting for closed request")
    assert(closed_err == "connection closed")

    runner.run(profile, "SELECT 2 AS value", function(result, err)
      rows, select_err = result, err
    end)
    assert(vim.wait(1000, function()
      return rows or select_err
    end), "timed out waiting for reconnected SQLite session")
    assert(select_err == nil, select_err)
    assert(rows[1].value == 2)
    assert(request.done)
    session.close(profile.name)
  end,

	["changing a profile replaces its retained session"] = function()
		local profile = {
			name = "session-profile-change",
			kind = "sqlite",
			options = { path = ":memory:" },
		}
		local created, create_err, select_err

		runner.run(profile, "CREATE TEMP TABLE orbit_session_test (value INTEGER)", function(_, err)
			created, create_err = true, err
		end)
		assert(vim.wait(1000, function()
			return created
		end), "timed out waiting for the initial SQLite session")
		assert(create_err == nil, create_err)

		profile.options = { arguments = { "-bail" }, path = ":memory:" }
		runner.run(profile, "SELECT value FROM orbit_session_test", function(_, err)
			select_err = err
		end)
		assert(vim.wait(1000, function()
			return select_err ~= nil
		end), "timed out waiting for the replacement SQLite session")
		assert(select_err:match("connection closed"))
		session.close(profile.name)
	end,
}
