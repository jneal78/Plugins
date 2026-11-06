/*  02_qs_top_consumers.sql  (read-only)
    Purpose : where the CPU goes. Top objects and top statements by CPU in a window, each compared with the same
              clock window @CompareDays earlier (a week ago by default).
    Needs   : SQL Server 2016+, Query Store on in the current database, VIEW DATABASE STATE.
    Params  : EDIT ME block. @From/@To are local time, written '2026-10-28T07:00:00'; NULL = today 00:00 to now.
    Reading : cpu_min = CPU-minutes in the window (60 CPU-min per hour = one core busy for that hour).
              stmt_execs counts statement executions, not procedure calls (a procedure with 10 statements counts 10).
              Objects that were dropped and recreated keep their old Query Store rows under the old object id; those
              rows are folded back to the live name when one of their statements still exists (matched on query_hash),
              otherwise they show as '(dropped id N)'.
              timeouts = execution_type 3 (aborted, usually a client timeout); errors = execution_type 4 (exception).
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 02_qs_top_consumers.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @From        datetime = NULL,   -- local time; NULL = today 00:00
        @To          datetime = NULL,   -- local time; NULL = now
        @CompareDays int      = 7,      -- comparison window = same clock window this many days earlier
        @TopN        int      = 25,
        @TimeZone    sysname  = NULL;   -- the site profile's Windows zone name (sys.time_zone_info), e.g.
                                        -- N'Central Standard Time'. NULL = the server's current UTC offset for every
                                        -- date, which is an hour off for a window across a daylight-saving change.
---------------------------------------------------------------------------------------------------------------------

IF @TimeZone IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = @TimeZone)
    RAISERROR(N'@TimeZone "%s" is not in sys.time_zone_info: use a Windows time zone name, or NULL.', 16, 1, @TimeZone);
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
DECLARE @nowLocal datetime = CASE WHEN @TimeZone IS NULL THEN GETDATE()
                                  ELSE CONVERT(datetime, (SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) END;
SET @From = ISNULL(@From, CAST(CAST(@nowLocal AS date) AS datetime));
SET @To   = ISNULL(@To, @nowLocal);
-- Local -> UTC, each date with its own offset (so the comparison window is the same clock hours on its own day)
DECLARE @bFrom datetime = DATEADD(DAY, -@CompareDays, @From), @bTo datetime = DATEADD(DAY, -@CompareDays, @To);
DECLARE @a0 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @From) ELSE CONVERT(datetime, (@From AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END,
        @a1 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @To)   ELSE CONVERT(datetime, (@To   AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END,
        @b0 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @bFrom) ELSE CONVERT(datetime, (@bFrom AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END,
        @b1 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @bTo)   ELSE CONVERT(datetime, (@bTo   AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END;
-- Whole Query Store intervals only: each window starts at an interval boundary and ends at the last complete one. The
-- interval running now holds only part of its data, so including it would compare a partial hour with a full one.
DECLARE @len int = (SELECT interval_length_minutes FROM sys.database_query_store_options);
SET @a0 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', DATEADD(SECOND, @len * 60 - 1, @a0)) / @len) * @len, '20000101');
SET @b0 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', DATEADD(SECOND, @len * 60 - 1, @b0)) / @len) * @len, '20000101');
SET @a1 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', @a1) / @len) * @len, '20000101');
SET @b1 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', @b1) / @len) * @len, '20000101');
IF @a1 <= @a0 RAISERROR(N'The window holds no complete Query Store interval yet: widen it or wait.', 10, 1);
DECLARE @hours decimal(9,3) = DATEDIFF(SECOND, @a0, @a1) / 3600.0, @hoursB decimal(9,3) = DATEDIFF(SECOND, @b0, @b1) / 3600.0;

SELECT CONVERT(varchar(16), @From, 120) AS window_from_local, CONVERT(varchar(16), @To, 120) AS window_to_local,
       CONVERT(varchar(16), @a0, 120) AS used_from_utc, CONVERT(varchar(16), @a1, 120) AS used_to_utc,
       CAST(@hours AS decimal(7,2)) AS hours, CAST(@hoursB AS decimal(7,2)) AS compare_hours, @CompareDays AS compare_days_back,
       ISNULL(@TimeZone, N'server offset now') AS time_zone,
       (SELECT TOP (1) DATEDIFF(MINUTE, start_time, end_time) FROM sys.query_store_runtime_stats_interval
        ORDER BY runtime_stats_interval_id DESC) AS qs_interval_min,
       (SELECT CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(MIN(start_time) AS datetime)), 120) FROM sys.query_store_runtime_stats_interval) AS qs_history_starts_local;

-- 1. Window totals: today vs comparison (cores_busy = CPU-min per hour / 60)
;WITH r AS (
    SELECT CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           rs.execution_type, rs.count_executions AS execs, rs.avg_cpu_time * rs.count_executions AS cpu_us,
           rs.avg_logical_io_reads * rs.count_executions AS reads, rs.avg_duration * rs.count_executions AS dur_us
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE (i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1)
)
SELECT CASE win WHEN 'A' THEN 'window' ELSE 'compare' END AS period,
       CAST(SUM(cpu_us) / 60e6 AS decimal(12,1)) AS cpu_min,
       CAST(SUM(cpu_us) / 60e6 / NULLIF(CASE win WHEN 'A' THEN @hours ELSE @hoursB END, 0) / 60 AS decimal(6,2)) AS cores_busy_avg,
       CAST(SUM(reads) * 8 / 1048576.0 AS decimal(12,1)) AS reads_gb,
       CAST(SUM(dur_us) / 60e6 AS decimal(12,1)) AS duration_min,
       SUM(execs) AS stmt_execs,
       SUM(CASE WHEN execution_type = 3 THEN execs ELSE 0 END) AS timeouts,
       SUM(CASE WHEN execution_type = 4 THEN execs ELSE 0 END) AS errors
FROM r GROUP BY win ORDER BY win;

-- Sections 2 and 3 aggregate the runtime stats per statement and window FIRST (a few thousand rows), and only then
-- look up names. Resolving names per runtime-stats row, with the dropped-object fold in the join, took minutes on a
-- busy server; the same work on aggregated rows takes seconds.

-- 2. Top objects by CPU in the window, with the comparison window
;WITH agg AS (
    SELECT p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS reads, SUM(rs.avg_duration * rs.count_executions) AS dur_us,
           MAX(rs.max_dop) AS max_dop, COUNT(DISTINCT rs.plan_id) AS plans,
           SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
           SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    WHERE (i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1)
    GROUP BY p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END
),
named AS (
    SELECT a.*, q.query_hash, q.object_id,
           CASE WHEN q.object_id = 0 THEN NULL ELSE OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id) END AS live_name
    FROM agg a JOIN sys.query_store_query q ON q.query_id = a.query_id
),
fold AS (   -- objects dropped and recreated: the live name of a statement with the same query_hash. Built once over
            -- all statements (under a second) and hash-joined; filtering it by the rows above re-ran their aggregation.
    SELECT q2.query_hash, MIN(OBJECT_SCHEMA_NAME(q2.object_id) + N'.' + OBJECT_NAME(q2.object_id)) AS obj
    FROM sys.query_store_query q2
    WHERE q2.object_id <> 0 AND OBJECT_NAME(q2.object_id) IS NOT NULL
    GROUP BY q2.query_hash
),
r AS (
    SELECT n.*, CASE WHEN n.object_id = 0 THEN N'(ad hoc, all)'
                     ELSE COALESCE(n.live_name, f.obj, N'(dropped id ' + CAST(n.object_id AS nvarchar(12)) + N')') END AS obj
    FROM named n LEFT HASH JOIN fold f ON f.query_hash = n.query_hash AND n.live_name IS NULL AND n.object_id <> 0
)
SELECT TOP (@TopN) obj,
       CAST(SUM(CASE WHEN win = 'A' THEN cpu_us END) / 60e6 AS decimal(12,1)) AS cpu_min,
       CAST(SUM(CASE WHEN win = 'B' THEN cpu_us END) / 60e6 AS decimal(12,1)) AS cpu_min_compare,
       CAST((ISNULL(SUM(CASE WHEN win = 'A' THEN cpu_us END), 0) - ISNULL(SUM(CASE WHEN win = 'B' THEN cpu_us END), 0)) / 60e6 AS decimal(12,1)) AS cpu_min_delta,
       CAST(100.0 * SUM(CASE WHEN win = 'A' THEN cpu_us END) / NULLIF(SUM(SUM(CASE WHEN win = 'A' THEN cpu_us END)) OVER (), 0) AS decimal(5,1)) AS pct_of_window,
       SUM(CASE WHEN win = 'A' THEN execs END) AS stmt_execs,
       SUM(CASE WHEN win = 'B' THEN execs END) AS stmt_execs_compare,
       CAST(SUM(CASE WHEN win = 'A' THEN reads END) * 8 / 1048576.0 AS decimal(12,1)) AS reads_gb,
       CAST(SUM(CASE WHEN win = 'A' THEN dur_us END) / 60e6 AS decimal(12,1)) AS duration_min,
       MAX(CASE WHEN win = 'A' THEN max_dop END) AS max_dop,
       SUM(CASE WHEN win = 'A' THEN plans END) AS plans,
       SUM(CASE WHEN win = 'A' THEN timeouts ELSE 0 END) AS timeouts,
       SUM(CASE WHEN win = 'A' THEN errors ELSE 0 END) AS errors
FROM r
GROUP BY obj
ORDER BY SUM(CASE WHEN win = 'A' THEN cpu_us END) DESC;

-- 3. Top statements by CPU in the window (one row per query_hash), with the comparison window
;WITH agg AS (
    SELECT p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS reads, SUM(rs.avg_duration * rs.count_executions) AS dur_us,
           SUM(rs.avg_rowcount * rs.count_executions) AS row_total, MAX(rs.max_dop) AS max_dop, COUNT(DISTINCT rs.plan_id) AS plans,
           SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
           SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    WHERE (i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1)
    GROUP BY p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END
),
named AS (
    SELECT a.*, q.query_hash, q.query_text_id, q.object_id,
           CASE WHEN q.object_id = 0 THEN NULL ELSE OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id) END AS live_name
    FROM agg a JOIN sys.query_store_query q ON q.query_id = a.query_id
),
fold AS (
    SELECT q2.query_hash, MIN(OBJECT_SCHEMA_NAME(q2.object_id) + N'.' + OBJECT_NAME(q2.object_id)) AS obj
    FROM sys.query_store_query q2
    WHERE q2.object_id <> 0 AND OBJECT_NAME(q2.object_id) IS NOT NULL
    GROUP BY q2.query_hash
),
r AS (
    SELECT n.*, CASE WHEN n.object_id = 0 THEN N'(ad hoc)'
                     ELSE COALESCE(n.live_name, f.obj, N'(dropped id ' + CAST(n.object_id AS nvarchar(12)) + N')') END AS obj
    FROM named n LEFT HASH JOIN fold f ON f.query_hash = n.query_hash AND n.live_name IS NULL AND n.object_id <> 0
),
s AS (
    SELECT query_hash, MAX(obj) AS obj, MAX(query_id) AS last_query_id, MAX(query_text_id) AS query_text_id,
           COUNT(DISTINCT query_id) AS query_ids,
           SUM(CASE WHEN win = 'A' THEN cpu_us END) AS cpu_a, SUM(CASE WHEN win = 'B' THEN cpu_us END) AS cpu_b,
           SUM(CASE WHEN win = 'A' THEN execs END) AS ex_a, SUM(CASE WHEN win = 'B' THEN execs END) AS ex_b,
           SUM(CASE WHEN win = 'A' THEN reads END) AS rd_a, SUM(CASE WHEN win = 'B' THEN reads END) AS rd_b,
           SUM(CASE WHEN win = 'A' THEN dur_us END) AS dur_a, SUM(CASE WHEN win = 'A' THEN row_total END) AS rows_a,
           MAX(CASE WHEN win = 'A' THEN max_dop END) AS max_dop,
           SUM(CASE WHEN win = 'A' THEN plans END) AS plans,
           SUM(CASE WHEN win = 'A' THEN timeouts ELSE 0 END) AS timeouts,
           SUM(CASE WHEN win = 'A' THEN errors ELSE 0 END) AS errors
    FROM r GROUP BY query_hash
)
SELECT TOP (@TopN) s.obj, s.last_query_id, CONVERT(varchar(20), s.query_hash, 1) AS query_hash,
       CAST(s.cpu_a / 60e6 AS decimal(12,1)) AS cpu_min, CAST(s.cpu_b / 60e6 AS decimal(12,1)) AS cpu_min_compare,
       CAST((ISNULL(s.cpu_a, 0) - ISNULL(s.cpu_b, 0)) / 60e6 AS decimal(12,1)) AS cpu_min_delta,
       s.ex_a AS execs, s.ex_b AS execs_compare,
       CAST(s.cpu_a / 1000.0 / NULLIF(s.ex_a, 0) AS decimal(14,2)) AS cpu_ms_per_exec,
       CAST(s.cpu_b / 1000.0 / NULLIF(s.ex_b, 0) AS decimal(14,2)) AS cpu_ms_per_exec_compare,
       CAST(s.rd_a / NULLIF(s.ex_a, 0) AS bigint) AS reads_per_exec,
       CAST(s.dur_a / 1000.0 / NULLIF(s.ex_a, 0) AS decimal(14,2)) AS ms_per_exec,
       CAST(s.rows_a / NULLIF(s.ex_a, 0) AS decimal(14,1)) AS rows_per_exec,
       s.max_dop, s.plans, s.query_ids, s.timeouts, s.errors,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM s JOIN sys.query_store_query_text t ON t.query_text_id = s.query_text_id
WHERE s.cpu_a IS NOT NULL
ORDER BY s.cpu_a DESC;
