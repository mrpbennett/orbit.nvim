# Retained sqlcmd Transport

Type: task
Status: resolved
Blocked by:

Implement strict retained framing and best-effort result parsing around user-installed Microsoft Go `sqlcmd`.

## Answer

The MSSQL Connector constructs a mandatory-encryption Go `sqlcmd` session, sanitizes inherited `SQLCMD*` variables, passes only `SQLCMDPASSWORD`, frames each Statement between marker batches, and rejects detectable malformed output while documenting undetectable fidelity loss.
