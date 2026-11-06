# Query Store and DMV field guide

## The Query Store joins you will write every time

```
sys.query_store_runtime_stats rs
  JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
  JOIN sys.query_store_plan p                   ON p.plan_id = rs.plan_id
  JOIN sys.query_store_query q                  ON q.query_id = p.query_id
  JOIN sys.query_store_query_text t             ON t.query_text_id = q.query_text_id
sys.query_store_wait_stats ws                   ON ws.plan_id = p.plan_id AND ws.runtime_stats_interval_id = i.runtime_stats_interval_id
```

- `q.object_id` = the procedure, function or trigger; `0` = ad hoc / `sp_executesql`.
- `q.query_hash` = shape of the statement. Stable across `ALTER`, drop/recreate and literal changes (for parameterized text). Use it to compare a statement before and after an upgrade.
- `rs.execution_type`: 0 = regular, 3 = aborted (client timeout / attention), 4 = exception (error).
- `rs.avg_cpu_time`, `avg_duration` are microseconds; `avg_logical_io_reads` are pages. Multiply by `count_executions` for totals.
- `ws.wait_category_desc`: CPU, Parallelism, Lock, Buffer IO, Memory, Network IO, etc. Totals are already totals (`total_query_wait_time_ms`).
- `p.query_plan` is `nvarchar(max)`; `TRY_CAST(... AS xml)` it inside a CTE, then use `.nodes()` / `.value()`. XQuery `starts-with()` isn't supported: use `substring(string(...),1,2) != "[#"` to skip temp tables. Don't put XML methods in a `GROUP BY`; compute them in a CTE first.

## Time

Query Store stores interval times in UTC. Convert each local date with **its own** offset, from the site profile's Windows time zone name (`sys.time_zone_info`, e.g. `Central Standard Time`; `AT TIME ZONE` does not accept IANA names such as `America/Chicago`):

```sql
DECLARE @tz sysname = N'Central Standard Time';                                       -- from the site profile
-- a local date's midnight, in UTC (DST-correct for that date):
DECLARE @d0 datetime2 = CONVERT(datetime2, (CAST(@day AS datetime2) AT TIME ZONE @tz) AT TIME ZONE 'UTC');
-- local clock hour of an interval inside a window that starts at local midnight @d0:
DATEDIFF(MINUTE, @d0, CAST(i.start_time AS datetime2)) / 60
-- local time of an interval, for display:
CONVERT(datetime2, i.start_time AT TIME ZONE @tz)
```

**Don't** apply today's offset (`DATEDIFF(MINUTE, GETUTCDATE(), GETDATE())`) to past dates. For a week after each daylight-saving change, "the same hours a week ago" is then an hour off, and a baseline day from the other half of the year stays an hour off for months. The scripts that compare windows (health check, dashboard, hotspots 02–04) take the zone name and fall back to today's offset only when none is given. Scripts that only label recent days in local time (05, 08, 09, 16) still use today's offset; their oldest days can show an hour shifted across a change.

`AT TIME ZONE` costs CPU per call. Convert a handful of window bounds (or one row per day) and compare `i.start_time` with them; don't convert every runtime-stats row.

Compare a window with the same clock hours 7 days earlier, and with a baseline day. Exclude the hour a change was deployed in ("mixed hour"). Use **whole intervals only**: the interval running now holds only part of its data, so a window that ends "now" compared with a full window a week ago understates the current one (by up to a quarter of an hour's worth on a 4-hour window). End windows at the last complete interval boundary (`interval_length_minutes` from `sys.database_query_store_options`) and divide by the hours actually included.

## Gotchas that change conclusions

| Gotcha | Symptom | What to do |
|---|---|---|
| Plans per query cap (`max_plans_per_query`, default 200; some sites set it low) | A busy query "disappears" or its cost drops sharply | Cross-check `sys.dm_exec_query_stats`; recommend raising the cap |
| Size-based cleanup | Week-ago figures look too low; history starts mid-week | Check `actual_state_desc`, `current_storage_size_mb` vs max; say the comparison is incomplete |
| READ_ONLY state | Nothing new recorded since a time | Report it; recommend size increase (capacity, not behavior) |
| Objects dropped and recreated (vendor upgrade, `DROP/CREATE` deploy) | Old rows have an `object_id` with `OBJECT_NAME() IS NULL` | Label as `(dropped id N)`; recover the name by matching `query_hash` to a statement of a live object |
| Literal (non-parameterized) ad hoc SQL | Thousands of query_ids with one `query_hash` | Group by `query_hash`; get one sample text with `MAX(query_text_id)` |
| Nested modules | A function's statements show under the function, not the caller; procedure stats include nested CPU | Don't add caller and callee totals; say "inclusive" |
| Capture mode AUTO | Cheap, infrequent statements aren't captured | Use plan cache for them |
| Interval length | 60 min is common; 15 min gives finer before/after | Read `interval_length_minutes` and report it |

## Plan cache (DMVs) — when Query Store isn't enough

| Need | View |
|---|---|
| Per-procedure totals since compile | `sys.dm_exec_procedure_stats` (also `_function_stats`, `_trigger_stats`) |
| Per-statement totals, with `query_hash`, `last_dop`, rows, spills, grants | `sys.dm_exec_query_stats` + `sys.dm_exec_sql_text(sql_handle)` + offsets |
| Cached plan XML | `sys.dm_exec_query_plan(plan_handle)` or `sys.dm_exec_text_query_plan` for statement offsets |
| What a connection last ran (stays after an error) | `sys.dm_exec_connections.most_recent_sql_handle` |
| Running now | `sys.dm_exec_requests` + `sys.dm_exec_sessions` |
| CPU per minute, last ~4 h | `sys.dm_os_ring_buffers` `RING_BUFFER_SCHEDULER_MONITOR` |
| Engine exceptions (error numbers, recent) | `sys.dm_os_ring_buffers` `RING_BUFFER_EXCEPTION` |
| Cumulative CPU per scheduler (for deltas) | `sys.dm_os_schedulers.total_cpu_usage_ms` where `status = 'VISIBLE ONLINE'` |
| Missing index suggestions | `sys.dm_db_missing_index_details / _groups / _group_stats` |

Plan cache counters reset when a plan recompiles or is evicted. For a before/after on a live system use a **timed delta**: read the counters into variables, `WAITFOR DELAY '00:05:00'`, read again, divide (script 07). This is read-only and needs no tables.

## Matching across a change

To compare a statement before and after a deploy or upgrade:
1. Group by `query_hash` and window (before / after), summing `count_executions`, CPU, reads, duration.
2. Statements with a hash in "after" but not "before" are **NEW** (the vendor rewrote them); rank those by CPU separately.
3. Compute per-execution deltas and `extra CPU-min/hr = (after_per_exec - before_per_exec) × after_execs_per_hr`. That ranks regressions by impact, not by ratio.
4. For a function called per row, also compare calls per hour of the caller: a function can stay the same per call and still cost more if the caller calls it more.
