# <object>: <one-line description of the change>

In-procedure fix for the <vendor> object `<schema>.<object>` (<what it does>). Built on <date> from the **live production definition**, matched by SHA-256 hash.
- No Query Store changes and no index changes.
- Not deployed yet. <or: Deployed <date time> by <who>; verified <date time>.>

Full analysis: [`docs/<object>_Analysis_<date>.md`](../../../docs/<object>_Analysis_<date>.md).

## The problem

<How often it runs, which statement, Query Store query id.>

| | |
|---|---|
| Per run | <reads, CPU, DOP, elapsed> |
| Per day | <CPU-min, share of the object, share of the database> |
| Query Store | <plans, flips, dates> |

<Root cause in 2–4 numbered points: operator, table, index, rows, why.>

## The change (<n> lines, marked `-- <MARKER>`)

```sql
<the changed lines in context>
```

**Why the output can't change:** <SELECT list, joins, predicates unchanged; hints change only access paths; note any non-deterministic tie-break that already existed.>

## Measured (read-only, production, <date>)

| Run (<time>) | CPU | Elapsed | Logical reads | Rows |
|---|---|---|---|---|
| Patched | | | | |
| **Original** | | | | |
| Patched | | | | identical |

**Variants tried:**

| Variant | CPU | Why rejected |
|---|---|---|
| | | |
| **Chosen** | | **Smallest change** |

**Expected saving:** ≈ <n> CPU-min/day.

## Files

| File | What |
|---|---|
| `<object>_original_rollback.sql` | Guarded rollback: refuses unless the live object is our patched build (so it can't overwrite a vendor upgrade), then the live definition as `ALTER`, same SET options; restores hash `<0x…>` exactly (rehearsed) |
| `<object>_patched.sql` | Live definition + the marked lines (reference) |
| `DEPLOY_<object>_LIVE.sql` | Guarded deploy |
| `Parity_<object>_ReadOnly.sql` | Original vs patched statement into this session's `#temp`; rows and cost (DBA-run) |
| `Verify_<object>.sql` | Read-only before/after and post-upgrade check |
| `<Vendor>_<object>.md` | Vendor note |

| Version | SHA-256 of `OBJECT_DEFINITION` |
|---|---|
| Original (live <date> → today) | `<0x…>` |
| Patched, as built | `<0x…>` |

## Deploy (DBA)

Window: <when it runs, how long; the gap to use>.

1. **Parity check:** run `Parity_<object>_ReadOnly.sql`. Pass = the same row count, and 0 rows only-original and 0 only-patched (compared with their duplicate counts), for at least one patched run.
2. **Deploy:** run `DEPLOY_<object>_LIVE.sql`. STEP 0 stops on wrong DB, hash mismatch, already patched, running now, plan guide or signature. STEP 2 shows `PATCHED`, `as built`, and the grants unchanged.
3. **Verify:** after <30–60 min>, run `Verify_<object>.sql`. Expect <after numbers>; no errors or timeouts.
4. **Rollback if needed:** `<object>_original_rollback.sql`, in the same kind of window. Its STEP 0 stops if the object is no longer exactly our patch (after a vendor upgrade, say): then don't force it, compare the live text first.

**After every <vendor> upgrade:** run section 1 of the Verify script. `original` → re-apply. `CHANGED` → rebuild from the new definition or confirm the vendor fixed it.

**Dependencies:** <indexes the hints rely on; what happens if they are dropped (FORCESEEK without a usable index = error 8622)>.

## How it was tested

- Production, read-only: <variants as SELECTs with STATISTICS IO/TIME; estimated plans>.
- Scratch database (LocalDB): rollback restores the original hash, and a second rollback stops with "Already the original"; DEPLOY passes STEP 0 and reports PATCHED / as built; a second DEPLOY stops with "Already patched"; the patched statement compiles with the production index names.
- Not run by Claude: <parity on production (writes #temp), the deploy>.
