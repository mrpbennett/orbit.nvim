local redis = require("orbit.connectors.redis")

return {
	["Redis profiles validate structured endpoint completion and TLS options"] = function()
		local profiles = require("orbit.profiles")
		local path = vim.fn.tempname()
		assert(profiles.write(path, { version = 1, profiles = { {
			name = "cache",
			kind = "redis",
			options = {
				host = "localhost",
				database = 0,
				password_env = "REDIS_PASSWORD",
				key_pattern = "capture:*",
				key_limit = 10000,
				scan_count = 1000,
			},
		} } }))
		assert(profiles.load(path))

		for field, value in pairs({ port = 0, database = -1, key_limit = 0, scan_count = 1.5, arguments = {} }) do
			local options = { host = "localhost", [field] = value }
			local valid, err = redis.validate_options("bad", options)
			assert(valid == nil and err, field)
		end
		local valid, err = redis.validate_options("bad-tls", { host = "localhost", cert = "/cert.pem" })
		assert(valid == nil and err:match("options.tls"), tostring(err))
		valid, err = redis.validate_options("bad-user", { host = "localhost", user = "orbit" })
		assert(valid == nil and err:match("password_env"), tostring(err))
	end,

	["Redis Connector builds a secret-safe one-shot redis-cli command"] = function()
		local original = vim.fn.environ
		vim.fn.environ = function()
			return { PATH = "/bin", REDIS_PASSWORD = "secret", REDISCLI_AUTH = "stale", KEEP = "value" }
		end
		local ok, command, process_options = pcall(function()
			local argv, err, system_options = redis.prepare({
				host = "cache.example.test",
				port = 6380,
				database = 2,
				user = "orbit",
				password_env = "REDIS_PASSWORD",
				tls = true,
				cacert = "/certs/redis-ca.pem",
			}, [[GET "capture:one"]])
			assert(argv, err)
			return argv, system_options
		end)
		vim.fn.environ = original
		assert(ok, command)
		assert(vim.deep_equal(command, {
			"redis-cli", "-h", "cache.example.test", "-p", "6380", "--user", "orbit",
			"--tls", "--cacert", "/certs/redis-ca.pem", "-n", "2", "--json", "--show-pushes", "no", "-e",
			"GET", "capture:one",
		}))
		assert(process_options.clear_env == true)
		assert(vim.deep_equal(process_options.env, { PATH = "/bin", KEEP = "value", REDISCLI_AUTH = "secret" }))
		local direct = assert(redis.sanitize_environment({ password_env = "REDISCLI_AUTH" }, {
			PATH = "/bin", REDISCLI_AUTH = "secret",
		}))
		assert(vim.deep_equal(direct, { PATH = "/bin" }))
		assert(vim.deep_equal(assert(redis.arguments([[GET path\key]])), { "GET", [[path\key]] }))
		assert(vim.deep_equal(assert(redis.arguments([[SET 'path\\key' value]])), { "SET", [[path\\key]], "value" }))
		assert(vim.deep_equal(assert(redis.arguments([[SET 'it\'s' value]])), { "SET", "it's", "value" }))
		assert(vim.deep_equal(assert(redis.arguments([[SET "bad\xzz" value]])), { "SET", "badxzz", "value" }))
		assert(redis.quote_argument("user's") == [["user's"]])
	end,

	["Redis Connector preserves decoded replies and emits pretty JSON documents"] = function()
		local keys, key_err, metadata = redis.parse('[["ignored"],"capture:one"]')
		assert(key_err == nil)
		assert(vim.deep_equal(keys, { { value = '["ignored"]' }, { value = "capture:one" } }))
		assert(vim.deep_equal(metadata.columns, { "value" }))
		assert(vim.deep_equal(metadata.redis_reply, { { "ignored" }, "capture:one" }))
		assert(vim.deep_equal(metadata.document, {
			syntax = "json",
			lines = {
				"[",
				'  [',
				'    "ignored"',
				'  ],',
				'  "capture:one"',
				"]",
			},
		}))

		local scalar, scalar_err, scalar_metadata = redis.parse('"hello"')
		assert(scalar_err == nil and scalar[1].value == "hello")
		assert(vim.deep_equal(scalar_metadata.document.lines, { '"hello"' }))
		local encoded_rows, encoded_err, encoded_metadata = redis.parse(
			'"{\\"name\\":\\"Ada\\",\\"roles\\":[\\"admin\\"]}"'
		)
		assert(encoded_err == nil)
		assert(encoded_rows[1].value == '{"name":"Ada","roles":["admin"]}')
		assert(encoded_metadata.redis_reply == '{"name":"Ada","roles":["admin"]}')
		assert(vim.deep_equal(encoded_metadata.document.lines, {
			"{",
			'  "name": "Ada",',
			'  "roles": [',
			'    "admin"',
			"  ]",
			"}",
		}))
		local encoded_array = select(3, redis.parse('"[{\\"id\\":1}]"'))
		assert(vim.deep_equal(encoded_array.document.lines, {
			"[",
			"  {",
			'    "id": 1',
			"  }",
			"]",
		}))
		local encoded_scalar = select(3, redis.parse('"true"'))
		assert(vim.deep_equal(encoded_scalar.document.lines, { '"true"' }))
		local malformed_inner = select(3, redis.parse('"{"'))
		assert(malformed_inner.redis_reply == "{")
		assert(vim.deep_equal(malformed_inner.document.lines, { '"{"' }))
		local null_rows, null_err, null_metadata = redis.parse("null")
		assert(null_err == nil and null_rows[1].value == vim.NIL)
		assert(vim.deep_equal(null_metadata.document.lines, { "null" }))
		local map, map_err, map_metadata = redis.parse('{"second":2,"first":1}')
		assert(map_err == nil)
		assert(vim.deep_equal(map, { { key = "first", value = 1 }, { key = "second", value = 2 } }))
		assert(vim.deep_equal(map_metadata.columns, { "key", "value" }))
		assert(vim.deep_equal(map_metadata.document.lines, {
			"{",
			'  "second": 2,',
			'  "first": 1',
			"}",
		}))

		local escaped = select(3, redis.parse('{"message":"a { brace } and \\"quote\\""}'))
		assert(vim.deep_equal(escaped.document.lines, {
			"{",
			'  "message": "a { brace } and \\"quote\\""',
			"}",
		}))
		local _, empty_err, empty_metadata = redis.parse('{"array":[],"object":{},"enabled":true}')
		assert(empty_err == nil)
		assert(vim.deep_equal(empty_metadata.document.lines, {
			"{",
			'  "array": [],',
			'  "object": {},',
			'  "enabled": true',
			"}",
		}))
	end,

	["Redis completion offers commands and indexed keys only in key positions"] = function()
		local completion = require("orbit.completion")
		local cache = require("orbit.redis_cache")
		local runner = require("orbit.runner")
		local profile = { name = "redis-completion", kind = "redis", options = { host = "localhost", database = 0 } }
		local original_run = runner.run
		runner.run = function(_, statement, callback)
			if statement == "COMMAND" then
				callback({}, nil, { redis_reply = {
					{ "get", -2, { "readonly" }, 1, 1, 1 },
					{ "blpop", -3, { "write" }, 1, -2, 1 },
					{ "ping", -1, { "readonly" }, 0, 0, 0 },
				} })
			else
				callback({}, nil, { redis_reply = { "0", { "capture:one", "capture two", "other", "user's" } } })
			end
			return { kill = function() end }
		end
		local function words(items)
			local result = {}
			for _, item in ipairs(items) do result[#result + 1] = item.word end
			return result
		end
		local ok, err = xpcall(function()
			cache.load_commands(profile)
			cache.load_keys(profile)
			assert(vim.deep_equal(words(completion.items(profile, { "GE" }, 1, 2)), { "GET" }))
			assert(vim.deep_equal(words(completion.items(profile, { "GET cap" }, 1, 7)), {
				'"capture two"', "capture:one",
			}))
			assert(vim.deep_equal(words(completion.items(profile, { "PING cap" }, 1, 8)), {}))
			assert(vim.deep_equal(words(completion.items(profile, { "GET user" }, 1, 8)), { '"user\'s"' }))
			local blocking = "BLPOP cap 0"
			assert(#completion.items(profile, { blocking }, 1, #"BLPOP cap") == 2)
			assert(vim.deep_equal(completion.items(profile, { blocking }, 1, #blocking), {}))
			local item = completion.items(profile, { "GET cap" }, 1, 7)[1]
			assert(item.replace_start_row == 1 and item.replace_start_col == 4)
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,

	["Redis mutation confirmation follows cached readonly command metadata"] = function()
		local cache = require("orbit.redis_cache")
		local runner = require("orbit.runner")
		local profile = { name = "redis-mutations", kind = "redis", options = { host = "localhost" } }
		local original_run = runner.run
		runner.run = function(_, _, callback)
			callback({}, nil, { redis_reply = {
				{ "get", -2, { "readonly" }, 1, 1, 1 },
				{ "set", -3, { "write" }, 1, 1, 1 },
			} })
			return { kill = function() end }
		end
		local ok, err = xpcall(function()
			cache.load_commands(profile)
			assert(not redis.requires_confirmation("GET key", profile))
			assert(redis.requires_confirmation("SET key value", profile))
			assert(redis.requires_confirmation("CUSTOM key", profile))
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,
}
