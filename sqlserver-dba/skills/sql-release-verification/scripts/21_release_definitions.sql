/*  21_release_definitions.sql  (read-only)
    Purpose : a snapshot of every module's live text in scope, one block per object, for Compare-Definitions.ps1.
              Take one BEFORE a release whenever you hear of one (it is the only exact "before" you will have),
              and one after. Production is the truth: release notes and source control are claims about it.
    Needs   : VIEW DEFINITION on the modules (encrypted modules come out empty and are reported as such).
    Params  : EDIT ME block.
    Output  : each block starts with a line
                  @@@@ schema.name | type | sha256 of the text | modified (local)
              followed by the definition exactly as stored. Compare-Definitions.ps1 checks every block's local
              SHA-256 against the server's, so a capture damaged by line-ending conversion or truncation is caught.
    Run     : the switches matter: -y 0 keeps long text whole and -f 65001 keeps the characters (-h can't be
              combined with -y 0, and isn't needed: the comparer skips anything before the first block).
              sqlcmd -S <server> -d <db> -E -I -y 0 -f 65001 -t 300 -i 21_release_definitions.sql -o defs_<yyyymmdd_hhmm>.txt
              Keep the file as written (no editor, no line-ending conversion).
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Schema   nvarchar(128) = NULL,   -- e.g. N'app'; NULL = every schema
        @NameLike nvarchar(300) = NULL;   -- e.g. N'usp[_]Feed%'; NULL = every name
---------------------------------------------------------------------------------------------------------------------

SELECT N'@@@@ ' + SCHEMA_NAME(o.schema_id) COLLATE DATABASE_DEFAULT + N'.' + o.name COLLATE DATABASE_DEFAULT
       + N' | ' + RTRIM(o.type) COLLATE DATABASE_DEFAULT
       + N' | ' + ISNULL(CONVERT(nvarchar(66), HASHBYTES('SHA2_256', m.definition), 1), N'encrypted') COLLATE DATABASE_DEFAULT
       + N' | ' + CONVERT(nvarchar(19), o.modify_date, 120) COLLATE DATABASE_DEFAULT
       + NCHAR(13) + NCHAR(10) + ISNULL(m.definition COLLATE DATABASE_DEFAULT, N'')
FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND (@Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
  AND (@NameLike IS NULL OR o.name LIKE @NameLike)
ORDER BY SCHEMA_NAME(o.schema_id), o.name;
