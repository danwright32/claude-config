# Overture issue triage (danwright32/overture)

Counts: total 864, lesson 303, feature 442, chore 118, unclear 1 (#489, a needs-verification UI truncation report never confirmed).

Method: all 864 titles and labels classified; 37 issues deep-read via gh (bodies and comments) where the title alone did not carry the diagnosis. Every LESSON issue below carries a root-cause family tag and a forward-looking build rule. Families are sorted by issue count descending.

## duplicate-code-drift (26)

Shared lesson: never write a second copy of behavior that already exists (a predicate, a control, a status vocabulary, an address constant, a capsule button); the two copies always drift, and the drift surfaces as a user-visible contradiction later.

- 1609: two "is this show still open" predicates disagreed, so a reachability control appeared on a show in a refused town.
- 1587, 1567, 1570: the Scout pill and the queue list answered "is this showable" with two different filters; share one predicate from the start.
- 987: two ingest paths disagreed about what a usable event is; one definition, both callers.
- 1073: near-copy functions writing the same fields need a guard or, better, one function.
- 1001: recordCheck and recordSuccess were two functions doing one job, which is exactly how #1005's wiring gap happened.
- 1461, 1460, 1451, 932: hand-drawn status pills and capsule buttons at multiple sizes; extract the shared component the first time it repeats.
- 677: the "has an unhandled reply" predicate lived in three files.
- 662, 631, 623, 618: duplicated menu controls and duplicated save-failure warning blocks; a copy-pasted alert block is a defect, not a convenience.
- 472: two run-state vocabularies (RunLiveness and DetachedRunPhase) for one concept.
- 447: duplicate lead-level marking controls beside per-contact ones confuse which is authoritative.
- 949, 951: the sending address was hard-coded in several places instead of routed through SendIdentity.
- 317, 307, 297, 289, 224: path helpers, deep-link builders, acknowledgment wording, notification delivery, and next-date logic each existed twice before being consolidated.
- 552: prep-run.sh and reply-classify-run.sh grew identical setup logic separately.

## ui-copy-and-affordance (24)

Shared lesson: read every new user-facing sentence cold, in screen order, next to its neighbors, before shipping; restated copy, controls that do not look like controls, and text that mirrors a button instead of adding information are invisible from inside the code and obvious on the screen.

- 840, 841, 843, 364, 1136, 336, 353, 1195: the same fact stated twice on one surface (row line, header, model credit, empty state, wordmark, status text).
- 844: the cold read is a required step because no test can catch restated copy.
- 842, 338, 488, 565: things that act like buttons must look like buttons, and instructions ("click Reconnect") must ship the button they describe.
- 1534: a card line restated the Keep button instead of saying what Dan needed to know (no contact was found).
- 1137, 1139: redundant chrome and duplicate-looking controls on the contact row.
- 959: copy composed from counts must handle the singular case (subject and verb agreement).
- 1548: use one word per concept across the app; two words for one state read as two states.
- 1547: conditional copy must cover the "all items ignored" branch, not only the "gaps remain" branch.
- 1513: two entity types on one list need one visual language, and a shared date heading must mean one thing.
- 1363: a badge whose label conflates two questions (genre and production type) cannot be answered.
- 347, 339, 335: status lines must read in the user's flow order and a breakdown must read as a breakdown, not a second total.

## silent-failure-swallowed-error (23)

Shared lesson: every error path must surface failure (throw, alert, or an honest failure record); a swallowed error, an empty fallback result, or a success acknowledgment posted regardless of outcome converts a diagnosable failure into silent wrong state.

- 477, 499: dozens of try? context.save() sites persisted user actions best-effort while the UI acknowledged success; propagate save failures everywhere, from the first save written.
- 479: launch-time backfills relied on autosave timing instead of an explicit save.
- 484: a failed token write after OAuth showed phantom connect success then unexplained disconnection.
- 1417: a success message must never post over a failed save's warning.
- 483: a 2xx response that fails to parse fell back to an empty threadId, so the sent email was silently never watched for replies; parse failures on success paths are failures.
- 485: a detached runner wrapper discarded stderr, leaving early script failures with no trace anywhere.
- 868, 856, 848: a detached run that exits without writing results must write an honest failure record; otherwise the app polls a file that will never appear.
- 875: a failed source explained itself in a note no surface ever showed; an explanation nobody sees is not surfaced.
- 1163: OAuth sign-in failed as a dead browser tab plus a two-minute spinner; a failure must become an error, not a timeout.
- 899: a command that can fire into nothing must say so instead of doing nothing.
- 1253: an obviously corrupt cached artifact (Gmail signature) must fail loud, not ship in real mail.
- 1002: rejection reasons that are written but rendered nowhere are dead diagnostics.
- 316: send failures need a durable record, not a transient banner.
- 48, 27, 876: an empty or short run result (Prep returned nothing, scout extracted zero, fewer shows than given) must be announced, never left as silent waiting.
- 792: a contact blocked by a send guard made the show read as fully Sent and it left the queue with a contact never emailed; a guard that removes work must leave a visible residue.
- 1018: reply classification had no detection for a reply that never got classified; every queue needs a "never came back" check.
- 1047: a warning line silently overwritten by the next status update is a swallowed warning.
- 1419: an action that may change nothing must report whether it actually changed anything.

## misleading-diagnosis (16)

Shared lesson: distinct failure modes must produce distinct messages, and a message must state only what its check actually measured; collapsing a TLS failure, a malformed feed, an empty page, and a dead link into one sentence sends the user to fix the wrong thing.

- 1543, 1555: a broken TLS handshake and a malformed adapter response both read as "Couldn't reach that page", the same as a dead link.
- 1539: the empty-feed warning blamed the page format when the app knew every row was dropped by its own filter.
- 1531: an error that names no source and claims a window the source does not use misdirects the fix.
- 1545: "New listings, not read yet, run a scout" on a page with no dated listings is a promise the next run cannot keep, like 958's same advice for a JavaScript-drawn page.
- 126: a failed calendar fetch must be distinguishable from a genuinely empty week.
- 1533: an uncertainty badge must blame the part the classifier is unsure of, not the part it is sure of.
- 1536: audit hedged warnings against what the underlying check measures; wording must not overclaim.
- 1032: rejection counts bucketed into one number hide which rule fired.
- 1168: a debug log that says "redirect received" for dropped junk misleads the next debugging session.
- 1124: a progress line whose name and count come from uncoordinated sources reads as an index it is not.
- 1527, 1430: severity color is a message; a partial conflict must not wear the same alarm color as a total one, and a neutral state must not wear an urgent badge.
- 1480: a script message must describe what actually happened (you did not commit the regen) rather than restate a symptom (the file is stale).
- 1498: "no venue was ever published" must not be presented as "the page could not be read"; two causes, two states, two messages.

## false-green-test (13)

Shared lesson: a green result means nothing until the harness is proven to fail when it should; require positive proof of a real pass, keep tests hermetic, and never let a test pin an assumption about live data that time will invalidate.

- 1252: the test wrapper treated an exit-0 launch failure as a pass, so "all suites passed" could print with zero tests run; require the explicit success marker.
- 1465, 1459: the wrapper called every failure a crash and retried compile errors as flakes; classify outcomes by their distinguishing output, not by absence of a pattern.
- 1389, 1387: the eval harness itself was broken two ways (scorer rejected every real output; the inner command consumed the loop's stdin so only 1 of 8 fixtures ran), and it was shipped without being seen to score a real pass.
- 561, 416: tests asserting counts against a copy of the live store assumed a state (zero recipients) that real usage later falsified; snapshot the precondition inside the test.
- 153, 88: a non-hermetic listener test gives an unreliable pass or fail and trains re-running until green.
- 629: regression tests with no compiler-enforced link to the function they scan keep passing after the function moves.
- 982: a code comment asserting behavior no test enforces is a claim, not a fact; sweep for them.
- 811: tests silently depending on the real clock go red on a date, not on a change.
- 497: a refusal path (drip must refuse a fully-sent show) with no test is an untested failure path on the highest-stakes surface.

## incomplete-trigger-coverage (12)

Shared lesson: when a derived state has multiple inputs, every input's change must re-run the derivation; wiring the recompute to only the trigger you were thinking about leaves the state silently stale on the others.

- 923: conflicts recomputed on scout and on days-off edits, but not when a new booking arrived in the export.
- 1566: the went-by sweep ran at launch only, not on the reconcile tick.
- 1416: undoing a day-off block left the shows it clashed with still flagged.
- 197: Downbeat bookings re-checked at launch and scout, not when the export file changed.
- 1301: TicketTailor re-read on event-set change, not when a recurring show gained dates.
- 1132: an "unsure" badge silenced by a confirm stayed silenced even after a later scan re-guessed shaky.
- 1246, 1244: the self double-booking warning missed cross-stage collisions and the Archive send path.
- 542: manual book and close paths lacked the sibling-contact suppression the reply and auto-book paths had; parallel paths must get parity or share code.
- 410: the migration seeded resolution from replied only, missing booked and lost.
- 218: rejecting a legacy auto-detected booking did not stick because the detector re-applied it.
- 156: the live scout ignored the exported blocked dates a sibling path honored.

## long-run-liveness-invisible (11)

Shared lesson: any action that does not return instantly must make three states visibly distinct at a glance: it started, it is still alive, and it failed or stalled; a bare spinner identical in all three states is a defect (this repo is where Dan's global rule came from).

- 1010, 354, 44: scout and Prep ran behind indefinite spinners or hover-only counts.
- 1003: an N of M count that can sit stale while seconds tick fakes liveness.
- 1015: the runner that does the work must own the progress count; a model-side guess drifts.
- 1530: a stuck-warning threshold not tied to real liveness fired right before every finish.
- 471: "looks stuck" was a fixed five-minute clock, not actual run liveness.
- 436: the audit that applied the rule to every time-taking action, not just the reported one.
- 47, 54: timeouts must bound every long await (Prep batches, socket binds) so a hang converts to an error.
- 1613: cancel must be able to clear a run that died before its cancel watcher started; the escape hatch must not depend on the thing being escaped.

## concurrency-not-idempotent (10)

Shared lesson: assume every multi-step write runs twice; put an in-flight marker, lock, or idempotency key around send, launch, and confirm paths before shipping them, not after the double-fire is observed.

- 475: send wrote sent state only after Gmail accepted, so a crash in between re-queued a delivered email; record intent before the external call.
- 476: no in-flight lock across the send await; double-click or drip overlap could double-email one recipient.
- 480: Prep launch had a check-then-act race the reply-classify path had already solved with an atomic marker; reuse the solved pattern.
- 43, 733, 1323, 1033: every run trigger (Prep, re-prep, reachability, scout) needed its button disabled or guarded while a run was in flight; build the guard with the trigger.
- 282, 1160: install-and-launch scripts raced launchd into two live app instances, degrading the store's single-writer lock.
- 633: rapid consecutive UI actions targeted a stale row; async UI work must re-validate its target.

## stale-ui-state-after-action (10)

Shared lesson: every user action must immediately update every surface that displays the state it changed, and must visibly acknowledge itself; a correct save that still shows the old value reads as a failed save.

- 1125: the popup showed the old address after saving the fixed one, so a real save looked like a no-op.
- 1499: confirming "this page is right" left the card still showing the failure.
- 1521: after an address fix the results card stated the old page's failure in the present tense.
- 1140: the review queue kept a card whose draft was already sent.
- 449: dismissing a reply left the stale AI intent hint and draft behind.
- 459: a draft-lint warning persisted after Dan hand-edited the draft it flagged.
- 487, 285: an action with no visible movement needs an explicit acknowledgment; no silent no-op controls.
- 884: a shortfall message re-announced an old run on every launch; one-time messages need a consumed flag.
- 1573: picking a search result inside the already-focused stage did nothing.

## identity-key-fragility (10)

Shared lesson: choose and defend entity identity explicitly; a natural key built from mutable strings (title, date, venue spelling) will be rewritten, vary, or collide, and every consumer holding the old key is silently orphaned.

- 1606: a paid probe in flight across a venue rekey settles into silence because both marker and results hold the old natural key; migrations that rewrite a key must record old to new.
- 29, 21: prospect identity broke on listing title drift and on normalization differences.
- 1528, 1558: run rows differing only by start date minted three cards for one show, then 36 visible duplicates.
- 1590: one recurring event's title variants on the same night were distinct prospects.
- 369: sub-events of one ceremony with different titles risked duplicate outreach.
- 774: the org name matcher shredded accented names into junk tokens; normalize unicode before tokenizing.
- 1276: a merged event was detected by a "; " in the title, which a real title can legally contain; gate on the persisted flag, never a string heuristic.
- 1216: past-client matching ran on the event title only and missed the ensemble named in the presenter field; match on every field that can carry the identity.

## fix-one-instance-miss-the-class (10)

Shared lesson: when a defect is found, sweep for its siblings in the same change; the same root cause almost always exists everywhere the pattern was copied, and fixing only the reported instance leaves known bugs live.

- 976, 1443: the Sources scroll bug existed in every @Query-backed list.
- 630: the popover-cannot-anchor-in-a-toolbar limitation affected other toolbar controls.
- 683: the lightweight row dropped other signals besides the reported one.
- 1247: stage-scoped signals vanished across stages on more surfaces than the reported one.
- 1244: see incomplete-trigger; found by sweeping the send paths.
- 1273: every scouted field reaching a no-edit-surface outbound email needed the same audit as the one that bit.
- 1023, 1013: the progress fix and the stale-results fix applied to scout had to be applied to prep and reply-classify, which reuse the pattern.
- 963: real-send-proof hardening extended to outreach stats and booking detection.
- 855: after one prompt was found shell-mangled, expansion-test the other prompts.

## guard-wired-to-nothing (9)

Shared lesson: a guard, filter, or rule is only as real as its wiring plus a test that the wiring fires; a documented protection whose call site never executes sits green forever while providing nothing.

- 1005: the placement detector was wired into one ingest function while the native path recorded on another, so it silently never ran for 37 of 38 sources, and its silence was indistinguishable from a correct verdict.
- 888: the multi-owner reconcile rule could never fire because reports were fed one source at a time; the documented behavior was structurally unreachable.
- 1589: a genre filter existed but was wired to nothing.
- 1335: a short-circuit on websiteURL deleted a correct hard-to-reach warning; positive evidence must never swallow negative checks.
- 1466: a new performer match could be invisible on a show whose earlier match was rejected.
- 931: removing a button orphaned the settings it opened; when removing an entry point, rehome or delete what it reached.
- 26: a button labeled "Fetch latest scout" did not actually launch a scout.
- 90: a relationship tier existed in the ladder but was unreachable by any input.
- 564: a staged test lead's Send button stayed disabled because a gate nobody re-checked held it.

## extraction-misparse (9)

Shared lesson: parse scraped and extracted fields defensively against the messy shapes real pages produce (entities, stray HTML, recurring dates, city-for-venue swaps), and never destroy page structure before every consumer has read it.

- 995: the extract run put the city in the venue field when a page named no venue.
- 1030: the card's address line was an accident of source page plus a tiny hardcoded venue map.
- 125, 25: stray HTML fragments and undecoded entities reached user-visible names.
- 34: venue parsing assumed Carnegie's named halls.
- 1126: a weekly open mic was dated 2028 because the recurring-listing shape had no date rule; resolve to the next occurrence or skip.
- 892: the page cleaner deleted the site's own navigation before anything could use it; strip last, not first.
- 1502: only one URL shape of the Ticket Tailor embed was recognized, so the list view was misread as a JavaScript wall.
- 1127: three watched calendars returned unreadable with real content present; verify the extractor against each real page shape.

## silent-data-drop (8)

Shared lesson: any pipeline stage that discards or fails to fetch rows must carry that shortfall forward as an explicit count; downstream logic that treats "absent from results" as "absent from reality" will otherwise cancel live data.

- 887: half-read detail pages shrank the feed count, the run still looked healthy, and live shows were marked cancelled.
- 897: a stitched multi-month page had one verdict for four sections, so a run that read three of four just returned fewer shows.
- 826: reusing the scout pipeline for one pasted lead inherited the feed reconcile, and two confirms marked every Carnegie prospect disappeared; reusing a pipeline inherits every stage, so disable the destructive ones explicitly.
- 1189: a shared fairness clock flattened by the daily run plus a stable sort and a 20 cap starved the same 17 sources forever; fairness needs a tiebreaker and coverage needs a measurement.
- 1012: a truncated listings page was reported as fully read.
- 805, 1171: a source or adapter silently returning fewer or zero rows after a shape change needs a baseline comparison that shouts.
- 150: disappeared-show detection had to be gated on feed trustworthiness from the start.

## security-scoping-defaults (8)

Shared lesson: state and enforce who can run a thing and what it can touch at creation time; permissive defaults (full shell for an AI run, world-readable secrets, logs in /tmp, non-loopback listeners) do not tighten themselves later.

- 1026: the scout run had full shell access despite claiming Read/Write/WebFetch only; a detached agent's allowed tools must be enforced, not asserted.
- 1097, 524: the other detached runners and two more files needed the same lockdown; create locked down from the start.
- 486: the token file was briefly world-default-readable and the tightening was best-effort.
- 280, 279: PII files and agent logs sat on loose permissions in shared locations.
- 53, 52: the OAuth listener had to be bound to loopback and tokens moved to the Keychain; secure defaults from the first commit.

## stale-docs-drift (8)

Shared lesson: docs, comments, and measured claims are part of the change; a doc that describes a system that no longer exists, or a number measured once and never re-measured, actively misleads the next session.

- 494: README and PLAN.md described the dead Supabase plan and claimed nothing was built.
- 495: shipped behavior was undocumented and runbooks pointed Debug users at the wrong defaults domain.
- 496, 553: AGENTS.md documented commands and scripts that did not exist; assert doc-claimed commands in CI.
- 724: the fixtures README still called a superseded contract version current.
- 1060: a runbook's measured claim (0 of 26 venue strings contain a city) went stale as data changed.
- 1586: comments placed a signal at Review after triage moved to Scout.
- 1019: the runbook's verdict table and the PageVerdict enum needed a sync guard.

## ci-infra-fragility (7)

Shared lesson: CI must fail loud and finish; a runner that can deadlock, stall as forever-pending, retry a bad credential every 30 seconds without escalating, or never exist at all gives merges a false sense of verification.

- 478: no CI existed at all; TS tests, Swift tests, and the contract guard never ran automatically.
- 881: the runner loop deadlocked on a dead session with no symptom but a queued check.
- 886: registration failed 401 repeatedly and the loop treated it as routine retry; repeated failure must escalate to visibility.
- 761: Dependabot PRs could never merge because the self-hosted runner never picked them up.
- 1331: a flaky host falsely reddened main until auto-retry distinguished host crashes.
- 1368: merge scripts could land a stale generated project.pbxproj on main because nothing checked freshness on the merge path.
- 912: GitHub closes issues on a negated closing keyword ("does not close #N"); platform parsing rules must be checked, then blocked in tooling.

## date-run-edge-cases (7)

Shared lesson: model multi-night runs, recurrences, and timezones explicitly from day one; judging a run by its opening night, tagging the group's date, or defaulting to UTC each silently misclassifies real shows.

- 1122: a run was judged by its first night, mislabeled "Performance passed" while later nights were pitchable, across three surfaces; one canonical helper existed and two call sites bypassed it.
- 939: a multi-date event was treated as separate single days, not one run.
- 929: the date-header marker could tag the wrong date inside a run.
- 1523: a recurring series was conflict-checked against every day in its span, not the nights it plays.
- 1501: the conflict line read as if the clash was on the group's date rather than a night inside the run.
- 116: booking causation used UTC where the domain is America/New_York.
- 333: a missing timestamp rendered as "last prep 20632d ago"; never render an epoch default as a real elapsed time.

## count-vs-list-mismatch (6)

Shared lesson: a badge's number is a promise about the rows behind it; compute the count and the list from the same predicate, or the number promises rows the surface then windows away.

- 996: the Too far count promised rows the queue windowed away.
- 861: the Scout pill counted shows that already happened.
- 863: the same count-versus-shows bug audited across Prep, Review, and Send pills.
- 1546: a permanently unread source held the waiting count above zero and jumped the queue every press.
- 1428: a shrunken-calendar hold counted toward the attention badge without needing attention.
- 331: a fresh install showed never-contacted prospects under "Reached out".

## agentic-run-untrusted-output (6)

Shared lesson: treat a detached AI run as an untrusted subprocess: pin its model, forbid it from asking questions, verify it followed its instructions, and never assume it fetched what the runbook told it to fetch.

- 847: the run hit pagination ambiguity, asked a question with nobody there, and exited without writing results; a detached run must always decide, record the decision, and write output.
- 857: notice when a run ignored its instructions instead of trusting it.
- 804: pin the model explicitly on every detached run; an inherited default is a silent variable.
- 874: the reply drafter, the highest-stakes writing, ran on the cheap model because the run was named for its classification half; assign models per task, not per script name.
- 1024: the scout never followed event detail pages, so every venue was guessed; verify the expensive step actually happened.
- 1391: the drafter dropped an uncorroborated co-performer instead of holding her at low confidence; encode the uncertainty policy, do not let the model improvise one.

## shell-and-environment-fragility (6)

Shared lesson: a prompt or script that passes through a shell is rewritten by the shell; test what the process actually receives in the environment it actually runs in (headless PATH, sh not bash, symlinked worktrees, machine sleep), not what the file says.

- 853: a raw double quote and a backtick inside a double-quoted prompt truncated and mutated the instruction the model received; the guard must assert against the expanded text.
- 1387: the inner claude/tsx call consumed the loop's stdin so only 1 of 8 fixtures ran.
- 636: the cleanup hook failed because Node was not on PATH in the headless environment.
- 1491: a relative-path computation broke under a symlinked worktree, failing every Mac merge check.
- 855: after 853, the sibling prompts needed the same expansion test.
- 1009: a live Prep run had no protection against system sleep killing it mid-run.

## cross-language-mirror-drift (5)

Shared lesson: a hand-ported mirror of logic in a second language will drift unless both sides consume one shared committed fixture; better, do not keep a mirror at all without a declared authority.

- 490: the TS ranker drifted from the locked scoring decision and its own test enforced the stale rule.
- 492: group-name matching existed twice and the drift guard only guarded one side.
- 493: the whole scout pipeline existed in TS and Swift with no declared authority and disjoint tests; the unused one was retired.
- 530: audit found more hand-ported mirrors with undetected drift.
- 138: group-name normalization differed between the Swift app and the TS engine.

## venue-null-drops-show (5)

Shared lesson: a strict correctness rule (never guess a venue) needs a designed escape hatch for the legitimate case it excludes, or it silently discards real data and disables downstream detection.

- 1214: a named outdoor venue was nulled at extraction, so a real show never reached the queue.
- 1057: parks and plazas were dropped as venue-less, losing real prospects.
- 1529: a single-room theatre lost all 149 shows because its widget feed never repeats its own name and the queue item never carried Dan's own venueLocation; pass the run every fact it is allowed to use.
- 1472: venue-less feed rows tripped a permanent forfeit alarm as if the page were unreadable.
- 1469: a page's own "info coming soon" placeholder counted as unreadable and switched off cancellation detection.

## data-safety-store-defaults (5)

Shared lesson: never leave live data at a framework's shared default path or name, back it up before every open, verify a backup is actually yours before trusting it, and never let a second failure overwrite the first one's evidence.

- 663: launch now refuses to open a file at the store path lacking Overture's own schema; this caught two real foreign-file collisions.
- 1406: the store moved off the shared Application Support default that two other processes had already clobbered.
- 1409: warn when the store opens with far fewer shows than the last backup.
- 1410: a snapshot of a foreign file was being recorded as a successful backup.
- 911: quarantined corrupt results wrote to a fixed name, so a second failing run silently destroyed the first run's evidence; stamp evidence files.

## build-install-hygiene (5)

Shared lesson: prove that the binary being exercised is the binary just built and correctly identified; stale installs, leftover instances, and unverified signing identities make real fixes look broken and broken code look fine.

- 1425: reinstalling the ad-hoc-signed Release app silently dropped macOS TCC grants because the cdhash changed every rebuild; sign with a stable identity.
- 1524: a failed install left a stray Release-identity bundle registered with LaunchServices.
- 1526: verify the signing identity is usable before building, not after installing.
- 1345: flag when the installed Release build is behind HEAD, so UI bug reports check build freshness first.
- 632: the test script left a stale Debug app running, which then blocked later runs.

## rule-in-prompt-not-in-code (4)

Shared lesson: a rule that only lives in a runbook or prompt is a hope; every hard constraint the AI must obey (never the venue's inbox, never a press contact, never a signup-form URL) must also be enforced deterministically in code at the boundary.

- 722: the never-a-press-contact rule enforced in code, not just the runbook.
- 388: never-the-venue enforced at contact import.
- 1278: the no-signup-form listing URL rule enforced in code.
- 635: the waterfall surfaced a press inbox despite the runbook forbidding it, which is what proved the pattern.

## user-input-clobbered (4)

Shared lesson: never overwrite work the user has typed or edited; any background refresh, re-run, or scout that writes a field the user can edit must detect and preserve the human edit.

- 1274: the scout stopped clobbering Dan's manual rename of a prospect.
- 254: voice-guidance notes edited during an in-flight Prep run were reverted by its completion.
- 251: the notes section needed structural protection from regeneration.
- 462: a fresh AI classify run overwrote Dan's edited reply draft.

## contract-shape-drift (4)

Shared lesson: every cross-boundary file contract needs a version, a committed fixture, and readers that tolerate additive change; a reader that hard-rejects the next version silently degrades the feature it feeds.

- 491: the fixture guard never enumerated the fixture directories, so a new version could land with one reader updated.
- 109: the Swift reader rejected export v2 outright and every client read as cold, violating the contract's own tolerate-unknown-keys rule.
- 1184: only a renamed date field read as "format changed"; all drift must.
- 744: 5 of 7 workflow-side contracts lacked the enumeration guard added for the first.

## swiftui-recompute-perf (4)

Shared lesson: an uncached computed property in a SwiftUI body runs on every state flip on the main thread; cache derived collections and scope observation, or a working feature becomes an app-freezing one at real data scale.

- 1121: pill taps recomputed roughly ten full store scans synchronously and froze the machine.
- 974: the Sources sheet scroll snapped to top while sources updated.
- 1429: the sheet froze scrolling the full watchlist.
- 1440: fast scroll from the top jumped to the bottom; the coarse scroll pin was the wrong repair scope.

## misc-ui-defect (4)

Shared lesson: exercise the built UI at real data scale and in real focus flows before calling it done; layout shove, focus theft, and edge-flush text are invisible in code review and immediate on screen.

- 1582: the search bar kept keyboard focus while Dan worked elsewhere.
- 994: the live-run label shoved the whole toolbar sideways when a scout started.
- 1411: toolbar status text ran flush against its capsule edge.
- 345: summary text had too little padding inside its pill.

## test-touches-live-data (3)

Shared lesson: a test must be structurally unable to touch live stores, live handoff directories, or paid external runs; inject every seam and add a belt-and-braces refusal in the service itself.

- 849: the test suite wrote pinned pages into the live handoff directory and launched real paid claude runs on every test invocation.
- 1608: roughly one full-suite run in five failed on a store permission error from a test landing on a real on-disk default.store; a flaky gate trains re-run-until-green, which is how real regressions pass.
- 1006: a real-store test fixture raced and killed the whole suite run on main.

## magic-constant-inconsistency (3)

Shared lesson: a horizon, window, or cap that exists in more than one place is already wrong somewhere; derive every consumer from one named constant.

- 1353: host-routed feed adapters ingested beyond the default calendar horizon.
- 1183: the OPERA feed horizon had to be derived from the shared calendar horizon.
- 1571: the 90-day queue window disagreed with the four-month scout horizon.

## overbroad-guard-false-positive (3)

Shared lesson: a filter or lint must match the structure of what it forbids, not a substring or blanket shape; overbroad matching silently destroys the highest-value true positives.

- 481: the automated-sender filter used substring contains, so a real reply could be dropped as automated.
- 1141: the draft lint flagged exclamation points that were part of the show's own title.
- 779: a conflicting booking-history email suppressed a genuine performer match outright instead of downgrading it.

## deep-link-dead-target (3)

Shared lesson: any notification, deep link, or command that navigates must verify its target is reachable in the destination surface before firing, and must say something when it is not.

- 628: an OmniFocus follow-up tap on a closed show landed nowhere because the queue never shows closed shows.
- 674: the multi-lead deep link skipped the reachability check the single-lead one had.
- 568: overture:// lead links were not reliably navigating.

## signal-on-wrong-surface (3)

Shared lesson: put a signal or control on the surface where the user actually makes the decision it informs; a correct feature on the wrong screen is functionally absent.

- 1585: the reachability check never appeared on Scout, where keep and dismiss actually happen.
- 1129: Prep kept lived in a toolbar menu where it was undiscoverable.
- 346: the scout summary appeared far from the button that triggered it.

## platform-limits-pagination (2)

Shared lesson: verify how much of a paginated or windowed resource a read actually covers, and say so when it is partial; the first page is not the calendar.

- 858: a multi-page calendar only ever gave its first page.
- 900: an unpaginatable calendar was read one month deep and nothing said so.

## silent-default-fallback (2)

Shared lesson: a classifier's fallback value must be visibly marked as a non-answer, not silently scored as if it were a reading; otherwise the fallback quietly becomes the majority state.

- 1537: an unreadable genre was silently scored lowest instead of saying it could not be read.
- 1591: the classifier read no genre for three quarters of the queue before anyone noticed.

## guessed-api-or-platform-behavior (2)

Shared lesson: verify what an external API actually returns and guarantees instead of assuming the convenient behavior; ordering, included fields, and side effects must be read from evidence.

- 1144: outbound mail carried no signature because the Gmail API omits the web signature from API sends.
- 482: the latest reply was chosen by Gmail array order rather than message internalDate.

## scoring-misassumption (2)

Shared lesson: a ranking signal must mean what it claims; encode the semantics of an event (a bare send is not a relationship; too close is a reason to act, not to sink) before weighting it.

- 70: a bare outbound send was treated as a warm prior relationship.
- 1014: a too-close show sank to the bottom of the queue exactly when it needed attention.

## process-plan-against-reality (1)

Shared lesson: fetch the real page, store, or data before planning anything that reads it; a plan built on an imagined source shape produces confidently wrong designs.

- 983: made mandatory in docs after plans were repeatedly written against unfetched source pages.

## Non-lesson classification notes

- FEATURE (442): all plan-council and milestone phase records (for example 1592 to 1601, 1433 to 1438, 1369 to 1383, 748 to 756, 389 to 424, 263 to 271, 168 to 186), the v2 and deferred epics (1 to 17), and enhancement-labeled capability work (feed adapters, reachability layers, undo, inquiries, voice learning, OmniFocus, A/B framework).
- CHORE (118): dead-code removal (326, 669, 108, 104), dependency and tooling (127, 107, 508), pure guard or test additions with no underlying defect (1611, 1575, 622, 501, 509, 514, 321, 439, 113, 166), renames and doc catalogs (1196, 160, 529, 519, 14), and measurement or decision records (1285, 612, 1354).
- UNCLEAR (1): 489.
