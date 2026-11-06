/*  04_qs_regressions.sql  (read-only)
    Purpose : before/after comparison around a change (a vendor upgrade, a deploy, a plan flip, a statistics
              rebuild) or between any two windows: which statements got slower per execution, which are new,
              which disappeared, and how each object's hourly cost moved.
    Needs   : SQL Server 2016+, Query Store on, VIEW DATABASE STATE.
    Params  : EDIT ME block. Windows are local time. Leave out the hour in which the change happened (mixed).
              Write times as '2026-10-28T11:20:00' (the T form is safe under any DATEFORMAT).
              @Schema / @ObjectLike narrow the scope (e.g. one vendor's schema); NULL = whole database. With
              @Schema set, dropped ids that match no live statement are kept too: after an upgrade they are
              usually that schema's old versions.
    Reading : Statements are matched on query_hash, so a statement whose text did not change is compared even if
              its procedure was redefined, dropped or recreated. A statement whose text changed shows up as NEW
              (after) and GONE (before): pair them by eye using the object and text.
              extra_cpu_min_hr = (CPU per execution after - before) x executions per hour after. This is the CPU
              the regression costs per hour at today's call rate; rank fixes by it.
              Rates are per hour, so windows of different lengths compare fairly.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 04_qs_regressions.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @BeforeFrom datetime      = NULL,   -- local; NULL = same clock window as "after", 7 days earlier
        @BeforeTo   datetime      = NULL,
        @AfterFrom  datetime      = NULL,   -- local; NULL = last 4 hours
        @AfterTo    datetime      = NULL,   -- local; NULL = now
        @Schema     nvarchar(128) = NULL,   -- e.g. N'app'; NULL = all
        @ObjectLike nvarchar(300) = NULL,   -- e.g. N'%Feed%' on the object name; NULL = all
        @MinExecs   int           = 100,    -- minimum executions after, for the per-execution comparison
        @TopN       int           = 25,
        @TimeZone   sysname       = NULL;   -- the site profile's Windows zone name (sys.time_zone_info), e.g.
                                            -- N'Central Standard Time'. NULL = the server's current UTC offset for
                                            -- every date (an hour off for a window across a daylight-saving change).
---------------------------------------------------------------------------------------------------------------------

IF @TimeZone IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = @TimeZone)
    RAISERROR(N'@TimeZone "%s" is not in sys.time_zone_info: use a Windows time zone name, or NULL.', 16, 1, @TimeZone);
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
SET @AfterTo    = ISNULL(@AfterTo, CASE WHEN @TimeZone IS NULL THEN GETDATE()
                                        ELSE CONVERT(datetime, (SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE @TimeZone) END);
SET @AfterFrom  = ISNULL(@AfterFrom, DATEADD(HOUR, -4, @AfterTo));
SET @BeforeFrom = ISNULL(@BeforeFrom, DATEADD(DAY, -7, @AfterFrom));
SET @BeforeTo   = ISNULL(@BeforeTo, DATEADD(DAY, -7, @AfterTo));
-- Local -> UTC, each date with its own offset
DECLARE @b0 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @BeforeFrom) ELSE CONVERT(datetime, (@BeforeFrom AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END,
        @b1 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @BeforeTo)   ELSE CONVERT(datetime, (@BeforeTo   AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END,
        @a0 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @AfterFrom)  ELSE CONVERT(datetime, (@AfterFrom  AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END,
        @a1 datetime = CASE WHEN @TimeZone IS NULL THEN DATEADD(MINUTE, -@off, @AfterTo)    ELSE CONVERT(datetime, (@AfterTo    AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC') END;
-- Whole Query Store intervals only: windows start at an interval boundary and end at the last complete one, so the
-- per-hour rates divide exactly the hours whose data is included (the running interval holds only part of its data).
DECLARE @len int = (SELECT interval_length_minutes FROM sys.database_query_store_options);
SET @a0 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', DATEADD(SECOND, @len * 60 - 1, @a0)) / @len) * @len, '20000101');
SET @b0 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', DATEADD(SECOND, @len * 60 - 1, @b0)) / @len) * @len, '20000101');
SET @a1 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', @a1) / @len) * @len, '20000101');
SET @b1 = DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', @b1) / @len) * @len, '20000101');
IF @a1 <= @a0 OR @b1 <= @b0 RAISERROR(N'A window holds no complete Query Store interval: widen it.', 10, 1);
DECLARE @bh decimal(9,3) = DATEDIFF(SECOND, @b0, @b1) / 3600.0, @ah decimal(9,3) = DATEDIFF(SECOND, @a0, @a1) / 3600.0;

SELECT CONVERT(varchar(16), @BeforeFrom, 120) AS before_from, CONVERT(varchar(16), @BeforeTo, 120) AS before_to, CAST(@bh AS decimal(7,2)) AS before_hours,
       CONVERT(varchar(16), @AfterFrom, 120) AS after_from, CONVERT(varchar(16), @AfterTo, 120) AS after_to, CAST(@ah AS decimal(7,2)) AS after_hours,
       CONVERT(varchar(16), @b0, 120) + ' to ' + CONVERT(varchar(16), @b1, 120) AS before_used_utc,
       CONVERT(varchar(16), @a0, 120) + ' to ' + CONVERT(varchar(16), @a1, 120) AS after_used_utc,
       ISNULL(@TimeZone, N'server offset now') AS time_zone,
       ISNULL(@Schema, N'(all)') AS scope_schema, ISNULL(@ObjectLike, N'(all)') AS scope_object;

-- Every section aggregates the runtime stats per statement and window FIRST (a few thousand rows), then looks up
-- names, then folds objects that were dropped and recreated through a name map built once and hash-joined.
-- Resolving names per runtime-stats row, or filtering the map by those rows, took minutes on a busy server.

-- 1. Statement-level aggregates for both windows (scoped), then: regressions
;WITH agg AS (
    SELECT p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS reads, SUM(rs.avg_duration * rs.count_executions) AS dur_us,
           MAX(rs.max_dop) AS max_dop, COUNT(DISTINCT rs.plan_id) AS plans,
           SUM(CASE WHEN rs.execution_type IN (3, 4) THEN rs.count_executions ELSE 0 END) AS failed
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    WHERE ((i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1))
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
                     ELSE COALESCE(n.live_name, fo.obj, N'(dropped id ' + CAST(n.object_id AS nvarchar(12)) + N')') END AS obj
    FROM named n LEFT HASH JOIN fold fo ON fo.query_hash = n.query_hash AND n.live_name IS NULL AND n.object_id <> 0
),
f AS (
    SELECT * FROM r
    WHERE (@Schema IS NULL OR obj LIKE @Schema + N'.%' OR (obj LIKE N'(dropped id%' AND @ObjectLike IS NULL))
      AND (@ObjectLike IS NULL OR obj LIKE @ObjectLike)
),
s AS (
    SELECT query_hash, win, MAX(obj) AS obj, MAX(query_id) AS query_id, MAX(query_text_id) AS query_text_id,
           SUM(execs) AS execs, SUM(cpu_us) AS cpu_us, SUM(reads) AS reads, SUM(dur_us) AS dur_us,
           MAX(max_dop) AS max_dop, SUM(plans) AS plans, SUM(failed) AS failed
    FROM f GROUP BY query_hash, win
)
SELECT TOP (@TopN) a.obj, a.query_id, CONVERT(varchar(20), a.query_hash, 1) AS query_hash,
       CAST(b.cpu_us / 1000.0 / b.execs AS decimal(14,2)) AS cpu_ms_before,
       CAST(a.cpu_us / 1000.0 / a.execs AS decimal(14,2)) AS cpu_ms_after,
       CAST((a.cpu_us / a.execs) / NULLIF(b.cpu_us / b.execs, 0) AS decimal(9,1)) AS x_slower,
       CAST(b.reads / b.execs AS bigint) AS reads_before, CAST(a.reads / a.execs AS bigint) AS reads_after,
       CAST(b.execs / @bh AS bigint) AS execs_hr_before, CAST(a.execs / @ah AS bigint) AS execs_hr_after,
       CAST((a.cpu_us / a.execs - b.cpu_us / b.execs) * (a.execs / @ah) / 60e6 AS decimal(9,2)) AS extra_cpu_min_hr,
       a.max_dop, a.plans, a.failed AS failed_after,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM s a
JOIN s b ON b.query_hash = a.query_hash AND b.win = 'B' AND a.win = 'A'
JOIN sys.query_store_query_text t ON t.query_text_id = a.query_text_id
WHERE a.execs >= @MinExecs AND b.execs > 0
ORDER BY (a.cpu_us / a.execs - b.cpu_us / b.execs) * (a.execs / @ah) DESC;

-- 2. NEW statements (after only), by CPU per hour; and 3. GONE statements (before only)
;WITH agg AS (
    SELECT p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS reads, MAX(rs.max_dop) AS max_dop
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    WHERE ((i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1))
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
                     ELSE COALESCE(n.live_name, fo.obj, N'(dropped id ' + CAST(n.object_id AS nvarchar(12)) + N')') END AS obj
    FROM named n LEFT HASH JOIN fold fo ON fo.query_hash = n.query_hash AND n.live_name IS NULL AND n.object_id <> 0
),
f AS (
    SELECT * FROM r
    WHERE (@Schema IS NULL OR obj LIKE @Schema + N'.%' OR (obj LIKE N'(dropped id%' AND @ObjectLike IS NULL))
      AND (@ObjectLike IS NULL OR obj LIKE @ObjectLike)
),
s AS (
    SELECT query_hash, MAX(obj) AS obj, MAX(query_id) AS query_id, MAX(query_text_id) AS query_text_id,
           SUM(CASE WHEN win = 'A' THEN execs END) AS ex_a, SUM(CASE WHEN win = 'B' THEN execs END) AS ex_b,
           SUM(CASE WHEN win = 'A' THEN cpu_us END) AS cpu_a, SUM(CASE WHEN win = 'B' THEN cpu_us END) AS cpu_b,
           SUM(CASE WHEN win = 'A' THEN reads END) AS rd_a, SUM(CASE WHEN win = 'B' THEN reads END) AS rd_b,
           MAX(max_dop) AS max_dop
    FROM f GROUP BY query_hash
),
k AS (
    SELECT * FROM (SELECT TOP (@TopN) 'NEW' AS kind, obj, query_id, query_hash, query_text_id,
           CAST(cpu_a / 60e6 / @ah AS decimal(9,2)) AS cpu_min_hr, CAST(ex_a / @ah AS bigint) AS execs_hr,
           CAST(cpu_a / 1000.0 / NULLIF(ex_a, 0) AS decimal(14,2)) AS cpu_ms_per_exec, CAST(rd_a / NULLIF(ex_a, 0) AS bigint) AS reads_per_exec, max_dop
    FROM s WHERE ex_b IS NULL AND ex_a > 0 ORDER BY cpu_a DESC) n
    UNION ALL
    SELECT * FROM (SELECT TOP (@TopN) 'GONE' AS kind, obj, query_id, query_hash, query_text_id,
           CAST(cpu_b / 60e6 / @bh AS decimal(9,2)) AS cpu_min_hr, CAST(ex_b / @bh AS bigint) AS execs_hr,
           CAST(cpu_b / 1000.0 / NULLIF(ex_b, 0) AS decimal(14,2)) AS cpu_ms_per_exec, CAST(rd_b / NULLIF(ex_b, 0) AS bigint) AS reads_per_exec, max_dop
    FROM s WHERE ex_a IS NULL AND ex_b > 0 ORDER BY cpu_b DESC) g
)
SELECT k.kind, k.obj, k.query_id, CONVERT(varchar(20), k.query_hash, 1) AS query_hash, k.cpu_min_hr, k.execs_hr,
       k.cpu_ms_per_exec, k.reads_per_exec, k.max_dop,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM k JOIN sys.query_store_query_text t ON t.query_text_id = k.query_text_id
ORDER BY k.kind DESC, k.cpu_min_hr DESC;

-- 4. Per object: hourly rates before vs after (dropped ids folded to the live name where a statement matches)
;WITH agg AS (
    SELECT p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS reads,
           SUM(CASE WHEN rs.execution_type IN (3, 4) THEN rs.count_executions ELSE 0 END) AS failed
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    WHERE ((i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1))
    GROUP BY p.query_id, CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END
),
named AS (
    SELECT a.*, q.query_hash, q.object_id,
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
    SELECT n.*, CASE WHEN n.object_id = 0 THEN N'(ad hoc, all)'
                     ELSE COALESCE(n.live_name, fo.obj, N'(dropped id ' + CAST(n.object_id AS nvarchar(12)) + N')') END AS obj
    FROM named n LEFT HASH JOIN fold fo ON fo.query_hash = n.query_hash AND n.live_name IS NULL AND n.object_id <> 0
),
f AS (
    SELECT * FROM r
    WHERE (@Schema IS NULL OR obj LIKE @Schema + N'.%' OR (obj LIKE N'(dropped id%' AND @ObjectLike IS NULL))
      AND (@ObjectLike IS NULL OR obj LIKE @ObjectLike)
)
SELECT TOP (@TopN) obj,
       CAST(SUM(CASE WHEN win = 'B' THEN cpu_us END) / 60e6 / @bh AS decimal(9,2)) AS cpu_min_hr_before,
       CAST(SUM(CASE WHEN win = 'A' THEN cpu_us END) / 60e6 / @ah AS decimal(9,2)) AS cpu_min_hr_after,
       CAST(SUM(CASE WHEN win = 'B' THEN reads END) / 1e6 / @bh AS decimal(12,2)) AS reads_m_hr_before,
       CAST(SUM(CASE WHEN win = 'A' THEN reads END) / 1e6 / @ah AS decimal(12,2)) AS reads_m_hr_after,
       CAST(SUM(CASE WHEN win = 'B' THEN execs END) / @bh AS bigint) AS stmt_execs_hr_before,
       CAST(SUM(CASE WHEN win = 'A' THEN execs END) / @ah AS bigint) AS stmt_execs_hr_after,
       SUM(CASE WHEN win = 'B' THEN failed ELSE 0 END) AS failed_before,
       SUM(CASE WHEN win = 'A' THEN failed ELSE 0 END) AS failed_after
FROM f
GROUP BY obj
ORDER BY ABS(ISNULL(SUM(CASE WHEN win = 'A' THEN cpu_us END) / @ah, 0) - ISNULL(SUM(CASE WHEN win = 'B' THEN cpu_us END) / @bh, 0)) DESC;
