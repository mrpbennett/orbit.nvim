# Orbit.nvim v0.1 Plan

## Trino Schema Allowlist Plan

- [x] Confirm whether a Trino profile's schema allowlist may include catalogs other than `options.catalog`.
- [x] Generalize the allowlist as `schema_patterns` for all relational profiles and apply it to metadata discovery.
- [x] Add focused profile and metadata-statement tests, document the setting, and run the full test suite.

## Trino Schema Allowlist Review

- `schema_patterns` maps Trino catalogs to exact schema allowlists; PostgreSQL and SQLite accept non-empty arrays of exact schema names.
- Trino and PostgreSQL include the allowlist in their metadata queries; SQLite exposes its fixed `main` schema only when listed.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## Trino Multi-Catalog Schema Plan

- [x] Change Trino `schema_patterns` to map catalogs to exact schema allowlists, with an empty allowlist including the catalog's schemas.
- [x] Preserve source catalogs through schema browsing, metadata actions, copied names, cache keys, and completion.
- [x] Add focused tests, update the profile documentation, and run verification.

### Review

- Empty Trino schema arrays include every non-system schema in that catalog. Objects retain their catalog through metadata queries, actions, copies, cache keys, and completion.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## Orbit Rebrand Plan

- [x] Rename the repository, plugin loader, Lua module namespace, internal Neovim state, highlights, filetypes, and completion entry point to Orbit.
- [x] Rename every public user command and update the documented package, setup module, profile path, UI labels, and project/domain documentation.
- [x] Add the approved Orbit slogan to the README and update tests to exercise the renamed public surface.
- [x] Run the complete headless test suite and check the working tree for remaining legacy-name references.

## Orbit Rebrand Review

- [x] Renamed the workspace to `orbit.nvim` and moved the plugin and Lua module namespaces to `plugin/orbit.lua` and `lua/orbit/`.
- [x] Replaced all legacy-name references, including commands, state, highlights, filetypes, documentation, and test fixtures.
- [x] Verification: `nvim --headless -u NONE -l tests/run.lua` passed. `git diff --check` passed. No legacy-name references remain.

## Implementation

- [x] Scaffold the Lua plugin, its documented Neovim requirement, and a repeatable Lua test runner.
- [x] Implement versioned, owner-protected profile-file loading and validation for Trino and SQLite profiles.
- [x] Implement CLI adapters that construct machine-readable asynchronous commands and normalize their results.
- [x] Implement query-buffer profile selection and safe statement-target resolution.
- [x] Implement bottom-window result grids, full-value inspection, bounded rows, and execution diagnostics.
- [x] Implement the lazy schema browser with explicit refresh and Trino/SQLite metadata adapters.
- [x] Add user commands and configurable buffer-local mappings without global default mappings.
- [x] Document installation, profile-file format, CLI requirements, safety behavior, and current limitations.

## Verification

- [x] Test the approved public seams through profile loading, command construction, statement-target resolution, and result rendering behavior.
- [x] Run the focused tests throughout implementation and the complete test suite after the final slice.
- [x] Review the final source for design conformance, regressions, and missing coverage.

## Review

- Source review completed without Git history because this directory is not a Git repository.
- Fixed review findings: conservative mutation confirmation, quiet cancellation, profile-file permission enforcement, buffer-profile browser fallback, and structured result inspection.
- Remaining verification gap: no live Trino or SQLite CLI/profile is available in this environment.

## UX Implementation

- [x] Add status reporting, opt-in winbar, highlights, and opt-in documented keymaps.
- [x] Rework result grids into reusable per-tab windows with cell navigation, raw copying, paging, and floating inspection.
- [x] Rework schema browsing into a searchable tree with in-pane filtering and tree actions.
- [x] Update documentation and verify the approved status, keymap, grid, and filter seams.

## UX Review

- Independent UX review completed and all reported defects were fixed.
- Remaining verification gap: no live Trino or SQLite CLI/profile is available in this environment.

## Workspace Implementation

- [x] Add dedicated workspace tab lifecycle, commands, and opt-in entry mapping.
- [x] Build the persistent workspace sidebar with profiles, lazy schema loading, filtering, and query creation.
- [x] Mount a durable workspace result region and retain query-buffer profile bindings.
- [x] Add workspace help, documentation, tests, and independent review.

## Workspace Review

- Independent review completed; fixed stale query-window, initial profile-binding, overlapping schema-load, and sidebar row-mapping defects.
- Remaining verification gap: no live Trino or SQLite CLI/profile is available in this environment.

