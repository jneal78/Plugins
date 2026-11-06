/*=====================================================================================================================
  REPRODUCTION AND VERIFICATION KIT: <Product> <schema>.<object>, <statement in a few words>
  For     : <vendor> support (level 2). Read-only: it runs no procedure, changes no data and creates no table, so it is
            safe on your test system and on a customer's production server.
  Ticket  : <ticket number / title>                                   From: <company> DBA team, <date>

  WHAT YOU SHOULD SEE
    as shipped  : <Clustered Index Scan on dbo.<table> (NodeId <n>), est <n> rows, actual <n> rows read for <n> returned>
                  <cpu> ms CPU, <elapsed> ms elapsed, <n> logical reads, <n> physical reads per run; waits mostly <SOS_SCHEDULER_YIELD / CXPACKET>
    with change : <Index Seek on <index>>, <cpu> ms CPU, <n> logical reads; the same <n> rows (section 5: same count and checksum)
  PASS        : with change <= <n> logical reads and the same rows; as shipped >= <n> logical reads (reproduced)

  HOW TO RUN
    1. Use a copy of a database at <product version> with data like ours: section 2 shows the table sizes and the value
       distribution that make the plan go wrong. A small test database usually does NOT reproduce it.
    2. In SSMS: Query > Query Options > Results > "Discard results after execution" (the statement's own rows are not
       needed; returning them adds network wait), and include the actual plan (Ctrl+M), or keep SET STATISTICS XML below.
       Or with sqlcmd:  sqlcmd -S <server> -d <database> -E -I -W -s"|" -t 600 -i <this file> -o repro_output.txt
    3. Compare sections 0-2 with ours (attached: repro_output_<company>.txt), then the run table (section 4) with
       "what you should see". The plans are in the Messages / XML output; ours are attached as .sqlplan files.
    4. Section 7 finds the same statement in any database's Query Store, to size it across customers.
  The first run is "cold" (physical reads) and the next ones "warm". Clearing the buffer pool is your call on your test
  system; this file never does it.
=====================================================================================================================*/
SET NOCOUNT ON;
SET LOCK_TIMEOUT 5000;              -- give up after 5 s waiting for a lock: the kit never blocks anyone for long
SET DEADLOCK_PRIORITY LOW;          -- if it ever deadlocks, the kit is the victim, never the application

-- EDIT ME (filled in by <company>) --------------------------------------------------------------------------------
DECLARE @Object  nvarchar(300) = N'<schema>.<object>',
        @Tables  nvarchar(max) = N'<schema>.<table1>; <schema>.<table2>',   -- for section 2
        @QueryHash binary(8)   = <0x0123456789ABCDEF>,                       -- the statement's query_hash (section 7)
        @Runs    int           = 2,                                          -- runs of each variant (1st cold, then warm)
        @ShowPlans bit         = 1;                                          -- 1 = actual plan per run (STATISTICS XML)
-- The statement's parameters, with values that reproduce the problem:
DECLARE @p1 int = <value>,                   -- e.g. the order with 120 stops
        @p2 varchar(12) = '<value>';
---------------------------------------------------------------------------------------------------------------------

-- 0. Environment fingerprint (the settings that decide the plan; compare with ours)
SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(30)) AS product_version,
       CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(30)) AS cumulative_update,
       CAST(SERVERPROPERTY('Edition') AS nvarchar(60)) AS edition,
       d.compatibility_level, d.is_read_committed_snapshot_on AS rcsi, d.snapshot_isolation_state_desc AS snapshot_isolation,
       (SELECT CAST(value AS int) FROM sys.database_scoped_configurations WHERE name = N'LEGACY_CARDINALITY_ESTIMATION') AS legacy_ce,
       (SELECT CAST(value AS int) FROM sys.database_scoped_configurations WHERE name = N'MAXDOP') AS db_maxdop,
       (SELECT CAST(value AS int) FROM sys.database_scoped_configurations WHERE name = N'PARAMETER_SNIFFING') AS parameter_sniffing,
       (SELECT CAST(value AS int) FROM sys.database_scoped_configurations WHERE name = N'QUERY_OPTIMIZER_HOTFIXES') AS optimizer_hotfixes,
       (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'max degree of parallelism') AS server_maxdop,
       (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'cost threshold for parallelism') AS cost_threshold,
       (SELECT cpu_count FROM sys.dm_os_sys_info) AS cpus,
       (SELECT actual_state_desc FROM sys.database_query_store_options) AS query_store
FROM sys.databases d WHERE d.database_id = DB_ID();

-- 1. Object version (do you test the code we run?)
SELECT @Object AS object_name, CONVERT(varchar(19), o.modify_date, 120) AS modified,
       CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(o.object_id)), 1) AS sha256,
       m.uses_ansi_nulls, m.uses_quoted_identifier,
       REPLACE(REPLACE(LEFT(OBJECT_DEFINITION(o.object_id), 300), CHAR(13), N' '), CHAR(10), N' ') AS header_start
FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.object_id = OBJECT_ID(@Object);

