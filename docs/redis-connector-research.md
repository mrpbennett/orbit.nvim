# Redis Connector Research

Research date: 2026-09-17. Sources are limited to this repository, official Redis documentation and source, and official JetBrains documentation.

## Recommendation

Implement Redis through the user-installed `redis-cli` as a one-shot Connector. Match DataGrip's completion model: asynchronously build a bounded, in-memory Redis key index with cursor-based `SCAN`, then serve command and key candidates from cached metadata while the user types. Do not infer keys from arbitrary Result grid cells and never invoke `KEYS` automatically.

This fits Orbit's existing boundaries: Connectors own CLI construction and parsing, the Runner owns process lifecycle, and completion reads cached metadata without performing network I/O. Redis does not fit relational Schema acquisition, so its key index remains separate from tables, views, and columns.

## DataGrip Behavior

DataGrip treats Redis keys as introspected database objects used by completion. Its Redis introspector uses `SCAN`, a default key filter, and a configurable `COUNT`; executing `KEYS *` is not documented as populating completion. Metadata refresh synchronizes the cached keyspace, while Force Refresh clears and reloads cached metadata.

The reference screenshots therefore show two views of the same keyspace, not a result-to-completion pipeline: `KEYS *` displays keys, while `GET cap` completes matching keys already known through introspection. Database `0` and the endpoint decorate candidates as scope information.

Sources:

- [JetBrains Redis support](https://www.jetbrains.com/help/datagrip/redis.html)
- [JetBrains metadata and introspection](https://www.jetbrains.com/help/datagrip/introspection.html)
- [DataGrip Redis completion announcement](https://blog.jetbrains.com/datagrip/2022/11/02/datagrip-2022-3-eap-2-redis-support/)

## Redis CLI Contract

`redis-cli [OPTIONS] [cmd [arg ...]]` executes one command and exits. Orbit tokenizes one Redis statement with Redis CLI quoting rules and passes each token as a separate `vim.system` argv entry, never through a shell. The generated invocation uses:

```text
redis-cli -h <host> -p <port> [--user <user>] [TLS options] -n <database> \
  --json --show-pushes no -e <command> <arguments...>
```

`--json` requests structured replies and RESP3, `--show-pushes no` suppresses unrelated push replies, and `-e` makes Redis command errors nonzero exits. Redis errors can be printed to stdout, so Runner failure reporting must fall back to stdout when stderr is empty.

`REDISCLI_AUTH` is safer than `-a` because it keeps the password out of process arguments. Orbit resolves `password_env`, removes both the source variable and inherited `REDISCLI_AUTH`, then starts the child with a replacement environment containing only the resolved `REDISCLI_AUTH` credential plus unrelated inherited variables.

Sources:

- [Redis CLI](https://redis.io/docs/latest/develop/tools/cli/)
- [`redis-cli` source](https://github.com/redis/redis/blob/unstable/src/redis-cli.c)
- [`sdssplitargs` quoting implementation](https://github.com/redis/redis/blob/unstable/src/sds.c)
- [RESP specification](https://redis.io/docs/latest/develop/reference/protocol-spec/)

## Key Discovery And Completion

`KEYS pattern` is O(N), tagged `@slow` and `@dangerous`, and can block the server. `SCAN` performs incremental cursor iteration: start at cursor `0`, continue until Redis returns cursor `0`, tolerate empty batches and duplicate keys, and treat `COUNT` only as a work hint. Orbit deduplicates keys and stops at `key_limit`, marking the Redis key index truncated when unvisited cursor work remains.

The Redis key index is partitioned by complete connection-profile identity, including the logical database. It is prewarmed when a Redis profile is bound and refreshed explicitly through the Workspace profile refresh action. Completion itself remains synchronous and cache-only.

Orbit loads `COMMAND` metadata separately. Command names populate first-token completion; `firstkey`, `lastkey`, and `keystep` identify ordinary key arguments; and the `readonly` flag controls mutation confirmation. Unknown or custom commands are confirmed conservatively. If ACLs deny `COMMAND` or `SCAN`, statement execution remains available and command-name completion retains a small built-in fallback, but precise key completion is unavailable.

Sources:

- [`KEYS`](https://redis.io/docs/latest/commands/keys/)
- [`SCAN`](https://redis.io/docs/latest/commands/scan/)
- [`COMMAND`](https://redis.io/docs/latest/commands/command/)
- [`COMMAND DOCS`](https://redis.io/docs/latest/commands/command-docs/)

## MVP Scope

- One standalone Redis endpoint and one logical database per connection profile; database `0` is the default.
- One-shot execution; `SELECT`, `MULTI`, `WATCH`, and other connection-local state do not persist.
- Current-line execution and one-line visual selections; pipelines and multiple-command execution are excluded.
- Blink-only command and key completion; keys are offered only in metadata-identified key positions.
- Completion-only key indexing; keys are not rendered as a Workspace tree.
- `.redis` saved queries and Redis query-buffer filetype behavior; the SQL Structure panel remains unavailable.
- Native-shape Redis result documents. Successful replies use two-space-indented JSON rather than a tabular projection; strings containing serialized JSON objects or arrays render as their inner structure.
- Structured TCP, ACL, password-environment, logical-database, TLS, and scan-limit profile fields.

Not MVP: Redis Cluster, Sentinel discovery, Unix sockets, pipelines, retained transactions, cross-database browsing, key type ranking, subcommand or Redis module-specific argument completion, arbitrary result harvesting, exact binary fidelity, or RESP push-stream handling.

## Limits And Risks

- A complete `SCAN` remains O(N) overall and consumes server/network resources. `key_pattern`, `scan_count`, and `key_limit` bound its practical impact but do not make discovery free.
- A scan is not a transactionally consistent snapshot. Duplicates, expirations, deletion, and concurrent insertion are normal; completion can be stale.
- Redis Cluster requires scanning every primary shard. `redis-cli -c` follows redirections but cannot make a keyless `SCAN` visit every shard, so Cluster is deliberately deferred.
- RESP3 includes maps, sets, booleans, doubles, nulls, and push messages. JSON representation loses some protocol distinctions, and arbitrary bulk strings may not be valid text. Orbit's Redis result document is not a byte-for-byte export.
- `COMMAND` legacy key positions do not describe every movable or dynamic key specification. Unknown positions receive no key candidates rather than speculative ones.
- Redis ACL identities used for completion should receive only the required application, `COMMAND`, and `SCAN` permissions and appropriate key patterns.

## Verification

Deterministic tests cover profile validation, CLI argv and credential environment construction, Redis CLI quoting, pretty JSON result documents, command metadata, readonly mutation classification, cursor scanning, deduplication, truncation, completion context, query-buffer filetype, saved queries, Workspace refresh, Doctor registration, and one-shot Runner process options.

Live validation on Linux used `redis-cli 8.10.1` against the official `redis:8-alpine` container. `SET`, RESP3 JSON `COMMAND`, and cursor-based `SCAN` passed; Orbit loaded command metadata, classified `GET` as readonly and `SET` as mutating, and indexed the test key. Authentication and TLS were not exercised live.
