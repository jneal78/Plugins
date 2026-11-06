# Interpreting the numbers

Thresholds are starting points for a busy OLTP server. Replace them in the site profile once you have a few weeks of your own baseline.

## Conversions

- **CPU-minutes to cores:** CPU-min per hour ÷ 60 = cores busy. On a 16-core box, 480 CPU-min/hr is half the server.
- **Savings per day:** CPU-min in the window × (business hours ÷ window hours). Round, hedge ("≈").
- **Reads to bytes:** logical reads × 8 KB. 1M reads ≈ 7.6 GB touched in memory.
- **Query Store vs the CPU meter:** Query Store sees only the databases it is on and only completed/aborted statements. The ring-buffer `ProcessUtilization` meter sees everything (all DBs, compiles, AG redo, background). Compare Query Store with Query Store and the meter with the meter.

## Thresholds

| Metric | Healthy | Watch | Act |
|---|---|---|---|
| SQL CPU, hourly average | < 60% | 60–80% | > 80% for an hour, > 90% for 15 min |
| Worker threads | < 80% used, no thread waits | > 95% used, occasional `THREADPOOL` | `THREADPOOL` waits climbing |
| Page life expectancy | hours, steady | falling day over day | < ~1 h on a large buffer pool, or grants pending > 0 |
| Disk latency, data read / write / log write | < 5 / 5 / 2 ms | 5–15 ms | > 20 ms sustained |
| Disk free space | > 25% | 15–25% | < 15% |
| tempdb free | > 10 GB | 5–10 GB | < 5 GB, or the version store growing |
| Compiles / recompiles per s | < 50 / 20 | ~100 / 50 | rising with CPU |
| Deadlocks | the site's usual rate (profile) | a new pattern, or a rise | deadlocks hitting a business-critical process |
| Blocking | waits < 5 s | short chains that clear | holds of 30 s+, idle head blocker with open transaction |
| Query Store timeouts (execution_type 3) | < ~100/day | 100–500/day | hundreds per hour |
| Query Store errors (execution_type 4) | the site's normal noise level | a new object in the top 10 | a sudden jump |
| Query Store size | < 80% | 80–90% | > 90% or READ_ONLY |
| AG | synchronized, healthy, lag ≤ 2 s | send/redo queue growing | NOT_HEALTHY |

## Usually benign — don't flag

- Waits: `REDO_THREAD_PENDING_WORK`, `CLR_AUTO_EVENT`, `SP_SERVER_DIAGNOSTICS_SLEEP`, `BROKER_*`, `XE_*`, `*SLEEP*`, `*QUEUE*`, `DIRTY_PAGE_POLL`, `HADR_*` timers and notifications, `WAITFOR`.
- Database Mail sessions waiting on `BROKER_RECEIVE_WAITFOR`.
- Idle worker threads that count toward the thread total but are released after ~15 minutes. Only waits *for* a thread matter.
- Missing names because the reading login lacks `VIEW ANY DATABASE` or msdb access: report by id (an Agent job shows as its id in `program_name`).
- Database Mail sessions waiting on `BROKER_RECEIVE_WAITFOR` with a `DELETE` command are idle, not deleting.
- Deadlocks whose victim is always a monitoring tool (running at low deadlock priority) don't hurt the applications. Count them separately from application deadlocks; fix them anyway if they hide the ones that matter.
- The site profile lists this server's own normal noise (for example "~4,000 application errors a day is normal"). Use it before flagging.

## Reading Query Store figures

- **Windows are UTC.** `runtime_stats_interval.start_time` is a `datetimeoffset` in UTC; convert for the report and say the time zone.
- **Totals are `avg_x * count_executions`.** Summing averages is wrong.
- **One query can have many plans.** A per-plan breakdown with first/last seen shows plan flips (often at a nightly stats update or recompile).
- **Parallel CPU.** `avg_cpu_time` includes all workers; `avg_duration` is wall clock. CPU ≫ duration means parallelism.
- **Rows per execution** that are tiny next to reads per execution (25 rows for 40M reads) is the signature of a fixable plan.

## Ranking

Rank by recoverable CPU per day, then user-facing latency and timeouts, then risk and effort.

| Owner of the code | Usual route |
|---|---|
| In-house | Change the code |
| Vendor | In-procedure hint or small rewrite with rollback + vendor note, or a prefixed index; record it for re-checking after upgrades |
| Ad hoc callers (reports, apps, ORMs) | Fix the caller: parameter types, filters, schedule, Application Name |
| Configuration | DBA's call, with the reason and the expected effect |
