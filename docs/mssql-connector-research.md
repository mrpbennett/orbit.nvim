# Microsoft SQL Server Connector Research

Research date: 2026-09-11. Updated for the selectable-transport design on 2026-09-16. Sources are limited to this repository and primary documentation from Microsoft, OpenJDK, Arch Linux, Homebrew, FreeTDS, unixODBC, and upstream driver projects.

> [!IMPORTANT]
> **Current decision:** Orbit preserves Microsoft's user-installed Go `sqlcmd` as the default MSSQL transport and also implements a profile-selected JDBC transport with the jTDS 1.3.1 JDBC driver. The original recommendation to build and distribute a custom compiled SQL Server executable remains superseded. The prior `sqlcmd` investigation, source comparisons, output-fidelity findings, and platform constraints below remain applicable to that transport.

## Accepted Decision

Under [ADR-0004](./adr/0004-selectable-mssql-transports.md), the MSSQL Connector has two transports. A profile that omits `transport`, or explicitly selects `sqlcmd`, preserves the existing user-installed Microsoft Go `sqlcmd` path. A profile with `transport = "jdbc"` selects Orbit's retained Java-helper transport and initially requires `driver = "jtds"`. The MSSQL transport is Orbit's execution mechanism; jTDS is the JDBC driver library used by the JDBC transport, not a Connector or standalone client.

Users install and update `sqlcmd` through Microsoft's [installation guide](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17). JDBC users provide a [Java 11-or-newer source-file runtime](https://openjdk.org/jeps/330) and explicitly download the [jTDS 1.3.1 JAR](https://sourceforge.net/projects/jtds/files/jtds/1.3.1/). Orbit ships only its [Java source helper](../cmd/orbit-mssql/OrbitMssql.java); it does not bundle, download, install, or update Java or jTDS.

The two transports make different tradeoffs. `sqlcmd` keeps the smaller dependency and maintenance surface but its compatibility text is inherently lossy. JDBC/jTDS adds a helper and driver dependency to support explicit domain credentials, retained JDBC state, framed structured rows, and distinct SQL `NULL`. The accepted structured profile and protocol are implemented in the [MSSQL JDBC transport](../lua/orbit/connectors/mssql_jdbc.lua).

Java 25 source-file helper execution and jTDS 1.3.1 class loading were verified locally. Live JDBC verification passed on Linux against SQL Server `16.0.4252.3` with explicit domain credentials, server-reported NTLM, and the unsafe certificate-trust bypass. Orbit set `useNTLMv2` and `ssl=require`; the account could not independently inspect the negotiated NTLM version or server-side encryption state. Secure certificate-chain validation rejected the test server's chain because its issuer was absent from the JVM trust store. No live `sqlcmd` verification occurred, and JDBC observations must not be generalized beyond the tested combination.

## Client And Server Scope

Orbit needs a SQL Server client transport, not a local database engine. The database engine can be remote, in a supported virtual machine or container, or supplied by Azure. Restrictions on where SQL Server itself can run must not be presented as restrictions on a machine running Neovim with `sqlcmd` or Java/jTDS.

