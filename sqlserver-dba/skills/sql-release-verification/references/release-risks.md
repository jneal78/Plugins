# What releases break silently

A catalog of what a release, upgrade or hot-fix can change without anyone saying so, how to see it read-only, and what to do. Check every row on a full release; on a one-object hot-fix, R1–R3, R7 and R11–R13 are enough.

| # | What happens | How you see it | What to do |
|---|---|---|---|
| R1 | **A local patch is overwritten** by the vendor's original | 22 §1 `REVERTED`; `Compare-Definitions.ps1` `MARKER LOST` | Run the patch's Verify, then the DBA re-applies the guarded deploy. Tell the vendor the fix is still needed |
| R2 | **The vendor changed an object you patched** | 22 §1 `CHANGED` | Read the new text for your fix. Absent: rebuild the patch from the new text (the old deploy refuses, as it should) |
| R3 | **A local index is gone or disabled** after the release rebuilt a table | 22 §2 `MISSING` / `DISABLED`; 19 §5 table `added` with fewer indexes | Check the vendor's indexes for the same leading keys first; otherwise the DBA re-adds it |
| R4 | **Permissions lost**: the object was removed and re-added without its grants | 19 §2 `added` with `explicit_permissions = 0` while its neighbours have some; 20 removed + added; errors 229 in 09 | DBA re-applies the permissions; ask the vendor to script them |
| R5 | **Signature lost** (module signing for cross-database or elevated access) | 19 §2 `signatures = 0` on a module that had one (11 before the release) | DBA re-signs it |
| R6 | **Forced plans or plan guides stop applying** | 22 §4 `ORPHANED` / `FAILING`, plan guide validation messages | Per the site's Query Store policy; prefer a code fix that doesn't depend on forcing |
| R7 | **A new statement scans** where the old one sought: a lookup through a non-SARGable expression, an OR join, an implicit conversion, a per-row function over a big table | 04 NEW statements ranked by CPU; 19 §4 lists the new texts | sql-query-tuning; vendor ticket with the plan operator and the one-line fix |
| R8 | **A cheap function gets called far more** (the caller now calls it per row, or for pseudo-rows) | 04 per object: function executions per caller execution, before vs after | Fix at the caller; the function's per-call cost hides it |
| R9 | **Plans change with no code change**: the deploy flushed the cache, fresh compiles sniffed different parameters, or statistics were rebuilt | 04: same `query_hash`, worse per execution, more plans | sql-query-tuning on the statement; not a reason to roll back the release |
| R10 | **Module saved with ANSI_NULLS or QUOTED_IDENTIFIER off** (the deploy tool's session settings) | 19 §2 `ansi_nulls` / `quoted_id` = 0; error 1934 in 09 | The vendor re-deploys with the right settings; the DBA can do it from the live text |
| R11 | **Constraints re-added without checking existing rows** become untrusted, and the optimizer stops using them | 19 §6 `UNTRUSTED` | DBA re-validates them in a quiet window (it reads the whole table) |
| R12 | **Triggers disabled, or firing order lost** | 19 §6 `DISABLED`, `triggers re-added` on tables with several triggers | Compare with the vendor's install notes and the site's patch notes; the DBA sets order or enables |
| R13 | **New locking**: application locks, longer transactions, a new serializable scan | Lock waits per hour after vs week ago; 13 / 16 for new deadlock patterns | sql-deadlock-analysis for a pattern; check the blocker existed before blaming the release |
| R14 | **Database settings changed** by the deploy script: compatibility level, RCSI, forced parameterization, scoped configuration, Query Store off or read-only | 19 §7 vs the site profile; 20 events on the database itself | Ask who changed it and why; most belong to the DBA, not the vendor |
| R15 | **Leftover objects**: copy tables, old procedure versions, debug tables | 19 §5 `looks like a deploy copy`; new objects in 19 §2 | Ask the vendor whether they can be removed; don't remove them yourself |
| R16 | **Application-side changes** shipped with it: connection lifetime, application name, retry and polling intervals | 08 connection ages and program names; 03 calls per hour per group | Ask the vendor; record the new values in the profile |
| R17 | **Errors during the deploy itself**: 2801 (definition changed since compile), 208 (object briefly missing), schema-lock waits | 09 / error table, inside the deploy window only | Expected; count separately. The same errors after the window are not |
| R18 | **Encrypted modules** can't be diffed | 19 §2 `encrypted`; `Compare-Definitions.ps1` `encrypted` | Judge by Query Store (19 §3, 04) and the vendor's notes; say the diff couldn't be done |
| R19 | **The vendor's fix is partial**: shipped for one call path, or with a different design than agreed | The diff vs the ticket item; 04 on every caller, not only the one in the ticket | Report item by item: shipped as proposed / shipped differently / not shipped |
| R20 | **A removed object is still called** | 20 `REMOVED`; 09 errors 208 / 2812 by object and program | The caller's owner fixes it, or the vendor restores the object |
