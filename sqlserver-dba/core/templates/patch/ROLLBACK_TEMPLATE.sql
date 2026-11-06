/*=====================================================================================================================
  ROLLBACK  <schema>.<object>  (restores the original definition, byte for byte, removing the <MARKER> fix)
  Target  : PRODUCTION <Database>. Run in SSMS as a user who can alter <schema>.<object>.   ** DBA-run; contains DDL **
  Restores: the definition captured from production on <date>, SHA-256 <0x...original, first8...last8>.
  Safety  : STEP 0 stops the rollback (SET NOEXEC ON) unless the live object is exactly OUR patched build. In
            particular it refuses when a vendor upgrade has replaced the object since the patch was deployed: rolling
            back then would overwrite the vendor's new code with the pre-upgrade original. Also stops on the wrong
            database, when the object is already the original, when it is running right now, or when a plan guide or
            signature is attached. LOCK_TIMEOUT 5 s.
  Build   : STEP 1 is the captured live text with its first CREATE turned into ALTER and nothing else
            (core/patch-package.md, "Byte-exact text"). Assemble the file from three parts: this header and STEP 0, the
            object text, and the STEP 2 tail; never edit the object text by hand.
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
        @original varchar(66) = '<0x... SHA-256 of the original definition, 66 chars>',
        @patched  varchar(66) = '<0x... SHA-256 of the patched definition as deployed, 66 chars>',
        @AllowMarkedVariant bit = 0   -- 1 only after reviewing: the live text carries our marker but not our exact hash
DECLARE @current varchar(66) = CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(@obj))), 1)
DECLARE @hasMarker bit = CASE WHEN OBJECT_DEFINITION(OBJECT_ID(@obj)) LIKE N'%' + @marker + N'%' THEN 1 ELSE 0 END

IF DB_NAME() <> N'<Database>'
    SET @fail = N'Wrong database: ' + DB_NAME()
ELSE IF OBJECT_ID(@obj) IS NULL
    SET @fail = @obj + N' not found'
ELSE IF @current = @original
    SET @fail = N'Already the original definition - nothing to do'
ELSE IF @current <> @patched AND @hasMarker = 0
    SET @fail = N'The live definition is neither our patch nor the original (hash ' + @current
              + N'): probably a vendor upgrade. Rolling back would overwrite it with the old code - review instead'
ELSE IF @current <> @patched AND @AllowMarkedVariant = 0
    SET @fail = N'The live text carries our marker but differs from the patched build (hash ' + @current
              + N'). Compare it with the patch; set @AllowMarkedVariant = 1 only if the difference is understood'
ELSE IF EXISTS (SELECT 1 FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
                 WHERE t.dbid = DB_ID() AND t.objectid = OBJECT_ID(@obj))
    SET @fail = @obj + N' is running right now - try again in a few minutes'
ELSE IF EXISTS (SELECT 1 FROM sys.plan_guides WHERE scope_object_id = OBJECT_ID(@obj))
    SET @fail = N'A plan guide is scoped to the object - review before rolling back'
ELSE IF EXISTS (SELECT 1 FROM sys.crypt_properties WHERE major_id = OBJECT_ID(@obj))
    SET @fail = N'The object is signed - ALTER would drop the signature'

SELECT @@SERVERNAME AS server_name, DB_NAME() AS db, SUSER_SNAME() AS rolled_back_by, SYSDATETIME() AS checked_at,
       @current AS current_hash, @hasMarker AS has_marker, ISNULL(@fail, N'OK') AS precheck
SELECT USER_NAME(p.grantee_principal_id) AS grantee_before, p.permission_name, p.state_desc
  FROM sys.database_permissions p WHERE p.major_id = OBJECT_ID(@obj)

IF @fail IS NOT NULL
BEGIN
    RAISERROR(N'ROLLBACK STOPPED: %s', 16, 1, @fail)
    SET NOEXEC ON
END
GO

---------------------------------------------------------------------------------------------------------------------
-- STEP 1. The original object, byte for byte, with the original SET options.
--         Everything between the GO after QUOTED_IDENTIFIER and the next GO is the captured text with its first
--         CREATE turned into ALTER. SQL Server stores it as CREATE again, so the hash returns to the original.
---------------------------------------------------------------------------------------------------------------------
SET ANSI_NULLS ON          -- match sys.sql_modules.uses_ansi_nulls of the original
GO
SET QUOTED_IDENTIFIER ON   -- match sys.sql_modules.uses_quoted_identifier of the original
GO
/* paste the captured original here: header comments included, first CREATE turned into ALTER, nothing else */
GO

---------------------------------------------------------------------------------------------------------------------
-- STEP 2. Confirm
---------------------------------------------------------------------------------------------------------------------
SET NOEXEC OFF
GO
DECLARE @obj nvarchar(300) = N'<schema>.<object>'
SELECT o.name, CONVERT(varchar(19), o.modify_date, 120) AS modified,
       CASE CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(o.object_id)), 1)
            WHEN '<0x... SHA-256 of the original definition>' THEN 'ORIGINAL restored (hash matches)'
            ELSE 'hash differs from the original - check the rollback text' END AS result,
       m.uses_ansi_nulls, m.uses_quoted_identifier
FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.object_id = OBJECT_ID(@obj)
SELECT USER_NAME(p.grantee_principal_id) AS grantee_after, p.permission_name, p.state_desc
  FROM sys.database_permissions p WHERE p.major_id = OBJECT_ID(@obj)
GO
