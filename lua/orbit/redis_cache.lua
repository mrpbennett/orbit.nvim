-- Profile-scoped Redis metadata used by completion. Reads are synchronous and
-- never perform I/O; loading walks SCAN asynchronously and publishes one
-- bounded snapshot only after the walk succeeds.
local runner = require("orbit.runner")
local redis = require("orbit.connectors.redis")

local M = {}
local profiles = {}
local snapshot

local function abandon(state, err)
	runner.cancel(state.key_process)
	runner.cancel(state.command_process)
	state.loading = false
	state.command_loading = false
	state.error = err
	local key_callbacks = vim.list_extend(state.callbacks, state.refresh_callbacks)
	local command_callbacks = vim.list_extend(state.command_callbacks, state.command_refresh_callbacks)
	state.callbacks, state.refresh_callbacks = {}, {}
	state.command_callbacks, state.command_refresh_callbacks = {}, {}
	vim.schedule(function()
		for _, callback in ipairs(key_callbacks) do callback(nil, err, snapshot(state)) end
		for _, callback in ipairs(command_callbacks) do callback(nil, err) end
	end)
end

local function entry(profile)
	local signature = vim.json.encode({ kind = profile.kind, options = profile.options })
	local current = profiles[profile.name]
	if not current or current.signature ~= signature then
		local replacement = {
			command_callbacks = {},
			command_loading = false,
			command_refresh_callbacks = {},
			command_refreshing = false,
			callbacks = {},
			commands = nil,
			keys = nil,
			loading = false,
			refresh_callbacks = {},
			refreshing = false,
			signature = signature,
			truncated = false,
		}
		profiles[profile.name] = replacement
		if current then
			abandon(current, "Redis connection profile changed during metadata acquisition")
		end
		current = replacement
	end
	return current
end

local fallback_commands = {
	"DEL", "EXISTS", "EXPIRE", "GET", "HGET", "HGETALL", "HSET", "KEYS", "LLEN", "LPUSH", "LRANGE",
	"MGET", "MSET", "PERSIST", "PING", "PTTL", "RENAME", "RPUSH", "SADD", "SCAN", "SET", "SMEMBERS",
	"TTL", "TYPE", "UNLINK", "ZADD", "ZRANGE",
}

function M.command(profile, name)
	return entry(profile).commands and entry(profile).commands[name:lower()] or nil
end

function M.command_names(profile)
	local names = {}
	local commands = entry(profile).commands
	if commands then
		for name in pairs(commands) do names[name:upper()] = true end
	else
		for _, name in ipairs(fallback_commands) do names[name] = true end
	end
	local result = vim.tbl_keys(names)
	table.sort(result)
	return result
end

function M.is_key_argument(profile, command_name, argument_position, total_arguments)
	local command = M.command(profile, command_name)
	if not command or command.first_key == 0 or argument_position < command.first_key then
		return false
	end
	if command.last_key < 0 then
		if command.last_key == -1 then
			return (argument_position - command.first_key) % command.key_step == 0
		end
		local complete_arguments = math.max(total_arguments, command.minimum_arguments)
		local last = complete_arguments + command.last_key + 1
		return argument_position <= last and (argument_position - command.first_key) % command.key_step == 0
	end
	local last = command.last_key
	return argument_position <= last and (argument_position - command.first_key) % command.key_step == 0
end

