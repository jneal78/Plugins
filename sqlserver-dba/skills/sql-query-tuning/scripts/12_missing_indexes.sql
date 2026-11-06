/*  12_missing_indexes.sql  (read-only)
    Purpose : the optimizer's missing-index requests for the tables one object uses (or one table, or the whole
              database), next to the indexes those tables already have and how much each is used, so an
              existing index can be extended instead of adding another.
    Needs   : SQL Server 2017+ (STRING_AGG), VIEW SERVER STATE.
    Params  : EDIT ME block: @Object (tables it references), or @Table, or both NULL for the whole database.
    Reading : The missing-index DMVs reset at restart, ignore column order beyond equality/inequality, never
              suggest filtered or overlapping indexes, and often repeat one need in several shapes. Treat them
              as evidence, not as a script to run. improvement = avg cost x avg impact % x (seeks + scans), the
              usual ranking. Before proposing an index:
                - check section 2 for an index with the same leading key that an INCLUDE would complete;
                - weigh write cost (user_writes) on busy tables;
                - prefer an in-code fix when the request comes from one bad statement (see 06 and the
                  fix-patterns reference); a vendor table index needs your prefix and the vendor's knowledge.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 12_missing_indexes.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Object nvarchar(300) = N'dbo.SomeProc',   -- tables this module references; NULL to skip
        @Table  nvarchar(300) = NULL,              -- one table; NULL to skip
        @TopN   int           = 25;
---------------------------------------------------------------------------------------------------------------------

DECLARE @oid int = OBJECT_ID(@Object), @tid int = OBJECT_ID(@Table);
DECLARE @all bit = CASE WHEN @oid IS NULL AND @tid IS NULL THEN 1 ELSE 0 END;
SELECT DB_NAME() AS db, @Object AS object_scope, @Table AS table_scope,
       CASE WHEN @all = 1 THEN 'whole database' ELSE 'scoped' END AS scope,
       (SELECT CONVERT(varchar(16), sqlserver_start_time, 120) FROM sys.dm_os_sys_info) AS dmv_data_since;

-- 1. Missing-index requests
;WITH t AS (
    SELECT d.referenced_id AS object_id
    FROM sys.sql_expression_dependencies d JOIN sys.tables tb ON tb.object_id = d.referenced_id
    WHERE d.referencing_id = @oid
    UNION
    SELECT @tid WHERE @tid IS NOT NULL
)
SELECT TOP (@TopN) OBJECT_SCHEMA_NAME(mid.object_id) + N'.' + OBJECT_NAME(mid.object_id) AS table_name,
       mid.equality_columns, mid.inequality_columns, mid.included_columns,
       migs.user_seeks, migs.user_scans,
       CAST(migs.avg_total_user_cost AS decimal(12,2)) AS avg_cost, CAST(migs.avg_user_impact AS decimal(5,1)) AS avg_impact_pct,
       CAST(migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans) AS decimal(18,0)) AS improvement,
       CONVERT(varchar(16), migs.last_user_seek, 120) AS last_seek
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
  AND (@all = 1 OR mid.object_id IN (SELECT object_id FROM t))
ORDER BY migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans) DESC;

-- 2. Existing indexes on the same tables (whole database: only tables with a missing-index request)
;WITH t AS (
    SELECT d.referenced_id AS object_id
    FROM sys.sql_expression_dependencies d JOIN sys.tables tb ON tb.object_id = d.referenced_id
    WHERE d.referencing_id = @oid
    UNION
    SELECT @tid WHERE @tid IS NOT NULL
    UNION
    SELECT mid.object_id FROM sys.dm_db_missing_index_details mid WHERE @all = 1 AND mid.database_id = DB_ID()
),
k AS (
    SELECT ic.object_id, ic.index_id,
           STRING_AGG(CASE WHEN ic.is_included_column = 0 THEN c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END END, N', ')
               WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id) AS key_cols,
           STRING_AGG(CASE WHEN ic.is_included_column = 1 THEN c.name END, N', ')
               WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id) AS include_cols
    FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id IN (SELECT object_id FROM t)
    GROUP BY ic.object_id, ic.index_id
),
sz AS (
    SELECT ps.object_id, ps.index_id, SUM(ps.row_count) AS row_count, SUM(ps.used_page_count) * 8 / 1024.0 AS used_mb
    FROM sys.dm_db_partition_stats ps WHERE ps.object_id IN (SELECT object_id FROM t)
    GROUP BY ps.object_id, ps.index_id
)
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name, i.type_desc,
       i.is_unique, i.is_primary_key, i.is_disabled, k.key_cols, k.include_cols, i.filter_definition,
       sz.row_count, CAST(sz.used_mb AS decimal(12,1)) AS used_mb,
       us.user_seeks, us.user_scans, us.user_lookups, us.user_updates AS user_writes,
       CONVERT(varchar(16), (SELECT MAX(v) FROM (VALUES (us.last_user_seek), (us.last_user_scan), (us.last_user_lookup)) x(v)), 120) AS last_read
FROM sys.indexes i
LEFT JOIN k ON k.object_id = i.object_id AND k.index_id = i.index_id
LEFT JOIN sz ON sz.object_id = i.object_id AND sz.index_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
WHERE i.object_id IN (SELECT object_id FROM t) AND i.type > 0
ORDER BY table_name, i.index_id;
