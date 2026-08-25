local adapters = require("orbit.adapters")
local session = require("orbit.session")

local M = {}

local function run_once(profile, statement, callback)
  local command, command_err = adapters.prepare(profile, statement)
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

      local rows, parse_err = adapters.parse_profile(profile, result.stdout)
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

function M.run(profile, statement, callback)
  if not adapters.supports_session(profile) then
    return run_once(profile, statement, callback)
  end
  return session.run(profile, statement, function(output, run_err)
    if run_err then
      callback(nil, run_err)
      return
    end
    local rows, parse_err = adapters.parse_profile(profile, output)
    callback(rows, parse_err)
  end)
end

function M.cancel(process)
  if not process then
    return
  end
  if process.kill then
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
