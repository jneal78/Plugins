---
name: sql-deadlock-analysis
description: Finds, explains and fixes SQL Server deadlocks, read-only and evidence-first. Measures the deadlock rate and lock-type mix, collects every graph the server still holds (system_health or a dedicated Extended Events session, event files read by full path, ring buffer cast once), clusters the graphs into repeatable patterns, tags each pattern's mechanism (lock-order inversion, read-then-write conversion, same-key concurrency, key lookup, scans under page locks, heaps, serializable range locks, escalation, schema locks, parallelism, client-held transactions), gets weeks of history per pattern from failed Query Store executions, and traces each pattern upstream to the code, plan, index, program, host, job, schedule and change behind it, using the hotspots and tuning skills. Ends with a ranked fix per pattern at the right owner and a way to verify it. Use this whenever someone mentions deadlocks, error 1205, "chosen as the deadlock victim", "transaction was deadlocked", a deadlock graph or .xdl file, or asks why two processes keep blocking each other, even if they don't say "deadlock analysis".
---

# Deadlock analysis

Goal: every deadlock on the server assigned to a **pattern**, and for each pattern, one paragraph that a DBA, a developer or a vendor can act on:

> *Pattern P1 (≈ n a day since <date>, mostly <hours>): `<side A code:line>`, sent by `<program/host/job>`, holds `<lock>` on `<table/index>` and wants `<lock>`; `<side B>` holds and wants the reverse. They meet because `<mechanism>`, which happens because `<root cause in a plan, index, isolation setting or client behavior>`, driven upstream by `<schedule / concurrency / change>`. The smallest fix is `<change>` by `<owner>`; verify by `<measure>`.*

Everything here is read-only. A DBA runs anything that writes, including the optional dedicated deadlock session.

## Before you start

The shared core is at `../../core/` from this skill's folder.
1. **Find the site folder** (`core/site.md`). From `site-profile.md`, get the production servers, the time zone, the deadlock rate that is normal there, the `system_health` path if it's recorded, any dedicated deadlock session, application tables that log error 1205, and known benign victims (a monitoring tool). From the ledger, get the deadlock patterns already known, fixed or waiting on a vendor. Report their status; don't rediscover them.
2. **Read `core/safety.md`** the first time in a session. For this skill: always pass `sqlcmd -t`, never shred an XML target inside a CTE, and read event files rather than the ring buffer for anything older than minutes.
3. **Read `references/method.md`** before your first graph. It explains how to read one, where history lives, and the upstream checklist.

## Steps and scripts

Copy a script to a scratch folder, fill its `EDIT ME` block, and run it with sqlcmd. Each script's header gives the exact command. The JSON collectors need `-y 0 -f 65001` (`-y 0` keeps the JSON whole and rules out `-W` and `-h`); the others use `-W -s"|"`.

| Step | Question | Script | Skill used |
|---|---|---|---|
| 1. Rate | How many, of which lock types, since when? Where are graphs kept? RCSI on? | `scripts/13_deadlock_probe.sql` | — |
| 2. Collect | Every graph the server still holds | `scripts/14_deadlock_graphs_file.sql` (event files); `scripts/15_deadlock_graphs_ring.sql` (ring buffer); `scripts/Collect-Deadlocks.ps1` (on a timer, bounded) | — |
| 3. Cluster | Which repeatable patterns, which mechanism, who is on each side? | `scripts/Analyze-Deadlocks.ps1` (local only) → `deadlock_patterns.md` | — |
| 4. History | How long, how often, which hours, still growing? | `scripts/16_deadlock_history_qs.sql` (targets come from step 3) | sql-workload-hotspots `09_errors_timeouts.sql` for error numbers |
| 5. Root cause | Why does each side take those locks? Scan or seek, which index, which predicate? | `scripts/17_deadlock_objects.sql` | **sql-query-tuning**: `11_definition_fingerprint.sql`, `05_qs_object_profile.sql`, `06_plan_operators.sql`, `12_missing_indexes.sql` |
| 6. Upstream | Who sends each side, when, why concurrently, what changed? | `scripts/18_agent_jobs.sql` for jobs | **sql-workload-hotspots**: `08_who_runs_it.sql`, `03_qs_hourly.sql`, `04_qs_regressions.sql` |
| 7. Fix | The smallest change at the right owner | `references/deadlock-patterns.md` | **sql-query-tuning** (design, parity, package); `core/patch-package.md` |
| 8. Verify | Is the pattern gone? | 13 (rate), 14 + `Analyze-Deadlocks.ps1 -Compare`, 16 (victim failures → 0) | — |
| 9. Write up | Analysis for the team, tickets for vendors | — | **sql-findings-report** (sequence diagram of the cycle) |

