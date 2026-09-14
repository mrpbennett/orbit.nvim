# MSSQL Connector

Type: task
Status: resolved
Blocked by: 01, 02

Register and validate MSSQL profiles, integrate retained Go `sqlcmd`, add naming/schema actions, and support T-SQL lexical and mutation behavior.

## Answer

The registered MSSQL Connector validates the agreed profile, frames retained `sqlcmd` work, parses strict best-effort ordered results, browses tables/views/columns, completes bracket-qualified names, rejects `GO` and sqlcmd control commands, and conservatively confirms T-SQL mutations.
