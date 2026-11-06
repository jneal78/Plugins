# Deadlock pattern catalog

Each entry gives:
- **Signature:** what the graph shows (the analyzer's tags);
- **Root cause:** why the locks cross;
- **Upstream:** what brings the two sides together;
- **Evidence:** what proves it (scripts);
- **Fix:** smallest first;
- **Owner;**
- **Seen:** a measured case, where one exists.

Script numbers refer to this plugin: 13–18 are in this skill, 03/04/08/09 in sql-workload-hotspots, 05/06/10/11/12 in sql-query-tuning. Fix patterns in `core/fix-catalog.md` are cited as "fix catalog §n".

---

## D1. Lock order across tables (`cross-object`)

- **Signature:** two sides, two tables. A holds a lock on T1 and wants T2; B holds T2 and wants T1.
- **Root cause:** two code paths change the same pair of tables in opposite order inside one transaction. It is often hidden: a trigger on T1 writes T2, while another procedure writes T2 and then T1.
- **Upstream:** which two processes run together (a job and an interactive save; two integrations); whether a trigger adds the second table (stack, 17 §6); 17 §7 lists every other piece of code that touches both tables.
- **Evidence:** both definitions at the graph's lines and what each did earlier in the transaction; the stack (`frames`); 17.
- **Fix:**
  1. Take the locks in one order everywhere. Usually that means locking the parent or anchor row first with `UPDLOCK, HOLDLOCK` on a read at the start of the transaction.
  2. Shorten the transaction: move reads and lookups before `BEGIN TRAN`.
  3. If one side scans, make it seek (D5). Fewer locks means fewer crossings.
- **Owner:** whoever owns the code; a vendor note when the two paths are vendor code.

## D2. Read, then write the same row (`conversion`)

- **Signature:** both sides hold S (or U) on the same key or page and wait to convert to X (`requestType="convert"`). It is often the same code on both sides.
- **Root cause:** a check-then-act under read committed: `IF EXISTS (SELECT …) UPDATE … ELSE INSERT …`, or `SELECT` a value then change it. Two sessions both read and both try to write.
- **Upstream:** concurrency on one key (D3 questions); an application that saves an entity twice.
- **Evidence:** the code at the line; the read before it in the same transaction.
- **Fix:**
  - `WITH (UPDLOCK, HOLDLOCK)` on the read that decides the write (one session waits instead of both deadlocking);
  - or do it in one statement: an update that checks `@@ROWCOUNT`, then an insert guarded by a unique key with retry on duplicate.
  - Avoid a single upsert statement without `HOLDLOCK`: it has the same race.
- **Owner:** the code owner.

## D3. The same routine twice on one key (`same-code`)

- **Signature:** every side runs the same procedure or statement (sometimes at different lines of it), on the same table, key locks. The deadlocks often come in bursts.
- **Root cause:** two sessions process the same business key (document, order, message) at the same moment. Each locks that key's rows in a different order, usually the order the client sent them vs index order, or a read on one index and a write on another.
- **Upstream:** this is the important part. Why are there two concurrent requests for one key?
  - two workers taking the same queue item without `READPAST`/`UPDLOCK`;
  - a client retry after a timeout while the first call is still running;
  - double submission from a UI;
  - redelivered messages;
  - a batch that splits work so two threads share keys.
  
  Check the owner's worker count and retry settings; check the business key in the graphs' wait resources (the same key hash on both sides).
- **Evidence:** the definition; the business key (parameters in `inputbuf`, or the wait resource hash); timing bursts in the analyzer; the victim's statement history (16).
- **Fix:**
  - serialize per key inside the procedure: `UPDLOCK, HOLDLOCK` on the parent row or a history/existence check, or `sp_getapplock` on the key, taken before the rows are touched;
  - or have the client stop sending concurrent work for one key.
  
  Prove the extra wait is short (lock waits, the statement's duration).
- **Owner:** the code owner for the lock; the application owner for the concurrency.
- **Seen:** two workers saving the same document. One saves the document's fields in the order the client sent them, the other in key order; every plan seeks, so only the same document collides. About 4 a day, 5–20 at peaks. Fix: `UPDLOCK, HOLDLOCK` on the document's existence check, so one save per document at a time. It also stopped duplicate first-save inserts.

## D4. Two indexes of one table: lookup vs write (`two-indexes`)

- **Signature:** one table, locks on its clustered index and a nonclustered index. The reader holds S on the nonclustered key and wants S on the clustered key; the writer holds X on the clustered key and wants X on the nonclustered key.
- **Root cause:** the reader seeks a nonclustered index, then looks up columns it doesn't cover (a key lookup). The writer changes the row (clustered first), then the index entry.
- **Upstream:** a frequent reader (a screen or an API poll) against a busy writer.
- **Evidence:** a key lookup in the reader's plan (06); `user_lookups` in 17 §3; the columns the reader needs that the index lacks.
- **Fix:**
  - make the index cover the reader (`INCLUDE` the looked-up columns: fix catalog "Index as the last resort", sql-query-tuning 12 to check an existing index first);
  - or have the reader use a snapshot-based read for that query when the application tolerates it.
- **Owner:** DBA (index) or the code owner (hint).

## D5. A scan under page or row locks meets writers (`page`, or scans in 17)

- **Signature:** page locks, or many key locks on one table, with an S or U lock from a statement that reads far more rows than it needs. The other side is an ordinary writer.
- **Root cause:** a predicate that can't seek, for example:
  - a function on the column;
  - a converted key (fix catalog §14);
  - a leading-wildcard `LIKE`;
  - an OR across columns (§5);
  - an implicit conversion (§6);
  - a per-row function called from a job.
  
  The scan takes shared locks across the table while writers change rows inside it.
- **Upstream:** who runs the scanner and how often. It is often a job, a report, a polling feed or a monitoring check.
- **Evidence:** the scan in the plan (06) and its reads per call (05); `user_scans` and page-lock waits (17); the predicate.
- **Fix:**
  - make it seek: add a seekable test next to the original one, so the result can't change (fix catalog §14);
  - hoist the expression (§4);
  - fix the parameter type (§6);
  - for a count in a monitoring check only, read uncommitted.
- **Owner:** the code owner.
- **Seen:**
  - A lookup function compared `CONVERT(varchar, int_key)` to a string, scanning a 7,000-page table for every row a job processed, under shared page locks. The application's status updates deadlocked with it. The seekable test cut it to 7 reads per call, about 96 CPU-min a day saved, and the deadlocks stopped.
  - A monitoring count with a leading wildcard scanned a message table every few minutes (see D15).

## D6. A heap used as a queue (`heap`)

- **Signature:** RID locks on a table with no clustered index. A producer adds rows while a consumer removes or updates rows by key.
- **Root cause:** with no index, every keyed operation scans the heap under RID and page locks, so producer and consumer cross.
- **Upstream:** the queue's producer (an application, a trigger) and consumer (a service polling it).
- **Evidence:** 17 §2 shows `(heap)` with no nonclustered index on the key; `user_scans` keeps climbing.
- **Fix:** a clustered index on the key the consumer uses, with a site prefix and `ONLINE` where the edition allows, plus a rollback (fix catalog §16).
- **Owner:** DBA, with a vendor note.
- **Seen:** an outbound message queue. Each removal scanned 114 pages; with the index it reads 2 pages, and the deadlocks stopped.

## D7. Serializable range locks (`range`)

- **Signature:** `RangeS-S`, `RangeS-U`, `RangeI-N` or `RangeX-X` modes; isolation `serializable`. It can happen on a table with **no rows**.
- **Root cause:** the session runs at serializable, so every read locks the range it examined, including the gap at the end of an empty index. Concurrent inserts into that range then cross. The database code rarely asks for this. The client does: .NET `TransactionScope` defaults to serializable, and some frameworks and ODBC settings do too.
- **Upstream:** the program in the graph, its framework and its connection settings.
- **Evidence:** the isolation level in the graph for every side that holds range locks; the procedures don't contain `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` (check the definition); an empty or tiny table scanned by a trigger or existence check.
- **Fix:** at the source, so the client uses read committed (`TransactionScope` with explicit `IsolationLevel.ReadCommitted`), or snapshot. A local guard can help: an `IF EXISTS` with a seekable predicate, or skipping the check when the table is empty (fix catalog §18). This is usually vendor code: write it up rather than patch it.
- **Owner:** the client application's vendor.
- **Seen:** a vendor client at serializable, whose triggers and deletes checked an empty child table. The scan took a range lock on the end of the index, which every concurrent writer then needed. Filed with the vendor; no local patch.

## D8. Lock escalation or table locks (`table-lock`)

- **Signature:** object-level S, X, IX or SIX locks (not Sch-*); one side holds a table lock.
- **Root cause:**
  - a statement took more than about 5,000 locks on one table and escalated to a table lock;
  - or the code uses `TABLOCK`/`TABLOCKX`;
  - or `PAGLOCK` plus escalation.
- **Upstream:** a large batch (purge, archive, nightly recalculation) running during interactive hours.
- **Evidence:** `escalations` > 0 in 17 §4; the statement's rows per execution in Query Store (05); hints in the code.
- **Fix:**
  - work in chunks below the escalation threshold;
  - an index so the statement touches fewer rows;
  - move the batch out of busy hours.
  
  `ALTER TABLE … SET (LOCK_ESCALATION = …)` is the DBA's call and affects every statement on that table.
- **Owner:** the code or job owner.

## D9. A job that rewrites far more rows than change (graph: one side is a job or batch; evidence elsewhere)

- **Signature:** one side is a scheduled job's update touching the whole table (long X locks, large `logused`); the other side is the application's interactive writes.
- **Root cause:** the job sets every row to a value most rows already have. A changed-rows filter is missing or commented out, or the job joins on a grouping key and multiplies the rows.
- **Upstream:** the job and its schedule (18); its cadence vs the application's busy hours.
- **Evidence:** Query Store rows per execution ≈ the table's row count (05); a read-only count of rows that would actually change (often 0).
- **Fix:** write only changed rows with a NULL-safe test, and join on the row key (fix catalog §15). Check triggers, CDC and rowversion consumers that relied on every row being touched.
- **Owner:** the job owner.
- **Seen:** an hourly job rewrote about 528K rows to change almost none, holding exclusive locks while users saved. The fix wrote 0 rows on a typical run.

## D10. A short statement that turns long: plan flip or placeholder value (evidence elsewhere)

- **Signature:** a statement that normally takes milliseconds (often in a trigger) appears in deadlocks with high `waittime` and `logused`. The deadlocks cluster on particular rows or after a statistics update.
- **Root cause:**
  - a plan flip, where the nightly recompile chose a scan;
  - or a catch-all value ("unknown", 0, blank) that millions of rows carry, so estimates of 1 row meet millions, and the long scan holds update locks while users save.
- **Upstream:** which business rows carry the placeholder; when statistics are updated.
- **Evidence:** plan changes and reads per execution at the deadlock hours (05, 04); the row counts per value.
- **Fix:** an in-procedure hint that keeps the plan starting from the small driving set (`FORCE ORDER, LOOP JOIN`), plus a guard that skips the statement when its `WHERE` can't match (fix catalog §17, §2).
- **Owner:** the code owner (vendor note for vendor code).
- **Seen:** a cleanup statement in a trigger read 9.4M rows for the placeholder value. After the fix it read 33 rows, and the deadlocks between users of that screen stopped.

## D11. Unindexed foreign key (evidence: 17 §5)

- **Signature:** a parent row removal or key change on one side; the other side changes the child table. Locks on the child table come from the parent's statement (the check scans the child).
- **Root cause:** the foreign key's child column doesn't lead an index, so each parent change scans the child table to check references or cascade.
- **Evidence:** 17 §5 says `NO`; the parent statement's plan scans the child (06).
- **Fix:** an index leading on the foreign key column(s) (site prefix, rollback).
- **Owner:** DBA, with a vendor note.

## D12. Schema locks (`schema`)

- **Signature:** metadata or object locks in Sch-S and Sch-M modes, often on temp tables or the tables of one database. One side is frequently a monitoring tool listing objects, a statistics or index job, or code that creates and drops tables.
- **Root cause:**
  - DDL (create, drop or alter a table, including temp tables whose metadata is cached), statistics updates or online index operations need Sch-M;
  - a metadata query or compile needs Sch-S, and they cross with ordinary locks.
- **Upstream:** the tool or job and its cadence; the code that creates temp tables in a trigger or procedure.
- **Evidence:** the program on each side; the object (temp table names show as `#…` with a suffix).
- **Fix:**
  - the tool: turn off or slow its object collection;
  - the job: move it out of busy hours, or use `WAIT_AT_LOW_PRIORITY` for online index work;
  - the code: avoid DDL inside hot transactions.
- **Owner:** the tool's admin, the job owner, or the code owner.
- **Seen:** a monitoring product's tempdb object listing (at deadlock priority −5) against application triggers' cached temp tables. The tool always lost. It's an admin setting.

## D13. Intra-query parallelism (`parallel`)

- **Signature:** `exchangeEvent` or `threadpool` resources; several processes with the same spid and different `ecid`. Sometimes the only real session is one.
- **Root cause:** one parallel plan's threads wait on each other (or, with threadpool, on workers that aren't free). It is a plan problem, usually a big scan that went parallel.
- **Evidence:** the statement's plan (06), its degree of parallelism and reads.
- **Fix:**
  - make the statement cheap enough not to go parallel (an index, a seekable predicate);
  - or `OPTION (MAXDOP 1)` for that statement.
  
  Server-wide `MAXDOP` and cost threshold are the DBA's call (fix catalog §13).
- **Owner:** the code owner.

## D14. Application locks taken out of order (`applock`)

- **Signature:** `applicationlock` resources, sometimes mixed with key locks.
- **Root cause:** `sp_getapplock` resources taken in different orders by two paths, or an app lock taken after row locks that another path takes after the app lock.
- **Fix:** take app locks first, in a fixed order (sort the keys), at transaction scope; never take one after row locks that another path acquires inside the same app lock.
- **Owner:** the code owner.

## D15. Monitoring and maintenance tools (`low-priority`, `monitoring-tool`)

- **Signature:** one side has negative deadlock priority or a monitoring product's program name, and it is (almost) always the victim. It often runs on a fixed cadence.
- **Root cause:** the check reads hot tables with locks (a count, a "stuck messages" query, an object listing) and crosses with application writes.
- **Upstream:** the tool, the check and its interval; whether anyone acts on its alert.
- **Evidence:** the program name, the statement, its cadence (hotspots 08 §5), and reads per run (05).
- **Fix:** rewrite the check (read uncommitted for a count, a seekable date test, a lower bound), slow it, or retire it if nobody acts on it (fix catalog §19). Count these deadlocks separately from application deadlocks.
- **Owner:** the monitoring admin.
- **Seen:** a message-stuck check scanned the message table every few minutes. The rewrite cut it from 16K to 2.3K reads with no shared locks; in the end the alert was retired.

## D16. Transactions held open by the client (`client-tran`, `implicit-tran`, `distributed`)

- **Signature:**
  - `lasttranstarted` earlier than `lastbatchstarted`;
  - or `transactionname="implicit_transaction"`;
  - or `DTCXact`.
  
  Often combined with D1, D2 or D7. The victim has a large `logused` and a long-running transaction.
- **Root cause:** the client opens a transaction and makes several round trips (or waits for a user, a web call or a file) before committing, so the locks from early statements last much longer than the statements did. Autocommit off (some JDBC and ODBC settings, ORMs) puts every read inside an open transaction.
- **Upstream:** the client library and its settings; the code path that spans round trips.
- **Evidence:** the graph's transaction fields; `open_transaction_count` and `last_request_end_time` of the program's sleeping sessions (hotspots 08 §2–3).
- **Fix:** commit before waiting on anything outside the database; autocommit on; read committed instead of a framework default of serializable. This is client work.
- **Owner:** the application owner or vendor.

## D17. Triggers that extend the transaction (evidence: stack and 17 §6)

- **Signature:** a trigger in a side's stack (an extra frame above the statement that fired it), or a trigger listed on a locked table.
- **Root cause:** the trigger runs inside the writer's transaction and touches more tables, so the writer holds locks on tables it never named, in an order other code paths don't expect (D1), or it scans (D5, D10).
- **Fix:** make the trigger's statements seek and touch only the affected rows (join `inserted`/`deleted` on the key); move work that doesn't need to be transactional out of the trigger (a queue the application drains).
- **Owner:** the code owner.

---

## Settings that change deadlock behavior (the DBA's call)

| Setting | Helps | Doesn't help | Costs |
|---|---|---|---|
| Read-committed snapshot (RCSI) per database | Readers vs writers (D4, D5 reads, D15 counts) | Writers vs writers (D1, D2, D3, D6, D7, D9) | Version store in tempdb; changes what readers see for all code (semantics must be reviewed, especially vendor code) |
| Snapshot isolation, per session | The same, only where a session asks for it | Same | Update conflicts (error 3960) instead of deadlocks |
| `LOCK_ESCALATION` per table | D8 | — | More locks in memory |
| `DEADLOCK_PRIORITY` per session | Chooses the victim (tools, batch work) | The deadlock itself | — |
| Retry on 1205 in the client | The user-facing effect | The cause | Repeated work |
