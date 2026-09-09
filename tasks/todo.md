# Orbit.nvim v0.1 Plan

## Semantic Icon Colors

- [x] Add focused coverage for icon-only highlights in the Workspace and Structure panel.
- [x] Define semantic icon highlight groups using Catppuccin Mocha for dark backgrounds and Latte for light backgrounds.
- [x] Apply each highlight to the icon's exact byte range without changing existing row highlights or configured glyphs.
- [x] Document highlight customization and run complete verification.

### Settled Design

- Orbit remains dependency-free; `nvim-web-devicons` and `mini.icons` are not required for database-specific icons.
- Existing `icons` values remain strings and all current icon overrides continue to work.
- Icon groups use Catppuccin colors by default while remaining user-overridable through normal Neovim highlight configuration.
- Disclosure markers keep their existing appearance; semantic object and Structure icons receive color.

### Review

- Workspace and Structure icons now use semantic, icon-only highlight ranges; disclosure markers and labels retain their existing highlights.
- Mocha and Latte defaults follow `background`, survive colorscheme changes, and update without replacing user-owned highlight groups.
- Coverage verifies multibyte Nerd Font byte ranges, nested Workspace offsets, saved-query icons, and Structure current-row precedence.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` pass. `stylua` is unavailable.

## Saved Query Save Command

- [x] Add failing coverage for location and directory selection, filename normalization, overwrite protection, and cancellation.
- [x] Implement `:OrbitSave` for Workspace query buffers while preserving buffer identity and profile binding.
- [x] Refresh and reveal the saved query in the Workspace sidebar after a successful save.
- [x] Document the command and run complete verification.

### Settled Design

- `:OrbitSave` acts as Save As for any query buffer owned by a Workspace; existing saved queries retain normal `:w` behavior.
- Saving keeps the current buffer and its profile binding, gives it the chosen file name, and makes later `:w` write that file.
- Users choose from every configured Saved query location and its existing descendant directories; no directories are created.
- The filename prompt defaults to the current basename or `query.sql`, appends `.sql` when omitted, and cannot contain a path.
- Existing destinations require explicit overwrite confirmation, with cancellation as the default.
- A successful save rescans the affected location and expands the selected directory's ancestors so the file is visible immediately.
- Empty queries are saveable. With no configured locations, Orbit reports how to configure `saved_query_dirs`.

### Review

- `:OrbitSave` presents every available Saved query location and existing descendant directory, appends `.sql`, rejects path/control characters, and confirms overwrites.
- Successful saves retain the current buffer and profile binding, support later `:w`, rescan the selected location, clear an incompatible filter, and reveal the saved file.
- Descendant symlinks and symlink destinations are excluded so the picker cannot redirect a save outside the selected directory.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` pass. Independent standards and specification reviews found no remaining actionable issues. `stylua` is not installed.

## Saved Query File Management

- [x] Add focused regression coverage for the saved-query action menu and rename, move, and delete flows.
- [x] Implement safe saved-query filesystem operations, including stale-source checks, conflict refusal, and cross-filesystem move fallback.
- [x] Keep loaded query buffers synchronized with rename, move, and delete operations without losing edits or profile bindings.
- [x] Refresh overlapping saved query locations, reveal successful rename/move destinations, and retain useful sidebar focus after deletion.
- [x] Update Workspace help and README documentation, then run formatting, the complete test suite, and diff checks.

### Settled Design

- Orbit is a focused organizer for reusable `.sql` files inside configured saved query locations, not a general filesystem manager.
- Saved queries are managed items; directories are existing organizational containers and move destinations. Orbit does not create, rename, or delete directories.
- Context-sensitive `a` opens Open, Preview, Rename, Move, and Delete actions for a saved query while retaining connector actions for schema objects. `<CR>` and `P` remain direct shortcuts.
- Rename prompts with the current filename stem, appends `.sql` when omitted, and uses the same filename validation as `:OrbitSave`.
- Move offers every existing directory across all configured saved query locations, including roots and nested directories.
- Rename and Move refuse existing destinations. A successful operation clears the filter, expands the destination ancestors, and reveals the saved query.
- An open saved query follows its renamed or moved path while preserving buffer identity, cursor position, unsaved edits, Workspace ownership, and profile binding.
- Delete always requires confirmation. If the saved query is open, its contents remain in the same unnamed query buffer; modified content remains modified. The sidebar retains its filter and focuses the nearest remaining item.
- Move creates its destination exclusively so it cannot overwrite a raced file. It uses a hard link on the same filesystem and an exclusive copy fallback otherwise, removes the source only after success, and cleans up the destination if source removal fails.
- Every configured location containing the old or new path is rescanned so overlapping saved query locations remain consistent. Symbolic-link and stale-node protections continue to prevent mutations through unsupported entries.

### Review

