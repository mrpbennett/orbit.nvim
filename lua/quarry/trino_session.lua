local adapters = require("quarry.adapters")

local M = {}

local sessions = {}
local sequence = 0
local ensure_process
local stop

local function next_json(buffer)
  local array = buffer:find("[", 1, true)
  local object = buffer:find("{", 1, true)
  local start = array and object and math.min(array, object) or array or object
  if not start then
    return nil, "", buffer
  end

  buffer = buffer:sub(start)
  local depth = 0
  local escaped = false
  local quoted = false
  for index = 1, #buffer do
    local character = buffer:sub(index, index)
    if quoted then
      if escaped then
        escaped = false
      elseif character == "\\" then
        escaped = true
      elseif character == '"' then
        quoted = false
      end
    elseif character == '"' then
      quoted = true
    elseif character == "[" or character == "{" then
      depth = depth + 1
    elseif character == "]" or character == "}" then
      depth = depth - 1
      if depth == 0 then
        return buffer:sub(1, index), buffer:sub(index + 1), ""
      end
    end
  end
  return nil, "", buffer
end

-- Decode complete JSON values while retaining a partial value for the next stdout chunk.
function M.decode_stream(state, chunk)
  state.buffer = (state.buffer or "") .. (chunk or "")
  local values = {}
  while true do
    local json, rest, partial = next_json(state.buffer)
    state.buffer = partial
    if not json then
      return values
    end
    local ok, value = pcall(vim.json.decode, json)
    if not ok then
      return nil, "Trino CLI output is not valid JSON"
    end
    table.insert(values, value)
    state.buffer = rest
  end
end

local function session_for(profile)
  local session = sessions[profile.name]
  if not session then
    session = { profile = profile, queue = {}, stream = { buffer = "" }, stderr = "" }
    sessions[profile.name] = session
  end
  return session
end

local function password_required(options)
  return vim.tbl_contains(options.arguments or {}, "--password")
end

local function finish(session, rows, err)
  local job = session.active
  if not job then
    return
  end
  session.active = nil
  vim.schedule(function()
    job.callback(rows, err)
  end)
end

local function start_next(session)
  if session.active or #session.queue == 0 then
    return
  end
  if not session.process then
    local started, start_err = ensure_process(session)
    if not started then
      local job = table.remove(session.queue, 1)
      vim.schedule(function()
        job.callback(nil, start_err)
      end)
      start_next(session)
      return
    end
  end
  session.active = table.remove(session.queue, 1)
  local job = session.active
  sequence = sequence + 1
  job.marker = string.format("__quarry_%d_%d__", vim.uv.hrtime(), sequence)
  job.stderr_start = #session.stderr
  local statement = vim.trim(job.statement)
  if statement:sub(-1) ~= ";" then
    statement = statement .. ";"
  end
  local input = statement .. "\nSELECT '" .. job.marker .. "' AS __quarry_marker;\n"
  local ok, write_err = pcall(session.process.write, session.process, input)
  if not ok then
    stop(session, "cannot write to Trino CLI: " .. tostring(write_err))
    start_next(session)
  end
end

stop = function(session, err)
  local process = session.process
  session.process = nil
  if process then
    pcall(process.kill, process, 15)
  end
  if session.active then
    finish(session, nil, err)
  end
end

local function handle_stdout(session, chunk)
  local values, parse_err = M.decode_stream(session.stream, chunk)
  if not values then
    stop(session, parse_err)
    start_next(session)
    return
  end
  local job = session.active
  if not job then
    return
  end
  for _, value in ipairs(values) do
    local marker = false
    if vim.islist(value) then
      for _, row in ipairs(value) do
        if row.__quarry_marker == job.marker then
          marker = true
          break
        end
      end
    end
    if marker then
      local stderr = vim.trim(session.stderr:sub(job.stderr_start + 1))
      finish(session, stderr == "" and job.rows or nil, stderr == "" and nil or "Trino CLI: " .. stderr)
      start_next(session)
      return
    end
    if vim.islist(value) then
      vim.list_extend(job.rows, value)
    else
      table.insert(job.rows, value)
    end
  end
end

ensure_process = function(session)
  if session.process then
    return true
  end
  local command, command_err = adapters.prepare(session.profile, "interactive")
  if not command then
    return nil, command_err
  end
  local password
  if password_required(session.profile.options) then
    password = vim.env.TRINO_PASSWORD
    if not password or password == "" then
      return nil, "TRINO_PASSWORD must be set before starting Neovim when using --password"
    end
  end
  local process
  local ok, start_err = pcall(function()
    process = vim.system(command, {
      stdin = true,
      stdout = function(_, chunk)
        if chunk then
          handle_stdout(session, chunk)
        end
      end,
      stderr = function(_, chunk)
        if chunk then
          session.stderr = session.stderr .. chunk
        end
      end,
      text = true,
    }, function(result)
      if session.process ~= process then
        return
      end
      session.process = nil
      if session.active then
        local detail = vim.trim(session.stderr:sub(session.active.stderr_start + 1))
        local message = detail ~= "" and "Trino CLI: " .. detail or string.format("Trino CLI exited (%d)", result.code)
        finish(session, nil, message)
      end
      local started = ensure_process(session)
      if started then
        start_next(session)
      end
    end)
  end)
  if not ok then
    return nil, "cannot start CLI: " .. tostring(start_err)
  end
  session.process = process
  if password then
    local wrote, write_err = pcall(process.write, process, password .. "\n")
    if not wrote then
      session.process = nil
      pcall(process.kill, process, 15)
      return nil, "cannot provide Trino password: " .. tostring(write_err)
    end
  end
  return true
end

function M.run(profile, statement, callback)
  local session = session_for(profile)
  local job = { callback = callback, rows = {}, statement = statement }
  table.insert(session.queue, job)
  local started, start_err = ensure_process(session)
  if not started then
    table.remove(session.queue, #session.queue)
    vim.schedule(function()
      callback(nil, start_err)
    end)
    return nil
  end
  start_next(session)
  return {
    cancel = function()
      if session.active == job then
        stop(session, "query cancelled")
        local started = ensure_process(session)
        if started then
          start_next(session)
        end
        return
      end
      for index, queued in ipairs(session.queue) do
        if queued == job then
          table.remove(session.queue, index)
          vim.schedule(function()
            callback(nil, "query cancelled")
          end)
          return
        end
      end
    end,
  }
end

return M
