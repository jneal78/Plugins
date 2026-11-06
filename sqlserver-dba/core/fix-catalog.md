# Fix patterns: symptom → evidence → fix → proof

Deadlock shapes (lock order, conversions, same-key concurrency, key lookups, range locks, escalation, schema locks, client-held transactions) have their own catalog in `skills/sql-deadlock-analysis/references/deadlock-patterns.md`; it points back here for the code fixes (§5, §6, §13–19).

Each pattern below came from a real production fix. The measured results are included so you can calibrate what "good" looks like. Always keep the SELECT list, joins and predicates unchanged unless the fix *is* a logic correction, and prove row parity.

## 1. Row goal turns an existence check into a scan

- **Symptom:** `IF EXISTS (...)`, `TOP 1`, `IN (subquery)` statement costs seconds; plan shows a scan with a row goal (`EstimateRowsWithoutRowGoal` attribute).
- **Fix:** `WITH (FORCESEEK)` on the table inside the procedure (or `OPTION (USE HINT('DISABLE_OPTIMIZER_ROWGOAL'))`).
- **Result seen:** ~3 s → 0.15 ms per call; 874 → 5 CPU-min per 15 h.

## 2. Plan flips at the nightly recompile

- **Symptom:** the same statement has 2+ plans in Query Store, alternating good/bad after a stats update; per-call cost differs 10–50×.
- **Evidence:** per-plan table (sql-query-tuning script 05) with first/last seen around the maintenance window; the good plan's index.
- **Fix:** an in-procedure `WITH (FORCESEEK)` / `INDEX(...)` on the index the good plan uses, or `OPTION (OPTIMIZE FOR (@p UNKNOWN))` when it's parameter sniffing. Avoid Query Store forcing if that's site policy.
- **Result seen:** 245 ms → 5 ms per call on bad-plan days.

## 3. Eager index spool rebuilt every run, plus a hash per outer row

- **Symptom:** a scheduled procedure returns tens of rows but reads tens of millions of pages at DOP 8; most reads are worktable.
- **Evidence:** plan shows `Index Spool` (eager) over a big table and a Hash Match under an Apply whose build side is all "active" rows, executed once per outer row.
- **Fix:** `WITH (FORCESEEK)` on the spooled table (it uses an existing index instead) + `OPTION (LOOP JOIN)` so the per-row part becomes a chain of seeks. Check each variant: `NO_PERFORMANCE_SPOOL` alone didn't remove an *eager* spool; filtering out finished rows alone didn't help.
- **Result seen:** 49.2 s → 0.11–0.19 s CPU per run, ~39M → ~71K reads, identical rows; ≈ 100 CPU-min/day.

## 4. Outer-column expression in a seek predicate

- **Symptom:** a function called per row scans a big table each call; predicate like `U.Key = COALESCE(L.col, S.col, '')` on the inner side of an outer join / apply.
- **Fix:** compute the expression once into a variable (`SELECT @k = COALESCE(...)`), then `WHERE U.Key = @k`; skip the lookup when `@k = ''`.
- **Result seen:** per-row function 14 ms → 3 ms; a mobile app's main call 2.07 s → 0.71 s CPU; server CPU 52–59% → 29–41%.

## 5. OR across two join keys

- **Symptom:** `JOIN T ON T.a = X.a OR T.b = X.b` → full scan (3M rows) per call.
- **Fix:** `CROSS APPLY (SELECT ... WHERE T.a = X.a UNION ALL SELECT ... WHERE T.b = X.b AND T.a <> X.a)` or two `EXISTS`. Mind duplicates: use `UNION` or a guard when one row could match both.
- **Result seen:** 640 ms → 3.7 ms per call.

## 6. Implicit conversion from the caller

- **Symptom:** `CONVERT_IMPLICIT(nvarchar, T.varchar_col)` in the plan; scans; usually an ORM, JDBC or .NET app sending strings as `nvarchar`.
- **Fix:** at the caller — typed parameters (`SqlDbType.VarChar` with length), or the driver setting (`sendStringParametersAsUnicode=false` for JDBC). Not in the database.
- **Proof:** sql-query-tuning script 10 lists the statements, the column and the CPU; after the caller fix the convert disappears from new plans.

