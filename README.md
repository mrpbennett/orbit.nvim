# :rocket: Orbit.nvim

## A database IDE for Neovim

Your database revolves around your editor, not the other way around.

Orbit runs statements through backend-specific Connectors using user-installed database clients. It retains one connection per profile where the client supports it, keeps profiles per query buffer, browses schemas, completes cached objects and Redis keys, and renders normalized results in a navigable grid.

![preview](./assets/preview.png)

## Contents

- [What It Does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Connection Profiles](#connection-profiles)
- [Workspace Workflow](#workspace-workflow)
- [Commands](#commands)
- [Keybindings](#keybindings)
- [Completion](#completion)
- [Structure Panel](#structure-panel)
- [Execution And Results](#execution-and-results)
- [Configuration](#configuration)

## What It Does

- Open one dedicated workspace tab with a searchable profile and schema browser.
- Run a whole statement or a visual selection asynchronously without leaving Neovim.
- Bind each query buffer to its own connection profile.
- Browse tables, views, and columns; run connector-specific object actions; create a bound sample statement; copy qualified object names.
- Inspect and copy raw result values, including structured JSON values.
- Confirm potentially mutating statements before they run.
- Complete cached tables, views, columns, and table aliases, clause-aware, through a blink.cmp source.
- Browse reusable SQL and Redis files from multiple named saved-query locations.

## Requirements

- Neovim 0.10 or later.
- No required third-party Neovim plugins.
- The executable required by each connection profile:

| Profile kind | Executable                                                                                                                                                                                        | Notes                                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| `mssql`      | Microsoft [Go `sqlcmd`](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17), or [Java 11+](https://docs.oracle.com/en/java/javase/11/tools/java.html) and [jTDS 1.3.1](https://sourceforge.net/projects/jtds/files/jtds/1.3.1/) | The profile selects the MSSQL transport; all dependencies are user-installed. |
| `trino`      | [`trino`](https://trino.io/docs/current/client/cli.html)                                                                                                                                          | Defaults to CSV with headers; JSON is optional.      |
| `sqlite`     | `sqlite3`                                                                                                                                                                                         | Requires a build that supports `-json`.              |
| `postgres`   | [`psql`](https://www.postgresql.org/docs/current/app-psql.html)                                                                                                                                   | Requires a version that supports `--csv`.            |
| `redis`      | [`redis-cli`](https://redis.io/docs/latest/develop/tools/cli/)                                                                                                                                    | Uses RESP3 JSON through one-shot processes.           |
| `mysql`      | Oracle [`mysql`](https://dev.mysql.com/doc/refman/8.4/en/mysql.html) 8.x or MariaDB [`mariadb`](https://mariadb.com/docs/server/clients-and-utilities/mariadb-client/mariadb-command-line-client) | Connects to MySQL 8.x servers using XML.             |
| `vertica`    | [`vsql`](https://docs.vertica.com/24.3.x/en/connecting-to/using-vsql/)                                                                                                                            | Uses HTML table output.                              |

The MSSQL Connector targets only Microsoft's Go implementation of `sqlcmd`. Install it using Microsoft's [Download and install the sqlcmd utility](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17) instructions and keep it updated yourself. Orbit does not install or update it. A trusted system CA store is required unless the profile explicitly enables the unsafe certificate-trust bypass.

Alternatively, an MSSQL profile can select Orbit's JDBC transport and its initially supported JDBC driver, jTDS 1.3.1. The transport and driver are different: Orbit's transport owns the retained Java helper protocol, while jTDS is the Java library that communicates with SQL Server. Install a Java 11-or-newer runtime capable of [source-file mode](https://openjdk.org/jeps/330) and download the jTDS 1.3.1 JAR yourself. Orbit ships the [helper as Java source](./cmd/orbit-mssql/OrbitMssql.java) but does not bundle, download, install, or update Java or jTDS. See [ADR-0004](./docs/adr/0004-selectable-mssql-transports.md) for the accepted design.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mrpbennett/orbit.nvim",
  opts = {},
}
```

Or call setup from your Neovim configuration:

```lua
require("orbit").setup()
```

### Microsoft Go sqlcmd Installation

Install Microsoft Go `sqlcmd` by following Microsoft's [primary installation guide](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install?view=sql-server-ver17). The default executable name is `sqlcmd`; set the profile's `options.executable` to another path or command name when necessary. Installation and updates remain entirely user-managed.

Run `:OrbitDoctor mssql` after installation. It validates profiles, resolves each MSSQL profile's executable from `options.executable` or `PATH`, runs only `sqlcmd --version`, and checks that a configured `password_env` is populated. It does not execute SQL or connect to SQL Server.

### MSSQL JDBC/jTDS Installation

Install Java 11 or newer with source-file execution support, then download [jTDS 1.3.1](https://sourceforge.net/projects/jtds/files/jtds/1.3.1/) to a user-managed location. Set `options.driver_path` to that JAR. Orbit runs `java` from `PATH` by default; set optional `options.java_executable` to another command name or path.

Run `:OrbitDoctor mssql` after configuring the profile. For JDBC profiles it validates the profile and password source, resolves Java, checks that `driver_path` is readable, and runs the shipped Java source helper in doctor mode to verify Java 11+ source execution and exact jTDS 1.3.1 class loading. It does not connect to SQL Server. Java 25 helper and driver class loading and the live compatibility described below have been verified locally.

## Quick Start

1. Run `:OrbitProfiles`. This creates `~/.local/share/orbit.nvim/profiles.json` with owner-only (`0600`) permissions and opens it for editing.
2. For MSSQL, install the dependencies for the selected `sqlcmd` or JDBC/jTDS transport, then run `:OrbitDoctor mssql`.
3. Add a connection profile using the format below.
4. Open `:OrbitWorkspace`, a SQL buffer, or a Redis buffer.
5. Bind a profile with `:OrbitProfile`, or press `<CR>` on a profile in the workspace.
6. Run `:OrbitExecute`, or use `<leader>E` in Normal or Visual mode in a query buffer.

If a query buffer has no profile, executing it opens profile selection and retries after you choose one.

### Supported Connectors

| Kind       | Required options            | Optional options                                                                                                                | Schema support                                                                                                           |
| ---------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `mssql` (`sqlcmd`, default) | `host`, `database`, `user` | `transport`, `port`, `password`, `password_env`, `trust_server_certificate`, `schema_patterns`, `executable`, `confirm_mutations` | User tables and views in every listed database, plus columns. |
| `mssql` (`jdbc`) | `transport`, `driver`, `driver_path`, `host`, `authentication` | `port` or `instance`, `database`, `java_executable`, `trust_server_certificate`, `schema_patterns`, `confirm_mutations` | User tables and views in every listed database, or the login-default database when omitted, plus columns. |
| `trino`    | `server`, `user`, `catalog` | `schema`, `schema_patterns`, `executable`, `arguments`, `confirm_mutations`                                                     | Tables, views, and columns from `information_schema`. Omitting `schema` browses the catalog except `information_schema`. |
| `sqlite`   | `path`                      | `schema_patterns`, `executable`, `arguments`, `confirm_mutations`                                                               | Tables and views from `sqlite_master`, plus columns from `PRAGMA table_info`, under `main`.                              |
| `postgres` | `database`                  | `schema_patterns`, `host`, `port`, `user`, `password`, `sslmode`, `executable`, `arguments`, `confirm_mutations`                | Tables and views outside PostgreSQL system schemas, plus columns, primary keys, foreign keys, and indexes.               |
| `redis`    | `host`                      | `port`, `database`, `user`, `password_env`, `tls`, `cacert`, `cacertdir`, `cert`, `key`, `sni`, `key_pattern`, `key_limit`, `scan_count`, `executable`, `confirm_mutations` | Cached Redis keys for completion; no schema tree. |
| `mysql`    | `database`                  | `schema_patterns`, `host`, `port`, `socket`, `user`, `client_family`, `sslmode`, `executable`, `arguments`, `confirm_mutations` | MySQL 8.x tables and views, plus columns, primary keys, foreign keys, indexes, and view definitions.                     |
| `vertica`  | `host`, `user`, `database`  | `schema_patterns`, `port`, `password`, `sslmode`, `executable`, `arguments`, `confirm_mutations`                                | User tables and views, plus columns, primary keys, foreign keys, projections, and view definitions.                      |

`executable` replaces a CLI-backed Connector's default executable. `arguments` is supported only by Connectors that explicitly accept it and adds an array of string arguments before Orbit's generated arguments; MSSQL and Redis intentionally do not accept `arguments`. For MSSQL, SQLite, PostgreSQL, MySQL, and Vertica, Orbit retains one child process per profile; statements, schema browsing, and completion prewarming share it and are serialized per profile. MSSQL retains either an interactive Go `sqlcmd` process or a Java helper with one JDBC connection as one SQL Server session. A changed profile definition, failed executable, `:OrbitDisconnect`, cancellation, or Neovim exit closes the retained process; the next request reconnects automatically. Trino and Redis use one CLI invocation per statement. Redis therefore does not preserve `SELECT`, `MULTI`, `WATCH`, or other connection-local state between executions.

Schema browsing and completion cache rows only while the connection profile's kind and options are unchanged. Updating a profile clears its prior schema rows before Orbit acquires replacements. Connector metadata that is unavailable for an object, such as Trino primary keys, is shown as unavailable rather than treated as a statement failure. Explicit Workspace refreshes run after pending acquisitions and coalesce with other refresh requests.

`schema_patterns` restricts the tables and views shown by Orbit's Workspace schema browser, but does not change database permissions or restrict statements you run manually. For Trino, it maps each catalog to an array of schema patterns; use an empty array to include every non-system schema from that catalog. MSSQL, PostgreSQL, MySQL, SQLite, and Vertica use a non-empty array instead. Entries accept `*` and `?` globs. MSSQL patterns select schemas within every database named by `database`; JDBC uses the login's default database when `database` is omitted. A MySQL profile always includes its required default `database`; its patterns add other databases. SQLite's only available schema is `main`.

## Connection Profiles

The profile file is the source of truth for named connection profiles. Its default location is `~/.local/share/orbit.nvim/profiles.json`; set `profile_path` in `setup()` to use another location. Orbit refuses to load a file that is not mode `0600`.

Profiles are JSON, versioned at `1`, and names must be unique:

<details>
<summary>Microsoft SQL Server</summary>

### Microsoft Go sqlcmd Transport (Default)

#### Direct Password

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "warehouse-mssql",
      "kind": "mssql",
      "options": {
        "host": "sql.example.com",
        "port": 1433,
        "database": "warehouse",
        "user": "orbit",
        "password": "replace-me",
        "trust_server_certificate": false,
        "schema_patterns": ["dbo", "reporting*"]
      }
    }
  ]
}
```

#### Password From The Environment

Set the named variable before starting Neovim, then use its name, not `$MSSQL_PASSWORD`, in the connection profile:

```sh
export MSSQL_PASSWORD='replace-me'
```

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "warehouse-mssql-env",
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
  ]
}
```

MSSQL accepts exactly these profile fields:

- `transport`: optional literal `sqlcmd`; omitting it selects this transport unchanged.
- `host`: required non-empty string.
- `database`: required non-empty string or non-empty array of unique non-empty strings. For an array, the first database is the retained session's default and schema acquisition includes every entry.
- `user`: required non-empty SQL login string.
- `port`: optional integer from `1` through `65535`; defaults to `1433`.
- `password`: optional non-empty string stored in the owner-only profile file.
- `password_env`: optional non-empty environment-variable name. It is mutually exclusive with `password`; the named variable must contain a non-empty value before the CLI starts.
- `trust_server_certificate`: optional boolean; defaults to `false`.
- `schema_patterns`: optional non-empty array whose entries are non-empty schema globs using `*` and `?`.
- `executable`: optional non-empty command name or path replacing `sqlcmd`.
- `confirm_mutations`: optional boolean per-profile mutation-confirmation override.

One of `password` or `password_env` must resolve to a password before Go `sqlcmd` starts. Orbit passes it as `SQLCMDPASSWORD`, never in argv. The child receives a sanitized environment: Orbit removes every inherited variable whose name starts with `SQLCMD` (case-insensitive), removes the source variable named by `password_env`, preserves other inherited variables, and then sets only the resolved `SQLCMDPASSWORD` credential among the SQLCMD variables.

The current argv, in order, is `<executable> -S tcp:<host>,<port> -d <default-database> -U <user> -N mandatory [-C] -s <ASCII 31> -w 65535 -y 8000 -Y 8000 -x`; `<default-database>` is the string value or first array entry. The bracketed `-C` is present only when `trust_server_certificate` is `true`. ASCII 31 is the unit-separator field delimiter, `-w` sets width `65535`, `-y` and `-Y` set variable and fixed type limits to `8000`, and `-x` disables variable substitution. Orbit does not use `-r`, so SQL errors stay ordered inside the framed stdout response instead of racing a separate stderr stream.

The address is always one explicit TCP host and port. An array-valued `database` browses every listed database through three-part SQL Server names; the login must be able to read each database's catalog views. Named-instance discovery remains unsupported. Encryption is always requested as mandatory with `-N mandatory`; profiles cannot weaken it. `trust_server_certificate = true` adds `-C`, bypassing certificate validation and enabling man-in-the-middle attacks. Treat it only as an unsafe temporary development escape hatch.

### JDBC Transport With jTDS

Omitting `transport` preserves the complete `sqlcmd` behavior above. Select the separate JDBC transport explicitly with `"transport": "jdbc"`; that transport initially requires the jTDS JDBC driver through `"driver": "jtds"`.

Set the password variable before starting Neovim. This complete domain-password profile uses the first listed database as the retained JDBC connection's default and browses both databases:

```sh
export MSSQL_PASSWORD='replace-me'
```

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "domain-mssql",
      "kind": "mssql",
      "options": {
        "transport": "jdbc",
        "driver": "jtds",
        "driver_path": "/home/you/.local/share/jdbc/jtds-1.3.1.jar",
        "host": "db3.company.data",
        "port": 54059,
        "database": ["Schema1", "Schema2"],
        "authentication": {
          "type": "domain_password",
          "domain": "company.corp",
          "user": "user",
          "password_env": "MSSQL_PASSWORD"
        }
      }
    }
  ]
}
```

SQL-password authentication uses the same outer profile shape and omits `domain`:

```json
{
  "transport": "jdbc",
  "driver": "jtds",
  "driver_path": "/home/alice/.local/share/jdbc/jtds-1.3.1.jar",
  "java_executable": "/usr/bin/java",
  "host": "sql.example.com",
  "database": "warehouse",
  "authentication": {
    "type": "sql_password",
    "user": "orbit",
    "password_env": "MSSQL_PASSWORD"
  }
}
```

JDBC profiles accept only these structured fields; raw JDBC URLs and arbitrary driver properties are not accepted:

- `transport`: required literal `jdbc`.
- `driver`: required literal `jtds`; the initially supported driver version is exactly jTDS 1.3.1.
- `driver_path`: required absolute path to the user-provided jTDS 1.3.1 JAR. Profile values are literal, so `$HOME` and `~` are not expanded.
- `java_executable`: optional non-empty Java command name or path; defaults to `java` from `PATH`.
- `host`: required non-empty SQL Server host.
- `port`: optional integer from `1` through `65535`; defaults to `1433` when neither `port` nor `instance` is present.
- `instance`: optional non-empty named instance. `port` and `instance` are mutually exclusive.
- `database`: optional non-empty string or non-empty array of unique non-empty strings. Omitting it uses and browses the login's default database. For an array, the first entry is the retained JDBC connection's default and schema acquisition includes every entry.
- `authentication`: required object with `type`, `user`, exactly one of `password` or `password_env`, and `domain` only when `type` is `domain_password`. Supported types are `sql_password` and `domain_password`; domain authentication enables NTLMv2.
- `trust_server_certificate`: optional boolean; defaults to `false`.
- `schema_patterns`: optional non-empty array whose entries are non-empty schema globs using `*` and `?`.
- `confirm_mutations`: optional boolean per-profile mutation-confirmation override.

The helper always requests encrypted TLS. By default, jTDS uses `ssl=authenticate`, which requires a certificate signed by an authority trusted by the JVM; there is no plaintext fallback. jTDS does not document hostname matching for this mode, so do not treat it as equivalent to a modern hostname-verified TLS client. Setting `trust_server_certificate = true` explicitly changes this to `ssl=require`, retaining encryption but bypassing certificate-chain validation. This is unsafe and permits man-in-the-middle attacks.

Orbit resolves either the direct password or `password_env` value before launch. It excludes the credential from process arguments, the generated JDBC URL, and the Java child environment, then sends it only through the helper's length-framed standard input after Java starts. The URL and driver properties are built by Orbit from the validated fields.

jTDS 1.3.1 is an old driver whose general SQL Server, Java, authentication, and TLS compatibility should not be assumed. On Linux with Java 25, live verification passed against SQL Server `16.0.4252.3` using explicit domain credentials; SQL Server reported `NTLM`, while deterministic property checks confirm Orbit enabled jTDS `useNTLMv2`. Retained state, structured values, single-database schema acquisition, error recovery, cancellation, and reconnection passed. Multi-database acquisition, including cross-database permissions, Unicode database names, and mixed collations, has deterministic coverage only. The test server's certificate chain was not trusted by the JVM: secure `ssl=authenticate` failed with a PKIX error, while the explicit unsafe path connected with the client configured as `ssl=require`. Server-side encryption-state inspection was unavailable to this account. Successful certificate-chain validation, hostname behavior, other servers, and other authentication modes remain unverified.

</details>

<details>
<summary>Redis</summary>

### Local Redis

Start a local Redis container and verify it independently of Orbit:

```sh
docker run --name orbit-redis -p 127.0.0.1:6379:6379 -d redis:8-alpine
redis-cli -h 127.0.0.1 -p 6379 PING
```

The second command should print `PONG`. Add this profile to the profile file:

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "local-redis",
      "kind": "redis",
      "options": {
        "host": "127.0.0.1",
        "port": 6379,
        "database": 0
      }
    }
  ]
}
```

Run `:OrbitDoctor redis`, open `:OrbitWorkspace`, select `local-redis`, and create a query buffer with `n`. Redis commands execute from the current line. Stop and remove the example container with `docker rm -f orbit-redis` when it is no longer needed.

### Authenticated Redis

Set the password variable before starting Neovim when the Redis ACL identity requires authentication:

```sh
export REDIS_PASSWORD='replace-me'
```

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "app-cache",
      "kind": "redis",
      "options": {
        "host": "redis.example.com",
        "port": 6379,
        "database": 0,
        "user": "orbit",
        "password_env": "REDIS_PASSWORD",
        "tls": true,
        "cacert": "/home/you/.local/share/redis/ca.pem",
        "key_pattern": "app:*",
        "key_limit": 10000,
        "scan_count": 1000
      }
    }
  ]
}
```

`host` is required. `port` defaults to `6379`, `database` to `0`, `key_pattern` to `*`, `key_limit` to `10000`, and `scan_count` to `1000`. `database` is a non-negative integer; the limits are positive integers. `password_env` is optional; setting the optional ACL `user` also requires `password_env`. Orbit passes the resolved password only as `REDISCLI_AUTH` in a sanitized child environment, never in argv.

Set `tls = true` to enable TLS. Optional `cacert` and `cacertdir` are mutually exclusive; optional client `cert` and `key` must be configured together; `sni` sets the TLS server name. TLS fields are rejected unless TLS is enabled. `executable` can replace `redis-cli`, and `confirm_mutations` retains its ordinary per-profile meaning. Free-form `arguments`, credential-bearing URIs, Cluster mode, and insecure TLS are not accepted.

Binding the profile asynchronously runs `COMMAND` and cursor-based `SCAN MATCH <key_pattern> COUNT <scan_count>`. The Redis key index is in memory, scoped to the complete profile and logical database, deduplicated, and capped by `key_limit`. Press `r` on the profile in the Workspace to refresh it. Orbit never runs `KEYS` automatically; `KEYS` is blocking and intended only for deliberate use. If ACLs deny `COMMAND` or `SCAN`, statement execution remains available but precise key completion does not.

Redis query buffers execute the current nonblank line; a visual selection must contain exactly one line. Each Statement launches one `redis-cli` process with RESP3 JSON output. Scalar and array replies render under `value`; map replies render under `key` and `value`; nested replies are JSON text. This projection is not binary-lossless. `.redis` saved queries are supported, while the SQL Structure panel is disabled for Redis buffers.

</details>

<details>
<summary>MySQL</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "app-mysql",
      "kind": "mysql",
      "options": {
        "database": "app",
        "host": "mysql.example.com",
        "port": 3306,
        "user": "alice",
        "sslmode": "verify_identity",
        "arguments": [
          "--login-path=orbit",
          "--ssl-ca=/home/alice/.mysql/ca.pem"
        ]
      }
    }
  ]
}
```

### MySQL Profiles

Use TCP for Docker and remote servers. Use a Unix socket only when Neovim and MySQL can access the same socket file on one machine. MySQL passwords are not connection-profile options; configure them through the selected client's credential file.

#### Oracle MySQL Client

Create a protected login path. This command prompts for the password without placing it in shell history:

```sh
mysql_config_editor set \
  --login-path=orbit \
  --host=mysql.example.com \
  --port=3306 \
  --user=alice \
  --password
```

Then paste the complete MySQL profile shown above into the profile file and replace the example host, database, user, home directory, and CA path. `client_family` and `executable` default to `mysql` and can be omitted.

#### MariaDB Client With Local Docker

The MariaDB client can connect to a MySQL 8.x server but cannot read Oracle MySQL login paths. Create a dedicated owner-only option file instead:

```bash
mkdir -p ~/.local/share/orbit.nvim
read -rsp "MySQL password: " MYSQL_PASSWORD; printf '\n'
umask 077
printf '[client]\npassword=%s\n' "$MYSQL_PASSWORD" \
  > ~/.local/share/orbit.nvim/mysql-docker.cnf
unset MYSQL_PASSWORD
```

Paste this complete profile into the profile file. Replace `/home/you` with the value printed by `printf '%s\n' "$HOME"`:

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "docker-mysql",
      "kind": "mysql",
      "options": {
        "database": "orbit_dev",
        "host": "127.0.0.1",
        "port": 3306,
        "user": "orbit",
        "client_family": "mariadb",
        "executable": "mariadb",
        "arguments": [
          "--defaults-extra-file=/home/you/.local/share/orbit.nvim/mysql-docker.cnf"
        ]
      }
    }
  ]
}
```

Publish the container's MySQL port, for example with `-p 3306:3306`. If Neovim runs in another container on the same Docker network, replace `127.0.0.1` with the MySQL service name. Set `client_family` explicitly even when the MariaDB executable is named `mysql`; executable names do not reliably identify the client family. MariaDB servers are not supported.

#### Unix Socket

Replace `host` and `port` with the socket path in either profile shape:

```json
{
  "database": "app",
  "user": "alice",
  "socket": "/run/mysqld/mysqld.sock"
}
```

Socket profiles cannot set `host`, `port`, or `sslmode`. Mounting a container socket onto the host is possible, but publishing the TCP port is usually simpler.

#### MySQL Connection Scenarios

- **Local Docker:** Publish `3306`, then connect to `127.0.0.1:3306`.
- **Docker-to-Docker:** Put both containers on one network, then use the MySQL service name and port `3306`.
- **Remote MySQL:** Use the server DNS name and port, `sslmode: "verify_identity"`, and a trusted CA. The server firewall and MySQL grants must permit the client address.
- **SSH tunnel:** Run `ssh -L 3307:127.0.0.1:3306 user@remote-host`, then connect to `127.0.0.1:3307`. Because that loopback host normally does not match the server certificate, Oracle MySQL users should use `verify_ca` with a trusted CA, or use a local hostname that resolves to `127.0.0.1` and appears in the certificate. MariaDB clients do not expose an equivalent CA-only mode.

Oracle MySQL clients support `disabled`, `preferred`, `required`, `verify_ca`, and `verify_identity` for `sslmode`. MariaDB clients support `disabled`, `preferred`, and `verify_identity`; other modes fail validation rather than silently changing their security meaning. Pass CA files through `arguments`, as shown in the Oracle profile.
</details>

<details>
<summary>PostgreSQL</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "app-db",
      "kind": "postgres",
      "options": {
        "database": "postgres",
        "host": "postgres.example.com",
        "port": 5432,
        "user": "postr",
        "password": "somePassword",
        "sslmode": "require"
      }
    }
  ]
}
```

</details>

<details>
<summary>Vertica</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "warehouse",
      "kind": "vertica",
      "options": {
        "host": "vertica.example.com",
        "port": 5433,
        "database": "warehouse",
        "user": "alice",
        "password": "somePassword",
        "sslmode": "require"
      }
    }
  ]
}
```

</details>

<details>
<summary>SQLite</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "local",
      "kind": "sqlite",
      "options": {
        "path": "/home/projects/data.db"
      }
    }
  ]
}
```

</details>

<details>
<summary>Trino</summary>

```json
{
  "version": 1,
  "profiles": [
    {
      "name": "analytics",
      "kind": "trino",
      "options": {
        "server": "https://trino.example.com:8443",
        "user": "alice",
        "catalog": "hive",
        "schema": "analytics",
        "arguments": ["--password"],
        "output_format": "CSV_HEADER",
        "schema_patterns": {
          "hive": ["analytics", "reporting"],
          "iceberg": []
        }
      }
    }
  ]
}
```

### Trino Multi-Catalog Schema Browser

Trino profiles still require `catalog` as the CLI's default catalog, but `schema_patterns` can browse schemas from multiple catalogs. Orbit retains each object's catalog for column inspection, copied names, and generated sample statements:

```json
{
  "catalog": "gridhive",
  "schema_patterns": {
    "catalog_1": ["data_v2"],
    "catalog_2": ["aggr", "cleanroom", "report"],
    "iceberg": ["cleanroom"],
    "sqlserver_rep": ["dbo"]
  }
}
```

An empty array, such as `"catalog_1": []`, includes every non-system schema from that catalog. Omit a catalog entirely to hide it.

Trino defaults to `"output_format": "CSV_HEADER"`. This supports every Trino result type, including maps, arrays, rows, and binary values, by displaying the CLI's text representation. CSV represents both SQL `NULL` and an empty string as an empty cell. Set `"output_format": "JSON"` when preserving native scalar values and distinct nulls is more important and statements do not return maps or other complex container types; the stock Trino CLI cannot serialize those values in JSON mode.

Set `output_format` inside the Trino profile's `options` object. Use the default for statements that may return complex values:

```json
{
  "output_format": "CSV_HEADER"
}
```

Switch to JSON for scalar-only results:

```json
{
  "output_format": "JSON"
}
```

Run `:OrbitProfiles`, change the value in the profile's existing `options` object, and save the profile file. The next statement uses the new format. Omitting `output_format` is equivalent to `"CSV_HEADER"`.
</details>

### Authentication

Default MSSQL `sqlcmd` profiles require SQL authentication through either `options.password` or `options.password_env`. Orbit resolves the password before starting Go `sqlcmd` and passes it only as `SQLCMDPASSWORD` in the sanitized child environment. JDBC/jTDS profiles instead use an `authentication` object with `sql_password` or explicit `domain_password` credentials and exactly one password source; their resolved password travels only over helper stdin. Windows integrated authentication, Kerberos, and Microsoft Entra authentication are not supported.

PostgreSQL profiles may include `options.password`. Orbit passes it only to `psql` as `PGPASSWORD`, never as a command-line argument. The profile file is owner-protected (`0600`), but a password remains sensitive; use your system's credential management or a `~/.pgpass` file if you prefer not to store it in JSON.

Vertica profiles may include `options.password`. Orbit passes it only to `vsql` as `VSQL_PASSWORD`, never as a command-line argument.

MySQL profiles do not accept a password. Follow [MySQL Profiles](#mysql-profiles) to configure an Oracle MySQL login path or a protected MariaDB option file.

Configure Trino authentication exactly as you do for the Trino CLI, including its `--password` flag, environment variables, tokens, keyrings, or credential providers it uses.

Orbit passes profile values to the CLI as literal arguments. It does **not** expand `$VAR` or `${VAR}` inside JSON. Other Trino CLI authentication mechanisms, such as tokens or external credential providers, continue to work through their normal CLI configuration.

> [!NOTE]
> Connection profiles can contain sensitive settings, including MSSQL, PostgreSQL, and Vertica passwords. Orbit requires the profile file to be mode `0600`; do not copy it into a repository or share it.

## Workspace Workflow

`:OrbitWorkspace` toggles a dedicated Orbit tabpage with a profile/schema browser and a normal query-editing window. Run it once to open the Workspace and again to close it.

1. Press `<CR>` on a profile to select it and bind it to the active query buffer.
2. Optionally press `l` to load its schema or Redis key index for browsing and completion.
3. Press `n` to open a new query buffer already bound to the selected profile.
4. Execute a statement. Results appear in the reusable bottom result grid.

Schema browser labels normally retain their familiar dotted form. If distinct catalog/schema combinations would display the same label, Orbit quotes their segments to distinguish them, for example `"a.b"."c"` versus `"a"."b.c"`. These labels stay stable while filtering, and each group's expansion and metadata state remain independent. Copied qualified names and SQL completion formatting are unchanged.

Set `saved_query_dirs` to add ordered, named recursive trees of `.sql` and `.redis` files to the sidebar:

```lua
saved_query_dirs = {
  { Work = "~/queries/work" },
  { Personal = "~/queries/personal" },
}
```

Each entry must contain one unique display name and directory. Orbit preserves the configured order, expands paths such as `~`, and shows each location as a separate top-level tree collapsed by default. Select a profile, then press `<CR>` on a saved query to open it in the Workspace query window bound to that profile; loading the schema is not required. Press `r` on any saved-query directory to rescan only its top-level location.

Run `:OrbitSave` from a Workspace query buffer to save it into a configured location. Orbit lets you choose from the available locations and their existing subdirectories, prompts for a filename, and adds `.sql` or `.redis` according to the bound profile when needed. Existing files require confirmation. After saving, the current buffer becomes the saved file, so later `:w` writes it normally, and the Workspace reveals it in the saved-query tree.

Press `a` on a saved query to open, preview, rename, move, or delete it. Rename and Move refuse to overwrite an existing file and keep an open query buffer attached to its new path, including unsaved edits. Move can target any existing directory under a configured saved query location. Delete requires confirmation and preserves an open query as an unnamed buffer so its contents are not lost.

From a workspace query buffer, `/` focuses the workspace filter. Elsewhere, `/` retains normal Neovim search behavior.

## Commands

| Command                | Description                                                                  |
| ---------------------- | ---------------------------------------------------------------------------- |
| `:OrbitProfiles`       | Create, protect, and edit the profile file.                                  |
| `:OrbitProfile`        | Search profiles and bind one to the current query buffer.                    |
| `:OrbitSelectProfile`  | Alias for `:OrbitProfile`.                                                   |
| `:OrbitExecute`        | Execute the single unambiguous statement in the current buffer.              |
| `:'<,'>OrbitExecute`   | Execute the selected line range.                                             |
| `:OrbitCancel`         | Cancel the statement running in the current buffer.                          |
| `:OrbitDisconnect`     | Close the connection for the current buffer's profile.                       |
| `:OrbitDoctor [kind]`  | Diagnose profiles, executable selection, and versions without connecting.    |
| `:OrbitStructure`      | Toggle the current query buffer's Structure panel.                           |
| `:OrbitSave`           | Save a Workspace query buffer into a saved query location.                   |
| `:OrbitWorkspace`      | Toggle the Orbit workspace tabpage.                                          |

Whole-buffer execution rejects ambiguous multi-statement content. Select the exact statement in Visual mode, then run `:OrbitExecute` or `<leader>E`.

With no argument, `:OrbitDoctor` diagnoses every Connector. Supply `mssql`, `mysql`, `postgres`, `redis`, `sqlite`, `trino`, or `vertica` to restrict the report. For default MSSQL profiles, `:OrbitDoctor mssql` preserves the existing `sqlcmd` checks: it validates the profile file, reports the user-installed executable selected from an override or `PATH`, invokes only `--version`, and checks `password_env` presence. For JDBC profiles, it checks the password source, Java executable, readable jTDS JAR, Java 11+ source-file execution, and exact jTDS 1.3.1 class loading through the helper's doctor mode. It does not install anything, execute SQL, or open a database session, and it redacts known profile secrets from diagnostic output.

## Keybindings

### Configurable Mappings

Orbit installs the following defaults:

| Mode and scope          | Default     | Action                                                   |
| ----------------------- | ----------- | -------------------------------------------------------- |
| Normal, global          | `<leader>D` | Toggle the Workspace tabpage.                            |
| Normal, SQL buffer      | `<leader>E` | Execute the buffer statement.                            |
| Visual, SQL buffer      | `<leader>E` | Execute the visual selection.                            |
| Normal, Structure panel | `<leader>E` | Execute the highlighted Structure element.               |
| Normal, SQL buffer      | `<leader>P` | Select a connection profile.                             |
| Normal, SQL buffer      | `<leader>X` | Cancel the running statement.                            |
| Normal, SQL buffer      | Disabled    | Toggle the Structure panel (`structure = false`).        |

Configure action mappings through `keymaps`. `execute` also applies in the Structure panel; `cancel`, `select_profile`, and the disabled-by-default `structure` action are buffer-local in SQL buffers, while `workspace` is global. Set an action to `false` to disable it.

```lua
require("orbit").setup({
  keymaps = {
    execute = "<leader>E",
    workspace = "<leader>D",
    select_profile = "<leader>P",
    cancel = "<leader>X",
    structure = false,
  },
})
```

### Workspace Sidebar

| Key             | Action                                                                                                      |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| `l`             | Expand the selected profile, schema, object group, table metadata folder, or object.                        |
| `h`             | Collapse the selected node.                                                                                 |
| `<CR>`          | Select and bind a profile to the current query buffer, or open a saved query bound to the selected profile. |
| `n`             | Create a query buffer bound to the selected profile.                                                        |
| `s`             | Open a bound sample statement for the selected table or view.                                               |
| `a`             | Select an action for the selected table, view, or saved query.                                              |
| `y`             | Copy the qualified selected table or view name.                                                             |
| `P`             | Preview the selected saved query without opening or binding it.                                             |
| `/`             | Focus the filter from the sidebar or a Workspace query buffer.                                              |
| `r`             | Reload the profile file and refresh its schema or Redis key index, or rescan saved queries.                 |
| `Z`             | Collapse the open profile metadata tree.                                                                    |
| `<2-LeftMouse>` | Activate the clicked node; expandable nodes toggle, profiles bind, and saved queries open.                  |
| `?`             | Show help.                                                                                                  |
| `q`             | Close the workspace.                                                                                        |

While editing the Workspace filter, press `<Esc>` to finish filtering. In a saved-query preview, `q` or `<Esc>` closes the preview. In Workspace help, `q`, `?`, or `<Esc>` closes the help window.

Expanding a table reveals its available metadata folders. MSSQL provides columns. SQLite, PostgreSQL, and MySQL provide columns, primary keys, foreign keys, and indexes; Vertica provides columns, primary keys, foreign keys, and projections. Each folder loads on demand. Views remain under the schema's `views` group and expose their columns.

### Saved Queries

![saved](./assets/savedqueries.png)

Saved queries are `.sql` or `.redis` files kept in named directories that appear as their own section in the Workspace sidebar. Configure one or more via `saved_query_dirs`:

```lua
require("orbit").setup({
  saved_query_dirs = {
    { Personal = "~/sql/personal" },
    { Team = "~/projects/app/sql" },
  },
})
```

To add a query, run `:OrbitSave` from a Workspace query buffer. It prompts for a destination directory (when more than one is configured) and a filename, then writes the buffer's contents there.

Save, Rename, Move, and Delete revalidate the selected location and file identity before changing anything. Orbit refuses stale or replaced files, never follows descendant symlinks, creates destinations exclusively, and keeps an open buffer synchronized with a successful filesystem change.

In the sidebar, pressing `<CR>` on a saved query opens it bound to its profile, and pressing `a` on a saved query brings up an action menu:

| Action  | Effect                                         |
| ------- | ---------------------------------------------- |
| Open    | Open the query bound to its profile.           |
| Preview | Show the query's contents without opening it.  |
| Rename  | Rename the file in place.                      |
| Move    | Move the file to another configured directory. |
| Delete  | Remove the file after confirmation.            |

Pressing `P` previews a saved query directly, without going through the menu. Pressing `r` rescans all configured directories, picking up files added or removed outside of Neovim.

### Structure Panel

![structure panel](./assets/structure.png)

`:OrbitStructure` opens a fixed-width panel at the far-right edge of the current tabpage and focuses it. Running the command again closes the panel. The panel works in ordinary SQL tabs and in the Orbit Workspace, follows the active query buffer, and updates as statements are edited.

By default, statements are grouped under expanded `DDL`, `DML`, `SELECT`, and `Other` headings and sorted alphabetically within each group. Each row keeps its expand/collapse marker and adds a semantic icon distinguishing category groups, statement categories, `WITH` containers, CTEs, query blocks, and clauses. Statement parents start collapsed. A leading `WITH` clause expands into its named CTEs, and each CTE owns one query block per top-level `UNION`, `INTERSECT`, or `EXCEPT` branch. Query blocks expose their `SELECT`, `FROM`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW`, `ORDER BY`, `LIMIT`, and `OFFSET` clauses. Parenthesized `SELECT` and `WITH` blocks recurse beneath their owning clause, while ordinary function calls and grouped expressions remain inline. The outer query block appears beside the `WITH` container. Orbit ignores comments in labels and highlights the deepest visible element containing the query-buffer cursor.