- Saved-query `a` actions now open, preview, rename, move, and delete reusable `.sql` files while keeping the existing `<CR>` and `P` shortcuts and connector action menu.
- Rename and Move create destinations exclusively, preserve loaded buffers and unsaved edits, reject conflicts and stale directories, support cross-filesystem copies, and refresh overlapping locations before revealing the result.
- Confirmed deletion preserves loaded contents in an unnamed query buffer, rejects a file replaced during confirmation, retains the filter, and focuses the nearest remaining node.
- Coverage exercises the action menu, filename normalization, conflict refusal, modified buffers, overlapping roots, successful cross-filesystem fallback, cleanup after source-removal failure, and deletion focus.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` pass. `stylua` is not installed in this environment.

## MySQL README Onboarding

- [x] Close the MySQL profile details block consistently with the other connectors.
- [x] Provide complete Oracle MySQL and MariaDB-client credential/profile workflows.
- [x] Correct MySQL schema, metadata, editable-result, and SSH/TLS guidance.
- [x] Validate every JSON and shell example, then run Markdown whitespace checks.

### Review

- MySQL onboarding now provides copy-paste credential setup and complete profiles for Oracle MySQL and MariaDB clients, plus explicit TCP, Docker, socket, remote, and SSH-tunnel guidance.
- The MySQL details block matches the other connector blocks. The default database is no longer redundantly repeated in `schema_patterns`.
- Workspace metadata and editable-result documentation now includes MySQL. SSH tunnel guidance distinguishes hostname verification from CA-only verification and calls out the MariaDB-client limitation.
- Both complete profile documents pass `jq`, the credential script passes `bash -n`, and `git diff --check` passes.

## MySQL Connector Plan

- [x] Add failing coverage for MySQL profile validation, client commands, XML framing/parsing, schema capabilities, and editable mutations.
- [x] Implement the full MySQL 8.x connector and register the `mysql` connection-profile kind.
- [x] Add MySQL-aware tokenization for backticks, comments, escapes, and qualified-name splitting without changing existing dialect behavior.
- [x] Verify retained execution and schema acquisition against the local MySQL 8.4 fixture.
- [x] Update user and domain documentation, run complete verification, and independently review the implementation.

### Settled Design

- `kind: "mysql"` targets MySQL 8.x servers through either Oracle MySQL 8 or MariaDB CLI clients; MariaDB servers are unsupported and rejected.
- Profiles require `database`; optional database patterns extend that default. TCP and Unix-socket settings are mutually exclusive.
- `client_family` defaults to `mysql`. TLS mappings are exact per family and unsupported MariaDB-client modes fail validation.
- Credentials remain client-managed. Orbit does not accept a MySQL password or use `MYSQL_PWD`.
- Retained sessions use XML framing. One row-producing result set is supported, with explicit errors for multiple sets and arbitrary binary-cell limitations.
- Qualified names use backtick-quoted database and object segments. MySQL lexical behavior is selected without regressing existing connectors.

### Review

- Added the `mysql` connection-profile kind with strict TCP/socket, client-family, TLS, and credential validation; retained XML sessions; MySQL 8 server enforcement; schema metadata/actions; qualified completion; and editable table results.
- Generated text uses mode-independent hex literals. Connector-owned `--skip-force` makes a SQL error terminate the client so MySQL rolls back an unfinished editable batch before Orbit reconnects.
- MySQL-aware tokenization handles backticks, default double-quoted strings, backslash escapes, `#` comments, and MySQL's whitespace requirement for `--` comments without changing existing connector behavior.
- Live MySQL 8.4 verification passed through both Oracle MySQL 8.4 and MariaDB 12.3 clients, including value fidelity, schema patterns, keys/indexes, warning-only stderr, user/internal field-name collisions, trailing comments, error recovery, editable writes, and rollback after a forced mid-batch duplicate-key failure.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` pass. `stylua` is unavailable. Independent Standards and Spec reviews found no remaining code issues after follow-up fixes.
- No commit or GitHub write was made under repository policy.

## Trino Schema Loading Regression

- [x] Create a deterministic performance regression test for a large Trino schema snapshot.
- [x] Measure the current schema acquisition/render path and isolate the post-`248e222` bottleneck.
- [x] Apply the smallest correction and preserve schema-object identity behavior.
- [x] Run focused and complete verification, then record the root cause and results.

### Review

- Root cause: `248e222` allocated and JSON-serialized structural identities for every object twice during first tree render, including a separate namespace record per object. Large Trino schemas therefore spent most of their load time in local bookkeeping rather than acquisition.
- `schema.identity` now uses an unambiguous length-prefixed tuple. Grouping retains and labels each unique catalog/schema once, and object labels are deferred until an object action needs one.
- Regression coverage exercises a 100,000-object Trino snapshot through tree population and initial render with a 500ms budget.
- Verification: the full suite passes via `nvim --headless -u NONE -l tests/run.lua`; `git diff --check` passes. `stylua` is unavailable in this environment.

## Schema Object Identity Deepening

- [x] Confirm scope and ownership with the user; distinguish Schema object from its display label in the domain glossary.
- [x] Deepen the existing schema module around structural identity and grouping; make acquisition reads accept schema objects and remove completion's key encoder.
- [x] Use structural identity for schema browser expansion and metadata; preserve ordinary labels and disambiguate collisions before filtering.
- [x] Verify collisions through acquisition, completion, grouping, and schema browser interfaces, including metadata categories and expansion across filtering.
- [x] Run the full suite, inspect the diff, and complete an independent code review.

### Settled Design

- Scope includes acquisition, completion, schema browser state, and catalog/schema grouping; no new module, seam, or adapter.
- The existing pure schema module owns structural identity. Callers must not reconstruct or interpret its encoding.
- Schema acquisition accepts schema objects instead of dotted storage keys; there is no persisted-key migration or established external key contract.
- Display labels do not determine identity. Preserve ordinary labels; quote identifier segments for collisions based on the complete acquired schema, before filtering.
- Keep connector-owned qualified names, completion insertion and name matching, refresh semantics, loaded-empty metadata behavior, defaults, and keybindings unchanged.
- Test through existing module interfaces, using the established runner substitution seam rather than direct cache mutation.

### Review

- Structural identity and collision-aware display labels now live in `lua/orbit/schema.lua`; acquisition and schema browser state use opaque identities, while completion passes schema objects directly.
- Regression tests first reproduced acquisition collisions, namespace merging, and shared schema browser state. Coverage now verifies independent in-flight and cached metadata, qualified/unqualified and INSERT/UPDATE completion, category isolation, stable labels, and expansion across filtering and label changes.
- Verification: 42 focused schema/completion/schema-browser tests passed; `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. An independent reviewer also ran the full suite with `-i NONE` successfully.
- Independent Standards and Spec reviews reported no actionable findings. PostgreSQL/Trino/Vertica were not tested against live databases; collision tests use real connectors with the existing runner substitution seam.
- No formatter configuration was found and `stylua` is unavailable; no formatting-only changes were made. No commits or GitHub writes were made.

## 0.2.5 Release Plan

- [x] Convert the current `Unreleased` notes into the missing `0.2.1` historical section.
- [x] Add a dated `0.2.5` section covering every user-visible change from `v0.2.1` through `HEAD`.
- [x] Run the complete test suite and release-file whitespace checks.
- [x] Inspect the final diff and determine whether a local `v0.2.5` tag can be created without violating repository GitHub policy.

### Scope

- `0.2.5` covers Vertica support, the Structure panel and its execution/configuration features, progressive Trino completion, blink-only completion behavior, glob-style schema patterns, Workspace profile identity, and completion fixes.
- This repository has no version constant, package manifest, or release workflow; Git tags are its only discoverable version source.
- GitHub release publication is excluded because workspace policy is read-only and the configured `gh` credentials currently return HTTP 401.

### Review

- `CHANGELOG.md` now preserves the features shipped by `v0.2.1` in a dated historical section and records the complete `v0.2.1..HEAD` user-visible delta under `0.2.5`.
- Verification: `nvim --headless -u NONE -l tests/run.lua` passed (163 tests). `git diff --check` passed.
- No version constant or package manifest exists to update; Git tags are the repository's only version source.
- A release commit, local `v0.2.5` tag, and GitHub release were not created because repository policy prohibits commits and GitHub writes. The configured `gh` credentials also return HTTP 401.

