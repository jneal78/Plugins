# Safety rules for production analysis

The value of this work depends on trust: the DBA lets Claude look at production because Claude never changes it. Keep that trust cheap to verify.

## What Claude may run on production

- `SELECT` against DMVs, catalog views, Query Store views and (with `NOLOCK` / `READ UNCOMMITTED`, narrowly filtered) business tables.
- `DECLARE`, `SET` session options, CTEs, `WAITFOR DELAY` (for a timed delta).
- `SET STATISTICS IO, TIME ON` and `SET SHOWPLAN_XML ON` around a read-only `SELECT` version of a statement, built by the rules in the next section.

## Running a SELECT version of an application statement

Tuning and parity work runs copies of real statements as SELECTs. A SELECT is not harmless just because it doesn't write: copied as-is it keeps the original's locking hints and side effects, and the statements being tuned are by definition the expensive ones. Before running one on production:

1. **Remove locking hints** that change the locks a read takes: `UPDLOCK`, `XLOCK`, `HOLDLOCK`, `SERIALIZABLE`, `REPEATABLEREAD`, `TABLOCK`, `TABLOCKX`, `PAGLOCK`, `READPAST`. A copied `WITH (UPDLOCK, HOLDLOCK)` scan holds update and range locks for the whole statement and blocks every writer on the table. **Keep** the hints that shape the plan you are testing: `FORCESEEK`, `INDEX(...)`, join hints and `OPTION (...)`. Remove the locking hints from every variant, so they stay comparable.
2. **Remove side effects.** Drop the target, `INTO` and `OUTPUT` clauses. Replace `NEXT VALUE FOR` with a constant, because a SELECT still consumes sequence numbers. If the statement calls a function that isn't plain T-SQL (CLR, a wrapper around an extended procedure, anything that can send mail or call out), don't run it: use the estimated plan, or ask the DBA to test on a copy.
3. **Cap your own impact.** Start the batch with `SET LOCK_TIMEOUT 5000; SET DEADLOCK_PRIORITY LOW;`, so the test gives up after 5 seconds of waiting for a lock and is always the deadlock victim, never the application. Keep the default isolation level, the same for every variant.
4. **Estimate before you execute.** Read the estimated plan first (`SET SHOWPLAN_XML ON`, which executes nothing) and the statement's recent cost in Query Store. If one execution costs more than about 10 seconds or a few million reads, don't run it on production: say so, and test on a restored copy or ask the DBA.
5. **Say what you're about to spend,** run at a quiet moment, and pass a sqlcmd timeout (`-t`) that covers the expected duration with margin.

## What Claude never runs on production

- DML or DDL of any kind, including `#temp` tables, table variables filled by `INSERT`, `SELECT ... INTO`, `EXEC` of procedures (a procedure may write, send mail, or call out), `sp_query_store_*` procedures, `DBCC` commands that change state, `KILL`.
- Query Store configuration, plan forcing, Query Store hints, automatic tuning.
- Anything that redirects a connection string or changes a setting.