## Architecture Review

- [x] Examine the Workspace, schema browser, result grid, and connection profile modules for deepening opportunities.
- [x] Produce and open a temporary HTML architecture report with before/after visuals.
- [x] Verify the report and record the completed review.

## Architecture Review Notes

- Report: `/tmp/architecture-review-20260824-151913.html`.
- No Git history was available, so scope followed the recent Workspace implementation plan and its related modules.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (28 tests).

## Architecture Deepening

- [x] Centralize schema acquisition and navigation mechanics with explicit refresh.
- [x] Move persistent Workspace result-grid policy to the Workspace module.
- [x] Centralize validated connection-profile resolution while reloading on the next action.
- [x] Add focused tests and run the complete suite.

## Architecture Deepening Review

- [x] Confirm behavior and record verification results.

- `schema_cache` now owns shared table/column acquisition, in-flight coordination, and explicit-refresh cache invalidation.
- Workspace owns persistent result-grid policy; the result-grid module only renders and delegates the quit action.
- Connection-profile lookup is centralized in `profiles.find`; Workspace selection and schema-browser refresh reload the profile file.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (32 tests). `stylua` is not installed in this environment.

## Schema Tree UX

- [x] Render Workspace schema browsing as connection profile, schema, object group, object, and column nodes.
- [x] Preserve filtering and expand/collapse behavior at every tree level.
- [x] Add tree-rendering coverage and run the complete suite.

- SQLite reports its `main` schema so it uses the same Workspace tree as Trino.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (36 tests).

## Architecture Review (Current)

- [x] Examine the Workspace, schema browser, result grid, and connection-profile modules for deepening opportunities.
- [x] Produce and open a temporary HTML architecture report with before/after visuals.
- [x] Verify the report and record the completed review.

## Architecture Review (Current) Notes

- Report opened: `/tmp/architecture-review-20260824-155406.html`.
- Scope followed recent Workspace implementation notes because this directory has no Git history.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (36 tests).

## Architecture Deepening (Current)

- [x] Settle the Schema acquisition module's seam and refresh semantics.
- [x] Settle connection-profile option validation ownership.
- [x] Settle Result grid geometry interface and placement.
- [x] Implement the agreed deepening and verify the complete suite.

### Settled Decisions

- Deepen `schema_cache`; do not add a second Schema acquisition module.
- Normal loads join a refresh in flight, and a failed refresh retains the last successful Schema acquisition.
- Connection-profile options are strict and validated by the Trino and SQLite adapters.
- Extract logical Result grid geometry while retaining identical Neovim-visible behavior.

### Review

- `nvim --headless -u NONE -l tests/run.lua` passed (39 tests).
- `stylua` is not installed in this environment.

## Schema Browser Navigation Fix

- [x] Add a public Schema browser navigation regression test.
- [x] Correct the rendered-row mapping and verify all navigation mappings.
- [x] Run the complete suite.

### Review

- Root cause: table and view rows were indexed one line below their rendered buffer line, so navigation mappings could not identify the selected row.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (40 tests).

## README Refresh

- [x] Document the supported connectors, profile-file lifecycle, setup options, commands, keybindings, and end-to-end workflow from the current public implementation.
- [x] Verify every README command, option, mapping, and connector claim against source and run the documentation-adjacent test suite.

## README Refresh Review

- Rewrote `README.md` around the user workflow, then cross-checked every public claim against the implementation.
- Corrected stale documentation: no configured default browse mapping exists, and profile JSON does not interpolate environment variables.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (40 tests).
- `git diff --check` is unavailable because this directory is not a Git repository.

## Saved Query Directory Plan

- [x] Inspect configuration, workspace sidebar, query-buffer binding, and test seams.
- [x] Confirm recursive discovery and saved-query profile-binding behavior.
- [x] Add a `saved_query_dir` setup option and enumerate its SQL files for each Workspace render.
- [x] Render the configured directory and its saved SQL files in the Workspace sidebar, respecting the existing filter.
- [x] Open a selected saved query in the Workspace query window, configure it as a query buffer, and bind the agreed profile.
- [x] Document the option and sidebar behavior; add focused Workspace coverage and run the complete suite.

## Saved Query Directory Review

- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (41 tests).
- `stylua --check lua tests` could not run because `stylua` is not installed in this environment.

## Saved Query Profile Selection Fix