## Structure View Options Plan

- [x] Add a nested `structure_view` setup object for alphabetical sorting, statement-category visibility, and grouping by type, all enabled by default.
- [x] Apply category filtering to complete statement subtrees and render enabled non-empty groups in DDL, DML, SELECT, Other order.
- [x] Keep category groups initially expanded, statement nodes initially collapsed, and sort statements alphabetically with stable source-order ties.
- [x] Document the options, add focused regression coverage, and run complete verification.

### Settled Design

- `structure_view` owns `sort_alphabetically`, `show_ddl`, `show_dml`, `show_select`, `show_other`, and `group_by_type`; `structure_width` remains a separate geometry option.
- Disabling a category hides each matching top-level statement and its complete subtree.
- Grouping adds only enabled, non-empty category headings in fixed DDL, DML, SELECT, Other order.
- Alphabetical sorting applies within each group, or across all visible statements when grouping is disabled.
- Category headings start expanded; existing statement expansion behavior remains unchanged.

### Review

- `structure_view` now owns grouping, category visibility, and alphabetical sorting while `structure_width` remains the panel geometry option. Every display field defaults to enabled.
- Presentation-only category nodes reuse the existing tree controls without changing parser nodes, statement navigation, or execution ranges. Text filtering continues to match statement-tree labels rather than category headings.
- Coverage verifies fixed group order, initial expansion, alphabetical and source ordering, category filtering, empty-group omission, ungrouped sorting, and nested defaults.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent review found no code defects; its documentation finding was resolved. `stylua` is not installed in this environment.

## Structure Panel Execution Plan

- [x] Confirm which Structure elements execute exact source ranges and which fall back to their containing statement.
- [x] Add regression coverage for exact `SELECT` execution, containing-statement fallback, configurable mapping, and result focus.
- [x] Route Structure panel execution through the existing query-buffer execution path with an explicit source window.
- [x] Run focused and complete verification, review the diff, and record the results.

### Settled Design

- `<leader>E` executes the Structure element highlighted by the panel cursor and remains configurable through `keymaps.execute`.
- Statement, query-block, and `SELECT`-clause rows execute their exact end-exclusive source ranges. Connector errors are acceptable when extracted text is not independently executable.
- Other rows execute their containing top-level statement.
- Successful execution keeps focus in the Structure panel unless existing result-focus configuration requests otherwise; execution failures retain the existing focused diagnostic split.
- Execution continues through `orbit.query` so profile resolution, mutation confirmation, running-state control, cancellation, diagnostics, and Result grid behavior remain intact.

### Review

- Structure rows now execute through `orbit.query`: statement, query-block, and `SELECT`-clause rows use exact end-exclusive ranges, while navigation-only rows use their containing statement.
- Execution retains the query buffer's source context while preserving panel focus. Profile-selection retries return to the panel and reject changed or closed source buffers rather than executing stale ranges.
- Changed-tick validation refreshes stale Structure ranges before execution, and configured execution mappings explicitly take precedence over fixed panel mappings.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent standards/spec review found no actionable defects. `stylua` is not installed in this environment.

## PostgreSQL Completion Edit Plan

- [x] Add a Blink-level regression proving a PostgreSQL completion replaces the typed qualifier instead of appending quoted text to it.
- [x] Carry the exact SQL completion replacement span from scope analysis through completion items.
- [x] Emit Blink `textEdit` items for exact replacement while preserving labels, kinds, and existing Trino completion behavior.
- [x] Run focused and complete tests, validate whitespace, and record the root cause and verification.

### Review

- Root cause: Orbit supplied quoted, dotted PostgreSQL names through Blink's inferred `insertText` path, which Blink documents for exclusively alphanumeric text; its guessed replacement range malformed the completion preview around a typed schema qualifier.
- Scope analysis now carries the exact qualifier start position, and Blink receives an explicit `textEdit` replacing the typed target with the connector's canonical completion word.
- Regression coverage verifies both `public` and `public.` become `"public"."orders"`; existing connector completion tests preserve Trino, SQLite, and Vertica behavior.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment. Independent review found no actionable issues.

## Trino Schema Allowlist Plan

- [x] Confirm whether a Trino profile's schema allowlist may include catalogs other than `options.catalog`.
- [x] Generalize the allowlist as `schema_patterns` for all relational profiles and apply it to metadata discovery.
- [x] Add focused profile and metadata-statement tests, document the setting, and run the full test suite.

## Trino Schema Allowlist Review

- `schema_patterns` maps Trino catalogs to exact schema allowlists; PostgreSQL and SQLite accept non-empty arrays of exact schema names.
- Trino and PostgreSQL include the allowlist in their metadata queries; SQLite exposes its fixed `main` schema only when listed.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## Architecture Review 2026-08-25 (current)

- [x] Scan the recent Result grid and connector/session/schema-acquisition hot spots using the domain model and deletion test.
- [x] Validate deepening candidates against tests and completed architecture work.
- [x] Produce, verify, and open a temporary HTML report with before/after visuals.

### Review

- Report: `/tmp/architecture-review-20260825-155140.html`; opened in the existing browser session.
- Top recommendation: deepen Schema acquisition around Connector capability interpretation; a focused reproduction confirmed Trino primary-key acquisition raises `unsupported schema node`.
- No ADRs exist under `docs/adr/`; completed Connector resolver, naming, and Schema tree work was not re-suggested.
- Verification: `nvim --headless -u NONE -l tests/run.lua`, HTML validation, and `git diff --check` passed.

## Schema Acquisition Deepening

- [x] Make recognized unsupported table metadata an expected empty acquisition and reject unknown categories.
- [x] Key cached and in-flight Schema acquisition by full connection-profile identity, isolating old generations.
- [x] Preserve refresh intent when a refresh arrives during an ordinary acquisition.
- [x] Make synchronous reads profile-aware and remove test-only cache mutation functions.
- [x] Add interface-level regression coverage, run the complete suite, and review the change.

### Settled Design

