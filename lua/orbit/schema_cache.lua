local adapters = require("orbit.adapters")
local runner = require("orbit.runner")

local M = {}
local profiles = {}

local function entry(profile_name)
  profiles[profile_name] = profiles[profile_name] or {
    columns = {},
    column_callbacks = {},
    metadata = {},
    metadata_callbacks = {},
    loading_metadata = {},
    loading_columns = {},
    loading_tables = false,
    table_callbacks = {},
    tables = nil,
  }
  return profiles[profile_name]
end

function M.store_tables(profile_name, tables)
  local value = entry(profile_name)
  value.tables = tables
end

function M.tables(profile_name)
  return entry(profile_name).tables or {}
end

function M.store_columns(profile_name, table_name, columns)
  entry(profile_name).columns[table_name] = columns
end

function M.columns(profile_name, table_name)
  return entry(profile_name).columns[table_name] or {}
end

local function deliver(callbacks, rows, err)
  for _, callback in ipairs(callbacks) do
    callback(rows, err)
  end
end

function M.load_tables(profile, options, callback)
  options = options or {}
  callback = callback or function() end
  local value = entry(profile.name)
  if value.loading_tables then
    table.insert(value.table_callbacks, callback)
    return
  end
  if value.tables and not options.refresh then
    vim.schedule(function()
      callback(value.tables)
    end)
    return
  end
  table.insert(value.table_callbacks, callback)
  value.loading_tables = true
  local statement = assert(adapters.schema_statement(profile, { type = "tables" }))
  runner.run(profile, statement, function(rows, err)
    value.loading_tables = false
    local callbacks = value.table_callbacks
    value.table_callbacks = {}
    if not err then
      value.tables = rows
      if options.refresh then
        value.columns = {}
        value.metadata = {}
      end
    end
    deliver(callbacks, rows, err)
  end)
end

function M.load_columns(profile, row, options, callback)
  options = options or {}
  callback = callback or function() end
  local table_name = table.concat(vim.tbl_filter(function(value)
    return value and value ~= ""
  end, { row.catalog, row.schema, row.name }), ".")
  local value = entry(profile.name)
  if value.loading_columns[table_name] then
    table.insert(value.column_callbacks[table_name], callback)
    return
  end
  if value.columns[table_name] and not options.refresh then
    vim.schedule(function()
      callback(value.columns[table_name])
    end)
    return
  end
  value.column_callbacks[table_name] = value.column_callbacks[table_name] or {}
  table.insert(value.column_callbacks[table_name], callback)
  value.loading_columns[table_name] = true
  local statement = assert(adapters.schema_statement(profile, {
    type = "columns",
    name = row.name,
    schema = row.schema,
    catalog = row.catalog,
  }))
  runner.run(profile, statement, function(columns, err)
    value.loading_columns[table_name] = nil
    local callbacks = value.column_callbacks[table_name]
    value.column_callbacks[table_name] = nil
    if not err then
      value.columns[table_name] = columns
    end
    deliver(callbacks, columns, err)
  end)
end

function M.load_metadata(profile, row, category, options, callback)
  if category == "columns" then
    return M.load_columns(profile, row, options, callback)
  end

  options = options or {}
  callback = callback or function() end
  local table_name = table.concat(vim.tbl_filter(function(value)
    return value and value ~= ""
  end, { row.catalog, row.schema, row.name }), ".")
  local key = table_name .. "\0" .. category
  local value = entry(profile.name)
  if value.loading_metadata[key] then
    table.insert(value.metadata_callbacks[key], callback)
    return
  end
  if value.metadata[key] and not options.refresh then
    vim.schedule(function()
      callback(value.metadata[key])
    end)
    return
  end
  value.metadata_callbacks[key] = value.metadata_callbacks[key] or {}
  table.insert(value.metadata_callbacks[key], callback)
  value.loading_metadata[key] = true
  local statement = assert(adapters.schema_statement(profile, {
    type = category,
    name = row.name,
    schema = row.schema,
    catalog = row.catalog,
  }))
  runner.run(profile, statement, function(rows, err)
    value.loading_metadata[key] = nil
    local callbacks = value.metadata_callbacks[key]
    value.metadata_callbacks[key] = nil
    if not err then
      value.metadata[key] = rows
    end
    deliver(callbacks, rows, err)
  end)
end

return M
