/*  07_live_delta_benchmark.sql  (read-only)
    Purpose : measure what is happening right now, independent of Query Store intervals: read the plan-cache
              counters of a few objects (and optionally one ad hoc query_hash), wait @Sample, read them again and
              report the difference per call. Use it to benchmark a fix minutes after it is deployed, or to get
              a clean per-call figure for a vendor ticket.
    Needs   : SQL Server 2016+, VIEW SERVER STATE. Nothing is stored: the first reading is kept in an xml variable.
    Params  : EDIT ME block. @Objects = comma-separated schema.name list (procedures, scalar functions, triggers).
    Reading : calls come from sys.dm_exec_procedure_stats / function_stats / trigger_stats (one row per call);
              stmt_* columns sum the object's statements from sys.dm_exec_query_stats (for a scalar function that
              is the per-row cost; for a procedure it excludes nested procedure calls).
              cpu_min_per_hr = this object's CPU at the sampled rate. The last result is all of SQL Server, every
              database, over the sample: from the scheduler counters when the edition fills them, otherwise
              from the per-minute ring buffer.
              If the object was recompiled or its plan evicted during the sample, its counters restart and the
              row is flagged 'counters reset': run the sample again.
              Run it at a representative time; a 5-minute sample at a quiet moment says little about the peak.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 07_live_delta_benchmark.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Objects   nvarchar(max) = N'dbo.SomeProc,dbo.SomeFunction',
        @QueryHash binary(8)     = NULL,          -- optional ad hoc statement, e.g. 0x0123456789ABCDEF
        @Sample    char(8)       = '00:05:00';    -- hh:mm:ss
---------------------------------------------------------------------------------------------------------------------

DECLARE @t0 datetime2 = SYSDATETIME(), @t1 datetime2, @snap xml, @busy0 bigint, @busy1 bigint;
DECLARE @schedulers int = (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE');
DECLARE @list xml = CAST(N'<i>' + REPLACE(@Objects, N',', N'</i><i>') + N'</i>' AS xml);   -- comma list as xml (no STRING_SPLIT: works at any compatibility level)

-- First reading
;WITH objs AS (
    SELECT LTRIM(RTRIM(x.n.value('.', 'nvarchar(300)'))) AS name, OBJECT_ID(LTRIM(RTRIM(x.n.value('.', 'nvarchar(300)')))) AS oid
    FROM @list.nodes('/i') x(n) WHERE LTRIM(RTRIM(x.n.value('.', 'nvarchar(300)'))) <> N''
),
m AS (
    SELECT object_id, SUM(execution_count) AS n, SUM(total_worker_time) AS cpu, SUM(total_logical_reads) AS rd, SUM(total_elapsed_time) AS el
    FROM (SELECT object_id, execution_count, total_worker_time, total_logical_reads, total_elapsed_time FROM sys.dm_exec_procedure_stats WHERE database_id = DB_ID()
          UNION ALL
          SELECT object_id, execution_count, total_worker_time, total_logical_reads, total_elapsed_time FROM sys.dm_exec_function_stats WHERE database_id = DB_ID()
          UNION ALL
          SELECT object_id, execution_count, total_worker_time, total_logical_reads, total_elapsed_time FROM sys.dm_exec_trigger_stats WHERE database_id = DB_ID()) x
    GROUP BY object_id
),
st AS (
    SELECT t.objectid AS object_id, MAX(qs.execution_count) AS n, SUM(qs.total_worker_time) AS cpu, SUM(qs.total_logical_reads) AS rd
    FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
    WHERE t.dbid = DB_ID() AND t.objectid IN (SELECT oid FROM objs)
    GROUP BY t.objectid
),
cur AS (
    SELECT o.name, o.oid, m.n, m.cpu, m.rd, m.el, st.n AS sn, st.cpu AS scpu, st.rd AS srd
    FROM objs o LEFT JOIN m ON m.object_id = o.oid LEFT JOIN st ON st.object_id = o.oid
    UNION ALL
    SELECT N'query_hash ' + CONVERT(nvarchar(20), @QueryHash, 1), NULL, SUM(execution_count), SUM(total_worker_time),
           SUM(total_logical_reads), SUM(total_elapsed_time), NULL, NULL, NULL
    FROM sys.dm_exec_query_stats WHERE @QueryHash IS NOT NULL AND query_hash = @QueryHash
    HAVING @QueryHash IS NOT NULL
)
SELECT @snap = (SELECT name, n, cpu, rd, el, sn, scpu, srd FROM cur FOR XML RAW('o'), TYPE);
SELECT @busy0 = SUM(total_cpu_usage_ms) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE';

SELECT CONVERT(varchar(19), @t0, 120) AS sample_started, @Sample AS sample_length, @schedulers AS schedulers;
RAISERROR(N'Sampling... results print when the wait ends.', 0, 1) WITH NOWAIT;

WAITFOR DELAY @Sample;
SET @t1 = SYSDATETIME();
SELECT @busy1 = SUM(total_cpu_usage_ms) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE';
DECLARE @sec decimal(12,3) = DATEDIFF(MILLISECOND, @t0, @t1) / 1000.0;

-- Second reading and the per-call deltas
;WITH objs AS (
    SELECT LTRIM(RTRIM(x.n.value('.', 'nvarchar(300)'))) AS name, OBJECT_ID(LTRIM(RTRIM(x.n.value('.', 'nvarchar(300)')))) AS oid
    FROM @list.nodes('/i') x(n) WHERE LTRIM(RTRIM(x.n.value('.', 'nvarchar(300)'))) <> N''
),
m AS (
    SELECT object_id, SUM(execution_count) AS n, SUM(total_worker_time) AS cpu, SUM(total_logical_reads) AS rd, SUM(total_elapsed_time) AS el
    FROM (SELECT object_id, execution_count, total_worker_time, total_logical_reads, total_elapsed_time FROM sys.dm_exec_procedure_stats WHERE database_id = DB_ID()
          UNION ALL
          SELECT object_id, execution_count, total_worker_time, total_logical_reads, total_elapsed_time FROM sys.dm_exec_function_stats WHERE database_id = DB_ID()
          UNION ALL
          SELECT object_id, execution_count, total_worker_time, total_logical_reads, total_elapsed_time FROM sys.dm_exec_trigger_stats WHERE database_id = DB_ID()) x
    GROUP BY object_id
),
st AS (
    SELECT t.objectid AS object_id, MAX(qs.execution_count) AS n, SUM(qs.total_worker_time) AS cpu, SUM(qs.total_logical_reads) AS rd
    FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
    WHERE t.dbid = DB_ID() AND t.objectid IN (SELECT oid FROM objs)
    GROUP BY t.objectid
),
cur AS (
    SELECT o.name, m.n, m.cpu, m.rd, m.el, st.n AS sn, st.cpu AS scpu, st.rd AS srd
    FROM objs o LEFT JOIN m ON m.object_id = o.oid LEFT JOIN st ON st.object_id = o.oid
    UNION ALL
    SELECT N'query_hash ' + CONVERT(nvarchar(20), @QueryHash, 1), SUM(execution_count), SUM(total_worker_time),
           SUM(total_logical_reads), SUM(total_elapsed_time), NULL, NULL, NULL
    FROM sys.dm_exec_query_stats WHERE @QueryHash IS NOT NULL AND query_hash = @QueryHash
    HAVING @QueryHash IS NOT NULL
),
prev AS (
    SELECT o.n.value('@name', 'nvarchar(300)') AS name, o.n.value('@n', 'bigint') AS n, o.n.value('@cpu', 'bigint') AS cpu,
           o.n.value('@rd', 'bigint') AS rd, o.n.value('@el', 'bigint') AS el, o.n.value('@sn', 'bigint') AS sn,
           o.n.value('@scpu', 'bigint') AS scpu, o.n.value('@srd', 'bigint') AS srd
    FROM @snap.nodes('/o') o(n)
),
d AS (
    SELECT c.name, c.n - p.n AS calls, c.cpu - p.cpu AS cpu, c.rd - p.rd AS rd, c.el - p.el AS el,
           c.sn - p.sn AS stmt_execs, c.scpu - p.scpu AS stmt_cpu, c.srd - p.srd AS stmt_rd,
           CASE WHEN c.n < p.n OR c.cpu < p.cpu OR c.sn < p.sn THEN 'counters reset - run again'
                WHEN p.n IS NULL AND p.sn IS NULL AND c.n IS NULL AND c.sn IS NULL THEN 'not in plan cache'
                WHEN p.n IS NULL AND p.sn IS NULL THEN 'first seen during sample - run again' ELSE '' END AS note
    FROM cur c LEFT JOIN prev p ON p.name = c.name
)
SELECT name, calls, CAST(calls * 3600 / @sec AS bigint) AS calls_per_hr,
       CAST(cpu / 1000.0 / NULLIF(calls, 0) AS decimal(14,2)) AS cpu_ms_per_call,
       rd / NULLIF(calls, 0) AS reads_per_call,
       CAST(el / 1000.0 / NULLIF(calls, 0) AS decimal(14,2)) AS elapsed_ms_per_call,
       CAST(ISNULL(cpu, stmt_cpu) / 60e6 * 3600 / @sec AS decimal(9,2)) AS cpu_min_per_hr,
       stmt_execs, CAST(stmt_cpu / 1000.0 / NULLIF(stmt_execs, 0) AS decimal(14,3)) AS stmt_cpu_ms_per_exec,
       stmt_rd / NULLIF(stmt_execs, 0) AS stmt_reads_per_exec, note
FROM d;

-- SQL Server CPU over the sample. The scheduler counter is exact but some editions leave it at 0; the ring buffer
-- (one reading per minute) is the fallback, so samples shorter than 2 minutes may show NULL there.
;WITH rb AS (
    SELECT CAST(record AS xml) AS r
    FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%'
      AND [timestamp] >= (SELECT ms_ticks FROM sys.dm_os_sys_info) - CAST(@sec * 1000 AS bigint)
)
SELECT CAST(@sec AS decimal(9,1)) AS seconds_sampled,
       CAST(NULLIF(@busy1 - @busy0, 0) / 10.0 / @sec / @schedulers AS decimal(5,1)) AS sql_cpu_pct_schedulers,
       (SELECT AVG(r.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')) FROM rb) AS sql_cpu_pct_ring_buffer,
       (SELECT COUNT(*) FROM rb) AS ring_buffer_minutes;
