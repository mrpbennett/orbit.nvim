# Changelog

All notable changes to Orbit.nvim are documented in this file.

## Unreleased

### Changed

- Made the dedicated Workspace tabpage the sole schema-browsing workflow. `:OrbitBrowse`, its mapping, configuration, implementation, and tests were removed.
- Moved schema-object naming and completion qualifier handling into each connector, preserving canonical quoted identifiers for copied object names.
- Replaced the forwarding-heavy adapter API with one connector resolver. Execution, schema acquisition, sessions, completion, Workspace actions, and editable result writes now use connector capabilities directly.
- Updated documentation to describe Workspace schema browsing and the supported configuration surface.

### Fixed

- Retained sessions now replace their CLI process after a connection profile changes and safely report CLI exits that provide no stderr output.

### Tests

- Added coverage for connector resolution, direct connector capabilities, one-resolution schema handoff, unsupported profile kinds, and session replacement after profile changes.

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
