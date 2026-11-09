---
name: sql-release-verification
description: Verifies a vendor release, upgrade, hot-fix or in-house deploy on SQL Server, read-only. Use this whenever someone says a vendor upgraded, patched or deployed something, or asks "is the hot-fix working", "did last night's release break anything", "what did the upgrade change", "did the upgrade overwrite our fix" or "the vendor is upgrading Thursday, what should we do", even if they don't say "release verification". Finds the deploy window and what changed (really changed vs only re-applied), checks that local patches, indexes, permissions and forced plans survived, proves changed logic returns the same rows, compares cost before and after against the same hours a week ago, hunts new errors, timeouts and deadlocks, and ends with a verdict and re-check dates. Also prepares for an announced release.
---

# Release verification

Goal: one verdict a DBA, a manager and the vendor can all act on:

> *The <product> release of <date> (<deploy window>, <n> objects redefined, <m> really changed) is **<working as intended / working, with regressions / not working / too early to tell>**. What it was meant to fix: <measured before → after, like for like>. What it broke or put back: <regression, reverted local patch, lost index or permission>, costing <n CPU-min/hr or user-facing effect>, fix by <owner>. Errors, timeouts and deadlocks: <before vs after>. Still to confirm: <rare events, business-hours load>, re-check on <date>.*

Everything here is read-only. A human deploys every fix and re-applies every reverted patch.

## Before you start

The shared core is at `../../core/` from this skill's folder.
1. **Find the site folder** (`core/site.md`). From `site-profile.md` get the production servers, time zone, the vendors table (schema or name pattern, version-note format, where a copy of their code is kept), the change marker and index prefix, application tables that log errors, and the policy on fixes to vendor code. From the ledger, list every **Done** item on the vendor's objects (patches, indexes) and every **Open / Watch** item the vendor was asked to fix: those are the two lists this check must answer.
2. **Read `core/safety.md`** once per session, and `core/query-store.md` ("Matching across a change") before the first before/after query.
3. **Read `references/method.md`** for the windows, the order of work and the report. `references/release-risks.md` lists what releases break silently and which script shows each.

## Steps and scripts

Copy a script to a scratch folder, fill its `EDIT ME` block, run it with sqlcmd as its header says (always with `-t`).

| Step | Question | Script | Skill used |
|---|---|---|---|
| 0. Prepare | (When the release is announced) What must we capture now, and what is at risk? | `21_release_definitions.sql` (snapshot), `22_local_changes_check.sql` (baseline), sql-query-tuning `07_live_delta_benchmark.sql` on the objects that matter | — |
| 1. Scope | When was the deploy, what did it add, redefine or remove, and who ran it? | `19_release_changes.sql` (sections 0–2, 5–7); `20_release_ddl_events.sql` if the login may read the default trace | — |
| 2. Real changes | Which objects have new code, which were only re-applied? Did the vendor ship what was asked? | `21_release_definitions.sql` + `Compare-Definitions.ps1` (local); without a "before" snapshot, `19` sections 3–4 | sql-query-tuning `11_definition_fingerprint.sql` per object |
| 3. Local changes | Did our patches, indexes, objects, permissions, forced plans survive? | `22_local_changes_check.sql`; `19` sections 2 and 6 | sql-query-tuning to rebuild a patch; `core/patch-package.md` |
| 4. Same output | Does changed logic return the same rows (or exactly the intended difference)? | `23_equivalence_TEMPLATE.sql`; business indicators from the profile | `core/templates/patch/Parity_TEMPLATE.sql` when a test needs a `#temp` table (DBA runs it) |
| 5. Cost | Per statement and per object, after vs before, like for like | sql-workload-hotspots `04_qs_regressions.sql`, twice (see method); sql-query-tuning `07_live_delta_benchmark.sql` in the first hours | sql-health-check for the server-level view |
| 6. Failures | New errors, timeouts, deadlocks, lock waits? | sql-workload-hotspots `09_errors_timeouts.sql`; the profile's application error table; sql-deadlock-analysis `13_deadlock_probe.sql` / `16_deadlock_history_qs.sql` | sql-deadlock-analysis for a new pattern |
| 7. Outside the code | Did the application's connections, program names or call mix change with the release? | sql-workload-hotspots `08_who_runs_it.sql`, `03_qs_hourly.sql` | — |
| 8. Verdict | Working? What to fix, re-apply, ask the vendor, re-check when? | — | sql-findings-report; the ledger |