-- 2. Data shape: table sizes and statistics age (metadata only, no table is read)
DECLARE @tx xml = CAST(N'<t>' + REPLACE(@Tables, N';', N'</t><t>') + N'</t>' AS xml);
SELECT v.name AS table_name, SUM(ps.row_count) AS rows_, SUM(ps.used_page_count) * 8 / 1024 AS used_mb,
       (SELECT MIN(STATS_DATE(s.object_id, s.stats_id)) FROM sys.stats s WHERE s.object_id = OBJECT_ID(v.name)) AS oldest_statistics,
       (SELECT MAX(STATS_DATE(s.object_id, s.stats_id)) FROM sys.stats s WHERE s.object_id = OBJECT_ID(v.name)) AS newest_statistics
FROM (SELECT LTRIM(RTRIM(n.value('.', 'nvarchar(300)'))) AS name FROM @tx.nodes('t') x(n)) v
JOIN sys.dm_db_partition_stats ps ON ps.object_id = OBJECT_ID(v.name) AND ps.index_id IN (0, 1)
WHERE v.name <> N''
GROUP BY v.name;
-- The value distribution that drives the plan (reads the table: run it on your test system, or at a quiet time):
-- SELECT TOP (10) <key column>, COUNT(*) AS rows_ FROM <schema>.<table> WITH (NOLOCK) GROUP BY <key column> ORDER BY COUNT(*) DESC;

-- 3. Measuring: per run, this request's own CPU, reads and elapsed time, this session's waits, and the file I/O of this
--    database and tempdb (file I/O is server-wide: other activity adds to it, so read it on a quiet test system).
DECLARE @i int = 1, @variant varchar(12), @t0 datetime2, @t1 datetime2, @cpu0 bigint, @lr0 bigint, @pr0 bigint, @wr0 bigint,
        @cpu1 bigint, @lr1 bigint, @pr1 bigint, @wr1 bigint, @ws0 xml, @io0 xml, @out nvarchar(max) = N'';

-- 4. Runs: as shipped, then with the change
WHILE @i <= 2 * @Runs
BEGIN
    SET @variant = CASE WHEN @i <= @Runs THEN 'as shipped' ELSE 'with change' END;
    SET @ws0 = (SELECT wait_type AS [@t], wait_time_ms AS [@ms] FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID FOR XML PATH('w'), TYPE);
    SET @io0 = (SELECT database_id AS [@d], file_id AS [@f], num_of_bytes_read AS [@rb], num_of_bytes_written AS [@wb], io_stall_read_ms AS [@rs]
                FROM sys.dm_io_virtual_file_stats(NULL, NULL) WHERE database_id IN (DB_ID(), 2) FOR XML PATH('f'), TYPE);
    -- CPU and reads are read last, just before the statement, so the snapshots above don't count as its cost
    SELECT @cpu0 = cpu_time, @lr0 = logical_reads, @pr0 = reads, @wr0 = writes FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();
    -- the actual plan and per-table reads (with read-ahead) for the statement only, in the XML / Messages output
    IF @ShowPlans = 1 SET STATISTICS XML ON;
    SET STATISTICS IO, TIME ON;

    IF @variant = 'as shipped'
    BEGIN
        ------------------------------------------------------------------------------------------- AS SHIPPED
        -- <the statement exactly as the product runs it, in its read-only SELECT form (target removed), same
        --  SELECT list, joins and predicates, using @p1, @p2>
        SELECT TOP (0) 1 AS replace_me WHERE @p1 = @p1 AND @p2 = @p2;
    END
    ELSE
    BEGIN
        ------------------------------------------------------------------------------------------- WITH THE CHANGE
        -- <the same statement with the proposed hint or rewrite, marked -- <MARKER>>
        SELECT TOP (0) 1 AS replace_me WHERE @p1 = @p1 AND @p2 = @p2;
    END
    -- counters first, in their own statement: computing the I/O and wait deltas below costs CPU of its own
    SELECT @cpu1 = cpu_time, @lr1 = logical_reads, @pr1 = reads, @wr1 = writes, @t1 = SYSDATETIME()
    FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET STATISTICS XML OFF;
    SET STATISTICS IO, TIME OFF;

    SELECT @out = @out + (
        SELECT @i AS [@run], @variant AS [@variant],
               (@cpu1 - @cpu0) AS [@cpu_ms], DATEDIFF(MILLISECOND, @t0, @t1) AS [@elapsed_ms],
               (@lr1 - @lr0) AS [@logical_reads], (@pr1 - @pr0) AS [@physical_reads], (@wr1 - @wr0) AS [@writes],
               (SELECT CAST(SUM(f.num_of_bytes_read - i0.n.value('@rb', 'bigint')) / 1048576.0 AS decimal(12,1))
                FROM sys.dm_io_virtual_file_stats(NULL, NULL) f
                JOIN @io0.nodes('f') i0(n) ON i0.n.value('@d', 'int') = f.database_id AND i0.n.value('@f', 'int') = f.file_id
                WHERE f.database_id = DB_ID()) AS [@db_read_mb],
               (SELECT SUM(f.io_stall_read_ms - i0.n.value('@rs', 'bigint'))
                FROM sys.dm_io_virtual_file_stats(NULL, NULL) f
                JOIN @io0.nodes('f') i0(n) ON i0.n.value('@d', 'int') = f.database_id AND i0.n.value('@f', 'int') = f.file_id
                WHERE f.database_id = DB_ID()) AS [@db_read_stall_ms],
               (SELECT CAST(SUM(f.num_of_bytes_written - i0.n.value('@wb', 'bigint')) / 1048576.0 AS decimal(12,1))
                FROM sys.dm_io_virtual_file_stats(NULL, NULL) f
                JOIN @io0.nodes('f') i0(n) ON i0.n.value('@d', 'int') = f.database_id AND i0.n.value('@f', 'int') = f.file_id
                WHERE f.database_id = 2) AS [@tempdb_write_mb],
               (SELECT STRING_AGG(CONCAT(w.wait_type, N' ', w.wait_time_ms - ISNULL(w0.ms, 0), N' ms'), N', ')
                         WITHIN GROUP (ORDER BY w.wait_time_ms - ISNULL(w0.ms, 0) DESC)
                FROM sys.dm_exec_session_wait_stats w
                LEFT JOIN (SELECT n.value('@t', 'nvarchar(60)') AS t, n.value('@ms', 'bigint') AS ms FROM @ws0.nodes('w') x(n)) w0 ON w0.t = w.wait_type
                WHERE w.session_id = @@SPID AND w.wait_time_ms - ISNULL(w0.ms, 0) > 0) AS [@waits]
        FOR XML PATH('run'));
    SET @i += 1;
