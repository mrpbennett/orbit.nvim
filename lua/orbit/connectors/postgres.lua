-- ============================================================================
-- PostgreSQL connector
-- ============================================================================
-- This module is orbit.nvim's PostgreSQL "connector": one of several backend
-- adapters (see the sibling files in lua/orbit/connectors/, e.g. sqlite.lua
-- and trino.lua) that the rest of the plugin talks to through a common,
-- implicit interface. Orbit's core (the query runner, the workspace/schema
-- browser sidebar, and the results grid) doesn't know anything about
-- Postgres-specific SQL or command-line flags; it just calls functions like
-- `prepare`, `session_command`, `schema_statement`, `parse`, etc. on whichever
-- connector module matches the active connection profile, and this file
-- supplies the Postgres-flavoured implementations of those functions.
--
-- How it actually talks to Postgres: this connector does NOT use a Lua
-- Postgres wire-protocol library and does NOT use libpq via FFI. Instead it
-- shells out to the `psql` command-line client (see M.prepare and
-- M.session_command below), asking it to emit results as CSV
-- (`--csv --no-psqlrc --pset footer=off`) so the output is easy to parse back
-- into rows/columns in M.parse. Credentials are passed via environment
-- variables (M.environment), not command-line arguments, so they don't leak
-- into process listings (e.g. `ps aux`).
--
-- The connector interface implemented here, roughly:
--   * M.validate_options      - sanity-check a connection profile's options
--   * M.prepare               - build a one-shot `psql` argv for a single statement
--   * M.session_command       - build a `psql` argv for a long-lived interactive session
--   * M.session_request       - wrap a statement for that persistent session
--   * M.session_output        - pull one statement's output out of the session's stream
--   * M.environment           - environment variables (e.g. PGPASSWORD) for the psql process
--   * M.schema_statement      - SQL to list schemas/tables/columns/keys/indexes
--   * M.qualified_name / M.completion_word - identifier formatting helpers
--   * M.metadata_categories / M.object_actions - sidebar UI metadata for a database object
--   * M.editable_table / M.mutation_statement  - support for editing grid results in place
--   * M.parse                 - turn psql's CSV output into Lua row tables
--
-- What this module returns/exports: a single table `M` containing all of the
-- above functions. There is no per-connection object/instance here; every
-- function takes whatever `options` (the profile's connector-specific config)
-- or `statement`/`row`/`node` data it needs as plain arguments, so the module
-- itself is stateless.
-- ============================================================================

local M = {}

-- Appends every item in `values` onto the end of `arguments`, in order.
-- Used throughout this file to build up psql command-line argument lists
-- (Lua's `table.insert` only adds one item at a time, so this is a small
-- convenience wrapper around a loop of those).
-- Side effects: mutates `arguments` in place; returns nothing.
local function append(arguments, values)
  for _, value in ipairs(values) do
    table.insert(arguments, value)
  end
end

-- Formats a Lua value as a single-quoted SQL string literal, e.g. for use in
-- a WHERE clause or INSERT statement. Doubles any embedded single quotes
-- ('' is how Postgres escapes a literal quote inside a string), which is the
-- standard SQL escaping rule for string literals.
-- Params: value - any Lua value; it is stringified with tostring() first.
-- Returns: a string like "'it''s a test'" including the surrounding quotes.
local function literal(value)
  -- SQL literals and identifiers are different syntactic domains.
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

-- Formats a Lua value as a double-quoted SQL identifier (table/column/schema
-- name), e.g. "My Table". Doubles any embedded double quotes, which is how
-- Postgres escapes a literal quote inside a quoted identifier. Quoting
-- identifiers protects against reserved words and mixed-case/special-
-- character names being misinterpreted by the server.
-- Params: value - any Lua value; stringified first.
-- Returns: a string like '"My Table"' including the surrounding quotes.
local function identifier(value)
  return '"' .. tostring(value):gsub('"', '""') .. '"'
end

-- Builds a fully-qualified, properly quoted "schema"."table" reference for a
-- database object. Falls back to the "public" schema (Postgres's default
-- schema) when the row doesn't specify one.
-- Params: row - a table describing a database object; only row.schema and
--   row.name are used here.
-- Returns: a string such as '"public"."users"'.
local function qualified(row)
  return table.concat({ identifier(row.schema or "public"), identifier(row.name) }, ".")
end

local schema_pattern = require("orbit.connectors.schema_pattern")

-- Builds an "AND (table_schema IN (...) OR table_schema LIKE ...)" SQL
-- fragment to restrict schema listing queries to a configured allow-list of
-- schemas (the `schema_patterns` profile option). Entries may be exact
-- schema names or `*`/`?` glob patterns (see schema_pattern.lua).
-- Params: schemas - a Lua array of schema name/pattern strings, or nil.
-- Returns: the SQL fragment string, or nil if `schemas` is nil (meaning "no
--   filter, show every schema").
local function schema_filter(schemas)
  local clause = schema_pattern.sql_clause("table_schema", schemas)
  return clause and ("AND " .. clause) or nil
end

-- Validates the `options` table of a connection profile that uses this
-- Postgres connector, before any connection is attempted. This catches typos
-- and type mistakes in the user's config early, with a clear error message,
-- rather than letting them surface later as a confusing psql failure.
-- Params:
--   profile_name - string name of the profile, used only for error messages.
--   options - the connector-specific config table from the profile (things
--     like host, port, database, user, password, etc).
-- Returns: on success, `true`. On failure, `nil, error_message` (the
--   classic Lua "nil plus error string" convention used throughout this
--   file for functions that can fail).
-- Side effects: none (pure validation, no I/O).
function M.validate_options(profile_name, options)
  local allowed = {
    arguments = true,
    confirm_mutations = true,
    database = true,
    executable = true,
    host = true,
    password = true,
    port = true,
    sslmode = true,
    schema_patterns = true,
    user = true,
  }
  -- Reject any option key we don't recognize, so a misspelled option (e.g.
  -- `hosts` instead of `host`) fails loudly instead of being silently ignored.
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported PostgreSQL option %q", profile_name, name)
    end
  end
  -- These options are passed straight to psql/environment variables, so they
  -- must be strings (not e.g. numbers or tables) or the command build below
  -- would produce nonsense arguments.
  for _, name in ipairs({ "host", "password", "sslmode", "user" }) do
    if options[name] ~= nil and type(options[name]) ~= "string" then
      return nil, string.format("profile %q options.%s must be a string", profile_name, name)
    end
  end
  -- Port must be a whole number within the valid TCP port range.
  if options.port ~= nil and (type(options.port) ~= "number" or options.port % 1 ~= 0 or options.port < 1 or options.port > 65535) then
    return nil, string.format("profile %q options.port must be an integer between 1 and 65535", profile_name)
  end
  return true
end

-- Builds the argv (list of command-line arguments) used to run a single SQL
-- `statement` as a one-shot `psql` invocation. This is what the query runner
-- uses for ordinary "run this query" requests: it spawns the process built
-- here, lets it run to completion, and reads its stdout.
-- Params:
--   options - the profile's connector options (executable, database, host,
--     port, user, extra arguments, ...).
--   statement - the raw SQL text to execute.
-- Returns: a Lua array of strings suitable for passing to vim.fn.jobstart /
--   vim.system as the command, e.g. { "psql", "--dbname", "mydb", ... }.
-- Side effects: none itself (it just builds a table); the caller is
--   responsible for actually spawning the process.
function M.prepare(options, statement)
  local command = { options.executable or "psql" }
  append(command, options.arguments or {})
  append(command, { "--dbname", options.database })
  if options.host then
    append(command, { "--host", options.host })
  end
  if options.port then
    append(command, { "--port", tostring(options.port) })
  end
  if options.user then
    append(command, { "--username", options.user })
  end
  append(command, {
    "--csv", -- ask psql to format query results as CSV, which M.parse expects
    "--no-psqlrc", -- don't load the user's ~/.psqlrc, so behaviour is predictable
    "--pset", "footer=off", -- suppress the "(N rows)" footer line psql normally prints
    "--set", "ON_ERROR_STOP=on", -- abort immediately on the first SQL error (one-shot run)
    "--command", statement,
  })
  return command
