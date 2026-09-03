-- Schema cache.
--
-- This module caches the results of database "metadata discovery" queries
-- (the list of tables in a connection, a table's columns, its primary/
-- foreign keys, its indexes) so the sidebar tree and SQL completion source
-- don't have to re-run a schema query against the real database every time
-- the user opens a menu or triggers completion. Callers ask for data via
-- M.tables/M.columns (synchronous - read whatever is cached right now,
-- possibly nothing) or M.load_tables/M.load_columns/M.load_metadata
-- (asynchronous - fetch if needed, then invoke a callback with fresh rows).
--
-- Getting the actual metadata SQL to run is delegated to whichever
-- "connector" module (lua/orbit/connectors/postgres.lua, trino.lua,
-- sqlite.lua) matches the profile's `kind` - see connector.schema_statement
-- in those files. This module only owns *caching and request de-duplication*
-- around that: making sure that if the sidebar and completion both ask for
-- the same table's columns at the same time, only one query is actually run
-- against the database and both callers get the answer once it comes back.
--
-- Cache shape: `profiles` is a table keyed by profile name, each holding one
-- "state" table (see `entry` below) with:
--   .tables   - cached array of table/view rows, or nil if never loaded.
--   .columns  - map of "catalog.schema.table" -> cached array of column rows.
--   .metadata - map of "catalog.schema.table\0category" -> cached array of
--               rows for a metadata category (primary_keys/foreign_keys/indexes/projections).
--   .requests - map of cache key -> in-flight request bookkeeping (see
--               `acquire`), so concurrent callers asking for the same thing
--               share one underlying query instead of firing duplicates.
--   .signature - a JSON-encoded fingerprint of the profile's kind+options,
--               used to detect that a profile was edited and its cache
--               should be thrown away (see `entry`).
--
-- This module has no persistence: everything lives only in this in-memory
-- Lua table for the lifetime of the Neovim process, and is discarded/rebuilt
-- whenever a profile's connection settings change.
local adapters = require("orbit.adapters")
local runner = require("orbit.runner")

local M = {}
local profiles = {}
-- The set of metadata "categories" this module knows how to cache/route,
-- beyond plain columns (which gets its own dedicated M.load_columns path).
-- Kept in sync with what connectors advertise via metadata_categories().
local metadata_categories = {
  columns = true,
  foreign_keys = true,
  indexes = true,
  primary_keys = true,
  projections = true,
}

-- Looks up (creating if necessary) the cache state for one connection
-- `profile`, discarding any previous cache if the profile's kind/options
-- have changed since it was last cached (e.g. the user edited the host or
-- switched database kind, so any previously cached tables/columns would now
-- be for a different database and must not be reused).
-- Parameter: profile - a connection profile table with .name, .kind, .options.
-- Returns: the state table for this profile (see cache shape above), never nil.
-- Side effect: may replace/insert profiles[profile.name].
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

-- Invokes every callback in `callbacks` with the same (rows, err) result.
-- Used to fan a single completed query out to every caller that was waiting
-- on it (see `acquire` below - multiple callers asking for the same data
-- while a request is in flight all get queued into one `callbacks` list).
local function deliver(callbacks, rows, err)
  for _, callback in ipairs(callbacks) do
    callback(rows, err)
  end
end

-- Forward-declared because start_acquisition and finish_acquisition call
-- each other (a refresh that gets queued while finishing restarts
-- acquisition), so one of the two must be declared as a local upvalue
-- before either function body is written.
local start_acquisition

-- Called once a request's underlying query (`request.execute`) has
-- completed, whether it succeeded or failed. Stores successful results into
-- the cache, notifies every caller that was waiting on this request, and -
-- if another "refresh" request came in while this one was still running -
-- immediately kicks off that queued refresh next.
-- Parameters:
--   request - the in-flight request bookkeeping table (see `acquire`).
--   rows    - the rows returned by the query, or nil on error.
--   err     - an error message string, or nil on success.
-- Side effects: mutates `request` state, calls request.store(rows) to write
-- into the cache, may call request.invalidate() to drop now-stale dependent
-- cache entries, and invokes every queued callback.
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

-- Actually runs a request's query. Marks the request as loading (so any
-- other caller who asks for the same key while this is in flight gets
-- queued instead of starting a duplicate query - see `acquire`), then calls
-- request.execute (which runs the real database query, asynchronously) and
-- routes its result through finish_acquisition.
-- Parameters: request (bookkeeping table), refresh (true if this run is a
-- forced cache-busting reload rather than a first-time fetch).
-- Side effect: eventually invokes every callback waiting on this request.
start_acquisition = function(request, refresh)
  request.loading = true
  request.refreshing = refresh
  request.execute(function(rows, err)
    finish_acquisition(request, rows, err)
  end)
end

-- The core cache/de-duplication engine shared by M.load_tables,
-- M.load_columns, and M.load_metadata. Given a cache `key` (e.g. "tables",
-- or "columns\0mytable"), decides whether to answer `callback` immediately
-- from cache, join an already-in-flight request for the same key, or start
-- a brand new query.
-- Parameters:
--   state      - the profile's cache state table (from `entry`).
--   key        - a string uniquely identifying what's being requested,
--                scoped to this profile's `state.requests` table.
--   options    - caller options; only `options.refresh` (boolean) is used,
--                to force a reload even if a cached value already exists.
--   callback   - function(rows, err) to call once an answer is available.
--   cached     - function() -> cached rows or nil; reads the current cache
--                value for this key.
--   store      - function(rows); writes a freshly fetched result into the
--                cache for this key.
--   execute    - function(done); runs the actual query and calls done(rows, err)
--                asynchronously when finished.
--   invalidate - optional function(); called after a successful *refresh*
--                (not a first load) to drop other cache entries that
--                depended on this one (e.g. reloading the table list clears
--                cached columns, since tables may have been added/removed).
-- Side effects: may create/mutate state.requests[key], schedules callback
-- invocation on Neovim's event loop (via vim.schedule) so callers always get
-- an asynchronous response even on a cache hit, and may start a new
-- database query.
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

