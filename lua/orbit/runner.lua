local adapters = require("orbit.adapters")

local M = {}

function M.run(profile, statement, callback)
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

      local rows, parse_err = adapters.parse(result.stdout)
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

function M.cancel(process)
  if process then
    process:kill(15)
  end
end

return M
