-- SQLite connector.
--
-- Like the other modules under lua/orbit/connectors/, this is a "connector":
-- a table of functions that plugs one specific database backend into the
-- rest of Orbit (see lua/orbit/adapters.lua for the registry, and
-- lua/orbit/runner.lua / lua/orbit/session.lua for how these functions get
-- called). Orbit never links against SQLite's C library or an FFI binding -
-- it shells out to the external `sqlite3` command-line binary and parses the
-- `-json` output it prints. That keeps the plugin free of any compiled
-- dependency, at the cost of requiring the `sqlite3` CLI to be installed and
-- on the user's PATH.
--
-- Contract implemented here (see trino.lua's header comment for the full
-- list of hooks a connector may provide - this module implements a larger
-- subset than trino.lua because SQLite supports persistent sessions and
-- editable query results):
--   * validate_options   - checks the profile's options table is well-formed.
--   * prepare             - builds argv for a one-shot `sqlite3` invocation.
--   * qualified_name / completion_word / schema_of - naming helpers used by
--     the sidebar and SQL completion engine.
--   * session_command     - builds argv for a *persistent* `sqlite3` process
--     that lua/orbit/session.lua keeps running and feeds multiple statements
--     to over its stdin, rather than starting a new process per statement.
--     This matters for SQLite specifically because a transaction (BEGIN ...
--     COMMIT) only makes sense if the follow-up statements run in the same
--     process/connection - a one-shot process per statement would silently
--     lose the transaction.
--   * session_request / session_output - encode a statement for that shared
--     stdin stream, and cut this request's slice of output back out of the
--     stream once it appears (see below for how the sentinel marker works).
--   * editable_table / mutation_statement - support for editing rows in the
--     results grid: decide whether a query result maps back to an editable
--     table, and translate the user's row edits into DELETE/UPDATE/INSERT
--     statements.
--   * schema_statement    - SQL (or PRAGMA) to run to discover tables,
--     columns, primary keys, foreign keys, or indexes, called by
--     lua/orbit/schema_cache.lua.
--   * metadata_categories / object_actions - tell the sidebar UI what detail
--     categories and context-menu actions are available for a table/view.
--
-- Not implemented here: `environment` (SQLite needs no extra environment
-- variables/credentials the way postgres.lua sets PGPASSWORD, since a
-- SQLite "connection" is just a local file path).
local M = {}

-- Appends every item of `values` onto the end of `arguments`, in place.
-- Small helper for building up CLI argument lists piece by piece.
-- Side effect: mutates `arguments`.
local function append(arguments, values)
  for _, value in ipairs(values) do
    table.insert(arguments, value)
  end
end

-- Formats a Lua value as a single-quoted SQL *string literal*, doubling any
-- embedded single quotes (the standard SQL escaping rule). Use this for
-- values, not names - e.g. the string argument to PRAGMA table_info(...).
local function literal(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

-- Formats a Lua value as a double-quoted SQL *identifier* (table/column
-- name), doubling any embedded double quotes. Use this for names that need
-- to appear as SQL identifiers, e.g. in generated UPDATE/INSERT statements,
-- so that unusual table/column names (spaces, reserved words) still work.
local function identifier(value)
  return '"' .. tostring(value):gsub('"', '""') .. '"'
end

-- Checks a connection profile's `options` table only contains keys this
-- SQLite connector understands. Runs once when a profile is loaded/edited,
-- before any query is attempted, to catch typos/misconfiguration early.
-- Parameters: profile_name (for error messages), options (user config table).
-- Returns: `true` on success, or `nil, "error message"` on failure.
function M.validate_options(profile_name, options)
  local allowed = {
    arguments = true,
    confirm_mutations = true,
    executable = true,
    path = true,
    schema_patterns = true,
  }
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported SQLite option %q", profile_name, name)
    end
  end
  return true
end

-- Builds the argv for running one `statement` through the `sqlite3` CLI as a
-- brand new, one-shot subprocess (used for plain/non-transactional queries;
-- see `session_command` below for the persistent-process alternative used
-- when a request needs to share a transaction with others).
-- Parameters: options (executable override, extra CLI arguments, database
-- file `path`), statement (the raw SQL text to run).
-- Returns: an argv array, e.g. { "sqlite3", "-json", "/path/to.db", "SELECT ..." }.
-- `-json` makes the CLI print query results as a JSON array of row objects,
-- which lua/orbit/adapters.lua's generic JSON parser then decodes (this
-- module defines no M.parse of its own).
function M.prepare(options, statement)
  local command = { options.executable or "sqlite3" }
  append(command, options.arguments or {})
  append(command, { "-json", options.path, statement })
  return command
end

