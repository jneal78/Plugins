/*  03_qs_hourly.sql  (read-only)
    Purpose : hour-over-hour for one day vs the same hours @CompareDays earlier: CPU, reads, executions, timeouts,
              errors; the same split by workload group (integration, application, schema); and parallelism waits.
    Needs   : SQL Server 2017+ (section 4 uses query_store_wait_stats), Query Store on, VIEW DATABASE STATE.
    Params  : EDIT ME block. Edit the group CASE in section 2 to name this system's integrations and applications
              (by schema, object name prefix, or query_hash for an ad hoc caller). The first match wins.
    Reading : hour = local clock hour. cores = CPU-min / 60. A group whose share jumps against the comparison day
              is the place to drill in (02 for its top statements, 05 for one object).
              In section 2 the rows with hr = NULL are the group's whole-day totals.
              Parallelism wait-minutes are summed across threads, so they can exceed 60 per hour.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 03_qs_hourly.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Day         date    = NULL,   -- local date; NULL = today (up to the last complete Query Store interval)
        @CompareDays int     = 7,
        @TimeZone    sysname = NULL;   -- the site profile's Windows zone name (sys.time_zone_info), e.g.
                                       -- N'Central Standard Time'. NULL = the server's current UTC offset for every
                                       -- date, which is an hour off for a day across a daylight-saving change.
---------------------------------------------------------------------------------------------------------------------

IF @TimeZone IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = @TimeZone)
    RAISERROR(N'@TimeZone "%s" is not in sys.time_zone_info: use a Windows time zone name, or NULL.', 16, 1, @TimeZone);
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
SET @Day = ISNULL(@Day, CASE WHEN @TimeZone IS NULL THEN CAST(GETDATE() AS date)
                             ELSE CAST((SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone AS date) END);
DECLARE @cDay date = DATEADD(DAY, -@CompareDays, @Day);
-- Each day's local midnight in UTC, with its own date's offset
DECLARE @d0 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, CAST(@Day AS datetime))
                            ELSE CONVERT(datetime, (CAST(@Day AS datetime) AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END;
DECLARE @dN datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(DAY, 1, @d0)
                            ELSE CONVERT(datetime, (CAST(DATEADD(DAY, 1, @Day) AS datetime) AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END;
DECLARE @c0 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, CAST(@cDay AS datetime))
                            ELSE CONVERT(datetime, (CAST(@cDay AS datetime) AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END;
-- The day ends at the next local midnight or, today, at the last complete Query Store interval (the running one holds
-- only part of its data). The comparison day covers the same number of hours from its own midnight.
DECLARE @len int = (SELECT interval_length_minutes FROM sys.database_query_store_options);
DECLARE @lastComplete datetime = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', GETUTCDATE()) / @len) * @len, '20000101');
DECLARE @d1 datetime = CASE WHEN @dN > @lastComplete THEN @lastComplete ELSE @dN END;
DECLARE @c1 datetime = DATEADD(MINUTE, DATEDIFF(MINUTE, @d0, @d1), @c0);
SELECT CONVERT(varchar(10), @Day, 120) AS day_local, DATEDIFF(MINUTE, @d0, @d1) / 60.0 AS hours_compared,
       CONVERT(varchar(10), @cDay, 120) AS compare_day, ISNULL(@TimeZone, N'server offset now') AS time_zone,
       CONVERT(varchar(16), @d0, 120) AS day_starts_utc, CONVERT(varchar(16), @c0, 120) AS compare_starts_utc;

-- 1. Per hour: day vs comparison day (hr = hours since that day's local midnight, i.e. the local clock hour)
;WITH r AS (
    SELECT CASE WHEN i.start_time >= @d0 THEN 'D' ELSE 'C' END AS win,
           DATEDIFF(MINUTE, CASE WHEN i.start_time >= @d0 THEN @d0 ELSE @c0 END, CAST(i.start_time AS datetime)) / 60 AS hr,
           rs.execution_type, rs.count_executions AS execs, rs.avg_cpu_time * rs.count_executions AS cpu_us,
           rs.avg_logical_io_reads * rs.count_executions AS reads
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE (i.start_time >= @d0 AND i.start_time < @d1) OR (i.start_time >= @c0 AND i.start_time < @c1)
)
SELECT hr,
       CAST(SUM(CASE WHEN win = 'D' THEN cpu_us END) / 60e6 AS decimal(9,1)) AS cpu_min,
       CAST(SUM(CASE WHEN win = 'C' THEN cpu_us END) / 60e6 AS decimal(9,1)) AS cpu_min_compare,
       CAST(SUM(CASE WHEN win = 'D' THEN cpu_us END) / 3600e6 AS decimal(6,2)) AS cores,
       CAST(SUM(CASE WHEN win = 'D' THEN reads END) * 8 / 1048576.0 AS decimal(9,1)) AS reads_gb,
       CAST(SUM(CASE WHEN win = 'C' THEN reads END) * 8 / 1048576.0 AS decimal(9,1)) AS reads_gb_compare,
       CAST(SUM(CASE WHEN win = 'D' THEN execs END) / 1000.0 AS decimal(12,1)) AS stmt_execs_k,
       SUM(CASE WHEN win = 'D' AND execution_type = 3 THEN execs ELSE 0 END) AS timeouts,
       SUM(CASE WHEN win = 'C' AND execution_type = 3 THEN execs ELSE 0 END) AS timeouts_compare,
       SUM(CASE WHEN win = 'D' AND execution_type = 4 THEN execs ELSE 0 END) AS errors,
       SUM(CASE WHEN win = 'C' AND execution_type = 4 THEN execs ELSE 0 END) AS errors_compare
FROM r GROUP BY hr ORDER BY hr;

-- 2. Per workload group and hour (hr NULL = whole day). EDIT the CASE to match this system.
;WITH g AS (
    SELECT q.query_id,
           CASE
             WHEN q.object_id = 0                                              THEN 'Ad hoc / ORM'            -- literal or prepared SQL from applications
             WHEN OBJECT_NAME(q.object_id) IS NULL                             THEN 'Dropped or recreated'    -- old object ids (upgrades)
             WHEN OBJECT_SCHEMA_NAME(q.object_id) = N'app'                     THEN 'Vendor app (schema app)' -- example: one vendor per schema
             WHEN OBJECT_NAME(q.object_id) LIKE N'usp[_]Report%'               THEN 'Reports'                 -- example: a name prefix
             WHEN OBJECT_NAME(q.object_id) LIKE N'%Feed%'
               OR OBJECT_NAME(q.object_id) LIKE N'%Export%'                    THEN 'Feeds and exports'       -- example: integrations
             ELSE 'Other modules'
           END AS grp
    FROM sys.query_store_query q
),
r AS (
    SELECT g.grp, CASE WHEN i.start_time >= @d0 THEN 'D' ELSE 'C' END AS win,
           DATEDIFF(MINUTE, CASE WHEN i.start_time >= @d0 THEN @d0 ELSE @c0 END, CAST(i.start_time AS datetime)) / 60 AS hr,
           rs.execution_type, rs.count_executions AS execs, rs.avg_cpu_time * rs.count_executions AS cpu_us,
           rs.avg_logical_io_reads * rs.count_executions AS reads
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN g ON g.query_id = p.query_id
    WHERE (i.start_time >= @d0 AND i.start_time < @d1) OR (i.start_time >= @c0 AND i.start_time < @c1)
)
SELECT grp, hr,
       CAST(SUM(CASE WHEN win = 'D' THEN cpu_us END) / 60e6 AS decimal(9,1)) AS cpu_min,
       CAST(SUM(CASE WHEN win = 'C' THEN cpu_us END) / 60e6 AS decimal(9,1)) AS cpu_min_compare,
       CAST(SUM(CASE WHEN win = 'D' THEN reads END) * 8 / 1048576.0 AS decimal(9,1)) AS reads_gb,
       CAST(SUM(CASE WHEN win = 'D' THEN execs END) / 1000.0 AS decimal(12,1)) AS stmt_execs_k,
       SUM(CASE WHEN win = 'D' AND execution_type = 3 THEN execs ELSE 0 END) AS timeouts,
       SUM(CASE WHEN win = 'D' AND execution_type = 4 THEN execs ELSE 0 END) AS errors,
       SUM(CASE WHEN win = 'C' AND execution_type = 4 THEN execs ELSE 0 END) AS errors_compare
FROM r
GROUP BY GROUPING SETS ((grp), (grp, hr))
ORDER BY CASE WHEN hr IS NULL THEN 0 ELSE 1 END, CASE WHEN hr IS NULL THEN -SUM(CASE WHEN win = 'D' THEN cpu_us END) END, grp, hr;

-- 3. Busiest hour's top 10 statements (the hour with the most CPU in section 1)
;WITH h AS (
    SELECT TOP (1) DATEADD(HOUR, DATEDIFF(HOUR, 0, CAST(i.start_time AS datetime)), 0) AS h0
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE i.start_time >= @d0 AND i.start_time < @d1
    GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, CAST(i.start_time AS datetime)), 0)
    ORDER BY SUM(rs.avg_cpu_time * rs.count_executions) DESC
),
s AS (
    SELECT q.query_hash, MAX(q.query_text_id) AS query_text_id,
           MAX(CASE WHEN q.object_id = 0 THEN N'(ad hoc)'
                    ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END) AS obj,
           SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS reads, MAX(rs.max_dop) AS max_dop
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    CROSS JOIN h
    WHERE i.start_time >= h.h0 AND i.start_time < DATEADD(HOUR, 1, h.h0)
    GROUP BY q.query_hash
)
SELECT TOP (10) (SELECT DATEDIFF(MINUTE, @d0, h0) / 60 FROM h) AS busiest_hr, s.obj,
       CONVERT(varchar(20), s.query_hash, 1) AS query_hash,
       CAST(s.cpu_us / 60e6 AS decimal(9,1)) AS cpu_min, s.execs,
       CAST(s.cpu_us / 1000.0 / NULLIF(s.execs, 0) AS decimal(12,2)) AS cpu_ms_per_exec,
       CAST(s.reads / NULLIF(s.execs, 0) AS bigint) AS reads_per_exec, s.max_dop,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM s JOIN sys.query_store_query_text t ON t.query_text_id = s.query_text_id
ORDER BY s.cpu_us DESC;

-- 4. Parallelism wait-minutes per hour (day vs comparison), then the top statements behind them on the day
SELECT DATEDIFF(MINUTE, CASE WHEN i.start_time >= @d0 THEN @d0 ELSE @c0 END, CAST(i.start_time AS datetime)) / 60 AS hr,
       CAST(SUM(CASE WHEN i.start_time >= @d0 THEN ws.total_query_wait_time_ms END) / 60000.0 AS decimal(9,1)) AS parallel_wait_min,
       CAST(SUM(CASE WHEN i.start_time < @d0 THEN ws.total_query_wait_time_ms END) / 60000.0 AS decimal(9,1)) AS parallel_wait_min_compare
FROM sys.query_store_wait_stats ws
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
WHERE ws.wait_category_desc = N'Parallelism'
  AND ((i.start_time >= @d0 AND i.start_time < @d1) OR (i.start_time >= @c0 AND i.start_time < @c1))
GROUP BY DATEDIFF(MINUTE, CASE WHEN i.start_time >= @d0 THEN @d0 ELSE @c0 END, CAST(i.start_time AS datetime)) / 60
ORDER BY hr;

SELECT TOP (10)
       CASE WHEN q.object_id = 0 THEN N'(ad hoc) ' + CONVERT(nvarchar(20), q.query_hash, 1)
            ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END AS source,
       CAST(SUM(ws.total_query_wait_time_ms) / 60000.0 AS decimal(9,1)) AS parallel_wait_min
FROM sys.query_store_wait_stats ws
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = ws.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE ws.wait_category_desc = N'Parallelism' AND i.start_time >= @d0 AND i.start_time < @d1
GROUP BY CASE WHEN q.object_id = 0 THEN N'(ad hoc) ' + CONVERT(nvarchar(20), q.query_hash, 1)
              ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END
ORDER BY SUM(ws.total_query_wait_time_ms) DESC;