- [x] Add a regression test that selects a profile without loading its schema, then opens a saved query.
- [x] Separate the active profile used for binding queries from the profile whose schema tree is expanded.
- [x] Update saved-query workflow documentation and run the complete test suite.

### Review

- [x] Record the root cause and verification results.

- Root cause: `state.selected` represented both the profile whose schema was expanded and the profile used to bind saved queries. Only `l` assigned it, so an explicit profile binding did not make saved queries available.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (41 tests).

## Persistent Trino Sessions Plan

- [x] Establish the supported Trino authentication mechanism and a repeatable local or mocked protocol test seam.
- [x] Design a session-owning Trino transport that retains response session headers across queries.
- [ ] Implement query submission, paginated result collection, and query cancellation without spawning a CLI per query.
- [ ] Preserve the CLI-backed schema browser until it can use the same authenticated transport.
- [ ] Document the connection lifecycle and run the complete test suite.

### Settled Design

- Persistent mode is opt-in with `options.transport = "http"`; existing profiles retain CLI behavior.
- Persistent mode uses Trino basic authentication with the password from `options.password_env` or `TRINO_PASSWORD`.
- `lua-http` and `cqueues` are an optional runtime dependency, embedded using non-blocking `cqueue:step(0)` calls driven by Neovim libuv polling.
- One HTTP/1.1 TLS connection and Trino protocol-header state are retained per profile. Results follow `nextUri` sequentially; cancellation sends `DELETE` to the latest `nextUri`.
- The CLI remains the schema/completion transport in this slice, so its behavior and authentication remain unchanged.

### Redesign Required

- The LuaRocks transport cannot meet the zero-configuration installation requirement.
- Replace it with one interactive Trino CLI process per profile. This uses the existing required `trino` CLI and its authentication configuration, retaining the CLI's Trino HTTP session without additional dependencies.
- Serialize statements per profile. Cancellation terminates the CLI session, which is recreated for the next statement.

### Review

- [ ] Record the supported authentication, compatibility limits, and verification results.

- Implemented the opt-in HTTP session runner, including retained HTTP/1.1 connections, basic authentication, Trino session headers, paginated results, and cancellation after the active response.
- The CLI remains the schema-browser and completion transport.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (42 tests).
- Verification gap: Neovim's LuaJIT runtime does not have `lua-http` or `cqueues`, so a live Trino HTTP connection and cancellation test cannot run in this environment.

## Persistent Trino Dependency Installation

- [ ] Replace the LuaRocks HTTP transport with a bundled dependency-free persistent transport.
- [ ] Verify persistent Trino connections from a fresh lazy.nvim installation.

- Rejected LuaRocks packaging: lazy.nvim first resolved an unrelated `orbit.nvim` rock, and the unique-name fallback failed because the current `http` rock cannot resolve its `basexx` dependency for Lua 5.1.

## Persistent Trino CLI Session Redesign

- [x] Replace the Lua HTTP transport with a dependency-free interactive Trino CLI session per profile.
- [x] Route statement execution and schema acquisition through the retained CLI session, serializing work per profile.
- [x] Remove obsolete HTTP transport profile options and documentation.
- [x] Add protocol and configuration regression coverage, run the full test suite, and review the result.

### Review

- Trino statements are queued per profile and sent to a retained interactive CLI without `--execute`.
- An internal marker statement delimits JSON results across arbitrary stdout chunks; cancellation terminates the session before the next statement starts a fresh CLI.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (43 tests).
- Remaining verification gap: no live Trino CLI/profile is available in this environment.

## Default Keymaps

- [x] Add regression coverage for default, overridden, and disabled action mappings.
- [x] Apply default keymaps when Orbit is configured and preserve user overrides through `opts.keymaps`.
- [ ] Run the complete test suite after the unrelated Trino adapter/profile-test mismatch is resolved.

## Review

- [ ] Record final full-suite verification after the unrelated Trino adapter/profile-test mismatch is resolved.

- Default mappings are `<leader>D` (workspace), `<leader>E` (execute), `<leader>X` (cancel), `<leader>P` (select profile), and `<leader>B` (browse).
- `opts.keymaps` overrides individual defaults; set an action to `false` to disable it.
- Verification: focused keymap coverage and `git diff --check` passed. The full suite is blocked by `tests/profile_spec.lua:155`, which expects `--execute interactive` while the current Trino adapter emits `--execute "SELECT 1"`. `stylua` is not installed.

## Clickable Workspace Sidebar Plan

