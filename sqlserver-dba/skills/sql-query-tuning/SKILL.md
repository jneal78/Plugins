---
name: sql-query-tuning
description: Senior-DBA method for making one SQL Server stored procedure, function, trigger or query cheaper, read-only and evidence-first. Profiles the object statement by statement from Query Store and the plan cache, finds the expensive plan operator and the predicate that prevents a seek (scans, eager spools, row goals, OR joins, implicit conversions, plan flips, per-row functions, converted keys, no-op updates), picks the smallest fix from a catalog of proven patterns (in-procedure hint, small rewrite, caller fix, prefixed index), proves identical results with a read-only parity and cost test, and hands a guarded, reversible patch to the DBA. Use this whenever someone asks why a procedure or query is slow, wants it profiled or tuned, asks what is wrong with a plan, wants a fix for a vendor's procedure, or asks to benchmark a change, even if they don't say "execution plan".
---

# Query tuning

Goal: one sentence of root cause – *"statement N spends X of Y CPU because operator O reads R rows of table T per execution, since predicate P can't seek index I"* – backed by numbers, and the smallest change that removes that operator with provably identical output.

## Before you start

The shared core is at `../../core/` from this skill's folder.
1. **Find the site folder** (`core/site.md`): the profile gives production servers, the Query Store policy, the local index prefix and change marker, and where patches are saved. Check the ledger: the object may already have a fix, ready or deployed.
2. **Read `core/safety.md`** the first time in a session.
3. If you arrived from **sql-workload-hotspots**, **sql-deadlock-analysis** or the dashboard, start from its handoff request (object, statement, windows, numbers, or the locks a deadlock side holds and wants) instead of re-measuring. For a deadlock side the question is which rows the statement *reads*, because that decides the locks it takes: a scan, a key lookup or a non-seekable predicate is usually the root cause, and the fix that removes it also removes the deadlock.

## Steps and scripts

| Step | Question | Script | Read |
|---|---|---|---|
| 1. Fingerprint | Has it changed? Hash, `modify_date`, SET options, signature, plan guides, local marker | `scripts/11_definition_fingerprint.sql` | `references/procedure-analysis.md` §1 |
| 2. Cost by statement | Which statement, which plan, since when, waits | `scripts/05_qs_object_profile.sql` | `references/procedure-analysis.md` §2 |
| 3. Read the plan | Which operator, which table and index, rows read vs returned | `scripts/06_plan_operators.sql`, `scripts/10_implicit_conversions.sql`, `scripts/12_missing_indexes.sql` | `references/procedure-analysis.md` §3, `core/fix-catalog.md` |
| 4. Understand the data | Row counts, skew, placeholder values, tables that only grow | (ad hoc read-only queries) | `references/procedure-analysis.md` §4 |
| 5. Design and prove the fix | 2–4 variants as SELECTs you write yourself, built by the rules in `core/safety.md` (locking hints and side effects removed, lock timeout, estimate first); rows and cost each | (ad hoc read-only queries) | `core/safety.md` ("Running a SELECT version"), `core/fix-catalog.md` (proving the output is unchanged) |
| 6. Benchmark live | Before/after counters on the live system | `scripts/07_live_delta_benchmark.sql` | `core/query-store.md` (timed delta) |
| 7. Package | Guarded deploy, guarded exact rollback, parity test for the DBA (`Parity_TEMPLATE.sql` writes to `#temp`, so Claude never runs it), verify, README, vendor note | `core/templates/patch/` | `core/patch-package.md` |

## The rules that matter most

- **Find the statement, then the operator.** One statement is usually 90%+ of the cost, and one operator in its plan is the reason. Name the operator, table, index, rows read vs returned, and the predicate. That is the root cause; everything else is evidence.
- **Fix with the smallest change that removes the operator,** in this order:
  1. caller or configuration fix, when the caller is at fault (parameter types, a screen's filter, a schedule);
  2. in-procedure hint or small rewrite that keeps the result identical (`FORCESEEK`, `OPTION (LOOP JOIN)`, `FORCE ORDER`, `OPTIMIZE FOR`, hoisting an expression into a variable, splitting an OR join, a seekable test added beside the original one, a changed-rows filter);
  3. a narrow, site-prefixed index when nothing in the code can reach a seek;
  4. server settings, framed as the DBA's call, after the big scanners are fixed.
  Query Store plan forcing and hints follow the site's policy (`core/safety.md`; default: code first, forcing only with approval).
- **Keep the SELECT list, joins and predicates identical** unless the fix *is* a logic correction. Prove row parity: patched / original / patched, compared as multisets (row counts plus `GROUP BY` all columns with `COUNT(*)` both ways; `EXCEPT` alone misses duplicated rows). Look for non-deterministic ties a hint could legitimately change, and say so.
- **Measure variants, keep the losers.** A table of variants tried (CPU, reads, rows) goes in the write-up: it shows the vendor what doesn't work.
- **Read-only proof only.** If the statement writes, the parity test writes to the session's own `#temp` copy and is a script for the DBA to run.
- **A hint has a dependency.** `FORCESEEK` with no usable index raises error 8622. Name the index the fix relies on in the README.

## Finishing

- Package the patch exactly as `core/patch-package.md` says. Build the rollback from the live definition, byte for byte, and prove it locally.
- Hand the write-up to **sql-findings-report**: an analysis for the team and, for vendor code, a vendor ticket.
- Update the ledger: the item under Ready with its script path and expected saving; after the DBA deploys and you've verified it, move it to Done with measured before → after, and add a Watch row to re-check after the next vendor upgrade.