## 7. Data-type precedence error in an application statement

- **Symptom:** thousands of errors/day (Query Store execution_type 4) on one `UPDATE`; error 8114 "Error converting data type varchar to bigint".
- **Cause:** `col = COALESCE(@p_bigint, col_varchar)` — `COALESCE` takes the highest-precedence type (bigint), so any non-numeric existing value fails even when `@p` is NULL.
- **Fix:** vendor/app: parameter typed to the column (`varchar(12)`), or `CASE WHEN @p IS NULL THEN col ELSE CONVERT(varchar(12), @p) END`. Write it up with the data impact (rows that never get updated), not just CPU.

## 8. Polling feeds that rescan the whole window every run

- **Symptom:** an integration procedure runs every few minutes and rescans days of history to find what changed; 20–150 s per run, timeouts.
- **Fix (in-house code):** incremental watermark (last processed key/time), a claims table so concurrent runs don't double-send, `sp_getapplock` around the batch, and indexes on the watermark column.
- **Result seen:** 21–56 s → under 2 s per run; 36–145 s → 0.15–0.28 s.

## 9. Repeated work that returns nothing

- **Symptom:** a call that is usually empty still does all the joins; or a bug (an empty stop list) makes it scan everything.
- **Fix:** short-circuit when the driving set is empty; cache an empty result for a short time when the caller polls.
- **Result seen:** ~1.6 s → ~3 ms; ~160 → ~17 ms.

## 10. Tables that only grow

- **Symptom:** cost rises a few percent every day; a tracking/queue/log/price table keeps rows forever, or the cleanup trigger leaks.
- **Fix:** a purge (owner decides retention), plus an index on the purge/lookup key. Recommend; don't run.

## 11. Literal ad hoc SQL and plan-cache bloat

