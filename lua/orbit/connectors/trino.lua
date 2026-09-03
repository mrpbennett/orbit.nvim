-- Trino connector.
--
-- This module is one of several "connector" backends in lua/orbit/connectors/.
-- A connector is a plain Lua table of functions that teaches the rest of the
-- plugin (mainly lua/orbit/runner.lua, lua/orbit/session.lua, and
-- lua/orbit/schema_cache.lua) how to talk to one specific kind of database.
-- Orbit itself never speaks Trino's wire protocol directly: instead it shells
-- out to the `trino` command-line client (a separate program the user must
-- have installed) and parses whatever that CLI prints to stdout. This keeps
-- the plugin free of any HTTP/JDBC client code, at the cost of depending on
-- an external binary being on the user's PATH.
--
-- Contract this module implements (see lua/orbit/adapters.lua for the lookup
-- table and lua/orbit/runner.lua for how these hooks get called):
--   * validate_options(profile_name, options) -> true | nil, err
--       Sanity-checks the user's profile configuration before it is ever used.
--   * prepare(options, statement) -> command (array of CLI arguments)
--       Builds the argv for a *one-shot* `trino` invocation that runs a single
--       SQL statement and exits. Trino has no `session_command`/session_*
--       functions (unlike postgres.lua/sqlite.lua), so runner.lua always
--       spawns a brand new `trino` process per statement instead of reusing
--       a persistent session (see lua/orbit/runner.lua M.run: connectors
--       without session_command fall back to run_once()).
--   * qualified_name(options, row) -> string
--       Renders a fully-qualified "catalog.schema.table" name for display/use
--       in generated SQL.
--   * completion_word(options, row, prefix) -> string
--       Produces the text that should be inserted when a user is completing
--       a table/column name in the SQL editor.
--   * schema_statement(options, node) -> statement (string) | nil, err
--       Given a description of what metadata is wanted (all tables, or the
--       columns of one table), returns the SQL to run against Trino's
--       information_schema to fetch that metadata. Called by
--       lua/orbit/schema_cache.lua whenever the sidebar/completion needs to
--       (re)discover tables or columns.
--   * metadata_categories(options, row) -> list of {id, label}
--       Tells the UI which extra detail categories (columns, primary keys,
--       etc.) can be shown for a given schema object. Trino only supports
--       "columns" here (no primary/foreign key or index introspection).
--   * object_actions(options, row, limit) -> list of action tables | nil, err
--       Builds the context-menu actions offered for a table/view in the
--       sidebar (e.g. "open a sample SELECT", "show columns").
--
-- Notably absent compared to postgres.lua/sqlite.lua: `session_command`,
-- `session_request`, `session_output`, `environment`, `editable_table`, and
-- `mutation_statement`. Those are all optional parts of the connector
-- contract - Trino connections here are always one-shot processes (no long
-- lived session to reuse), and this module does not support editing grid
-- results back into the database (no primary-key based UPDATE/INSERT/DELETE
-- generation), so those hooks are simply omitted.
local M = {}

-- Appends every item of `values` onto the end of `arguments`, in place.
-- Small helper used throughout this file to build up CLI argument lists
-- (Lua has no built-in "array concat", so this is the idiomatic substitute).
-- Side effect: mutates `arguments`.
local function append(arguments, values)
  for _, value in ipairs(values) do
    table.insert(arguments, value)
  end
end

local schema_pattern = require("orbit.connectors.utils.schema_pattern")

-- Formats a Lua value as a single-quoted SQL *string literal*, escaping any
-- embedded single quotes by doubling them (the standard SQL escaping rule).
-- Use this for values that go where SQL expects a string/constant, e.g.
-- inside a WHERE clause comparing against a schema name. Do NOT use this for
-- table/column names - see `identifier` below for that.
local function literal(value)
  -- SQL literals and identifiers use distinct escaping rules and must never be interchangeable.
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

-- Formats a Lua value as a double-quoted SQL *identifier* (table/column/
-- catalog/schema name), escaping embedded double quotes by doubling them.
-- Wrapping identifiers like this lets Orbit safely reference names that
-- contain spaces, reserved words, or mixed case without Trino reinterpreting
-- or case-folding them.
local function identifier(value)
  return '"' .. tostring(value):gsub('"', '""') .. '"'
end

