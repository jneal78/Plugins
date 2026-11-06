/*  19_release_changes.sql  (read-only)
    Purpose : what a release changed since a given time, in one schema, a name pattern or the whole database.
              1. The deploy window: changes per 10 minutes (one burst is the release; a later one is often a
                 hot-fix or a local customization re-applied by hand).
              2. Every module, synonym and sequence added or redefined: dates, SHA-256 of the live text, the
                 vendor's version note, your change marker, SET options, explicit permissions and signatures.
              3. Which redefined modules really changed statements, from Query Store, with no snapshot needed: a
                 statement text first compiled after the module's last redefinition, and never before, is new code.
              4. The new statement texts themselves.
              5. Tables touched: rows, indexes, newest statistics, and names that look like a deploy's copy table.
              6. Problems on the tables in scope: untrusted or disabled constraints, disabled indexes and triggers,
                 and triggers, keys and defaults the release re-added.
              7. Database settings a deploy script can flip (compatibility level, isolation, Query Store state,
                 database-scoped configuration).
    Needs   : SQL Server 2016+, VIEW DEFINITION (hashes and version notes), VIEW DATABASE STATE (Query Store, rows).
    Params  : EDIT ME block. Dates are the server's local time, as sys.objects stores them.
    Reading : modify_date says an object was redefined, not that it changed. A vendor that re-applies its whole
              schema touches every object; section 3 and a definition diff (21 + Compare-Definitions.ps1) say
              which really changed. In one real release, 150 modules were redefined and 7 had new code.
              Section 3 compares each module with its own modify_date (its last redefinition). It is evidence for
              the statements that ran, not proof:
                - a branch that has not run since the redefinition cannot show up ('not run since: no evidence');
                - a module that was removed and re-added has a new object_id, so its old statements are on the
                  old id: 04 lists them as GONE;
                - a change that only adds or removes a hint keeps the query_hash but not the text, so it shows here;
                - Query Store size-based cleanup can make an old text look new (check query_store_state and the
                  size in section 7);
                - a database restored or re-created from elsewhere has no history: every text looks new.
              explicit_permissions = 0 on a module that was re-added (change 'added') while its neighbours have
              some means the release removed and re-added it without its permissions: callers get error 229.
              ansi_nulls / quoted_id = 0 on a module breaks it on tables with filtered indexes, indexed views or
              indexed computed columns (error 1934), and breaks XML methods inside it.
              Untrusted constraints (re-added without checking existing rows) stop the optimizer from using them.
              Section 5 and 6 cover tables in any schema touched since @Since; index maintenance moves a table's
              modify_date too, so read them next to the deploy window from section 1.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -t 120 -i 19_release_changes.sql -o changes.txt
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Since           datetime      = '2026-01-01T00:00:00', -- local; a little before the release started
        @Schema          nvarchar(128) = NULL,         -- e.g. N'app'; NULL = every schema
        @NameLike        nvarchar(300) = NULL,         -- e.g. N'usp[_]Feed%'; NULL = every name
        @VersionTag      nvarchar(100) = N'VERSION:',  -- text that starts the vendor's version note in a header; NULL to skip
        @Marker          nvarchar(200) = NULL,         -- your change marker, e.g. N'MyCo 20'; NULL to skip
        @TablesAnySchema bit           = 1,            -- 1 = sections 5-6 cover tables touched in any schema
        @TopN            int           = 300;
---------------------------------------------------------------------------------------------------------------------

DECLARE @off int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());
DECLARE @first datetime = (SELECT MIN(o.modify_date) FROM sys.objects o   -- modules only: index maintenance moves table dates
                           WHERE o.is_ms_shipped = 0 AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V', 'SN', 'SO')
                             AND o.modify_date >= @Since
                             AND (@Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
                             AND (@NameLike IS NULL OR o.name LIKE @NameLike));

-- 0. Scope
SELECT DB_NAME() AS db, CONVERT(varchar(19), GETDATE(), 120) AS now_local, @off AS utc_offset_min,
       CONVERT(varchar(19), @Since, 120) AS since_local, ISNULL(@Schema, N'(all)') AS scope_schema,
       ISNULL(@NameLike, N'(all)') AS scope_name, CONVERT(varchar(19), @first, 120) AS first_module_change_local,
       (SELECT actual_state_desc FROM sys.database_query_store_options) AS query_store_state;

-- 1. Deploy window: changes per 10 minutes
SELECT CONVERT(varchar(16), DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', o.modify_date) / 10) * 10, '20000101'), 120) AS bucket_local,
       SUM(CASE WHEN o.type <> 'U' THEN 1 ELSE 0 END) AS modules,
       SUM(CASE WHEN o.type <> 'U' AND o.create_date >= @Since THEN 1 ELSE 0 END) AS modules_added,
       SUM(CASE WHEN o.type = 'U' THEN 1 ELSE 0 END) AS tables,
       CONVERT(varchar(19), MIN(o.modify_date), 120) AS first_local, CONVERT(varchar(19), MAX(o.modify_date), 120) AS last_local,
       MIN(SCHEMA_NAME(o.schema_id) + N'.' + o.name) AS example
FROM sys.objects o
WHERE o.is_ms_shipped = 0 AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V', 'U', 'SN', 'SO')
  AND o.modify_date >= @Since
  AND (@Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
  AND (@NameLike IS NULL OR o.name LIKE @NameLike)
GROUP BY DATEADD(MINUTE, (DATEDIFF(MINUTE, '20000101', o.modify_date) / 10) * 10, '20000101')
ORDER BY bucket_local;

-- 2. Modules, synonyms and sequences added or redefined since @Since (summary, then one row each; tables are in 5)
;WITH c AS (
    SELECT o.object_id, o.type, CASE WHEN o.create_date >= @Since THEN 'added' ELSE 'redefined' END AS change,
           m.definition, m.uses_ansi_nulls, m.uses_quoted_identifier, CASE WHEN m.object_id IS NOT NULL THEN 1 ELSE 0 END AS is_module
    FROM sys.objects o LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
    WHERE o.is_ms_shipped = 0 AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V', 'SN', 'SO')
      AND o.modify_date >= @Since
      AND (@Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
      AND (@NameLike IS NULL OR o.name LIKE @NameLike)
)
SELECT RTRIM(type) AS type, change, COUNT(*) AS objects,
       SUM(CASE WHEN is_module = 1 AND definition IS NULL THEN 1 ELSE 0 END) AS encrypted,
       SUM(CASE WHEN uses_ansi_nulls = 0 OR uses_quoted_identifier = 0 THEN 1 ELSE 0 END) AS set_options_off,
       SUM(CASE WHEN @Marker IS NOT NULL AND CHARINDEX(@Marker, definition) > 0 THEN 1 ELSE 0 END) AS with_marker
FROM c GROUP BY type, change ORDER BY type, change;

SELECT TOP (@TopN)
       SCHEMA_NAME(o.schema_id) + N'.' + o.name AS object_name, RTRIM(o.type) AS type,
       CASE WHEN o.create_date >= @Since THEN 'added' ELSE 'redefined' END AS change,
       CONVERT(varchar(19), o.create_date, 120) AS created_local, CONVERT(varchar(19), o.modify_date, 120) AS modified_local,
       CASE WHEN m.object_id IS NULL THEN '' WHEN m.definition IS NULL THEN 'encrypted'
            ELSE CONVERT(varchar(66), HASHBYTES('SHA2_256', m.definition), 1) END AS sha256,
       LEN(m.definition) AS chars,
       CASE WHEN @VersionTag IS NULL OR CHARINDEX(@VersionTag, m.definition) = 0 THEN ''
            ELSE REPLACE(REPLACE(REPLACE(SUBSTRING(m.definition, CHARINDEX(@VersionTag, m.definition), 40), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ') END AS version_note,
       CASE WHEN @Marker IS NULL THEN 'n/a' WHEN CHARINDEX(@Marker, m.definition) > 0 THEN 'yes' ELSE 'no' END AS has_marker,
       m.uses_ansi_nulls AS ansi_nulls, m.uses_quoted_identifier AS quoted_id,
       (SELECT COUNT(*) FROM sys.database_permissions pe WHERE pe.class = 1 AND pe.major_id = o.object_id) AS explicit_permissions,
       (SELECT COUNT(*) FROM sys.crypt_properties cp WHERE cp.class = 1 AND cp.major_id = o.object_id) AS signatures,
       CASE WHEN o.type = 'TR' THEN (SELECT CASE WHEN tr.is_disabled = 1 THEN 'trigger DISABLED' ELSE 'trigger on' END FROM sys.triggers tr WHERE tr.object_id = o.object_id) ELSE '' END AS note
FROM sys.objects o LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0 AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V', 'SN', 'SO')
  AND o.modify_date >= @Since
  AND (@Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
  AND (@NameLike IS NULL OR o.name LIKE @NameLike)
ORDER BY o.modify_date, object_name;

-- 3. Query Store evidence per redefined module, against the module's own last redefinition (mod_utc): statement
--    texts first compiled after it and never before (new code); for modules that kept their object_id, old texts
--    that have not run since
IF EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state <> 0)
BEGIN
    ;WITH chg AS (
        SELECT o.object_id, TODATETIMEOFFSET(DATEADD(MINUTE, -@off, o.modify_date), 0) AS mod_utc
        FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
        WHERE o.is_ms_shipped = 0 AND o.modify_date >= @Since
          AND (@Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
          AND (@NameLike IS NULL OR o.name LIKE @NameLike)
    ),
    q AS (   -- one row per changed module and statement text
        SELECT q.object_id, q.query_text_id, MAX(c.mod_utc) AS mod_utc, MAX(q.last_execution_time) AS last_run
        FROM sys.query_store_query q JOIN chg c ON c.object_id = q.object_id
        GROUP BY q.object_id, q.query_text_id
    ),
    first_seen AS (   -- when each of those texts was first compiled anywhere (old object ids included)
        SELECT q2.query_text_id, MIN(q2.initial_compile_start_time) AS first_compiled
        FROM sys.query_store_query q2 JOIN (SELECT DISTINCT query_text_id FROM q) t ON t.query_text_id = q2.query_text_id
        GROUP BY q2.query_text_id
    ),
    per_obj AS (
        SELECT q.object_id,
               COUNT(*) AS statements_in_qs,
               SUM(CASE WHEN q.last_run >= q.mod_utc THEN 1 ELSE 0 END) AS ran_since_change,
               SUM(CASE WHEN fs.first_compiled >= q.mod_utc THEN 1 ELSE 0 END) AS new_texts,
               SUM(CASE WHEN q.last_run < q.mod_utc THEN 1 ELSE 0 END) AS old_texts_not_run_since
        FROM q JOIN first_seen fs ON fs.query_text_id = q.query_text_id
        GROUP BY q.object_id
    )
    SELECT TOP (@TopN) SCHEMA_NAME(o.schema_id) + N'.' + o.name AS object_name, RTRIM(o.type) AS type,
           CONVERT(varchar(19), o.modify_date, 120) AS modified_local,
           ISNULL(p.statements_in_qs, 0) AS statements_in_qs, ISNULL(p.ran_since_change, 0) AS ran_since_change,
           ISNULL(p.new_texts, 0) AS new_texts, ISNULL(p.old_texts_not_run_since, 0) AS old_texts_not_run_since,
           CASE WHEN p.object_id IS NULL THEN 'no Query Store rows (not run, or not captured)'
                WHEN p.new_texts > 0 THEN 'CODE CHANGED: new statement text'
                WHEN p.ran_since_change = 0 THEN 'not run since: no evidence'
                WHEN p.old_texts_not_run_since > 0 THEN 'same texts so far; some old ones not run since'
                ELSE 'same statement texts (as far as they ran)' END AS evidence
    FROM chg c JOIN sys.objects o ON o.object_id = c.object_id
    LEFT JOIN per_obj p ON p.object_id = c.object_id
    ORDER BY CASE WHEN p.new_texts > 0 THEN 0 WHEN p.old_texts_not_run_since > 0 THEN 1 WHEN p.object_id IS NULL THEN 3 ELSE 2 END,
             ISNULL(p.new_texts, 0) DESC, object_name
    OPTION (HASH JOIN);   -- the Query Store views have no useful indexes: read each once, never once per row

-- 4. The new statement texts (first compiled after their module's last redefinition, never seen before)
    ;WITH chg AS (
        SELECT o.object_id, TODATETIMEOFFSET(DATEADD(MINUTE, -@off, o.modify_date), 0) AS mod_utc
        FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
        WHERE o.is_ms_shipped = 0 AND o.modify_date >= @Since
          AND (@Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
          AND (@NameLike IS NULL OR o.name LIKE @NameLike)
    ),
    q AS (
        SELECT q.query_id, q.query_text_id, q.query_hash, q.object_id, c.mod_utc
        FROM sys.query_store_query q JOIN chg c ON c.object_id = q.object_id
        WHERE q.initial_compile_start_time >= c.mod_utc
    ),
    first_seen AS (
        SELECT q2.query_text_id, MIN(q2.initial_compile_start_time) AS first_compiled
        FROM sys.query_store_query q2 JOIN (SELECT DISTINCT query_text_id FROM q) tx ON tx.query_text_id = q2.query_text_id
        GROUP BY q2.query_text_id
    )
    SELECT TOP (@TopN) OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id) AS object_name, q.query_id,
           CONVERT(varchar(20), q.query_hash, 1) AS query_hash,
           CONVERT(varchar(16), DATEADD(MINUTE, @off, CAST(fs.first_compiled AS datetime)), 120) AS first_compiled_local,
           LEFT(REPLACE(REPLACE(REPLACE(t.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 160) AS stmt
    FROM q JOIN first_seen fs ON fs.query_text_id = q.query_text_id AND fs.first_compiled >= q.mod_utc
    JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
    ORDER BY object_name, q.query_id
    OPTION (HASH JOIN);
END
ELSE
    SELECT 'Query Store is off in this database: sections 3 and 4 skipped. Use a definition diff (21).' AS note;

-- 5. Tables touched since @Since
SELECT TOP (@TopN) SCHEMA_NAME(o.schema_id) + N'.' + o.name AS table_name,
       CASE WHEN o.create_date >= @Since THEN 'added' ELSE 'changed' END AS change,
       CONVERT(varchar(19), o.create_date, 120) AS created_local, CONVERT(varchar(19), o.modify_date, 120) AS modified_local,
       (SELECT SUM(ps.row_count) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = o.object_id AND ps.index_id IN (0, 1)) AS row_count,
       (SELECT COUNT(*) FROM sys.indexes ix WHERE ix.object_id = o.object_id AND ix.index_id > 0) AS indexes,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes ix WHERE ix.object_id = o.object_id AND ix.index_id = 0) THEN 'heap' ELSE '' END AS heap,
       CONVERT(varchar(16), (SELECT MAX(STATS_DATE(s.object_id, s.stats_id)) FROM sys.stats s WHERE s.object_id = o.object_id), 120) AS newest_stats_local,
       CASE WHEN o.name LIKE N'%[_]20[0-9][0-9][01][0-9][0-3][0-9]%' OR o.name LIKE N'%[_]20[0-9][0-9][_-][01][0-9][_-][0-3][0-9]%'
              OR o.name LIKE N'%[_]bak%' OR o.name LIKE N'%[_]old' OR o.name LIKE N'%[_]copy%' OR o.name LIKE N'%[_]save%'
              OR o.name LIKE N'%[_]tmp%' OR o.name LIKE N'%[_]prev%'
            THEN 'looks like a deploy copy' ELSE '' END AS name_hint
FROM sys.objects o
WHERE o.type = 'U' AND o.is_ms_shipped = 0 AND o.modify_date >= @Since
  AND (@TablesAnySchema = 1 OR @Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)
ORDER BY o.modify_date;

-- 6. Problems on the tables in scope (tables of @Schema, plus tables touched since @Since): untrusted or disabled
--    constraints, disabled or hypothetical indexes, disabled triggers; then, per table, the triggers, keys and
--    defaults re-added since @Since (a re-added trigger loses its first / last firing order, which matters only
--    when the table has more than one trigger for the same action)
;WITH t AS (
    SELECT o.object_id FROM sys.objects o
    WHERE o.type = 'U' AND o.is_ms_shipped = 0
      AND ((@Schema IS NOT NULL AND SCHEMA_NAME(o.schema_id) = @Schema)
           OR (o.modify_date >= @Since AND (@TablesAnySchema = 1 OR @Schema IS NULL OR SCHEMA_NAME(o.schema_id) = @Schema)))
)
SELECT TOP (@TopN) OBJECT_SCHEMA_NAME(x.parent_id) + N'.' + OBJECT_NAME(x.parent_id) AS table_name, x.kind, x.name, x.state
FROM (
    SELECT fk.parent_object_id AS parent_id, 'foreign key' AS kind, fk.name,
           CASE WHEN fk.is_disabled = 1 THEN 'DISABLED' WHEN fk.is_not_trusted = 1 THEN 'UNTRUSTED' ELSE 'ok' END AS state
    FROM sys.foreign_keys fk WHERE fk.parent_object_id IN (SELECT object_id FROM t)
    UNION ALL
    SELECT ck.parent_object_id, 'check constraint', ck.name,
           CASE WHEN ck.is_disabled = 1 THEN 'DISABLED' WHEN ck.is_not_trusted = 1 THEN 'UNTRUSTED' ELSE 'ok' END
    FROM sys.check_constraints ck WHERE ck.parent_object_id IN (SELECT object_id FROM t)
    UNION ALL
    SELECT ix.object_id, 'index', ix.name, CASE WHEN ix.is_disabled = 1 THEN 'DISABLED' ELSE 'HYPOTHETICAL' END
    FROM sys.indexes ix WHERE ix.object_id IN (SELECT object_id FROM t) AND (ix.is_disabled = 1 OR ix.is_hypothetical = 1)
    UNION ALL
    SELECT tr.parent_id, 'trigger', tr.name, 'DISABLED'
    FROM sys.triggers tr WHERE tr.parent_id IN (SELECT object_id FROM t) AND tr.is_disabled = 1
    UNION ALL
    SELECT tr.parent_id, 'triggers re-added', CAST(COUNT(*) AS varchar(10)) + ' of ' + CAST(MAX(n.total) AS varchar(10)),
           CASE WHEN MAX(n.total) > 1 THEN 'check firing order (sp_settriggerorder) against the patch notes' ELSE 'only trigger: order n/a' END
    FROM sys.triggers tr
    CROSS APPLY (SELECT COUNT(*) AS total FROM sys.triggers t2 WHERE t2.parent_id = tr.parent_id) n
    WHERE tr.parent_id IN (SELECT object_id FROM t) AND tr.create_date >= @Since
    GROUP BY tr.parent_id
    UNION ALL
    SELECT kc.parent_object_id, 'keys / defaults re-added', CAST(COUNT(*) AS varchar(10)), 'added since @Since'
    FROM sys.objects kc WHERE kc.parent_object_id IN (SELECT object_id FROM t) AND kc.type IN ('PK', 'UQ', 'D', 'F', 'C') AND kc.create_date >= @Since
    GROUP BY kc.parent_object_id
) x
WHERE x.state <> 'ok'
ORDER BY CASE WHEN x.state IN ('DISABLED', 'UNTRUSTED', 'HYPOTHETICAL') THEN 0 ELSE 1 END, table_name, x.kind, x.name;

-- 7. Database settings a deploy script can flip. No history here: compare with the site profile and with 20.
SELECT d.name AS db, d.compatibility_level, d.is_read_committed_snapshot_on AS rcsi, d.snapshot_isolation_state_desc AS snapshot_isolation,
       d.is_parameterization_forced AS forced_parameterization, d.is_auto_create_stats_on AS auto_create_stats,
       d.is_auto_update_stats_on AS auto_update_stats, d.is_auto_update_stats_async_on AS auto_update_stats_async,
       d.recovery_model_desc AS recovery_model, d.collation_name
FROM sys.databases d WHERE d.database_id = DB_ID();

SELECT qso.actual_state_desc, qso.desired_state_desc, qso.readonly_reason, qso.current_storage_size_mb, qso.max_storage_size_mb,
       qso.interval_length_minutes, qso.query_capture_mode_desc, qso.max_plans_per_query, qso.size_based_cleanup_mode_desc
FROM sys.database_query_store_options qso;

SELECT dsc.name, CAST(dsc.value AS nvarchar(100)) AS value, CAST(dsc.value_for_secondary AS nvarchar(100)) AS value_for_secondary
FROM sys.database_scoped_configurations dsc
WHERE dsc.name IN (N'MAXDOP', N'LEGACY_CARDINALITY_ESTIMATION', N'PARAMETER_SNIFFING', N'QUERY_OPTIMIZER_HOTFIXES',
                   N'OPTIMIZE_FOR_AD_HOC_WORKLOADS', N'TSQL_SCALAR_UDF_INLINING', N'BATCH_MODE_ON_ROWSTORE',
                   N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION', N'CE_FEEDBACK', N'DOP_FEEDBACK')
ORDER BY dsc.name;
