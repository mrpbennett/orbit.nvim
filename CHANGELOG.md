# Changelog

All notable changes to Orbit.nvim are documented in this file.

## Unreleased

### Added

- Added clause-aware SQL completion: a dependency-free tokenizer and statement/alias-scope resolver replace the old single-line regexes, so tables, schemas, columns, and table aliases complete correctly in `SELECT`, `WHERE`, `ON`, `GROUP BY`, `ORDER BY`, `FROM`-family clauses, `INSERT INTO t (...)`, and `UPDATE t SET ...`, across multi-line statements. Table aliases resolve to their columns, including old-style comma joins; unqualified columns are offered from every table in scope, annotated by source.
- Added an optional `blink.cmp` completion source (`orbit.blink`) offering the same suggestions; since blink.cmp has no runtime source-registration API, it must be added to the user's own `sources.providers`/`sources.default` config (documented in the README).
- Added a `completion` configuration option (default `true`) to disable both the native omnifunc attachment and the blink.cmp source.
- Added multiple named saved-query locations (`saved_query_dirs`), replacing the single `saved_query_dir` option, each rendered as its own root in the Workspace sidebar.

### Changed

- Saved-query roots in the Workspace sidebar now start collapsed instead of expanded.

### Tests

- Added tokenizer, statement/clause/alias-scope, completion, and blink.cmp source coverage, including malformed-input resilience, multi-statement alias isolation, comma-joins, CTE/derived-table graceful degradation, and per-dialect qualifier depth.

## 0.2.0 - 2026-08-25

### Changed

- Made the dedicated Workspace tabpage the sole schema-browsing workflow. `:OrbitBrowse`, its mapping, configuration, implementation, and tests were removed.
- Moved schema-object naming and completion qualifier handling into each connector, preserving canonical quoted identifiers for copied object names.
- Replaced the forwarding-heavy adapter API with one connector resolver. Execution, schema acquisition, sessions, completion, Workspace actions, and editable result writes now use connector capabilities directly.
- Deepened Schema acquisition around connector capabilities, connection-profile identity, and refresh coordination. Cached schema rows now invalidate when a profile changes, unsupported metadata is empty rather than an execution failure, and explicit refreshes coalesce without losing their intent.
- Updated documentation to describe Workspace schema browsing and the supported configuration surface.

### Fixed

- Retained sessions now replace their CLI process after a connection profile changes and safely report CLI exits that provide no stderr output.
- Prevented Trino sample-table results from failing while checking unsupported primary-key metadata.

### Tests

- Added coverage for connector resolution, direct connector capabilities, one-resolution schema handoff, unsupported profile kinds, session replacement after profile changes, and Schema acquisition capability, identity, and refresh behavior.

## 0.1.0 - 2026-08-25

### Added

- Added PostgreSQL support through the `psql` CLI, including CSV result parsing, schema discovery, metadata actions, and protected password handoff through `PGPASSWORD`.
- Added retained, serialized CLI sessions for SQLite and PostgreSQL, plus explicit disconnect and automatic reconnection after session failure.
- Added the dedicated Workspace with connection-profile selection, lazy schema trees, table metadata, saved-query discovery, filtering, and persistent result grids.
- Added editable SQLite and PostgreSQL sample-table result grids with primary-key-based updates, transactional writes, local undo, and inline cell editing.

### Changed

- Added connector-specific schema-object actions, canonical qualified-name copying, and SQL completion for cached objects and columns.
- Added schema allowlists for Trino, PostgreSQL, and SQLite profile discovery.

### Fixed

- Restored Trino execution to one CLI process per statement because its interactive JSON output does not flush while stdin remains open.
