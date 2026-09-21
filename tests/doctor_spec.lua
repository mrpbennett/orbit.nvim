local doctor = require("orbit.doctor")

local function assert_match(value, pattern)
	assert(value and value:match(pattern), tostring(value))
end

return {
	["doctor checks redis-cli without inheriting Redis credentials"] = function()
		local report
		doctor.run("redis", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function(command) return command == "/custom/redis-cli" end,
			exepath = function(command) return command end,
			getenv = function(name) return name == "REDIS_PASSWORD" and "secret" or nil end,
			environ = function()
				return { PATH = "/bin", REDIS_PASSWORD = "secret", REDISCLI_AUTH = "stale", KEEP = "value" }
			end,
			load_profiles = function()
				return { profiles = { { name = "cache", kind = "redis", options = {
					executable = "/custom/redis-cli", host = "localhost", password_env = "REDIS_PASSWORD",
				} } } }
			end,
			run = function(command, callback, options)
				assert(vim.deep_equal(command, { "/custom/redis-cli", "--version" }))
				assert(options.clear_env == true)
				assert(vim.deep_equal(options.env, { PATH = "/bin", KEEP = "value" }))
				callback({ code = 0, stdout = "redis-cli 8.10.1\n", stderr = "" })
			end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert_match(report, "%[OK%] redis profile \"cache\" environment REDIS_PASSWORD")
		assert_match(report, "version: redis%-cli 8%.10%.1")
		assert(not report:match("secret"))
	end,

	["doctor strips ambient Redis authentication without a Redis profile"] = function()
		local report
		doctor.run("redis", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function() return true end,
			exepath = function(command) return command end,
			environ = function() return { PATH = "/bin", REDISCLI_AUTH = "ambient-secret" } end,
			load_profiles = function() return { profiles = {} } end,
			run = function(_, callback, options)
				assert(vim.deep_equal(options.env, { PATH = "/bin" }))
				callback({ code = 0, stdout = "redis-cli 8.10.1\n", stderr = "" })
			end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert_match(report, "%[OK%] redis version")
		assert(not report:match("ambient%-secret"))
	end,

	["doctor checks sqlcmd and password environment without connecting"] = function()
		local commands = {}
		local report
		doctor.run("sqlserver", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function(command) return command == "/custom/sqlcmd" end,
			exepath = function(command) return command end,
			getenv = function() return "secret" end,
			load_profiles = function()
				return { profiles = { { name = "warehouse", kind = "sqlserver", options = {
					executable = "/custom/sqlcmd",
					password_env = "SQLSERVER_PASSWORD",
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
		assert_match(report, "%[OK%] sqlserver profile \"warehouse\" environment SQLSERVER_PASSWORD")
		assert_match(report, "version: 1%.8%.0")
		assert_match(report, "compatibility unverified")
		assert(not report:match("secret"))
	end,

	["doctor rejects an empty SQL Server password environment"] = function()
		local report
		doctor.run("sqlserver", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function() return false end,
			getenv = function() return "" end,
			load_profiles = function()
				return { profiles = { { name = "empty", kind = "sqlserver", options = { password_env = "SQLSERVER_PASSWORD" } } } }
			end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert_match(report, "%[FAIL%] sqlserver profile \"empty\" environment SQLSERVER_PASSWORD")
	end,
	["doctor validates Java and jTDS for JDBC profiles without connecting"] = function()
		local commands = {}
		local report
		doctor.run("sqlserver", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function(command) return command == "/mise/java" end,
			exepath = function(command) return command end,
			filereadable = function(path) return path == "/drivers/jtds.jar" end,
			getenv = function() return "domain-secret" end,
			load_profiles = function()
				return { profiles = { { name = "domain", kind = "sqlserver", options = {
					transport = "jdbc",
					driver = "jtds",
					driver_path = "/drivers/jtds.jar",
					java_executable = "/mise/java",
					authentication = { type = "domain_password", domain = "EXAMPLE", user = "orbit", password_env = "SQLSERVER_PASSWORD" },
				} } } }
			end,
			environ = function()
				return { PATH = "/bin", SQLSERVER_PASSWORD = "domain-secret", JAVA_TOOL_OPTIONS = "unsafe", MISE_ENV_FILE = "/tmp/unsafe", KEEP = "value" }
			end,
			run = function(command, callback, options)
				commands[#commands + 1] = command
				assert(options.clear_env == true and vim.deep_equal(options.env, { PATH = "/bin" }))
				callback({ code = 0, stdout = "Orbit SQL Server helper: Java 25; jTDS 1.3.1 loaded\n", stderr = "" })
			end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert(#commands == 1)
		assert(commands[1][1] == "/mise/java" and commands[1][2] == "--class-path")
		assert(commands[1][3] == "/drivers/jtds.jar" and commands[1][4]:match("OrbitSqlServer%.java$"))
		assert(commands[1][5] == "--doctor")
		assert_match(report, "%[OK%] sqlserver profile \"domain\" jTDS JAR: /drivers/jtds%.jar")
		assert_match(report, "%[OK%] sqlserver profile \"domain\" helper: Java 25; jTDS 1%.3%.1 loaded")
		assert(not report:match("domain%-secret"))
	end,
	["doctor reports JDBC Java JAR and helper failures"] = function()
		local function report_for(overrides)
			local report
			local defaults = {
				executable = function() return true end,
				exepath = function(command) return command end,
				filereadable = function() return true end,
				environ = function() return {} end,
				load_profiles = function()
					return { profiles = { { name = "jdbc-failure", kind = "sqlserver", options = {
						transport = "jdbc",
						driver_path = "/drivers/jtds.jar",
						authentication = { password = "secret" },
					} } } }
				end,
				run = function(_, callback) callback({ code = 1, stdout = "", stderr = "driver class missing secret" }) end,
				uname = function() return { sysname = "Linux", machine = "x86_64" } end,
			}
			doctor.run("sqlserver", { profile_path = "/profiles.json" }, function(value) report = value end,
				vim.tbl_extend("force", defaults, overrides))
			return report
		end
		assert_match(report_for({ executable = function() return false end }), "Java executable not found")
		assert_match(report_for({ filereadable = function() return false end }), "jTDS JAR not readable")
		local helper_failure = report_for({})
		assert_match(helper_failure, "helper: driver class missing %[REDACTED%]")
		assert(not helper_failure:match("secret"))
		assert_match(report_for({
			run = function(_, callback) callback({ code = 1, stdout = "", stderr = "Orbit SQL Server helper requires Java 11 or newer" }) end,
		}), "requires Java 11 or newer")
	end,

	["doctor reports missing SQL Server credentials and non-Go sqlcmd variants"] = function()
		local report
		doctor.run("sqlserver", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function() return true end,
			exepath = function(command) return command end,
			load_profiles = function()
				return { profiles = { { name = "missing", kind = "sqlserver", options = {} } } }
			end,
			run = function(_, callback) callback({ code = 0, stdout = "Microsoft SQL Server Command Line Tool\n", stderr = "" }) end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert_match(report, "credential: password or password_env is required")
		assert_match(report, "cannot identify Microsoft Go sqlcmd")
	end,
	["doctor uses sqlcmd diagnostics without an SQL Server profile"] = function()
		local report
		doctor.run("sqlserver", { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function(command) return command == "sqlcmd" end,
			exepath = function() return "/usr/bin/sqlcmd" end,
			load_profiles = function() return { profiles = {} } end,
			run = function(command, callback)
				assert(vim.deep_equal(command, { "/usr/bin/sqlcmd", "--version" }))
				callback({ code = 0, stdout = "Version: 1.8.0\n", stderr = "" })
			end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		assert_match(report, "%[OK%] sqlserver: /usr/bin/sqlcmd %(PATH%)")
		assert(not report:match("credential:"))
		assert_match(report, "version: 1%.8%.0")
	end,

	["doctor diagnoses every Connector and registers command completion"] = function()
		local report
		doctor.run(nil, { profile_path = "/profiles.json" }, function(value) report = value end, {
			executable = function() return false end,
			load_profiles = function() return { profiles = {} } end,
			uname = function() return { sysname = "Linux", machine = "x86_64" } end,
		})
		for _, kind in ipairs({ "sqlserver", "mysql", "postgres", "redis", "sqlite", "trino", "vertica" }) do
			assert_match(report, "%[FAIL%] " .. kind .. ":")
		end
		require("orbit").setup()
		assert(vim.fn.exists(":OrbitDoctor") == 2)
		assert(vim.tbl_contains(vim.fn.getcompletion("OrbitDoctor s", "cmdline"), "sqlserver"))
		assert(vim.fn.exists(":OrbitInstall") == 0)
	end,
}
