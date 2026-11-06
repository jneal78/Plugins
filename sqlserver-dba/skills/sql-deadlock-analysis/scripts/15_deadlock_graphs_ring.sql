/*  15_deadlock_graphs_ring.sql  (read-only)
    Purpose : deadlock graphs still in an Extended Events session's ring buffer (memory), as JSON for
              Analyze-Deadlocks.ps1. Use it when the session has no event file you can read, or for the last few
              minutes right after a deadlock.
    Needs   : VIEW SERVER STATE.
    Params  : EDIT ME block: @Session.
    Reading : The ring buffer holds only the most recent events of every kind, often minutes on a busy server;
              oldest_event_utc says how far back it reaches. Prefer the event files (14) for anything older.
    Footprint: the buffer is cast to xml ONCE and held in a variable, and the variable is shredded. Never cast the
              target inside a CTE or derived table and shred that: the cast is re-evaluated per node and has cost
              minutes of CPU on a production server.
    Run     : sqlcmd -S <server> -d master -E -I -y 0 -f 65001 -t 60 -i 15_deadlock_graphs_ring.sql -o graphs_ring_<yyyyMMdd_HHmm>.json
*/
SET NOCOUNT ON;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Session sysname = N'system_health';
---------------------------------------------------------------------------------------------------------------------

DECLARE @x xml = (
    SELECT TOP (1) CAST(t.target_data AS xml)
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
    WHERE s.name = @Session AND t.target_name = N'ring_buffer');

SELECT @@SERVERNAME AS server_name, @Session AS xe_session, SYSUTCDATETIME() AS read_utc,
       @x.value('(RingBufferTarget/@eventCount)[1]', 'int') AS events_in_buffer,
       @x.value('(RingBufferTarget/event/@timestamp)[1]', 'datetime2(3)') AS oldest_event_utc,
       (SELECT e.n.value('@timestamp', 'datetime2(3)') AS utc,
               CONVERT(nvarchar(max), e.n.query('data[@name="xml_report"]/value/deadlock')) AS graph
        FROM @x.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') e(n)
        FOR JSON PATH) AS deadlocks
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