**Quick mode, "is the hot-fix working?"** One or a few named objects: `11_definition_fingerprint.sql` (is it live, which hash), `07_live_delta_benchmark.sql` (per call now), `04_qs_regressions.sql` with `@ObjectLike` (vs before and vs a week ago), `09_errors_timeouts.sql` with `@Object`. Skip steps 1–3 unless the fingerprint shows something unexpected.

## Rules that matter

- **Production is the truth; release notes and source control are claims.** Diff the live text. A vendor that re-applies its whole schema redefines every object, so `modify_date` alone says nothing: in one release 150 modules were redefined and 7 had new code. Name the 7, with their version notes before → after, and say which ticket item each answers.
- **Take a snapshot before the release whenever you know one is coming.** It's the only exact "before". Without one, Query Store statement texts (19 §3–4) show which modules got new code for every statement that has run, and a source-control copy gives the rest. Say which source you used.
- **Never measure in the deploy hour.** Query Store's interval that contains the deploy mixes old and new code. Before ends at the interval that holds the deploy start; after starts at the first whole interval after the deploy ends. In the first hour, use the plan-cache benchmark (07) instead.
- **Compare like with like, twice.** After vs the hours just before shows the step change; after vs the same clock hours a week earlier removes time-of-day and weekday mix. A release checked at 17:00 against an afternoon "before" flatters it: the evening carries less work per call. When the two comparisons disagree, trust the week-ago one and say why.
- **Per call and per business unit, not only totals.** Calls can rise or fall with the release (a loop removed, a retry added). Report per call, per hour, and per business event where the profile defines one. A function can cost the same per call and be called far more.
- **Don't add nested modules.** A procedure's figures include the functions and procedures it calls. Report a family "inclusive" once, and its parts separately.
- **A release that rebuilds an object loses what was attached to it.** Removing and re-adding an object drops its permissions, signatures, trigger order, forced plans and plan guides, and gives its statements new ids. 19, 20 and 22 check each; 04 still matches its statements by `query_hash`.
- **Your local changes are the release's first casualty.** Every Done patch and local index on the vendor's objects is checked (22). REVERTED means re-apply after review; CHANGED means read the vendor's new text for the fix before rebuilding. Never re-apply automatically: the guarded deploy refuses a text it wasn't built for, as it should.
- **Rare events need time.** A deadlock or error pattern that ran at 0–20 a day isn't fixed after one quiet night. State the sample ("0 in 16 hours, against 5 in the 16 hours before"), call it preliminary, and set a re-check date that covers the old rate's quiet days.
- **Errors during the deploy itself are expected; count them apart.** "Definition changed since compiled" (2801), objects briefly missing (208), and schema-lock waits inside the deploy window are the deploy, not the release. Anything after the window counts.
- **When a bigger sample changes an earlier number, label it a correction** (`core/number-hygiene.md`), and keep the first figure visible so the reader can follow.
- **Leftover objects are the vendor's to remove.** A copy table created during the deploy goes to the vendor as a question ("can it be removed?"), not into a cleanup script.

## Handing off

- **To sql-query-tuning:** each regressed or new expensive statement, with `query_id`, `query_hash`, before/after per call, executions per hour and extra CPU-min/hr from 04. It returns the root cause and the smallest fix. A reverted patch goes there only if the vendor's text changed (rebuild).
- **To sql-deadlock-analysis:** a deadlock pattern that is new since the release, or one the release was meant to fix (verify step 8 there).
- **To sql-findings-report:** the verification write-up (verdict, windows table, what changed, equivalence, cost, failures, to-do) and, per regression, a vendor ticket with the evidence; a vendor note for every patch that had to be re-applied.
- **From the dashboard or sql-health-check:** an object that jumped on a day the profile or the ledger ties to a release starts here at step 1.

## Reporting and the ledger

Lead with the verdict paragraph above, then the windows table (name, local hours, code old/new, source), then a measures table with before, week-ago and after columns. Follow with: what changed (object, version before → after, change, ticket item), local changes (state per patch and index), equivalence, cost, failures, configuration, and a numbered to-do with owners and dates. `references/method.md` has the outline.

Update the ledger:
- vendor-fixed items → **Done**, with the measured before → after and "fixed by vendor release <date>";
- reverted patches → **Ready** (re-apply), or **Open** if the vendor's text changed;
- each regression → **Open** with owner and cost;
- a **Watch** row per item that needs time (deadlock patterns, business-hours benchmark), with the re-check date and script;
- every Done patch on the vendor's objects stays on the upgrade checklist: note the release date it survived.
