# Release verification: method

How to run a release check end to end, which windows to use, how to read the evidence, and how to write it up. The scripts are in `../scripts/`; the other skills' scripts are named by skill.

## Timeline of a release check

| When | What | Why then |
|---|---|---|
| **Days before** (release announced) | Snapshot the definitions in scope (21). Run 22 with the ledger's patches and indexes filled in, and keep the filled copy in the site folder. Benchmark the objects users care about (07, at a busy hour). Ask the vendor for release notes and the object list, and ask about each local patch: "will the release replace `<object>`?" | The snapshot is the only exact "before". The vendor answer decides whether a patch needs rebuilding. |
| **Right after the deploy** (first hour) | 19 (scope, deploy window), 22 (local changes), 21 + `Compare-Definitions.ps1` (real changes), 09 and the application error table (errors since the deploy). 07 on the changed objects. | Reverted patches and lost permissions hurt from the first minute. Query Store has no clean "after" interval yet. |
| **Same day, after 3–4 whole intervals** | 04 twice (vs just before, vs a week ago). 23 for changed logic. 13 for the deadlock rate. | Enough whole intervals for per-statement comparisons. |
| **Next business day** | 04 over business hours vs the same hours a week ago; 07 at the busy hour; 09; 16 for each deadlock pattern the release touched. | Evening load flatters a release; business hours size the saving or the damage. |
| **After a week** | 16 / 09 for rare events; 22 again if a hot-fix followed. Close the Watch rows. | Rare patterns have quiet days; a week covers them. |

## Scope: what the release touched (19, 20)

- Set `@Since` an hour or two before the announced window, `@Schema` to the vendor's schema (or `@NameLike` to its prefix) from the profile's vendors table.
- **Section 1** gives the deploy window: one dense burst is the release. A second, small burst minutes or hours later is usually a hot-fix, or someone re-applying a local customization by hand (look for your marker on those objects in section 2). Tables in that list are often index maintenance at night; they are listed so you can tell them apart.
- **Section 2** is the object list. `added` means its `create_date` is inside the window: the release removed and re-added it (check permissions and signatures in the same row) or it is new. `set_options_off > 0` is worth a sentence in the report on its own.
- **20** (optional) adds who and from where, and the only read-only record of objects **removed**. If the login can't read the default trace, ask the DBA for the deploy log instead.

## Real changes: the before text (21, Compare-Definitions.ps1, 19 §3–4)

Sources for "before", best first:

| Source | Exact? | Notes |
|---|---|---|
| A snapshot taken with 21 before the release | Yes, with hashes | Always take one when a release is announced |
| A nightly or scheduled copy of definitions (source-control sync, schema compare output) | Usually | May lag production by a day; check the copy's date against the last change before the release |
| The vendor's previous release scripts | Not reliably | May differ from what was deployed, local patches aren't in them |
| Query Store statement texts (19 §3–4) | Statement level only | Shows which modules got new statements, for statements that have run; no help for branches that haven't run since, nor for encrypted modules' non-statement code |
| A restored copy of a pre-release backup (DBA) | Yes | The fallback when nothing else exists |

Reading `definition_changes.md`:
- **same / same-norm**: re-applied, no code change. Report the count, not the list.
- **CHANGED**: read each diff. Match it to the release notes and to the ledger's vendor items: "item #2 shipped as proposed", "item #4 shipped differently: …", "not mentioned in the notes". A change the notes don't mention gets its own line.
- **MARKER LOST**: a local patch was overwritten. Confirm with 22.
- **NEW / GONE**: new objects and removed ones. For a removed object, check callers (09: errors 208 / 2812) before calling it harmless.
- **HASH MISMATCH**: the snapshot file was altered after capture; take it again.

Without any "before" text, 19 §3 still classifies each redefined module:
- `CODE CHANGED: new statement text`: at least one statement text was compiled for the first time after the module's last redefinition. §4 lists those statements.
- `same statement texts (as far as they ran)`: every statement that has run since is one Query Store already knew.
- `not run since: no evidence` / `no Query Store rows`: say so; don't guess.

## Local changes (22)

Fill the three lists once from the ledger and each patch README (object, marker, original hash, patched hash; local indexes; local objects) and keep that filled copy in the site folder. After every release:

| State | Meaning | Action |
|---|---|---|
| patched, as built | Survived | Note "survived release <date>" in the ledger |
| patched, variant | Marker present, different text | Someone re-applied it by hand, or the vendor kept your lines. Diff it, record the new hash |
| REVERTED | The vendor original is back | Re-run the patch's Verify, then the DBA re-applies the guarded deploy |
| CHANGED | New vendor text, marker gone | Read it for the fix you asked for. If absent, rebuild the patch from the new text (sql-query-tuning, `core/patch-package.md`) |
| MISSING (object) | The release removed it | Ask the vendor; check callers |
| MISSING / DISABLED (index) | A table rebuild dropped or disabled it | Check whether the vendor shipped an equivalent (same leading keys); otherwise the DBA re-adds it |
| forced plan ORPHANED / FAILING | The forcing no longer applies | Per the site's Query Store policy: re-establish, or replace with a code fix |

## Same output (23)

Equivalence matters when a release changes a filter, a join, a window, a function or a default that decides *what* the application sees. Three ways, cheapest first:

1. **Business indicators** (rows produced per hour by the process, from its output table) before and after. Cheap and convincing for "nothing got lost", but blind to wrong values.
2. **23 over a bounded key set**: the old expression from the before text and the new one from the live text, as SELECTs over the same keys, compared as multisets. Follow `core/safety.md` for SELECT versions of application statements.
3. **A parity run on a copy** when the logic needs a `#temp` table or writes: `core/templates/patch/Parity_TEMPLATE.sql`, run by the DBA.

An intended behavior change is still a finding: describe exactly which rows now differ and why ("legs already started are now returned at any date; before, only within 15 days"), so the business can confirm it.

## Cost (04 twice, 07)

Windows, in local time, whole Query Store intervals:
- **Deploy hour** = the interval containing the deploy start through the interval containing its end. Excluded from everything.
- **Before** = the 3–4 whole intervals just before the deploy hour, on the old code.
- **After** = whole intervals from the first one after the deploy hour, to the last complete one.
- **Week ago** = the same clock hours as "after", seven days earlier (old code).

Run sql-workload-hotspots `04_qs_regressions.sql` twice with `@Schema` / `@ObjectLike` scoped to the vendor:
1. `@Before*` = before, `@After*` = after: the step change, but different hours of the day.
2. `@Before*` = week ago, `@After*` = after: like for like.

Rank by `extra_cpu_min_hr`, then look at NEW statements by CPU (rewritten statements show as NEW and GONE: pair them by object and text). For a function called per row, compare calls per caller execution too.

In the first hours use sql-query-tuning `07_live_delta_benchmark.sql`: per call CPU, reads and elapsed over 5 minutes, on the changed objects and the main callers. Say the load during the sample (batches/s) and the hour; an evening sample is not a business-hours figure.

The saving or cost at business volume = (after − before per call) × calls per business hour; say which "before" (week ago) and which hours, and hedge it until a business-hours run confirms it.

## Failures (09, error tables, 13 / 16)

- Query Store aborts (type 3) and exceptions (type 4) per object, after vs the same length before vs week ago (09 with `@Object`, or `@Days` covering both).
- The application's own error table, if the profile names one: by procedure and error number, after vs before. Separate the deploy-window errors.
- Deadlocks: the rate (13) and, for patterns the release touched or was meant to fix, the per-pattern history (16). A pattern that disappeared needs a full cycle of its old rate before it is "fixed".
- Lock waits: per hour, after vs week ago. A release that adds application locks or longer transactions shows up here before it shows up as deadlocks. If one hour stands out, check whether the same blocker existed before the release before blaming it.

## Outside the code (08, 03)

Releases often ship application changes with the database changes: connection-string settings (pool lifetime, application name), retry logic, polling intervals. 08 shows connection ages and program names; 03 shows calls per hour per group. A change in call rate or connection age with no code change in the database is the application's; ask the vendor what changed.

## The write-up

Use sql-findings-report. Outline (it worked for real releases):

1. **Verdict** (the paragraph from SKILL.md), with the latest update on top when the report is revised over days.
2. **Windows table**: name, local hours, old/new code, source (Query Store / plan cache).
3. **Measures table**: before, week ago, after, change vs week ago. Calls first, then per-call cost, then totals, then the server.
4. **What changed**: object, version before → after, change in one line, ticket item. Then "not changed" items the vendor was asked for.
5. **Local changes**: per patch, index and object.
6. **Same output**: each check and its result; intended behavior changes in words.
7. **Cost**: per statement and per object, hour by hour if the shape matters.
8. **Errors, timeouts, deadlocks, blocking.**
9. **Configuration** (connections, settings).
10. **To do**: numbered, each with owner, script and date. Questions for the vendor, listed.
11. **Sources**: each script and what it gave.

Say the deploy window, the check time and the time zone in the first lines. Every number carries its window and source (`core/number-hygiene.md`).
