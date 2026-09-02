# Bidspoke test speed audit (2026-08-22)

## The headline

The tests themselves are healthy and fast. The whole worker suite (2,958 tests in 207 files) runs in 3.2 seconds on your machine, and the web suite (1,277 tests in 160 files) runs in 5.5 seconds. The time a PR spends "in testing" is almost entirely CI plumbing: serial steps that could run side by side, the same work done twice in two places, and a production build that gets rebuilt from scratch on every run.

That is good news, because it means we can cut the wait roughly in half without touching a single test. Nothing below weakens what is checked. Every recommendation runs the same commands on the same code, just fewer times or at the same time as each other.

**Today a typical PR waits about 3.2 minutes for CI.** With the changes below, a backend PR (the common case) drops to roughly 1.7 minutes, a web PR to roughly 2.5 minutes, and each merge to main stops paying for about 5 minutes of duplicated compute on a private repo where runner minutes are billed.

## Where the time actually goes (measured)

All numbers are from real runs in the last week (per-job timings pulled from the GitHub API across recent PR runs, local timings measured today on this machine).

### CI jobs on a pull request (all run in parallel, so the slowest one is the wait)

| Job | Typical | What is inside it |
|---|---|---|
| Test | 168 to 183s | setup 25s, worker tests 62s, web tests 77s, run one after another |
| Auth gate fails closed | 121 to 144s | setup 27s, next-on-pages build 84s, the actual probe 2s |
| Accessibility (axe) | 158 to 175s when web changed, ~9s when skipped | setup 29s, next-on-pages build 96s, specs 26s |
| Lint & Typecheck | 88 to 114s | setup 28s, typecheck 44s, lint 38s, run one after another |
| Security scans | 46 to 51s | fine as is |
| DB types freshness | 6 to 7s | fine as is |

The critical path is the Test job at about 3 minutes, even though the tests inside it take 9 seconds combined on a fast machine. The CI runner is slower, but the bigger issue is that worker and web run back to back in one job when they have no dependency on each other.

### The local gates (for comparison, these are not the problem)

| Gate | Measured |
|---|---|
| Pre-commit (tracked typecheck + full lint) | ~10s |
| Pre-push repo hook (tree check, typecheck, docs check, copy guards) | ~10s |
| Pre-push test gate model judge | up to 90s worst case (its own timeout), only when source changed |
| Worker suite, full | 3.2s |
| Web suite, full | 5.5s |

### After the merge

Every push to main runs two workflows at once: ci.yml again (about 3.2 minutes) and deploy.yml (5 to 7 minutes). Deploy's Verify job re-runs typecheck, lint, and every test suite that ci.yml is running at the same moment on the same commit. The deploy is gated on Verify, not on CI, so the ci.yml copies of Lint & Typecheck and Test on main-push events protect nothing that Verify does not already protect.

## Findings, ranked by payoff

### 1. Split the Test job into two parallel jobs (biggest wall-clock win)

Worker tests (62s) and web tests (77s) run serially inside one job. They share nothing: different packages, different configs. Two jobs (one for uuidv7 + worker, one for web) each pay their own ~25s setup but run at the same time, so the Test wall time drops from ~170s to roughly 95s.

Same commands, same tests, same failure behavior. The `ci-runs-every-package-suite` guard test needs updating to read both jobs, which is a feature: it will catch a package dropped from either.

Saves about 80 to 90 seconds on every PR and every push to main. Risk to coverage: none.

### 2. Stop running the worker guard suite twice in CI

The worker's `test` script is `vitest run && pnpm --filter=web exec vitest run src/lib/__guards__/worker`. That second half boots the web vitest project to run the 27 guard files (246 tests) that scan worker source. Locally that is the design working as intended: someone changing worker code gets guard feedback without knowing the guards live in apps/web.

In CI it is pure duplication. The "Test web" step runs the full web suite, guards included, minutes later in the same job. The guards execute twice on every CI run, and the second vitest boot is a meaningful slice of the 62s worker step (the guard run itself is under 1s; the boot and transform around it are not).

Fix: add a `test:unit` script to the worker (plain `vitest run`) and have the CI Test job call that, leaving `test` unchanged for local use and for deploy's `pnpm -r test`. The guard suite still runs on every PR, once, where it already runs today.

Saves an estimated 10 to 20 seconds of the worker step. Risk to coverage: none, the guards still gate every PR via the web step.

### 3. Scope the auth gate job by changed paths, the same fail-closed way the a11y job already does

The auth gate builds the full next-on-pages artifact (84s) on every PR, including pure backend PRs where apps/web is untouched, to run a 2 second probe. The a11y job already solved this exact problem with a fail-closed changed-files check: if the job cannot prove nothing relevant changed, it runs.

Apply the same pattern to the auth gate, with a wider trigger set than a11y uses: `apps/web/**`, `packages/**`, `pnpm-lock.yaml`, `package.json` (the same superset reasoning deploy.yml documents for its paths filter, because a dependency bump can move the middleware artifact). Dependabot PRs touch the lockfile, so they still run it, which preserves the job's deliberate property of running without secrets on fork and Dependabot PRs.

After finding 1, this job (121 to 144s) becomes the critical path on backend PRs, so this is what gets a backend PR to ~1.7 minutes. Risk to coverage: the gate still runs whenever anything that can change the artifact changes, and runs when in doubt.

### 4. Split Lint & Typecheck into two parallel jobs

Typecheck (44s) and lint (38s) run back to back. As separate jobs they finish in ~75s each instead of ~110s combined. After findings 1 and 3, this job is next in line to be the critical path, so the split is what holds the ~1.7 minute floor.

Same commands. Risk to coverage: none.

### 5. Cache the Next.js build cache in the two jobs that build the artifact

The next-on-pages build is 84 to 96 seconds in both the a11y job and the auth gate job, from cold, every time. Next.js is built to avoid exactly this: caching `apps/web/.next/cache` between runs (keyed on lockfile plus source hash, with a restore-keys fallback, the same shape as the existing Playwright browser cache) typically cuts a warm rebuild substantially.

This is the only lever on web-PR wall time once the jobs above are split, because the a11y job's 96s build dominates its 26s of actual specs. It also speeds the auth gate whenever it runs.

Estimated saving: 30 to 60 seconds per build, twice per web PR. Risk to coverage: none, the build output is identical or the build fails loudly. Worth confirming next-on-pages plays well with a restored cache; if a stale-cache oddity ever appears, the key includes the source hash precisely so a real change always rebuilds.

### 6. Web PRs build the same artifact twice (compute, not wall clock)

When apps/web changes, the a11y job and the auth gate job each build the identical next-on-pages artifact in parallel. That is about 3 minutes of paid runner time per web PR doing the same build twice. Options, in order of preference:

1. Live with it once finding 5 makes both builds cheap. Simplest, no coupling.
2. Build once in one job, share via an uploaded artifact. Saves the duplicate build but serializes the two jobs and adds upload/download time, so wall clock likely gets slightly worse. Only worth it if runner spend matters more than simplicity.

Merging the two jobs into one was considered and rejected: the auth gate deliberately runs without secrets on fork and Dependabot PRs while a11y skips there, and the a11y coverage guard deliberately assumes one playwright invocation per job. Folding them together trades two clean gates for one complicated one.

### 7. Each merge to main pays for the same verification twice (about 5 minutes of paid compute per merge)

On push to main, ci.yml runs Lint & Typecheck plus Test while deploy.yml's Verify job runs typecheck, lint, and `pnpm -r test` on the same commit at the same time. The deploy is gated on Verify. The ci.yml copies on the push event gate nothing.

Fix: add `if: github.event_name == 'pull_request'` to the lint-typecheck and test jobs in ci.yml (they keep running on every PR, which is where they gate the merge). Verify remains the blocking check on main before anything deploys, so main is still verified by the exact same commands; it is just verified once instead of twice. The push-event jobs that are unique to main (direct push guard, security, db types, a11y, auth gate) stay as they are.

Saves roughly 5 minutes of paid runner time per merge with zero wall-clock change and zero coverage change. The one thing to check in implementation: nothing else keys off those two check names on main-push events (branch protection cannot, since it is unavailable on this plan).

### 8. Optional experiment: vitest cold-start on the CI runner

The worker suite takes 3.2s locally and 62s on CI; web takes 5.5s locally and 77s on CI. Some of that is the runner having 4 cores against this machine's 10+, but most of it is cold vite transform and import of ~370 files. Two bounded experiments, measured before keeping:

1. Cache vitest's transform cache directory between runs (same pattern as the other caches).
2. Try `pool: 'threads'` for the node-environment projects, which often starts faster than the default forked processes on CI.

Explicitly not recommended: `isolate: false`. It is the biggest vitest speed lever and it is a weakening: tests that share module state can start passing or failing for reasons unrelated to the code under test, which is exactly the class of quiet corruption this repo's lessons file warns about. The suites are already fast enough locally that the isolation is worth keeping everywhere.

## Second pass (2026-08-29): what the combined lessons caught

The first pass was re-run against the twelve combined lessons below and against a week more of data. The PR numbers still hold (Test 170 to 191s, Auth gate 129 to 158s, Lint & Typecheck 84 to 127s across the twelve most recent PR runs). Five things were missed, and they cluster where the lessons predicted: the merge side of the pipeline (lessons 3, 5, 6), the sleeps nobody measured (lesson 11), the on-demand download (lesson 4), and the bill (lessons 7, 12).

### 9. Deploy's Verify job is the merge-to-live critical path, and it runs everything in a line

Measured on the four most recent deploys: Verify takes 216 to 249s, and inside it typecheck (41s), lint (38s), `pnpm -r test` (123s), the docs check and the Supabase migration check (14s) run one after another. Every deploy job `needs: [verify, ...]`, so Deploy Pages (140 to 153s) or Deploy Worker (about 85s including the artifact comparison) only starts when Verify is done. Merge-to-live is therefore about 6.5 minutes for a web change and 5.5 for a worker change, and finding 7 does not touch it: skipping the ci.yml copies saves money on the merge, not time.

Fix: the same move as finding 1, applied to deploy.yml. Split Verify into parallel jobs (typecheck plus lint, worker plus uuidv7 tests, web tests, docs plus migrations check) behind a fan-in job that keeps the job id `verify`. That id is load-bearing (lesson 6): `deploy-worker` re-asserts `needs.verify.result == 'success'` by hand inside an `always()` condition, and every other job names `verify` in its `needs`. The fan-in also needs its own pin (lesson 9), a test that its `needs` list contains every test-carrying job in the file, because a job missing from that list keeps running while gating nothing. Verify drops from about 250s to about 130s; merge-to-live for a web change from about 6.5 minutes to about 4.5. The worker leg should call the `test:unit` script finding 2 introduces, because today `pnpm -r test` runs the worker guard suite twice on the merge path too, and finding 2 as written leaves that alone. Risk to coverage: none, once the fan-in pin exists.

Pre-existing #520 (2026-07-02, "Deploy Verify re-runs the entire CI suite doubling every main push") is this same duplication seen from the other side; finding 7 is its concrete fix and #520 should close against it.

### 10. No job outside ci.yml has a timeout

`ci-job-timeouts.test.ts` requires `timeout-minutes` on every ci.yml job, for the reason its comment gives: without one a stalled step hangs for six hours and reads as slowness (L110). deploy.yml, deploy-drift.yml and db-types-drift.yml have no timeout on any job. A Verify that hangs holds the deploy for six hours; the same Chromium install that stalled the a11y job three times on 2026-08-19 could stall the Pages build. Extend the guard to every workflow file, with values taken from the measured durations plus headroom, exactly as ci.yml did. This is a hang finding rather than a speed finding, but a hang is the slowest outcome a pipeline has.

### 11. The worker suite waits on real backoff (about 7.5 seconds of tests doing nothing)

Per-test timing on the worker suite: the three slowest tests each take exactly 1.5 seconds (`retry.test.ts` "still retries a transient PartnerApiError", `tracing.test.ts` "failed step emits step_error", `integration-e2e.test.ts` "logs parallel_end with failed status"), which is the engine's default backoff (500ms then 1s) lived through for real. `engine/retry.ts` sleeps through a private `setTimeout` with no seam, so a test that drives the engine end to end through a retry cannot avoid it; the other retry tests in that file already use fake timers because they call `withRetry` directly. Seven route test files also show one test at about 380ms each, but that is a cold dynamic `import('../index')` in `beforeEach`, not a sleep, and is left alone.

Fix, the same as PET's finding 2: give `withRetry` an injectable sleep (defaulting to the real one) and have those three tests record the delays the code asked for rather than waiting through them, which also makes them stronger (they then assert 500 then 1000, not just survival). Saves about 4.5 seconds off the slowest worker file and about 7.5 seconds of idle across the suite. Small against the 62s CI step, but these are the suite's longest tests and they set the floor of the slowest vitest worker. Risk to coverage: none.

### 12. `pages:build` downloads an unpinned Vercel CLI on every build

