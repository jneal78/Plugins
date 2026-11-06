# Deadlock method: reading graphs, finding history, tracing upstream

## 1. Where deadlock evidence lives, and for how long

| Source | What it holds | Reach | Read with |
|---|---|---|---|
| Performance counter `Number of Deadlocks/sec` | A cumulative count per lock type since the last restart | Since restart | 13 |
| `system_health` event files | Full graphs (`xml_deadlock_report`), shared with every other event the session records | A fixed number of small files, so **hours to days** depending on how busy the server is | 14, by full path (found automatically from the current file) |
| `system_health` ring buffer | The same, in memory | Minutes on a busy server | 15, cast once into a variable |
| A dedicated deadlock session | Graphs only | Weeks (its file size and count decide) | 14 with `@Session` |
| A monitoring product | Graphs it collected | Its retention | Export to `.xdl`, then the analyzer |
| Query Store | Executions that ended in an exception (`execution_type` 4) per statement and interval: the victim's statement | Its retention, usually weeks | 16 |
| Engine exception ring buffer | Recent error numbers, including 1205 | Minutes to hours | hotspots `09_errors_timeouts.sql` section 4 |
| Application error tables | Many applications log 1205 with their own procedure names | Their retention | Ad hoc read-only query; the site profile names the table |
| SQL Server error log | Only with trace flag 1222 or 1204 on (old practice) | Log retention | The DBA |

**Two cautions:**
- Query Store counts *all* exceptions, so read it as an upper bound per pattern. When the trend matters, check the error numbers (09) or the application's error table.
- The counter resets at a restart and a failover. Compare per-day rates, not raw counts.

## 2. Reading one graph

A graph (`<deadlock>`) has three parts.

**The victim list:** `victimProcess id=…`. SQL Server picks the process with the lowest `DEADLOCK_PRIORITY`. Between equal priorities, it picks the cheapest to roll back, which is the least log used.

**The process list** has one `process` per participant. The fields that matter:

| Attribute / element | Meaning | Why it matters |
|---|---|---|
| `executionStack/frame` | Innermost first: `procname` (db.schema.object, or `adhoc`/`unknown`), `line`, `stmtstart`, `sqlhandle`; on newer versions `queryhash`; inner text = the statement | Which code, which line, which statement |
| `inputbuf` | The batch the client sent (for a procedure: the call) | The caller and its parameter shape |
| `isolationlevel` | e.g. `read committed (2)`, `serializable (4)` | Serializable → range locks (catalog D7); usually set by the client |
| `transactionname` | `user_transaction` (explicit), `implicit_transaction` (driver autocommit off), a statement name (autocommit), `DTCXact` (distributed) | The transaction's shape (D16) |
| `trancount`, `lasttranstarted`, `lastbatchstarted` | Transaction start vs current batch start | A transaction that started before the current batch was held open by the client across round trips |
| `lockMode`, `waitresource`, `waittime` | What it is waiting for, and for how long | `KEY: db:hobt (hash)` / `PAGE: db:file:page` / `RID: db:file:page:slot` / `OBJECT: db:id` / `METADATA` / `APPLICATION` |
| `logused` | Log written so far | The cost of the rollback; large values mean long transactions |
| `priority` | Deadlock priority | Negative = a tool that volunteers to lose (D15) |
| `clientapp`, `hostname`, `loginname`, `hostpid` | Who sent it | The upstream owner. `SQLAgent - TSQL JobStep (Job 0x… : Step n)` is an Agent job (18) |
| `spid`, `ecid` | Session and execution context | The same spid on several processes means parallel threads (D13) |

**The resource list** has one element per locked resource: `keylock`, `pagelock`, `ridlock`, `objectlock`, `metadatalock`, `applicationlock`, `exchangeEvent`, `threadpool`. Each element holds:
- `objectname` and `indexname`;
- an `owner-list` saying who holds which mode;
- a `waiter-list` saying who wants which mode. `requestType="convert"` means the waiter already holds a weaker lock on the same resource and wants to strengthen it (D2).

**Lock modes in one line each:**

| Mode | Meaning |
|---|---|
| S | Shared: read |
| U | Update: read with intent to write; only one U per resource |
| X | Exclusive: write |
| IS / IU / IX | Intent locks on the parent (page, table) |
| SIX | Shared plus intent exclusive |
| Sch-S / Sch-M | Schema stability / modification |
| RangeS-S, RangeS-U, RangeI-N, RangeX-X | Key-range locks: serializable only |

**Draw the cycle:** side A holds R1 and wants R2; side B holds R2 and wants R1. If you can't say that sentence for a graph, read it again before moving on. With more than two sides it is a ring; name every link.

## 3. Mechanism tags (from Analyze-Deadlocks.ps1)

| Tag | Graph evidence | Catalog |
|---|---|---|
| `cross-object` | Locks on two or more tables | D1 |
| `conversion` | A waiter with `requestType="convert"` | D2 |
| `same-code` | Every side runs the same routine, at the same or different lines | D3 |
| `same-index` | Different code, key locks on one index of one table: two sessions on the same key, taking its rows in different orders | D3 (D2 if a waiter converts) |
| `two-indexes` | One table, two indexes | D4 |
| `page` | Page locks | D5 |
| `heap` | RID locks | D6 |
| `range` | Range modes or serializable isolation | D7 |
| `table-lock` | Object locks other than schema locks | D8 |
| `schema` | Metadata locks or Sch-S/Sch-M | D12 |
| `parallel` | Exchange or threadpool resources, or one spid on several processes | D13 |
| `applock` | Application locks | D14 |
| `low-priority` / `monitoring-tool` | Negative priority or a known tool name | D15 |
| `client-tran` / `implicit-tran` / `distributed` | Transaction shape | D16 |
| `multi-party` | More than two sessions | — |
| `agent-job` | A SQL Agent job is a side | Upstream (18) |

