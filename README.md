# :rocket: Orbit.nvim

## A database IDE for Neovim

Your database revolves around your editor, not the other way around.

Orbit runs statements through your existing database CLI, retains one connection per profile where the CLI supports it, keeps profiles per query buffer, browses schemas, completes cached objects, and renders JSON results in a navigable grid.

![preview](./assets/preview.png)

## What It Does

- Open one dedicated workspace tab with a searchable profile and schema browser.
- Run a whole statement or a visual selection asynchronously without leaving Neovim.
- Bind each query buffer to its own connection profile.
- Browse tables, views, and columns; run connector-specific object actions; create a bound sample statement; copy qualified object names.
- Inspect and copy raw result values, including structured JSON values.
- Confirm potentially mutating statements before they run.
- Complete cached tables, views, and columns with Neovim's built-in omnifunc.

## Requirements

- Neovim 0.10 or later.
- No required third-party Neovim plugins.
- The CLI required by each connection profile:

| Profile kind | CLI                                                             | Notes                                     |
| ------------ | --------------------------------------------------------------- | ----------------------------------------- |
| `trino`      | [`trino`](https://trino.io/docs/current/client/cli.html)        | Orbit requests JSON output.               |
| `sqlite`     | `sqlite3`                                                       | Requires a build that supports `-json`.   |
| `postgres`   | [`psql`](https://www.postgresql.org/docs/current/app-psql.html) | Requires a version that supports `--csv`. |

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mrpbennett/orbit.nvim",
  opts = {},
}
```

Or call setup from your Neovim configuration:

```lua
require("orbit").setup()
```

## Quick Start

1. Run `:OrbitProfiles`. This creates `~/.local/share/orbit.nvim/profiles.json` with owner-only (`0600`) permissions and opens it for editing.
2. Add a connection profile using the format below.
3. Open `:OrbitWorkspace` or a SQL buffer.
4. Bind a profile with `:OrbitProfile`, or press `<CR>` on a profile in the workspace.
5. Run `:OrbitExecute`, or use `<leader>E` in Normal or Visual mode in a SQL buffer.

If a query buffer has no profile, executing it opens profile selection and retries after you choose one.

### Supported Connectors

| Kind       | Required options            | Optional options                                                                                                 | Schema support                                                                                                           |
| ---------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `trino`    | `server`, `user`, `catalog` | `schema`, `schema_patterns`, `executable`, `arguments`, `confirm_mutations`                                      | Tables, views, and columns from `information_schema`. Omitting `schema` browses the catalog except `information_schema`. |
| `sqlite`   | `path`                      | `schema_patterns`, `executable`, `arguments`, `confirm_mutations`                                                | Tables and views from `sqlite_master`, plus columns from `PRAGMA table_info`, under `main`.                              |
| `postgres` | `database`                  | `schema_patterns`, `host`, `port`, `user`, `password`, `sslmode`, `executable`, `arguments`, `confirm_mutations` | Tables and views outside PostgreSQL system schemas, plus columns, primary keys, foreign keys, and indexes.               |

`executable` replaces the CLI binary and `arguments` adds an array of string arguments before Orbit's generated arguments. This is useful for wrappers or CLI-specific authentication flags. For SQLite and PostgreSQL, Orbit retains one interactive CLI connection per profile; statements, schema browsing, and completion prewarming share it and are serialized per profile. A changed profile definition, failed CLI, `:OrbitDisconnect`, or Neovim exit closes the connection; the next request reconnects automatically. Trino statements instead run one `trino` CLI invocation per statement, serialized per profile, because the `trino` CLI does not flush its output while held open on a retained connection.

`schema_patterns` restricts the tables and views shown by Orbit's schema browser, but does not change database permissions or restrict statements you run manually. For Trino, it maps each catalog to an array of exact schema names; use an empty array to include every non-system schema from that catalog. PostgreSQL and SQLite use a non-empty array of exact schema names instead. SQLite's only available schema is `main`.

## Connection Profiles

The profile file is the source of truth for named connection profiles. Its default location is `~/.local/share/orbit.nvim/profiles.json`; set `profile_path` in `setup()` to use another location. Orbit refuses to load a file that is not mode `0600`.

Profiles are JSON, versioned at `1`, and names must be unique:

<details>
<summary>PostgreSQL</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "app-db",
      "kind": "postgres",
      "options": {
        "database": "postgres",
        "host": "postgres.example.com",
        "port": 5432,
        "user": "postr",
        "password": "somePassword",
        "sslmode": "require"
      }
    }
  ]
}
```

</details>

<details>
<summary>SQLite</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "local",
      "kind": "sqlite",
      "options": {
        "path": "/home/projects/data.db"
      }
    }
  ]
}
```

</details>

<details>
<summary>Trino</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "analytics",
      "kind": "trino",
      "arguments": ["--password"]
      "options": {
        "server": "https://trino.example.com:8443",
        "user": "alice",
        "catalog": "hive",
        "schema": "analytics",
        "schema_patterns": {
          "hive": ["analytics", "reporting"],
          "iceberg": []
          // add more catalogs as needed...
          // see Trino Multi-Catalog Schema Browser
        },
      }
    }
  ]
}
```

