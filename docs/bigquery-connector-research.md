# Google BigQuery Connector Research

Research date: 2026-09-04. Sources are limited to this repository and official Google Cloud documentation.

## Executive recommendation

Add an MVP `bigquery` connector around the standalone `bq` command-line tool, using one one-shot `bq query` process per Orbit statement. Do not embed the REST API in Lua and do not add a language client library or helper process for the MVP.

This follows Orbit's defining transport model: it runs database CLIs, dispatches through a stateless connector, and treats connectors without `session_command` as one-shot processes (`README.md:7`, `lua/orbit/adapters.lua:28-38`, `lua/orbit/runner.lua:133-155`). The Google Cloud CLI package includes `bq`, while the official BigQuery client libraries target C#, Go, Java, Node.js, PHP, Python, and Ruby rather than Lua ([Google Cloud CLI installation](https://cloud.google.com/sdk/docs/install), [BigQuery client libraries](https://cloud.google.com/bigquery/docs/reference/libraries)). A REST implementation would therefore make Orbit own OAuth token acquisition/refresh, HTTP retries, job polling, pagination, schema-directed row decoding, and cancellation. A Python helper using `google-cloud-bigquery` would solve those concerns but introduce Python packaging and a second private IPC protocol that the existing connectors do not need.

The recommendation is conditional on a live `bq --format=json` compatibility test before release. Official documentation exposes JSON output but does not specify every query-value conversion performed by `bq`, especially SQL `NULL` versus JSON `null`, exact large integers/decimals, and nested/repeated values ([bq reference](https://cloud.google.com/bigquery/docs/reference/bq-cli-reference)). If that gate fails, use a small Python helper built on the official `google-cloud-bigquery` library as the follow-up transport; do not hand-roll REST in Lua.

## MVP scope

- One explicit job/billing project and one explicit BigQuery location per connection profile.
- Optional default dataset and optional exact dataset allowlist for schema acquisition.
- Ambient Google Cloud CLI authentication, with optional existing Orbit `executable` and `arguments` overrides.
- One-shot GoogleSQL statement execution through `bq query`.
- JSON rows with explicit remote fetch limits and local result-grid limits.
- Projects mapped to Orbit `catalog`, datasets to `schema`, and tables/views to schema objects.
- Project-location table/view discovery, per-dataset column discovery, qualified names, completion namespaces, sample statements, columns, and logical-view definitions.
- Read-only result grids.
- Best-effort local cancellation, with the limitation that the remote job can continue and incur cost stated in documentation.

Not MVP: project discovery, multiple projects or locations in one profile, BigQuery sessions, parameter UI, job-aware server cancellation, paging beyond the initial fetch cap, editable results, primary/foreign-key folders, table options/partitions, routines/models, or Storage Read API support.

## Orbit integration constraints

### Connector contract

Orbit's normalized connector boundary is implicit and capability-based. The required practical hooks for BigQuery are `validate_options`, `prepare`, `qualified_name`, `completion_word`, `schema_statement`, `metadata_categories`, and `object_actions`; `parse` can override the generic JSON parser (`lua/orbit/adapters.lua:28-38`, `lua/orbit/runner.lua:30-37`, `lua/orbit/connectors/trino.lua:13-50`). BigQuery should omit session and editable-result hooks.

Adding a connector requires:

- Registering `require("orbit.connectors.bigquery")` in the connector table (`lua/orbit/adapters.lua:33-38`).
- Accepting `bigquery` in profile-kind validation and assigning required fields (`lua/orbit/profiles.lua:128-160`).
- Keeping backend option validation in the connector after shared validation of `executable`, `arguments`, `confirm_mutations`, and `schema_patterns` (`lua/orbit/adapters.lua:82-123`). The shared `schema_patterns` special-case currently knows only Trino versus list-based connectors and should be generalized or BigQuery should use a list-shaped option (`lua/orbit/adapters.lua:98-116`).

### Runner and limits

One-shot execution already supplies the correct lifecycle: `prepare` returns argv, `vim.system` captures text stdout/stderr, nonzero status becomes an error, and successful stdout is parsed (`lua/orbit/runner.lua:58-115`). Orbit currently calls `prepare(options, statement)` without request context (`lua/orbit/runner.lua:73-81`), while `result_limit` reaches only the rendering layer after the entire CLI stdout has been captured (`lua/orbit/query.lua:374-391`, `lua/orbit/results.lua:61-69`). This is inadequate for BigQuery because `bq query --max_rows` must be set before output is materialized.

MVP should minimally extend `runner.run`/`run_once` with optional request context containing `max_rows`. Query execution should request `result_limit + 1`, allowing the existing renderer to detect truncation (`lua/orbit/results.lua:318-336`). Schema acquisition needs a separate, higher metadata cap or explicit paging strategy because it calls `runner.run` without UI configuration (`lua/orbit/schema_cache.lua:224-243`). Do not wrap arbitrary user SQL in an outer `SELECT ... LIMIT`: DDL/DML/scripts cannot be wrapped and wrapping changes semantics.

### Schema and completion shape

Schema rows are already `{ catalog, schema, name, type }`; grouping includes `catalog.schema`, cache keys include all three segments, and completion can expose connector-defined progressive namespaces (`lua/orbit/schema.lua:74-97`, `lua/orbit/schema_cache.lua:278-287`, `lua/orbit/completion.lua:132-197`). BigQuery maps naturally as:

- `catalog`: Google Cloud project ID.
- `schema`: BigQuery dataset ID.
- `name`: table or view ID.
- `type`: `view` for logical views and, by product decision, materialized views; `table` for supported table-like types.

However, Orbit's tokenizer recognizes double-quoted identifiers, not BigQuery backtick-quoted identifiers (`lua/orbit/sql/tokenizer.lua:84-88`, `lua/orbit/sql/tokenizer.lua:257-270`, `lua/orbit/sql/scope.lua:143-149`). BigQuery uses backticks for quoted identifiers and project IDs commonly contain hyphens ([GoogleSQL lexical structure](https://cloud.google.com/bigquery/docs/reference/standard-sql/lexical#quoted_identifiers)). Backtick support in tokenization, qualified-name splitting, scope extraction, and tests is an MVP requirement, not polish.

## Transport choices

### `bq` CLI: recommended

Advantages:

- It is Google's first-party BigQuery CLI, included in Google Cloud CLI installations ([installation guide](https://cloud.google.com/sdk/docs/install), [bq reference](https://cloud.google.com/bigquery/docs/reference/bq-cli-reference)).
- It owns Google Cloud CLI authentication, TLS, API calls, job polling, and normal transient handling.
- It supports project, location, GoogleSQL, output format, row cap, maximum bytes billed, cache use, job IDs, and sessions as command flags ([bq reference](https://cloud.google.com/bigquery/docs/reference/bq-cli-reference#bq_query)).
- A one-shot process fits Orbit's current `prepare`/`parse` boundary (`lua/orbit/runner.lua:133-155`).

Disadvantages:

- Installing the Google Cloud CLI is substantially heavier than a database-only binary and requires a supported Python runtime unless the selected package bundles one ([installation guide](https://cloud.google.com/sdk/docs/install)).
- The CLI's row-oriented JSON is convenient but not a schema-bearing wire contract. Exact conversion behavior needs live verification.
- `--max_rows` controls returned rows, not bytes scanned. Cost control is separate.
- Killing the local CLI does not provide Orbit with a documented confirmation that the remote job was cancelled.
- Per-statement process startup and authentication lookup add latency, including for schema prewarming.

### BigQuery REST API: viable follow-up, not MVP

The REST API gives the best control: `jobs.insert`/`jobs.query`, `jobs.getQueryResults`, and `jobs.cancel` expose job identity, completion, pagination, schemas, errors, and cancellation ([jobs.query](https://cloud.google.com/bigquery/docs/reference/rest/v2/jobs/query), [jobs.getQueryResults](https://cloud.google.com/bigquery/docs/reference/rest/v2/jobs/getQueryResults), [jobs.cancel](https://cloud.google.com/bigquery/docs/reference/rest/v2/jobs/cancel)). It also returns positional `TableRow` cells plus a schema, which can preserve duplicate result-column names internally if Orbit's row model is enhanced ([tables resource types](https://cloud.google.com/bigquery/docs/reference/rest/v2/tables#TableRow)).

It is a poor direct fit today: Orbit has no HTTP/OAuth abstraction, request retry policy, job handle richer than a process, or positional result model. Google documents that `jobs.query` can return before completion, subsequent result calls use page tokens, cancellation is asynchronous, and cancelled jobs may still incur costs. Owning those state machines in Lua would be a new subsystem rather than a connector.

### Official client library helper: fallback/follow-up

A Python helper using `google-cloud-bigquery` is preferable to direct Lua REST if full fidelity or job-aware cancellation becomes mandatory. The library provides official authentication, retries, jobs, iterators, and typed values ([BigQuery client libraries](https://cloud.google.com/bigquery/docs/reference/libraries)). Costs are an additional Python package/runtime, subprocess protocol, version support policy, and deployment/debugging surface. Use it only if live `bq` output proves insufficient or if a later product requirement justifies those capabilities.

## Installation and runtime dependencies

MVP runtime requirements:

- Neovim 0.10+, already required (`README.md:22-25`).
- `bq` on `PATH`, or `options.executable` pointing to it/wrapper. Debian/Ubuntu and Red Hat packages named `google-cloud-cli` include `bq`; archive installations also install it ([installation guide](https://cloud.google.com/sdk/docs/install)).
- A Google Cloud CLI-supported Python version when the chosen installation does not bundle Python. Current official packages document Python 3.10 through 3.14, but Orbit docs should link rather than freeze that range ([installation guide](https://cloud.google.com/sdk/docs/install)).
- Network access to Google Cloud APIs and the BigQuery API enabled in the job project.
- IAM permission `bigquery.jobs.create` in the job project plus data/metadata permissions for referenced resources; exact statement permissions vary ([jobs.query](https://cloud.google.com/bigquery/docs/reference/rest/v2/jobs/query)).

No Lua rocks, curl, Java, JDBC, or Neovim plugin should be required. The research machine has no `bq` executable, so no live Google Cloud calls were made.

### Getting `bq` ready for Orbit

The `bq` executable is Google's official BigQuery CLI and is included with the Google Cloud CLI. A user would prepare it as follows:

1. Install the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) and confirm that `bq` is on `PATH` with `bq version`.
2. Authenticate the Google Cloud CLI for interactive use with `gcloud auth login`, or configure one of the workload authentication methods described below. `gcloud auth application-default login` configures ADC for client libraries and is not the primary authentication path for `bq`.
3. Optionally select the default project with `gcloud config set project PROJECT_ID`. Orbit should still pass the profile's explicit `project` to avoid depending on mutable CLI defaults.
4. Ensure the BigQuery API is enabled in the job project and the principal has `bigquery.jobs.create` there, plus the permissions required to read metadata and referenced datasets or tables.
5. Verify the same command shape Orbit would use:

```bash
bq \
  --project_id=PROJECT_ID \
  --location=US \
  --format=json \
  --quiet=true \
  query \
  --use_legacy_sql=false \
  --max_rows=100 \
  'SELECT 1 AS value'
```

This should print a compact JSON array. A nonzero exit should be resolved before configuring Orbit because it normally indicates an authentication, IAM, API, project, location, or SQL error. The profile can use `options.executable` when `bq` is not on `PATH`.

## Connection profile

### Proposed MVP options

```json
{
  "name": "warehouse",
  "kind": "bigquery",
  "options": {
    "project": "billing-and-default-project",
    "location": "US",
    "dataset": "analytics",
    "datasets": ["analytics", "reporting"],
    "maximum_bytes_billed": "10000000000"
  }
}
```

Required:

- `project`: non-empty string. This is the project in which query jobs run and are billed, and the default project used in generated qualified names.
- `location`: non-empty string. Require it even though BigQuery can infer some locations; deterministic schema acquisition uses a region-qualified `INFORMATION_SCHEMA` view and job lookup/cancellation require matching location in many cases. BigQuery treats regions and `US`/`EU` multi-regions as distinct locations ([BigQuery locations](https://cloud.google.com/bigquery/docs/locations)).

Optional:

- `dataset`: non-empty string; passed as the default dataset for unqualified relation names. It does not by itself limit schema browsing.
- `datasets`: non-empty array of unique, non-empty exact dataset IDs; limits schema acquisition. Exact IDs are simpler and safer for MVP than wildcard semantics. Omit to browse every visible dataset in the profile project and location.
- `maximum_bytes_billed`: decimal digit string greater than zero. A string avoids JSON/Lua numeric precision loss and maps to BigQuery's maximum-bytes-billed guard ([cost controls](https://cloud.google.com/bigquery/docs/best-practices-costs), [bq query flags](https://cloud.google.com/bigquery/docs/reference/bq-cli-reference#bq_query)). Omit to use account/project defaults; docs must make that absence explicit.
- `use_query_cache`: boolean, default true; maps to `--use_cache`. Cached query results are normally reused when eligible ([cached results](https://cloud.google.com/bigquery/docs/cached-results), [bq query flags](https://cloud.google.com/bigquery/docs/reference/bq-cli-reference#bq_query)).
- Existing shared `executable`, `arguments`, and `confirm_mutations` (`lua/orbit/adapters.lua:82-97`).

Do not put access tokens, refresh tokens, passwords, or service-account JSON content in the profile. Orbit protects the profile file as mode `0600` (`lua/orbit/profiles.lua:58-79`, `README.md:77-80`), but avoiding duplicate credential storage is safer and lets `bq` use normal credential refresh.

### Validation

Reject unknown options, empty project/location/dataset strings, non-list or empty `datasets`, duplicate/empty dataset IDs, non-boolean `use_query_cache`, and non-digit/zero `maximum_bytes_billed`. Keep `location` syntactic validation conservative: Google can add regions, so require a non-empty string rather than maintaining a stale enum. Do not perform network validation while loading profiles; current profile validation is pure and errors early on shape/type (`lua/orbit/profiles.lua:165-223`). Runtime is where inaccessible projects, wrong locations, disabled APIs, and IAM failures belong.

An optional `credential_file` profile field is not recommended. Existing `arguments` can support advanced `bq` flags or wrappers, while official CLI configurations and environment variables provide cleaner principal isolation.

## Authentication and credential security

Supported ambient modes, all owned by Google Cloud CLI:

- Human login with `gcloud auth login`; credentials are stored in the Google Cloud CLI configuration directory and reused by later commands.
- An attached service account on a Google Cloud resource with a metadata server.
- Workforce Identity Federation for humans.
- Workload Identity Federation for external workloads.
- Service-account impersonation.
- A credential configuration/service-account key file through `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` or the corresponding CLI property.
- A short-lived access token through `CLOUDSDK_AUTH_ACCESS_TOKEN` or an access-token file.

Google documents these modes, their precedence, and recommends federation/impersonation over long-lived service-account keys ([Google Cloud CLI authentication](https://cloud.google.com/sdk/docs/authenticate)). The gcloud CLI itself does **not** use Application Default Credentials; `gcloud auth application-default login` serves client libraries and REST clients, not gcloud/bq ([ADC setup](https://cloud.google.com/docs/authentication/provide-credentials-adc)). Orbit documentation must not tell `bq` users to configure ADC as the primary path.

Security rules:

- Default to the active Google Cloud CLI principal and configuration; do not copy credentials into Orbit.
- Recommend separate named Google Cloud CLI configurations when users need profile-specific principals/projects.
- If a wrapper or `arguments` selects a credential file, store only its path in Orbit and protect the credential file independently.
- Never support raw access tokens in `arguments`: argv is process-visible. Environment-based tokens are still secrets and should be short-lived.
- Warn that `gcloud auth login` stores reusable credentials in the user's home directory; Google cautions that filesystem access can expose them ([Google Cloud CLI authentication](https://cloud.google.com/sdk/docs/authenticate)).
- Do not log argv if it might contain user-supplied secret flags. Orbit currently passes `arguments` literally (`README.md:71`, `README.md:209`).

## Project, dataset, and location semantics

The profile `project` has two roles: job/billing project and default data project. BigQuery jobs are created under a project, and `jobs.insert` explicitly describes that project as the one billed for the job ([BigQuery REST discovery](https://bigquery.googleapis.com/$discovery/rest?version=v2)). SQL may reference tables in other projects if IAM allows it, but MVP schema acquisition and completion cover only the profile project.

The default dataset allows `dataset`-local unqualified table references. Canonical generated SQL should still use a three-part backtick-quoted name, `` `project.dataset.table` ``, so pasted sample statements are independent of CLI defaults ([GoogleSQL lexical structure](https://cloud.google.com/bigquery/docs/reference/standard-sql/lexical#table_names)).

Location is not a namespace segment in SQL object names. It controls where the job runs and which region-scoped metadata is visible. The query execution location must match referenced datasets; a wrong location can surface as `notFound`, and multi-regions are not interchangeable with contained single regions ([BigQuery locations](https://cloud.google.com/bigquery/docs/locations), [BigQuery errors](https://cloud.google.com/bigquery/docs/error-messages#notFound)). A single-location profile therefore cannot safely browse mixed-location datasets. Follow-up multi-location browsing should use separate profiles, not silently fan one statement across regions.

## Statement execution

### Proposed argv

Build argv directly, never through a shell:

```text
bq
  <options.arguments...>
  --quiet=true
  --format=json
  --project_id=<project>
  --location=<location>
  [--dataset_id=<project>:<dataset>]
  query
  --use_legacy_sql=false
  --max_rows=<request limit>
  [--maximum_bytes_billed=<decimal string>]
  [--use_cache=true|false]
  <statement>
```

The global flags precede the `query` command; query-specific flags follow it. `--use_legacy_sql=false` must always be generated. Use compact `json`, not human table output; `prettyjson` is useful for diagnostics but increases captured output. `--quiet=true` suppresses status updates while jobs run. All flags and their scope should be checked against the minimum supported `bq` release chosen during implementation ([bq reference](https://cloud.google.com/bigquery/docs/reference/bq-cli-reference)).

Orbit already passes argv arrays to `vim.system`, so the statement is a literal argument and shell metacharacters are not interpreted (`lua/orbit/runner.lua:73-90`). Generated flags should come after user `arguments` so Orbit's required output/dialect/location settings cannot accidentally be overridden, subject to a live test of duplicate-flag precedence.

Statements remain subject to Orbit's conservative mutation confirmation. `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN`, `USE`, and `VALUES` are currently considered read-only (`lua/orbit/query.lua:90-111`). BigQuery supports multi-statement scripts, but Orbit's whole-buffer target rejects ambiguity and users can run a visual selection (`README.md:250`). No BigQuery-specific mutation parser is needed for MVP.

### Machine-readable output and parsing

`bq --format=json` is the candidate wire format ([bq reference](https://cloud.google.com/bigquery/docs/reference/bq-cli-reference), [BigQuery error diagnostics](https://cloud.google.com/bigquery/docs/error-messages)). Orbit's generic parser accepts a JSON array/object or newline-delimited objects and preserves decoded JSON `null` as Neovim's `vim.NIL` sentinel (`lua/orbit/adapters.lua:146-186`); the grid already displays that sentinel as `NULL` and serializes structured Lua values (`tests/results_spec.lua:10-30`).

Add a BigQuery-specific `parse` even if it delegates most decoding, because it should validate that the top-level value is an array of row objects and provide a BigQuery-specific error. It is the right seam for any conversions established by live testing.

Required fidelity tests before release:

- Top-level SQL `NULL` versus empty string, zero, and false.
- SQL `NULL` versus BigQuery JSON-type `null` if `bq` exposes both identically.
- INT64 minimum/maximum and values above JavaScript's exact integer range.
- NUMERIC and BIGNUMERIC trailing scale/precision.
- FLOAT64 finite values and documented non-finite representations.
- BOOL, BYTES, DATE, DATETIME, TIME, TIMESTAMP, GEOGRAPHY, INTERVAL, JSON, and RANGE display forms.
- STRUCT/RECORD and ARRAY/REPEATED values, including nested/repeated nulls and empty arrays.
- Very long strings, large arrays/structs, Unicode, newlines, and embedded quotes.
- Duplicate and empty result-column aliases.

Do not coerce numeric-looking strings to Lua numbers. BigQuery's REST model marks 64-bit integers as string-formatted values and the JSON ecosystem cannot safely represent every INT64/NUMERIC value as a Lua number ([BigQuery REST discovery](https://bigquery.googleapis.com/$discovery/rest?version=v2), [BigQuery data types](https://cloud.google.com/bigquery/docs/reference/standard-sql/data-types)). Displaying exact numeric text is better than silent precision loss.

Orbit rows are maps keyed by column name, so duplicate aliases cannot be represented without overwrite regardless of transport (`lua/orbit/results.lua:171-174`). That is an existing result-model limitation and should be documented; preserving duplicate columns requires a future positional `{ columns, rows }` result contract.

Large structured cells are otherwise compatible: the grid retains raw values while truncating only display text, and inspection JSON-serializes tables (`README.md:17`, `README.md:375`, `lua/orbit/results.lua:107-136`). The risk is process memory: `vim.system` captures complete stdout and JSON decode builds another in-memory representation (`lua/orbit/runner.lua:84-104`, `lua/orbit/adapters.lua:143-145`). Remote row and byte caps are therefore mandatory.

### Pagination, row limits, and costs

BigQuery APIs paginate with page tokens and also enforce response-size/field-value limits; `jobs.getQueryResults` and `tabledata.list` have different paging behavior ([pagination guide](https://cloud.google.com/bigquery/docs/paging-results), [jobs.getQueryResults](https://cloud.google.com/bigquery/docs/reference/rest/v2/jobs/getQueryResults), [tabledata.list](https://cloud.google.com/bigquery/docs/reference/rest/v2/tabledata/list)). The `bq query` contract exposes `--max_rows` as the number of result rows to return, but the CLI reference does not document its internal API paging behavior. Live testing must verify results that cross an API page boundary.

MVP policy:

- Fetch `result_limit + 1` rows for user statements, then let the existing grid display `result_limit` and mark truncation.
- Do not expose paging UI yet.
- Give metadata acquisition a distinct cap high enough for expected projects and report a clear truncation error rather than silently caching an incomplete schema. A later REST/client-helper path can page all metadata.
- Never confuse row caps with scan caps. `LIMIT`/`--max_rows` can reduce transfer and memory but does not guarantee lower bytes processed.
- Pass `maximum_bytes_billed` when configured. BigQuery rejects a query whose estimated bytes exceed it, which is the useful per-statement cost guard ([cost controls](https://cloud.google.com/bigquery/docs/best-practices-costs)).
- Keep query cache enabled by default; cached results can avoid charges when eligible, but are not a security/cost guarantee ([cached results](https://cloud.google.com/bigquery/docs/cached-results)).
- Document on-demand versus capacity pricing without embedding prices, which change by edition/location ([BigQuery pricing](https://cloud.google.com/bigquery/pricing)).

Schema prewarming runs automatically when a profile is bound and completion is enabled (`lua/orbit/query.lua:215-220`, `lua/orbit/completion.lua:463-469`). Metadata SQL should be narrow and should not inspect table data. Users must still understand that ordinary statement execution can incur cost.

## Cancellation and sessions

BigQuery is job-based, not a retained interactive CLI connection for this MVP. Omit `session_command`; Orbit will use its one-shot process path (`lua/orbit/runner.lua:133-155`). That path does not serialize separate query buffers by profile, and BigQuery does not require such serialization for independent jobs. `:OrbitDisconnect` will have no remote session to close, and status remains `bound`, matching other one-shot behavior (`lua/orbit/runner.lua:176-187`, `lua/orbit/query.lua:558-568`).

Orbit currently cancels one-shot work by sending SIGTERM to the CLI process (`lua/orbit/runner.lua:158-173`). That stops local waiting but is not sufficient evidence that the BigQuery job stopped. The official cancellation API requires project, job ID, and often location; it returns immediately, must be polled, and cancelled jobs may still incur costs ([jobs.cancel](https://cloud.google.com/bigquery/docs/reference/rest/v2/jobs/cancel)). MVP must label cancellation best-effort and warn that remote work/cost may continue.

Follow-up job-aware cancellation should generate/retain a unique `--job_id`, enrich the runner handle with `{ process, project, location, job_id }`, and on cancel invoke `bq cancel` or the REST/client helper before/alongside terminating local wait. It must handle races where job creation has not completed, poll terminal state, and avoid reusing job IDs.

BigQuery sessions preserve temporary tables, variables, and session state across queries, but they are server-side resources with session IDs and inactivity/lifetime semantics ([sessions overview](https://cloud.google.com/bigquery/docs/sessions-intro)). They do not map to Orbit's retained stdin/stdout CLI protocol (`lua/orbit/session.lua:4-27`). Session support should be a separate design: retain a BigQuery session ID per profile and attach it to one-shot jobs, rather than pretending `bq` is an interactive process. Not MVP.

## Schema acquisition

### Projects and datasets

MVP does not discover projects; the profile's explicit project is the only catalog. Official project/dataset list APIs are paginated and filtered by caller visibility ([datasets.list](https://cloud.google.com/bigquery/docs/reference/rest/v2/datasets/list)). Project discovery would also blur job/billing project versus data project.

Datasets are represented implicitly by table rows. The project-location `INFORMATION_SCHEMA.SCHEMATA` view can list datasets in a region, but Orbit's current cache/tree has no empty namespace rows, so empty datasets would not appear without a schema model extension ([SCHEMATA view](https://cloud.google.com/bigquery/docs/information-schema-datasets-schemata), `lua/orbit/schema.lua:74-97`). MVP may omit empty datasets. Follow-up can add explicit namespace acquisition or use `bq ls --datasets`/`datasets.list` with pagination.

### Tables and views

For `{ type = "tables" }`, query the region-qualified `INFORMATION_SCHEMA.TABLES` view for the profile project/location. Select:

- `table_catalog AS catalog`
- `table_schema AS schema`
- `table_name AS name`
- a normalized `type` derived from `table_type`

Filter `table_schema` through `datasets` if configured and order by project/dataset/name. The view exposes one row per table or view and supports region qualification; the query execution location must match the view's region ([TABLES view](https://cloud.google.com/bigquery/docs/information-schema-tables), [INFORMATION_SCHEMA introduction](https://cloud.google.com/bigquery/docs/information-schema-intro)). Construct the qualifier using the exact syntax from the selected view documentation and BigQuery backtick escaping; do not interpolate unquoted profile values.

MVP normalization decision:

- `VIEW` and `MATERIALIZED VIEW` -> `view` so they appear in Orbit's views group.
- `BASE TABLE`, `CLONE`, `SNAPSHOT`, and `EXTERNAL` -> `table`.

Orbit only has table and view buckets; unknown types otherwise fall into tables (`lua/orbit/schema.lua:91-97`). Preserve the original BigQuery `table_type` in another row field if useful for actions, but do not require core changes.

### Columns

For `{ type = "columns", catalog, schema, name }`, query that dataset's `INFORMATION_SCHEMA.COLUMNS`, selecting `column_name AS name` and `data_type AS type`, filtered by `table_name`, ordered by `ordinal_position` ([COLUMNS view](https://cloud.google.com/bigquery/docs/information-schema-columns)). Include mode/nullability in a follow-up if the schema-browser row contract is expanded. `data_type` is already the detail text completion displays (`lua/orbit/completion.lua:211-217`).

`COLUMNS` describes top-level columns. For nested STRUCT field completion or a fully expanded schema browser, use `COLUMN_FIELD_PATHS` later; flattening nested paths into ordinary columns during MVP would imply invalid unnesting semantics ([INFORMATION_SCHEMA introduction](https://cloud.google.com/bigquery/docs/information-schema-intro)).

### View definitions and other metadata

Logical view definitions are available through dataset-level `INFORMATION_SCHEMA.VIEWS.view_definition` and should be an object action for logical views ([VIEWS view](https://cloud.google.com/bigquery/docs/information-schema-views)). Materialized-view metadata uses a separate view and should be follow-up.

MVP table metadata categories:

- All supported objects: `columns`.
- Definitions should remain an object action, matching PostgreSQL/Vertica rather than a cache category (`lua/orbit/connectors/postgres.lua:465-497`, `README.md:327-336`).

MVP object actions:

- Sample: ``SELECT * FROM `project.dataset.object` LIMIT <result_limit>;`` in a bound query buffer.
- Columns: execute the same column metadata statement.
- Definition: logical views only.

Follow-ups can expose primary/foreign keys from `TABLE_CONSTRAINTS`, `KEY_COLUMN_USAGE`, and `CONSTRAINT_COLUMN_USAGE`; BigQuery declares these constraints as not enforced, so they must not establish editable-result safety ([primary and foreign keys](https://cloud.google.com/bigquery/docs/primary-foreign-keys)). Table options, partitions, search/vector indexes, materialized-view state, routines, and models need new table metadata category IDs because the cache currently recognizes only columns, keys, indexes, and projections (`lua/orbit/schema_cache.lua:43-50`, `lua/orbit/schema_cache.lua:389-397`).

## Qualified naming and completion

Canonical qualified names should be a single backtick-quoted three-part path, escaping embedded backticks according to GoogleSQL rules: `` `project.dataset.table` `` ([GoogleSQL lexical structure](https://cloud.google.com/bigquery/docs/reference/standard-sql/lexical#quoted_identifiers)). Do not use the double-quote helper copied from Trino/PostgreSQL.

Recommended completion behavior:

- With no qualifier, offer configured/default project as a `Project`/`Catalog` namespace and direct relations from the default dataset if one is configured.
- After `project.`, offer datasets as `Schema` namespaces.
- After `project.dataset.`, offer tables/views.
- Allow `dataset.table` resolution in the profile project and bare `table` resolution in the default dataset.
- Insert canonical backtick-quoted names for relation candidates; column names should also be backtick-quoted when required.

The existing `completion_namespaces`, `completion_path`, and `completion_word` hooks support this progression (`lua/orbit/connectors/trino.lua:195-281`, `lua/orbit/completion.lua:132-197`). The blocker is lexical support for backticks and correct replacement ranges. Tests must cover hyphenated project IDs, dots/backticks in quoted identifiers where legal, typed unquoted dataset prefixes, aliases, and three-part paths.

## Editable results

Keep BigQuery results read-only. Orbit enables editing only when a connector implements both target selection and mutation SQL, after loading primary keys (`lua/orbit/query.lua:410-437`, `lua/orbit/results.lua:710-724`). BigQuery primary/foreign keys are not enforced, so they cannot prove that an UPDATE/DELETE identifies one row ([primary and foreign keys](https://cloud.google.com/bigquery/docs/primary-foreign-keys)). Additional blockers are nested/repeated values, exact typed literal generation, DML cost, streaming-buffer restrictions, and BigQuery transaction/script behavior.

A follow-up would need an explicit opt-in editable key, typed schema-aware literals/parameters, optimistic conflict policy, partition safeguards, bytes-billed policy, and live DML tests. Merely reusing `mutation_sql.build` would be unsafe.

## Error behavior

Current one-shot handling is acceptable for MVP: nonzero `bq` exit reports trimmed stderr; malformed successful stdout reports a parser error; query UI shows a notification and diagnostics window (`lua/orbit/runner.lua:90-105`, `lua/orbit/query.lua:359-372`). BigQuery distinguishes HTTP errors, job `errorResult`, and arrays of errors; common reasons include `accessDenied`, `invalidQuery`, `notFound`, `quotaExceeded`, `rateLimitExceeded`, `responseTooLarge`, and `stopped` ([BigQuery errors](https://cloud.google.com/bigquery/docs/error-messages)).

Requirements:

- Preserve complete stderr, including project/location/job references; do not reduce it to a generic connector message.
- Treat nonzero status as failure even if stdout contains JSON.
- Treat blank stdout with zero status as zero rows, supporting DDL/DML that has no row result (`lua/orbit/adapters.lua:146-150`).
- Distinguish malformed JSON from valid non-row JSON in the connector parser.
- Do not automatically retry user statements in Orbit. Retrying unknown-outcome DML/DDL can duplicate effects; Google specifically notes ambiguity around failed `jobs.insert` calls and recommends job-ID-aware handling ([BigQuery errors](https://cloud.google.com/bigquery/docs/error-messages#backendError)). Let `bq` own its safe transport retries.
- A wrong location should remain visible as a BigQuery `notFound`-style error, not be silently retried elsewhere.
- On local cancellation, suppress the eventual process error as Orbit already does (`lua/orbit/query.lua:351-365`) but warn in docs that remote cancellation is not confirmed.

## Tests and live verification

### Deterministic tests

Follow the existing single-process Lua spec style and module-load list (`tests/run.lua:8-54`). Add tests for:

- Adapter/profile registration, required project/location, allowed option types, unknown-option rejection, and owner-only profile behavior, extending patterns at `tests/profile_spec.lua:22-93` and `tests/profile_spec.lua:444-478`.
- Exact argv ordering and literal statement argument, analogous to connector command tests at `tests/profile_spec.lua:170-233`.
- JSON parser fixtures covering the fidelity matrix above, including `vim.NIL`.
- BigQuery backtick tokenization, qualified splitting, statement scope, aliases, and completion replacement.
- Project/dataset completion progression, default-dataset shortening, and canonical qualified names, extending Trino hierarchy tests at `tests/completion_spec.lua:279-387`.
- Table/view and column metadata SQL with escaping, location qualifier, dataset filtering, and type normalization.
- Metadata category/action sets and generated sample/view-definition statements, extending `tests/profile_spec.lua:313-379`.
- Schema cache catalog/dataset identity and unsupported metadata behavior, extending `tests/schema_spec.lua:35-108`.
- Result caps passed separately for user statements and metadata acquisition.
- One-shot cancellation behavior with a fake executable; do not claim remote cancellation.

### Live release gate

Use a dedicated, low-cost test project and dataset in at least `US` and one single region. Configure a strict `maximum_bytes_billed`, create small fixtures, and verify:

- `bq` minimum supported version and exact argv flags.
- Ambient user auth and one non-key workload mode; no credentials appear in argv/logs.
- Scalar/null/numeric/nested fidelity matrix and duplicate alias behavior.
- Output above one API page, `--max_rows`, `result_limit + 1`, and an oversized single value.
- DDL, DML, SELECT, script/error, dry-run/bytes cap, cache on/off, IAM denial, missing dataset, and location mismatch.
- Region `TABLES`, dataset `COLUMNS`, logical view definition, materialized/external/snapshot/clone classification, and more metadata objects than the selected cap.
- SIGTERM behavior: inspect the job in BigQuery after Orbit cancellation and document whether the tested `bq` release forwards cancellation. Do not elevate observed behavior into a guarantee without official documentation.
- Cost/job history after all schema and sample operations.

No live verification was possible during this research because `bq` is not installed in the workspace environment. This is the largest unresolved implementation risk.

## Documentation work

MVP docs should update:

- README requirements table with `bigquery` and Google Cloud CLI/`bq` installation link (`README.md:22-33`).
- Supported connectors/options/schema support table (`README.md:62-75`).
- A BigQuery profile example and the distinction among job project, default dataset, browsed datasets, and location (`README.md:77-181`).
- Authentication guidance: Google Cloud CLI auth, not ADC; federation/impersonation preferred; no credential material in Orbit (`README.md:201-212`).
- Execution/results: one-shot jobs, remote row cap, `maximum_bytes_billed`, cache behavior, cancellation limitation, and no retained connection (`README.md:369-375`).
- Schema browser/actions and completion sections with project/dataset hierarchy and backtick naming (`README.md:327-365`).
- Editable-results section stating BigQuery is read-only (`README.md:308-324`).
- Changelog entry and domain context connector list (`docs/agents/CONTEXT.md:1-4`).

Avoid fixed Google Cloud CLI Python versions or prices in README; link official pages.

## Rough implementation slices

### MVP

1. **Profile and connector shell:** register `bigquery`, validate options, build deterministic one-shot `bq query` argv, and parse JSON. Unit-test command and fidelity fixtures.
2. **Execution caps:** add optional runner request context; send `result_limit + 1` for user statements and a separately defined metadata cap. Add `maximum_bytes_billed` and query-cache options.
3. **BigQuery identifiers:** extend tokenizer/scope/splitting for backticks and add regression tests for existing double-quoted dialects.
4. **Schema acquisition:** region `TABLES`, dataset `COLUMNS`, project/dataset cache identity, dataset filtering, metadata caps, and table/view normalization.
5. **Naming/completion/actions:** project/dataset namespaces, canonical qualified names, sample, columns, and logical-view definition; explicitly read-only results.
6. **Live gate:** run the full auth/type/null/nested/paging/location/cost/cancellation matrix and adjust parser/flags. Do not ship before this slice.
7. **Docs:** README, context connector list, and changelog.

### Follow-ups

1. Job-aware handles and confirmed server cancellation using explicit job IDs.
2. Full metadata pagination and explicit empty-dataset/project namespaces.
3. Multiple configured data projects, while retaining one explicit job/billing project; separate profiles for different locations.
4. Python official-client helper if `bq` JSON fidelity is inadequate, or if typed schema/job APIs become required.
5. BigQuery session IDs and temporary-object lifecycle as a separate server-session design.
6. Nested field paths, keys, partitions/options, materialized views, routines/models, search/vector indexes, and richer object actions.
7. Positional result model for duplicate aliases and schema-carrying typed values.
8. Explicit, heavily guarded editable-result design, if ever justified.

## Risks and open decisions

Highest risk:

- `bq --format=json` query-value fidelity is under-documented and unverified locally. This determines whether the recommended transport is acceptable.

Decisions required before implementation:

- Minimum supported Google Cloud CLI/`bq` version.
- Whether `maximum_bytes_billed` is optional or required by Orbit policy. Recommendation: optional in schema, strongly recommended in docs; organizations may already enforce custom quotas/reservations.
- Metadata cap value and behavior. Recommendation: fail visibly on possible truncation, never cache an incomplete tree as complete.
- Materialized-view classification. Recommendation: display under views but offer only actions proven to work.
- Completion insertion style. Recommendation: canonical backtick-qualified relation names for correctness, with default-dataset bare names only as additional convenience candidates if duplicates are avoided.
- Whether MVP cancellation semantics are acceptable. If confirmed server cancellation is a release requirement, job-aware runner work moves into MVP.
- Whether profile-specific Google Cloud CLI configurations deserve a first-class non-secret option. Recommendation: defer; wrappers/`arguments` and ambient configuration are sufficient initially.

Other risks:

- Schema prewarming can create many one-shot jobs and latency for large projects.
- Region-scoped metadata omits datasets in other locations by design, which users may mistake for IAM filtering.
- JSON row maps lose duplicate column names and may conflate SQL and JSON nulls.
- Capturing/decoding complete stdout can consume significant memory even with a row cap if cells are large.
- BigQuery product object types exceed Orbit's table/view model.
- User-provided `arguments` can alter auth/behavior and may contain secrets; generated correctness flags need precedence testing.
- BigQuery cancellation can still incur cost even when the server accepts it ([jobs.cancel](https://cloud.google.com/bigquery/docs/reference/rest/v2/jobs/cancel)).

## Bottom line

The connector is feasible without changing Orbit's overall architecture. A useful MVP is approximately one new connector plus small registration/profile changes, a request-limit extension to the runner, backtick support in SQL tokenization/completion, schema/action tests, and documentation. `bq` is the pragmatic transport because it preserves Orbit's CLI boundary and delegates Google-specific auth/job machinery to Google. The non-negotiable gates are live JSON fidelity testing, explicit project/location semantics, remote fetch/cost controls, and honest best-effort cancellation semantics.
