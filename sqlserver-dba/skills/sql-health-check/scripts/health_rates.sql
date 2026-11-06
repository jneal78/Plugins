/*
    health_rates.sql - READ-ONLY 60-second sample: two snapshots (T0, T1) of file I/O, waits and key counters.
    SELECT-only. Run with -h -1 so only data rows are printed, then compute rates locally with rates.awk:
        sqlcmd -S <server> -d <AppDb> -E -I -W -h -1 -s"|" -i health_rates.sql -o rates.txt
        tr -d '\r' < rates.txt | awk -f rates.awk
*/
SET NOCOUNT ON;
SELECT 'T0', CONVERT(varchar(23), SYSDATETIME(), 121);
SELECT 'IO', fs.database_id, fs.file_id, fs.num_of_reads, fs.num_of_writes, fs.io_stall_read_ms, fs.io_stall_write_ms, fs.num_of_bytes_read, fs.num_of_bytes_written FROM sys.dm_io_virtual_file_stats(NULL, NULL) fs;
SELECT 'WT', wait_type, wait_time_ms, waiting_tasks_count FROM sys.dm_os_wait_stats WHERE wait_time_ms > 0;
SELECT 'PC', REPLACE(RTRIM(counter_name), ' ', '_'), cntr_value FROM sys.dm_os_performance_counters
 WHERE (object_name LIKE '%SQL Statistics%' AND counter_name IN ('Batch Requests/sec', 'SQL Compilations/sec', 'SQL Re-Compilations/sec'))
    OR (object_name LIKE '%Buffer Manager%' AND counter_name IN ('Page reads/sec', 'Page writes/sec', 'Checkpoint pages/sec', 'Lazy writes/sec'))
    OR (object_name LIKE '%Access Methods%' AND counter_name IN ('Full Scans/sec', 'Index Searches/sec', 'Workfiles Created/sec', 'Worktables Created/sec', 'Page Splits/sec'))
    OR (object_name LIKE '%Locks%' AND instance_name = '_Total' AND counter_name IN ('Lock Waits/sec', 'Number of Deadlocks/sec', 'Lock Timeouts (timeout > 0)/sec'))
    OR (object_name LIKE '%Databases%' AND instance_name = DB_NAME() AND counter_name IN ('Transactions/sec', 'Log Flushes/sec', 'Log Bytes Flushed/sec'))
    OR (object_name LIKE '%General Statistics%' AND counter_name IN ('Logins/sec'));
WAITFOR DELAY '00:01:00';
SELECT 'T1', CONVERT(varchar(23), SYSDATETIME(), 121);
SELECT 'IO1', fs.database_id, fs.file_id, fs.num_of_reads, fs.num_of_writes, fs.io_stall_read_ms, fs.io_stall_write_ms, fs.num_of_bytes_read, fs.num_of_bytes_written FROM sys.dm_io_virtual_file_stats(NULL, NULL) fs;
SELECT 'WT1', wait_type, wait_time_ms, waiting_tasks_count FROM sys.dm_os_wait_stats WHERE wait_time_ms > 0;
SELECT 'PC1', REPLACE(RTRIM(counter_name), ' ', '_'), cntr_value FROM sys.dm_os_performance_counters
 WHERE (object_name LIKE '%SQL Statistics%' AND counter_name IN ('Batch Requests/sec', 'SQL Compilations/sec', 'SQL Re-Compilations/sec'))
    OR (object_name LIKE '%Buffer Manager%' AND counter_name IN ('Page reads/sec', 'Page writes/sec', 'Checkpoint pages/sec', 'Lazy writes/sec'))
    OR (object_name LIKE '%Access Methods%' AND counter_name IN ('Full Scans/sec', 'Index Searches/sec', 'Workfiles Created/sec', 'Worktables Created/sec', 'Page Splits/sec'))
    OR (object_name LIKE '%Locks%' AND instance_name = '_Total' AND counter_name IN ('Lock Waits/sec', 'Number of Deadlocks/sec', 'Lock Timeouts (timeout > 0)/sec'))
    OR (object_name LIKE '%Databases%' AND instance_name = DB_NAME() AND counter_name IN ('Transactions/sec', 'Log Flushes/sec', 'Log Bytes Flushed/sec'))
    OR (object_name LIKE '%General Statistics%' AND counter_name IN ('Logins/sec'));
