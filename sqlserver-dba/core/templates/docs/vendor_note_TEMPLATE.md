# <Product> `<schema>.<object>`: <statement> <cost in a phrase>

**For:** <vendor> support (<module>) \
**From:** <company>, DBA team (<date>) \
**Product:** <product>, `<schema>.<object>` as installed by our <date> upgrade. Revision header last entry: "<…>". SQL Server <version> (<build>), compatibility level <n>, <CE>

## Summary

The <object> runs <how often, from where>. Its <statement> costs:
- **<CPU> and <reads> per run**, at DOP <n>, to return <n> rows;
- **≈ <n> CPU-minutes a day**: <n>% of the object and <n>% of our database.

## Cause

1. **<Operator> on `<table>`.** <Why: the predicate, the missing index, the estimate vs actual.>
2. **<Second factor>.** <…>
3. **<Data factor, if any: a table that should be purged>.** <Ask the vendor to confirm.>

## Evidence

- Query Store, <dates>: <plans, cost per run per plan>.
- Read-only test on production, the statement run as a SELECT, back to back:

| | CPU | Elapsed | Logical reads | Rows |
|---|---|---|---|---|
| As shipped | | | | |
| With the change below | | | | identical |

- <Variant that does not help, and why>

## Reproduce and verify on your side

Read-only, safe on a test system or production: `<repro_<object>.sql>` (attached). It prints the environment and data shape (compare with ours), runs the statement as shipped and with our change <n> times each, and prints CPU, elapsed, logical and physical reads, file I/O and waits per run, plus a row count and checksum for both.

1. Run sections 0–2; our values: compatibility level <n>, <CE>, MAXDOP <n>, `<table>` <n> rows, `<object>` SHA-256 `<0x…>`.
2. Set `@p1…` to <values>, run the script.
3. You should see: as shipped <operator> on `<table>`, about <n> reads and <n> ms CPU; with the change <operator>, about <n> reads; same rows.
4. The plans: `<object>_as_shipped.sqlplan`, `<object>_with_change.sqlplan` (attached).

## What we have done locally (marked `-- <MARKER>`)

```sql
<the exact changed lines>
```

Nothing else in the object changed. Please tell us whether a future release will replace this object, so we can re-check the change after upgrades.

## Suggested permanent fix

- <rewrite: drive the query from …, or materialize … first>
- <or ship an index: …>
