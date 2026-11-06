# Who is running it, and why is it failing

Use this when a statement is costly or failing and nobody recognizes it.

## Finding the sender (script 08)

1. **Plan cache:** `sys.dm_exec_query_stats` by `query_hash` gives the `sql_handle`, the module (`objectid`) or "ad hoc / sp_executesql", plan creation and last execution times.
2. **Connections:** `sys.dm_exec_connections.most_recent_sql_handle` keeps the last batch a connection ran, *even after it failed*. Join to `sys.dm_exec_sessions` for `program_name`, `host_name`, `login_name`, `nt_user_name`, `client_interface_name` (e.g. `Microsoft SqlClient Data Provider`, `ODBC`, `jTDS`), `client_net_address`, `host_process_id`.
3. **The app's other work:** every session from the same program/host/login shows pool size and what else it runs.
4. **Audit stamps:** many business tables stamp `updated_by = SUSER_SNAME()` and a timestamp. Rows changed at the times the statement succeeded point to the login.
5. **Configuration tables and the login's creation date:** `sys.server_principals.create_date`, the database user's `create_date`, settings rows inserted on the same day, and bulk data that appeared that day (a partner table filled in one go) date when an integration was installed.
6. **The host:** `host_name` + `host_process_id` identify the Windows service. The user can check that machine's services; don't run remote commands against it yourself unless asked.

A blank `program_name` is itself a finding: ask the vendor to set `Application Name` in the connection string so the next DBA doesn't have to do this.

## Why it fails (script 09)

- Query Store execution_type 4 (exception) and 3 (aborted/timeout) per day and per object show when it started and how often.
- `RING_BUFFER_EXCEPTION` gives recent engine error numbers; join `sys.messages` for the text.
- Read the statement and the column types (`sys.columns`) of every column it touches. Most "mystery" application errors are type mismatches (precedence in `COALESCE`/`CASE`, string to number), constraint/trigger rejections, or truncation.
- Count the data that triggers it (e.g. rows where the column isn't numeric) and the data that is consequently never written. That's the impact assessment: performance is often negligible, but the business data is wrong.

## Reproducing

A read-only repro is a `SELECT` that evaluates the same expression against the same rows (e.g. `SELECT COALESCE(CAST(NULL AS bigint), col) FROM T WHERE key = 'X'`) — it raises the same error without writing. Ask before running even that on production; the user may prefer to keep evidence-only.

## Writing it up for the vendor

- Identify the product and component precisely (service name, host, login, client library), with how you know.
- Give the exact statement text and parameter types as SQL Server received them (from the plan cache or Query Store), the error, and counts per day since it started.
- Impact: records blocked, users or partners affected, exposure (how many rows could hit the same bug), CPU and log volume of the retries.
- Asks: correct the parameter types, set Application Name, back off on repeated failures, replay what failed.
