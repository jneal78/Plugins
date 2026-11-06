# Site profile (copy to `site-profile.md` in your site folder and fill in)

Every sqlserver-dba skill reads this before its first server query (see `core/site.md` for where the site folder lives). Keep it current: it is what makes the second run faster than the first. Leave `<…>` where you don't know yet.

## Servers

| Server / listener | Role | Databases | Notes |
|---|---|---|---|
| `<prod-listener>` | **PRODUCTION**, read-only for Claude | `<AppDb>` (main), `<OtherDb>` | SQL Server 20xx, n cores, n GB, AG with n replicas |
| `<dev-server>` | Dev / test | | Claude may run read-only scripts; writes only if the user says so |

- Time zone for reports, as a Windows name from `sys.time_zone_info`: `<Central Standard Time>`. The scripts pass it to `AT TIME ZONE`, which does not accept IANA names such as `America/Chicago`, so each date gets its own daylight-saving offset
- Query Store: interval `<60>` min, max size `<n>` MB, `max_plans_per_query` `<n>`, capture mode `<AUTO>`
- Reading login lacks: `<VIEW ANY DATABASE / msdb / VIEW SERVER STATE>` (expect NULL names)
- `system_health` event files: `<full path, e.g. D:\MSSQL\Log\system_health*.xel>` (they reach back about `<n>` hours)
- Dedicated deadlock session: `<none | name, created on every replica>`; a monitoring product that keeps deadlock graphs: `<none | product, how to export .xdl>`
- Application tables that log deadlock victims (error 1205): `<none | schema.table, columns for error number, procedure and date>`

## Policy

- [ ] Claude is read-only on production (SELECT, DMVs, Query Store views)
- [ ] Guardrail hook in place: `<name>` — blocks `<what>`; on a block, stop and hand over
- [ ] Query Store plan forcing / hints: `<code-first (default): fix in code, forcing only with approval | never | allowed with approval>`
- [ ] Fixes to vendor code: `<in-procedure hints and small rewrites with rollback + vendor note>`
- [ ] Local index prefix: `<MyCo_>`; local change marker in code: `<-- MyCo yyyy-mm-dd>`
- [ ] Who deploys: `<DBA name/team>`; change process: `<ticket / CAB / none>`
- [ ] Where work is saved: analyses `<repo>\docs\`, scripts `<repo>\sql\<topic>\`, patches `<repo>\sql\vendor_patches\<object>\`

## Ledger

Ledger: `findings-ledger.md` (in this folder) `<or another path>`

## Baselines

| Day | Why it's the reference | Business-hours CPU-min/hr |
|---|---|---|
| `<yyyy-mm-dd>` | `<first steady day after ...>` | `<n–n>` |

## Normal on this server

Overrides and additions to `core/interpretation.md`. Say where each figure came from and when.

| Measure | Normal here | Measured |
|---|---|---|
| Business-hours CPU (Query Store, main DB) | `<n–n CPU-min/hr>` | `<yyyy-mm-dd>` |
| Application errors (Query Store execution type 4) | `<≈ n/day>` | |
| Timeouts (execution type 3) | `<≈ n/day>` | |
| Deadlocks | `<≈ n/day, and which are monitoring tools>` | |
| Worker threads | `<max n; peaks of n are idle workers>` | |
| Benign quirks | `<e.g. a monitoring tool's tempdb query is a frequent deadlock victim>` | |

## Workload groups (used by `03_qs_hourly.sql` and the dashboard)

| Group | How to recognize it (schema / name pattern / login / query_hash) | Owner | Normal CPU-min/day |
|---|---|---|---|
| `<Mobile app>` | schema `<APP>` | `<vendor>` | |
| `<EDI>` | names `edi%`, `dx[_]%` | | |
| `<Billing>` | names `d[_]invoice%` | | |
| `<Reports>` | `Proc[_]Report[_]%` | | |
| Ad hoc | `object_id = 0` | | |

Group SQL for the dashboard: `<path to groups SQL>`. Dashboard config: `<path to *.config.json>`.

## Business processes

Processes whose throughput is measured from a business table, not from calls (used by the client-path profiler and the dashboard).

| Process | Business table and the column that marks completion | Who runs it, from where | Normal pace |
|---|---|---|---|
| `<Invoice printing>` | `<invoice table: printed_date set>` | `<billing users, from a session host>` | `<≈ n per minute>` |

## Vendors and contacts

| Product | Objects / schema | Support route | Notes (version header format, upgrade cadence) |
|---|---|---|---|
| `<Vendor product>` | `<schema or name pattern>` | `<portal / email>` | `<upgrades overwrite local patches: re-run each Verify script after an upgrade>` |