-- Checks that a connection profile's `options` table (the per-profile config
-- the user wrote in their Orbit setup) only contains keys this connector
-- understands, and that the values have sane types/shapes. This runs once
-- when a profile is loaded/edited, before any query is ever attempted, so
-- mistakes are reported early with a clear message rather than surfacing as
-- a confusing CLI failure later.
-- Parameters:
--   profile_name - string, used only to make error messages identify which
--                  profile is misconfigured.
--   options      - table of user-supplied connection settings.
-- Returns: `true` on success, or `nil, "error message"` on failure. No side
-- effects (pure validation).
function M.validate_options(profile_name, options)
  local allowed = {
    arguments = true,
    catalog = true,
    confirm_mutations = true,
    executable = true,
    schema = true,
    schema_patterns = true,
    server = true,
    user = true,
  }
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported Trino option %q", profile_name, name)
    end
  end
  if options.schema ~= nil and type(options.schema) ~= "string" then
    return nil, string.format("profile %q options.schema must be a string", profile_name)
  end
  if options.schema_patterns ~= nil then
    if type(options.schema_patterns) ~= "table" or vim.islist(options.schema_patterns) then
      return nil, string.format("profile %q options.schema_patterns must map catalogs to schema arrays", profile_name)
    end
    for catalog, schemas in pairs(options.schema_patterns) do
      if type(catalog) ~= "string" or catalog == "" or type(schemas) ~= "table" or not vim.islist(schemas) then
        return nil, string.format("profile %q options.schema_patterns must map catalog names to schema arrays", profile_name)
      end
      for _, schema in ipairs(schemas) do
        if type(schema) ~= "string" or schema == "" then
          return nil, string.format("profile %q options.schema_patterns must contain non-empty schema names", profile_name)
        end
      end
    end
  end
  return true
end

-- Builds the argument list (argv) for running one SQL `statement` through the
-- `trino` CLI as a fresh, one-shot subprocess (there is no persistent Trino
-- session in this connector - every statement pays the cost of starting a
-- new client and connecting to the cluster).
-- Parameters:
--   options   - the profile's connection options (server URL, catalog,
--               schema, user, executable override, extra CLI arguments).
--   statement - the raw SQL text to execute.
-- Returns: an array of strings suitable for vim.system()/vim.fn.jobstart(),
-- e.g. { "trino", "--server", ..., "--execute", statement }.
-- `--output-format JSON` tells the CLI to print results as JSON so this
-- module's parsing (delegated to lua/orbit/adapters.lua's generic JSON
-- parser, since this file defines no M.parse) can read them back reliably.
-- No side effects - this only builds a table describing a command; runner.lua
-- is responsible for actually spawning it.
function M.prepare(options, statement)
  local command = { options.executable or "trino" }
  append(command, options.arguments or {})
  append(command, {
    "--server", options.server,
    "--user", options.user,
    "--catalog", options.catalog,
  })
  if options.schema and options.schema ~= "" then
    append(command, { "--schema", options.schema })
  end
  append(command, {
    "--no-progress",
    "--output-format", "JSON",
    "--execute", statement,
  })
  return command
end

-- Renders a fully-qualified "catalog.schema.table" name for a discovered
-- schema object `row` (as produced by the tables/columns queries below),
-- falling back to the profile's default catalog/schema when the row itself
-- doesn't carry one. Used anywhere Orbit needs to generate SQL that
-- unambiguously names an object (e.g. the sample SELECT in object_actions).
-- Parameters: options (profile options, for defaults), row (a table/view
-- metadata row with optional .catalog/.schema and required .name).
-- Returns: a string like `"catalog"."schema"."table"`.
function M.qualified_name(options, row)
  return table.concat({
    identifier(row.catalog or options.catalog),
    identifier(row.schema or options.schema),
    identifier(row.name),
  }, ".")
end