`pages:build` is `npx @cloudflare/next-on-pages`, and next-on-pages runs `vercel build` underneath. `vercel` is a peer dependency it declares (`>=30.0.0 && <=47.0.4`) and nothing in the repo installs it, so npx fetches it on every build: the a11y job log shows about 9 seconds between next-on-pages starting and `Vercel CLI 59.10.0` announcing itself. That happens on both artifact-building PR jobs, on Deploy Pages, and on every local `pages:build`. Two problems in one: the download is uncached (lesson 4, PET's wrangler case exactly), and the version is whatever is latest that day, already outside the range next-on-pages says it supports (L25). Fix: add `vercel` to apps/web's devDependencies at a version inside the declared range, so `pnpm install` supplies it from the store. Of the 103 second build step, `next build` itself is 76s (what finding 5 caches), the Vercel download 9s, dependency detection 4s, the adapter 6s.

### 13. The bill, measured, and two jobs whose isolation is decorative

The first pass said "runner minutes are billed" and left it there. The org billing API (itemized, per repo, per day) says: Bidspoke used 3,246 Actions minutes in June ($13.39), 3,743 in July ($16.75) and 6,599 in August through the 29th ($37.87). The org's 2,000 free minutes are shared across every Try-Pennie repo (Slate 6,074 and PET 2,009 in August) and run out in the first week, so from then on every Bidspoke minute is paid at $0.006. The per-event model in the first pass reconciles with the bill (Aug 20: 41 CI runs, 14 deploys, 23 Deploy Drift runs modelled at about 750 minutes against 703 billed), and the money is small, but two shapes in it are lesson 12:

- **Deploy Drift** runs three jobs (worker, site, tail worker) that each take 8 to 11 seconds, hourly. Each bills a full minute, so the workflow bills up to 3 minutes for under 30 seconds of work. The full tally of every job in the last 30 days puts it at 954 billed minutes (about 15 percent of Bidspoke's bill) at the cron delivery rate actually seen, 502 runs rather than 720 (see #1058); at a true hourly rate it would be about 2,160, a third of the bill. The three targets are read-only comparisons that alert independently; as three steps of one job, each reporting and alerting on its own, they bill one minute and lose nothing. Slate's migration gate stays a separate job because it gates deploys; these gate nothing.
- **Dependabot Auto-merge** runs its job on every successful pull request CI completion (302 runs in 30 days) and checks out the repo before asking whether the PR is Dependabot's. Each run bills a minute to decide, in about ten seconds, that a human PR is not eligible. The `workflow_run` payload carries `head_branch`, so a job-level `if` on `startsWith(github.event.workflow_run.head_branch, 'dependabot/')` skips at zero cost and leaves the tested decision script exactly where it is for the runs that matter.

Together about 600 minutes a month at today's cron delivery (Deploy Drift 954 measured plus the auto-merge job's 136, less the one minute per drift run that remains), rising to about 1,600 if hourly delivery returns: roughly $4 to $10, for no lost signal. The full per-workflow tally for the last 30 days, each job rounded up to the minute the way GitHub bills it: CI 4,293, Deploy 1,034, Deploy Drift 954, Dependabot Auto-merge 136, DB Types Drift 32, total 6,449 against 6,599 billed.

### Also caught, no issue needed

- The redundancy sweep the combined lessons (lesson 10) credit Bidspoke with was never actually recorded here, so it was run: 400 test files, 7 titles that appear in three or more files, all of them per-route behaviour checks ("returns 500, not a false 404, when the update hits a real DB error" in seven route files) that assert their own route and are not mergeable without losing per-route coverage. Same clean result as Slate. Lesson 10 below is corrected accordingly.
- The a11y job still starts, detects "no web change", and bills a minute doing so on every backend PR; #894 already holds that decision, and finding 3 will give the auth gate the same shape, so #894 belongs in this milestone.
- Finding 7's open question is answered: nothing keys on the `Test` or `Lint & Typecheck` check names. Dependabot Auto-merge keys on the CI workflow's conclusion for pull_request events only, the direct-push guard reads no check names, and Deploy reads Verify.

### A correction to the PET section

The PET audit below says its plan "is capped at 2,000 minutes a month and already runs near the cap." The itemized bill says otherwise: the 2,000 minutes are the org's shared free allowance, PET alone used 2,009 in August, and the org as a whole used 16,341 and paid $82.53 for the overage. Nothing is capped; it is metered at $0.006 a minute. That does not change PET's findings, all of which save both currencies, but it changes the framing of its structure options: the parallel-jobs option costs about 70 minutes a month, which is 42 cents, not a budget line.

## What the WWT article's practices say about this suite

The article's practices are mostly about test quality rather than speed: descriptive names, arrange-act-assert structure, isolated setup per test, no logic inside tests, one behavior per test, parameterized cases, and eliminating redundancy. Spot-checking the suites, they already follow these well: names are behavioral sentences, fixtures are per-test, and the guard suites assert specific failure signatures rather than generic throws.

The one practice with a direct speed consequence here is "eliminate test redundancy," and that is findings 2, 6, and 7: the redundancy in this pipeline is not duplicated test cases, it is the same suites and the same build executed more than once per event. The article's advice lands at the pipeline level rather than the test level.

## What was deliberately not proposed

These came up and were rejected for exactly the reason you gave, they trade signal for speed:

- Skipping the Test job by changed paths. Worker and web tests guard each other's source (the web guard suite scans worker code by design), so a path filter would eventually skip a test that should have run.
- Removing the a11y or auth gate fail-closed behavior. Seven wasted minutes remains cheaper than a gate that quietly turns itself off.
- Trimming or sampling the suites. At 3 and 5 seconds locally there is nothing to trim.
- Making deploy wait on CI instead of running Verify. It would save the duplication of finding 7 but serialize the two workflows and make every deploy slower, which is backwards.
- `isolate: false` in vitest, per finding 8.

## The picture after all of it

| Scenario | Today | After |
|---|---|---|
| Backend PR, CI wall time | ~3.2 min | ~1.7 min |
| Web PR, CI wall time | ~3.2 min | ~2.5 min |
| Paid compute per web PR | ~13 job-minutes | ~9 job-minutes |
| Paid compute per merge to main | ~11 job-minutes across two workflows | ~6 job-minutes |
| Merge-to-live, web change (finding 9) | ~6.5 min | ~4.5 min |
| Merge-to-live, worker change (finding 9) | ~5.5 min | ~3.5 min |
| Bidspoke Actions minutes per month (finding 13, August measured) | 6,599 min, $37.87 | roughly 3,500 to 4,000 min at the same activity |

## Proposed milestone

One milestone, `Faster PR testing`, with one issue per finding:

1. Split the CI Test job into parallel worker and web jobs (priority p2, labels ci, developer-experience)
2. CI runs the worker guard suite twice, run it once (p2, ci, tech-debt)
3. Scope the auth gate job by changed paths, fail closed (p2, ci)
4. Split Lint & Typecheck into parallel jobs (p3, ci)
5. Cache the Next.js build cache in artifact-building jobs (p2, ci)
6. Decide whether web PRs should share one artifact build (p4, ci) (may close as wontfix once 5 lands)
7. Skip ci.yml's lint and test jobs on push to main, Deploy Verify already gates (p3, ci, cost)
8. Experiment: vitest transform cache and thread pool on CI (p4, ci, experiment)

Filed 2026-08-22 as #966 to #973, plus #974 (cache builds in the deploy pipeline), which was added to the milestone afterwards and is the deploy-side half of finding 5.

Added by the second pass (2026-08-29):

9. Split Deploy Verify into parallel jobs behind a fan-in job named verify (p2, ci, deployment, developer-experience): the `needs.verify` couplings and the fan-in completeness pin are the checklist
10. Give every job in every workflow a timeout, and widen the guard past ci.yml (p2, ci, reliability, deployment)
11. Give the engine retry an injectable sleep so worker tests stop waiting on real backoff (p3, testing, developer-experience)
12. Pin vercel as a devDependency so pages:build stops downloading an unpinned CLI on every build (p3, ci, dependencies, performance)
13. Bill one minute for Deploy Drift and none for the auto-merge check on human PRs (p3, ci, cost)

Also moved into the milestone: #894 (whether the accessibility job should skip outright rather than skip its steps; finding 3 gives the auth gate the same shape). Closed against #972: #520, the earlier report of the Verify duplication.

Findings 1 through 4 are each small, independent workflow edits and could land the same day. Finding 5 needs one verification pass. Findings 7, 8 and 13 are cleanups that save money rather than wait time. Finding 9 is the one second-pass item that needs care, for the same reason Slate's split does: a job id that automation reads.

---

# PET test speed audit (2026-08-29)

## The headline

Same shape as Bidspoke, with one difference: PET's tests carry some real waste of their own, not just CI plumbing. The Node suite (3,907 tests in 359 files) runs in 26 seconds on your machine and the browser suite (486 tests in 96 files) in 45 seconds, so the local gates are already fine. But a typical PR waits 7 to 9.5 minutes for CI, and inside both suites there are measured, fixable costs: one library function that burns about 15 seconds per run, about 39 seconds of tests literally sleeping on a timer, and roughly a hundred repeated loads of the same page.

The second difference is the budget. PET's GitHub Actions plan is capped at 2,000 minutes a month and already runs near the cap, and CI alone used about 770 of those minutes last month (67 PR runs plus 33 merge runs). So the findings are split into two groups: things that cut both waiting time and billed minutes (do these first, they are free wins), and structure changes that buy waiting time by spending billed minutes (your call, with both numbers shown).

Nothing below weakens what is checked. One finding makes coverage strictly stronger.

## Where the time actually goes (measured)

CI numbers are per-step timings from the GitHub API across recent PR runs; local numbers were measured today on this machine with per-test timing reports.

### One CI run on a pull request (a single Test job, steps run one after another)

| Step | Typical | Notes |
|---|---|---|
| Checkout, Node setup, npm install | ~30s | npm cache already on |
| Node suite (no dev server, 2 workers) | 133s | the same tests take 26s locally at 4 workers |
| Deploy gate on a fixture build | 1s | fine as is |
| Install the Playwright browser | 26s | downloaded from scratch every run, no cache |
| Start the wrangler dev server | ~17s | PR runs only (the browser suite is skipped on push to main); wrangler is not in package.json, so npx downloads it every run; the same download races the 30s webServer timeout (#931) |
| Browser suite (one shared wrangler server, 2 workers) | 326s | the same tests take 45s locally; this is the critical path |
| Workflow lint (separate parallel job) | 5s | but billed as a full minute, every run |

### The local gates (already healthy)

| Gate | Measured |
|---|---|
| Node suite, full | 26.2s |
| Browser suite, full | 44.6s |
| Pre-push hook (Node suite + 11 browser smoke tests) | ~32s |
| Pre-push test gate model judge (global, all repos) | up to 90s worst case, only when source changed |

The CI browser suite runs 7.3 times slower than local. Half the worker count explains part of it; the rest is a 2-core runner hosting the dev server, the browser, and two test workers at once, all competing for the same two cores.

## Findings, ranked by payoff per unit of risk

### 1. One CSS-scanning function costs about 15 seconds every suite run (pure speed fix)

The palette guard (the test that makes sure every colour in the shipped stylesheet goes through a design token) is the slowest thing in the Node suite: 18.7 of the suite's 26 seconds sit in that one file, and profiling shows where: `findRawColors` in `lib/css-scan.js` takes 6.7 seconds on the real stylesheet and `findDimmedRules` another 1.1 seconds. For every colour it finds, the code re-scans everything before that point in the file to work out the line number and nearest rule name. With 223 colours in a 99KB stylesheet that re-scanning multiplies out badly.

Fix: compute the line positions once up front and look them up, and bound the rule-name search to the text since the last closing brace. Same inputs, same outputs, provably: run old and new on the real stylesheet and assert the results are identical before swapping.

Saves roughly 15 seconds locally and more on CI (where those seconds run on slower cores), on every Node suite run: every pre-push, every PR, every merge. It also removes a latent hazard: the slowest single test (8.5s) is already over halfway to the suite's 15-second per-test timeout, so on a loaded machine this test is the first candidate to flake for reasons unrelated to what it checks. Risk to coverage: none.

### 2. Tests pay real one-second sleeps to prove retry behavior (about 11 seconds of pure waiting)

The retry helper (`lib/with-retry.js`) was built with an injectable sleep precisely so tests can run instantly. But the production fetchers hard-code their retry settings and give tests no way to reach that seam, so every test that drives a fetcher end-to-end through a retry pays the real backoff: five wiring tests at exactly 1 second each, one Supabase test at 3 seconds, one alert-pipeline test at 3.1 seconds.

Fix: thread the seam through (the fetchers accept an optional retry-options override that defaults to today's exact behavior), and have the tests record the delays the code asked for instead of living through them. That is slightly stronger than today: the tests then assert the actual backoff values (1000ms, then 2000ms) rather than just surviving them.

Saves about 11 seconds of Node suite time everywhere it runs. Risk to coverage: none; the wiring is still proven end to end.

### 3. About 28 seconds of the browser suite is fixed timer sleeps, and roughly 4 seconds of it is safely removable now

A sweep of all 96 browser specs found every place a test waits a fixed time instead of waiting for a condition. They fall into two very different buckets:

- **The safe bucket (about 4 seconds):** fourteen specs sleep 100 to 600ms after a click before asserting, plus two waits with nothing conditional after them at all (a 1,200ms sleep in the keyboard-scrolling spec and a 600ms one in the nav spec). Replace each with a wait on the thing itself (the row appearing, the request firing). That is faster on the happy path and less flaky under CI load, where a fixed 300ms is exactly the kind of budget that stops being enough (this is lesson L522's territory).
- **The do-not-touch bucket (about 21 seconds):** the accessibility scans deliberately wait 1.5 seconds per page state so entry animations finish before contrast is measured. There is no cheap "all animations done" condition, and the obvious shortcut (killing transitions before scanning) changes what the scan measures, which makes it a coverage decision, not a speed fix. Left alone on purpose.

### 4. Cache the Playwright browser download in CI, and stop downloading wrangler on demand

Every PR run downloads the browser from scratch (26 seconds). Caching it keyed on the Playwright version is the standard pattern and saves both wall time and billed minutes, roughly 30 billed minutes a month at current PR volume. Risk to coverage: none; a version bump changes the key and re-downloads.

The same run pays a second uncached download that the first pass of this audit missed and the combined lessons caught (lesson 4). `wrangler` is not in `package.json`, so `playwright.config.js` starts the dev server with `npx wrangler pages dev`, and npx fetches the package every run. Measured on the last green PR run: about 17 seconds between the `will be installed: wrangler@4.86.0` warning and the first test starting. That download is also what races the config's 30 second server timeout, and when it loses, the whole browser suite errors out before a test runs and the PR pays a full 7 to 9 minute re-run in both currencies. This was already open as #931 (filed 2026-07-31 as a flake) but never priced as a speed cost; it now sits in the milestone at p2. Fix as #931 describes: pin wrangler as a devDependency at the version CI already resolves, so `npm ci` installs it from the npm cache. Saves ~17 seconds per PR and roughly 19 billed minutes a month (67 PR runs; the browser suite does not run on push to main). Confirmed on a second run at the same ~17 seconds. Risk to coverage: none.

### 5. The workflow lint job bills a full minute to do 5 seconds of work

GitHub bills each job's time rounded up to the minute. The actionlint check runs as its own parallel job, finishes in 5 seconds, and bills 1 minute, on every PR and every merge: roughly 100 billed minutes a month for nothing. Folding it into the Test job as a step adds about 5 seconds of wall time and gets those minutes back. Against a maxed 2,000-minute cap, this is the cheapest 5% of the budget you will ever recover.

### 6. Redundant tests found by a full sweep of all 478 spec files (deletions and merges that keep or strengthen coverage)

A dedicated sweep classified every spec, cross-checked duplicate test titles, and traced the shared helpers. The deliberate layering in this suite (unit test plus wiring test, axe scan plus contrast arithmetic) was excluded on purpose; what follows is genuine redundancy.

1. **Three tests are strictly subsumed by a stronger neighbour.** The Achieve banner schedule spec string-matches the alert step's trigger condition; the alert gating spec extracts the same condition and actually evaluates it against fabricated scenarios, which catches everything the string match catches plus reorderings and negation flips. Delete the three string-match tests. claude-config, the sixth, is the counterexample that fixes the wording: its plumbing is 5 to 8 seconds and the whole 3.5 minute wait is one 1,148 check suite that takes 473 seconds serially on a 14 core Mac. The tests are innocent until measured, and the measurement is what says so either way; there the first move that paid was per-section timing inside the suite rather than per-step timing outside it. Overture is the first repo where the rule runs the other way, and it took the same instrument to know: CI is 13 to 20 seconds on a public repository, the pull request waits 13.6 minutes, and 9.8 of those minutes are the test bodies of a Swift suite running one test at a time. Per-step timing from the API cleared the pipeline in one query; a per-test cost table from the run's own log did the rest.
2. **Six API endpoint spec files hand-copy the same auth-gate tests.** "GET is 401 without a session" appears six times, the PATCH validation set two to three times each, all as copies of the same three lines. The repo already maintains a machine-readable list of session-gated endpoints, and a test already proves that list is complete. Table-drive the gate tests off that list. This is the finding that makes coverage stronger: a future endpoint added to the list gets the gate tests automatically instead of only when someone remembers to copy them. claude-config: no duplicate job, but seventeen sections that relaunch the whole suite 39 times to ask it a question, at 1.4 seconds of startup each. Overture found the shape one level down, inside a single test process: the same copy inventory built twelve times by twelve tests that each needed it, the same source walk four times, the same surfaces report four times, 71 percent of a 507 second suite in twelve suites. The duplicate-title sweep was clean there too, the ninth in a row, and the redundancy was in what the tests computed rather than in what they asserted.
3. **Three workflow-linting specs each re-list and re-read every workflow file.** Merge into one spec with one read per file, keeping one test per file per rule so failures still name the exact file. Two fewer worker spin-ups, no behavior change. claude-config had exactly one serial step worth moving (a changed-section audit that runs after the 200 second suite and could run beside it), and its biggest win was inside the suite instead. Overture is the case where the serial steps are the tests themselves: 8,595 of them behind `parallelizable = "NO"`, which is the project generator's default and was never chosen, on a 12 core machine, with a per-test sum of 507 seconds against a 502 second wall clock. A default is a decision nobody made, and the way to see it is to sum what the runner reports and compare with the clock.
4. **Small merges:** two auth-fetch specs test the same function through two hand-rolled copies of the same stub; two sweep-coverage specs are the same pattern parameterized by page; two Slack-copy assertions are word-for-word duplicates across two files (delete the copies).

### 7. Read-only browser specs reload the same page about 106 times where about 7 loads would do

Seven board specs (daily grid, rep table, projections, rankings, header, KPI rail, nav) open every single test with a fresh load of the identical default dashboard, then read what is on screen without changing anything. That is roughly 106 navigations of the same URL. The aliases family repeats the pattern with hand-rolled per-file setup helpers even though a shared fixture already stubs the same routes.

Fix: group the read-only assertions in each file behind one shared page load, and give the handful of tests that click, sort, or edit their own private loads. The assertions themselves do not change.

This is a medium-risk change and the risk is exactly lesson L205: a test that only passes because its neighbour reset something is exposed the moment you share state. The mitigation is structural (mutating tests keep private pages, enforced by ordering, not hope), and the change should land family by family with the suite run in between, not as one big sweep.

Explicitly checked and rejected along the way: rewriting these as pure text checks against the built HTML and CSS. They read computed styles from a rendered page, which is what catches a style rule that exists but never wins or never matches. Text greps would keep passing while that breaks.

### 8. The four accessibility and contrast sweeps each re-walk the same five pages

The axe scan, resting contrast, hover/focus contrast, and focus-visibility specs each independently load and settle the same five URLs: about 22 loads plus those deliberate 1.5-second settles, where 5 loads could serve all four if they shared the visit. The catch is ordering: two of the four mutate the page (opening pickers, forcing hover), so the resting measurement must run first on a pristine load or it quietly stops being a resting measurement. The axe spec's own comments show this file has been carefully hand-optimized before. Worth doing, last, deliberately, with the order pinned in the test structure rather than in a comment.

### 9. CI structure options, each priced in both currencies

With the maxed cap, every parallelization idea gets two numbers: minutes you stop waiting, and minutes you start paying.

| Option | PR wait | Billed minutes | Verdict |
|---|---|---|---|
| Raise browser suite workers from 2 to 3 | maybe minus 1 to 1.5 min | free | Try first, as an experiment |
| Run Node and browser suites as parallel jobs | minus ~1.5 to 2 min | plus ~1 min per PR (~70/mo) | Reasonable second step |
| Also split the browser suite across 2 parallel jobs | PR wait lands near 4 min | plus ~2 min per PR (~130/mo) | Only if the wait still hurts |
| Bigger runners | more cores | not available on the free plan | ruled out |

The workers experiment exists because the instrument for it now exists: the suite already publishes a retry report on every CI run (built for the old shared-server flakiness), and recent runs show zero retries. Raise workers to 3, watch that report for a week of PRs, keep it if the report stays clean, revert if not. That is the free version of what sharding buys. The history here matters: 2 workers was chosen when the shared dev server flaked under load, so this must be measured, not assumed.

If the parallel-jobs option is taken, one coupling has to move in the same change (lessons 6 and 9): `tests/workflow-ci.spec.js` pins ci.yml as a single job, asserting that the Node suite appears before the browser suite in the file and that the browser install and run steps carry a step-level push gate. A job split moves that gate to job level, so the spec must be rewritten to pin the new shape (both jobs present, the browser job gated off push, the Node job not). The Dependabot auto-merge keys on the CI workflow's conclusion, not a job name, and is unaffected.

### 10. Two 500-line test files are parallel copies (maintenance, not speed)

The two refresh-script test files share word-for-word fixtures, helpers, and six identical test scenarios that differ only in which script they drive. They cover two real, different production scripts, so nothing should be deleted, but the scaffolding belongs in one shared harness. The one care point: the two scripts write different columns, so the column-specific assertions must stay per-file or the shared version quietly stops checking one script's columns.

## What the WWT article's practices say about this suite

Fetched and read in full (via the Internet Archive; the live page sits behind a bot check). Its practices: agree on conventions as a team, name tests for the behavior, structure as arrange-act-assert, isolate setup per test, hide irrelevant details, one behavior per test, no logic inside tests, assertions whose failure messages explain themselves, and eliminate redundancy.

PET already follows the quality practices well: test names are behavioral sentences, fixtures are per-test, and the guard specs assert specific failure signatures. As with Bidspoke, the one practice with a speed consequence is "eliminate test redundancy," and in PET it shows up at two levels: duplicated test code (the six copies of the auth-gate tests, the three workflow linters) and duplicated work (a hundred loads of one page, four walks of the same five URLs). Findings 6, 7, and 8 are that practice applied.

## What was deliberately not proposed

- Trimming the accessibility and contrast coverage. It is 40% of the browser suite's test time and it is the crown jewels: the axe scan alone is known to miss contrast issues (435 filtered incompletes), which is why the arithmetic checks exist beside it. Both stay.
- Killing animations before the axe scans to skip the settle waits. Changes what the scan measures; a coverage decision that would need its own review, not a speed fix.
- Rewriting rendered-page style checks as text checks. Faster and blinder.
- Skipping suites by changed paths. The suites are already auto-partitioned by content; path filters are how a test that should have run gets skipped.
- Cutting CI retries or the smoke set. The retry report is the instrument that makes the workers experiment safe; the smoke set exists because a browser-only regression once reddened every PR for a day.

## The picture after all of it

| Scenario | Today | After the free wins (1 to 6) | Plus the structure options (7 to 9) |
|---|---|---|---|
| PR wait in CI | 7 to 9.5 min | ~6.5 to 7 min | ~4 to 5 min |
| Pre-push wait, local | ~32s | ~15s | ~15s |
| Billed CI minutes per month | ~770 | ~600 | ~670 to 730, still under today |

## Proposed milestone

One milestone, `Faster PR testing`, one issue per finding:

1. Speed up the CSS palette scanner, identical outputs proven (p2)
2. Give retry tests an injectable clock so they stop sleeping for real (p2)
3. Replace the safe fixed sleeps in browser specs with condition waits (p2)
4. Cache the Playwright browser download in CI (p2)
4b. Pin wrangler as a devDependency so the browser suite stops downloading it on demand (p2, the pre-existing #931, moved into the milestone 2026-08-29)
5. Fold the workflow lint job into the Test job (p3)
6. Delete subsumed tests, merge the workflow linters, table-drive the endpoint auth gates (p2)
7. Share page loads in the read-only board and aliases specs (p2)
8. Share the page walk across the four a11y and contrast sweeps (p3)
9. Experiment: browser suite workers 2 to 3, judged by the retry report (p2)
10. Decide: parallel or sharded CI jobs against the Actions cap (p3)
11. Extract the shared refresh-script test harness (p3)

Findings 1 through 5 are independent and low risk. Finding 6 is deletions and merges with the sweep's file-by-file notes as the map. Findings 7 and 8 land family by family. Finding 9 is a measured experiment with a built-in instrument and an easy revert.

---

# Slate test speed audit (2026-08-29)

## The headline

Slate's tests are the healthiest of the three repos. The node harness (300 suite files) runs in 5.8 seconds on this machine and vitest (199 files, 2,014 tests) in 9.3 seconds. A dedicated sweep of all 499 test files found essentially no redundant coverage to delete, and not a single test sleeps on a real timer of 100ms or more: every retry path already has an injectable clock. The wait is entirely pipeline. A typical PR sits 5 to 5.75 minutes in CI because every check runs one after another inside a single job on GitHub's 2-core runner, and a second job then runs the ENTIRE test suite again under coverage instrumentation, on every PR, producing a report nothing reads.

So the fix is workflow restructuring only: the same commands run side by side instead of in a line, and the duplicate run moves off PRs. PR wait drops from about 5.5 minutes to roughly 2.5, and merge-to-live from about 7 minutes to roughly 4.5. Nothing below weakens what is checked.

## Where the time actually goes (measured)

CI numbers are per-step timings from the GitHub API (34 recent PR runs: average 5m05s, slowest 5m45s). Local numbers were measured today on this machine.

### One CI run on a pull request (four jobs in parallel; `ci` is the critical path)

| Job | Typical | What is inside it |
|---|---|---|
| ci | 5m15s to 5m45s | setup + install 25s, dependency audit 1s, typecheck 17s, lint 23s, node suite 83s, vitest 122s, Cloudflare build 48s, all run one after another |
| coverage | 4m05s | the entire test suite a SECOND time, under coverage instrumentation, plus the merged report |
| security-scan | 1m22s | semgrep install 18s, scan 58s; fine as is |
| migration-drift | 11s | fine as is |

Two numbers stand out. The node suite that takes 5.8 seconds on this machine takes 83 on the runner (2 cores against 14, and 300 separate node processes each paying a cold start). And vitest spends 122 seconds of wall time to run about 30 seconds of actual test bodies; the rest is worker startup, file collection, transforms, and the jsdom environment for the 44 component files.

### The local gates

| Gate | Measured |
|---|---|
| Node suite, full | 5.8s (concurrency 14) |
| Vitest, full | 9.3s |
| tsc / lint / Cloudflare build in the working tree | 1.4s / 7.3s / 14.5s |
| Pre-push hook, end to end | 52s |

The pre-push hook measures 52 seconds, not the "~20s on a warm cache" AGENTS.md claims. The isolated worktree it deliberately builds (#490, so an uncommitted file cannot make a check pass locally that fails in CI) pays a fresh install, a cold typecheck, and a cold build on every push. 52 seconds is a fair price for catching CI-only failures before they reach a PR; the stale documentation number should simply be corrected.

### After the merge

A push to main re-runs the full ci job on the merge commit (5m25s) and only then starts the deploy job (1m43s), so merge-to-live is about 7m10s. The re-run is not waste (the merge commit is new, and the ci check is what both the deploy and the main-push guard read), but it inherits every second the PR pipeline loses, so the fix below pays twice per PR: once at the PR and once on the way to production.

### Volume and billed minutes

378 CI runs in the last 30 days, roughly 201 on PRs and 177 pushes to main. At GitHub's round-up-per-job billing that is roughly 5,600 billed job-minutes a month for this workflow family, of which the coverage job's duplicate suite run is about 1,900. (The smoke canary is another ~1,440 runs a month on its own schedule; it is production monitoring, not PR testing, and nothing here touches it.)

## Findings, ranked by payoff

### 1. Run the pipeline's independent halves side by side (biggest wall-clock win)

Typecheck, lint, the node suite, vitest, and the Cloudflare build have no dependency on each other, and today they run in a line inside one job. Split them into three parallel jobs: one for typecheck + lint + the node suite (about 2m30s), one for vitest (about 2m25s), one for the Cloudflare build (about 1m10s), with a small fan-in job that requires all three. PR wall time drops from ~5m20s to roughly 2m35s, the same drop applies to the push to main, and merge-to-live falls to about 4m30s. Same commands, same tests, same failure behavior; billed minutes stay roughly flat (three small setups replace one).

Three couplings must move in the same change, and this is most of the work. The main-push guard decides whether a merge to main was legitimate by reading the check literally named "ci" on the PR head commit (two places in main-push-guard.yml), so the fan-in job must carry that exact name. The deploy job's requirements list points at `ci`. And scripts/test-ci-workflow.ts pins the workflow's shape and needs updating. The fan-in job also needs its own guard: a job accidentally missing from its requirements list would keep running while gating nothing, so the workflow test should pin that the fan-in requires every test-carrying job in the file. Risk to coverage: none, once that pin exists.

### 2. Stop running every test twice on every PR (the coverage job)

The coverage job re-runs both full suites under instrumentation on every PR and every merge, purely to print a percentage and upload a file. It is report-only by design (#603), the uploaded artifact has no consumer anywhere in the repo or workflows, and the merge logic it exercises is separately unit-tested inside the normal suite, which keeps running on every PR.

It matters more than it looks: the merge flow waits for ALL checks to go green, so a report-only job still delays every merge it outlives. Today it hides behind the 5m20s ci job; after finding 1 it would BE the critical path at 4m05s and silently take back most of the win. Move it to pushes to main only (keeps a per-merge coverage record, saves ~1,000 billed minutes a month), or to a weekly schedule (saves ~1,900). Risk to coverage of the code: none; what changes is how often a number nobody currently reads gets printed.

### 3. Vitest's overhead on the cold runner (bounded experiments)

122 seconds of wall for 30 seconds of tests is the startup tax of a cold 2-core runner: transforms, collection, and 44 jsdom environments. Two cheap experiments, measured before keeping, same as the Bidspoke list: cache vitest's transform cache directory between CI runs keyed on the lockfile, and try the thread pool instead of forked processes. If the vitest leg is still the critical path after that and 2.5 minutes still hurts, splitting it across two shards is the next step (costs ~2 extra billed minutes per run). Explicitly not on the table: turning off test isolation, for the same reason as the other two repos.

### 4. The pre-push hook: fix the stale claim, optionally overlap the steps

Correct AGENTS.md's "~20s" to the measured ~50s so nobody budgets against a fiction. Optional, low priority: the hook runs its four checks serially in the isolated worktree; the Cloudflare build could run concurrently with typecheck + lint + tests (the machine has cores to spare), landing around 35 seconds. The isolated-worktree design itself is load-bearing and stays.

### 5. What the redundancy sweep found: a clean bill, three small cleanups

A dedicated sweep of all 499 test files, built to find duplicated coverage, subsumed weak tests, duplicated test titles, and real-timer sleeps, came back nearly empty, which is the one-guard-per-invariant culture holding. The 38 test titles that appear in multiple files (the same 401 check in eleven cron route files, the same login redirect in seven admin page files) each assert their own route's behavior and are not mergeable without losing per-route coverage. The three genuine cleanups, none urgent: one 44-line suite is fully absorbable into its neighbour that already imports the same module (test-sync-agents.ts into test-sync-pace.ts, moving its three unique assertions); the two alert-notifier suites share seven byte-identical assertion blocks that belong in one shared helper (boilerplate, not coverage); and one guard test re-resolves the same two binaries eleven times per run where once would do. Worth batching into a single cleanup PR when someone is nearby, not worth a dedicated effort.

The sweep also confirmed where the node harness's weight sits: only 12 of 300 suites spawn subprocesses, and just two are expensive, the scripts-tree typecheck (a full tsc pass, 23 to 37 seconds on CI, the slowest single file) and the license check (a full dependency-tree resolution). Both are CI-shaped guards doing real work; after finding 1 they sit comfortably inside the node leg's 83 seconds and need nothing. (The first half of that sentence survived the post-filing sweep; the second did not, see the correction below.)

## After filing (2026-08-29): a sweep of the milestone against the combined lessons

The five proposed issues were filed as #1592 to #1596. The milestone was then swept against the combined lessons and the open issue list, the same second pass the other two repos got. It caught one new finding, corrected one claim above, and pulled two pre-existing issues into the milestone plus one new one beside it.

### 6. No job in any workflow has a timeout (filed #1597)

Every job in all five workflow files runs with GitHub's default 6 hour timeout: zero `timeout-minutes` anywhere. This is Bidspoke's finding 10 sitting unchecked in the neighbouring repo, which is lesson 14 doing exactly what it warns about. The consequence is sharpest on main: ci.yml deliberately never cancels an in-progress main run (a run on main IS the deploy), so a hung main run is never superseded, pushes queue behind it, and every deploy is blocked for up to six hours while the hang bills up to 360 minutes per job. The smoke canary fires every 30 minutes, so a hang there stacks. The class has already fired here in miniature: #1437 was the Supabase CLI download hanging up its socket. Fix as in Bidspoke: measured durations plus headroom on every job, plus a guard over EVERY workflow file (extend scripts/test-ci-workflow.ts or add a sibling in `pnpm test`), scoped to the directory so a sixth workflow is covered by construction rather than by memory.

### A correction to finding 5

Finding 5 said the scripts-tree typecheck "needs nothing". Pre-existing #1516 (2026-08-16) says otherwise: that suite runs tsc over the tree TWICE, once for real and once with a planted undefined identifier to prove the guard can still fail, so about half of the slowest single suite in CI is a self-proof being re-proved on every push, every pre-push, and every CI job. The issue already names the fix (one tsc program with the control file planted up front, asserting it is the ONLY finding, or a flag-gated control run exercised on a schedule so its absence is not silent). Moved into the milestone at its existing p3.

### Also caught

- **#1555** (the admin settings page test fails intermittently under a full vitest run) moved into the milestone, priced the way PET's #931 was: a flake on the pre-push gate and in CI is a speed cost, because its failure mode is a full re-run of the pipeline in both currencies, plus the erosion of the suite being believed.
- **deploy-alert.yml still carries the full dependency install that #1524 removed from the main push guard**: pnpm setup plus `pnpm install --frozen-lockfile`, purely to post one Slack message, in the workflow that fires precisely when CI on main has already failed. Same lesson 14 shape (the fix covered the file that failed, not its sibling), but a reliability finding rather than a speed one, so filed outside the milestone as #1598: route it through the no-dependency slack-post.ts path the guard uses since #1524.
- The rest of the second-pass lesson list comes back clean here: no npx-invoked tool missing from package.json (wrangler and opennextjs-cloudflare are pinned devDependencies; the gitleaks binary is version-pinned and checksummed), and the tiny always-on jobs all earn their isolation (migration-drift separately gates deploys, merge-gap and the main push guard are alone on their trigger events, and deploy-alert's job-level `if:` means its roughly 200 monthly skipped runs bill nothing, which is the exact shape finding 13 asks Bidspoke's auto-merge check to adopt).

## What the WWT article's practices say about this suite

The live page still sits behind a bot check (both fetch attempts this audit); the practices below are the ones read in full during the PET audit via the Internet Archive: team conventions, behavioral test names, arrange-act-assert, isolated per-test setup, hiding irrelevant detail, one behavior per test, no logic in tests, self-explaining assertions, and eliminating redundancy.

Slate follows the quality practices unusually well, and two of them are visibly load-bearing here. "Isolated setup" is the strictest of the three repos: every node suite is its own process by contract. And the injectable-clock discipline means the "no fixed sleeps" battle PET still has to fight never started here. As in both other repos, the one practice with a speed consequence, eliminate redundancy, lands at the pipeline level rather than the test level: Slate's duplicate is not a copied test but the coverage job running every test twice per PR (finding 2).

## What was deliberately not proposed

- Dropping the pre-push/CI double-run. The hook exists because a green-local, red-CI push happened (#490); 52 seconds per push is the price of catching that class before it reaches a PR, and the CI re-run on the merge commit is the gate the deploy and the main-push guard read.
- Batching the 300 one-process-per-file node suites into fewer processes. On paper the biggest node-harness lever (115 files are under 100 lines, each paying a process start), but one-file-one-process is the harness's isolation contract, the suite is 5.8 seconds locally, and after finding 1 the CI cost sits fine.
- Consolidating the ten guards that each walk the whole src/ tree. Measured at single-digit seconds across already-parallel processes; sharing the walk would cost per-invariant failure isolation for almost nothing.
- Turning off vitest isolation, path-filtering which tests run, or trimming suites. Same reasoning as the other two repos: each trades signal for speed.
- Skipping the Cloudflare build on PRs. It exists because build-only breaks that typecheck accepts have shipped before (#412).

## The picture after all of it

| Scenario | Today | After |
|---|---|---|
| PR wait in CI | 5m05s to 5m45s | ~2m35s |
| Merge-to-live | ~7m10s | ~4m30s |
| Pre-push wait, local | 52s | ~35s (optional finding 4) |
| Billed job-minutes per month | ~5,600 | roughly flat; ~4,900 if coverage goes weekly |

## Proposed milestone

One milestone, `Faster PR testing`, one issue per finding:

1. Split CI into three parallel jobs behind a fan-in check named ci (p2): the guard couplings in finding 1 are the checklist
2. Move the coverage job off pull requests (p2): decide main-only vs weekly in the issue
3. Correct AGENTS.md's pre-push timing claim; optionally overlap the hook's build with its other checks (p3)
4. Experiment: vitest transform cache and thread pool on CI, measured before keeping (p3)
5. Test-suite cleanups from the sweep: absorb test-sync-agents, extract the shared notifier harness, hoist the repeated binary lookups (p3)

Added by the post-filing sweep (2026-08-29):

6. Give every job in every workflow a timeout and guard the class (p2, ci, reliability)

Filed 2026-08-29: findings 1 through 5 as #1592 to #1596, finding 6 as #1597. Also moved into the milestone: #1516 (the scripts typecheck double run, the correction to finding 5) and #1555 (the intermittent vitest failure, priced as a re-run cost). Filed beside the milestone as #1598: the deploy-alert dependency chain.

Finding 1 is the one that needs care (three named couplings plus a new pin); 2 and 3 are small edits; 4 is a measured experiment; 5 is a tidy-up PR; 6 is mechanical once its guard exists.

---

# NurseDex test speed audit (2026-08-29)

## The headline

NurseDex is the fourth repo and it breaks the pattern in one way: the merge is not the wait. Vercel deploys production about 55 seconds after a push to main and is gated on nothing, so merge-to-live is one minute and every job that runs on main is a signal after the fact. The wait people actually sit through is the pull request, and that wait is the E2E job: 7.8 to 12.8 minutes, of which the 54 Playwright specs are 3.5 to 4 minutes on a clean run and everything before them is plumbing. CI runs beside it in 2 to 3.3 minutes and never sets the critical path.

The unit tests are the cleanest of the four repos on the test-level lessons: 1,967 tests in 226 files run in 11.9 seconds locally, no test sleeps on a real timer (110 fake-timer uses, zero real ones), only four tests exceed half a second (4.2 seconds between them), and the duplicate-title sweep found only per-route checks already table-driven through a shared helper. There is nothing to trim.

So the findings sit almost entirely in the E2E job's setup: about 115 seconds pulling twelve Docker images cold on every run, the same 65 migrations and seed applied twice in consecutive steps, an uncached browser download, and a flake that doubles the Playwright step on one run in five. Together they take a clean PR from about 8.5 minutes to about 5.5 without changing a single assertion, and the two measured experiments after that (a second Playwright worker, a prebuilt server instead of the dev server) are what would get it under 4. Nothing below weakens what is checked.

## Where the time actually goes (measured)

CI numbers are per-step timings from the GitHub API across the twelve most recent CI runs (six pull request, six push) and ten E2E runs; local numbers were measured today on this machine with per-test timing reports. Both jobs, plus the Vercel preview, are required checks in the `Protect main` ruleset, so a PR waits for the slower one.

### One pull request (two workflows in parallel; E2E is the critical path)

| Job | Typical | What is inside it |
|---|---|---|
| E2E, `authenticated e2e` | 466 to 769s | setup 30s, Supabase CLI 4s, `supabase start` 121 to 167s, `db reset` 32 to 38s, RLS tests 21 to 29s, Playwright browser install 23 to 41s, Playwright specs 210 to 462s, all in a line |
| CI, `lint, typecheck, test` | 126 to 198s | install 24 to 34s, lint 7 to 10s, typecheck 14 to 24s, vitest 66 to 111s, guard mutation 1 to 7s |
| Vercel preview | ~55s | fine as is |

Inside `supabase start` (read from the log of a 160 second run): 115 seconds pulling images (postgres, kong, gotrue, postgrest, storage-api, realtime, edge-runtime, postgres-meta, studio, logflare, vector, mailpit), 17 seconds starting the database, 1.5 seconds applying 65 migrations and the seed, 24 seconds starting the containers. Inside `db reset` (32 seconds): 19 seconds restarting the database, 2 seconds re-applying the same 65 migrations, 11 seconds re-running the same seed.

Inside the Playwright step: 54 specs on one worker against a Turbopack dev server that compiles routes on demand (the reason `e2e/global-setup.ts` warms five routes before any spec runs, #623). The four fastest runs were 210 to 230 seconds and reported `54 passed (3.6m)`; the two slowest were 413 and 462 seconds and reported `1 flaky, 53 passed (7.6m)`. A single retry roughly doubles the step, because the retried spec re-drives a whole authenticated journey and `retries: 2` allows it twice.

Inside the vitest step (from the CI log): transform 3.5s, import 32s, environment 18s (62 of the 226 files run under happy-dom), test bodies 24s, wall 103s on the runner's four cores against 12 seconds on this machine's ten.

### The local gates

| Gate | Measured |
|---|---|
| Vitest, full (`npm test`) | 11.9s |
| Slowest test file | `page-authz-boundary.test.tsx`, 2.4s; next `zip-seed-migration.test.ts` 1.6s |
| Tests over 500ms | 4, totalling 4.2s |
| Real timer sleeps in unit tests | none (one `waitForTimeout(500)` in the e2e blog author spec) |
| Pre-push test gate model judge (global, all repos) | up to 90s worst case, only when source changed |

The repo installs no git hooks of its own; the pre-push gates are the global ones. CONTRIBUTING's "a few seconds" for `npm test` is 12 seconds measured, close enough. The stale claim is in `e2e/README.md`, which still says the CI job "currently runs only lint, typecheck, and the vitest suite, not Playwright" and that an e2e job "is needed": e2e.yml has existed and gated every PR for weeks (L32, L244).

### After the merge

A push to main starts four workflows at once: CI again (374 to 394 seconds, because the guard mutation step switches from the PR's changed-sites scope to the full sweep of 105 mutants, 207 to 219 seconds), E2E again (466 to 718 seconds), Migration Drift (47 to 64 seconds) and Production Smoke (64 to 69 seconds). Vercel builds and promotes production in 51 to 58 seconds in parallel with all of them and waits for none. So merge-to-live is about one minute, and the 6.5 minute CI run and the 8 to 12 minute E2E run on main are post-hoc signals: a survived mutant or a broken journey found there is found after it has shipped. That is not a speed finding (nothing waits), but it has to be named so nobody speeds up the main-push jobs believing they hold the deploy, and so the shape is a known decision rather than an accident (lesson 13, in reverse).

### Volume and billed minutes

The billing API needs the `user` scope on the `nursedexapp` token and this session's token does not carry it, so the bill is computed rather than read: every job in the last 30 days, rounded up to the minute the way GitHub bills it. CI 205, E2E 397, Production Smoke 93, Migration Drift 62, Dependency Audit 4: about 761 minutes a month across 47 CI runs, 47 E2E runs, 48 of each scheduled check and 4 audits. The repo is private and owned by the personal `nursedexapp` account, not the Try-Pennie org, so it draws on that account's own free allowance (2,000 minutes on Free, 3,000 on Pro) and sits well inside it. Unlike the other three repos, the paid currency is currently zero here; wall clock is the only budget that bites, and the billing findings below are worth doing for tidiness and for the day the volume triples, not for money today.

## Findings, ranked by payoff

### 1. `supabase start` pulls twelve Docker images cold on every E2E run (about 115 seconds, on every PR and every merge)

The image pull is the single largest block in the whole PR pipeline, and most of the images are for services the suite never touches. `supabase/config.toml` enables studio, analytics (which brings logflare and vector, the two largest pulls), edge_runtime, realtime and inbucket (mailpit). Checked against the code: there are no edge functions in the repo, nothing in `src/` subscribes to Realtime, the e2e setups create their users through the admin API with `email_confirm: true` so no test reads a mailbox, and nobody opens Studio on a runner. Storage is used (nurse photos, blog images) and stays, as do postgres, kong, gotrue and postgrest.

Fix: keep config.toml as it is for local development and pass the CI-only exclusion flag on the runner, `supabase start -x studio,logflare,vector,edge-runtime,realtime,mailpit,postgres-meta`, then confirm from the log that the excluded images are no longer pulled and that the RLS suite and every Playwright project still pass. Measure before keeping: the saving is the pull time of the excluded images plus their container start, estimated at 50 to 80 seconds of the 121 to 167. The alternative, caching the images with `docker save` into `actions/cache`, was considered and set aside: a multi-gigabyte cache costs restore time on every run and the exclusion removes the work instead of relocating it. Risk to coverage: none, provided the exclusion list is checked against the services the suite reaches, which the run itself proves (a spec that needed an excluded service fails loudly on connection refused, not quietly).

### 2. The migrations and seed are applied twice, back to back (32 to 38 seconds)

`supabase start` on a fresh runner applies all 65 migrations and the seed (the log shows `Applying migration 001_schema.sql` through `065` and `Seeding data from supabase/seed.sql` inside the start step), and the very next step, `supabase db reset`, restarts the database and applies the identical 65 migrations and the identical seed again. The workflow comment credits reset with two jobs: a clean known state, which a runner that did not exist a minute ago already has, and surfacing a broken migration, which `start` also does if it fails on one.

Fix: drop the reset step, after proving the second half of that claim rather than assuming it (L1): plant a deliberately broken migration on a branch and confirm the `supabase start` step goes red on it. If it does not, keep the reset and instead stop `start` from applying migrations, which is the same saving from the other side. Saves 32 to 38 seconds per E2E run. Risk to coverage: none once the planted-migration check has been seen to fail.

### 3. The Playwright browser is downloaded from scratch on every run (23 to 41 seconds)

PET's finding 4 exactly: `npx playwright install --with-deps chromium` fetches the browser every time. Cache `~/.cache/ms-playwright` keyed on the `@playwright/test` version from the lockfile and keep the `--with-deps` system package install, which is a few seconds. Saves 20 to 35 seconds per run. Risk to coverage: none; a version bump changes the key and re-downloads.

### 4. One run in five pays a flake, and nothing makes the flake visible

Two of the ten sampled E2E runs reported `1 flaky` and took 413 and 462 seconds against 210 to 230 for the clean runs: the retry roughly doubles the Playwright step, and with `retries: 2` a second retry would triple it. The reporter is `html` only, so the only trace of which spec flaked is the uploaded report artifact and a one-line summary buried in the job log; nothing counts flakes across runs, and a reviewer sees a green tick either way.

This is the instrument finding (lesson 9), and it comes before any experiment on the Playwright step. Add a list or GitHub reporter beside the html one (or write the flaky count and spec names to the step summary), so a flake is visible on the run and countable across runs. Then identify the spec from the two reports and file it as a speed cost the way PET's #931 and Slate's #1555 were priced: its failure mode is 3 minutes on the critical path, on one PR in five.

### 5. Two measured experiments on the Playwright step itself (210 to 230 seconds clean)

With the instrument from finding 4 in place, two bounded experiments, each measured before keeping and each revertible in one line:

1. **Workers 1 to 2.** `workers: process.env.CI ? 1 : undefined` was set defensively; the runner has four cores and the dev server, the browser and one worker do not saturate them. Judge by the flaky count over a week of PRs, exactly as PET's worker experiment is judged by its retry report. The three storageState projects (admin, family, nurse) are independent journeys and the natural parallel unit.
2. **`next build` plus `next start` instead of `next dev`.** Every spec today drives a Turbopack dev server that compiles each route on first request, which is both a cost inside every spec and the class of failure `global-setup.ts` exists to work around (#623, a real 404 from a route not yet compiled). A production build costs about a minute on the runner (Vercel does the same build in 51 to 58 seconds) and then every route is precompiled, so the specs get a server that answers at production speed and the 404 race disappears by construction rather than by warming a hand-listed set of routes. Whether the minute of build is repaid by the specs is the measurement; the expected answer is yes by a wide margin, because 54 authenticated journeys each hit several cold routes today.

### 6. The guard mutation sweep is 105 separate vitest boots (207 to 219 seconds on every push to main)

`scripts/guard-mutation.ts` mutates one guard call site at a time and spawns `npx vitest run <suite>` for each, so the sweep pays 105 vitest boots (each a cold collect of one suite file, about two seconds on the runner) to run about 24 seconds of test bodies. The one-mutant-at-a-time semantics and `classifyRun`'s refusal to score a kill without a real assertion failure are the whole point of the tool and must not change; the lever is the boot. Two shapes, measured before keeping: run mutants concurrently in N isolated checkouts (a `git worktree` per lane, because a mutation is a write to the real file on disk and two lanes in one tree would score each other's mutants), or keep one vitest instance warm through its Node API and re-run the suite per mutant. Both are gated by the existing `guard-mutation.test.ts` (47 tests) and by the sweep's own summary line, which must still read `Killed 105, weak 0, survived 0, inconclusive 0` on an unchanged tree.

Two things make this worth doing even though nobody waits on main. First, the same sweep runs on a PR whenever a boundary suite changes, because every site mapped to that suite is re-proven, so a PR that edits `authz-boundary.test.ts` pays the full 3.5 minutes inside CI (though E2E still hides it). Second, ci.yml's `cancel-in-progress: true` applies to `refs/heads/main` as well as to branches, so a second merge inside the 6.5 minute window cancels the first merge's sweep, and a mutant that survived on the first merge is never reported anywhere (L98: a cancelled watcher reads the same as a clean one). Thirty days of runs show no cancelled push run, so the window has not been hit yet; shrinking the sweep shrinks the window, and the concurrency group should in any case not cancel on main. About 60 billed minutes a month.

### 7. Two scheduled checks install the whole dependency tree to run one script

Migration Drift (47 to 64 seconds) and Production Smoke (64 to 69 seconds) each run `npm ci` (22 to 38 seconds) so that `npx tsx` can execute a checker script whose imports are its own sibling module and one constants file. This is Slate's #1598 shape, and it has a billing consequence lesson 12 predicts: Production Smoke lands just over the minute on every run and bills two, 48 times a month. Installing tsx alone, pinned (`npm install --no-save tsx@<lockfile version>`, a few seconds), brings both jobs under a minute and saves about 100 billed minutes a month.

The two workflows also fire on the same events (every push to main, and daily at 13:00 and 13:30 UTC), link the same Supabase project, and each answers a read-only question that alerts on its own. Production Smoke already shows the right shape for that: its legacy host check is a second `if: always()` step inside the same job, re-linking rather than trusting its predecessor, so each question fails independently. Migration Drift could be a third such step and bill nothing extra. Whether to fold it is a judgement call (the drift check has no Slack path today and the smoke check does; folding would give it one), and at today's volume it is worth about 60 minutes a month; noted, not pushed.

### 8. Three of five workflows have no timeout, and no guard covers the class

ci.yml (15 minutes, against 6.6 measured) and e2e.yml (20, against 12.8) carry `timeout-minutes`; dependency-audit.yml, migration-drift.yml and prod-smoke.yml carry none, so a hung Supabase CLI download or a link that never answers holds a runner for six hours and bills 360 minutes (L110). Bidspoke's finding 10 and Slate's finding 6, in the fourth repo running. The four workflow tests under `scripts/` each pin one file's shape and none asks about timeouts, so the fix is one test over the whole `.github/workflows` directory requiring a timeout on every job, with values taken from the measured durations plus headroom (the scheduled checks at 5 minutes, the audit at 5).

### 9. The Supabase CLI is `version: latest` in three workflows (reliability, note only)

`supabase/setup-cli@v2` with `version: latest` in e2e.yml, migration-drift.yml and prod-smoke.yml, and `npx supabase` in the local scripts. Unpinned (L25), but deliberately: the e2e.yml comment records why (#354, a CLI release changed Data API exposure and the repo chose to track it rather than discover the next change late). The cost is the other direction, a CLI release breaking E2E on a day nothing in the repo changed. A pinned version bumped on purpose is the safer shape and Dependabot cannot bump this field, so it is a hand decision; recorded here so the trade is visible, not proposed as a change.

### 10. What the redundancy sweep found: clean

226 files, 1,967 tests. Six titles appear in three or more files: "returns 401 without the cron secret" in 13 cron route files and "does no work at all when unauthenticated" in 12, both generated per route by `test/cron-auth.ts`'s `describeCronAuthGuard` (already the table-driven shape PET's finding 6 asks for, with each route keeping its own coverage), and four component titles ("blocks a second submit while the first is running", "stays disabled on a stall and never offers a retry") that each assert their own component's button. Nothing mergeable without losing per-route or per-component coverage. No real-timer sleeps in the unit suite; the one fixed wait is `waitForTimeout(500)` in `blog.author.auth.spec.ts`, PET's safe bucket, replaceable with a wait on the thing itself when someone is in that file.

### 11. Vitest cold start on the runner (bounded experiment, low priority)

103 seconds of wall for 24 seconds of test bodies, on four cores: 32 seconds of import and 18 of environment setup for the 62 happy-dom files. The pool is already `threads`. The one remaining lever the other repos list is caching vitest's transform cache between runs; here `npm ci` recreates `node_modules` on every run, so the cache directory has to be restored after the install step or pointed outside `node_modules`. Worth a single measured run and not more: CI is not the critical path and will not be until E2E is under about 2.5 minutes.

## Third pass (2026-08-29): what lessons 17 to 31 caught

The NurseDex section was re-run against the fifteen lessons the other five repos added. Most describe shapes NurseDex does not have (macOS runner pools, Swift test output formats, a suite that shards itself). Five were checked directly, one turned up a real finding, and three sharpened issues already filed.

### 12. The E2E run on every push to main re-tests a tree the same job already passed (lesson 22, PostRoll's shape, provable here)

The `Protect main` ruleset requires linear history and an up-to-date branch, and every merge is a squash, so the merged commit's tree is the pull request head's tree. Checked on the last six merges (#789 to #794): all six merge commits have a tree hash identical to the PR head that carried the green `authenticated e2e` check. e2e.yml then runs again on the push, against a throwaway Supabase, on that identical tree: 17 runs and 149 billed minutes in the last 30 days (about 40 percent of the E2E workflow's bill), 7.8 to 12 minutes each, gating nothing and read by nobody, since Vercel has already deployed. The lint, typecheck and vitest steps of the CI push run (about 135 seconds of its 6.5 minutes) are the same duplicate; only the full guard mutation sweep is new on a push, and it runs its own baseline of the three suites it mutates.

Fix, fail closed the way lesson 22 describes: on a push to main, look up the merged pull request for that commit, compare its head tree hash with the pushed commit's tree hash, and confirm its `authenticated e2e` check succeeded; skip the E2E job only when all three hold, and run it in every other case (a direct push, a tree mismatch, a check that was not green, a lookup that fails). The same proof can skip CI's lint, typecheck and test steps on push and leave the sweep. Because the skip condition is a proof of identity rather than a path filter, it cannot skip a test that should have run. Risk to coverage: none; saves about 150 billed minutes a month and stops the main branch's E2E history being a copy of the PR's.

### Also caught

- **The account is capped, and nothing shows how much is left (lesson 19).** The repo is on a personal account whose free minutes, when exhausted, refuse every run rather than bill; at about 760 of 2,000 a month it is at 38 percent, and the three E2E findings plus finding 12 roughly halve that. No workflow, badge or page in the repo shows the remaining allowance, and this session's token cannot read it. The check is a person's: open the account's billing page once a month, or on the first red run that has no log. The one red CI run in the sample (2026-08-24, a Dependabot PR) was opened and is a real typecheck failure (a Stripe API version type), not a refusal.
- **Vitest's own timing store never reaches the runner (lesson 21).** Vitest orders test files slowest first from a results cache under `node_modules/.vite/vitest`, and `npm ci` deletes `node_modules` on every run, so the runner orders by file size every time. Folded into #811: the cache experiment should carry that store as well as the transform cache, because the ordering is what a four-core runner needs most.
- **The mutation sweep has no measured distance to its deadline (lesson 26).** 105 mutants take 211 seconds under ci.yml's 15 minute timeout, and every new guard site adds about two seconds; nothing reports the ratio, and the first sign of growth would be a red main run that names the timeout rather than the size. Folded into #807: log the sweep's duration against its timeout, and keep a check that it stays under a fraction of it.
- **The Playwright experiments must be judged by tests executed before tests failed (lesson 29).** Folded into #806: the first line to read after a workers or server change is `54 passed` against 54 expected, not the failure list.
- **Bare failure assertions (lesson 18): clean.** Seven `toThrow()` calls with no expected message, all on pure parsers fed a literal bad string (the drift, smoke and audit checkers), none of which can reach a network. No unit test reaches a real host; the tests that spawn work run PGlite in process, not a subprocess.
- **Lessons 17, 20, 23 to 25, 27, 28, 30, 31: nothing here.** Per-test timings were read on a ten-core machine, not the runner; the suite does not shard itself; no scanner pays per line (all tree walks are under 1.2 seconds); the private repo's concurrency limit is far above four workflows; the one recorded premise that had expired (e2e/README) is already #810; no derivation is rebuilt per test at a cost worth a memo; and the concurrency setting that mattered (one Playwright worker) is #806.

## What the WWT article's practices say about this suite

Same list as the other three (behavioural names, arrange-act-assert, isolated per-test setup, one behaviour per test, no logic in tests, self-explaining assertions, eliminate redundancy). NurseDex follows them at least as well as Slate: test names are sentences that say what would be wrong, the cron and page guard tests are generated from shared helpers so a new route inherits its gate tests, and the guard mutation tool is the article's "a test must be able to fail" made mechanical. As in every repo so far, the redundancy with a speed consequence is not a duplicated assertion but duplicated work: a database built twice per run, an image set pulled 47 times a month, a browser downloaded 47 times.

## What was deliberately not proposed

- **Splitting the CI job.** Lint (9s) and typecheck (22s) run before the tests (100s) and could run beside them, saving about 30 seconds of a job that finishes 5 to 10 minutes before the E2E job does. Worth nothing until E2E is under about 2.5 minutes; and both `lint, typecheck, test` and `authenticated e2e` are named as required checks in the `Protect main` ruleset, so any future split must ship a fan-in job carrying the old name (lesson 6).
- **Skipping the E2E job by changed paths.** The RLS suite proves the database and the Playwright suite proves the app against it; a backend change breaks journeys and a frontend change breaks reveal flows that write. There is no path set that is safely uninteresting.
- **Cutting `retries: 2`, the RLS suite, or any of the 54 specs.** The retries are the reason a flake costs 3 minutes rather than a red PR and a manual re-run; finding 4 makes the flake visible so it can be fixed instead of hidden. The RLS suite is 20 seconds of test bodies that have caught self-escalation and paywall bypass before (#384 to #389).
- **Running `npm test` in the E2E job or the RLS tests in CI.** Each already runs exactly once per event in the job that has what it needs; `test/every-test-runs.test.ts` exists to keep that true.
- **`isolate: false` in vitest, and trimming the unit suite.** Same reason as the other three repos; at 12 seconds locally there is nothing to trim.
- **Gating the Vercel production deploy on CI or E2E.** It would make every deploy wait 8 to 12 minutes. Whether production should ship before its full sweep finishes is a product decision about what a merge means, not a speed decision, and belongs in its own issue if it is to be made at all.

## The picture after all of it

| Scenario | Today | After findings 1 to 3 | Plus findings 4 and 5 (if the experiments hold) |
|---|---|---|---|
| Clean PR wait in CI (E2E critical path) | ~8.5 min (466 to 585s) | ~5.5 min | ~3.5 to 4 min |
| PR wait with one flake | ~12.5 min | ~9.5 min | flakes visible and being fixed |
| Merge-to-live | ~1 min (ungated) | ~1 min | ~1 min |
| Push-to-main full sweep, CI | ~6.5 min | ~6.5 min | ~3 min with finding 6 |
| Billed minutes a month | ~761 | ~600 | ~500 (still inside the free allowance either way) |

## Proposed milestone

One milestone, `Faster PR testing`, one issue per finding. Filed 2026-08-29 as #802 to #811 (milestone 27), in the order below. Also in the milestone: #801, the decision on whether production should wait for the main branch sweep (finding 10's open question), filed the same day.

1. Exclude the Supabase services the e2e suite never touches from `supabase start` in CI, measured (p2, ci, developer-experience)
2. Stop applying migrations and seed twice in the E2E job, after proving `start` fails on a planted broken migration (p2, ci, testing)
3. Cache the Playwright browser download in CI (p2, ci)
4. Make Playwright flakes visible on every run, then price and fix the one already flaking (p2, ci, testing, reliability)
5. Experiment: two Playwright workers, and a prebuilt server instead of the dev server, each judged by the flake instrument (p3, ci, experiment)
6. Cut the guard mutation sweep's 105 boots, and stop cancelling in-progress sweeps on main (p3, ci, testing)
7. Run the drift and smoke scripts without installing the whole tree; consider folding drift into the smoke job (p3, ci, cost)
8. Give every workflow job a timeout and guard the class across the directory (p2, ci, reliability)
9. Correct e2e/README's claim that CI runs no Playwright job (p4, documentation)
10. Experiment: vitest transform cache on the runner (p4, ci, experiment)

Added by the third pass (2026-08-29):

11. Skip the E2E job and CI's duplicate steps on a push to main when the merged tree is provably the PR tree that already passed (p3, ci, cost)

Findings 1 to 3 are independent, each a few lines of workflow, and together take a clean PR from about 8.5 minutes to about 5.5. Finding 4 is the instrument and comes before finding 5. Finding 6 is the one that needs care, for the same reason Slate's split did: a tool whose whole value is its refusal to score a kill it did not see.

---

# PlayedIt test speed audit (2026-08-29)

## The headline

PlayedIt is the fifth repo and the first where the question "how long do the tests take" has a worse answer than the number: **CI has not run at all since 2026-07-28.** The last run that started (30386381717, the open PR #342) was refused by GitHub before either job began, with the message "The job was not started because recent account payments have failed or your spending limit needs to be increased." The reason is arithmetic. The Swift job runs on a macOS runner, GitHub counts every macOS minute as ten minutes of the free allowance, and the fourteen App jobs that ran on 27 and 28 July (plus one cancelled run) total 197 rounded-up macOS minutes, which is 1,970 of the 2,000 free minutes the personal `PlayedItApp` account gets a month, spent in 26 hours. The next run had nothing left to draw on. No push, PR or merge has happened since, so the shortfall has not been noticed as a shortfall; it reads as a red check on one PR.

So on this repo speed and budget are the same currency, at a ten to one exchange rate. A typical PR waited 10 to 12 minutes (median App job 723 seconds, worst 35 minutes), and the whole wait is one `xcodebuild test` step: 20 to 55 seconds fetching packages, 80 to 390 seconds building (including a UI test runner that is never executed), then 6 to 26 minutes of "testing" for a suite whose bodies sum to one to eight minutes, most of which is a set of four tests calling a placeholder Supabase host over the network and waiting for it to fail. The Deno job beside it takes 11 to 18 seconds and is fine.

Nothing below weakens what is checked. One finding strengthens it (a set of tests that currently passes for the wrong reason). The two structural questions (whether the merge-commit run earns its cost, and whether a self-hosted Mac should replace the paid runner) are laid out with numbers rather than decided.

## Where the time actually goes (measured)

CI numbers are from the GitHub API and the job logs of every run the workflow has ever had: 16 runs between 2026-07-27 and 2026-07-28, of which 13 App jobs succeeded, one failed on a real test, one was cancelled by a newer push, and one was refused for billing. The phase boundaries inside the `xcodebuild` step come from log timestamps (package resolution, first and last build command) and from xcodebuild's own `Testing started completed` elapsed line, because the per-test output is buffered and every test line carries the same timestamp.

### One App (Swift) job (`macos-26`, GitHub's 3 or 4 core hosted Mac, the entire PR wait)

| Phase | Measured across 13 runs | Notes |
|---|---|---|
| Checkout, select Xcode, choose a simulator | 15 to 40s | the simulator is chosen but not booted here |
| Resolve Package Graph | 20 to 55s | nine packages fetched from GitHub on every run; `Package.resolved` is committed but nothing caches the checkouts |
| Build | 78 to 387s (typically 90 to 170s) | builds `PlayedItUITests-Runner.app` every run although the job runs only `PlayedItTests` |
| Testing phase | 336 to 1,548s (typically 370 to 650s) | simulator boot, one or two clones, install, then the tests |
| of which test bodies (summed) | 62 to 478s | 595 to 641 tests in 42 suites |
| of which `AppleAuthIntegrationTests` alone | 10 to 308s | four tests; see finding 3 |
| Write the result bundle | 12 to 30s | |
| Whole job | 565 to 2,110s, median 723s | billed as 10 to 36 minutes, times ten |

The testing phase minus the summed bodies is 175 to 1,070 seconds (median about 300), and the bodies overcount when two clones run in parallel, so at least four to seven minutes of every run is the simulator being booted, cloned and loaded rather than tests running. The two runs that used one clone were one of the fastest and one of the slowest, so the clone count alone does not explain the spread.

The per-test durations in the logs need a caution before anyone acts on them (L203). The three slowest tests in the median run were `test_toGame_nilMetacritic_propagatesNil` at 70.8 seconds, which constructs a struct and reads a nil field, `test_deleteComment_canDelete_ownerCanDelete` at 21.8 seconds, which evaluates one boolean, and a bias calculation at 9.7 seconds. In the next run none of those three appears in the top twenty, and a different set of trivial tests does. Those numbers measure a 3 or 4 core runner hosting xcodebuild, two simulator clones and the test process at once, not the tests. The one entry that is slow in every single run is `AppleAuthIntegrationTests`, and that is the only per-test signal this log supports.

### The Edge functions (Deno) job

11 to 18 seconds end to end, 98 tests in 274ms. Bills one Linux minute per run, which is the cheapest thing in the pipeline by a factor of a hundred and is left alone.

### The local gates

| Gate | Measured |
|---|---|
| Deno suite, `deno test` in `supabase/functions` | 98 tests, 274ms (2.4s wall) |
| Swift suite | not measurable on this Mac: `xcrun simctl list runtimes` is empty, so no iOS simulator is installed and the documented `xcodebuild test` command fails at "no iPhone simulator available" |
| Pre-push hooks in the repo | none; only the global test gate and style gate apply |

Two things about the local picture. The command CLAUDE.md documents (`xcodebuild test -scheme PlayedIt`) runs everything in the scheme: the 724 unit tests including the nine suites that talk to the live Supabase project, plus the 425 UI tests, which sign in with a real refresh token. That is the local gate, and it is also why the unit tests cannot be timed here in isolation without the runtime. And with the real `config.swift` in place, `AppleAuthIntegrationTests` sends malformed tokens to the production auth endpoint on every local run (L2), which is harmless to data but is a live call inside what is meant to be a unit suite.

### After the merge

There is no deploy pipeline. A push to `master` runs the same two jobs again on the merge commit, and nothing consumes the result: the repo has no branch protection or rulesets (the API answers "Upgrade to GitHub Pro" for rulesets and 404 for branch protection), no deploy reads the check, and no automation keys on the job names. Release is a manual App Store submission. So a merge costs the same 10 to 36 macOS minutes (100 to 360 of allowance) as the PR did, for a check nobody and nothing waits on. That is not automatically waste (a merge commit is a new commit, as the Slate audit says), but on this repo it is half of the bill, and the choice belongs in writing (finding 2).

### Volume and billed minutes

The billing API is not readable with this session's token (the repo is owned by the personal account `PlayedItApp`, not the Try-Pennie org, and the token belongs to a different account), so the allowance is computed from the jobs, each rounded up to the minute the way GitHub bills it, with the macOS multiplier applied: fourteen App jobs at 189 minutes, the cancelled run's App job at 8, times ten, is 1,970 allowance minutes, plus 15 Linux minutes for the Deno job: 1,985 of the 2,000 a Free personal account gets a month. The refusal on the next run is the confirmation. Whether the message's other clause (a failed payment) is also true is not something the repo can answer; the arithmetic alone explains it.

Put the other way round: at today's shape a PR costs about 250 allowance minutes (one PR run and one merge run, each about 12 macOS minutes), so the free allowance funds about eight PRs a month. July had seven PRs in two days.

## Findings, ranked by payoff

### 1. The budget is the finding, and there are three ways out of it

Every other finding in this section is worth ten times its wall-clock number, because that is the rate the macOS runner draws on the allowance. Before any of them, the shape of the account needs a decision, and all three options are cheaper than the current one, which is a CI that silently does not run.

1. **A self-hosted runner on one of the Macs.** Zero billed minutes, no allowance, and faster hardware than the 3 or 4 core hosted runner by a wide margin (the same build on an Apple Silicon Mac with a warm DerivedData is seconds, not minutes). GitHub's runner agent is a background service; the workflow changes from `runs-on: macos-26` to `runs-on: self-hosted`. The cost is that the Mac has to be on for CI to run, and that a self-hosted runner must never be used by a public repo (it is private, so this is a rule to write down rather than a risk today). This is the free option, and under the cost rule it is the default proposal.
2. **Pay for the hosted runner.** Set a spending limit. macOS is $0.062 a minute on the hosted runner (GitHub's published rate), so a 12 minute run is about 75 cents, and a PR with its merge run about $1.50. At the July rate that is roughly $12 to $45 a month depending on activity, for a runner that is slow and shared.
3. **Cut the run down so the free allowance goes further.** Findings 3 through 8. Together they take a run from about 12 minutes to about 6, which doubles the number of PRs the allowance funds (about 16), and dropping the merge run (finding 2) doubles it again.

Options 1 and 3 are not exclusive: everything in 3 also makes a self-hosted run faster. Option 2 is listed so the free one is a choice and not an assumption.

### 2. The merge-commit run gates nothing, and the workflow cancels it anyway

Both jobs run on every push to `master` as well as every PR. Nothing reads the result (no protection, no deploy, no automation), and the workflow's concurrency group cancels an in-progress run whenever a newer push arrives on the same ref, including `master`, so two merges inside a 12 minute window leave the first merge with no verdict at all (L98: a cancelled watcher reads the same as a clean one, and here it reads the same as one that never ran). Two choices, both defensible, and the current file has taken neither on purpose:

- **Keep the merge run as a signal on the merged commit**, in which case exclude `master` from `cancel-in-progress` so a verdict is always produced, and accept that it is half of the allowance.
- **Run only on pull requests**, which halves the bill with no change to what gates a merge, because nothing gates a merge today. The merged commit is then unverified only when a branch was behind `master` at merge time, which the PR run cannot see. If this is chosen, the CLAUDE.md sentence "Both suites run on every push" needs to change with it (L32).

This audit recommends the second while the runner is hosted, and revisiting if a self-hosted runner makes the merge run free.

### 3. Four tests spend 10 to 308 seconds per run waiting for a placeholder host to fail (and they pass for the wrong reason)

`AppleAuthIntegrationTests` calls `SupabaseManager.shared.signInWithApple` with a junk token and asserts the call returns false, sets an error message and resets `isLoading`. The file's own comment says why: "We can't inject a fake Supabase client without a protocol seam, so we test the state contract by examining what the real SupabaseManager exposes after each call." In CI the real manager is pointed at `https://example.supabase.co` with a placeholder key, so the call goes to the network and fails however the runner's network happens to fail that day: sometimes at once (10 to 30 seconds for the four tests), often after a timeout (100 to 308 seconds, in seven of the thirteen runs). It is the only test group that is slow in every run, and it is most of the summed test time whenever it is slow.

The coverage problem is the bigger one. The assertion is "returns false and sets an error", and an unreachable host satisfies it exactly as well as a rejected token does (L140: a test satisfied by any failure). CI has never once exercised the path these tests describe, a server rejecting a malformed token, because it cannot reach a server. Locally, with the real config, the tests do reach one: the production auth endpoint, with malformed tokens, on every run.

Fix, in two steps. First, move the suite into the same `-skip-testing` set as the other live-project suites, which is where the workflow's own rule already puts anything that "talks to a live Supabase project"; that saves 10 to 308 seconds of the testing phase (100 to 3,080 allowance minutes a month at the July rate) and stops a test that proves nothing from running. Second, and this is the strengthening, give `SupabaseManager` the protocol seam the comment asks for so the state contract can be tested against a fake client that throws, which tests the actual contract (error message set, loading reset, authentication unchanged) in milliseconds and without a network. The seam is the same design as Slate's injectable clocks (lesson 11): a decision that removes the tax for good.

### 4. Boot the simulator during the build, and measure whether the second clone helps or hurts

The "Choose a simulator" step resolves a device and stops. `xcodebuild` then builds for two to six minutes and only afterwards boots the simulator, clones it for parallel testing, installs the app and starts the runner, which is the four to seven minute gap between the last build command and the first test. Two bounded changes:

1. **Pre-boot in the step that chooses the device**: `xcrun simctl boot "$UDID"` followed by `xcrun simctl bootstatus "$UDID" -b` at the start of the test step. The boot then overlaps the build instead of following it. This is the same move as caching a browser download: the work still happens, but not on the critical path. Measure the gap before and after.
2. **Turn off parallel testing for the CI run** (`-parallel-testing-enabled NO`), as an experiment judged by the whole job time. Eleven of the thirteen runs cloned a second simulator on a 3 or 4 core runner; the two that did not landed at both ends of the range; and the trivial tests reporting 20 to 70 seconds are the signature of a machine starved by running two simulators and the build toolchain at once. Parallel testing is the right default on a 10-core Mac, and the test plan should keep it there; the question is only whether it pays on the hosted runner. If a self-hosted Mac is chosen in finding 1, this experiment is moot and should not be run.

### 5. Cache the package checkouts (20 to 55 seconds a run, free)

`Resolve Package Graph` fetches nine repositories (supabase-swift, swift-crypto, posthog-ios, plcrashreporter and their dependencies) from GitHub on every run. `Package.resolved` is committed, so the pins are exact; cache the `SourcePackages` directory under DerivedData keyed on its hash, with a restore-keys fallback, the same shape as every other cache in this document. Saves 20 to 55 wall seconds (200 to 550 allowance) per run. Risk to coverage: none; a changed pin changes the key.

### 6. The job compiles a UI test runner it never runs

`-only-testing:PlayedItTests` decides which tests execute, not which targets build: the scheme's test action lists both test targets, so every run compiles and signs `PlayedItUITests-Runner.app` (143 build lines in the log) for 425 UI tests the job never launches. Give CI its own test plan (or a second scheme) containing only `PlayedItTests`, and point the workflow at it with `-testPlan`. The saving is whatever share of the 78 to 387 second build the UI target is, which the build log can measure before and after; it is also the change that makes the CI command say what it does. Risk to coverage: none, the UI tests were not running.

### 7. No job has a timeout, and here a hang costs two months of allowance

Neither job carries `timeout-minutes`. GitHub's default is six hours, and six hours on a macOS runner is 3,600 allowance minutes, nearly twice the month's supply, from one hung simulator boot (a class that has already stalled the a11y job at Bidspoke and the Supabase CLI at Slate). Bidspoke's finding 10, Slate's finding 6 and NurseDex's finding 8, in the fifth repo; the difference is the multiplier. Set the App job to 40 minutes (the slowest measured run is 35, and that run was an outlier that should itself have been a signal) and the Deno job to 5, and add the directory-wide guard the other four repos are adding, which in this repo can be a Deno test beside the existing ones since there is no Node harness.

### 8. Scope the macOS job by changed paths, fail closed

The Swift tests read three trees: `PlayedIt/` (sources, plus the lint tests that scan them), `PlayedItTests/`, and `PlayedIt.xcodeproj/project.pbxproj` (the release-notes readiness test reads the marketing version from it). Nothing under `PlayedItTests/` reads `supabase/` or `site/`, and no Deno test reads Swift, which is the condition the other audits said a path filter must meet before it is safe. The macOS job can therefore skip, fail closed, when the change is provably confined to `supabase/**`, `site/**` and Markdown, and run in every other case including any change to `.github/`. Of the seven most recent PRs, one (#342, the open one, ten edge-function files and a doc) would have skipped both its PR and merge runs: 240 allowance minutes for that PR alone. The a11y job at Bidspoke is the pattern to copy, including the "cannot prove, so run" branch.

### 9. DerivedData cache for the build (bounded experiment)

The build is 78 to 387 seconds cold. Caching Xcode's DerivedData between runs is widely tried and unevenly rewarded, because the build system invalidates on more than file hashes; it is worth exactly one measured attempt keyed on the pbxproj, `Package.resolved` and a source hash, kept only if the warm build is materially shorter and the result is identical. If finding 1 lands on a self-hosted runner, DerivedData is warm by construction and this finding closes as unnecessary.

### 10. What the redundancy sweep found: clean, with one sleep and one local-only bucket

51 test classes, 724 test functions. Six titles appear in two files each, and every pair is the per-subject shape: three request-builder assertions shared by the Steam login and Steam match request tests (each asserts its own request), and three message-parsing assertions shared by the Apple link and delete account message tests (each asserts its own parser). Nothing mergeable without losing per-subject coverage. Same clean result as Slate, NurseDex and Bidspoke.

One real timer in the unit suite: `PendingImportRPCTests.test_fetchAny_multipleRows_returnsMostRecent` sleeps 1.1 seconds so two rows get different second-precision `updated_at` values. That suite is in the CI skip set, so it costs nothing in CI; when it runs locally the sleep could be replaced by seeding explicit timestamps, which also makes the test deterministic. Noted, not filed.

The UI test target is a separate story: 425 tests, never run in CI, containing 121 fixed `sleep(forTimeInterval:)` calls that total about 174 seconds if each runs once (37 of them are three seconds). That is PET's safe bucket, condition waits standing in for sleeps, but it only costs the person running the UI suite locally, and it is left out of the milestone: nothing here should encourage adding the UI suite to a runner billed at ten to one.

### 11. Eleven percent of the unit suite never runs anywhere but a developer's Mac

82 tests in nine suites, plus one individual test, are skipped in CI because they need the live project, which is issue #312's territory and a coverage fact rather than a speed one. It belongs in this audit for one reason: when #312 gives CI a test project, those 83 tests are network tests and will add real seconds at ten to one, so the CI-side design should reach for the same seam as finding 3 rather than a bigger allowance.

## Second pass (2026-08-29, later the same day): what lessons 20 to 31 caught

The section above was written against lessons 1 to 19. The four repos audited after it added twelve more, and re-reading PlayedIt against them changed one finding, added a task ahead of another, and widened one decision.

### Finding 2 is stronger than written: the merge run is provably redundant, so skip it on proof rather than on the trigger (lesson 22)

PostRoll's proof was applied here and it holds. The last six merges to `master` (#314 to #334) are all squash merges of a branch that was zero commits behind, and each merge commit's tree hash is identical to its pull request head's tree hash. The push-to-master run therefore re-tests, byte for byte, a tree the same workflow already passed on the PR. The first pass proposed dropping the push trigger, which loses the merge signal in the one case it matters (a branch merged while behind). The better shape is the one lesson 22 names: keep the push trigger, and have the App job skip when it can prove the pushed commit's tree hash equals the tree of a commit that already has a successful App job, and run otherwise (a behind branch, a rebase, a manual push, or any failure to prove). Same allowance saving (about half), no lost signal, and the `cancel-in-progress` question becomes moot for the runs that skip. The repo allows merge commits and rebases as well as squash, so the proof must be computed each time rather than assumed from the merge method. #348's body is amended.

### Finding 4 needs an executed-count readout before the parallel experiment, not after (lesson 29)

Overture turned parallel testing on and lost 3,720 of 8,595 tests behind a verdict naming twelve failures. PlayedIt's job has the same blind spot in the other direction: it runs with two simulator clones today, nothing records how many tests executed, and the count already drifts run to run for legitimate reasons (595 to 641 over two days as tests were added), so a clone whose share went missing would be invisible. Before toggling parallel testing either way, write the executed and expected counts to the job summary (`xcrun xcresulttool` over the result bundle, or the `Executed N tests` line) and fail the step when the executed count is below the previous run's. That is the instrument of lesson 9 for this experiment, and it is now the first task on #349.

### The per-test seconds were re-checked against Overture's reading of lesson 17 (cleared, with a caveat recorded)

Overture found that xcodebuild's parallel log format reports each test's seconds as elapsed since its worker started, which would make the first pass's table meaningless. PlayedIt's log is that format (`passed on 'Clone 1 of iPhone 17 Pro'`), so it was checked: the values here are not monotonic within a clone (0.008, 0.006, 0.004, 0.001 in sequence, then a 70 second outlier, then milliseconds again), so they are not elapsed-since-start. The starvation reading stands, and so does the one stable signal (`AppleAuthIntegrationTests`, whose four durations look like network timeouts and not like a clock). Overture's caveat still applies to anyone reading a different Xcode's parallel output, so it is recorded here rather than assumed away.

### Finding 1 has a fourth option (lesson 27)

PostRoll and Overture are public repositories, and on a public repository GitHub's hosted macOS minutes are free and unmetered, with the runner limit as the only budget. Making PlayedIt public would zero the allowance problem at a stroke. It is listed on #347 as an option with its caveat: this is a shipping commercial app whose secrets are already gitignored, but going public is a product and legal decision (source visibility, the moderation and auth code, the test seed data) before it is a CI one, and the audit does not recommend it, only refuses to leave it unnamed.

### Recorded premises checked (lesson 28)

`tests.yml` records its premises well where it has them: the Xcode pin names the failure that motivated it, the simulator lookup names why a hardcoded device is wrong, and the skip list names #312. The one decision with no premise at all is `runs-on: macos-26` itself, which is the line that costs ten to one and was never priced; #347 should leave a comment on that line saying what the runner costs and why it was chosen, so the next audit re-measures the premise instead of inheriting the line. The CLAUDE.md claim ("Both suites run on every push") is already on #346.

### Also checked and cleared

- Lessons 20, 21 and 26 (sharding, timing stores, count-sized sweeps): nothing here shards or deals work by count.
- Lesson 23 (guards of the gate): no repo-level hooks; the global gates are measured in the other sections.
- Lesson 24 (partial stubs running the rest for real): finding 3 is the instance, already filed.
- Lesson 25 (per-line scanners): `LogRedactionTests` scans the source tree in-process, one file read and one predicate per line, 2.5 seconds; `DesignTokenLintTests` walks the tree once per test, seven times, at about 0.1 seconds each. Lesson 30's memo shape would apply if either grew; at three seconds combined it is noted, not filed.
- Lesson 31 (the concurrency setting): both testables say `parallelizable = "YES"`, and the summed bodies (62 to 478s) sit well under the testing phase (336 to 1,548s), so the suite is not running on one core; the overhead is boot and clone, finding 4.

## What the WWT article's practices say about this suite

Same list as the other four (behavioural names, arrange-act-assert, isolated per-test setup, one behaviour per test, no logic in tests, self-explaining assertions, eliminate redundancy). The Swift suite follows them well: names are sentences ("a server error with no message still fails loudly", "the anon key is never sent as the caller's identity"), the guard tests carry a proof that they can fail (`testTheGuardCatchesAVersionWithNoEntryAtAll`), and the lint tests assert that they found source files before asserting anything about them. The one practice with a speed consequence, again, lands outside the tests: the redundancy is a UI runner built for nothing, a package graph fetched 16 times, and a merge run nobody reads. The one test-level exception is finding 3, which is the article's "a test must be able to fail" in its purest form: a test that cannot distinguish the failure it describes from a network being down.

## What was deliberately not proposed

- **Running the UI tests in CI.** 425 tests with about three minutes of fixed sleeps on a runner billed at ten to one is the fastest way to have no CI at all. They stay local until the runner is self-hosted, and then it is a coverage decision, not a speed one.
- **Trimming the unit suite or turning off test isolation.** The bodies are one to two minutes on a starved runner and would be seconds on a Mac; there is nothing to trim.
- **Skipping the Deno job by path.** It bills one Linux minute and finishes in 15 seconds.
- **Building in Release to skip debug work.** Changes what is tested.
- **Treating the per-test durations in the CI log as a list of slow tests.** They are a list of moments the runner was starved (the table above), and "fixing" `test_toGame_nilMetacritic_propagatesNil` would fix nothing. Only `AppleAuthIntegrationTests` is stable enough to act on.

## The picture after all of it

| Scenario | Today | After findings 3 to 8 | Plus finding 2 (merge run skipped on tree-hash proof) | Self-hosted runner (finding 1) |
|---|---|---|---|---|
| PR wait, hosted runner | ~12 min (median), 35 worst | ~6 to 7 min | ~6 to 7 min | minutes, on a warm Mac |
| Allowance minutes per PR (with its merge run) | ~250 | ~130 | ~65 | 0 |
| PRs the free allowance funds a month | ~8 | ~16 | ~30 | unbounded |
| Cost of a six-hour hang | 3,600 allowance minutes | 400 (finding 7) | 400 | 0 |
| State of CI | refused since 2026-07-28 | runs | runs | runs |

## Proposed milestone

One milestone, `Faster PR Testing` (filed 2026-08-29 as milestone 15: findings 1, 2, 4, 5, 6, 8, 9 and 10 as #347 to #354, finding 3 as #343 and finding 7 as #344, both filed earlier the same day and moved in). Finding 1 is a decision that should be made before the rest are sized.

1. Decide the runner: self-hosted Mac (recommended, free), a spending limit, or the free allowance made to stretch (p1, ci, cost, decision)
2. Skip the merge-commit run when its tree hash matches a tree the App job already passed, fail closed; see the second pass (p2, ci, cost)
3. Skip `AppleAuthIntegrationTests` in CI with the other live suites, then give `SupabaseManager` a client seam and test the state contract against a fake (p1, testing, ci; the first half is a one-line change)
4. Boot the simulator during the build, and measure parallel testing off on the hosted runner (p2, ci, experiment)
5. Cache the Swift package checkouts keyed on Package.resolved (p2, ci)
6. Give CI a test plan with only PlayedItTests so the UI runner is not built (p2, ci)
7. Give both jobs a timeout and guard the class across the workflow directory (p1, ci, reliability, cost)
8. Scope the macOS job by changed paths, fail closed (p2, ci, cost)
9. Experiment: DerivedData cache on the hosted runner, closed as unnecessary if the runner is self-hosted (p4, ci, experiment)
10. Replace the 1.1 second timestamp sleep in the pending-import RPC test with seeded timestamps (p4, testing)

Findings 3 (first half), 5, 7 and 8 are each a few lines of workflow and could land the same day, and together with 4 they are what gets a hosted run under seven minutes. Finding 1 is the one that changes everything else's arithmetic, so it comes first even though it is a conversation rather than a commit.

### Also caught

- The checkout at `~/Non-icloudDocuments/Apps/playeditapp` (the path CLAUDE.md lists for this project) is itself a git clone of the same remote with an older, flat layout, and the live repository is the `PlayedIt/` directory inside it. Tooling that keys on the listed path (the project check, the issue spool, hooks looking for `.github/workflows`) finds the stale outer clone first. Worth collapsing to one checkout at the listed path.
- CLAUDE.md's "Both suites run on every push via `.github/workflows/tests.yml`" has been untrue for a month (L244, L32); it becomes true again with finding 1, and finding 2 changes its wording either way.

---

# claude-config test speed audit (2026-08-29)

## The headline

This repo is the mirror image of the other five. The CI plumbing costs 5 to 8 seconds a run (checkout 2 to 5s, three guard steps at 0 to 1s each, no dependency install, no build, no browser), and the entire 3 to 3.7 minute wait is one test suite: `tests/test-claude-sync.sh`, 1,148 checks in 105 sections, which takes 181 to 219 seconds on the two-core runner while the other 41 suites finish beside it and wait. The runner (`run-all-tests.sh`) is already the parallel, timing-ordered, budgeted thing the other audits had to ask for, and the suite already splits itself into shards. So lesson 1 does not hold here: the tests are the time, and the pipeline is innocent.

That changes what the levers are. Nothing here is a cache, a split of serial steps, or a duplicate job. The time is inside one suite, and it goes to three measurable things: shards that are balanced by counting sections rather than timing them (the slowest of four shards carries 165 seconds of work against 76 in the lightest), seventeen sections that relaunch the whole suite as a subprocess 39 times at about 1.4 seconds of startup each, and about 90 seconds of real clock that the tool and the tests spend polling in one and two second steps for things that finished in milliseconds. The first is a pure speed fix with a known ideal (the same suite, time-balanced, is about 16 percent faster at two shards and about 28 percent faster at four). The other two make the tests stronger as well as faster.

**Today a push waits 3m08s to 3m44s for CI.** Findings 1 to 4 take the suite from about 209 to roughly 130 to 150 seconds on the runner without changing what is checked, and the full repo run on a Mac from 195 seconds to roughly 120. Splitting the suite across CI jobs (finding 6) would take the wait to about 70 seconds, but it doubles or triples the billed minutes on a Free personal account whose allowance this repo is already using about 40 percent of, so it is presented as a choice rather than a recommendation.

## Where the time actually goes (measured)

CI numbers are per-step timings from the GitHub API over the eight most recent green runs (188 to 224 seconds each). Local numbers were measured today on this Mac (14 cores).

### One CI run (a single job, `suite`, steps run one after another)

| Step | Typical | What is inside it |
|---|---|---|
| Set up job + checkout (full history) | 2 to 7s | fine as is; the full clone is 2 to 5s and the changed-section step needs the base commit |
| Record the environment | 0 to 1s | prints bash, git, rsync, jq, perl versions; does NOT print the core count (see also caught) |
| A read-only run of the tool | 0 to 1s | fine |
| No machine specific home path | 0 to 1s | fine |
| Every suite in the repo | 181 to 219s | 42 suites under a budget of 4 processes: two suites at once, two slots each. `test-claude-sync.sh` takes two shards and 198 to 218s; the other 41 sum to about 160s of serial time and run in the other slot, finishing long before |
| Each changed suite section, run on its own | 0s, or 4 to 58s | 0s on a push that does not touch the suite; measured at 4, 4, 14, 21, 26 and 58s on the eight pushes that did. Runs AFTER the full suite, serially |

Inside the long step, the runner prints `launch order from measured wall clock for 0 of 42 suite(s), file size for the rest` on every CI run: its timing store lives in `~/.cache` and nothing persists it between runs, so CI orders by file size every time. That happens to be right today (the sync suite is the largest file and launches first), and would silently go wrong the day a smaller file became the slowest suite.

### Inside `test-claude-sync.sh` (the whole wait)

| Measurement | Result |
|---|---|
| Serial, one shard, on this Mac | 473s (463s of section time across 105 sections; 21 sections take 0s, 12 take 9s or more) |
| Four shards (the Mac default), on this Mac | 179s |
| Two shards (what CI runs), section time per shard from the serial measurement | shard 1: 185s, shard 2: 276s |
| Four shards, the same | 76s, 165s, 115s, 105s |
| Time-balanced split of the same sections, two shards | 231s and 230s |
| Time-balanced split, four shards | 116s, 115s, 115s, 115s |
| One launch of the suite in coverage-only mode (what a nested run costs before its first section) | 1.43s |
| One launch in `SECTION_LIST` mode (parse only, no re-exec) | 0.27s |

The shard selector groups sections by their `# needs:` declarations and then deals groups round robin to the least loaded shard, where load is a COUNT of sections. The slowest five sections are 52, 38, 27, 27 and 24 seconds; the median is under 2. Round robin therefore stacks them by accident: at four shards one shard carries 165 seconds and the run ends at 179, when the same sections balanced by measured time would end near 120.

The slowest sections, from the serial run:

| Section | Serial time | What the time is |
|---|---|---|
| #151 a section is never run twice to satisfy a needs declaration | 52s | launches the real selector 20 times (2 + 4 + 6 + 8 shards, coverage-only), about 1.4s of startup each, plus the verdicts |
| #152 the deadline kills a run that STOPPED, not one that is merely slow | 38s | two nested runs: one that hangs until a 6 second stall timeout fires, and one that pauses 2 seconds in every section up to `apply is idempotent` to outlast an 8 second stall timeout; the watchdog itself polls every 2 seconds |
| #105 the suite can run ONE section, and what it needs | 27s | seven nested launches |
| #178 a pull runs the hook suite it just installed | 27s | about eight real `sync` and `pull` runs of the tool, each of which runs a stub runner and then waits for it in 2 second steps |
| #184 every receive path runs the suite it installed | 24s | the same shape across `sync`, `send` and `apply-only` |
| #166 a force-killed run's leftovers are cleared | 18s | fixtures started and confirmed by 1 second polls, two fixed `sleep 1` settles |
| #185 a passing pull says how much of the suite actually ran | 17s | the 2 second runner poll again |
| #32 only one suite run at a time | 14s | the tool's lock wait polls every 1 second |

### The local gates

There is no git pre-push hook in this repo (`core.hooksPath` unset, `.git/hooks` empty). The gate is `require-tests-before-push.sh`, a PreToolUse hook on the model's own `git push`, which checks that each change carries a test; it does not run the suite. A full local run is `bash payload/hooks/run-all-tests.sh`: 195 seconds today, all of it the sync suite (194s with four slots), against README's claim of 84 seconds for 38 suites measured 2026-08-21. The claim is stale by 2.3x: the repo has grown to 42 suites and the sync suite has grown with it. Nothing pins the README number (the #41 section pins DESIGN.md's figures to the code, not README's).

### After the push

Pushes go straight to main: 233 runs in the last 30 days, 186 of them pushes to main (32 cancelled by the concurrency group) and 47 on pull requests. The sync daemon on the other Mac pulls main when it changes, not when CI is green, and then runs the whole suite ITSELF on what it installed (bounded at 1,800 seconds, verdict recorded in `.hook-tests`). So "merge-to-live" here is seconds, and CI is a second opinion after the fact, the same shape NurseDex's Vercel deploy has (lesson 13). What actually waits on CI is a pull request (`block-red-merge` refuses `gh pr merge` until every check is green) and every session's "pushed and awaiting CI" close-out.

32 of the 233 runs were red (14 percent). 30 were real: each was followed within the hour by a push that changed the suite or the tool. One was a flake: run 33119513948 on 2026-08-27 failed `test-run-all-tests.sh` on "#144 a record that is not a number falls back to size, and does not fail the run", and the next push, which changed only LESSONS.md and its index, passed. Priced the way lesson 16 says: one full re-run, 3.5 minutes in both currencies.

### Volume and billed minutes

The repo is private on the personal account `danwright32`, which is a Free plan (the API refuses branch protection with "Upgrade to GitHub Pro", the Free-plan signature). The billing endpoint needs the `user` scope the CLI token does not carry, and I did not widen it. From the runs: about 200 completed runs a month at a 4 minute job (3m08s to 3m44s, rounded up the way GitHub bills) is roughly 800 of the 2,000 free minutes, shared with every other repo on that account. Nothing is paid today, so, as at NurseDex, wall clock ranks first and the allowance is the constraint on finding 6.

## Findings, ranked by payoff

### 1. Balance the shards by measured time, not by section count (biggest win, pure speed)

The suite already measures every section (`(section: N checks, Ns)`, #107) and the runner one level up already keeps a per-suite timing store and orders launches by it (#144). The shard selector does neither: it counts. Keep a per-section timing record (same design as the runner's: one small file per section keyed on the heading, outside the config directory), sort groups longest first, and deal each to the least loaded shard by seconds rather than by count. Fall back to the count when no record exists, and SAY which one ordered the run, exactly as the runner does. The measured ideal is 231/230 at two shards against 185/276 today (about 16 percent off the CI critical path, roughly 209s to 175s) and 116 each at four against 76/165/115/105 (179s to roughly 125s on a Mac). The `# needs:` grouping (#151) and the coverage pin (#137) are unchanged by this: the partition is the same shape, only the dealing order moves.

Two couplings. #151 measures that pinning dependents to their prerequisite's shard does not pile one shard up, using section counts as the measure; that check must move to seconds with the selector or it measures the wrong thing (L63). And CI has no timing store between runs (the `0 of 42` line above), so on the runner this falls back to counts unless the store is persisted with `actions/cache`; the same cache fixes the runner's own launch order. Risk to coverage: none.

### 2. Stop relaunching the whole suite to ask it a question (about 50 seconds)

Seventeen sections launch the suite as a subprocess, 39 launch sites in all, and each launch pays about 1.4 seconds before its first section (the temp copy re-exec from #121, the registry, the lock) against 0.27 seconds for a parse-only listing. #151 alone launches the real selector 20 times to read 20 coverage lines. That is lesson 15's shape (a harness that reruns the suite once per case pays the boot once per case). The fix is a coverage mode that returns before the prelude's fixture setup, and, for #151, one launch that prints every shard's selection for a given count instead of one per shard. The semantics the checks rely on (the REAL selector, every shard count from 2 to 8, a partition with nothing borrowed) survive unchanged, which is what those checks are for. Measure the 1.4s first: the split between the re-exec and the lock is not written down anywhere.

### 3. The tool polls a finished runner every two seconds (about 40 seconds of the suite, and a faster real pull)

`claude-sync` starts the hook suite runner in the background and waits for it with `sleep 2` in a loop (line 2951), and takes the sync lock with `sleep 1` polls (lines 426 and 456). In production a two second rounding on a 200 second suite is nothing. In the test suite, #178, #184 and #185 run about fifteen real pulls against a STUB runner that returns in milliseconds, so each pays up to 2 seconds for nothing: 68 seconds of section time between the three, most of it this. #32 pays the 1 second lock poll fourteen times. Poll at a tenth of a second (the deadline is still measured against the clock, L226, so nothing else changes), or make the interval a setting the suite can shorten. Lesson 11, in its polling form: the granularity of a wait is a seam, and it is chosen on day one.

### 4. The stall watchdog's own interval is not injectable (about 45 seconds)

#152 proves the deadline kills a STOPPED run and not a slow one by living through both: a 6 second stall, then a run that pauses 2 seconds in every section until it has outlasted an 8 second stall timeout. #31 (9s) and #163 do the same for the hard ceiling. The stall timeout is injectable (`SUITE_STALL_TIMEOUT`), but the watchdog polls every 2 seconds and the deliberate pause is a fixed `sleep 2`, so the smallest stall the test can stage is several seconds. Make the watchdog's interval and the test seam's pause the same injectable unit, and these sections stage the same stalls in tenths of a second. The assertions do not change (killed, "no progress", the section named, the ceiling not reached, the slow run not killed); only the clock they are staged on does.

### 5. Run the changed-section audit beside the suite, not after it (4 to 58 seconds on pushes that touch the suite)

`audit-changed-sections.sh` needs only the checkout and the base commit, and it runs as a step AFTER the 200 second suite. As a second job it runs in parallel and costs one more billed minute on the pushes where it has work (it is a no-op on the others, and a job-level `if` on the diff keeps those free). Lesson 3's shape, at the smallest scale in these six audits, and the only serial-step finding in this repo.

### 6. The choice: split the sync suite across CI jobs by shard (wall clock against allowance)

The suite already accepts `SUITE_SHARD=i/n` and prints a coverage line per shard, and #137's verdict already reads a directory of those lines and refuses a run whose shards did not partition the sections. That is everything a matrix job needs: N jobs each running one or two shards, uploading their coverage and result lines, and a fan-in job that runs the #137 verdict over all of them. After finding 1, two jobs of two shards would end near 110 seconds and four jobs of one shard near 70. The cost is billed minutes: today's 4 minute run becomes about 5 (two jobs) or 6 to 7 (four jobs plus fan-in), so 800 allowance minutes a month become roughly 1,000 or 1,400, on an account whose 2,000 is shared with every other private repo it holds. Nothing keys on the job name (`block-red-merge` reads whether ALL checks are green and the sync tool reads none, and a Free plan has no rulesets to hold a required-check name), so the rename is safe. Ranked last because it is the only finding that spends the second currency; the free ones come first, and the size of this one should be re-measured after they land.

### 7. The #144 flake in `test-run-all-tests.sh` (one re-run a month, so far)

One red run in 30 days was a flake, and it was in the runner's own suite: "a record that is not a number falls back to size, and does not fail the run" printed `exit=0 bigfile=2`, which is the launch order coming out different from what the check expected under a timing store holding one unreadable record. The check reads an ORDER off a run on a loaded two-core runner, and order is exactly what a starved machine perturbs (lesson 17). Read the check against what it actually asserts: if it asserts the runner's fallback DECISION, assert the line the runner prints about it rather than the order the suites happened to finish in.

### 8. Nothing guards the job timeout, and nothing prints the core count

The one job has `timeout-minutes: 20` above the suite's own 900 second deadline, and no test pins either the presence of the timeout or the ordering (the workflow comment says the 900 is "set there and not measured"). This repo has one workflow file, so the class cannot hide next door today, but lesson 14 is five for five on this and the guard is cheap: a check in the suite that every job in `.github/workflows/` carries a timeout, and that the job timeout exceeds the suite's own. Separately, the environment step prints five tool versions and not `nproc`, while the budget comment assumes two cores (L188: measure the value the plan rests on). One line.

### 9. README's timing claim is 2.3x stale, and unpinned

README says the whole repo ran in 84 seconds on 2026-08-21 (38 suites); it is 195 today (42 suites). The #41 section pins DESIGN.md's numbers to the code and leaves README's alone (L210). Either pin the README figure to the runner's own summary the way the DESIGN pins work, or replace the number with the command that measures it.

### 10. What the redundancy sweep found: clean

42 suites, 2,300 checks. No test title appears in more than one suite; the nearest thing to duplication is the deliberate one the workflow comments name (the home-path guard runs alone first and again inside the suite, on purpose). The 3,600 and 600 second `sleep`s in the suite are fixtures to be killed, not waits. The one-guard-per-invariant culture the other audits credit Slate with is the same here, and it licenses the same conclusion: all of the effort goes to the one suite's mechanics, none to trimming.

## What the WWT article's practices say about this suite

The practices read in the PET audit (behavioral names, isolated setup, one behavior per test, no logic in tests, eliminate redundancy) hold here to a degree the other repos do not reach: every check names the issue it guards and the failure it was written after, every section builds its own throwaway state, and the suite's own comments record why each guard exists. The one practice with a speed consequence is not redundancy but its neighbour, "hide irrelevant detail": the suite tests its own sharding, deadline and lock machinery by running itself, and that self-hosting is where a third of the time lives (findings 2 and 4). It is the right design (a fake selector would test nothing, L52), which is why the lever is the launch cost and the clock granularity rather than the tests.

## What was deliberately not proposed

- Path-filtering the workflow or scoping the suite to what changed. The workflow's own comment explains why (L88): the suite reads README, DESIGN.md and the whole tree, and a filter derived from where the code lives skips exactly the change that breaks it.
- Dropping the receiving Mac's post-pull suite run to make a pull faster. It is the only run that executes the config on the machine it was installed on (L3), and it already runs with the lock released.
- Running the 41 small suites in fewer processes, or raising `HOOK_TESTS_BUDGET` on the runner. They finish inside the sync suite's shadow either way; the budget comment already records that the deliberate oversubscription costs seconds.
- Replacing the self-hosted sections (the suite running itself) with a stubbed selector or a fake watchdog. That trades the one thing those sections prove (L52).
- Making `sleep 2` in the tool a longer interval to be safe. The wait is already against the clock (L226); the interval only decides how long a finished runner sits unnoticed.

## The picture after all of it

| Scenario | Today | After findings 1 to 5 | With finding 6 (two jobs) |
|---|---|---|---|
| Push or PR wait in CI | 3m08s to 3m44s | roughly 2m15s to 2m35s | roughly 1m50s |
| Full repo run on a Mac | 195s | roughly 120s | same |
| Sync suite, serial, on a Mac | 473s | roughly 340s | same |
| Allowance minutes per month | ~800 of 2,000 | ~600 (a 3 minute job rounds down) | ~1,000 |

## Proposed milestone

One milestone, `Faster PR Testing`, one issue per finding, priorities chosen by me (nothing here was reported by Dan):

1. Balance the sync suite's shards by measured section time, with a persisted record on CI (p2)
2. Answer coverage questions without relaunching the whole suite (p2)
3. Poll a finished hook suite runner and the sync lock in tenths of a second (p3)
4. Make the stall watchdog's interval and the test pause one injectable unit (p3)
5. Run the changed-section audit as its own job beside the suite (p3)
6. Decide whether to split the sync suite across CI jobs by shard (p3, a decision issue with both currencies priced)
7. Make the #144 fallback check assert the decision, not the finishing order (p2, the one measured flake)
8. Guard the workflow timeout and print the runner's core count (p3)
9. Correct and pin README's full-run timing claim (p3)

Finding 10 needs no issue. Findings 1 and 2 are the work; 3, 4 and 8 are small edits with a test each; 5 is a workflow edit; 6 is a decision; 7 and 9 are tidy-ups.

Filed 2026-08-29 as milestone 3, `Faster PR Testing` (https://github.com/danwright32/claude-config/milestone/3): findings 1 through 9 as #203 to #211 in that order.

## Second pass (2026-08-29, later the same day): what combined lessons 23 to 31 caught

The section above was re-read against the nine lessons the Downbeat, PostRoll and Overture audits added. Three things were missed, two of them where lesson 28 predicted (a recorded number whose premise expired while the number stayed), and one instrument is missing that lesson 29 says must exist before #203 changes how the suite is dealt out.

### 11. The job timeout is already below the suite's own ceiling, the reverse of what its comment promises (lessons 26, 28)

The workflow comment says the suite "kills itself at 900s" and that `timeout-minutes: 20` is "set well above it so it never fires first". The suite's ceiling is `SUITE_TIMEOUT=3600` with a 1,200 second stall timeout (#152 raised both, and DESIGN.md's table records the new values). So the 1,200 second job timeout sits BELOW the suite's ceiling and level with its stall timeout: on a genuinely hung run the platform kills the job first, and the section name the suite's deadline exists to print is never printed. Nothing in the first pass checked the ordering because the comment stated it. Folded into #210 with the fix: the guard must read the suite's ceiling from the suite file (the #41 pin already does) and assert the job timeout exceeds it.

### 12. The receive-path run is the one nobody times (lessons 23, 26)

Every pull that lands a hook runs the whole suite on the receiving Mac (the real gate after the fact, finding "After the push" above), and `.hook-tests` records outcome, time, exit status and suite counts, but no DURATION. The only statement of how long it takes is the comment beside the 1,800 second timeout: "measured between 220 and 400 seconds on this hardware". The suite grew from 38 to 42 suites in a week and measures 195 seconds here today; on the other Mac nothing writes the number at all. Lesson 26's shape exactly: the run grows towards a fixed deadline, nothing measures the distance, and the day it crosses, the failure reads as "the hook suite could NOT be completed here", which sends the reader to a hung suite rather than a slow one. Filed as #218: record the duration in the verdict, show it in `status`, and hold it to half the timeout with a check that says "no duration recorded" as its own outcome.

### 13. Six more recorded premises have expired (lesson 28)

Beyond README's 84 seconds (#211): the workflow's "two cores" (never printed), "roughly 7 seconds per changed section" (measured 4 to 58), and "900s" (now 3,600); the runner's own header, "38 suites in 84 seconds measured on 2026-08-21" (42 and 195); README's "87 sections" and "873 / 920 / 986 checks" (105 and 1,148); and DESIGN.md's #147 rejection, which rests on the 84 second figure and does not name it as a premise. #211 widened to cover the set, with the #41 pins as the pattern: derive the number, or replace it with the command that measures it.

### 14. No readout for a suite that finishes early with fewer checks (lesson 29)

The sync suite guards its own partial runs (#137, #146). For the other 41 suites the runner reads `SUITE-RESULT passed=N failed=M` exactly and fails a suite that leaves no line, which catches a suite that dies. It does not catch a suite that finishes honestly with FEWER checks (an empty fixture glob, a case table that lost a row): `12 passed, 0 failed` is green. #203 and #208 are about to change how the sync suite is dealt out, which lesson 29 names as the moment a partial run reports a verdict, and the 1,148 count that proves nothing was lost is a number in a log rather than a line the runner prints. Filed as #219: keep the last count beside the timing store and say on the suite's line when it drops.

### Checked and cleared

- Lesson 23 (the gate's own guards): the seven PreToolUse hooks that run on every command cost 0.22 seconds together on a plain command; the push judge is the only real gate cost and it carries a 120 second cap. The untimed gate is the receive path (finding 12).
- Lesson 24 (stubs some collaborators, runs the rest for real): every `launchctl` call site in the tool sits behind `SYNC_NO_LAUNCHCTL`, and every install call in the suite sets it. 65 of the 343 tool invocations in the suite carry no notify seam and `terminal-notifier` is installed on this Mac, so the three failure-flavoured sections holding the most of them were run with a counting notifier in place: zero notifications. Sampled rather than proved for all 65.
- Lesson 25 (a scanner that pays per line): 27,486 lines of shell in the repo; the pipefail scanner is one `grep` per file and took 1 second on CI, the home-path guard 0 to 1.
- Lesson 27 (runner slots): one Linux job per run on a plan with 20 concurrent jobs; the concurrency group cancels superseded runs (32 of 186 pushes last month).
- Lesson 30 (a derivation computed once per test): no whole-tree scan appears in the suite's top ten; the repeated work is the relaunch already filed as #204.
- Lesson 31 (the concurrency setting in the runner you actually use): the receive path launches the runner with no budget set, so it derives one from `sysctl` (present on the daemon's PATH, which the plist sets explicitly) capped at 8, and CI sets 4 by hand. The unmeasured half is the core count on the runner (#210).

Filed in this pass: #218 and #219 into the milestone; #210 and #211 widened by comment.


---

# Downbeat test speed audit (2026-08-29)

## The headline

Downbeat is the seventh repo and the first with no CI at all: there is no `.github/workflows` directory, GitHub bills nothing, and pull requests are not part of the flow (the last one merged in June, every one of the twelve most recent merged within seconds of opening, and the 462 commits of the last 30 days went to `main` directly). So "PR testing" here means the pre-push hook, `scripts/git-hooks/pre-push`, and its wait is priced in exactly one currency: the minutes a session spends watching it, about 450 times a month.

**The tests are innocent.** The unit suite ran 3,271 tests in 362 suites in 26.9 seconds, inside a 46 second `xcodebuild` run on an unchanged tree (56 seconds after touching one app source). **The wait is the hook's own self tests**: the 45 `scripts/test-*.sh` scripts that guard the gate, run one after another on every push before the suite memo is even consulted, measured at **402 seconds, 6.7 minutes**, on a 12 core M2 Max. The comment above that loop in the hook says "They take about a second." Three scripts account for 305 of those seconds, and each is slow for a reason that has nothing to do with what it checks: a machine wide `lsof`, a real `lsregister` dump eleven times over, and two processes spawned per line of shell in the tree. One of the three also failed once in three runs.

Nothing below weakens what is checked. Two findings strengthen it: a test that rewrites the live LaunchServices database on every push, and a slow scanner whose intermittent failure is currently thrown away with the push it blocked.

## Where the time actually goes (measured)

All numbers are from this Mac (Apple M2 Max, 12 cores, Xcode 26.6) on 2026-08-29. The self tests were timed one at a time in the order the hook runs them, once serially and again alone for the two outliers; the suite was run twice through `scripts/run-tests.sh` with its console log kept, once unchanged and once after touching one app source file. There is no CI to read from the GitHub API, and no billing to read.

### One push (the pre-push hook, everything serial)

| Stage | Measured | Notes |
|---|---|---|
| The 45 `scripts/test-*.sh` self tests, serially | **402s** | run on EVERY push, before the suite memo is consulted; the hook's comment says about a second |
| `report-awaiting-verification.sh` (asks GitHub) and `report-release-warnings.sh` | 1.0s | fine |
| Unit suite, when `.git/last-green-suite` does not remember this tree | 46 to 56s | `xcodebuild` warm build check plus launch 15 to 27s, then 27 to 29s of tests |
| Whole push, suite remembered | about 6.7 min | |
| Whole push, suite run | about 7.5 min | the suite is 11 percent of it |

### Inside the self tests (the whole wait)

| Script | Measured | What is inside it |
|---|---|---|
| `test-pipefail-short-circuit.sh` | 80s alone, **177s in the serial run, exit 1 that time** | a `sed` and a `grep` spawned per line for 17,353 lines of tracked shell (about 35,000 processes) |
| `test-sweep-temp-dirs.sh` | **70s** | three of its cases run `sweep-temp-dirs.sh --older-than-days`, and that path calls `lsof -w` over every process on the Mac, 20.7s and 25,388 rows each time; the fixture root holds a dozen files |
| `test-build-install.sh` | **58s** | eleven installer runs with every collaborator stubbed except `REGISTRATION_CLEANUP`, so each runs the real `clean-stale-app-registrations.sh --fix`, a 4.5s `lsregister -dump` and a real unregister pass |
| `test-google-calendar-lag.sh` | 22s | 1,260 lines of cases, with a fixed `sleep 2` and `sleep 1` |
| `test-override-isolation.sh` | 13.5s | re-runs the other harness scripts clean and once per override variable, itself a second copy of part of the loop |
| `test-run-tests-lock.sh` | 11.4s | three lock timeouts of `TEST_LOCK_TIMEOUT=2` against a fixed `sleep 2` poll, plus `sleep 1.1` for mtime granularity |
| `test-awaiting-verification.sh` | 11.3s | a hanging tracker staged against a fixed `sleep 1` poll |
| `test-check-temp-dir-leaks.sh` | 7.3s | drives `run-tests.sh` with a stubbed xcodebuild several times; a stubbed whole suite run costs 1.0s (two fingerprints plus two snapshots of 39,193 temp entries) |
| `test-update-downbeat.sh`, `test-green-suite.sh` | 6.9s, 6.0s | git clones and stubbed suite runs, fine |
| The other 35 | 15s together | 0.02 to 2.3s each |

### Inside the suite

Swift Testing under Xcode 26 prints a `passed after N seconds` line per test, and here those numbers are elapsed since the run started rather than the test's own cost: 3,211 of 3,267 tests report 0.5 seconds or more and the sum is 37,152 seconds inside a 27 second run. The `xcresult` carries the same numbers. So there is no per-test table to read (lesson 17, by a different route), and the sleeps had to be found by reading the sources instead. Under one second of real waiting was found: three 50ms coalescing windows in `OvertureExportReportingTests`, one 100ms phase in `CommitOrchestratorTests`, a 0.4s `Thread.sleep` standing in for a hung reader against a 50ms deadline in `QuestionnaireImportModelTests`, 2 to 5ms polls in the settle helpers, and a 60 second sleep in `CommitRunOwnershipTests` that is cancelled by the test itself. Every retry, poll and recheck in the app takes an injectable sleep (`FantasticalService`, `BuildFreshnessState`, `RepeatingChecks`, `CommitInFlightStatus`, `CalendarEventVerification`, `GoogleLoopbackListener`), which is Slate's design and is why the suite pays nothing for its retry tests (lesson 11, L524).

The suite log also shows `DownbeatUITests-Runner.app` being processed, linked, its Swift libraries copied and codesigned on every unit run, although the scheme marks that testable `skipped = "YES"`: a skipped testable is still built (PlayedIt finding 6, the macOS edition).

### The local gates, and the memo that already exists

`scripts/green-suite.sh` remembers a green suite against a hash of every file git can see plus the Xcode version, for a day, so a push against an unchanged tree skips the suite (#151). It works, it says so out loud, and the fingerprint costs 0.17s. Its limit is the shape of the tree: 78 of the last 200 commits touched nothing under `Downbeat/`, so the suite re-ran for a change the compiler never saw. Scoping the fingerprint by path is NOT safe here and is declined below: the identity guards (`RepositoryFiles.roots`) read the whole repository including `scripts/` and the docs, `DocumentedComponentsExistTests` reads `CLAUDE.md`, and `SpecIsMarkedHistoricalTests` reads `PRD.md`, so a filter derived from where the code lives would go blind to exactly the tests that read outside it (L88).

### After the push

There is no deploy pipeline and nothing on GitHub reads a push. The path to "live" is `Downbeat/build-install.sh` run by hand (a Release build, about three minutes, then a verified swap into `/Applications`), and the pre-push hook records `shipped-commit.json` so the running app can say when the installed copy is behind (#157, #422). So the consumer of the gate is the person, or the session, waiting at the terminal, and the whole audit is priced in that one currency (lesson 22): at 15 pushes a day the self tests alone are about 100 minutes of waiting a day.

## Findings, ranked by payoff

### 1. The self tests run one after another, and the wait is their sum (biggest win, pure speed)

Every one of the 45 scripts sandboxes itself (a `mktemp -d`, `TEST_LOCK_DIR`, stubbed commands through env seams), so they are independent by construction, and the hook runs them in a `while read` loop, serially, before anything else. A bounded pool of about the core count turns the 402 second sum into the slowest script. With findings 2 to 4 landed the serial sum is about 200 seconds and the bound is about 22 seconds (`test-google-calendar-lag.sh`). The refusals stay (a missing script, a non executable one, an empty list all still block), every failing script is named rather than only the first (L154), and `test-override-isolation.sh`'s re-entry guard has to keep working under the pool. Filed as #454.

### 2. The pipefail scanner spawns two processes per line of shell, and it failed once in three runs

`test-pipefail-short-circuit.sh` guards a real class of fault (#369, L183) and does it with an `offenders_in()` loop that runs `sed` and `grep` on each of the 17,353 lines of tracked shell: 80 seconds alone, 177 in the serial run. In that serial run it exited 1; alone it passed twice with "19 passed, 0 failed (68 of 68 shell files set pipefail)". The cause is not established (L203), and today it could not be: the hook shows `tail -20` of a failing self test and keeps nothing, so a push blocked by it is retried rather than diagnosed (L148), the same gap #418 closed for the suite. The fix is one pass per file with the identical rules, seen to fail on a planted offender before it is trusted (L1), and ten timed consecutive runs afterwards. Filed as #455; keeping the output is in #458.

### 3. The sweep test runs a machine wide `lsof` three times

`sweep-temp-dirs.sh` asks `lsof -w` about every process on the Mac to learn which candidates are open, and `test-sweep-temp-dirs.sh` runs that path three times against a fixture of a dozen files: 62 of its 70 seconds, measuring the machine rather than the sweep. An injectable lister (the same env seam style as `TEST_XCODEBUILD`) lets the test say which fixture files are held open, and adds the case the real `lsof` could never stage deterministically: an open candidate survives, a closed one goes, and the stub must be seen to change the outcome or the seam has replaced the check with an assumption (L52). The daily agent pays the same 20 seconds and is worth a separate measurement of a root scoped query. Filed as #456.

### 4. The installer's test rewrites the live LaunchServices database eleven times per push (strengthens)

`test-build-install.sh` stubs the build, `open`, `codesign`, the identity finder and the shipped recorder, but never `REGISTRATION_CLEANUP`, so each of its eleven installer runs calls the real `clean-stale-app-registrations.sh --fix`: a 4.5 second `lsregister -dump` (the 58 seconds) and an `lsregister -u` pass over your real registrations, from a test, on every push. A test has to be structurally unable to touch live state (L2). The fix stubs the cleanup and ASSERTS the installer called it with `--fix`, since the invariant #306 added is that the install runs it, and adds the case where the stub fails to prove `|| true` keeps the install going. `test-clean-stale-app-registrations.sh` (0.13s) keeps the cleanup itself covered against a recorded dump. Filed as #457.

### 5. Nothing bounds a self test or the suite run, and a hang says nothing

No deadline on any self test and none on `xcodebuild` itself (the lock has `TEST_LOCK_TIMEOUT`; the run does not). A stuck `lsof` against a Synology mount, which this Mac has, or a test host that never exits, hangs the push silently, and a hang is worse than a failure because it reads as slowness (L110). It is the timeout class from the other six repos in its seventh shape: no CI, so the hook is where the class lives. This Mac has no `timeout` binary, and `report-awaiting-verification.sh` already carries a hand rolled bounded wait to copy. A killed script is a distinct message from a failed one (L11), and the full output of either is kept under `.git/` beside `last-red-suite.log`. Filed as #458.

### 6. The hook's own timing claim is a comment, and nobody re-measures a comment

"They take about a second" has stood since #190 while three scripts each grew past a minute, unseen, because the only timing anyone saw was the whole push. The instrument comes before the structure change (lesson 9): print each script's wall time and a total on every push, replace the comment with the measured number and its date (L32, L210), and consider a soft ceiling that names a script over some seconds without adding a new way to block. Filed as #459.

### 7. Two polls with fixed intervals, staged with fixed timeouts (about 15 seconds)

`run-tests.sh` polls the lock with a fixed `sleep 2` and `report-awaiting-verification.sh` polls its tracker with a fixed `sleep 1`, so their tests stage three lock timeouts and a hanging tracker in whole seconds: 11.4 and 11.3 seconds. A poll interval is a sleep with a condition attached and its granularity is the seam (lesson 11, L524): an env seam on the interval, defaulting to today's value, lets the same timeouts be staged in tenths of a second with the assertions unchanged. `test-google-calendar-lag.sh` has a `sleep 2` and `sleep 1` of the same kind. Ranked p3 because the parallel run makes the sum matter less. Filed as #460.

### 8. The unit run builds the UI test runner it skips (bounded experiment)

The scheme's test action lists `DownbeatUITests` with `skipped = "YES"`, and the log shows the runner linked, its libraries copied and signed on every run anyway. The UI tests already have their own `Downbeat UI Tests` scheme, which is the route they are run by. Measure the runner's share of the 15 to 27 second build and launch phase from the log timestamps, then drop it from the unit scheme's test action or give the unit run a test plan, and keep the change only if the saving is real. Risk to coverage: none, those tests were not executing. Filed as #461.

### 9. What the redundancy sweep found: clean

307 test files, 3,271 tests. Eight function titles repeat across files and every pair is the per subject shape (`runningTwiceChangesNothingTheSecondTime` four times, each about a different idempotent operation; the four pane budget titles shared by two Settings panes). Nothing mergeable without losing a subject. Same clean result as Slate, NurseDex, Bidspoke and PlayedIt.

## Second pass (2026-08-29): what the new combined lessons caught

Run after lessons 26 to 31 were written from PostRoll and Overture, and after milestone 16 had landed (#454 to #459 and #462 closed the same afternoon: the self tests measured at **76 seconds concurrent** against the 402 serial, the sweep test 70s to 23s, the installer test 58s to 8s, the pipefail scanner 80s to 2s, with a 300 second per script deadline and a slowest-script readout on every push). The 22 second parallel figure in the picture below was an estimate; 76 is the measurement, and what bounds it is now the next question rather than this one.

### 10. Twenty-four suites re-walk the repository once per test (lesson 30, 40 percent of the suite)

`RepositoryFiles.swiftFiles()` and `textFiles()` are plain functions, so every test that reads the tree walks and reads it again: the cooperative pool detector, the identity and reserved-name guards, the documented-components check, the addressable-controls and layout-budget suites, 24 suites and 206 tests in all. Measured in one filtered run: **10.9 seconds for those 206 tests**, 40 percent of the 27 second suite for 6 percent of its tests. It is Overture's copy inventory at a smaller scale, and the fix is the same one line: a memo on the no-argument form, with the callers that inject their own root left building (`RepositoryFilesScopeTests` tests the walker), and a memo that cannot capture an empty scan, since a memoised empty result passes every guard at once (L98). Filed as #470.

### 11. Nothing reads how many tests ran, and a filtered run that ran none exits 0 (lesson 29)

The hook asks whether at least one test ran; `run-tests.sh` asks nothing. This pass produced the case by accident: a filtered run whose identifiers matched nothing printed `Executed 0 tests` twice and returned success, and the leak check said it judged nothing, which was the only sentence that noticed. The green memo records a pass with no count, so a scheme or toolchain change that silently drops a target would be remembered as green with fewer tests than the day before and nothing would say so. Filed as #471: print the executed count on every run, make an empty filtered run its own non-zero exit, and refuse to remember a pass whose count fell unless the tree removed tests.

### 12. The gate still prices the suite at three minutes, in six places (lesson 28)

`pre-push` (four times, including the message "This takes a couple of minutes"), `run-tests.sh` and `green-suite.sh` all carry the premise the #151 memo was justified on. Measured today: 46 seconds unchanged, 56 after a touch. The memo stands either way, but a premise that has expired goes on being cited, exactly as the "about a second" line was (finding 6). Filed as #472 at p3: measured, dated numbers, and the run's wall time printed so the number is re-measured rather than remembered.

### Cleared

- **Lesson 31** (the suite's concurrency setting): the scheme's testable carries no `parallelizable` attribute, Swift Testing runs in parallel by default under it, and the log shows every test started before the first finished. 3,271 tests in 27 seconds is that parallelism.
- **Lesson 26** (a sweep sized by count under a deadline): the new 300 second deadline sits about thirteen times above the slowest guard after the fixes (23s), and the slowest is now printed on every push, which is the distance measurement the lesson asks for. Worth re-reading if a guard is added that scans the tree.
- **Lesson 27** (runner slots): no runners here.

## What the WWT article's practices say about this suite

Same list as the other six. The Swift suite follows them closely: names are sentences, guards carry a proof they can fail, an empty input is a reported problem rather than a pass (`L98` appears in the suite's own comments), and the sleeps that exist are seams. The practice with a speed consequence again lands outside the tests, and this time outside the suite entirely: the redundancy is in the gate's own gate, three self tests that each measure the whole machine to check a dozen fixture files.

## What was deliberately not proposed

- **Scoping the green suite memo by path** so docs and script only pushes skip the suite (39 percent of recent commits). The identity guards and two documentation tests read the whole repository, so a path filter derived from where the code lives would exempt exactly those tests, and the honest version (a filter derived from every file the suite reads) is the whole tree. The memo stays as it is.
- **Running the self tests only when `scripts/` changed.** They read `CLAUDE.md`, the project file, the tree's shell files and, for the status claims check, GitHub, so a path key would go blind to their inputs the same way. The parallel run makes the question moot at about 22 seconds.
- **Trimming the unit suite, turning off parallel testing, or removing any self test.** The suite is 27 seconds and the self tests each guard a fault this repository has actually had.
- **Skipping `test-override-isolation.sh`'s re-run of the harnesses.** It is the check that an escape hatch left set in the environment cannot change a harness's answer (#433); 13.5 seconds is its cost and the pool absorbs it.
- **Adding CI.** Nothing here needs a runner: the suite is fast, the gate is versioned, and a hosted macOS minute is billed at ten to one (PlayedIt).

## The picture after all of it

| Scenario | Today | After findings 2, 3, 4 (serial) | Plus finding 1 (parallel) |
|---|---|---|---|
| Self tests per push | 402s | about 200s | 76s measured after #454 landed (22s was the estimate) |
| Push wait, suite remembered | about 6.7 min | about 3.3 min | about 25s |
| Push wait, suite run | about 7.5 min | about 4.2 min | about 75s |
| Live LaunchServices writes per push | 11 | 0 | 0 |
| A hung self test | hangs the push, silently | same | named and killed (finding 5) |
| Waiting per day at 15 pushes | about 100 min | about 50 min | about 6 min |

## Proposed milestone

One milestone, `Faster PR Testing` (filed 2026-08-29 as milestone 16, findings 1 to 8 as #454 to #461, all eight landed the same day; the second pass added #470 to #472, and the review that followed the first pass added #462, a guard for the class behind finding 4). Finding 9 needed no issue.

1. Run the hook's self tests side by side instead of one after another (p1, tooling, tests, performance) #454
2. Rewrite the pipefail scanner as one pass per file and catch its intermittent failure (p1, tooling, tests, reliability, performance) #455
3. Inject the open files lister into `sweep-temp-dirs` so its test never runs a machine wide `lsof` (p1, tooling, tests, performance) #456
4. Stub the registration cleanup in the installer's test so a push stops rewriting live LaunchServices records (p1, tooling, tests, data-safety, build-install) #457
5. Give every self test and the suite run in the hook a deadline and keep a failing script's output (p2, tooling, reliability, observability) #458
6. Print each self test's duration on every push so the next slow one is visible (p2, tooling, observability, tests) #459
7. Make the lock poll and the verification poll injectable so their tests stage waits in tenths of a second (p3, tooling, tests, performance) #460
8. Measure what building the skipped UI test runner costs a unit run and stop building it if it pays (p3, tooling, tests, performance) #461

Findings 3 and 4 are each an env seam and a stub and could land the same day; 6 should land before 1 so the parallel run has numbers to be judged by; 2 is the one that needs to be seen to fail before it is trusted.

### Also caught

- `test-pipefail-short-circuit.sh` failing once in three runs is recorded here as unexplained rather than as a flake to retry. Nothing in the hook keeps the output that would explain it, which is the half of #458 that is not about speed.
- The per test durations Swift Testing prints under Xcode 26 are unusable as a cost table on this project, and the `xcresult` repeats them. Anyone reading `passed after` lines to find slow tests here will find the run order instead.

---

# PostRoll test speed audit (2026-08-29)

## The headline

PostRoll is the eighth repo, and the first where the wait is neither the tests nor the pipeline's own steps but a queue outside both. **A pull request waits a median of 18.6 minutes for its checks, and one in ten waits 35.** The Swift job that is the critical path takes 11 minutes when it starts; the rest of the median is spent waiting for a macOS runner to become free. GitHub gives a Free personal account five macOS runners at a time, this repository launches six macOS jobs on every pull request and ten on every merge, and last week it had 52 pull request runs and 33 merges in six days. During 933 of the 1,504 minutes in which anything was running, all five runners were busy, and something was queued for 877 of them.

What fills the runners is mostly a job nobody waits on: the post-merge guard proof sweep, four runners for about 23 minutes on every merge, is 51% of all macOS runner time and held 48% of the runners while other jobs queued. The next largest share is a pair of runs that deliberately render the same reels twice, which the workflow comments price at "about 200 seconds of wall clock and nothing else" on the grounds that the runners are free. They are free in money. They are not free in runners, and the runner is the budget here.

The tests themselves are in good shape. The Python suite runs in 121 seconds on this Mac and 192 on the Linux runner, with its slowest tests doing real rendering, every retry delay patched out, and its per-file costs measured and recorded. The Swift suite's 2,546 tests take 257 seconds of test bodies on this Mac and 417 on the runner, and the reason the runner's three cores do not help is that the suite runs one test at a time, which is the largest test-level lever in the repo. Nothing below weakens what is checked; one finding strengthens it (a set of tests that waits on the clock instead of setting it), and one re-judges a recorded decision on arithmetic that has changed under it.

## Where the time actually goes (measured)

Every CI number is from the GitHub API for all 300 runs since 2026-08-22 (861 jobs, per step). Queue is the time from the run being created to the job starting; the runner's own five-way limit is what fills it. Local timings were measured today on this Mac (12 cores).

### One pull request (three workflows, seven jobs, six of them on macOS)

| Job | Runs when started | Queue, median / p90 / worst | Inside it |
|---|---|---|---|
| Tests / python (Linux) | 213s | 3s / 6s / 21s | pip 6s, ffmpeg 7s, ruff 1s, pytest 192s (2,274 tests, 4 cores) |
| Tests / macos | 502s | 21s / 958s / 1,377s | pip 5s, ffmpeg 7s, pytest 480s (the same suite plus the 31 font-gated reel tests Linux skips) |
| macOS / swift-unit | 644s | 46s / 940s / 1,983s | xcodegen 4s, cache restore 8s, Release build 112s, test scheme 472s, GUI test compile 38s, cache save 8 to 16s |
| macOS / reference-frames, three shards | 123s to 159s each | 134s to 183s / 1,200s to 1,556s / 2,250s | pip 5s, ffmpeg 7s, pytest 98s to 137s |
| Guard proofs / changed | 154s, p90 450s, worst 1,511s | 128s / 938s / 2,074s | xcodegen, pip, ffmpeg 15s, then one rebuild per guard the diff touches |

The wall clock a pull request actually waited, taking the slowest job's queue plus its run across the 43 complete runs: median 1,118 seconds (18.6 minutes), p90 2,099 (35 minutes), best 599 (10 minutes). The critical path was swift-unit in 29 of the 43, the macOS Python leg in 6, the guard job in 4 and a reference-frame shard in 4. Almost half of all macOS jobs on pull requests (46%) waited more than a minute for a runner.

### Inside the Swift job (the critical path when the queue is empty)

From the log of a run with an exact build-cache hit (run 33272151437):

| Phase | Measured | Notes |
|---|---|---|
| Checkout, Xcode select, xcodegen, cache restore | 19s | |
| Build the app, Release | 122s | compiles every source for TWO architectures, arm64 and x86_64 |
| Test scheme: compile Debug and link | 52s | arm64 only |
| Test scheme: run 2,546 tests | 418s | one at a time; the suite is not parallelised |
| Compile the GUI tests without running them | 38s | #874 |
| Prune and save the cache | 16s | |

The five slowest tests are 136 seconds of the 418: one unseen-surface check at 44 seconds, three banner legibility checks at 74 seconds between them, and one build-freshness check at 18 seconds. The legibility checks render real surfaces and are the work. The build-freshness file is different: its seven tests sleep 2.05 seconds between git commits so the commits get different second-resolution timestamps, 23.6 seconds of a 26 second file, on the runner and on this Mac alike.

Locally the same suite is 257 seconds of test bodies against 417 on the runner, a ratio of 1.6, and the local Mac has four times the cores. That is the signature of a serial suite: the runner's cores are idle while the tests run one after another.

### One merge to main (four workflows, eleven jobs, ten of them on macOS)

| Job | Runs when started | Queue, median / p90 | Who reads it |
|---|---|---|---|
| Tests / python and macos, macOS / swift-unit and three reference-frame shards | the same as above | 4s to 482s / 794s to 1,296s | nobody: the tree is identical to the pull request's (below) |
| Guard proofs / full, four shards | 1,274s to 1,391s median, 1,747s worst, against an 1,800s deadline | 159s to 242s / 639s to 883s | a warning annotation on the next sweep if it stops running |
| GUI / ui | 421s | 4s / 500s | the only thing in the repo that runs the app's entry point (#867); it reports, it does not gate |
| GUI / hand-check-reminder (Linux) | 6s | | the job summary |

Every one of the 60 most recent commits on main is a squash merge made by `tools/wait_for_checks.py --merge`, which refuses a head that does not contain main (exit code 6) and merges the exact commit it judged. A squash of a head that contains its base produces the head's tree byte for byte. So the Tests and macOS workflows on a push to main re-run, on an identical tree, the checks that just went green on the pull request: about 27 macOS runner-minutes per merge, 33 times last week, for no new information. The guard sweep and the GUI job are different: neither runs on the pull request, so on the merge they are the first run, not the second.

### Volume and the two currencies, plus a third

The repository is public, on a personal account. Standard hosted runners cost nothing on a public repository and draw on no allowance, so the money column is zero and the 10x macOS multiplier that PlayedIt paid is, as swift.yml's own comment says, dormant rather than gone. Counted anyway, so the multiplier has a number to apply to the day the repo goes private: 5,753 macOS runner-minutes and 352 Linux minutes in the week, 29 macOS minutes per pull request run and 123 per merge.

The currency that does bite is the runner limit. GitHub's concurrency limit for a Free plan is 20 jobs, of which 5 may be macOS, and it is the limit in practice, not only on paper: in 524 of the 877 minutes in which one of this repo's jobs was queued, exactly five of its own jobs were running. Who held the five while others waited:

| Job | Share of runner-minutes held while something queued |
|---|---|
| Guard proofs / full (post-merge sweep) | 48% |
| macOS / reference-frames (three shards) | 16% |
| macOS / swift-unit | 14% |
| Tests / macos | 12% |
| GUI / ui | 6% |
| Guard proofs / changed | 4% |

### The local gates

| Gate | Measured |
|---|---|
| `make test-python`, full suite, 12 cores | 121s (3,327 tests under `--dist worksteal`, #783) |
| `make test-python-fast` | 35s |
| `make test-swift`, warm cache | about 5 minutes: 257s of test bodies plus the build |
| `make test` | the two above, in sequence by design (each wants the whole machine) |
| `build-install.sh` before an install | the Swift suite, then the fast Python subset |
| `.githooks/pre-push` | an iCloud duplicate check, under a second |
| Global test gate model judge | up to 90s, only when source changed |

Healthy. The Python suite's expensive files are measured, recorded and derived into the fast subset rather than guessed (`tests/file_durations.py`), which is the shape three other audits had to recommend.

## Findings, ranked by payoff

### 1. The post-merge guard sweep is half of all runner time, nothing waits on it, and it is running into its own deadline

`guards.yml`'s `full` job re-proves every one of the 433 registered guards on every push to main, across four shards of about 99 to 108 entries. Each shard runs 21 to 29 minutes (275 of the entries are Swift, and each of those pays an xcodebuild rebuild of about 13 to 29 seconds; the measured dead ends for making that cheaper are recorded in the file and are not re-derived here). Four runners for that long, 33 times a week, is 2,938 of 5,753 macOS runner-minutes, and 8 of the 33 sweeps started while the previous one was still running, so on a busy afternoon the sweep alone can hold the whole pool.

It is also failing on its own terms. Four shards in the week went red at the 1,800 second deadline, one of them with 48 of 99 entries "never reached before the deadline, so they are UNPROVEN". The shard medians are 1,264 to 1,391 seconds and the p90 is about 1,500, so the sweep has grown to within a few entries of its own ceiling, and every guard added moves it closer. The file's comment says the schedule is "the SECOND cadence and not the only one, with the merge sweep still the cadence that gates". The merge sweep gates nothing: it runs after the merge, nothing reads its result but a warning annotation, and the entries a merge actually touched were already proved on the pull request by the `changed` job.

Fix, two parts. First, cadence: run the full sweep once a day on any day main moved (a daily schedule that exits early when no push has landed since the last sweep, or a push-triggered job under a `concurrency` group keyed on the branch with `cancel-in-progress`, so a newer merge supersedes an older sweep rather than queueing behind it; the second is smaller but leaves a superseded sweep with no verdict, which `check_guard_sweep_freshness.py` would need to read as superseded rather than absent, L98). Last week that is 6 sweeps instead of 33, and the weekly schedule and `workflow_dispatch` stay. Second, size: shard by measured entry time rather than by count (lesson 20), and hold the shard's expected time to a fraction of the deadline with a test, so the sweep cannot again drift to within one entry of red. Risk to coverage: a guard weakened by a change OUTSIDE its own entry's files (the case only the full sweep catches) is found within a day instead of within 25 minutes of the merge, on a signal nobody was reading at 25 minutes either. The `changed` job on every pull request is unchanged.

### 2. Every merge re-runs the pull request's checks on an identical tree

Above: 27 macOS runner-minutes and 3.5 Linux minutes per merge, on the Tests and macOS workflows, for a tree the merge tool has just proved is the one the pull request went green on. Bidspoke's finding 7 and PlayedIt's finding 2, except that here the argument is exact rather than probable, because the merge tool refuses a stale base by construction (#680).

Fix, fail closed: a first step in each of those jobs that asks whether this push's tree (`git rev-parse HEAD^{tree}`) equals the tree of a pull request head whose expected checks all succeeded (the commit-to-pulls association, then the check runs on that head), and skips the job's remaining steps when it can prove that. Anything it cannot prove (no associated pull request, an empty answer from the association index, L119, a check missing or not green) runs the job exactly as today. As steps inside the existing jobs rather than a new gate job, deliberately: `tools/wait_for_checks.py` derives the checks a pull request must carry from these workflow files and calibrates the set against a recorded green reply, so a new job name costs a knowingly red merge (this repo's own rule, recorded in swift.yml and ui.yml), and a step adds no name. Bidspoke's a11y job is the shape. The guard sweep and the GUI job keep running on every merge; they are first runs. Risk to coverage: none when the proof succeeds, since the tree is identical; the failure direction is a job that runs when it could have skipped.

### 3. The Swift build cache restores on every run and saves nothing

`swift-unit` restores a DerivedData cache keyed on the toolchain plus a hash of every Swift file, saves it on every miss, and prunes and measures it. On the 16 most recent runs, all 16 restored a cache (14 by prefix, 2 exact hits on identical sources), and all 16 compiled every source unit: 525 to 528 compile invocations in the test scheme every time, and the Release build compiled both architectures from scratch, exact hit included (122 seconds on the exact hit, 84 to 181 across the sixteen). Whatever the cache saved when #412 added it, it saves nothing now: xcodebuild is not treating the restored folder as its own, most likely because `xcodegen generate` rewrites the project before the restore and the build system keys on the project it made, or because the restore does not preserve what the build database checks.

It is not free either. Restore, prune and save are 16 to 32 seconds of every run, and the repository holds 58 copies of it at 276 MB each: 16.0 of 16.9 GB of caches against GitHub's 10 GB limit, so the oldest entries are evicted continuously, and the pip and ffmpeg caches that DO work are the ones at risk (the file's own comment names this exact failure, for a cache over the cap it declines to upload; it did not foresee 58 under it). Fix: one measured run with the cache steps removed against one with them, keep whichever is faster, and if the cache is kept, make it actually hit (restore before generating the project, and a test that the number of compile invocations on an exact-hit run is near zero). Either way, delete the 58 entries and cap what is stored. Risk to coverage: none; the cache changes nothing about what is compiled or tested.

### 4. The Swift suite runs one test at a time on a three-core runner (the largest test-level lever)

418 seconds of the critical path is 2,546 tests run serially. The `PostRollTests` scheme sets no parallel execution, so XCTest runs one test at a time in one process while two of the runner's three cores idle; the local ratio confirms it (257 seconds on twelve cores against 417 on three, for a serial suite). XCTest's parallel mode runs test classes across several processes, and on three cores the ceiling for a suite this shape is roughly the sum of its heaviest class (the legibility checks, about 90 seconds) against a third of the rest, so 418 seconds could become about 150 to 200.

This is an experiment rather than a change, because parallel execution changes what a test can rely on: any two classes that share a file on disk, a process-wide singleton, `UserDefaults` or the keychain can pass serially and fail or, worse, pass for the wrong reason side by side. The suite already has the instrument for the first kind (a test that goes red is loud); the second kind needs one measured run under randomised class order before the switch is trusted (lesson 9: structure changes ride on instruments). Set `parallelizable` on the test target in `project.yml`, pass `-parallel-testing-worker-count` sized to the runner, judge by the whole job time, and keep the local `make test-swift` on the same setting so the two cannot disagree (L41). Risk to coverage: none if the randomised run is clean; a hidden shared-state dependency is a defect the change exposes rather than creates.

### 5. The Release build compiles an architecture nobody runs

The "Build the app" step builds Release, and Release builds universal (arm64 and x86_64) by default; the log shows every source compiled twice. Nothing in `PostRollApp/Sources` or the tests is architecture-specific (no `#if arch` anywhere), the Swift diagnostics that this build exists to catch (#485, #521) are the same for both slices, and the x86_64 slice runs on no machine this app is installed on. `ONLY_ACTIVE_ARCH=YES` on the CI build alone halves the step, about 60 of 122 seconds, with the local `make build` and the shipped bundle untouched. Risk to coverage: none today, and a source guard that fails the day an `#if arch` appears in the tree keeps it that way (L96: the exemption needs a reviewer).

### 6. Seven tests sleep two seconds each to make git's clock move

`BuildFreshnessScopeTests.sleepOneSecond()` sleeps 2.05 seconds between commits so that two commits get different whole-second timestamps, and its own comment records that one second was not enough. 23.6 seconds of a 26 second file, on every run, local and CI. The fixture can set the commit's time instead of waiting for it (`GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` on each commit), which is deterministic, takes no time, and is the stronger test: it pins both ends of the comparison rather than one (L130, L134). Lesson 11 in its git form. Saves about 23 seconds of the critical path. Risk to coverage: none; the assertions do not change.

### 7. The reel suite renders twice per event, and the premise that priced it has changed

`tests.yml`'s `macos` job runs the whole Python suite on a Mac, and `swift.yml`'s three `reference-frames` shards render the same font-gated reel files on the same image. Both files record that this is deliberate (#571): the shards exist so `-n auto` can use more than one runner's three cores, and the Mac leg exists so it runs the SAME command as Linux, which two earlier attempts at narrowing broke. Both files price it identically: "The runners are free on a public repo, so the second run costs about 200s of wall clock and nothing else."

That sentence was true of the money and is not true of the runners. Under the five-way limit those two jobs held 28% of the runners while other jobs queued (16% shards, 12% Mac leg), and the Mac leg is 8.5 minutes in one slot on every pull request and every merge. Dan's decision on 2026-08-29, reading the arithmetic: remove the duplicate render. The shape that keeps every property the two earlier attempts lost: the Mac leg deselects exactly the files the reference-frame matrix already names (`tests/ci_workflow.py` reads that matrix today, so the list is derived and cannot drift, L41), and a guard holds that every font-gated file is in exactly one of the two, which `tests/test_ci_runs_the_font_dependent_checks.py` already does for the shards. The Mac leg still runs everything else on a Mac, still records its ffmpeg version, still runs on pull requests, and drops from about 8.5 minutes to about 3, freeing a runner for 5.5 minutes on every event. The shards keep rendering the reels with fonts and ffmpeg on the same image as before. What is lost is a second rendering of the same frames on the same image, and #571's "do not re-open it on the strength of the wall clock alone" is answered here on the strength of the runner limit, which the comment did not know about. The workflow comments citing #571 change in the same pull request (L32).

### 8. The timeout guard covers three of the four workflow files, by a list

`tests/test_ci_gates.py` requires `timeout-minutes` on every job in `tests.yml`, `swift.yml` and `guards.yml`, named in a tuple. `ui.yml` is not in it; its jobs happen to carry timeouts today. Lesson 14, eighth repo: derive the list from the directory. A five minute change.

### 9. The per-pull-request guard job is 25 minutes at its worst, and sharding it is cheap once the pool has room

`Guard proofs / changed` is 154 seconds at the median and 1,511 at the worst (44 entries at about 29 seconds each, as the file's own measurement says), and it was the critical path on four of the 43 pull requests. The file declines to shard it because sharding "consumes more of the very runners the queue above is short of". Once finding 1 lands that objection is much weaker, and sharding only when the entry count crosses a threshold (say twelve, about six minutes) keeps the common case at one runner. Judged by the same balance rule as the reference-frame shards. Risk to coverage: none; every entry lands in exactly one shard, which `shard_of` already guarantees.

### 10. What the redundancy sweep found: clean

183 Python test files with 2,274 tests, 292 Swift test files with 2,547. The Python titles that repeat (`test_x`, `test_a`, `test_plain`, three files each) are strings inside fixtures for the tooling tests, not tests; the rest are per-subject pairs (a title card applied and skipped, in the clip and the week generators). The Swift repeats are the guard proof shape: `testTheScannerCanStillSeeOne` appears in four files, one per scanner, each proving its own scanner can fail. Nothing mergeable. Real sleeps in the Python suite total about 4.4 seconds (three in the update wrapper's tests, reading a progress file while a build is in flight) plus one 15 second staged hang that exists to prove the per-test deadline kills a hung test, and every retry delay in the pipeline is patched out where it is tested. Same clean result as five of the other seven.

## Second pass (2026-08-29): what the new combined lessons caught

The section above was re-run against lessons 29 to 31 and the Overture section. Three things were missed, and one finding gained its cause.

### 11. Nothing reads the executed count on the runner, and the local readout refuses only zero

`tools/suite_counts.py` refuses a leg that ran ZERO tests (#932) and passes one that ran half; the `swift-unit` step in `swift.yml` calls xcodebuild directly, so on the runner no count is read at all. A run that loses a worker's share and still prints TEST SUCCEEDED reads as green (L98). That is the run finding 4's experiment produces: Overture's parallel attempt executed 4,875 of 8,595 tests with no crash line and reported twelve failures, and nothing said 3,720 never ran (lesson 29). So a floor readout (the suite has 2,546 tests today; hold each run, local and CI, to a floor derived from a recorded count, printing what it judged) lands BEFORE the parallel switch, in the order the other repos adopted. The Python legs are covered already: pytest-xdist reports a crashed worker's tests as failures.

### 12. The same derivation, once per test, in both suites (about 50 seconds, guards unchanged)

Lesson 30's shape, one level down from the pipeline. Swift: the three banner legibility tests each re-render every one of about 40 banner states from scratch (74 seconds on the runner), and two of the three render the IDENTICAL pairs (the same state at the same width, with and without its words), so about 27 seconds is the same pictures drawn twice; the source walks in `TextFieldStyleTests`, `CollapsedGroupLabelTests` and `RepoFixture.files(under:)` are `static func` and run per test, Downbeat's exact shape. Python: `test_swift_tests_never_reach_live_data.py` re-reads every Swift test file in each of its 22 tests (9.4 seconds), and `test_guard_mutation_registry.py` reads each of the 433 target files in three separate parametrised tests (20 seconds). A memo keyed on the default input for each, with the injected-root callers left building because they are the tests of the walker, and with the "scanner can still see one" proofs re-run so a memoised EMPTY scan cannot pass every reader at once.

### 13. Nothing keeps a series, and the Swift step grew 11% in the week this audit measured

The Swift test step's median was 476 seconds in the first eight runs of the week and 530 in the last eight; the Python leg went from 185 to 192; the guard sweep drifted to within a few entries of its deadline and went red four times before anyone measured the distance (finding 1); the workflow comment sizing the Swift job still says 2,250 tests against 2,546. Overture's finding 4 is the same blindness at 3x. Both legs already print `--durations=25` and every step timing is in the API, so the series costs no new measurement: a per-run summary line, or a scheduled job, comparing the latest duration and executed count against the recent spread and warning when it is outside it, with the count beside the seconds so growth can be told from slowing. It is the instrument findings 3 and 4 are judged by (lesson 9), so it goes ahead of them.

### A cause for finding 3, and a measurement for finding 4

Overture's finding 3 is the likely cause of the decorative cache: the checkout writes every source with a fresh modification time, so a restored build folder sees every file as newer than its build database and recompiles everything, hit or not. Setting each file's mtime to its commit time before the restore is the first thing to try, and the compile count is the judge. And lesson 31's measurement for finding 4 is in the log already: 416.7 seconds of summed test bodies against a 417.8 second testing phase, one core, which no reading of `project.yml` says.

## What the WWT article's practices say about this suite

The same list, and this suite follows it more thoroughly than any of the others: names are sentences, guards carry proofs that they can fail (433 of them, mechanised), tests that scan source assert they found files before asserting about them, and the expensive files are measured rather than guessed. The one practice with a speed consequence, eliminating redundancy, lands at the pipeline level again and in a new place: not a suite run twice, but a proof sweep run 33 times a week for the same 433 facts, and a build cache restored 16 times for the same nothing.

## What was deliberately not proposed

- **Path-filtering the Swift or macOS jobs.** Decided by Dan on 2026-08-13 after a compile error sat red on main across eight merges because the job was skipped, and recorded in swift.yml as "a deliberate decision to reopen that hole, not a tidy-up". Not reopened.
- **A self-hosted runner on one of the Macs.** The free option at PlayedIt, and the wrong one here: the repository is public, and a self-hosted runner on a public repository runs any fork's pull request on the Mac that hosts it. It becomes an option the day the repo goes private, which is also the day the money currency wakes up.
- **A larger hosted runner.** Bills on a private repo, as swift.yml already records, and does not exist for free on a public one.
- **Running the GUI job on pull requests, or dropping it from merges.** It is the only thing that runs the app's entry point (#867), it reports rather than gates, and it holds a runner for seven minutes once per merge. That is the right shape.
- **Dropping the Release build from CI.** It is the only compile of the views in Release, which caught #485 and #521. Finding 5 halves it without dropping it.
- **Treating the runner's per-test Swift durations as a list of slow tests.** The top five are the same on this Mac and on the runner, in the same order, so unlike PlayedIt the list is real, but only those five are worth reading: the rest is 2,540 tests at a tenth of a second, which is parallelism's job (finding 4), not trimming's.

## The picture after all of it

| Scenario | Today | After findings 1, 2, 3 | Plus 4, 5, 6 | Plus 7 |
|---|---|---|---|---|
| macOS runner-minutes per merge | 123 | about 30 (GUI plus the sweep amortised daily) | about 25 | about 20 |
| macOS runner-minutes per pull request | 29 | 29 | about 24 | about 18 |
| Runners the sweep holds per merge | 4 for 23 minutes | 0 (once a day instead) | 0 | 0 |
| PR wait, median | 18.6 min | about 11 min (the Swift job's own length, queue mostly gone) | about 7 min | about 7 min |
| PR wait, p90 | 35 min | about 13 min | about 9 min | about 8 min |
| Guard sweep at its deadline | 4 red shards a week | balanced by time, held under it | | |

## Proposed milestone

One milestone, `Faster PR Testing` (filed 2026-08-29 as milestone 17, findings 1 to 9 as #989 to #997 in this order; the second pass added findings 11 to 13 as #1017 to #1019, with the cause and the measurement above as comments on #991 and #992), one issue per finding:

1. Run the full guard sweep once a day when main moved, cancel a superseded sweep, and shard it by measured time under its deadline (p1, ci, cost, reliability)
2. Skip the post-merge Tests and macOS jobs, fail closed, when the pushed tree is one a green pull request already carried (p2, ci, cost)
3. The Swift build cache restores on every run and saves nothing: make it hit or remove it, and clear the 16 GB it holds (p2, ci, performance)
4. Experiment: run the Swift unit tests in parallel on the runner, judged by a randomised-order run first (p2, ci, performance)
5. Build the CI Release app for the active architecture only, with a guard against architecture-specific code (p3, ci, performance)
6. Set commit dates in the build-freshness tests instead of sleeping two seconds per commit (p3, performance, tech-debt)
7. Remove the duplicate reel render: the Mac Python leg deselects the files the reference-frame matrix already renders, with a guard that every font-gated file runs in exactly one place (p2, ci, performance)
8. Derive the timeout guard's file list from the workflow directory (p3, ci, reliability)
9. Shard the per-pull-request guard proof job when its entry count is large (p3, ci, performance)

Added by the second pass:

11. Read the executed test count against a recorded floor on every Swift run, before the suite's mode changes (p2, ci, reliability)
12. Compute the per-test source walks and banner renders once per run instead of once per test (p2, performance, tech-debt)
13. Keep a series of each CI job's duration and test count, and say when the latest is outside the recent spread (p3, ci, observability)

Findings 5, 6 and 8 are each a few lines and could land the same day. Finding 1 is the one that changes everything else's arithmetic, because it is what empties the pool; 2 and 7 are what keep it empty on a busy afternoon. Finding 4 is the one that needs care, for the reason its own paragraph gives.

### Also caught

- `guards.yml`'s comment on the `changed` job already says "This repository runs six macOS jobs per pull request and GitHub allows five concurrent macOS runners, so the sixth waits", measured on 2026-08-20. The fact was recorded, in the file for the job it was noticed on, and the job that fills the pool sits sixty lines below it in the same file. Lesson 14's shape, applied to a measurement rather than a guard.
- The Swift suite's local run on this Mac took 257 seconds of test bodies while the workflow comment sizes the job at "2250 tests, measured at 8m44s"; the count is 2,546 now. The timeout it justifies still holds.

---

# Overture test speed audit (2026-08-29)

## The headline

Overture is the ninth repo and the first where lesson 1 runs the other way: **the tests are the time.** CI is a single `typecheck-and-test` job on a public repository, and it takes 13 to 20 seconds end to end (setup 3 to 6s, install 2s, typecheck under a second, vitest 2 to 3s; 40 of the last 40 runs green). Everything else a pull request waits for is local, on this Mac, and almost all of it is one thing: the Swift suite, 8,595 tests, whose test bodies alone took 502 to 528 seconds across four full runs on 2026-08-26 and 27, and 586 seconds inside the verify run measured today.

Two facts explain that number, and both were measured rather than assumed. **The suite runs one test at a time.** Both test targets carry `parallelizable = "NO"` in the shared scheme, which is xcodegen's default when `project.yml` says nothing, and it has said nothing since the first commit (5732781a, 2026-06-22), so nobody ever chose it. The sum of the per-test durations in the last full log is 507.3 seconds against a 502.3 second wall clock, and the log's `started` and `passed` lines strictly alternate; the 95 tests that appear to overlap are parametrised tests printing one line per argument. On a 12 core M2 Max the suite is using one of them. **And 71 percent of that serial time is twelve suites**, most of which scan the source tree, and most of which scan it more than once: `CopyInventory.build()` is called twelve times per run at 5.9 seconds each, `CopySurfaces.build()` four times at 12.6, the #2839 real-person guard walks `mac`, `fixtures`, `src` and `docs` four times over and then spends 70 seconds in `String.contains` over about a thousand lowercased files and 150 names. The other 8,340 tests take about 75 seconds together, nine milliseconds each.

A pull request here pays that suite twice by design, once in the author's mandatory `scripts/test-all.sh` and once in `verify-and-merge-branch.sh` against current main, both through one lock shared by 16 worktrees. PR #3232 today went from open to merged in 13.6 minutes with CI green at 23 seconds; the other 13.3 minutes were the verify run. **Today a pull request costs about 23 minutes of exclusive xcodebuild on one Mac; with findings 1 and 2 landed it is about 5, and nothing below removes a guard or a run.**

One experiment was run rather than reasoned about, and its result is the reason finding 1 is not a one line scheme change: with xcodebuild's parallel flag on, the suite finished in 95 seconds instead of 525, seven tests went red (a loopback port bind, a process-global URL stub, a file watcher), and **3,720 of the 8,595 tests never executed while the run reported a verdict about the 12 it named and nothing at all about the rest.** The wrapper's own readouts, which exist to catch exactly that, could not read the parallel log format and said so.

## Where the time actually goes (measured)

All numbers are from this Mac (Apple M2 Max, 12 cores, macOS 26.5.1, Xcode 26.6) on 2026-08-29, the CI step timings from the GitHub API over recent pull request runs, and the per-test table from the full-suite log of the 2026-08-27 batch verification (`/tmp/overture-batch.log`, 8,158 pure tests in 1,107 suites plus 296 hosted in 49). Swift Testing's serial output prints a real per-test duration here (the Downbeat elapsed-since-start quirk appears only in xcodebuild's parallel format, see finding 1), so the cost table below is a cost table.

### One CI run on a pull request (one job, free)

| Step | Typical |
|---|---|
| Set up, checkout, pnpm, node | 5 to 9s |
| `pnpm install --frozen-lockfile` | 2s |
| `pnpm typecheck` | 0 to 1s |
| `pnpm test` (17 files) | 2 to 3s |
| Whole job | 13 to 20s |

The repository is public (`visibility: public`, read from the API today), so these minutes are not metered and there is no allowance to run out. `ci.yml`'s own header still describes "a private repo on a free personal plan, whose default spending limit is zero: CI STOPS rather than bills", which was true when the push trigger was removed on 2026-08-16 and is not now. Nothing here is worth a finding; the record is corrected below.

### The local gates (the whole wait)

`scripts/test-all.sh` runs two lanes. The Swift suite starts first in the background; the cheap lane runs beside it and is entirely hidden behind it today.

| Stage | Measured | Notes |
|---|---|---|
| `check-pure-suite-imports.sh`, `check-pbxproj-fresh.sh` (before the build, serial) | 2.9s, 0.6s | fine |
| Swift suite, test bodies (pure target) | **501.5, 502.3, 515.8, 527.7s** on four runs 08-26/27; 586s test action in today's verify run | one test at a time |
| Swift suite, hosted target (296 ViewInspector tests) | 4.9 to 5.0s | fine |
| Build and host launch, warm | about 18 to 25s | `elapsed -- Testing started completed` minus the test bodies |
| Cheap lane, all of it, serial | about 113s | 81 shell fixtures 65.7s, `check-live-store-claims.sh` 24.4s, `check-brand-voice-drift.sh` 9.2s, `prune-stale-registrations.sh` 5.4s, the rest under a second each |
| The three global push hooks on an already pushed branch | 0.1 to 0.2s each | the model judge (`sonnet`, 90s timeout) did not fire; unmeasured on a real push |
| Whole `test-all.sh`, warm | **about 9.5 to 10 minutes** | the Swift lane is the critical path by a factor of five |

The shell fixture lane is 221 seconds of fixtures dealt across 8 lanes, and its 66 second wall clock is set by one fixture, `mac/scripts/run-tests-locked.test.sh` at 55.8 seconds (nine stubbed runs of the wrapper), with `run-tests-locked-stall.test.sh` at 27.3 and four more between 11 and 14. That matters only once the Swift lane drops under it, which findings 1 and 2 make happen, so it is finding 5 rather than noise.

### Inside the suite

| Suite (from the 08-27 log) | Seconds | What is inside it |
|---|---|---|
| Test data addresses only domains that can never belong to anybody (#2839) | **118.3** | one test at 82.7s: about 1,000 files lowercased, then `String.contains` for each of about 150 names; three more tests at 11.7 to 12.0s, each a fresh walk of `mac`, `fixtures`, `src` and `docs` |
| Copy inventory (#915) | **59.4** | twelve calls to `CopyInventory.build()` at 5.9s each, one per test, nothing memoised |
| A generated doc only moves when its own subject does (#2349) | 42.8 | builds the inventory and the surfaces report again, per test |
| Where Overture's messages render (#2210) | 38.6 | three calls to `CopySurfaces.build()` at 12.6s each |
| Every stored fold key has a realignment pass (#2451) | 36.3 | one static scan (35.6s) that walks every app file against every `@Model` for argument lists and assignments |
| The fragment-match correction, rehearsed on copies of the live store (#2565) | 18.2 | clones every launch backup on disk (ten) through SQLite's online backup |
| What Overture decided about each organisation, live store (#1776) | 17.3 | one clone of the 1,018 show store, then `OrganisationListing.build` over it, which is APP code the Organisations sheet runs |
| Outbound copy has a reader (#2650) | 11.4 | inventory built again |
| Return reaching a sheet's default button (#2306) | 10.3 | |
| The gate's consumers agree about the same name, live store (#1785) | 9.0 | |
| The next twenty suites | 2.4 to 6.7 each | copy checks, dash guards, live-store clones |
| Everything else, about 8,340 tests | about 75 | 9ms each |

Sixty tests take over a second and 32 take over five. The 22 live-store suites total 68.7 seconds, each paying a clone of Dan's 1,018 show store. Real sleeps were looked for and are not the problem: eighteen sleep sites in the Swift tests, all seams or bounded races (a 5 second `SlowSender` raced against a watchdog and cancelled, a 3 second loopback fallback, 300ms settle polls), and none appears in the top forty tests. Which is Slate's and Downbeat's design (lesson 11): every retry in the app takes an injectable clock.

The suite has grown 3.7x in six weeks (2,309 `@Test` declarations on 07-15, 4,811 on 08-01, 7,134 on 08-13, 8,588 today; 273 test files to 899), and the wall clock has grown faster than the count: AGENTS.md records 177 seconds on 08-13, #3166 records 474 on 08-24, today is 502 to 586. The count explains the 75 seconds of ordinary tests. The scanning suites explain the rest, and most of them arrived in the last three weeks.

### After the push

There is no deploy pipeline; the path to "live" is `mac/build-install.sh` by hand. What a merge waits on is `scripts/verify-and-merge-branch.sh`, and it was timed on today's PR #3232 from the API and the build logs: opened 20:55:17Z, CI green 20:55:40Z, xcodebuild build log created 20:56:50Z (about 70 seconds of scrub, `pnpm install` and the two pre-build checks), test action 20:58:56Z to 21:08:42Z (586 seconds), merged 21:08:55Z. **13.6 minutes from open to merge, of which 2.1 minutes are a rebuild** (the verify slot keeps its DerivedData warm on purpose, but `git clean -ffdx` and the re-checkout move every file's mtime, so the build system recompiles the tree) **and 9.8 are the tests.** PR #3231 took 14.0 the same way.

So the consumer of every run is the session at the terminal (lesson 22), and the volume is high: 52 pull requests merged in the last seven days, 209 in the last fifteen, 12 today. At two full runs per PR that is about 23 minutes of exclusive xcodebuild per PR and about 4.6 hours of the shared lock today alone, all of it serialised by `/tmp/overture-mac-tests.lock` across the 16 worktrees on this Mac, so an agent's run queues behind whichever run is ahead of it. On top of that each PR body carries one to four `mutate.sh` proofs (counted across the last twelve merged PRs), each a scoped run that still pays the build.

#2487 (closed) proposed making the app-free `OvertureCore` scheme the normal path on the premise that building and launching the app was the cost. It was measured on 2026-08-29 to save nothing, which the table above explains: the build is 18 to 25 seconds of a 525 second run. The premise was never measured before the decision, and lesson 28's shape applies to the ISSUE as much as to a workflow comment.

## Findings, ranked by payoff

### 1. The suite runs one test at a time, and turning that off is measured, not a flag flip (biggest win)

`parallelizable = "NO"` on both testables is xcodegen's default, never a decision, and the RealStoreTestLock header (#1006) says the suite "runs suites concurrently by default", which is true of `swift test` and false under an Xcode scheme that says no; the lock was built for a race the suite is not currently exposed to, and 31 files take it. The experiment today (`-parallel-testing-enabled YES -parallel-testing-worker-count 12` through the wrapper, with Downbeat's suite also running on this Mac from 17:10:57 to 17:14, so the number is if anything pessimistic) finished in 95 seconds against 525.

Three things happened in that run, and every one of them is a task in the issue rather than a reason not to file it. Seven tests failed across twelve reported names, all of the shape a parallel run exposes: `LoopbackListenerTests` binding a real port, `SourceFetcherTests`, `SourceFetcherPaginationTests` and `CleartextFallbackTests` sharing a process-global `URLProtocol` stub (`SourceFetcherTests` is already `.serialized`, which orders tests within one suite and cannot order it against the two others), `DetachedRunActivityTests` waiting on a file watcher. Those are tests to give their own state, not tests to delete. Second, and worse: xcodebuild split the bundle across two `xctest` workers, the second printed 58 lines and its share never appeared, and **the xcresult says 4,875 tests executed of 8,595, with no crash line anywhere in the log and a verdict naming 12 failures as if they were the whole story** (L98, L11). Third, the wrapper printed `Suite shape: could not read the test totals from this run`, because the parallel format prints `Test case 'Suite/test()' passed on 'My Mac - xctest (pid)' (N seconds)` rather than Swift Testing's lines, so the short-run baseline gate (8,595) that exists for exactly this could not fire, and the per-test seconds in that format are elapsed since the worker began (a one line boolean at 64.4s), the Downbeat reading of lesson 17.

So the issue is: teach `run-tests-locked.sh` and `suite-stats.sh` the parallel format first and make the baseline gate refuse a run that executed fewer tests than the baseline (seen to fail on today's log, which is the fixture), then find why the second worker's share was lost (a worker count of 2 against 12 requested is itself a question), then give the network tests their own state, then flip `parallelizable` in `project.yml` with a source guard that it stays on. The order is the instrument before the structure change (lesson 9). Filed as #3233 (the readout) and #3234 (the switch); the experiment's full log is kept at `~/.overture-mac-test-diagnostics/parallel-experiment-20260829.log` as the fixture for the first.

### 2. Twelve suites are 71 percent of the run, and most of it is the same scan done again (pure speed, guards unchanged)

361 of 507 seconds. `CopyInventory.build()` with its default root is called twelve times per run and builds the same document each time; `CopySurfaces.build()` four times; `AppSourceWalk.files(under:)` is walked once per test in the #2839 suite; `GeneratedDocDriftTests` and `OutboundCopyTests` build both again. A `static let` memo keyed on the default root (the injected-root callers keep building, they are the tests of the builder itself) turns roughly 130 seconds into one inventory and one surfaces build. The #2839 guard's 70 seconds of `String.contains` over Unicode strings becomes about a second as a single pass over each file's UTF-8 bytes with the 150 names, and its four walks become one. What every one of these keeps is the assertion: the same document, the same names, the same files, compared to the same checked-in copy. Each must be seen to fail after the change exactly as before (`mutate.sh`, and the copy inventory's own stale-file check), because a memo that captured an empty scan would pass every reader (L98). `KeyBearingFieldCoverageTests`' 35 second scan is already a one-off static; whether it can be cheaper is a separate, smaller question. Filed as #3235.

### 3. The verify run rebuilds the tree from cold on every merge (2.1 minutes a merge)

The verify slot at `~/.overture-verify-worktree` keeps one DerivedData folder warm on purpose (#2601, measured 75 seconds better than cold), and then `git clean -ffdx` plus the detach and re-checkout touch every source file's mtime, so the build system rebuilds everything anyway: 20:56:50Z to 20:58:56Z today, on a change to a handful of files. The scrub is deliberate and stays (`worktree-safety.sh`, #2923). The question is whether the checkout can be brought to the merge result without rewriting unchanged files (a `git checkout` of the merge commit over the previous merge result rewrites only what differs; the `clean` then removes only untracked files, which is what it is for), measured by the build log's compile count before and after, on the same merge. If the mtimes cannot be preserved safely, the finding closes as measured and the 2.1 minutes are the price of the scrub. Filed as #3236.

### 4. Nothing in the suite reads its own duration, so a 3x climb in three weeks was noticed by this audit (#3166, already open)

`Suite shape:` prints the wall clock and AGENTS.md rightly refuses to write it down, so the number is read in the moment and compared with nothing. 177 seconds on 08-13, 474 on 08-24, 502 to 586 today. #3166 (p3, Ungrouped) already asks for a local series and a one line notice when the latest is outside the recent spread. It is the instrument findings 1 and 2 are judged by, so it moves into the milestone and ahead of them in order (lesson 23). The series should carry the test count beside the seconds, because a count that grows 3.7x while the seconds grow 3x is healthy and the same seconds on a flat count is the thing to look at.

### 5. Once the Swift lane is fast, the cheap lane is the floor, and one fixture sets it

The cheap lane is about 113 seconds serial and entirely hidden today. After findings 1 and 2 the Swift lane is around 100 seconds and the two lanes are level, so the 66 second fixture run and the 24 second `check-live-store-claims.sh` start to show. The fixture lane is bound by `run-tests-locked.test.sh` at 55.8 seconds alone (nine stubbed runs of the wrapper), then `run-tests-locked-stall.test.sh` at 27.3 with three real sleeps staged in whole seconds (`lock_wait`, `quiet`, `tail_quiet`), the poll-granularity shape of lesson 11. `check-live-store-claims.sh` reads every Swift and Markdown file in a bash loop with a subshell per file, lesson 25's shape at about 1,500 files. None of this blocks anything until 1 and 2 land; ranked p3 so it is measured then rather than discovered then. Filed as #3237.

### 6. `OrganisationListing.build` takes 17 seconds over the live store, and it is the app's code

The #1776 live-store test clones the store (a second or two) and then runs `OrganisationListing.build` over 1,018 shows, which asks `ProducerGate.qualifies(name, among: gateShows)` once per organisation key against every show: the shape of a quadratic. The same function is what `OrganisationsSheetModel` runs to build the Organisations sheet, so this is 17 seconds of every suite run and, unless the sheet is handed fewer shows, 17 seconds of the sheet. Index the shows by key once and the test and the sheet get the same saving; the test is the measurement that proves it (its `listing.count > 50` and the three-verdict assertions are unchanged). Filed as #3238.

### 7. Twenty-two live-store suites each clone the 1,018 show store (69 seconds)

`LiveStoreClone.makeClone` goes through SQLite's online backup, correctly (#1672), once per suite that reads the real data. The reads are read-only by design (a suite that writes into a clone writes into its own). Sharing one clone per process among the read-only suites, taken once and handed out as a path, is a measured experiment rather than a fix: it saves at most the clone cost, and a suite that turns out to write to it will fail its neighbours in a way that reads as a data defect. Ranked last among the suite findings for that reason. Filed as #3239.

### 8. What the redundancy sweep found: clean

899 pure test files, 43 hosted, 8,588 `@Test` declarations. Repeated test titles across files are all the per-subject shape (the same sentence asked of a different guard or a different queue surface), and the 2,186 source-text guards are one guard per invariant by the repo's own rule (#2726 fails a guard that can be answered twice). Nothing mergeable without losing a subject. The redundancy in this repo is inside one process: the same document built twelve times by twelve tests that each need it (finding 2), which is lesson 2's shape one level down from where the other eight repos had it.

## What the WWT article's practices say about this suite

Same list as the other eight. This suite follows them more literally than any of the others: every test name is a sentence, every guard carries a proof that it can fail in its PR body, an empty input is its own reported outcome (`L98` and `L11` appear in the suite's own comments hundreds of times), and the sleeps are seams. The one practice with a speed consequence, eliminate redundancy, lands here inside the test process rather than in a pipeline: the same expensive derivation recomputed per test because nothing said it could be shared.

## What was deliberately not proposed

- **Dropping either of the two full runs per PR.** They prove different things and the difference has bitten: an author's run proves the branch beside what it was cut from, the verify run proves it beside current main, and PR #2345 was green on the first and red on the second (#2353). Making both runs five times faster is the answer, not making one of them optional. #2487 already tried to make the author's run lighter by scheme and it saved nothing.
- **Scoping the suite by changed paths.** 2,186 of its declarations are source-text guards over the whole tree, the copy inventory reads every app file, the live-store suites read Dan's data, and `everyTestFileOnDiskIsCompiled` reads the project. A filter derived from where the change lives would exempt exactly the tests that read outside it (L88), the same refusal as Downbeat's memo.
- **Removing or thinning the scanning guards.** Each one exists because of a defect this repository shipped (the #2839 people, the #2349 stale documents, the #2451 unrealigned keys). Finding 2 makes them cheap; it does not make them fewer.
- **Turning parallelism on without finding 1's instrument.** Today's run shows what that looks like: 3,720 tests unexecuted behind a verdict that named 12 failures, on a wrapper that said it could not read the totals. A faster suite that cannot say how many tests it ran is not a faster suite.
- **Adding CI for the Swift suite.** The reason it left (#1347, a self-hosted runner going offline mid-job) has not changed, a hosted macOS minute costs ten of a free allowance (PlayedIt), and the local run is the only place the live-store suites can run at all.

## The picture after all of it

| Scenario | Today | After finding 2 (serial) | Plus finding 1 (parallel) |
|---|---|---|---|
| Swift test bodies, full suite | 502 to 586s | about 150s | under 60s, bounded by the serialised store suites and the 35s static scan |
| `test-all.sh`, warm | 9.5 to 10 min | about 3.5 min | about 2 min, the cheap lane now level with the Swift lane (finding 5) |
| Verify and merge, from PR open | 13.6 min | about 7 min | about 5.5 min, or 3.5 if finding 3's rebuild goes away |
| Exclusive xcodebuild per PR | about 23 min | about 11 min | about 5 min |
| Shared lock per day at 12 PRs | about 4.6 h | about 2.2 h | about 1 h |
| A run that executed fewer tests than the baseline | reported as a pass or as 12 failures | same | refused, naming the count (finding 1's first task) |

## Proposed milestone

One milestone, `Faster PR Testing` (filed 2026-08-29 as milestone 60, findings 1 to 7 as #3233 to #3239 in this order; #3166 moved in), one issue per finding:

1. Teach the test wrapper the parallel log format and refuse a run that executed fewer tests than the baseline (p1, tests, tech-debt, reliability) #3233
2. Run the Swift suite in parallel: find the lost worker share, give the network tests their own state, flip `parallelizable` with a guard (p1, tests, performance) #3234
3. Build the copy inventory, the surfaces report and the source walk once per process, and make the #2839 name search one pass (p1, tests, performance) #3235
4. Measure whether the verify slot can keep its build warm across the scrub (p3, tech-debt, performance, experimentation) #3236
5. Time the cheap lane's fixtures and scripts once they are the floor: the wrapper fixture, the stall fixture's whole-second sleeps, the per-file claims loop (p3, tests, tech-debt, performance) #3237
6. Index `OrganisationListing.build` so the Organisations sheet and its live-store test stop paying a quadratic over 1,018 shows (p2, performance, ui) #3238
7. Experiment: one shared live-store clone for the read-only live-store suites (p3, tests, experimentation) #3239

Moved into the milestone: #3166 (record each suite run's duration), which is the instrument the rest are judged by, and goes first.

Findings 2 and 6 are the ones that need no experiment and could land the same day; each guard touched has to be seen to fail afterwards exactly as before. Finding 1 is two issues on purpose, because the readout has to exist before anyone can say what the switch did. Findings 3, 5 and 7 are measurements first and changes only if the measurement pays.

## Third pass (2026-08-29, later the same day): what the other repos' second passes caught here

The combined lessons gained evidence from five other repos' second passes and three of those additions apply to this one.

### 9. Twenty-nine more suites each re-walk the app tree, 58 seconds (lesson 30, Downbeat's shape)

Finding 2 counted the four biggest scanners. Reading the per-suite table again with Downbeat's addition to lesson 30 in hand (24 guard suites each recomputing one repository walk, a `static func` where a `static let` would do): 32 test files and 40 suites call `AppSourceWalk`, 31 of them appear in the 08-27 log, and outside the four suites finding 2 already names they total **58 seconds across 29 suites** (`Return reaching a sheet's default button` 10.3s, `No em/en dashes in user-facing string literals` 6.7s, `One producer-name rule` 4.5s, `App code nothing reaches` 4.5s, and 25 more between 1 and 3.5s). `AppSourceWalk.appFiles()` is a static function that enumerates and reads about 500 files per call. One memo on the default root (the same one-line change finding 2 asks for on the inventory and the surfaces report) covers all 29 at once; the `refusal(found:floor:)` floors stay and must still fire on an empty walk (L98). Added to #3235's scope rather than filed separately, because it is the same line.

### 10. The merge path records no duration of its own (lesson 23)

`verify-and-merge-branch.sh` and `pr-merge.sh` write nothing about how long they took; the only stage that states its own time is the Swift wrapper's `Suite shape:` line. The 13.6 minutes on PR #3232 had to be reconstructed from the GitHub API, a build log's creation time and an xcresult, which is claude-config's receive-path shape exactly. #3166 (the duration series) should record the whole verify run by stage (prelude, build, tests, merge) rather than the suite alone, because finding 3's rebuild (2.1 minutes) is invisible to a series that only sees the suite. Noted on #3166.

### 11. AGENTS.md carries a dated duration that is now three times wrong (lesson 28)

`AGENTS.md:124` says "measured 2026-08-13, the cheap lane took 54s on its own and a full two-lane run took 200s against a Swift suite of 177s", and that measurement is what justifies the two-lane design and the stall limits being "an order of magnitude past the cheap lane". Today the cheap lane is about 113 seconds serial, the Swift lane 525 to 610, and the design is still right, which is Downbeat's memo sentence again: the decision holds and the number beside it does not. The same file refuses to state the full run time for exactly this reason (L32), so the fix is to make that line say what it is (a record of the day the lanes were split, not a current figure) and let #3166's series be the current number. Noted on #3166.

Also checked and cleared on this pass: the short-run gate refuses at 90 percent of the baseline, so a half run in the serial format is caught (lesson 29's PostRoll case does not apply); `RepoRoot.url` and `SourceGuardHelper.source` are uncached and called 107 and 350 times, but each is a handful of stats and one small file read, well under a second in total; no deadline here is set so that the platform's fires first (lesson 26), since the wrapper's stall guard warns rather than kills and CI's 10 minute limit sits over a 20 second job; there is no post-merge re-run to skip (lesson 22) and no capped allowance to watch (lesson 19).

### Also caught

- `ci.yml`'s header describes a private repository whose free allowance would stop CI at 2,000 minutes. The repository is public and the job costs nothing; the reasoning that removed the push trigger (a second look at code that had already passed, L85 covered by the merge scripts) still holds on its own. The premise line should say so rather than carry a limit that no longer exists (lesson 28). No issue; a one line correction to ride on #3233.
- The RealStoreTestLock header (#1006) records that Swift Testing "runs suites concurrently by default", and the suite it guards has run one test at a time since the scheme was generated. The lock did not cause the crash it was written for to stop (the serial scheme did), and it will be the thing that keeps the store suites safe when finding 1 lands, so it stays; its comment should say which of those two it is doing.
- xcodebuild's parallel format reports per-test seconds as elapsed since the worker started (a trivial test at 64.4 seconds), so the cost table in this section can only be read from a serial run. Anyone reading `(N seconds)` lines from a parallel log to find slow tests will find the start order, Downbeat's lesson 17 by a third route.
- The experiment ran while another repository's suite was using the same Mac, so its 95 seconds was measured under contention (L224) and is a ceiling rather than a number to design to.

---

# Combined lessons (across all nine repos)

1. **The tests are innocent until measured guilty; the pipeline rarely is.** All four repos run their suites in seconds to under a minute locally while PRs wait minutes in CI (Bidspoke 9s of tests against a 3.2 minute wait, PET 71s against 7 to 9.5 minutes, Slate 15s against 5.5 minutes, NurseDex 12s against 8.5 minutes). Slate is the purest case: an audit that started from the test code would have found almost nothing, because there was almost nothing wrong with the tests. PlayedIt is the case where the tests could not be timed locally at all (no simulator runtime on the machine) and the CI log still told the story: one to eight minutes of summed test bodies inside a 10 to 35 minute job, with the difference being package fetches, a build of a target that never runs, and a simulator booted after the build instead of during it. The first move that paid, every time, was per-step CI timing from the GitHub API. Downbeat had no CI to time and the suite was 27 seconds, and the wait was still 7.5 minutes a push: the pre-push hook's own 45 self tests, run serially, at 402 seconds, under a comment saying they take about a second. When there is no pipeline, the gate's own guards ARE the pipeline, and they need the same per-step timing.
2. **Look for the same work done twice per event.** Bidspoke: a guard suite run twice per CI run, one artifact built twice per web PR, every merge verified twice by two workflows. PET: the same auth-gate tests copied into six files, about 106 loads of one page. Slate: the entire test suite run a second time per PR by a report-only coverage job. NurseDex: the same 65 migrations and seed applied by `supabase start` and then again by `supabase db reset` in the very next step, 47 times a month. PlayedIt: a UI test runner compiled and signed on every run for 425 tests the job never launches, because `-only-testing` chooses what executes and not what builds, and a merge-commit run that nothing reads. In all five, redundancy at the pipeline level dwarfed redundancy at the assertion level, and the duplicate-title sweep came back clean in four of them. Downbeat: eleven stubbed installer runs that each ran the real LaunchServices dump, three sweep cases that each ran a machine wide `lsof`, and a scanner that spawned two processes per line of shell; the duplicate-title sweep was clean there too. PostRoll: not a suite run twice but a PROOF sweep run 33 times a week, four macOS runners for 23 minutes on every merge re-proving the same 433 guards, and a build cache restored on all 16 recent runs while all 16 recompiled every source; its duplicate-title sweep was clean too, the eighth repo where the redundancy lived in the pipeline and not the assertions.
3. **Serial steps with no dependency on each other are free money.** Bidspoke's worker and web suites ran back to back in one job; PET's Node and browser suites still do; Slate ran its whole pipeline, typecheck through build, in one line. Splitting costs a duplicated setup and buys the entire shorter leg, and it was the single biggest wall-clock win in the first three audits. NurseDex is the exception that shows the limit: its serial steps live inside one E2E job because each needs the Supabase the job just started, so splitting them would start Supabase twice, and its CI job could be split for a 30 second win on a PR that waits 8 minutes for the other job. Split only what is independent, and only when the split leg is on the critical path. Downbeat is the purest case of the rule: 45 self tests that each sandbox themselves, run one after another in a `while read` loop, so the wait is their sum (402s) when it could be their maximum (about 22s once the three outliers are fixed).
4. **Cache or kill the cold starts.** Bidspoke: the Next.js build cache. PET: the Playwright browser download. Slate: vitest paying four times its actual test time in startup and collection on a cold runner. Keyed on the thing that invalidates them, these caches save both currencies with no coverage surface at all. The second pass found the same shape hiding under one more layer in both repos with a browser build: a tool invoked through `npx` that is not in `package.json` (PET's wrangler, Bidspoke's vercel underneath next-on-pages) is downloaded on every run AND resolves to whatever version is latest that day, so the fix is a pinned devDependency, not a cache. NurseDex added a fourth layer: container images. `supabase start` pulls twelve Docker images cold on every run, 115 seconds of a 160 second step, and seven of them (studio, logflare, vector, edge-runtime, realtime, mailpit, postgres-meta) are for services nothing in the suite reaches. The cheapest cache is the work you do not do: exclude the services on the runner rather than cache their images. PlayedIt added a fifth layer and a second move. The layer is Swift package checkouts: nine repositories fetched from GitHub on every run with `Package.resolved` already committed, the exact shape of the lockfile-keyed caches everywhere else. The move is overlap rather than cache: its simulator is chosen in one step and booted by `xcodebuild` only after a two to six minute build, when `simctl boot` in the choosing step would have it ready by the time the build finishes. A cold start that cannot be cached can often be started earlier, and the saving is the same. PostRoll adds the failure mode the other four did not have: a cache that RESTORES on every run and speeds up nothing. All 16 recent Swift jobs restored a DerivedData cache, two of them exact hits on identical sources, and all 16 compiled every one of about 527 units anyway, while the 58 copies at 276 MB each put the repo 6 GB over its 10 GB cache limit and evicted the pip and ffmpeg caches that do work. A cache hit is a log line; a cache that saves is a measured difference in what gets rebuilt, and only the second is worth keeping (L3, L98).
5. **A report-only check still gates in practice.** If the merge flow waits for every check to go green, "report-only" describes the workflow file, not the waiting. Slate's coverage job gates nothing on paper and delays every merge in fact, and would have silently become the critical path the moment the real gate got faster. Price informational jobs as if they were gates, because to the person waiting, they are.
6. **Job and check names are load-bearing.** Automation keys on them: Bidspoke's plan had to verify nothing keyed on the check names it wanted to skip (it does not; confirmed in the second pass), Bidspoke's own deploy re-asserts `needs.verify.result` by hand inside an `always()` so a Verify split must keep the job id `verify`, and Slate's merge-legitimacy guard reads the check literally named "ci", so its job split must ship a fan-in job with that exact name plus a pin that the fan-in's requirements list stays complete. NurseDex's required checks are named in a branch ruleset (`lint, typecheck, test`, `authenticated e2e`, `Vercel`), which is a third place a name can be load-bearing besides a workflow file and a guard script, and one that a search of the repo cannot find. A rename that breaks an automation is a coverage loss wearing a speed win's clothes, and the fix (a fan-in job holding the old name) is cheap once you know to look, so look in the ruleset too.
7. **Both currencies, always.** Wall-clock minutes and billed minutes are different budgets, and every audit had at least one recommendation declined, reordered, or reshaped by the paid one (Bidspoke: artifact sharing that would worsen wall clock; PET: sharding against what it believed was a maxed cap; Slate: a split that is bought with extra setup minutes and paid for by moving the coverage job). Read the paid currency off the billing system, not off the plan page: the 2,000 free minutes are one org-wide allowance shared by every repo, it was gone by the 7th of August, and from then on every minute in every repo is metered at $0.006. PET's "near the cap" and Bidspoke's "minutes are billed" were both true and both uninformative until the itemized bill (6,599 Bidspoke minutes and $37.87 in August; 16,341 and $82.53 across the org) put a number on it. The fourth repo showed the currencies can weigh differently per repo: NurseDex is a private repo on a personal account with its own free allowance, uses about 760 minutes a month against it, and pays nothing, so there every recommendation was ranked by wall clock alone and the billing findings were kept but ranked last. Which currency bites is a fact about the account the repo lives in, and it is read off the billing system, not assumed from the org next door. PlayedIt then showed that the exchange rate between the two currencies is part of the workflow's design: a macOS runner draws ten allowance minutes for every minute it runs, so fourteen ordinary CI runs (197 macOS minutes) consumed 1,970 of a personal account's 2,000 free minutes in 26 hours, and the fifteenth was refused. Every wall-clock finding in that repo is worth ten times its number, a six-hour hang would cost two months of allowance, and the largest single lever is not a cache or a split but the choice of runner (a self-hosted Mac bills nothing). Read the multiplier off the runner label before ranking anything. claude-config is on the same Free personal plan shape as PlayedIt, using about 800 of 2,000 allowance minutes a month, and its one finding that spends minutes (splitting a suite across jobs) was ranked last and written as a decision for that reason; the billing endpoint needed a token scope the CLI did not carry, and widening a token's scope to read a number is not something an audit does on its own. PostRoll is a public repository on a Free personal plan, so the money currency is zero and the allowance is untouched, and it still had the longest pull request wait of the eight (a median of 18.6 minutes, p90 35) because of a THIRD currency: GitHub allows a Free plan five concurrent macOS jobs, this repo launches six per pull request and ten per merge, and in 524 of the 877 minutes something was queued exactly five of its own jobs were running. A workflow comment had priced a duplicate render at "about 200s of wall clock and nothing else" because the runners are free; they are free in money and rationed in slots, and the slot is what every other job waits on. Read the concurrency limit off the plan alongside the price, because on a free public repo it is the only budget there is.
8. **The speed lever you refuse is part of the audit.** Bidspoke: vitest's isolate:false. PET: killing animations before accessibility scans, rewriting rendered-style checks as text greps. Slate: batching its one-process-per-file suites, and dropping its 52-second pre-push double-check. Each is the biggest available lever in its repo and each changes what is measured or what is caught. Naming the refusal in writing keeps a future speed pass from "discovering" it.
9. **Structure changes ride on instruments, not optimism.** Bidspoke gated its job splits on an existing coverage guard; PET's worker-count experiment is only safe because a retry report already publishes every run; Slate's split rides on a workflow-shape test that pins the fan-in's completeness. If no instrument exists, build the instrument first. NurseDex is the case where it did not exist: two of ten E2E runs paid a 3 minute retry, the reporter was `html` only, and the only trace of which spec flaked was a line in the job log and an artifact nobody opens. Neither the worker-count experiment nor the prebuilt-server experiment can be judged until the flake count is on the run, so making it visible is the first issue in that milestone, ahead of anything it would measure. Overture is the sharpest case yet: the wrapper HAD the instrument (a short-run gate against a baseline count) and the experiment that would have used it changed the log format under it, so it printed that it could not read the totals and the gate went quiet while 3,720 tests went unexecuted behind a verdict. An instrument that only reads the shape of run it has already seen is not an instrument for the change you are about to make; re-fit it to the new shape first, then judge.
10. **A subsumption sweep is worth running even when it finds nothing.** PET found weak tests standing beside strictly stronger neighbours; Bidspoke's sweep (400 files, run in the second pass because the first pass had claimed it without doing it), Slate's sweep of 499 files and NurseDex's of 226 (its repeated titles are generated per route by one shared helper, which is the table-driven shape PET is being asked to adopt) all came back clean, which is its one-guard-per-invariant culture paying out, and that clean result is what licenses spending all the effort on the pipeline instead. When the sweep does find deletions, name which surviving test covers each deleted assertion.
11. **Sleeps are a seam decision made on day one.** PET carries about 39 seconds of real timer waits because its retry settings were hard-coded and tests could not reach the seam; Bidspoke carries about 7.5 seconds for the same reason, three tests sitting at exactly the engine's 1.5 second default backoff, found only when per-test timings were read rather than the suite total; Slate carries zero because every retry path takes an injectable clock and its tests assert the delays the code asked for instead of living through them. The second design is also the stronger test. Retrofitting the seam (PET's fix) works; building it in (Slate) means never paying the tax. claude-config showed the polling form of the same rule: the tool waits for a finished runner in 2 second steps and for a lock in 1 second steps, harmless in production and about 40 seconds of a test suite that runs fifteen pulls against a stub, and its stall watchdog polls every 2 seconds so the smallest stall a test can stage is several seconds long. A poll interval is a sleep with a condition attached, and its granularity is the seam. Downbeat carries under a second in its Swift suite because every retry and recheck in the app already takes an injectable sleep, and about 25 seconds in its shell self tests for the same reason as claude-config: a lock poll fixed at 2 seconds and a tracker poll fixed at 1. PostRoll carries about 4 seconds in Python (every retry delay is patched where it is tested) and 24 seconds in Swift, all of it one file sleeping 2.05 seconds between git commits so their whole-second timestamps differ, which is the clock form of the same rule: a fixture that WAITS for a clock to move can instead SET the clock (GIT_AUTHOR_DATE and GIT_COMMITTER_DATE), and the version that sets it is both instant and the stronger test, because it pins both ends (L130, L134). Overture carries under a second in 8,595 Swift tests (eighteen sleep sites, every one a seam or a bounded race) and its whole-second sleeps live in the shell fixtures that test its runner's stall guard, the poll-granularity form again.
12. **Tiny always-on jobs are quietly expensive, but only when their isolation is decorative.** Every job bills a minimum of one minute: PET's 5-second lint job burned about 100 minutes a month for nothing and folded away; Bidspoke's hourly Deploy Drift bills three minutes for under 30 seconds of work because its three read-only comparisons are three jobs, and its auto-merge check bills a minute on every green human PR to learn the PR is not Dependabot's when a job-level `if` on the branch name would learn it for free; Slate's 11-second migration gate bills the same minute and stays, because it separately gates deploys and must be able to fail on its own. The test is whether the isolation does work, not the job's size. The rounding cuts the other way too: NurseDex's Production Smoke runs 64 to 69 seconds and bills two minutes 48 times a month, because 30 of those seconds are an `npm ci` whose only purpose is to make `tsx` available to a script that imports two files. A job that sits just over the minute is worth looking at for the same reason as one that sits just under.
13. **An audit of "PR testing" stops at the PR unless you make it walk to production.** Bidspoke's first pass measured every PR job to the second and then treated the merge side as a compute bill: it never timed Deploy's Verify job, which is 250 serial seconds that every deploy waits on, the largest single serial block in the whole pipeline, and the one wait a person actually sits through after clicking merge. Slate's first pass did walk to production (merge-to-live was in its table) and found its biggest win there. Time the path from merge to live as carefully as the path from push to green, because the second one is the one people complain about. The walk can also come back with the opposite answer: NurseDex's production deploy is a Vercel build that starts on push and is gated on nothing, so merge-to-live is one minute and the 6.5 minute CI run and 8 to 12 minute E2E run on main are signals after the fact. That is not a speed finding, but it has to be written down, because a person optimising the main-push jobs on the belief that they hold the deploy is optimising the wrong thing, and whether production should ship before its full sweep finishes is a product decision that deserves its own issue rather than a discovery in a speed audit. PlayedIt is the third answer: there is no deploy pipeline at all (release is a manual App Store submission), no branch protection, and no automation reading any check, so the merge-commit run is a signal with no reader that costs the same as the PR run. The walk to production must also ask who consumes each run, because a run nobody reads is priced entirely in the paid currency.
14. **The guard you already have covers the file it was written for, not the class.** Bidspoke's timeout guard requires `timeout-minutes` on every ci.yml job, with a comment explaining why a hang is worse than a failure, and three other workflow files in the same directory have no timeout on any job. A guard scoped to one file passes forever while the defect it names sits next door (L135, L30). When a guard is written for a class of defect, point it at every file the class can appear in. Slate's post-filing sweep found the same shape twice more: no Slate workflow had a timeout at all (the defect Bidspoke's guard names, in a repo with no guard to scope), and the #1524 fix that freed its main push guard of a fragile dependency chain left the sibling deploy-alert workflow carrying the identical chain. A FIX obeys the same law as a guard: it covers the file it was written for until the class is swept in the same change (L30, L195). NurseDex made it four for four on the timeout class (two of five workflow files carry one, three do not, and four workflow-shape tests pin four files without asking), and PlayedIt made it five for five with no timeout on either of its two jobs, on the one runner where the default six hours costs 3,600 allowance minutes. That is the strongest possible argument that the guard belongs on the directory, not on a file, and that it belongs in every repo the class can appear in, not only the one where it was first noticed. claude-config makes it six for six: one workflow file, one job with a timeout, and nothing pinning that it stays there or that it exceeds the suite's own deadline. Downbeat is seven for seven, and shows where the class lives when there is no CI: the pre-push hook bounds its lock wait and nothing else, so a self test stuck on a machine wide `lsof` against a network mount hangs the push with nothing printed. PostRoll is eight for eight, in the mildest form: every job in all four workflow files carries a timeout, and the guard that requires it names three of the four files in a tuple. The fourth passes today by habit, which is the state every one of the other seven was in the day before it was not. The same repo shows the shape one more time with a MEASUREMENT instead of a guard: the comment on its per-pull-request guard job records, correctly, that six macOS jobs per pull request against five runners means the sixth waits, and the job that fills the five sits sixty lines below it in the same file, unpriced.
15. **A harness that reruns the suite once per case pays the boot once per case.** NurseDex's guard mutation sweep is the right design (one mutant at a time, a kill scored only on a real assertion failure) and it costs 207 to 219 seconds on every push to main for about 24 seconds of test bodies, because each of its 105 mutants spawns a fresh vitest process to run one suite file. Mutation testing, property sweeps, matrix runs and anything else that executes a suite N times is dominated by N boots, not by the tests, and the lever is the boot: a warm runner reused across cases, or isolated lanes running cases side by side. The semantics that make the tool trustworthy (one case at a time, per-case verdicts) must survive the change unchanged, which is what the tool's own tests are for. claude-config is the same shape at a smaller scale: a suite that tests its own sharding, deadline and lock machinery by running itself, 39 launch sites across 17 sections, where a launch costs 1.4 seconds before its first section and a parse-only listing costs 0.27. Self-hosting is the right design (a fake selector proves nothing), so the lever is the boot, never the tests. PostRoll's guard sweep is the largest instance yet: 433 guards, 275 of them proved by an xcodebuild rebuild of 13 to 29 seconds each, and the measured dead ends (splitting the perturbed file, carrying a warm cache between jobs, batching entries) are recorded in the workflow so the boot is known to be the floor. What was left to find was the CADENCE: the sweep re-proves all 433 on every merge, 33 times a week, for facts that change only when a guard or its target changes, and the per-pull-request scoped job already proves those. A sweep whose cost is N boots is priced per run, so the lever after the boot is how often it runs.
16. **A flake is a speed cost priced at a full re-run, and retries hide the price.** PET's #931 was filed as a flake and sat for a month before it was priced (a 7 to 9 minute re-run in both currencies); Slate's #1555 was moved into the milestone for the same reason; NurseDex's E2E job took 413 and 462 seconds on two of ten runs against 210 to 230 on the rest, and both were green, because `retries: 2` absorbed the failure and the html reporter told nobody. Retries are the right call (a red PR and a manual re-run is worse), but they convert a failure that would have been investigated into a delay nobody sees, so count flakes on every run, put the count where a reviewer looks, and rank a recurring one with the speed findings rather than the reliability backlog. claude-config: one flake in 233 runs, in the runner's OWN suite, and it read a launch order off a starved two-core runner (lesson 17); the fix is to assert the decision the runner printed rather than the order the suites happened to finish in. Overture adds the opposite failure: a parallel run in which a whole worker's share of the suite silently did not execute, no retry, no crash line, a verdict naming 12 failures and nothing about 3,720 absences. A retry hides a failure; an absent worker hides a non-run, and only a count against a baseline can see either.
17. **On a starved runner, per-test durations measure the runner, not the tests.** PlayedIt's CI log names a struct constructor at 70.8 seconds and a one-line boolean at 21.8 seconds as its slowest tests, and the next run names a completely different set of trivial tests. A 3 or 4 core machine hosting the build toolchain, two simulator clones and the test process reports whichever test happened to be running while it was frozen (L203: a cause inferred from co-occurrence). The per-test timing table that found real sleeps at PET and Bidspoke can only be read on a runner that is not oversubscribed, or across several runs, keeping only what is slow in every one of them. In PlayedIt exactly one group survived that filter, and it was the real finding. Downbeat is the same lesson by a different route: Swift Testing under Xcode 26 prints `passed after N seconds` per test where N is elapsed since the run began, so 3,211 of 3,267 tests read as half a second or more inside a 27 second run and the sum is 37,000 seconds. The table looks like a cost table and is a start order. Overture confirms the Downbeat reading is a property of the FORMAT and not the project: the same suite's serial log prints real per-test costs (which is how its cost table was read), and xcodebuild's parallel format prints elapsed-since-worker-start (a one line boolean at 64.4 seconds). Read the format before reading the numbers, and note which format the run you are reading used.
18. **A test that asserts only that a failure happened is satisfied by the environment failing, and it pays for the privilege.** PlayedIt's Apple sign-in tests call the real client with a junk token and assert it returned false and set an error. In CI the client points at a placeholder host, so the network fails, the assertion passes, and the tests wait 10 to 308 seconds per run for a timeout on the way to proving nothing (L140: any throw satisfies "it threw"). The file's own comment explains the shape: no protocol seam, so test the real thing. That sentence is the whole cost, in both currencies, and the same sentence is what lesson 11 says about sleeps: the seam is a day-one decision, and its absence turns every test of an error path into a test of the network. When a test can only pass by reaching something, either it is an integration test and lives with the others, or the seam is missing.
19. **CI that has stopped is the slowest test suite there is, and it stops quietly.** PlayedIt's free allowance ran out on 28 July and every run since has been refused before its first step; the only visible trace is a red check on one PR, which reads as a failing test to anyone who does not open it. Nothing alerts on an allowance, a refused run looks like a failed run in every list, and a repo that goes quiet for a month looks like a repo nobody is working on. An audit of test speed has to begin by confirming the tests are running at all, and a repo on a metered or capped runner needs a place where "how much of the month is left" is visible before the day it is zero (L13: alert on the absence of an expected run, and L523: a limit must be listed somewhere visible). NurseDex is the same account type one step earlier: a capped personal allowance at 38 percent with no surface showing the remainder, so the check is calendar driven until one exists.
20. **When the tests ARE the time, the suite's own parallelism is the pipeline, and it has the same defects.** claude-config's suite shards itself, and the selector balanced shards by counting sections when the slowest five sections were 52, 38, 27, 27 and 24 seconds against a median under 2: at four shards one carried 165 seconds and the lightest 76, and the run ended at 179 when a time-balanced deal of the same sections ends near 120. The runner one level up already kept a per-suite timing store and ordered by it (#144); the suite one level down printed every section's duration (#107) and used none of it. Anything that divides work between workers must divide by a measured cost, and the balance check that guards it must measure in the same unit (L63), or it passes while measuring the wrong thing.
21. **A measurement that only exists on the machine it was taken on is not in CI.** The runner's launch order comes from a timing store in `~/.cache`, and every CI run prints `measured wall clock for 0 of 42 suites, file size for the rest` because nothing persists the store between runs. It happens to be right today (the slowest suite is also the largest file) and would go wrong silently the day that stops being true. The same store is what finding 1 needs on the runner. A cache keyed on nothing but the runner is the honest fix; a hard-coded order is the dishonest one. Vitest has the same store built in (a results cache under `node_modules/.vite/vitest` that orders files slowest first), and NurseDex's `npm ci` deletes it on every run, so the runner orders by file size every time and the audit's cache experiment has to carry that store as well as the transforms.
22. **Walk to production, and it may turn out there is no gate there at all, in which case say who does wait.** claude-config's other Mac pulls main when it changes, not when CI is green, and then runs the whole suite itself on what it installed. Merge-to-live is seconds, CI is a second opinion, and the thing that actually waits on CI is a pull request behind a merge guard and a session's close-out line. That is the third time in six audits (NurseDex's Vercel build, PlayedIt's absent pipeline) that the deploy did not read the check, and each time the audit had to name the real consumer of the run before it could rank anything, because a run whose only reader is a person is priced in that person's minutes. PostRoll is the fourth: every commit on main is a squash merge made by a tool that refuses a head behind main and merges the exact commit it judged, so the merged tree is byte for byte the pull request's tree, and the two workflows that re-run on the push re-test it for nobody, 27 macOS runner-minutes a merge, while the two jobs that DO run first on a merge (the guard sweep and the GUI job) are the ones a re-run would have to keep. When the merge tool proves tree identity, the post-merge re-run is provably redundant rather than probably, and the skip can be written fail closed on that proof. Overture is the fifth: the consumer of every run is the session at the terminal, the merge is a local script that runs the full suite against current main before anything reaches GitHub, and the 13.6 minutes a pull request waits are 98 percent that script. There the two runs per PR are not redundant (they prove the branch beside two different bases, and PR #2345 was green on one and red on the other), so the audit's answer was to make both five times faster rather than to drop one. NurseDex's third pass applied PostRoll's proof and it held: linear history plus an up-to-date branch plus squash merges, and the last six merge commits have tree hashes identical to their PR heads, so the E2E job's 17 post-merge runs a month (149 billed minutes) re-test a tree the same job already passed. The skip is written on the tree hash, fail closed, never on a path. PlayedIt's second pass made it six of six: its last six merges are squash merges of up-to-date branches with tree hashes identical to their PR heads, and on a runner billed at ten to one that proof turns a first-pass proposal to drop the push trigger (which would have lost the signal on a behind branch) into a skip that keeps it.
23. **A gate's own guards are a pipeline, and they are never timed because nobody thinks of them as tests.** Downbeat's pre-push hook runs 45 shell self tests before it will run the suite it exists to run, and they took 402 seconds against a 27 second suite. Nobody had measured them because the only number anyone ever saw was the whole push, and the comment beside the loop said they take about a second, which was true the day it was written (#190) and had been untrue by a factor of four hundred for weeks (L32, L210). Time every stage a push or a merge waits on, including the ones that guard the guards, and put the measurement where the claim lives so the next drift is a diff rather than a discovery. claude-config's per-command gates cost 0.22 seconds for seven hooks and were cleared, but its receive-path run (the whole suite on the Mac that just installed the config) records a verdict with no duration, and the only statement of its length is a comment beside the 1,800 second timeout. Overture's merge path is the same: `verify-and-merge-branch.sh` records nothing about its own length, so the 13.6 minutes a pull request waits was reconstructed from the API, a build log's timestamp and an xcresult, and the 2.1 minute rebuild inside it is invisible to a series that only records the suite.
24. **A test that stubs some of a script's collaborators runs the rest for real, and the real ones are the slow and the dangerous ones.** Downbeat's installer test stubs the build, `open`, `codesign`, the identity finder and the shipped recorder, and forgot the registration cleanup, so eleven runs per push each did a 4.5 second `lsregister` dump and unregistered bundles from the live LaunchServices database (L2). Its sweep test stubs nothing, so three cases each asked `lsof` about every process on the Mac to check a dozen fixture files. When a script takes its collaborators through env seams, list every seam beside the test and assert the test sets each one, or the missing seam is both the time and the live write (L52, L196).
25. **A scanner that guards a class of fault across the whole tree pays per line, and its cost grows with the tree it guards.** Downbeat's pipefail scanner is the right guard (four hand fixes, then a check, L30), and it spawned a `sed` and a `grep` per line for 17,353 lines of shell: 80 to 177 seconds, and one unexplained failure in three runs that nothing kept the output of. A per line subprocess loop is fine at a hundred lines and is the whole wait at twenty thousand, so a tree wide guard is written as one pass per file from the start, and a failing guard's full output is kept (L148) so an intermittent one can be diagnosed instead of retried.
26. **A sweep sized by count grows into its own deadline, and the deadline then reports the sweep's size as a failure.** PostRoll's guard sweep is four shards of about 100 entries under an 1,800 second deadline, and the shard medians reached 1,264 to 1,391 seconds with a p90 near 1,500, so four shards in one week went red with entries "never reached before the deadline, so they are UNPROVEN", one of them 48 of 99. Every guard added moves the sweep closer to red, nothing measures the distance, and the red it produces reads as a broken guard rather than a full shard. Anything divided into fixed-size pieces under a fixed deadline needs a test that holds the measured size of the largest piece to a fraction of the deadline (L172, L224), and a shard dealt by measured cost rather than by count (lesson 20), or the first sign of growth is a failure on main that names the wrong cause (L11). claude-config had the mirror image: the deadline that would fire first is the platform's, because the job timeout stayed at 20 minutes while the suite's own ceiling was raised to an hour, so the deadline that exists to name the section would never get to speak.
27. **On a free public repository the runner limit is the budget, and every job is priced in the slots it holds, not the minutes it bills.** Lesson 7's two currencies are both zero on PostRoll, and it had the longest wait of the eight repos. Five concurrent macOS jobs is the whole capacity, so a job's cost is the runner it holds times how long it holds it, whoever is waiting: the post-merge sweep at four runners for 23 minutes was 48% of the slot-minutes held while other jobs queued, and the duplicate render that a comment priced at "nothing else" was 28%. The audit had to model the pool minute by minute to see it (which jobs were running whenever something queued), because no single job's duration shows it and the queue is attributed to GitHub rather than to the jobs filling the pool. Count the macOS jobs a pull request and a merge launch, compare with the plan's limit, and treat every job over it as a job that delays every other.
28. **A recorded decision carries the premise it was made on, and the premise can expire while the decision stands.** PostRoll's workflow comments record, twice, that the same reels rendering twice per event was decided on purpose (#571) and priced at "about 200s of wall clock and nothing else" because the runners are free, with the instruction "do not re-open it on the strength of the wall clock alone". Every word was true when written; the premise (that a free runner has no other cost) stopped being true the day the repo had enough traffic to fill five runners, and the decision went on being cited as settled. A recorded decision should name what it rests on in a form that can be re-measured (here: the pool is never full), so that a later audit re-checks the premise rather than deferring to the conclusion (L61, L244). The audit re-opened it on the strength of the runner limit, which is a different premise than the one the comment forbade. Overture has it twice in one repo. Its `ci.yml` header prices a private repository's 2,000 minute allowance for a repository that is now public and free, and its closed issue #2487 proposed a lighter test scheme on the premise that building the app was the cost, which was measured months later to save nothing because the build is 20 seconds of a 525 second run. A decision recorded in an issue carries its premise exactly as a workflow comment does, and the premise there was never measured before the decision was made. claude-config had seven in one repo, all dated 2026-08-21 and all a week stale: the runner's header, the workflow's core count and per-section cost and deadline, README's counts, and a DESIGN.md rejection resting on a number that has since more than doubled. A date on a number makes it more trusted, not less, which is why dated numbers need a pin or a command rather than a comment. Downbeat's gate still says the suite takes two to three minutes in six places, the premise the green memo was justified on, against 46 seconds measured; the memo is still right and the sentence is still wrong. Overture's third pass found the same sentence in AGENTS.md: a two-lane design justified by "a Swift suite of 177s" measured 2026-08-13, three times wrong sixteen days later, in the one file that elsewhere refuses to state the run time for exactly this reason.
29. **A partial run that reports a verdict is worse than a failed run, and a change to how a suite runs is the moment it happens.** Overture's parallel experiment executed 4,875 of 8,595 tests, lost a whole worker's share with no crash line, and ended with `Failing tests:` naming twelve. Nothing in that output says 3,720 tests did not run, and the wrapper's baseline gate, built for exactly this, could not parse the new format and said so in a line nobody was looking for. Any change to a runner's mode (parallel workers, sharding, a new scheme, a new reporter) has to be judged first by the count of tests executed against the count expected, before a single failure is read, because the failures are the visible half and the absences are the half that matters (L98, L11). PlayedIt is the repo about to make such a change with no count at all: it already runs on two simulator clones, its executed count drifts legitimately as tests are added, and nothing writes the count anywhere, so the readout was made the first task of its parallel-testing issue rather than a follow-up. claude-config's runner already fails a suite that leaves no result line, and had no readout for a suite that finishes early with fewer checks, which is the partial run that reports a verdict; the count readout was filed ahead of the shard rebalance that could cause it. Downbeat produced the case by accident during its second pass: a filtered run whose identifiers matched nothing printed `Executed 0 tests` and exited 0, and the hook's guard against an empty run covers only the whole suite path, so the count readout was filed there too. PostRoll is the fifth, and the one where the readout exists and does not reach: `suite_counts.py` refuses a leg that ran zero tests and passes one that ran half, and the CI Swift step never goes through it at all, while the same repo has the parallel switch queued; the floor was filed ahead of the switch.
30. **A derivation that every test in a suite needs is computed once per test unless something says otherwise, and the something is one line.** Overture's copy inventory is built twelve times a run, its surfaces report four times, its source walk four times, each by a test that legitimately needs the result and none of which knows the others exist: 130 seconds of a 507 second suite recomputing the same document. The fix is a memo on the default input (a `static let`), and the discipline is that the callers which inject their own input keep building, because those are the tests OF the builder. Look for it whenever a suite has a scan, a parse or a clone in its top ten, and check that the memo could not capture an empty result, because a memoised empty scan passes every reader at once. Downbeat is the same shape at a smaller scale: a repository walk that 24 guard suites each recompute per test, 206 tests taking 10.9 of the suite's 27 seconds, a `static func` where a `static let` would do. PostRoll has both shapes at once: three banner legibility tests that each re-render every one of about 40 states, two of them drawing the identical pictures (74 seconds, about 27 of them twice), and source walks that are `static func` in Swift and uncached module functions in Python, one of which re-reads every Swift test file in each of 22 tests. The empty-scan caveat is what the repo's own "the scanner can still see one" proofs exist for, so a memo there is guarded before it is written. Overture's third pass, reading the table again with Downbeat's addition in hand, found 29 more suites doing it: every one calls a static function that walks and reads about 500 app files, 58 seconds beyond the four suites its first pass had named, and one memo covers all of them.
31. **When the tests are the time, the suite's own concurrency setting is the first thing to read, and read it in the runner you actually use.** Swift Testing runs in parallel under `swift test` and serially under an Xcode scheme whose testable says `parallelizable = "NO"`, which is what the project generator writes when nobody says otherwise. Overture's suite carried a process-wide lock written on the belief that suites run concurrently by default, in a scheme where nothing ever had, and the belief was recorded in the lock's own header as fact. Sum the per-test durations the runner prints and compare with the wall clock: equal means one core, and no reading of the source will tell you that. PostRoll gave the reading in the runner's own log: 416.7 seconds of summed test bodies against a 417.8 second testing phase, one core, in a project whose scheme carries no `parallelizable` at all because xcodegen wrote none, and whose local run on twelve cores is the same serial suite. The sum and the wall clock were both already printed; nobody had subtracted them.

