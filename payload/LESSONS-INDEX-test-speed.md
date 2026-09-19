# Lessons index: Test speed (generated, do not edit)

One SHORTENED line per lesson: the condition and the instruction, routinely dropping the
clause saying what the failure looks like. Read the whole entry before a rule decides
anything: `~/claude-config-sync/claude-sync lesson L174`, or the entry in ~/.claude/LESSONS.md,
which is NOT loaded into the session.

- L290. A test that waits a FIXED time for something is asserting about the machine's load, so wait on the condition itself, or SET the clock.
- L291. A test that can only pass by REACHING a real service is either an integration test or one with a missing seam, and pays a timeout to prove nothing.
- L292. Run a subsumption sweep even when it finds nothing, and when it does find a deletion, name which surviving test covers each deleted assertion.
- L293. A flake is a speed cost priced at a full re-run, and a retry hides the price, so count flakes and rank a recurring one with the speed findings.
- L294. On a starved runner per-test durations measure the runner, so read the format and core count first, and keep only what is slow in several runs.
- L295. When the tests are the time, read the suite's own concurrency setting: sum the per-test durations against the wall clock, because equal means one core.
- L296. Anything dividing work between workers divides by a MEASURED cost, never a count of items, and the guard measures in the same unit.
- L297. A scanner guarding a class of fault across the whole tree pays per line, so write it as one pass per file, and keep a failing guard's full output.
- L298. A harness that reruns the suite once per case pays the boot each time, so the lever is the boot, then the cadence, and never the tests.
- L433. Work a runner SPLITS across parallel workers must be self contained per unit, because the split moves between runs and neighbours land elsewhere.
- L672. A probe in a DIFFERENT JS realm cannot see the page's globals or a framework's element properties, so an ABSENCE read through one is never evidence.
- L438. A measurement sampled from inside the same context as the thing measured can itself be the load, so judge by the events the platform emits.
