# Microsoft SQL Server Connector Research

Research date: 2026-09-11. Sources are limited to this repository and primary documentation from Microsoft, Go, Arch Linux, Homebrew, FreeTDS, unixODBC, and upstream driver projects.

## Executive recommendation

Add an `mssql` connector backed by a small Orbit-owned `orbit-mssql` helper built with Microsoft's pure-Go [`go-mssqldb`](https://github.com/microsoft/go-mssqldb/tree/v1.11.0) driver. Ship prebuilt helper binaries for Linux, macOS, and Windows. Keep one helper process and one `database/sql.Conn` per active connection profile, exchanging newline-delimited JSON over stdin/stdout.

This is the most reliable cross-platform path, especially for Arch Linux:

- `go-mssqldb` is Microsoft's recommended pure-Go driver for SQL Server, Azure SQL Database, Azure SQL Managed Instance, and Azure Synapse Analytics. It supports Linux, macOS, Windows, SQL authentication, Windows single sign-on, Kerberos, Microsoft Entra authentication, TLS, and SQL Server 2005 or newer ([driver README](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/README.md)).
- The helper can be distributed as self-contained binaries for Go's supported `linux`, `darwin`, and `windows` targets, including `amd64` and `arm64`; Go publishes the supported target matrix and cross-compilation rules ([Go target matrix](https://go.dev/doc/install/source#environment)). End users do not need Go, ODBC, FreeTDS, Python, LuaRocks, or a C compiler.
- Orbit already retains one subprocess per connection profile, serializes statements, passes connector-owned environment variables, and restarts failed sessions (`lua/orbit/runner.lua:133-155`, `lua/orbit/session.lua:103-205`). A framed helper fits this design better than adding synchronous FFI or a new in-process network stack.
- Microsoft's ODBC Driver 18 does not list Arch Linux as supported. The supported Linux distributions are selected Alpine, Debian, Oracle Linux, RHEL, SLES, Ubuntu, and Azure Linux releases ([Microsoft support matrix](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/system-requirements?view=sql-server-ver17)). An ODBC-first connector would make the main requested Linux platform depend on unsupported, user-maintained packaging.
- Neither Go nor ODBC `sqlcmd` provides a lossless arbitrary-result protocol. Its documented output uses one 8-bit separator, wraps at a configured width, pads columns, truncates large variable-length values by default, and can only remove control characters destructively ([`sqlcmd` format options](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility?view=sql-server-ver17#format-options)). The documented JSON command only changes decoration around SQL that already returns JSON; it does not transform arbitrary result sets into JSON ([`sqlcmd` JSON output](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-commands?view=sql-server-ver17#json-output-format)).

Do not require or bundle Microsoft ODBC, `mssql-tools`, FreeTDS, or `sqlcmd` for the MVP. They remain useful diagnostic and expert-operated alternatives.

## Scope distinction: client versus server

Orbit only needs a SQL Server **client** transport. The database engine can be remote, in a VM, in a supported container, or provided by Azure. An Arch ARM64 laptop, Apple Silicon Mac, or Windows ARM64 machine can run an Orbit helper and connect over TCP even though that machine cannot host a supported native SQL Server engine.

Running SQL Server itself has narrower support:

- SQL Server 2025 on Linux supports selected RHEL and Ubuntu releases on x64. Arch Linux and Linux ARM64 are not supported native server platforms ([SQL Server on Linux requirements](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup?view=sql-server-ver17)).
- Microsoft SQL Server Linux container images are supported on Linux x86-64 hosts. Microsoft states that Rosetta, Prism, and QEMU translation environments are not tested or supported ([container requirements](https://learn.microsoft.com/en-us/sql/linux/containers/deploy?view=sql-server-ver17#system-requirements)).
- macOS has no native SQL Server engine. A development VM or emulated container may work, but an Apple Silicon emulation path is outside Microsoft's supported container matrix.
- SQL Server 2025 on Windows requires x64 hardware. Windows ARM64 is a viable Orbit client, not a supported native SQL Server host ([Windows SQL Server requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2025?view=sql-server-ver17)).

Local-engine limitations should not be presented as Orbit client limitations.

## Why an Orbit-owned helper fits

### Existing connector boundary

Orbit connectors are stateless capability tables. The runner selects retained execution when a connector provides `session_command`, then delegates request framing and response extraction to `session_request` and `session_output` (`lua/orbit/adapters.lua:28-39`, `lua/orbit/runner.lua:133-155`, `lua/orbit/session.lua:103-205`). Connector-specific parsing, schema SQL, naming, object actions, and environment construction already belong in one backend file, as demonstrated by PostgreSQL (`lua/orbit/connectors/postgres.lua:115-150`, `lua/orbit/connectors/postgres.lua:220-325`, `lua/orbit/connectors/postgres.lua:346-518`).

The proposed connector can use that boundary with only a small protocol:

1. `session_command(options)` starts `orbit-mssql` without secrets in argv.
2. `environment(options)` passes a generated connection document or individual sensitive values through environment variables. A protected stdin initialization message would be even less exposed than an environment variable, but requires a small session initialization extension.
3. `session_request(statement, marker)` emits one JSON line containing the marker and statement. JSON escaping safely carries multiline SQL.
4. The helper executes the request and emits exactly one JSON response line containing the same marker, rows, columns, and either an error or success status.
5. `session_output(output, marker)` extracts that complete response and returns only its result payload to `parse`.
6. Cancelling active work continues to terminate the helper and discard that connection profile's session, matching current retained-connector behavior (`lua/orbit/session.lua:266-298`). The next statement starts a fresh connection.

No shell should interpret the request, connection values, or statement.

### Connection ownership

The helper should acquire and retain one explicit [`database/sql.Conn`](https://pkg.go.dev/database/sql#Conn), rather than running statements directly against a pooled `sql.DB`. Go documents that a `Conn` represents one underlying database connection and that all operations on it use the same database session. This preserves transactions, `USE`, `SET`, session context, and local temporary tables across Orbit statements.

The helper should use `QueryContext`, inspect [`Rows.Columns`](https://pkg.go.dev/database/sql#Rows.Columns), [`Rows.ColumnTypes`](https://pkg.go.dev/database/sql#Rows.ColumnTypes), and [`Rows.NextResultSet`](https://pkg.go.dev/database/sql#Rows.NextResultSet), and close every result set. Context cancellation is useful inside the helper, but Orbit's existing cancellation contract can initially terminate the process rather than add a second cancellation message.

`go-mssqldb` documents a temporary-table caveat when parameterized execution causes a separate session. Orbit sends complete user statements without parameters, so ordinary `#temporary_table` statements remain on the retained connection; this behavior still needs an integration test ([temporary-table caveat](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/README.md#caveat-for-local-temporary-tables)).

## Result protocol and current Orbit limits

Orbit currently represents results as a list of maps keyed by column name (`lua/orbit/results.lua:167-186`). That model cannot preserve duplicate column names and does not intrinsically preserve column order. SQL Server also permits batches and procedures to return multiple result sets.

For the smallest compatible MVP:

- Support zero or one row-producing result set.
- Reject multiple row-producing result sets with a clear connector error instead of silently discarding data.
- Reject duplicate or empty column labels before converting positional helper rows into Orbit row maps.
- Return an explicit ordered `columns` list if the runner/result path is minimally extended to carry it; otherwise preserve the helper's discovered order when creating row maps and test the current inference path.
- Encode SQL `NULL` as JSON `null`, which Neovim decodes to `vim.NIL` and the Result grid already displays as `NULL`.
- Encode `bigint`, exact decimals/money, date/time values, GUIDs, XML, and other precision-sensitive values as canonical strings. LuaJIT numbers cannot represent every SQL Server integer or decimal exactly.
- Encode binary values as an explicit tagged base64 or hexadecimal value. Do not send arbitrary bytes as UTF-8 JSON strings.
- Keep Result grids read-only until typed literal generation, primary-key safety, affected-row verification, and transaction behavior have dedicated live tests.

A later positional result contract such as `{ columns, types, rows, result_sets }` would remove the duplicate-heading and multi-result limitations for every connector, not only SQL Server. It should be a separate core change rather than hidden inside the MVP connector.

## Proposed connection profile

```json
{
  "name": "warehouse-mssql",
  "kind": "mssql",
  "options": {
    "host": "sql.example.com",
    "port": 1433,
    "database": "warehouse",
    "user": "orbit",
    "password": "replace-me",
    "encrypt": "mandatory",
    "trust_server_certificate": false
  }
}
```

Required for the MVP:

- `host`: non-empty string.
- `database`: non-empty string.

Optional for the MVP:

- `port`: integer from 1 through 65535, default `1433`.
- `instance`: non-empty named instance, mutually exclusive with `port`. Prefer a fixed port because instance discovery depends on SQL Server Browser and network access to it.
- `user`: non-empty SQL login. Omit only for Windows integrated authentication in the initial release.
- `password`: string passed outside argv. If SQL authentication is selected, require both `user` and `password`.
- `authentication`: initially `sql` or `windows`; default based on whether `user` is present only if that rule is documented clearly.
- `encrypt`: `mandatory` by default; consider `strict` after testing TDS 8.0 servers and older-server errors.
- `trust_server_certificate`: boolean, default `false`.
- `certificate`: CA/server certificate path for normal chain, expiry, and hostname validation.
- `hostname_in_certificate`: expected certificate hostname when it differs from `host`.
- Existing shared `schema_patterns`, `executable`, `arguments`, and `confirm_mutations` options.

Advanced connection-string support should be an explicit escape hatch, not the primary profile shape. If added, accept a named environment variable containing a DSN rather than storing the DSN in argv. The helper should construct normal URL-form DSNs with Go's `net/url`; the driver requires percent-encoding for URL usernames/passwords and supports `host\instance` discovery, ADO strings, and `odbc:`-prefixed strings ([connection formats](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/README.md#the-connection-string-can-be-specified-in-one-of-three-formats)).

## TLS policy

Orbit should override the driver's permissive compatibility default:

- Default to encrypted transport and certificate validation: `encrypt=mandatory`, `TrustServerCertificate=false`.
- Permit `encrypt=strict` as a follow-up or expert option. It uses TDS 8.0 and therefore needs server-version compatibility tests.
- `certificate` should use normal CA-chain, expiry, and hostname validation. `hostname_in_certificate` changes the expected hostname.
- `serverCertificate` byte-pins an exact server certificate but deliberately skips chain, expiry, and hostname checks. If exposed, name and document it distinctly from a CA certificate.
- `trust_server_certificate=true` accepts any presented certificate and hostname and is vulnerable to man-in-the-middle attacks. Document it as development-only.

These semantics are defined by [`go-mssqldb`'s TLS parameters](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/README.md#connection-parameters-and-dsn). Secure defaults mean a self-signed local SQL Server will fail until the user supplies/trusts its CA, pins the certificate, or explicitly opts into the unsafe bypass.

## Authentication scope

### MVP

- SQL Server username/password authentication on every client platform.
- Windows integrated single sign-on when no username is supplied. The driver documents Windows SSO and uses its Windows SSPI provider ([driver features](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/README.md#features)).

### Follow-up

- Kerberos on Linux/macOS by importing the driver's optional `integratedauth/krb5` provider and selecting `authenticator=krb5`. The driver supports keytabs, credential caches, and raw credentials, with `/etc/krb5.conf` or explicit configuration ([Kerberos configuration](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/README.md#kerberos-active-directory-authentication-outside-windows)). This needs DNS, SPN, realm, ticket, and clock-skew integration tests.
- Microsoft Entra authentication by importing `azuread` and opening the `azuresql` driver. Upstream supports service principals, managed identity, environment credentials, Azure CLI, workload identity, device code, interactive browser, and other flows ([Entra authentication](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/README.md#azure-active-directory-authentication)). Interactive/device-code flows need a deliberate Neovim UX because authentication instructions must not be mixed into machine-readable stdout.
- NTLM on Unix is available in the driver, but should not be advertised until tested and security expectations are documented.

Do not claim Kerberos or Entra support merely because the upstream driver implements it. The Orbit helper must import the provider and the project must verify the complete login flow on each advertised platform.

## Platform and packaging matrix

### Recommended helper

| Orbit client | Release artifact | End-user runtime dependencies |
| --- | --- | --- |
| Arch/other Linux x86-64 | `orbit-mssql-linux-amd64` | Binary, network access, and a trusted CA store |
| Linux ARM64 | `orbit-mssql-linux-arm64` | Binary, network access, and a trusted CA store |
| macOS Intel | `orbit-mssql-darwin-amd64` | Binary and network access |
| macOS Apple Silicon | `orbit-mssql-darwin-arm64` | Binary and network access; no Rosetta |
| Windows x64 | `orbit-mssql-windows-amd64.exe` | Binary and network access |
| Windows ARM64 | `orbit-mssql-windows-arm64.exe` | Binary and network access |

Build with pinned `go-mssqldb` and committed `go.sum`. Version 1.11.0 requires Go 1.25 ([module file](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/go.mod)). Prefer reproducible `CGO_ENABLED=0` release builds and verify every artifact on its target OS. The driver uses BSD-3-Clause terms, which require retaining its copyright, conditions, and disclaimer ([license](https://github.com/microsoft/go-mssqldb/blob/v1.11.0/LICENSE.txt)); release artifacts should include generated third-party notices for all transitive modules.

Helper discovery options, in preference order:

1. A profile `executable` override for development and custom packaging.
2. A helper found on `PATH`.
3. A plugin-owned platform/architecture path populated by release installation.

Orbit currently has no binary-download/update subsystem. Implementation must choose whether releases attach binaries for a plugin manager hook, require a separate package, or provide a documented one-time installer. Do not download and execute a binary silently when the connector first runs.

### Arch Linux ODBC alternative

Microsoft does not support Arch in the ODBC Driver 18 platform matrix. Arch's official repositories contain [`freetds`](https://archlinux.org/packages/extra/x86_64/freetds/) and [`unixodbc`](https://archlinux.org/packages/core/x86_64/unixodbc/), but not Microsoft's ODBC driver or `sqlcmd`. AUR packages for [`msodbcsql`](https://aur.archlinux.org/packages/msodbcsql) and [`go-sqlcmd`](https://aur.archlinux.org/packages/go-sqlcmd) are user-maintained rather than Microsoft- or Arch-supported packages.

If Orbit ever offers an ODBC helper, treat Arch driver installation as user-managed and unsupported by Microsoft. At minimum it requires unixODBC plus a registered SQL Server ODBC driver; `odbcinst -j` reports active configuration paths and `odbcinst -q -d` lists registered drivers ([unixODBC configuration](https://www.unixodbc.org/odbcinst.html)). A DSN-less Microsoft string names the registered driver, for example `Driver={ODBC Driver 18 for SQL Server};Server=tcp:host,1433;...`; Linux/macOS use TCP and put the port in `Server`, not a `Port` keyword ([Microsoft DSN guidance](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/connection-string-keywords-and-data-source-names-dsns?view=sql-server-ver17)).

### macOS ODBC alternative

Microsoft documents installation through its Homebrew tap, with `msodbcsql18` and optionally `mssql-tools18`; the formula uses unixODBC and OpenSSL and supports Intel and Apple Silicon ([Microsoft macOS installation](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/install-microsoft-odbc-driver-sql-server-macos?view=sql-server-ver17)). Homebrew Core separately provides [`sqlcmd`](https://formulae.brew.sh/formula/sqlcmd), the standalone Go variant.

This route is supported, but it adds native-driver discovery and licensing complexity that the helper avoids.

### Windows ODBC alternative

Windows includes the ODBC Driver Manager, but the Microsoft SQL Server ODBC driver is still a separate install. Driver 18.7 supports x64, x86, and ARM64; Microsoft states that version 18.7 no longer requires a separately installed Visual C++ Redistributable ([ODBC download page](https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server?view=sql-server-ver17)). Windows has separate 32-bit and 64-bit ODBC administrators, so helper and driver architecture must match ([ODBC Data Source Administrator](https://learn.microsoft.com/en-us/sql/odbc/admin/odbc-data-source-administrator?view=sql-server-ver17)).

Again, this is viable but unnecessary for a pure-Go helper.

## Evaluated alternatives

### Go `sqlcmd`

Microsoft's Go `sqlcmd` is standalone and runs on Windows, macOS, Linux, and in containers ([variant documentation](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility?view=sql-server-ver17#sqlcmd-variants)). It is easy to obtain on macOS through Homebrew and on Windows through Microsoft's documented installers ([installation guide](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17)).

It is not the recommended Orbit transport because its compatibility output is human-oriented and ambiguous for arbitrary data. A separator can occur inside a value, lines can wrap, large values truncate unless configured otherwise, headers/padding require stripping, control-character removal changes data, and multiple result sets are not represented as a typed structure. Using the same underlying Go driver through a purpose-built protocol removes these failures.

`sqlcmd` remains useful for user diagnostics and could be an explicitly limited compatibility backend if Orbit documents the fidelity loss.

### Microsoft ODBC Driver 18 plus custom helper

This can provide structured results, excellent SQL Server feature coverage, and native enterprise authentication. It is a reasonable choice for applications already standardized on ODBC.

It is a poor default for Orbit because Arch is unsupported, Linux/macOS require unixODBC and driver registration, Windows introduces architecture-specific installation, and redistribution is governed by Microsoft's proprietary EULA/REDIST terms ([ODBC EULA and redistribution terms](https://aka.ms/odbc18eularedist)). Orbit should require user installation rather than bundle ODBC components if this backend is ever added.

### Python plus `pyodbc`

[`pyodbc`](https://github.com/mkleehammer/pyodbc) can expose structured rows from a helper, but users need Python, pyodbc, an ODBC manager, and a SQL Server ODBC driver. Building pyodbc from source also requires native build tooling. This retains every Arch ODBC problem while adding Python packaging, so it is not a useful default.

### FreeTDS

FreeTDS is attractive on Arch because `freetds` and `unixodbc` are official packages, and Homebrew offers bottles for macOS and Linux ([Arch package](https://archlinux.org/packages/extra/x86_64/freetds/), [Homebrew formula](https://formulae.brew.sh/formula/freetds)). It supports modern TDS versions, TLS, NTLMv2, and Kerberos ([protocol versions](https://www.freetds.org/userguide/ChoosingTdsProtocol.html), [configuration](https://www.freetds.org/userguide/freetdsconf.html)).

Its CLI tools are not a strong machine protocol. FreeTDS explicitly describes `tsql` as a diagnostic tool rather than a complete `isql` replacement ([FreeTDS utilities](https://www.freetds.org/userguide/usefreetds.html)). Windows packaging/builds are also less predictable than a Go cross-build ([Windows notes](https://www.freetds.org/userguide/osissues.html#Windows)). Use FreeTDS for diagnostics or a user-managed ODBC backend, not the primary connector.

### Native Lua ODBC or direct TDS

Native Lua ODBC modules add Lua ABI, compiler, driver-manager, and blocking-I/O concerns inside Neovim. A direct TDS implementation would make Orbit own a large authentication, encryption, protocol, type-decoding, and compatibility surface already maintained by Microsoft. Neither is justified.

## Schema acquisition and SQL Server behavior

Map SQL Server naturally into Orbit's existing model:

- `catalog`: database name if multi-database browsing is later supported; omit for the MVP profile's fixed database if that better matches existing single-database connectors.
- `schema`: SQL Server schema, normally `dbo` but never assume only `dbo` exists.
- `name`: table or view name.
- `type`: `table` or `view`.
- Qualified name: bracket-quote every segment and escape `]` as `]]`, for example `[sales].[order details]`.
- Sample statement: `SELECT TOP (N) * FROM [schema].[object];`, not `LIMIT`.

Initial schema acquisition should cover tables, views, and columns through Microsoft's catalog views [`sys.tables`](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-tables-transact-sql?view=sql-server-ver17), [`sys.views`](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-views-transact-sql?view=sql-server-ver17), [`sys.schemas`](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/schemas-catalog-views-sys-schemas?view=sql-server-ver17), and [`sys.columns`](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-columns-transact-sql?view=sql-server-ver17). Exclude Microsoft-shipped objects deliberately, but do not hide user objects merely because they use an unusual schema.

Primary keys, foreign keys, indexes, and view definitions fit Orbit's current table metadata categories and object actions, but should follow after basic acquisition and result fidelity are stable. Editable Result grids should follow only after primary-key order, computed/identity/rowversion columns, triggers, affected-row counts, and transactional mutation batches are proven live.

The SQL tokenizer and mutation classifier also need SQL Server-specific tests for bracketed identifiers, `N'...'` strings, `--` and nested/non-nested block-comment behavior as applicable, `GO` batch separators, CTEs, `TOP`, `OUTPUT`, `MERGE`, and T-SQL DDL. `GO` is a client batch separator rather than T-SQL; the helper must either split it correctly or reject it explicitly for the MVP.

## Windows profile-file blocker

Orbit currently refuses any profile file whose libuv mode bits are not exactly POSIX `0600`, creates its default under `~/.local/share/orbit.nvim`, and applies `chmod` after writes (`lua/orbit/profiles.lua:58-87`, `lua/orbit/profiles.lua:227-240`). Windows security is ACL-based and does not provide the same owner/group/other permission contract.

Before Orbit advertises Windows support for any connector:

- Run profile create/load/write tests on Windows with Neovim's bundled libuv.
- Define a Windows ACL policy that restricts the current user and necessary system principals.
- Use an appropriate Windows data directory rather than assuming the Unix XDG-style path is desirable.
- Preserve the current exact `0600` behavior on Unix.

This is a core portability issue, not an MSSQL-helper issue. A functioning Windows helper is insufficient if Orbit rejects or weakly protects the profile file.

## Minimal implementation slices

1. **Protocol spike:** Implement the Go helper with SQL authentication, host/port, database, secure TLS defaults, one retained `sql.Conn`, one JSON request/response at a time, zero/one result set, and explicit unsupported-shape errors.
2. **Fidelity gate:** Test `NULL`, empty strings, Unicode, multiline/control characters, `bigint`, decimal/money, floating values, GUID, all date/time types, XML, JSON text, `varchar(max)`, `nvarchar(max)`, `varbinary(max)`, duplicate/empty labels, warnings, DDL/DML, and multiple result sets.
3. **Connector shell:** Register `mssql`, validate connection-profile options, launch the helper, pass secrets outside argv, frame retained requests, parse errors, and verify cancellation/reconnect behavior.
4. **T-SQL naming:** Add bracket-identifier tokenization/splitting/completion tests, bracket-qualified names, and `TOP (N)` sample statements. Define `GO` behavior explicitly.
5. **Schema acquisition:** Add table/view and column acquisition, schema patterns, completion, sample/columns actions, and read-only results.
6. **Cross-platform releases:** Build signed/checksummed binaries for Linux/macOS/Windows on amd64/arm64 as applicable, generate third-party notices, and test helper discovery and upgrade behavior.
7. **Platform gates:** Run Windows profile-file security tests and client smoke tests on Arch x86-64, Linux ARM64, macOS Intel/Apple Silicon, and Windows x64/ARM64 against one remote test server.
8. **Documentation:** Add installation, profile, TLS, authentication, remote-versus-local server, troubleshooting, and unsupported-feature guidance.

## Verification matrix

Deterministic tests without SQL Server:

- Go protocol framing, malformed requests, redaction, type conversion, invalid UTF-8/binary encoding, duplicate headings, multiple result sets through driver fakes where practical, and process termination.
- Lua connection-profile validation, helper argv/environment, marker extraction across arbitrary stdout chunks, parsing, error propagation, bracket quoting, generated metadata SQL, completion, and T-SQL lexical behavior.
- Existing connector/session tests to prove the helper protocol does not regress PostgreSQL, MySQL, SQLite, Trino, or Vertica.

Live Linux x86-64 integration gate:

- Use an official SQL Server 2022 or 2025 x86-64 Linux container on a supported Linux CI host.
- Verify retained transactions with `BEGIN TRANSACTION`/`ROLLBACK`, `USE`, `SET`, `SESSION_CONTEXT`, and `#temporary_table` across separate Orbit requests.
- Verify trusted CA, wrong hostname, untrusted/expired certificate, exact pinning, and explicit trust bypass.
- Verify cancellation of a long-running statement kills the helper, rolls back/discards session state, and reconnects cleanly.
- Verify all scalar/binary/large-value fidelity cases and explicit failures for unsupported result shapes.
- Verify tables/views/columns across unusual schemas and bracket-containing names.

Client-platform smoke gate:

- Connect each released Linux, macOS, and Windows artifact to the same remote SQL Server.
- Test SQL authentication everywhere and Windows SSO on Windows.
- Test Windows profile creation/loading security separately.
- Add separately credentialed suites before claiming Kerberos or Microsoft Entra support.

No live SQL Server verification was performed during this research.

## Risks and open decisions

Decisions required before implementation:

- Binary distribution and update mechanism. Recommendation: signed/checksummed release artifacts with an explicit install step; never an implicit first-run download.
- MVP authentication modes. Recommendation: SQL authentication everywhere plus Windows SSO; defer Kerberos and Entra until their UX and integration tests exist.
- Result envelope. Recommendation: retain Orbit's row-map contract for MVP and fail explicitly on duplicate headings/multiple result sets; design a positional core contract separately.
- Secret handoff. Recommendation: add a protected helper initialization message if practical; environment variables are acceptable as an initial parity path because Orbit already uses them, but they can be inspectable by same-user processes on some systems.
- Named instances. Recommendation: accept either a fixed port or an instance, but strongly recommend fixed TCP ports for predictable cross-network behavior.
- `GO` handling. Recommendation: reject batches containing client separators initially rather than implement a partial splitter.
- Supported SQL Server versions. Upstream supports SQL Server 2005+, but Orbit should choose and test a narrower modern floor rather than inherit an unverified claim.
- Helper auto-discovery path and compatibility/version handshake. Recommendation: have the helper report a protocol version and fail clearly on mismatch.

Highest risks:

- Packaging a native helper is new release infrastructure for a plugin currently described as running existing CLIs (`README.md:7`, `README.md:37-49`).
- Windows profile-file security and default paths are currently unverified.
- SQL Server's type and multi-result behavior is richer than Orbit's row-map result contract.
- Interactive Entra authentication can corrupt stdout framing unless explicitly separated from protocol output.
- Killing the helper is reliable local cancellation but initially provides no structured confirmation of server-side cancellation timing.

## Bottom line

SQL Server support is feasible on Arch Linux, macOS, and Windows without platform-specific database runtimes. The most dependable design is a small retained helper built on Microsoft's pure-Go driver, not `sqlcmd` text parsing and not ODBC. It fits Orbit's existing session ownership while avoiding Arch's unsupported Microsoft ODBC path.

The MVP should stay narrow: SQL authentication plus Windows SSO, TCP, secure TLS defaults, one row-producing result set, read-only Result grids, bracket-qualified names, and basic table/view/column acquisition. The release gates are live type-fidelity testing, cross-platform helper packaging, and a correct Windows replacement for Orbit's POSIX-only profile-file permission policy.
