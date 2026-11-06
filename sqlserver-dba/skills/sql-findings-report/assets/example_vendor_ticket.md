# Example DMS `dbo.udf_LookupTractor`: scans `dbo.Legs` for every document it indexes

**For:** Example Software support (Document Indexing module) \
**From:** MyCo DBA team (2026-11-06) \
**Severity requested:** P3 – performance; ≈ 96 CPU-minutes a day and deadlocks with dispatch updates \
**Environment:** Example DMS 7.4.2; SQL Server 2022 (16.0, CU14), compatibility level 150, default CE; database `AppDb`

## 1. Summary

The nightly indexing job calls `dbo.udf_LookupTractor` once per document. The function compares a converted column with a string (`CONVERT(varchar(20), L.OrderNumber) = @OrderRef`), so it cannot seek the order-number index and reads the whole `dbo.Legs` table (7,375 pages) on every call: about 430 ms CPU per call, ≈ 96 CPU-minutes a day, under shared page locks that deadlock with the dispatch application's status updates. Adding a seekable test next to the original one returns the same row in 7 reads and 1 ms. We ask for that change (or an equivalent) in a release.

## 2. Which component this is, and how we know

| Evidence | Value |
|---|---|
| Caller | SQL Agent job "DMS – index documents", step 2 (program `SQLAgent - TSQL JobStep`) |
| Object | `dbo.udf_LookupTractor`, SHA-256 `0x7D21…9C04`, header "v7.4.2 2025-03-11" |
| Statement | the function's only query, Query Store query 812345 |

## 3. The defect

```sql
-- as shipped (inside dbo.udf_LookupTractor)
SELECT TOP (1) @Tractor = L.Tractor
FROM dbo.Legs L
WHERE CONVERT(varchar(20), L.OrderNumber) = @OrderRef;
```

`OrderNumber` is `int` and indexed (`IX_Legs_OrderNumber`). Converting the column to `varchar` makes the predicate non-sargable, so the plan is a Clustered Index Scan of all 1.9M rows to return one.

## 4. Evidence

| Day | Calls | CPU ms per call | Reads per call | CPU-min |
|---|---:|---:|---:|---:|
| 2026-11-04 | 13,210 | 431 | 7,375 | 94.9 |
| 2026-11-05 | 13,480 | 428 | 7,375 | 96.2 |

## 5. How to reproduce and verify (for your support engineer)

Everything below runs read-only: no procedure is called, no data or table changes, so it is safe on your test system and on a customer's production server. Expect about 15 minutes. Full script: `repro_udf_LookupTractor.sql` (attached, and in Appendix A).

**Environment that reproduces it** (section 0 of the script prints yours; the settings in bold decide the plan):

| Setting | Ours |
|---|---|
| SQL Server | 16.0, CU14, Enterprise |
| **Compatibility level / cardinality estimator** | 150 / default |
| **MAXDOP / cost threshold** | 8 / 50 |
| RCSI / Query Store | off / READ_WRITE |
| `dbo.udf_LookupTractor` | SHA-256 `0x7D21…9C04`, modified 2025-03-11 (header "v7.4.2") |
| **Data shape** | `dbo.Legs`: 1.9M rows, 58 MB; any existing order number reproduces it |

**Steps**

1. Run sections 0–2 and compare with the table above. Any database with more than about 100,000 rows in `dbo.Legs` shows the scan; a small demo database does not.
2. Leave `@p2` as it is (the script picks the newest existing order number). Turn on "Discard results after execution" in SSMS, or run with sqlcmd.
3. Run the script. Section 4 prints one row per run. **As shipped you should see** a Clustered Index Scan on `dbo.Legs` (NodeId 1), about 7,375 logical reads and 400–450 ms CPU per run.
4. Open the actual plan of an "as shipped" run: the scan at NodeId 1 reads 1.9M rows to return 1; its predicate is `CONVERT(varchar(20),[L].[OrderNumber],0)=[@p2]`, which can't seek `IX_Legs_OrderNumber`.
5. Compare with the "with change" runs: an Index Seek on `IX_Legs_OrderNumber`, 7 logical reads, about 1 ms CPU. Section 5 shows the same row count and checksum for both.
6. Optional, to size it across customers: section 7 lists this statement's plans and cost from Query Store in any database.

**Expected results** (ours, from the same script on 2026-11-06):

| Run | CPU ms | Elapsed ms | Logical reads | Physical reads | Main waits |
|---|---:|---:|---:|---:|---|
| As shipped, run 1 | 414 | 582 | 7,375 | 0 | SOS_SCHEDULER_YIELD 216 ms |
| As shipped, run 2 | 458 | 877 | 7,375 | 0 | SOS_SCHEDULER_YIELD 448 ms |
| With the change | 1 | 0 | 7 | 0 | – |

**Pass:** as shipped ≥ 7,000 logical reads (reproduced) and with the change ≤ 10, same rows (count 1, checksum identical). Attached: `udf_LookupTractor_as_shipped.sqlplan`, `udf_LookupTractor_with_change.sqlplan`, `repro_output_MyCo.txt`.

## 6. Impact assessment

| Area | Impact |
|---|---|
| Data | none: the result is correct, only slow |
| Business | dispatch status updates wait on the job's page locks; 2–3 deadlocks a night, the dispatch update is retried |
| Exposure | every customer whose `dbo.Legs` has grown past ~100,000 rows |
| Performance | ≈ 96 CPU-minutes a day; the job runs 95 minutes instead of under 1 |

## 7. What we have done locally

Nothing yet: we will apply the change in section 8 locally (marked `-- MyCo 2026-11-06`) if a release can't take it soon, and send you the deploy script.

## 8. Suggested fix

```sql
WHERE L.OrderNumber = TRY_CONVERT(int, @OrderRef)            -- seekable; NULL for a non-numeric reference
  AND CONVERT(varchar(20), L.OrderNumber) = @OrderRef;       -- the original test, kept: the result can't change
```

## 9. Questions for the vendor

1. Is this a known issue, and which release could include the change?
2. Did the reproduction in section 5 match on your system? If not, which of sections 0–2 differed?

## Appendix A: reproduction script (excerpt; the full file is attached)

```sql
DECLARE @Object  nvarchar(300) = N'dbo.udf_LookupTractor',
        @Tables  nvarchar(max) = N'dbo.Legs',
        @QueryHash binary(8)   = 0x1A2B3C4D5E6F7081,
        @Runs    int           = 2,
        @ShowPlans bit         = 1;
DECLARE @p2 varchar(20) = (SELECT CONVERT(varchar(20), MAX(OrderNumber)) FROM dbo.Legs WITH (INDEX(IX_Legs_OrderNumber)));

-- 4. Runs: as shipped, then with the change (each measured: CPU, elapsed, logical and physical reads, file I/O, waits)
IF @variant = 'as shipped'
    SELECT L.LegNumber, L.Tractor FROM dbo.Legs L WHERE CONVERT(varchar(20), L.OrderNumber) = @p2;
ELSE
    SELECT L.LegNumber, L.Tractor FROM dbo.Legs L
    WHERE L.OrderNumber = TRY_CONVERT(int, @p2) AND CONVERT(varchar(20), L.OrderNumber) = @p2;   -- MyCo 2026-11-06
```
