/*  17_deadlock_objects.sql  (read-only)
    Purpose : the tables and indexes a deadlock pattern locks, and what about them makes a deadlock possible:
              heaps, missing or non-covering indexes, scans, lock escalation, unindexed foreign keys, triggers, and
              every other piece of code that touches the same tables (the other side of a lock-order problem).
    Needs   : VIEW DATABASE STATE, VIEW DEFINITION (names of referencing code). Run it in the tables' database.
    Params  : EDIT ME block. @Tables comes from the analyzer (deadlock_patterns.md, "Objects"); @HobtIds is only
              needed when a graph has no object names: the number in a wait resource "KEY: <db_id>:<hobt_id> (...)"
              or "PAGE"/"RID" resources that the analyzer could not name.
    Reading : 1. hobt ids to names.
              2. Indexes: keys, includes, row and page lock options, escalation setting, size. A heap holding a queue,
                 or a table whose only index doesn't lead on the column the deadlocking statement filters by, is
                 usually the root cause by itself.
              3. Usage since restart: scans on a hot table point at the scanner side; lookups on the clustered
                 index point at the key-lookup pattern (a reader on a nonclustered index meeting a writer on the
                 clustered one).
              4. Lock contention per index since its metadata was cached: row and page lock waits, and lock
                 escalations (index_lock_promotion_count > 0 means some statement took a table lock).
              5. Foreign keys to and from these tables, with cascades, and whether the referencing column leads an
                 index. An unindexed foreign key makes every key change or removal on the parent scan the child.
              6. Triggers on these tables: they run inside the writer's transaction and lengthen it.
              7. Other code that references these tables (procedures, functions, triggers, views): the candidates
                 for the other side of a lock-order inversion, and for "who else takes these locks".
              8. This database's isolation settings.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -t 60 -i 17_deadlock_objects.sql -o objects.txt
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @Tables  nvarchar(max) = N'dbo.Orders; dbo.OrderLines',
        @HobtIds nvarchar(max) = N'';      -- e.g. N'72057594045136896; 72057594045202432'
---------------------------------------------------------------------------------------------------------------------

DECLARE @tx xml = CAST(N'<t>' + REPLACE(@Tables, N';', N'</t><t>') + N'</t>' AS xml);
DECLARE @hx xml = CAST(N'<t>' + REPLACE(@HobtIds, N';', N'</t><t>') + N'</t>' AS xml);
DECLARE @ids nvarchar(max) = N',';

SELECT @ids = @ids + CAST(OBJECT_ID(LTRIM(RTRIM(n.value('.', 'nvarchar(400)')))) AS nvarchar(12)) + N','
FROM @tx.nodes('t') x(n)
WHERE OBJECT_ID(LTRIM(RTRIM(n.value('.', 'nvarchar(400)')))) IS NOT NULL;

SELECT @ids = @ids + CAST(p.object_id AS nvarchar(12)) + N','
FROM sys.partitions p
WHERE p.hobt_id IN (SELECT TRY_CONVERT(bigint, LTRIM(RTRIM(n.value('.', 'nvarchar(40)')))) FROM @hx.nodes('t') x(n))
  AND CHARINDEX(N',' + CAST(p.object_id AS nvarchar(12)) + N',', @ids) = 0;

-- 1. hobt ids from wait resources, named
SELECT p.hobt_id, OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id) AS table_name,
       ISNULL(i.name, N'(heap)') AS index_name, p.partition_number, p.rows
FROM sys.partitions p
JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE p.hobt_id IN (SELECT TRY_CONVERT(bigint, LTRIM(RTRIM(n.value('.', 'nvarchar(40)')))) FROM @hx.nodes('t') x(n));

-- 2. Indexes of the tables
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name, i.index_id,
       ISNULL(i.name, N'(heap)') AS index_name, i.type_desc, i.is_primary_key AS pk, i.is_unique AS uq,
       STUFF((SELECT N', ' + c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
              ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, N'') AS keys,
       STUFF((SELECT N', ' + c.name
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
              FOR XML PATH('')), 1, 2, N'') AS includes,
       i.filter_definition, i.allow_row_locks AS row_locks, i.allow_page_locks AS page_locks,
       t.lock_escalation_desc AS escalation,
       (SELECT SUM(ps.row_count) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id) AS rows_,
       (SELECT SUM(ps.used_page_count) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id) AS used_pages
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
WHERE CHARINDEX(N',' + CAST(i.object_id AS nvarchar(12)) + N',', @ids) > 0
ORDER BY table_name, i.index_id;

-- 3. Usage since restart
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name, ISNULL(i.name, N'(heap)') AS index_name,
       us.user_seeks, us.user_scans, us.user_lookups, us.user_updates AS user_writes,
       CONVERT(varchar(16), us.last_user_scan, 120) AS last_scan_local,
       CONVERT(varchar(16), us.last_user_seek, 120) AS last_seek_local
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
WHERE CHARINDEX(N',' + CAST(i.object_id AS nvarchar(12)) + N',', @ids) > 0
ORDER BY table_name, i.index_id;

-- 4. Lock contention and escalation per index
SELECT OBJECT_SCHEMA_NAME(o.object_id) + N'.' + o.name AS table_name, ISNULL(i.name, N'(heap)') AS index_name,
       SUM(os.row_lock_count) AS row_locks_taken, SUM(os.row_lock_wait_count) AS row_lock_waits, SUM(os.row_lock_wait_in_ms) / 1000 AS row_lock_wait_s,
       SUM(os.page_lock_count) AS page_locks_taken, SUM(os.page_lock_wait_count) AS page_lock_waits, SUM(os.page_lock_wait_in_ms) / 1000 AS page_lock_wait_s,
       SUM(os.index_lock_promotion_attempt_count) AS escalation_attempts, SUM(os.index_lock_promotion_count) AS escalations,
       SUM(os.range_scan_count) AS range_scans, SUM(os.singleton_lookup_count) AS singleton_lookups
FROM sys.objects o
CROSS APPLY sys.dm_db_index_operational_stats(DB_ID(), o.object_id, NULL, NULL) os
JOIN sys.indexes i ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE CHARINDEX(N',' + CAST(o.object_id AS nvarchar(12)) + N',', @ids) > 0
GROUP BY o.object_id, o.name, i.index_id, i.name
ORDER BY table_name, i.index_id;

-- 5. Foreign keys to and from the tables
SELECT fk.name AS foreign_key,
       OBJECT_SCHEMA_NAME(fk.parent_object_id) + N'.' + OBJECT_NAME(fk.parent_object_id) AS child_table,
       OBJECT_SCHEMA_NAME(fk.referenced_object_id) + N'.' + OBJECT_NAME(fk.referenced_object_id) AS parent_table,
       STUFF((SELECT N', ' + c.name
              FROM sys.foreign_key_columns fkc JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
              WHERE fkc.constraint_object_id = fk.object_id ORDER BY fkc.constraint_column_id FOR XML PATH('')), 1, 2, N'') AS child_columns,
       fk.delete_referential_action_desc AS on_parent_row_removed, fk.update_referential_action_desc AS on_parent_key_changed,
       fk.is_disabled, fk.is_not_trusted,
       CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_key_columns fkc
                         JOIN sys.index_columns ic ON ic.object_id = fkc.parent_object_id AND ic.column_id = fkc.parent_column_id
                                                  AND ic.key_ordinal = 1 AND ic.is_included_column = 0
                         WHERE fkc.constraint_object_id = fk.object_id AND fkc.constraint_column_id = 1)
            THEN 'yes' ELSE 'NO: parent key changes scan the child' END AS child_column_leads_an_index
FROM sys.foreign_keys fk
WHERE CHARINDEX(N',' + CAST(fk.parent_object_id AS nvarchar(12)) + N',', @ids) > 0
   OR CHARINDEX(N',' + CAST(fk.referenced_object_id AS nvarchar(12)) + N',', @ids) > 0
ORDER BY parent_table, child_table;

-- 6. Triggers on the tables
SELECT OBJECT_SCHEMA_NAME(tr.parent_id) + N'.' + OBJECT_NAME(tr.parent_id) AS table_name, tr.name AS trigger_name,
       tr.is_disabled, tr.is_instead_of_trigger,
       STUFF((SELECT N', ' + te.type_desc FROM sys.trigger_events te WHERE te.object_id = tr.object_id FOR XML PATH('')), 1, 2, N'') AS fires_on,
       CONVERT(varchar(16), o.modify_date, 120) AS modified
FROM sys.triggers tr
JOIN sys.objects o ON o.object_id = tr.object_id
WHERE tr.parent_class = 1 AND CHARINDEX(N',' + CAST(tr.parent_id AS nvarchar(12)) + N',', @ids) > 0
ORDER BY table_name, trigger_name;

-- 7. Other code that references the tables
SELECT TOP (200) OBJECT_SCHEMA_NAME(d.referenced_id) + N'.' + OBJECT_NAME(d.referenced_id) AS table_name,
       OBJECT_SCHEMA_NAME(d.referencing_id) + N'.' + OBJECT_NAME(d.referencing_id) AS referencing_code,
       o.type_desc, CONVERT(varchar(16), o.modify_date, 120) AS modified
FROM sys.sql_expression_dependencies d
JOIN sys.objects o ON o.object_id = d.referencing_id
WHERE d.referenced_id IS NOT NULL AND d.referencing_id <> d.referenced_id AND CHARINDEX(N',' + CAST(d.referenced_id AS nvarchar(12)) + N',', @ids) > 0
GROUP BY d.referenced_id, d.referencing_id, o.type_desc, o.modify_date
ORDER BY table_name, o.type_desc, referencing_code;

-- 8. Isolation settings of this database
SELECT d.name AS database_name, d.is_read_committed_snapshot_on AS rcsi, d.snapshot_isolation_state_desc AS snapshot_isolation
FROM sys.databases d
WHERE d.database_id = DB_ID();
