/*=====================================================================================================================
  DEPLOY  <schema>.<object>  (<MARKER> in-procedure fix: <n> hints / small rewrite; no Query Store changes, no index changes)
  Target  : PRODUCTION <Database>. Run in SSMS as a user who can alter <schema>.<object>.   ** DBA-run; contains DDL **
  Change  : <n> lines in <which statement> (Query Store query <id>), each marked "-- <MARKER>":
              <old line>   ->   <new line>
            <one or two sentences: which operator it removes and why the output can't change>
  Measured: <Query Store per run / per day before>. Read-only on production, <date time>, original vs patched as SELECTs,
            run back to back (patched, original, patched):
              original : <cpu> CPU, <elapsed> elapsed, <reads> logical reads
              patched  : <cpu> CPU, <elapsed> elapsed, <reads> logical reads    same <n> rows
  Safety  : STEP 0 stops the deploy (SET NOEXEC ON) if the database is wrong, the live definition is not the expected
            original (SHA-256), it is already patched, the object is running right now, a plan guide / signature is
            attached, the SET options in STEP 1 don't match the original, a trigger's firing order would be lost, or an
            index the hints rely on is missing. LOCK_TIMEOUT 5 s. <When it runs / the deploy window>.
  Rollback: <object>_original_rollback.sql (the exact live definition, hash <0x...first8...last8>).
=====================================================================================================================*/
USE <Database>
GO
SET NOCOUNT ON
SET LOCK_TIMEOUT 5000
GO

---------------------------------------------------------------------------------------------------------------------
-- STEP 0. Safety checks
---------------------------------------------------------------------------------------------------------------------
DECLARE @fail nvarchar(400) = NULL,
        @obj  nvarchar(300) = N'<schema>.<object>',
        @marker nvarchar(100) = N'<MARKER>',                                  -- e.g. N'MyCo 2026-10-28'
        @expected varchar(66) = '<0x... SHA-256 of the original OBJECT_DEFINITION, 66 chars>',
        @ansiNulls bit = <1>,                -- the SET ANSI_NULLS value in STEP 1 (from sys.sql_modules of the original)
        @quotedId  bit = <1>,                -- the SET QUOTED_IDENTIFIER value in STEP 1
        @triggerOrderHandled bit = 0,        -- 1 only if STEP 2 re-applies sp_settriggerorder (ALTER TRIGGER drops it)
        @requiredIndexes nvarchar(max) = N'' -- indexes the hints rely on, 'schema.table.index;...': FORCESEEK without a
                                             -- usable index fails with error 8622, an INDEX() hint on a missing one 308
DECLARE @current varchar(66) = CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(@obj))), 1)
DECLARE @ix xml = CAST(N'<i>' + REPLACE(@requiredIndexes, N';', N'</i><i>') + N'</i>' AS xml)
DECLARE @missingIndex nvarchar(400) = (
    SELECT TOP (1) v.name
    FROM (SELECT LTRIM(RTRIM(n.value('.', 'nvarchar(400)'))) AS name FROM @ix.nodes('i') x(n)) v
    WHERE v.name <> N''
      AND NOT EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = OBJECT_ID(PARSENAME(v.name, 3) + N'.' + PARSENAME(v.name, 2))
                        AND i.name = PARSENAME(v.name, 1)))

IF DB_NAME() <> N'<Database>'
    SET @fail = N'Wrong database: ' + DB_NAME()
ELSE IF OBJECT_ID(@obj) IS NULL
    SET @fail = @obj + N' not found'
ELSE IF OBJECT_DEFINITION(OBJECT_ID(@obj)) LIKE N'%' + @marker + N'%'
    SET @fail = N'Already patched - nothing to do'
ELSE IF @current <> @expected
    SET @fail = N'Live definition changed since the patch was built (hash ' + @current + N') - rebuild the patch from the current definition'
ELSE IF EXISTS (SELECT 1 FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
                 WHERE t.dbid = DB_ID() AND t.objectid = OBJECT_ID(@obj))
    SET @fail = @obj + N' is running right now - try again in a few minutes'
