# Daily workload dashboard

One self-contained HTML page per day that answers, in order: is the server healthy right now, how does today compare with the same hours a week ago and with a baseline day (overall, per integration, per object), and what is bubbling up to optimize next. Every number comes from read-only queries against Query Store and DMVs; the page itself has no server connection, so it can be opened offline, mailed or printed.

## Files

| File | What it does |
|---|---|
| `Build-Dashboard.ps1` | Runs the collectors with `sqlcmd`, joins their JSON with the candidate list, renders the page |
| `dash_server.sql` | Server state: CPU meter, a 10-second rate sample, memory, workers, AG, disks, I/O, log, blocking, settings, Query Store |
| `dash_workload.sql` | One database: today vs a week ago vs baseline per hour, per group, per object (ad hoc by query_hash), statements, waits, 14 days. Objects recreated by an upgrade are matched to their new id by statement hash |
| `groups_default.sql` | Rules that put objects in workload groups (integrations). Copy it per site |
| `model.js` | Builds the view model from the JSON: deltas, flags (rising, slower, more calls, new entrant, untracked, timeouts, errors, many plans), candidate status, pipeline stage, score, the request to paste to Claude |
| `dashboard.html` | The page template (the winner of a judged design competition: CTO, senior DBA, IT Director, integration owner) |
| `dashboard.config.example.json` | Config to copy |

## Set up (15 minutes)

1. Copy `dashboard.config.example.json` to a folder of your own (not inside the skill) and fill in the server, databases, baseline day and output folder.
2. Copy `groups_default.sql` next to it and add one rule row per integration or product: `(prio, 'Group', schema LIKE, name LIKE, query_hash)`. The first match by `prio` wins; `'(adhoc)'` matches ad hoc SQL; a `query_hash` row names one ad hoc statement. No path with spaces.
3. Optional: a business-throughput query (`"extra"`), SELECT-only, returning `{"metrics":[{key,label,good,group}],"hourly":[{metric,h,c,a}]}`; `group` puts each metric beside its integration's CPU.
4. Optional but recommended: the site's findings ledger (`core/templates/findings-ledger.template.md`; set its path as `"candidates"` in the config), with `## Done`, `## Ready`, `## Open` sections whose tables start with an `Item` column. Object names in backticks and `0x…` query hashes in a row link it to the objects on the page; an `Owner` column shows on the cards.
5. Run it:
   ```powershell
   pwsh -NoProfile -File <skill>\assets\dashboard\Build-Dashboard.ps1 -Config <your>\dashboard.config.json -Open
   ```
   It takes one to three minutes on a busy server (each section reads Query Store once; no temp tables) and writes `Dashboard_<date>_<HHmm>.html`, `Dashboard_latest.html` (always the newest run) and `data\dashboard_<date>_<HHmm>.json`. Each run keeps its own page, so several runs a day, or one that crosses midnight, don't overwrite each other.

The login needs `VIEW SERVER STATE` and `VIEW DATABASE STATE` (2022: the `PERFORMANCE STATE` variants), plus `db_datareader` only for a business query.

## Reading it

- **CPU-min or % of server** (switch in the header, kept in the link as `unit=pct` and remembered per browser): % of server = CPU-min ÷ (logical CPUs × minutes in the span), so an hour divides by 60, a whole day by 1,440 and the window by its minutes. In % mode the hourly chart also marks the CPU meter (ring buffer, the last ~4 hours) for the whole SQL Server, and says how much of it this database's Query Store CPU accounts for; today's bar on the whole-days chart becomes its average so far, comparable to full days. Scores, copied requests, candidate rows and thresholds stay in CPU-min whichever unit is shown; Share columns are always the share of the database's CPU.
- **Header:** verdict naming the worst server check and any business alarm, then "Look first at" in the model's order, KPI strip (today, week ago, baseline, whole-day estimate).
- **Today:** hourly CPU (today bars; week ago and baseline as distinct lines), 15 days, integrations with CPU, timeouts, errors, business throughput and CPU per 1,000 units, and a group × hour heatmap.
- **Work board:** Bubbling up (worsening and not on the candidate list) → Open → Ready to deploy → Done – watch (done items showing a signal again), with counts, CPU and owners. "Large, untracked" is the quiet list of big items that aren't getting worse.
- **Objects:** the sortable, filterable top objects with flags; keyboard: ↑/↓, Enter, Esc, `/`.
- **Changes:** statement movers by object (vendor rewrites shown as one net change), waits and parallelism, the candidate list.
- **Drill-down** (`#drill=<db>|<object>`): today / week ago / baseline, signals and the score worked out, hourly shape, statements with plan counts and text, candidate fields, the request to paste to Claude, and the EDIT ME values for scripts 05 and 06 (sql-query-tuning) and 08 and 09 (sql-workload-hotspots).

## Rules the code keeps

- Read-only: every SQL file is SELECT-only; the builder writes only local files.
- A production guardrail may scan files for SQL write words. The dashboard files contain none (not even in comments or JavaScript keywords), and the page copies text with a hidden textarea rather than the Clipboard API, whose method name is one of those words. Keep it that way when you change them.
