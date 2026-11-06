/*  09_errors_timeouts.sql  (read-only)
    Purpose : failing statements. Query Store counts executions that ended in a client abort (execution_type 3,
              almost always a command timeout) or an exception (type 4) per statement and interval; this script
              trends them by day, ranks the statements and objects behind them, and lists the error numbers the
              engine raised recently.
    Needs   : SQL Server 2016+, Query Store on, VIEW DATABASE STATE and VIEW SERVER STATE (section 4).
    Params  : EDIT ME block.
    Reading : Query Store does not keep error numbers or messages, only that the execution failed. Section 4 reads
              the engine's exception ring buffer (recent exceptions only, every database, including some that
              the engine raises and handles internally; one failure is often recorded several times as it
              passes up the call stack, so compare trends, not counts), and match by timing and statement text:
              e.g. 8114 / 245 / 8115 = conversion errors (a typed parameter against a varchar column),
              1205 = deadlock victim, 2627 / 2601 = duplicate key, 547 = constraint, 3621 = statement ended.
              A statement that fails thousands of times a day with no CPU cost is still worth a ticket: its work
              is not being done (the data stays stale), and the application usually retries forever.
              Timeouts are where users feel slowness: rank them before CPU when someone reports "it hangs".
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 09_errors_timeouts.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Days   int           = 7,      -- history to scan
        @Object nvarchar(300) = NULL,   -- optional: one object only
        @TopN   int           = 20;
---------------------------------------------------------------------------------------------------------------------

DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
DECLARE @d0 datetime = DATEADD(MINUTE, -@off, DATEADD(DAY, -@Days, CAST(CAST(GETDATE() AS date) AS datetime)));
DECLARE @oid int = OBJECT_ID(@Object);

-- 1. By local day: executions, timeouts, errors
SELECT CONVERT(varchar(10), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120) AS day_local,
       SUM(rs.count_executions) AS stmt_execs,
       SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
       SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors,
       CAST(SUM(CASE WHEN rs.execution_type = 3 THEN rs.avg_duration * rs.count_executions ELSE 0 END) / 60e6 AS decimal(12,1)) AS minutes_spent_before_timeout
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE i.start_time >= @d0 AND (@oid IS NULL OR q.object_id = @oid)
GROUP BY CONVERT(varchar(10), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120)
ORDER BY day_local;

-- 2. Statements behind them (one row per query_hash), worst first
;WITH s AS (
    SELECT q.query_hash, MAX(q.query_id) AS query_id, MAX(q.query_text_id) AS query_text_id,
           MAX(CASE WHEN q.object_id = 0 THEN N'(ad hoc)'
                    ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END) AS obj,
           SUM(CASE WHEN rs.execution_type = 0 THEN rs.count_executions ELSE 0 END) AS ok,
           SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
           SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors,
           CAST(AVG(CASE WHEN rs.execution_type = 3 THEN rs.avg_duration END) / 1e6 AS decimal(9,1)) AS avg_s_at_timeout,
           MIN(CASE WHEN rs.execution_type IN (3, 4) THEN i.start_time END) AS first_fail,
           MAX(CASE WHEN rs.execution_type IN (3, 4) THEN i.start_time END) AS last_fail,
           COUNT(DISTINCT CASE WHEN rs.execution_type IN (3, 4) THEN CAST(i.start_time AS date) END) AS days_failing
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE i.start_time >= @d0 AND (@oid IS NULL OR q.object_id = @oid)
    GROUP BY q.query_hash
    HAVING SUM(CASE WHEN rs.execution_type IN (3, 4) THEN rs.count_executions ELSE 0 END) > 0
)
SELECT TOP (@TopN) s.obj, s.query_id, CONVERT(varchar(20), s.query_hash, 1) AS query_hash,
       s.errors, s.timeouts, s.ok,
       CAST(100.0 * (s.errors + s.timeouts) / NULLIF(s.errors + s.timeouts + s.ok, 0) AS decimal(5,1)) AS fail_pct,
       s.avg_s_at_timeout, s.days_failing,
       CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(s.first_fail AS datetime)), 120) AS first_fail_local,
       CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(s.last_fail AS datetime)), 120) AS last_fail_local,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM s JOIN sys.query_store_query_text t ON t.query_text_id = s.query_text_id
ORDER BY s.errors + s.timeouts DESC;

-- 3. Today by local hour for the top 5 failing statements of the last day (is it constant, or tied to a schedule?)
;WITH top5 AS (
    SELECT TOP (5) q.query_hash
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE i.start_time >= DATEADD(DAY, -1, GETUTCDATE()) AND rs.execution_type IN (3, 4) AND (@oid IS NULL OR q.object_id = @oid)
    GROUP BY q.query_hash
    ORDER BY SUM(rs.count_executions) DESC
)
SELECT CONVERT(varchar(20), q.query_hash, 1) AS query_hash,
       CONVERT(varchar(13), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120) AS hour_local,
       SUM(CASE WHEN rs.execution_type = 0 THEN rs.count_executions ELSE 0 END) AS ok,
       SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
       SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE i.start_time >= DATEADD(DAY, -1, GETUTCDATE()) AND q.query_hash IN (SELECT query_hash FROM top5)
GROUP BY q.query_hash, CONVERT(varchar(13), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120)
ORDER BY query_hash, hour_local;

-- 4. Exceptions raised recently (engine ring buffer, all databases), with the message text
;WITH x AS (
    SELECT CAST(rb.record AS xml) AS r, rb.[timestamp]
    FROM sys.dm_os_ring_buffers rb
    WHERE rb.ring_buffer_type = N'RING_BUFFER_EXCEPTION'
),
v AS (
    SELECT x.r.value('(//Exception/Error)[1]', 'int') AS error_number,
           x.r.value('(//Exception/Severity)[1]', 'int') AS severity,
           x.r.value('(//Exception/State)[1]', 'int') AS state,
           DATEADD(MILLISECOND, -CAST((SELECT ms_ticks FROM sys.dm_os_sys_info) - x.[timestamp] AS int), GETDATE()) AS raised_local
    FROM x
)
SELECT v.error_number, v.severity, COUNT(*) AS occurrences,
       CONVERT(varchar(19), MIN(v.raised_local), 120) AS first_local, CONVERT(varchar(19), MAX(v.raised_local), 120) AS last_local,
       LEFT(m.text, 150) AS message
FROM v
LEFT JOIN sys.messages m ON m.message_id = v.error_number AND m.language_id = 1033
GROUP BY v.error_number, v.severity, LEFT(m.text, 150)
ORDER BY occurrences DESC;