end

-- Returns the fully-qualified, quoted "schema"."name" form of a database
-- object row. Part of the connector interface used by the schema browser to
-- display/insert a canonical reference to a table, view, etc.
-- Params: first argument (unused, `_`) is the options table, kept only so
--   the function signature matches other connectors; row - object metadata
--   with .schema and .name.
-- Returns: a string like '"public"."users"'.
function M.qualified_name(_, row)
  return qualified(row)
end

-- Returns the text that should be inserted into the buffer when the user
-- accepts a completion suggestion for this database object. For Postgres
-- that's the same fully-qualified quoted name as M.qualified_name.
-- Params: _ (options, unused), row - object metadata with .schema and .name.
-- Returns: a string like '"public"."users"'.
function M.completion_word(_, row)
  return qualified(row)
end

-- Builds the argv for a long-lived, interactive `psql` process (as opposed
-- to M.prepare's one-shot invocation). Orbit keeps one of these processes
-- running per connection so that multiple statements can share a session
-- (e.g. for transactions, session state, or just to avoid the cost of
-- reconnecting for every query) — see M.session_request/M.session_output for
-- how individual statements are sent to and read back from this session.
-- Params: options - the profile's connector options.
-- Returns: a Lua array of strings, the command to spawn.
-- Side effects: none itself; only builds the argument list.
function M.session_command(options)
  local command = { options.executable or "psql" }
  append(command, options.arguments or {})
  append(command, { "--dbname", options.database })
  if options.host then
    append(command, { "--host", options.host })
  end
  if options.port then
    append(command, { "--port", tostring(options.port) })
  end
  if options.user then
    append(command, { "--username", options.user })
  end
  append(command, {
    "--csv",
    "--no-psqlrc",
    "--pset", "footer=off",
    -- A persistent process must survive statement errors so they reach the owning request.
    "--set", "ON_ERROR_STOP=off",
  })
  return command
end

local mutation_sql = require("orbit.connectors.mutation_sql")

-- Decides whether a result row from a query can be edited in the results
-- grid; see mutation_sql.editable_table for the shared logic (identical
-- across every connector that supports editable results).
M.editable_table = function(_, row, primary_keys)
  return mutation_sql.editable_table(row, primary_keys)
end

-- Turns a set of edits made in the results grid (rows deleted, modified, or
-- newly inserted) into a single SQL script that applies all of them
-- atomically. This is the write-back half of the "edit results in a grid
-- like a spreadsheet" feature: `M.editable_table` decides a result *can* be
-- edited, and this function generates the actual DELETE/UPDATE/INSERT
-- statements once the user has made changes and asked to save them. See
-- mutation_sql.build for the shared generation logic; postgres supplies its
-- own quoting functions, its schema-qualified table name, and a plain
-- "BEGIN" (Postgres doesn't need SQLite's write-lock-eagerly variant).
function M.mutation_statement(_, target, changes)
  return mutation_sql.build(qualified(target), identifier, literal, "BEGIN", target.primary_keys, changes)
end

-- Wraps a SQL statement for sending to the persistent psql session (started
-- with M.session_command). Because that session's stdout is one continuous
-- stream shared by every request that goes through it, we need a way to
-- tell where *this* statement's output ends and the next one's begins.
-- The trick: immediately after the real statement, run an extra
-- `SELECT '<marker>' AS __orbit_marker` query. When that marker row shows up
-- in the output, we know everything before it belongs to this request.
-- Params:
--   statement - the SQL text the caller actually wants to run.
--   marker - a unique string (generated per-request by the caller) used as
--     the sentinel value.
-- Returns: the combined SQL text to send to the session, ending in the
--   sentinel SELECT.
function M.session_request(statement, marker)
  -- The sentinel row delimits this request's CSV output in the shared psql stream.
  return statement .. ";\nSELECT '" .. marker .. "' AS __orbit_marker;\n"
end

-- Given the psql session's accumulated output so far and the `marker` used
-- in M.session_request, extracts just the portion of output that belongs to
-- this request (i.e. everything before the sentinel row), if the sentinel
-- has appeared yet.
-- Params:
--   output - the full text captured from the session's stdout so far
--     (may include output from this request plus the sentinel row, and
--     possibly nothing yet if the query is still running).
--   marker - the same unique sentinel string passed to M.session_request.
-- Returns: the output text belonging to this request (everything before the
--   sentinel), or nil if the sentinel hasn't appeared in `output` yet
--   (meaning: keep waiting, the statement hasn't finished).
function M.session_output(output, marker)
  local marker_at = output:find(marker, 1, true)
  if not marker_at then
    return nil
  end
  -- Walk backwards from the marker to find where the "__orbit_marker"
  -- column header (from the sentinel SELECT's CSV output) begins, so we can
  -- cut it and everything after it off, leaving only the real result.
  local start = output:sub(1, marker_at):match(".*()__orbit_marker")
  if not start then
    return nil
  end
  return output:sub(1, start - 1)
end

-- Builds the environment variables to set on the spawned psql process.
-- Params: options - the profile's connector options.
-- Returns: a table of environment variable name -> value, suitable for
--   passing as the `env` field to vim.system/jobstart.
function M.environment(options)
  local environment = {}
  if options.password then
    -- Keep credentials out of argv, where process listings could expose them.
    environment.PGPASSWORD = options.password
  end
  if options.sslmode then
    environment.PGSSLMODE = options.sslmode
  end
  return environment
end

-- Generates the SQL used to populate the workspace/schema sidebar: listing
-- tables and views, or listing metadata (columns/primary keys/foreign
-- keys/indexes) about one specific table/view. `node` describes what the
-- sidebar is currently asking for/expanding.
-- Params:
--   options - the profile's connector options; only options.schema_patterns
--     is used here (to filter which schemas are listed), and only for the
--     "tables" node type. NOTE: callers that only ever request node types
--     other than "tables" (see M.object_actions below) may safely pass nil
--     for `options`, since those branches never touch it.
--   node - a table describing what to list; node.type is one of "tables",
--     "columns", "primary_keys", "foreign_keys", or "indexes", and (for
--     everything except "tables") node.name/node.schema identify which
--     table/view to inspect.
-- Returns: on success, a single SQL SELECT statement (a string) that would
--   produce the requested listing. On an unrecognized node type, returns
--   `nil, "unsupported schema node"`.
-- Side effects: none (pure string-building; doesn't run anything itself).
function M.schema_statement(options, node)
  if node.type == "tables" then
    local clauses = {
      "SELECT table_schema AS schema, table_name AS name,",
      "CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS type",
      "FROM information_schema.tables",
      -- information_schema and pg_* are Postgres's own internal/system
      -- schemas; users almost never want to browse those in the sidebar.
      "WHERE table_schema <> 'information_schema' AND table_schema NOT LIKE 'pg_%'",
      "AND table_type IN ('BASE TABLE', 'VIEW')",
    }
    local filter = schema_filter(options.schema_patterns)
    if filter then
      table.insert(clauses, filter)
    end
    table.insert(clauses, "ORDER BY table_schema, table_name")
    return table.concat(clauses, " ")
  end
  if node.type == "columns" and node.name then
    -- Lists column name and declared data type for one table/view.
    return table.concat({
      "SELECT column_name AS name, data_type AS type",
      "FROM information_schema.columns",
      "WHERE table_schema = " .. literal(node.schema or "public"),
      "AND table_name = " .. literal(node.name),
      "ORDER BY ordinal_position",
    }, " ")
  end
  if node.type == "primary_keys" and node.name then
    -- Joins the constraint metadata tables to list which columns make up
    -- this table's primary key, in their declared order (ordinal_position).
    return table.concat({
      "SELECT kcu.column_name AS name, kcu.ordinal_position AS pk, tc.constraint_name",
      "FROM information_schema.table_constraints tc",
      "JOIN information_schema.key_column_usage kcu",
      "ON tc.constraint_name = kcu.constraint_name",
      "AND tc.table_schema = kcu.table_schema AND tc.table_name = kcu.table_name",
      "WHERE tc.constraint_type = 'PRIMARY KEY'",
      "AND tc.table_schema = " .. literal(node.schema or "public"),
      "AND tc.table_name = " .. literal(node.name),
      "ORDER BY kcu.ordinal_position",
    }, " ")
  end
  if node.type == "foreign_keys" and node.name then
    -- Lists this table's foreign key constraints. Uses Postgres's low-level
    -- catalog tables (pg_constraint/pg_class/pg_attribute) rather than
    -- information_schema because those catalogs directly expose the
    -- constraint's raw column-number arrays (conkey/confkey), which we need
    -- to correctly pair up multi-column ("composite") foreign keys.
    -- WITH ORDINALITY pairs composite source and target key columns by position.
    return table.concat({
      "SELECT constraint_row.conname AS id, source_column.attname AS \"from\",",
      "target_table.relname AS \"table\", target_column.attname AS \"to\"",
      "FROM pg_constraint constraint_row",
      "JOIN pg_class source_table ON source_table.oid = constraint_row.conrelid",
      "JOIN pg_namespace source_schema ON source_schema.oid = source_table.relnamespace",
      "JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY",
      "AS source_key(attnum, position) ON true",
      "JOIN pg_attribute source_column",
      "ON source_column.attrelid = source_table.oid AND source_column.attnum = source_key.attnum",
      "JOIN pg_class target_table ON target_table.oid = constraint_row.confrelid",
      "JOIN LATERAL unnest(constraint_row.confkey) WITH ORDINALITY",
      "AS target_key(attnum, position) ON target_key.position = source_key.position",
      "JOIN pg_attribute target_column",
      "ON target_column.attrelid = target_table.oid AND target_column.attnum = target_key.attnum",
      "WHERE constraint_row.contype = 'f'",
      "AND source_schema.nspname = " .. literal(node.schema or "public"),
      "AND source_table.relname = " .. literal(node.name),
      "ORDER BY constraint_row.conname, source_key.position",
    }, " ")
  end
  if node.type == "indexes" and node.name then
    -- Lists this table's indexes and their full DDL definitions (as
    -- returned by pg_indexes.indexdef, e.g. "CREATE INDEX ... ON ... (...)").
    return table.concat({
      "SELECT indexname AS name, indexdef AS definition",
      "FROM pg_indexes",
      "WHERE schemaname = " .. literal(node.schema or "public"),
      "AND tablename = " .. literal(node.name),
      "ORDER BY indexname",
    }, " ")
  end
  return nil, "unsupported schema node"
end

-- Tells the sidebar which metadata categories to show as expandable
-- sub-nodes under a given database object (table/view). Every object gets a
-- "columns" category; only actual tables (not views) additionally get
-- primary keys, foreign keys, and indexes categories, since those concepts
-- don't apply to views.
-- Params: _ (options, unused), row - object metadata (row.type is "table"
--   or "view", etc).
-- Returns: a Lua array of { id, label } tables describing the categories,
--   in display order. The `id` values line up with the node.type values
--   handled by M.schema_statement.
function M.metadata_categories(_, row)
  local categories = { { id = "columns", label = "columns" } }
  if row.type == "table" then
    table.insert(categories, { id = "primary_keys", label = "primary keys" })
    table.insert(categories, { id = "foreign_keys", label = "foreign keys" })
    table.insert(categories, { id = "indexes", label = "indexes" })
  end
  return categories
end

-- Builds the list of quick actions offered for a database object in the
-- sidebar (e.g. right-click / context menu entries), such as opening a
-- ready-made "SELECT * ... LIMIT n" query buffer, or running a statement
-- that shows the object's columns/keys/indexes/definition.
-- Params:
--   _ - options (unused).
--   row - object metadata (row.type, row.name, row.schema).
--   limit - the row limit to bake into the generated sample SELECT
--     statement (so opening a huge table doesn't try to fetch everything).
-- Returns: a Lua array of action descriptor tables, each with .id, .kind
--   ("query_buffer" opens an editable buffer with the statement; "statement"
--   presumably runs it directly), .label, and .statement (the SQL text).
-- Side effects: none (pure data-building); note it calls M.schema_statement
--   with `nil` for options, which is safe here because the node types used
--   (columns/primary_keys/foreign_keys/indexes) never read from `options`.
function M.object_actions(_, row, limit)
  local actions = {
    {
      id = "sample",
      kind = "query_buffer",
      label = "Open sample statement",
      statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", qualified(row), limit),
    },
    {
      id = "columns",
      kind = "statement",
      label = "Columns",
      statement = assert(M.schema_statement(nil, { type = "columns", name = row.name, schema = row.schema })),
    },
  }
  if row.type == "table" then
    for _, category in ipairs({ "primary_keys", "foreign_keys", "indexes" }) do
      table.insert(actions, {
        id = category,
        kind = "statement",
        label = category:gsub("_", " "):gsub("^%l", string.upper),
        statement = assert(M.schema_statement(nil, { type = category, name = row.name, schema = row.schema })),
      })
    end
  else
    table.insert(actions, {
      id = "definition",
      kind = "statement",
      label = "Definition",
      statement = "SELECT pg_get_viewdef(" .. literal(qualified(row)) .. "::regclass, true) AS definition;",
    })
  end
  return actions
end

-- Parses the raw text captured from a `psql --csv` invocation (see
-- M.prepare/M.session_command) into an array of Lua row tables, keyed by
-- column name. This is the last step of the round trip: SQL text goes out
-- through M.prepare, comes back as CSV text on stdout, and this function
-- turns that CSV text into the row data the results grid actually displays.
--
-- This is a small hand-written character-by-character CSV parser (not a
-- regex or a library) because CSV quoting rules aren't regular: a quoted
-- field can contain commas, newlines, and escaped quotes ("" means a
-- literal "), so a simple string.gmatch split on "," or "\n" would corrupt
-- data any time a cell contains one of those characters. Walking the string
-- one character at a time and tracking "am I currently inside a quoted
-- field?" as a piece of state is a minimal example of what's usually called
-- a state machine: fixed byte, fixed transition rules.
--
-- Params: output - the full CSV text (header row + data rows) from psql.
-- Returns: a Lua array of row tables. Each row table maps column name
--   (from the CSV header row) to that cell's value, which is either a Lua
--   string, or the special `vim.NIL` sentinel representing a SQL NULL.
-- Side effects: none (pure parsing).
function M.parse(output)
  -- Preserve quoted empty strings separately from unquoted SQL NULL fields in psql's CSV output.
  local records, record, field = {}, {}, {}
  -- `quoted` remembers whether the field we're currently building started
  -- with a '"' (so `""`, a quoted empty string, can later be told apart
  -- from a genuinely empty/NULL field). `in_quotes` is the state-machine
  -- flag: true while we're scanning characters that are "inside" an open
  -- pair of quotes, where commas/newlines are just literal characters
  -- rather than field/record separators.
  local quoted, in_quotes, index = false, false, 1

  -- Closes off the field currently being built: records its accumulated
  -- text plus whether it was quoted, then resets the buffers so the next
  -- field starts fresh.
  local function finish_field()
    table.insert(record, { value = table.concat(field), quoted = quoted })
    field, quoted = {}, false
  end
  -- Closes off the current field (there's always at least one, even on an
  -- empty line) and then the current record (row of fields), appending it
  -- to `records` and starting a new one.
  local function finish_record()
    finish_field()
    table.insert(records, record)
    record = {}
  end

  while index <= #output do
    local character = output:sub(index, index)
    if in_quotes then
      -- Inside a quoted field: a doubled quote ("") is CSV's escape
      -- sequence for a single literal quote character in the data, so we
      -- emit one '"' and skip both characters. A lone quote closes the
      -- field's quoted section (note we stay "inside" the field itself
      -- until a comma/newline is seen next — a field could in theory have
      -- trailing unquoted characters after the closing quote, though psql
      -- itself doesn't produce that).
      if character == '"' and output:sub(index + 1, index + 1) == '"' then
        table.insert(field, '"')
        index = index + 1
      elseif character == '"' then
        in_quotes = false
      else
        -- Any other character, including a literal comma or newline, is
        -- just data while inside quotes.
        table.insert(field, character)
      end
    elseif character == '"' and #field == 0 then
      -- A quote at the very start of a field (nothing accumulated yet)
      -- begins a quoted field. Note this deliberately doesn't trigger for a
      -- quote appearing after other characters, since psql's CSV output
      -- only ever quotes a field from its first character.
      quoted, in_quotes = true, true
    elseif character == "," then
      finish_field()
    elseif character == "\n" then
      finish_record()
    elseif character ~= "\r" then
      -- Skip bare "\r" (part of Windows-style "\r\n" line endings) so it
      -- doesn't get treated as data; everything else is ordinary field text.
      table.insert(field, character)
    end
    index = index + 1
  end
  -- The loop above only finishes a field/record when it sees a delimiter;
  -- the very last field/record in the input has no trailing comma/newline
  -- to trigger that, so it must be flushed manually here. The three-part
  -- check (leftover text, a quoted-but-empty field, or a record that
  -- already has some fields) covers "there's still something pending."
  if #field > 0 or quoted or #record > 0 then
    finish_record()
  end
  if #records == 0 then
    return {}
  end

  -- The first record is the CSV header row (column names); every
  -- subsequent record is a data row. Build one Lua table per data row,
  -- keyed by the corresponding header's text.
  local headers, rows = records[1], {}
  for record_index = 2, #records do
    local row = {}
    for column_index, header in ipairs(headers) do
      local field_value = records[record_index][column_index] or {}
      -- Postgres/psql's CSV output can't otherwise distinguish an empty
      -- string value ('') from a SQL NULL, because both would just render
      -- as an empty cell — UNLESS the value was quoted, which only happens
      -- for a real empty string, never for NULL. So: an empty, *unquoted*
      -- field means NULL (mapped to vim.NIL); an empty, *quoted* field
      -- means a genuine empty string.
      row[header.value] = field_value.value == "" and not field_value.quoted and vim.NIL or field_value.value or ""
    end
    table.insert(rows, row)
  end
  return rows
end

return M