-- Asks the profile's connector for the SQL to discover some piece of schema
-- metadata (`node`, e.g. { type = "tables" } or { type = "columns", ... } -
-- see connector.schema_statement in lua/orbit/connectors/*.lua), then
-- actually runs that SQL against the real database via lua/orbit/runner.lua.
-- Parameters:
--   profile   - the connection profile to run against.
--   connector - the already-resolved connector module, or nil to look one
--               up from `profile.kind` via lua/orbit/adapters.lua.
--   node      - the schema_statement request descriptor.
--   callback  - function(rows, err) invoked (async, on Neovim's event loop)
--               once the query completes or an error occurs earlier.
-- Side effects: performs actual process/CLI I/O through runner.run (spawns
-- or reuses a database CLI process - see lua/orbit/runner.lua and
-- lua/orbit/session.lua for how that I/O happens).
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

-- Resolves the connector for `profile` and checks that it actually
-- advertises support for the given metadata `category` (via the
-- connector's metadata_categories function - see e.g. trino.lua's version,
-- which only ever offers "columns", vs sqlite.lua's, which also offers
-- primary_keys/foreign_keys/indexes for real tables). This exists because
-- not every connector/object combination supports every category, and
-- callers need a graceful "no rows" answer rather than an error when a
-- category simply isn't applicable.
-- Parameters: profile, row (the schema object being inspected), category
-- (string id like "primary_keys"), callback (function(rows, err), used only
-- on the "unsupported" paths here - see below).
-- Returns: the connector module if the category is supported, so the caller
-- can proceed to actually run a query with it; otherwise returns nothing
-- (nil) and instead calls `callback({})` itself (asynchronously) to report
-- "no metadata of this kind" without treating it as an error.
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

-- Builds the cache key used to identify one schema object across catalog/
-- schema/table, e.g. "mycatalog.myschema.mytable" or just "mytable" for a
-- backend (like SQLite) that has no catalog/schema. Empty/absent parts are
-- dropped rather than leaving stray "." separators.
-- Parameter: row - a schema object row with optional .catalog/.schema and .name.
-- Returns: a dotted string uniquely naming the object for cache-key purposes.
local function object_name(row)
  return table.concat(vim.tbl_filter(function(value)
    return value and value ~= ""
  end, { row.catalog, row.schema, row.name }), ".")
end

-- Synchronously returns whatever table/view list is currently cached for
-- `profile`, without triggering a load. Callers that want to guarantee
-- fresh (or at least loaded-once) data should call M.load_tables instead;
-- this is for UI code that just wants to render "whatever we already know".
-- Returns: an array of table/view rows, or {} if nothing has been loaded yet.
function M.tables(profile)
  return entry(profile).tables or {}
end

-- Synchronously returns whatever column list is currently cached for
-- `table_name` (as produced by object_name) on `profile`, without
-- triggering a load. See M.tables above for the same "cache read, no fetch"
-- pattern.
-- Returns: an array of column rows, or {} if not loaded yet.
function M.columns(profile, table_name)
  return entry(profile).columns[table_name] or {}
end

-- Asynchronously loads the list of tables/views for `profile`, using the
-- cache if possible. This is the entry point the sidebar tree calls when it
-- needs to show (or refresh) the top-level list of database objects.
-- Parameters:
--   profile  - the connection profile to query.
--   options  - optional table; `options.refresh = true` forces a reload
--              even if a cached table list already exists (e.g. user hit a
--              manual refresh keybinding).
--   callback - optional function(rows, err) called once data is available
--              (always asynchronously, even on a cache hit).
-- Side effects: may run a real schema query (process/CLI I/O); on a
-- successful *refresh* (not first load), also clears the cached columns and
-- metadata for this profile, since a table could have been renamed/dropped
-- and any cached column/key/index info for it would now be stale.
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

-- Asynchronously loads the column list for one schema object `row`, using
-- the cache if possible. This is what powers both the sidebar's "expand a
-- table to see its columns" view and (indirectly, via load_metadata) SQL
-- completion for column names.
-- Parameters:
--   profile  - the connection profile to query.
--   row      - the table/view row (name/schema/catalog) to fetch columns for.
--   options  - optional table; `options.refresh = true` forces a reload.
--   callback - optional function(rows, err), called asynchronously.
-- Side effects: may run a real schema query. If the connector doesn't
-- advertise "columns" support for this row (see connector_for_metadata),
-- calls back with an empty list instead of querying anything.
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

-- Asynchronously loads one "metadata category" (columns, primary_keys,
-- foreign_keys, or indexes) for schema object `row`. This is the general
-- entry point the sidebar's per-object detail panels use; `category ==
-- "columns"` is simply delegated to M.load_columns so there's only one
-- cache/code path for that particular category.
-- Parameters:
--   profile  - the connection profile to query.
--   row      - the table/view row the metadata belongs to.
--   category - one of the keys in the module-level `metadata_categories`
--              table: "columns", "primary_keys", "foreign_keys", "indexes", "projections".
--   options  - optional table; `options.refresh = true` forces a reload.
--   callback - optional function(rows, err), called asynchronously.
-- Side effects: may run a real schema query. Calls back with an error if
-- `category` isn't one of the known categories, or with an empty list if
-- the connector doesn't support this category for this object.
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
