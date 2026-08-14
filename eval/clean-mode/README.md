# Clean mode eval

`round1-baseline.json` is the user-run baseline round of 2026-08-14,
extracted verbatim from the checklist's saved browser state — scripts,
what landed, the user's expected outputs, verdicts, tags, and their
per-pattern grammar rulings.

**The `expected` fields are Clean mode's calibration set.** The rolling
protocol from `review/LEDGER.md` applies: they judge changes, they are
re-scored after any guard/prompt/model change (expect agreement), and
future rounds mint held-out sets before folding in.

The frozen C-group acceptance criteria, the grammar policy table, and
the reader-needs-it tripwire are recorded in the ledger entries
"CLEAN MODE · Baseline round 1 results" and "CLEAN · C-group intensity
resolved" — this file carries the data, the ledger carries the
decisions. If they ever disagree, the ledger wins and this file gets
regenerated, not hand-edited.

Score to beat: 4/17 at the fidelity-plus-polish bar.
