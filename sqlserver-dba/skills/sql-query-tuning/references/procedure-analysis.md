# Profiling a stored procedure or function

Goal: one sentence of root cause — *"statement N spends X of Y CPU because operator O reads R rows of table T per execution, since predicate P can't seek index I"* — backed by numbers, and a fix that removes that operator.

## 1. Fingerprint the object (script 11)

- `modify_date`, `create_date`, SHA-256 of `OBJECT_DEFINITION`, `uses_ansi_nulls`, `uses_quoted_identifier`, signature, plan guides, permissions.
- Does the text contain a local-change marker (e.g. `-- MyCo 2026-10-28`)? If a previous local fix is missing after an upgrade, that's often the whole story.
- Has it changed recently? A `modify_date` that matches the start of a regression is strong evidence. Compare against the upgrade window.
- Read the definition itself (`OBJECT_DEFINITION` or `sys.sql_modules.definition`) for the statements that matter. Note any version/revision header the vendor keeps.

## 2. Cost by statement (script 05)

- Daily trend over 1–2 weeks: is it growing (data growth, a tracking table never purged), stepping (a deploy, a plan flip), or flat-but-big?
- Per statement: share of the object's CPU, per-execution CPU / reads / duration / rows / DOP, number of plans. Usually one statement is 90%+.
- Per plan: first/last seen and per-execution cost. Two plans alternating at 3× different cost = plan flip; look at what happens at the recompile time (nightly stats job, index maintenance).
- Waits by category for the object: CPU-bound vs parallelism vs lock vs I/O changes the fix.

## 3. Read the plan (script 06)

Look for these, in roughly this order of payoff:

| Operator / signal | Usually means |
|---|---|
| Clustered Index Scan / Table Scan of a big table on the inner side of a Nested Loop | No seekable predicate: function on the column, `COALESCE`/expression with an outer column, implicit conversion, `OR` across tables |
| Eager **Index Spool** over a big table | The optimizer is building the index you don't have, *every execution*. Huge worktable reads |
| Hash Match whose build side is millions of rows, under an Apply/loop | The subquery isn't correlated well enough; it's hashing the world per outer row |
| Key Lookup with millions of executions | Missing covering columns; fine if a few, bad if per row |
| `PlanAffectingConvert` / `CONVERT_IMPLICIT(...column...)` | Parameter or join type mismatch (nvarchar vs varchar, int vs varchar). Fix the type at the source |
| Row goal (`TOP`, `EXISTS`, `IN`, `FAST n`) with a scan | Optimizer bet on finding a match early and lost |
| Estimated rows 1 vs actual many (from `STATISTICS PROFILE` / actual plan) | Table variable, multi-statement TVF, skewed density, ascending key |
| `NoJoinPredicate` warning | Missing join condition (often a real bug) |
| Sort / hash spills (`SpillToTempDb`) | Memory grant too small for the real row count |
| Scalar UDF or multi-statement TVF called per row | The function's cost × rows; shows up as the function's own statements in Query Store |
| DOP 8 on a statement returning 30 rows | Huge input for a tiny output: fix the access path, not MAXDOP |

Estimated plan for a statement you can run as a SELECT: `SET SHOWPLAN_XML ON` then the statement — read-only, nothing executes. Actual cost: run it as a `SELECT` with `SET STATISTICS IO, TIME ON` (read-only) at a quiet moment, and only if the cost is acceptable on production (state the CPU you're about to spend).

## 4. Understand the data, not just the plan

- Row counts of the tables involved (`sys.dm_db_partition_stats`), and the selectivity of the predicate in question.
- Skew: a "0" or blank key that has millions of rows wrecks density estimates (`order_id = 0` style). Check the top values.
- Housekeeping tables that only grow (tracking, queue, log, "pending" tables) explain costs that rise a little every day.
- The business rhythm: when does it run (every 15 minutes? per driver refresh? per screen open?), and who calls it (script 08).

## 5. Design the fix (see fix-patterns.md)

- Prefer the smallest change that removes the bad operator and keeps the SELECT list, joins and predicates identical, so the output can't change.
- Try 2–4 variants as read-only SELECTs and keep a table of each one's CPU, reads and row parity. Rejected variants and why are useful in the write-up: they show the vendor what doesn't work.
- Consider what a hint does when an index disappears: `FORCESEEK` with no usable index raises error 8622. Name the index(es) it relies on in the README.

## 6. Note what is not the problem

The write-up should say what you checked and ruled out (blocking, I/O latency, a missing index that wouldn't help, load growth). It saves the next person the same hour.

## Functions called per row

`CROSS APPLY dbo.udf_X(...)` over N rows runs udf_X N times. Measure it per call (`sys.dm_exec_query_stats` grouped by the function's `objectid`, or Query Store by `object_id`) and multiply by calls per hour of the caller. A 3 ms function that went to 14 ms per row, at 450K calls/hour, is +80 CPU-min/hour — the kind of finding that explains a whole server's CPU after an upgrade.
