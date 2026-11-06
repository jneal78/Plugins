/*
    VERIFY (read-only, no write keywords) the <MARKER> patch of <schema>.<object>.
    Run before the deploy (baseline) and again 30-60 minutes after it, and after every vendor upgrade.
    Expected after the deploy:
      - section 1: version 'patched', SET options as before;
      - section 2: the target statement drops from <before per exec> to <after per exec>;
      - section 3: per hour, "after" rows show the lower cost at the same execution rate;
      - section 4: no new errors or timeouts.
    Section 1b: every index the patch's hints rely on is 'present'.
    After a vendor upgrade: 'original' = the upgrade restored the slow version (re-apply);
    'CHANGED' = the vendor shipped a new definition (check it for the fix, or rebuild the patch from it).
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
-- EDIT ME --------------------------------------------------------------------------------------------------
DECLARE @Object       nvarchar(300) = N'<schema>.<object>',
        @Marker       nvarchar(100) = N'<MARKER>',
        @OriginalHash varchar(66)   = '<0x... original>',
        @RequiredIndexes nvarchar(max) = N'',   -- indexes the patch's hints rely on, 'schema.table.index;...'
        @TopN         int           = 8;
-------------------------------------------------------------------------------------------------------------
DECLARE @id int = OBJECT_ID(@Object);
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
DECLARE @changed_utc datetime = DATEADD(MINUTE, -@off, (SELECT modify_date FROM sys.objects WHERE object_id = @id));

-- 1. Version
SELECT o.name, CONVERT(varchar(16), o.modify_date, 120) AS modified_local,
       CASE WHEN OBJECT_DEFINITION(o.object_id) LIKE N'%' + @Marker + N'%' THEN 'patched'
            WHEN CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(o.object_id)), 1) = @OriginalHash THEN 'original'
            ELSE 'CHANGED (upgrade?) - see README' END AS version,
       CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(o.object_id)), 1) AS current_hash,
       m.uses_ansi_nulls, m.uses_quoted_identifier
FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.object_id = @id;

-- 1b. Indexes the patch's hints rely on. An upgrade that renames or drops one while keeping the patched object makes
--     every call fail (FORCESEEK without a usable index: error 8622; INDEX() on a missing index: error 308).
DECLARE @ix xml = CAST(N'<i>' + REPLACE(@RequiredIndexes, N';', N'</i><i>') + N'</i>' AS xml);
SELECT v.name AS required_index,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                         WHERE i.object_id = OBJECT_ID(PARSENAME(v.name, 3) + N'.' + PARSENAME(v.name, 2)) AND i.name = PARSENAME(v.name, 1))
            THEN 'present' ELSE 'MISSING - the patched statement will fail' END AS state
FROM (SELECT LTRIM(RTRIM(n.value('.', 'nvarchar(400)'))) AS name FROM @ix.nodes('i') x(n)) v
WHERE v.name <> N'';

-- 2. Plan cache per statement since the object was last compiled. The object's cached batches come from the per-module
--    stats, so the text lookup runs for its own entries only, not for every entry in the plan cache.
;WITH mh AS (
    SELECT sql_handle FROM sys.dm_exec_procedure_stats WHERE database_id = DB_ID() AND object_id = @id
    UNION SELECT sql_handle FROM sys.dm_exec_function_stats WHERE database_id = DB_ID() AND object_id = @id
    UNION SELECT sql_handle FROM sys.dm_exec_trigger_stats WHERE database_id = DB_ID() AND object_id = @id
)
SELECT TOP (@TopN) qs.statement_start_offset AS stmt_offset,
       CAST(LEFT(REPLACE(REPLACE(REPLACE(SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 200), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 90) AS varchar(90)) AS stmt,
       CONVERT(varchar(16), qs.creation_time, 120) AS compiled, qs.execution_count AS execs,
       CAST(qs.total_worker_time / 1000.0 / qs.execution_count AS decimal(12, 1)) AS avg_cpu_ms,
       CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS decimal(12, 1)) AS avg_ms,
       qs.total_logical_reads / qs.execution_count AS avg_reads, qs.last_dop,
       CAST(qs.total_worker_time / 60000000.0 AS decimal(12, 2)) AS total_cpu_min
FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
WHERE qs.sql_handle IN (SELECT sql_handle FROM mh)
ORDER BY qs.total_worker_time DESC;

-- 3. Query Store per local hour, from a day before the change: the object's costliest statements by query_hash
;WITH r AS (
    SELECT q.query_hash, i.start_time, rs.count_executions AS execs,
           rs.avg_cpu_time * rs.count_executions AS cpu_us, rs.avg_logical_io_reads * rs.count_executions AS reads
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE q.object_id = @id AND i.start_time >= DATEADD(DAY, -1, @changed_utc) AND i.start_time >= DATEADD(DAY, -2, GETUTCDATE())
),
top_h AS (SELECT TOP (3) query_hash FROM r GROUP BY query_hash ORDER BY SUM(cpu_us) DESC)
SELECT CONVERT(varchar(16), DATEADD(MINUTE, @off, r.start_time), 120) AS hour_local,
       CASE WHEN r.start_time >= DATEADD(HOUR, -1, @changed_utc) THEN 'after' ELSE 'before' END AS period,
       CONVERT(varchar(20), r.query_hash, 1) AS query_hash, SUM(r.execs) AS execs,
       CAST(SUM(r.cpu_us) / 1000.0 / NULLIF(SUM(r.execs), 0) AS decimal(12, 1)) AS cpu_ms_per_exec,
       CAST(SUM(r.reads) / NULLIF(SUM(r.execs), 0) AS bigint) AS reads_per_exec,
       CAST(SUM(r.cpu_us) / 60000000.0 AS decimal(9, 2)) AS cpu_min
FROM r JOIN top_h ON top_h.query_hash = r.query_hash
GROUP BY r.start_time, r.query_hash
ORDER BY r.query_hash, r.start_time;

-- 4. Errors (4) and timeouts (3) for the object, per day, last 3 days
SELECT CONVERT(varchar(10), DATEADD(MINUTE, @off, i.start_time), 120) AS day_local,
       SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS timeouts,
       SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS errors
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE q.object_id = @id AND i.start_time >= DATEADD(DAY, -3, GETUTCDATE())
GROUP BY CONVERT(varchar(10), DATEADD(MINUTE, @off, i.start_time), 120)
ORDER BY day_local;

-- 5. Business indicator that should not change (edit: rows queued / sent per hour from the object's output table)
-- SELECT DATEPART(HOUR, created_at) AS hr, COUNT(*) FROM dbo.<output_table> WITH (NOLOCK) WHERE created_at >= DATEADD(DAY, -1, GETDATE()) GROUP BY DATEPART(HOUR, created_at);
