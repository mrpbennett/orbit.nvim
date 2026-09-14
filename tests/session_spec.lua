local runner = require("orbit.runner")
local session = require("orbit.session")
local adapters = require("orbit.adapters")

return {
	["MSSQL builds the exact Go sqlcmd argv and a sanitized child environment"] = function()
		local mssql = require("orbit.connectors.mssql")
		local separator = string.char(31)
		local options = {
			host = "sql.example",
			port = 1444,
			database = "warehouse",
			user = "orbit",
			password = "resolved-secret",
			executable = "/opt/sqlcmd",
			trust_server_certificate = true,
		}
		assert(vim.deep_equal(assert(mssql.session_command(options)), {
			"/opt/sqlcmd", "-S", "tcp:sql.example,1444", "-d", "warehouse", "-U", "orbit",
			"-N", "mandatory", "-C", "-s", separator, "-w", "65535", "-y", "8000",
			"-Y", "8000", "-x",
		}))
		local defaults = vim.deepcopy(options)
		defaults.port = nil
		defaults.trust_server_certificate = false
		assert(vim.deep_equal(assert(mssql.session_command(defaults)), {
			"/opt/sqlcmd", "-S", "tcp:sql.example,1433", "-d", "warehouse", "-U", "orbit",
			"-N", "mandatory", "-s", separator, "-w", "65535", "-y", "8000", "-Y", "8000",
			"-x",
		}))
		local environment = assert(mssql.environment(options, {
			PATH = "/bin",
			SQLCMDSERVER = "inherited",
			SQLCMDINI = "/tmp/unsafe",
			sqlcmdpassword = "old-secret",
		}))
		assert(mssql.inherit_environment == false)
		assert(vim.deep_equal(environment, { PATH = "/bin", SQLCMDPASSWORD = "resolved-secret" }))
		assert(not vim.inspect(assert(mssql.session_command(options))):find("resolved-secret", 1, true))
	end,

	["MSSQL resolves password_env without inheriting its source variable"] = function()
		local mssql = require("orbit.connectors.mssql")
		local name = "ORBIT_MSSQL_RESOLVED_PASSWORD"
		local original = vim.env[name]
		vim.env[name] = "environment-secret"
		local ok, test_err = xpcall(function()
			local options = {
				host = "sql.example",
				database = "warehouse",
				user = "orbit",
				password_env = name,
			}
			local environment = assert(mssql.environment(options, {
				PATH = "/bin",
				[name] = "environment-secret",
				SQLCMDUSER = "inherited-user",
			}))
			assert(vim.deep_equal(environment, { PATH = "/bin", SQLCMDPASSWORD = "environment-secret" }))
			assert(not vim.inspect(assert(mssql.session_command(options))):find("environment-secret", 1, true))
		end, debug.traceback)
		vim.env[name] = original
		assert(ok, test_err)
	end,
	["Session replaces the inherited environment for MSSQL sqlcmd"] = function()
		local original_system = vim.system
		local captured
		vim.system = function(_, options)
			captured = options.env
			return { write = function() end, kill = function() end }
		end
		local profile = {
			name = "mssql-sanitized-environment",
			kind = "mssql",
			options = { host = "sql.example", database = "warehouse", user = "orbit", password = "secret" },
		}
		local ok, test_err = xpcall(function()
			runner.run(profile, "SELECT 1", function() end)
			assert(captured.SQLCMDPASSWORD == "secret")
			for name in pairs(captured) do
				assert(name == "SQLCMDPASSWORD" or not name:upper():match("^SQLCMD"), name)
			end
		end, debug.traceback)
		session.close(profile.name)
		vim.system = original_system
		assert(ok, test_err)
	end,

	["MSSQL checks password sources before spawning sqlcmd"] = function()
		local original_system = vim.system
		local original_password = vim.env.ORBIT_MSSQL_MISSING
		local spawned, received = false, nil
		vim.env.ORBIT_MSSQL_MISSING = nil
		vim.system = function()
			spawned = true
		end
		local profile = {
			name = "mssql-missing-password",
			kind = "mssql",
			options = { host = "sql.example", database = "warehouse", user = "orbit", password_env = "ORBIT_MSSQL_MISSING" },
		}
		local ok, test_err = xpcall(function()
			runner.run(profile, "SELECT 1", function(_, err) received = err end)
			assert(vim.wait(100, function() return received ~= nil end))
			assert(received:match("does not contain an MSSQL password"), received)
			assert(not spawned)
		end, debug.traceback)
		session.close(profile.name)
		vim.system = original_system
		vim.env.ORBIT_MSSQL_MISSING = original_password
		assert(ok, test_err)
	end,

	["MSSQL frames three batches and consumes the complete end marker record"] = function()
		local mssql = require("orbit.connectors.mssql")
		local marker = "orbit-marker"
		assert(mssql.session_request("SELECT 7 AS value", marker) == table.concat({
			"SET NOCOUNT ON;",
			"SELECT 'orbit-marker:BEGIN' AS [__orbit_frame];",
			"GO",
			"SELECT 7 AS value",
			"GO",
			"SET NOCOUNT ON;",
			"SELECT 'orbit-marker:END' AS [__orbit_frame];",
			"GO",
			"",
		}, "\n"))
		local payload = "value   \n------- \n7       \n\n"
		local output = table.concat({
			"__orbit_frame      ",
			"------------------ ",
			marker .. ":BEGIN   ",
		}, "\r\n") .. "\r\n\r\n" .. payload .. table.concat({
			"__orbit_frame    ",
			"---------------- ",
			marker .. ":END   ",
		}, "\r\n") .. "\r\n\r\nresidual"
		local expected_consumed = #output - #"residual"
		for length = 1, expected_consumed - 1 do
			assert(mssql.session_output(output:sub(1, length), marker) == nil, length)
		end
		assert(select(2, mssql.session_output(output:sub(1, expected_consumed), marker)) == expected_consumed)
		local framed, consumed = mssql.session_output(output, marker)
		assert(framed == payload, vim.inspect(framed))
		assert(consumed == expected_consumed)
	end,

	["MSSQL rejects GO and sqlcmd control commands"] = function()
		local mssql = require("orbit.connectors.mssql")
		for _, statement in ipairs({
			"SELECT 1\nGO",
			"EXIT",
			" quit ",
			":CONNECT other-server",
			":r file.sql",
			":setvar name value",
			"!! rm file",
			"ED",
			"RESET",
			"ON ERROR EXIT",
			"EXIT(SELECT 1)",
		}) do
			local framed, err = mssql.session_request(statement, "marker")
			assert(framed == nil and err:match("not supported"), statement)
		end
		assert(mssql.session_request("SELECT 'GO', ':r', 'EXIT'", "marker"))
		assert(mssql.session_request("EXIT_PROC", "marker"))
		assert(mssql.session_request("RESET_CACHE", "marker"))
		assert(mssql.session_request("LIST", "marker"))
		assert(mssql.session_request("SELECT 'open\nGO\nclose'", "marker"))
	end,
	["MSSQL preserves stdout diagnostics when sqlcmd exits before its end marker"] = function()
		local mssql = require("orbit.connectors.mssql")
		local stdout = "__orbit_frame\n---------------\nmarker:BEGIN\n\nMsg 102, Level 15, State 1\nIncorrect syntax near 'FROM'.\n"
		local detail = mssql.session_exit_error(stdout, "")
		assert(detail:match("Msg 102") and detail:match("Incorrect syntax"), detail)
		local combined = mssql.session_exit_error(stdout, "fatal stderr")
		assert(combined:match("Msg 102") and combined:match("fatal stderr"), combined)
		assert(mssql.session_exit_error("partial result row", "") == nil)
	end,

	["MSSQL parses one padded separator result and exposes NULL ambiguity"] = function()
		local mssql = require("orbit.connectors.mssql")
		local separator = string.char(31)
		local rows, err, metadata = mssql.parse(table.concat({
			" value " .. separator .. " missing ",
			"-------" .. separator .. "---------",
			" 7     " .. separator .. " NULL    ",
			" NULL  " .. separator .. " text    ",
			"",
		}, "\n"))
		assert(err == nil and #rows == 2)
		assert(rows[1].value == "7" and rows[1].missing == "NULL")
		-- Keep ambiguous NULL output as text rather than claiming typed fidelity.
		assert(rows[2].value == "NULL" and rows[2].missing == "text")
		assert(vim.deep_equal(metadata, { columns = { "value", "missing" } }))
	end,

	["MSSQL rejects detectable parser corruption, messages, and multiple results"] = function()
		local mssql = require("orbit.connectors.mssql")
		local separator = string.char(31)
		local cases = {
			{ "" .. separator .. "b\n-" .. separator .. "-\n1" .. separator .. "2\n", "heading must not be empty" },
			{ "a" .. separator .. "a\n-" .. separator .. "-\n1" .. separator .. "2\n", "duplicate heading" },
			{ "a" .. separator .. "b\n-" .. separator .. "-\n1\n", "1 fields for 2 headings" },
			{ "a\nnot-dashes\n1\n", "malformed underline" },
			{ "a\n-\n1" .. separator .. "injected\n", "2 fields for 1 headings" },
			{ "a\n-\nMsg 102, Level 15, State 1\n", "contains a server message" },
			{ "informational message\n", "message or malformed result" },
			{ "a\n-\n1\n\nb\n-\n2\n", "multiple tabular results" },
			{ "a\n-\n1\nb\n-\n2\n", "multiple tabular results" },
		}
		for _, case in ipairs(cases) do
			local rows, err = mssql.parse(case[1])
			assert(rows == nil and err:match(case[2]), vim.inspect({ case[2], err }))
		end
		local _, server_err = mssql.parse("Msg 102, Level 15, State 1\nIncorrect syntax near 'FROM'.\n")
		assert(server_err:match("Msg 102") and server_err:match("Incorrect syntax"), server_err)
		local empty, empty_err, metadata = mssql.parse("")
		assert(vim.deep_equal(empty, {}) and empty_err == nil and metadata == nil)
	end,
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
	["invalid framing isolates stale process callbacks from a replacement"] = function()
		local original_system = vim.system
		local process
		local processes = {}
		vim.system = function(_, options, exit_callback)
			process = { writes = {}, stdout = options.stdout, stderr = options.stderr, killed = false }
			function process:write(input) self.writes[#self.writes + 1] = input end
			function process:kill() self.killed = true end
			process.exit = exit_callback
			processes[#processes + 1] = process
			return process
		end
		local profile = { name = "discard-response", kind = "fake", options = {} }
		local connector = {
			session_command = function() return { "fake" } end,
			 session_request = function(statement, marker) return statement .. "|" .. marker end,
			session_output = function(output)
				if output == "fatal\n" then return "fatal", #output + 1 end
				if output == "ok\n" then return "ok", #output end
			end,
		}
		local first, second
		local ok, test_err = xpcall(function()
			session.run(profile, connector, "first", function(output, err) first = { output, err } end)
			session.run(profile, connector, "second", function(output, err) second = { output, err } end)
			assert(#process.writes == 1)
			process.stdout(nil, "fatal\n")
			assert(vim.wait(100, function() return first and second end))
			assert(first[1] == nil and first[2] == "connector returned invalid session framing")
			assert(second[1] == nil and second[2] == first[2])
			assert(#process.writes == 1 and process.killed and not session.connected(profile.name))
			local third
			session.run(profile, connector, "third", function(output, err) third = { output, err } end)
			assert(#processes == 2 and #processes[2].writes == 1 and session.connected(profile.name))
			processes[1].stdout(nil, "fatal\n")
			processes[1].stderr(nil, "stale error")
			assert(session.connected(profile.name) and third == nil)
			processes[1].exit({ code = 1, stderr = "old process closed" })
			assert(session.connected(profile.name) and third == nil)
			processes[2].stdout(nil, "ok\n")
			assert(vim.wait(100, function() return third ~= nil end))
			assert(third[1] == "ok" and third[2] == nil)
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
