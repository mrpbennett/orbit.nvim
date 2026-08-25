# Orbit.nvim

Orbit.nvim is a personal Neovim database query workspace for Trino and SQLite. It provides statement execution, schema browsing, and formatted query results through backend-specific CLIs.

## Language

**Connection profile**:
A named JSON-defined database target with a `kind` and backend-specific options, containing the settings Orbit.nvim needs to invoke its CLI, including connection credentials where required.
_Avoid_: connection, config, data source

**Connector**:
The backend-specific component selected by a connection profile's `kind`. It implements the capabilities supported by that backend using the profile's backend-specific options.
_Avoid_: adapter, driver

**Profile file**:
The owner-protected JSON file in `~/.local/share/orbit.nvim/` that is the source of truth for connection profiles.
_Avoid_: configuration file, credentials file

**Schema browser**:
A navigable view of the hierarchy and metadata exposed by a connection profile, including tables, views, and columns with their types.
_Avoid_: database tree, sidebar

**Schema acquisition**:
The retrieval and refresh of the tables, views, and table metadata exposed by a connection profile for use by Orbit.nvim views, completion, and editable results.

**Table metadata category**:
A recognized kind of metadata for a schema object: columns, primary keys, foreign keys, or indexes. A connector exposes only the categories it supports for that object.

**Qualified name**:
The canonical SQL-pasteable identifier for a schema object. It is connector-specific: SQLite uses a quoted object name, PostgreSQL uses quoted schema and object names, and Trino uses quoted catalog, schema, and object names.
_Avoid_: table name, object path

**Completion qualifier**:
The identifier prefix before a completion target, resolved by the connection profile's connector. PostgreSQL accepts either its canonical quoted schema prefix or its ordinary unquoted schema prefix.

**Result grid**:
A configurable formatted window, shown at the bottom by default, that displays the rows and column headers produced by an executed statement.
_Avoid_: result buffer, table window

**Statement**:
Text executed through a connection profile's CLI, including read, data-changing, and schema-changing operations.
_Avoid_: query, command

**Mutating statement**:
A statement that can change data or database structure and requires confirmation by default before Orbit.nvim executes it.
_Avoid_: write query, destructive query

**Active profile**:
The default connection profile used only when a query buffer has not selected its own profile.
_Avoid_: active database, current connection

**Query buffer**:
A Neovim buffer containing statements and optionally associated with a specific connection profile.
_Avoid_: SQL file, editor buffer

**Workspace**:
A dedicated Neovim tabpage containing Orbit's profile/schema browser, query buffers, and persistent result grid.
_Avoid_: IDE, dashboard
