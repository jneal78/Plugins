/*  13_deadlock_probe.sql  (read-only, cheap: no XML shredding, no file reads)
    Purpose : how many deadlocks, of which lock types, since when, and where the graphs are kept. Run it first: it
              tells you whether the graphs you need still exist and which collector (14 or 15) to use.
    Needs   : VIEW SERVER STATE (SQL Server 2022: VIEW SERVER PERFORMANCE STATE).
    Params  : none.
    Reading : 1. Rate. The counter is cumulative since the last restart; per_day is the average since then. Compare
                 two runs a few hours apart for the current rate. A number higher than the profile's "normal" is the
                 reason to continue.
              2. Lock types. Which kinds of resource deadlocked since restart: Key and Page are row/page conflicts,
                 RID means a heap, Object means table locks (escalation or TABLOCK), Metadata means schema locks
                 (DDL, temp tables, monitoring tools), Application means sp_getapplock, Xact/Exchange-type
                 counts point at parallelism. This is the mechanism mix before you read one graph.
              3. Where graphs are kept. Every running Extended Events session that records deadlock reports, its
                 targets and the current file. system_health is always there; a dedicated session (or a monitoring
                 product's own session) may keep far more history. Feed the session name to 14.
              4. Lock waits since restart by type. Range waits (LCK_M_R*) mean serializable isolation somewhere;
                 schema waits (LCK_M_SCH_*) mean DDL or metadata queries; U-lock waits (LCK_M_U) mean
                 read-then-write patterns.
              5. Isolation settings per database (empty when the login lacks VIEW ANY DATABASE; 17 shows the
                 setting of the database it runs in): read-committed snapshot (RCSI) and snapshot isolation change
                 which deadlocks are possible (readers stop taking shared locks under RCSI; writers still collide).
              6. Blocking right now, for context.
    Run     : sqlcmd -S <server> -d master -E -I -W -s"|" -t 60 -i 13_deadlock_probe.sql -o probe.txt
*/
SET NOCOUNT ON;

-- 1. Rate since the last restart
SELECT CONVERT(varchar(16), si.sqlserver_start_time, 120) AS sql_started_local,
       CONVERT(varchar(16), GETDATE(), 120) AS now_local,
       DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()) AS utc_offset_min,
       CAST(pc.cntr_value AS bigint) AS deadlocks_since_restart,
       CAST(pc.cntr_value * 1440.0 / NULLIF(DATEDIFF(MINUTE, si.sqlserver_start_time, GETDATE()), 0) AS decimal(9,1)) AS per_day_avg
FROM sys.dm_os_sys_info si
CROSS JOIN sys.dm_os_performance_counters pc
WHERE pc.object_name LIKE N'%Locks%' AND pc.counter_name = N'Number of Deadlocks/sec' AND pc.instance_name = N'_Total';

-- 2. Deadlocks, lock waits and lock timeouts since restart, by lock resource type
SELECT RTRIM(pc.instance_name) AS lock_type,
       SUM(CASE WHEN pc.counter_name = N'Number of Deadlocks/sec' THEN CAST(pc.cntr_value AS bigint) ELSE 0 END) AS deadlocks,
       SUM(CASE WHEN pc.counter_name = N'Lock Waits/sec' THEN CAST(pc.cntr_value AS bigint) ELSE 0 END) AS lock_waits,
       SUM(CASE WHEN pc.counter_name = N'Lock Timeouts (timeout > 0)/sec' THEN CAST(pc.cntr_value AS bigint) ELSE 0 END) AS lock_timeouts
FROM sys.dm_os_performance_counters pc
WHERE pc.object_name LIKE N'%Locks%'
  AND pc.counter_name IN (N'Number of Deadlocks/sec', N'Lock Waits/sec', N'Lock Timeouts (timeout > 0)/sec')
GROUP BY RTRIM(pc.instance_name)
HAVING SUM(CASE WHEN pc.counter_name = N'Number of Deadlocks/sec' THEN CAST(pc.cntr_value AS bigint) ELSE 0 END) > 0
    OR SUM(CASE WHEN pc.counter_name = N'Lock Waits/sec' THEN CAST(pc.cntr_value AS bigint) ELSE 0 END) > 0
ORDER BY deadlocks DESC, lock_waits DESC;

-- 3. Extended Events sessions that record deadlocks, with their targets
SELECT s.name AS xe_session, e.event_name, t.target_name, t.execution_count AS target_writes,
       DATALENGTH(t.target_data) AS target_bytes,
       CASE WHEN t.target_name = N'event_file'
            THEN CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(520)') END AS current_file,
       CONVERT(varchar(16), s.create_time, 120) AS session_started_local
FROM sys.dm_xe_sessions s
JOIN sys.dm_xe_session_events e ON e.event_session_address = s.address
JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
WHERE e.event_name IN (N'xml_deadlock_report', N'database_xml_deadlock_report', N'lock_deadlock', N'lock_deadlock_chain')
ORDER BY CASE WHEN s.name = N'system_health' THEN 1 ELSE 0 END, s.name, t.target_name;

-- 4. Lock waits since restart, by wait type (the mechanism mix of blocking, not only deadlocks)
SELECT TOP (15) ws.wait_type, ws.waiting_tasks_count,
       CAST(ws.wait_time_ms / 60000.0 AS decimal(12,1)) AS wait_min,
       CAST(ws.wait_time_ms * 1.0 / NULLIF(ws.waiting_tasks_count, 0) AS decimal(12,1)) AS avg_wait_ms,
       ws.max_wait_time_ms
FROM sys.dm_os_wait_stats ws
WHERE ws.wait_type LIKE N'LCK[_]M[_]%' AND ws.waiting_tasks_count > 0
ORDER BY ws.wait_time_ms DESC;

-- 5. Isolation settings of the user databases
SELECT d.name AS database_name, d.state_desc, d.compatibility_level,
       d.is_read_committed_snapshot_on AS rcsi, d.snapshot_isolation_state_desc AS snapshot_isolation
FROM sys.databases d
WHERE d.database_id > 4
ORDER BY d.name;

-- 6. Blocking right now
SELECT COUNT(*) AS blocked_requests,
       MAX(r.wait_time) / 1000 AS longest_wait_s,
       COUNT(DISTINCT r.blocking_session_id) AS distinct_blockers
FROM sys.dm_exec_requests r
WHERE r.blocking_session_id > 0;