| Key         | Action                                                                          |
| ----------- | ------------------------------------------------------------------------------- |
| `h`         | Collapse the selected node, or move to its parent.                              |
| `l`         | Expand the selected node, or move to its first child.                           |
| `j`, `k`    | Move through visible tree nodes.                                                |
| `zh`, `zl`  | Scroll horizontally through a complete SQL label.                               |
| `<leader>E` | Execute the highlighted element using the configured `keymaps.execute` mapping. |
| `<CR>`      | Return to the query buffer and navigate to the selected element.                |
| `/`         | Filter statement labels using case-insensitive substring matching.              |
| `<Esc>`     | Clear the filter, or close the panel when no filter is active.                  |
| `q`         | Close the panel and return to the query buffer.                                 |

Executing a statement, query block, or `SELECT` clause uses that element's exact source range. Other rows execute their containing top-level statement. Extracted query blocks and clauses are not guaranteed to be independently valid, so connector errors are shown through the normal diagnostic split.

Structure parsing is dependency-free and tolerant of incomplete SQL. It outlines reliably bounded query blocks and clauses rather than guessing at every SQL expression. Labels retain their complete normalized SQL even when they exceed `structure_width`; the panel remains fixed-width with wrapping disabled. PostgreSQL dollar-quoted bodies and SQLite trigger bodies are kept together; other dialect-specific procedural constructs may appear as best-effort entries.

