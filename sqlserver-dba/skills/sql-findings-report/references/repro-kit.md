# The reproduction kit: let the vendor's support engineer verify it in an hour

A vendor ticket is triaged by a level-2 support engineer who has never seen your system, has a queue of other tickets, and must reproduce the problem before anyone looks at the code. A ticket that says "procedure X is slow" waits weeks. One that comes with a kit that reproduces it on their test system, shows the bad plan and the numbers, and shows the fix doing better on the same data gets escalated the same day.

So every vendor ticket and vendor note carries a **reproduction kit**: exact steps, a ready-to-run SQL file, and the numbers we measured, so the engineer only has to run it and compare. Do as much of their work as you can: they should not have to write a single query.

## What the kit contains

| Part | What it gives the engineer | Where it comes from |
|---|---|---|
| 1. Environment fingerprint | SQL Server version and build, edition, compatibility level, cardinality estimator, MAXDOP and cost threshold, database-scoped settings, RCSI, Query Store state. Their test system must match the ones that decide the plan, or they will "not reproduce" | Section 0 of `core/templates/docs/repro_kit_TEMPLATE.sql` |
| 2. Object version | The object's SHA-256, modify date, SET options and the version header, so they test the code we run (or know that theirs differs) | Section 1 of the kit; sql-query-tuning script 11 |
| 3. Data shape | Row counts of the tables involved, statistics dates, and the distribution that drives the plan (a placeholder value that holds millions of rows, a table that only grows, an empty table). Most "can't reproduce" answers are a small test database | Section 2 of the kit; the analysis |
| 4. The statement and real parameter values | The exact statement as SQL Server receives it, its parameter types, and 2–3 parameter values that show the problem (and one that doesn't, if the problem is value-dependent) | Query Store / plan cache text; the plan's ParameterCompiledValue (sql-query-tuning 06 section 4) |
| 5. Run as shipped | The statement in a read-only form, with `SET STATISTICS IO, TIME, XML ON`, and per-run deltas of CPU, elapsed, logical and physical reads, read-ahead, waits and file I/O | Sections 3–5 of the kit |
| 6. Run with the change | The same, with our proposed hint or rewrite, so they see the improvement and the identical rows on their own system | Section 6 |
| 7. Expected results | Our numbers for both runs, the plan operator to look for (table, index, rows read vs returned), and the pass criteria | The kit's header and the ticket's table |
| 8. Their own production view | Query Store and plan-cache queries they can give other customers, to see whether the same statement costs them | Section 7 |
| 9. The plan files | The bad and good plans as `.sqlplan` (exported from Query Store or the actual-plan run), attached | sql-query-tuning 06 / SSMS |

## How to build it

1. **Start from the finished analysis.** The kit reproduces the root-cause sentence ("statement N spends X because operator O reads R rows of T per execution, since predicate P can't seek index I"). If you can't say that sentence yet, the kit isn't ready.
2. **Copy `core/templates/docs/repro_kit_TEMPLATE.sql`** next to the ticket and fill every `<...>`:
   - the statement twice (as shipped, and with the change), in its read-only SELECT form built by `core/safety.md` ("Running a SELECT version"): locking hints removed, side effects removed, same SELECT list and predicates;
   - the parameter declarations and the values that reproduce it;
   - the tables and the key column for the data-shape section;
   - our measured numbers in the header ("expected").
3. **Run it yourself first**, read-only, at a quiet moment, on the system where you measured (or a restored copy). The numbers in the ticket must come from this exact file, so the engineer's run is comparable. Keep the output file and attach it.
4. **Export the plans**: the actual plans from the run (`SET STATISTICS XML` output, saved as `.sqlplan`) or the Query Store plans (sql-query-tuning 06 / SSMS "Top Resource Consuming Queries" → plan → Save As). Name them `<object>_as_shipped.sqlplan` and `<object>_with_change.sqlplan`.
5. **Write the steps** into the ticket's "How to reproduce and verify" section (the templates have it): numbered, each with what to run and what they should see. A level-2 engineer follows steps; they don't infer them.
6. **Say what is customer data.** Parameter values (order numbers, IDs) and row counts may identify business records. Use them if the vendor's support terms allow it; otherwise describe the shape ("an order with 120 stops", "the placeholder trailer 'UNKNOWN' with 2.3M events") and give a value-agnostic way to find a matching row on their test data (a `SELECT TOP (1) ... ORDER BY COUNT(*) DESC` in the kit).

## What makes a kit fast to verify

- **Pass criteria in numbers**, not adjectives: "as shipped: about 9.4M logical reads and 2–4 s CPU per execution, Clustered Index Scan on `dbo.event`; with the change: under 100 reads, Index Seek on `IX_EVT_TMTUPDATE`, same rows".
- **One file, top to bottom**, read-only, safe on their test system and on a customer's production. It runs no procedure, writes nothing, creates no table: anyone can run it without a change ticket.
- **Deltas, not totals**: per-run CPU, reads and waits from the session's own counters (`sys.dm_exec_sessions`, `sys.dm_exec_session_wait_stats`) and file I/O from `sys.dm_io_virtual_file_stats`, read before and after each run. Server-wide totals mean nothing on a busy test server.
- **Cold and warm**: physical reads differ between the first and second run. The kit runs the as-shipped statement twice (`@Runs`), so they see both. Clearing the buffer pool is their call on their own test system, never part of the kit.
- **The operator to look at**, named with its NodeId, table, index and the actual vs estimated rows, so they open the plan and go straight to it.
- **The variants that don't work**, so they don't spend a day re-trying them.
- **Their production view**: queries to find the same statement in any customer's Query Store, ranked by CPU, so they can size the problem across their customers. Vendors prioritize what affects many customers.

A worked example (neutral names, measured numbers): `assets/example_vendor_ticket.md`.

## Where it goes in the documents

- **Vendor ticket**: section "How to reproduce and verify", between the evidence and the impact assessment. Steps in the body; the full SQL as an appendix and as an attached `.sql` file; the plans attached.
- **Vendor note** (a local patch): a shorter "Reproduce and verify" section with the same kit, so they can confirm the patch on their side before taking it into a release.
- **Analysis** for the team: a one-line pointer to the kit file, so a colleague can re-run it after an upgrade.
- **Rendered HTML/PDF**: the steps and expected-results table render as normal markdown; the kit's SQL renders as a code block (wrapped in print). Attach the `.sql` and `.sqlplan` files beside the PDF: a PDF is for reading, the files are for running.
