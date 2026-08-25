local adapters = require("orbit.adapters")
local session = require("orbit.session")

local M = {}

local function parse(connector, output)
	return connector.parse and connector.parse(output) or adapters.parse(output)
end

local function run_once(profile, connector, statement, callback)
  -- Always deliver completion on Neovim's loop, including command construction and spawn failures.
	if type(profile) ~= "table" or type(profile.options) ~= "table" then
		vim.schedule(function()
			callback(nil, "profile options are required")
		end)
		return nil
	end
	if type(statement) ~= "string" or statement == "" then
		vim.schedule(function()
			callback(nil, "statement is required")
		end)
		return nil
	end

	local command, command_err = connector.prepare(profile.options, statement)
  if not command then
    vim.schedule(function()
      callback(nil, command_err)
    end)
    return nil
  end

  local ok, process = pcall(vim.system, command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, string.format("command failed (%d): %s", result.code, vim.trim(result.stderr)))
        return
      end

			local rows, parse_err = parse(connector, result.stdout)
      if not rows then
        callback(nil, parse_err)
        return
      end
      callback(rows)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback(nil, "cannot start CLI: " .. process)
    end)
    return nil
  end

  return process
end

function M.run(profile, statement, callback, connector)
	if not connector then
		local err
		connector, err = adapters.connector(profile)
		if not connector then
			vim.schedule(function()
				callback(nil, err)
			end)
			return nil
		end
	end
  -- Trino uses one-shot processes; supported connectors retain a serialized CLI session.
	if not connector.session_command then
		return run_once(profile, connector, statement, callback)
  end
	return session.run(profile, connector, statement, function(output, run_err)
    if run_err then
      callback(nil, run_err)
      return
    end
		local rows, parse_err = parse(connector, output)
    callback(rows, parse_err)
  end)
end

function M.cancel(process)
  if not process then
    return
  end
  if process.kill then
    -- One-shot vim.system handles expose kill; session requests are opaque queue entries.
    process:kill(15)
  else
    session.cancel(process)
  end
end

function M.close(profile_name)
  session.close(profile_name)
end

function M.connected(profile_name)
  return session.connected(profile_name)
end

return M
