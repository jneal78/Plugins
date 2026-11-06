/*=====================================================================================================================
  PARITY + COST CHECK for the <MARKER> patch of <schema>.<object>     ** DBA-run: writes only to this session's #temp **
  Runs the object's own statement (Query Store query <id>) exactly as written, original and patched, three times:
  patched, original, patched. Compares the rows and reports CPU, elapsed time and logical reads per run.
  Nothing else in the object runs: no real table changes, nothing is sent.

  When : <a quiet moment / between scheduled runs>. The original costs about <n> s CPU (one extra run of the slow version).
  Pass : same row_count, and rows_only_original = 0 and rows_only_patched = 0, against at least one of the two patched
         runs. Rows are compared as multisets (grouped with their count), so a patch that returns a row twice fails;
         a plain EXCEPT would pass it.
         Rows that become "due" between runs are timing, not a difference: re-run if in doubt.
  Measured by Claude as read-only SELECTs on <date>: patched <n> ms CPU / original <n> ms / patched <n> ms; <n> rows, identical.
=====================================================================================================================*/
USE <Database>
GO
SET NOCOUNT ON
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED    -- only if the object itself does this
SET STATISTICS TIME ON                              -- exact CPU per statement (incl. parallel workers) in the Messages tab
GO
SELECT CASE CONVERT(varchar(66), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(N'<schema>.<object>'))), 1)
            WHEN '<original hash>' THEN 'original (live, unpatched)'
            WHEN '<patched hash>'  THEN 'patched'
            ELSE 'CHANGED - the statements below may no longer match the live object' END AS live_version
GO
IF OBJECT_ID('tempdb..#target') IS NOT NULL DROP TABLE #target
IF OBJECT_ID('tempdb..#runs') IS NOT NULL DROP TABLE #runs
IF OBJECT_ID('tempdb..#res') IS NOT NULL DROP TABLE #res
CREATE TABLE #target (/* same columns as the statement's target (#temp in the procedure, or the real table's columns) */ k int, v varchar(20))
CREATE TABLE #runs (run_no int, version varchar(10), started datetime2, cpu_ms int, elapsed_ms int, logical_reads bigint, row_count int)
CREATE TABLE #res  (run_no int, /* same columns as #target */ k int, v varchar(20))
GO

/*--- run 1: patched ---------------------------------------------------------------------------------------*/
TRUNCATE TABLE #target
DECLARE @t0 datetime2 = SYSDATETIME(),
        @c0 int    = (SELECT cpu_time      FROM sys.dm_exec_requests WHERE session_id = @@SPID),
        @r0 bigint = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID)
INSERT INTO #target (k, v)
SELECT /* PATCHED statement body, byte for byte from the patched object, target renamed to #target */ 1, 'x'
INSERT INTO #runs SELECT 1, 'patched', @t0,
       (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @c0,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()),
       (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0,
       (SELECT COUNT(*) FROM #target)
INSERT INTO #res SELECT 1, * FROM #target
GO

/*--- run 2: original --------------------------------------------------------------------------------------*/
TRUNCATE TABLE #target
DECLARE @t0 datetime2 = SYSDATETIME(),
        @c0 int    = (SELECT cpu_time      FROM sys.dm_exec_requests WHERE session_id = @@SPID),
        @r0 bigint = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID)
INSERT INTO #target (k, v)
SELECT /* ORIGINAL statement body, byte for byte from the live object */ 1, 'x'
INSERT INTO #runs SELECT 2, 'original', @t0,
       (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @c0,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()),
       (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0,
       (SELECT COUNT(*) FROM #target)
INSERT INTO #res SELECT 2, * FROM #target
GO

/*--- run 3: patched again (copy of run 1 with run_no 3) ---------------------------------------------------*/
-- ...

/*--- results ----------------------------------------------------------------------------------------------*/
SELECT * FROM #runs ORDER BY run_no
-- Multiset comparison: each side grouped by all its columns with the number of copies, then EXCEPT both ways.
-- A row present twice on one side and once on the other differs in its count, so it is reported.
SELECT p.run_no AS patched_run,
       (SELECT COUNT(*) FROM #res WHERE run_no = 2) AS original_row_count,
       (SELECT COUNT(*) FROM #res WHERE run_no = p.run_no) AS patched_row_count,
       (SELECT COUNT(*) FROM (SELECT k, v, COUNT(*) AS copies FROM #res WHERE run_no = 2 GROUP BY k, v
                              EXCEPT
                              SELECT k, v, COUNT(*) FROM #res WHERE run_no = p.run_no GROUP BY k, v) x) AS rows_only_original,
       (SELECT COUNT(*) FROM (SELECT k, v, COUNT(*) AS copies FROM #res WHERE run_no = p.run_no GROUP BY k, v
                              EXCEPT
                              SELECT k, v, COUNT(*) FROM #res WHERE run_no = 2 GROUP BY k, v) x) AS rows_only_patched
FROM (SELECT DISTINCT run_no FROM #runs WHERE version = 'patched') p
GO
