# Packaging an in-procedure fix

A patch to vendor code is only as good as its deploy and its way back. Every patch folder (`<repo>\sql\vendor_patches\<object>\`) contains the same seven files, built from the templates in `core/templates/patch/`.

| File | Purpose | Who runs it |
|---|---|---|
| `<obj>_original_rollback.sql` | Guarded rollback (below, from `ROLLBACK_TEMPLATE.sql`): STEP 0 refuses unless the live object is exactly our patched build, then the **live** definition, byte for byte, as `ALTER`, with the original `SET ANSI_NULLS` / `QUOTED_IDENTIFIER`. Restores the original hash exactly | DBA, only if needed |
| `<obj>_patched.sql` | Live definition + the marked lines (reference copy) | — |
| `DEPLOY_<obj>_LIVE.sql` | Guarded deploy (below) | DBA |
| `Parity_<obj>_ReadOnly.sql` | Original vs patched statement, patched / original / patched, rows and cost compared | DBA (it writes to `#temp`) |
| `Verify_<obj>.sql` | Read-only: version (original / patched / changed), plan cache per statement, Query Store per hour before vs after, errors and timeouts | Anyone; Claude can run it |
| `README.md` | Problem, change, measured results, variants tried, files, hashes, deploy steps, what to do after upgrades | — |
| `<Vendor>_<obj>.md` | The vendor note | Sent by the user |

## Building from the live definition

1. Pull the definition from production read-only (`OBJECT_DEFINITION`, or `sys.sql_modules.definition`) with sqlcmd `-y 0` (no truncation) or from SSMS "Script as ALTER". Don't start from source control or a vendor script: production is the truth.
2. Record its SHA-256: `CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(N'schema.obj'))), 1)`. `HASHBYTES` input is unlimited from SQL Server 2016.
3. Record `uses_ansi_nulls` and `uses_quoted_identifier` from `sys.sql_modules`; the rollback and deploy must set them the same.
4. Make the change with a marker comment on each changed line: `-- MyCo 2026-10-28: <why>`. Keep the change as small as possible.
5. Build the rollback's object text by turning `CREATE` into `ALTER` and nothing else. SQL Server stores `ALTER` text as `CREATE`, so applying the rollback restores the original hash exactly. Wrap it in the guard from `ROLLBACK_TEMPLATE.sql` (head + object text + tail, concatenated, never edited by hand). Rehearse on a scratch database (LocalDB is fine): create original → hash, deploy patch → hash, rollback → hash equals the original; then run the rollback again and check that STEP 0 stops it ("already the original").
6. Compute the patched hash after a rehearsal deploy and put both hashes in the README and the Verify script.

### Byte-exact text: the traps

The rollback only restores the hash if every byte matches. These broke exact rollbacks in practice:
- **sqlcmd adds bytes.** With `-f 65001` the output file starts with a UTF-8 byte-order mark, and sqlcmd appends a CRLF after the value. Strip both (`tail -c +4 | head -c -2` in Git Bash, or the equivalent) and check the local SHA-256 of the text encoded as UTF-16LE against the server's hash before building anything.
- **Line endings.** Vendor code is usually CRLF. Tools that normalize line endings (Git Bash `sed` without `-b`, some editors, `core.autocrlf`) silently change every line. Use binary-safe edits (`sed -b`) and keep `*.sql` files out of line-ending conversion.
- **Trailing spaces.** Some editors and editing tools trim trailing whitespace on lines they touch. Build the rollback by a binary-safe substitution of the first `CREATE` keyword only, never by editing the text by hand.
- **The header before CREATE is part of the definition.** Comment blocks above `CREATE PROCEDURE` are stored with it; keep them, or the hash changes.
- **Prove it locally:** convert the rollback body back (`ALTER` → `CREATE`) and compare it byte for byte with the captured live text before handing it over.

A deployed text that differs from the patch you built (a DBA dropped the header, say) is a different hash. Judge it by the marker and by comparing the logic, and record the deployed hash.

## The guarded deploy (STEP 0 must stop it, not warn)

```
SET LOCK_TIMEOUT 5000
-- STEP 0: build @fail; if not NULL: RAISERROR(..., 16, 1) and SET NOEXEC ON
  wrong database
  object not found
  definition already contains the marker      -> "Already patched - nothing to do"
  hash <> expected original                   -> "Live definition changed - rebuild the patch"
  the object is running right now             -> "Try again in N minutes"
                                                 (sys.dm_exec_requests CROSS APPLY dm_exec_sql_text: objectid = @obj)
  a plan guide is scoped to it                -> review first
  it is signed (sys.crypt_properties)         -> ALTER would drop the signature
  ANSI_NULLS / QUOTED_IDENTIFIER OFF          -> set STEP 1 to match first
  a trigger with first/last firing order      -> ALTER drops it; add sp_settriggerorder to STEP 2
  print server, DB, login, time, current hash, and the grants before
-- STEP 1: SET ANSI_NULLS / QUOTED_IDENTIFIER as the original; ALTER (the patched text)
-- STEP 2: print version (PATCHED / as built hash), SET options, grants after (ALTER keeps grants; show them anyway)
```

Why each guard exists: a hash check prevents overwriting a vendor change you haven't seen; "running now" avoids a schema lock wait on a hot procedure; the signature and plan-guide checks catch side effects of `ALTER` that nobody remembers.

**Deploy window:** for a scheduled procedure, list when it runs and how long it takes and name a gap. For a hot procedure, deploy at low traffic; `ALTER` waits for a schema lock, hence `LOCK_TIMEOUT`.

## The guarded rollback (STEP 0 must stop it, too)

A rollback is run rarely, often months later and under pressure, when nobody remembers what changed since. By then a vendor upgrade may have replaced the object; restoring "the original" would overwrite the vendor's new code with the pre-upgrade text. So the rollback has its own STEP 0 (`ROLLBACK_TEMPLATE.sql`):

```
  wrong database / object not found
  hash = original                             -> "Already the original - nothing to do"
  hash <> patched build and no marker         -> "Neither our patch nor the original (vendor upgrade?) - review instead"
  marker present but hash <> patched build    -> stop unless @AllowMarkedVariant = 1 after a review
  running right now / plan guide / signed     -> as in the deploy
-- STEP 1: SET options as the original; the original text with CREATE -> ALTER, byte for byte
-- STEP 2: confirm the hash equals the original; grants after
```

Put both hashes (original and patched as deployed) in it. If the DBA deployed a slightly different text (a dropped header, say), record that deployed hash as `@patched` after the deploy.

## The parity test

- Copy the procedure's exact statement twice (original and patched). If it writes to a `#temp` table, create the same `#temp` in the test session and write there. Nothing else in the procedure runs: no real tables change, nothing is sent.
- Capture CPU and reads per run from `sys.dm_exec_requests` for `@@SPID` before/after (and `SET STATISTICS TIME ON` for exact CPU including parallel workers).
- Compare rows as multisets, not sets. `EXCEPT` removes duplicates, so a patch that returns a row twice passes an `EXCEPT` test. Pass = the same row count, and 0 rows in both directions when each side is grouped by all its columns with `COUNT(*)` (a row that appears twice on one side and once on the other then shows up), against at least one patched run.
- If Claude already measured it as read-only SELECTs, put those numbers in the header so the DBA knows what to expect.

## The verify script

Read-only, no write keywords, so anyone (including Claude through the guardrail) can run it.
1. Version: `patched` if the marker is present, `original` if the hash matches, otherwise `CHANGED (upgrade?)`.
2. Plan cache per statement since compile.
3. Query Store per hour for a day before and since `modify_date`, for the statement(s) that matter, matched by text pattern or `query_hash` (the patched object gets new query_ids).
4. Errors and timeouts for the object.
5. Any business indicator that should stay the same (rows queued, messages sent).

Write the expected before/after values in its header.

## After vendor upgrades

Every patch goes on an upgrade checklist. After an upgrade, run section 1 of each Verify script:
- `original` → the upgrade restored the slow version; re-apply.
- `CHANGED` → the vendor shipped a new definition; check whether it contains the fix, otherwise rebuild the patch from the new text.

## The vendor note (`core/templates/docs/vendor_note_TEMPLATE.md`)

Short and in the vendor's terms: product, object, version header, SQL Server version and compatibility level and CE; the statement; the cause (operator, table, index, rows); evidence table (as shipped vs with hints, same rows); what we changed locally (the exact lines); the permanent fix we suggest (rewrite or an index the vendor ships); and the question "will a future release replace this object?"
