-- Workload group rules for dash_workload.sql (included with :r inside a VALUES list).
-- One row per rule: (prio, group, schema LIKE, name LIKE, query_hash). NULL = any. The lowest prio that matches wins.
-- Ad hoc statements have schema and name '(adhoc)'; objects that no longer exist have '(old)'.
-- Copy this file, add a row per integration or product, and point the dashboard config at your copy.
-- No trailing comma after the last row, and no GO.
     (10, 'Ad hoc', '(adhoc)', NULL, NULL)
    ,(99, 'Other',  NULL,      NULL, NULL)