### Result Grid

| Key                | Action                                                                   |
| ------------------ | ------------------------------------------------------------------------ |
| `h`, `j`, `k`, `l` | Move between cells.                                                      |
| `<CR>`             | Inspect a read-only value, or edit the focused cell in an editable grid. |
| `y`                | Copy the raw selected value.                                             |
| `q`                | Close the standalone grid, or return to the query editor in a Workspace. |

Workspace sample statements for MySQL, PostgreSQL, and SQLite base tables become editable when Orbit can load a primary key. MSSQL, ad-hoc statements, views, Trino, Vertica, and tables without a primary key remain read-only.

| Key / command       | Action                                                                     |
| ------------------- | -------------------------------------------------------------------------- |
| `o`, `O`            | Insert a local row below or above the current row.                         |
| `i`, `<CR>`         | Enter Insert mode in the focused cell; press `Esc` to keep the local edit. |
| `dd`                | Mark the current row for local deletion.                                   |
| `V`, `j` / `k`, `d` | Select complete rows and delete the selection.                             |
| `<Esc>`             | Clear the current row selection.                                           |
| `u`                 | Undo the most recent local edit.                                           |
| `gg`, `G`           | Move to the first or last result row while retaining the focused column.   |
| `:w`                | Confirm, transactionally save, and reload pending changes.                 |
| `:wq`               | Save successfully, then close the Result grid.                             |
| `:q!`               | Discard local changes and close.                                           |
| `:e!`               | Discard local changes and reload the table.                                |