- SQL Server 2025 on Linux supports selected RHEL and Ubuntu releases on x64. Arch Linux and Linux ARM64 are not supported native server platforms ([SQL Server on Linux requirements](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup?view=sql-server-ver17)).
- Microsoft SQL Server Linux container images are supported on Linux x86-64 hosts. Microsoft states that Rosetta, Prism, and QEMU translation environments are not tested or supported ([container requirements](https://learn.microsoft.com/en-us/sql/linux/containers/deploy?view=sql-server-ver17#system-requirements)).
- macOS has no native SQL Server engine. A development VM or emulated container may work, but that does not establish Microsoft support.
- SQL Server 2025 on Windows requires x64 hardware ([Windows SQL Server requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2025?view=sql-server-ver17)).

## JDBC/jTDS Transport

The JDBC profile shape, including the complete approved domain-password endpoint and SQL-password form, is documented in [README: JDBC Transport With jTDS](../README.md#jdbc-transport-with-jtds). Profiles expose structured fields only: `host`; optional string or array `database`; either `port` or `instance`; `authentication`; `trust_server_certificate`; `driver_path`; optional `java_executable`; `schema_patterns`; and mutation confirmation. Raw JDBC URLs and arbitrary driver properties are rejected. Port and instance are mutually exclusive, and the port defaults to `1433` when neither is provided.

`authentication.type` is either `sql_password` or `domain_password`. Both require `user` and exactly one of `password` or `password_env`; domain-password authentication also requires `domain` and enables NTLMv2. Orbit resolves the password before launch but excludes it from argv, the JDBC URL, and the sanitized Java child environment. The helper receives it only through the length-framed stdin request after startup.

TLS is encrypted without plaintext fallback. The default maps to jTDS `ssl=authenticate`, which upstream defines as requiring a certificate signed by an authority trusted by the JVM. jTDS does not document hostname matching for this mode, so it is not claimed equivalent to a modern hostname-verified TLS client. The explicit `trust_server_certificate = true` bypass maps to `ssl=require`: encryption remains, but certificate-chain validation is disabled and man-in-the-middle attacks become possible.

One Java helper and JDBC connection are retained per connection profile. Statements and schema acquisition share that connection, preserving the existing MSSQL schema browser, bracket-qualified names, completion, mutation policy, `GO` rejection, and read-only Result grids. Structured results retain ordered column labels, string values, and distinct SQL `NULL`; non-row statements return an empty result. Empty or duplicate labels and multiple tabular result sets are rejected.

Ordinary SQL errors leave the helper and connection available. Connection failures and malformed protocol terminate that retained generation. Active cancellation terminates the JVM and work queued on it; later work launches a fresh helper and reconnects. Neovim shutdown explicitly closes retained children.

For JDBC profiles, `:OrbitDoctor mssql` resolves Java, checks the configured password source and JAR readability, and runs the [source helper](../cmd/orbit-mssql/OrbitMssql.java) in doctor mode. This verifies Java 11+ source-file execution and exact jTDS 1.3.1 class loading without opening a database connection. The omitted-transport `sqlcmd` diagnostics remain unchanged.

jTDS 1.3.1 is old, so compatibility with other Java runtimes, SQL Server versions, domain environments, and TLS configurations cannot be inferred. The tested Java 25, SQL Server `16.0.4252.3`, domain-password, NTLM, and unsafe-trust combination passed; successful trusted-chain and hostname behavior remain unverified.

## Default Go sqlcmd Transport

Microsoft's Go `sqlcmd` is standalone and available on Windows, macOS, Linux, and in containers ([variant documentation](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility?view=sql-server-ver17#sqlcmd-variants)). Microsoft documents installation methods for each supported client environment ([installation guide](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17)).

It also fits Orbit's existing retained-CLI boundary: one process can accept serialized batches for statement execution, schema acquisition, and completion prewarming. Retaining the process is intended to preserve transactions, temporary tables, and other SQL Server session state between requests, but that behavior still requires live verification.

The tradeoff is substantial: `sqlcmd` emits human-oriented compatibility text, not a structured arbitrary-result protocol. The accepted design is deliberately strict about detectable corruption while explicitly making no losslessness guarantee.

## sqlcmd Profile Contract

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

- `host` and `user` are required non-empty strings. `database` is a required non-empty string or non-empty array of unique non-empty strings.
- `transport` may be the literal `sqlcmd`; omitting it selects the same transport.
- `port` is an integer from `1` through `65535` and defaults to `1433`.
- `password` and `password_env` are non-empty strings when present and are mutually exclusive. One must resolve to a non-empty password before startup.
- `trust_server_certificate` is a boolean and defaults to `false`.
- `schema_patterns` is a non-empty array of non-empty schema globs.
- `executable` is a non-empty string selecting the user-installed CLI command or path.
- `confirm_mutations` is a boolean overriding mutation confirmation for the profile.

No arbitrary CLI argument field is accepted. Certificate paths, hostname overrides, encryption modes, named instances, integrated authentication, Kerberos, and Microsoft Entra authentication are not profile options.

## sqlcmd Command And Environment Contract

Orbit constructs this argument shape:

```text
<executable> -S tcp:<host>,<port> -d <default-database> -U <user> \
  -N mandatory [-C] -s <ASCII 31> -w 65535 -y 8000 -Y 8000 -x
```

`options.executable` supplies `<executable>` and otherwise it is `sqlcmd`. The bracketed `-C` appears only when `trust_server_certificate = true`; all other arguments and their order are fixed.

The generated arguments have these purposes:

- `-S tcp:<host>,<port>` fixes one TCP endpoint; named-instance discovery is unsupported.
- `-d <default-database>` selects the string value or first array entry as the retained session's initial database; schema acquisition uses three-part names for every array entry.
- `-U <user>` selects SQL username/password authentication.
- `-N mandatory` always requests encrypted transport. Profiles cannot weaken this setting.
- `-C` trusts the presented server certificate without validation. It permits man-in-the-middle attacks and is only an unsafe temporary development bypass.
- `-s`, `-w`, `-y`, and `-Y` configure separator-delimited output and large fixed limits; they do not make the output lossless.
- Orbit deliberately omits `-r` so SQL errors remain ordered in the framed stdout stream; `-x` disables sqlcmd variable substitution.

Passwords never appear in argv. Orbit removes every inherited environment variable whose name begins with `SQLCMD`, case-insensitively, and also removes the source variable named by `password_env`. It preserves unrelated inherited variables and sets the resolved password as `SQLCMDPASSWORD` in the child environment.

## sqlcmd Retained Session And Input Rules

Orbit retains one interactive Go `sqlcmd` process per connection profile and serializes all work sent to it. A profile change, disconnect, cancellation, process failure, or Neovim exit discards that process; later work starts another.

Orbit wraps each accepted statement between internal marker batches so it can identify a complete response. Lines containing a standalone `GO` batch separator are rejected rather than split, using Go sqlcmd's multiline string/comment state. Lines beginning with sqlcmd control commands are also rejected, including `:...`, `!!`, `ED`, `RESET`, `ON ERROR`, `EXIT`, and `QUIT`.

Mutation confirmation is conservative for T-SQL. Only a single `SELECT` without a top-level `INTO` is treated as read-only. Other operations, ambiguous input, and multiple statements require confirmation by default.

## sqlcmd Output Fidelity

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

## Shared Schema And Editor Behavior

Schema acquisition reads user tables, views, and columns from SQL Server catalog views. A string-valued `database` retains the original single-database behavior. An array uses its first entry as the retained session's default and acquires every listed database through three-part catalog-view names; JDBC uses the login's default when `database` is omitted. Microsoft-shipped objects are excluded. Optional `schema_patterns` restrict the schemas shown in every selected database without changing database permissions.

Orbit bracket-quotes every database, schema, and object segment and escapes `]` as `]]`. String profiles retain names such as `[sales].[order details]`; array profiles use `[database].[sales].[order details]`. The same naming rules drive copied qualified names and completion. Completion offers databases, schemas, tables, views, columns, and aliases from cached objects. It does not run a transport while the user types.

Object actions provide a bracket-qualified `SELECT TOP (N)` sample statement and a columns view. Primary keys, foreign keys, indexes, definitions, and editable MSSQL grids are outside the implemented scope.

## Historical Alternatives

### Direct Driver Integration

The original investigation favored direct driver integration because structured rows could distinguish nulls, retain type-sensitive text, reject multiple sets deliberately, and avoid separator and newline ambiguity. It could also expose transport and authentication options more directly.

The original compiled executable and distribution proposal was superseded because it would give Orbit a substantially larger binary, dependency, security, and release responsibility. ADR-0004 later accepted a narrower form of direct driver integration: an Orbit-owned Java source helper, a user-installed Java runtime, and a user-provided jTDS JAR. This retains the fidelity advantages without Orbit distributing a compiled runtime or driver, while accepting maintenance of the helper and protocol.

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

## Verification Status

Deterministic Lua and Java suites cover sqlcmd compatibility, JDBC profile validation, secure process construction, both authentication-property mappings, both TLS-property mappings, framing, structured values, SQL `NULL`, malformed responses, ordinary and fatal errors, multiple-result rejection, cancellation, reconnection, Doctor, and shutdown cleanup.

Live verification on Linux used Java 25, jTDS 1.3.1, and SQL Server `16.0.4252.3` Enterprise Edition (64-bit). Explicit domain credentials negotiated `NTLM`. The live suite passed Unicode, embedded line feeds, empty strings, literal and SQL `NULL`, schema acquisition, retained temporary-table state, ordinary-error recovery, active cancellation, queued-work termination, and reconnection. The `ssl=authenticate` attempt reached the server but failed PKIX chain construction because the corporate issuer was absent from the JVM trust store; the explicit unsafe `ssl=require` path then passed and still required TLS.

Remaining live gaps include multi-database acquisition, cross-database permissions, Unicode database names, mixed collations, the `sqlcmd` transport, JDBC SQL-password authentication, direct password fields, named instances, successful trusted-chain validation, hostname, expired-certificate and plaintext-refusal scenarios, transaction rollback, large/binary values, connection loss, and multiple-result behavior against a real server. Compatibility claims must remain limited to the exact tested combination.
