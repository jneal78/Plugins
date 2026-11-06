/*
    health_workload.sql - READ-ONLY workload comparison from Query Store (current database).
    Today (local midnight -> last complete hour) vs the same clock hours 7 days ago (A) and on a baseline date (B).
    SELECT-only: CTEs and derived tables, no temp tables. Run once per database:
        sqlcmd -S <server> -d <AppDb>   -E -I -W -s"|" -v BaselineDate=<yyyy-mm-dd> -i health_workload.sql
        sqlcmd -S <server> -d <OtherDb> -E -I -W -s"|" -v BaselineDate=<yyyy-mm-dd> -i health_workload.sql
    BaselineDate = a known-good "steady state" day (yyyy-mm-dd). Columns: _a = a week ago, _b = baseline, _c = today.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());                     -- local minus UTC, minutes (e.g. -300 for CDT)
DECLARE @cS datetime2 = DATEADD(MINUTE, -@off, CAST(CAST(GETDATE() AS date) AS datetime2));   -- today's local midnight, in UTC
DECLARE @hours int = DATEDIFF(MINUTE, @cS, SYSUTCDATETIME()) / 60;                 -- complete hours so far today
IF @hours < 1 SET @hours = 1;
DECLARE @base date = TRY_CONVERT(date, '$(BaselineDate)');
DECLARE @aS datetime2 = DATEADD(DAY, -7, @cS);
DECLARE @bS datetime2 = CASE WHEN @base IS NULL THEN NULL ELSE DATEADD(MINUTE, -@off, CAST(@base AS datetime2)) END;
DECLARE @cSo datetimeoffset = CAST(@cS AS datetimeoffset), @cEo datetimeoffset = CAST(DATEADD(HOUR, @hours, @cS) AS datetimeoffset);
DECLARE @aSo datetimeoffset = CAST(@aS AS datetimeoffset), @aEo datetimeoffset = CAST(DATEADD(HOUR, @hours, @aS) AS datetimeoffset);
DECLARE @bSo datetimeoffset = CAST(@bS AS datetimeoffset), @bEo datetimeoffset = CAST(DATEADD(HOUR, @hours, @bS) AS datetimeoffset);

SELECT DB_NAME() AS db, CONVERT(varchar(16), GETDATE(), 120) AS now_local, @hours AS hours_compared,
       CONVERT(varchar(10), DATEADD(MINUTE, @off, @aS), 120) AS day_a_week_ago, CONVERT(varchar(10), @base, 120) AS day_b_baseline, CONVERT(varchar(10), CAST(GETDATE() AS date), 120) AS day_c_today;

-- 1. Hour by hour (local hour)
WITH r AS (
  SELECT CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN 'C' WHEN i.start_time >= @aSo AND i.start_time < @aEo THEN 'A' ELSE 'B' END AS win,
         CASE WHEN i.start_time >= @cSo THEN DATEDIFF(MINUTE, @cSo, i.start_time) WHEN i.start_time >= @aSo AND i.start_time < @aEo THEN DATEDIFF(MINUTE, @aSo, i.start_time) ELSE DATEDIFF(MINUTE, @bSo, i.start_time) END / 60 AS h,
         rs.count_executions AS n, rs.avg_cpu_time * rs.count_executions AS cpu, rs.avg_logical_io_reads * rs.count_executions AS reads, rs.execution_type
  FROM sys.query_store_runtime_stats rs JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
  WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo) OR (i.start_time >= @bSo AND i.start_time < @bEo)
)
SELECT RIGHT('0' + CAST(h AS varchar(2)), 2) + ':00' AS hour_local,
       CAST(SUM(CASE WHEN win = 'A' THEN cpu END) / 60e6 AS decimal(9,0)) AS cpu_min_a, CAST(SUM(CASE WHEN win = 'B' THEN cpu END) / 60e6 AS decimal(9,0)) AS cpu_min_b,
       CAST(SUM(CASE WHEN win = 'C' THEN cpu END) / 60e6 AS decimal(9,0)) AS cpu_min_c,
       CAST(SUM(CASE WHEN win = 'A' THEN reads END) * 8 / 1048576e0 AS decimal(9,0)) AS reads_gb_a, CAST(SUM(CASE WHEN win = 'C' THEN reads END) * 8 / 1048576e0 AS decimal(9,0)) AS reads_gb_c,
       CAST(SUM(CASE WHEN win = 'C' THEN n END) / 1e6 AS decimal(9,1)) AS execs_m_c,
       SUM(CASE WHEN win = 'A' AND execution_type = 3 THEN n ELSE 0 END) AS timeouts_a, SUM(CASE WHEN win = 'C' AND execution_type = 3 THEN n ELSE 0 END) AS timeouts_c
FROM r GROUP BY h ORDER BY h;

-- 2. Totals, timeouts and errors per window
WITH r AS (
  SELECT CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN 'C' WHEN i.start_time >= @aSo AND i.start_time < @aEo THEN 'A' ELSE 'B' END AS win,
         rs.count_executions AS n, rs.avg_cpu_time * rs.count_executions AS cpu, rs.avg_logical_io_reads * rs.count_executions AS reads, rs.execution_type
  FROM sys.query_store_runtime_stats rs JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
  WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo) OR (i.start_time >= @bSo AND i.start_time < @bEo)
)
SELECT win, CAST(SUM(cpu) / 60e6 AS decimal(9,0)) AS cpu_min, CAST(SUM(cpu) / 60e6 / @hours / 60 AS decimal(5,1)) AS avg_cores_busy,
       CAST(SUM(reads) * 8 / 1048576e0 / @hours AS decimal(9,0)) AS reads_gb_per_hour, CAST(SUM(n) / 1e6 AS decimal(9,1)) AS execs_m,
       SUM(CASE WHEN execution_type = 3 THEN n ELSE 0 END) AS timeouts, SUM(CASE WHEN execution_type = 4 THEN n ELSE 0 END) AS errors
FROM r GROUP BY win ORDER BY win;

-- 3. Waits by category per window (minutes)
SELECT ws.wait_category_desc,
       CAST(SUM(CASE WHEN i.start_time >= @aSo AND i.start_time < @aEo THEN ws.total_query_wait_time_ms END) / 60000.0 AS decimal(9,0)) AS wait_min_a,
       CAST(SUM(CASE WHEN i.start_time >= @bSo AND i.start_time < @bEo THEN ws.total_query_wait_time_ms END) / 60000.0 AS decimal(9,0)) AS wait_min_b,
       CAST(SUM(CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN ws.total_query_wait_time_ms END) / 60000.0 AS decimal(9,0)) AS wait_min_c
FROM sys.query_store_wait_stats ws JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo) OR (i.start_time >= @bSo AND i.start_time < @bEo)
GROUP BY ws.wait_category_desc HAVING SUM(ws.total_query_wait_time_ms) > 60000
ORDER BY SUM(CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN ws.total_query_wait_time_ms END) DESC;

-- 4. Top 30 objects today (ad hoc grouped by query_hash) with the same object a week ago and on the baseline
WITH r AS (
  SELECT CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN 'C' WHEN i.start_time >= @aSo AND i.start_time < @aEo THEN 'A' ELSE 'B' END AS win,
         CASE WHEN q.object_id > 0 THEN CONCAT(OBJECT_SCHEMA_NAME(q.object_id), '.', OBJECT_NAME(q.object_id)) ELSE CONCAT('adhoc 0x', CONVERT(varchar(20), q.query_hash, 2)) END AS obj,
         rs.count_executions AS n, rs.avg_cpu_time * rs.count_executions AS cpu, rs.avg_logical_io_reads * rs.count_executions AS reads, rs.execution_type
  FROM sys.query_store_runtime_stats rs JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
  JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id JOIN sys.query_store_query q ON q.query_id = p.query_id
  WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo) OR (i.start_time >= @bSo AND i.start_time < @bEo)
), g AS (
  SELECT obj, SUM(CASE WHEN win = 'A' THEN cpu END) AS cpuA, SUM(CASE WHEN win = 'B' THEN cpu END) AS cpuB, SUM(CASE WHEN win = 'C' THEN cpu END) AS cpuC,
         SUM(CASE WHEN win = 'C' THEN n END) AS nC, SUM(CASE WHEN win = 'C' THEN reads END) AS readsC,
         SUM(CASE WHEN win = 'C' AND execution_type = 3 THEN n ELSE 0 END) AS timeoutsC
  FROM r GROUP BY obj
), t AS (SELECT SUM(cpuC) AS tot FROM g)
SELECT TOP (30) g.obj, CAST(g.cpuC / 60e6 AS decimal(9,1)) AS cpu_min_c, CAST(100 * g.cpuC / t.tot AS decimal(5,1)) AS pct_c,
       CAST(g.cpuA / 60e6 AS decimal(9,1)) AS cpu_min_a, CAST(g.cpuB / 60e6 AS decimal(9,1)) AS cpu_min_b,
       g.nC AS stmt_execs_c, CAST(g.cpuC / 1000.0 / NULLIF(g.nC, 0) AS decimal(12,2)) AS cpu_ms_per_stmt, CAST(g.readsC / NULLIF(g.nC, 0) AS bigint) AS reads_per_stmt, g.timeoutsC AS timeouts_c
FROM g CROSS JOIN t WHERE g.cpuC IS NOT NULL ORDER BY g.cpuC DESC;

-- 5. Biggest movers vs a week ago (statement level, at least 5 CPU-min either day): regressions and wins
WITH r AS (
  SELECT CASE WHEN i.start_time >= @cSo AND i.start_time < @cEo THEN 'C' ELSE 'A' END AS win, q.query_id, q.object_id,
         rs.count_executions AS n, rs.avg_cpu_time * rs.count_executions AS cpu
  FROM sys.query_store_runtime_stats rs JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
  JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id JOIN sys.query_store_query q ON q.query_id = p.query_id
  WHERE (i.start_time >= @cSo AND i.start_time < @cEo) OR (i.start_time >= @aSo AND i.start_time < @aEo)
), s AS (
  SELECT query_id, MAX(object_id) AS object_id, SUM(CASE WHEN win = 'A' THEN cpu ELSE 0 END) AS cpuA, SUM(CASE WHEN win = 'C' THEN cpu ELSE 0 END) AS cpuC,
         SUM(CASE WHEN win = 'A' THEN n ELSE 0 END) AS nA, SUM(CASE WHEN win = 'C' THEN n ELSE 0 END) AS nC
  FROM r GROUP BY query_id
)
SELECT TOP (15) s.query_id, ISNULL(OBJECT_NAME(s.object_id), 'adhoc') AS obj, CAST(s.cpuA / 60e6 AS decimal(9,1)) AS cpu_min_a, CAST(s.cpuC / 60e6 AS decimal(9,1)) AS cpu_min_c,
       CAST(s.cpuA / 1000.0 / NULLIF(s.nA, 0) AS decimal(12,1)) AS ms_a, CAST(s.cpuC / 1000.0 / NULLIF(s.nC, 0) AS decimal(12,1)) AS ms_c, s.nA, s.nC,
       LEFT(REPLACE(REPLACE(REPLACE(qt.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 100) AS sql_text
FROM s JOIN sys.query_store_query q ON q.query_id = s.query_id JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE s.cpuA >= 5 * 60e6 OR s.cpuC >= 5 * 60e6
ORDER BY ABS(s.cpuC - s.cpuA) DESC;
