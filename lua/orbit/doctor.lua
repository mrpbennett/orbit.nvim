-- Local diagnostics for connector profiles and their executables.
local M = {}

local connector_defaults = {
	mysql = { executable = "mysql", version_args = { "--version" } },
	postgres = { executable = "psql", version_args = { "--version" } },
	redis = { executable = "redis-cli", version_args = { "--version" } },
	sqlite = { executable = "sqlite3", version_args = { "--version" } },
	trino = { executable = "trino", version_args = { "--version" } },
	vertica = { executable = "vsql", version_args = { "--version" } },
}

local kinds = { "sqlserver", "mysql", "postgres", "redis", "sqlite", "trino", "vertica" }

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

local function redact(value, profile, deps)
	if not profile then
		return value
	end
	local credentials = type(profile.options.authentication) == "table" and profile.options.authentication or profile.options
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
	local override = profile and profile.options and profile.options.executable
	if kind == "mysql" and not override and profile and profile.options.client_family == "mariadb" then
		return "mariadb", "PATH"
	end
	return override or connector_defaults[kind].executable, override and "override" or "PATH"
end

-- Doctor formats the safe facts returned by the SQL Server Connector. Transport
-- selection, prerequisite checks, environment handling, and invocation stay
-- behind the Connector seam.
local function append_sqlserver_facts(entry, label, facts, profile, deps)
	local executable = facts.executable
	entry[#entry + 1] = string.format(
		"%s %s: %s (%s)",
		executable.found and "[OK]" or "[FAIL]",
		label,
		executable.value,
		executable.source
	)
	if facts.credential and facts.credential.environment then
		entry[#entry + 1] = string.format(
			"%s %s environment %s",
			facts.credential.present and "[OK]" or "[FAIL]",
			label,
			facts.credential.environment
		)
	elseif facts.credential and facts.credential.configured then
		entry[#entry + 1] = "[OK] " .. label .. " credential: profile password configured"
	elseif facts.credential then
		entry[#entry + 1] = "[FAIL] " .. label .. " credential: password or password_env is required"
	end
	for _, prerequisite in ipairs(facts.prerequisites or {}) do
		entry[#entry + 1] = string.format(
			"%s %s %s: %s",
			prerequisite.found and "[OK]" or "[FAIL]",
			label,
			prerequisite.label,
			prerequisite.value
		)
	end
	if facts.result then
		if facts.result.value then
			entry[#entry + 1] = string.format("[OK] %s %s: %s (compatibility unverified)", label, facts.result.name, redact(facts.result.value, profile, deps))
		else
			entry[#entry + 1] = "[FAIL] " .. label .. " " .. facts.result.name .. ": " .. redact(facts.result.error, profile, deps)
		end
	end
	for _, finding in ipairs(facts.findings or {}) do
		entry[#entry + 1] = "[FAIL] " .. label .. " " .. finding.name .. ": " .. redact(finding.error, profile, deps)
	end
end

-- Diagnose without running SQL or opening a database connection. Only each
-- executable's version mode is invoked; environment values are never printed.
function M.run(kind, config, callback, overrides)
	callback = callback or function() end
	if kind and not vim.tbl_contains(kinds, kind) then
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
		if check.kind == "sqlserver" then
			require("orbit.connectors.sqlserver").diagnose(profile and profile.options or nil, deps, function(facts)
				local entry = {}
				append_sqlserver_facts(entry, label, facts, profile, deps)
				results[index] = entry
				pending = pending - 1
				complete()
			end)
		else
		local executable, source = selected_executable(check.kind, profile, deps)
		local resolved = deps.executable(executable) and deps.exepath(executable) or ""
		if resolved == "" and deps.executable(executable) then
			resolved = executable
		end
		local entry = { string.format("%s %s: %s (%s)", resolved ~= "" and "[OK]" or "[FAIL]", label, resolved ~= "" and resolved or executable, source) }
		results[index] = entry

		if check.kind == "redis" and profile and profile.options.password_env then
			local value = deps.getenv(profile.options.password_env)
			entry[#entry + 1] = string.format(
				"%s %s environment %s",
				value ~= nil and value ~= "" and "[OK]" or "[FAIL]",
				label,
				profile.options.password_env
			)
		end

		if resolved == "" then
			entry[#entry + 1] = "[FAIL] " .. label .. " version: executable not found"
			pending = pending - 1
			complete()
		else
			local command = { resolved }
			vim.list_extend(command, connector_defaults[check.kind].version_args)
			local run_options
			if check.kind == "redis" then
				run_options = {
					clear_env = true,
					env = require("orbit.connectors.redis").sanitize_environment(profile and profile.options or {}, deps.environ()),
				}
			end
			deps.run(command, function(result)
				local version = redact(first_line(result.stdout or ""), profile, deps)
				if result.code == 0 and version ~= "" then
					entry[#entry + 1] = string.format("[OK] %s version: %s", label, version)
				else
					local stderr = redact(first_line(result.stderr), profile, deps)
					entry[#entry + 1] = "[FAIL] " .. label .. " version: " .. (stderr ~= "" and stderr or "version command failed")
				end
				pending = pending - 1
				complete()
			end, run_options)
		end
		end
	end
end

function M.kinds()
	return vim.deepcopy(kinds)
end

return M
