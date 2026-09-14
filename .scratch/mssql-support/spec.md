# Microsoft SQL Server Support

Status: implemented-unverified-live

## Goal

Add an MSSQL Connector backed by Microsoft's user-installed `sqlcmd`, without making Orbit own or distribute a compiled executable.

## Contract

- Require a compatible `sqlcmd` on `PATH` or through `options.executable`; Orbit never downloads or updates it.
- Support SQL authentication over a retained interactive `sqlcmd` process, with passwords outside argv.
- Require `host`, `database`, and `user`; accept `port`, mutually exclusive `password`/`password_env`, `trust_server_certificate`, `schema_patterns`, `executable`, and `confirm_mutations`.
- Parse strict separator-delimited text into ordered row maps and reject detectable malformed widths, empty/duplicate headings, and multiple tabular results.
- Document that `sqlcmd` output is not lossless: separators, line breaks, blank one-column values, `NULL` text, large values, and other formatting can be ambiguous or transformed before Orbit receives them.
- Keep MSSQL Result grids read-only and represent every accepted cell as text; do not claim typed SQL `NULL` when the CLI cannot distinguish it from literal `NULL` text.
- Reject standalone `GO`, use bracket-qualified names, confirm T-SQL mutations conservatively, and browse user tables/views/columns in one database.
- Diagnose the user-installed executable locally with `:OrbitDoctor [kind]`; remove `:OrbitInstall` and all Orbit helper release infrastructure.
- Require deterministic parser/session tests and live `sqlcmd` integration before making server, client-version, TLS, authentication, or fidelity claims.

## Decisions

See `tasks/todo.md` under "Microsoft SQL Server Design" and `docs/mssql-connector-research.md`.
