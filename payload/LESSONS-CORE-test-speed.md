# Lessons core: Test speed (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L290. A test that waits a FIXED time for something is asserting about the machine's load, so wait on the condition itself, or SET the clock.
- L292. Run a subsumption sweep even when it finds nothing, and when it does find a deletion, name which surviving test covers each deleted assertion.
- L293. A flake is a speed cost priced at a full re-run, and a retry hides the price, so count flakes and rank a recurring one with the speed findings.
- L294. On a starved runner per-test durations measure the runner, so read the format and core count first, and keep only what is slow in several runs.
- L295. When the tests are the time, read the suite's own concurrency setting: sum the per-test durations against the wall clock, because equal means one core.
- L297. A scanner guarding a class of fault across the whole tree pays per line, so write it as one pass per file, and keep a failing guard's full output.
- L298. A harness that reruns the suite once per case pays the boot each time, so the lever is the boot, then the cadence, and never the tests.
- L672. A probe in a DIFFERENT JS realm cannot see the page's globals or a framework's element properties, so an ABSENCE read through one is never evidence.
- L438. A measurement sampled from inside the same context as the thing measured can itself be the load, so judge by the events the platform emits.