When a test genuinely needs a write (a parity test that fills the procedure's own `#temp` table, a deploy, a rollback), Claude writes the script and the DBA runs it.

## Guardrail hooks

Many shops run a hook that blocks shell commands containing write keywords next to a production server name, and some scan the script being run. Work with it:
- Put the SQL in a `.sql` file and keep the command line to `sqlcmd -S <server> -d <db> -E -I -W -s"|" -i <file> -o <file>`.
- The bundled scripts contain no write keywords, even in comments. Keep it that way when you edit a copy (don't paste `INSERT` into a comment or a `LIKE` pattern; match on another part of the text).
- If a command is blocked: don't retry, don't rename, don't split the keyword. Tell the user what you were trying to read and let them run it.

Known false positives, so you recognize them (still hand them over; never work around them):
- a write word inside a `LIKE` pattern or a comment of an otherwise read-only query;
- a .NET call such as `[SHA256]::Create()` or a file opened in `Create` mode, in the same command as a production server name;
- a text-processing command (`sed`, `awk`) that edits a script containing `ALTER` or `CREATE`, run next to a server name;
- JavaScript in a page you are building (`clipboard.writeText`).

Separate the local step from the server step when you can (capture the definition in one command, hash or edit it locally in another), and ask the user before running each half.

## Keep your own footprint small

Read-only can still hurt a busy server. These came from real incidents:
- **Always pass a query timeout** (`sqlcmd -t 60`, or longer only for a known slow read). A runaway read is cancelled instead of burning CPU for minutes.
- **Never shred an XML ring buffer inside a CTE.** The cast is re-evaluated for every node and can take minutes of CPU. Cast the target data into an `xml` variable once, then shred the variable. Extended-event file targets (`sys.fn_xe_file_target_read_file` with the full path) are cheaper for anything older than a few minutes.
- **Don't join DMVs to large user tables in one query.** The optimizer has no statistics for DMVs and can pick a plan that scans the user table once per session row. Read the user-table part separately (one range query, or build a short comma list into a variable) and combine.
- **Benchmark on a quiet moment** and say the CPU you're about to spend before running an expensive read-only statement on production.
- **Sampling loops** (a sampler every minute during a batch) must be bounded: a stop time, and a stop condition when the work ends.

## sqlcmd practicalities (Windows)

- Use Windows paths (`C:\...`) or relative paths for `-i` / `-o`. An msys `/c/...` path is misread as a switch.
- `-W` (trim) and `-y` (fixed width) can't be combined; `-h -1` drops headers; `-I` turns on quoted identifiers, which XML methods need.
- Long text columns get truncated; select `LEFT(...)` of statement text with CR/LF/TAB replaced. Without `-y 0`, `(max)` columns are cut at 256 characters: cast to a sized type (`varchar(4000)`) when you need the whole value in `-W` output.
- `-v name=value` rejects drive paths and some punctuation; put such values in the script (a filled scratch copy) instead.
- To capture a definition byte for byte, use `-y 0 -f 65001` and strip the UTF-8 byte-order mark and the trailing CRLF that sqlcmd adds (see `patch-package.md`).

## The Query Store policy is a site setting

The site profile's `Query Store forcing / hints` line decides. When the profile doesn't say, use the **code-first default**: fix in the code first (in-procedure hint, small rewrite, caller fix, prefixed index); recommend plan forcing or a Query Store hint only as a stated alternative that needs the DBA's approval, never as the main fix. Some sites set "never"; some allow forcing with approval. Don't assume.

The reasoning behind code-first is worth knowing:
- A forced plan or Query Store hint is invisible in the code. The vendor can't see it, it doesn't show up in a code review, and the next upgrade can silently invalidate it (forcing fails quietly when the plan can no longer be produced).
- A hint or small rewrite inside the procedure is visible, versioned, testable, carries a marker comment and a hash, and can be sent to the vendor for inclusion.
- Raising Query Store's *size* (`MAX_STORAGE_SIZE_MB`, `max_plans_per_query`) is capacity, not behavior, and is fine to recommend.

## Who deploys

The DBA. Every recommendation names the script and the window to run it in. Claude never claims something is deployed until it has seen the evidence (the definition's marker or hash, a new `modify_date`, the new plan's cost in Query Store).

## Outside the database server

Some diagnoses need data from other machines (application servers, terminal or virtual-desktop session hosts). Claude usually has no rights there and shouldn't seek them:
- Write a read-only collector the host's admin can run, test it locally first under the shell they will use (Windows PowerShell 5.1 as well as PowerShell 7), and make it tolerate missing or invalid counters rather than stop.
- Have it run for a duration, not until a clock time: the host may be in another time zone. Have it write UTC timestamps.
- Never download or run tools on someone else's machine yourself; give the admin the steps.
