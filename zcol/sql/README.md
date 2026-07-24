# zcol/sql

Small typed SQL subset parser and binder. It supports `SELECT` projections and
`COUNT`/`SUM`/`MIN`/`MAX`/`AVG`, numeric and string predicates joined by `AND`,
and composite `GROUP BY`, `IS NULL`/`IS NOT NULL`, single-key `JOIN ... ON`,
`ORDER BY`, and `LIMIT`. Invalid user SQL returns typed parse errors.
