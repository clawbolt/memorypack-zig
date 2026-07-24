# zcol/sql

Small typed SQL subset parser and binder. It supports `SELECT` projections and
`COUNT`/`SUM`/`MIN`/`MAX`/`AVG`, numeric and string predicates joined by `AND`,
and composite `GROUP BY`, `IS NULL`/`IS NOT NULL`, composite equi-joins with
INNER/LEFT/RIGHT/FULL keywords, `ORDER BY`, and `LIMIT`, plus window
partition/order expressions including DESC. Invalid user SQL returns typed
parse errors.