Edits are never sent to the database until `:w`. A failed write leaves the local Result grid unchanged.
Type `NULL` as the complete cell value to write a SQL `NULL` value.

Normal Neovim scrolling remains available, including `<C-d>`, `<C-u>`, `zh`, and `zl`.

In the raw-value inspector, `y` copies the complete value and `q` closes the window.

### Diagnostic Window

Database and execution errors may open in a diagnostic split. Press `q` there to close it.

### Schema Object Actions

Press `a` on a table or view in the Workspace schema browser to select an action supplied by its connection profile kind. Actions that inspect metadata open in the Result grid; sample actions create a bound query buffer instead.

- MSSQL: `SELECT TOP (N)` sample statement and columns.
- SQLite: sample statement, columns, primary keys, indexes, foreign keys, and object definition.
- PostgreSQL: sample statement, columns, primary keys, indexes, foreign keys, and view definition.
- MySQL: sample statement, columns, primary keys, indexes, foreign keys, and view definition.
- Vertica: sample statement, columns, primary keys, foreign keys, projections, and view definition.
- Trino: sample statement and columns.

Available actions are intentionally connector-specific. Orbit does not present metadata actions that the selected CLI or database cannot support reliably.

## Completion

Orbit's metadata-aware completion (tables, views, columns, table aliases, Redis commands, and Redis keys) is provided entirely through a [blink.cmp](https://github.com/Saghen/blink.cmp) source — there is no native/omnifunc fallback, so blink.cmp is required to get any Orbit completion suggestions. blink.cmp has no API for a plugin to register itself as a source at runtime, so add it to your own blink.cmp config:

```lua
{
  "saghen/blink.cmp",
  opts = {
    sources = {
      default = { "lsp", "path", "snippets", "buffer", "orbit" },
      providers = {
        orbit = { name = "orbit", module = "orbit.blink" },
      },
    },
  },
}
```

Once wired up, suggestions appear automatically as you type, no manual trigger needed. Completion is clause-aware: it parses the statement around your cursor (not just the current line) with a small dependency-free SQL tokenizer, so suggestions depend on where you are:

- Tables and views after any `FROM`-family clause (`FROM`, `JOIN`, `UPDATE`, `INTO`), and after database/schema/catalog qualifiers on Connectors that support them (MSSQL, MySQL, PostgreSQL, Trino).
- Trino catalogs configured as top-level `schema_patterns` keys are offered alongside direct relation suggestions. Selecting a catalog and schema completes progressively (`catalog.` → `catalog.schema.` → `catalog.schema.table`); without `schema_patterns`, only the profile's default `catalog` is offered.
- Columns in the `SELECT` list, `WHERE`, `ON`, `GROUP BY`, `ORDER BY`, `INSERT INTO t (...)`, and `UPDATE t SET ...`.
- Table aliases: `SELECT u.| FROM users u` resolves `u` to `users`'s columns, including old-style comma joins (`FROM a, b`). With more than one table in scope, unqualified columns are offered from every table, each annotated with its source alias.
- Alias/table scope is limited to the query block and set-operation branch containing the cursor, plus SQL-visible correlated outer blocks. Sibling subqueries and `UNION`/`INTERSECT`/`EXCEPT` branches do not leak aliases; `JOIN ... ON` sees only tables introduced so far; non-`LATERAL` derived tables are isolated, while `LATERAL` derived tables see preceding sources. CTEs and derived tables (`FROM (SELECT ...) sub`) are recognized but do not offer inferred columns.
- Suggestions are narrowed to whatever you've already typed (case-insensitive prefix match) before being handed to blink.cmp, so its own fuzzy scoring only ever sees genuinely relevant candidates.
- Redis command names are offered in the first token. Redis keys are offered only where cached `COMMAND` metadata identifies a key argument; matching is case-sensitive because Redis keys are binary strings. Keys requiring Redis CLI quoting are inserted with exact escaping.

