local cache = require("orbit.redis_cache")

-- Every test passes a fake executor through `options.execute`, so no real
-- redis-cli process is spawned. A fake returns a process-like handle because
-- redis_cache stores it and hands it to runner.cancel on abandon.
return {
	["Redis command metadata identifies names key arguments and readonly commands"] = function()
		local profile = { name = "commands", kind = "redis", options = { host = "localhost" } }
		-- Fake executor: answer COMMAND with a small, well-formed reply.
		local function execute(_, statement, callback)
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
		cache.load_commands(profile, { execute = execute }, function(commands, load_err)
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
	end,

	["Redis metadata cancellation terminates processes and completes waiters"] = function()
		local profile = { name = "cancel-metadata", kind = "redis", options = { host = "localhost" } }
		local killed = 0
		-- Fake executor: never answers; its handle counts kill() calls so the
		-- test can prove cancel() terminated both in-flight processes.
		local function execute()
			return { kill = function() killed = killed + 1 end }
		end
		local key_err, command_err
		cache.load_keys(profile, { execute = execute }, function(_, value) key_err = value end)
		cache.load_commands(profile, { execute = execute }, function(_, value) command_err = value end)
		cache.cancel(profile.name)
		assert(killed == 2)
		assert(vim.wait(100, function() return key_err ~= nil and command_err ~= nil end))
		assert(key_err:match("cancelled") and command_err:match("cancelled"))
		assert(cache.status(profile).loaded == false)
	end,

	["Redis command acquisition rejects malformed command arity"] = function()
		local profile = { name = "bad-command-arity", kind = "redis", options = { host = "localhost" } }
		-- Fake executor: reply with a non-numeric arity.
		local function execute(_, _, callback)
			callback({}, nil, { redis_reply = { { "get", "invalid", { "readonly" }, 1, 1, 1 } } })
			return { kill = function() end }
		end
		local received_err
		cache.load_commands(profile, { execute = execute }, function(_, value) received_err = value end)
		assert(received_err and received_err:match("invalid COMMAND entry"), tostring(received_err))
	end,

	["Redis command acquisition rejects malformed key positions"] = function()
		local profile = { name = "bad-command-keys", kind = "redis", options = { host = "localhost" } }
		-- Fake executor: reply with a fractional first-key position.
		local function execute(_, _, callback)
			callback({}, nil, { redis_reply = { { "get", 2, { "readonly" }, 1.5, 1, 1 } } })
			return { kill = function() end }
		end
		local received_err
		cache.load_commands(profile, { execute = execute }, function(_, value) received_err = value end)
		assert(received_err and received_err:match("key positions"), tostring(received_err))
	end,

	["Redis key acquisition scans to cursor zero and deduplicates keys"] = function()
		local profile = { name = "scan", kind = "redis", options = {
			host = "localhost", key_pattern = "capture:*", key_limit = 3, scan_count = 2,
		} }
		local requests = {}
		-- Fake executor: record each SCAN so the test can answer them one by
		-- one and check the cursor advances.
		local function execute(received, statement, callback)
			assert(received == profile)
			requests[#requests + 1] = { statement = statement, callback = callback }
			return { kill = function() end }
		end
		local received
		cache.load_keys(profile, { execute = execute }, function(keys, load_err, status)
			received = { keys = keys, err = load_err, status = status }
		end)
		assert(requests[1].statement == "SCAN 0 MATCH capture:* COUNT 2")
		requests[1].callback({}, nil, { redis_reply = { "7", { "capture:one", "capture:two" } } })
		assert(requests[2].statement == "SCAN 7 MATCH capture:* COUNT 2")
		requests[2].callback({}, nil, { redis_reply = { "0", { "capture:two", "capture:three" } } })
		assert(vim.deep_equal(received.keys, { "capture:one", "capture:three", "capture:two" }))
		assert(received.err == nil and received.status.truncated == false)
		assert(vim.deep_equal(cache.keys(profile), received.keys))
	end,

	["Redis key acquisition stops at the configured cap and reports truncation"] = function()
		local profile = { name = "limited", kind = "redis", options = { host = "localhost", key_limit = 2 } }
		-- Fake executor: a single final SCAN page with more keys than the cap.
		local function execute(_, _, callback)
			callback({}, nil, { redis_reply = { "0", { "one", "two", "three" } } })
			return { kill = function() end }
		end
		local received
		cache.load_keys(profile, { execute = execute }, function(keys, load_err, status)
			received = { keys = keys, err = load_err, status = status }
		end)
		assert(vim.deep_equal(received.keys, { "one", "two" }))
		assert(received.err == nil and received.status.truncated == true)
	end,
}
