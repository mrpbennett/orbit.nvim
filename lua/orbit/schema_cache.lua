local adapters = require("orbit.adapters")
local runner = require("orbit.runner")

local M = {}
local profiles = {}
local metadata_categories = {
  columns = true,
  foreign_keys = true,
  indexes = true,
  primary_keys = true,
}

local function entry(profile)
  local signature = vim.json.encode({ kind = profile.kind, options = profile.options })
  if not profiles[profile.name] or profiles[profile.name].signature ~= signature then
    profiles[profile.name] = {
      columns = {},
      metadata = {},
      requests = {},
      signature = signature,
      tables = nil,
    }
  end
  return profiles[profile.name]
end

local function deliver(callbacks, rows, err)
  for _, callback in ipairs(callbacks) do
    callback(rows, err)
  end
end

local start_acquisition

local function finish_acquisition(request, rows, err)
  local refresh = request.refreshing
  local callbacks = request.callbacks
  local refresh_queued = #request.queued_refresh_callbacks > 0
  if refresh_queued then
    -- Reserve the queued refresh before callbacks run so reentrant requests join it.
    request.callbacks = request.queued_refresh_callbacks
    request.queued_refresh_callbacks = {}
    request.loading = true
    request.refreshing = true
  else
    request.callbacks = {}
    request.loading = false
    request.refreshing = false
  end
  if not err then
    request.store(rows)
    if refresh and request.invalidate then
      request.invalidate()
    end
  end
  deliver(callbacks, rows, err)

  if refresh_queued then
    start_acquisition(request, true)
  end
end

start_acquisition = function(request, refresh)
  request.loading = true
  request.refreshing = refresh
  request.execute(function(rows, err)
    finish_acquisition(request, rows, err)
  end)
end

local function acquire(state, key, options, callback, cached, store, execute, invalidate)
  local request = state.requests[key]
  if not request then
    request = {
      callbacks = {},
      loading = false,
      queued_refresh_callbacks = {},
      refreshing = false,
    }
    state.requests[key] = request
  end

  if request.loading then
    if options.refresh and not request.refreshing then
      table.insert(request.queued_refresh_callbacks, callback)
    else
      -- Normal requests join a refresh; refresh requests queue behind ordinary acquisition.
      table.insert(request.callbacks, callback)
    end
    return
  end

  local rows = cached()
  if rows and not options.refresh then
    -- Cache hits remain asynchronous so callers have one completion timing model.
    vim.schedule(function()
      callback(rows)
    end)
    return
  end

  request.callbacks = { callback }
  request.execute = execute
  request.invalidate = invalidate
  request.store = store
  start_acquisition(request, options.refresh == true)
end

local function run_schema_statement(profile, connector, node, callback)
  if not connector then
    local connector_err
    connector, connector_err = adapters.connector(profile)
    if not connector then
      vim.schedule(function()
        callback(nil, connector_err)
      end)
      return
    end
  end
  local statement, statement_err = connector.schema_statement(profile.options, node)
  if not statement then
    vim.schedule(function()
      callback(nil, statement_err)
    end)
    return
  end
  runner.run(profile, statement, callback, connector)
end

local function connector_for_metadata(profile, row, category, callback)
  local connector, connector_err = adapters.connector(profile)
  if not connector then
    vim.schedule(function()
      callback(nil, connector_err)
    end)
    return
  end
  for _, candidate in ipairs(connector.metadata_categories and connector.metadata_categories(profile.options, row) or {}) do
    if candidate.id == category then
      return connector
    end
  end
  vim.schedule(function()
    callback({})
  end)
end

local function object_name(row)
  return table.concat(vim.tbl_filter(function(value)
    return value and value ~= ""
  end, { row.catalog, row.schema, row.name }), ".")
end

function M.tables(profile)
  return entry(profile).tables or {}
end

function M.columns(profile, table_name)
  return entry(profile).columns[table_name] or {}
end

function M.load_tables(profile, options, callback)
  options = options or {}
  callback = callback or function() end
  local state = entry(profile)
  acquire(state, "tables", options, callback, function()
    return state.tables
  end, function(rows)
    state.tables = rows
  end, function(done)
    run_schema_statement(profile, nil, { type = "tables" }, done)
  end, function()
    -- A successful table refresh invalidates dependent object metadata, not failed data.
    state.columns = {}
    state.metadata = {}
  end)
end

function M.load_columns(profile, row, options, callback)
  options = options or {}
  callback = callback or function() end
  local connector = connector_for_metadata(profile, row, "columns", callback)
  if not connector then
    return
  end
  local table_name = object_name(row)
  local state = entry(profile)
  acquire(state, "columns\0" .. table_name, options, callback, function()
    return state.columns[table_name]
  end, function(rows)
    state.columns[table_name] = rows
  end, function(done)
    run_schema_statement(profile, connector, {
      type = "columns",
      name = row.name,
      schema = row.schema,
      catalog = row.catalog,
    }, done)
  end)
end

function M.load_metadata(profile, row, category, options, callback)
  options = options or {}
  callback = callback or function() end
  if not metadata_categories[category] then
    vim.schedule(function()
      callback(nil, "unknown table metadata category: " .. tostring(category))
    end)
    return
  end
  if category == "columns" then
    return M.load_columns(profile, row, options, callback)
  end

  local connector = connector_for_metadata(profile, row, category, callback)
  if not connector then
    return
  end
  local key = object_name(row) .. "\0" .. category
  local state = entry(profile)
  acquire(state, "metadata\0" .. key, options, callback, function()
    return state.metadata[key]
  end, function(rows)
    state.metadata[key] = rows
  end, function(done)
    run_schema_statement(profile, connector, {
      type = category,
      name = row.name,
      schema = row.schema,
      catalog = row.catalog,
    }, done)
  end)
end

return M
