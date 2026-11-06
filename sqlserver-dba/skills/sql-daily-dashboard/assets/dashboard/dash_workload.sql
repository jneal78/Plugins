/*  dash_workload.sql  (read-only)
    Purpose : one database's workload for the daily dashboard, from Query Store, as JSON.
              Windows (local clock hours, complete hours only):
                C = today from local midnight to the last complete hour
                A = the same clock hours 7 days ago
                B = the same clock hours on BaselineDate (a known-good day)
    Output  : five top-level FOR JSON results, each one object with one key; Build-Dashboard.ps1 merges them.
                meta   database, windows, Query Store size
                core   one array, rows tagged by "s":
                         h  = totals per window and hour          g  = per group and window
                         gh = per group, window (C, A) and hour   o  = per object and window (>= 0.25 CPU-min, or any
                                                                       timeout or error); ad hoc grouped by query_hash
                         oh = per object and hour, today (>= 0.05 CPU-min)
                stmts  statements with >= 0.5 CPU-min today or a week ago (cost, plans, text)
                waits  wait categories per window, and the objects behind today's parallelism waits
                daily  whole-day totals for the last 14 days
    Groups  : GroupsFile is a list of rule rows (prio, group, schema LIKE, name LIKE, query_hash); first match by
              prio wins. Ad hoc statements have schema and name '(adhoc)'; objects that no longer exist (for
              example recreated by an upgrade) have '(old)'. See groups_default.sql.
    Needs   : SQL Server 2017+, Query Store on, VIEW DATABASE STATE (2022: VIEW DATABASE PERFORMANCE STATE).
    Run     : from the folder that holds the groups file (sqlcmd :r takes the bare name):
              sqlcmd -S <server> -d <db> -E -I -y 0 -f 65001 -v BaselineDate=2026-10-16 GroupsFile=groups.sql
                     -i dash_workload.sql -o workload.txt
    Cost    : each statement reads Query Store once (no temp tables); a few seconds to a minute on a busy server.
              Hours are mapped with today's UTC offset; across a DST change the comparison days shift by an hour.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 10000;

DECLARE @base date = TRY_CONVERT(date, '$(BaselineDate)');
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());                                   -- local minus UTC
DECLARE @cS datetime2 = DATEADD(MINUTE, -@off, CAST(CAST(GETDATE() AS date) AS datetime2));     -- local midnight, in UTC
DECLARE @hours int = DATEDIFF(MINUTE, @cS, SYSUTCDATETIME()) / 60;
IF @hours < 1 SET @hours = 1;
DECLARE @aS datetime2 = DATEADD(DAY, -7, @cS);
DECLARE @bS datetime2 = CASE WHEN @base IS NULL THEN NULL ELSE DATEADD(MINUTE, -@off, CAST(@base AS datetime2)) END;
DECLARE @cSo datetimeoffset = CAST(@cS AS datetimeoffset), @cEo datetimeoffset = CAST(DATEADD(HOUR, @hours, @cS) AS datetimeoffset);
DECLARE @aSo datetimeoffset = CAST(@aS AS datetimeoffset), @aEo datetimeoffset = CAST(DATEADD(HOUR, @hours, @aS) AS datetimeoffset);
DECLARE @bSo datetimeoffset = CAST(@bS AS datetimeoffset), @bEo datetimeoffset = CAST(DATEADD(HOUR, @hours, @bS) AS datetimeoffset);
DECLARE @dSo datetimeoffset = CAST(DATEADD(DAY, -14, @cS) AS datetimeoffset);

-- 1. meta
SELECT JSON_QUERY((SELECT DB_NAME() AS db, CONVERT(varchar(19), GETDATE(), 126) AS now_local, @off AS utc_offset_min, @hours AS hours,
                          CONVERT(varchar(10), CAST(GETDATE() AS date), 126) AS day_c,
                          CONVERT(varchar(10), DATEADD(DAY, -7, CAST(GETDATE() AS date)), 126) AS day_a,
                          CONVERT(varchar(10), @base, 126) AS day_b,
                          o.actual_state_desc AS qs_state, o.current_storage_size_mb AS qs_used_mb, o.max_storage_size_mb AS qs_max_mb,
                          o.interval_length_minutes AS qs_interval_min
                   FROM sys.database_query_store_options o FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS meta
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;

-- 2. core: one read of the runtime stats, aggregated per query, named, grouped, then rolled up with GROUPING SETS
WITH iv AS (
    SELECT i.runtime_stats_interval_id AS id,
           CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN 'C'
                WHEN i.start_time >= @aSo AND i.start_time < @aEo THEN 'A' ELSE 'B' END AS win,
           DATEPART(HOUR, DATEADD(MINUTE, @off, i.start_time)) AS h
    FROM sys.query_store_runtime_stats_interval i
    WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo)
       OR (i.start_time >= @bSo AND i.start_time < @bEo)
),
rules AS (
    SELECT prio, CAST(grp AS nvarchar(100)) AS grp, CAST(sch_like AS nvarchar(128)) AS sch_like,
           CAST(name_like AS nvarchar(256)) AS name_like, CAST(qhash AS binary(8)) AS qhash
    FROM (VALUES
:r $(GroupsFile)
    ) v (prio, grp, sch_like, name_like, qhash)
),
qa AS (
    SELECT p.query_id, iv.win, iv.h,
           SUM(rs.avg_cpu_time * rs.count_executions) AS cpu, SUM(rs.count_executions) AS n,
           SUM(rs.avg_logical_io_reads * rs.count_executions) AS rd, SUM(rs.avg_duration * rs.count_executions) AS dur,
           SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS tmo,
           SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS err
    FROM sys.query_store_runtime_stats rs
    JOIN iv ON iv.id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    GROUP BY p.query_id, iv.win, iv.h
),
oldmap AS (            -- objects recreated by an upgrade: map the old object_id to the current object that shares
                        -- the most statement hashes with it, so a week ago and today line up under one name
    SELECT t.old_id, t.new_id
    FROM (SELECT oq.object_id AS old_id, nq.object_id AS new_id,
                 ROW_NUMBER() OVER (PARTITION BY oq.object_id ORDER BY COUNT(*) DESC, nq.object_id) AS rn
          FROM sys.query_store_query oq
          JOIN sys.query_store_query nq ON nq.query_hash = oq.query_hash AND nq.object_id <> oq.object_id AND nq.object_id <> 0
          WHERE oq.object_id <> 0 AND OBJECT_NAME(oq.object_id) IS NULL AND OBJECT_NAME(nq.object_id) IS NOT NULL
          GROUP BY oq.object_id, nq.object_id) t
    WHERE t.rn = 1
),
qo AS (
    SELECT qa.win, qa.h, qa.cpu, qa.n, qa.rd, qa.dur, qa.tmo, qa.err, nm.sch, nm.nm,
           CASE WHEN e.oid = 0 THEN 'adhoc' ELSE 'object' END AS kind,
           CASE WHEN e.oid = 0 THEN '0x' + CONVERT(varchar(20), q.query_hash, 2) END AS qhash,
           CASE WHEN e.oid = 0 THEN 'adhoc 0x' + CONVERT(varchar(20), q.query_hash, 2)
                WHEN nm.sch = '(old)' THEN CONCAT('(old object id ', e.oid, ')')
                ELSE nm.sch + '.' + nm.nm END AS obj,
           ISNULL(g.grp, CASE WHEN e.oid = 0 THEN N'Ad hoc' ELSE N'Other' END) AS grp
    FROM qa
    JOIN sys.query_store_query q ON q.query_id = qa.query_id
    LEFT JOIN oldmap m ON m.old_id = q.object_id
    CROSS APPLY (SELECT ISNULL(m.new_id, q.object_id) AS oid) e
    CROSS APPLY (SELECT CASE WHEN e.oid = 0 THEN '(adhoc)' WHEN OBJECT_NAME(e.oid) IS NULL THEN '(old)'
                             ELSE OBJECT_SCHEMA_NAME(e.oid) END AS sch,
                        CASE WHEN e.oid = 0 THEN '(adhoc)' ELSE ISNULL(OBJECT_NAME(e.oid), '(old)') END AS nm) nm
    OUTER APPLY (SELECT TOP (1) r.grp FROM rules r
                 WHERE (r.sch_like IS NULL OR nm.sch LIKE r.sch_like) AND (r.name_like IS NULL OR nm.nm LIKE r.name_like)
                   AND (r.qhash IS NULL OR (e.oid = 0 AND r.qhash = q.query_hash))
                 ORDER BY r.prio) g
)
SELECT CASE WHEN GROUPING(obj) = 0 AND GROUPING(h) = 0 THEN 'oh' WHEN GROUPING(obj) = 0 THEN 'o'
            WHEN GROUPING(grp) = 0 AND GROUPING(h) = 0 THEN 'gh' WHEN GROUPING(grp) = 0 THEN 'g' ELSE 'h' END AS s,
       win, h, grp, obj, kind, sch, nm, qhash,
       CAST(SUM(cpu) / 60e6 AS decimal(14,3)) AS cpu_min, SUM(n) AS execs, CAST(SUM(rd) AS bigint) AS reads,
       CAST(SUM(dur) / 60e6 AS decimal(14,3)) AS dur_min, SUM(tmo) AS timeouts, SUM(err) AS errors
FROM qo
GROUP BY GROUPING SETS ((win, h), (grp, win), (grp, win, h), (obj, kind, sch, nm, qhash, grp, win), (obj, win, h))
HAVING CASE WHEN GROUPING(obj) = 0 AND GROUPING(h) = 0 THEN CASE WHEN win = 'C' AND SUM(cpu) >= 3e6 THEN 1 ELSE 0 END
            WHEN GROUPING(obj) = 0 THEN CASE WHEN SUM(cpu) >= 15e6 OR SUM(tmo) + SUM(err) > 0 THEN 1 ELSE 0 END
            WHEN GROUPING(grp) = 0 AND GROUPING(h) = 0 THEN CASE WHEN win IN ('C', 'A') THEN 1 ELSE 0 END
            ELSE 1 END = 1
FOR JSON PATH, ROOT('core');

-- 3. statements: today and a week ago, with plan count and text. A statement is (object, query_hash), so the same
--    statement lines up across a code change or a recreate (new query_id, same hash); query_id is the latest one.
WITH iv AS (
    SELECT i.runtime_stats_interval_id AS id, CASE WHEN i.start_time >= @cSo THEN 'C' ELSE 'A' END AS win
    FROM sys.query_store_runtime_stats_interval i
    WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo)
),
oldmap AS (
    SELECT t.old_id, t.new_id
    FROM (SELECT oq.object_id AS old_id, nq.object_id AS new_id,
                 ROW_NUMBER() OVER (PARTITION BY oq.object_id ORDER BY COUNT(*) DESC, nq.object_id) AS rn
          FROM sys.query_store_query oq
          JOIN sys.query_store_query nq ON nq.query_hash = oq.query_hash AND nq.object_id <> oq.object_id AND nq.object_id <> 0
          WHERE oq.object_id <> 0 AND OBJECT_NAME(oq.object_id) IS NULL AND OBJECT_NAME(nq.object_id) IS NOT NULL
          GROUP BY oq.object_id, nq.object_id) t
    WHERE t.rn = 1
),
sq AS (
    SELECT ISNULL(m.new_id, q.object_id) AS oid, q.query_hash, MAX(q.query_id) AS query_id,
           SUM(CASE WHEN iv.win = 'C' THEN rs.avg_cpu_time * rs.count_executions END) AS cpuC,
           SUM(CASE WHEN iv.win = 'A' THEN rs.avg_cpu_time * rs.count_executions END) AS cpuA,
           SUM(CASE WHEN iv.win = 'C' THEN rs.count_executions END) AS nC, SUM(CASE WHEN iv.win = 'A' THEN rs.count_executions END) AS nA,
           SUM(CASE WHEN iv.win = 'C' THEN rs.avg_logical_io_reads * rs.count_executions END) AS rdC,
           SUM(CASE WHEN iv.win = 'C' THEN rs.avg_duration * rs.count_executions END) AS durC,
           COUNT(DISTINCT CASE WHEN iv.win = 'C' THEN rs.plan_id END) AS plansC,
           COUNT(DISTINCT CASE WHEN iv.win = 'A' THEN rs.plan_id END) AS plansA
    FROM sys.query_store_runtime_stats rs
    JOIN iv ON iv.id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    LEFT JOIN oldmap m ON m.old_id = q.object_id
    GROUP BY ISNULL(m.new_id, q.object_id), q.query_hash
    HAVING SUM(CASE WHEN iv.win = 'C' THEN rs.avg_cpu_time * rs.count_executions ELSE 0 END) >= 30e6
        OR SUM(CASE WHEN iv.win = 'A' THEN rs.avg_cpu_time * rs.count_executions ELSE 0 END) >= 30e6
)
SELECT TOP (400)
       CASE WHEN sq.oid = 0 THEN 'adhoc 0x' + CONVERT(varchar(20), sq.query_hash, 2)
            ELSE ISNULL(OBJECT_SCHEMA_NAME(sq.oid) + '.' + OBJECT_NAME(sq.oid), CONCAT('(old object id ', sq.oid, ')')) END AS obj,
       sq.query_id, '0x' + CONVERT(varchar(20), sq.query_hash, 2) AS query_hash,
       CAST(ISNULL(sq.cpuC, 0) / 60e6 AS decimal(14,2)) AS cpu_c, CAST(ISNULL(sq.cpuA, 0) / 60e6 AS decimal(14,2)) AS cpu_a,
       ISNULL(sq.nC, 0) AS execs_c, ISNULL(sq.nA, 0) AS execs_a,
       CAST(sq.cpuC / 1000.0 / NULLIF(sq.nC, 0) AS decimal(14,2)) AS cpu_ms_c,
       CAST(sq.cpuA / 1000.0 / NULLIF(sq.nA, 0) AS decimal(14,2)) AS cpu_ms_a,
       CAST(sq.durC / 1000.0 / NULLIF(sq.nC, 0) AS decimal(14,2)) AS dur_ms_c,
       CAST(sq.rdC / NULLIF(sq.nC, 0) AS decimal(18,0)) AS reads_per_c,
       sq.plansC AS plans_c, sq.plansA AS plans_a,
       LEFT(LTRIM(REPLACE(REPLACE(REPLACE(qt.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')), 300) AS sql_text
FROM sq
JOIN sys.query_store_query q ON q.query_id = sq.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
ORDER BY CASE WHEN ISNULL(sq.cpuC, 0) > ISNULL(sq.cpuA, 0) THEN sq.cpuC ELSE sq.cpuA END DESC
FOR JSON PATH, ROOT('stmts');

-- 4. waits: categories per window, and the objects behind today's parallelism waits
WITH iv AS (
    SELECT i.runtime_stats_interval_id AS id,
           CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN 'C'
                WHEN i.start_time >= @aSo AND i.start_time < @aEo THEN 'A' ELSE 'B' END AS win
    FROM sys.query_store_runtime_stats_interval i
    WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo)
       OR (i.start_time >= @bSo AND i.start_time < @bEo)
),
w AS (
    SELECT iv.win, ws.wait_category_desc AS category, ws.plan_id, ws.total_query_wait_time_ms AS ms
    FROM sys.query_store_wait_stats ws JOIN iv ON iv.id = ws.runtime_stats_interval_id
)
SELECT JSON_QUERY((SELECT category,
                          CAST(SUM(CASE WHEN win = 'C' THEN ms END) / 60000.0 AS decimal(12,0)) AS min_c,
                          CAST(SUM(CASE WHEN win = 'A' THEN ms END) / 60000.0 AS decimal(12,0)) AS min_a,
                          CAST(SUM(CASE WHEN win = 'B' THEN ms END) / 60000.0 AS decimal(12,0)) AS min_b
                   FROM w GROUP BY category HAVING SUM(ms) > 60000
                   ORDER BY SUM(CASE WHEN win = 'C' THEN ms END) DESC FOR JSON PATH)) AS categories,
       JSON_QUERY((SELECT TOP (15) pw.obj,
                          CAST(SUM(CASE WHEN pw.win = 'C' THEN pw.ms END) / 60000.0 AS decimal(12,0)) AS min_c,
                          CAST(SUM(CASE WHEN pw.win = 'A' THEN pw.ms END) / 60000.0 AS decimal(12,0)) AS min_a
                   FROM (SELECT w.win, w.ms,
                                CASE WHEN q.object_id = 0 THEN 'adhoc 0x' + CONVERT(varchar(20), q.query_hash, 2)
                                     ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + '.' + OBJECT_NAME(q.object_id), CONCAT('(old object id ', q.object_id, ')')) END AS obj
                         FROM w JOIN sys.query_store_plan p ON p.plan_id = w.plan_id JOIN sys.query_store_query q ON q.query_id = p.query_id
                         WHERE w.category = 'Parallelism' AND w.win IN ('A', 'C')) pw
                   GROUP BY pw.obj ORDER BY SUM(CASE WHEN pw.win = 'C' THEN pw.ms END) DESC FOR JSON PATH)) AS parallel_objects
FOR JSON PATH, ROOT('waits');

-- 5. daily: whole days, last 14 days (today is partial)
SELECT CONVERT(varchar(10), CAST(DATEADD(MINUTE, @off, i.start_time) AS date), 126) AS day,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 60e6 AS decimal(12,0)) AS cpu_min,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) * 8 / 1048576e0 AS decimal(12,0)) AS reads_gb,
       SUM(rs.count_executions) AS execs,
       SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
       SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors,
       COUNT(DISTINCT i.runtime_stats_interval_id) AS intervals
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE i.start_time >= @dSo
GROUP BY CAST(DATEADD(MINUTE, @off, i.start_time) AS date)
ORDER BY CAST(DATEADD(MINUTE, @off, i.start_time) AS date)
FOR JSON PATH, ROOT('daily');
