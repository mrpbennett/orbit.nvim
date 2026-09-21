# User-installed sqlcmd for SQL Server

Status: superseded by ADR-0004

Orbit will implement SQL Server connectivity through Microsoft's user-installed `sqlcmd` rather than an Orbit-owned helper. This avoids making Orbit build, sign, publish, and maintain native binaries, while deliberately accepting and documenting that `sqlcmd`'s human-oriented output cannot preserve every arbitrary result value losslessly.
