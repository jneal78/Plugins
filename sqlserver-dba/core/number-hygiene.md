# Number hygiene

A wrong number published once costs more than a slow analysis: the retraction undoes trust in everything else in the report. Check these before anything leaves the session.

## Every number carries its window, time zone and source

- Say the window in local time and name the zone ("today 00:00–14:00 CST vs the same hours a week ago").
- Query Store intervals are stored in **UTC**. Convert before grouping by local hour or day; a "day" grouped in UTC splits the evening across two days.
- Machines disagree about time. Host counters, application logs and the database may be in different zones (a session host on UTC, the database server on local time). Normalize to one zone before lining sources up, and write UTC timestamps when you produce data that others will join.
- Name the source: Query Store, plan cache since compile, a timed DMV delta, the ring-buffer CPU meter, a business table, host counters. They measure different things and reset differently.

## Exclusions are stated, not silent

- The **mixed hour** (a deploy or upgrade happened inside it) belongs to neither before nor after. Drop it and say so.
- A **partial hour** or partial day is divided by the elapsed time, not by 1.
- Outliers you removed (a user away from the desk, a 30-minute stall) are listed with the reason.

## Per call, per hour, per business unit

- Per-execution and per-hour are different stories: a statement can get cheaper per call and costlier per hour because it is called more.
- **Calls are not business events.** One invoice, order or message may be several procedure calls, and one call may run a per-row function thousands of times. Measure throughput from the business table that records the outcome (rows that reached a status, with their timestamps), not from procedure call counts.
- An **average of averages** is wrong. Weight by executions (`SUM(avg × count) / SUM(count)`). A skewed average can be far from the typical value; give the median or distribution when it matters.

## Estimates are hedged and labeled

- Round, and use "≈" for anything projected ("≈ 90 CPU-min/day").
- Say which numbers you measured and which are someone else's claim (a vendor's release note, a user's recollection).
- Savings per day = cost in the window × (business hours ÷ window hours). State the business-hours assumption.

## Corrections are visible

When a later measurement changes an earlier claim, say so in the document ("**Correction:** the 324 ms figure was an unweighted average; the weighted figure is 41 ms") rather than silently changing the number. Readers who saw the first version need to know which number to trust.

## Before you publish

- [ ] Window, zone and source on every table.
- [ ] Mixed and partial hours handled and stated.
- [ ] Throughput from a business table, not call counts.
- [ ] Weighted averages; medians where the distribution is skewed.
- [ ] Estimates hedged; claims attributed.
- [ ] Corrections labeled.
