local cache = require("orbit.redis_cache")
local runner = require("orbit.runner")

return {
	["Redis command metadata identifies names key arguments and readonly commands"] = function()
		local profile = { name = "commands", kind = "redis", options = { host = "localhost" } }
		local original_run = runner.run
		runner.run = function(_, statement, callback)
			assert(statement == "COMMAND")
			callback({}, nil, { redis_reply = {
				{ "get", -2, { "readonly", "fast" }, 1, 1, 1 },
				{ "set", -3, { "write" }, 1, 1, 1 },
				{ "mget", -2, { "readonly" }, 1, -1, 1 },
				{ "ping", -1, { "fast" }, 0, 0, 0 },
				{ "blpop", -3, { "write" }, 1, -2, 1 },
			} })
			return { kill = function() end }
		end
		local loaded
		local ok, err = xpcall(function()
			cache.load_commands(profile, {}, function(commands, load_err)
				assert(load_err == nil)
				loaded = commands
			end)
			assert(loaded.get.readonly == true and loaded.set.readonly == false)
			assert(cache.is_key_argument(profile, "GET", 1, 1))
			assert(cache.is_key_argument(profile, "MGET", 3, 3))
			assert(cache.is_key_argument(profile, "MGET", 2, 1))
			assert(not cache.is_key_argument(profile, "PING", 1, 1))
			assert(cache.is_key_argument(profile, "BLPOP", 1, 2))
			assert(not cache.is_key_argument(profile, "BLPOP", 2, 2))
			assert(cache.command(profile, "get").readonly == true)
			assert(vim.tbl_contains(cache.command_names(profile), "GET"))
			assert(not vim.tbl_contains(cache.command_names(profile), "TTL"))
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,

	["Redis metadata cancellation terminates processes and completes waiters"] = function()
		local profile = { name = "cancel-metadata", kind = "redis", options = { host = "localhost" } }
		local original_run = runner.run
		local killed = 0
		runner.run = function()
			return { kill = function() killed = killed + 1 end }
		end
		local key_err, command_err
		local ok, err = xpcall(function()
			cache.load_keys(profile, {}, function(_, value) key_err = value end)
			cache.load_commands(profile, {}, function(_, value) command_err = value end)
			cache.cancel(profile.name)
			assert(killed == 2)
			assert(vim.wait(100, function() return key_err ~= nil and command_err ~= nil end))
			assert(key_err:match("cancelled") and command_err:match("cancelled"))
			assert(cache.status(profile).loaded == false)
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,

	["Redis command acquisition rejects malformed command arity"] = function()
		local profile = { name = "bad-command-arity", kind = "redis", options = { host = "localhost" } }
		local original_run = runner.run
		runner.run = function(_, _, callback)
			callback({}, nil, { redis_reply = { { "get", "invalid", { "readonly" }, 1, 1, 1 } } })
			return { kill = function() end }
		end
		local received_err
		local ok, err = xpcall(function()
			cache.load_commands(profile, {}, function(_, value) received_err = value end)
			assert(received_err and received_err:match("invalid COMMAND entry"), tostring(received_err))
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,

	["Redis command acquisition rejects malformed key positions"] = function()
		local profile = { name = "bad-command-keys", kind = "redis", options = { host = "localhost" } }
		local original_run = runner.run
		runner.run = function(_, _, callback)
			callback({}, nil, { redis_reply = { { "get", 2, { "readonly" }, 1.5, 1, 1 } } })
			return { kill = function() end }
		end
		local received_err
		local ok, err = xpcall(function()
			cache.load_commands(profile, {}, function(_, value) received_err = value end)
			assert(received_err and received_err:match("key positions"), tostring(received_err))
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,

	["Redis key acquisition scans to cursor zero and deduplicates keys"] = function()
		local profile = { name = "scan", kind = "redis", options = {
			host = "localhost", key_pattern = "capture:*", key_limit = 3, scan_count = 2,
		} }
		local original_run = runner.run
		local requests = {}
		runner.run = function(received, statement, callback)
			assert(received == profile)
			requests[#requests + 1] = { statement = statement, callback = callback }
			return { kill = function() end }
		end
		local received
		local ok, err = xpcall(function()
			cache.load_keys(profile, {}, function(keys, load_err, status)
				received = { keys = keys, err = load_err, status = status }
			end)
			assert(requests[1].statement == "SCAN 0 MATCH capture:* COUNT 2")
			requests[1].callback({}, nil, { redis_reply = { "7", { "capture:one", "capture:two" } } })
			assert(requests[2].statement == "SCAN 7 MATCH capture:* COUNT 2")
			requests[2].callback({}, nil, { redis_reply = { "0", { "capture:two", "capture:three" } } })
			assert(vim.deep_equal(received.keys, { "capture:one", "capture:three", "capture:two" }))
			assert(received.err == nil and received.status.truncated == false)
			assert(vim.deep_equal(cache.keys(profile), received.keys))
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,

	["Redis key acquisition stops at the configured cap and reports truncation"] = function()
		local profile = { name = "limited", kind = "redis", options = { host = "localhost", key_limit = 2 } }
		local original_run = runner.run
		runner.run = function(_, _, callback)
			callback({}, nil, { redis_reply = { "0", { "one", "two", "three" } } })
			return { kill = function() end }
		end
		local received
		local ok, err = xpcall(function()
			cache.load_keys(profile, {}, function(keys, load_err, status)
				received = { keys = keys, err = load_err, status = status }
			end)
			assert(vim.deep_equal(received.keys, { "one", "two" }))
			assert(received.err == nil and received.status.truncated == true)
		end, debug.traceback)
		runner.run = original_run
		assert(ok, err)
	end,
}
