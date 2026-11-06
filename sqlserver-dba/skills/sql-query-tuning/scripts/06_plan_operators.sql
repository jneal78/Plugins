/*  06_plan_operators.sql  (read-only)
    Purpose : find the hot operators inside Query Store plans without opening them in SSMS: scans, spools,
              lookups, big hashes and sorts, per-row scalar functions, plan warnings (implicit conversions that
              block seeks, missing join predicates, spills), missing-index suggestions and the parameter values
              each plan was compiled for.
    Needs   : SQL Server 2017+ (STRING_AGG), Query Store on, VIEW DATABASE STATE.
    Params  : EDIT ME block. Give @QueryIds (from 02/04/05) or @Object (all plans of that object), not both.
    Reading : Query Store keeps estimated plans, so the row counts are estimates. est_execs = 1 + rewinds + rebinds:
              an operator with est_rows_read in the thousands and est_execs in the thousands (inner side of a
              nested loop, a per-row function) is the usual hot spot. Large estimates against small real row
              counts point at a bad cardinality estimate.
              Patterns:  Clustered Index Scan / Table Scan of a big table  -> no usable index or a non-sargable
                           predicate (function on the column, OR across columns, implicit conversion);
                         Index Spool (Eager Spool)                       -> the optimizer builds a temporary index
                           every execution because no real index fits the correlated predicate;
                         Key Lookup with many executions                 -> index missing included columns;
                         PlanAffectingConvert ConvertIssue = Seek Plan   -> parameter or column type mismatch;
                         UserDefinedFunction                             -> scalar function called per row.
              Plans nested deeper than XML allows (very large plans) cast to NULL and are counted, not parsed.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 06_plan_operators.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @QueryIds nvarchar(max) = NULL,            -- e.g. N'1234,5678'; NULL = use @Object
        @Object   nvarchar(300) = N'dbo.SomeProc', -- used when @QueryIds is NULL
        @MaxPlans int           = 20,              -- most recently used plans to parse
        @MinRows  float         = 10000;           -- hash/sort/seek size worth listing
---------------------------------------------------------------------------------------------------------------------

DECLARE @oid int = OBJECT_ID(@Object);

-- 0. Plans selected
;WITH sel AS (
    SELECT TOP (@MaxPlans) p.plan_id, p.query_id, p.last_execution_time,
           CASE WHEN TRY_CAST(p.query_plan AS xml) IS NULL THEN 1 ELSE 0 END AS unparsable
    FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE (@QueryIds IS NOT NULL AND N',' + REPLACE(@QueryIds, N' ', N'') + N',' LIKE N'%,' + CAST(p.query_id AS nvarchar(20)) + N',%')
       OR (@QueryIds IS NULL AND q.object_id = @oid)
    ORDER BY p.last_execution_time DESC
)
SELECT COUNT(*) AS plans_selected, SUM(unparsable) AS plans_not_parsable, MIN(query_id) AS min_query_id, MAX(query_id) AS max_query_id
FROM sel;

-- 1. Hot operators
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
pl AS (
    SELECT TOP (@MaxPlans) p.plan_id, p.query_id, TRY_CAST(p.query_plan AS xml) AS x
    FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE (@QueryIds IS NOT NULL AND N',' + REPLACE(@QueryIds, N' ', N'') + N',' LIKE N'%,' + CAST(p.query_id AS nvarchar(20)) + N',%')
       OR (@QueryIds IS NULL AND q.object_id = @oid)
    ORDER BY p.last_execution_time DESC
),
ops AS (
    SELECT pl.query_id, pl.plan_id,
           r.n.value('@NodeId', 'int') AS node,
           r.n.value('@PhysicalOp', 'varchar(40)') AS physical_op,
           r.n.value('@LogicalOp', 'varchar(40)') AS logical_op,
           r.n.value('(./*/Object/@Database)[1]', 'nvarchar(130)') AS db,
           r.n.value('(./*/Object/@Schema)[1]', 'nvarchar(130)') + N'.' + r.n.value('(./*/Object/@Table)[1]', 'nvarchar(130)') AS tbl,
           r.n.value('(./*/Object/@Index)[1]', 'nvarchar(130)') AS idx,
           r.n.value('(./IndexScan/@Lookup)[1]', 'bit') AS is_lookup,
           r.n.value('@EstimateRows', 'float') AS est_rows,
           r.n.value('@EstimatedRowsRead', 'float') AS est_rows_read,
           1 + ISNULL(r.n.value('@EstimateRewinds', 'float'), 0) + ISNULL(r.n.value('@EstimateRebinds', 'float'), 0) AS est_execs,
           r.n.value('@EstimateIO', 'float') AS est_io,
           r.n.value('@EstimatedTotalSubtreeCost', 'float') AS subtree_cost,
           r.n.value('(./*/Predicate/ScalarOperator/@ScalarString)[1]', 'nvarchar(max)') AS predicate,
           r.n.value('(./*/SeekPredicates//ScalarOperator/@ScalarString)[1]', 'nvarchar(max)') AS seek_on
    FROM pl
    CROSS APPLY pl.x.nodes('//RelOp[
          ((@PhysicalOp = "Index Scan" or @PhysicalOp = "Clustered Index Scan" or @PhysicalOp = "Table Scan"
            or @PhysicalOp = "Key Lookup" or @PhysicalOp = "RID Lookup" or ./IndexScan/@Lookup = 1
            or @PhysicalOp = "Index Spool" or @PhysicalOp = "Table Spool" or @PhysicalOp = "Row Count Spool"
            or ((@PhysicalOp = "Index Seek" or @PhysicalOp = "Clustered Index Seek") and @EstimateIO > 0.01))
           and substring(string((./*/Object/@Table)[1]), 1, 2) != "[#"
           and substring(string((./*/Object/@Table)[1]), 1, 2) != "[@")
          or @PhysicalOp = "Hash Match" or @PhysicalOp = "Sort"]') r(n)
)
SELECT query_id, plan_id, node, physical_op, logical_op,
       REPLACE(REPLACE(ISNULL(tbl, N''), N'[', N''), N']', N'') AS table_name, REPLACE(REPLACE(ISNULL(idx, N''), N'[', N''), N']', N'') AS index_name,
       CAST(est_rows AS decimal(14,1)) AS est_rows, CAST(est_rows_read AS decimal(16,0)) AS est_rows_read,
       CAST(est_execs AS decimal(14,1)) AS est_execs,
       CAST(ISNULL(est_rows_read, est_rows) * est_execs AS decimal(18,0)) AS est_total_rows_touched,
       CAST(est_io AS decimal(12,4)) AS est_io,
       LEFT(REPLACE(REPLACE(predicate, CHAR(13), ' '), CHAR(10), ' '), 200) AS predicate,
       LEFT(seek_on, 150) AS seek_on
