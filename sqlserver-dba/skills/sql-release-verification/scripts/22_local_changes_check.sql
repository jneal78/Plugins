/*  22_local_changes_check.sql  (read-only)
    Purpose : did the release keep YOUR changes? One pass over everything the site changed locally in vendor code:
              1. In-procedure patches (from the ledger's Done table and each patch README): as built, a variant,
                 REVERTED to the vendor's original, CHANGED to new vendor text, or MISSING.
              2. Local indexes (by your index prefix, plus a list of expected ones): present, DISABLED, MISSING.
              3. Other local objects that must exist (tables, procedures, functions a patch relies on).
              4. Every forced plan and plan guide in the database, with failures: a redefined or rebuilt object
                 leaves forced plans pointing at old query ids, and forcing fails quietly.
    Needs   : VIEW DEFINITION, VIEW DATABASE STATE.
    Params  : EDIT ME blocks: one VALUES list per section. Fill them from the ledger once and keep the filled copy in
              the site folder, so every release check reruns it unchanged.
    Reading : 1. 'REVERTED' = the release put back the slow original: the patch's guarded deploy still matches it
                 and can be re-applied after a review (core/patch-package.md). 'CHANGED' = new vendor text: read
                 it for the fix you asked for; if it isn't there, rebuild the patch from the new text (the old
                 deploy refuses, as it should). 'variant' = your marker is there but the text differs from the
                 build: someone re-applied it by hand, or the vendor kept your lines in a new version.
              2. An index removed by a table rebuild is the commonest silent loss; check whether the vendor shipped
                 an equivalent before re-adding yours.
              4. force_failure_count > 0 or an object that no longer exists = the forcing no longer applies.
                 A plan guide with a message from sys.fn_validate_plan_guide is invalid.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -t 120 -i 22_local_changes_check.sql -o local_changes.txt
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Since       datetime      = '2026-01-01T00:00:00',  -- local; the release's start (marks what it touched)
        @IndexPrefix nvarchar(100) = N'MyCo[_]%';            -- LIKE pattern of your index names; NULL to skip
---------------------------------------------------------------------------------------------------------------------

-- 1. In-procedure patches
;WITH patches (object_name, marker, original_hash, patched_hash) AS (
    SELECT * FROM (VALUES
        -- EDIT ME: one row per patch: object, marker text, SHA-256 of the vendor original, SHA-256 as deployed
        (N'dbo.SomeProc', N'MyCo 2026-01-01', '0x0000', '0x0000')
    ) v (object_name, marker, original_hash, patched_hash)
),
live AS (
    SELECT p.object_name, p.marker, p.original_hash, p.patched_hash, OBJECT_ID(p.object_name) AS oid,
           CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(p.object_name))), 1) AS hash_now,
           CASE WHEN CHARINDEX(p.marker, OBJECT_DEFINITION(OBJECT_ID(p.object_name))) > 0 THEN 1 ELSE 0 END AS has_marker
    FROM patches p
)
SELECT l.object_name,
       CASE WHEN l.oid IS NULL THEN 'MISSING'
            WHEN l.hash_now IS NULL THEN 'no definition visible (encrypted or no VIEW DEFINITION)'
            WHEN l.hash_now = l.patched_hash THEN 'patched, as built'
            WHEN l.has_marker = 1 THEN 'patched, variant (marker present, text differs)'
            WHEN l.hash_now = l.original_hash THEN 'REVERTED to the vendor original'
            ELSE 'CHANGED: new vendor text, marker gone' END AS state,
       CONVERT(varchar(19), o.modify_date, 120) AS modified_local,
       CASE WHEN o.modify_date >= @Since THEN 'yes' ELSE '' END AS touched_by_release,
       l.hash_now, m.uses_ansi_nulls AS ansi_nulls, m.uses_quoted_identifier AS quoted_id,
       (SELECT COUNT(*) FROM sys.database_permissions pe WHERE pe.class = 1 AND pe.major_id = l.oid) AS explicit_permissions,
       (SELECT COUNT(*) FROM sys.crypt_properties cp WHERE cp.class = 1 AND cp.major_id = l.oid) AS signatures,
       (SELECT COUNT(*) FROM sys.plan_guides pg WHERE pg.scope_object_id = l.oid) AS plan_guides
FROM live l
LEFT JOIN sys.objects o ON o.object_id = l.oid
LEFT JOIN sys.sql_modules m ON m.object_id = l.oid
ORDER BY CASE WHEN l.oid IS NULL OR (l.hash_now <> l.patched_hash AND l.has_marker = 0) THEN 0 ELSE 1 END, l.object_name;

-- 2. Local indexes: expected ones, plus any index named with your prefix
;WITH expected (table_name, index_name) AS (
    SELECT * FROM (VALUES
        -- EDIT ME: one row per local index: table (schema.name), index name
        (N'dbo.SomeTable', N'MyCo_SomeTable_SomeColumn')
    ) v (table_name, index_name)
),
found AS (
    SELECT OBJECT_SCHEMA_NAME(ix.object_id) + N'.' + OBJECT_NAME(ix.object_id) AS table_name, ix.name AS index_name,
           ix.object_id, ix.index_id, ix.type_desc, ix.is_disabled, ix.has_filter, ix.filter_definition
    FROM sys.indexes ix JOIN sys.objects o ON o.object_id = ix.object_id
    WHERE o.is_ms_shipped = 0 AND ix.name IS NOT NULL
      AND (ix.name IN (SELECT index_name FROM expected) OR (@IndexPrefix IS NOT NULL AND ix.name LIKE @IndexPrefix))
)
SELECT COALESCE(f.table_name, e.table_name) AS table_name, COALESCE(f.index_name, e.index_name) AS index_name,
       CASE WHEN f.index_name IS NULL THEN 'MISSING'
            WHEN f.is_disabled = 1 THEN 'DISABLED'
            WHEN e.index_name IS NULL THEN 'present (prefix match, not in the expected list)'
            WHEN e.table_name <> f.table_name THEN 'present, but on another table'
            ELSE 'present' END AS state,
       f.type_desc,
       STUFF((SELECT N', ' + c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = f.object_id AND ic.index_id = f.index_id AND ic.is_included_column = 0
              ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, N'') AS key_columns,
       STUFF((SELECT N', ' + c.name
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = f.object_id AND ic.index_id = f.index_id AND ic.is_included_column = 1
              ORDER BY c.name FOR XML PATH('')), 1, 2, N'') AS included_columns,
       f.filter_definition,
       CONVERT(varchar(16), STATS_DATE(f.object_id, f.index_id), 120) AS stats_date_local
FROM found f FULL JOIN expected e ON e.index_name = f.index_name
ORDER BY CASE WHEN f.index_name IS NULL OR f.is_disabled = 1 THEN 0 ELSE 1 END, table_name, index_name;

-- 3. Other local objects that must exist
;WITH must (object_name) AS (
    SELECT * FROM (VALUES
        -- EDIT ME: one row per local object (schema.name)
        (N'dbo.SomeLocalTable')
    ) v (object_name)
)
SELECT m.object_name, CASE WHEN o.object_id IS NULL THEN 'MISSING' ELSE 'present' END AS state, o.type_desc,
       CONVERT(varchar(19), o.create_date, 120) AS created_local, CONVERT(varchar(19), o.modify_date, 120) AS modified_local,
       CASE WHEN o.modify_date >= @Since THEN 'yes' ELSE '' END AS touched_by_release,
       CASE WHEN o.type = 'U' THEN (SELECT SUM(ps.row_count) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = o.object_id AND ps.index_id IN (0, 1)) END AS row_count
FROM must m LEFT JOIN sys.objects o ON o.object_id = OBJECT_ID(m.object_name)
ORDER BY CASE WHEN o.object_id IS NULL THEN 0 ELSE 1 END, m.object_name;

-- 4. Forced plans (Query Store) and plan guides, all of them
SELECT 'forced plan' AS kind, p.plan_id, q.query_id,
       CASE WHEN q.object_id = 0 THEN N'(ad hoc)'
            ELSE ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(object gone: id ' + CAST(q.object_id AS nvarchar(12)) + N')') END AS object_name,
       p.force_failure_count, p.last_force_failure_reason_desc,
       CONVERT(varchar(16), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), CAST(p.last_execution_time AS datetime)), 120) AS plan_last_run_local,
       CONVERT(varchar(16), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), CAST(q.last_execution_time AS datetime)), 120) AS query_last_run_local,
       CASE WHEN q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NULL THEN 'ORPHANED: the object was rebuilt or removed'
            WHEN p.force_failure_count > 0 THEN 'FAILING'
            WHEN o.modify_date >= @Since THEN 'object touched by the release: check it still applies'
            ELSE 'ok' END AS state
FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id
LEFT JOIN sys.objects o ON o.object_id = q.object_id
WHERE p.is_forced_plan = 1
ORDER BY state, object_name;

SELECT 'plan guide' AS kind, pg.name, pg.scope_type_desc,
       ISNULL(OBJECT_SCHEMA_NAME(pg.scope_object_id) + N'.' + OBJECT_NAME(pg.scope_object_id), N'') AS scope_object,
       CASE WHEN pg.is_disabled = 1 THEN 'disabled' ELSE 'enabled' END AS enabled,
       v.msgnum AS validation_error, LEFT(v.message, 200) AS validation_message
FROM sys.plan_guides pg
OUTER APPLY sys.fn_validate_plan_guide(pg.plan_guide_id) v
ORDER BY pg.name;