</details>

### Trino Multi-Catalog Schema Browser

Trino profiles still require `catalog` as the CLI's default catalog, but `schema_patterns` can browse schemas from multiple catalogs. Orbit retains each object's catalog for column inspection, copied names, and generated sample statements:

```json
{
  "catalog": "gridhive",
  "schema_patterns": {
    "catalog_1": ["data_v2"],
    "catalog_2": ["aggr", "cleanroom", "report"],
    "iceberg": ["cleanroom"],
    "sqlserver_rep": ["dbo"]
  }
}
```

An empty array, such as `"catalog_1": []`, includes every non-system schema from that catalog. Omit a catalog entirely to hide it.

### Authentication

PostgreSQL profiles may include `options.password`. Orbit passes it only to `psql` as `PGPASSWORD`, never as a command-line argument. The profile file is owner-protected (`0600`), but a password remains sensitive; use your system's credential management or a `~/.pgpass` file if you prefer not to store it in JSON.

Configure Trino authentication exactly as you do for the Trino CLI, including its `--password` flag, environment variables, tokens, keyrings, or credential providers it uses.

Orbit passes profile values to the CLI as literal arguments. It does **not** expand `$VAR` or `${VAR}` inside JSON. Other Trino CLI authentication mechanisms, such as tokens or external credential providers, continue to work through their normal CLI configuration.

> [!NOTE]
> Connection profiles can contain sensitive settings, including PostgreSQL passwords. Orbit requires the profile file to be mode `0600`; do not copy it into a repository or share it.

## Workspace Workflow

`:OrbitWorkspace` opens a dedicated Orbit tabpage with a profile/schema browser and a normal SQL editing window. Run it again to toggle that browser. `:OrbitWorkspaceClose` closes only that tabpage.

1. Press `<CR>` on a profile to select it and bind it to the active query buffer.
2. Optionally press `l` to load its schema for browsing and completion.
3. Press `n` to open a new SQL buffer already bound to the selected profile.
4. Execute a statement. Results appear in the reusable bottom result grid.

Set `saved_query_dir` to add a recursive tree of `.sql` files to the sidebar. Select a profile, then press `<CR>` on a saved query to open it in the Workspace query window bound to that profile; loading the schema is not required. Press `r` on the saved-query directory to rescan it.

From a workspace query buffer, `/` focuses the workspace filter. Elsewhere, `/` retains normal Neovim search behavior.

## Commands

| Command                   | Description                                                                               |
| ------------------------- | ----------------------------------------------------------------------------------------- |
| `:OrbitProfiles`          | Create, protect, and edit the profile file.                                               |
| `:OrbitProfile`           | Search profiles and bind one to the current query buffer.                                 |
| `:OrbitSelectProfile`     | Alias for `:OrbitProfile`.                                                                |
| `:OrbitExecute`           | Execute the single unambiguous statement in the current buffer.                           |
| `:'<,'>OrbitExecute`      | Execute the selected line range.                                                          |
| `:OrbitCancel`            | Cancel the statement running in the current buffer.                                       |
| `:OrbitDisconnect`        | Close the connection for the current buffer's profile.                                    |
| `:OrbitBrowse [profile]`  | Open the standalone schema browser for a profile or the buffer's profile.                 |
| `:OrbitBrowse! [profile]` | Open the schema browser and focus its filter. In a workspace, focus the workspace filter. |
| `:OrbitWorkspace`         | Open the workspace or toggle its profile/schema browser.                                  |
| `:OrbitWorkspaceClose`    | Close the Orbit workspace tabpage.                                                        |

Whole-buffer execution rejects ambiguous multi-statement content. Select the exact statement in Visual mode, then run `:OrbitExecute` or `<leader>E`.

## Keybindings

### Configurable Mappings

Orbit installs the following defaults:

| Mode and scope     | Mapping     | Action                                                   |
| ------------------ | ----------- | -------------------------------------------------------- |
| Normal, global     | `<leader>D` | Open the workspace or toggle its profile/schema browser. |
| Normal, SQL buffer | `<leader>E` | Execute the buffer statement.                            |
| Visual, SQL buffer | `<leader>E` | Execute the visual selection.                            |
| Normal, SQL buffer | `<leader>P` | Select a connection profile.                             |
| Normal, SQL buffer | `<leader>B` | Open the schema browser.                                 |
| Normal, SQL buffer | `<leader>X` | Cancel the running statement.                            |

Configure action mappings through `keymaps`. `execute`, `browse`, `cancel`, and `select_profile` are buffer-local in SQL buffers; `workspace` is global. Set an action to `false` to disable its default mapping.

```lua
require("orbit").setup({
  keymaps = {
    execute = "<leader>E",
    workspace = "<leader>D",
    select_profile = "<leader>P",
    browse = "<leader>B",
    cancel = "<leader>X",
  },
})
```

### Workspace Sidebar

| Key    | Action                                                                                                      |
| ------ | ----------------------------------------------------------------------------------------------------------- |
| `l`    | Expand the selected profile, schema, object group, table metadata folder, or object.                        |
| `h`    | Collapse the selected node.                                                                                 |
| `<CR>` | Select and bind a profile to the current query buffer, or open a saved query bound to the selected profile. |
| `n`    | Create a query buffer bound to the selected profile.                                                        |
| `s`    | Open a bound sample statement for the selected table or view.                                               |
| `a`    | Select a connector-supported action for the selected table or view.                                         |
| `y`    | Copy the qualified selected table or view name.                                                             |
| `P`    | Preview the selected saved query without opening or binding it.                                             |
| `/`    | Filter profiles, schema objects, and saved queries.                                                         |
| `r`    | Reload the profile file and refresh the selected profile schema, or rescan saved queries.                   |
| `Z`    | Collapse the open profile schema tree.                                                                      |
| `?`    | Show help.                                                                                                  |
| `q`    | Close the workspace.                                                                                        |

Expanding a table reveals its available metadata folders. SQLite provides columns, primary keys, foreign keys, and indexes; each folder loads on demand. Views remain under the schema's `views` group and expose their columns.

### Standalone Schema Browser

| Key           | Action                                                                                                     |
| ------------- | ---------------------------------------------------------------------------------------------------------- |
| `l` or `<CR>` | Expand an object's columns.                                                                                |
| `h`           | Collapse an object's columns.                                                                              |
| `s`           | Open a bound `SELECT * ... LIMIT ...` sample statement.                                                    |
| `a`           | Select a connector-supported action for the object, such as columns, indexes, foreign keys, or definition. |
| `y`           | Copy the object name. Trino names include catalog and schema.                                              |
| `/`           | Filter objects.                                                                                            |
| `r`           | Reload the profile and schema.                                                                             |
| `?`           | Show help.                                                                                                 |
| `q`           | Close the browser.                                                                                         |

### Result Grid

| Key                | Action                                                                   |
| ------------------ | ------------------------------------------------------------------------ |
| `h`, `j`, `k`, `l` | Move between cells.                                                      |
| `<CR>`             | Inspect the raw value in a floating window.                              |
| `y`                | Copy the raw selected value.                                             |
| `q`                | Close the standalone grid, or return to the query editor in a workspace. |

Schema-browser sample statements for PostgreSQL and SQLite base tables become editable when Orbit can load a primary key. Ad-hoc statements, views, Trino, and tables without a primary key remain read-only.

| Key / command | Action |
| --- | --- |
| `o`, `O` | Insert a local row below or above the current row. |
| `i`, `<CR>` | Enter Insert mode in the focused cell; press `Esc` to keep the local edit. |
| `dd` | Mark the current row for local deletion. |
| `V`, `j` / `k`, `d` | Select complete rows and delete the selection. |
| `u` | Undo the most recent local edit. |
| `:w` | Confirm, transactionally save, and reload pending changes. |
| `:wq` | Save successfully, then close the Result grid. |
| `:q!` | Discard local changes and close. |
| `:e!` | Discard local changes and reload the table. |

Edits are never sent to the database until `:w`. A failed write leaves the local Result grid unchanged.
Type `NULL` as the complete cell value to write a SQL `NULL` value.

Normal Neovim scrolling remains available, including `<C-d>`, `<C-u>`, `zh`, and `zl`.

### Schema Object Actions

