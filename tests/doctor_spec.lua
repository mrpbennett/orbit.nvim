local doctor = require("orbit.doctor")

local function assert_match(value, pattern)
	assert(value and value:match(pattern), tostring(value))
end

return {
	["doctor checks sqlcmd and password environment without connecting"] = function()
		local commands = {}
		local report
		doctor.run("mssql", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function(command) return command == "/custom/sqlcmd" end,
			exepath = function(command) return command end,
			getenv = function() return "secret" end,
			load_profiles = function()
				return { profiles = { { name = "warehouse", kind = "mssql", options = {
					executable = "/custom/sqlcmd",
					password_env = "MSSQL_PASSWORD",
				} } } }
			end,
			run = function(command, callback)
				commands[#commands + 1] = command
				callback({ code = 0, stdout = "sqlcmd: Install/Create/Query SQL Server\nVersion: 1.8.0\n", stderr = "" })
			end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert(#commands == 1 and commands[1][1] == "/custom/sqlcmd" and commands[1][2] == "--version")
		assert_match(report, "/custom/sqlcmd %(override%)")
		assert_match(report, "%[OK%] mssql profile \"warehouse\" environment MSSQL_PASSWORD")
		assert_match(report, "version: 1%.8%.0")
		assert_match(report, "compatibility unverified")
		assert(not report:match("secret"))
	end,

	["doctor rejects an empty MSSQL password environment"] = function()
		local report
		doctor.run("mssql", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function() return false end,
			getenv = function() return "" end,
			load_profiles = function()
				return { profiles = { { name = "empty", kind = "mssql", options = { password_env = "MSSQL_PASSWORD" } } } }
			end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert_match(report, "%[FAIL%] mssql profile \"empty\" environment MSSQL_PASSWORD")
	end,

	["doctor reports missing MSSQL credentials and non-Go sqlcmd variants"] = function()
		local report
		doctor.run("mssql", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function() return true end,
			exepath = function(command) return command end,
			load_profiles = function()
				return { profiles = { { name = "missing", kind = "mssql", options = {} } } }
			end,
			run = function(_, callback) callback({ code = 0, stdout = "Microsoft SQL Server Command Line Tool\n", stderr = "" }) end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert_match(report, "credential: password or password_env is required")
		assert_match(report, "cannot identify Microsoft Go sqlcmd")
	end,

	["doctor diagnoses every Connector and registers command completion"] = function()
		local report
		doctor.run(nil, { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function() return false end,
			load_profiles = function() return { profiles = {} } end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		for _, kind in ipairs({ "mssql", "mysql", "postgres", "sqlite", "trino", "vertica" }) do
			assert_match(report, "%[FAIL%] " .. kind .. ":")
		end
		require("orbit").setup()
		assert(vim.fn.exists(":OrbitDoctor") == 2)
		assert(vim.tbl_contains(vim.fn.getcompletion("OrbitDoctor m", "cmdline"), "mssql"))
		assert(vim.fn.exists(":OrbitInstall") == 0)
	end,
}
