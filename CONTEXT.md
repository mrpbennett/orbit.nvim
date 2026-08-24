# Quarry.nvim

Quarry.nvim is a personal Neovim database query workspace for Trino and SQLite. It provides statement execution, schema browsing, and formatted query results through backend-specific CLIs.

## Language

**Connection profile**:
A named JSON-defined database target with a `kind` and backend-specific options, containing the settings Quarry.nvim needs to invoke its CLI, including connection credentials where required.
_Avoid_: connection, config, data source

**Profile file**:
The owner-protected JSON file in `~/.local/share/quarry.nvim/` that is the source of truth for connection profiles.
_Avoid_: configuration file, credentials file

**Schema browser**:
A navigable view of the hierarchy and metadata exposed by a connection profile, including tables, views, and columns with their types.
_Avoid_: database tree, sidebar

**Schema acquisition**:
The retrieval and refresh of the tables, views, and columns exposed by a connection profile for use by Quarry.nvim views and completion.

**Result grid**:
A configurable formatted window, shown at the bottom by default, that displays the rows and column headers produced by an executed statement.
_Avoid_: result buffer, table window

**Statement**:
Text executed through a connection profile's CLI, including read, data-changing, and schema-changing operations.
_Avoid_: query, command

**Mutating statement**:
A statement that can change data or database structure and requires confirmation by default before Quarry.nvim executes it.
_Avoid_: write query, destructive query

**Active profile**:
The default connection profile used only when a query buffer has not selected its own profile.
_Avoid_: active database, current connection

**Query buffer**:
A Neovim buffer containing statements and optionally associated with a specific connection profile.
_Avoid_: SQL file, editor buffer

**Workspace**:
A dedicated Neovim tabpage containing Quarry's profile/schema browser, query buffers, and persistent result grid.
_Avoid_: IDE, dashboard
