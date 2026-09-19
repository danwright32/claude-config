# Lessons index: Pipeline speed (generated, do not edit)

One SHORTENED line per lesson: the condition and the instruction, routinely dropping the
clause saying what the failure looks like. Read the whole entry before a rule decides
anything: `~/claude-config-sync/claude-sync lesson L174`, or the entry in ~/.claude/LESSONS.md,
which is NOT loaded into the session.

- L395. A speed improvement claimed from ONE reading per arm cannot be told from noise
- L299. The tests are innocent until measured guilty, so the first move in a speed pass is per-step timing of every stage a push waits on.
- L300. A gate's own guards are an untimed pipeline, so time every stage a push waits on and put the measurement where the claim about it lives.
- L301. Look for the same work done twice per event: a suite run by two jobs, an artifact built twice, a merge verified by two workflows.
- L302. Serial steps with no dependency are free wall clock, so split them, but only what is independent and only on the critical path.
- L303. Cache or kill the cold starts, keyed on what invalidates them, and prove a cache saves something by a measured difference in what gets rebuilt.
- L304. A report-only check still gates in practice if the merge flow waits for every check, so price an informational job as if it were a gate.
- L305. Job and check names are load-bearing and a branch ruleset cannot be found by searching the repo, so a rename ships a fan-in job holding the old name.
- L306. Wall-clock and billed minutes are different budgets, so price every pipeline change in both and read the multiplier off the runner label.
- L307. On a free public repository the runner concurrency limit is the budget, so a job is priced in the slots it holds times how long it holds them.
- L308. Name in writing the biggest speed lever you deliberately did not pull, so a future pass does not discover it.
- L309. A structural change to how a suite runs rides on an instrument that already reports what the change could break, and building one is the first issue.
- L310. Every job bills a minimum of one minute, so a tiny always-on job is expensive when its isolation is decorative and worth keeping when it does work.
- L311. An audit of PR testing stops at the PR unless it walks to production, so time merge to live as carefully as push to green.
- L312. Name the consumer of every run before ranking anything, and skip a provably redundant post-merge re-run on proof of an identical tree, never on a path.
- L313. Every CI job carries an explicit timeout, and the guard requiring it points at every repo the class can appear in, not the one file it was written for.
- L314. CI that has stopped is the slowest suite there is and it stops quietly, so a speed pass begins by confirming the tests are running at all.
- L315. Anything divided into fixed-size pieces under a fixed deadline needs the largest piece held to a fraction of it, and pieces dealt by measured cost.
- L316. A recorded decision carries a premise that can expire, so record the premise in a form that can be re-measured, not as a dated sentence.
- L538. A build left red for a known unrelated reason stops being a signal for everything else, so fix or quarantine it rather than working alongside it.
- L671. A concurrency rule cancelling a superseded run saves a read only job and crashes a writing one, so decide per workflow by what it WRITES.
- L380. Two build invocations sharing an output directory share no work unless every setting keying that output matches, so measure what actually recompiles.
- L571. A gate performing a network call BEFORE the check it is named for can fail without running that check, and merging then depends on a third party.
- L573. Before running a pure check once per item, count the DISTINCT inputs it will see, and cache on the WHOLE input, never a coarser key.
- L682. A live path is only as outage tolerant as its LEAST cached read, so inventory every read on it and give each one a served-stale fallback
