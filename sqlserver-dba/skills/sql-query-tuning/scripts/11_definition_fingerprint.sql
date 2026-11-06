/*  11_definition_fingerprint.sql  (read-only)
    Purpose : everything a safe in-procedure patch depends on, for one object: the exact live text (SHA-256 hash),
              dates, SET options, whether it is signed, plan guides, Query Store forced plans, permissions, what it
              references and what references it, and whether it already carries your change marker.
              Run it before building a patch (to record the baseline), and after every vendor upgrade (to see
              whether the upgrade replaced your patch or the vendor changed the code).
    Needs   : SQL Server 2016+, VIEW DEFINITION on the object, VIEW DATABASE STATE.
    Params  : EDIT ME block. @Marker = the comment tag your patches carry, e.g. N'MyCo 2026-'.
    Reading : hash_sha256 is the value a guarded deploy compares before it changes anything: if it differs from
              the hash the patch was built from, rebuild the patch from the current text.
              The SET options must be the same when the patch is applied (ANSI_NULLS / QUOTED_IDENTIFIER are
              stored with the module and the patch script must set them to match).
              A signature is dropped when a module is redefined; a plan guide or forced plan may stop matching.
              Permissions survive a redefinition of the same object, but not removing the object and building it again.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -i 11_definition_fingerprint.sql
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Object nvarchar(300) = N'dbo.SomeProc',
        @Marker nvarchar(200) = N'MyCo 20';   -- text your patches add in a comment; NULL to skip
---------------------------------------------------------------------------------------------------------------------

DECLARE @oid int = OBJECT_ID(@Object);
IF @oid IS NULL RAISERROR(N'Object %s not found in this database', 16, 1, @Object);
DECLARE @def nvarchar(max) = OBJECT_DEFINITION(@oid);
DECLARE @pos int = CASE WHEN @Marker IS NULL THEN 0 ELSE CHARINDEX(@Marker, @def) END;

-- 1. Identity, dates, hash, options, marker
SELECT DB_NAME() AS db, OBJECT_SCHEMA_NAME(o.object_id) + N'.' + o.name AS object_name, o.object_id, o.type_desc,
       CONVERT(varchar(19), o.create_date, 120) AS created, CONVERT(varchar(19), o.modify_date, 120) AS modified,
       CONVERT(varchar(66), HASHBYTES('SHA2_256', @def), 1) AS hash_sha256,
       LEN(@def) AS definition_chars,
       (LEN(@def) - LEN(REPLACE(@def, NCHAR(10), N''))) + 1 AS definition_lines,
       m.uses_ansi_nulls, m.uses_quoted_identifier, m.is_schema_bound, m.uses_native_compilation,
       USER_NAME(m.execute_as_principal_id) AS execute_as_user, o.is_ms_shipped,
       CASE WHEN @Marker IS NULL THEN 'n/a' WHEN @pos > 0 THEN 'yes' ELSE 'no' END AS has_marker,
       CASE WHEN @pos > 0 THEN REPLACE(REPLACE(SUBSTRING(@def, CASE WHEN @pos > 60 THEN @pos - 60 ELSE 1 END, 200), CHAR(13), ' '), CHAR(10), ' ') END AS marker_context
FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.object_id = @oid;

-- 2. Signatures (lost when the module is redefined) and plan guides scoped to it
SELECT 'signature' AS kind, cp.crypt_type_desc AS detail, CONVERT(varchar(66), cp.thumbprint, 1) AS name_or_value
FROM sys.crypt_properties cp WHERE cp.class = 1 AND cp.major_id = @oid
UNION ALL
SELECT 'plan guide', CASE WHEN pg.is_disabled = 1 THEN 'disabled' ELSE 'enabled' END, pg.name
FROM sys.plan_guides pg WHERE pg.scope_object_id = @oid
UNION ALL
SELECT 'forced plan (Query Store)', 'query_id ' + CAST(p.query_id AS varchar(20)) + ', failures ' + CAST(p.force_failure_count AS varchar(10)),
       'plan_id ' + CAST(p.plan_id AS varchar(20))
FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE q.object_id = @oid AND p.is_forced_plan = 1;

-- 3. Permissions on the object (compare before and after a deploy)
SELECT USER_NAME(pe.grantee_principal_id) AS grantee, pe.permission_name, pe.state_desc,
       USER_NAME(pe.grantor_principal_id) AS grantor
FROM sys.database_permissions pe
WHERE pe.class = 1 AND pe.major_id = @oid
ORDER BY grantee, pe.permission_name;

-- 4. What it references (tables, views, functions, other modules)
SELECT ISNULL(d.referenced_database_name + N'.', N'') + ISNULL(d.referenced_schema_name, N'?') + N'.' + d.referenced_entity_name AS referenced,
       ISNULL(o.type_desc, CASE WHEN d.referenced_database_name IS NOT NULL THEN 'CROSS-DATABASE' ELSE 'UNRESOLVED' END) AS type_desc,
       d.is_caller_dependent, d.is_ambiguous
FROM sys.sql_expression_dependencies d
LEFT JOIN sys.objects o ON o.object_id = d.referenced_id
WHERE d.referencing_id = @oid
GROUP BY d.referenced_database_name, d.referenced_schema_name, d.referenced_entity_name, o.type_desc, d.is_caller_dependent, d.is_ambiguous
ORDER BY type_desc, referenced;

-- 5. What references it (callers inside this database; application callers are not listed here, see 08)
SELECT OBJECT_SCHEMA_NAME(d.referencing_id) + N'.' + OBJECT_NAME(d.referencing_id) AS referencing_object, o.type_desc,
       CONVERT(varchar(16), o.modify_date, 120) AS modified
FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id = d.referencing_id
WHERE d.referenced_id = @oid
ORDER BY referencing_object;

-- 6. Query Store statements of the object, newest first. A statement whose text changed in a redefinition gets a
--    new query_id first compiled at the deploy time, and the old one stops running: this dates code changes.
DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
SELECT TOP (50) q.query_id, CONVERT(varchar(20), q.query_hash, 1) AS query_hash,
       CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(q.initial_compile_start_time AS datetime)), 120) AS first_compiled_local,
       CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(q.last_execution_time AS datetime)), 120) AS last_run_local,
       LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 120) AS stmt
FROM sys.query_store_query q JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
WHERE q.object_id = @oid
ORDER BY q.initial_compile_start_time DESC;
