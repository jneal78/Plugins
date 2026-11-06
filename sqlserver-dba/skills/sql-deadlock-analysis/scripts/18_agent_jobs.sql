/*  18_agent_jobs.sql  (read-only)
    Purpose : name the SQL Agent jobs that appear in deadlock graphs and show when they run. A graph shows a job
              only as clientapp "SQLAgent - TSQL JobStep (Job 0x<32 hex> : Step <n>)"; this resolves that id to
              the job, its steps, its schedule and its recent run times, so a deadlock pattern can be matched to
              a schedule (an upstream driver).
    Needs   : read access to msdb (SQLAgentReaderRole, or db_datareader in msdb). Many reading logins don't have
              it; if this fails, give the job ids to someone who does.
    Params  : EDIT ME block: the 0x ids, from the analyzer (deadlock_patterns.md lists them per pattern).
    Reading : 1. The job and its steps (step command excerpt only).
              2. Schedules: freq_subday_type 4 = every n minutes, 8 = every n hours, 1 = once at active_start_time.
              3. Recent runs of each step with start time and duration: does a pattern's deadlock time fall inside a
                 run? Do long runs line up with the deadlock hours?
    Run     : sqlcmd -S <server> -d msdb -E -I -W -s"|" -t 60 -i 18_agent_jobs.sql -o jobs.txt
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @JobIds  nvarchar(max) = N'0x00000000000000000000000000000000',   -- ';'-separated
        @RunDays int           = 3;
---------------------------------------------------------------------------------------------------------------------

DECLARE @jx xml = CAST(N'<t>' + REPLACE(@JobIds, N';', N'</t><t>') + N'</t>' AS xml);
DECLARE @ids nvarchar(max) = N',';
SELECT @ids = @ids + CONVERT(nvarchar(40), j.job_id) + N','
FROM msdb.dbo.sysjobs j
WHERE CONVERT(binary(16), j.job_id) IN (SELECT TRY_CONVERT(binary(16), LTRIM(RTRIM(n.value('.', 'nvarchar(40)'))), 1) FROM @jx.nodes('t') x(n));
DECLARE @from int = CONVERT(int, CONVERT(char(8), DATEADD(DAY, -@RunDays, GETDATE()), 112));

-- 1. Jobs and steps
SELECT CONVERT(varchar(40), CONVERT(binary(16), j.job_id), 1) AS job_id_as_in_graph, j.name AS job_name, j.enabled,
       s.step_id, s.step_name, s.subsystem, s.database_name,
       LEFT(REPLACE(REPLACE(REPLACE(s.command, CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' '), 200) AS command_excerpt
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
WHERE CHARINDEX(N',' + CONVERT(nvarchar(40), j.job_id) + N',', @ids) > 0
ORDER BY j.name, s.step_id;

-- 2. Schedules
SELECT j.name AS job_name, sc.name AS schedule_name, sc.enabled,
       sc.freq_type, sc.freq_interval, sc.freq_subday_type, sc.freq_subday_interval,
       STUFF(STUFF(RIGHT(N'000000' + CAST(sc.active_start_time AS nvarchar(6)), 6), 5, 0, N':'), 3, 0, N':') AS starts_at,
       STUFF(STUFF(RIGHT(N'000000' + CAST(sc.active_end_time AS nvarchar(6)), 6), 5, 0, N':'), 3, 0, N':') AS ends_at,
       CASE sc.freq_subday_type WHEN 1 THEN N'once' WHEN 2 THEN N'every ' + CAST(sc.freq_subday_interval AS nvarchar(5)) + N' s'
            WHEN 4 THEN N'every ' + CAST(sc.freq_subday_interval AS nvarchar(5)) + N' min'
            WHEN 8 THEN N'every ' + CAST(sc.freq_subday_interval AS nvarchar(5)) + N' h' END AS cadence
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
WHERE CHARINDEX(N',' + CONVERT(nvarchar(40), j.job_id) + N',', @ids) > 0
ORDER BY j.name, sc.name;

-- 3. Recent runs per step (server local time)
SELECT TOP (300) j.name AS job_name, h.step_id, h.step_name,
       CONVERT(varchar(19), DATETIMEFROMPARTS(h.run_date / 10000, h.run_date / 100 % 100, h.run_date % 100,
                                              h.run_time / 10000, h.run_time / 100 % 100, h.run_time % 100, 0), 120) AS started_local,
       (h.run_duration / 10000) * 3600 + (h.run_duration / 100 % 100) * 60 + h.run_duration % 100 AS duration_s,
       CASE h.run_status WHEN 0 THEN 'failed' WHEN 1 THEN 'succeeded' WHEN 2 THEN 'retry' WHEN 3 THEN 'canceled' ELSE 'other' END AS outcome,
       LEFT(REPLACE(REPLACE(h.message, CHAR(13), N' '), CHAR(10), N' '), 160) AS message_excerpt
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE CHARINDEX(N',' + CONVERT(nvarchar(40), j.job_id) + N',', @ids) > 0 AND h.run_date >= @from
ORDER BY h.run_date DESC, h.run_time DESC, h.step_id;