FROM ops
WHERE physical_op NOT IN ('Hash Match', 'Sort') OR est_rows * est_execs >= @MinRows
ORDER BY query_id, plan_id, ISNULL(est_rows_read, est_rows) * est_execs DESC;

-- 2. Plan warnings, scalar functions called per row, statement-level info
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
pl AS (
    SELECT TOP (@MaxPlans) p.plan_id, p.query_id, TRY_CAST(p.query_plan AS xml) AS x
    FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE (@QueryIds IS NOT NULL AND N',' + REPLACE(@QueryIds, N' ', N'') + N',' LIKE N'%,' + CAST(p.query_id AS nvarchar(20)) + N',%')
       OR (@QueryIds IS NULL AND q.object_id = @oid)
    ORDER BY p.last_execution_time DESC
),
w AS (
    SELECT pl.query_id, pl.plan_id, 'PlanAffectingConvert' AS warning,
           c.n.value('@ConvertIssue', 'nvarchar(60)') AS detail, c.n.value('@Expression', 'nvarchar(400)') AS expression
    FROM pl CROSS APPLY pl.x.nodes('//Warnings/PlanAffectingConvert') c(n)
    UNION ALL
    SELECT pl.query_id, pl.plan_id, 'NoJoinPredicate', NULL, NULL
    FROM pl CROSS APPLY pl.x.nodes('//Warnings[@NoJoinPredicate = 1]') c(n)
    UNION ALL
    SELECT pl.query_id, pl.plan_id, 'SpillToTempDb', 'spill level ' + c.n.value('@SpillLevel', 'varchar(10)'), NULL
    FROM pl CROSS APPLY pl.x.nodes('//Warnings/SpillToTempDb') c(n)
    UNION ALL
    SELECT pl.query_id, pl.plan_id, 'UnmatchedIndexes', NULL, NULL
    FROM pl CROSS APPLY pl.x.nodes('//Warnings[@UnmatchedIndexes = 1]') c(n)
    UNION ALL
    SELECT pl.query_id, pl.plan_id, 'UserDefinedFunction (per row)', NULL, c.n.value('@FunctionName', 'nvarchar(400)')
    FROM pl CROSS APPLY pl.x.nodes('//UserDefinedFunction') c(n)
    UNION ALL
    SELECT pl.query_id, pl.plan_id, 'NonParallelPlanReason', c.n.value('@NonParallelPlanReason', 'nvarchar(120)'), NULL
    FROM pl CROSS APPLY pl.x.nodes('//QueryPlan[@NonParallelPlanReason]') c(n)
    UNION ALL
    SELECT pl.query_id, pl.plan_id, 'CardinalityEstimationModel',
           c.n.value('@CardinalityEstimationModelVersion', 'varchar(10)'), c.n.value('@StatementOptmEarlyAbortReason', 'nvarchar(60)')
    FROM pl CROSS APPLY pl.x.nodes('//StmtSimple[@CardinalityEstimationModelVersion]') c(n)
)
SELECT query_id, plan_id, warning, detail, LEFT(expression, 200) AS expression, COUNT(*) AS occurrences
FROM w
GROUP BY query_id, plan_id, warning, detail, LEFT(expression, 200)
ORDER BY query_id, plan_id, warning;

