-- Opt-in live acceptance for the MSSQL JDBC transport. All connection values
-- come from the environment so credentials never enter this repository.
local root = vim.fn.getcwd()
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

local runner = require("orbit.runner")
local connector = require("orbit.connectors.mssql")

local function required(name)
	local value = vim.env[name]
	assert(value and value ~= "", name .. " is required")
	return value
end

local profile = {
	name = "live-mssql-jdbc",
	kind = "mssql",
	options = {
		transport = "jdbc",
		driver = "jtds",
		driver_path = required("ORBIT_MSSQL_JTDS_JAR"),
		java_executable = vim.env.ORBIT_MSSQL_JAVA or "java",
		host = required("ORBIT_MSSQL_HOST"),
		port = tonumber(required("ORBIT_MSSQL_PORT")),
		authentication = {
			type = "domain_password",
			domain = required("ORBIT_MSSQL_DOMAIN"),
			user = required("ORBIT_MSSQL_USER"),
			password_env = vim.env.ORBIT_MSSQL_PASSWORD_ENV or "MSSQL_PASSWORD",
		},
		trust_server_certificate = vim.env.ORBIT_MSSQL_TRUST_SERVER_CERTIFICATE == "1",
	},
}
local tls_mode = profile.options.trust_server_certificate and "ssl=require" or "ssl=authenticate"

assert(connector.validate_options(profile.name, profile.options))

local function execute(statement)
	local rows, err, metadata, completed
	local request = runner.run(profile, statement, function(result, run_err, result_metadata)
		rows, err, metadata, completed = result, run_err, result_metadata, true
	end, connector)
	assert(vim.wait(15000, function() return completed end), "timed out waiting for MSSQL JDBC statement")
	return rows, err, metadata, request
end

local function success(statement)
	local rows, err, metadata = execute(statement)
	assert(rows, err)
	return rows, metadata
end

local live_evidence
local ok, test_err = xpcall(function()
	local rows, metadata = success(table.concat({
		"SELECT CAST(NULL AS varchar(1)) AS [sql_null],",
		"CAST('NULL' AS varchar(4)) AS [literal_null],",
		"CAST('' AS varchar(1)) AS [empty_text],",
		"NCHAR(955) AS [unicode_text],",
		"N'line' + NCHAR(10) + N'value' AS [multiline]",
	}, " "))
	assert(vim.deep_equal(metadata.columns, { "sql_null", "literal_null", "empty_text", "unicode_text", "multiline" }))
	assert(rows[1].sql_null == vim.NIL)
	assert(rows[1].literal_null == "NULL" and rows[1].empty_text == "")
	assert(rows[1].unicode_text == "λ" and rows[1].multiline == "line\nvalue")
	local connection = success(table.concat({
		"SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(32)) AS [product_version],",
		"CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS [edition],",
		"CAST(CONNECTIONPROPERTY('auth_scheme') AS varchar(32)) AS [auth_scheme]",
	}, " "))
	assert(connection[1].auth_scheme == "NTLM", "expected NTLM domain authentication")
	live_evidence = connection[1]

	success("CREATE TABLE #orbit_jdbc_live (value int NOT NULL)")
	success("INSERT INTO #orbit_jdbc_live (value) VALUES (7)")
	local retained = success("SELECT value FROM #orbit_jdbc_live")
	assert(retained[1].value == "7")

	local _, ordinary_err = execute("SELECT * FROM [__orbit_missing_table__]")
	assert(ordinary_err and ordinary_err ~= "", "ordinary SQL error was not reported")
	local retained_after_error = success("SELECT value FROM #orbit_jdbc_live")
	assert(retained_after_error[1].value == "7", "ordinary SQL error replaced the retained connection")
	local recovered = success("SELECT 8 AS value")
	assert(recovered[1].value == "8")

	local schema_rows = success(assert(connector.schema_statement(profile.options, { type = "tables" })))
	assert(type(schema_rows) == "table")

	local active_done, active_err, queued_done, queued_err
	local active = runner.run(profile, "WAITFOR DELAY '00:00:10'; SELECT 1 AS value", function(_, err)
		active_err, active_done = err, true
	end, connector)
	runner.run(profile, "SELECT 2 AS value", function(_, err)
		queued_err, queued_done = err, true
	end, connector)
	vim.wait(100)
	runner.cancel(active)
	assert(vim.wait(1000, function() return active_done and queued_done end), "cancellation callbacks timed out")
	assert(active_err == "query cancelled" and queued_err == "query cancelled")
	local reconnected = success("SELECT 9 AS value")
	assert(reconnected[1].value == "9")
end, debug.traceback)

runner.close(profile.name)
assert(ok, test_err)
print(string.format(
	"PASS live MSSQL JDBC: SQL Server %s %s, %s observed; jTDS configured %s",
	live_evidence.product_version,
	live_evidence.edition,
	live_evidence.auth_scheme,
	tls_mode
))