Four catalog entries can't be seen in a graph and need a script:
- **D9, mass rewrite:** Query Store rows per execution ≈ the table's size.
- **D10, plan flip or placeholder value:** plan changes and reads per execution at the deadlock times.
- **D11, unindexed foreign key:** 17 section 5.
- **D17, trigger inside the transaction:** a trigger in the stack, or 17 section 6.

## 4. Root cause per side

For each side of a pattern, in this order:
1. **The code.** Read the definition at the line in the graph. Use sql-query-tuning `11_definition_fingerprint.sql` for its hash and modify date (has it changed recently?). Note what the transaction did before this statement: earlier statements in the same procedure, the caller's open transaction, a trigger.
2. **The plan.** For the statement: sql-query-tuning `05_qs_object_profile.sql` and `06_plan_operators.sql`. Look for:
   - a scan where a seek was expected;
   - a key lookup;
   - an eager spool;
   - a parallel plan;
   - an implicit conversion (`10_implicit_conversions.sql`).
   
   The rows a statement *reads* decide the locks it takes, not the rows it changes.
3. **The objects.** 17 shows indexes, heaps, usage (scans vs seeks), lock waits and escalations, foreign keys, triggers and every other piece of code that references the tables.
4. **The mechanism, confirmed.** Match the graph, plan and objects to one catalog entry. When two apply, the one that removes a scan or shortens the transaction usually fixes both.

## 5. Upstream: why do the two sides meet?

| Question | How to answer it |
|---|---|
| Who sends each side? | The graph's program, host and login; hotspots `08_who_runs_it.sql` by query_hash or object, which also finds failing callers; `18_agent_jobs.sql` for job ids |
| When? | Per day and per hour from 16 (weeks) and the analyzer (the graphs held); bursts in the analyzer; job schedules and run times from 18 |
| How busy is that source at those hours? | hotspots `03_qs_hourly.sql` for the side's workload group. Also the business table that records the work (orders, messages, documents), because a burst of business work on one key looks like a burst of deadlocks |
| Why at the same moment, on the same key? | `same-code` patterns: two workers taking the same queue item, a retry after a client timeout, a double submission, redelivered messages. Check the application's settings and logs with its owner |
| What isolation and transaction shape does the client use? | The graph's isolation level and transaction name, and whether the transaction started before the batch. Serializable or held-open transactions come from the client library or framework, not the database |
| What changed? | The day the pattern started (16 by day), then hotspots `04_qs_regressions.sql` across that day, `11_definition_fingerprint.sql` modify dates, a vendor release, an index change, data growth (a table that only grows, a placeholder value that now holds millions of rows) |
| Is it a tool? | Negative priority, a monitoring product's program name, a fixed cadence of a few minutes |
| Is the victim's work lost? | Whether the application retries 1205: its error table, its logs, or the same statement succeeding seconds later in Query Store. Lost work belongs in the impact paragraph |

Write the upstream driver into the pattern's sentence, because it decides the owner. "The nightly job and the 07:00 import overlap" leads to a schedule change. "The client opens every transaction at serializable" goes to the vendor. "Two workers poll the same queue without READPAST" is a fix to the queue procedure.

## 6. Choosing the fix

Pick the smallest change at the right owner:
1. **Make one side cheaper or shorter:**
   - a seek instead of a scan (a seekable predicate, a covering `INCLUDE`, a narrow index);
   - only the rows that changed;
   - a shorter transaction.
2. **Make the order consistent:** lock the parent or anchor row first, with `UPDLOCK, HOLDLOCK` on the read that decides the write. For per-key serialization, use one `sp_getapplock` per business key.
3. **Fix the client or schedule:**
   - the isolation level (read committed instead of serializable);
   - commit sooner;
   - turn autocommit back on;
   - retry 1205;
   - move or slow a job;
   - fix or retire a monitoring check.
4. **Server or database settings** (the DBA's decision, explained with what else they change):
   - RCSI for a database whose readers deadlock with writers and whose code tolerates row versioning;
   - `LOCK_ESCALATION` for one table;
   - `MAXDOP` for one statement or database.
5. **Mitigation only:** `SET DEADLOCK_PRIORITY LOW` for a side whose work can wait, and retry logic.

Vendor code follows the site's policy (`core/safety.md`): a small in-procedure change with a rollback plus a vendor note, or a ticket only. Package anything the DBA deploys with `core/patch-package.md`.

## 7. Verifying a fix

- **Rate:** 13 now vs before (per day), allowing for the pattern's own day-to-day spread.
- **The pattern itself:** fresh graphs (14) analyzed with `-Compare <before>\deadlock_patterns.csv`. The pattern should be gone, and no new pattern should appear on the same tables. A fix that moves the conflict elsewhere shows up here.
- **Query Store:** the victim statement's failed executions (16) drop to zero, and its duration and reads per call don't rise.
- **Side effects:** waits on the new lock (`UPDLOCK`, app lock) stay short, so blocking replaced the deadlock without a cost users feel. Check `LCK_M_*` waits (13) and the statement's duration.
- **Ledger:** Done with before → after; a Watch row for vendor code that an upgrade could revert.
