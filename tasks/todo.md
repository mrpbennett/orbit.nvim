# Orbit.nvim v0.1 Plan

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
