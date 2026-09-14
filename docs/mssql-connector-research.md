# Microsoft SQL Server Connector Research

Research date: 2026-09-11. Updated for the accepted redesign on 2026-09-14. Sources are limited to this repository and primary documentation from Microsoft, Arch Linux, Homebrew, FreeTDS, unixODBC, and upstream driver projects.

> [!IMPORTANT]
> **Superseded decision:** The original recommendation to build and distribute a custom SQL Server executable is no longer accepted. The implemented design targets Microsoft's user-installed Go `sqlcmd`. The investigation, source comparisons, output-fidelity findings, and platform constraints below are retained as historical research, but the former transport and distribution recommendation must not be used as current guidance.

## Accepted Decision

Orbit uses Microsoft's Go `sqlcmd` as a user-installed CLI. Users install and update it through Microsoft's [Download and install the sqlcmd utility](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17) instructions. Orbit resolves `sqlcmd` from `PATH` unless `options.executable` selects another command or path. Only the Go variant is targeted.

This redesign accepts the limitations of `sqlcmd` compatibility output in exchange for a much smaller ownership and maintenance surface. `:OrbitDoctor mssql` validates local profiles, executable resolution, version output, and `password_env` presence without opening a database connection.

No live `sqlcmd` or SQL Server verification occurred during the research or implementation. Server-version, client-version, TLS, authentication, retained-session, and result-fidelity claims are therefore not release-ready.

## Client And Server Scope

Orbit needs a SQL Server client, not a local database engine. The database engine can be remote, in a supported virtual machine or container, or supplied by Azure. Restrictions on where SQL Server itself can run must not be presented as restrictions on a machine running Neovim and `sqlcmd`.

