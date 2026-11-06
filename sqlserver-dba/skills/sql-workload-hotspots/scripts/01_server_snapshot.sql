/*  01_server_snapshot.sql  (read-only)
    Purpose : one-page picture of the instance right now: version and size, CPU per minute for the last hour,
              worker threads, memory, cumulative rates, top waits since restart, blocking, the availability
              group, Query Store state for the current database, and the settings that shape plans.
    Needs   : SQL Server 2017+, VIEW SERVER STATE. Run it in the database you are analysing (sections 9-10 use it).
    Params  : none.
    Reading : 2. sql_cpu_pct is SQL Server; other_cpu_pct is everything else on the box. Sustained > 80% = act.
              3. tasks_waiting_for_worker > 0 or rising THREADPOOL waits = thread starvation (look for big parallel scanners).
              5. *_per_sec_since_start are averages since restart; for live rates sample twice and take the difference.
              6. waits are cumulative since restart; benign idle waits are filtered out here.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 01_server_snapshot.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @uptime_s bigint = (SELECT DATEDIFF(SECOND, sqlserver_start_time, SYSDATETIME()) FROM sys.dm_os_sys_info);

-- 1. Instance
SELECT @@SERVERNAME AS server_name,
       CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) AS version,
       CAST(SERVERPROPERTY('ProductLevel') AS varchar(10)) AS level,
       CAST(SERVERPROPERTY('ProductUpdateLevel') AS varchar(10)) AS cu,
       CAST(SERVERPROPERTY('Edition') AS varchar(40)) AS edition,
       si.cpu_count, (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE') AS schedulers_online,
       CAST(si.physical_memory_kb / 1048576.0 AS decimal(9,1)) AS server_ram_gb,
       CAST(si.committed_kb / 1048576.0 AS decimal(9,1)) AS sql_committed_gb,
       CAST(si.committed_target_kb / 1048576.0 AS decimal(9,1)) AS sql_target_gb,
       CONVERT(varchar(16), si.sqlserver_start_time, 120) AS started, CAST(@uptime_s / 86400.0 AS decimal(7,1)) AS uptime_days,
       CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS hadr_enabled
FROM sys.dm_os_sys_info si;

-- 2. CPU per minute, last 60 minutes (scheduler monitor ring buffer; newest first) and the hour's summary
;WITH rb AS (
    SELECT CAST(record AS xml) AS r, [timestamp]
    FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%'
),
v AS (
    SELECT DATEADD(MILLISECOND, -CAST((SELECT ms_ticks FROM sys.dm_os_sys_info) - rb.[timestamp] AS int), GETDATE()) AS t,
           rb.r.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu,
           rb.r.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS idle
    FROM rb
)
SELECT TOP (60) CONVERT(varchar(16), t, 120) AS minute_local, sql_cpu AS sql_cpu_pct, 100 - idle - sql_cpu AS other_cpu_pct
FROM v ORDER BY t DESC;

;WITH rb AS (
    SELECT CAST(record AS xml) AS r, [timestamp]
    FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%'
),
v AS (
    SELECT rb.[timestamp], rb.r.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu
    FROM rb
    WHERE rb.[timestamp] >= (SELECT ms_ticks FROM sys.dm_os_sys_info) - 3600000
)
SELECT COUNT(*) AS minutes_sampled, AVG(sql_cpu) AS sql_cpu_avg_pct, MAX(sql_cpu) AS sql_cpu_max_pct,
       SUM(CASE WHEN sql_cpu >= 80 THEN 1 ELSE 0 END) AS minutes_at_80_plus
FROM v;

-- 3. Worker threads and waits for a thread
SELECT si.max_workers_count,
       SUM(s.current_workers_count) AS current_workers, SUM(s.active_workers_count) AS active_workers,
       CAST(100.0 * SUM(s.current_workers_count) / si.max_workers_count AS decimal(5,1)) AS pct_of_max,
       SUM(s.work_queue_count) AS tasks_waiting_for_worker, SUM(s.runnable_tasks_count) AS runnable_tasks,
       (SELECT waiting_tasks_count FROM sys.dm_os_wait_stats WHERE wait_type = N'THREADPOOL') AS threadpool_waits_since_start,
       (SELECT wait_time_ms FROM sys.dm_os_wait_stats WHERE wait_type = N'THREADPOOL') AS threadpool_wait_ms_since_start
FROM sys.dm_os_schedulers s CROSS JOIN sys.dm_os_sys_info si
WHERE s.status = 'VISIBLE ONLINE'
GROUP BY si.max_workers_count;

-- 4. Memory: buffer pool health, grants, process memory, top clerks, single-use plan cache
SELECT RTRIM(counter_name) AS counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE (object_name LIKE N'%Buffer Manager%' AND counter_name IN (N'Page life expectancy', N'Lazy writes/sec'))
   OR (object_name LIKE N'%Memory Manager%' AND counter_name IN (N'Memory Grants Pending', N'Memory Grants Outstanding',
                                                               N'Target Server Memory (KB)', N'Total Server Memory (KB)'));

SELECT CAST(physical_memory_in_use_kb / 1048576.0 AS decimal(9,1)) AS sql_in_use_gb, memory_utilization_percentage,
       process_physical_memory_low, process_virtual_memory_low
FROM sys.dm_os_process_memory;

SELECT TOP (8) type AS clerk, CAST(SUM(pages_kb) / 1048576.0 AS decimal(9,2)) AS gb
FROM sys.dm_os_memory_clerks GROUP BY type ORDER BY SUM(pages_kb) DESC;

SELECT objtype, COUNT(*) AS plans, CAST(SUM(CAST(size_in_bytes AS bigint)) / 1073741824.0 AS decimal(9,2)) AS gb,
       SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS single_use_plans,
       CAST(SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS bigint) ELSE 0 END) / 1073741824.0 AS decimal(9,2)) AS single_use_gb
FROM sys.dm_exec_cached_plans GROUP BY objtype ORDER BY gb DESC;

-- 5. Cumulative rates since restart (averages; sample twice for live rates)
SELECT RTRIM(counter_name) AS counter_name, cntr_value AS total_since_start,
       CAST(cntr_value * 1.0 / NULLIF(@uptime_s, 0) AS decimal(12,1)) AS per_sec_since_start
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%SQL Statistics%' AND counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec')
   OR object_name LIKE N'%General Statistics%' AND counter_name IN (N'Logins/sec', N'Logouts/sec')
   OR object_name LIKE N'%Access Methods%' AND counter_name IN (N'Page Splits/sec', N'Full Scans/sec')
   OR object_name LIKE N'%Locks%' AND instance_name = N'_Total' AND counter_name IN (N'Number of Deadlocks/sec', N'Lock Timeouts (timeout > 0)/sec');

-- 6. Top waits since restart, idle/benign waits removed
SELECT TOP (15) wait_type,
       CAST(wait_time_ms / 3600000.0 AS decimal(12,1)) AS wait_hours,
       CAST(100.0 * wait_time_ms / SUM(wait_time_ms) OVER () AS decimal(5,1)) AS pct,
       waiting_tasks_count,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(12,1)) AS avg_ms,
       CAST(100.0 * signal_wait_time_ms / NULLIF(wait_time_ms, 0) AS decimal(5,1)) AS signal_pct
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0
  AND wait_type NOT LIKE N'%SLEEP%' AND wait_type NOT LIKE N'%QUEUE%' AND wait_type NOT LIKE N'BROKER[_]%'
  AND wait_type NOT LIKE N'XE[_]%' AND wait_type NOT LIKE N'HADR[_]%' AND wait_type NOT LIKE N'%DIAGNOSTICS[_]SLEEP'
  AND wait_type NOT LIKE N'PREEMPTIVE[_]XE%' AND wait_type NOT LIKE N'PREEMPTIVE[_]OS[_]FLUSHFILEBUFFERS'
  AND wait_type NOT IN (N'REDO_THREAD_PENDING_WORK', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'DIRTY_PAGE_POLL', N'CHECKPOINT_QUEUE',
                        N'LAZYWRITER_SLEEP', N'WAITFOR', N'DISPATCHER_QUEUE_SEMAPHORE', N'FT_IFTS_SCHEDULER_IDLE_WAIT',
                        N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE', N'PARALLEL_REDO_TRAN_LIST', N'PARALLEL_REDO_WORKER_SYNC',
                        N'PARALLEL_REDO_WORKER_WAIT_WORK', N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
                        N'QDS_ASYNC_QUEUE', N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
                        N'QDS_SHUTDOWN_QUEUE', N'SOS_WORK_DISPATCHER', N'VDI_CLIENT_OTHER', N'WAIT_XTP_CKPT_CLOSE',
                        N'WAIT_XTP_HOST_WAIT', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',
                        N'KSOURCE_WAKEUP', N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SNI_HTTP_ACCEPT', N'SQLTRACE_BUFFER_FLUSH',
                        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'XE_DISPATCHER_WAIT', N'XE_TIMER_EVENT', N'LOGMGR_QUEUE',
                        N'REQUEST_FOR_DEADLOCK_SEARCH', N'BROKER_RECEIVE_WAITFOR', N'CXCONSUMER')
ORDER BY wait_time_ms DESC;

-- 7. Blocking and long-running requests right now
SELECT r.session_id, r.blocking_session_id, r.status, r.command, r.wait_type, r.wait_time / 1000 AS wait_s,
       DATEDIFF(SECOND, r.start_time, GETDATE()) AS running_s, r.cpu_time / 1000 AS cpu_s, r.logical_reads, r.dop,
       DB_NAME(r.database_id) AS db, s.program_name, s.host_name, s.login_name,
       ISNULL(OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid), N'(ad hoc)') AS module,
       LEFT(REPLACE(REPLACE(REPLACE(SUBSTRING(t.text, r.statement_start_offset / 2 + 1, 300), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
  AND (r.blocking_session_id <> 0 OR DATEDIFF(SECOND, r.start_time, GETDATE()) >= 30
       OR r.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0))
ORDER BY CASE WHEN r.blocking_session_id = 0 THEN 0 ELSE 1 END, running_s DESC;

-- Idle head blockers (sleeping sessions with an open transaction that block others)
SELECT s.session_id, s.status, s.open_transaction_count, s.program_name, s.host_name, s.login_name,
       CONVERT(varchar(19), s.last_request_end_time, 120) AS last_request_end,
       (SELECT COUNT(*) FROM sys.dm_exec_requests b WHERE b.blocking_session_id = s.session_id) AS sessions_blocked
FROM sys.dm_exec_sessions s
WHERE s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
  AND NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests r WHERE r.session_id = s.session_id);

-- 8. Availability group replicas for this database (empty when not in an AG)
SELECT ar.replica_server_name, drs.is_local, drs.is_primary_replica, drs.synchronization_state_desc, drs.synchronization_health_desc,
       drs.log_send_queue_size AS send_queue_kb, drs.redo_queue_size AS redo_queue_kb, drs.secondary_lag_seconds,
       CONVERT(varchar(19), drs.last_commit_time, 120) AS last_commit
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.database_id = DB_ID();

-- 9. Query Store for the current database
SELECT DB_NAME() AS db, actual_state_desc, desired_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb,
       CAST(100.0 * current_storage_size_mb / NULLIF(max_storage_size_mb, 0) AS decimal(5,1)) AS pct_full,
       query_capture_mode_desc, size_based_cleanup_mode_desc, stale_query_threshold_days, interval_length_minutes,
       max_plans_per_query, wait_stats_capture_mode_desc
FROM sys.database_query_store_options;

-- 10. Settings that shape plans
SELECT name, CAST(value_in_use AS int) AS value_in_use
FROM sys.configurations
WHERE name IN (N'max degree of parallelism', N'cost threshold for parallelism', N'optimize for ad hoc workloads',
               N'max server memory (MB)', N'min server memory (MB)', N'max worker threads')
UNION ALL
SELECT N'db compatibility_level', compatibility_level FROM sys.databases WHERE database_id = DB_ID()
UNION ALL
SELECT N'db read_committed_snapshot', CAST(is_read_committed_snapshot_on AS int) FROM sys.databases WHERE database_id = DB_ID()
UNION ALL
SELECT N'db scoped ' + name, CAST(value AS int) FROM sys.database_scoped_configurations
WHERE name IN (N'MAXDOP', N'LEGACY_CARDINALITY_ESTIMATION', N'PARAMETER_SNIFFING', N'QUERY_OPTIMIZER_HOTFIXES');