MSSQL completion uses bracket-qualified schema and object names such as `[sales].[orders]` for string profiles. Array profiles use three-part names such as `[Schema].[sales].[orders]` and complete progressively through database and schema namespaces. They appear in the schema browser under flattened `database.schema` groups. Completion uses only acquired objects, including the login-default database when a JDBC profile omits `database`.

Selecting a relational profile preloads tables and views in the background. Selecting Redis preloads command metadata and a bounded key index through `SCAN`; explicit Workspace refresh reloads it. Completion never runs a Connector executable while you type. SQL keywords and functions, formatting, and highlighting remain the responsibility of your existing SQL tooling.

Set `completion = false` in Orbit's `setup()` to disable the blink source's `enabled()` check.

## Execution And Results

Orbit runs statements asynchronously through the selected profile's Connector client. For MSSQL, SQLite, PostgreSQL, MySQL, and Vertica, schema work and statements share one retained process and execute one at a time. MSSQL keeps either one interactive Go `sqlcmd` process or one Java helper and JDBC connection per connection profile, so transactions, temporary tables, and other session state can persist until disconnect, cancellation, connection failure, malformed helper protocol, profile change, or exit. An ordinary JDBC SQL error is request-scoped and preserves the retained connection. Trino and Redis statements each run their own CLI invocation.

