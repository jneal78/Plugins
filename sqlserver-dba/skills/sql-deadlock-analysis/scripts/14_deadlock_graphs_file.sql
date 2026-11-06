/*  14_deadlock_graphs_file.sql  (read-only)
    Purpose : every deadlock graph still in an Extended Events session's event files, as one JSON document for
              Analyze-Deadlocks.ps1. Default session: system_health, which every SQL Server runs.
    Needs   : VIEW SERVER STATE; SQL Server 2017+ (the timestamp_utc column of sys.fn_xe_file_target_read_file).
    Params  : EDIT ME block: @Session (a dedicated deadlock session if the DBA created one; 13 lists them),
              @SinceUtc (skip older events; NULL = everything in the files).
    Reading : The file path is taken from the session's current file, so nothing server-specific is typed here.
              oldest_event_utc says how far back the files reach. system_health keeps a small, fixed number of files
              that every kind of event shares, so on a busy server it may hold only hours: if the deadlocks you
              need are older, they are gone. Use Query Store history (16) for the trend, and collect on a timer
              (Collect-Deadlocks.ps1) or ask the DBA for a dedicated session (core/templates).
    Cost    : reads all of the session's files (tens of MB): typically 5-30 s of one core. Keep the -t timeout.
    Run     : sqlcmd -S <server> -d master -E -I -y 0 -f 65001 -t 120 -i 14_deadlock_graphs_file.sql -o graphs_file_<yyyyMMdd_HHmm>.json
              (-y 0 keeps the long JSON whole; it cannot be combined with -W or -h. The analyzer skips the header line.)
*/
SET NOCOUNT ON;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Session  sysname      = N'system_health',
        @SinceUtc datetime2(3) = NULL;            -- e.g. '2026-01-31T06:00'
---------------------------------------------------------------------------------------------------------------------

DECLARE @cur nvarchar(520) = (
    SELECT TOP (1) CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(520)')
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
    WHERE s.name = @Session AND t.target_name = N'event_file');
DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'\', @cur) > 0 THEN N'\' ELSE N'/' END;
DECLARE @file nvarchar(520) = RIGHT(@cur, CHARINDEX(@sep, REVERSE(@cur)) - 1);
-- rollover files are named <prefix>_0_<number>.xel; read them all
DECLARE @pattern nvarchar(520) = LEFT(@cur, LEN(@cur) - LEN(@file))
        + CASE WHEN CHARINDEX(N'_0_', @file) > 0 THEN LEFT(@file, CHARINDEX(N'_0_', @file) - 1) ELSE @Session END + N'*.xel';

SELECT @@SERVERNAME AS server_name, @Session AS xe_session, ISNULL(@pattern, N'(session has no event_file target)') AS file_pattern,
       SYSUTCDATETIME() AS read_utc,
       (SELECT TOP (1) f.timestamp_utc FROM sys.fn_xe_file_target_read_file(@pattern, NULL, NULL, NULL) f) AS oldest_event_utc,
       (SELECT f.timestamp_utc AS utc,
               CONVERT(nvarchar(max), CAST(f.event_data AS xml).query('event/data[@name="xml_report"]/value/deadlock')) AS graph
        FROM sys.fn_xe_file_target_read_file(@pattern, NULL, NULL, NULL) f
        WHERE f.object_name = N'xml_deadlock_report'
          AND (@SinceUtc IS NULL OR f.timestamp_utc >= @SinceUtc)
        FOR JSON PATH) AS deadlocks
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