- Schema acquisition remains the sole module and seam; no additional seam is introduced.
- Profile name locates state while `kind` and validated `options` define its identity.
- An identity change hides old cached data immediately. Old in-flight work may finish only for its original callbacks and cannot populate or satisfy the new generation.
- A recognized category unsupported by a Connector returns an empty result; an unknown category is an error.
- Failed refreshes retain successful data only within the same identity. A refresh arriving during ordinary acquisition runs afterward and coalesces.
- All reads accept the full connection profile. Tests populate state through the acquisition interface.

### Review

- Schema acquisition owns the canonical table metadata categories. Recognized unsupported categories, including columns, return an empty result without running a statement; unknown categories return an error.
- Cache entries use connection-profile kind and options as identity. New identities receive empty state while old in-flight work remains isolated with its original callbacks.
- One internal acquisition state machine coalesces ordinary requests, active refreshes, queued refreshes, and refreshes requested reentrantly from completion callbacks.
- Completion reads cached rows with the full connection profile, and tests populate cache state through acquisition rather than mutation helpers.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent standards and spec reviews found no remaining issues. `stylua` is not installed.

## 0.2.0 Release

- [x] Update the changelog and README for the completed release changes.
- [ ] Run release verification and inspect the complete staged diff.
- [ ] Commit the release and create the local `v0.2.0` tag.

### Review

- Pending.

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

Files: `lua/orbit/browser.lua` (401 lines, delete), `lua/orbit/workspace.lua`, `lua/orbit/init.lua:54,72-77`, `tests/browser_spec.lua` (delete), `tests/workspace_spec.lua`, `tests/run.lua`, `README.md`.

- Problem: the Schema browser and the Workspace sidebar are the same module written twice — duplicated `object_name`, `postgres_name`, filter-line editing, `set_lines`/`render`, `focus_filter`, `show_help`, `select_action`/`run_action`, `copy_name`, generation counter — and they have already diverged (the browser has no metadata categories and no saved queries).
- Solution: delete `browser.lua` and the redundant `OrbitBrowse` command. The Workspace profile pane is the sole schema-browser workflow.
- Wins: deletion test concentrates complexity; 391 lines gone with no behaviour lost; divergence stops at the source.

- [x] Decide the sole Workspace mounting for schema browsing.
- [x] Delete `OrbitBrowse` and `browser.lua`.
- [x] Fold `tests/browser_spec.lua` coverage into the Workspace tests.
- [x] Update command, keymap, result-grid, and configuration documentation; run the complete suite and record verification.

#### Scoped Design

- Decision: schema browsing exists only in the dedicated Workspace tabpage. Do not add a split-mounted Workspace mode or a command that duplicates profile-pane actions.
- Use `<CR>` on a profile to bind it to the Workspace query buffer and `l`/`h` to load, expand, and collapse its schema tree. Double-click retains its bind-and-toggle behavior.
- Keep `OrbitWorkspace` as the explicit toggle command. `workspace.open` retains that toggle behavior for this command only; the new browse operation must use a non-toggling internal ensure/open path. `OrbitWorkspaceClose` continues to close the dedicated tabpage.
- Delete `schema_width`, the `browse` keymap, and their documentation. Retain `workspace_sidebar_width`.
- Delete `lua/orbit/browser.lua`, `OrbitBrowse`, their eager module-load assertion, and `tests/browser_spec.lua`. Do not retain compatibility aliases or dead browser state.

#### Acceptance Coverage

- Retain Workspace coverage for profile binding, tree expansion, table metadata, and asynchronous action results returning to the Workspace tabpage after focus changes.
- Update README commands, configurable mappings, the Workspace workflow, editable sample-statement wording, and configuration tables. Remove standalone-browser and browse-keymap documentation.
- Verification: run `nvim --headless -u NONE -l tests/run.lua`, `git diff --check`, and `stylua --check lua tests` when `stylua` is installed. Record unavailable formatter or live-connector gaps in this review section.

#### Review

- The standalone browser module, its test file, its loader assertion, and `schema_width` were deleted.
- Follow-up decision: remove the redundant `OrbitBrowse` command, mapping, and Workspace browse API. Use `:OrbitWorkspace`, then `<CR>` to bind a profile and `l`/`h` to expand or collapse its schema tree.
- Workspace coverage retains schema navigation and asynchronous action-result placement after focus changes.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

### 3. Push object naming behind the connector seam — Strong

Files: `lua/orbit/completion.lua:15-25, 34-51, 61-84`; `lua/orbit/workspace.lua:46-51, 449-458`; `lua/orbit/browser.lua:18-23, 192-201`; `lua/orbit/connectors/*.lua`.

- Problem: identifier quoting and catalog qualification are connection-profile behaviour, but nine `profile.kind` checks decide them outside `connectors/`. Each connector already has a private `identifier`/`literal`/`qualified` and exposes none of it, so three callers reimplement quoting.
- Solution: add `qualified_name(options, row)`, `completion_word(options, row, prefix)`, and `schema_of(options, qualifier)` to the connector interface; delete the kind checks from the Workspace, the Schema browser, and completion.
- Wins: three adapters make the seam real; a fourth connector kind needs no grep; naming becomes testable per adapter with no buffer. Also supplies the cache key for item 4 and the node labels for item 1.

- [x] Add the naming functions to all three connectors.
- [x] Remove naming `profile.kind` checks from `completion.lua` and `workspace.lua`.
- [x] Add per-connector naming and completion-qualification tests.
- [x] Run the complete suite and record verification.

#### Settled Design

- A qualified name is the canonical SQL-pasteable identifier for a schema object: SQLite quotes the object name, PostgreSQL quotes schema and object names, and Trino quotes catalog, schema, and object names.
- Completion qualifier recognition belongs to the connector. PostgreSQL accepts both quoted and unquoted schema prefixes; completion output remains canonically quoted.
- Retain `adapters.lua` as the normalized dispatch seam for this slice. Add the naming forwards there and defer item 5's broader connector-resolution decision.

#### Implementation

- [x] Add connector-owned qualified-name, completion-word, and qualifier-to-schema functions with adapter forwards.
- [x] Replace Workspace and completion naming kind checks with the naming seam.
- [x] Add focused per-connector naming and completion qualification coverage.
- [x] Run the complete suite and record verification.

#### Review