- [x] Extract current-node expansion, collapse, and activation actions from sidebar keymaps.
- [x] Bind `<2-LeftMouse>` locally in the Workspace sidebar and activate the clicked node.
- [x] Add regression coverage for the mapping and profile activation.
- [x] Run focused and complete test suites, then record verification results.

### Review

- `<2-LeftMouse>` is buffer-local to the Workspace sidebar, verifies the clicked window and line, then moves the sidebar cursor before activating the node.
- Existing keyboard behavior remains unchanged: `h` collapses, `l` expands, and `<CR>` binds a profile or opens a saved query.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed. `git diff --check` passed.

## Clickable Workspace Sidebar Regression Plan

- [x] Reproduce double-click activation with an input-level Workspace test.
- [x] Correct the failing mouse-dispatch path without changing keyboard actions.
- [x] Run the complete test suite and record the verified behavior.

### Review

- Root cause: profile expansion tested `state.selected`, which tracks query binding, rather than `state.schema_profile`, which tracks the visible schema tree. A selected profile could therefore never be expanded with `l`.
- `<2-LeftMouse>` now binds and expands a profile. `<CR>` remains bind-only, and `h`/`l` retain their existing tree behavior.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed.

## Schema Object Actions Plan

- [x] Define connector-level schema object-action capabilities and action contracts, retaining the shared Schema browser UI.
- [x] Add a Schema browser action picker that runs connector-provided metadata actions or opens a bound sample statement.
- [x] Provide SQLite and Trino object-action capabilities without regressing their existing Schema acquisition.
- [x] Add focused adapter, profile, Schema acquisition, and browser interaction tests.
- [x] Update README connector/profile/action documentation and run the complete headless suite plus the configured formatter when available.

### Design

- `adapters` remains the only dispatch layer. Each connector declares the object actions it supports and produces the statement or sample-statement text for the selected object.
- The Schema browser owns selecting and running an action; it does not encode backend-specific SQL or object-kind conditionals.
- PostgreSQL support is deferred until this capability contract has been proven with the existing connectors.

### Review

- [x] Record verification results, live-CLI coverage gaps, and any deferred metadata actions.