**Step 2: what to do when graphs are gone.** If 14's `oldest_event_utc` comes after the deadlocks the user cares about, say so plainly. Then:
- take the trend from Query Store (16);
- capture fresh graphs with `Collect-Deadlocks.ps1`, set to run every half of the files' reach for a day;
- offer the DBA `core/templates/deadlock_xe_session_TEMPLATE.sql`, a dedicated session that keeps weeks of graphs. Note that a session must be created on each availability-group replica that can become primary.

A monitoring product may already keep graphs (13 lists every session that records deadlocks). Its exported `.xdl` files can go straight into the analyzer.

**Step 3: read `deadlock_patterns.md` before anything else.** For each pattern, it lists:
- the sides, with their stacks, statements, held and wanted locks, isolation level, transaction shape, program, host, login and job;
- the mechanism tags and catalog candidates;
- timing, bursts and upstream signals;
- the exact `@Targets` and `@Tables` values for 16 and 17, and handoff requests for the other skills.

Work the patterns from largest to smallest, and stop when the rest add up to noise (a single deadlock in a week, or a monitoring tool that loses by design).

## Root cause, then upstream: the rules that matter

- **A deadlock is two access paths, not two queries.** For each side, find the statement, its plan, and the index it locks through. Most application deadlocks disappear when one side seeks instead of scans, touches fewer rows, or holds its locks for less time. That is query-tuning work: hand it over with the request from `deadlock_patterns.md`.
- **Name the mechanism from the graph, then prove it.** Tags are hypotheses:
  - `conversion` is proven by the read and the later write of the same row in the code;
  - `two-indexes` by a key lookup in the reader's plan;
  - `page` by a scan in a plan or `user_scans` in 17;
  - `range` by the isolation level and the program that sets it;
  - `same-code` by the business key both sides were working on.
  
  The catalog (`references/deadlock-patterns.md`) gives the evidence and the fix for each.
- **Look upstream for why the sides meet.** Every pattern has a reason two sessions were there at the same moment. Find it before choosing a fix, because it often moves the fix to a different owner:
  - a schedule (a job, a feed, a nightly batch);
  - concurrency on one key (two workers, client retries after a timeout, double submissions);
  - a client that holds transactions open, runs at serializable, or turns autocommit off;
  - a monitoring check;
  - a recent change (a release, a plan flip, data growth, a placeholder value). For a pattern that started with a vendor release, **sql-release-verification** shows what the release changed and whether it removed a local fix.
  
  `references/method.md` has the checklist and which script answers each item.
- **Count monitoring-tool victims separately.** They are real deadlocks that cost the application little. Fix the check (its owner is the monitoring admin), and keep them out of the application's rate.
- **Don't reach for server-wide switches first.** Turning on RCSI, changing `LOCK_ESCALATION`, raising `DEADLOCK_PRIORITY` or adding retry logic all change behavior for everything or only hide the symptom. Say when one of them is the right call for a given pattern, but frame it as the DBA's or owner's decision. Most patterns have a local fix.
- **Retries are mitigation, not a fix.** Applications should retry error 1205. Say whether the victim's work is lost when they don't (the impact) or repeated when they do (load), but still fix the pattern.

## Handing off

- **To sql-query-tuning:** one side's statement, with pattern, counts, window, held and wanted locks, and the question "scan or seek, and why". It returns the root-cause sentence and a packaged patch.
- **To sql-workload-hotspots:** "who sends `<query_hash / object>` and when" (08), "how busy is this group at the deadlock hours" (03), "what changed in the week the pattern started" (04).
- **To sql-findings-report:** the analysis (verdict, per-pattern table, corrective actions, verify) and a vendor ticket per vendor-owned pattern. Use a mermaid sequence diagram of the cycle: who holds what, who waits for what, who loses.
- **From sql-health-check or the dashboard:** a deadlock rate above the profile's normal, or a new pattern, starts here at step 1.

## Reporting

Lead with the verdict: the rate (per day, now vs normal), how many patterns account for most of it, which are fixable locally today, which belong to vendors, and which are tools.

Then give a pattern table with these columns:
- pattern;
- per day, and history since;
- sides and their owners;
- mechanism;
- root cause;
- upstream driver;
- fix and owner;
- status.

Next, list the corrective actions in order, each with its script, risk and expected effect, and say how to verify them.

Update the ledger:
- one row per pattern with its count and status;
- Done with the measured before → after once verified;
- a Watch row for each vendor-owned pattern, to re-check after the next upgrade.