- `qualified_name`, `completion_word`, and `schema_of` are connector capabilities forwarded by `adapters`. Completion and copied Workspace object names no longer duplicate connector-specific naming rules.
- SQLite copied names are now canonical quoted identifiers; its completion words remain unquoted. PostgreSQL accepts quoted and unquoted schema prefixes while returning quoted completion words. Trino preserves existing unquoted completion words and uses quoted catalog/schema/object names for copied objects.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua --check lua tests` could not run because `stylua` is not installed.

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

- Problem: `adapters` is shallow: most of its interface mirrors connector functions solely to resolve `profile.kind`, forward backend options, and supply fallback errors. Growing a connector therefore requires editing both its module and `adapters`.
- Decision: `adapters.connector(profile) -> connector, err` is the sole profile-kind resolver. It returns the canonical unsupported-kind error. Retain only shared `validate_options` and generic JSON `parse` behavior in `adapters`; remove its forwarding API without compatibility aliases.
- Resolution scope: resolve a connector once per user operation and retain it through that operation. Schema acquisition passes its resolved connector through the execution path so statement construction and parsing do not resolve it again. Sessions retain the connector for their lifetime and replace it when their profile signature changes.
- Connector contract: connector methods retain their current `options`-based signatures. A connector owns backend-specific behavior; operation modules own connection-profile selection, lifecycle, and user-facing errors.
- Optional capabilities: an absent connector method means unsupported. The owning domain preserves current behavior: Result grids report read-only editing, session code reports unavailable persistent sessions, and Workspace/schema UI omits unavailable actions and metadata. Do not add no-op methods to every connector.
- Tests: replace forwarding tests with resolver coverage for every supported kind and an unknown kind. Keep behavior tests with their connectors and add operation-level tests for capability fallbacks and errors.

- [x] Decide whether to do this before or after item 3.
- [x] Collapse the forwarding functions and update callers.
- [x] Run the complete suite and record verification.

#### Review

- `adapters` now resolves connector kinds once and retains shared profile-option validation plus generic JSON parsing; connector-specific forwards were deleted.
- Runner, persistent sessions, schema acquisition, completion, Workspace actions, and editable-result writes invoke resolved connector capabilities directly. Schema acquisition, Workspace metadata actions, and editable writes pass the same resolved connector into Runner.
- Added resolver, unsupported-kind, schema handoff, and session profile-change regression coverage. The profile-change test also fixed the session exit path for CLI failures without stderr.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

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

## Editable Result Grid Discoverability Fix

- [x] Render an explicit editable action bar and read-only explanation in every Result grid.
- [x] Name eligible sample-table Result grids after their table instead of the anonymous query buffer.
- [x] Add visible-output regression coverage and run the complete suite.

- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed.

## BigQuery Connector Research

- [x] Map BigQuery requirements onto Orbit's connector, runner, schema acquisition, completion, and result seams.
- [x] Compare first-party `bq`, REST, and client-library transports using official Google Cloud sources.
- [x] Define an MVP, follow-up scope, risks, tests, and live release gates in `docs/bigquery-connector-research.md`.

### Review

- Recommended a one-shot `bq query` connector, conditional on live JSON fidelity and paging tests before release.
- Identified required core work beyond a connector file: remote result-limit context and GoogleSQL backtick tokenization/completion.
- No live verification was possible because `bq` is not installed in this environment.
- Documentation verification: `git diff --check` passed.

## Editable Result Grid Plan

- [x] Add a database-agnostic editable-result model with ordered rows, row states, row selection, and local undo.
- [x] Add PostgreSQL and SQLite editability, primary-key, literal, and transactional mutation capabilities; leave Trino read-only.
- [x] Carry known table identity from schema-browser sample statements through execution into the Result grid.
- [x] Make editable Result grids `acwrite` buffers and implement local row operations, cell prompting, `:w`, `:wq`, `:q!`, and `:e!`.
- [x] Add focused model, adapter, and Result grid coverage; document the capability and run the full suite.

### Settled Design

- Only Result grids whose table identity originates in the Schema browser are editable in this slice. Arbitrary statements remain read-only.
- PostgreSQL and SQLite are editable when a primary key is present. Trino is read-only.
- Cell edits use a focused-cell prompt via `i` or `<CR>`; rendered table text never becomes the data source.
- A write is one confirmed transaction. A failed transaction retains every local change.

### Review

- [x] Record verification and review findings.

## Vertica Connector Plan

- [x] Implement the `vsql` connector with required host, user, and database profile options; optional password, port, sslmode, schema_patterns, executable, and arguments.
- [x] Use secure `VSQL_PASSWORD` environment handoff, persistent `vsql` sessions, and strict HTML-table parsing for lossless result rows and session markers.
- [x] Acquire Vertica tables, views, columns, primary keys, foreign keys, and projections; add view-definition and schema-object actions.
- [x] Register and validate `kind: "vertica"`, document the connection profile, add focused regression coverage, and run the full test suite and available formatter.

### Review

- Vertica profiles require host, user, and database. Optional passwords are supplied through `VSQL_PASSWORD`; `vsql` arguments never contain them.
- The connector parses `vsql --html` tables, preserving HTML-encoded values and a configured NULL marker. Persistent-session responses are delimited by a marker table.
- Schema acquisition lists user tables and views, with columns, primary keys, foreign keys, and projections for tables, plus view definitions through object actions.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `vsql` and `stylua` are not installed, so live Vertica and formatter verification could not run.

### Settled Design

- Vertica is a complete registered connector. Its connection profiles require `host`, `user`, and `database`.
- Passwords are optional, stored only in the owner-protected profile file, and passed exclusively through `VSQL_PASSWORD`; they never enter command arguments.
- `vsql` persistent sessions emit HTML tables. The connector strictly parses those tables and decodes entities so result values containing delimiters or line breaks remain intact.
- Schema acquisition excludes Vertica administrative system catalog objects. User tables expose columns, primary keys, foreign keys, and projections; views expose columns and a definition action.

- Review fixes: cancelling a local insert now removes it rather than generating an invalid delete; reused read-only grids remove editable mappings and autocommands; generated SQL must remain unchanged before its result can be editable; a successful transaction clears local changes even if reload fails; stale schema callbacks cannot replace a newer result; and `NULL` input preserves SQL null semantics.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed.

## Inline Editable Result Grid Plan

- [x] Add a focused regression test for entering, committing, and navigating inline cell edits without opening a prompt.
- [x] Replace the editable-grid `i` prompt with a temporary buffer edit that commits the focused cell on leaving Insert mode.
- [x] Preserve cell navigation, local undo, database-write behavior, and safe redraws after an inline edit.
- [x] Update Result grid editing documentation and run the complete headless test suite plus whitespace validation.

### Design

- `i` enters Insert mode at the focused cell in the Result grid; no `vim.ui.input` prompt is opened.
- Leaving Insert mode commits only the focused cell's displayed text into the editable-result model, then redraws the grid and keeps the cell focused.
- The grid remains model-owned: structural table text, headers, and footers are never interpreted as database data. Inline mode temporarily exposes only the focused cell for editing and restores the rendered grid immediately after commit.
- `NULL` continues to represent a SQL null when entered as the complete cell value.

### Review

- `i` and `<CR>` enter Insert mode directly in the focused cell. Leaving Insert mode commits the cell to the local model and restores the formatted grid for continued navigation.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## Multiple Saved Query Locations

- [x] Confirm the public configuration shape, terminology, validation, ordering, expansion, and refresh behavior.
- [x] Record the saved-query location term and configuration-shape rationale.
- [x] Replace `saved_query_dir` with validated, normalized `saved_query_dirs` configuration.
- [x] Render and independently refresh multiple named saved-query roots.
- [x] Add focused configuration and Workspace regression coverage.
- [x] Update public documentation and run complete verification.

### Settled Design

- `saved_query_dirs = { { Work = "~/sql/work" }, { Personal = "~/sql/personal" } }` replaces `saved_query_dir`; each key is displayed exactly and array order controls root order.
- Setup rejects malformed entries, duplicate names, and duplicate normalized paths. Paths are expanded and made absolute during setup.
- Every top-level root starts collapsed. Unavailable and empty roots remain visible, overlapping roots are allowed, and symbolic links remain ignored.
- Refreshing any saved-query directory rescans only its containing top-level root.

### Review

- [x] Record implementation outcomes and verification.

- `setup()` now converts the public singleton-map array into ordered `{ name, path }` records, rejects malformed or duplicate locations, and reports the removed singular option instead of silently ignoring it.
- Workspace roots preserve configured labels and order, remain visible when unavailable, carry root-scoped expansion identity for overlapping paths, and refresh only the selected directory's containing root.
- Coverage includes replacement during repeated setup, lexical path normalization, invalid entries, unavailable and overlapping roots, independent refresh and expansion, and ignored file and directory symlinks.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. A follow-up code review found no remaining correctness or specification issues. `stylua` is not installed in this environment.

## Clause-Aware SQL Autocomplete

Plan: `~/.claude/plans/sprightly-seeking-blanket.md`. Replaces the two single-line regexes in `completion.lua` with a hand-rolled tokenizer + statement/alias scope resolver, enabling clause-aware table/schema/column/alias completion. ADR: `docs/adr/0002-hand-rolled-sql-tokenizer-for-completion.md`.

- [x] Build `lua/orbit/sql/tokenizer.lua` (pure lexer: strings, quoted identifiers, comments, paren depth, never throws) with `tests/sql_tokenizer_spec.lua`.
- [x] Build `lua/orbit/sql/scope.lua` (statement-at-cursor boundary, clause detection, alias/comma-join/CTE/derived-table scope) with `tests/sql_scope_spec.lua`.
- [x] Rewrite `lua/orbit/completion.lua`: change `M.items` signature to `(profile, lines, row, col)`, consume tokenizer/scope, add Table/View/Column/Schema/Alias kinds, connector-driven qualifier-depth matching, prefix-first sort. Update `tests/completion_spec.lua` in lockstep.
- [x] Add `M.config.completion` toggle (default `true`) in `init.lua`; guard `apply_completion` and `query.lua`'s direct `completion.attach`/`prewarm` call site.
- [x] Build `lua/orbit/blink.lua` blink.cmp source module with `tests/blink_spec.lua`; document the LazyVim `sources.providers`/`sources.default` snippet in the README (no nvim-cmp bridge in v1).
- [x] Register new modules/specs in `tests/run.lua`.
- [x] Update README's completion section; run the complete test suite and record verification.

### Settled Design

- Tokenizer and statement/alias scope resolution are pure, dialect-agnostic, and never throw on malformed input; all dialect naming/quoting stays behind the existing `completion_word`/`schema_of`/`qualified_name` connector seam.
- Alias scope is bounded to the statement containing the cursor; CTEs and derived tables are recognized structurally but resolve to zero columns, not an error.
- Unqualified column completion with multiple tables in scope shows every table's columns, annotated by source, never deduplicated.
- blink.cmp has no runtime provider-registration API, so its source ships with a documented one-line user-side config snippet rather than auto-registration; no nvim-cmp bridge in v1.
- Qualifier depth (schema.table vs. catalog.schema.table) is generic: rows are filtered by comparing the typed segments against each row's own empty-prefix canonical decomposition, not a hardcoded schema-only check. A bonus `Schema`-kind item is only offered when 2+ distinct next-level segments are genuinely ambiguous, additive to the direct table listing so it never disturbs the single-schema case.
- `M.items(profile, line, cursor)` became `M.items(profile, lines, row, col)`; `M.attach`/`M.prewarm` signatures are unchanged.

### Review

- [x] Record implementation outcomes and verification.

- New `lua/orbit/sql/tokenizer.lua` (pure lexer) and `lua/orbit/sql/scope.lua` (statement/clause/alias-scope resolution) replace the two single-line regexes in `completion.lua`; `completion.lua` is the only place dialect naming (`completion_word`/`schema_of`) is consulted.
- `lua/orbit/blink.lua` is a new optional blink.cmp source with no require-time dependency on blink.cmp itself; `completion._profile_for_buffer` was exported so both it and tests can resolve a buffer's profile without duplicating that logic.
- A real bug was caught by the test suite, not by inspection: `object_name`'s `ipairs({row.catalog, row.schema, row.name})` silently stopped at the leading `nil` when catalog/schema were absent, so every alias-qualified/unqualified column lookup returned zero columns until it was rewritten as three individual field checks.
- CONTEXT.md was corrected (PostgreSQL is a supported backend, not just Trino/SQLite) and gained **Table alias** and **Derived table** glossary entries; ADR `docs/adr/0002-hand-rolled-sql-tokenizer-for-completion.md` records the tokenizer-vs-regex decision.
- Verification: `nvim --headless -u NONE -l tests/run.lua` (111 tests, all passing) and `git diff --check` passed. `stylua` is not installed in this environment.

## Trino Catalog Autocomplete

- [x] Separate Trino's full catalog/schema/table completion path from its shortened unqualified insertion text.
- [x] Offer configured catalogs and progressively complete catalog, schema, then table/view segments.
- [x] Preserve direct relation suggestions and autocomplete behavior for non-Trino connectors.
- [x] Add focused catalog-qualified, configured-empty-namespace, fallback, and regression coverage.
- [x] Run the complete headless test suite, available formatter, and whitespace validation.

### Settled Design

- At a `FROM`-family position, existing relation suggestions remain available alongside Trino catalogs.
- With `schema_patterns`, only its top-level keys are catalog suggestions; without it, only `options.catalog` is suggested.
- Completion traverses one namespace at a time: catalog, schema, then table/view. Catalog and schema selections include the trailing dot needed to continue traversal.
- Exact configured schemas remain suggestible without cached relations. Empty or wildcard schema lists derive concrete schema names from cached metadata.
- Explicit qualification and relation insertion are separate concerns, so explicitly typing the default catalog works without changing shortened unqualified relation suggestions.
- PostgreSQL, SQLite, and Vertica behavior remains unchanged.

### Review

- [x] Record implementation outcomes and verification.

- Trino's connector now exposes configured completion namespaces and a full metadata path independently of its shortened direct relation insertion text.
- Catalog and schema candidates include trailing dots, exact configured schemas work without relation rows, and empty or wildcard schema lists use concrete cached schema names.
- Legacy default-schema completion remains available when the first qualifier is not a configured catalog; other connectors retain their existing completion path.
- The completion glossary and README describe progressive namespace traversal.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. `stylua` is not installed in this environment.

## Workspace Header Spacing And Identity

- [x] Add regression coverage for the agreed header spacing, selected-profile title, and filter editing.
- [x] Render the selected profile in the Workspace title and preserve the agreed selection lifecycle.
- [x] Run focused and complete tests, whitespace validation, and independent review.

### Review

- The header now separates help from Filter and content while preserving the existing Filter highlight and editable-filter behavior.
- The title shows the selected profile after binding, schema expansion, refresh, or double-click, and falls back to Orbit Workspace when that profile is removed.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent spec review found no mismatches. `stylua` is not installed.

## Structure Panel

- [x] Extend SQL tokenization for PostgreSQL dollar-quoted bodies and cover statement-separator edge cases.
- [x] Add a pure statement outline model with source ranges, DDL/DML/SELECT/Other classification, normalized labels, grouping, and filtering.
- [x] Add a reusable far-right Structure panel per tabpage with live query-buffer tracking, current-statement selection, navigation, filtering, and toggle/close behavior.
- [x] Register `:OrbitStructure`, `structure_width`, and the disabled-by-default `keymaps.structure`; prevent Workspace query-window discovery from selecting the panel.
- [x] Document commands, configuration, keybindings, and best-effort procedural SQL behavior.
- [x] Run focused and complete tests, formatting when available, whitespace validation, and independent review.

### Settled Design

- `:OrbitStructure` toggles a focused far-right panel in normal tabs and the Workspace; one panel is reused per tabpage.
- The panel follows the active query buffer, highlights its current statement, refreshes after edits, and remains open with `No query buffer` if its source disappears.
- Fixed non-collapsible DDL, DML, SELECT, and Other groups omit empty sections and preserve source order within each group.
- Statement labels omit comments, normalize whitespace, and truncate to the configured `structure_width` (default 40).
- `<CR>` navigates without closing, `/` starts case-insensitive substring filtering, `q` closes, and `<Esc>` clears a filter before closing.
- Parsing is dependency-free and best-effort. Unsupported procedural constructs are represented conservatively rather than emitting known-false navigation targets.
- `keymaps.structure` is configurable and disabled by default.

### Review

- [x] Record implementation outcomes and verification.

- Added a pure SQL outline model and a tab-local Structure panel that tracks edits from both user input and buffer API changes.
- Statement extraction ignores comments and quoted semicolons, supports PostgreSQL dollar quotes, keeps recognized compound bodies coarse, and avoids crossing completed definitions into later statements.
- `:OrbitStructure`, `structure_width`, and `keymaps.structure` are documented and integrated without changing the existing default mappings.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent standards and specification reviews found no remaining actionable issues. `stylua` is not installed in this environment.

## Hierarchical Structure Panel

- [x] Replace flat grouped entries with source-order statement trees.
- [x] Parse leading WITH clauses into CTE declaration nodes, CTE body query nodes, and an outer query node.
- [x] Preserve stable node identity, live refresh, filtering, current-source selection, and exact navigation ranges.
- [x] Add expandable rendering with `l` to expand/enter, `h` to collapse/return to parent, and ordinary `j`/`k` movement.
- [x] Update Structure panel documentation and run complete verification and independent review.

### Settled Design

- Each top-level statement is a root node labeled with its normalized SQL preview and rendered in source order without category headings.
- A statement beginning with WITH contains a WITH node. Each CTE is a child of WITH and owns one body-query child; the outer query is a sibling of WITH.
- Parent nodes start collapsed. Expansion state uses stable source-based node IDs and survives live redraws when those IDs remain valid.
- `l` expands the selected node or moves to its first child; `h` collapses it or moves to its parent. `j` and `k` retain normal line movement.
- `<CR>` navigates to the selected element's first meaningful token. Filtering retains matching nodes and their ancestors.

### Review

- [x] Record implementation outcomes and verification.

- The Structure panel now renders source-order statement trees with WITH, CTE declaration, CTE body-query, and outer-query nodes.
- Tree state starts expanded, survives compatible live redraws, filters through matching ancestors, and uses `h`/`l` for parent/collapse and child/expand traversal while preserving normal `j`/`k` movement.
- Nested nodes carry exact source ranges for current-cursor highlighting and `<CR>` navigation. Malformed CTE syntax falls back atomically to its statement root.
- The UI and SQL model now document their state, range, filtering, parsing, and lifecycle invariants in the repository's established comment style.
- Verification: `nvim --headless -u NONE -l tests/run.lua`, the focused malformed-CTE test, and `git diff --check` passed. Independent standards and specification reviews found no remaining behavioral issues. `stylua` is not installed in this environment.

## Collapsed Structure And Set Branches

- [x] Start every parent node collapsed when a Structure panel first opens.
- [x] Split CTE bodies at top-level UNION, INTERSECT, and EXCEPT operators into sibling query nodes.
- [x] Keep nested parenthesized SELECT clauses inside their owning query branch.
- [x] Preserve exact source highlighting/navigation and collapse state across live refreshes.
- [x] Update documentation and comments; run complete verification and independent review.

### Settled Design

- A newly opened panel shows only collapsed statement roots. Each `l` action reveals exactly one additional level.
- Set-operation modifiers (`ALL` or `DISTINCT`) belong to the separator, not either query label.
- Only operators at the CTE body's own token depth split branches; nested SELECT clauses do not become siblings.

### Review

- [x] Record implementation outcomes and verification.

- New panels register every parent as collapsed; user expansion survives compatible live refreshes while newly discovered parents still default collapsed.
- CTE bodies now expose one query node per top-level UNION, INTERSECT, or EXCEPT branch. ALL/DISTINCT separators are omitted from labels and nested SELECT clauses remain in their owning branch.
- Malformed set-operation and incomplete WITH structures fall back atomically to the statement root rather than exposing partial children.
- Verification: `nvim --headless -u NONE -l tests/run.lua`, focused exact-label/ID coverage, and `git diff --check` passed. Independent reviews found no remaining behavioral issues. `stylua` is not installed in this environment.

## Detailed Structure Panel Plan

- [x] Add a regression fixture based on the PostgreSQL database-structure statement, covering deeply nested scalar subqueries and long labels.
- [x] Extend the pure Structure model to recursively expose query blocks and their major clauses without treating ordinary function-call parentheses as queries.
- [x] Preserve complete node labels in the panel buffer so `structure_width` controls window geometry rather than deleting SQL text.
- [x] Preserve stable IDs, source ranges, collapsed-by-default behavior, filtering, cursor highlighting, and exact navigation for the new nodes.
- [x] Update Structure panel documentation and run focused tests, the complete headless suite, formatter when available, and whitespace validation.

### Proposed Hierarchy

- Statement roots retain source order and remain collapsed initially.
- Existing `WITH -> CTE -> query branch` nodes remain intact.
- Each query block exposes source-ordered `SELECT`, `FROM`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW`, `ORDER BY`, `LIMIT`, and `OFFSET` clause nodes when present.
- Parenthesized query blocks found inside clauses become nested query nodes and recurse through the same clause model. Parenthesized expressions and function calls remain part of their owning clause rather than creating noisy false structure.
- Full normalized labels remain in the scratch buffer with wrapping disabled, allowing normal horizontal scrolling instead of irreversible ellipsis truncation.