- SQL Server 2025 on Linux supports selected RHEL and Ubuntu releases on x64. Arch Linux and Linux ARM64 are not supported native server platforms ([SQL Server on Linux requirements](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup?view=sql-server-ver17)).
- Microsoft SQL Server Linux container images are supported on Linux x86-64 hosts. Microsoft states that Rosetta, Prism, and QEMU translation environments are not tested or supported ([container requirements](https://learn.microsoft.com/en-us/sql/linux/containers/deploy?view=sql-server-ver17#system-requirements)).
- macOS has no native SQL Server engine. A development VM or emulated container may work, but that does not establish Microsoft support.
- SQL Server 2025 on Windows requires x64 hardware ([Windows SQL Server requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2025?view=sql-server-ver17)).

## Why Go sqlcmd

Microsoft's Go `sqlcmd` is standalone and available on Windows, macOS, Linux, and in containers ([variant documentation](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility?view=sql-server-ver17#sqlcmd-variants)). Microsoft documents installation methods for each supported client environment ([installation guide](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17)).

It also fits Orbit's existing retained-CLI boundary: one process can accept serialized batches for statement execution, schema acquisition, and completion prewarming. Retaining the process is intended to preserve transactions, temporary tables, and other SQL Server session state between requests, but that behavior still requires live verification.

The tradeoff is substantial: `sqlcmd` emits human-oriented compatibility text, not a structured arbitrary-result protocol. The accepted design is deliberately strict about detectable corruption while explicitly making no losslessness guarantee.

## Implemented Profile Contract

```json
{
  "name": "warehouse-mssql",
  "kind": "mssql",
  "options": {
    "host": "sql.example.com",
    "port": 1433,
    "database": "warehouse",
    "user": "orbit",
    "password_env": "MSSQL_PASSWORD",
    "trust_server_certificate": false,
    "schema_patterns": ["dbo", "reporting*"]
  }
}
```

Accepted fields are intentionally narrow:

- `host`, `database`, and `user` are required non-empty strings.
- `port` is an integer from `1` through `65535` and defaults to `1433`.
- `password` and `password_env` are non-empty strings when present and are mutually exclusive. One must resolve to a non-empty password before startup.
- `trust_server_certificate` is a boolean and defaults to `false`.
- `schema_patterns` is a non-empty array of non-empty schema globs.
- `executable` is a non-empty string selecting the user-installed CLI command or path.
- `confirm_mutations` is a boolean overriding mutation confirmation for the profile.

No arbitrary CLI argument field is accepted. Certificate paths, hostname overrides, encryption modes, named instances, integrated authentication, Kerberos, and Microsoft Entra authentication are not profile options.

## Command And Environment Contract

Orbit constructs this argument shape:

```text
<executable> -S tcp:<host>,<port> -d <database> -U <user> \
  -N mandatory [-C] -s <ASCII 31> -w 65535 -y 8000 -Y 8000 -x
```

`options.executable` supplies `<executable>` and otherwise it is `sqlcmd`. The bracketed `-C` appears only when `trust_server_certificate = true`; all other arguments and their order are fixed.

The generated arguments have these purposes:

- `-S tcp:<host>,<port>` fixes one TCP endpoint; named-instance discovery is unsupported.
- `-d <database>` fixes the profile database used for statements and schema browsing.
- `-U <user>` selects SQL username/password authentication.
- `-N mandatory` always requests encrypted transport. Profiles cannot weaken this setting.
- `-C` trusts the presented server certificate without validation. It permits man-in-the-middle attacks and is only an unsafe temporary development bypass.
- `-s`, `-w`, `-y`, and `-Y` configure separator-delimited output and large fixed limits; they do not make the output lossless.
- Orbit deliberately omits `-r` so SQL errors remain ordered in the framed stdout stream; `-x` disables sqlcmd variable substitution.

Passwords never appear in argv. Orbit removes every inherited environment variable whose name begins with `SQLCMD`, case-insensitively, and also removes the source variable named by `password_env`. It preserves unrelated inherited variables and sets the resolved password as `SQLCMDPASSWORD` in the child environment.

## Retained Session And Input Rules

Orbit retains one interactive Go `sqlcmd` process per connection profile and serializes all work sent to it. A profile change, disconnect, cancellation, process failure, or Neovim exit discards that process; later work starts another.

Orbit wraps each accepted statement between internal marker batches so it can identify a complete response. Lines containing a standalone `GO` batch separator are rejected rather than split, using Go sqlcmd's multiline string/comment state. Lines beginning with sqlcmd control commands are also rejected, including `:...`, `!!`, `ED`, `RESET`, `ON ERROR`, `EXIT`, and `QUIT`.

Mutation confirmation is conservative for T-SQL. Only a single `SELECT` without a top-level `INTO` is treated as read-only. Other operations, ambiguous input, and multiple statements require confirmation by default.

## Output Fidelity

MSSQL output parsing is strict best-effort and is not lossless.

- A unit-separator byte in a value can collide with the selected field separator. Some collisions produce a detectable width error; others may be indistinguishable from valid fields.
- A newline in a value can collide with record framing. Wrapping or embedded line breaks may be undetectable when they happen to resemble valid rows.
- A blank value in a one-column result is indistinguishable from the blank line Go `sqlcmd` uses between result blocks.
- Leading and trailing whitespace is trimmed from every heading and cell.
- Literal text equal to `NULL` is indistinguishable from SQL `NULL`; both remain text rather than receiving a false typed interpretation.
- Values can truncate at the configured type limits or wrap despite the large line width.
- Informational output mixed into a result is rejected rather than displayed.
- Multiple tabular result sets are unsupported and rejected when detected.
- Empty or duplicate headings, malformed underline rows, unexpected carriage returns, and detectable row-width mismatches are rejected.
- All cell data arrives as text and SQL types are not preserved.
- Statements capable of reproducing Orbit's internal marker rows can break in-band framing; the marker protocol is not a security boundary for adversarial SQL.

The Result grid must not be described as a byte-for-byte export or typed representation. MSSQL grids remain read-only.

## Schema And Editor Behavior

Schema acquisition stays within the profile's fixed database and reads user tables, views, and columns from SQL Server catalog views. Microsoft-shipped objects are excluded. Optional `schema_patterns` restrict the schemas shown without changing database permissions.

Orbit bracket-quotes every schema and object segment and escapes `]` as `]]`, for example `[sales].[order details]`. The same naming rules drive copied qualified names and completion. Completion offers schemas, tables, views, columns, and aliases from cached objects. It does not run `sqlcmd` while the user types.

Object actions provide a bracket-qualified `SELECT TOP (N)` sample statement and a columns view. Primary keys, foreign keys, indexes, definitions, and editable MSSQL grids are outside the implemented scope.

## Historical Alternatives

### Direct Driver Integration

The original investigation favored direct driver integration because structured rows could distinguish nulls, retain type-sensitive text, reject multiple sets deliberately, and avoid separator and newline ambiguity. It could also expose transport and authentication options more directly.

That direction was superseded because it would give Orbit a substantially larger executable, dependency, security, and maintenance responsibility. Its fidelity advantages remain relevant if the CLI format proves inadequate, but they are not part of the accepted design.

### Microsoft ODBC

Microsoft's ODBC Driver 18 does not list Arch Linux in its supported Linux matrix. Supported distributions are selected Alpine, Debian, Oracle Linux, RHEL, SLES, Ubuntu, and Azure Linux releases ([Microsoft support matrix](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/system-requirements?view=sql-server-ver17)).

ODBC is viable for environments already standardized on it, but Linux and macOS require driver-manager and driver registration, Windows introduces architecture concerns, and redistribution is governed by Microsoft's terms ([ODBC download page](https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server?view=sql-server-ver17)). Orbit does not use ODBC for the accepted Connector.

### Python And pyodbc

[`pyodbc`](https://github.com/mkleehammer/pyodbc) can expose structured rows, but users also need Python, pyodbc, an ODBC manager, and a SQL Server ODBC driver. Building it can require native tooling. This compounds the ODBC installation problem and is not the accepted default.

### FreeTDS

FreeTDS is available in Arch repositories and through Homebrew ([Arch package](https://archlinux.org/packages/extra/x86_64/freetds/), [Homebrew formula](https://formulae.brew.sh/formula/freetds)). It supports modern TDS versions and several authentication mechanisms ([FreeTDS configuration](https://www.freetds.org/userguide/freetdsconf.html)).

Its command-line tools are not a strong machine protocol. FreeTDS describes `tsql` as a diagnostic tool rather than a complete `isql` replacement ([FreeTDS utilities](https://www.freetds.org/userguide/usefreetds.html)). It remains an expert-operated alternative, not Orbit's MSSQL transport.

### Native Lua ODBC Or Direct TDS

Native Lua ODBC adds Lua ABI, compiler, driver-manager, and blocking-I/O concerns inside Neovim. A direct TDS implementation would make Orbit responsible for a large authentication, encryption, protocol, and type-decoding surface. Neither is justified for the accepted scope.

## Verification Required

Deterministic tests cover profile validation, argv construction, environment sanitization, marker extraction, parser rejection, bracket quoting, metadata SQL, completion, control-command rejection, and mutation classification. They do not establish real client/server behavior.

Before MSSQL support claims are release-ready, live testing must cover:

- The supported Microsoft Go `sqlcmd` version range and each advertised client environment.
- SQL authentication with both password sources.
- Trusted certificates, hostname mismatch, untrusted and expired certificates, mandatory encryption, and the explicit `-C` bypass.
- Retained transactions, temporary tables, session settings, cancellation, failure, and reconnection.
- Empty results, Unicode, whitespace, separators, line breaks, literal and SQL `NULL`, large values, wrapping, truncation, informational output, SQL errors, and multiple sets.
- Tables, views, columns, schema globs, unusual names, bracket escaping, actions, and completion against a live SQL Server.

Until that work occurs, documentation must distinguish implemented argument and parsing behavior from verified SQL Server, client, TLS, authentication, session, and fidelity support.
