# Build-time lessons

Distilled from the 2026-07-27 audit of 3,506 GitHub issues across 9 repos (1,721 carried
a lesson). Apply these by default in every project, alongside the rules in CLAUDE.md.
Full provenance per rule: ~/.claude/audits/2026-07-27-issue-audit/. Numbering is stable
for reference; L6 was reviewed and deliberately not adopted.

## Proof over green

- **L1. A test or guard is only real once it has been seen to fail.** Mocked guards
  asserting their own mock, wrappers treating exit 0 as a pass, vacuous assertions, and
  tests of hand-copied reimplementations all sit green while protecting nothing. Break
  the code once and watch it go red before trusting it. (58 issues, 6 repos)
- **L140. A test asserting that something THREW is satisfied by ANY throw, including one
  raised by its own fixture, so assert on the specific failure (the message, the type, the
  state left behind) rather than on the mere fact of an error.** A typo in the fake then
  fails as a typo, instead of masquerading as the refusal the test exists to prove, and the
  suite reports hardest on the branch it is covering least.
  (slate#1504: a fake in the test for "a block-lookup read error aborts with ZERO inserts"
  incremented an undefined `calls`, which threw BEFORE the fake recorded anything, so the
  surrounding try/catch set threw=true and both assertions passed. Had the sweep ever
  regressed into mass-inserting busy blocks, that test would still have reported success.
  It was invisible because tsconfig excludes the whole scripts tree from typechecking)

- **L154. A tool that reports whether a check CAUGHT a deliberate defect must name WHICH check
  fired, because a defect large enough to break everything makes every check fail and is
  indistinguishable from the one that should have.** Require the witness, not the verdict, and treat
  a near-total failure as evidence the instrument misfired rather than as proof the guard is real.
  Distinct from L1 and L151, which are about the guard: this is about the INSTRUMENT that measures
  the guard being wrong, and it fails in the reassuring direction.
  (overture#2820: `scripts/mutate.sh` separates "matched nothing" from "went red" but has no outcome
  for "applied somewhere else". A mutation whose expression used a pipe as its perl delimiter
  prepended text ahead of the shebang, the script stopped parsing, every fixture went red, and the
  tool reported CAUGHT. It validates roughly 1,600 source-text guards, and CAUGHT is the verdict
  quoted as proof. Only the diff it already printed exposed it, and only because a person read it)

- **L151. Every outcome a guard's own contract ENUMERATES must have a test that PRODUCES that
  outcome, not merely a test that passes.** A documented outcome nobody constructs can be
  unreachable in the code while the guard looks thoroughly tested, so read the contract as a list
  of states to build and check each one is achievable. Distinct from L1, which asks that a guard be
  seen to fail at all: this asks that it be seen to fail in each case it claims to cover.
  (overture#2817: `check-pbxproj-fresh.sh`'s header names three outcomes including "a regen that
  was never committed BLOCKS", and it decides with `git diff --quiet -- <path>`, which compares the
  working tree to the INDEX rather than to HEAD. A regeneration staged and left uncommitted, which
  is exactly what the repo's own post-merge hook produces, therefore read as FRESH. The gate exists
  because a stale file reached main once, and the one state it was written for was the one state no
  test built)

- **L2. Tests must be structurally unable to touch live data, production services, or
  paid APIs.** Inject seams for stores, directories, clocks, and external calls, plus a
  refusal inside the service itself. (10 issues, 6 repos)
- **L3. Built is not wired, and wired is not proven.** Prove every guard, integration,
  and gate actually executes in the shipping runtime, and wire the CI gate the day the
  first test lands. (45 issues, 8 repos)
- **L4. A merged fix is not a deployed fix.** Verify the change is live where it ships:
  migration applied in production, the live site serving the new commit, behavior
  confirmed in a production build. CI must exercise the artifact production actually
  runs. (20 issues, 5 repos)