### Acceptance Notes

- The supplied PostgreSQL statement must expose `user_schemas`, `relations`, the outer query, and nested query blocks for extensions, enum types, schemas, columns, constraints, indexes, triggers, and RLS policies.
- Every visible nested node must navigate to its first meaningful source token and participate in source-cursor highlighting and filtering.
- Incomplete SQL must continue to fall back conservatively without raising an error or exposing known-false ranges.

### Review

- The Structure model now exposes major SELECT-query clauses and recursively outlines parenthesized SELECT/WITH blocks, including every metadata branch represented by the supplied PostgreSQL statement.
- Top-level and nested set operations remain distinct query branches. Incomplete nested WITH syntax and contextual identifiers fall back conservatively instead of creating known-false nodes.
- Full normalized labels remain in the non-wrapping panel buffer and can be inspected with horizontal scrolling; `structure_width` now controls only panel geometry.
- Regression coverage verifies nested IDs/ranges, collapse traversal, filtering, cursor tracking, navigation, expansion persistence, long labels, set operations, and contextual LIMIT/OFFSET cases.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent review found no actionable findings. `stylua` is not installed in this environment.

## Structure Panel Semantic Icons Plan

- [x] Extend the flat icon defaults with configurable statement-category and Structure-element glyphs, retaining documented `icons.query` as a fallback for `icons.query_block`.
- [x] Render a semantic icon after the existing disclosure column for every Structure row, reusing `icons.folder` for category groups.
- [x] Add regression coverage for every icon distinction, custom overrides, ungrouped statements, and the legacy query-icon fallback.
- [x] Document the new icon options and define query block, common table expression, and clause in the domain glossary.
- [x] Run the complete headless suite, configured formatter when available, and whitespace validation; record the outcome below.

