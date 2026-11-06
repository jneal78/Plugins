# Findings ledger

What has been found on this site's servers, what was done about it, and what is waiting. Every skill reads this before reporting and updates it afterwards, so the next run starts from current state instead of rediscovering it.

**Format rules** (the daily dashboard parses this file):
- Keep the four `##` headings below: Done, Ready, Open, Watch (Watch is optional).
- Each section holds one table whose first column is `Item`.
- Put object names in `backticks` and query hashes as `0x` + 16 hex digits in the Item cell or anywhere on the row: those become the keys the dashboard uses to match an item to what it sees on the server.
- Dates are `yyyy-mm-dd`. Numbers carry units and windows ("≈ 90 CPU-min/day", "245 → 5 ms per call").

## Done
| Item | Before → after | Deployed | Script | Notes |
|---|---|---|---|---|
| `<schema.object>` <one-line problem> | <before → after, with units> | <yyyy-mm-dd> | `<path to DEPLOY / ROLLBACK / Verify>` | <re-check after upgrades?> |

## Ready
| Item | Expected saving | Script | Waiting on |
|---|---|---|---|
| `<schema.object>` <one-line problem> | <≈ n CPU-min/day, or the user-facing effect> | `<path to DEPLOY>` | <deploy window / approval / vendor> |

## Open
| Item | Cost now | Fix idea | Owner |
|---|---|---|---|
| `<schema.object>` or `0x<query_hash>` <one-line problem> | <today's cost, with window> | <smallest fix that removes the operator> | <in-house / vendor / DBA> |

## Watch
| Item | Why watch | Until | Check with |
|---|---|---|---|
| `<schema.object>` <what was changed or is suspect> | <what would mean it regressed> | <yyyy-mm-dd> | `<path to Verify script>` |