ELSE IF EXISTS (SELECT 1 FROM sys.plan_guides WHERE scope_object_id = OBJECT_ID(@obj))
    SET @fail = N'A plan guide is scoped to the object - review before deploying'
ELSE IF EXISTS (SELECT 1 FROM sys.crypt_properties WHERE major_id = OBJECT_ID(@obj))
    SET @fail = N'The object is signed - ALTER would drop the signature'
ELSE IF EXISTS (SELECT 1 FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID(@obj)
                 AND (m.uses_ansi_nulls <> @ansiNulls OR m.uses_quoted_identifier <> @quotedId))
    SET @fail = N'The original''s ANSI_NULLS / QUOTED_IDENTIFIER differ from STEP 1 - set STEP 1 (and @ansiNulls / @quotedId) to match'
ELSE IF @triggerOrderHandled = 0 AND EXISTS (SELECT 1 FROM sys.trigger_events WHERE object_id = OBJECT_ID(@obj) AND (is_first = 1 OR is_last = 1))
    SET @fail = N'The trigger has a first/last firing order, which ALTER drops - add sp_settriggerorder to STEP 2 and set @triggerOrderHandled = 1'
ELSE IF @missingIndex IS NOT NULL
    SET @fail = N'Index ' + @missingIndex + N' that the patch''s hints rely on does not exist - the patched statement would fail'
-- Note: "running right now" sees only the innermost module of each request; if the object is called by other procedures,
-- check them too before deploying during traffic.

SELECT @@SERVERNAME AS server_name, DB_NAME() AS db, SUSER_SNAME() AS deployed_by, SYSDATETIME() AS checked_at,
       @current AS current_hash, ISNULL(@fail, N'OK') AS precheck
SELECT USER_NAME(p.grantee_principal_id) AS grantee_before, p.permission_name, p.state_desc
  FROM sys.database_permissions p WHERE p.major_id = OBJECT_ID(@obj)

IF @fail IS NOT NULL
BEGIN
    RAISERROR(N'DEPLOY STOPPED: %s', 16, 1, @fail)
    SET NOEXEC ON
END
GO

---------------------------------------------------------------------------------------------------------------------
-- STEP 1. The patched object: the live definition + the marked lines, with the same SET options as the original.
--         Everything between the GO after QUOTED_IDENTIFIER and the next GO is the object text.
---------------------------------------------------------------------------------------------------------------------
SET ANSI_NULLS ON          -- match sys.sql_modules.uses_ansi_nulls of the original
GO
SET QUOTED_IDENTIFIER ON   -- match sys.sql_modules.uses_quoted_identifier of the original
GO
ALTER <PROCEDURE | FUNCTION | TRIGGER> [<schema>].[<object>]   -- the object's own type
    /* paste the live definition here, starting after the object name, with the marked changes */
GO

---------------------------------------------------------------------------------------------------------------------
-- STEP 2. Confirm
---------------------------------------------------------------------------------------------------------------------
SET NOEXEC OFF
GO
DECLARE @obj nvarchar(300) = N'<schema>.<object>'
SELECT o.name, CONVERT(varchar(19), o.modify_date, 120) AS modified,
       CASE WHEN OBJECT_DEFINITION(o.object_id) LIKE N'%<MARKER>%' THEN 'PATCHED' ELSE 'NOT PATCHED' END AS version,
       CASE CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(o.object_id)), 1)
            WHEN '<0x... patched hash, as built>' THEN 'as built' ELSE 'hash differs from the rehearsal' END AS build_check,
       m.uses_ansi_nulls, m.uses_quoted_identifier
FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.object_id = OBJECT_ID(@obj)
SELECT USER_NAME(p.grantee_principal_id) AS grantee_after, p.permission_name, p.state_desc
  FROM sys.database_permissions p WHERE p.major_id = OBJECT_ID(@obj)
GO
