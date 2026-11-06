/*
    health_server.sql - READ-ONLY point-in-time server health (instance level + the current database).
    SELECT-only: no temp tables, no table variables, no writes. Run in the main application database:
        sqlcmd -S <server> -d <AppDb> -E -I -W -s"|" -i health_server.sql
    Sections are separated by their column headers; read them top to bottom.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 5000;

-- 1. Instance
SELECT CONVERT(varchar(19), GETDATE(), 120) AS now_local, @@SERVERNAME AS server_name, si.sqlserver_start_time,
       DATEDIFF(DAY, si.sqlserver_start_time, GETDATE()) AS uptime_days, si.cpu_count, si.scheduler_count,
       CAST(si.physical_memory_kb / 1048576.0 AS decimal(9,0)) AS server_mem_gb, CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) AS version
FROM sys.dm_os_sys_info si;

-- 2. CPU meter (ring buffer keeps ~4 h): per hour, and the last 15 minutes
DECLARE @ms bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
WITH rb AS (
  SELECT DATEADD(MILLISECOND, -1 * (@ms - r.[timestamp]), GETDATE()) AS t, CAST(r.record AS xml) AS x
  FROM sys.dm_os_ring_buffers r WHERE r.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND r.record LIKE N'%<SystemHealth>%'
), v AS (SELECT t, x.value('(//SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu, 100 - x.value('(//SystemHealth/SystemIdle)[1]', 'int') AS total_cpu FROM rb)
SELECT CONVERT(varchar(13), t, 120) AS hour_local, COUNT(*) AS samples, AVG(sql_cpu) AS sql_cpu_avg, MAX(sql_cpu) AS sql_cpu_max, AVG(total_cpu) AS total_cpu_avg
FROM v GROUP BY CONVERT(varchar(13), t, 120) ORDER BY 1;

-- 3. Memory
SELECT CAST(pm.physical_memory_in_use_kb / 1048576.0 AS decimal(9,1)) AS sql_mem_gb, pm.memory_utilization_percentage AS mem_util_pct, pm.process_physical_memory_low,
       (SELECT CAST(cntr_value AS bigint) FROM sys.dm_os_performance_counters WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%') AS ple_s,
       (SELECT CAST(cntr_value AS bigint) FROM sys.dm_os_performance_counters WHERE counter_name = 'Memory Grants Pending') AS grants_pending,
       (SELECT CAST(available_physical_memory_kb / 1048576.0 AS decimal(9,1)) FROM sys.dm_os_sys_memory) AS os_free_gb,
       (SELECT system_memory_state_desc FROM sys.dm_os_sys_memory) AS os_mem_state
FROM sys.dm_os_process_memory pm;
SELECT TOP (6) type AS memory_clerk, CAST(SUM(pages_kb) / 1048576.0 AS decimal(9,1)) AS gb FROM sys.dm_os_memory_clerks GROUP BY type ORDER BY SUM(pages_kb) DESC;

-- 4. Worker threads and thread starvation
SELECT SUM(current_workers_count) AS workers, SUM(active_workers_count) AS workers_active, SUM(runnable_tasks_count) AS runnable_now,
       SUM(work_queue_count) AS queued_for_worker, (SELECT max_workers_count FROM sys.dm_os_sys_info) AS max_workers,
       (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type = 'THREADPOOL') AS waiting_for_thread_now,
       (SELECT waiting_tasks_count FROM sys.dm_os_wait_stats WHERE wait_type = 'THREADPOOL') AS threadpool_waits_since_restart
FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE';

-- 5. Sessions by program
SELECT TOP (12) ISNULL(NULLIF(program_name, ''), '(none)') AS program, COUNT(*) AS sessions, SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running
FROM sys.dm_exec_sessions WHERE is_user_process = 1 GROUP BY program_name ORDER BY COUNT(*) DESC;

-- 6. Availability group (current database and anything unhealthy)
SELECT ar.replica_server_name, DB_NAME(drs.database_id) AS db, drs.is_primary_replica, drs.synchronization_state_desc, drs.synchronization_health_desc,
       drs.log_send_queue_size AS send_queue_kb, drs.redo_queue_size AS redo_queue_kb
FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.database_id = DB_ID() OR drs.synchronization_health_desc <> 'HEALTHY';

-- 7. tempdb, disk volumes, I/O latency since restart
SELECT CAST(SUM(unallocated_extent_page_count) * 8 / 1048576.0 AS decimal(9,1)) AS tempdb_free_gb,
       CAST(SUM(user_object_reserved_page_count + internal_object_reserved_page_count + version_store_reserved_page_count) * 8 / 1048576.0 AS decimal(9,1)) AS tempdb_used_gb
FROM tempdb.sys.dm_db_file_space_usage;
SELECT DISTINCT vs.volume_mount_point, CAST(vs.total_bytes / 1073741824.0 AS decimal(9,0)) AS total_gb, CAST(vs.available_bytes / 1073741824.0 AS decimal(9,0)) AS free_gb,
       CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,1)) AS free_pct
FROM (SELECT DB_ID() AS dbid, file_id FROM sys.database_files UNION ALL SELECT 2, file_id FROM tempdb.sys.database_files) f
CROSS APPLY sys.dm_os_volume_stats(f.dbid, f.file_id) vs;
SELECT CASE WHEN fs.database_id = 2 THEN 'tempdb' ELSE DB_NAME(fs.database_id) END AS db, CASE WHEN fs.file_id = 2 THEN 'LOG' ELSE 'DATA' END AS kind,
       CAST(SUM(fs.io_stall_read_ms) * 1.0 / NULLIF(SUM(fs.num_of_reads), 0) AS decimal(9,1)) AS avg_read_ms,
       CAST(SUM(fs.io_stall_write_ms) * 1.0 / NULLIF(SUM(fs.num_of_writes), 0) AS decimal(9,1)) AS avg_write_ms,
       CAST(SUM(fs.num_of_bytes_read) / 1073741824.0 AS decimal(12,0)) AS gb_read, CAST(SUM(fs.num_of_bytes_written) / 1073741824.0 AS decimal(12,0)) AS gb_written
FROM sys.dm_io_virtual_file_stats(NULL, NULL) fs WHERE fs.database_id IN (DB_ID(), 2)
GROUP BY fs.database_id, CASE WHEN fs.file_id = 2 THEN 'LOG' ELSE 'DATA' END ORDER BY db, kind;
SELECT recovery_model, CONVERT(varchar(19), log_backup_time, 120) AS last_log_backup, CAST(log_since_last_log_backup_mb AS decimal(12,0)) AS log_since_backup_mb,
       CAST(total_log_size_mb AS decimal(12,0)) AS log_size_mb, log_truncation_holdup_reason
FROM sys.dm_db_log_stats(DB_ID());

-- 8. Blocking now: blocked requests with their head blocker, and long-running requests (> 60 s)
SELECT r.session_id, r.blocking_session_id AS blocked_by, s.program_name, s.login_name, r.wait_type, CAST(r.wait_time / 1000.0 AS decimal(9,1)) AS wait_s,
       r.command, DB_NAME(r.database_id) AS db, hb.program_name AS blocker_program, hb.login_name AS blocker_login, hb.status AS blocker_status
FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id LEFT JOIN sys.dm_exec_sessions hb ON hb.session_id = r.blocking_session_id
WHERE r.blocking_session_id <> 0;
SELECT r.session_id, s.program_name, s.login_name, r.status, r.command, r.wait_type, r.total_elapsed_time / 1000 AS elapsed_s, r.cpu_time / 1000 AS cpu_s,
       r.logical_reads, ISNULL(OBJECT_NAME(st.objectid, st.dbid), '(ad hoc)') AS module
FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID AND r.total_elapsed_time > 60000 AND r.wait_type NOT LIKE 'BROKER%' AND r.command NOT LIKE 'WAITFOR%';

-- 9. Deadlocks since restart, configuration, Query Store
SELECT CAST(cntr_value AS bigint) AS deadlocks_since_restart FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Locks%' AND instance_name = '_Total' AND counter_name = 'Number of Deadlocks/sec';
SELECT name, value_in_use FROM sys.configurations
WHERE name IN ('cost threshold for parallelism', 'max degree of parallelism', 'max server memory (MB)', 'optimize for ad hoc workloads', 'max worker threads');
SELECT actual_state_desc, current_storage_size_mb, max_storage_size_mb, CAST(100.0 * current_storage_size_mb / max_storage_size_mb AS decimal(5,1)) AS pct_full,
       max_plans_per_query, query_capture_mode_desc
FROM sys.database_query_store_options;
