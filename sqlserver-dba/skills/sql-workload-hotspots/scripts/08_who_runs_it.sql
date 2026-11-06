/*  08_who_runs_it.sql  (read-only)
    Purpose : attribute a statement or object to the application that sends it: program name, host, login,
              client driver, network address and client process id, plus how many sessions that application
              holds and what it is running now. Use it before writing to a vendor ("which product is this?").
    Needs   : SQL Server 2016+, VIEW SERVER STATE.
    Params  : EDIT ME block: @QueryHash (from 02/04/09) or @Object.
    Reading : 2. Sessions whose most recent batch was the statement. They stay visible after the statement fails,
                 so this works for erroring callers too, as long as the connection is still open (pooled
                 connections usually are). A short-lived caller may need a few runs to catch.
              3. The whole footprint of those applications (every session from the same program/host/login).
              A blank or default program_name ('.Net SqlClient Data Provider', 'Microsoft SqlClient Data
              Provider', 'Core Microsoft SqlClient Data Provider', 'jTDS', 'Microsoft JDBC Driver') means the
              application does not set Application Name in its connection string: identify it by host,
              login and host_process_id (the client's process id on that host), and ask the owner to set it.
              5. When it runs (Query Store, last 48 hours by local hour): a fixed cadence suggests a scheduler or
                 polling service; business-hours shape suggests users.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 08_who_runs_it.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @QueryHash binary(8)     = NULL,              -- e.g. 0x0123456789ABCDEF
        @Object    nvarchar(300) = N'dbo.SomeProc';   -- used when @QueryHash is NULL
---------------------------------------------------------------------------------------------------------------------

DECLARE @oid int = CASE WHEN @QueryHash IS NULL THEN OBJECT_ID(@Object) END;
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());

-- 1. Plan-cache entries (which module or ad hoc batch carries it)
SELECT TOP (20) CONVERT(varchar(16), qs.creation_time, 120) AS plan_created, CONVERT(varchar(19), qs.last_execution_time, 120) AS last_exec,
       qs.execution_count, CAST(qs.total_worker_time / 1000.0 / qs.execution_count AS decimal(14,2)) AS avg_cpu_ms,
       ISNULL(OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid), N'(ad hoc / prepared)') AS module,
       DB_NAME(t.dbid) AS db, CONVERT(varchar(20), qs.query_hash, 1) AS query_hash,
       LEFT(REPLACE(REPLACE(REPLACE(SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
WHERE (@QueryHash IS NOT NULL AND qs.query_hash = @QueryHash)
   OR (@oid IS NOT NULL AND t.objectid = @oid AND t.dbid = DB_ID())
ORDER BY qs.last_execution_time DESC;

-- 2. Sessions whose most recent batch is the statement or object
;WITH h AS (
    SELECT DISTINCT qs.sql_handle
    FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
    WHERE (@QueryHash IS NOT NULL AND qs.query_hash = @QueryHash)
       OR (@oid IS NOT NULL AND t.objectid = @oid AND t.dbid = DB_ID())
),
c AS (
    SELECT c.session_id, c.client_net_address, c.net_transport, c.auth_scheme, c.most_recent_sql_handle
    FROM sys.dm_exec_connections c
    OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
    WHERE c.session_id <> @@SPID AND (c.most_recent_sql_handle IN (SELECT sql_handle FROM h)
       OR (@oid IS NOT NULL AND t.dbid = DB_ID() AND t.objectid = @oid)
       OR (@oid IS NOT NULL AND t.text LIKE N'%' + OBJECT_NAME(@oid) + N'%'))
)
SELECT s.session_id, s.program_name, s.host_name, s.host_process_id, s.login_name, s.nt_user_name,
       s.client_interface_name, s.client_version, c.client_net_address, c.net_transport, c.auth_scheme,
       s.status, s.open_transaction_count, DB_NAME(s.database_id) AS db,
       CONVERT(varchar(19), s.login_time, 120) AS login_time, CONVERT(varchar(19), s.last_request_end_time, 120) AS last_request_end,
       CASE WHEN ISNULL(s.program_name, N'') = N'' OR s.program_name IN (N'.Net SqlClient Data Provider', N'Microsoft SqlClient Data Provider',
                 N'Core Microsoft SqlClient Data Provider', N'jTDS', N'Microsoft JDBC Driver for SQL Server')
            THEN 'default program_name: ask the owner to set Application Name' ELSE '' END AS note
FROM c JOIN sys.dm_exec_sessions s ON s.session_id = c.session_id;

-- 3. Footprint of those applications: every session from the same program / host / login
;WITH h AS (
    SELECT DISTINCT qs.sql_handle
    FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
    WHERE (@QueryHash IS NOT NULL AND qs.query_hash = @QueryHash)
       OR (@oid IS NOT NULL AND t.objectid = @oid AND t.dbid = DB_ID())
),
src AS (
    SELECT DISTINCT s.program_name, s.host_name, s.login_name
    FROM sys.dm_exec_connections c
    JOIN sys.dm_exec_sessions s ON s.session_id = c.session_id
    OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
    WHERE c.session_id <> @@SPID AND (c.most_recent_sql_handle IN (SELECT sql_handle FROM h)
       OR (@oid IS NOT NULL AND t.dbid = DB_ID() AND t.objectid = @oid)
       OR (@oid IS NOT NULL AND t.text LIKE N'%' + OBJECT_NAME(@oid) + N'%'))
)
SELECT ISNULL(s.program_name, N'') AS program_name, s.host_name, s.login_name, COUNT(*) AS sessions,
       SUM(CASE WHEN s.status = 'sleeping' THEN 1 ELSE 0 END) AS sleeping,
       COUNT(DISTINCT ISNULL(s.host_process_id, 0)) AS client_processes,
       MIN(CONVERT(varchar(19), s.login_time, 120)) AS oldest_login,
       MAX(CONVERT(varchar(19), ISNULL(s.last_request_end_time, s.login_time), 120)) AS latest_request,
       CAST(SUM(s.cpu_time) / 60000.0 AS decimal(12,1)) AS session_cpu_min_since_login
FROM sys.dm_exec_sessions s
JOIN src ON src.program_name = s.program_name AND src.host_name = s.host_name AND src.login_name = s.login_name
WHERE s.session_id <> @@SPID
GROUP BY s.program_name, s.host_name, s.login_name;

-- 4. Running right now
SELECT r.session_id, s.program_name, s.host_name, s.login_name, r.status, r.wait_type, r.blocking_session_id,
       DATEDIFF(SECOND, r.start_time, GETDATE()) AS running_s, r.cpu_time / 1000 AS cpu_s, r.logical_reads, r.dop
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id <> @@SPID
  AND ((@QueryHash IS NOT NULL AND r.query_hash = @QueryHash) OR (@oid IS NOT NULL AND t.objectid = @oid AND t.dbid = DB_ID()));

-- 5. When it runs: Query Store, last 48 hours by local hour (calls and failures)
SELECT CONVERT(varchar(13), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120) AS hour_local,
       SUM(rs.count_executions) AS stmt_execs,
       SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
       SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 60e6 AS decimal(9,2)) AS cpu_min
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE i.start_time >= DATEADD(HOUR, -48, GETUTCDATE())
  AND ((@QueryHash IS NOT NULL AND q.query_hash = @QueryHash) OR (@oid IS NOT NULL AND q.object_id = @oid))
GROUP BY CONVERT(varchar(13), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120)
ORDER BY hour_local;