Press `a` on a table or view in the standalone Schema browser to select an action supplied by its connection profile kind. Actions that inspect metadata open in the Result grid; sample actions create a bound query buffer instead.

- SQLite: sample statement, columns, primary keys, indexes, foreign keys, and object definition.
- PostgreSQL: sample statement, columns, primary keys, indexes, foreign keys, and view definition.
- Trino: sample statement and columns.

Available actions are intentionally connector-specific. Orbit does not present metadata actions that the selected CLI or database cannot support reliably.

## Completion

Binding a connection profile attaches Orbit's native omnifunc to the query buffer. Use `<C-x><C-o>` in Insert mode for cached schema objects:

- Tables and views after `FROM`, `JOIN`, `UPDATE`, or `INTO`.
- Trino and PostgreSQL tables and views after `schema.`.
- Cached columns after `table.`.

Selecting a profile preloads tables and views in the background; opening the schema browser fills more of the cache. Completion never runs the CLI while you type. SQL keywords, CTE aliases, formatting, and highlighting remain the responsibility of your existing SQL tooling.

## Execution And Results

Orbit runs statements asynchronously through the selected profile's CLI. For SQLite and PostgreSQL, schema work and statements share one retained connection and execute one at a time; failures notify you and open a diagnostic window, and the next request starts a new connection. Trino statements each run their own `trino` CLI invocation, still serialized per profile. One running statement is allowed per query buffer; `:OrbitCancel` terminates the current CLI invocation (and, for SQLite/PostgreSQL, the retained connection) and pending work fails rather than running against an uncertain session.

Potentially mutating statements require confirmation by default. A single `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN`, `USE`, or `VALUES` statement runs without confirmation; everything else requires it. This is a convenience guardrail, not a security boundary.

Result grids are reused per tabpage. They show up to `result_limit` rows and truncate displayed cell text to `max_cell_width` characters while retaining the raw value for copy and inspection.

## Configuration

```lua
require("orbit").setup({
  confirm_mutations = true,
  focus_results = false,
  profile_path = vim.fn.expand("~/.local/share/orbit.nvim/profiles.json"),
  result_limit = 200,
  result_height = 15,
  saved_query_dir = vim.fn.expand("~/queries"),
  max_cell_width = 48,
  schema_width = 36,
  workspace_sidebar_width = 32,
  workspace_result_ratio = 0.30,
  winbar = false,
  icons = {
    collapsed = ">",
    column = "󰠵",
    expanded = "󰘖",
    folder = "󰉋",
    index = "",
    key = "",
    profile = "󰆼",
    query = "󰆋",
    result = "󰎟",
    saved_query = "󰆼",
    table = "󰓫",
    view = "󰈈",
    workspace = "󱓞",
  },

})
```

| Option                    | Default                                   | Description                                                                                                                                          |
| ------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `confirm_mutations`       | `true`                                    | Ask before statements that are not recognised as read-only. A profile can override this with `options.confirm_mutations`.                            |
| `focus_results`           | `false`                                   | Focus a completed standalone result grid instead of keeping focus in the query buffer.                                                               |
| `profile_path`            | `~/.local/share/orbit.nvim/profiles.json` | Location of the profile file.                                                                                                                        |
| `result_limit`            | `200`                                     | Maximum returned rows displayed in the result grid.                                                                                                  |
| `result_height`           | `15`                                      | Height of a standalone result grid.                                                                                                                  |
| `saved_query_dir`         | `nil`                                     | Directory of recursively discovered `.sql` files shown in the Workspace sidebar.                                                                     |
| `max_cell_width`          | `48`                                      | Maximum displayed width of a result cell.                                                                                                            |
| `schema_width`            | `36`                                      | Width of the standalone schema browser.                                                                                                              |
| `workspace_sidebar_width` | `32`                                      | Width of the workspace sidebar.                                                                                                                      |
| `workspace_result_ratio`  | `0.30`                                    | Fraction of editor height used by workspace results, with a six-line minimum.                                                                        |
| `winbar`                  | `false`                                   | Show Orbit status in SQL-window winbars.                                                                                                             |
| `keymaps`                 | See above                                 | Configurable action mappings.                                                                                                                        |
| `icons`                   | Nerd Font glyphs                          | Override `collapsed`, `expanded`, `folder`, `index`, `key`, `profile`, `query`, `result`, `saved_query`, `table`, `view`, `column`, and `workspace`. |

For a custom statusline, call `require("orbit").status()`. It reports the bound profile and shows elapsed time while a statement is running.