- **Symptom:** one `query_hash` with hundreds of query_ids/plans; high compiles/s; GBs of single-use plans.
- **Fix:** parameterize at the source; meanwhile a narrow, prefixed index for the scan, and `optimize for ad hoc workloads = 1` (DBA's call).

## 12. Big screens and reports

- **Symptom:** a screen refresh or report takes 60–100 s at DOP 8 in business hours.
- **Fix:** materialize the small driving set first (the rows on screen) and join out from it; or move scorecard reports to an overnight schedule.
- **Result seen:** ~90 s → ~13 s per refresh.

## 13. Parallelism waits are the top category

- **Fix order:** the big scanners above first (they are the parallel queries). Then, as the DBA's call, cost threshold for parallelism ~50–100 and/or MAXDOP 4–8 per NUMA guidance. Watch worker threads.

## 14. Converting the column to match a string key

- **Symptom:** a lookup function or join reads a whole table per call: `CONVERT(varchar(20), T.int_key) = @string_key`. The function is called per row by a job, so the server spends minutes a day on it, and its scans deadlock with the application's updates.
- **Fix:** add a seekable test and keep the original one, so the result can't change: `T.int_key = TRY_CONVERT(int, @string_key) AND CONVERT(varchar(20), T.int_key) = @string_key`. `TRY_CONVERT` returns NULL for non-numeric keys, so those rows still match nothing.
- **Result seen:** ≈ 3.4 s → ≈ 45 ms per call across two such functions, ≈ 96 CPU-min/day; their deadlocks with the application stopped.

## 15. A scheduled UPDATE that rewrites every row to the same value

- **Symptom:** a job runs hourly and its write step touches the whole table (500K+ rows, 4–40 s, ~60 MB of log per run, about 1 GB of log a day shipped to every replica) while almost nothing changes. For those seconds it holds exclusive locks, so interactive saves wait and deadlock with it.
- **Evidence:** Query Store rows per execution ≈ table size every run; a read-only count of rows whose value would actually change (often 0); a changed-rows filter that someone commented out.
- **Fix:** write only changed rows with a NULL-safe test (`ISNULL(target.col, '') <> source.col`), and join on the row key, not a grouping key (a join on the order number matched each row to every row of its order: 765K pairs for 528K rows). Prove with a read-only parity check: same rows reached, no conflicting values, collations compatible.
- **Watch for:** anything downstream that relied on every row being "touched" (triggers, change tracking, CDC, rowversion, replication). Check before calling it safe.

## 16. A heap used as a queue

- **Symptom:** an outbound message or work queue has no clustered index. Producers append, a consumer removes by key; every removal scans the heap under RID locks, and producer and consumer deadlock.
- **Fix:** a clustered index on the key the consumer uses (site-prefixed name, online where the edition allows, with rollback).
- **Result seen:** 114 → 2 pages per lookup, seeks instead of scans, no further deadlocks on the queue.

## 17. A placeholder value that holds millions of rows

- **Symptom:** a cleanup statement in a trigger usually takes milliseconds, but for some rows takes 2–5 s and millions of reads under update locks. The slow cases share a catch-all value ("unknown", 0, blank) that millions of rows carry; estimates assume 1 row, and the plan starts from the wrong side.
- **Fix:** `OPTION (FORCE ORDER, LOOP JOIN)` so the plan always starts from the small driving set (the rows the trigger handles), plus a guard that skips the statement when its own `WHERE` can't match.
- **Result seen:** 9.4M reads → 33 for the worst case, 2.2–4.5 s → ≈ 0.1 ms; deadlocks between users of that screen stopped.

## 18. Serializable client + a scan of an empty table

- **Symptom:** deadlocks on a table that has no rows. A client opens its transactions at `SERIALIZABLE`; a trigger or procedure checks an empty child table; the scan takes a key-range lock on the end of the index, which every concurrent writer then needs.
- **Fix:** at the source: the client uses `READ COMMITTED` (or snapshot); or the vendor guards the check (`IF EXISTS` with a seekable predicate, or skip when the table is empty). This is usually vendor code: write it up rather than patch it.

## 19. Monitoring queries that scan a hot table

- **Symptom:** a monitoring check (a count of stuck messages, say) runs every few minutes with a leading-wildcard `LIKE` and a function on a date column. It scans the hot table under shared locks and is the deadlock victim several times a day, adding noise to the deadlock count.
- **Fix:** read uncommitted for the count (a monitor can tolerate it), a seekable date test (`dt < DATEADD(MINUTE, -10, GETDATE())` instead of `DATEADD(MINUTE, 10, dt) < GETDATE()`), and a lower date bound. Or retire the check if nobody acts on it.
- **Result seen:** 16K → 2.3K reads per run, ≈ 578 → 16 ms CPU, no shared locks.

## Index as the last resort

When code can't reach a seek: a narrow index named with a site prefix (e.g. `MyCo_IX_table_cols`) so upgrades and vendors can see it's local, created `ONLINE = ON` where the edition allows, with its own rollback and an entry on the upgrade checklist. Check sql-query-tuning script 12 first: extending an existing index (adding an `INCLUDE`) often beats adding one.

## Proving the output is unchanged

- Run patched / original / patched as read-only SELECTs (statement body only, its `INTO`/target removed, built by the rules in `core/safety.md`) with `SET STATISTICS IO, TIME ON`. Compare them as multisets, not sets: `EXCEPT` ignores duplicates, so a rewrite that returns a row twice (an OR split into `UNION ALL`, say) still shows 0 and 0. Compare the row counts too, and compare `GROUP BY` all columns with `COUNT(*)` both ways, or the counts plus a checksum (`CHECKSUM_AGG(BINARY_CHECKSUM(*))`).
- Run the patched version first and last: a row that becomes "due" between runs is timing, not a difference.
- For statements that write, the parity script writes only to the session's own `#temp` copy of the target and is DBA-run.
- Look for ties in `ROW_NUMBER() ... ORDER BY` that the vendor left non-deterministic: a hint can legitimately change which tied row wins. Say so if you find one.