END

-- 4 (results). One row per run. Compare with "what you should see" in the header.
DECLARE @res xml = CAST(@out AS xml);
SELECT n.value('@run', 'int') AS run, n.value('@variant', 'varchar(12)') AS variant,
       n.value('@cpu_ms', 'bigint') AS cpu_ms, n.value('@elapsed_ms', 'bigint') AS elapsed_ms,
       n.value('@logical_reads', 'bigint') AS logical_reads, n.value('@physical_reads', 'bigint') AS physical_reads,
       n.value('@writes', 'bigint') AS writes, n.value('@db_read_mb', 'decimal(12,1)') AS db_read_mb,
       n.value('@db_read_stall_ms', 'bigint') AS db_read_stall_ms, n.value('@tempdb_write_mb', 'decimal(12,1)') AS tempdb_write_mb,
       LEFT(n.value('@waits', 'nvarchar(400)'), 200) AS top_waits
FROM @res.nodes('run') x(n);

-- 5. Same rows? Count and checksum of each variant's result (a separate query per variant: the plan may differ from
--    the measured runs, this is only about the rows).
-- SELECT 'as shipped'  AS variant, COUNT(*) AS rows_, CHECKSUM_AGG(BINARY_CHECKSUM(*)) AS checksum_ FROM (<as shipped>) x;
-- SELECT 'with change' AS variant, COUNT(*) AS rows_, CHECKSUM_AGG(BINARY_CHECKSUM(*)) AS checksum_ FROM (<with change>) x;

-- 6. Our measurements for the same runs, for side-by-side comparison
SELECT * FROM (VALUES
    ('as shipped (ours)',  <cpu_ms>, <elapsed_ms>, <logical_reads>, <physical_reads cold>, '<top waits>'),
    ('with change (ours)', <cpu_ms>, <elapsed_ms>, <logical_reads>, <physical_reads cold>, '<top waits>')
) v (variant, cpu_ms, elapsed_ms, logical_reads, physical_reads, top_waits);

-- 7. The same statement in Query Store (this database, last 7 days), per plan: how much it costs here, and which plan
--    is the bad one. Run it on other customers' databases to size the problem.
SELECT p.plan_id, q.query_id, CONVERT(varchar(20), q.query_hash, 1) AS query_hash, CONVERT(varchar(20), p.query_plan_hash, 1) AS plan_hash,
       SUM(rs.count_executions) AS execs,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS decimal(14,2)) AS cpu_ms_per_exec,
       CAST(SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS decimal(14,2)) AS ms_per_exec,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS bigint) AS reads_per_exec,
       CAST(SUM(rs.avg_physical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS bigint) AS physical_reads_per_exec,
       MAX(rs.max_dop) AS max_dop, CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 60e6 AS decimal(12,1)) AS cpu_min_7_days,
       CONVERT(varchar(16), MAX(rs.last_execution_time), 120) AS last_run_utc
FROM sys.query_store_query q
JOIN sys.query_store_plan p ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE q.query_hash = @QueryHash AND i.start_time >= DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY p.plan_id, q.query_id, q.query_hash, p.query_plan_hash
ORDER BY cpu_min_7_days DESC;
-- The plan itself: SELECT TRY_CAST(query_plan AS xml) FROM sys.query_store_plan WHERE plan_id = <plan_id>  (click it in SSMS)
