---
name: sql-workload-hotspots
description: Finds where a SQL Server's time goes and what changed, read-only, from Query Store and DMVs. Ranks objects, statements and application or integration groups by CPU, reads, duration, timeouts and errors, hour by hour, today vs a week ago vs a baseline day; finds per-execution regressions and new statements between two windows; and attributes a statement to the program, host and login that sends it, including failing statements nobody recognizes. Use this whenever someone asks "where is the CPU going", "what's using the server", "what changed since last week / since the upgrade", "which integration is busiest", "who is running this query", "why is this statement failing or timing out", or wants a top-N or hour-over-hour breakdown, even if they don't say Query Store.
---

# Workload hotspots

The question is always "where does the time go, and what changed?" Answer it top-down: server → database → group → object → statement, and stop at the level that answers the user. When one statement clearly stands out, hand it to **sql-query-tuning**.

Everything here is read-only. A DBA runs anything that writes.

## Before you start

The shared core is at `../../core/` from this skill's folder.
1. **Find the site folder** (`core/site.md`): read `site-profile.md` (production servers, time zone, policies, workload groups, baseline day, normal noise) and the findings ledger. Don't rediscover a ledger item; report its status.
2. **Read `core/safety.md`** the first time in a session. Short version: SELECT only, SQL in `.sql` files, `sqlcmd -t` always, never reword a blocked command.
3. **Fix the windows up front:** today vs the same clock hours 7 days ago, and the profile's baseline day. For a deploy or upgrade, use explicit before / after windows and drop the mixed hour. Read `core/number-hygiene.md`.

## Steps and scripts

Copy a script to a scratch folder, fill its `EDIT ME` block, run it with `sqlcmd -S <server> -d <db> -E -I -W -s"|" -t 120 -i <file> -o <file>`.

| Step | Question | Script | Read |
|---|---|---|---|
| 1. Triage | Is the box healthy right now? CPU, threads, waits, memory, blocking, Query Store state | `scripts/01_server_snapshot.sql` (for a full check, use **sql-health-check**) | `core/interpretation.md` |
| 2. Where | Top objects and statements by CPU, reads, timeouts, errors vs a week ago | `scripts/02_qs_top_consumers.sql` | `core/query-store.md` |
| 3. When | Hour over hour, by the profile's workload groups | `scripts/03_qs_hourly.sql` | — |
| 4. What changed | Per-execution regressions and new statements between two windows | `scripts/04_qs_regressions.sql` | `core/query-store.md` (matching across a change) |
| 5. Who sends it | Program, host, login, process id for a statement or object | `scripts/08_who_runs_it.sql` | `references/attribution.md` |
| 6. Is it failing | Timeouts and errors by day and object; engine exceptions | `scripts/09_errors_timeouts.sql` | `references/attribution.md` |

"How busy is X today?" is steps 2–3. "What changed after last night's release?" is step 4, then **sql-release-verification** when it's a vendor release. "Who keeps running this failing update?" is steps 5–6.

## What matters most

- **Rank by recoverable CPU per day**, then user impact (latency, timeouts), then risk. 60 CPU-min per hour is one core busy. Hedge estimates ("≈ 90 CPU-min/day").
- **Calls are not business events.** Before calling a rise "load growth", check the business table that records the outcome (orders, invoices, messages). If the user's real complaint is a slow business process and the server looks fine, that's **sql-client-path-profiler**.
- **Query Store has blind spots:** the plans-per-query cap, size-based cleanup, objects dropped and recreated by upgrades, literal ad hoc SQL. Cross-check surprising drops against the plan cache and match statements by `query_hash` (`core/query-store.md`).
- **Group before you rank.** A hundred literal ad hoc statements with one `query_hash` are one problem. Integration groups (from the profile) show which owner to talk to.
- **Per execution vs per hour:** a statement can get cheaper per call and costlier per hour because it is called more. Show both when they disagree.

## Handing off

When one object or statement explains most of the cost, hand it on with a short, explicit request so the next step starts working instead of re-measuring:

> Tune `schema.object` on `<server>/<db>`: statement query_id `<n>` (`query_hash 0x…`), `<n>` CPU-min/day today vs `<n>` a week ago, `<n>` ms and `<n>` reads per call, plans `<ids>`, windows `<local times, zone>`.

Deadlock complaints go to **sql-deadlock-analysis**; vendor releases to **sql-release-verification**; write-ups to **sql-findings-report**.

## Reporting

Lead with the verdict (what dominates, what changed, by how much), then a table per level (week ago / baseline / today / change), then the ranked list with owners. Mark new items **new**. Update the ledger with anything new under Open.