- SQLite provides sample statements, columns, primary keys, indexes, foreign keys, and object definitions. Trino provides sample statements and columns. Unsupported actions are not shown.
- The standalone Schema browser action picker opens sample statements in a profile-bound query buffer and metadata in the Result grid. Result grids retain the originating tabpage if the user switches tabs while an action runs.
- PostgreSQL support, inbound references, and actions in the Workspace sidebar remain deferred.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua --check lua tests` could not run because `stylua` is not installed in this environment.

## Workspace Explorer QoL

- [x] Add `Z` to collapse the open profile schema tree without changing the selected profile.
- [x] Expose the existing connector-provided table actions in the Workspace sidebar, including sample statements, action selection, and qualified-name copying.
- [x] Add read-only `P` previews for saved SQL queries without opening or binding an editable query buffer.
- [x] Document the new Workspace mappings and add focused regression coverage.
- [x] Run the complete headless suite, formatter when available, and review the completed change.

### Review

- Table nodes retain their schema-owning profile, so actions and column loading remain correct after a different profile is bound to the query buffer.
- Metadata action callbacks discard results after the workspace closes, preventing an orphan result grid in another tab.
- Independent review found no remaining actionable issues.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## Table Metadata Tree Plan

- [x] Extend the schema acquisition contract to load table metadata by category.
- [x] Render expandable `columns`, `keys`, `foreign keys`, and `indexes` nodes below tables in the Workspace tree.
- [x] Add SQLite implementations for each supported metadata category and display individual metadata entries.
- [x] Preserve views as a sibling schema group and mark unsupported metadata categories unavailable rather than inventing empty data.
- [x] Add focused tree/navigation regression coverage and run the complete headless suite.

### Intended Hierarchy

- Profile -> schema -> tables/views -> table -> metadata category -> metadata entry.
- Views remain under the existing `views` group; they are schema objects, not children of a table.

### Review

- SQLite table metadata folders are loaded when a table expands, show their entry counts, and list columns, primary keys, foreign keys, and indexes as individual entries.
- The connector-level metadata-category contract supports future PostgreSQL categories without Workspace-specific conditionals.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## PostgreSQL Connector Plan

- [x] Add a `postgres` connector backed by the required `psql` CLI, register it with adapter dispatch, and validate PostgreSQL-specific connection-profile options.
- [x] Execute statements with `psql` CSV output, normalize that output into Orbit rows, and pass an optional profile password exclusively as `PGPASSWORD` to the spawned CLI process.
- [x] Add PostgreSQL schema acquisition, metadata categories, and schema object actions consistent with the existing SQLite capabilities.
- [x] Document the `psql` requirement, profile format, password handling, and PostgreSQL connector capabilities.
- [x] Add focused profile/adapter coverage, run the complete headless suite and configured formatter when available, then review the change.

### Design

- `kind: "postgres"` requires `options.database`; `host`, `port`, `user`, `password`, `sslmode`, `executable`, `arguments`, and `confirm_mutations` are optional. A password is permitted because the profile file is owner-protected (`0600`) and is never added to the process arguments.
- Orbit invokes `psql` with CSV output and no footer. Adapter parsing remains JSON-compatible for existing connectors and normalizes PostgreSQL CSV rows, including quoted fields and embedded newlines.
- PostgreSQL schema discovery excludes system schemas and reports tables, views, columns, primary keys, foreign keys, indexes, and definitions through the established connector contracts. Object actions use schema-qualified, safely quoted identifiers.

### Review

- [x] Record verification results and any live-`psql` coverage gap.

- Added the `postgres` connector with `psql --csv`, protected password handoff through `PGPASSWORD`, PostgreSQL schema acquisition, metadata actions, quoted-name completion, and README connection guidance.
- Review fixes: preserve CSV `NULL` values, pair composite foreign-key columns by ordinal position, exclude PostgreSQL system schemas, align metadata rows with the Workspace contract, validate profile mode through the open descriptor, and support quoted PostgreSQL completion.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `psql 18.6` is installed and supports `--csv`; no usable local PostgreSQL connection profile is available for a live query. `stylua --check lua tests` could not run because `stylua` is not installed.

## Persistent Connector Sessions Plan

- [x] Define one profile-session interface used by statements, schema acquisition, and cancellation for every current and future connector.
- [x] Implement retained interactive CLI sessions for SQLite, PostgreSQL, and Trino, including request delimiting, serialized work, failure recovery, and explicit session teardown.
- [x] Route runner and schema-cache calls through the profile session; distinguish profile binding from connection status in user feedback.
- [x] Add transport-level regression coverage for session reuse, queueing, cancellation, reconnecting after failure, and schema/query sharing; update documentation and run the complete suite.

### Review

- `orbit.session` owns one queued interactive CLI process per profile; `runner` remains the only caller seam for statements, schema acquisition, and object actions.
- SQLite integration coverage proves that queued requests share a `:memory:` connection and that an explicit close fails active work before a subsequent request reconnects.
- PostgreSQL and Trino session command/delimiter paths are covered by the shared transport but need live-profile verification because this environment has no usable server for either connector.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## Workspace Tree Double-Click Fix

- [x] Add an input-level regression test for double-clicking schema and table nodes.
- [x] Make double-click toggle every expandable Workspace tree node while retaining profile binding.
- [x] Run the focused and complete test suites and record verification.

### Review

- Double-click uses the same expand/collapse state as `h` and `l` for profiles, schemas, object groups, tables, metadata categories, and saved-query directories.
- Profile double-click retains its existing profile-binding behavior before toggling the profile schema tree.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed.

## Architecture Review 2026-08-25 (deepening backlog)

Report: `/tmp/architecture-review-20260825-093322.html` (regenerate with `/improve-codebase-architecture`; temp file will not survive a reboot).
Scope followed the hot spot: every uncommitted change lands in `workspace.lua`, `connectors/`, or `schema_cache.lua`. No ADRs exist under `docs/adr/`, so no recorded decision is contradicted. Suggested order: 1, then 3, then 2.

### 1. Extract a Schema tree module out of the Workspace — Strong (recommended first)

Files: `lua/orbit/workspace.lua:124-233` (render), `:252-338` (load/collapse/reload), `:557-637` (kind dispatch), `tests/workspace_spec.lua`.

- Problem: expansion state lives in six sibling tables (`expanded_schemas`, `expanded_groups`, `expanded_tables`, `expanded_metadata`, `expanded_saved_dirs`, `loading_metadata`) with no owner. The same nine-line reset block appears at `:262`, `:283`, `:302`, `:328`, `:588`, and every node kind is handled three times — `current_expanded` (`:560`), `collapse_current` (`:585`), `expand_current` (`:615`).
- Solution: one Schema tree module owning nodes with `expanded`/`children`, exposing `build(profile, rows, metadata)`, `toggle(node)`, and a pure `lines(tree, icons, filter) -> lines, nodes, highlights`. The Workspace keeps buffers, windows, and keymaps only.
- Wins: locality — one place to add a node kind; interface is the test surface — no buffer, no `nvim_feedkeys`, no `vim.wait` polling; five reset blocks collapse to one; makes item 2 a deletion rather than a merge.
- Target shape: `lua/orbit/grid.lua`, which is already deep (pure `render`/`layout`/`cell_at`/`move`/`cursor_for`, tested directly).
- Open question: whether saved-query nodes join the same tree or stay a separate section.

- [x] Design the Schema tree interface and confirm the saved-query question.
- [x] Extract the module and move `render` to pure line/highlight production.
- [x] Replace the buffer-driven Workspace tree tests with interface-level tests.
- [x] Run the complete suite and record verification.

#### Design

- Decision: saved-query directory nodes stay a separate Workspace-owned section. They are filesystem-discovered, not schema objects, and forcing them into the schema shape would couple two unrelated domains for no reuse.
- New module `lua/orbit/schema_tree.lua`, a stateful sibling to `grid.lua`'s pure style:
  - `M.new()` -> `{ tables = {}, metadata = {}, loading_metadata = {}, expanded = {} }`. One `expanded` map (keyed internally by node-kind-prefixed strings) replaces `expanded_schemas`/`expanded_groups`/`expanded_tables`/`expanded_metadata`.
  - `M.reset(tree)` clears all four fields — the single call that replaces the six duplicated nine-line reset blocks in `workspace.lua` (`:262`, `:283`, `:302`, `:328`, `:588`, and the `reload_profiles` block). Drops `state.columns`, which is dead (assigned `{}` four times, never read) — a leftover from before metadata categories.
  - `M.set_tables(tree, rows)`, `M.is_metadata_loaded/is_metadata_loading/set_metadata_loading/set_metadata(tree, row, category_id, ...)`.
  - `M.is_expanded(tree, node)` / `M.toggle(tree, node)` for `schema`/`group`/`table`/`metadata` node kinds. `profile` and `saved_directory` kinds stay handled in Workspace (profile drives cache loading via `load_schema`/`collapse_schema_tree`, which call `M.reset`; saved-query expansion stays in its existing map).
  - `M.lines(tree, profile, filter, { icons, loading, adapters }) -> lines, nodes, highlights`: pure — absorbs the render body at `workspace.lua:150-193` (schema/group/table/metadata rendering) plus `object_name`, `group_name`, `metadata_name`, `metadata_label`. `nodes` is keyed by line number within the returned block; Workspace splices it into `state.nodes` at the current offset exactly as it splices the saved-query section today.
- Workspace changes: `render` calls `schema_tree.lines` for the schema portion and keeps assembling the profile header and saved-queries section itself; `current_expanded`/`collapse_current`/`expand_current` delegate schema/group/table/metadata cases to `schema_tree.is_expanded`/`toggle`, keeping only the `profile`/`saved_directory` branches local.
- Test split: add `tests/schema_tree_spec.lua` feeding fixture rows/metadata straight into `schema_tree.lines`/`toggle` and asserting on the returned lines/nodes/highlights — no buffer, no `nvim_feedkeys`, no `vim.wait`. Row-by-row category/label assertions move out of "workspace renders schemas before object groups" and "workspace displays SQLite metadata below expanded tables" into the new spec; those two `workspace_spec.lua` tests keep a thin end-to-end check that a profile expands and one schema/table becomes visible. Mouse/keyboard wiring tests (double-click, table actions, discard-on-close) stay in `workspace_spec.lua` unchanged since they exercise real windows and keymaps, not tree shape.

#### Review

- Added `lua/orbit/schema_tree.lua` owning `tables`, `metadata`, `loading_metadata`, and one `expanded` map (keyed internally per node kind) behind `new`/`reset`/`set_tables`/metadata accessors/`is_expanded`/`toggle`/`lines`. `lines` is pure: fixture rows and metadata in, `lines, nodes, highlights, has_matches` out.
- `workspace.lua` now only assembles the profile header and saved-queries section itself and splices in `schema_tree.lines`' output with a fixed 4-space indent; `expand_current`/`collapse_current`/`current_expanded` delegate `schema`/`group`/`table`/`metadata` node kinds to `schema_tree`, keeping only `profile`/`saved_directory` handling local. The six duplicated reset blocks collapsed to `schema_tree.reset` calls in `load_schema`, `collapse_schema_tree`, and `reload_profiles`. Dropped `state.columns`, which was dead (assigned `{}` four times, never read).
- Added `tests/schema_tree_spec.lua` (7 tests) exercising the tree interface directly. Thinned "workspace renders schemas before object groups" and "workspace displays SQLite metadata below expanded tables" in `workspace_spec.lua` to end-to-end checks that a click path reaches a visible table/metadata entry; the removed row-by-row label assertions are now covered by the new spec.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (64 tests). `git diff --check` passed. `stylua` is not installed in this environment.

### 2. Delete the standalone Schema browser — Strong

Files: `lua/orbit/browser.lua` (391 lines, delete), `lua/orbit/workspace.lua`, `lua/orbit/init.lua:69-74`, `tests/browser_spec.lua`.

- Problem: the Schema browser and the Workspace sidebar are the same module written twice — duplicated `object_name`, `postgres_name`, filter-line editing, `set_lines`/`render`, `focus_filter`, `show_help`, `select_action`/`run_action`, `copy_name`, generation counter — and they have already diverged (the browser has no metadata categories and no saved queries).
- Solution: delete `browser.lua`; point `OrbitBrowse` at `workspace.open` with the filter focused, which `OrbitBrowse!` already does (`init.lua:70`).
- Wins: deletion test concentrates complexity; 391 lines gone with no behaviour lost; divergence stops at the source.
- Decision needed first: `OrbitBrowse` opens a split in the current tabpage, the Workspace owns a tabpage. Either it moves to a tabpage, or the Workspace sidebar learns a split mount.

- [ ] Decide split vs tabpage mounting for `OrbitBrowse`.
- [ ] Repoint `OrbitBrowse` and delete `browser.lua`.
- [ ] Fold `tests/browser_spec.lua` coverage into the Workspace tests.
- [ ] Run the complete suite and record verification.

### 3. Push object naming behind the connector seam — Strong

Files: `lua/orbit/completion.lua:15-25, 34-51, 61-84`; `lua/orbit/workspace.lua:46-51, 449-458`; `lua/orbit/browser.lua:18-23, 192-201`; `lua/orbit/connectors/*.lua`.

- Problem: identifier quoting and catalog qualification are connection-profile behaviour, but nine `profile.kind` checks decide them outside `connectors/`. Each connector already has a private `identifier`/`literal`/`qualified` and exposes none of it, so three callers reimplement quoting.
- Solution: add `qualified_name(options, row)`, `completion_word(options, row, prefix)`, and `schema_of(options, qualifier)` to the connector interface; delete the kind checks from the Workspace, the Schema browser, and completion.
- Wins: three adapters make the seam real; a fourth connector kind needs no grep; naming becomes testable per adapter with no buffer. Also supplies the cache key for item 4 and the node labels for item 1.

- [ ] Add the naming functions to all three connectors.
- [ ] Remove `profile.kind` from `completion.lua`, `workspace.lua`, `browser.lua`.
- [ ] Add per-connector naming and completion-qualification tests.
- [ ] Run the complete suite and record verification.

### 4. One acquisition function in Schema acquisition — Worth exploring

Files: `lua/orbit/schema_cache.lua:45-154`.

- Problem: the request-coalescing implementation (key building, in-flight callback fan-out, `vim.schedule` cache hit, store-on-success) is written three times, once per node type. Line `:115` already admits it: `if category == "columns" then return M.load_columns(...)`. The object-name expression is copy-pasted at `schema_cache.lua:80` and `:121`, `workspace.lua:41`, `browser.lua:13`.
- Solution: one `M.load(profile, node, options, callback)` keyed by `qualified_name(row) .. "\0" .. node.type` (from item 3); the three named functions become one-line calls into it.
- Wins: one coalescing implementation; new node types are free; ~110 lines become ~45; interface unchanged, so no caller churn.
- Lower payoff than 1-3: the interface is already the right shape, only the implementation is triplicated.

- [ ] Collapse the three loaders into one acquisition function.
- [ ] Run the complete suite and record verification.

### 5. Resolve the connector once instead of mirroring it — Worth exploring

Files: `lua/orbit/adapters.lua` (148 lines, 13 functions).

- Problem: Adapters is shallow — its interface mirrors the connector interface function for function. Eleven of thirteen functions are the same four lines (look up `connectors[profile.kind]`, forward, return a bespoke "unsupported" string), so growing a connector means editing Adapters too. The persistent-session work added 58 lines of exactly this.
- Solution: `adapters.connector(profile) -> connector, err` resolves once; callers use the connector interface directly. Keep only the functions that add behaviour — `validate_options` and `parse`.
- Wins: interface shrinks and the implementation absorbs the forwards; connectors grow without touching the seam; one "unsupported kind" error instead of eleven.
- Caveat: the deletion test partly moves complexity rather than concentrating it — callers must handle a nil connector. Weigh against item 3, which removes most of the reason to reach for Adapters at all.

- [ ] Decide whether to do this before or after item 3.
- [ ] Collapse the forwarding functions and update callers.
- [ ] Run the complete suite and record verification.

### Examined, not recommended

- `lua/orbit/runner.lua` — shallow (31 lines; `cancel`/`close`/`connected` forward straight to Session), but it is the seam the tests substitute at (`runner.run = function(...)` in `workspace_spec` and `profile_spec`). Deleting it moves complexity into every test. Leave it.
- `lua/orbit/grid.lua` — already deep and tested through its interface. Leave it; use it as the model for item 1.

## Trino Persistent Session Hang Fix

- [x] Reproduce the reported "stuck on loading schema" hang against a real `trino` CLI.
- [x] Diagnose the root cause.
- [x] Fix Trino statement execution and update documentation.
- [x] Run the complete suite and record verification.

### Diagnosis

- Reported symptom: expanding a Trino profile in the Workspace sidebar left it stuck on the "loading schema..." placeholder indefinitely, with no error anywhere.
- Reproduced with a local mock Trino HTTP server plus the real `trino` CLI in the same "one persistent process, stdin held open" shape used by `lua/orbit/session.lua`: the mock server answered a query in under a second, but the CLI's stdout produced zero bytes for 5+ seconds while stdin stayed open. The buffered output only appeared the instant stdin was closed (EOF).
- Root cause: the Trino CLI only flushes its JSON/interactive-mode output on stdin EOF or process exit when stdout is a pipe, not a TTY. `session.lua`'s persistent-session design deliberately keeps stdin open indefinitely so one CLI process can serve many statements — which means the CLI never flushes, `session.lua`'s `stdout` handler never fires, the request's completion marker is never found, and the request hangs forever with no error path. This predates today's work; `tasks/todo.md`'s "Persistent Trino CLI Session Redesign" review already flagged it as unverified against a live CLI.
- SQLite's persistent session does not have this problem — verified live (`sqlite3`) flushes per statement while stdin stays open, matching the passing `tests/session_spec.lua` coverage. PostgreSQL's `psql` session was not re-verified live (no local PostgreSQL server available in this environment); it is unchanged by this fix.

### Fix

- Removed Trino's `session_command`/`session_request`/`session_output` connector hooks (`lua/orbit/connectors/trino.lua`) — they cannot work given the CLI's flush-on-EOF behavior.
- Added `adapters.supports_session(profile)`. `runner.lua` now runs a one-shot `trino` CLI invocation per statement (the original pre-session design, restored) when a profile's connector has no session support, and keeps the persistent-session path for connectors that do. `runner.cancel` distinguishes the two opaque handles it can now return.
- Statements, schema browsing, and object actions for Trino still serialize per profile (each spawned one at a time through the same `runner.run` seam); they simply no longer share a held-open CLI process.
- Updated `README.md` to describe SQLite/PostgreSQL's retained connection and Trino's per-statement CLI invocation separately, with the reason.

### Review

- Reproduced the hang and the fix against a real `trino` CLI (version 483) and a local mock Trino HTTP server: before the fix, a query never returned; after the fix, the same query resolves in well under a second.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (64 tests). `git diff --check` passed. `stylua` is not installed in this environment.

## Source Commenting Plan

- [x] Add concise module and implementation comments for invariants, asynchronous lifecycle guards, cache/session protocols, and backend-specific SQL or stream handling.
- [x] Add comments to user-interface modules where programmatic redraws, buffer/window reuse, and cross-tab asynchronous results have non-obvious behavior.
- [x] Leave self-explanatory functions and mechanical dispatch unannotated; do not alter executable code or tests.
- [x] Inspect the comment-only diff and run the complete headless test suite plus whitespace validation.

### Review

- Added comments only; source lines were not otherwise changed.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed.
