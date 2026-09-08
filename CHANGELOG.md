# Changelog

All notable changes to Orbit.nvim are documented in this file.

## Unreleased

### Changed

- Schema browser labels now quote identifier segments when distinct catalog/schema combinations would otherwise look identical. Ordinary labels remain unchanged, and disambiguated labels stay stable while filtering.

### Fixed

- Prevented distinct schema objects with identical dotted labels, such as `"a.b"."c"` and `"a"."b.c"`, from sharing cached metadata or receiving each other's column completions.
- Kept colliding catalog/schema groups separate and made schema browser expansion and metadata state independent of display labels.

### Tests

- Added regression coverage for independent in-flight and cached metadata, column completion, metadata categories, namespace grouping, quoted-label collisions, and expansion across filtering and label changes.

## 0.2.5 - 2026-09-07

### Added

- Added Vertica support through the `vsql` CLI, including retained sessions, HTML result parsing, secure `VSQL_PASSWORD` handoff, schema browsing, completion, table and view actions, and metadata for columns, primary keys, foreign keys, projections, and view definitions.
- Added the `:OrbitStructure` panel for browsing SQL as an expandable outline in ordinary query tabs and the Workspace. The panel follows edits and cursor movement, supports filtering and navigation, and recursively outlines statements, `WITH` clauses, CTEs, set-operation branches, major clauses, and nested query blocks.
- Added Structure panel controls for statement-category visibility, grouping, alphabetical sorting, panel width, semantic icons, and an optional query-buffer mapping.
- Added execution from the Structure panel. Statements, query blocks, and `SELECT` clauses use their exact source ranges; other rows execute their containing statement, with stale ranges refreshed before execution.
- Added glob-style `*` and `?` matching to `schema_patterns` for PostgreSQL, SQLite, Trino, and Vertica while preserving exact-name matching.

### Changed

- Completion is now provided exclusively through the `blink.cmp` source; the native omnifunc and `_G.OrbitComplete` fallback were removed. The `completion` option now controls whether the blink source is enabled.
- Trino completion now offers configured catalogs and progressively traverses `catalog.`, `catalog.schema.`, and relations while retaining direct relation suggestions and discovered-schema fallbacks.
- The Workspace header now identifies the selected connection profile and returns to the default title when that profile is removed.
- Structure panel labels retain their complete normalized SQL for horizontal inspection instead of being truncated to the configured panel width.

### Fixed

- Filtered completion candidates by their typed prefix before blink's fuzzy matching, preventing unrelated cached objects from appearing.
- Made completion matching for identifiers, aliases, schemas, and catalogs case-insensitive.
- Prevented stale table and column suggestions after terminal clauses and set operators such as `LIMIT`, `OFFSET`, `FETCH`, `HAVING`, `UNION`, `INTERSECT`, and `EXCEPT`.
- Added explicit blink text-edit ranges so partial and quoted qualified identifiers are replaced cleanly without duplicated prefixes, dots, or quotes.
- Corrected blink completion item kinds, names, and database icons.

### Tests

- Added comprehensive Structure parser and panel coverage for statement classification, CTEs, set operations, nested clauses, procedural bodies, filtering, navigation, live refresh, configuration, icons, execution ranges, and stale-source protection.
- Added Vertica connector coverage for profile validation, secure command construction, HTML parsing, retained-session markers, schema acquisition, metadata, and object actions.
- Expanded completion coverage for filtering, case-insensitive matching, replacement ranges, PostgreSQL and Vertica qualification, and progressive Trino catalog traversal.
- Added shared mutation-SQL coverage for editable targets, primary-key changes, inserts, deletes, `NULL` values, no-op updates, and transactions.

## 0.2.1 - 2026-09-02

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
