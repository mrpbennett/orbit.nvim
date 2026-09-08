local adapters = require("orbit.adapters")

local function assert_equal(actual, expected)
	assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function mysql()
	return assert(adapters.connector({ kind = "mysql" }))
end

local function result(statement, rows)
	return '<?xml version="1.0"?>\n<resultset statement="' .. statement .. '">\n' .. (rows or "") .. "</resultset>\n"
end

local function row(fields)
	return "<row>\n" .. fields .. "</row>\n"
end

local function framed(user_output, identity, diagnostics)
	return result("frame begin", row('<field name="__orbit_frame">marker:BEGIN</field>'))
		.. result("server identity", row('<field name="__orbit_server">' .. (identity or "8.4.11|MySQL Community Server") .. '</field>'))
		.. (user_output or "")
		.. result("SHOW WARNINGS", diagnostics or "")
end

return {
	["MySQL profiles validate transport, client family, TLS, and credentials"] = function()
		local connector = mysql()
		assert(connector.validate_options("local", { database = "orbit_dev", host = "127.0.0.1", port = 3306 }))
		assert(connector.validate_options("local", { database = "orbit_dev", socket = "/run/mysqld/mysqld.sock", client_family = "mariadb" }))

		local _, transport_err = connector.validate_options("local", { database = "orbit_dev", socket = "/tmp/mysql.sock", host = "localhost" })
		assert(transport_err:match("socket"))
		local _, password_err = connector.validate_options("local", { database = "orbit_dev", password = "secret" })
		assert(password_err:match("unsupported MySQL option"))
		local _, family_err = connector.validate_options("local", { database = "orbit_dev", client_family = "other" })
		assert(family_err:match("client_family"))
		local _, tls_err = connector.validate_options("local", { database = "orbit_dev", client_family = "mariadb", sslmode = "required" })
		assert(tls_err:match("does not support sslmode"))
	end,

	["MySQL connector builds retained Oracle and MariaDB client commands"] = function()
		local connector = mysql()
		assert_equal(connector.session_command({
			database = "orbit_dev",
			host = "db.example.test",
			port = 3307,
			user = "alice",
			arguments = { "--login-path=orbit" },
			sslmode = "verify_identity",
		}), {
			"mysql", "--login-path=orbit", "--host", "db.example.test", "--port", "3307", "--user", "alice",
			"--protocol=tcp", "--ssl-mode=VERIFY_IDENTITY", "--xml", "--unbuffered", "--skip-force", "--binary-mode",
			"--skip-reconnect", "--default-character-set=utf8mb4", "orbit_dev",
		})
		assert_equal(connector.session_command({
			database = "orbit_dev",
			client_family = "mariadb",
			socket = "/tmp/mysql.sock",
			sslmode = "disabled",
		}), {
			"mariadb", "--socket", "/tmp/mysql.sock", "--protocol=socket", "--skip-ssl", "--xml", "--unbuffered",
			"--skip-force", "--binary-mode", "--skip-reconnect", "--default-character-set=utf8mb4", "orbit_dev",
		})
	end,

	["MySQL retained requests are framed with server and diagnostic checks"] = function()
		local connector = mysql()
		local request = connector.session_request("SELECT 1", "orbit_marker")
		assert(request:match("__orbit_frame", 1, true))
		assert(request:match("@@version_comment", 1, true))
		assert(request:find("SELECT 1\n;", 1, true))
		assert(request:match("SHOW WARNINGS;", 1, true))
		assert(select(2, request:gsub("__orbit_frame", "")) == 2)
		local commented = connector.session_request("SELECT 1 # trailing comment", "comment_marker")
		assert(commented:find("# trailing comment\n;\nSHOW WARNINGS", 1, true))

		local output = result("SELECT marker", row('<field name="__orbit_frame">orbit_marker:BEGIN</field>'))
			.. result("SELECT 1", row('<field name="value">1</field>'))
			.. result("SELECT marker", row('<field name="__orbit_frame">orbit_marker:END</field>'))
		assert(connector.session_output(output, "orbit_marker") == result("SELECT marker", row('<field name="__orbit_frame">orbit_marker:BEGIN</field>')) .. result("SELECT 1", row('<field name="value">1</field>')))
	end,

	["MySQL XML parsing preserves text values and rejects unsafe responses"] = function()
		local connector = mysql()
		local output = result("SELECT values", row(table.concat({
			'<field name="missing" xsi:nil="true" />\n',
			'<field name="empty"></field>\n',
			'<field name="note">Ada &amp; Bob&#10;next&#9;tab</field>\n',
		}, "")))
		assert_equal(assert(connector.parse(output)), { { missing = vim.NIL, empty = "", note = "Ada & Bob\nnext\ttab" } })

		local multiple, multiple_err = connector.parse(result("SELECT 1", row('<field name="a">1</field>')) .. result("SELECT 2", row('<field name="b">2</field>')))
		assert(multiple == nil and multiple_err:match("multiple result sets"))

		local maria, maria_err = connector.parse(framed(nil, "11.8.2|MariaDB Server"))
		assert(maria == nil and maria_err:match("MariaDB servers are not supported"))
		local old, old_err = connector.parse(framed(nil, "5.7.44|MySQL Community Server"))
		assert(old == nil and old_err:match("requires a MySQL 8.x server"))
		assert_equal(assert(connector.parse(result("SELECT 'user value' AS __orbit_server", row('<field name="__orbit_server">user value</field>')))), { { __orbit_server = "user value" } })
		assert_equal(assert(connector.parse(result("SHOW WARNINGS", row('<field name="Level">Warning</field>')))), { { Level = "Warning" } })

		local failure, failure_err = connector.parse(framed(nil, nil, row('<field name="Level">Error</field>\n<field name="Code">1146</field>\n<field name="Message">missing table</field>')))
		assert(failure == nil and failure_err == "MySQL error 1146: missing table")
	end,

	["MySQL connector exposes names, schema metadata, actions, and editable mutations"] = function()
		local connector = mysql()
		local options = { database = "orbit_dev", schema_patterns = { "report*" } }
		assert(connector.qualified_name(options, { schema = "sales`west", name = "order`item" }) == "`sales``west`.`order``item`")
		assert(connector.completion_word(options, { schema = "orbit_dev", name = "users" }) == "`orbit_dev`.`users`")

		local tables = assert(connector.schema_statement(options, { type = "tables" }))
		assert(tables:find("table_schema = DATABASE()", 1, true))
		assert(tables:find("table_schema LIKE CONVERT(X'7265706F727425' USING utf8mb4)", 1, true))
		assert(connector.schema_statement(options, { type = "primary_keys", schema = "orbit_dev", name = "users" }):match("statistics"))
		assert(connector.schema_statement(options, { type = "foreign_keys", schema = "orbit_dev", name = "posts" }):match("referenced_table_name"))
		assert(connector.schema_statement(options, { type = "indexes", schema = "orbit_dev", name = "users" }):match("index_name"))
		assert(#connector.metadata_categories(options, { type = "table" }) == 4)
		assert(#connector.object_actions(options, { type = "view", schema = "orbit_dev", name = "active_users" }, 50) == 3)

		local target = assert(connector.editable_table(options, { type = "table", schema = "orbit_dev", name = "users" }, { "id" }))
		local statement = assert(connector.mutation_statement(options, target, { deleted = {}, modified = {}, inserted = { { values = {} } } }))
		assert(statement == "START TRANSACTION;\nINSERT INTO `orbit_dev`.`users` () VALUES ();\nCOMMIT;")
		local escaped = assert(connector.mutation_statement(options, target, { deleted = {}, modified = {}, inserted = { { values = { name = [[a\'b]] } } } }))
		assert(escaped:find("CONVERT(X'615C2762' USING utf8mb4)", 1, true))
		assert(connector.session_error("WARNING: advisory") == nil)
		assert(connector.session_error("ERROR 1045: denied") == "ERROR 1045: denied")
	end,
}
