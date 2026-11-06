# core – shared by every skill in sqlserver-dba

Each skill's `SKILL.md` names the core files it needs. From a skill's folder the core is at `../../core/` (the plugin root is two levels up from `skills/<name>/`).

| File | What it holds | Read it when |
|---|---|---|
| `site.md` | How to find the organization's site folder (profile, ledger, deny-list) and how to set one up | **Always first.** Every skill starts here |
| `safety.md` | What may and may not run on production, guardrail behavior, sqlcmd practicalities, the Query Store policy setting | First time in a session, before any server query |
| `number-hygiene.md` | Windows, time zones, sources, hedging, corrections | Before publishing any number |
| `interpretation.md` | Conversions and default thresholds | Judging whether a value is healthy |
| `query-store.md` | Query Store and plan-cache field guide, gotchas, matching across a change | Any Query Store query |
| `fix-catalog.md` | Symptom → evidence → minimal fix → proof, with measured results | Choosing a fix |
| `patch-package.md` | Guarded deploy, exact rollback, parity, verify, README, vendor note | Packaging any change for a DBA to run |
| `templates/` | Site profile, findings ledger, patch files, analysis / vendor ticket / vendor note, a DBA-run dedicated deadlock session | Creating any of those |
| `render/` | Markdown + mermaid → HTML shell, and a headless Edge/Chrome PDF script | Turning a write-up into HTML/PDF |

Rules for editing the core:
- It is shared, so change it only for something every skill should follow.
- Nothing organization-specific goes here: names, servers, thresholds measured on one server. Those belong in the site profile. Run `tools/Test-Scrub.ps1` before committing.