-- Load server command metadata asynchronously. Concurrent ordinary reads
-- coalesce; a refresh arriving during an ordinary load runs immediately after.
function M.load_commands(profile, options, callback)
	options = options or {}
	callback = callback or function() end
	local state = entry(profile)
	if state.command_loading then
		if options.refresh and not state.command_refreshing then
			state.command_refresh_callbacks[#state.command_refresh_callbacks + 1] = callback
		else
			state.command_callbacks[#state.command_callbacks + 1] = callback
		end
		return
	end
	if state.commands and not options.refresh then
		vim.schedule(function() callback(state.commands) end)
		return
	end
	state.command_loading = true
	state.command_refreshing = options.refresh == true
	state.command_callbacks = { callback }
	state.command_process = runner.run(profile, "COMMAND", function(_, err, metadata)
		if profiles[profile.name] ~= state then
			return
		end
		local commands
		if not err then
			local reply = metadata and metadata.redis_reply
			if type(reply) ~= "table" or not vim.islist(reply) then
				err = "redis-cli returned an invalid COMMAND reply"
			else
				commands = {}
				for _, row in ipairs(reply) do
					if type(row) ~= "table" or type(row[1]) ~= "string" or type(row[2]) ~= "number"
						or type(row[3]) ~= "table"
						or type(row[4]) ~= "number" or type(row[5]) ~= "number" or type(row[6]) ~= "number"
					then
						err = "redis-cli returned an invalid COMMAND entry"
						break
					end
					local arity, first_key, last_key, key_step = row[2], row[4], row[5], row[6]
					local integer_fields = arity % 1 == 0 and first_key % 1 == 0 and last_key % 1 == 0 and key_step % 1 == 0
					local no_keys = first_key == 0 and last_key == 0 and key_step == 0
					local has_keys = first_key > 0 and key_step > 0 and last_key ~= 0
					if not integer_fields or arity == 0 or not (no_keys or has_keys) or (last_key > 0 and last_key < first_key) then
						err = "redis-cli returned invalid COMMAND key positions"
						break
					end
					local flags = {}
					for _, flag in ipairs(row[3]) do
						flags[flag] = true
					end
					commands[row[1]:lower()] = {
						first_key = first_key,
						key_step = key_step > 0 and key_step or 1,
						last_key = last_key,
						minimum_arguments = math.max(0, math.abs(arity) - 1),
						readonly = flags.readonly == true,
					}
				end
			end
		end
		state.command_loading = false
		state.command_refreshing = false
		state.command_process = nil
		if not err then
			state.commands = commands
		end
		local callbacks = state.command_callbacks
		state.command_callbacks = {}
		for _, waiting in ipairs(callbacks) do
			waiting(err and nil or state.commands, err)
		end
		local refresh_callbacks = state.command_refresh_callbacks
		state.command_refresh_callbacks = {}
		if #refresh_callbacks > 0 then
			M.load_commands(profile, { refresh = true }, function(refreshed, refresh_err)
				for _, waiting in ipairs(refresh_callbacks) do
					waiting(refreshed, refresh_err)
				end
			end)
		end
	end)
end

snapshot = function(state)
	return {
		count = #(state.keys or {}),
		error = state.error,
		loaded = state.keys ~= nil,
		loading = state.loading,
		truncated = state.truncated,
	}
end

function M.keys(profile)
	return entry(profile).keys or {}
end

-- Report the last published key index without starting network work.
function M.status(profile)
	return snapshot(entry(profile))
end

local function deliver(state, keys, err)
	local callbacks = state.callbacks
	state.callbacks = {}
	for _, callback in ipairs(callbacks) do
		callback(keys, err, snapshot(state))
	end
end

-- Build a bounded key index with cursor-based SCAN. Successful snapshots are
-- replaced atomically; failed refreshes leave the previous keys available.
function M.load_keys(profile, options, callback)
	options = options or {}
	callback = callback or function() end
	local state = entry(profile)
	if state.loading then
		if options.refresh and not state.refreshing then
			state.refresh_callbacks[#state.refresh_callbacks + 1] = callback
		else
			state.callbacks[#state.callbacks + 1] = callback
		end
		return
	end
	if state.keys and not options.refresh then
		vim.schedule(function()
			callback(state.keys, nil, snapshot(state))
		end)
		return
	end

	state.loading = true
	state.refreshing = options.refresh == true
	state.error = nil
	state.callbacks = { callback }
	local keys, seen = {}, {}
	local overflow = false
	local limit = profile.options.key_limit or 10000
	local pattern = profile.options.key_pattern or "*"
	local count = profile.options.scan_count or 1000

	local function finish(err, truncated)
		if profiles[profile.name] ~= state then
			return
		end
		state.loading = false
		state.refreshing = false
		state.key_process = nil
		state.error = err
		if not err then
			table.sort(keys)
			state.keys = keys
			state.truncated = truncated == true
		end
		deliver(state, err and nil or state.keys, err)
		local refresh_callbacks = state.refresh_callbacks
		state.refresh_callbacks = {}
		if #refresh_callbacks > 0 then
			M.load_keys(profile, { refresh = true }, function(refreshed, refresh_err, refresh_status)
				for _, waiting in ipairs(refresh_callbacks) do
					waiting(refreshed, refresh_err, refresh_status)
				end
			end)
		end
	end

	local scan
	scan = function(cursor)
		local statement = table.concat({
			"SCAN", tostring(cursor), "MATCH", redis.quote_argument(pattern), "COUNT", tostring(count),
		}, " ")
		state.key_process = runner.run(profile, statement, function(_, err, metadata)
			if profiles[profile.name] ~= state then
				return
			end
			if err then
				finish(err)
				return
			end
			local reply = metadata and metadata.redis_reply
			local next_cursor = type(reply) == "table" and reply[1] or nil
			local batch = type(reply) == "table" and reply[2] or nil
			if (type(next_cursor) ~= "string" and type(next_cursor) ~= "number") or type(batch) ~= "table" or not vim.islist(batch) then
				finish("redis-cli returned an invalid SCAN reply")
				return
			end
			for _, key in ipairs(batch) do
				if type(key) ~= "string" then
					finish("redis-cli returned a non-string Redis key")
					return
				end
				if not seen[key] then
					seen[key] = true
					if #keys < limit then
						keys[#keys + 1] = key
					else
						overflow = true
					end
				end
			end
			next_cursor = tostring(next_cursor)
			if #keys >= limit and next_cursor ~= "0" then
				finish(nil, true)
			elseif next_cursor == "0" then
				finish(nil, overflow)
			else
				scan(next_cursor)
			end
		end)
	end

	scan("0")
end

-- Cancel metadata work and invalidate one profile's cached Redis metadata.
-- Waiting callers complete with an error instead of remaining indefinitely.
function M.cancel(profile_name)
	local state = profiles[profile_name]
	if not state then return end
	profiles[profile_name] = nil
	abandon(state, "Redis metadata acquisition cancelled")
end

-- Neovim shutdown must not leave one-shot metadata children running.
function M.close_all()
	local names = vim.tbl_keys(profiles)
	for _, name in ipairs(names) do M.cancel(name) end
end

return M
