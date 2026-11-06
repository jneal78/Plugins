/*  23_equivalence_TEMPLATE.sql  (read-only once filled; a template: copy it, fill the two queries, run the copy)
    Purpose : prove that a changed piece of vendor logic returns the same rows as before, on today's production
              data, without running the procedure. The old code is gone from the database, so the "old" side is the
              changed expression copied from the BEFORE definition (21 snapshot, source copy, or the old statement
              text in Query Store); the "new" side is the same expression from the live definition, or a call to
              the live function. Both run as plain SELECTs over the same keys.
    When    : a release changes a function, a filter, a join or a window that decides WHAT the application sees
              (not only how fast). If the change is meant to change the output, use this to measure exactly which
              rows differ and confirm that is the intended difference.
    Rules   : core/safety.md "Running a SELECT version of an application statement": no locking hints, no
              side effects, keep the plan hints, estimate before executing. The header below caps the impact.
              Test a bounded key set first (@KeysFrom / @KeysTo, or TOP); widen it only if the cost is small.
    Reading : rows_old and rows_new are the multiset sizes. 'only in old' / 'only in new' rows compare each side
              grouped by every column with COUNT(*), so a row that appears twice on one side and once on the
              other shows up too (a plain set comparison would hide it). Pass = equal row counts and no rows
              in either direction. If a difference is intended (a new filter), every differing row must be
              explained by it: show a sample per reason.
    Run     : sqlcmd -S <server> -d <db> -E -I -W -s"|" -t 120 -i <filled copy> -o equivalence.txt
*/
SET NOCOUNT ON;
SET LOCK_TIMEOUT 5000;          -- give up after 5 s of waiting for a lock
SET DEADLOCK_PRIORITY LOW;      -- always the victim, never the application

-- EDIT ME ---------------------------------------------------------------------------------------------------------
DECLARE @KeysFrom int = 0,      -- the key range to test, e.g. open orders, today's stops
        @KeysTo   int = 1000;
---------------------------------------------------------------------------------------------------------------------

;WITH keys AS (
    -- EDIT ME: the business keys both sides are evaluated for (bounded)
    SELECT k.KeyColumn FROM dbo.SomeTable k WITH (NOLOCK) WHERE k.KeyColumn BETWEEN @KeysFrom AND @KeysTo
),
old_side AS (
    -- EDIT ME: the OLD expression, copied from the before definition, as a SELECT over keys
    SELECT k.KeyColumn, CAST(NULL AS varchar(50)) AS Result1, CAST(NULL AS int) AS Result2 FROM keys k
),
new_side AS (
    -- EDIT ME: the NEW expression from the live definition, or the live function: CROSS APPLY dbo.SomeFunction(k.KeyColumn)
    SELECT k.KeyColumn, CAST(NULL AS varchar(50)) AS Result1, CAST(NULL AS int) AS Result2 FROM keys k
),
o AS (SELECT KeyColumn, Result1, Result2, COUNT(*) AS n FROM old_side GROUP BY KeyColumn, Result1, Result2),
n AS (SELECT KeyColumn, Result1, Result2, COUNT(*) AS n FROM new_side GROUP BY KeyColumn, Result1, Result2),
diff AS (
    SELECT 'only in old' AS side, KeyColumn, Result1, Result2, n FROM (SELECT * FROM o EXCEPT SELECT * FROM n) x
    UNION ALL
    SELECT 'only in new', KeyColumn, Result1, Result2, n FROM (SELECT * FROM n EXCEPT SELECT * FROM o) y
)
SELECT (SELECT ISNULL(SUM(n), 0) FROM o) AS rows_old, (SELECT ISNULL(SUM(n), 0) FROM n) AS rows_new,
       (SELECT COUNT(*) FROM diff WHERE side = 'only in old') AS groups_only_in_old,
       (SELECT COUNT(*) FROM diff WHERE side = 'only in new') AS groups_only_in_new;

-- A sample of the differences (rerun with the same EDIT ME values; the CTEs are repeated so each statement stands alone)
;WITH keys AS (
    SELECT k.KeyColumn FROM dbo.SomeTable k WITH (NOLOCK) WHERE k.KeyColumn BETWEEN @KeysFrom AND @KeysTo
),
old_side AS (
    SELECT k.KeyColumn, CAST(NULL AS varchar(50)) AS Result1, CAST(NULL AS int) AS Result2 FROM keys k
),
new_side AS (
    SELECT k.KeyColumn, CAST(NULL AS varchar(50)) AS Result1, CAST(NULL AS int) AS Result2 FROM keys k
),
o AS (SELECT KeyColumn, Result1, Result2, COUNT(*) AS n FROM old_side GROUP BY KeyColumn, Result1, Result2),
n AS (SELECT KeyColumn, Result1, Result2, COUNT(*) AS n FROM new_side GROUP BY KeyColumn, Result1, Result2)
SELECT TOP (50) side, KeyColumn, Result1, Result2, n
FROM (SELECT 'only in old' AS side, * FROM (SELECT * FROM o EXCEPT SELECT * FROM n) x
      UNION ALL
      SELECT 'only in new', * FROM (SELECT * FROM n EXCEPT SELECT * FROM o) y) d
ORDER BY KeyColumn, side;
