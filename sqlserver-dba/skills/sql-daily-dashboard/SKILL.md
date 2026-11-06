---
name: sql-daily-dashboard
description: Builds and explains a self-contained daily SQL Server workload dashboard from read-only collectors – a verdict on server health, today vs the same hours a week ago vs a baseline day per hour, per integration and per object, business throughput beside its CPU, a work board (bubbling up → open → ready → done-watch) read from the site's findings ledger, and a drill-down per object that hands a ready-made request to the tuning skills. Also sets the dashboard up for a new site (config, workload group rules, business metrics). Use this whenever someone asks to run, refresh, open, set up or change "the dashboard", wants a daily or recurring view of the server, asks what's bubbling up, or wants to look into something they saw on the dashboard.
---

# Daily dashboard

One page a DBA or manager reads every day: is the server healthy, how does today compare with a week ago and the baseline, and what should we work on next. The page has no server connection; it's a snapshot you can open, mail or archive.

## Before you start

The shared core is at `../../core/` from this skill's folder.
1. **Site folder** (`core/site.md`): the profile names the dashboard config (`Dashboard config:`), the group SQL and the ledger. If there's no config yet, see *Setting up* below.
2. **Read `core/safety.md`** the first time in a session. The collectors are SELECT-only and contain no write keywords; keep it that way in any site SQL you add.

## Run it

```powershell
pwsh -NoProfile -File <this skill>\assets\dashboard\Build-Dashboard.ps1 -Config <site>\<name>.config.json -Open
```

About one to three minutes on a busy server, read-only. It writes, in the config's `outDir`:
- `Dashboard_<yyyy-MM-dd>_<HHmm>.html` – this run's page (each run keeps its own);
- `Dashboard_latest.html` – the newest run, for a bookmark;
- `data\dashboard_<yyyy-MM-dd>_<HHmm>.json` – the data, so the page can be re-rendered later with `-FromJson <file>` without touching the server.

When it's done, summarize the verdict and the top of "Look first at" in a few lines rather than describing the whole page.

## Looking into something on the page

Every object has a drill-down (`#drill=<db>|<object>`) with a **request to paste to Claude**: object, windows, numbers, signals and top query_ids. Start from that request:
- a costly or worsening object → **sql-query-tuning** (or **sql-workload-hotspots** to see what else changed around it);
- timeouts or errors → **sql-workload-hotspots** steps 5–6;
- a business metric falling while its CPU is normal → **sql-client-path-profiler**.

## The work board and the ledger

The board reads the site's findings ledger (`core/templates/findings-ledger.template.md` format). Object names in backticks and `0x…` query hashes on a row link it to what the page sees. When an item moves (fixed, deployed, verified), update the ledger, not the page; the next run follows.

## Setting up for a new site

Read `assets/dashboard/README.md`. In short:
1. Copy `dashboard.config.example.json` into the site folder; fill in server, databases (mark the main one), baseline day, output folder and the ledger path (`"candidates"`).
2. Copy `groups_default.sql` beside it and add one rule per integration or product (`prio, group, schema LIKE, name LIKE, query_hash`).
3. Optional: a business-throughput query (`"extra"`), SELECT-only, so business volume sits beside its CPU.
4. Add the config and group paths to the site profile, run it once, and check the page with the user.

## Changing the page

The template is `assets/dashboard/dashboard.html`; the view model is `model.js`. Re-render from saved data with `-FromJson` while working on it, and look at the result in a browser. Keep the page self-contained (no external scripts or fonts), and keep every file free of SQL write keywords, including JavaScript, so production guardrails that scan scripts don't block the build.
