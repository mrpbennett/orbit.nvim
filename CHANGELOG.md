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
