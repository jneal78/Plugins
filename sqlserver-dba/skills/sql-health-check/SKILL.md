---
name: sql-health-check
description: Read-only SQL Server health check. Covers CPU, memory, disk space and I/O latency, worker threads, waits, compiles, blocking, deadlocks, the availability group, tempdb and Query Store, takes a 60-second sample of live rates, compares today's workload with the same hours a week ago and with a baseline day, then gives a verdict and ranks the savings still available, optionally as a shareable PDF. Use this whenever someone asks how the SQL Server or "the database server" is doing, whether anything is wrong right now, for a health check, a CPU / disk / I/O / memory check, a before-and-after or week-over-week comparison, "where is the CPU going" at server level, or a server report to share, even if they don't say "health check".
---

# SQL Server health check

Answers three questions with read-only measurements:
1. Is the server healthy right now?
2. How does today compare with a week ago and with a known-good day?
3. Where are the next savings?

Audience: a DBA or IT manager who wants a verdict first, then numbers, then a ranked to-do list.

## Before you start

The shared core is at `../../core/` from this skill's folder.
1. **Site folder** (`core/site.md`): from the profile take the production server, the main database and others worth comparing, the time zone, the baseline day, and **Normal on this server** (this server's own thresholds and noise). Read the ledger.
2. **Read `core/safety.md`** the first time in a session. Use only the scripts in `scripts/`: they are SELECT-only, with no temp tables, no `EXEC` and no write keywords, so they pass production guardrails. Keep command lines to the sqlcmd calls below.

Run from a scratch folder. Use Windows paths (`C:\...`) or relative paths for `-i` / `-o`.

## 1. Server state, right now

```bash
sqlcmd -S <server> -d <AppDb> -E -I -W -s"|" -t 120 -i "<skill-dir>\scripts\health_server.sql"
```

In order: instance details; CPU per hour (the ring buffer keeps about 4 hours); memory and clerks; worker threads and waits for a thread; sessions by program; the availability group; tempdb, volumes and I/O latency since restart; log backups; blocking and long requests; deadlocks since restart; key settings and Query Store size.

## 2. Live rates, from a 60-second sample

```bash
sqlcmd -S <server> -d <AppDb> -E -I -W -h -1 -s"|" -t 120 -i "<skill-dir>\scripts\health_rates.sql" -o rates.txt
tr -d '\r' < rates.txt | awk -f "<skill-dir>/scripts/rates.awk"
```

Per second: batch requests, transactions (for the current database), compiles and recompiles, page reads and splits, lock waits and deadlocks; I/O per database file (by database id; 2 = tempdb); the top non-benign waits. The benign-wait list lives inside `rates.awk`, so it never appears on a command line.

## 3. Workload: today vs a week ago vs the baseline

```bash
sqlcmd -S <server> -d <AppDb> -E -I -W -s"|" -t 300 -v BaselineDate=<yyyy-mm-dd> TimeZone=<Windows_zone> -i "<skill-dir>\scripts\health_workload.sql"
```

Run it once per database worth comparing. Window: local midnight to the last complete hour, against the same clock hours 7 days ago (`_a`) and on the baseline day (`_b`). Output: CPU, reads and timeouts by hour; totals per window with average cores busy; waits by category; the top 30 objects with their week-ago and baseline figures; the biggest movers.

Both variables are required by sqlcmd:
- `TimeZone` is the profile's Windows time zone name (`sys.time_zone_info`) with spaces written as underscores, e.g. `TimeZone=Central_Standard_Time` (a sqlcmd `-v` value with spaces breaks in some shells). Each window then starts at its own date's local midnight, so comparisons stay aligned across daylight-saving changes. `TimeZone=none` falls back to the server's current offset, which is an hour off for days on the other side of a change; say so if you use it.
- `BaselineDate=none` when the profile has no baseline yet: run without one, then suggest a steady day from the data and confirm it with the user.

## 4. Interpret and rank

- Thresholds: `core/interpretation.md`, overridden by the profile's **Normal on this server**. Say which you used.
- Known items: the ledger. Report status and script for anything already there; mark everything else **new** – new items are the most valuable part of a repeat run.
- Savings: CPU-minutes in the window scaled to a business day, hedged ("≈ 90 CPU-min/day"). Say which figures are vendor claims.
- `core/number-hygiene.md` before publishing.

When a candidate needs more than a line, hand it on: one object → **sql-query-tuning**; "what changed" across many → **sql-workload-hotspots**; deadlocks → **sql-deadlock-analysis**; a slow business process on a healthy server → **sql-client-path-profiler**.

## 5. Report

Lead with a one-paragraph verdict: healthy or not, what changed versus a week ago, the savings still available. Then:
1. **Key metrics:** week ago / baseline / today / change.
2. **Resources right now:** memory, disk space and latency, tempdb, the AG, worker threads, compiles, blocking, deadlocks, Query Store – each with a verdict.
3. **What was fixed** since the comparison day.
4. **Remaining candidates,** ranked by recoverable CPU: what, today's cost, the fix, owner and status, estimated saving per day.
5. **Server settings to consider,** framed as the DBA's call, with the reason.
6. **Bottom line:** near-term savings that don't depend on a vendor.

## 6. Shareable PDF (when asked)

Write the report as markdown (an hourly CPU chart as mermaid `xychart-beta`: today as bars, week ago and baseline as lines) and render it with **sql-findings-report** (`core/render/`). Save it where the profile says reports go, look at a screenshot, then give the user the file.

## After the check

Update the ledger: new findings under Open with today's cost; Watch items checked off or flagged.
