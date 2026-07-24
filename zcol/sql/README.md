# zcol/sql

Small typed SQL subset parser and binder. It supports `SELECT` projections and
`COUNT`/`SUM`/`MIN`/`MAX`/`AVG`, numeric and string predicates joined by `AND`,
and one-column `GROUP BY`. Invalid user SQL returns typed parse errors.