One running statement is allowed per query buffer. `:OrbitCancel` terminates an active retained process, fails work queued on that process, and starts a fresh session only when the next Statement is requested. Cancelling work that has not started removes only that queued request. Orbit reports cancellation as cancellation rather than opening diagnostics; server-side completion timing is not asserted after the CLI is terminated.

Potentially mutating statements require confirmation by default. A single `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN`, `USE`, or `VALUES` statement runs without confirmation; everything else requires it. This is a convenience guardrail, not a security boundary.

The MSSQL Connector uses a stricter T-SQL classifier: only a single `SELECT` without top-level `INTO` runs without confirmation. Data mutations, DDL, `SELECT INTO`, `EXEC`, CTEs whose effective operation mutates, and ambiguous or multiple statements require confirmation; an `OUTPUT` clause does not make a mutation read-only. Standalone `GO` batch separators are rejected rather than split.

The Redis Connector uses cached server `COMMAND` metadata. Commands marked `readonly` run without confirmation; mutating, unknown, and custom commands require confirmation. This remains a convenience guardrail rather than an ACL or security boundary.

Result grids are reused per tabpage. They show up to `result_limit` rows and truncate displayed cell text to `max_cell_width` characters while retaining the raw value for copy and inspection.

MySQL XML results preserve SQL `NULL`, empty strings, tabs, line feeds, and ordinary Unicode text. Statements returning multiple row-producing result sets fail explicitly because the Result grid represents one set. Arbitrary binary/BLOB bytes are not guaranteed to round-trip through the CLI XML format. MariaDB servers are rejected rather than treated as compatible MySQL servers.

MSSQL `sqlcmd` output handling is strict best-effort, not a lossless transport. Orbit rejects detectable malformed widths, empty or duplicate headings, informational output mixed into results, and multiple tabular result sets. Detection cannot make the format safe: a unit-separator byte or newline inside a value can collide with framing and may be undetectable; a blank one-column row is indistinguishable from result spacing; leading and trailing whitespace in every heading and cell is trimmed; the literal text `NULL` is indistinguishable from SQL `NULL`; and Go `sqlcmd` may truncate or wrap values despite Orbit's large fixed width and type limits. All cell data, including apparent `NULL`, remains text and Orbit performs no typed decoding. Statements capable of reproducing Orbit's internal marker output can break in-band framing, so framing is not a security boundary. Do not rely on an MSSQL `sqlcmd` Result grid for byte-for-byte export or type preservation.

The MSSQL JDBC transport returns one structured tabular result with ordered column labels, string cell values, and SQL `NULL` kept distinct from empty strings and literal `NULL` text. A non-row statement returns an empty result. Empty or duplicate labels and multiple tabular result sets fail explicitly rather than being normalized, merged, or discarded. Schema acquisition and ordinary statements use the same retained JDBC connection; existing MSSQL schema browsing, completion, bracket-qualified names, mutation confirmation, `GO` rejection, and read-only grids are retained.

Orbit rejects other detectable malformed CLI formats rather than rendering partial rows. This includes incomplete CSV/XML/HTML records, duplicate or empty column headings, invalid encoded entities, inconsistent tabular row widths, and JSON rows that are not objects.

### MSSQL Scope And Limits

These tables describe implemented behavior plus one narrow live compatibility observation. No live `sqlcmd` transport verification occurred. JDBC verification passed on Linux with Java 25, jTDS 1.3.1, SQL Server `16.0.4252.3`, explicit domain credentials, server-reported NTLM, and the unsafe certificate-trust bypass. Orbit set `useNTLMv2` and `ssl=require`, but this account could not independently inspect the NTLM version or server-side encryption state. Secure certificate-chain validation refused the test server's untrusted chain as expected; a successful trusted-chain connection and hostname behavior remain unverified. Do not generalize this result to other environments.

#### Microsoft Go sqlcmd Transport

