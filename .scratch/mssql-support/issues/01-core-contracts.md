# Core Result And Session Contracts

Type: task
Status: resolved
Blocked by:

Carry ordered columns through Runner and Query, and allow a Connector to replace the inherited child environment without regressing existing retained sessions.

## Answer

Runner carries optional ordered columns for empty and ordered tabular results. Session supports Connector-owned complete child environments and generation-isolates every callback after process failure.
