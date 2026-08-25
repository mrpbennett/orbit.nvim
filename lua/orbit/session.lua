local adapters = require("orbit.adapters")

local M = {}
local sessions = {}

local function finish(request, output, err)
  if request.done then
    return
  end
  request.done = true
  vim.schedule(function()
    request.callback(output, err)
  end)
end

local function fail(session, err)
  local active = session.active
  session.active = nil
  session.process = nil
  if active then
    finish(active, nil, err)
  end
  for _, request in ipairs(session.queue) do
    finish(request, nil, err)
  end
  session.queue = {}
end

local function start_next(session)
  if session.active or #session.queue == 0 then
    return
  end
  if not session.process then
    local command, command_err = adapters.session_command(session.profile)
    if not command then
      fail(session, command_err)
      return
    end
    local environment = adapters.environment(session.profile)
    local options = {
      stdin = true,
      stdout = function(err, data)
        if err or not data or not session.active then
          return
        end
        session.active.output = session.active.output .. data
        local output = adapters.session_output(session.profile, session.active.output, session.active.marker)
        if output then
          local request = session.active
          session.active = nil
          finish(request, output, request.stderr ~= "" and vim.trim(request.stderr) or nil)
          start_next(session)
        end
      end,
      stderr = function(_, data)
        if data and session.active then
          session.active.stderr = session.active.stderr .. data
        end
      end,
      text = true,
    }
    if next(environment) then
      options.env = vim.tbl_extend("force", vim.fn.environ(), environment)
    end
    local ok, process = pcall(vim.system, command, options, function(result)
      if sessions[session.profile.name] == session then
        fail(session, result.code == 0 and "connection closed" or string.format("connection closed (%d): %s", result.code, vim.trim(result.stderr)))
      end
    end)
    if not ok then
      fail(session, "cannot start CLI: " .. process)
      return
    end
    session.process = process
  end

  local request = table.remove(session.queue, 1)
  session.active = request
  local input, input_err = adapters.session_request(session.profile, request.statement, request.marker)
  if not input then
    session.active = nil
    finish(request, nil, input_err)
    start_next(session)
    return
  end
  session.process:write(input)
end

local function session_for(profile)
  local signature = vim.json.encode({ kind = profile.kind, options = profile.options })
  local session = sessions[profile.name]
  if session and session.signature ~= signature then
    M.close(profile.name)
    session = nil
  end
  if not session then
    session = {
      profile = profile,
      queue = {},
      signature = signature,
      sequence = 0,
    }
    sessions[profile.name] = session
  end
  return session
end

function M.run(profile, statement, callback)
  local session = session_for(profile)
  session.sequence = session.sequence + 1
  local request = {
    callback = callback,
    marker = string.format("__orbit_%s_%d_%d", profile.name:gsub("[^%w]", "_"), vim.uv.hrtime(), session.sequence),
    output = "",
    stderr = "",
    statement = statement,
  }
  table.insert(session.queue, request)
  start_next(session)
  return request
end

function M.cancel(request)
  if not request or request.done then
    return
  end
  for _, session in pairs(sessions) do
    if session.active == request then
      if session.process then
        session.process:kill(15)
      end
      return
    end
    for index, queued in ipairs(session.queue) do
      if queued == request then
        table.remove(session.queue, index)
        finish(request, nil, "query cancelled")
        return
      end
    end
  end
end

function M.close(profile_name)
  local session = sessions[profile_name]
  if not session then
    return
  end
  sessions[profile_name] = nil
  local process = session.process
  fail(session, "connection closed")
  if process then
    process:kill(15)
  end
end

function M.connected(profile_name)
  return sessions[profile_name] and sessions[profile_name].process ~= nil
end

return M