### Settled Design

- Disclosure markers continue to communicate expansion state; semantic icons independently communicate row identity.
- Category groups use the existing folder icon. Statements use separate DDL, DML, SELECT, and Other icons even when grouping is disabled.
- WITH containers, common table expressions, query blocks, and clauses each use one structural icon; clause labels continue to distinguish individual clause types.
- Icons remain unhighlighted Nerd Font glyphs and are configurable through the existing flat `icons` setup table.
- `query_block` is the canonical public term. A configured legacy `query` icon remains the fallback when `query_block` is not explicitly configured.

### Review

- Structure rows retain their disclosure marker and now show distinct configurable icons for category groups, statement categories, WITH containers, common table expressions, query blocks, and clauses.
- The documented legacy `icons.query` key supplies `icons.query_block` until the canonical key is explicitly configured. Repeated and failed setup calls preserve that precedence correctly.
- README configuration and Structure-panel guidance list the new defaults, while the domain glossary now defines query block, common table expression, and clause.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent review found no remaining issues. `stylua` is not installed in this environment.

## Schema Namespace Icon Plan

- [x] Add a configurable `icons.schema` default for catalog/schema namespace rows.
- [x] Render the schema icon independently from the expand/collapse marker.
- [x] Cover the default and custom rendering behavior with regression tests.
- [x] Document the option and run the full verification suite.

### Settled Design

- Catalog and schema components remain one namespace row, matching the existing schema grouping model.
- `icons.schema` defaults to ``; `icons.profile` remains the icon for connection-profile rows.

### Review

- Schema namespace rows now show a semantic icon after their disclosure marker in both collapsed and expanded states.
- User configuration can override `icons.schema` without changing other tree markers or profile icons.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent standards and spec reviews found no remaining actionable issues. `stylua` is not installed in this environment.

## Collapsed Table Group Icon Plan

- [x] Render `icons.with` beside the table group's disclosure marker.
- [x] Keep collapsed and expanded disclosure markers visible for table and view groups.
- [x] Add regression coverage for collapsed and expanded groups.
- [x] Run the full test suite and review the final diff.

### Settled Design

- A collapsed table group renders exactly as `> 󰙅 tables 10` before indentation.
- Expanded table groups retain `icons.with` beside `icons.expanded`; view groups continue using only the standard markers.

### Review

- Table groups use `icons.with` as a semantic icon beside their standard disclosure marker.
- Regression tests cover collapsed and expanded table/view groups and their child object icons.
- Verification: `nvim --headless -u NONE -l tests/run.lua` and `git diff --check` passed. Independent review found no remaining actionable issues.
