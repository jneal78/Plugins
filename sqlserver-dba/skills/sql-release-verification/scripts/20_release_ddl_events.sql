/*  20_release_ddl_events.sql  (read-only; optional: needs the default trace and permission to read it)
    Purpose : the schema-change events the server recorded itself: which objects were added, removed or redefined,
              exactly when, and by which login, host and application. It is the only read-only source that shows
              objects a release REMOVED (the catalog no longer has them) and database settings it changed.
    Needs   : the default trace enabled (it is unless someone turned it off) and the server-level permission to
              read traces (sysadmin has it; a monitoring login often does). Without it, sys.traces shows nothing
              and the script stops with a message: use 19 and a definition snapshot instead.
    Params  : EDIT ME block. @Since is local server time, like the trace.
    Reading : 0. Reach. The default trace keeps five rolling files of 20 MB; on a busy server that can be only hours
                 or a day. If it starts after the release, the events are gone: say so.
              1. Who and when: each burst of schema changes with its login, host and application. A release run
                 from the vendor's installer looks different from a hand-applied hot-fix or a local re-apply.
              2. Per object: added / removed / redefined, first and last time, how many times. type_code is the
                 sys.objects type (P procedure, FN / IF / TF functions, TR trigger, U table, V view, IX index,
                 ST statistics, DB the database itself, i.e. a database setting changed). An object removed and
                 added again in the same minute was rebuilt from scratch: its permissions, signatures, forced
                 plans and trigger order need checking (22). An object only removed is gone: check whether
                 anything still calls it (errors 208 / 2812 in 09).
              Index maintenance and statistics also log events; @IncludeStats = 0 leaves statistics out.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -t 180 -i 20_release_ddl_events.sql -o ddl_events.txt
*/
SET NOCOUNT ON;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Since        datetime      = '2026-01-01T00:00:00',  -- local; a little before the release started
        @NameLike     nvarchar(300) = NULL,    -- e.g. N'usp[_]Feed%'; NULL = all (the trace has no schema column)
        @IncludeStats bit           = 0,       -- 1 = include statistics events (auto-created statistics are noisy)
        @AllDatabases bit           = 0,       -- 1 = every database, not only the current one
        @TopN         int           = 400;
---------------------------------------------------------------------------------------------------------------------

DECLARE @path nvarchar(260) = (SELECT REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N'\', REVERSE(path)), 260)) + N'log.trc'
                               FROM sys.traces WHERE is_default = 1);
IF @path IS NULL
BEGIN
    RAISERROR(N'No default trace visible: it is off, or this login may not read traces. Use 19 and a definition snapshot (21) instead.', 16, 1);
    RETURN;
END;

-- 0. Reach of the trace files
SELECT @path AS trace_files, CONVERT(varchar(19), MIN(tg.StartTime), 120) AS reaches_back_to_local,
       CONVERT(varchar(19), MAX(tg.StartTime), 120) AS newest_event_local, COUNT(*) AS events,
       CASE WHEN MIN(tg.StartTime) > @Since THEN 'starts AFTER @Since: earlier events are gone' ELSE 'covers @Since' END AS covers
FROM sys.fn_trace_gettable(@path, DEFAULT) tg;

-- 1 and 2 read the files once more, filtered
;WITH e AS (
    SELECT tg.StartTime, tg.EventClass, tg.EventSubClass, tg.ObjectType, tg.ObjectName, tg.DatabaseName,
           tg.LoginName, tg.HostName, tg.ApplicationName,
           CASE tg.EventClass WHEN 46 THEN 'added' WHEN 47 THEN 'removed' WHEN 164 THEN 'redefined' END AS event,
           RTRIM(CHAR(tg.ObjectType % 256) + CHAR(tg.ObjectType / 256)) AS type_code
    FROM sys.fn_trace_gettable(@path, DEFAULT) tg
    WHERE tg.EventClass IN (46, 47, 164) AND tg.EventSubClass = 0
      AND tg.StartTime >= @Since
      AND (@AllDatabases = 1 OR tg.DatabaseID = DB_ID())
      AND (@IncludeStats = 1 OR tg.ObjectType <> 21587)
      AND (@NameLike IS NULL OR tg.ObjectName LIKE @NameLike)
)
SELECT CONVERT(varchar(16), DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', StartTime) / 10) * 10, '20000101'), 120) AS bucket_local,
       DatabaseName AS db, LoginName AS login, HostName AS host, LEFT(ApplicationName, 60) AS application,
       SUM(CASE WHEN event = 'added' THEN 1 ELSE 0 END) AS added,
       SUM(CASE WHEN event = 'removed' THEN 1 ELSE 0 END) AS removed,
       SUM(CASE WHEN event = 'redefined' THEN 1 ELSE 0 END) AS redefined,
       CONVERT(varchar(19), MIN(StartTime), 120) AS first_local, CONVERT(varchar(19), MAX(StartTime), 120) AS last_local
FROM e
GROUP BY DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', StartTime) / 10) * 10, '20000101'), DatabaseName, LoginName, HostName, LEFT(ApplicationName, 60)
ORDER BY bucket_local, first_local;

;WITH e AS (
    SELECT tg.StartTime, tg.ObjectName, tg.DatabaseName, tg.LoginName,
           CASE tg.EventClass WHEN 46 THEN 'added' WHEN 47 THEN 'removed' WHEN 164 THEN 'redefined' END AS event,
           RTRIM(CHAR(tg.ObjectType % 256) + CHAR(tg.ObjectType / 256)) AS type_code
    FROM sys.fn_trace_gettable(@path, DEFAULT) tg
    WHERE tg.EventClass IN (46, 47, 164) AND tg.EventSubClass = 0
      AND tg.StartTime >= @Since
      AND (@AllDatabases = 1 OR tg.DatabaseID = DB_ID())
      AND (@IncludeStats = 1 OR tg.ObjectType <> 21587)
      AND (@NameLike IS NULL OR tg.ObjectName LIKE @NameLike)
),
per_obj AS (
    SELECT DatabaseName, ObjectName, type_code,
           SUM(CASE WHEN event = 'added' THEN 1 ELSE 0 END) AS added,
           SUM(CASE WHEN event = 'removed' THEN 1 ELSE 0 END) AS removed,
           SUM(CASE WHEN event = 'redefined' THEN 1 ELSE 0 END) AS redefined,
           MIN(StartTime) AS first_at, MAX(StartTime) AS last_at, MIN(LoginName) AS login
    FROM e GROUP BY DatabaseName, ObjectName, type_code
)
SELECT TOP (@TopN) DatabaseName AS db, ObjectName AS object_name, type_code, added, removed, redefined,
       CASE WHEN removed > 0 AND added > 0 THEN 'removed and re-added: check permissions, signatures, forced plans (22)'
            WHEN removed > 0 THEN 'REMOVED: still called by anything? (09: errors 208 / 2812)'
            WHEN added > 0 THEN 'new'
            ELSE 'redefined in place' END AS reading,
       CONVERT(varchar(19), first_at, 120) AS first_local, CONVERT(varchar(19), last_at, 120) AS last_local, login
FROM per_obj
ORDER BY CASE WHEN removed > 0 AND added = 0 THEN 0 ELSE 1 END, first_at, object_name;
