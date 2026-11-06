---
name: sql-findings-report
description: Writes up SQL Server performance and reliability findings for people who weren't in the analysis – a DBA team, an IT manager, or a software vendor – with mermaid diagrams that show the mechanism, rendered to HTML and PDF. Covers analysis documents (verdict, evidence, root cause, fix, saving), vendor bug tickets with an impact assessment, short vendor notes for a local patch, and health or hour-over-hour reports. Use this whenever someone asks to "write this up", "make a vendor ticket / bug report", "give me a PDF for my manager", "document the root cause", "send this to the vendor", or wants a diagram of a problem and its fix, even if they don't say "report".
---

# Findings report

The reader wasn't there. Give them the verdict first, then the numbers that prove it, then what to do – and one diagram that lets them point at the box that is the problem.

## Before you start

The shared core is at `../../core/` from this skill's folder.
1. **Site folder** (`core/site.md`): who the audience is (team, manager, vendor), naming rules for sharing outside the team, where reports are saved, and the ledger entry this report belongs to.
2. **Read `core/number-hygiene.md`** before putting any number in the document.
3. **Read `references/diagrams-and-reports.md`** for diagram choice, mermaid gotchas, report structures and the rendering steps.

## Pick the document

| Audience and purpose | Template | Structure |
|---|---|---|
| Team or manager: one problem, its cause and fix | `core/templates/docs/analysis_TEMPLATE.md` | Verdict → scope and method → findings (evidence table, root cause, diagram, fix, saving) → variants tried → ruled out → next steps |
| Vendor: a defect in their code | `core/templates/docs/vendor_ticket_TEMPLATE.md` | Summary → how we identified the component → the defect → sequence or hot-path diagram → evidence → **how to reproduce and verify** → impact (data, business, exposure, performance) → what we did locally → suggested fix → asks |
| Vendor: a local patch to their object | `core/templates/docs/vendor_note_TEMPLATE.md` | Product, object, version; statement; cause; evidence (as shipped vs patched); **reproduce and verify**; exact lines changed; permanent fix suggested; "will a release replace this object?" |
| Manager: health or week-over-week | (structure in `references/diagrams-and-reports.md`) | Verdict → key metrics (week ago / baseline / today) → resources → what was fixed → ranked candidates → bottom line |

## Every vendor document carries a reproduction kit

A vendor's level-2 support engineer has to reproduce a problem before anyone fixes it. Do that work for them, so the ticket can be verified in under an hour instead of waiting in a queue. Read `references/repro-kit.md`, then:
1. Fill `core/templates/docs/repro_kit_TEMPLATE.sql`:
   - the environment and data shape that make the plan go wrong;
   - the statement as shipped and with the change, in read-only SELECT form (`core/safety.md`, "Running a SELECT version");
   - parameter values that reproduce it;
   - our numbers as "what you should see".
   
   It is read-only, so their engineer can run it anywhere.
2. **Run it yourself** where you measured, at a quiet moment (`sqlcmd … -t <enough for the runs>`), and put that output's numbers in the ticket. The vendor's run is then comparable to ours, line for line.
3. Export the two actual plans as `.sqlplan`.
4. Fill the template's reproduction section:
   - the environment table;
   - numbered steps, each saying what they should see;
   - an expected-results table: CPU, elapsed, logical and physical reads, waits, per run;
   - pass criteria in numbers;
   - the attachments.
5. Put the kit's SQL in an appendix too: the PDF is for reading, the attached `.sql` and `.sqlplan` files are for running.

For an error rather than a slow plan, the kit is the failing statement with its parameter types, one row that fails and one that doesn't, a read-only SELECT that raises the same error without writing, and the count of rows exposed.

## Diagrams

A diagram earns its place when it shows a mechanism or a number:
- the **hot path** from caller to the expensive operator, with numbers on the nodes and the bad nodes red;
- **before vs after** plan shape side by side (red vs green);
- a **sequence** for an integration or a deadlock (who holds what, who waits for what);
- a **trend** (hourly CPU, today vs a week ago).

Keep each to about 12 nodes; prefer top-to-bottom for chains longer than five. If it shows neither a mechanism nor a number, use a table.

## Render and check

1. Copy `core/render/report_shell.html` next to the markdown (never edit the plugin's own copy: it is shared, and site data would end up in it), put the markdown between the `<script type="text/markdown" id="src">` tags and set the `<title>`.
2. Run `core/render/render_pdf.ps1 -Html <file.html> [-Screenshot]` – local only, it touches no database (it loads marked and mermaid from jsDelivr, so it needs internet).
3. **Look at the result** before sending: every diagram rendered (not raw text), text readable at page width, tables fit, and the reproduction steps and appendix SQL readable (code blocks wrap in print). If a diagram is cramped, change its direction or split it.
4. **Hand over the package**, not just the PDF: the PDF, `repro_<object>.sql`, the two `.sqlplan` files and our run's output, in one folder.

## Sharing outside the team

- Drop internal hostnames, IPs and people's names unless the recipient needs them (a vendor ticket usually needs the service host and login).
- Use the vendor's own names for their objects.
- Nothing is sent by you: give the user the file. Sending, posting or emailing is theirs.

## After writing

Add the document's path to the ledger row it belongs to, so the next person finds it.