-- Renders a schema object's fully-qualified name for use in generated SQL.
-- SQLite has no real multi-schema/multi-catalog concept (a "database" is
-- just one file), so this ignores row.schema/row.catalog and simply quotes
-- the table/view name as an identifier.
-- Returns: a string like `"my_table"`.
function M.qualified_name(_, row)
  return identifier(row.name)
end

-- Decides what text to insert into the SQL buffer when a completion
-- suggestion for `row` is accepted. `prefix` is whatever qualifier text the
-- user already typed before the cursor; it's echoed back unchanged since
-- SQLite objects aren't schema-qualified the way Postgres/Trino ones are.
-- Returns: the text to insert (prefix .. row.name).
function M.completion_word(_, row, prefix)
  return prefix .. row.name
end

-- SQLite has no schema/catalog qualifiers to parse out of a completion
-- prefix (there is effectively only one implicit "main" schema), so this
-- always returns nil - there is nothing to report as "the schema being
-- typed into".
function M.schema_of()
  return nil
end

-- Builds the argv for a *long-lived* `sqlite3` process that
-- lua/orbit/session.lua starts once per profile and keeps feeding
-- statements to via stdin (see session_request/session_output below, and
-- lua/orbit/session.lua for the queueing/marker-matching logic that manages
-- this shared process). Using one persistent process (instead of `prepare`'s
-- one-shot process per statement) is what lets a multi-statement transaction
-- (BEGIN ... COMMIT, built by mutation_statement) actually take effect
-- against the same open database connection.
-- Parameters: options (executable override, extra CLI arguments, database
-- file `path`).
-- Returns: an argv array for the persistent process.
function M.session_command(options)
  local command = { options.executable or "sqlite3" }
  append(command, options.arguments or {})
  -- Abort the CLI on SQL errors so an uncommitted transaction rolls back on disconnect.
  append(command, { "-bail", "-json", options.path })
  return command
end

-- Decides whether a row from a query result can be edited (i.e. the results
-- grid UI lets the user change/delete/insert rows and have those changes
-- written back to the database). Editing is only possible when we know
-- which real database table the row came from *and* have a primary key to
-- uniquely identify that row again later.
-- Parameters:
--   row          - metadata describing the schema object the result came
--                  from (must be a "table", not a view, computed result, etc).
--   primary_keys - list of column names making up the primary key, as
--                  discovered separately via the "primary_keys" schema_statement.
-- Returns: a small "target" table { name, schema, primary_keys } describing
-- what to write mutations against, or `nil, "error message"` if the result
-- isn't editable (e.g. it's a view, or the table has no primary key).
function M.editable_table(_, row, primary_keys)
  if row.type ~= "table" or #primary_keys == 0 then
    return nil, "Result is read-only: unable to determine a unique database row."
  end
  return { name = row.name, schema = row.schema, primary_keys = primary_keys }
end

