/*  16_deadlock_history_qs.sql  (read-only)
    Purpose : the long history of each deadlock pattern, from Query Store. Event files hold hours of graphs;
              Query Store holds weeks of executions. A deadlock victim's statement is recorded as an execution
              that ended in an exception (execution_type 4), so failed executions of the victim statements, per
              day and per hour of day, give each pattern's trend and its time-of-day shape.
    Needs   : Query Store on in the database; VIEW DATABASE STATE. Run it in the database that holds the
              victim code (the analyzer groups the targets by database).
    Params  : EDIT ME block. @Targets is a ';'-separated list of label=target, written for you by
              Analyze-Deadlocks.ps1 (deadlock_patterns.md, "History"). A target is one of:
                schema.object        every statement of that procedure, function or trigger
                0x<16 hex digits>    one statement by query_hash
                text:<a%b%c>         ad hoc statements whose text matches LIKE '%a%b%c%' (use table and column
                                     names; a fragment with a write keyword in it trips production guardrails)
    Reading : An upper bound: other errors in the same statements count too (1205 is usually most of them;
              09_errors_timeouts.sql lists the error numbers the engine raised recently). Section 1 shows what
              each target matched, so check it before trusting the trend.
              2. By day: when the pattern started, whether it is growing, and whether a fix stopped it.
              3. By hour of day: the shape. A fixed hour points at a schedule (job, batch, feed); business-hours
                 shape points at users; flat points at a polling service.
              Times are converted with the server's CURRENT offset from UTC: across a daylight-saving change the
              older days shift by an hour.
    Cost    : one read of Query Store per target (about 10-30 s each on a large store), driven by a seekable
              filter (object_id or query_hash), kept in
              an xml variable; the three sections are built from that variable. A text: target has no seekable
              filter and reads every ad hoc statement text in Query Store: prefer an object or a hash.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -t 120 -i 16_deadlock_history_qs.sql -o history.txt
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Targets nvarchar(max) = N'P1=dbo.usp_Example; P2=0x0123456789ABCDEF; P3=text:SomeTable%SomeColumn',
        @Days    int           = 15;
---------------------------------------------------------------------------------------------------------------------

DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
DECLARE @since datetime2(0) = DATEADD(DAY, -@Days, SYSUTCDATETIME());
DECLARE @tx xml = CAST(N'<t>' + REPLACE(REPLACE(REPLACE(@Targets, N'&', N''), N'<', N''), N';', N'</t><t>') + N'</t>' AS xml);

-- One read per target: label, statement, local day and hour, failed / aborted / all executions.
-- (No temp tables on production: the rows are kept as xml text in a variable.)
DECLARE @g nvarchar(max) = N'', @i int = 1, @n int = @tx.value('count(/t)', 'int'),
        @v nvarchar(600), @label nvarchar(60), @target nvarchar(500), @oid int, @qh binary(8), @frag nvarchar(500);
WHILE @i <= @n
BEGIN
    SET @v = LTRIM(RTRIM(@tx.value('(/t[sql:variable("@i")])[1]', 'nvarchar(600)')));
    SET @i += 1;
    IF CHARINDEX(N'=', @v) < 2 CONTINUE;
    SET @label = LTRIM(RTRIM(LEFT(@v, CHARINDEX(N'=', @v) - 1)));
    SET @target = LTRIM(RTRIM(SUBSTRING(@v, CHARINDEX(N'=', @v) + 1, 500)));
    SET @oid = NULL; SET @qh = NULL; SET @frag = NULL;
    IF @target LIKE N'0x%' SET @qh = TRY_CONVERT(binary(8), @target, 1);
    ELSE IF @target LIKE N'text:%' SET @frag = N'%' + SUBSTRING(@target, 6, 500) + N'%';
    ELSE SET @oid = OBJECT_ID(@target);

    SELECT @g = @g + ISNULL((
        SELECT @label AS [@l], q.query_id AS [@q],
               CONVERT(char(10), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120) AS [@d],
               DATEPART(HOUR, DATEADD(MINUTE, @off, CAST(i.start_time AS datetime))) AS [@h],
               SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END) AS [@f],
               SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END) AS [@a],
               SUM(rs.count_executions) AS [@e]
        FROM sys.query_store_query q
        JOIN sys.query_store_plan p ON p.query_id = q.query_id
        JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
        JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
        WHERE i.start_time >= @since
          AND (   (@oid IS NOT NULL AND q.object_id = @oid)
               OR (@qh IS NOT NULL AND q.query_hash = @qh)
               OR (@frag IS NOT NULL AND q.object_id = 0
                   AND EXISTS (SELECT 1 FROM sys.query_store_query_text qt WHERE qt.query_text_id = q.query_text_id AND qt.query_sql_text LIKE @frag)))
        GROUP BY q.query_id, CONVERT(char(10), DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)), 120),
                 DATEPART(HOUR, DATEADD(MINUTE, @off, CAST(i.start_time AS datetime)))
        FOR XML PATH('g')), N'')
    OPTION (RECOMPILE);   -- compiled for this target's filter only, so the seekable branch is used
END;
DECLARE @grid xml = CAST(@g AS xml);

-- 1. What each target matched (statements, executions and failures over the window)
;WITH s AS (SELECT n.value('@l', 'nvarchar(60)') AS label, n.value('@q', 'bigint') AS query_id,
                   n.value('@f', 'bigint') AS f, n.value('@a', 'bigint') AS a, n.value('@e', 'bigint') AS e
            FROM @grid.nodes('g') x(n)),
t AS (SELECT label, query_id, SUM(f) AS f, SUM(a) AS a, SUM(e) AS e FROM s GROUP BY label, query_id)
SELECT t.label,
       CASE WHEN q.object_id = 0 THEN N'(ad hoc)' ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(id ' + CAST(q.object_id AS nvarchar(12)) + N')') END AS module,
       t.query_id, CONVERT(varchar(20), q.query_hash, 1) AS query_hash, t.e AS execs, t.f AS failed, t.a AS aborted,
       LEFT(REPLACE(REPLACE(REPLACE(qt.query_sql_text, CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' '), 120) AS stmt
FROM t
JOIN sys.query_store_query q ON q.query_id = t.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE t.f + t.a > 0
ORDER BY t.label, t.f DESC;

-- 2. By local day, per label
;WITH s AS (SELECT n.value('@l', 'nvarchar(60)') AS label, n.value('@d', 'char(10)') AS d,
                   n.value('@f', 'bigint') AS f, n.value('@a', 'bigint') AS a, n.value('@e', 'bigint') AS e
            FROM @grid.nodes('g') x(n))
SELECT label, d AS day_local, DATENAME(WEEKDAY, CAST(d AS date)) AS weekday,
       SUM(f) AS failed, SUM(a) AS aborted, SUM(e) AS execs,
       CAST(1000.0 * SUM(f) / NULLIF(SUM(e), 0) AS decimal(9,2)) AS failed_per_1000
FROM s
GROUP BY label, d
ORDER BY label, d;

-- 3. By local hour of day over the whole window, per label (the time-of-day shape)
;WITH s AS (SELECT n.value('@l', 'nvarchar(60)') AS label, n.value('@h', 'int') AS h,
                   n.value('@f', 'bigint') AS f, n.value('@e', 'bigint') AS e
            FROM @grid.nodes('g') x(n))
SELECT label, h AS hour_local, SUM(f) AS failed, SUM(e) AS execs
FROM s
GROUP BY label, h
HAVING SUM(f) > 0
ORDER BY label, h;
