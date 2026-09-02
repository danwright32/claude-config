# Pennie-side issue triage for the global guidelines audit

Date: 2026-07-27

Repos covered (issue counts verified complete against GitHub's own totals before triage):

1. Try-Pennie/slate: 552 issues
2. Try-Pennie/project-enrollment-tracker: 489 issues
3. Try-Pennie/bidspoke: 483 issues
4. dwright-pennie/new-agent-onboarding: 243 issues
5. Manager Goal Tracking: no repo found. All repos in Try-Pennie, dwright-pennie, and Halo-lab-Trypennie were listed and none match goal, track, tracking, or manager. The project appears to live only as a local data analysis workspace.

Total: 1,767 issues classified. Every issue was classified from title and labels; roughly 100 issues per repo (413 total) were deep read (body plus comments) prioritizing likely lessons, a cap Dan raised from the handoff's 40 mid-run. GitHub was touched read-only throughout.

Classification: LESSON (teaches a build-time rule), FEATURE, CHORE, UNCLEAR. Each LESSON carries a root-cause family tag and a one-line forward-looking rule. Family tags were invented independently per repo, so closely related tags differ in name across sections; the final synthesis section clusters them.

## Try-Pennie/slate

Counts: total 552 / lesson 190 / feature 228 / chore 134 / unclear 0

### concurrency-not-idempotent (30)
- slate#5, slate#6, slate#163, slate#169, slate#398, slate#413, slate#449, slate#519, slate#674: every user-triggered or automated mutation (book, cancel, reschedule, reassign, replay) must carry a DB-level idempotency or locking guard from day one; assume every submit arrives twice, every cron tick overlaps its predecessor, and every admin action gets double-clicked (a client-side disabled button is not a guard).
- slate#166, slate#586, slate#739, slate#770, slate#778: when a write-through cache (busy_blocks) is fed by both a mutation path and a background sync or reconcile sweep, design the dedup marker and the race window between them up front; a repair sweep that reads then inserts will collide with the very writes it repairs unless it skips recent rows or claims per row.
- slate#613, slate#429, slate#428, slate#431, slate#469, slate#666, slate#518, slate#1048: any operation spanning a DB write plus an external API call (Google event, webhook) needs an outbox or durable resume from the first version; a crash between the insert and the side effect must not lose the side effect permanently, and every entry path (including anonymous bookings) must go through the crash-safe primitive.
- slate#615, slate#480, slate#759: multi-step state transitions must re-check current state atomically at commit; an unconditional update can resurrect a concurrently cancelled record, clobber a concurrent reassign, or orphan the previous external artifact.
- slate#614: dedupe and idempotency keys must be unique per emission, not per target value; keying a rescheduled webhook on the destination time silently suppresses a move back to a previously used time.
- slate#78: a retry path that re-creates an external resource must converge with the fallback resource the first attempt left behind, not add a second one.
- slate#623: background sweeps over shared rows need a per-row claim so a concurrent manual action cannot double-deliver the same row.
- slate#629: client-side fetches keyed by user navigation need an abort or sequence guard so a stale response cannot overwrite a newer one.
- slate#1089: when a multi-step attempt fails partway (slot taken at 409), roll back every counted side effect (the per-contact cap) in the same breath.

### security-not-built-in (18)
- slate#588, slate#589, slate#599: authentication and role ceilings are launch requirements, not hardening; enforce domain restriction server-side, block privilege escalation through impersonation, and never auto-grant admin to the first login.
- slate#351, slate#596, slate#624: every new API route ships with an explicit answer to who may call it and whose data it touches; an unauthenticated or unscoped route leaks internal routing data and breaks multi-org isolation.
- slate#170, slate#593: postMessage handlers must verify origin on receive and set a concrete targetOrigin on send from the first version, on both sides of the frame.
- slate#591, slate#594, slate#600: handle secrets with standard hygiene by default: never in URLs, constant-time comparison, per-message signatures rather than one static header.
- slate#592, slate#1024, slate#1032, slate#1034: baseline transport and input hardening (security headers, enforced HTTPS, https-only webhook targets, payload size caps) belongs in the first deploy of any public endpoint.
- slate#597, slate#601: rate limiters and caches must fail closed and run after the auth gate; a per-key limiter alone cannot protect against a leaked key.
- slate#544: gate UI controls and their backing routes with the same permission check from one shared source, so a role never sees a button it cannot use.

### silent-failure-swallowed-error (15)
- slate#34, slate#277, slate#313, slate#314, slate#963, slate#1036, slate#1049: never destructure a Supabase result without checking error; a swallowed read on a decision path returns an empty pool, silently kills availability, treats every synced agent as brand new, or marks a webhook outbox step done while the event is permanently lost. Every read that feeds a decision must throw or alert on failure.
- slate#401, slate#617: treat external delete and update calls as failed unless proven otherwise; a `.catch(() => {})` on a Google delete leaves live calendar invites, and treating HTTP 410 as success makes writes to deleted events silently vanish.
- slate#223, slate#903, slate#635: any cap or truncation on a list or sweep must be visible to its consumer (a count, a flag, an alert), never a silent drop of the tail.
- slate#226, slate#533: when reference data can be incomplete or ambiguous (agent matches no bucket, user has two schedules), surface it loudly instead of silently excluding or silently picking one.
- slate#757: when one sweep in a family alerts on what it cleans, its siblings must too; repair work done silently hides real losses.

### platform-limit-ignored (13)
- slate#44, slate#164, slate#238, slate#294, slate#760, slate#762: size every cron lane and background job against Cloudflare Worker CPU and subrequest ceilings at target scale (200 agents) before shipping, and do not share one invocation's budget across multiple lanes; measure the live ceiling, do not assume it.
- slate#152, slate#167, slate#171, slate#225: bound every fan-out over external APIs (per-agent Google calls, pagination loops, verify waves) with explicit caps and budgets at design time, not after the pool grows.
- slate#725, slate#828: never consume a PostgREST list read as an aggregate without pagination or a server-side count; the silent 1000-row cap turns truncation into overbooking.
- slate#512: a fixed scan cap on a sweep must rotate or page so the tail beyond the cap is still eventually covered; a newest-first order plus a cap starves the oldest rows forever.

### fails-open-or-silent-noop (11)
- slate#113, slate#214, slate#233, slate#766, slate#982: every CI job, deploy step, and pre-push guard must fail loudly when its own credentials or preconditions are missing; a check that logs "skipping" and exits 0 is worse than no check because it manufactures false confidence (the drift check no-opped through three schema incidents).
- slate#165, slate#1019: required config and secrets must be declared where the deploy actually reads them and verified at deploy time; a silent fallback (localhost URL surviving only because CI happens to inject the real value) poisons production the first time someone deploys manually.
- slate#397, slate#456: a test scenario that cannot run must fail the run or print a loud skip notice, never exit green having exercised nothing.
- slate#796: when a protective layer deliberately fails open (rate limiter outage must not block real users), the fail-open event itself must log and alert; silent fail-open is indistinguishable from working.
- slate#1035: alerting is itself a failure path; live-verify the alert channel once and surface unconfigured or failed sends instead of no-oping.

### stuck-ui-no-failure-state (10)
- slate#168, slate#625, slate#626, slate#628, slate#630, slate#631: every async action wraps its await in try/catch/finally from the first version, clears the busy flag in finally, and pairs the spinner with a timeout that converts a stall into an actionable error; working, still alive, and failed must be visibly distinct states.
- slate#627: never render the empty-state message while data is still loading or after a failed fetch; loading, empty, and error are three different states and mapping !ok to an empty list conflates them.
- slate#634: every terminal state (invalid link, cancelled booking) offers a next step, never a dead end.
- slate#636: action feedback must be tied to the action instance (not a query param) so banners cannot go stale, and must carry a status role.
- slate#1076: when the server refuses or fails an admin action, show that outcome in the UI instead of appearing to succeed.

### test-gate-gap (10)
- slate#490, slate#848: pre-push gates must test exactly the committed tree being pushed (not the working tree) and must fully sandbox their own fixtures (scrub GIT_DIR) so they cannot leak artifacts into the pushed branch.
- slate#412: the local gate must run everything CI runs, including the production build, or build-only breaks still reach main.
- slate#402: a test must assert the real external effect (the calendar event is gone), not just the API's claimed success.
- slate#396: smoke and E2E tests get isolated fixtures (is_test buckets, dedicated mailboxes) from the start, never the production fleet.
- slate#603, slate#604, slate#611, slate#612: keep the test signal honest: measure coverage, do not fail-fast in a way that hides later failures, keep main green and close stale known-issue notes, and state explicitly what CI green does not cover (no browser layer).
- slate#606: every permission-gated route gets an authz denial test in the same commit as the route.

### platform-semantics-misread (9)
- slate#141, slate#142: verify framework behavior changes (React 19 form auto-reset, controlled input rules) against docs before relying on remembered semantics.
- slate#191, slate#503: on Cloudflare, fire-and-forget work dies with the response; route all background work through waitUntil or after() as a rule, and audit for it whenever adding any.
- slate#801: confirm the platform actually captures your logging channel; console.log lines that never reach production logs are silent observability loss.
- slate#35: know your client library's constraint semantics; supabase-js upsert on_conflict cannot target a partial unique index, so every sync write failed with 42P10 and the cache silently drifted from live.
- slate#620: know your query layer's string semantics; raw ilike treats underscore and percent as wildcards, so escape user input used in pattern matches.
- slate#917: map external API error codes precisely; a Google 403 rate limit is not an account-gone signal.
- slate#969: check external API notification defaults (Google sendUpdates=all) before reusing a create/delete helper in a context where the customer must not be emailed.

### rule-enforced-inconsistently (8)
- slate#527, slate#536, slate#540: every booking rule (daily cap, buffers, min notice, working hours) must be enforced by one shared checker used by every path that can place a booking (create, reschedule, reroute, verify), not only the slot display; a rule checked in one place is a rule not enforced.
- slate#266: eligibility filters (active, bookable, not deactivated) must apply on fallback and alternate paths exactly as on the primary path.
- slate#618: model state machines explicitly and block invalid transitions (completed to cancelled) at the mutation layer on every route, not just the one that happens to check.
- slate#100: invariant guards on admin mutations include self-inflicted lockouts; block or confirm self-demotion the same way last-admin removal is blocked.
- slate#987, slate#988: the moment a value set becomes admin-editable, remove every hardcoded reference to its members and validate submitted codes on every entry path, including machine APIs.

### missing-db-constraint (8)
- slate#263, slate#432, slate#265: add foreign keys and referential-integrity guards with the tables themselves; a hard delete without them orphans dependent records, so prefer soft-delete for externally synced entities.
- slate#513, slate#532, slate#537, slate#876: encode every one-row-per-X invariant (one busy_block per booking, one schedule per user, one endpoint per URL per org) as a unique constraint or partial unique index at schema time, remembering that Postgres treats nulls as distinct in unique indexes.
- slate#299: reference data completeness (every bookable agent has routing attributes) needs a constraint or standing alert, not an assumption; 12 agents silently matched no bucket.

### lifecycle-cleanup-missed (7)
- slate#12, slate#19, slate#239, slate#248, slate#274: when an entity exits a state (calendar unwatched, agent deactivated or leaves the pool), delete or stop every derived resource in the same change: busy blocks, watch channels, sync loop membership, vanished events.
- slate#134: when a record is edited, update every external artifact derived from it (the approved Slack message) instead of posting a new one and orphaning the old.
- slate#267: when replacing a deployed component (cron worker), decommission the old one in the same change or both fire and drift apart.

### stale-docs-drift (7)
- slate#639, slate#640, slate#641, slate#642, slate#643, slate#644, slate#645: update README, DEPLOY, and architecture docs in the same PR as any change to deploy process, crons, secrets, domains, or system layout; the audit found seven separate docs describing a system that no longer existed, including a secret list missing half the required secrets.

### alert-noise-false-positive (5)
- slate#87, slate#673, slate#758, slate#784: design every alert against its false-positive sources at creation time: transient blips that self-heal, preview and lookup traffic, chained-crash edge cases, and the perfectly normal window where async cleanup is still in flight; an alert that cries wolf gets ignored.
- slate#572: cap or aggregate alert volume during a broad outage so one incident does not page once per affected item.

### error-contract-sloppy (5)
- slate#479, slate#484, slate#717, slate#621: map every known failure mode of a route to a typed, correct status at the time the route is written; a legitimate no-availability or terminal-state outcome returned as a generic 500, or every outage flattened to 409 by substring matching, misleads every caller and automation retry policy.
- slate#622: validate and parse request inputs (date strings) with the same schema rigor on every route so bad input is a 400, never an unhandled 500.

### ops-readiness-gap (5)
- slate#595, slate#1027, slate#1028, slate#1029, slate#1042: production go-live has a fixed checklist that is not optional: health endpoint plus rollback runbook, server-side branch protection, verified backups with a restore drill, a stated PII retention and erasure posture, and SAST plus secret scanning in CI.

### wrong-assumption-domain (4)
- slate#7, slate#42: enumerate the real-world data sources up front; busy time comes from all of an agent's calendars with an explicit, tested decision about which ones count (writer access on a shared team OOO calendar is not ownership, and one teammate's OOO must not blank everyone's availability).
- slate#523: any self-check on a modify-in-place operation must exclude the entity's own current footprint, or the booking's own event makes the agent look busy and silently re-routes the customer to a different advisor.
- slate#619: design uniqueness keys against real data shapes; the same Google event id can legitimately appear on two of one agent's calendars.

### migration-deploy-drift (4)
- slate#276, slate#482, slate#516, slate#814: make applying DB migrations a blocking part of the deploy pipeline itself (code filtering on a not-yet-applied column silently emptied availability), alert when the applied version lags the deployed code, and make the lag check detect a gap anywhere in the sequence, not only at the head.

### leaked-internal-or-pii (4)
- slate#259, slate#590: audit every lead-facing surface and every committed example file for internal labels and real personal data before shipping; never paste production records into fixtures or demos.
- slate#598, slate#707: client-facing error responses return a generic message; raw internal err.message strings go only to server logs.

### external-call-unbounded (3)
- slate#11, slate#485, slate#922: every outbound call (webhooks, token fetches, reachability probes) ships with a timeout and a bounded retry policy on day one, never a bare fetch.

### misleading-metric-or-signal (3)
- slate#201, slate#303, slate#487: define a metric's denominator and wording precisely when creating it: exclude undecided items from rates, make a load test measure freshness while the lane under test is actually running, and keep alert copy in sync with the actual job schedule.

### timezone-assumption (2)
- slate#616, slate#908: never let UTC defaults stand in for a real zone: expand all-day events in the owner's timezone (not UTC midnight, which frees the agent's local afternoon), and render every timestamp surface in one explicitly chosen zone so the same booking never shows two times.

### dependency-hygiene-missing (2)
- slate#1025, slate#1026: turn on dependency vulnerability scanning at repo creation and keep the framework within patched versions; four high advisories including an auth middleware bypass accumulated unnoticed.

### point-in-time-data-not-captured (2)
- slate#158, slate#203: persist facts as real columns at write time instead of inferring them from magic values or resolving them through a deletable foreign key; attribution and flags must survive offboarding and future edits.

### a11y-not-default (2)
- slate#632, slate#633: forms get visible labels (placeholders are not labels) and dynamic state changes (loading, empty, loaded) get screen reader announcements as part of the first build, not an audit fix.

### ui-interaction-untested (2)
- slate#706, slate#951: verify UI changes by actually loading them in both themes and interacting; a dark-theme gutter from scoping the theme attribute to the wrong element and a full-page reload on every filter change (native GET form submit) both ship invisibly when you only read the code.

### dev-env-parity (1)
- slate#40: build auth redirects from the request origin, not a prod-pointing env var; otherwise the local flow bounces to production mid-login and the environment cannot exercise its own gated pages.

## Try-Pennie/project-enrollment-tracker

Counts: total 489 / lesson 194 / feature 146 / chore 149 / unclear 0

Classification notes: milestone and plan phase issues (CSP lockdown, auth rebuild, promotion handling, first pay rule rewrite, drill down) are counted as FEATURE. Proactive hardening (new alerts, heartbeats, dead man switches) is FEATURE; extensions of an existing guard, doc syncs, retirements of superseded checks, and data cleanups are CHORE. LESSON is reserved for issues that describe a defect, wrong assumption, silent failure, or misdesign in how the code was built. About 97 issues were deep read (body plus comments); the rest were classified from title and labels. One notable reclassification from deep reading: #325 was closed as not a bug (the audit grepped only app.js and missed the class set in the baked HTML), so it is counted as chore.

### security-afterthought (19)

- project-enrollment-tracker#456, project-enrollment-tracker#457, project-enrollment-tracker#49, project-enrollment-tracker#50: Gate every surface server side from day one: before calling a route or page done, state who may call it and whose data it touches; client side JS checks and an SSO allowlist that runs after data is served are not auth (the entire baked dashboard, 562KB of rep PII, was publicly fetchable with curl).
- project-enrollment-tracker#459, project-enrollment-tracker#505, project-enrollment-tracker#57: Escape every string interpolated into innerHTML, including error parameters, team names, and feed supplied names; escaping some fields in a table while concatenating others raw is how latent XSS surfaces ship.
- project-enrollment-tracker#471: Ship the migration that enables a security control (RLS) in the same change as the schema; a control that exists only as a comment protects nothing.
- project-enrollment-tracker#467, project-enrollment-tracker#517, project-enrollment-tracker#526, project-enrollment-tracker#522, project-enrollment-tracker#468: Ship baseline hardening with the first deploy (CSP and security headers, least privilege workflow permissions, rate limits on write endpoints, server side validation of value types and ranges, session tokens out of localStorage) instead of leaving it for a later security pass.
- project-enrollment-tracker#458, project-enrollment-tracker#548: Pin and integrity check everything pulled from a third party: CDN scripts get exact versions plus SRI, downloaded binaries get checksum verification.
- project-enrollment-tracker#490: Never disable host key checking to make an SFTP step work; solve trust properly.
- project-enrollment-tracker#599: Audit platform defaults that publish things (Pages build comments auto posting preview URLs) whenever the content is private.
- project-enrollment-tracker#492, project-enrollment-tracker#59: Return generic error bodies from API routes everywhere; passing raw upstream errors leaks internals and erodes the convention one route at a time.

### silent-failure-swallowed-error (17)

- project-enrollment-tracker#47, project-enrollment-tracker#63, project-enrollment-tracker#40, project-enrollment-tracker#38: Never convert a failed external operation into fake success: a bare catch on a transport error, a cleanup call in finally that masks the result, a shell || echo, and continue-on-error on a validation step each shipped stale or broken data as green.
- project-enrollment-tracker#48, project-enrollment-tracker#18: Missing credentials must fail the build fast with a clear error, never degrade to a silently empty deploy.
- project-enrollment-tracker#461, project-enrollment-tracker#497, project-enrollment-tracker#193: A fetch or parse failure must never quietly default to an empty dataset that then ships or silently skips a refresh; retry, then fail the build or alert with a pointer to the corrupt input.
- project-enrollment-tracker#744, project-enrollment-tracker#670: Every write must reconcile and report what actually landed versus what was computed, and a best effort write that a safety guard depends on must alert when it fails instead of leaving the guard quietly blind the next day.
- project-enrollment-tracker#42, project-enrollment-tracker#58: Treat a write that matched zero rows (PATCH with no target returning 204) as a failure to surface, not a success.
- project-enrollment-tracker#440, project-enrollment-tracker#296: Alert delivery and user saves are failure paths too: check the send helper's return value and exit nonzero on a failed Slack send (curl -s to a dead webhook exits 0), and surface failed behind login saves.
- project-enrollment-tracker#496: Preserve upstream error identity; passing a dependency's 401 through verbatim makes a backend misconfiguration indistinguishable from session expiry.
- project-enrollment-tracker#511: Keep stress test hooks out of production code paths; an env var leaking into the build silently scales every KPI to 65 percent with no other signal.

### unverified-domain-assumption (15)

- project-enrollment-tracker#171, project-enrollment-tracker#169, project-enrollment-tracker#658, project-enrollment-tracker#699, project-enrollment-tracker#697: Verify vendor field semantics against real data before building a metric on them: bucketing by a mutable draft date instead of the immutable original pushed the first pay rate past 100 percent, a flag is always true for one platform, a status field that never reports failures is not evidence of success, and a remainder bucket's label stops being true once a month closes.
- project-enrollment-tracker#712, project-enrollment-tracker#647: Measure a stated data model assumption before baking it into schema and docs; the one platform per rep assumption was false, got falser every month, and forced a lossy single valued source column.
- project-enrollment-tracker#163, project-enrollment-tracker#159, project-enrollment-tracker#603: Confirm the real business calendar with the business before hardcoding it; reps work a five of six Monday to Saturday week, and every Monday to Friday denominator and attribution rule under rated them.
- project-enrollment-tracker#158, project-enrollment-tracker#51: Derive days worked from the actual calendar plus hire and term dates; a placeholder zero and a days with enrollment proxy each corrupted the rankings from a different writer.
- project-enrollment-tracker#646: Keep semantically different dates apart; hire_date rows holding a promotion or demotion date instead of a hire date broke floor proration and flagged phantom pre floor production.
- project-enrollment-tracker#43: Never let a destructive reconcile fire on a weak heuristic (one CommissionMetric row means the month is official); require corroborating signals before zeroing estimates.
- project-enrollment-tracker#625: Model the real domain events (promotion versus departure) as distinct actions; an offboard endpoint that can only write term_date keeps writing the wrong field for promotions and zeroes their final month.

### dead-or-blind-guard (12)

- project-enrollment-tracker#737, project-enrollment-tracker#736, project-enrollment-tracker#735, project-enrollment-tracker#734, project-enrollment-tracker#347: Prove every guard can actually speak: seed a real difference and assert the guard names it, drive the gate end to end rather than only its helpers, make every fail open path announce itself, and verify activation (rsync -an prints nothing ever; a merge base resolving to HEAD exits 0 silently; a relative hooksPath means the hook never runs from a subdirectory or fresh clone).
- project-enrollment-tracker#498: A test asserting the hidden state of an element no code path can ever show is a misleading green; assert the feature fires, not only that it is currently off.
- project-enrollment-tracker#516: Schema guards that only regex match migration text prove nothing; actually apply migrations in a test database so a broken migration fails CI instead of prod apply.
- project-enrollment-tracker#465: Run CI on push to main, not only on PRs; squash merges and bot pushed commits landed on main with zero checks.
- project-enrollment-tracker#510: Derive monitoring coverage from the source of truth instead of a hand list; the only backup job was the one missing from the dead man's switch, and a hand list keeps drifting.
- project-enrollment-tracker#257: An alert must not depend on the healthy operation of the thing it watches; a hung run must not be able to block the deadline alert.
- project-enrollment-tracker#67: A defensive divide guard can hide the exact drift a check exists to find; guards must fail visible, not smooth over.
- project-enrollment-tracker#716: A one click permanent suppression list with no revisit path means enrollments can land forever under a name nobody will ever be told about; every deliberate silence needs a periodic audit signal.

### two-writers-unreconciled (9)

- project-enrollment-tracker#469, project-enrollment-tracker#53, project-enrollment-tracker#34: Never persist a whole document blob that two editors or two async paths can hold at once; patch only the changed key or use optimistic concurrency with a 409, since last write wins silently erased attendance edits (the same class as the April data loss).
- project-enrollment-tracker#26, project-enrollment-tracker#673: Give every column exactly one owning writer; a second writer (backfill versus refresh-cleared, the daily refresh versus a deliberate recompute) silently walks back correct data and nothing flags the reversal until a human notices the number has not moved.
- project-enrollment-tracker#668: Accumulate by canonical key before emitting writes; one PATCH per raw feed name clobbered the previous spelling's count, lost 44 first payments, and reported 102 rows updated with success.
- project-enrollment-tracker#72, project-enrollment-tracker#551, project-enrollment-tracker#523: Assume every scheduled or triggered action can run twice concurrently (overlapping crons, concurrent pushes to main, a read then write cooldown check) and protect it with a lock, rebase and retry, or an idempotency key.

### frontend-state-desync (9)

- project-enrollment-tracker#25, project-enrollment-tracker#32, project-enrollment-tracker#33: Validate and normalize at the input edge: a classList token with spaces threw mid save and desynced UI, memory, and server; a blank numeric edit committed NaN everywhere; $K and $M strings sorted wrong.
- project-enrollment-tracker#37, project-enrollment-tracker#36, project-enrollment-tracker#501: Derive rendered state from one source of truth; split title and data-tip attributes, a tooltip selector collision, and an incomplete class reset list all left stale UI after updates.
- project-enrollment-tracker#756: Apply roster filters consistently across pages; the dashboard filtered out departed and promoted people but the alias page rendered every stored row, showing dead team headers and departed reps.
- project-enrollment-tracker#69, project-enrollment-tracker#70: A hand rolled multi thousand line DOM app accumulates state bugs by default; keep rendering pure and test the navigation and edit paths, not just the initial paint.

### inconsistent-pattern-application (9)

- project-enrollment-tracker#721, project-enrollment-tracker#724, project-enrollment-tracker#68: When a helper encodes a rule (excludeKey, parseExcludedAgents, the exclusion list), route every consumer through it and make the convention guard assert how consumers obtain the data, not just that they call the helper; three hand rolled comparisons each silently missed the rule the helper promised while the single source guard read green.
- project-enrollment-tracker#56, project-enrollment-tracker#470, project-enrollment-tracker#481, project-enrollment-tracker#41, project-enrollment-tracker#138: Before shipping a cross cutting pattern (an override, an audit trail, retry and timeout, an auth header, a required field on insert), enumerate every call site and table it applies to and cover them all in the same change; each of these left exactly one path uncovered.
- project-enrollment-tracker#776: When fixing a guard's blind spot (the #745 terminated rep drop), apply the fix to every sibling using the same shared helper in the same pass; refresh-top kept the blind spot refresh-cleared had just lost.

### tested-artifact-differs-from-shipped (9)

- project-enrollment-tracker#804, project-enrollment-tracker#421, project-enrollment-tracker#843: Point guards and tests at the generated page and the live HTTP response, not the source template or the _headers file; a guard on the wrong artifact and banner wiring no test exercises both let the shipped thing drift unverified.
- project-enrollment-tracker#814: CI must run the same gates the deploy runs; a change passed all of CI, then failed the deploy time data quality gate and froze production for the day.
- project-enrollment-tracker#334, project-enrollment-tracker#277, project-enrollment-tracker#234, project-enrollment-tracker#132, project-enrollment-tracker#485: Test exactly what ships: always rebuild fixtures instead of trusting a stale dist (a stale build produced a false failure), keep the working checkout current before reading it, never compile the auth path out of the test build, and use npm ci so production installs match the dependency set CI tested.

### current-state-applied-to-history (8)

- project-enrollment-tracker#593, project-enrollment-tracker#14: Stamp history rows with point in time attributes captured during the month, never with the live roster at finalize time; a rep who moved teams on the 20th had all 15 of June's units credited to the team he joined for the last week.
- project-enrollment-tracker#13, project-enrollment-tracker#12, project-enrollment-tracker#11, project-enrollment-tracker#35, project-enrollment-tracker#31, project-enrollment-tracker#96: Every render or export of a past month must read that month's stored state (team, week structure, status codes), never current month globals; sweep for current month assumptions whenever a view becomes month navigable.

### time-and-month-boundary (8)

- project-enrollment-tracker#460, project-enrollment-tracker#54, project-enrollment-tracker#495, project-enrollment-tracker#539: Compute every business date in America/New_York through one shared helper, never from the host UTC clock or a month based DST approximation; an evening month end rebuild bakes next month early and late evening edits stamp the wrong month.
- project-enrollment-tracker#444, project-enrollment-tracker#446, project-enrollment-tracker#567: Pin tests, fixture builds, and client pacing math to the baked reference date; the wall clock class bit twice (build side, then client side calling buildContext with no argument) and fails silently with wrong numbers, so guard against reintroduction with a lint or test.
- project-enrollment-tracker#447: Design and test the 1st of month pre feed state explicitly instead of discovering a blank board in production at noon.

### ux-feedback-gap (8)

- project-enrollment-tracker#500, project-enrollment-tracker#502, project-enrollment-tracker#472: Every user action needs visibly distinct started, still alive, and failed states; silent no ops, month loads with no progress signal, and a login button stuck on Redirecting forever are defects, not polish.
- project-enrollment-tracker#506, project-enrollment-tracker#477: Handle session expiry as a first class path: refresh the token or redirect to login instead of capturing the token once at page load and dead ending on 401 an hour later.
- project-enrollment-tracker#478: Actions that change data attribution need confirmation or undo, not instant irreversible effect.
- project-enrollment-tracker#508: Update rows in place; refetching and rebuilding the whole table after every field save loses the user's place mid worklist.
- project-enrollment-tracker#667: Disabled navigation must look disabled; do not leave a dead arrow looking clickable.

### duplicate-implementation-drift (8)

- project-enrollment-tracker#671, project-enrollment-tracker#649: The moment a second consumer needs the same fold or derivation, extract one shared implementation; refresh-top and refresh-cleared folding names differently hid the #668 data loss, and two live conventions for deriving hire_date differ by a week of commission eligibility.
- project-enrollment-tracker#3, project-enrollment-tracker#612: One definition of commission eligibility, in one module, with the boundary encoded once; an open coded strict comparison versus the library's on or before put two real reps on the June board while commission excluded them.
- project-enrollment-tracker#503: Shared browser helpers (showToast, authedFetch) triplicated across pages drift in behavior; ship them as one module from the start.
- project-enrollment-tracker#840, project-enrollment-tracker#839: Do not build a second signal for a condition an existing signal already covers (two overlapping freshness indicators with subtly different meanings); unify before both ship.
- project-enrollment-tracker#66: Keep one source of schema truth and guard it; a hand maintained schema.sql lost a table and columns relative to the real database.

### untested-failure-path (8)

- project-enrollment-tracker#46, project-enrollment-tracker#55, project-enrollment-tracker#579: Exercise null and empty set paths before shipping: a missing full_name crashed the build, a fully offboarded team threw a TypeError, and reps with a null hire date silently never appear in the goal digest.
- project-enrollment-tracker#473: Every gated page needs a bootstrap failsafe; two of three pages lacked the 3 second reveal the third had, so a failed CDN load left a permanent blank page.
- project-enrollment-tracker#514: Reconciliation must handle the rows vanish entirely case, not only the value changed case; a vanished rep kept phantom units until month close.
- project-enrollment-tracker#488: Bound every workflow job with timeout-minutes; one hung SFTP step at the 6 hour default queued every later cron behind the concurrency group.
- project-enrollment-tracker#486: An external dependency (a link public sheet) needs retries and a failure alert, and its availability assumption should be recorded as a decision.
- project-enrollment-tracker#464: Decide the backup and restore story for human entered data before it exists only in one table.

### shipped-dead-code-unverified (7)

- project-enrollment-tracker#52, project-enrollment-tracker#480, project-enrollment-tracker#474: Prove a mechanism fires end to end before calling it done: an undefined TOKEN left inline editing entirely dead, sign out called window.client that no page ever set (so refresh tokens were never revoked), and a staleness badge had no consumer in any script.
- project-enrollment-tracker#479, project-enrollment-tracker#484, project-enrollment-tracker#30, project-enrollment-tracker#491: Never let UI copy, docs, or comments promise behavior the code does not implement: a sticky override whose promised clear action has no UI, goal proration documented in the PRD but built nowhere, a column label defining a different formula than the code computes, and a lock table whose comment claims enforcement no code performs.

### platform-limit-ignored (7)

- project-enrollment-tracker#135, project-enrollment-tracker#493, project-enrollment-tracker#62, project-enrollment-tracker#61: Assume PostgREST returns at most 1000 rows and Salesforce queries cap; paginate every table read from day one or results silently truncate.
- project-enrollment-tracker#45: Pagination code that only ever fetches page one is untested dead code; test the second page explicitly.
- project-enrollment-tracker#494: Offset paging needs a unique stable order clause or concurrent writes mid walk skip and duplicate rows; make the paging helper reject order less URLs.
- project-enrollment-tracker#524: Filter server side; pulling whole tables to filter in JS breaks at platform caps and wastes every request.

### accessibility-not-built-in (7)

- project-enrollment-tracker#475, project-enrollment-tracker#476: Build keyboard and touch parity from the start; hover only tooltips and mouse only sorting exclude whole classes of users.
- project-enrollment-tracker#529, project-enrollment-tracker#530, project-enrollment-tracker#536, project-enrollment-tracker#532: Treat contrast, the project's own minimum text size, skip links, and human readable aria-labels as build time requirements, not audit findings.
- project-enrollment-tracker#487: Add an automated accessibility scan instead of relying on one hand written keyboard spec.

### guard-overfires-unmodeled-legit-case (6)

- project-enrollment-tracker#742, project-enrollment-tracker#436, project-enrollment-tracker#588: A drift check must model legitimate movement before shipping: payment reversals legitimately lower a closed month, the open month is not settled data, and the same evaluated a month too early class false alarmed three separate times before a shared is this month settled helper was proposed; build that helper first, not after the third false alarm.
- project-enrollment-tracker#745: Compare like universes: snapshot the post fold written set rather than the raw feed cohort, or the guard alerts on its own bookkeeping differences.
- project-enrollment-tracker#704: Deduplicate alerts against what was already reported; reposting the identical unresolved name five times in two days trains readers to ignore the channel.
- project-enrollment-tracker#719: Record why each entry was suppressed at the moment of suppression; a flat reason less ignore list made a manager selling look like a departed rep returning, a live false positive path.

### guessed-external-behavior (5)

- project-enrollment-tracker#791, project-enrollment-tracker#462, project-enrollment-tracker#64: Classify an external system's output from captured real samples, never assumed wording, and make the classifier distinguish outage from file not there yet explicitly; a not found regex guessed from OpenSSH wording decides whether a normal late morning pages as a failure.
- project-enrollment-tracker#512: A hand rolled parser must either support the full input format (escaped quotes, embedded newlines) or guard its assumption loudly; an assumption enforced only by a comment silently splits and merges rows when the vendor changes escaping.
- project-enrollment-tracker#128: Learn the API's real response semantics (a 304 from the deploy hook is success) before writing the status check.

### identity-matching-fragility (4)

- project-enrollment-tracker#463, project-enrollment-tracker#44: Fuzzy and nickname matching must check whether a distinct real person shares the name before auto merging; route collisions to a human instead of silently aliasing a new hire into a veteran.
- project-enrollment-tracker#27: When two data sources use different name universes, reconcile them before letting one zero the other's rows.
- project-enrollment-tracker#482: When two alias mechanisms exist, the writer must write to the structure the readers read; half integration left second spellings permanently unresolved and paging humans.

### hand-maintained-field-lists-drift (4)

- project-enrollment-tracker#629, project-enrollment-tracker#631: Define SELECT column lists once and share them; a hand copied list that omits a column (promoted_at) yields undefined, the code silently keeps its old behavior, and the checker and writer disagree forever after.
- project-enrollment-tracker#28, project-enrollment-tracker#29: Guard hand maintained serialization payloads against silent field drops; two dropped fields broke alias resolution and showed $0 cleared volume downstream.

### deploy-not-verified-live (4)

- project-enrollment-tracker#859, project-enrollment-tracker#815, project-enrollment-tracker#119: After every deploy, verify the live site serves the merged commit and fail red otherwise; green CI, a merged PR, five auto closed issues, and a fired deploy hook together proved nothing while production silently stayed frozen on the previous commit, twice.
- project-enrollment-tracker#103: Every path that can deploy (including the platform's own git integration) must pass through the same validation gate as the scheduled pipeline.

### single-dependency-blocks-everything (4)

- project-enrollment-tracker#466, project-enrollment-tracker#369, project-enrollment-tracker#372, project-enrollment-tracker#39: Gate each pipeline step only on the inputs it actually reads; a gate condition copied wholesale meant one late feed (16 percent of volume) froze the other feed's healing, a sheet import that reads no feeds at all, and the whole day's deploy for the 84 percent that arrived.

### stale-input-trusted (3)

- project-enrollment-tracker#838, project-enrollment-tracker#60: Select input files by their authoritative filename date and enforce a staleness ceiling; ordering by modifiedTime and reading the newest file regardless of age both ingest stale data silently during an outage.
- project-enrollment-tracker#589: Reason through how tolerance windows and once per day caches interact; a today or yesterday tolerance plus a deploy cache pinned one source of the dashboard a full day stale on most days while every check stayed green.

### hardcoded-seed-drift (3)

- project-enrollment-tracker#483, project-enrollment-tracker#65: Never leave a hardcoded seed (a teams map) in a code path that has access to the live source; read the auto discovered data with the seed as fallback only, and alert on unknown entries instead of dropping them.
- project-enrollment-tracker#515: A hardcoded human name table encodes its author's bias (the nickname list skewed male); source such tables from data or make their gaps observable.

### missing-static-analysis (1)

- project-enrollment-tracker#518: Adopt standard linting from day one instead of guarding individual footguns with bespoke regex tests; a 4030 line unlinted file shipped an ASI bug that eslint's no-unexpected-multiline catches generically.

## Try-Pennie/bidspoke

Counts: total 483 / lesson 189 / feature 112 / chore 182 / unclear 0

Method note: all 483 titles and labels classified; about 104 issues deep read (body plus comments) to confirm root causes. Follow up work items (audits, guard tests, helpers, refactors, docs) were classified as chores even when they trace back to a defect; the defect record itself carries the lesson.

### silent-failure-swallowed-error (21)

The dominant family: errors caught and discarded, fail open defaults, and false success. Several caused multi day production incidents (a 104K row strand backlog, a purge that silently stopped, a 5 minute lead outage).

- bidspoke#51, bidspoke#460: when a walk or fallback path can fail after the response is sent, inspect the actual result (including r.ok on an inner fetch) before recording the step or execution as completed; never let a destructure or parse discard a failure.
- bidspoke#64, bidspoke#485 (see error-classification-wrong for #485): every throw site must set a real error type, because an alert gate that treats null as "business rejection, stay quiet" turns any untyped failure into silence.
- bidspoke#65, bidspoke#75: a security or dedup check that catches its own lookup error and returns "allowed" fails open; decide fail open versus fail closed explicitly, and always log the check failure.
- bidspoke#74: never let a blanket catch around an eval or expression path swallow a SyntaxError into a null result; a formula that cannot run must error, not silently produce no bid.
- bidspoke#82: treat an application level failure (Slack HTTP 200 with ok:false) as a send failure, and never consume a cooldown or dedup budget when the send did not happen.
- bidspoke#97: client API wrappers must throw on !res.ok like the rest of the client; a replay button whose failure resolves to null leaves the operator believing the action ran.
- bidspoke#129: never call a stateful dependency (circuit breaker DO) fire and forget with swallowed errors; a lost record-error call silently disables the protection it feeds.
- bidspoke#240: "feature not configured" must be a loud, visible state, not a silent null return; missing GitHub credentials made backups silently never happen for weeks.
- bidspoke#303, bidspoke#596: never write `if (!data) return 404` while ignoring the error field; a real DB error must map to 5xx, and a guard for the pattern must cover every syntactic form, not just the one it was written against.
- bidspoke#351: bound big cleanup UPDATEs so they cannot time out at the gateway, and surface their failure; a swept-into-summary.errors exception let a 72K row safety net silently do nothing for weeks.
- bidspoke#391: never cache an empty or errored load as a valid result; keep a last good copy and serve it on transient failure, because one pool blip cached blank credentials and failed every lead for the TTL.
- bidspoke#409: distinguish "query errored" from "row does not exist" in every lookup; conflating them silently dropped alerts exactly during the DB incidents the alerts exist for.
- bidspoke#475: a fallback path must be gated on the specific condition it exists for (not found), not any throw, and falling back to older code or data must emit a visible signal.
- bidspoke#487, bidspoke#588: check rows affected on every UPDATE and DELETE, not just the error field; a zero row write that returns success makes a served lead or a client mutation vanish without trace.
- bidspoke#514: every mutation call in the UI must surface its failure to the user; a swallowed rejection makes a failed rename or removal look like it worked.
- bidspoke#569: a save path must verify persistence and show a distinct confirmed state; a save that can silently not land in the database on a live money flow is the worst kind of failure.
- bidspoke#613: a maintenance job that processes zero items while its backlog grows must alert; "no error" is not the same as "worked", so key alerts off outcomes, not only exceptions.

### ui-state-drift (17)

Frontend state tracked by scattered manual flags and unguarded effects instead of derived from the data.

- bidspoke#92, bidspoke#94, bidspoke#160: derive dirty state from a content signature of the saved versus current definition, never from hand maintained boolean flags scattered across handlers; edits during an in flight save, undo and redo, and post save resets all drifted.
- bidspoke#96: give list editors stable React keys independent of user editable names, or each keystroke remounts the row, loses focus, and collides values.
- bidspoke#99: once a user manually edits a field that is otherwise mirrored from another field, set an edited flag and stop mirroring (the codebase already had this pattern in one form but not the other).
- bidspoke#101: any page that can navigate between ids of the same route must reset state and guard against out of order fetches in its load effect.
- bidspoke#113: render every timestamp in one declared timezone convention per page; mixed raw UTC and ET side by side misleads during incident review.
- bidspoke#241: a panel showing persisted history must refresh (or subscribe) when a save occurs while it is open.
- bidspoke#399: never let optional collapsible sections and a flex-1 editor share one flex column without a minimum height for the primary work area.
- bidspoke#403: memoize row components and stabilize handlers on drag and drop lists, or every button click remeasures and repaints the whole page.
- bidspoke#477, bidspoke#492: anything long running must show working, still alive, and failed as visibly distinct states with a timeout that converts hang into an actionable error; a frozen Running badge and bare infinite spinners are defects, not styling gaps.
- bidspoke#478: the unsaved changes guard must cover in-app router navigation, not only beforeunload; one click on a back link lost live workflow edits.
- bidspoke#493: never gate a critical action (Save) on an optional nicety (an AI changelog draft) or on any third party call without a timeout.
- bidspoke#516: after programmatically inserting content on a canvas, move the viewport to it; work that lands off screen reads as work that did not happen.
- bidspoke#550: constrain user supplied text in fixed width UI (overflow, ellipsis) as part of building the component, not after a report.
- bidspoke#567: graph mutations (insert between, append after) must locate the edge to rewire by exact identity and verify the resulting wiring, then surface it; a silent mis-wire on a money routing canvas was only caught by querying the database.

### concurrency-not-idempotent (13)

Multi step writes designed as if they run exactly once, in order, alone.

- bidspoke#49: never cache a failure as the canonical idempotency result, and store enough (status, headers) to replay the response faithfully; also bypass the cache on deliberate resume or replay.
- bidspoke#50: a resume or replay path must honor exactly the same routing semantics as the live walk (every routed node type, wait_for:first), or it silently re-executes side effecting children down the wrong arm.
- bidspoke#57, bidspoke#483: an exporter must not ship or stamp rows that a concurrent finalizer can still correct; wait for the parent record's terminal state and make the stamp conditional so a winner flip cannot be clobbered then purged.
- bidspoke#63: on timeout, cancel or fence abandoned child promises; a late settling child otherwise double logs contradictory rows and overwrites shared context mid walk.
- bidspoke#66: a timeout wrapper must abort the underlying call (AbortSignal), because racing a timer against a non idempotent POST means the retry double submits a bid the partner already accepted.
- bidspoke#67: await the idempotency processing marker before the first outbound side effect; an unawaited put widens the duplicate window to whole executions.
- bidspoke#78: never read-modify-write a shared map held in an env secret from concurrent request handlers; one lost update silently revoked an unrelated source's key.
- bidspoke#111: any compare-and-swap against an external store (GitHub sha) needs a refetch and retry on conflict, or the newest save silently loses.
- bidspoke#476, bidspoke#490: an idempotency key must be scoped (per source) and must never be derivable to a constant; when every derive field is missing, skip idempotency and warn instead of letting all malformed leads hash identically and leak each other's responses.
- bidspoke#489: never infer "the previous step's output" from object insertion order on shared mutable context that background writers also touch; pass lineage explicitly.
- bidspoke#511: increments must be atomic at the database (single UPDATE expression or RPC), not a select-then-update in application code.

### error-classification-wrong (13)

Transient versus permanent decided by defaults, string matching, or per path ternaries instead of one classifier.

- bidspoke#26, bidspoke#249, bidspoke#694: classify upstream errors by what retrying will actually do: a saturated upstream (REQUEST_LIMIT_EXCEEDED) must not be hammered, and a vendor's transient infrastructure error must retry even when it arrives dressed as HTTP 400 or 500.
- bidspoke#53, bidspoke#318, bidspoke#458: never default an unrecognized thrown error to transient; a deterministic TypeError or a genuinely missing config re-fires non idempotent partner POSTs on every retry, and a permanent 4xx must fail fast.
- bidspoke#107, bidspoke#513: never classify or branch on error message substrings; use status codes and structured error types end to end.
- bidspoke#417: a partner configuration error (blank credential) is our fault, not the partner's; it must not feed the circuit breaker and re-bury the clear signal under circuit_open.
- bidspoke#485, bidspoke#486: there must be exactly one error classification path; the parallel child catch re-implemented a narrower ternary than the main loop and dropped PartnerApiError semantics, and raw errors with null errorType suppressed the per run alert.
- bidspoke#595: distinguish "no matching row" (PGRST116, a 404 per the API contract) from a real database error (5xx) at one shared helper, so the contract cannot vary by handler.
- bidspoke#604: an error type check must handle non Error throws; instanceof narrowing that fails changes live lead fallback behavior.

### missing-auth-scoping (11)

Routes shipped without asking "who can call this and whose data can it touch".

- bidspoke#55, bidspoke#56, bidspoke#76, bidspoke#103: every route that takes an id must verify the resource belongs to the caller's org before acting, including restore, test node, endpoint create and update, and admin-ish surfaces like breaker reset; build the check with the route, not in a later pass.
- bidspoke#70: every query over shared tables must carry the org filter (plus ORDER BY and a limit); metrics reads without scoping leak cross tenant data and scan unbounded rows.
- bidspoke#79: run the ownership check before serving a cached payload, not after; the cache is part of the route's attack surface.
- bidspoke#87: every new table needs RLS and policies at creation time, even rollup tables.
- bidspoke#102: JWT verification needs the full checklist on day one: refresh JWKS on unknown kid, validate aud, reject missing exp.
- bidspoke#258, bidspoke#326: any allowlist or domain gate enforced only in the browser does not exist; enforce it server side in the Worker API from the start.
- bidspoke#335: access management endpoints should be least privilege by default (admin tier), and if the team consciously accepts the risk, record that decision.

### input-not-validated (11)

External data (payloads, upstream responses, user text) trusted at a boundary.

- bidspoke#91: clamp or normalize every fixed width column at the write boundary; one unclamped "California" into VARCHAR(2) killed the entire sighting insert, and the write was best effort so it vanished.
- bidspoke#93, bidspoke#164: validation must reject the dangerous empty and duplicate cases the editor can actually produce: an unconfigured branch arm that evaluates as "match everything" and two arms sharing a label (the routing key) both passed save.
- bidspoke#100: validate names against the charset the rest of the system assumes, and encode every path parameter; a source name with a slash could be created but never revoked.
- bidspoke#106: never interpolate request parameters into a query filter string (PostgREST .or()); treat filter construction like SQL construction.
- bidspoke#402: template references must be validated at save time against the known roots; an unknown root silently resolves undefined in production.
- bidspoke#407: a destructive sync must sanity check its input; an empty upstream fetch while rows exist locally means "refuse and alert", not "delete the whole bid matrix".
- bidspoke#413: validate the shape and status of an internal service response; a malformed but parseable daily cap reply silently benched a partner as capped.
- bidspoke#473: escape every literal class (backslashes, not just quotes) in generated SQL, for every type branch, especially for partner controlled fields; better, never hand build SQL literals.
- bidspoke#506: numeric coercion of external values must check isFinite; a garbage string parsed to Infinity and won every auction.
- bidspoke#510: never trust identifiers parsed out of log lines for service role writes; a forged line could corrupt another row.

### missed-related-reference (10)

An operation (rename, delete, duplicate, register) that must touch N linked things touched N minus 1.

- bidspoke#16: duplicate must copy everything that makes the original work, including deployed code node bundles keyed by workflow id, not just the definition row.
- bidspoke#59, bidspoke#95, bidspoke#130: node and arm deletion must rebuild every property of the spliced edges (sourceHandle) and remove every orphaned edge, including in multi select and arm removal paths.
- bidspoke#60: a rename must update every reference site; step id rename missed parallel_source and trigger success_node_namespaces.
- bidspoke#104: renaming a key that exists in two stores (DB row plus Cloudflare secret) must migrate both or reject; a rename without a new value desynced them.
- bidspoke#105: when adding audit logging to new mutation types, give each its real entity_type and id, and cover all mutation surfaces; copy pasted types made the audit trail unfilterable.
- bidspoke#172: when node types are dispatched off category lists (timeout floors), adding a node type requires adding it to those lists; a guard test per registry beats memory.
- bidspoke#639: after fixing a bug in one of two twin nodes (branch_end), immediately check the twin (parallel_end) for the same defect.
- bidspoke#660: enum-keyed maps (minimap colors) must be exhaustively guard tested against the registry, or new node types silently fall through to a default that means something else.

### monitoring-logic-blind (9)

The alerting itself was wrong: blind windows, false pages, misleading content.

- bidspoke#80: anomaly baselines must exclude the current partial day, or every morning looks like a cliff.
- bidspoke#83: an alert window must be longer than the thing it measures; a 5 minute window is structurally blind to executions slower than 5 minutes.
- bidspoke#110: derive alert thresholds and windows from the stated spec and honor per workflow overrides; the shipped constants quietly meant a different policy than documented.
- bidspoke#235: a known nightly maintenance window must not page as an incident; make recurring self inflicted degradation alert-aware.
- bidspoke#322: a drift guard must ignore expected drift (auto created monthly partitions), or the team learns to ignore the guard.
- bidspoke#542, bidspoke#600: never put a canned "how to fix" in an alert; wrong guidance steered a multi day incident diagnosis in the wrong direction twice, so branch remediation text on the actual error class.
- bidspoke#599: an aggregated alert must report the true incident size, not a counter that resets on partial success.
- bidspoke#605: truncate alert text from the end that matters; cutting off the error code removed the most searchable token.

### sensitive-data-exposure (9)

Secrets and PII flowing into logs, caches, sandboxes, and responses by default.

- bidspoke#73: never persist resolved Authorization or API key headers into step logs; redact at the logging boundary.
- bidspoke#77: list endpoints must mask credential material by default; reveal must be a separate, deliberate action.
- bidspoke#108, bidspoke#474: never hand the whole env to user authored code or template scopes; allowlist exactly the keys a node references, because "every string binding" included the master encryption keys.
- bidspoke#193, bidspoke#528: never echo raw database or exec error messages to external callers; map to stable public messages and keep details server side.
- bidspoke#254: decide PII at rest posture (redaction, encryption, retention) when the table is designed, not after millions of rows of cleartext SSN and DOB exist.
- bidspoke#491: never cache decrypted secrets in a shared KV, and never with an unexpiring last good copy that outlives rotation and deletion.
- bidspoke#527: health endpoints must not disclose build metadata unauthenticated.

### docs-drift-from-code (8)

Two sources of truth that nothing forces to agree.

- bidspoke#22, bidspoke#524, bidspoke#525: reconcile spec documents (PRD, api.md) with shipped behavior in the same PR that changes the behavior; docs claimed an auth scheme never built and contradicted a shipped ADR.
- bidspoke#54: when a spec document and the code disagree on a value (a result code range), resolve it against the vendor's source of truth immediately; here the doc was the wrong side, but nobody knew for weeks.
- bidspoke#385, bidspoke#526: operational tables (worker secrets, credential names and storage locations) must be regenerated from the system, not hand maintained in three places.
- bidspoke#614: an ADR that cites a concrete platform number (statement_timeout) must cite the verified value.
- bidspoke#648: example queries in docs must be written for, and run against, the actual target dialect; the Snowflake examples were Postgres syntax and errored.

### duplicate-path-diverged (8)

A second implementation of an existing behavior that silently lacks what the first has.

- bidspoke#61: alternate input paths (Backspace versus toolbar delete) must route through the same handler, or one path bypasses undo history, pair expansion, and confirms.
- bidspoke#62, bidspoke#508: an optimization path (code node chaining) must preserve every cross cutting behavior of the normal path: timeout, retries, on_error, and response headers; whether a node is chained must be invisible.
- bidspoke#72: a new composition mode (tiered bid groups) must inherit the parent's safety constraints; tiers ran with no deadline because the group's race timeout was dropped.
- bidspoke#114: restore paths must run the same legacy shape migrations as the load path, or restoring an old version resurrects pre migration bugs.
- bidspoke#512: never re-implement a helper locally (formatErr); the local copy reintroduced the exact object-Object bug the shared one fixed.
- bidspoke#547: when every existing alert checks a gate (isTest), a new alert must too; enforce shared gates structurally, not by convention.
- bidspoke#560: one business classification (Tripoint result codes) must have exactly one implementation; two hand copied bucket lists agree only by coincidence.

### false-green-test (7)

Suites that pass while the production behavior is unexercised.

- bidspoke#481, bidspoke#503: test the real integration seam, not extracted helpers or mock call arguments; the finalize race and the webhook engine mapping could regress with all tests green.
- bidspoke#482: a race handling path must be drivable in a test all the way to its observable output (the 409 at the route), or it is dead code with coverage.
- bidspoke#500, bidspoke#501, bidspoke#504: cache invalidation, middleware cache population and fallthrough, and alert cooldown logic each need behavior tests against a real (fake but functional) store, not assertions that a mocked function was called.
- bidspoke#502: guard tests must run in the package whose code they guard; worker invariants tested only from the web package are skipped by worker-only runs.

### accessibility-not-built-in (7)

- bidspoke#273, bidspoke#372, bidspoke#515, bidspoke#672: build form controls accessibly from the start: label associations, dialog semantics, aria-invalid plus aria-describedby on validation errors, accessible names on selects, and never nest interactive controls inside an element with role button.
- bidspoke#274: pick palette colors against WCAG AA contrast when choosing them, not in a later sweep.
- bidspoke#496, bidspoke#497: every mouse only interaction (drag only palette, click only row expansion) needs a keyboard and click equivalent at design time.

### unmodeled-edge-case (6)

States the design did not account for, discovered in production.

- bidspoke#52: every state machine flag (half open probe) needs a TTL and an owner for every early return path; a deduped probe lead benched a partner until manual reset.
- bidspoke#86, bidspoke#376: any row with a lifecycle needs a sweeper for the stuck state, covering every terminal status (degraded and failed, not just completed), or in_flight rows age out with null outcomes.
- bidspoke#112: resume, replay, and re-delivery of an already terminal execution must be modeled explicitly; the fallthrough promoted a correct run to failed and paged.
- bidspoke#427: batch operations must isolate a poison row (skip and log) instead of letting one rejected row wedge the whole export for days.
- bidspoke#566: graph validity rules must be derived from real topologies (a branch arm connecting directly to its own branch_end is legal) rather than the happy path the author imagined.

### domain-logic-misdesign (6)

- bidspoke#69: sanity check formula weights against the real scale of each input; default weights let response speed swamp the bid amount.
- bidspoke#71: matrix lookups over bands must define ordering and overlap semantics explicitly; unordered first match over inclusive bands is nondeterministic pricing.
- bidspoke#109: encode domain rules as explicit predicates; "accepted" must not be derivable from a $0 bid.
- bidspoke#310: a status field must mean one thing; execution status meant "lead served" and "all bookkeeping succeeded" simultaneously, which forced a choice between false pages and silent loss until a degraded status split them.
- bidspoke#375: derived fields must respect the authoritative field; a reject_reason on outcome successful rows poisons downstream analytics.
- bidspoke#517: budget background work in the client (a 10 second prefetch sweep, per drag logging) as deliberately as server load; the app was its own top traffic source.

### commit-before-effect (6)

State advanced or consumed before the effect it records actually happened.

- bidspoke#68, bidspoke#507: consume a capped resource at the moment of the real side effect and refund on true non delivery only; consuming before dedup and rejection burned the cap, while refunding on post send timeouts overran it.
- bidspoke#81, bidspoke#85: record a dedup signature or advance a snapshot only after the alert is confirmed sent; otherwise one failed send suppresses the incident forever.
- bidspoke#484: never stamp rows as exported when a prerequisite enrichment failed; the filter that would re-select them matched the stamp, so whole nights of data shipped incomplete then purged.
- bidspoke#688: compute the final recorded status after recovery work completes, not before; a fully rescued run was still written as failed with a stale message.

### platform-limit-ignored (6)

- bidspoke#48: retry ladders must outlast the platform's known outage windows (PostgREST schema cache reload), or every nightly reload eats writes.
- bidspoke#84, bidspoke#509: assume every remote read is paginated: PostgREST caps at 1,000 rows and Salesforce SOQL at about 2,000 with nextRecordsUrl; an unpaginated read is a silent truncation bug waiting for growth.
- bidspoke#151: Snowflake SQL API results ship in partitions; reading only the inline partition 0 silently truncates large result sets.
- bidspoke#472: UPDATEs and DELETEs on partitioned tables must filter on the partition key or every statement scans all partitions; this dominated the DB's load spikes.
- bidspoke#488: KV is eventually consistent across colos; never correlate a mark and a check through it on a latency critical accept or reject path.

### guessed-api-or-schema (4)

- bidspoke#30: verify what a column actually stores before reading it; the backfill read HTTP status out of a column that only ever stored the body.
- bidspoke#58, bidspoke#89: read the vendor's actual response contract: Snowflake returns 202 with a statementHandle for async statements and no status field, so res.ok is not "the statement succeeded", and a guard on a field the API never returns is dead code that cached an empty schema.
- bidspoke#90: prove an encrypt-store-decrypt path round trips through the real column types before writing a million rows; base64 into BYTEA stored the wrong bytes and made every row undecryptable.

### security-hardening-missing (4)

- bidspoke#259, bidspoke#261, bidspoke#262: public ingestion endpoints need rate limits, body size caps, signature verification with constant time comparison, and security headers as part of the initial build, not a readiness sweep.
- bidspoke#260: any user defined graph the engine walks needs a step ceiling and cycle guard from day one; unbounded interpretation of user input is a denial of service primitive.

### critical-write-not-durable (4)

Must-not-lose business records written with best effort mechanics.

- bidspoke#23, bidspoke#237: classify every write path by loss tolerance up front; audit and outcome records need the same retry ladder the execution log got, because console.error-and-return is a deletion policy during the nightly purge window.
- bidspoke#88: never write a record another step will match on via void fire and forget; the finalize UPDATE raced the unawaited insert and the winning bid stayed unflagged forever.
- bidspoke#353: waitUntil is an eviction prone best effort queue; putting finalizeSighting on it stranded about 5 percent of lead outcomes per day, so run must-complete work inline or through a durable mechanism with a drain.

### shipped-without-verification (4)

Features that were wrong or dead in production and nothing checked.

- bidspoke#98: a safety affordance (post save Undo) must be tested against the state it claims to restore; it snapshotted the just saved values and so restored nothing.
- bidspoke#349: after shipping a new write path, verify rows actually appear in production; recordBidAttempt was only reachable from node types the live workflow never used, so the table stayed empty for weeks.
- bidspoke#495: never ship a progress state wired to a hardcoded false; the Deleting label and disabled state were dead code on a money path delete.
- bidspoke#645: never render a config derived badge as if it reflects reality when the backend ignores that config field; display what was actually sent, or validate the claim.

### maintenance-contention (3)

- bidspoke#24, bidspoke#236: schedule and lock-scope maintenance (partition purges) so it yields to live traffic; take lock_timeout, retries, and the schema cache reload blast radius into account when designing the job, not after the pages.
- bidspoke#392: never run heavy migration tooling (supabase db push with its pre migration dump) from a laptop against the production pool; give backfills and migrations a safe, bounded execution path.

### destructive-action-unguarded (2)

- bidspoke#479, bidspoke#494: every destructive action needs the same confirm pattern as its siblings, and any restore or overwrite must check for unsaved work before discarding it; folder delete fired straight from a menu item and version restore silently destroyed in progress edits.

## dwright-pennie/new-agent-onboarding

Counts: total 243 / lesson 130 / feature 77 / chore 36 / unclear 0

### stale-or-inconsistent-state (13)

- new-agent-onboarding#153, new-agent-onboarding#156, new-agent-onboarding#278: An aggregate status must be derived from, or reconciled with, its per-item statuses at build time; never let a step header claim Done while items remain outstanding, and never offer a finish control in a state where the underlying action is impossible.
- new-agent-onboarding#169: A bulk action must write the same per-item audit records the equivalent individual action writes, or the ledger and the UI tell different stories.
- new-agent-onboarding#171, new-agent-onboarding#187: Give any client-side persistence buffer an explicit lifecycle up front: clear finished work on next load, and never silently expire unfinished work on a timer.
- new-agent-onboarding#195: Persist state synchronously at the moment of the user action; a timer kept for visual polish must never carry the persistence.
- new-agent-onboarding#199: After a successful save, refetch or optimistically update every derived surface (history list, last-edited attribution), not just the primary value.
- new-agent-onboarding#205: Derive summary banners from live state instead of setting them once, so a later manual fix cannot leave a stale contradiction on screen.
- new-agent-onboarding#206: Every reachable state, including zero-item edge states, needs a visible completion path; do not gate the only finish control on a non-empty list.
- new-agent-onboarding#264, new-agent-onboarding#265: When a stored array is a cache keyed by id, derive totals and merges from the union of known ids so an unknown id is appended, never silently dropped.
- new-agent-onboarding#419: Compare dirty state against the server-normalized value after save (or normalize before comparing), or the unsaved-work warning stays armed after a successful save.

### concurrency-not-idempotent (12)

- new-agent-onboarding#41, new-agent-onboarding#176, new-agent-onboarding#181: Design every external create as re-runnable from the start: never blind-retry a non-idempotent POST, gate re-posts and adoptions on a durable ledger of what already happened, and give multi-call creates (create then set password) a recovery path for the half-done state.
- new-agent-onboarding#112: An adopt or recovery path may only take over resources the system's own ledger proves it created; provenance must be checked server-side, not assumed.
- new-agent-onboarding#49, new-agent-onboarding#222: Establish exactly one deploy authority and scope CI cancel-in-progress so a second push can never race a deploy or kill it between migrations and code swap.
- new-agent-onboarding#70, new-agent-onboarding#239: Treat browser storage as shared: two tabs on the same record need merge or lock semantics, not last-write-wins clobbering.
- new-agent-onboarding#86: Serialize appends to any read-then-write chain (hash chains, sequences); two concurrent writers forking off the same prior row is the default outcome, not the edge case.
- new-agent-onboarding#182: Two related database writes that must agree (value plus its history row) belong in one atomic batch, never two sequential awaits.
- new-agent-onboarding#192, new-agent-onboarding#204: While a run is in flight, disable every competing control (per-step Run, Reset, Start another); assume the operator will click them mid-run.

### silent-failure-swallowed-error (10)

- new-agent-onboarding#23, new-agent-onboarding#268: Treat audit and idempotency-key writes as failable at the call site: retry and surface a persistent failure, and never build a duplicate-prevention gate on a write that is allowed to fail silently (record intent before the side effect).
- new-agent-onboarding#39, new-agent-onboarding#225: Wire failure alerting the day the first error path or deploy pipeline exists; a red run or uncaught exception nobody is notified about is a silent failure.
- new-agent-onboarding#183: When a required secret is absent, make every route that depends on it fail fast identically; never let one integration silently create unusable resources while another refuses.
- new-agent-onboarding#188: Never fall back to a built-in default when a config fetch fails in an editor surface; block the editor with a retry so a subsequent Save cannot clobber the real stored value.
- new-agent-onboarding#229: Classify config checks by blast radius when writing them: a missing outage-class secret must fail the deploy, not print a warning nobody reads.
- new-agent-onboarding#242: Treat configured-but-blank the same as missing and show a clear error; an empty string passing a truthiness check must not render as an eternal loading state.
- new-agent-onboarding#261: A state-update helper must append, throw, or log when its target id is absent; a map-over-array update that silently discards the patch is a defect even when currently unreachable.
- new-agent-onboarding#424: A guard's catch-all must rethrow signals it does not own (Next's DynamicServerError); swallowing a framework control-flow signal converted a rendering mode into a production 500.

### accessibility-not-built-in (10)

- new-agent-onboarding#33, new-agent-onboarding#200: Give every input and select an accessible name in the first version, including conditional edit modes, not in a later a11y pass.
- new-agent-onboarding#50: Build modal dialogs with focus trap, move, and restore from the first render.
- new-agent-onboarding#51, new-agent-onboarding#202, new-agent-onboarding#361: Check WCAG contrast at design time for text, focus rings, and any dimmed or disabled treatment, in both themes; opacity tricks on already-faint text drop below AA.
- new-agent-onboarding#66, new-agent-onboarding#201: Keep heading and landmark semantics correct (one h1 per page, live regions, skip link) as each page is added.
- new-agent-onboarding#283: When a control is disabled, keep it focusable (aria-disabled) and expose the reason via aria-describedby so a screen reader can learn why.
- new-agent-onboarding#430: A menu widget ships with arrow-key movement, focus return to trigger, and aria wiring on day one, not just tab reachability.

### duplicate-logic-not-consolidated (9)

- new-agent-onboarding#28, new-agent-onboarding#155, new-agent-onboarding#159: Extract the shared component the moment a UI pattern (list row, copy field) is about to appear a second time, instead of copying it per step and consolidating later.
- new-agent-onboarding#184: Derivation and sanitization logic feeding two external systems must be one shared function, or the two identifiers drift.
- new-agent-onboarding#207, new-agent-onboarding#208, new-agent-onboarding#209: Page-level boilerplate (auth gate, tone maps, class strings) copied four times is four future divergences; hoist it into one shared module when writing the second page.
- new-agent-onboarding#216: Copy-pasted guard tests across seven files hid an asymmetry (403 asserted, 401 never); centralizing the guard and its test fixture would have enforced both.
- new-agent-onboarding#415: Domain label maps get exactly one source of truth; a second literal copy in a component is a drift waiting to happen.

### untested-failure-path (8)

- new-agent-onboarding#45, new-agent-onboarding#217: An e2e suite must exercise the real wiring (guards, session, database) and the failure, retry, and reload journeys, not one fully-stubbed happy path where no server code executes.
- new-agent-onboarding#214, new-agent-onboarding#215: Client API wrappers and degradation ladders, including the exhaustion throw, need tests when written; the code that runs only when things go wrong is exactly the code that ships untested.
- new-agent-onboarding#218: An a11y scan must cover both themes, every page, open dialogs, and error states, or those surfaces regress unnoticed.
- new-agent-onboarding#219: Test SQL against a real database layer (real SQLite plus migrations), not only hand-rolled fakes that encode the same wrong assumptions.
- new-agent-onboarding#251: When a guarantee is emergent (a full re-run after a mid-batch failure creates no duplicates), write one end-to-end test of the guarantee itself, not only piecewise unit tests.
- new-agent-onboarding#277: When one module hardcodes a fact that lives in other modules (which routes need the password), add a test that derives the list from the source of truth so they cannot drift.

### false-green-test (8)

- new-agent-onboarding#186: Stub external APIs with spec-accurate semantics (window.open with noopener returns null even on success); an unrealistic stub is how a completely broken feature ships green.
- new-agent-onboarding#212: Ratchet coverage thresholds to sit at actuals when coverage rises; a floor eleven points below reality gates nothing.
- new-agent-onboarding#281: Choose visual-diff tolerances by proving the guard fails on a known bad render; a tolerance that absorbs a control changing state is coverage theater.
- new-agent-onboarding#345: A guard must also fail on inputs that prove it is not running, such as orphaned baselines no fixture case uses.
- new-agent-onboarding#358: Fixtures that guard distinct states must be diffed against each other, not only against themselves, or two states can silently collapse into one while every screenshot stays green.
- new-agent-onboarding#359, new-agent-onboarding#369, new-agent-onboarding#370: Every fixture case must state in words what it shows, every negative assertion must be proven matchable against real copy, and dropping a case's row must fail; an assertion that can never fire is indistinguishable from coverage.

### missing-ci-gate (7)

- new-agent-onboarding#9, new-agent-onboarding#12: Wire tests, type-check, and build as a gate that actually blocks the deploy before the first production deploy; checks that run in parallel with the deploy give feedback, not protection.
- new-agent-onboarding#34: The deploy job must apply database migrations itself; a deploy pipeline that ships code without its schema silently breaks the first migration-dependent release.
- new-agent-onboarding#47: Turn on branch protection (or the closest available merge gate) when the repo is created, not after the audit.
- new-agent-onboarding#213: Promote e2e and a11y checks from advisory to blocking once they are stable; the only test exercising the real UI must be able to stop a deploy.
- new-agent-onboarding#221: An automation that rewrites test baselines and pushes to main needs human diff review and must not trigger side-effect production deploys.
- new-agent-onboarding#223: An auto-merge gate must consult every required workflow, including the security scan, not just the CI workflow it was written next to.

### missing-input-validation (6)

- new-agent-onboarding#5, new-agent-onboarding#38: Validate and parse-guard every request body server-side at the route boundary in the first version; client-side checks and one validated route do not cover the other routes.
- new-agent-onboarding#147: Constrain identity fields that derive downstream identifiers (names feeding email local parts) to an explicit character allowlist at entry.
- new-agent-onboarding#178: Internal logging and alert endpoints need value whitelists and length caps too; a permanent forensic ledger must not accept arbitrary garbage.
- new-agent-onboarding#197: When uniqueness is the product promise, validate across the whole batch, not each row independently.
- new-agent-onboarding#248: Where a deliberately loose validator feeds systems with their own parsing rules, add a server-side character rejection as defense-in-depth rather than relying on escaping at each sink.

### missing-auth-scoping (6)

- new-agent-onboarding#36: Allowlist membership must be rechecked on every request; with stateless JWT sessions, removal otherwise only blocks new sign-ins for up to the session lifetime.
- new-agent-onboarding#53: Put CSRF or origin checks on state-changing routes when the first route is written, not as a later defense-in-depth pass.
- new-agent-onboarding#64: Scope even status endpoints: return only what an unauthenticated caller genuinely needs (the sign-in flag), not the full integration inventory.
- new-agent-onboarding#96: Enforce auth and CSRF through one shared wrapper plus a meta-test over all routes, so a new route cannot ship unguarded by forgetting a paste.
- new-agent-onboarding#173: Never accept a client-supplied flag as an authorization input; derive permissions like allowExisting server-side from the ledger, as the sibling route already did.
- new-agent-onboarding#339: A client-rendered sign-in gate protects nothing; when the gate is client-side, treat every byte of app JS as public and plan server-side enforcement accordingly.

### indistinct-progress-and-failure-states (5)

- new-agent-onboarding#6: End every batch run with a per-agent, per-step success and failure summary; partial failure across systems must be reported, not left for the operator to reconstruct.
- new-agent-onboarding#189: Every loading state ships with a distinct failure state and a retry; returning empty string on error and rendering Loading forever hides a config problem as an eternal spinner.
- new-agent-onboarding#190, new-agent-onboarding#191: Give client fetches timeouts and long runs a heartbeat (current step, remaining count, elapsed time) so working, hung, and dead are visibly different states from the first build.
- new-agent-onboarding#193: Persisted in-progress status must be reconciled on reload; restoring a pulsing In progress badge with no live process behind it is a lie about liveness.

### platform-limit-ignored (5)

- new-agent-onboarding#175: Never design a per-request verification that recomputes an unbounded chain; plan incremental or checkpointed verification before the data grows.
- new-agent-onboarding#179: On Cloudflare Workers, module-global memory is per isolate; real rate limiting needs a shared store or a WAF rule, and any dashboard-only rule must be codified.
- new-agent-onboarding#210: Any capped list query needs pagination and a total count in the UI from the start, or history silently disappears once the cap is passed.
- new-agent-onboarding#224: Verify plan-level platform features (branch protection on a free private repo) before designing or documenting a process that assumes them.
- new-agent-onboarding#346: Learn the platform's designed side effects before building gates on them: a GITHUB_TOKEN push leaves a completed action_required phantom run that a newest-run gate misreads.

### pii-mishandled (5)

- new-agent-onboarding#56, new-agent-onboarding#95: Scrub PII with one shared scrubber applied at every sink (ledger, Slack alerts, raw upstream error strings), not per surface as each is remembered.
- new-agent-onboarding#57: Minimize PII on the client: no plaintext personal data parked in localStorage or embedded in compose URLs.
- new-agent-onboarding#58: Set no-store cache headers on any response carrying secrets or PII when the route is written.
- new-agent-onboarding#196: Apply the same redaction policy to the most durable store first; carefully redacting localStorage while writing the same personal email permanently to the shared ledger is the policy inverted.

### guessed-api-or-schema (4)

- new-agent-onboarding#4: Check an external identifier's uniqueness scope before mapping a field onto it; Salesforce usernames are globally unique across all orgs, so a locally-free email can still collide.
- new-agent-onboarding#174: Verify the target query language's actual escaping rules instead of assuming SQL semantics; SOQL does not honor backslash quote-escaping.
- new-agent-onboarding#228: Document rollback against the platform's real behavior: D1 migrations are forward-only and survive a Worker rollback, so old code can run against new schema.
- new-agent-onboarding#286: Verify an API's real response shape with a live call before writing a filter (gh reports bot authors as app/dependabot, not dependabot[bot]), and make the no-match branch a visible outcome instead of exit 0.

### fail-open-default (3)

- new-agent-onboarding#8, new-agent-onboarding#185: A dev-convenience fallback (auth open when unconfigured) must fail closed in production for both APIs and pages; mirror the strictness across every gate that shares the condition.
- new-agent-onboarding#194: Model auth state as unknown/true/false and hold rendering until known; a boolean that defaults to open flashes the app pre-auth and renders it fully when the status fetch fails.

### unbounded-external-calls (3)

- new-agent-onboarding#40, new-agent-onboarding#306: Every outbound fetch ships with an AbortSignal timeout and bounded retry by default, including the default parameter fallbacks future callers will hit.
- new-agent-onboarding#177: Retries need per-attempt timeouts and jittered exponential backoff; fixed serial sleeps inside a request stall the whole batch behind one hung call.

### stale-build-tested (3)

- new-agent-onboarding#11, new-agent-onboarding#426: CI must build and exercise the artifact production actually runs (the OpenNext/Workers build), not a lookalike Node build that passes while the real runtime 500s.
- new-agent-onboarding#425: Smoke-test the real production pages immediately after deploy and fail loudly on 5xx; a 90-minute outage shipped under fully green CI because nothing touched the deployed runtime.

### docs-drift (3)

- new-agent-onboarding#226: Never document an aspiration as if it exists; a README instructing uptime monitoring that was never configured hides the gap it describes.
- new-agent-onboarding#232: Update the README in the same PR as the change; five accumulated inaccuracies (allowlist location, missing steps and APIs, a stale no-database claim, a wrong secret list) each began as one skipped doc edit.
- new-agent-onboarding#233: Infrastructure invariants that live only in a dashboard (custom domain route, auto-deploy must stay off) must be recorded in the repo, or recreating the resource silently drops them.

### secret-mishandled (3)

- new-agent-onboarding#65: Never ship a shared static starter password as a committed example default; use per-account random values with forced change at first login.
- new-agent-onboarding#337: Treat anything in client-shipped code as public and add a build gate for real secret values; the same secret-in-bundle mistake happened twice before the gate existed.
- new-agent-onboarding#338: Never quote a real secret value in docs, reports, or plans; those files outlive the code cleanup that purges it everywhere else.

### dependency-risk-unmanaged (3)

- new-agent-onboarding#37, new-agent-onboarding#230: Do not put production auth on a pre-release dependency without pinning it exactly and creating a tracked mechanism to adopt GA when it ships.
- new-agent-onboarding#227: Pin the security toolchain (scanner images by digest, npx tools by version) with the same discipline as application dependencies; a floating latest scanner is itself a supply-chain risk.

### style-rule-violated (2)

- new-agent-onboarding#203, new-agent-onboarding#404: Apply the user's stated writing rules (zero dashes) to all generated output including UI copy, comments, docs, and workflow files, and widen the enforcing guard to every file class the first time, not app source only.

### incomplete-threat-model (2)

- new-agent-onboarding#180, new-agent-onboarding#307: When building tamper evidence, enumerate the attacks first (tail truncation, row deletion, id reordering out of the visible window), and sign everything the viewer relies on, including row ids, not just row content.

### Non-lesson counts

Feature (77): plan and phase records (#2, #13 to #19), the audit ledger and viewer (#3, #20, #21, #26, #116), production-readiness infrastructure additions (#32, #35, #42, #43, #44, #48, #52, #54, #55, #59, #60, #61, #62, #67, #68), recovery and health tooling (#83, #87, #89, #106, #117, #118, #125, #250, #308, #422, #432, #447), settings and template editing (#121, #130, #131, #132, #136, #137, #138, #141, #144, #146, #158), UI and workflow enhancements (#7, #24, #25, #27, #29, #101, #119, #120, #148, #149, #150, #151, #152, #154, #157, #164, #168, #172, #198, #211, #356, #395, #413, #414, #417, #427).

Chore (36): coverage and baseline additions (#133, #145, #160, #165, #220, #243, #279, #333, #334, #385, #431), lint and tooling upkeep (#46, #82, #97, #301, #302, #355, #405, #406, #456), cleanup and docs (#10, #22, #63, #69, #231, #234, #246, #269, #324, #332, #347, #348, #416, #420, #428, #446).

## Cross-repo synthesis: the root-cause families that recur most

Counts sum the per-repo family tags named in parentheses. All four repos had zero UNCLEAR issues. Lesson totals: slate 190, project-enrollment-tracker 194, bidspoke 189, new-agent-onboarding 130 (703 of 1,767 issues).

### 1. concurrency-not-idempotent (about 64 issues, all 4 repos)
Tags: concurrency-not-idempotent (slate 30, bidspoke 13, new-agent-onboarding 12), two-writers-unreconciled (project-enrollment-tracker 9).
Example lesson: every user-triggered or automated mutation must carry a database-level idempotency or locking guard from day one; assume every submit arrives twice, every cron tick overlaps its predecessor, and every admin action gets double-clicked (a client-side disabled button is not a guard). (slate#5 and 8 siblings)

### 2. silent-failure-swallowed-error (63 direct, about 89 with cousins, all 4 repos)
Tags: silent-failure-swallowed-error (bidspoke 21, project-enrollment-tracker 17, slate 15, new-agent-onboarding 10); cousins fails-open-or-silent-noop (slate 11), dead-or-blind-guard (project-enrollment-tracker 12), fail-open-default (new-agent-onboarding 3).
Example lesson: never convert a failed external operation into fake success; a bare catch on a transport error, a cleanup call in finally that masks the result, a shell || echo, and continue-on-error on a validation step each shipped stale or broken data as green. (project-enrollment-tracker#47 and siblings)

### 3. security-not-built-in (about 54 issues, all 4 repos)
Tags: security-afterthought (project-enrollment-tracker 19), security-not-built-in (slate 18), missing-auth-scoping (bidspoke 11, new-agent-onboarding 6).
Example lesson: gate every surface server side from day one; before calling a route or page done, state who may call it and whose data it touches. Client-side checks and an allowlist that runs after data is served are not auth: the entire baked dashboard, 562KB of rep PII, was publicly fetchable with curl. (project-enrollment-tracker#456 and siblings)

### 4. ui-state-and-progress-drift (about 62 issues, all 4 repos)
Tags: ui-state-drift (bidspoke 17), stale-or-inconsistent-state (new-agent-onboarding 13) plus indistinct-progress-and-failure-states (5), stuck-ui-no-failure-state (slate 10), frontend-state-desync (project-enrollment-tracker 9) plus ux-feedback-gap (8).
Example lesson: every async action wraps its await in try/catch/finally from the first version, clears the busy flag in finally, and pairs the spinner with a timeout that converts a stall into an actionable error; working, still alive, and failed must be visibly distinct states. (slate#168 and siblings)

### 5. tests-that-do-not-gate (about 48 issues, all 4 repos)
Tags: untested-failure-path (new-agent-onboarding 8, project-enrollment-tracker 8), false-green-test (new-agent-onboarding 8, bidspoke 7), test-gate-gap (slate 10), missing-ci-gate (new-agent-onboarding 7).
Example lesson: test the real integration seam, not extracted helpers or mock call arguments; the code that runs only when things go wrong is exactly the code that ships untested. (bidspoke#481, new-agent-onboarding#214)

### 6. platform-limit-ignored (31 direct, about 45 with cousins, all 4 repos)
Tags: platform-limit-ignored (slate 13, project-enrollment-tracker 7, bidspoke 6, new-agent-onboarding 5); cousins platform-semantics-misread (slate 9), guessed-external-behavior (project-enrollment-tracker 5).
Example lesson: assume every remote read is paginated (PostgREST caps at 1,000 rows, Salesforce SOQL at about 2,000) and size every background job against the platform's CPU and subrequest ceilings at target scale before shipping; an unpaginated read is a silent truncation bug waiting for growth. (bidspoke#84, slate#44 and siblings)

### 7. shipped-artifact-not-verified (about 31 issues, all 4 repos)
Tags: tested-artifact-differs-from-shipped (project-enrollment-tracker 9) plus shipped-dead-code-unverified (7) and deploy-not-verified-live (4), shipped-without-verification (bidspoke 4), migration-deploy-drift (slate 4), stale-build-tested (new-agent-onboarding 3).
Example lesson: point guards and tests at the generated page and the live HTTP response, not the source template, and make CI run the same gates the deploy runs; a change passed all of CI, then failed the deploy-time gate and froze production for the day. (project-enrollment-tracker#804, #814)

### 8. unverified-domain-assumption (about 27 issues, all 4 repos)
Tags: unverified-domain-assumption (project-enrollment-tracker 15), guessed-api-or-schema (bidspoke 4, new-agent-onboarding 4), wrong-assumption-domain (slate 4).
Example lesson: verify vendor field semantics against real data before building a metric on them; bucketing by a mutable draft date instead of the immutable original pushed the first-pay rate past 100 percent. (project-enrollment-tracker#171 and siblings)

### 9. accessibility-not-built-in (26 issues, all 4 repos)
Tags: accessibility-not-built-in (new-agent-onboarding 10, bidspoke 7, project-enrollment-tracker 7), a11y-not-default (slate 2).
Example lesson: give every input a label association, every dialog focus trap and restore, and every palette color AA contrast in the first version, not in a later accessibility sweep. (bidspoke#273, new-agent-onboarding#33 and siblings)

### 10. duplicate-logic-drift (25 issues, 3 repos)
Tags: duplicate-logic-not-consolidated (new-agent-onboarding 9), duplicate-path-diverged (bidspoke 8), duplicate-implementation-drift (project-enrollment-tracker 8).
Example lesson: the moment a second consumer needs the same derivation, extract one shared implementation; two live conventions for deriving hire_date differed by a week of commission eligibility. (project-enrollment-tracker#649 and siblings)

### Process observation
In bidspoke the lesson density concentrates in three big retrospective self-audit waves rather than at build time, and slate and project-enrollment-tracker show the same shape (production-readiness and audit series). Most of these defects were found by sweeps written months after the code shipped, which is exactly the pattern the resulting global guidelines should eliminate: each family above is cheap to enforce while writing the code and expensive to excavate later.
