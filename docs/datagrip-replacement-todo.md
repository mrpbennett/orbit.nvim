# DataGrip Replacement Todo

This backlog prioritizes a fast, native Neovim database workspace over exhaustive DataGrip feature parity.

## Foundation

- [ ] Choose the next connection profile kind based on the database used most often.
- [ ] Replace the fixed connector map with a connector registry and explicit capabilities.
- [ ] Add a connection-profile health check and `:QuarryTestProfile` command.
- [ ] Introduce a runner session abstraction while retaining one-shot CLI execution where appropriate.
- [ ] Add per-query-buffer persistent sessions for supported connection profile kinds.
- [ ] Add `:QuarryBegin`, `:QuarryCommit`, and `:QuarryRollback`.
- [ ] Show transaction state, running state, elapsed time, and active profile in status output.

## Statement Execution

- [ ] Resolve the statement under the cursor using SQL-aware boundaries.
- [ ] Support scripts containing multiple statements without confusing semicolons in strings or comments for statement separators.
- [ ] Add a command to run all statements in a query buffer deliberately.
- [ ] Add named parameter prompts and reuse values within a query-buffer session.
- [ ] Record execution duration, affected-row count, database query ID when available, and errors with source locations.
- [ ] Add `EXPLAIN` and `EXPLAIN ANALYZE` commands with dedicated result rendering.

## Result Grid

- [ ] Replace display-only result limits with a result provider that supports server-side paging.
- [ ] Display total row count when the connector can provide it.
- [ ] Add copy actions for selected rows, columns, and rectangular cell ranges.
- [ ] Export results as CSV, JSON, TSV, and SQL `INSERT` statements.
- [ ] Add result sorting and filtering, pushing work to the database when possible.
- [ ] Support editable table results only when an unambiguous primary key is available.
- [ ] Preview and confirm generated mutations before applying editable-grid changes.

## Schema Browser

- [ ] Generalize schema acquisition beyond tables, views, and columns.
- [ ] Show column nullability, defaults, and generated expressions.
- [ ] Show primary keys, foreign keys, indexes, constraints, triggers, sequences, routines, and views' definitions where supported.
- [ ] Add actions to copy object DDL and open table data.
- [ ] Add actions to generate bound select, count, insert, update, and delete statement templates.
- [ ] Add searchable object discovery across schemas and object kinds.
- [ ] Navigate foreign-key targets and object dependencies.

## Query Productivity

- [ ] Complete CTE names, aliases, qualified columns, functions, and SQL keywords.
- [ ] Provide an optional completion source for installed Neovim completion frameworks while retaining omnifunc support.
- [ ] Integrate optional external formatting and linting rather than owning SQL dialect formatting.
- [ ] Add searchable connection-profile query history with rerun, copy, delete, and favorite actions.
- [ ] Add query-buffer templates and configurable SQL snippets.
- [ ] Persist workspace layout, bound query buffers, and expanded schema-browser state.

## Connection Profile QoL

- [ ] Organize connection profiles into groups without putting credentials in project files.
- [ ] Support project-local references to connection profiles stored in the owner-protected profile file.
- [ ] Document CLI authentication, SSH tunnel, and environment-based secret workflows for each supported connector.
- [ ] Add additional connectors based on actual use: PostgreSQL first if applicable, then MySQL/MariaDB and SQL Server.

## Verification

- [ ] Add connector contract tests for every capability.
- [ ] Add integration coverage against disposable local databases for each supported connection profile kind.
- [ ] Test transaction lifecycle, cancellation, session cleanup, and reconnect behavior.
- [ ] Test schema metadata acquisition and result paging against real database responses.
- [ ] Run the complete headless Neovim test suite after each completed slice.