-- 3. Missing-index suggestions inside the plans (impact = optimizer's estimated % saving for that statement)
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
pl AS (
    SELECT TOP (@MaxPlans) p.plan_id, p.query_id, TRY_CAST(p.query_plan AS xml) AS x
    FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE (@QueryIds IS NOT NULL AND N',' + REPLACE(@QueryIds, N' ', N'') + N',' LIKE N'%,' + CAST(p.query_id AS nvarchar(20)) + N',%')
       OR (@QueryIds IS NULL AND q.object_id = @oid)
    ORDER BY p.last_execution_time DESC
),
mi AS (
    SELECT pl.query_id, pl.plan_id, g.n.value('@Impact', 'float') AS impact, m.n.query('.') AS mx,
           m.n.value('@Schema', 'nvarchar(130)') + N'.' + m.n.value('@Table', 'nvarchar(130)') AS tbl
    FROM pl
    CROSS APPLY pl.x.nodes('//MissingIndexes/MissingIndexGroup') g(n)
    CROSS APPLY g.n.nodes('./MissingIndex') m(n)
)
SELECT mi.query_id, mi.plan_id, CAST(mi.impact AS decimal(5,1)) AS impact_pct,
       REPLACE(REPLACE(mi.tbl, N'[', N''), N']', N'') AS table_name,
       (SELECT STRING_AGG(c.n.value('@Name', 'nvarchar(130)'), N', ') FROM mi.mx.nodes('//ColumnGroup[@Usage = "EQUALITY"]/Column') c(n)) AS equality_cols,
       (SELECT STRING_AGG(c.n.value('@Name', 'nvarchar(130)'), N', ') FROM mi.mx.nodes('//ColumnGroup[@Usage = "INEQUALITY"]/Column') c(n)) AS inequality_cols,
       (SELECT STRING_AGG(c.n.value('@Name', 'nvarchar(130)'), N', ') FROM mi.mx.nodes('//ColumnGroup[@Usage = "INCLUDE"]/Column') c(n)) AS include_cols
FROM mi
ORDER BY mi.impact DESC;

-- 4. Parameter values each plan was compiled for (parameter sniffing: compare good and bad plans of one query)
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
pl AS (
    SELECT TOP (@MaxPlans) p.plan_id, p.query_id, TRY_CAST(p.query_plan AS xml) AS x
    FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE (@QueryIds IS NOT NULL AND N',' + REPLACE(@QueryIds, N' ', N'') + N',' LIKE N'%,' + CAST(p.query_id AS nvarchar(20)) + N',%')
       OR (@QueryIds IS NULL AND q.object_id = @oid)
    ORDER BY p.last_execution_time DESC
)
SELECT pl.query_id, pl.plan_id,
       c.n.value('@Column', 'nvarchar(130)') AS parameter,
       c.n.value('@ParameterDataType', 'nvarchar(60)') AS data_type,
       LEFT(c.n.value('@ParameterCompiledValue', 'nvarchar(400)'), 100) AS compiled_value
FROM pl CROSS APPLY pl.x.nodes('//ParameterList/ColumnReference') c(n)
ORDER BY pl.query_id, pl.plan_id, parameter;
