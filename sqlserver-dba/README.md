# sqlserver-dba

Claude skills that work the way a careful senior DBA does on a busy production SQL Server:
- measure first;
- find the few statements that matter, and say why their plans are expensive;
- change as little as possible, and prove the output is identical;
- leave a paper trail a colleague or a vendor can act on.

Everything Claude runs is **read-only**. A human DBA deploys every change, from scripts that stop themselves if anything is unexpected and come with an exact rollback.

## Skills

| Skill | Ask it… |
|---|---|
| `sql-health-check` | "How's the server doing?" – health now, live rates, today vs a week ago vs a baseline, ranked savings, optional PDF |
| `sql-workload-hotspots` | "Where is the CPU going? What changed? Who runs this?" – ranking by object, statement, hour and integration; regressions; attribution of failing or unknown statements |
| `sql-query-tuning` | "Why is this procedure slow?" – statement-level profile, the expensive operator, the smallest proven fix, packaged for the DBA |
| `sql-daily-dashboard` | "Run the dashboard" – one self-contained page a day, with a work board and a drill-down that starts the tuning work |
| `sql-deadlock-analysis` | "We keep getting deadlocks" – rate and lock-type mix, every graph the server still holds clustered into patterns with mechanism tags, weeks of history per pattern from Query Store, root cause per side (with the tuning skill) and the upstream driver (with the hotspots skill), a ranked fix per pattern and a verify step |
| `sql-release-verification` | "The vendor upgraded last night – check it", "Is the hot-fix working?" – the deploy window and what it touched, which objects really changed (snapshot diffs, or Query Store statement texts when there is no snapshot), whether local patches, indexes, permissions and forced plans survived, same-output checks, cost before vs after like for like, new errors and deadlocks, a verdict with re-check dates; also what to capture before an announced release |
| `sql-findings-report` | "Write this up / make a vendor ticket" – analysis docs, vendor tickets and notes with mermaid diagrams, rendered to HTML and PDF |

Coming next: `sql-client-path-profiler` ("is it the database or the app?").

All skills share `core/`: safety rules, the site-profile and findings-ledger templates, field guides, a catalog of proven fixes, patch packaging and report rendering.

## Install (Claude Code)

From a clone of this repository:

```
/plugin marketplace add <path-or-url-of-this-repo>
/plugin install sqlserver-dba@sqlserver-dba
```

Start a new session afterwards. If you previously installed standalone copies of similar skills, remove them so two skills don't answer the same request.

## Set up your site (10 minutes)

The plugin holds nothing about your organization. Your servers, policies, baselines and the list of fixes already done live in a **site folder** you own: `~/.sqlserver-dba/`, `.sqlserver-dba/` in a repo, or any folder named by `SQLSERVER_DBA_SITE`. See `core/site.md`. The quickest start is to ask Claude to "set up the sqlserver-dba site profile" and answer its questions.

Give Claude's login:
- `VIEW SERVER STATE` and `VIEW DATABASE STATE` (SQL Server 2022: `VIEW SERVER PERFORMANCE STATE`);
- `VIEW DEFINITION` where code fingerprints are wanted;
- `db_datareader` only where business-table metrics are needed.

**Strongly recommended:** a Claude Code hook that blocks write keywords in any command naming a production server. The bundled scripts are written to pass one. A portable hook ships here in a later release.

## Requirements

- SQL Server 2016 or later with Query Store on (2019/2022 give the best data). Azure SQL Managed Instance mostly works; Azure SQL Database is not supported yet.
- `sqlcmd` (or SSMS) on the machine running Claude, and PowerShell 7 for the dashboard and tools.
- For PDFs: Edge or Chrome, and internet access to jsDelivr for the markdown and mermaid scripts.

## Contributing

- Nothing organization-specific in this repository: no server, database, product, vendor or person names, and no thresholds measured on one server. Run `pwsh -File tools/Test-Scrub.ps1` (it reads your own deny-list from your site folder) before every commit.
- Every `.sql` and `.ps1` file under `skills/` must stay read-only, without write keywords even in comments (guardrails scan scripts run with `-File` too): `pwsh -File tools/Test-ReadOnlyScripts.ps1`.
- Keep each `SKILL.md` short and put detail in `references/` or `core/`. Explain why a rule exists, not just the rule.

## License

MIT (to be added with the first public release).
