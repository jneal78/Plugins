/*
    DBA-RUN TEMPLATE - a dedicated Extended Events session that keeps deadlock graphs for weeks.
    Why: system_health shares a few small files with every other event it records, so on a busy server its
         deadlock graphs roll away within hours. This session records only xml_deadlock_report: negligible
         overhead, <files> x <MB> of disk.
    Before running: replace every <...>. The folder must exist and be writable by the SQL Server service account
         (the instance's Log folder is a safe choice: 13_deadlock_probe.sql shows system_health's current file).
    Availability groups: sessions are server objects, not part of the AG. Run it on EACH replica that can become
         primary.
    Read it with sql-deadlock-analysis 14_deadlock_graphs_file.sql, @Session = N'<SiteName>_Deadlocks'.
    Remove: DROP EVENT SESSION [<SiteName>_Deadlocks] ON SERVER;
*/
IF NOT EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'<SiteName>_Deadlocks')
    CREATE EVENT SESSION [<SiteName>_Deadlocks] ON SERVER
    ADD EVENT sqlserver.xml_deadlock_report
    ADD TARGET package0.event_file (SET filename = N'<instance Log folder>\<SiteName>_Deadlocks.xel',
                                        max_file_size = 50, max_rollover_files = 10)
    WITH (MAX_DISPATCH_LATENCY = 30 SECONDS, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, STARTUP_STATE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'<SiteName>_Deadlocks')
    ALTER EVENT SESSION [<SiteName>_Deadlocks] ON SERVER STATE = START;
GO
SELECT s.name, t.target_name, CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(400)') AS current_file
FROM sys.dm_xe_sessions s JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
WHERE s.name = N'<SiteName>_Deadlocks';
