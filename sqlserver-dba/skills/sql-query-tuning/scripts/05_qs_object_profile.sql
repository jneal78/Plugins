/*  05_qs_object_profile.sql  (read-only)
    Purpose : everything Query Store knows about one procedure, function or trigger: its definition fingerprint,
              daily trend, per-hour shape over the last 24 hours, each statement's cost, every plan (to spot plan
              flips) and waits.
    Needs   : SQL Server 2017+ (section 6 uses query_store_wait_stats), Query Store on, VIEW DATABASE STATE and
              VIEW DEFINITION on the object.
    Params  : EDIT ME block.
    Reading : 1. hash_sha256 identifies the exact live text: keep it with any patch built from it.
              2. A daily cost that grows while executions stay flat = a table the code scans is growing (or a
                 cleanup that stopped). A step change on one day = a deploy or a plan change on that day.
              3. Per-hour: cost per run rising through the day = it scans rows that accumulate during the day.
              4. share_pct tells which statement to fix; usually one statement is 80-99% of the object.
              5. Several plans for one statement, with very different cpu_ms_per_exec, = plan flips (parameter
                 sensitivity or recompiles). first/last seen show when each plan was in use.
              Statements of earlier versions of a dropped and recreated object are included when their
              query_hash still matches a live statement of the object.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 05_qs_object_profile.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Object nvarchar(300) = N'dbo.SomeProc',   -- schema.name
        @Days   int           = 14;                -- history for the daily trend and plan list
---------------------------------------------------------------------------------------------------------------------

DECLARE @oid int = OBJECT_ID(@Object);
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
DECLARE @d0 datetime = DATEADD(MINUTE, -@off, DATEADD(DAY, -@Days, CAST(CAST(GETDATE() AS date) AS datetime)));
DECLARE @h0 datetime = DATEADD(HOUR, -24, GETUTCDATE());
IF @oid IS NULL RAISERROR(N'Object %s not found in this database', 16, 1, @Object);

-- 1. Definition fingerprint
SELECT OBJECT_SCHEMA_NAME(o.object_id) + N'.' + o.name AS object_name, o.type_desc,
       CONVERT(varchar(16), o.create_date, 120) AS created, CONVERT(varchar(16), o.modify_date, 120) AS modified,
       CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(o.object_id)), 1) AS hash_sha256,
       LEN(OBJECT_DEFINITION(o.object_id)) AS definition_chars, m.uses_ansi_nulls, m.uses_quoted_identifier,
       (SELECT COUNT(*) FROM sys.query_store_query q WHERE q.object_id = o.object_id) AS qs_queries
FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.object_id = @oid;

-- 2. Daily trend (local days)
;WITH qs AS (
    SELECT q.query_id FROM sys.query_store_query q WHERE q.object_id = @oid
    UNION
    SELECT q2.query_id FROM sys.query_store_query q2
    WHERE q2.object_id <> 0 AND OBJECT_NAME(q2.object_id) IS NULL
      AND q2.query_hash IN (SELECT query_hash FROM sys.query_store_query WHERE object_id = @oid)
)
SELECT CONVERT(varchar(10), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120) AS day_local,
       SUM(rs.count_executions) AS stmt_execs,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 60e6 AS decimal(12,2)) AS cpu_min,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / 1e6 AS decimal(12,1)) AS reads_m,
       CAST(SUM(rs.avg_duration * rs.count_executions) / 60e6 AS decimal(12,2)) AS duration_min,
       COUNT(DISTINCT rs.plan_id) AS plans_used, MAX(rs.max_dop) AS max_dop,
       SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
       SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN qs ON qs.query_id = p.query_id
WHERE i.start_time >= @d0
GROUP BY CONVERT(varchar(10), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120)
ORDER BY day_local;

-- 3. Last 24 hours by local hour: does each run get more expensive through the day?
SELECT CONVERT(varchar(13), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120) AS hour_local,
       SUM(rs.count_executions) AS stmt_execs,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 60e6 AS decimal(12,2)) AS cpu_min,
       CAST(MAX(rs.avg_cpu_time) / 1000.0 AS decimal(14,1)) AS worst_stmt_avg_cpu_ms,
       CAST(MAX(rs.avg_logical_io_reads) AS bigint) AS worst_stmt_avg_reads,
       CAST(MAX(rs.avg_duration) / 1000.0 AS decimal(14,1)) AS worst_stmt_avg_ms
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE q.object_id = @oid AND i.start_time >= @h0
GROUP BY CONVERT(varchar(13), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120)
ORDER BY hour_local;

-- 4. Statements (one row per query_hash) over @Days, most expensive first
;WITH qs AS (
    SELECT q.query_id, q.query_hash, q.query_text_id, q.object_id FROM sys.query_store_query q WHERE q.object_id = @oid
    UNION
    SELECT q2.query_id, q2.query_hash, q2.query_text_id, q2.object_id FROM sys.query_store_query q2
    WHERE q2.object_id <> 0 AND OBJECT_NAME(q2.object_id) IS NULL
      AND q2.query_hash IN (SELECT query_hash FROM sys.query_store_query WHERE object_id = @oid)
),
s AS (
    SELECT qs.query_hash, MAX(qs.query_id) AS last_query_id, MAX(qs.query_text_id) AS query_text_id,
           COUNT(DISTINCT qs.query_id) AS query_ids, COUNT(DISTINCT rs.plan_id) AS plans,
           SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS reads, SUM(rs.avg_duration * rs.count_executions) AS dur_us,
           SUM(rs.avg_rowcount * rs.count_executions) AS row_total, MAX(rs.max_dop) AS max_dop,
           SUM(CASE WHEN rs.execution_type IN (3, 4) THEN rs.count_executions ELSE 0 END) AS failed,
           MAX(rs.last_execution_time) AS last_exec
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN qs ON qs.query_id = p.query_id
    WHERE i.start_time >= @d0
    GROUP BY qs.query_hash
)
SELECT s.last_query_id, CONVERT(varchar(20), s.query_hash, 1) AS query_hash, s.query_ids, s.plans, s.execs,
       CAST(s.cpu_us / 60e6 AS decimal(12,2)) AS cpu_min,
       CAST(100.0 * s.cpu_us / NULLIF(SUM(s.cpu_us) OVER (), 0) AS decimal(5,1)) AS share_pct,
       CAST(s.cpu_us / 1000.0 / NULLIF(s.execs, 0) AS decimal(14,2)) AS cpu_ms_per_exec,
       CAST(s.reads / NULLIF(s.execs, 0) AS bigint) AS reads_per_exec,
       CAST(s.dur_us / 1000.0 / NULLIF(s.execs, 0) AS decimal(14,2)) AS ms_per_exec,
       CAST(s.row_total / NULLIF(s.execs, 0) AS decimal(14,1)) AS rows_per_exec,
       s.max_dop, s.failed, CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(s.last_exec AS datetime)), 120) AS last_exec_local,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM s JOIN sys.query_store_query_text t ON t.query_text_id = s.query_text_id
ORDER BY s.cpu_us DESC;

-- 5. Plans of the object's statements over @Days: plan flips show as several plans per query_id with different cost
SELECT p.query_id, p.plan_id, p.is_forced_plan, p.count_compiles,
       CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(MIN(rs.first_execution_time) AS datetime)), 120) AS first_seen_local,
       CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(MAX(rs.last_execution_time) AS datetime)), 120) AS last_seen_local,
       SUM(rs.count_executions) AS execs,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 / NULLIF(SUM(rs.count_executions), 0) AS decimal(14,2)) AS cpu_ms_per_exec,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS bigint) AS reads_per_exec,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 60e6 AS decimal(12,2)) AS cpu_min,
       MAX(rs.max_dop) AS max_dop,
       CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(p.last_compile_start_time AS datetime)), 120) AS last_compile_local
FROM sys.query_store_plan p
JOIN sys.query_store_query q ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE q.object_id = @oid AND i.start_time >= @d0
GROUP BY p.query_id, p.plan_id, p.is_forced_plan, p.count_compiles, p.last_compile_start_time
HAVING SUM(rs.avg_cpu_time * rs.count_executions) > 0
ORDER BY p.query_id, MIN(rs.first_execution_time);

-- 6. Waits of the object's statements over @Days, by category
SELECT ws.wait_category_desc,
       CAST(SUM(ws.total_query_wait_time_ms) / 60000.0 AS decimal(12,2)) AS wait_min
FROM sys.query_store_wait_stats ws
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = ws.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE q.object_id = @oid AND i.start_time >= @d0
GROUP BY ws.wait_category_desc
ORDER BY wait_min DESC;
