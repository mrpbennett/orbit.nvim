-- Local diagnostics for connector profiles and their executables.
local M = {}

local connector_defaults = {
	mssql = { executable = "sqlcmd", version_args = { "--version" } },
	mysql = { executable = "mysql", version_args = { "--version" } },
	postgres = { executable = "psql", version_args = { "--version" } },
	redis = { executable = "redis-cli", version_args = { "--version" } },
	sqlite = { executable = "sqlite3", version_args = { "--version" } },
	trino = { executable = "trino", version_args = { "--version" } },
	vertica = { executable = "vsql", version_args = { "--version" } },
}

local kinds = { "mssql", "mysql", "postgres", "redis", "sqlite", "trino", "vertica" }

local function default_dependencies()
	return {
		executable = function(command)
			return vim.fn.executable(command) == 1
		end,
		exepath = vim.fn.exepath,
		getenv = function(name)
			return vim.env[name]
		end,
		filereadable = function(path)
			return vim.fn.filereadable(path) == 1
		end,
		load_profiles = function(path)
			return require("orbit.profiles").load(path)
		end,
		environ = vim.fn.environ,
		run = function(command, callback, options)
			options = vim.tbl_extend("force", { text = true, timeout = 5000 }, options or {})
			vim.system(command, options, function(result)
				vim.schedule(function()
					callback(result)
				end)
			end)
		end,
		uname = vim.uv.os_uname,
	}
end

local function first_line(value)
	return vim.trim((value or ""):match("[^\r\n]*") or "")
end

local function jdbc_profile(profile)
	return profile and profile.kind == "mssql" and profile.options.transport == "jdbc"
end

local function version_text(kind, output, profile)
	if jdbc_profile(profile) then
		local text = first_line(output)
		return text:match("^Orbit MSSQL helper: (Java %d+; jTDS 1%.3%.1 loaded)$")
	end
	if kind == "mssql" then
		return output:match("[Vv]ersion:%s*([^\r\n]+)")
	end
	return first_line(output)
end