| Area | Implemented contract | Current limit |
| ---- | -------------------- | ------------- |
| CLI | User-installed Microsoft Go `sqlcmd`, selected from `options.executable` or `PATH` | Other implementations sharing the `sqlcmd` name are not targeted. |
| Authentication | SQL username/password through sanitized `SQLCMDPASSWORD` | Integrated, Kerberos, and Microsoft Entra authentication are unsupported. |
| Transport | Mandatory encryption; certificate validation by default | `trust_server_certificate = true` adds unsafe `-C` and bypasses validation. |
| Addressing | One TCP host and fixed port; `database` may list multiple databases on that server | Named-instance discovery is unsupported; every listed database must be accessible to the login. |
| Session | One retained interactive CLI process per profile | Cancellation, failure, disconnect, profile changes, and exit discard it. |
| Schema acquisition | User tables and views excluding Microsoft-shipped objects, columns, and optional schema globs | Primary keys, foreign keys, indexes, and definitions are not exposed. |
| Object UX | `SELECT TOP (N)` samples, columns action, bracket-qualified names, and bracket-aware completion | Result grids are read-only. |
| Results | Zero or one separator-delimited tabular result parsed into text cells | Output is best-effort and lossy; multiple sets and informational output are rejected. |
| T-SQL input | One Statement with conservative mutation confirmation | Active `GO` lines and sqlcmd control commands (`:...`, `!!`, `ED`, `RESET`, `ON ERROR`, `EXIT`, and `QUIT`) are rejected. |

#### JDBC Transport With jTDS 1.3.1

| Area | Implemented contract | Current limit |
| ---- | -------------------- | ------------- |
| Runtime | User-installed Java 11+ source-file runtime and user-provided jTDS 1.3.1 JAR | Java 25 was verified; Orbit performs no download, bundle, installation, or update. |
| Authentication | Structured `sql_password` or explicit `domain_password`; NTLMv2 for domain credentials | Integrated authentication, Kerberos, Microsoft Entra, and other modes are unsupported. |
| Transport | Encrypted TLS with JVM-trusted certificate-chain validation by default | jTDS does not document hostname matching; `trust_server_certificate = true` also bypasses chain validation. |
| Addressing | Structured host, optional mutually exclusive port or instance, and optional string or array `database` | Port defaults to `1433`; raw JDBC URLs and arbitrary driver properties are unsupported. |
| Session | One retained Java helper and JDBC connection per profile; ordinary SQL errors preserve it | Connection/protocol failure, cancellation, disconnect, profile changes, and exit discard it. |
| Cancellation | Active cancellation terminates the JVM and fails work queued on it; later work reconnects | Server-side completion timing after process termination is not asserted. |
| Schema and object UX | Same tables, views, columns, schema globs, samples, naming, completion, and mutation policy as `sqlcmd` | Result grids remain read-only. |
| Results | Zero or one structured tabular result with ordered labels, text values, and distinct SQL `NULL` | Empty/duplicate labels and multiple tabular result sets are rejected; SQL types are not retained. |

## Configuration

```lua
require("orbit").setup({
  completion = true,
  confirm_mutations = true,
  focus_results = false,
  profile_path = vim.fn.expand("~/.local/share/orbit.nvim/profiles.json"),
  result_limit = 200,
  result_height = 15,
  structure_view = {
    group_by_type = true,
    show_ddl = true,
    show_dml = true,
    show_other = true,
    show_select = true,
    sort_alphabetically = true,
  },
  structure_width = 40,
  saved_query_dirs = {
    { Work = "~/queries/work" },
    { Personal = "~/queries/personal" },
  },
  max_cell_width = 48,
  workspace_sidebar_width = 32,
  workspace_result_ratio = 0.30,
  winbar = false,
  icons = {
    clause = "󰅪",
    collapsed = ">",
    column = "󰠵",
    cte = "󰌷",
    expanded = "󰘖",
    folder = "󰉋",
    index = "",
    key = "",
    profile = "󰆼",
    query = "󰆋",
    query_block = "󰆋",
    result = "󰎟",
    saved_query = "󰆼",
    schema = "",
    statement_ddl = "󰒓",
    statement_dml = "󰏫",
    statement_other = "󰌋",
    statement_select = "󰍉",
    table = "󰓫",
    view = "󰈈",
    with = "󰙅",
    workspace = "󱓞",
  },

})
```

| Option                    | Default                                   | Description                                                                                                                                                          |
| ------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `completion`              | `true`                                    | Enable clause-aware completion via the blink.cmp source's `enabled()` (requires wiring `orbit.blink` into your own blink.cmp config; see [Completion](#completion)). |
| `confirm_mutations`       | `true`                                    | Ask before statements that are not recognised as read-only. A profile can override this with `options.confirm_mutations`.                                            |
| `focus_results`           | `false`                                   | Focus a completed standalone result grid instead of keeping focus in the query buffer.                                                                               |
| `profile_path`            | `~/.local/share/orbit.nvim/profiles.json` | Location of the profile file.                                                                                                                                        |
| `result_limit`            | `200`                                     | Maximum returned rows displayed in the result grid.                                                                                                                  |
| `result_height`           | `15`                                      | Height of a standalone result grid.                                                                                                                                  |
| `saved_query_dirs`        | `{}`                                      | Ordered named directories of recursively discovered `.sql` and `.redis` files shown in the Workspace sidebar.                                                        |
| `max_cell_width`          | `48`                                      | Maximum displayed width of a result cell.                                                                                                                            |
| `structure_view`          | All fields `true`                         | Structure display controls: `group_by_type`, `show_ddl`, `show_dml`, `show_other`, `show_select`, and `sort_alphabetically`.                                         |
| `structure_width`         | `40`                                      | Width of the right-side Structure panel.                                                                                                                             |
| `workspace_sidebar_width` | `32`                                      | Width of the workspace sidebar.                                                                                                                                      |
| `workspace_result_ratio`  | `0.30`                                    | Fraction of editor height used by workspace results, with a six-line minimum.                                                                                        |
| `winbar`                  | `false`                                   | Show Orbit status in query-window winbars.                                                                                                                           |
| `keymaps`                 | See above                                 | Configurable action mappings.                                                                                                                                        |
| `icons`                   | Nerd Font glyphs                          | Override tree, schema, Workspace, result, and Structure-panel icons shown above. The legacy `query` key supplies `query_block` when the precise key is omitted.      |

Orbit colors semantic icons independently from their labels. Dark backgrounds use Catppuccin Mocha colors and light backgrounds use Catppuccin Latte colors; the palette is reapplied after `:colorscheme`. Override any group through normal Neovim highlight configuration, for example:

```lua
vim.api.nvim_set_hl(0, "OrbitIconTable", { fg = "#89b4fa" })
vim.api.nvim_set_hl(0, "OrbitIconView", { fg = "#b4befe" })
vim.api.nvim_set_hl(0, "OrbitIconColumn", { fg = "#a6e3a1" })
```

Available groups are `OrbitIconWorkspace`, `OrbitIconProfile`, `OrbitIconSchema`, `OrbitIconTable`, `OrbitIconView`, `OrbitIconColumn`, `OrbitIconFolder`, `OrbitIconKey`, `OrbitIconIndex`, `OrbitIconQuery`, `OrbitIconResult`, `OrbitIconClause`, `OrbitIconCTE`, `OrbitIconDDL`, `OrbitIconDML`, `OrbitIconSelect`, and `OrbitIconOther`.

Within `structure_view`, `show_ddl`, `show_dml`, `show_select`, and `show_other` each control a complete statement subtree. `group_by_type` places enabled, non-empty categories in DDL, DML, SELECT, Other order. `sort_alphabetically` sorts statements within those groups, or across all statements when grouping is disabled; disabling it preserves source order within each group or across the ungrouped list.

For a custom statusline, call `require("orbit").status()`. It reports the bound profile and shows elapsed time while a statement is running.