-- Translates the results grid's pending row edits into one SQL script
-- (wrapped in a transaction) that applies them to the real database table.
-- This is what actually persists edits a user makes in the query results UI
-- back to SQLite.
-- Parameters:
--   target  - the editable-table descriptor returned by editable_table
--             above (table name/schema + primary key column names).
--   changes - a table with three lists describing what the user changed:
--     .deleted  - rows the user deleted (only original values needed, to
--                 build the WHERE clause matching them by primary key).
--     .modified - rows the user edited: `.values` (all current column
--                 values) and `.original` (the values as loaded, used to
--                 detect which columns actually changed and to build the
--                 WHERE clause).
--     .inserted - brand new rows the user added, keyed by column name.
-- Returns: a single string containing "BEGIN IMMEDIATE; ...; COMMIT;" (all
-- statements needed to apply every change), or `nil, "error message"` if a
-- change can't be expressed safely (e.g. editing a primary key column, or a
-- delete/update whose row no longer has a known primary key value).
-- No side effects itself - it only builds SQL text; running it against the
-- persistent session process happens elsewhere (lua/orbit/session.lua).
function M.mutation_statement(_, target, changes)
  local name = identifier(target.name)
  local primary_keys = target.primary_keys
  -- vim.NIL is Neovim's stand-in for a real SQL NULL (Lua's own `nil` can't
  -- be stored in a table value), so it must be translated to the literal
  -- SQL keyword NULL rather than being treated as a normal string value.
  local function value_sql(value)
    return value == vim.NIL and "NULL" or literal(value)
  end
  -- BEGIN IMMEDIATE (rather than plain BEGIN) grabs SQLite's write lock
  -- right away, so this whole batch of deletes/updates/inserts is applied
  -- atomically and fails fast if another writer is already using the file.
  local statements = { "BEGIN IMMEDIATE" }
  for _, row in ipairs(changes.deleted) do
    local conditions = {}
    for _, column in ipairs(primary_keys) do
      local value = row.original[column]
      if value == nil or value == vim.NIL then
        return nil, "Cannot delete a row with a NULL primary key."
      end
      conditions[#conditions + 1] = identifier(column) .. " = " .. value_sql(value)
    end
    statements[#statements + 1] = "DELETE FROM " .. name .. " WHERE " .. table.concat(conditions, " AND ")
  end
  for _, row in ipairs(changes.modified) do
    local assignments, conditions = {}, {}
    for column, value in pairs(row.values) do
      -- Only emit SET clauses for columns that actually changed - comparing
      -- the current value against the originally-loaded value avoids
      -- rewriting every column on every edited row.
      if not vim.deep_equal(value, row.original[column]) then
        for _, primary_key in ipairs(primary_keys) do
          if column == primary_key then
            return nil, "Editing primary key values is not supported."
          end
        end
        assignments[#assignments + 1] = identifier(column) .. " = " .. value_sql(value)
      end
    end
    for _, column in ipairs(primary_keys) do
      local value = row.original[column]
      if value == nil or value == vim.NIL then
        return nil, "Cannot update a row with a NULL primary key."
      end
      conditions[#conditions + 1] = identifier(column) .. " = " .. value_sql(value)
    end
    if #assignments > 0 then
      statements[#statements + 1] = "UPDATE " .. name .. " SET " .. table.concat(assignments, ", ") .. " WHERE " .. table.concat(conditions, " AND ")
    end
  end
  for _, row in ipairs(changes.inserted) do
    local columns, values = {}, {}
    -- Skip columns the user left as `nil` (as opposed to explicitly setting
    -- them to SQL NULL via vim.NIL) so the database applies its own default
    -- value/DEFAULT clause for anything untouched.
    for column, value in pairs(row.values) do
      if value ~= nil then
        columns[#columns + 1] = identifier(column)
        values[#values + 1] = value_sql(value)
      end
    end
    -- Sorting gives a deterministic column order (Lua's `pairs` iteration
    -- order over row.values is otherwise unspecified), which matters
    -- because `columns` and `ordered_values` below must line up positionally.
    table.sort(columns)
    if #columns == 0 then
      statements[#statements + 1] = "INSERT INTO " .. name .. " DEFAULT VALUES"
    else
      local ordered_values = {}
      for _, column in ipairs(columns) do
        -- `columns` entries are already-quoted identifiers (e.g. `"col""name"`),
        -- but row.values is keyed by the original unquoted column name, so
        -- each entry must be unquoted again here to look its value back up.
        local raw = column:sub(2, -2):gsub('""', '"')
        ordered_values[#ordered_values + 1] = value_sql(row.values[raw])
      end
      statements[#statements + 1] = "INSERT INTO " .. name .. " (" .. table.concat(columns, ", ") .. ") VALUES (" .. table.concat(ordered_values, ", ") .. ")"
    end
  end
  statements[#statements + 1] = "COMMIT"
  return table.concat(statements, ";\n") .. ";"
end

-- Encodes one SQL `statement` to write to the persistent sqlite3 session's
-- stdin (see session_command above). Because the CLI's stdout is one long,
-- shared stream across many requests, a follow-up SELECT is appended whose
-- sole purpose is printing a unique `marker` string - session_output below
-- watches for that marker to know exactly where this request's JSON output
-- ends before the next request's output begins.
-- Parameters: statement (the SQL to run), marker (a string unique to this
-- request, generated by lua/orbit/session.lua).
-- Returns: the exact bytes to write to the process's stdin.
function M.session_request(statement, marker)
  -- The marker query delimits one JSON response in SQLite's persistent stdout stream.
  return statement .. ";\nSELECT '" .. marker .. "' AS __orbit_marker;\n"
end

-- Given everything the persistent session process has printed to stdout so
-- far (`output`, which keeps growing as more data arrives) and the `marker`
-- for the request currently waiting on a response, tries to extract just
-- this request's JSON result.
-- Returns: the JSON text for this request if the marker has appeared yet
-- (meaning the sqlite3 CLI has finished emitting this statement's rows), or
-- `nil` if the marker hasn't shown up in `output` yet (caller should keep
-- waiting for more stdout data).
function M.session_output(output, marker)
  local marker_at = output:find(marker, 1, true)
  if not marker_at then
    -- Marker hasn't printed yet - this request's output isn't complete.
    return nil
  end
  -- Walk backwards from the marker to the start of the JSON array ("[") that
  -- sqlite3's `-json` mode wraps every result set in, so the returned slice
  -- is exactly the JSON for this statement and excludes the marker query's
  -- own (irrelevant) JSON output.
  local start = output:sub(1, marker_at):match(".*()%[")
  if not start then
    return nil
  end
  return output:sub(1, start - 1)
end

-- Builds the SQL/PRAGMA statement used to discover schema metadata for the
-- sidebar and completion engine. `node.type` selects what's being asked for:
-- "tables" (all tables/views), "columns", "primary_keys", "foreign_keys", or
-- "indexes" for one named table. Called by lua/orbit/schema_cache.lua.
-- Parameters:
--   options - profile options; only `schema_patterns` is consulted here
--             (SQLite has just one implicit "main" schema, so patterns are
--             only used to decide whether to include it at all).
--   node    - the metadata request, e.g. { type = "columns", name = "t" }.
-- Returns: a SQL/PRAGMA string to execute, or `nil, "error message"` for an
-- unrecognized node type.
function M.schema_statement(options, node)
  if node.type == "tables" then
    if options.schema_patterns then
      -- SQLite exposes only main here; filters without it intentionally acquire no rows.
      for _, schema in ipairs(options.schema_patterns) do
        if schema == "main" then
          return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
        end
      end
      return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE 1 = 0"
    end
    return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
  end
  if node.type == "columns" and node.name then
    -- PRAGMA table_info is SQLite's built-in way to describe a table's
    -- columns (name, declared type, whether it's part of the primary key,
    -- etc) - there is no information_schema in SQLite to query instead.
    return "PRAGMA table_info(" .. literal(node.name) .. ")"
  end
  if node.type == "primary_keys" and node.name then
    -- pragma_table_info() is the "table-valued function" form of the same
    -- PRAGMA, usable inside a normal SELECT so it can be filtered/ordered;
    -- `pk > 0` selects only columns that are part of the primary key, and
    -- the value is that column's 1-based position within a composite key.
    return "SELECT name, type, pk FROM pragma_table_info(" .. literal(node.name) .. ") WHERE pk > 0 ORDER BY pk"
  end
  if node.type == "foreign_keys" and node.name then
    return "PRAGMA foreign_key_list(" .. literal(node.name) .. ")"
  end
  if node.type == "indexes" and node.name then
    return "PRAGMA index_list(" .. literal(node.name) .. ")"
  end
  return nil, "unsupported schema node"
end

-- Reports which extra detail "categories" the sidebar UI can offer for a
-- schema object `row`. Every object gets "columns"; only real tables (not
-- views) additionally get primary key, foreign key, and index categories,
-- since those PRAGMAs are meaningful only for tables.
-- Returns: a list of { id = string, label = string } tables.
function M.metadata_categories(_, row)
  local categories = {
    { id = "columns", label = "columns" },
  }
  if row.type == "table" then
    table.insert(categories, { id = "primary_keys", label = "primary keys" })
    table.insert(categories, { id = "foreign_keys", label = "foreign keys" })
    table.insert(categories, { id = "indexes", label = "indexes" })
  end
  return categories
end

-- Builds the list of context-menu actions the sidebar offers for a
-- discovered table/view `row` (right-click/action menu entries).
-- Parameters: row (table/view metadata), limit (row cap baked into the
-- generated sample SELECT).
-- Returns: a list of action tables describing id/kind/label/statement.
-- Unlike trino.lua's version, this always returns every category
-- unconditionally (columns, primary keys, indexes, foreign keys, and a
-- "definition" lookup) rather than checking row.type first - even for a
-- view, the primary_keys/foreign_keys/indexes PRAGMAs are harmless, they
-- simply return no rows.
function M.object_actions(_, row, limit)
  local name = literal(row.name)
  -- PRAGMAs take string literals, while generated sample SQL needs an escaped identifier.
  return {
    {
      id = "sample",
      kind = "query_buffer",
      label = "Open sample statement",
      statement = string.format("SELECT *\nFROM %s\nLIMIT %d;", identifier(row.name), limit),
    },
    {
      id = "columns",
      kind = "statement",
      label = "Columns",
      statement = "PRAGMA table_info(" .. name .. ");",
    },
    {
      id = "primary_keys",
      kind = "statement",
      label = "Primary keys",
      statement = "SELECT name, type, pk FROM pragma_table_info(" .. name .. ") WHERE pk > 0 ORDER BY pk;",
    },
    {
      id = "indexes",
      kind = "statement",
      label = "Indexes",
      statement = "PRAGMA index_list(" .. name .. ");",
    },
    {
      id = "foreign_keys",
      kind = "statement",
      label = "Foreign keys",
      statement = "PRAGMA foreign_key_list(" .. name .. ");",
    },
    {
      id = "definition",
      kind = "statement",
      label = "Definition",
      statement = "SELECT sql FROM sqlite_master WHERE name = " .. name .. " AND type IN ('table', 'view');",
    },
  }
end

return M
