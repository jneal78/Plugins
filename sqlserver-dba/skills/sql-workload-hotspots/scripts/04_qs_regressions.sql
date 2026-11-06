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
        @TopN       int           = 25;
---------------------------------------------------------------------------------------------------------------------

DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
SET @AfterTo    = ISNULL(@AfterTo, GETDATE());
SET @AfterFrom  = ISNULL(@AfterFrom, DATEADD(HOUR, -4, @AfterTo));
SET @BeforeFrom = ISNULL(@BeforeFrom, DATEADD(DAY, -7, @AfterFrom));
SET @BeforeTo   = ISNULL(@BeforeTo, DATEADD(DAY, -7, @AfterTo));
DECLARE @b0 datetime = DATEADD(MINUTE, -@off, @BeforeFrom), @b1 datetime = DATEADD(MINUTE, -@off, @BeforeTo),
        @a0 datetime = DATEADD(MINUTE, -@off, @AfterFrom),  @a1 datetime = DATEADD(MINUTE, -@off, @AfterTo);
DECLARE @bh decimal(9,3) = DATEDIFF(SECOND, @b0, @b1) / 3600.0, @ah decimal(9,3) = DATEDIFF(SECOND, @a0, @a1) / 3600.0;

SELECT CONVERT(varchar(16), @BeforeFrom, 120) AS before_from, CONVERT(varchar(16), @BeforeTo, 120) AS before_to, CAST(@bh AS decimal(7,2)) AS before_hours,
       CONVERT(varchar(16), @AfterFrom, 120) AS after_from, CONVERT(varchar(16), @AfterTo, 120) AS after_to, CAST(@ah AS decimal(7,2)) AS after_hours,
       ISNULL(@Schema, N'(all)') AS scope_schema, ISNULL(@ObjectLike, N'(all)') AS scope_object;

-- 1. Statement-level aggregates for both windows (scoped), then: regressions
;WITH live AS (
    SELECT q.query_hash, MIN(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id)) AS obj
    FROM sys.query_store_query q
    WHERE q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NOT NULL
    GROUP BY q.query_hash
),
r AS (
    SELECT q.query_hash, q.query_id, q.query_text_id,
           CASE WHEN q.object_id = 0 THEN N'(ad hoc)'
                ELSE COALESCE(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), lv.obj,
                              N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END AS obj,
           CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           rs.execution_type, rs.count_executions AS execs, rs.avg_cpu_time * rs.count_executions AS cpu_us,
           rs.avg_logical_io_reads * rs.count_executions AS reads, rs.avg_duration * rs.count_executions AS dur_us, rs.max_dop, rs.plan_id
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    LEFT JOIN live lv ON lv.query_hash = q.query_hash AND q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NULL
    WHERE ((i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1))
),
f AS (
    SELECT * FROM r
    WHERE (@Schema IS NULL OR obj LIKE @Schema + N'.%' OR (obj LIKE N'(dropped id%' AND @ObjectLike IS NULL))
      AND (@ObjectLike IS NULL OR obj LIKE @ObjectLike)
),
s AS (
    SELECT query_hash, win, MAX(obj) AS obj, MAX(query_id) AS query_id, MAX(query_text_id) AS query_text_id,
           SUM(execs) AS execs, SUM(cpu_us) AS cpu_us, SUM(reads) AS reads, SUM(dur_us) AS dur_us,
           MAX(max_dop) AS max_dop, COUNT(DISTINCT plan_id) AS plans,
           SUM(CASE WHEN execution_type IN (3, 4) THEN execs ELSE 0 END) AS failed
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
;WITH live AS (
    SELECT q.query_hash, MIN(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id)) AS obj
    FROM sys.query_store_query q
    WHERE q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NOT NULL
    GROUP BY q.query_hash
),
r AS (
    SELECT q.query_hash, q.query_id, q.query_text_id,
           CASE WHEN q.object_id = 0 THEN N'(ad hoc)'
                ELSE COALESCE(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), lv.obj,
                              N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END AS obj,
           CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           rs.count_executions AS execs, rs.avg_cpu_time * rs.count_executions AS cpu_us,
           rs.avg_logical_io_reads * rs.count_executions AS reads, rs.max_dop
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    LEFT JOIN live lv ON lv.query_hash = q.query_hash AND q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NULL
    WHERE ((i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1))
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
;WITH live AS (
    SELECT q.query_hash, MIN(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id)) AS obj
    FROM sys.query_store_query q
    WHERE q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NOT NULL
    GROUP BY q.query_hash
),
r AS (
    SELECT CASE WHEN q.object_id = 0 THEN N'(ad hoc, all)'
                ELSE COALESCE(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), lv.obj,
                              N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END AS obj,
           CASE WHEN i.start_time >= @a0 AND i.start_time < @a1 THEN 'A' ELSE 'B' END AS win,
           rs.execution_type, rs.count_executions AS execs, rs.avg_cpu_time * rs.count_executions AS cpu_us,
           rs.avg_logical_io_reads * rs.count_executions AS reads
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    LEFT JOIN live lv ON lv.query_hash = q.query_hash AND q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NULL
    WHERE ((i.start_time >= @a0 AND i.start_time < @a1) OR (i.start_time >= @b0 AND i.start_time < @b1))
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
       SUM(CASE WHEN win = 'B' AND execution_type IN (3, 4) THEN execs ELSE 0 END) AS failed_before,
       SUM(CASE WHEN win = 'A' AND execution_type IN (3, 4) THEN execs ELSE 0 END) AS failed_after
FROM f
GROUP BY obj
ORDER BY ABS(ISNULL(SUM(CASE WHEN win = 'A' THEN cpu_us END) / @ah, 0) - ISNULL(SUM(CASE WHEN win = 'B' THEN cpu_us END) / @bh, 0)) DESC;
