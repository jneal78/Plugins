/*  10_implicit_conversions.sql  (read-only)
    Purpose : statements in the plan cache whose plans carry a PlanAffectingConvert warning: SQL Server had to
              convert a column to compare it with a value of another type, which blocks index seeks
              (ConvertIssue = 'Seek Plan') or skews row estimates ('Cardinality Estimate').
    Needs   : SQL Server 2016+, VIEW SERVER STATE.
    Params  : EDIT ME block.
    Reading : The usual cause is the caller, not the database: an nvarchar parameter (the default for .NET strings,
              JDBC with sendStringParametersAsUnicode=true, many ORMs) compared with a varchar or char column.
              Under a SQL collation the varchar column is converted, so its index can only be scanned; a few
              thousand calls an hour of a 2-second scan is a typical finding. The fix is typed parameters in
              the application (or sendStringParametersAsUnicode=false), not a database change.
              'Seek Plan' rows matter; 'Cardinality Estimate' rows from a CONVERT in the select list are usually
              harmless. The plan cache only covers what is cached now: run it at a busy time.
              Section 1 inspects this database's statements among the 4 x @TopStatements most expensive cached
              statements server-wide; section 2 the @TopStatements Query Store plans with the most CPU in the
              look-back. Both pick their candidates before reading any plan XML, which is the costly part.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 10_implicit_conversions.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @TopStatements int = 500,   -- most expensive cached statements to inspect (plan XML is costly to parse)
        @TopN          int = 25,
        @QsDays        int = 1;     -- Query Store look-back for section 2
---------------------------------------------------------------------------------------------------------------------

-- 1. Plan cache: statements in this database with plan-affecting conversions, by CPU
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
top_cpu AS (   -- the most expensive cached statements server-wide first: a sort of the DMV, no function per entry
    SELECT TOP (@TopStatements * 4) qs.plan_handle, qs.sql_handle, qs.statement_start_offset, qs.statement_end_offset,
           qs.execution_count, qs.total_worker_time, qs.total_logical_reads, qs.query_hash
    FROM sys.dm_exec_query_stats qs
    ORDER BY qs.total_worker_time DESC
),
top_stmts AS (   -- then this database's among them (plan attributes read for those entries only)
    SELECT TOP (@TopStatements) t.*
    FROM top_cpu t
    CROSS APPLY sys.dm_exec_plan_attributes(t.plan_handle) pa
    WHERE pa.attribute = N'dbid' AND CAST(pa.value AS int) = DB_ID()
    ORDER BY t.total_worker_time DESC
),
p AS (
    SELECT s.*, TRY_CAST(tp.query_plan AS xml) AS x
    FROM top_stmts s
    CROSS APPLY sys.dm_exec_text_query_plan(s.plan_handle, s.statement_start_offset, s.statement_end_offset) tp
    WHERE tp.query_plan LIKE N'%PlanAffectingConvert%'
),
w AS (
    SELECT p.sql_handle, p.statement_start_offset, p.execution_count, p.total_worker_time, p.total_logical_reads, p.query_hash,
           c.n.value('@ConvertIssue', 'nvarchar(40)') AS convert_issue, c.n.value('@Expression', 'nvarchar(400)') AS expression
    FROM p CROSS APPLY p.x.nodes('//Warnings/PlanAffectingConvert') c(n)
)
SELECT TOP (@TopN) w.convert_issue, LEFT(w.expression, 150) AS expression,
       ISNULL(OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid), N'(ad hoc / prepared)') AS module,
       CONVERT(varchar(20), w.query_hash, 1) AS query_hash, w.execution_count AS execs,
       CAST(w.total_worker_time / 60e6 AS decimal(12,2)) AS cpu_min_cached,
       CAST(w.total_worker_time / 1000.0 / NULLIF(w.execution_count, 0) AS decimal(14,2)) AS cpu_ms_per_exec,
       w.total_logical_reads / NULLIF(w.execution_count, 0) AS reads_per_exec,
       LEFT(REPLACE(REPLACE(REPLACE(SUBSTRING(t.text, w.statement_start_offset / 2 + 1, 400), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM w CROSS APPLY sys.dm_exec_sql_text(w.sql_handle) t
ORDER BY CASE WHEN w.convert_issue = N'Seek Plan' THEN 0 ELSE 1 END, w.total_worker_time DESC;

-- 2. Query Store plans used in the last @QsDays with a 'Seek Plan' conversion, by CPU in that period
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
used AS (
    SELECT rs.plan_id, SUM(rs.count_executions) AS execs, SUM(rs.avg_cpu_time * rs.count_executions) AS cpu_us
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE i.start_time >= DATEADD(DAY, -@QsDays, GETUTCDATE())
    GROUP BY rs.plan_id
),
top_used AS (   -- the TOP is a barrier: the text search below can't be pushed down to every stored plan
    SELECT TOP (@TopStatements) plan_id, execs, cpu_us FROM used ORDER BY cpu_us DESC
),
p AS (
    SELECT p.plan_id, p.query_id, u.execs, u.cpu_us, TRY_CAST(p.query_plan AS xml) AS x
    FROM top_used u JOIN sys.query_store_plan p ON p.plan_id = u.plan_id
    WHERE p.query_plan LIKE N'%PlanAffectingConvert%ConvertIssue="Seek Plan"%'
),
w AS (
    SELECT p.plan_id, p.query_id, p.execs, p.cpu_us, c.n.value('@Expression', 'nvarchar(400)') AS expression
    FROM p CROSS APPLY p.x.nodes('//Warnings/PlanAffectingConvert[@ConvertIssue = "Seek Plan"]') c(n)
)
SELECT TOP (@TopN) w.query_id, w.plan_id,
       CASE WHEN q.object_id = 0 THEN N'(ad hoc / prepared)'
            ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(dropped id ' + CAST(q.object_id AS nvarchar(12)) + N')') END AS module,
       CONVERT(varchar(20), q.query_hash, 1) AS query_hash, w.execs,
       CAST(w.cpu_us / 60e6 AS decimal(12,2)) AS cpu_min, LEFT(w.expression, 150) AS expression,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 150) AS stmt
FROM w
JOIN sys.query_store_query q ON q.query_id = w.query_id
JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
ORDER BY w.cpu_us DESC;