- **L63. A regression guard must assert the quantity it exists to protect, never a proxy for
  it.** A pinned count, size or flag stays constant while the thing it stands in for doubles,
  so the guard passes for the whole time the defect is growing and the detector goes back to
  being the person who notices.
  (overture#1913, overture#1992)
- **L103. A guard that asserts the exact rendering of a value rather than the rule behind it fails
  the first legitimate refinement of that value, and when the value is a file's text it can also be
  satisfied by a comment ABOUT the thing, including one explaining that the thing was removed.**
  Assert the invariant, and strip comments before matching on source or config text, because a guard
  that is green on prose is indistinguishable from one that works.
  (new-agent-onboarding#516: four in one session, an engines range pinned as `>=22 <23` in two files
  that forbade stating the more precise floor a dependency required, a typecheck command pinned as
  `tsc --noEmit` that forbade it checking a second thing, and two assertions that had passed for
  months on the comment explaining the behaviour they asserted had been deleted)
- **L48. A test fixture that claims to come from real data must be measured from it, never
  shaped so the rule under test fires.** An invented shape makes a test appear to cover a
  case that cannot occur, so it passes forever while protecting nothing, and the
  fabrication is invisible to every reviewer who does not query the real data.
  (overture#1719)
- **L52. A test whose only outside dependency is a stub you wrote can only confirm your
  own assumption about the real interface.** Read the real contract in the same change
  that stubs it (its help output, its API docs, one live read only call), because a fake
  will happily accept the wrong identifier, field, or shape and stay green.
  (2026-07-29, milestone gate: 128 passing tests still had a milestone passed by number
  to a command that matches only by name)
- **L58. Two systems that must agree cannot be verified against records one of them wrote
  into the other.** A synced copy shares its source's spelling by construction, so the
  comparison passes for a reason unrelated to the rule under test; find or wait for a record
  each system created independently.
  (overture#1899)
- **L56. A new validator on a live data path must be calibrated against a sample fetched
  through the same code path it will guard, and must be observed for one real cycle before
  it is allowed to block.** An on disk sample is a snapshot of the schema on its own date,
  not a contract, so a guard calibrated on it encodes a shape the vendor may already have
  changed. Note the guard can be CORRECT and still cause the outage: the first version of
  this one truly caught a renamed column, but because its first live run was also its first
  enforcing run, a real finding stopped the primary feed instead of reporting itself.
  (project-enrollment-tracker#925, #930)
- **L68. A guard that reads live production data must assert the SIGNATURE of the failure it
  protects against, never the data's current emptiness.** A blanket bad default sets every row
  while ordinary use sets one, so a guard written as "no row has this yet" expires the first time
  the feature is legitimately used and can no longer tell that use apart from the defect.
  (overture#2054)
- **L65. A guard shipped deliberately inactive needs the issue that activates it filed in
  the same change.** The observe only state becomes invisible the moment the reason for it
  is forgotten, and an unenforced guard is indistinguishable from no guard. This applies to
  every deliberately temporary state, an observe only check, a dark launch constant, a date
  gate. (project-enrollment-tracker#928, #951)
- **L70. A check whose expected value and its actual value come from the same lookup can only
  prove that lookup is self-consistent, never that it is correct.** Resolve the two sides by
  independent routes, and where several candidates could match, assert against the others too,
  because a self-agreeing check passes hardest exactly when the lookup is wrong.
  (2026-08-04, driving the Mac during overture#2088: a guard proved the frontmost app matched
  the process it had resolved, both from one bad specifier, and quit the live app it was
  written to protect)
- **L82. When a platform primitive's DOCUMENTED guarantee is the entire reason a guard is safe
  (a clock that excludes sleep, a delivery that happens once, a write that is atomic), measure
  that guarantee on the real target before shipping.** Documentation ages behind the hardware
  and the runtime, while every test that injects the value agrees with the documentation by
  construction, so the suite is structurally unable to notice.
  (overture#2220: ProcessInfo.systemUptime is documented as awake time only and lost 7.6
  minutes across two nights of closed lid on Apple Silicon, so a sleep-immune outage detector
  reported a false twelve hour failure every morning)
- **L84. A recorded expectation (a baseline screenshot, a golden file, an approved snapshot)
  captures whatever the surface happened to be showing when it was recorded, including an error
  or empty state caused by a dependency the harness never fed it, and then defends that broken
  state as correct for as long as it lives.** Stub every dependency the recorded surface
  fetches, and make each recording assert in words the state it claims to show, because a
  recording cannot notice it photographed a failure.
  (new-agent-onboarding#468: the canonical screenshot of the new-hire form had recorded the
  trainer picker's red "couldn't load the trainer list" error as the form at rest, and the
  guard passed on it for as long as it existed)
- **L85. Two changes that are each green can merge into a broken main, because each one was
  verified against a base that did not contain the other.** A passing check proves the change
  works beside what existed when it ran, never beside what landed since, so when anything merges
  while yours is open, rebase and re-run before merging instead of trusting the earlier green, and
  prefer having the platform require an up to date branch so the guarantee stops depending on
  anyone remembering.
  (new-agent-onboarding#477 and #478: one made a field required, the other added a fixture built
  without it, both green, red on main. Only the typecheck caught it, because the test suite does
  not typecheck, so it surfaced after merging rather than on either branch)
- **L88. A CI job that runs only when certain paths change must have those paths derived
  from every input its tests actually read, not from where the code under test lives.**
  A shared fixture, golden file or config consumed from elsewhere in the tree makes the
  job skip precisely the change that breaks it, and a skipped job looks identical to a
  passing one.
  (PostRoll#246: a Swift job filtered to the app folder, while two of its tests read
  cross-language fixtures living beside the Python suite)
- **L92. When you make a removal or refusal durable by recording it against an identifier
  (an email, an id, a URL), every item the action can apply to must actually carry that
  identifier, or the ones lacking it silently keep the exact defect the recording was added
  to fix.** The gap is invisible because the fix demonstrably works on every item you tested
  it on.
  (overture#2392 recorded a struck contact as a refused EMAIL, so the six contacts with no
  address at all were still hard deleted and rebuilt by the next run: overture#2421)
- **L93. A guard that avoids a wrong action by falling back to a different action has only
  chosen which defect to ship, so name what the fallback gets wrong and measure how often the
  guard fires on real data.** One written for a rare ambiguity that turns out to be true in the
  common case makes its fallback the only live path, and the code reads as careful the whole
  time.
  (overture#2422: an importer skipped matching whenever a batch held two contacts of the same
  kind, which is every multi performer show, so every re-run appended duplicates instead of
  correcting rows)
- **L98. A watcher, poller or wait-for-completion step that reports SUCCESS when it found NOTHING
  to watch is indistinguishable from one that saw everything pass.** Finding zero subjects has to be
  its own non-success outcome, because the empty result arrives exactly when the work has not started
  yet, which is the moment a green verdict is most likely to be believed and acted on.
  (2026-08-10, new-agent-onboarding#490: `gh pr checks --watch` exited 0 printing "no checks
  reported" seconds after a branch was republished, so trusting it would have merged a commit no
  check had run against; minutes later a hand written filter over that same output reported every
  check green while one job was still running)

- **L171. A positive control proves the query SHAPE, never that the query reached the period you
  are asking about, so a control satisfiable by data from outside that period cannot detect a
  lagging pipeline and an absence there is worthless.** Scope the control to the same recency as
  the question (assert its newest row is recent), because the control passing is exactly what
  makes the wrong answer believable. Distinct from L98, where the watcher found no subjects at
  all: here it found plenty, just none from the window that mattered.
  (slate#1533: Cloudflare's log query API ran about three hours behind, so asking at 16:19
  whether a line appeared at 14:44 returned needle 0 and control 101 over one 4h window and
  scored a trustworthy absence. `wrangler tail` saw lines live that the same API reported zero
  of. The control was working the whole time)

- **L172. Before shipping a threshold, measure where it lands in the REAL distribution of the
  quantity it judges, because one sitting inside the dense middle turns the count it produces
  into noise: a small uniform shift carries dozens of items across at once and reads as a sudden
  regression rather than as the same population barely moving.** Report the spread beside the
  count, since a threshold at the 90th percentile with a quarter of the population within a hair
  of it is indistinguishable, from the count alone, from a clean separation. Distinct from L36,
  which designs an alert against its false positive sources, and from L139, where a volume floor
  discards the saturated case: here every input is judged and the cut line is simply drawn through
  the thickest part of the data.
  (project-enrollment-tracker#1062: a conversion drift check went 15, then 48, on a gap
  distribution whose median was 0.37pt and whose 90th percentile was exactly the 1.00pt threshold,
  with 55 rows sitting between 0.75 and 1.0. Running the identical query against four retained
  Salesforce dataset builds gave 49, 48, 48, 48, so the population had barely moved)

- **L119. A detection that ACCUSES on an empty answer from an external provider's derived index (a
  commit-to-PR association, a search index, a related-records lookup) must confirm against the
  primary record before acting, because a missing index entry and a real violation are
  indistinguishable and the index can stay permanently incomplete rather than catch up.** The mirror
  of L98: there, finding nothing reads as success; here, finding nothing reads as guilt, and the
  false accusation is what teaches everyone to ignore the guard.
  (slate#1447: main-push-guard paged "direct push to main with no merged PR (review bypassed)" on a
  squash merge of a reviewed, green PR. GitHub's `/commits/<sha>/pulls` returned `[]` and still did
  twenty minutes later, while the PR itself recorded that exact commit as its merge_commit_sha. The
  three merges before it associated fine; the one that differed was merged during a GitHub API
  incident, so the association record was never written and no retry could have helped)

- **L173. A fallback added because a lookup failed must be reachable on EVERY way that lookup can
  fail, not only the flavour that was observed, because the remedy gets scoped to the symptom named
  in the incident report and is then absent in the neighbouring, worse failure.** The tell is a
  fallback consulted only when the primary ANSWERS: a route that requires the primary to succeed is
  not a fallback, and the code reads as having two routes while having one. Distinct from L119,
  which is the lesson that PRODUCES such a fallback, and from L93, where the fallback fires and
  ships the wrong defect: here it never fires at all.
  (slate#1519, from #1447: the main push guard's second route, asking a PR named in the commit
  subject whether it claims this commit as its merge commit, was written for an association index
  that answered EMPTY during a GitHub incident, and sat below an early return for an association
  that could not be READ. When that endpoint began answering 403 on 2026-08-17 the guard fetched the
  proof, printed it to its own log as `#1518 isMergeCommitOfThisPush:true ciConclusion:success`, and
  discarded it, failing every merge to main and paging on each one. The 403 itself turned out to be
  transient, measured against a controlled permission experiment, which makes the point sharper: a
  blip is precisely what the second route was for)

- **L120. A fan out that delivers only to recipients matching a subscription list reports SUCCESS
  when it matches ZERO of them, so a newly added event, topic or category is silently delivered to
  nobody while the send path looks healthy.** Assert that every value the code can emit has at least
  one recipient that could receive it, because the delivery record is written either way and nothing
  downstream can tell an empty fan out from a delivered one. The sibling of L98 (a watcher finding
  nothing reads as everything passing) on the sending side, and of L46 (a field written but never
  read): here the value is emitted but nothing has subscribed to it.
  (slate#1459: adding a webhook event to the code union ships it inert, because delivery is filtered
  by a subscriber list held in a database column that no code change touches, and #1341 was about to
  add one)

- **L100. An operation that finds its target by matching text (a marker to insert at, a file to stash,
  a pattern to replace, a helper name to call) reports SUCCESS when it matches NOTHING, so the next
  step acts on a state nobody created.** Assert the match happened, because zero matches and a
  completed edit are indistinguishable from the exit code, and the failure surfaces later as the
  wrong thing having been done rather than as an error.
  (2026-08-11, four times in one session on overture: a `gh issue create` whose backticked body the
  shell executed instead of sending, filing nothing while reporting as backgrounded; a `git stash push`
  of an already-committed file, so the following `pop` restored an unrelated older stash and left
  conflicts in two untouched files; a scripted insert whose anchor text did not exist, which printed
  "added" and added nothing; and three shell assertions calling a helper that file never defined,
  which printed "command not found" to stderr while the summary reported every fixture passing)
- **L143. A test double that selects what it intercepts by PATTERN (a route glob, a URL matcher, a
  path prefix) silently becomes NO double at all when the pattern misses, so the test talks to the
  real dependency and reports whatever that produces as the behaviour under test.** Assert that every
  declared double actually fired at least once, because a stub that matched nothing is
  indistinguishable from one that worked, and is worse than having none, since you believe the case
  is covered. Distinct from L84, where the dependency was never faked at all, and from L100, which is
  about operations rather than test doubles: here the fake was written, reviewed, and is inert.
  (new-agent-onboarding#591: a Playwright stub written as `**/api/starter-password/value` matched
  nothing once the request carried `?onboardingId=`, so the unauthenticated CI fixture reached the
  real route, got a 401, and drew its "couldn't load" error. It was one guard away from being
  committed as the canonical screenshot of the screen at rest)
- **L133. A detector that identifies records written BEFORE a fix must key on a recorded stamp, never
  on a property of the stored value itself, because a store that re-encodes on save normalizes that
  property away and the detector then reports every row as already correct.** The tell is usually
  visible in the source data and gone from the file, so the design reads as obviously workable right
  up until it is measured against what is actually on disk. Distinct from L40, where the stand-in
  merely happens to match, and from L68, where the guard expires on legitimate use: here the evidence
  is destroyed by the persistence layer doing exactly its job.
  (PostRoll#549: stale analytics were to be found by their publish time carrying no timezone offset,
  but AnalyticsStore encodes with .iso8601, so the first save after any import had already rewritten
  every naive time as an absolute instant)
- **L101. A code path that switches behaviour on the SIZE of its input will always take the
  small branch under test, because a fixture is minimal by construction, so the mode that
  actually ships is the one never exercised and the suite is green the whole time.** Size
  the fixture past the threshold, and assert the run did not report taking the degraded
  path.
  (PostRoll#319: every Thursday reel test rendered ten photos, below the point where the
  strip is taller than the frame, so the generator collapsed the scroll to a still and each
  test checked a reel that never moved)


- **L102. A cost or latency measured while the expensive path is switched off measures the
  short circuit, not the work, so the number reads as reassurance for exactly the case nobody
  has tested.** Measure with the thing that makes it expensive turned on, or state plainly
  which case the figure came from, because a fast reading taken against an empty roster, an
  unpopulated table or a disabled integration is indistinguishable from a genuinely fast path.
  (slate#1365: an on demand availability search timed at 2.9s against a deliberately dark
  roster, where every pass returned before touching a single calendar)

- **L104. A filter that identifies data by its SHAPE (a redaction regex, a content
  classifier, a profanity or spam rule) must be tested against the content it has to
  PRESERVE, not only against the content it has to catch, because the shape it matches is
  rarely unique to its target and an over match reads exactly like the feature working.**
  (slate#1368: a scrubber written to keep a lead's phone number out of browser error
  reports matched "digits and separators", so it turned every 2026-08-11 into [phone] and
  stripped the slot time out of exactly the booking errors it was built to surface)
- **L107. A number measured to justify a design decision must be produced by the code's own
  predicate, never by a query written beside it, because an ad-hoc reimplementation is a second
  definition that drifts silently and in the direction that flatters the argument being made.**
  Distinct from L16, which keeps one predicate behind a count and the rows it promises INSIDE the
  product: this is the measurement taken to argue FOR a change, which no test covers and which
  therefore reaches a decision, a plan or a comment tagged as verified with nothing between it and
  belief.
  (overture#2035 and #2517: a funnel measured by SQL beside the app counted a web form or a DM as a
  contact, which the shipped rule excludes because neither can be written to, so the design note said
  81 shows held a contact where the code said 66, and 49 waiting where it said 38. It passed the full
  suite, CI and a merge, and was caught only when Dan read the real numbers off his own screen)
- **L156. A success check that looks for a SUBSTRING OF THE THING BEING TALKED TO (a hostname, a
  command name, a file path, a resource id) also matches the ERROR about it, because a failure
  message quotes its target, so match the shape of the SUCCESS output instead.** The check then
  reports success hardest at the exact moment the thing failed, and a retry loop built on it stops
  retrying on its first failure. Distinct from L100, where the operation matched NOTHING and the
  silence read as success: here the match is real, and it is the error text that satisfied it.
  (2026-08-16, caught live: a loop retrying `gh issue create` through a network fault decided it had
  worked by finding "github.com" in the output, and the failure is
  `Post "https://api.github.com/graphql": dial tcp ...: can't assign requested address`. It printed
  FILED and stopped. Correct predicate: the issue URL itself,
  `^https://github\.com/[^/]+/[^/]+/issues/[0-9]+$`)
- **L115. A harness that measures whether content is VISIBLE must be checked against the
  substitutes its own renderer makes for content it cannot draw, because a placeholder is
  itself a mark on the page and measures as presence.** A surface built only from controls the
  renderer does not support then clears every legibility check while showing no words at all,
  and the check reports hardest on exactly the surface it can see least of. Measure a bare
  unsupported control once, assert that it scores as content, and either exclude it from the
  measured surfaces or render those through a real host.
  (PostRoll#396, #404: SwiftUI's ImageRenderer has no AppKit host, so `Menu` and `ProgressView`
  come out as a bright placeholder block that measured well above the ink threshold separating a
  legible screen from a blank one)
- **L141. A visibility check that measures ink over a whole surface is answered by whatever that
  surface paints for ITSELF, a fill, a border, a panel, so the words it exists to check can be
  drawn in the background colour while the measurement barely moves.** Assert the contrast between
  the text colour and the colour behind it, read from the values the view actually draws with
  rather than a copy of them, and prove it by making the text invisible and watching the check go
  red. The sibling of L115, where the renderer's own substitute measures as presence: here nothing
  is substituted and the surface's legitimate decoration is what answers for the missing type.
  (PostRoll#559: the Insights staleness notice measured 0.0799 against a 0.01 threshold with its
  sentence drawn in the colour of its own panel, because the panel and its rose gold border were
  what the check was reading. A filled button was worse still at 0.2475, almost all of it the
  button's own background. Found by mutation, not by review: the first guard written for it
  SURVIVED)
- **L147. A guard seen to fail on a fixture you chose has only been shown to work on the shape you had
  in mind, so measure how often it fires on the REAL values it will meet.** An exact comparison on a
  normalized name (a domain, a slug, a key) routinely misses the common case for a difference the
  normalization keeps, and a guard that never fires is indistinguishable from one with nothing to catch.
  Distinct from L1, which any red satisfies: here the guard genuinely goes red on the fixture and is
  still blind to production. The mirror of L93, which catches a guard firing on the common case it was
  not written for.
  (overture#2743: `VenueContactGuard` compares a slugged venue name to the domain's second-level label
  exactly, so `thegreenroom42` never equals `greenroom42` and the guard keeping a room's own address out
  of the product, the oldest standing rule in it, has never fired on the room behind four of Dan's five
  open pitches. Its tests pass, because every one of them was written with a venue whose name carries no
  article)
- **L117. A per-item ceiling judged against a POOLED total cannot notice one item running away, because
  the expensive item is paid for out of the cheap ones' headroom, and a single-item run is the only
  size where the ceiling and the total are the same number.** So the guard fires on the smallest runs
  and stays quietest on the large ones it was written for, whose silence then reads as proof they were
  fine. Enforce it per item, which means RECORDING per item, and measure the firing rate against real
  runs of each size rather than trusting the arithmetic.
  (overture#2617: a 15 lookups per show cap pooled to an 810 allowance on a 17 show run that used 338
  and never warned, while the same show checked alone spent 18 against 15 and did, so every warning
  Dan has seen came from the cheapest run the app makes. Note the first version of THIS lesson said
  a pooled ceiling can only ever be tripped by a single item run, which the same data refuted: one
  14 show run reached 71%, so the absolute claim was the measurement being flattered, L107)

- **L130. A test fixture whose meaning is the RELATIONSHIP between a stored date and the clock (a show
  still ahead, a licence not yet expired, a record inside its retention window) must pin BOTH ends,
  because pinning only the fixture lets real time walk the pair into a different state and the test then
  passes while asserting about a case nobody chose.** The tell is a literal date sitting beside a bare
  read of now, and it fails silently in both directions: one such test had spent months asserting that a
  show 27 days in the past should still be chased. Distinct from L39, which pins the clock to test month
  and DST boundaries: there the clock is the subject, here it is the half of a pair nobody thought of as
  an input at all.
  (overture#2669, overture#2670: four fixtures in one session, every one of them red the moment a rule
  about shows that have already performed arrived, and not one of them red for a reason it asserted)

- **L134. A test that derives two inputs from the same LIVE shared resource read at different moments
  must ASSERT the separation it depends on, never assume it, because the healthy margin is usually one
  unit of that resource's own granularity and a single stale read closes it exactly.** The resulting
  intermittent failure is indistinguishable from the defect the check exists to catch, so it is
  investigated as a real outage every time and then dismissed, which is how a canary stops being read.
  (slate#1489: a production booking canary picked one slot from a list fetched at the start of the run
  and the other from a list fetched mid run, whose head shifts by exactly one event length while an
  earlier scenario's booking is still cached, so the two landed on the same instant, the API deduped
  correctly, and the same two checks paged three times in ten days)

- **L135. A guard that matches source text over a WHOLE FILE is satisfied by any occurrence in it, so a
  second legitimate use of the same construct elsewhere in that file answers the check while the region
  it was written about is broken.** Scope every source assertion to the function or declaration it is
  about, because a large file makes a coincidental match near certain and the guard reads greenest
  exactly when it is blindest. Distinct from L103, where the guard is satisfied by a COMMENT about the
  thing: here it is satisfied by real code correctly doing the same thing somewhere else, so stripping
  prose does not help and nothing about the match looks wrong.
  (overture#2726: a guard asserting the Reached Out list drew a quiet exit row searched the whole of
  QueueView.swift, and the date-grouped list draws that same row from another function, so it passed
  unchanged on a mutation deleting the Reached Out branch's entire conditional. Two more guards failed
  the same session for the neighbouring reasons, a searched substring surviving a rewrite that inverted
  the rule, and a fallback defended against a state no writer can produce)

- **L142. When phasing a risky change into observe then enforce, check WHICH half the observation
  covers: the observed half is usually the one you understand, and the harm usually lives in the
  other, so an observe phase that never exercises the dangerous path buys confidence about the wrong
  thing.** Split the phases along the axis of BLAST RADIUS rather than along the axis of what is
  easiest to watch. Distinct from L56, which asks for one observed cycle before a validator blocks,
  and from L3, which asks that a guard be proven to execute: here both are honoured and the rollout is
  still blind, because the phase boundary was drawn in the wrong place.
  (project-enrollment-tracker#1036: a plan to derive PET's access list phased it as compute-then-use,
  so phase one watched the computation, which was pure and unit tested, while the thing that could take
  the whole app offline was the edge gate importing the generated file at all. That import is at module
  scope, so a throw there fails every request including the login page, leaving nobody able to sign in
  and fix it, and it would first have run in the phase that also changed who was on the list)

- **L144. A monitor reporting whether an action HAPPENED must judge by the same predicate the
  action used to decide whether to ACT, or the two disagree precisely when the action correctly
  declined, and the resulting false alarm cannot be cleared by the remedy it names, because
  re-running the action makes it decline again.** The second harm is the one that costs: while
  stuck, the monitor cannot report the real failure it exists to catch, since both read
  identically. Distinct from L16, which shares one predicate between a count and its rows inside
  the product, and from L119, where an empty index entry is mistaken for guilt: here both sides
  answer confidently and mean different things by the same question.
  (bidspoke#802: the deploy decides the worker changed by building the bundle at both commits and
  comparing bytes, while the drift check asked git which commits touched the apps/worker path, so
  a commit changing only worker TEST files paged hourly from 21:40 on 2026-08-14 with nothing
  unshipped, and its printed fix, re-run the deploy, hit the same artifact gate and skipped again)

- **L146. To check that content reached a rendered surface, measure the surface WITHOUT that content and
  take the difference, because any quantity computed over the whole surface (ink, coverage, a pixel
  count) also counts the fill, the border and the controls, and can even RISE when the content is
  removed, since removing it changes what the commonest colour is.** Keep the with-content side
  uninstrumented: an instrument added to both sides can change the path the content takes and dissolve
  the very defect being looked for, which is how a probe reported every screen healthy while measuring a
  screen the product never draws. The remedy L141 reaches for, asserting contrast between the type and
  what is behind it, answers whether content COULD be read; this answers whether it is there at all, and
  a floor derived from the difference is one number every surface can share instead of one per screen.
  (PostRoll#612, PostRoll#614: three thresholds had drifted down to fit sparse screens, three notices
  measured MORE ink with their words switched off than with them on, and the first version of the probe
  drew an animating view's label perfectly as soon as that view's type went through a renderer of ours)

- **L165. A fixture built by damaging the END of something lets the scenario finish its real
  work before failing, so the case under test never occurs while the test reads as convincing,
  and it passes for a reason unrelated to what it claims.** Break the input where the work
  BEGINS, and confirm by hand that the scenario actually fails the way the test describes.
  Distinct from L48, where the fixture's shape was invented rather than measured: here the
  shape is right and the damage is in the wrong place.
  (claude-config#28: a pulled script broken by appending a bad line after its dispatch
  completed its entire job successfully and failed only on the last line, so the self-update
  it was meant to block went through normally. Four fixtures in one session failed this way)

## Data safety

- **L5. Never destroy good state before its replacement is verified to exist.** Write to
  temp and rename, keep the prior version until the new one is confirmed, defer physical
  deletes until undo expires, and never let a blank value beat real data in a merge.
  (16 issues, 2 repos)
- **L95. Adding a WRITE to an error path re-audits every error that can reach it**, because a
  misclassification that was harmless while the path only reported becomes data loss the
  moment it persists. The classification was never checked against the new consequence, and
  the branch reads as long-settled code, so review skips it.
  (PostRoll#262: a salvage branch added to the failure path merged a half-finished run over
  hand-edited captions on Cancel, because cancelling surfaces as an ordinary script failure,
  which had never mattered while that path only showed a message)
- **L7. User data gets a rotating backup and a restore path from day one.** A single
  .bak copied from the possibly-bad current file is not a backup. Rehearse every
  destructive migration against a copy of the real store, never only fresh data.
  (12 issues, 3 repos)
- **L8. Own your paths.** Never leave data at a framework or OS default location or
  name, never share a default resource (clipboard, default store, one appended log)
  between concurrent writers, and put app data in the platform-correct home before the
  first byte. (14 issues, 3 repos)
- **L9. Destructive actions get confirmation or undo from the first build, and any
  automatic deletion or retention policy is the user's product decision, never a silent
  default.** (9 issues, 4 repos)
- **L40. A check that decides to SKIP work must compare something that changes whenever
  the content changes.** Size plus timestamp, or any cheap stand-in, silently keeps the
  stale copy whenever the stand-in happens to match, so compare the content itself
  wherever skipping means keeping what is already there.
  (claude-config#6)
- **L105. A read, modify, write cycle whose read answers EMPTY when it fails will erase the
  whole record the first time the read fails, and it does so at the exact moment the record
  is worth having.** Distinguish absent from unreadable at the read itself and refuse the
  write on unreadable, because both look identical to every caller downstream and only one
  of them is safe to rebuild a file from.
  (downbeat#165: three append-by-rewrite logs, the commit failures, the Overture export and
  the warnings, each treating an unopenable file as an empty one and writing a single line
  back over it)
- **L116. A rule that only encodes somebody's PREFERENCE must be enforced by filtering what is
  shown, never by deleting the data it filters, because a preference can be reversed and the data
  cannot be brought back.** Enforcing it by deletion also makes the reversal invisible, since the
  code then reads as though the value was never found.
  (overture#2421 deleted 45 social-only contacts to enforce "an Instagram is a dead end", and when
  that call was reversed on 2026-08-13 the handles were gone from 33 shows and only a paid re-check
  could recover them)

- **L136. Clearing a field to CORRECT bad data is a state change whose consequences live in every
  reader of that field, and a constant named for the empty case (a noManager message, a notSet
  label) can be a hard REFUSAL rather than a graceful fallback, so read what the null branch DOES
  before writing the null.** The correction then moves the person from a wrong but working state
  into a blocked one, and it reads as obviously right the whole time precisely because the empty
  case appears to be handled. Distinct from L38, which enumerates the derived resources a delete
  must also touch: here nothing else needs deleting, and the damage is done by a reader that
  refuses.
  (slate#1474 cleared a manager link Salesforce contradicted, correctly, on the strength of the
  request flow already having a NO_MANAGER_MESSAGE for the empty case; that message is a refusal at
  submission, so the manager could no longer request time off at all, and it told him to ask an
  admin to set a manager that no surface can now set: slate#1499)

- **L168. A parameter a function needs in order to be CORRECT must never carry a default standing
  for absent, because a caller that forgets it then receives silently missing data instead of a
  compile error, and the failure surfaces far away as a blank value rather than as a refusal.**
  The default reads as a convenience for the callers that genuinely have nothing to pass, and it is
  indistinguishable at every call site from one that simply forgot. Distinct from L138, where a
  missing setting arrives as an empty string the absence check accepts: here the value never arrives
  at all and the language would have said so.
  (downbeat#244: moving a booking's venue onto each show made the venue an id resolved against the
  roster, and five entry points took that roster with a default of none, so a screen that forgot it
  would render and commit a booking with the venue missing from the folder name, the task text, the
  calendar sentence and the filename, with nothing anywhere reporting it)

## Honest failure

- **L10. An error state and an empty state are different screens.** Never render a
  cheerful empty state over a failure, and return real not-found semantics rather than a
  200 shell. (16 issues, 3 repos)
- **L11. Distinct causes get distinct messages, and a message may claim only what its
  check actually measured.** A fallback or unreadable value presents as "could not
  read", never silently scored as an answer. (21 issues, 3 repos)
- **L12. Show success only after the write commits, and report what verifiably
  happened.** No success UI over a detached save; "sent" means the external system
  confirmed. (12 issues, 4 repos)
- **L13. Background jobs and webhooks alert on failure and on the absence of an expected
  run.** A caught error that never reaches monitoring is invisible twice; also alert on
  zero work done while a backlog grows. (30 issues, 3 repos)
- **L53. Two independent checks must never share one status field.** A pass from one
  silently erases the other's failure, so the alert that depends on it can never reach
  its threshold and the condition it watches becomes unreportable; give each check its
  own counter and judge it against its own cadence. (slate#1150)
- **L90. A counter or category whose only input is a value nothing in the system ever writes
  reports ZERO, and zero is indistinguishable from a true measurement.** The mirror of L46:
  that one catches a field written but never read, this one catches a reader whose value has
  no live writer, and it is the worse of the two because it fails as a confident number rather
  than as a blank. Assert that every value a reader branches on is actually produced somewhere.
  (overture#2401: the funnel's lost count could only be filled by two show-level values that no
  code path writes, so it read zero while every closed-out show was tallied as "no response",
  and the history teaching the scout could learn that an org booked Dan but never that one
  turned him down)
- **L47. A batch that partly fails must record the attempt on the items it failed, not
  only on the ones it completed.** An item left with no trace is indistinguishable from
  one never attempted, so the work is silently selected and paid for again, and the
  partial result reports as a clean run. (overture#1724)
- **L67. A placeholder rendered in place of a missing required value (no subject, unknown, not
  set) is a DETECTION that the value is absent, so it must block the action it appears in, never
  merely label it.** The code substituting the placeholder has already proved the data is missing,
  so leaving the commit button enabled beside it means the app told the person it was wrong and let
  them proceed anyway.
  (overture#2052)
- **L138. A templating or interpolation layer usually renders a MISSING setting as an EMPTY value
  rather than an absent one, so every absence check written as a null fallback silently accepts it
  and the default it promises never applies.** Validate that the referenced setting EXISTS, and
  treat empty as absent at the read, because the wiring reads as configured either way and the
  failure surfaces far from it. Distinct from L3, where the guard was never wired at all: here it
  IS wired, to nothing.
  (slate#1494 wired SLATE_BASE_URL from a repo variable that does not exist, so GitHub passed the
  empty string, the `?? "https://slate.trypennie.app"` fallback accepted it, and the production
  canary failed 11 minutes after the merge with `Failed to parse URL from /api/availability`. Two
  scripts had been converted to an empty-safe read and the shared helper every request goes through
  had not: slate#1498, slate#1500)

- **L152. A change is usually reported by the surfaces that show what is still OUTSTANDING (a badge, a
  waiting list, a standing question), so an operation that RESOLVES everything silences every one of
  them and the most complete success is the one the product says least about.** Give the completed
  state its own durable line naming what was captured and that nothing is waiting, because a fully
  successful run and a run that never happened otherwise look identical on the screen the person is
  standing in front of. Distinct from L148, where a refusal's reason evaporates, and from L126, where
  the remedy outlives nothing: here the action fully succeeded and its own success is what removes
  every surface that could have reported it.
  (overture#2806: linking a Gmail conversation onto a form pitch wrote five facts including a new email
  address on a contact, then stamped the reply as already handled, which is exactly the state whose row
  draws nothing at all, so Dan asked whether the link had worked)

- **L50. A value parsed from storage or input must never feed a comparison
  directly.** A failed parse yields NaN or an invalid value that compares false
  against every threshold, so the check silently lands on the healthy or
  permissive side with no error ever raised. Parse through one shared helper that
  returns a value or null, and map null to the fail-safe side at each call site.
  (slate#1169, slate#1171)
- **L71. A watchdog must not share the abort-on-error behaviour of the work it watches**,
  because an incidental failure then kills the watchdog silently and leaves the work
  running unobserved, which looks exactly like a healthy system. Give it its own error
  handling and a fail-safe exit that stops the work it can no longer vouch for.
  (overture#2106, overture#2109)
- **L77. An error deliberately classified as EXPECTED (a lost race, a declined payment, a
  rejected duplicate, a taken slot) must still be counted against a RATE.** The code waving
  it through has no notion of volume, so one benign instance and a systemic outage arrive on
  the same path and are indistinguishable, which leaves the second invisible for exactly as
  long as it lasts. Classify by frequency, not only by kind: normal below a threshold, a page
  above it.
  (slate#1313, slate#1315: cal.com refused 50+ bookings in two hours because its booker
  offered slots that were not free, and every one of them looked like ordinary contention)
- **L94. A request or payload assembled in two places, a builder plus a caller that adds more
  fields, has nowhere its completeness can be seen, so a field missing from both halves is
  invisible to a reader of either.** Assemble it in one function and give that function the
  whole input it needs.
  (PostRoll#266: the Friday re-render manifest was half built by a helper and half by its
  caller, and the key that keeps a user's own music was in neither, so every hand-edited
  Friday silently swapped his track for a stranger's)
- **L78. A report of what changed must be assembled from the finished state, never from one of
  the code paths that change it.** A write deliberately routed around the ordinary path to
  PROTECT it (a merge held back so a copy cannot clobber it, a hand applied fix, a retry) is
  thereby also missing from a summary built only from the ordinary path, so the tool says
  nothing happened about the very change that needed special handling, and any instruction
  hanging off that report (restart, re-read, re-run, go look) never fires. The protection and
  the blindness come from the same exclusion, which is why it reads as correct in review.
  (claude-config, 2026-08-06: a config pull merged three entries into the rule file every
  session loads, then printed "nothing on this Mac needed changing" and named nothing to
  restart for)

- **L106. A liveness signal emitted on a timer (a heartbeat, a keepalive, a still-working marker)
  proves only that its EMITTER is alive, never that the work is progressing, so a live signal over
  dead work is indistinguishable from a healthy run.** The mirror of L71: that one catches the
  watchdog dying while the work runs unobserved, this one catches the work dying while the watchdog
  keeps vouching for it, and this is the worse half because it actively reassures. Tie the signal to
  observed progress, or surface both facts separately so a fresh heartbeat beside a frozen count
  reads as the alarm it is.
  (overture#2506: a paid 27 source run finished its work at 10:47 and was still reporting "26 of 27,
  running" at 11:43, because one parallel chunk's worker died writing nothing at all while the
  heartbeat kept touching the marker every few seconds. The 10 minute staleness timeout could never
  fire, since the marker was never stale. Dan saw it was stuck from the screen and was talked out of
  it twice on the strength of a fresh heartbeat, while the results file's CONTENT had not changed)

- **L108. A check that validates a value's recognisable PREFIX or shape, but not its
  completeness, accepts a truncated paste and then stays silent, and that silence reads as
  confirmation the whole value is good.** Validate length and shape together for anything
  copied by hand (keys, tokens, account numbers, ids), and refuse rather than warn, because
  the failure otherwise surfaces as an authentication or lookup error far from the paste
  that caused it.
  (PostRoll#348: the API key field checked only that the value started with sk-ant-, so
  thirteen characters of a hundred and eight sat stored and unremarked from 2026-08-09,
  the field rendered as dots so it looked full, and the metered path had never once run)

- **L109. A refusal message that can only be spoken by an action, while the same predicate that
  would produce it disables that action, can never be spoken, so the person is left with a dead
  control and no reason while the code reads as careful and its tests pass.** Render the refusal
  where the gate is applied, from the same function, so the reason and the disabling cannot
  disagree.
  (overture#2544: the manual prep sheet computed a refusal naming the missing field on every
  keystroke, kept only the boolean, and disabled Save draft; the four sentences it discarded were
  reachable only through the save path that button opens, so Dan met a greyed out button with an
  empty Subject box and nothing on screen connecting the two)

- **L110. A wait for a condition with no deadline cannot fail, it can only hang, and a hang is worse
  than a failure because it is indistinguishable from slowness and holds whatever shared resource it
  acquired.** Give every wait a timeout that names what it was waiting for, because the first person
  to trip it spends hours believing the machine is merely busy. Distinct from L98, which catches a
  watcher that finds nothing and calls it success, and from L106, which catches a heartbeat still
  ticking over dead work: this is the wait that emits no signal at all and is read as patience.
  (overture#2576, overture#2577, 2026-08-12: making a greeting required turned one test fixture
  unsendable, so a `while cleared.isEmpty { await Task.yield() }` never exited; the run span for over
  an hour writing 21MB of repeated CoreData errors while holding the machine wide xcodebuild lock,
  a second run sat blocked behind it for 50 minutes, and three consecutive status reports said
  "waiting on the suite" when the work had been dead the whole time)

- **L121. A retry or self heal step that decides from a RECORDED success marker (a stored
  status, an effects string, an ok field) cannot notice that the artifact it created has since
  been deleted, so it suppresses its own repair permanently.** Decide from the artifact's
  current existence, and treat a null reference beside an ok marker as damage rather than as
  done, because the two halves are usually written by different code and nothing compares them.
  (slate#1464: an approved time off whose calendar event timed out fell back to a Slate busy
  block, which a reconcile sweep deleted 31 seconds later as an orphan. The foreign key was ON
  DELETE SET NULL, so the record ended up saying no block was ever written while its effects
  still read "ok (slate fallback)", and the guard skipping the step on any effect starting with
  "ok" meant no later pass could ever put it back)

- **L122. A permission or capability check written as equality against ONE rank of a ranked
  vocabulary silently excludes every rank ABOVE it, so the most privileged person is the one
  refused.** Compare through the shared at least predicate, and exercise the TOP tier in the
  test, because it is the rank no fixture reaches for and the person holding it is usually the
  one who never gets asked whether the control worked.
  (slate#1468: the admin only retry that repairs a failed time off gated on `role !== "admin"`
  in a five tier hierarchy, so the owner, whose role is `super_admin`, met "Not authorized" on
  the one control that could fix slate#1464, while the button itself rendered for every role
  from team lead up)

- **L125. A function answering WHEN something comes due must not fold in the test for whether it is due
  YET, because reporting nothing for a moment still in the future is indistinguishable from having no
  moment at all, and any fold that takes the soonest of several such clocks then confidently names a
  later one.** Keep the schedule and the is-it-now test as two functions, so a countdown reads the
  schedule and a gate reads the test. Distinct from L98, where finding nothing reads as success: here
  the silent clock is the nearest one, so the answer is not merely missing but wrong in the reassuring
  direction.
  (overture#2646: `PostEventPrompt.nextPromptDate`, commented as the single source of truth for when a
  prompt is due, guarded `now >= dayAfter` and returned nil until the date had already arrived, so a
  row for a show performing that night counted down to a follow-up nudge five days out while the thing
  actually owed landed the next morning, then jumped to "Reach out now" overnight with no warning)

- **L139. A minimum volume floor added so a RATE is not noisy at small samples also silences the
  SATURATION case, because a proportion cannot tell one bad out of two from twelve bad out of
  twelve.** Pair every rate threshold with a separate near total rule carrying its own much smaller
  floor, or the clearest evidence a source is broken is precisely the evidence the guard is built to
  discard. Distinct from L117, which catches a per item ceiling judged against a pooled total: there
  the arithmetic hides one bad item among many, here the floor discards the item entirely before any
  arithmetic runs.
  (bidspoke#744, bidspoke#777: an email drop alert judged each lead source on a 5% rate above a 20
  lead floor, so a source sending twelve leads with all twelve addresses rejected was never judged at
  all, which Dan spotted immediately on reading the shipped behaviour)

- **L148. A durable control whose failure reason is written only to a surface that dies with the
  attempt (a terminal window that closes, a process's stderr, a toast) leaves the person facing the
  same control, the same unchanged condition, and no way to learn why it did nothing, so pressing it
  again is the only diagnosis available.** Persist the reason wherever the condition itself is
  reported, because a control that refused and a control never pressed are otherwise
  indistinguishable. The mirror of L126, where the condition persists and the remedy is transient:
  here the remedy persists and the explanation is what evaporates.
  (downbeat#210: the stale copy panel's Update button refused, printed its reason into a Terminal
  window that then closed, and the panel went on reporting the copy as behind with no record that an
  attempt had been made. The reason given was also wrong, which nothing could have revealed, since
  the only place it was ever written no longer existed)

- **L158. When the text a failure is diagnosed FROM can come from more than one place (a launcher
  shell and the process it launched, a supervisor and its child), a rule that takes whichever place
  is non empty hands the diagnosis to the launcher, because the launcher speaks exactly when the
  real work never started.** Read the failed process's own output first and treat the launcher's as
  context, since the one that has something to say is the one whose failure came first, and it is
  never the one you meant to diagnose. Distinct from L11, which asks that distinct causes get
  distinct messages: here the classifier is working correctly and has been handed the wrong text.
  (PostRoll#650, found while fixing PostRoll#648: the app redirects Python's stderr into a per run
  log and reads that log only when the stderr pipe is EMPTY, so a checkout that had moved produced
  one line of shell output, `zsh:cd:2: no such file or directory`, which matched the classifier's
  missing file rule and told the photographer to check that his PHOTOS were still in their original
  locations, while the real traceback sat unread. Today the login shell is silent, so the first
  Homebrew notice or zsh deprecation warning would misclassify every failed run)

- **L160. A condition is only OVER once it has stayed healthy for a re-arm window, never on the first
  healthy sample, and its duration must be measured to the last observed failure rather than to the
  moment the all clear is sent.** Otherwise the first quiet minute inside a flapping outage ends the
  incident, and every relapse after it is announced as a new short one, each arithmetically correct
  and all of them together false about the thing the reader actually lived through. Distinct from
  L36, which is about how the alert FIRES: this is the recovery half, which nobody re-reads because
  it only ever brings good news.
  (bidspoke#814: an Equifax ACRO_GATEWAY outage ran 9:25 to 11:04 PM over 1,326 failed runs, went
  quiet for 23 minutes in the middle, and was announced to the team as an incident lasting 5 minutes)

- **L164. Failure recording that lives INSIDE the program a launcher starts cannot record any
  failure of the launcher itself, so a missing directory, a bad path or an unreadable interpreter
  leaves no trace at all and reads exactly like the control never having been pressed.** Put the
  recording where the wrapper can reach it too, because a wrapper's own failures are both the
  likeliest and the least visible. Distinct from L148, where the reason IS produced and written
  somewhere that dies: here it is never produced, because its producer never ran.
  (downbeat#228: pressing Update ran a launcher whose cd into a moved checkout failed, so
  update-downbeat.sh, which holds every path that writes update-attempt.json, never started, and
  the panel went on saying "behind" with no record of the attempt)

## State and identity

- **L14. Derived state re-derives on every input that feeds it, and every action updates
  every surface showing what it changed.** Enumerate the inputs, then the surfaces; a
  correct save that still shows the old value reads as a failed save. (25 issues, 3 repos)
- **L15. Key everything on stable identifiers.** Never mutable strings, display names,
  positional indices, or fabricated fallbacks; when a key must change, record the
  old-to-new mapping for everything still holding the old one. (16 issues, 4 repos)
- **L145. Changing a record's identity IN PLACE can land on an identity another record already holds, so
  check the destination is free before writing it.** Under a unique constraint the write either fails and
  leaves the record half-changed, or silently merges the two and destroys one's history, and both
  outcomes look from the call site exactly like the operation working. The other half of L15: that one
  covers carrying the old-to-new mapping to everything still holding the old key, this one covers the new
  key not being anybody else's.
  (overture#2754: dropping one night of a multi-night run re-keys the row onto its next night, and 8 of
  98 live runs have a SEPARATE stored card on that very night, because a weekly series is stored both as
  a run carrying every night and as individual cards. Found by measuring the live store immediately after
  merging, not by any test)
- **L153. A path built from the user's home directory plus a literal folder name records where
  something happened to be, not what it is, so the first time anyone moves it the code points at
  nothing.** Derive a location from the artifact that needs it (the running bundle, the source file's
  own path, the repo root), because a suite gated on that path's existence then skips rather than
  fails, and a skip is indistinguishable from a pass. Distinct from L8, which is about never settling
  for a framework or OS DEFAULT location: here a location was chosen deliberately, and chosen by
  where the thing sat rather than by what could find it again.
  (PostRoll#648, downbeat#217: moving five projects out of iCloud Drive on 2026-08-16 broke the Mac
  app's Python lookup and silenced Downbeat's research fixture suites in the same moment, and only
  the app half was visible. The first sweep for the damage filtered by file extension and missed
  every Swift file, so it reported the move as cosmetic)
- **L16. A count and the rows it promises come from one shared predicate**, and any
  cross-cutting filter or threshold is one named implementation every consumer is forced
  through. (16 issues, 2 repos)
- **L17. Long-running work belongs to an owner that outlives the screen that started
  it**, and re-reads live state at write-back instead of a copy captured at start.
  (6 issues, 2 repos)
- **L55. A reader whose correctness depends on which code path produced the state it
  reads breaks silently when a second path starts producing that state.** When you add a
  writer for an existing status or flag, recheck every rule that interprets it, because
  the assumption is usually recorded only in a comment and the rule keeps answering with
  confidence. (overture#1797)
- **L59. Bookkeeping state that changes for reasons unrelated to the data (a scroll position,
  an in flight animation, a hover, a tick) must not live on the component that derives the
  expensive data, because every such write pays the whole derivation again.** Keep it on its
  own object read only by the small control that shows it, and let an idle surface pay
  nothing. (overture#1774, overture#1922, overture#1923)
- **L60. A one-shot trigger (navigate to, scroll to, present, run once) must carry an event
  with its own identity, never the destination value, because a change-detecting effect
  cannot see a repeat request for the same target and silently drops it.** The second
  identical request is the case a first walk never tries, so it ships looking correct.
  (overture#1774, overture#1927)
- **L83. A fact that could sit at either of two levels (the organisation or the contact, the order
  or its line, the show or the person on it) must have ONE declared home, and every writer and
  reader must use it.** A fact written at one level and read at the other goes missing in exactly
  one direction, so the writing file and the reading file each look correct alone and only somebody
  holding both notices. A guard phrased at the coarser level does the same damage, silently
  excluding a whole segment from a per item rule that was already enforcing the same thing.
  (overture#2225 wrote the booking on the show and read it per contact, overture#2226 wrote it on
  the contact and read it on the show, overture#2223 skipped booking detection for every past
  client on an organisation level flag)
- **L86. A short lived component that registers actions, observers or callbacks into a longer
  lived shared host (an undo stack, a notification center, an event target, a subscription
  registry) must either own a private instance of that host or deregister on teardown, because
  these hosts routinely hold unowned references and outlive the component.** The shared default
  also silently merges independent components' histories, so one instance's undo, replay or
  callback reaches another's state.
  (PostRoll#196: seven text editors sharing the window's NSUndoManager, which does not retain
  its targets, so holding Cmd+Z walked past the live editor's history into a freed one and
  killed the app)
- **L89. When two controls can write the same stored field, their option lists are one
  vocabulary and must be reconciled against each other, not each against some third
  reference.** A list trimmed carefully against one neighbour still duplicates a second one
  sitting beside it, and the duplicate reads to the person as two different outcomes while
  the report counts one.
  (overture#2388: a close-out menu deliberately trimmed against the Archive card's menu,
  with a comment saying so, still offered the same stored outcome as the state menu
  rendered one line beneath it)
- **L91. A user action's visible response must not wait on a derivation whose cost scales with
  the whole collection rather than with what changed.** Removing one row by rebuilding every row
  reads as a broken control at any real data size, and the person presses it again, so decouple
  what the screen does on the press from what the store recomputes after it.
  (overture#2417: closing a show out took a second or two to leave the screen, because each write
  invalidated the queue's whole query and rebuilt every card, whole-corpus derivations included,
  on the main thread; the same lag struck an address off a card, and Dan named the pattern before
  anyone had looked at the cause)
- **L131. A map keyed by a value the real data can repeat (a date, a name, a day) silently keeps the
  LAST writer and discards every earlier one, and because the surface renders one row per key the
  loss is invisible on the very screen that exists to report it.** Check the live data for a repeat
  before making something a key, and where one can occur hold a list rather than a single value.
  Distinct from L66, which collapses several records onto one shared external identifier and then
  writes member level facts about all of them: here the other members are dropped outright, so
  nothing downstream can even know they existed.
  (overture#2693: the blocked calendar stored one booked shoot per date under a comment reading "a
  day cannot be blocked twice", which is true of the blocking decision and false of the shoots
  behind it, so two of Dan's fifteen bookings were missing from the list of what he already has on,
  and which of each colliding pair survived was decided by the order the export happened to list
  them in)

- **L162. A completion flag whose only writers are actions performed INSIDE your product is
  permanently wrong for anyone who does the work in the tool that work actually lives in (a mail
  client, a CRM, a calendar), so when the truth is visible in a system you already read, derive it
  from there rather than waiting to be told.** The record then asserts for ever that something is
  outstanding, and nothing about the code looks wrong, because every path that exists writes the
  flag correctly. Distinct from L46, where a field has no reader at all, and from L90, where a
  reader's value has no live writer: here the field is read constantly and the writers are real,
  they are simply all on the inside.
  (overture#2865: `replyHandledAt` has three writers, the in-app send, the copy-out button and a
  one-shot check made at the moment a Gmail conversation is linked, so a reply Dan answers from his
  mail client leaves the row reading "waiting on you" for ever. The routine reply check re-reads
  that same Gmail thread every half hour, already holds the JSON that answers the question, and
  never asks it. Two live conversations were in that state when it was found)

- **L163. When the model has no field for a fact, never express that fact by NEGATING a neighbouring
  one, because the negated field goes on being read as its own fact everywhere else and the system
  then confidently asserts the opposite of what happened.** Add the field, since a missing column is
  a day's work and a corrupted one is a number nobody can tell is wrong. Distinct from L136, where
  clearing a field was the CORRECT response to bad data and the harm came from a reader that refused,
  and from L83, where one fact was written at two levels: here the clearing is simply false, and
  every reader is behaving properly.
  (overture#2868: an `Inquiry` has no "Dan answered" stamp, so linking a conversation he had already
  answered says so by setting `replied = false`. `InquiryReporting` branches on that exact flag, so a
  hire inquiry where somebody really wrote and he really answered is filed permanently as "Dan
  replied, they never answered". The same shape as overture#2401, arriving by a different route)

- **L166. An action that carries out a decision must be addressed by every attribute the decision was
  made over, because an instruction scoped by fewer names a FAMILY where the decision named one
  MEMBER, and it silently acts on the records the decision deliberately excluded.** The deciding code
  reads as correct throughout, since it really did choose correctly, and the harm is done by the
  instruction that carries the choice out. Distinct from L75, where identifying the target FAILS and
  the fix is to refuse: here identification succeeds and merely under-specifies, so nothing anywhere
  reports a problem. Also distinct from L16, which shares one predicate between a count and its rows,
  and from L144, where a monitor and an action answer the same question differently.
  (overture#2885: `OmniFocusSync.reconcile` decides per (show, contact, due date) and correctly chose
  to complete only the stale-due follow-up task, then called `complete(naturalKey:recipientId:)`,
  which carries no due date, so the AppleScript it built matched EVERY open task for that show and
  contact and would have ticked off the live reminder as well. It was caught only because the same
  script tripped a separate crash on its second iteration and died before reaching the live task, and
  the order OmniFocus happened to return them in is what decided whether a real reminder was lost)

- **L169. A variable recording that a step has ALREADY HAPPENED is inherited by every process that
  step starts, so a descendant reads it as true of ITSELF and skips work it never did.** Clear such a
  flag for anything you spawn, because the descendant looks correct read alone and the skipped work
  is invisible. Distinct from L55, where a second writer changes what a stored value means: here
  there is one writer and the value is simply carried somewhere it was never meant to apply.
  (claude-config#37: a section-limited test run re-executes itself with a flag meaning "extraction
  already done", which its own children then inherited, so each ignored the section limit it was
  given, ran the WHOLE suite, reached the section that spawns, and started another. One process at a
  time rather than a burst, so no process count tripped and it read as a suite merely taking a
  while. It happened twice in one session, the second time after the first had been fixed)

## Security and privacy

- **L18. Enforce authorization at the database layer, not only in application code.**
  Row-level security with WITH CHECK on every self-write policy, column guards on
  privilege fields, least-privilege grants, shipped in the same change as the schema.
  (27 issues, 2 repos)
- **L19. Secret checks fail closed and compare constant-time through one shared
  verifier.** Secrets never reach logs, process arguments, repos, client binaries, or
  diagnostic exports; PII is never committed, logged loosely, or stored on a public
  bucket. (22 issues, 5 repos)
- **L42. A control that exists to protect someone fails closed, not open.** When the
  data a block list, permission check, or content filter depends on cannot be loaded,
  keep hiding or refusing rather than defaulting to an empty set, because an empty
  protective list is indistinguishable from no protection and the person it protects is
  never told. (playedit#307)
- **L43. A platform's built in request authentication is not caller authentication when
  it accepts your public client key.** Supabase's verify_jwt passes the anon key that
  ships inside every app binary, so an endpoint can look protected while accepting
  anyone: establish the caller yourself and reject the public key explicitly.
  (playedit#308, playedit#335)
- **L72. A gate's stored DEFAULT must be its OFF value, so that FORGETTING to set it
  produces the safe state rather than the live one.** A default of enabled, bookable,
  active, visible or published means every insert path that omits the column ships a
  record into production behavior, and the one path that forgets is the one nobody
  tests; a comment stating the intended default enforces nothing.
  (slate#1266, a column defaulting to bookable=true put agents in the live routing
  pool on first login while the migration's own comment said an admin had to
  approve them)

- **L75. When identifying WHO or WHAT an outward action targets fails, refuse the action; never
  fall back to a nearby candidate.** A visible placeholder at least tells the person something is
  missing, while a silent substitution looks exactly like success and performs the action on
  somebody else.
  (overture#2147, a reply whose sender matched no known contact fell back to the row's own contact,
  so answering the person who wrote would have emailed a colleague instead)

- **L124. A platform's DEFAULT grant may already give away what you are about to grant**, so the
  GRANT you add as protection changes nothing while making the migration READ as protected, and
  an accompanying comment describing the exclusion is worse than silence. Query the live
  privilege after applying rather than reviewing the migration text, because the only evidence
  is a REVOKE that is absent, and nobody reviews for a missing line.
  (bidspoke#762: Postgres grants EXECUTE to PUBLIC on every new function, so six security-definer
  functions were callable by anon over the REST API, two of which write and bypass RLS)

- **L123. Declining to PROVISION someone is not declining to AUTHENTICATE them**, so a signup
  gate that only skips creating app records still hands that person a valid session carrying a
  privileged role, and every policy written against that role must then defend against someone
  you believe you already turned away. Refuse at the credential itself and prune the accounts
  earlier refusals left behind, because the code performing the refusal reads as complete.
  (bidspoke#759)

- **L137. A grant checked only where it is GRANTED (a login, a signup, an invite) is never
  re-checked for anyone already holding a session, so removing someone from an access list takes
  nothing away from the people most likely to be removed, and the gap stays invisible until the
  first real removal.** Consult the list on the path that SERVES the protected data, and end
  existing sessions when a grant is withdrawn, because an expiry measured in weeks is the very
  window the removal was meant to close. Distinct from L123, where the refusal never reached the
  credential: here the grant was legitimate and the REVOCATION is what fails to land.
  (project-enrollment-tracker#1022: the access list was consulted at login and on API routes only,
  while the gate serving the dashboard and every data file checked just that the session cookie was
  valid, and sessions rotated silently for 30 days)

- **L155. An issue or plan written with REAL measured evidence becomes the source whoever implements
  it copies into fixtures, so redact people's identities where the evidence is RECORDED rather than
  trusting the implementer to anonymise it later.** The evidence-rich issue is the right habit and is
  exactly what carries a real person's name, address and their own words into test data, and a
  reviewer cannot tell an invented contact from a real one by reading a fixture, so the only defence
  is somebody recognising a name. Distinct from L19, which says PII is never committed: this names
  the ROUTE it travels, out of the evidence you were right to gather and into a file you were right
  to write.
  (overture#2833, 2026-08-16: #2815 documented a real defect with a real Gmail thread, quoting the
  presenter by name and his own words about a fee. The agent sent to fix it copied all of that into a
  test and opened a PR against a PUBLIC repo. Closing the PR and deleting the branch then exposed the
  wider habit: roughly 90 occurrences of twelve addresses across 18 files, eight or nine of them real
  people, one in an app source comment and one in a checked-in fixture)

## UX completeness

- **L20. Accessibility is part of building each control.** Labels on icon-only controls,
  real buttons instead of tap gestures, type scaling, tap targets, AA contrast in both
  themes, reduced motion, focus management. (49 issues, 7 repos)
- **L149. A colour token that clears the level for an icon or a border does not thereby clear
  it for TEXT, because an interface component needs 3:1 and body text needs 4.5:1, so an accent
  reused for a label ships under the line while every check that measures whether it DREW
  reports it as fine.** Measure each token in every role it is used in, and let the strictest
  role decide the value.
  (PostRoll#580: roseGold measured 4.31:1 on the page and 3.68:1 on the deeper panel, under the
  floor in roughly 50 places where it is type, and over the 3:1 it needs in the 240-odd places
  where it is a rule or an icon)
- **L21. Read every new user-facing sentence cold, rendered, in the state that produces
  it.** Copy is a contract: limits, prices, labels, and promises must match what the
  code does, and a control labeled as navigation must never trigger a paid operation.
  (42 issues, 5 repos)
- **L118. One word must name one unit across the whole product, and an added qualifier is not enough
  to separate two, because each sentence is correct read alone and the contradiction exists only in
  the reading.** Reading new copy cold already covers the sentence; what this adds is the PAIR, so
  check a new count against every other place the product counts something with that word.
  (overture#2616: a button promising a re-check "costs one lookup" was followed three minutes later
  by "18 web lookups for 1 show, more than expected", one counting shows and the other counting web
  calls, and Dan read it as a control that spent eighteen times what it said)
- **L22. Walk the whole flow as the user before calling it done.** Cancel, retry,
  resume, and every exit path of a guarded action get deliberate behavior; enumerate
  degenerate inputs (zero items, missing files, overlong media) at design time.
  (32 issues, 4 repos)
- **L44. A request to stop, cancel, or undo gets its own acknowledged state the instant it
  is accepted, distinct from both running and stopped.** A control that keeps offering
  itself after being pressed reads as broken, so the person presses it again, and the work
  meanwhile may already be honoured, already finished, or still costing money.
  (overture#1684)
- **L45. When filtered views are the only way to reach records, the filters must cover the
  whole state space between them.** Every record must match at least one view, and no state
  transition may move a record into a combination that matches none, or it stays in the data
  while vanishing from the product. (overture#1691)
- **L49. A control must look like a control at rest, not only on hover and not only in a
  tooltip.** An interactive element styled like static text ships as an invisible feature, so the
  person it was built for asks for it while looking straight at it, and no test can tell the two
  apart. (overture#1742)
- **L54. A guard may refuse only what the system genuinely cannot do; when the work is
  possible, confirm it instead of blocking it.** A ceiling meant to catch an accident cannot tell
  an accident from a deliberate choice, so it only ever stops the person who meant it, and it
  forces them to hand-do the batching or chunking the machinery already performs.
  (overture#1765)
- **L64. What a person reviews and approves must be exactly what ships, including WHO it goes to, so
  anything the system composes onto it (a greeting, a header, a footer) or chooses on its behalf (which
  of several addresses, accounts or targets) belongs in the reviewed artifact.** A step that adds
  content or picks a target after approval is invisible to the only person who could have caught it,
  and whether it goes wrong then depends on details they cannot see.
  (overture#2010, overture#2015)
- **L69. A preview or approval surface must render the content on both light and dark backgrounds.**
  Styling that matches one background is invisible there and glaring on the other, so a single
  background preview can approve a defect it is structurally unable to show: a signature carrying
  white 1px borders previewed on a white card shipped a hard white outline box to every dark-mode
  recipient for two weeks.
  (overture#2086)
- **L76. A region that clips its content must show, at rest and with no interaction, that content
  continues past the edge, and must stop showing it once the end is reached.** A platform that hides
  scrollbars until a gesture starts makes an overflowing panel look like a complete one, so the
  person reads what fits and never learns the rest existed.
  (overture#2159)
- **L79. A notice placed in a container the platform may collapse, overflow or truncate (a toolbar
  slot, a header that condenses, a single row) is not shipped until it has been seen at the window
  size the person actually uses.** Every mechanism protecting that message, a priority rule that stops
  it being overwritten, a dedupe, a retention window, is worth nothing while the surface holding it is
  off screen, and the code stays entirely correct the whole time.
  (overture#2204)
- **L80. When a message names a specific record, source or item so the person can act on it, the
  surface showing it must carry that action.** Naming the target and then classifying the message as
  informational tells the person exactly what is wrong and gives them nowhere to go, and the two halves
  usually live in different files so no reviewer sees the contradiction.
  (overture#2207)
- **L97. An undo whose input is the very thing the action removed from the screen is not an undo,
  because the action destroys the only key to its own reversal.** Either keep what was removed
  listed somewhere with the way back attached to it, or make the reversal reachable without the
  person having to remember the value, since from inside the code the undo genuinely exists and
  the gap is invisible.
  (overture#2392, overture#2408: striking a contact address was reversible by typing that address
  back in, and the strike removed that address from every screen that showed it)
- **L99. A client side input mask or cap must never be stricter than the validator that accepts
  the value, because the form then refuses input the server would take and the person is blocked
  by a rule nothing states.** Decide the real limit once and let the stricter side be the one that
  explains itself, since the two rules usually live in different files and the contradiction is
  invisible until somebody arrives with the value that falls between them.
  (slate#1356: a booker phone field capped at ten digits beside a validator deliberately accepting
  ten to fifteen, so a number the server would have booked could not be typed in)
- **L150. A writer that accepts a value on its own terms must accept only what its READER can
  actually consume, so validate at the write against the reader's own predicate rather than a
  looser one.** Otherwise the value is stored, looks correct, and is silently unusable at the
  point it matters, and because the accepting rule and the consuming rule live in different
  files neither looks wrong when read alone. The mirror of L99, which catches the form being
  STRICTER than the validator behind it: this catches the writer being LOOSER than the reader.
  (overture#2794: `EventLocationFill` rule 1 stores a page's own location verbatim, and
  `460 Main Street, Chatham NJ` is accepted and then answers `couldNotPlace` in `EventPlace`,
  which is what actually decides where a show is, while `cityFromVenue` in the same file would
  have read `Chatham, NJ` cleanly)
- **L111. A message that tells someone HOW to recover must name an action that actually changes
  the state they are stuck in, so trace the suggested step against the stored state before
  shipping it.** Advice like reload, retry or start again is written from the developer's mental
  model and reads as helpful while leaving the person in exactly the same place, and the code is
  entirely correct the whole time.
  (new-agent-onboarding#565: a refused Salesforce profile told the operator to reload the page,
  but the stale profile id lives on the saved onboarding, so the reload restored the same value
  and the only control that could fix it went unmentioned)

- **L112. An alert's urgency is set by what the reader must DO and how soon, never by
  whether something is broken.** A condition correctly judged "not a fault" gets filed
  as informational and put on a long cooldown, which makes the product quietest at
  exactly the moment customers are being turned away for the most ordinary reason.
  (slate#1412: a bucket with no bookable times because its agents were genuinely booked
  whispered on the info channel, while the booker told every lead "all times are taken")

- **L113. A lookup table keyed by a vocabulary (a colour by status, an icon by type, a label
  by code) must have its completeness enforced by the type system or a test, because a missing
  key silently takes the default branch, and a default is indistinguishable from a deliberate
  choice.** The entry most likely to be missing is the one written by a second set of writers
  that arrived after the table was built.
  (new-agent-onboarding#554: the audit ledger's colour table was built for provisioning
  outcomes, the settings routes later became a second writer of the same ledger, and every
  audited config change rendered in the muted fallback for months, two lines under a comment
  warning that the fallback renders the most consequential row as the quietest on the screen)

- **L126. An action offered only on a transient surface (a run summary, a status message, a toast)
  cannot serve a condition that PERSISTS in the data, because the notice clears while the state
  stays, so every encounter after the first finds the fault still named and the remedy gone.** Put
  the action on the durable surface showing the condition, and let the notice be a shortcut to it.
  The sibling of L80, which catches a message naming a target with no action at all: this one catches
  the action existing and outliving nothing.
  (overture#2621: a card reading "A check missed this show" carries that badge for 90 days, while the
  control that re-runs exactly those shows hangs off the status message set when a run ends, and the
  badge's own hover text then sends Dan to re-tick the whole date instead)

## External systems

- **L23. Treat every external response as hostile and every event stream as unordered,
  late, and duplicated.** Check status and shape before indexing, map the other system's
  vocabulary at the boundary, and give webhook handlers event-timestamp ordering guards.
  (28 issues, 5 repos)
- **L24. State the expected data volume before writing any query or loop.** Count
  server-side, paginate every list (PostgREST caps at 1,000 rows silently), batch N+1s,
  run independent awaits concurrently, keep heavy work out of render paths, ship the
  index with the query. (58 issues, 4 repos)
- **L81. A batch must be sized in the UNIT the limit is actually expressed in, measured
  from the real inputs, never in a proxy unit calibrated on one sample.** A row count
  standing in for URL bytes, or a message count standing in for tokens, holds only while
  every input is the same size, so the number gets copied to a call site with larger
  inputs and the request is refused outright rather than merely running slow.
  (slate#1259, slate#1268: a 500 id batch carried from 27 character keys onto 36
  character uuids and then onto 43 to 181 character calendar event ids)
- **L87. A change that multiplies how many items an existing request carries inherits
  that request's aggregate limit, and proving the change correct says nothing about
  whether it still fits.** Measure the whole payload against the real ceiling on the
  largest realistic input, because the item that got better is not the one that breaks.
  (PostRoll#216: splitting each program page into two images to fix a misread name was
  verified on one page and doubled an uncapped request, so an eight page program went
  from working to refused outright)
- **L25. Pin everything.** Toolchains, dependencies, external API versions, AI models;
  "latest" is an unannounced breaking change. (11 issues, 4 repos)
- **L26. Twin implementations in two languages consume one shared committed fixture**,
  with a declared source of truth that is itself directly tested. (11 issues, 2 repos)
- **L127. An identifier you SUPPLY to an external system is a request, never a fact, so read back
  the one it actually assigned before storing it as the key to any later operation.** Verifying in
  the vendor's OWN client cannot catch the substitution, because that client can reach the record by
  a private path that never touches the identifier, so it looks correct in the one place anybody
  checks and is broken everywhere else.
  (overture#2647: Gmail discarded Overture's Message-ID and assigned its own, so every follow-up
  referenced a message that existed nowhere, while Gmail's web view still grouped the thread on its
  internal threadId and Spark showed two unrelated conversations)

- **L157. An atomic operation guarantees only its own span, so acting on a judgement formed
  BEFORE it (remove this lock because it was stale, revoke this token because it had expired,
  evict this entry because it was cold) reintroduces the race the atomicity appears to close,
  and reads as rigorous precisely because the primitive really is atomic.** Put the judgement
  and the action in one critical section, and prove it by holding two callers at the decision
  point rather than hoping the interleaving reproduces. Distinct from L70, where both sides of
  a check come from one lookup: here the two sides are correct and merely separated in time.
  (downbeat#218: claim-stale-lock.sh renamed away whatever sat at the lock path, citing L70 in
  its own header, so a waiter acting on a stale owner it had read seconds earlier removed a
  LIVE lock and both suites ran at once)

- **L159. A test asserting that something did NOT happen is satisfied by a fixture in which it
  COULD not happen, so prove the positive case fires in the SAME fixture before trusting the
  negative.** A suite that switches a whole mechanism off for convenience turns every such
  assertion green permanently, and the test reads as careful precisely because it names the thing
  it checks for. Distinct from L143, where a declared double matched nothing: here nothing was
  stubbed and the capability is simply off.
  (claude-config#22: a check that no desktop alert was raised passed against a suite exporting
  SYNC_NO_NOTIFY=1 for everything. Caught only because the sibling assertion that an alert SHOULD
  fire failed in the same run, which is the control this lesson asks for)

## Building with AI

- **L27. A rule that lives only in a prompt is a hope.** Every hard constraint on AI
  output also gets a deterministic code check at the boundary, and every field a prompt
  references must provably exist in the payload sent, or the model fabricates it.
  (14 issues, 2 repos)
- **L28. Treat a detached AI run as an untrusted subprocess.** Pin its model per task,
  forbid it from asking questions, enforce its tool limits rather than asserting them,
  verify it did the expensive step, and require an honest failure record when it dies.
  (12 issues, 1 repo)
- **L128. A field whose only writer is an AI prompt, and whose ABSENCE is itself a legitimate value
  in the domain, cannot tell a model that IGNORED the instruction from one that judged the field
  inapplicable, so the feature stays dormant forever while every reader reports its honest default.**
  Assert at the boundary that a run produced the field at all, at least once per run, because the
  first run after shipping is the cheapest moment to find out the prompt is being ignored. Neither
  L27 (a hard constraint on output needs a deterministic check) nor L90 (a value nothing writes
  reports a confident zero) covers it: here the writer exists and may simply decline, and its
  declining is indistinguishable from an answer.
  (overture#2641, from #2622's contact tier and #2612's social route, both instructions added to the
  prep runbook with no way to notice a run that skips them)

- **L161. When an AI writes a fact the system ALREADY HOLDS the true value for (a date, a venue, a
  price, a name), check what it wrote AGAINST that value rather than merely checking that something
  is there, because a presence check passes a contradicted fact, and a wrong fact reaching a stranger
  is worse than an omitted one, which at least reads as missing.** Neither L27 (a prompt rule needs a
  deterministic check) nor L108 (a value validated for shape but not completeness) covers it: both are
  about a value being absent or partial, where this one is present, well formed, and contradicts a
  source of truth sitting in the same record.
  (overture#2864: a pitch that had already been SENT told a theatre Dan wanted to photograph their
  show "on July 18" when the stored performanceDate for it was July 25, and the check being specified
  asked only whether a date appeared anywhere in the subject or body, which that draft passes. Found
  by measuring the live store rather than by reading the code: 6 of 19 drafts named no date at all and
  2 named a wrong one)

- **L167. An AI writer that can READ the code consuming its output derives its contract from that
  code's permissiveness, so an optional field is not neutral, it is permission: any combination the
  schema tolerates will eventually be emitted and defended as valid.** Express the real constraint in
  the type or in a boundary check that refuses the combination, because a prompt stating only the
  positive form leaves the schema as the more authoritative document. Distinct from L27, which asks
  that a prompt rule get a deterministic check: here the loose schema is not merely failing to catch
  the violation, it is what taught the model the violation was allowed.
  (overture#2893: told to record a social route as `method: form_or_dm` with the profile URL in
  `formUrl`, the check read `PrepResults.swift` mid-run and wrote "Good, `formUrl` is optional. That
  confirms a `form_or_dm` contact can carry no `formUrl`", then emitted two contacts each naming a
  route and carrying none. `formUrl` is optional because two OTHER methods have no form. The app
  correctly discarded both, so the card told Dan the show had no way in while he found one himself
  in seconds)

## Codebase hygiene

- **L29. Dead code is worse than deleted code.** Wire it or delete it the moment nothing
  calls it; git remembers. (10 issues, 2 repos)
- **L46. Stored data needs a reader, not just a writer.** A field that is only ever
  written looks alive to any is-this-used check, because the write path really does run,
  so the purpose the field was added for silently never happens: name a field's consumer
  in the same change that adds it, and when the last consumer goes away either wire a new
  one or delete the field. (overture#1715)
- **L30. Fix the class, not the instance.** Sweep for a found defect's siblings in the
  same change, and enumerate every surface a cross-cutting behavior must cover before
  shipping it. (22 issues, 4 repos)
- **L31. Everything the product depends on lives in git.** Schema, security policies,
  RPC bodies, migrations, pipelines; a dashboard-only artifact has no rollback path.
  (9 issues, 2 repos)
- **L32. Docs state testable claims.** A doc stating a fact the code no longer matches
  is a bug fixed in the same PR; measured numbers are generated or omitted, never
  hand-written. (56 issues, 8 repos)
- **L41. A list that must mirror another source of truth is derived from it, never
  maintained by hand beside it.** The two drift the moment someone updates one and not
  the other, and the drift stays silent until something turns up missing.
  (claude-config#9)
- **L96. A guard driven by a hand-written registry checks only what the registry lists, so
  anything missing from it is exempt from the very check meant to catch it, and the guard
  reports green while blind.** Derive the registry from the code, or add a second check in the
  code-to-registry direction, because the entries you remembered are exactly the ones already
  safe.
  (PostRoll#273: the payload contract enforced that every declared payload was fully declared,
  and six payloads crossing the same boundary were never declared at all, so the sweep that
  claimed to cover all of them passed)
- **L129. A category deliberately EXEMPTED from a review or check, for a CORRECT reason, has no
  reviewer at all unless one is named in the same change, and the gap is invisible precisely
  because the exemption was right.** The excluded content still needs reviewing, just by something
  else, so name what WILL review it rather than only what will not. The mirror of L96, where the
  registry forgot an entry: here nothing was forgotten and the exclusion is correct on its own
  terms, which is why it survives every audit of whether the check is working.
  (overture#2643, overture#2650: outbound email is rightly kept out of the app's copy inventory,
  since that inventory is the app's own voice to Dan and the cold read of it is a required pre-PR
  step, which left the sentences going to strangers under his name as the only copy in the product
  with no reader. A closing note told people who had never replied "it was good to be in touch",
  and it survived a rewrite of the first sentence of that same paragraph three days earlier)
- **L57. A correction recorded only in memory or a transcript will recur, because the
  artifact that actually governs the behavior never changed.** Write every accepted
  correction into the prompt, config, or rule file that decides the outcome, in the same
  session it is given, and add the check that would catch its return.
  (overture#1884, the same recital defect twice, 2026-07-18 and 2026-07-31)
- **L61. A decision recorded on an issue is only true as of its date, so re-check it against
  what has shipped since before building to it.** Work that landed in between can make the
  recorded choice actively harmful rather than merely stale, and nothing links the two: the
  July decision here was to write the act into a field, and by August a shipped feature was
  using that field's EMPTINESS to select the 169 rows it served, so following the decision
  would have silently dropped every one of them back out of it.
  (overture#1823 against overture#1861, caught 2026-08-01)
- **L62. A guard on a function's first line cannot protect against the cost of building its
  arguments, because every language evaluates those before the call runs.** Put the cheap
  check at the call site, or take the expensive input as something the function can decline
  to run, because the call site reads as free while paying in full and no test measures what
  an answer cost.
  (overture#1916, overture#1960)
- **L132. A generated catalogue that a PERSON reviews (a copy inventory, an API surface list, a
  route map) must be derived from what is REACHABLE, not from what merely appears in the source,
  because an entry for code nothing calls is indistinguishable from a live one and every reader
  spends real attention reasoning about a surface that cannot exist.** Distinct from L29, which
  is about the dead code itself, and from L96, where the hand-written registry lists too FEW: here
  the derivation is automatic and correct on its own terms, and lists too MANY. It also inflates
  whatever headline count the catalogue opens with, which is the number quoted whenever its
  coverage is discussed.
  (overture#2707: a sentence about a masthead line removed by #1131 sat in the copy inventory for
  more than a thousand issues, and that inventory's cold read is a required pre-PR step)
- **L170. A criterion placed last in a strictly ordered comparison chain is consulted only on an
  exact tie of everything above it, so any earlier criterion carrying many distinct values (a
  count, a rating, a timestamp) makes it permanently inert while the code reads as a criterion
  that ranks.** Measure how often each level of the chain actually decides an ordering against
  real data, because an inert criterion and a working one are indistinguishable from the source.
  Distinct from L46, where a field has no reader at all: here the reader exists, runs on every
  request, and can never reach the value.
  (nursedex#724: the nurse directory ranked on featured tier, photo, communication preference,
  review count, average rating and profile completeness in that order, so a single review broke
  the tie before completeness was ever compared, and a fully filled-out profile ranked below a
  bare one. The completeness score itself was correct and recomputed on every profile save)

## Cross-system reliability

- **L33. Make the pair of a database write and an external side effect crash-safe.**
  Record intent durably before firing, confirm after, consume caps and dedup budgets
  only when the effect verifiably happened, and never put a must-not-lose write on a
  best-effort mechanism. (27 issues, 5 repos)
- **L34. Verify domain and vendor data semantics against real samples before building on
  them.** A field's meaning is measured from captured live data or confirmed with the
  user, never assumed. (29 issues, 5 repos)
- **L35. Classify errors once, explicitly.** One shared classifier decides transient
  versus permanent and maps every failure mode to a typed status; never branch on
  message substrings, never default an unknown error to retryable. (23 issues, 2 repos)
- **L36. An alert that cries wolf gets ignored.** Design every alert against its
  false-positive sources at creation, give it a window longer than what it measures,
  aggregate during broad outages, dedupe repeats, and never embed canned remediation
  text that can steer a diagnosis wrong. (20 issues, 3 repos)
- **L37. History is stamped at write time.** Records about the past carry point-in-time
  attributes captured then; rendering or finalizing a past period reads that period's
  stored state, never the live present. (10 issues, 2 repos)
- **L38. Deletes, renames, and state exits enumerate every derived resource.** The
  recurring defect is touching N minus 1 of N linked things; list them all and cover
  them in the same change. (21 issues, 4 repos)
- **L39. One timezone, one date helper.** Compute every business date in one explicitly
  chosen zone through one shared helper, never the host clock's default; test month,
  DST, and midnight boundaries with a pinned clock. (15 issues, 5 repos)
- **L51. A time based threshold is only as timely as the schedule that evaluates it.**
  When you choose a cutoff, deadline, or staleness window, check the cadence of the job
  or build that computes it and confirm a run actually lands soon after the boundary, or
  the condition stays invisible until the next run.
  (project-enrollment-tracker#903)
- **L66. When several records are collapsed onto one shared external identifier (one email
  thread, one payment, one batch call), decide for EACH downstream fact whether it belongs to
  the group or to one member, and refuse to write a member level fact the external system does
  not name.** A group level fact like a reply can safely mark every member, but a member level
  fact like a bounce silently marks people it is not true of, and the data that would tell them
  apart is usually absent from the response you already fetch.
  (overture#2032)
- **L73. Independent steps sharing one handler each need their own failure boundary.**
  An unguarded throw in step three silently cancels steps four through thirteen, and the
  ones lost are unrelated to the one that broke, so a single try block around a sequence
  makes every check's reliability depend on every other check's worst case.
  (slate#1281, a monitor lane reached thirteen steps with four of them guarded)
- **L74. A deadline, age or due date computed from the current clock at read time can never
  age, because every evaluation moves it forward with the clock.** Anchor it to the stored
  instant the work actually arrived (the reply, the guess, the event) so a missed one reads as
  overdue instead of silently re-filing itself under today.
  (overture#2111, overture#2116)
- **L114. A tool that creates a throwaway workspace must also remove what that workspace caused to
  be created OUTSIDE it.** Build caches are keyed by workspace path, so every new path mints a fresh
  full copy that nothing reclaims when the path goes away, the growth is proportional to how often
  the workflow runs rather than to how much work is done, and it is invisible until the disk stops
  the machine, at which point the diagnosis itself can no longer run.
  (overture#2585: 105 Xcode DerivedData folders at roughly 1.6 GB each, 101 of them belonging to
  agent worktrees and throwaway verify worktrees that had already been deleted, filled a 926 GiB
  volume to 132 MiB free and left no command able to write even its own output)
