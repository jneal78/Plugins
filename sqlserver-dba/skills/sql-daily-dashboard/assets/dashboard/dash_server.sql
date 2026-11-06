/*  dash_server.sql  (read-only)
    Purpose : point-in-time server state for the daily dashboard, as a single JSON document: instance, CPU meter
              (ring buffer, ~4 h, per minute), a 10-second rate sample, memory, workers, sessions, availability
              group, tempdb, volumes, I/O latency since restart, log backups, blocking and long-running requests,
              deadlocks, key settings and Query Store options of the current database.
    Needs   : VIEW SERVER STATE (2022: VIEW SERVER PERFORMANCE STATE).
    Run     : sqlcmd -S <server> -d <main db> -E -I -h -1 -y 0 -f 65001 -i dash_server.sql -o server.json
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 5000;

-- 10-second sample of the per-second counters
DECLARE @b0 bigint, @c0 bigint, @r0 bigint, @t0 bigint, @s0 bigint, @l0 bigint, @w0 datetime2 = SYSDATETIME();
SELECT @b0 = MAX(CASE WHEN counter_name = 'Batch Requests/sec' THEN cntr_value END),
       @c0 = MAX(CASE WHEN counter_name = 'SQL Compilations/sec' THEN cntr_value END),
       @r0 = MAX(CASE WHEN counter_name = 'SQL Re-Compilations/sec' THEN cntr_value END),
       @t0 = MAX(CASE WHEN counter_name = 'Transactions/sec' AND instance_name = '_Total' THEN cntr_value END),
       @s0 = MAX(CASE WHEN counter_name = 'Page Splits/sec' THEN cntr_value END),
       @l0 = MAX(CASE WHEN counter_name = 'Lock Waits/sec' AND instance_name = '_Total' THEN cntr_value END)
FROM sys.dm_os_performance_counters
WHERE counter_name IN ('Batch Requests/sec', 'SQL Compilations/sec', 'SQL Re-Compilations/sec', 'Transactions/sec', 'Page Splits/sec', 'Lock Waits/sec');
WAITFOR DELAY '00:00:10';
DECLARE @b1 bigint, @c1 bigint, @r1 bigint, @t1 bigint, @s1 bigint, @l1 bigint;
DECLARE @secs float = DATEDIFF(MILLISECOND, @w0, SYSDATETIME()) / 1000.0;
SELECT @b1 = MAX(CASE WHEN counter_name = 'Batch Requests/sec' THEN cntr_value END),
       @c1 = MAX(CASE WHEN counter_name = 'SQL Compilations/sec' THEN cntr_value END),
       @r1 = MAX(CASE WHEN counter_name = 'SQL Re-Compilations/sec' THEN cntr_value END),
       @t1 = MAX(CASE WHEN counter_name = 'Transactions/sec' AND instance_name = '_Total' THEN cntr_value END),
       @s1 = MAX(CASE WHEN counter_name = 'Page Splits/sec' THEN cntr_value END),
       @l1 = MAX(CASE WHEN counter_name = 'Lock Waits/sec' AND instance_name = '_Total' THEN cntr_value END)
FROM sys.dm_os_performance_counters
WHERE counter_name IN ('Batch Requests/sec', 'SQL Compilations/sec', 'SQL Re-Compilations/sec', 'Transactions/sec', 'Page Splits/sec', 'Lock Waits/sec');

DECLARE @ms bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);

SELECT
    JSON_QUERY((SELECT CONVERT(varchar(19), GETDATE(), 126) AS now_local, @@SERVERNAME AS server_name, DB_NAME() AS db,
                       CONVERT(varchar(19), si.sqlserver_start_time, 126) AS start_time,
                       DATEDIFF(DAY, si.sqlserver_start_time, GETDATE()) AS uptime_days, si.cpu_count,
                       CAST(si.physical_memory_kb / 1048576.0 AS decimal(9,0)) AS server_mem_gb,
                       CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) AS version,
                       CAST(SERVERPROPERTY('Edition') AS varchar(60)) AS edition
                FROM sys.dm_os_sys_info si FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS instance,
    JSON_QUERY((SELECT v.t, v.sql_cpu, v.total_cpu
                FROM (SELECT CONVERT(varchar(16), DATEADD(MILLISECOND, -1 * (@ms - r.[timestamp]), GETDATE()), 126) AS t,
                             CAST(r.record AS xml).value('(//SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu,
                             100 - CAST(r.record AS xml).value('(//SystemHealth/SystemIdle)[1]', 'int') AS total_cpu
                      FROM sys.dm_os_ring_buffers r
                      WHERE r.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND r.record LIKE N'%<SystemHealth>%') v
                ORDER BY v.t FOR JSON PATH)) AS cpu,
    JSON_QUERY((SELECT CAST(@secs AS decimal(6,1)) AS seconds,
                       CAST((@b1 - @b0) / @secs AS decimal(12,1)) AS batch_requests,
                       CAST((@c1 - @c0) / @secs AS decimal(12,1)) AS compiles,
                       CAST((@r1 - @r0) / @secs AS decimal(12,1)) AS recompiles,
                       CAST((@t1 - @t0) / @secs AS decimal(12,1)) AS transactions,
                       CAST((@s1 - @s0) / @secs AS decimal(12,1)) AS page_splits,
                       CAST((@l1 - @l0) / @secs AS decimal(12,1)) AS lock_waits
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS rates,
    JSON_QUERY((SELECT CAST(pm.physical_memory_in_use_kb / 1048576.0 AS decimal(9,1)) AS sql_mem_gb,
                       pm.memory_utilization_percentage AS mem_util_pct, pm.process_physical_memory_low AS memory_low,
                       (SELECT CAST(cntr_value AS bigint) FROM sys.dm_os_performance_counters
                        WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%') AS ple_s,
                       (SELECT CAST(cntr_value AS bigint) FROM sys.dm_os_performance_counters WHERE counter_name = 'Memory Grants Pending') AS grants_pending,
                       (SELECT CAST(available_physical_memory_kb / 1048576.0 AS decimal(9,1)) FROM sys.dm_os_sys_memory) AS os_free_gb,
                       (SELECT CAST(SUM(pages_kb) / 1048576.0 AS decimal(9,1)) FROM sys.dm_os_memory_clerks WHERE type = 'CACHESTORE_SQLCP') AS adhoc_plan_cache_gb,
                       (SELECT CAST(SUM(pages_kb) / 1048576.0 AS decimal(9,1)) FROM sys.dm_os_memory_clerks WHERE type = 'MEMORYCLERK_SQLBUFFERPOOL') AS buffer_pool_gb
                FROM sys.dm_os_process_memory pm FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS memory,
    JSON_QUERY((SELECT SUM(current_workers_count) AS workers, SUM(active_workers_count) AS active,
                       SUM(runnable_tasks_count) AS runnable, SUM(work_queue_count) AS queued,
                       (SELECT max_workers_count FROM sys.dm_os_sys_info) AS max_workers,
                       (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type = 'THREADPOOL') AS threadpool_waiting_now,
                       (SELECT waiting_tasks_count FROM sys.dm_os_wait_stats WHERE wait_type = 'THREADPOOL') AS threadpool_waits_since_restart
                FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS workers,
    JSON_QUERY((SELECT TOP (10) ISNULL(NULLIF(program_name, ''), '(none)') AS program, COUNT(*) AS sessions,
                       SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running
                FROM sys.dm_exec_sessions WHERE is_user_process = 1 GROUP BY program_name ORDER BY COUNT(*) DESC FOR JSON PATH)) AS sessions,
    JSON_QUERY((SELECT ar.replica_server_name AS replica, DB_NAME(drs.database_id) AS db, drs.is_primary_replica AS is_primary,
                       drs.synchronization_state_desc AS sync_state, drs.synchronization_health_desc AS health,
                       drs.log_send_queue_size AS send_queue_kb, drs.redo_queue_size AS redo_queue_kb
                FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
                WHERE drs.database_id = DB_ID() OR drs.synchronization_health_desc <> 'HEALTHY'
                ORDER BY drs.is_primary_replica DESC, ar.replica_server_name FOR JSON PATH)) AS ag,
    JSON_QUERY((SELECT CAST(SUM(unallocated_extent_page_count) * 8 / 1048576.0 AS decimal(9,1)) AS free_gb,
                       CAST(SUM(user_object_reserved_page_count + internal_object_reserved_page_count + version_store_reserved_page_count) * 8 / 1048576.0 AS decimal(9,1)) AS used_gb,
                       CAST(SUM(version_store_reserved_page_count) * 8 / 1048576.0 AS decimal(9,1)) AS version_store_gb
                FROM tempdb.sys.dm_db_file_space_usage FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS tempdb,
    JSON_QUERY((SELECT DISTINCT vs.volume_mount_point AS volume, CAST(vs.total_bytes / 1073741824.0 AS decimal(9,0)) AS total_gb,
                       CAST(vs.available_bytes / 1073741824.0 AS decimal(9,0)) AS free_gb,
                       CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,1)) AS free_pct
                FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs FOR JSON PATH)) AS volumes,
    JSON_QUERY((SELECT TOP (8) CASE WHEN fs.database_id = 2 THEN 'tempdb' ELSE DB_NAME(fs.database_id) END AS db,
                       CASE WHEN mf.type = 1 THEN 'LOG' ELSE 'DATA' END AS kind,
                       CAST(SUM(fs.io_stall_read_ms) * 1.0 / NULLIF(SUM(fs.num_of_reads), 0) AS decimal(9,1)) AS read_ms,
                       CAST(SUM(fs.io_stall_write_ms) * 1.0 / NULLIF(SUM(fs.num_of_writes), 0) AS decimal(9,1)) AS write_ms,
                       CAST(SUM(fs.num_of_bytes_read) / 1073741824.0 AS decimal(12,0)) AS gb_read,
                       CAST(SUM(fs.num_of_bytes_written) / 1073741824.0 AS decimal(12,0)) AS gb_written
                FROM sys.dm_io_virtual_file_stats(NULL, NULL) fs
                JOIN sys.master_files mf ON mf.database_id = fs.database_id AND mf.file_id = fs.file_id
                GROUP BY fs.database_id, CASE WHEN mf.type = 1 THEN 'LOG' ELSE 'DATA' END
                ORDER BY SUM(fs.io_stall_read_ms + fs.io_stall_write_ms) DESC FOR JSON PATH)) AS io,
    JSON_QUERY((SELECT recovery_model, CONVERT(varchar(19), log_backup_time, 126) AS last_log_backup,
                       CAST(log_since_last_log_backup_mb AS decimal(12,0)) AS log_since_backup_mb,
                       CAST(total_log_size_mb AS decimal(12,0)) AS log_size_mb, log_truncation_holdup_reason AS holdup
                FROM sys.dm_db_log_stats(DB_ID()) FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS log,
    JSON_QUERY((SELECT COUNT(*) AS blocked_now, CAST(ISNULL(MAX(r.wait_time), 0) / 1000.0 AS decimal(9,1)) AS max_wait_s,
                       (SELECT TOP (5) hb.program_name AS program, hb.login_name AS login, COUNT(*) AS blocked
                        FROM sys.dm_exec_requests r2 JOIN sys.dm_exec_sessions hb ON hb.session_id = r2.blocking_session_id
                        WHERE r2.blocking_session_id <> 0 GROUP BY hb.program_name, hb.login_name ORDER BY COUNT(*) DESC FOR JSON PATH) AS blockers
                FROM sys.dm_exec_requests r WHERE r.blocking_session_id <> 0 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS blocking,
    JSON_QUERY((SELECT TOP (8) r.session_id, s.program_name AS program, s.login_name AS login, r.command, r.wait_type,
                       r.total_elapsed_time / 1000 AS elapsed_s, r.cpu_time / 1000 AS cpu_s, r.logical_reads,
                       ISNULL(OBJECT_SCHEMA_NAME(st.objectid, st.dbid) + '.' + OBJECT_NAME(st.objectid, st.dbid), '(ad hoc)') AS module
                FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
                WHERE s.is_user_process = 1 AND r.session_id <> @@SPID AND r.total_elapsed_time > 60000
                  AND r.wait_type NOT LIKE 'BROKER%' AND r.command NOT LIKE 'WAITFOR%'
                  AND s.login_name <> 'NT AUTHORITY\SYSTEM'          -- the built-in diagnostics session
                ORDER BY r.total_elapsed_time DESC FOR JSON PATH)) AS long_running,
    (SELECT CAST(cntr_value AS bigint) FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Locks%' AND instance_name = '_Total' AND counter_name = 'Number of Deadlocks/sec') AS deadlocks_since_restart,
    JSON_QUERY((SELECT name, CAST(value_in_use AS int) AS value FROM sys.configurations
                WHERE name IN ('cost threshold for parallelism', 'max degree of parallelism', 'max server memory (MB)',
                               'optimize for ad hoc workloads', 'max worker threads')
                ORDER BY name FOR JSON PATH)) AS settings,
    JSON_QUERY((SELECT actual_state_desc AS state, current_storage_size_mb AS used_mb, max_storage_size_mb AS max_mb,
                       CAST(100.0 * current_storage_size_mb / NULLIF(max_storage_size_mb, 0) AS decimal(5,1)) AS pct_full,
                       max_plans_per_query, query_capture_mode_desc AS capture_mode, interval_length_minutes,
                       stale_query_threshold_days AS retention_days
                FROM sys.database_query_store_options FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS query_store
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
