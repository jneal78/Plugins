# The site folder

The skills are generic. Everything about one organization – its servers, which of them are production, its policies, workload groups, baseline day, normal noise levels and the list of fixes already done – lives in a **site folder** that the organization owns and the plugin never ships.

## Finding it (in this order)

1. The folder named by the environment variable `SQLSERVER_DBA_SITE`.
2. `.sqlserver-dba/` in the current repository or working folder.
3. `~/.sqlserver-dba/` (on Windows, `%USERPROFILE%\.sqlserver-dba\`; a junction to a folder in a shared repo works well).

Use the first one that exists. Say which one you used the first time in a session.

## What's in it

| File | Required | Purpose |
|---|---|---|
| `site-profile.md` | **Yes** | Servers and production flags, time zone, Query Store settings, permissions the reading login lacks, policies, baselines, workload groups, owners, vendors, where work is saved. From `templates/site-profile.template.md` |
| `findings-ledger.md` | Recommended | Done / ready / open / watch, with before → after numbers and script paths. From `templates/findings-ledger.template.md`. The profile may point to a ledger elsewhere instead (`Ledger:` line) |
| `scrub-denylist.txt` | For contributors | Terms that must never appear in the shared plugin; used by `tools/Test-Scrub.ps1` |
| anything else | Optional | Workload group SQL, dashboard config, business-metric SQL – the profile says where they are |

## Using it

- **Read the profile before the first server query.** It says which server names are production, which overrides the default thresholds, and which policy applies (for example whether Query Store plan forcing is ever allowed).
- **Read the ledger before reporting a finding.** If an item is already there, report its status and script instead of rediscovering it. A new finding is the most valuable part of a repeat run, so mark it **new**.
- **Update the ledger after the work.** Add or move the item, with the date, measured before → after, owner and script path. If the ledger file is outside your write scope or the user prefers to do it, give them the row to paste.
- **Profile values beat defaults.** Where the profile has its own threshold or normal level ("~4,000 application errors a day is normal here"), use it and say so.

## No site folder yet

Offer to create one; don't guess the answers. Ask for:
1. The production server or listener names, and any dev/test servers.
2. Which databases matter, and which is the main one.
3. The time zone for reports.
4. Policies: is Claude read-only on production (it should be), is there a guardrail hook, is Query Store plan forcing allowed, the local index prefix and change marker, who deploys.
5. A known-good baseline day, if they have one (otherwise pick one later from the data and confirm it).

Then copy the two templates to the chosen folder, fill in what they answered, and leave clearly marked `<…>` placeholders for the rest. A profile with just the server names and policies is enough to start; the rest fills in as work happens.