local function redact(value, profile, deps)
	if not profile then
		return value
	end
	local credentials = jdbc_profile(profile) and profile.options.authentication or profile.options
	local secrets = { credentials and credentials.password }
	if credentials and credentials.password_env then
		secrets[#secrets + 1] = deps.getenv(credentials.password_env)
	end
	for _, secret in ipairs(secrets) do
		if type(secret) == "string" and secret ~= "" then
			value = value:gsub(vim.pesc(secret), "[REDACTED]")
		end
	end
	return value
end

local function selected_executable(kind, profile, deps)
	if jdbc_profile(profile) then
		local override = profile.options.java_executable
		return override or "java", override and "override" or "PATH"
	end
	local override = profile and profile.options and profile.options.executable
	if kind == "mysql" and not override and profile and profile.options.client_family == "mariadb" then
		return "mariadb", "PATH"
	end
	return override or connector_defaults[kind].executable, override and "override" or "PATH"
end

-- Diagnose without running SQL or opening a database connection. Only each
-- executable's version mode is invoked; environment values are never printed.
function M.run(kind, config, callback, overrides)
	callback = callback or function() end
	if kind and not connector_defaults[kind] then
		callback(nil, "unsupported connector kind: " .. tostring(kind))
		return
	end
	local deps = vim.tbl_extend("force", default_dependencies(), overrides or {})
	local selected_kinds = kind and { kind } or kinds
	local document, profile_err = deps.load_profiles(config.profile_path)
	local lines = {
		"Orbit Doctor",
		string.format("Platform: %s/%s", tostring(deps.uname().sysname), tostring(deps.uname().machine)),
	}
	if profile_err then
		lines[#lines + 1] = "[FAIL] Profiles: " .. profile_err
	else
		lines[#lines + 1] = string.format("[OK] Profiles: %d validated", #document.profiles)
	end

	local checks = {}
	for _, connector_kind in ipairs(selected_kinds) do
		local profiles = {}
		for _, profile in ipairs(document and document.profiles or {}) do
			if profile.kind == connector_kind then
				profiles[#profiles + 1] = profile
			end
		end
		if #profiles == 0 then
			profiles[1] = false
		end
		for _, profile in ipairs(profiles) do
			checks[#checks + 1] = { kind = connector_kind, profile = profile }
		end
	end

	local pending = #checks
	local results = {}
	local function complete()
		if pending ~= 0 then
			return
		end
		for index = 1, #checks do
			for _, line in ipairs(results[index]) do
				lines[#lines + 1] = line
			end
		end
		callback(table.concat(lines, "\n"))
	end

	for index, check in ipairs(checks) do
		local profile = check.profile or nil
		local label = check.kind .. (profile and (" profile " .. string.format("%q", profile.name)) or "")
		local executable, source = selected_executable(check.kind, profile, deps)
		local resolved = deps.executable(executable) and deps.exepath(executable) or ""
		if resolved == "" and deps.executable(executable) then
			resolved = executable
		end
		local entry = { string.format("%s %s: %s (%s)", resolved ~= "" and "[OK]" or "[FAIL]", label, resolved ~= "" and resolved or executable, source) }
		results[index] = entry

		if check.kind == "mssql" and profile then
			local credentials = jdbc_profile(profile) and profile.options.authentication or profile.options
			if credentials and credentials.password_env then
				local value = deps.getenv(credentials.password_env)
				entry[#entry + 1] = string.format("%s %s environment %s", value ~= nil and value ~= "" and "[OK]" or "[FAIL]", label, credentials.password_env)
			elseif credentials and type(credentials.password) == "string" and credentials.password ~= "" then
				entry[#entry + 1] = "[OK] " .. label .. " credential: profile password configured"
			else
				entry[#entry + 1] = "[FAIL] " .. label .. " credential: password or password_env is required"
			end
		end
		if check.kind == "redis" and profile and profile.options.password_env then
			local value = deps.getenv(profile.options.password_env)
			entry[#entry + 1] = string.format(
				"%s %s environment %s",
				value ~= nil and value ~= "" and "[OK]" or "[FAIL]",
				label,
				profile.options.password_env
			)
		end

		local dependency_missing = false
		if jdbc_profile(profile) then
			local readable = deps.filereadable(profile.options.driver_path)
			entry[#entry + 1] = string.format(
				"%s %s jTDS JAR: %s",
				readable and "[OK]" or "[FAIL]",
				label,
				profile.options.driver_path
			)
			dependency_missing = not readable
		end

		if resolved == "" or dependency_missing then
			if jdbc_profile(profile) then
				if resolved == "" then entry[#entry + 1] = "[FAIL] " .. label .. " helper: Java executable not found" end
				if dependency_missing then entry[#entry + 1] = "[FAIL] " .. label .. " helper: jTDS JAR not readable" end
			else
				entry[#entry + 1] = "[FAIL] " .. label .. " version: executable not found"
			end
			pending = pending - 1
			complete()
		else
			local command = { resolved }
			if jdbc_profile(profile) then
				vim.list_extend(command, {
					"--class-path",
					profile.options.driver_path,
					require("orbit.connectors.mssql_jdbc").helper_path(),
					"--doctor",
				})
			else
				vim.list_extend(command, connector_defaults[check.kind].version_args)
			end
			local run_options
			if jdbc_profile(profile) then
				run_options = {
					clear_env = true,
					env = require("orbit.connectors.mssql_jdbc").sanitize_environment(profile.options, deps.environ()),
				}
			elseif check.kind == "redis" then
				run_options = {
					clear_env = true,
					env = require("orbit.connectors.redis").sanitize_environment(profile and profile.options or {}, deps.environ()),
				}
			end
			deps.run(command, function(result)
				local version = redact(version_text(check.kind, result.stdout or "", profile) or "", profile, deps)
				if result.code == 0 and version ~= "" then
					local suffix = check.kind == "mssql" and " (compatibility unverified)" or ""
					local check_name = jdbc_profile(profile) and "helper" or "version"
					entry[#entry + 1] = string.format("[OK] %s %s: %s%s", label, check_name, version, suffix)
				else
					local stderr = redact(first_line(result.stderr), profile, deps)
					local fallback = jdbc_profile(profile) and "cannot load the Orbit helper and jTDS driver"
						or check.kind == "mssql" and "cannot identify Microsoft Go sqlcmd"
						or "version command failed"
					entry[#entry + 1] = "[FAIL] " .. label .. (jdbc_profile(profile) and " helper: " or " version: ") .. (stderr ~= "" and stderr or fallback)
				end
				pending = pending - 1
				complete()
			end, run_options)
		end
	end
end

function M.kinds()
	return vim.deepcopy(kinds)
end

return M