-- Decides what text to insert into the SQL buffer when the completion menu
-- (see the blink.cmp source added in lua/orbit's completion code) accepts a
-- suggestion for `row`. This is deliberately unquoted/plain (unlike
-- qualified_name, which produces quoted identifiers for generated SQL) since
-- it is inserted directly into text the user is actively typing.
-- Parameters:
--   options - profile options, used to know the default catalog so we only
--             add a catalog prefix when the object lives outside it.
--   row     - the table/view/column row being completed.
--   prefix  - the portion of the qualifier the user already typed (e.g.
--             "myschema." if they typed "myschema.par" before the cursor).
-- Returns: the completion text to insert.
function M.completion_word(options, row, prefix)
  if prefix ~= "" then
    return prefix .. row.name
  end
  local parts = row.schema and { row.schema, row.name } or { row.name }
  if row.catalog and row.catalog ~= options.catalog then
    table.insert(parts, 1, row.catalog)
  end
  return table.concat(parts, ".")
end

-- Builds the SQL statement used to discover schema metadata for the sidebar
-- and completion engine. `node` describes what is being asked for:
--   { type = "tables" }                                     - list all tables/views
--   { type = "columns", name = ..., schema = ..., catalog = ... } - list one table's columns
-- This is the connector's implementation of the metadata-discovery half of
-- the contract; lua/orbit/schema_cache.lua calls this (via
-- run_schema_statement) and then runs the returned SQL exactly like any
-- other query, through the normal Trino CLI one-shot process.
-- Parameters:
--   options - profile options; supplies the default catalog/schema, and
--             optionally `schema_patterns` (a table mapping catalog name ->
--             array of schema names) to restrict which schemas get scanned
--             when listing tables across multiple catalogs.
--   node    - the metadata request described above.
-- Returns: a SQL string to execute, or `nil, "error message"` if the
-- request can't be satisfied (e.g. columns requested with no schema known).
function M.schema_statement(options, node)
  if node.type == "tables" then
    if options.schema_patterns then
      -- Patterns are catalog-to-schema maps, so each catalog needs its own information_schema query.
      -- Unlike Postgres (one database = one information_schema), Trino
      -- federates multiple catalogs, each with its own information_schema.
      -- So when the user has restricted discovery to specific catalogs/
      -- schemas, we must build one SELECT per catalog and UNION them
      -- together rather than issuing a single query.
      local statements = {}
      for catalog, schemas in pairs(options.schema_patterns) do
        local clauses = {
          "SELECT " .. literal(catalog) .. " AS catalog, table_schema AS schema, table_name AS name, table_type AS type",
          "FROM " .. identifier(catalog) .. ".information_schema.tables",
          "WHERE table_schema <> 'information_schema'",
        }
        -- An empty schema list for a catalog means "all schemas in this
        -- catalog"; a non-empty list restricts to just those schemas
        -- (entries may be exact names or `*`/`?` glob patterns).
        local schema_clause = schema_pattern.sql_clause("table_schema", schemas)
        if schema_clause then
          table.insert(clauses, "AND " .. schema_clause)
        end
        table.insert(statements, table.concat(clauses, " "))
      end
      return table.concat(statements, " UNION ALL ") .. " ORDER BY catalog, schema, name"
    end
    -- No schema_patterns configured: fall back to a single query against
    -- just the profile's configured default catalog (and, if set, schema).
    local clauses = {
      "SELECT table_catalog AS catalog, table_schema AS schema, table_name AS name, table_type AS type",
      "FROM information_schema.tables",
      "WHERE table_catalog = " .. literal(options.catalog),
      "AND table_schema <> 'information_schema'",
    }
    if options.schema and options.schema ~= "" then
      table.insert(clauses, "AND table_schema = " .. literal(options.schema))
    end
    table.insert(clauses, "ORDER BY catalog, schema, name")
    return table.concat(clauses, " ")
  end
  if node.type == "columns" and node.name then
    -- A specific object's schema/catalog (from `node`) takes priority over
    -- the profile default, since the object may have been discovered in a
    -- catalog/schema other than the one configured as default.
    local schema = node.schema or options.schema
    local catalog = node.catalog or options.catalog
    if not schema or schema == "" then
      return nil, "schema is required to load Trino columns"
    end
    return table.concat({
      "SELECT column_name AS name, data_type AS type",
      "FROM " .. identifier(catalog) .. ".information_schema.columns",
      "WHERE table_catalog = " .. literal(catalog),
      "AND table_schema = " .. literal(schema),
      "AND table_name = " .. literal(node.name),
      "ORDER BY ordinal_position",
    }, " ")
  end
  return nil, "unsupported schema node"
end

-- Reports which extra detail "categories" the sidebar UI can offer for a
-- schema object. Trino only exposes column metadata here (no primary key,
-- foreign key, or index introspection support, unlike postgres.lua and
-- sqlite.lua), so this always returns the same single-item list regardless
-- of arguments.
-- Returns: a list of { id = string, label = string } tables.
function M.metadata_categories()
  return { { id = "columns", label = "columns" } }
end

-- Builds the list of context-menu actions the sidebar offers for a
-- discovered table/view `row` (e.g. right-clicking it in the tree).
-- Parameters:
--   options - profile options, used for default catalog/schema fallback.
--   row     - the table/view metadata row (name, schema, catalog, type).
--   limit   - the row limit to bake into the generated "sample" SELECT.
-- Returns: a list of action tables, each describing an id/kind/label and
-- either a `statement` to run or open, or `nil, "error message"` if the
-- object's schema can't be determined.
function M.object_actions(options, row, limit)
  local schema = row.schema or options.schema
  if not schema or schema == "" then
    return nil, "schema is required for Trino schema object actions"
  end
  local qualified = table.concat({ identifier(row.catalog or options.catalog), identifier(schema), identifier(row.name) }, ".")
  -- A discovered object may live outside the configured default catalog or schema.
  local columns = assert(M.schema_statement(options, {
    type = "columns",
    name = row.name,
    schema = schema,
    catalog = row.catalog,
  }))
  return {
    {
      id = "sample",
      kind = "query_buffer",
      label = "Open sample statement",
      statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", qualified, limit),
    },
    {
      id = "columns",
      kind = "statement",
      label = "Columns",
      statement = columns,
    },
  }
end

return M
