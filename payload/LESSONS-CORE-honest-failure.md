# Lessons core: Honest failure (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L710. A gap the NEXT occurrence repairs is invisible on every occurrence but the last and reads as working, so check the LAST occurrence directly.
- L583. A fallback relaxing only ONE dimension of a match does nothing where the shortage is in another, so name which dimension is actually thin first.
- L184. Judge a command by its EXIT CODE, never a line of its output: a tool's final line is often a different measurement, and the more reassuring one.
- L404. A tool put on the path IN PLACE of another must be proved to reproduce the original's EXIT CODE on a case that genuinely FAILS.
- L10. An error state and an empty state are different screens.
- L11. Distinct causes get distinct messages, and a message may claim only what its check actually measured.
- L13. Background jobs and webhooks alert on failure and on the absence of an expected run.
- L90. A counter or category whose only input is a value nothing in the system ever writes reports ZERO, and zero is indistinguishable from a true measurement.
- L229. Literal text handed to an interpolating evaluator can lose a sigil prefixed span silently, so the tool acts on text nobody wrote.
- L152. Surfaces report what is still OUTSTANDING, so an operation that RESOLVES everything silences them all and the most complete success says least.
- L50. A value parsed from storage or input must never feed a comparison directly.
- L71. A watchdog's own liveness must never depend on the health of what it watches
- L77. An error deliberately classified as EXPECTED (a lost race, a declined payment, a rejected duplicate, a taken slot) must still be counted against a RATE.
- L94. A payload assembled in two places has nowhere its completeness can be seen, so a field missing from both halves is invisible to a reader of either.
- L241. Work that BLOCKS must never run on a bounded shared worker pool: it does not grow, and a few blocked items starve every other concurrent task.
- L139. A minimum volume floor that stops a RATE being noisy also silences SATURATION: a proportion cannot tell one bad in two from twelve bad in twelve.
- L716. A rate RANKED against peers needs a minimum denominator, below which it is unmeasured, or the thinnest samples top and tail the board.
- L523. A suppression set by hand (a mute, a snooze, a maintenance window, a disabled check) must carry an EXPIRY and be listed somewhere visible.
- L264. A durable record that exists only because a CALLER redirects the tool's output belongs to that caller, not the tool
- L337. Making a reader that returned a benign default THROW re-audits every caller: the same refusal right behind an error screen strands a control mid-action.
- L357. A counter that renders its number on a screen is not a detector, because detection requires something that speaks on its own when the number is wrong.
- L536. A language or API that silently yields NOTHING for a construct it does not support makes the FIX indistinguishable from the BUG
- L550. A component omitting a state on an assumption about ALL its callers holds only while that assumption does, and nothing enforces it.
- L593. Write an audit record at the LOWEST layer every invocation path shares, usually the store itself, never in the API route or the UI handler.
- L431. A guard that skips expensive work when its inputs are unchanged saves nothing unless computing its KEY is cheaper than the work
- L445. A failing assertion renders its operands, so comparing against a LARGE value buries the message explaining what went wrong.
- L654. A monitor judging an outcome over ALL runs cannot see a fallback path: it is rare by construction, so its collapse to zero moves the rate by nothing.
- L664. When a submission is redirected onto an existing record, decide what happens to every field just entered, or a discarded correction reads as saved.
- L665. A refusal cleared only by re-running a process with a moving window becomes permanent once the refused item falls outside that window.
- L691. A tool printing a secret MASKS it by default, keeping its prefix and length, so it passes every completeness check and fails only at use.
- L695. An alert judged by one aggregate over a fixed trailing window cannot stand down until the window clears, so decide recovery on recent samples instead.
- L720. Copy explaining a derived number must name the field the code KEYS on, since a neighbouring date reads just as plausibly and passes every review.
- L723. A monitor baselined on a trailing window of its own series cannot see change slower than the window, so also compare against a fixed past reference.
