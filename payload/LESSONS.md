# Build-time lessons

Distilled from the 2026-07-27 audit of 3,506 GitHub issues across 9 repos (1,721 carried
a lesson). Apply these by default in every project, alongside the rules in CLAUDE.md.
Full provenance per rule: ~/.claude/audits/2026-07-27-issue-audit/. Numbering is stable
for reference; L6 was reviewed and deliberately not adopted.

## Proof over green

- **L224. A check that compares elapsed time against a FIXED number is a check on what else the
  machine is running, so compare it against a duration measured in the same run.** External load
  makes it fail on commits that changed nothing, and raising the threshold to stop that removes the
  very thing it was set to catch.
  (claude-config#149, 2026-08-21: across eight full runs of one tree, four checks failed only while
  Lightroom, Xcode and Backblaze held the Mac at load 38 to 103, and every one of them passed on the
  same commit at load 15. The suite's own deadline guard reported a run of 854 seconds against a
  normal 243, and the pre-push gate blocks on these, so a busy Mac blocks a correct push.)

- **L215. A reader that answers with an EMPTY collection when its own accessor throws is
  indistinguishable from a correct reader of an empty collection, and because the swallowing
  construct usually sits INSIDE the loop, one element of an unexpected shape empties the whole
  result.** Count what threw separately from what was genuinely absent, and make the empty answer
  a loud refusal wherever emptiness would be read as a conclusion. This is L98 applied to
  iteration rather than to a whole check: there the step found no subjects, here it found them
  and dropped every one.
  (downbeat#359, corrected by downbeat#375 on 2026-08-21: an AppleScript loop over the app's
  Settings window coerced a `missing value` inside a `try`, the error was swallowed per element,
  and the loop returned zero elements. That zero was recorded in the project guide as the fact
  that no working automation route to this app existed on this Mac, and it was believed twice.
  The same window returns 179 elements, with every declared identifier readable. Cost: two issues
  were routed to Dan as go and look jobs on those grounds, one of them running three sessions to
  collect a single sample per booking. The script that replaced the reader makes an empty listing
  a loud failure whose message names the conclusion it refuses)

- **L216. When two independent readings of the same input disagree, a disagreement rate that is
  CONCENTRATED and TOTAL, near 100% on a few named fields and near 0% on the rest, indicts the
  pipeline rather than the input, because a genuine data problem is spread out and partial.** The
  signature says a stage is systematically wrong; it does NOT say WHICH stage, so locate the fault
  by reading the code rather than by naming the likeliest one from the rate alone. Record HOW the
  two readings differed alongside the fact that they did, because that record is usually what
  separates two spellings of one answer from two different answers.
  (downbeat#373: ten questionnaire imports each compared 23 fields, and the same two disagreed
  every time while the other 21 never disagreed once. The cause written from the log alone was
  that the check compared rendered strings, so `3:00 PM` and `15:00` would read as different. The
  code disproved it: the cross check already matched times on hour and minute. What separated the
  two was the recorded SHAPE, which reported a character distance rather than a minute distance,
  so one reader was not producing a time at all. The real fault was upstream, in the label parser:
  two lines of the form claimed one field by keyword set and the LAST won, so a 24 character
  phrase replaced the 7 character answer the form's own field carried, and first match wins fixed
  it across all five samples. The conservative half was doing the harm, since a disagreed field is
  left empty, so every import had been discarding a shoot end time)

- **L203. A cause inferred from two things co-occurring in a log or a trace is not
  established until you find a case where the suspected cause is present and the effect
  is ABSENT, because a busy system produces near simultaneous events constantly and a
  coincidence reads exactly like a mechanism.**
  (downbeat#306: notification permission was refused in the same millisecond as two
  LaunchServices `_LSBundleCreateNode ... returned -43` failures, and the issue was opened,
  titled and worked for three sessions on the theory that the stale registrations behind
  those lines caused the refusal. Clearing them changed nothing. The control that settled
  it took one query: the same `-43` burst fires one millisecond before a DIFFERENT app's
  successful grant, so it never blocked anything. A second app with the identical signing
  shape being granted then killed the replacement theory too)

- **L205. A test that touches a shared mutable object other tests also touch can pass
  purely because its own fixture is SLOW enough to outlive a neighbour's reset, so making
  that fixture faster is what exposes it: remove the dependency on the shared object
  rather than serializing around it, and re-check any such test after speeding its
  fixture.**
  (downbeat#355: a new test asserted that a commit announces its calendar check while the
  check runs. It passed alone and in the full suite, because its stub polled for the full
  15 second timeout, long enough to survive four sibling suites that each reset the same
  shared check in their own setup. Shortening the fixture to 0.05s turned it red at once.
  Serializing the suite would have restored the green while leaving the hazard; injecting
  the bracketing so the test never touches the singleton removed it)


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

- **L177. When a failure reproduces only in an environment you cannot run (a CI runner, another
  machine, a device), make that environment PRINT the fact in question before changing any code,
  because a theory built from the symptom is cheap to believe and expensive to ship.** Each wrong
  fix also costs a full round trip through the only place that can judge it, and it leaves behind a
  change that reads as deliberate. Distinct from L82 and L34, which say measure a platform guarantee
  or a data semantic before BUILDING on it: this is about DIAGNOSING, where the temptation is
  stronger because a symptom is already in hand and looks like evidence.
  (claude-config#52: the suite's first Linux run failed 9 checks. Two plausible causes were acted
  on before anything was measured, that `claude-sync status` was exiting non-zero and tripping the
  self-update gate, then that git 2.54 had changed how it reports a conflicted autostash restore.
  Both were wrong, and the second shipped a reordering of a failure classifier defended by a comment
  stating the false reading as fact. A twenty line probe printing what git actually does settled it
  in one run: exit 0, stash kept, no rebase directory, identical to the older git)

- **L178. A check written as two conditions over one body of text is satisfied by two unrelated
  places in it, so it proves neither half and passes hardest when nothing works at all.** Assert the
  halves as ONE line carrying both, because each condition read alone looks specific and the compound
  reads as stricter than either, which is why nobody re-examines it. Distinct from L135, where a
  single match over a whole file is answered by a legitimate use elsewhere, and from L156, where the
  match is real and it is the error text that satisfied it: here both matches are real, both are
  irrelevant, and the conjunction is what creates the illusion.
  (claude-config#55: two assertions that a renumber warns about citations in `hooks/` and `skills/`
  each grepped the captured pull output for the file path AND for the warning wording. Both passed
  against completely unmodified code, because the pull's own change report names every file it
  applied while a pre-existing warning about a different file supplied the wording. Caught only
  because the fix was known to be still unwritten and the green looked wrong. The same mistake was
  made an hour later at a larger scale, reading one sentence in a blob of CI output as proof of which
  branch of a classifier had fired, which produced the wrong diagnosis recorded in L177)

- **L182. A ratchet or violation count driven to ZERO stops being read as a measurement and starts
  being read as proof the thing cannot occur, so nobody re-examines it.** Prove the detector
  recognises every form of what it bans before letting the count reach zero, because a zero produced
  by a narrow detector certifies only the spellings it happens to match. Distinct from L96, where
  the guard is blind because its registry omits an entry: here the blindness is the same, and what
  is new is that a zero forecloses the re-reading a non-zero count invites.
  (claude-config#67, claude-config#68: the suite's scan for assertions that grep one captured blob
  twice was lowered from a ceiling of 6 to 0 once the six were rewritten. The scan matches only one
  spelling of feeding a captured variable to grep, so a new weak check written another way is
  invisible and the count still reads 0. Noticed only while reviewing what had just been shipped)

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

- **L246. A feasibility check must exercise the HARDEST thing the plan depends on, not the easiest
  thing that proves the tool runs at all, because a green on the easy case reads as permission to
  build and the capability nobody measured is the one the plan actually rests on.**
  (postroll#867, 2026-08-23. #509 had closed a UI test target on the recorded grounds that a runner
  cannot drive XCUIApplication. That premise was two months old and worth re-checking, so it was
  measured: the runner has an Aqua session, the app launched, and two tests passed in nine seconds.
  All true, and all of it the easy half. The plan needed the target to close a window, read a form
  and commit a keystroke, and none of those was measured before the target, its scheme and its
  workflow were built and merged. Every one turned out to be unreachable, and five of the seven
  tests written against it were deleted within the day. The tell was there at the time: the
  measurement asked whether the tool RUNS, and the plan needed to know what the tool can REACH)
- **L248. A finding that rules a capability OUT must be measured under the same control as one
  that rules it in, because nothing downstream ever re-tests a closed door: the work that would
  have exercised it is exactly the work the finding stopped anyone writing.** The mirror of L246.
  An over optimistic feasibility check is corrected by the build failing; an over pessimistic one
  corrects nothing, because the code that would have contradicted it is never written.
  (postroll#877, 2026-08-23. #860 recorded that XCUITest goes blind on a PostRoll window, reporting
  the application Disabled with an empty element subtree, and concluded neither a pass nor a
  failure from that harness means anything. Five tests were deleted on it, three questions moved to
  a manual checklist, and a note on #855 repeated it as settled fact. A controlled run months later,
  one build with the suspect switched on and off and the state sampled once a second, measured the
  opposite: the app reports runningForeground and the tree is about 17,800 characters throughout.
  Only the close ACTION fails. Reading, which is what had been written off, works perfectly)
- **L2. Tests must be structurally unable to touch live data, production services, or
  paid APIs.** Inject seams for stores, directories, clocks, and external calls, plus a
  refusal inside the service itself. (10 issues, 6 repos)
- **L196. A component that CONSTRUCTS its own dependency rather than receiving one is beyond
  every refusal that dependency could offer**, because the construction site is compiled and
  shipped inside the code under test, so a build condition or a runtime refusal in the
  dependency cannot reach it and the seam has to be the caller receiving what it uses.
  (PostRoll#722: AnalyticsStore and HashtagStore were kept off Dan's imported Instagram
  history by compiling the initializer that names the live file out of the test bundle, so a
  test omitting the path stopped building. PostRoll#727: the same fix is impossible for
  PostingPresetStore, because the screen that reads Dan's real preferences builds its own with
  @State private var presetStore = PostingPresetStore(), and that screen is itself inside the
  test bundle, so the refusal would break the build for a legitimate caller)

- **L3. Built is not wired, and wired is not proven.** Prove every guard, integration,
  and gate actually executes in the shipping runtime, and wire the CI gate the day the
  first test lands. (45 issues, 8 repos)
- **L4. A merged fix is not a deployed fix.** Verify the change is live where it ships:
  migration applied in production, the live site serving the new commit, behavior
  confirmed in a production build. CI must exercise the artifact production actually
  runs. (20 issues, 5 repos)
- **L212. A count of source sites that CREATE a resource against source sites that RELEASE it
  cannot measure whether anything leaks, because one shared helper runs once per caller and a
  single missing teardown inside it multiplies invisibly, so measure what actually survives at
  runtime.** The two numbers look like a balance and are not comparable at all: one is a count of
  lines, the other a count of executions. Downbeat's suite read as 96 createDirectory calls
  against 95 defer cleanups, and the file holding the worst offender even contained a removeItem,
  so it sorted into the cleans-up bucket; that one helper had no teardown and had left 7,616
  directories. The measurement that settled it was running the suite and diffing the temp folder,
  which said 52 leaked per run and then 0 after the fix. Distinct from L63, which is about a guard
  asserting a proxy: this is the diagnosis reached before any guard exists, and the proxy is
  convincing precisely because the two counts are nearly equal.
  (downbeat 866e82c, overture#3065)
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
- **L188. A limit your code SETS (a minimum size, a timeout, a cap, a default) is only in force
  if nothing downstream recomputes it, because a framework or platform deriving the same value
  from other inputs overwrites yours silently and the line goes on reading as protection while
  protecting nothing, so measure the value in the RUNNING system rather than trusting the
  assignment.** Nothing fails when the assignment is beaten: the code still contains the safe
  number, every reader of the source sees it, and only the live object knows a different one,
  so the gap is invisible to review and to any test that reads the constant back.
  (PostRoll#687 and #690: the window explicitly set a minimum size of 760 by 500, SwiftUI derived
  the window's limits from the content instead and replaced it with 353 by 2834 against a usable
  screen height of 984, leaving a window macOS would not allow to fit on the screen and no drag
  able to recover it)
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

- **L179. A status query about work in flight must be scoped to the exact revision it asks about,
  because a superseded run reports under the same check names and answers for the new one in both
  directions: a stale failure blocks a commit nothing has judged, and a stale pass merges one.** Ask
  for the runs at the head commit and refuse to answer until every one of them has finished. Distinct
  from L98, where the watcher finds nothing and calls it success: here it finds a real, complete,
  confidently wrong answer about a different version of the work.
  (2026-08-17, PostRoll#669: `tools/wait_for_checks.py` asks `gh pr checks`, which is keyed by
  workflow and check name with no notion of commit, so three consecutive pushes each reported
  `red: failed: Tests / python` within seconds, every one of them the previous commit's run, while
  the new run had not started. The README directs everyone to that tool rather than to `gh` by hand)

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

- **L214. A fallback written for a source being ABSENT must not be reached when that source is
  PRESENT but EMPTY, because those are different situations: taking the absent branch on empty
  silently redirects the work to a different target than the one it was pointed at, and everything
  downstream then reports about something nobody asked about.** Distinct from L173, where the
  fallback never fires at all, and from L93, where it fires and ships a known worse defect: here it
  fires for the wrong reason and quietly changes the subject, so the output is about a real thing
  and answers a question nobody put.
  (claude-config#120: the test runner's fallback for "no repo above this script, so read its own
  directory" was also reached when a repo WAS found and held no suites. A run pointed at an empty
  fixture repo silently read the REAL hooks directory instead, found the runner's own test suite
  there, ran it, and that suite invokes the runner, which recursed until it was killed by hand. The
  check asserting an empty repo is refused is what caught it, and it caught it by hanging rather
  than by failing)

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
- **L223. A check that finds records made BEFORE a change by reading a marker those records
  carry can never see anything written before the marker itself shipped, which is exactly the
  population it exists to find, so cover the unmarked backlog with evidence the store already
  holds (a file date, a created time) rather than letting a missing marker read as up to date.**
  The mechanism looks complete because it is: the comparison is right, the tests pass, and the
  first record written after it ships is judged correctly. Everything older is silently exempt,
  and it is the old records that are wrong. L133 says to key on a recorded stamp rather than on
  the value; this is the other half of that, what to do about everything predating the stamp.
  (PostRoll#804: the before/after colophon fix bumped the template's design version, but the
  staleness badge only reports a folder holding a design.json recording an older version, and
  measured on the day of the fix not one folder in the library carried one, so Dan published a
  two week old render of the broken layout with nothing to warn him)
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
- **L183. A pipeline under `set -o pipefail` can be failed by its PRODUCER being killed when a
  short-circuiting consumer (`grep -q`, `head`) exits first, so a correct check reports a failure that
  never happened.** Feed the consumer from a herestring or a file rather than a pipe when it may exit
  early, because the race is load dependent, so it appears only when several things are running, and the
  false red is indistinguishable from the defect the check exists to catch. Distinct from the pipe rule
  already written down, which covers a pipe HIDING a failure by reporting the LAST command's status: this
  one is `pipefail` working exactly as documented and still lying, because of the FIRST. (2026-08-16,
  overture#2850: a full suite run went red claiming a script did not call a function it calls on the
  exact line the assertion reads. `printf '%s' "$text" | grep -qF '...'`, and `grep -q` exits on its
  first match, closing the pipe, so `printf` dies of SIGPIPE and pipefail takes printf's status. Eight
  such lines across four fixtures, in the mandatory pre-push gate, inventing a failure about correct
  code.)
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

- **L220. A change that SPLITS work into parts silently re-aims every guard calibrated against the
  whole: the guard goes on running, and passing, while now measuring a fragment, so it can no
  longer reach the threshold it was set to catch.** When you divide something up, find each check
  whose meaning was the TOTAL and give it back the total. Distinct from L135, where the span was
  wrong when the check was written: here it was right, and a later change moved it.
  (claude-config#133: the sync suite asserts its own deadline still has twice the headroom of the
  run it just watched, and its comment said it bites on a full run, "which is the run the deadline
  exists for". Sharding made the default full run four smaller runs, so the check measured a
  quarter of the elapsed time and could no longer fail on any path. Nothing reported a problem: it
  passed, faster than before, and was only found by going back to ask what else had changed span)

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

- **L502. A setting whose OFF state stops something being RECORDED must be monitored by
  asserting its current VALUE on a schedule, never only by auditing changes to it, because an
  application level audit cannot see a change made directly to the database, and the setting's
  whole effect is to remove the evidence that would reveal it.** The audit here was not missing
  and not broken: the handler had written the field into the audit log since the day the feature
  shipped, and the log was complete and never purged. It simply cannot see a write that did not
  go through the application, and an absence of change records reads exactly like a setting
  nobody has touched.
  (bidspoke#882: `workflows.capture_sightings` defaults to true, but was false on Main Flow, the
  live flow carrying the Equifax credit report at ~3,600 executions a day. Those leads produced no
  lead sighting, nothing in Snowflake, and their execution was truncated at 7 days, so they left no
  durable record anywhere. `audit_log` holds 857 rows back to the project's first week and contains
  zero records of that field ever changing, so who turned it off, when, and why are unrecoverable.
  Found only by querying the column directly while investigating something else)

- **L504. A test can only tell two implementations apart when the environment it runs in makes
  them behave differently, so when the ambient configuration (the host timezone, the locale, the
  filesystem's case sensitivity) is what separates a correct implementation from a wrong one, the
  test must SET that configuration itself rather than inherit it.** A runner's defaults are usually
  the exact setting under which the two agree, so the suite passes whichever version shipped, and no
  amount of realistic fixture data closes the gap because the fixture is not what is blind.
  (bidspoke#922: building the execution archive's day rule, two successive guards against a
  local-time implementation were written and both were hollow, because CI runs on UTC and on a UTC
  host `toISOString().slice(0,10)` and `getFullYear/getMonth/getDate` return the same string. The
  committed fixture held real timestamps measured from Postgres either side of UTC midnight and a
  DST change, and still could not fire. Only moving the host timezone inside the test caught it, and
  the mutation was then seen to go red while running under TZ=UTC)

- **L506. A guard that branches on a field arriving from OUTSIDE the system is only real once
  that field's presence has been measured on live traffic, because an absent field makes a
  strict comparison silently false and the guard then reads as an active safeguard while
  refusing nobody.** Check whether the same fact arrives under a DIFFERENT name in the same
  payload before concluding the sender does not provide it, because the usual cause is a field
  renamed or never agreed rather than a fact nobody sends. Extends L90 to the external
  boundary: there the remedy is auditing which code writes the value, here you cannot, because
  the producer is a third party, so presence has to be measured rather than reasoned about.
  Distinct from L147, which calibrates a guard that DOES fire against real values; this one
  never fires at all.
  (bidspoke#926: both RML bidding workflows exclude military applicants by testing
  personalInformation.militaryStatus === true, a key absent on 100% of 12,992 payloads sampled,
  so the branch has never fired in 150,110 runs, while the signal sits in the same payload as
  financialInformation.employmentStatus === 'military', arriving 34 times in 3 hours)

- **L209. A threshold measured while a co-varying component is held constant attaches itself to the wrong variable, because the part the fixture moves stands in for the sum.** Vary every component the real input varies, or state the measured limit as a limit on the total.
  (downbeat#344: two confident predicates for which calendar sentences Fantastical mangles shipped and were both disproven by real bookings, one the same day it shipped. Every ladder fixture held the title short and constant while varying the venue phrase, so the phrase's length aliased the sentence's total length and took the blame: "62 to 66 characters ending in a number" was really "a total near 170 under that fixture's title". Cloning the real failing sentence and bisecting title against phrase showed total length was the only variable that flipped the outcome, at a cliff between 166 and 172.)

- **L225. An invariant between two stored values must be checked by something that reads
  the VALUES, never only inside the tool that normally writes them**, because an edit made
  by hand takes the other route and escapes it entirely while the tool goes on reading as
  the safeguard.
  (PostRoll#808: the day a template's design last changed was held to its version number
  only inside `make record-design-change`, so a version bumped by editing the file kept a
  stale date and every preview made since read as current)
- **L228. A comparison asking whether two things hold the SAME ELEMENTS says nothing about their
  ORDER**, so for anything whose meaning is sequential (source code, a list of migrations, a
  sequence of steps) a sorted or set based check passes on a file that cannot run, and it is most
  tempting exactly when a real byte comparison has already reported a difference you are looking
  for a reason to dismiss. (claude-config#160: a commit series was rebuilt by re-applying split
  patches, and a plain diff reported the result differed from the version that had just passed a
  full test run. Comparing the sorted lines said "same lines, different order", which was read as
  harmless placement. A helper function had in fact moved BELOW the five checks that call it, and
  the next full run failed on all five. The set comparison was correct and answered a question
  nobody needed asking)

- **L511. A test that times out names the assertion that was running, not the cost that caused
  it.** A test that TIMES OUT names the assertion that happened to be running, never the accumulated
  cost that caused it, so a file whose per test setup repeats expensive work reports its growth as a
  failure somewhere unrelated. Compute a costly fixture once per file, and read a timeout on an
  assertion that does no waiting as a measurement of the FILE rather than a fault in that assertion.

A suite went red with `Test timed out in 5000ms` on a date formatting test whose whole body was
three synchronous calls. The issue filed against it theorised about the one unusual thing that test
did, and that theory was measured and disproved twice, on two operating systems. The real cause was
in a different file entirely: it rebuilt a whole TypeScript parse of the app thirteen times, several
of them inside one test, and had grown from 4450ms to 5841ms that same day as tests were added to
it. Nothing reported the growth, because a test file has no budget, and the timeout pointed at
whichever assertion was unlucky. Building the fixture once took the file to 3776ms and its slowest
test to 963ms.

(new-agent-onboarding#670, #689)

- **L517. When code sorts items into output buckets (paged versus logged, retried versus dead
lettered, shown versus hidden), assert that every item lands in exactly ONE bucket across every
combination of inputs.** A test that checks only one bucket is satisfied by an item that fell out of
all of them, and silence caused by vanishing reads exactly like silence caused by health.

PET#1107 changed a build watchdog three rounds running. Round 12 added a suppression so a step
already alerting its own failure would not page twice, with seven tests covering it, every one
asserting that no alert fired. The alert was correctly silent. A step that had never succeeded, was
attempting daily and was self alerting was excluded from the paged list for self alerting and from
the not paged list for attempting, so it was in neither, and the watchdog printed "All daily-build
write steps have a fresh heartbeat" about a step that had never once worked. The same author had
made the same class of mistake one round earlier. The fix that stuck was not another case: it was a
loop over all sixteen combinations of the two stamps asserting each entry appears in exactly one
output, plus a seam for what the watchdog PRINTS, which it had never had, so every test in the file
had been asserting on the alert text alone.

(PET#1133, #1107)

- **L518. A check that reads source by taking a FIXED NUMBER OF LINES from an anchor stops
containing the code it checks the moment a comment is added above it, and it then fails on the
comment rather than the code.** Slice from the anchor to the next structural boundary and strip
comment lines, because the obvious fix of widening the number only resets the trap.

PET#1107 round 17: a guard asserted that a workflow step reads a marker file and exits non zero,
by slicing fourteen lines from the step's name. Adding a six line comment to that step pushed its
`run:` body out of the window, so the guard failed while the step was correct, and the failure read
as the assertion being wrong. Widening the slice would have passed and left the same trap one
comment later. The fix was a shared reader returning everything from the heading to the next step
with comment lines removed. Two sibling specs in the same repo still count lines. The same shape
is waiting in any guard that reads "the line, or the comment block directly above it", whenever the
window is a count rather than a boundary.

(PET#1137, #1107)


- **L239. Sampling a TRANSIENT surface to decide whether an action happened cannot tell "it never
  appeared" from "it appeared and was already dismissed", so judge by the durable record the
  action would have written instead.** The two readings are identical, and the second is the one
  that has already changed something, so the mistake is always in the reassuring direction. This
  covers any check that looks at a screen, a sheet, a toast, a spinner or a window count some
  seconds after the trigger, including a screenshot: what the sample proves is the state at the
  moment of sampling, never the state in between.
  (postroll#844, 2026-08-22: a postroll:// link was fired at the running app and the reading a few
  seconds later was "windows: 1, sheets: 0", reported as the link having done nothing. The store
  showed otherwise: the sheet had opened and an event had been created and the sheet dismissed
  inside that gap. The correct check was `events.json`, which cannot be dismissed)

- **L250. A list written to mean one thing (a `.gitignore`, an exclude file, a skip list) is read by
  every OTHER tool that consults it as a DIFFERENT instruction, so a guard built on a question that
  tool answers inherits an exclusion nobody chose for it, and goes blind exactly where unowned writes
  land.** (overture#3161: `check-tree-untouched.sh` exists to notice a test run modifying the
  repository, and it decides from `git status --porcelain -uall`, which lists untracked files but
  never ignored ones. The `.gitignore` entry was written to mean "this is per machine, do not commit
  it"; the guard read it as "do not look at this". Measured 2026-08-23, a new fixture drove the real
  test wrapper and wrote a record into the repository root asserting that both live-store invariants
  had measured rows on a day the store held zero of both. The guard passed clean. It was found by
  reading the file by hand. Ignored paths are where scratch and state files land, so the blindness is
  in the likeliest place rather than an unlikely one)

- **L252. A test asserting a decision that has since been REVERSED stops being coverage and becomes the
  guard DEFENDING the rejected behaviour, so a reversal must hunt those tests down across every file
  and DELETE them rather than adjust them, because their whole content is the thing being removed.**
  (overture#3163: Dan reversed the rule so a show dismissed after being emailed owes no nudge. Two
  tests asserted the opposite, in two different files, and both had been written the SAME DAY, one of
  them by the change that had shipped against his most recent recorded call. The first was found by
  reading and replaced; the second was MISSED and surfaced only by a full suite run twenty minutes
  later. Adjusting such a test is the trap: its assertions look repairable one line at a time, while
  what it exists to prove is exactly what was rejected. The cost here was one wasted suite run; the
  risk is the reversed assertion sitting in a file nobody re-runs, quietly becoming the authority for
  the old rule)

## Data safety

- **L206. A tool mode whose NAME reads like an inspection (reach, check, status, list,
  show, verify) must not create or modify live data, because it will be run to look
  around by somebody who has not re-read the docs, and being reached for in a hurry is
  the whole point of such a tool.**
  (downbeat#360: a calendar measuring script has modes that fire real URLs at another
  app and modes that only read, with nothing in the naming to separate them. `reach` was
  run purely to list which calendars existed on the account; its documented job is to
  create one event on each REAL calendar, and it put a live event on the working
  Shoots calendar. The cleanup removed it, so the cost was luck rather than design.
  Distinct from L9, which is about destructive actions earning a confirmation: this one
  is about a CREATING action hiding behind a reading name)

- **L201. A seam or flag that keeps a test off live data on the way IN (a loadingSaved flag, an
  injected path the loader alone uses) does not cover the way OUT**, because any save, set or
  delete that names the live store directly is still reachable, and that is the half that
  cannot be undone.
  (PostRoll#738: HashtagStore's live initializer was compiled out of the test bundle so a test
  has to say loadingSaved: false, which gates the LOAD only, while save() names
  UserDefaults.standard itself and would write Dan's real global tags from any rendered screen.
  HandleBook.shared is the same shape: its store is a property precisely so a test can point it
  elsewhere, and the singleton is built by a private init that takes .standard)

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

- **L174. Shortening a retention or expiry window makes every later step keyed to a longer
  window unreachable, and that step goes on reading as an active safeguard rather than as
  dead code.** When you tighten a window, re-check every cleanup, scrub or archive that
  fires after it, because the one that no longer runs is usually the defence in depth
  someone will later cite as the reason the shorter window is safe. Distinct from L29,
  which asks that dead code be wired or deleted: here nothing looks dead, the job runs
  nightly and reports success, and only the arithmetic between two windows shows it can
  never match a row.
  (bidspoke#826: execution retention went from 14 days to 7, and the 03:00 job nulling lead
  payloads at 14 days has matched nothing every night since. Its own migration comment still
  says it exists so payloads are scrubbed before their partition is dropped, and the
  write-time redaction that would otherwise limit exposure is switched off, so the second
  line of defence anyone would cite is the one that stopped firing)
- **L191. A write into a CAPPED or rolling store (a log with a maximum, a ring buffer, a
  recent list) does not merely add noise, it EVICTS the oldest real records, so a cheap
  writer (a test, a retry, a health check) destroys the expensive observations the store
  exists to hold, and any count derived from the store then reports the junk as real.**
  (downbeat#313: the questionnaire agreement log exists to measure how often the two readers
  disagree on a real form, and it caps at 200 entries. The unit suite sandboxed the
  questionnaire copies but not the log, so every run appended entries stamped with its pinned
  clock. Measured 2026-08-19, 198 of the 200 lines were test writes and only two were real
  imports, so the observation window the product decision waits on had been flushed out, and
  the summary in Settings counted the test imports as observed ones)
- **L202. Evidence attached to a record that is itself swept on a retention schedule
  inherits that schedule's lifetime, so it is gone before the investigation that needs
  it, which by definition arrives days later.** Choose where a durable record lives from
  how late its reader arrives, not from which row it describes. Distinct from L174,
  which is about shortening a window and stranding a later step, and from L191, which is
  about a capped store evicting real records: here nothing is shortened and nothing is
  evicted, the record is simply written onto a row with a shorter life than the question
  it answers.
  (downbeat#343, downbeat#350: a commit's record of which calendar events it fired was
  moved onto the saved booking so it would survive the commit, which it does. Bookings
  are swept seven days after the shoot, and the loss that motivated the work was
  investigated nine days after the fact, so the fix covered the check that runs minutes
  later and not the situation that made it worth building)

- **L211. A cleanup that deletes whatever its read did NOT mention turns every
  incompleteness in that read into permanent deletion, so it must refuse on a SHORT read
  and not only on a failed one**, because a row cap, a swallowed partial error or a
  filtered query all come back as success. Compare against the previous run's count and
  refuse on a collapse, because an abort on read failure guard reads as diligence and is
  exactly why the second guard never gets written.
  (nursedex#745: the nightly blog image sweep correctly aborts when it cannot read the
  posts, and then deletes every storage object those posts did not reference. The read
  it trusts is an unpaginated select PostgREST silently caps at 1000 rows, beside a
  storage listing that logs its error and returns a partial list, so both ways it comes
  back short are indistinguishable from a blog that genuinely shrank, and storage
  deletion has no undo)

- **L219. A test that drives a real browser and does not assert on its CONSOLE discards a
  diagnosis the browser already made**, so a blocked resource, a policy refusal or a
  hydration mismatch reaches production having been correctly reported and never read.
  Listen to the console in the suite you already run, because these defects are invisible
  to code review and to every assertion about what the page renders.
  (nursedex#761, nursedex#763: a CSP with no worker-src blocked Sentry's replay worker on
  every page for every visitor. The browser printed the directive, the blocked URL and the
  reason that script-src was used as a fallback. The e2e suite drove that same browser
  through the whole sign in flow and had no console listener anywhere, so the defect was
  found by a person opening the page and looking)

## Honest failure

- **L515. Cleanup placed in a `finally` is only reached by the paths that THROW**, so a process
  exit on a failure path skips it in silence, and the cleanup reads as present in the source while
  being absent for exactly the failures that take the exit. Verify by RUNNING which paths reach it,
  never by reading. The companion to L514: L514 says record that it ran on every exit path, and this
  is the mechanism that quietly defeats that instruction.
  (project-enrollment-tracker#1124: the roster sync stamped its attempt heartbeat in a finally while
  the two Salesforce failure paths called process.exit, so a rotated credential, the one failure the
  heartbeat existed to diagnose, was the one it never witnessed)

- **L514. A signal that records THAT something ran must be written on every exit path, in a
  `finally`, never only on the success path**, because one written only on success turns a step
  FAILING every run into a step that appears to have STOPPED running, and those two send the reader
  after different problems: a scheduling or trigger fault instead of the real cause. The mirror of
  L106 (a live signal over dead work): here the work is alive and failing, and the silence lies the
  other way.
  (project-enrollment-tracker#1122: the roster sync stamped its "did this step run" heartbeat as the
  last line of the run, so a rotated credential failed the step every morning, the heartbeat went
  stale three days later, and the monitor reported the sync as no longer running)

- **L184. Judge a command by its EXIT CODE, never by a line of its output, because a tool's final
  line is routinely a different measurement than its verdict and is usually the more reassuring of
  the two.** Writing the rule down about one tool does not carry, since the next one phrases its
  summary differently, so the habit has to be reading the code rather than remembering which line
  each tool puts last.
  (new-agent-onboarding#637, 2026-08-17: eslint ends with "0 errors and 1 warning potentially
  fixable with the --fix option", a count of FIXABLE problems, printed below the real summary
  "5 problems (1 error, 4 warnings)". Reading the tail scored a genuine lint error as a clean run
  and the branch was pushed red. The repo already held a note about exactly this, written about the
  test runner, which is why the tool-specific form of the rule is not enough)

- **L10. An error state and an empty state are different screens.** Never render a
  cheerful empty state over a failure, and return real not-found semantics rather than a
  200 shell. (16 issues, 3 repos)
- **L199. A marker meant to be READ BY CODE (a prefix, an error code, a sentinel) must reach its
  reader unwrapped**, because a sentence composed around it for a person defeats every check that
  recognises it, and a test that feeds the check the bare marker never sees the wrapped form that
  actually ships.
  (PostRoll#730: the Friday clip pipeline reports too few usable clips as `insufficient_clips: ...`,
  and the review card recognises that prefix to offer the only two ways out of a state that will
  fail identically on every retry. The screen wraps the day's error as "Friday regeneration failed:
  <the marker>" before the card sees it, so the prefix check never matches and the escape hatch
  cannot appear. Its unit test passes the predicate the bare marker and has always been green)

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

- **L229. Literal text handed to an interpolating evaluator can have a sigil prefixed span silently
  deleted from it, so the tool acts on text nobody wrote and every verdict it reports afterwards is
  about something else.** Compare what actually LANDED against what was supplied, before running
  anything on it. Distinct from L138, where a MISSING value renders as empty: here the text was fully
  supplied and the layer ate a piece of it. Applies to a perl expression, a double quoted shell
  string, an SQL literal and a template alike.
  (overture#3109: scripts/mutate.sh passes its expression to `perl -0pi -e`, so the replacement
  "someone@arealpersonsite.com" reached the file as "someone.com" because `@arealpersonsite` is a
  perl array variable that interpolated to nothing. The guard under test correctly said nothing about
  a string that is no longer an address, and mutate.sh reported SURVIVED for a guard that was real and
  working. Re-run with `\@` it reported CAUGHT. Same class as the `$0` refusal added in overture#2995,
  which did not cover `@`, and the aim check cannot catch it because the change lands on exactly the
  line it was aimed at)

- **L230. A redaction or anonymisation step that changes the CONTAINER while leaving the identity
  inside it has anonymised nothing, and a guard written the same way passes every real person
  wearing a safe container.** Redact the identity, and check for the identity. Distinct from L104,
  which is about a shape filter OVER matching: this is a safe shape carrying real data straight
  through. The container is the domain half of an address, a masked account number, a test account
  wrapper, a reserved TLD, a staging URL.
  (overture#2839. A 2026-08-16 sweep replaced the domain half of every real address in a PUBLIC
  repository's test data, so caseen.gaines@gmail.com became caseen.gaines@example.com and went on
  naming a real person, alongside 37 display names and 20 references to their personal domain that
  the sweep never looked at. The guard written afterwards judged an address by its TLD, so
  realpersonsname.example passes it cleanly, and two such were already in the tree from an earlier
  partial scrub: the identical mistake made twice, independently, six days apart. overture#3110)

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
- **L236. A platform call that may need the PERSON to authorize it (a keychain read, a permission
  check, a credential store) must never run on the thread that would have to draw the question,
  because the two wait on each other and the whole app disappears rather than the one surface that
  asked.** Run it off that thread under a deadline and give the surface a visibly distinct checking,
  answered and gave up state. Distinct from L110, which is about a wait having no deadline at all,
  and from L91, which is a slow derivation making a control feel broken: here the wait is for the
  person, the person is never asked, and the blast radius is every window rather than the one that
  asked. The tell is a process that is alive with no windows, no menu bar and no response to its own
  deep links, which no crash reporter and no log will ever mention.
  (downbeat#402, 2026-08-22: two `.onAppear` handlers on the Integrations tab read the keychain
  synchronously on the main thread, so `SecItemCopyMatching` blocked inside a SwiftUI update while
  `SecurityAgent` waited for an answer; one click on that tab from a fresh launch left the app
  needing a force quit, reproduced three times across two builds)

- **L241. Work that BLOCKS must never run on a bounded shared worker pool (Swift's cooperative pool,
  a fixed size thread pool, an event loop), because such pools do not grow and a few blocked items
  starve every other piece of concurrent work in the process.** Give blocking work a pool that
  grows or a thread of its own. The tell is a failure far larger than its cause and pointing
  everywhere at once: not the blocked operation reporting a problem, but everything else stopping.
  Distinct from L110, which is a wait with no deadline, and from L236, which is a wait for a person
  on the thread that would ask them: a deadline does not help here, because the damage is done by
  occupying the thread at all.
  (downbeat#406, 2026-08-22: the fix for a keychain hang ran the blocking call with `Task.detached`,
  putting it on the cooperative pool; a suite whose fixtures blocked a handful of them killed the
  test process partway through and reported 1835 failures that were one starved runtime. The same
  trap was already documented in a comment two files away, which did not prevent the repeat, L57)

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

- **L505. A value that resolves to undefined is DROPPED from a serialized payload rather than
  sent as empty, so a wrong field reference is indistinguishable from a field nobody meant to
  send, and both ends read the absence as normal.** Assert that identity and correlation fields
  are actually present on the outbound payload at the boundary, rather than trusting the
  reference that builds them, because the sender sees a successful response and the receiver
  sees a well-formed message, so nothing anywhere reports a problem. Distinct from L138, the
  mirror case, where a templating layer renders a MISSING setting as an EMPTY value and an
  absence check then accepts it: here the key vanishes entirely and there is nothing left to
  check.
  (bidspoke#924: eight rejection paths across four live bidding workflows shipped with no lead
  id for months, two of them reading a payload field the partner never sends and six never
  setting it at all, so partners received rejections they could not tie back to the lead they
  had sent)

- **L218. A policy with a defined fallback chain (a CSP directive, a CSS cascade, an
  inherited config) treats an OMITTED rule as a NEIGHBOURING rule rather than as no rule,
  so the omission silently applies a restriction written for different content.** Name
  every directive the thing actually needs, because the only place this surfaces is a
  runtime console on a real page, never in the source and never in any test that reads it.
  (nursedex#761: the CSP set script-src and no worker-src, so the browser fell back to
  script-src, which does not permit blob:. Sentry's session replay creates its compression
  worker from a blob URL, so the worker was blocked on every page for every visitor and
  replay was degraded, while privacy work on that same replay shipped the same week on the
  assumption it was recording. Nothing in the source looked wrong: the omitted directive
  reads as unrestricted)

- **L516. A repair that BACKFILLS a field after the fact (a duration from a child record, a
  finish time from the last known activity) writes the value the work would have had if
  nothing had gone wrong, so it erases the evidence of the delay it repaired.** Any later
  query measuring lateness from that field then returns the same answer on a fully broken
  system as on a healthy one, so measure from state the repair does not touch and prove the
  query can tell the two apart before trusting a zero.
  (bidspoke#1005: both stranded-execution finalisers set duration_ms from the last completed
  step, so an execution rescued 26 hours late records a few seconds. The obvious question
  "how many finalised more than 2 hours after they started" was asked as duration_ms >
  2 hours and returned zero over 704,253 executions, which is exactly what it would return
  if every one of them had been stranded. The real answer came from state the repair does
  not write: rows still marked running, and rows carrying the finaliser's own outcome marker)
- **L520. A failure message built only from a response BODY says nothing when the request
  could not carry a body (an HTTP HEAD, a 204), and the empty payload then reads as no
  information rather than as the diagnosis it is.** Carry the status code, which is the only
  thing that survives such a response, and NAME the empty body rather than printing it, so
  the emptiness is reported as the method's own guarantee instead of as a lost error.
  (bidspoke#1040: the execution archive counts an hour's rows with a HEAD request before
  reading them. That count hit the 30 second statement timeout, which Supabase's edge log
  recorded precisely as `PostgREST; error=57014`, HTTP 500, but a HEAD response carries no
  body, so PostgREST's error text was stripped in transit and supabase-js built
  `{ message: '' }` out of the empty body. The alert said only `counting steps failed:
  {"message":""}`. Both of the archive's counts are HEAD requests, so EVERY count failure it
  could ever have reported that same empty object, while the status sat on the response
  unread. The root cause was a missing index, 7.1 s warm against a 30 s limit, and it was
  found only by digging through the provider's own logs)

- **L251. A substitution can only rewrite text that is PRESENT, so one used to also supply a
  separator when joining two pieces inserts nothing at all on the input that lacks it, and the
  pieces fuse into a single corrupted value.** Join explicitly and normalize separately, because
  the inputs that DO carry the whitespace join correctly and make the defect intermittent, which
  is what keeps it out of the case anyone thinks to test.
  (claude-config#192: the lessons index generator joined a wrapped rule by replacing a
  continuation line's leading whitespace with a single space, which does the right thing for an
  indented line and nothing whatever for an unindented one, so those fused onto the previous word
  and shipped into the index that loads into every session in every project)

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

- **L175. A value read once at startup is only true at startup, and when the thing it describes
  lives OUTSIDE the program (a checkout, a config file, a device, another service) there is no
  action inside the program to hang a re-read on, so it goes stale invisibly and its silence reads
  as an assurance.** Re-read it on the events the program does see, coming to the foreground and
  starting the work that depends on it, and refresh from a read something already takes rather than
  adding a second reader. Distinct from L14, which asks that derived state re-derive on every input
  that feeds it: there an action inside the product changes the input and can trigger the
  re-derivation, and here nothing inside it ever fires.
  (PostRoll#668: the banner saying the code folder was not on a clean main was read once at launch,
  and the folder moves precisely while the app is open, because that is when a session switches
  branch or leaves edits. So the likeliest state was the wrong one, the banner absent while the
  folder had already moved, or naming a branch left an hour ago. PostRoll#675 is the same check
  sitting beside it, whose own comment states as fact that its answer cannot change while the app
  is open)

- **L176. A field name that asserts a ROLE or a DIRECTION (who referred whom, source versus
  destination, sender versus recipient, parent versus child) must be verified against the code that
  RENDERS it, because the rendered wording is the authority and a backwards name silently recruits
  every future writer into filling it the wrong way round, with nothing anywhere reporting a
  problem.** Distinct from L118, which is about one word naming two different units, and from L46,
  which asks that a field have a reader at all: here the reader exists, is correct, and contradicts
  the name every writer is reading instead.
  (downbeat#252: `newGroupThatReferred` reads as the group that DID the referring, while the seeded
  Referral Tracker task renders it as `New Client:` beside `Returning Client: <<clientName>>` and
  `Name of Referring Group's Concert: <<photoshootName>>`, so the booking's own client is the
  referrer and the field holds the new group they referred IN. Found only because a questionnaire
  import was about to fill it from "Referral program (BK Treble Choir)", where that group is the
  referrer, which would have put the wrong organisation into a task Dan then acts on)

- **L185. A statement that NORMALIZES a value on the way in (a COALESCE, a lowercase, a trim, a
  default standing for absent) must group or deduplicate by the NORMALIZED form, never by the raw
  one, because two raw spellings that normalize to the same thing survive as separate groups and
  then collide on one stored key.** Each line reads as correct alone, and the collision stays
  dormant until the first input arrives in the second spelling, so the defect ships and waits.
  Distinct from L131, where a repeatable key silently keeps the last writer: here nothing is
  dropped and the write fails outright. Also distinct from L147, where normalization makes a
  guard miss: there the comparison is too loose, here the grouping is too tight.
  (bidspoke#837: `refresh_workflow_stats_daily` inserts `COALESCE(outcome, '')` into a NOT NULL
  DEFAULT '' primary key column while grouping by the raw `outcome`, so NULL and '' form two
  groups that collapse to one key. Measured live: 11 rows with NULL and 0 with '', which is the
  only reason a nightly job has never hit it, and a single execution written with the empty
  string would freeze the dashboard rollup until that row aged out of raw retention)

- **L186. A durable record that exists to stop an action repeating is only as durable as its
  KEY.** One keyed on an identifier minted in memory per attempt (a fresh UUID, an object
  identity, an in process map) survives a restart while nothing can find it again, so the
  protection silently shrinks to the session that wrote it: key it on something recomputable
  from the data itself, and surface any unresolved record at startup. (downbeat#277, where a
  commit journal entry recording an unknown OmniFocus outcome correctly refused a duplicating
  retry, then became unreachable, because the batch mints `bookingId` in a dictionary on itself
  and the fallback guard keys on a saved booking row a failed commit never writes; nothing at
  launch reads such an entry either, so it waits thirty days for the pruner and the next attempt
  fires the script again with no guard firing at all)

- **L192. A value INFERRED from content (a name pulled out of caption text, a category guessed
  from a title, a type read off a filename) must never be presented as the recorded fact it
  stands in for.** While every row's inference happens to agree with that fact the two are
  indistinguishable and nothing anywhere reports a problem, so the first change that lets them
  diverge (making the field optional, allowing a blank, admitting a new shape of input) silently
  reattributes the data under a label still claiming to be the fact: name the dimension after
  what it measures, or read the fact from where the system already holds it.
  (postroll#706: Insights labels a dimension "Orgs" and hangs a follower size band off it, while
  the value is `_extract_org`'s first non owner @mention in the caption, and `Event.org` is the
  real organization sitting one record away. #689 made the organization optional, so the account
  credited first is now often the venue or a performer, and the post plus its audience band are
  filed under that account with nothing looking broken)

- **L200. A record that permanently EXCLUDES something on the grounds that another record covers
  it (a night another card holds, a task another job owns, an item another order fulfils) must
  re-check that other record at read time, because deleting it leaves the exclusion standing over
  nothing and the gap is invisible on both sides.** The exclusion reads as a decision somebody
  made, and the surface that would have shown the thing simply never shows it, so nothing anywhere
  reports the loss. Distinct from L137, where a legitimate grant's REVOCATION fails to land, and
  from L175, where the stale value describes something outside the program: here both records are
  yours and one silently invalidates the other.
  (overture#3001: dismissing one night of a multi-night run releases every later night another card
  already holds, recorded as dropped so the next scout cannot fold it back. Nothing re-checks that
  the covering card still exists, so dismissing that card puts the night in the queue on no card at
  all, and the run card that used to carry it can never take it back)

- **L507. A category defined as a REMAINDER (the total minus every named category) records no
  members anywhere, so it can never be enumerated, audited or expanded, and it is exactly where
  the cases nobody has explained accumulate. If any surface will one day have to show what is in
  that bucket, record its members at the moment it is computed, because the subtraction cannot be
  run backwards.** The count itself is always right, which is what hides it: the number reconciles,
  every check passes, and the gap surfaces only the first time somebody asks WHICH ones. Distinct
  from L194, where the sender holds the value and reduces it to a flag: here nothing ever held it.
  (project-enrollment-tracker#1094: commission cohorts push a Salesforce id onto clearedIds for a
  cleared deal and benignIds for a recognised miss, while pending is the remainder and is
  deliberately never stored. On a closed month that remainder is permanently full of Achieve rows
  the upstream stopped updating, so a click-to-expand drill-down resolves every other count down to
  real clients and dead-ends on the one bucket that most needs explaining)

- **L509. A shared value that consumers EXTEND (a style token, a base config, a set of default
  props) must not set anything a consumer legitimately overrides, because the winner is then
  decided by a merge or emit order invisible at the call site, so the call site reads as correct
  while the override silently loses.** Either keep the contested property off the shared value, or
  compose through a merger that resolves conflicts deterministically. The shared value is usually
  written for the COMMON consumer, so the one that overrides is by definition the minority case and
  the least likely to be checked.
  (new-agent-onboarding#676: a minimum height was added to a shared field token so a select could
  not render shorter than the input beside it. That token is also composed by the app's one
  textarea, which sets its own far taller minimum, so the element carried both and the short one
  won: the welcome email body editor collapsed from 288px to 64px, about a line and a half of a
  template clipped mid-word. Nothing looked wrong at either site. It reddened 26 baselines, all
  correctly, and 18 of those were the intended change, so regenerating them would have recorded the
  collapsed editor as canonical and defended it (L84). A person comparing two images caught it)

- **L204. When a change removes an invariant other code silently relied on (only one of these can
  be alive, this only runs on one thread, this id is unique), find every reliance by searching for
  the invariant itself rather than by reasoning about the feature, because the reliance is usually
  recorded only in a comment that reads as reassurance and the code it justifies becomes actively
  destructive the moment the invariant goes.** Same shape as L95, where adding a write to an error
  path re-audits every error that can reach it: the change is small and the re-audit it forces is
  not. Distinct from L55, where a SECOND code path starts producing state an existing reader was
  written against; here no new path appears, the same code simply stops being the only one running.
  The comment is the tell and the trap: a line saying why something is safe names the dependency,
  and reads as having settled it.
  (overture#3009: `settleAnyCheckBefore` settles and then unconditionally clears the shared check
  marker on every Prep launch, gating only on the marker existing and never on the check being dead,
  because until now only one run could be alive. Its own comment states that as the justification.
  Lifting the exclusion in overture#2765 would make a Prep launch destroy a live check's paid
  answers, and make a finished Prep throw away every draft it just wrote)

- **L510. Code that recomputes part of an object must override the fields it changes on a COPY of
  the original, never rebuild the object from a list of the fields it happens to know about,
  because every field added later is then silently dropped and the loss surfaces far away as a
  blank rather than as an error.** The rebuild reads as careful, since the list is explicit and
  each field on it is correct; what it cannot express is the fields nobody has written yet, so it
  is a defect that arrives later, on a change that looks unrelated to it.
  (pet#1102, and the same shape twice before it in the same repo: `applyLiveEligibility` rebuilds
  every rep row on a team from five named stats whenever one rep's eligibility moves, so any other
  per rep field vanishes for the whole team with no error, which is what the commission drill down
  would have walked into; `toRepPayload` lost `alias` on 2026-06-12 and `hireDate`/`termDate` on
  2026-06-08 the same way, each producing wrong data with nothing failing)


- **L521. A lookup that requires exactly one match must treat MANY matches as its own refusal,
  never as absence**, because a fall-through to the create-new path manufactures a duplicate identity that
  every later writer then feeds. The zero-match and many-match cases need separate branches and
  separate reporting.
  (project-enrollment-tracker#1120: the roster sync's pass 1 accepted only a single fuzzy key
  match and recorded nothing on two or more, so an ambiguously named Salesforce rep fell through
  to the insert path and became a duplicate row; PR #1107 then had the duplicate born carrying the
  permanent salesforce_user_id, pinning an external system's join to a row no board shows while
  the real rep read clean. The sync refused two-names-one-row but never the mirror
  one-name-two-rows its own matcher had just detected.)

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

- **L503. An over-broad permission is invisible, because the code never attempts what it is not
  meant to do, while a missing one fails loudly on the first run**, so a least-privilege split
  that has never been observed REFUSING anything is a claim rather than a control. Prove it by
  attempting the forbidden action and treating SUCCESS as the finding, rather than by reading the
  grant that describes it. Distinct from L124, where the danger is a grant the platform already
  made: here the grant may be exactly as written and still nobody has established that.
  (bidspoke#914: three Snowflake identities were split so that only one could delete 13 months of
  archived identity data. The roles and users were read back and confirmed, the grants never
  were, and the archiver never deletes, so an excessive DELETE on the writer or reader would have
  sat unnoticed for the life of the archive. Found while checking a neighbouring setting that had
  silently applied to only one of the three)

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

- **L222. A privacy guard that scans your REPOSITORY cannot see what a tool PRINTS, so any tool
  that reads a live system (its screen, its database, its API) delivers real customer names and
  addresses straight into transcripts, terminal scrollback and logs by a route the guard never
  inspects, and from there into whatever somebody pastes them into.** Give such a tool no mode that
  dumps content wholesale: let it return one named field at a time, so the dangerous shape is ABSENT
  rather than discouraged, because a rule saying do not dump everything lives only in a comment
  (L27). Distinct from L155, which is about evidence somebody DELIBERATELY writes into an issue:
  this is incidental capture, and it happens while doing something else entirely, which is why
  nobody is watching for it. The tell is that the guard and the tool were built for different
  surfaces and nobody ever compared their scopes.
  (downbeat#389: the repo forbids any real client name, venue, address or phone number reaching the
  tree, a test output, a log or an issue, enforced by scanning the repository. An accessibility
  driver built an hour earlier was pointed at the running app to check a sentence on one screen, and
  a walk that printed every text node landed on the Clients tab, putting the whole roster, display
  names and email addresses, into the session output. The end of turn issue review reads session
  transcripts, so it was one paste away from a GitHub issue the guards would never have allowed)

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
- **L189. A persistent surface pinned over the edge of a scrolling region must RESERVE space
  inside that region rather than float above it, or the last item in the scroll is permanently
  unreachable.** The surface only overlaps once the content is long enough to scroll, so every
  short fixture and every empty state shows it working, and the amount of content silently
  decides whether the primary action of the screen can be clicked.
  (PostRoll#695)
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

- **L180. A confirmation dialog's consequence sentence must be derived from the state it is about to
  change, never asserted, because a warning shown on every delete carries no information and reads
  identically whether it is taking one row or a subtree of ten.** The person then learns to click
  through the one confirmation that mattered, and the code looks careful the whole time. Distinct
  from L11, which is about a failure claiming only what its check measured: here nothing has failed
  and the sentence is describing a consequence that may not exist.
  (downbeat#247, downbeat#248: a task delete always said "All subtasks are deleted as well." on leaf
  tasks with none, and an email template delete always claimed tasks would break without checking
  whether any referenced it, while two tabs in the same folder already built their warning from the
  live state)

- **L187. A control gated on a collection holding MORE THAN ONE member is absent in the
  commonest case, which is one member.** So the safe way out of a slow operation is missing
  exactly when a person is most likely to reach for an unsafe one: gate such a control on the
  operation being underway, never on the count of things it covers. (downbeat#282, where Stop
  rendered only for runs of two or more shows because `isRun` is `plans.count > 1`, so a single
  show booking, which is most of the year, was uninterruptible for up to 180 seconds with
  navigation locked, and on 2026-08-18 the only remaining exit was closing the window, which is
  the one action that loses the commit)

- **L508. A control that renders a value the BROWSER itself validates (a date input, a number
  input, a select) shows NOTHING when it is handed a value it rejects, so a message refusing that
  value stands beside an empty control and the two halves of the screen contradict each other
  about what was asked for.** The refusal reads as being about a filter nobody can see, and any
  Clear or Reset offered alongside it appears to clear nothing.
  (new-agent-onboarding#660, #666: a shared audit link carrying an outcome the ledger does not
  record showed "Couldn't show that view" beside an Outcome control reading "Any outcome", and the
  From and To date boxes have the same gap, because an <input type="date"> blanks any value that is
  not a valid date string)

- **L207. A constraint imposed by the surface your output is DISPLAYED on (a phone's notch or
  safe area, a host app's own overlay chrome, a fold, a print bleed) leaves no trace in the
  artifact you render or in any check you run over it, so it is only ever discovered on a real
  device.** Encode it once as a shared value every renderer reads and a test asserts, never as a
  clearance hand applied to whichever templates happened to be open when someone first noticed it,
  because the number then governs nothing outside those files and the ones written next are
  written blind. Distinct from L501, where a clone copies a corrected original as first written:
  here the correction was never expressed anywhere a later file could inherit it.
  (postroll#752: `generate_reel_screen.py` and `generate_before_after.py` each carried
  `170  # clears notch (~120px)` as a literal plus a comment, while `generate_reel_scroll.py`
  drew its title at y=35 and `generate_story.py` anchored its title bottom-up from the photo with
  no top clamp at all, so a two-line title started around y=33; every published story and scroll
  reel had the show's name printed under the clock and the battery, and the only report was a
  screenshot from Dan's phone)

- **L221. A limit calibrated against the DEVICE somebody owns is looser than the same device
  turned down, because display scaling, text size and browser zoom are settings a person changes
  with no code change and nothing re-runs the check, so calibrate against the most constrained
  SETTING the hardware can be put into rather than against the hardware itself.** The trap is
  that the guess feels conservative while being the opposite: reaching for a smaller machine than
  the one on the desk reads as caution, and it still lands above the floor the real machine can
  reach on its own. Nor can the running device be measured instead, because the check then passes
  most easily at the comfortable setting where the fault cannot happen (L101), and a person
  dragging a slider in System Settings triggers no build. Declare the floor, and write into the
  constant which part of it was measured and which part was taken from the platform's published
  options, so the next reader knows the direction of any error.
  (downbeat#388: a guard on whether the New client sheet fits a short screen was calibrated at 956
  points for a 13 inch MacBook Air, a machine Dan does not own; he runs one Mac, a 16 inch whose
  panel measures 3456 by 2234 and sits at 1728 by 1117, and whose smallest scaled step is 1352 by
  878, so the floor guessed from imagined hardware was 78 points looser than the setting he can
  pick at any moment. Headroom fell from 696 to 618 against the same 460 cap once corrected)

- **L213. A colour token that only has meaning as one half of a PAIR (a foreground against its
  background, a border against its fill) must be overridden as a pair, because a call site that
  swaps only the background silently keeps the base variant's foreground, the two can land on the
  same value, and the result is content that is present in the DOM, correctly named to a screen
  reader, and invisible on screen.** Every check that reads the DOM agrees it is fine: an
  accessible name assertion passes, and a visibility assertion passes too, since text drawn in the
  background colour still has a non empty box. Assert the two computed colours differ, or that the
  pair clears its contrast threshold. Distinct from L509, where the override LOSES to a merge
  order: here it wins and simply covers half of what it had to cover. The DOM side sibling of
  L141, which is the same failure seen by a harness measuring ink.
  (nursedex#751: `GoogleSignInButton` set `bg-warm-white` over the default variant's
  `bg-primary text-primary-foreground`, and `--color-primary-foreground` is itself warm white, so
  "Continue with Google" shipped as #fbf9f7 on #fbf9f7, a contrast ratio of 1.0 to 1, on both
  /login and /signup. A unit test asserting the accessible name and a Playwright `toBeVisible`
  both stayed green, and the only report was a screenshot from Dan)

- **L231. A container's background is only the background until something that paints its OWN is
  placed inside it (a platform list or table, a text view, an embedded frame, a third party
  widget), so every call site can name the correct token and still render differently, and any
  check that reads the declaration passes while the screen disagrees.** The value is not what
  differs, the child is, which is why consolidating the call sites onto one shared colour changes
  nothing on screen. Put the fill and the suppression of the child's own background in ONE shared
  container every such pane is built from, rather than a colour constant plus a convention, or the
  next surface gets one half and not the other.
  (downbeat#395: five Settings tabs all end their sidebar with `.background(DBColor.canvas)`. Task
  Templates fills its pane with a transparent `ScrollView` and reads as canvas; Clients, Venues,
  Calendar Events and Email Templates fill theirs with a SwiftUI `List`, which paints over it and
  which `.listStyle(.plain)` does not stop, so they read as the ordinary grey. The header strip is
  a sibling of the list rather than a row in it, so the split was visible INSIDE one pane, canvas
  above the rule and grey below it, and was reported by Dan from a screenshot)

- **L232. A minimum reserved for one part of a shared space (a pane's floor, a sidebar's minimum
  width, a gutter, a buffer) is SUBTRACTED from whatever shares that space, so it must be checked
  for being too LARGE as much as too small, because over reserving breaks nothing and fails no
  test: the neighbour simply cannot grow, and the number goes on reading as prudence.**
  (Downbeat #394, 2026-08-22. The Settings detail pane reserved 480 points, a constant whose own
  doc comment REASONED about the pane rather than deriving anything. The tree pane's ceiling is
  `available - 480`, and Dan's Settings window gives that tab 664 points, so the tree was pinned at
  its own 240 floor with a 16 point band the divider could move in, and he reported that he could
  make the pane narrower but not wider. Measured from AppKit, the widest thing in that pane that
  clips rather than reflowing needed 225, so 255 points were being reserved for nothing and taken
  straight off the pane beside it. Nothing could have caught this: every test asked whether the
  floor was big enough, which it emphatically was, and the failure has no error, no exception and
  no visual defect in the pane that over reserves. It is only visible from the OTHER side, as a
  neighbour that will not grow. Note also that the first fix, lowering the floor to the measured
  225 plus headroom, bought Dan almost nothing on its own: the real gain came from making the
  reserving side REFLOW, wrapping its button rows and tightening its gutters when narrow, which
  took the requirement from 385 to 225. So the question to ask of a reserved minimum is not only
  "is this number right" but "does this side have to be rigid at all")
- **L238. A modal or sheet driven by a single flag on shared application state is presented once
  per SURFACE bound to it, not once, so a second window puts up a second copy of the same thing
  and dismissing one leaves the others standing.** Scope the flag to the surface that raised it,
  or make the app single window on purpose, because how many surfaces exist is usually decided by
  the framework rather than by you: SwiftUI's `WindowGroup` opens a NEW window in response to an
  incoming URL open event, on top of whatever window is already there, so the count grows by one
  per link and survives a quit through window restoration.
  (postroll#842, 2026-08-22: verifying the new `postroll://` handler on the real machine, the
  window count went 1, then 2 after one link, then 3 after a quit and another link, with System
  Events reporting a New Event sheet on every one of them, all showing the same prefill. Every
  unit test passed and none of them could see it: the app entry point is not compiled into the
  test bundle, and no test bundle can open a second window anyway)

- **L242. A surface that can show only ONE of something at a time (a sheet, a modal, a dialog)
  silently ignores every request past the first, so attaching several independent presenters to
  one surface means all but one of those conditions can vanish with nothing said.** Route them
  through one piece of state that names which is showing, so a second request is a decision
  (queue it, refuse it, replace it) rather than whichever one the framework happens to honour.
  The mirror of L238: that one is a single condition reaching many surfaces and being shown many
  times, this one is many conditions reaching one surface and all but one being shown never. Both
  come from the same unexamined assumption, that the count of conditions and the count of surfaces
  are both one.
  (postroll#846, 2026-08-22: MainWindowView attached three sheets to one view, a New Event form, an
  outdated designs list and a build behind warning. It cost nothing while all three were things a
  person opened by hand and could only ask for one at a time, and became live the moment a
  postroll:// link could raise one at any moment. Both losers are bad in different ways: a
  swallowed form is a link that appears to do nothing, and a swallowed build behind warning is the
  notice that exists to stop a shipped fix looking like it never worked, cleared by an unrelated
  click)
- **L243. A surface presented from a boolean saying that SOMETHING is showing cannot notice that
  WHICH thing is showing has changed, so replacing one modal, alert or toast with another while it
  is open leaves the previous content on screen.** Bind the presentation to the identity of the
  thing being shown, and where the framework offers only a boolean, pass the value being presented
  as well so the content is rebuilt with it. The trap sits one step PAST L242: routing every
  condition through one presenter is the right fix and does nothing on its own about identity, and
  the two halves of a screen can then disagree, one heading over another's buttons, which is worse
  than either condition alone because each half reads as correct.
  (postroll#855, 2026-08-23: #846 replaced three sheets and three alerts with one presenter each.
  The sheets were safe by accident, because `.sheet(item:)` takes an identity and each case
  supplied a different one, while `.alert(_:isPresented:)` takes only a Bool. The queue lets the
  refusal to open the events displace the code folder warning, and both are raised by launch
  checks that run on every launch, so the swap is the everyday case rather than a rare one. Every
  model level test passed and none of them could see it: what a framework redraws is not a fact
  about the state, and nothing that runs the app was watching the alerts)

## External systems

- **L513. A value a platform REPORTS is what is currently configured, never what is available**,
  so a design that reads an observed setting as the ceiling silently inherits a default nobody
  chose. Ask what the maximum is, by probe if the console will not say it, before building a
  guarantee on the number you can see. Distinct from L82, where the documented guarantee itself
  goes unmeasured: here the observation is CORRECT and the error is treating it as a limit.
  (bidspoke#911: the execution archive's Snowflake undo window read 1 day, which an ADR recorded
  as near the best case available and reasoned from, including what an erasure could honestly
  claim. It was the account default, not the cap: the account permits 90, established by creating
  a table with a 2 day window and reading the setting back. Thirteen months of execution history
  was about to become the only copy behind a one day window nobody had chosen)

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

- **L181. Inferring that a person DID something from a provider's record must key on that provider's own
  committed state marker, never on an attribute a merely started attempt shares with a finished one (its
  author, its recipient, its subject), because platforms routinely return drafts, pending items and
  abandoned attempts in the same collection as completed ones.** A started and abandoned attempt then
  reads as a completed action, and the inference is wrong in the direction that closes the matter down
  and stops anything asking again. Distinct from L12, which is about OUR OWN write reporting success
  before it committed: here the action is somebody else's and the record is being read rather than
  written.
  (overture#2918: the check deciding Dan had answered a reply from his mail client took the newest
  message in the Gmail thread whose From was his. Gmail returns DRAFT messages inside a thread beside
  sent ones, so an abandoned draft would have stamped the conversation answered for good, with no badge
  and no task, and the stamp never moves backwards. Measured on a live thread the same day, an abandoned
  draft sat 29 minutes above a real reply, and only the timing of the next check saved it)
- **L237. Addressing something by its POSITION rather than its identity (screen coordinates, an
  array index, an nth child selector, a row number) measures whatever currently OCCUPIES that
  position, so prove the thing you named is the thing there, and refuse when you cannot.** A
  reading taken from the wrong place looks exactly like a correct one, and it fails in the
  reassuring direction: neighbouring things usually resemble each other, so the check passes on the
  wrong target rather than returning nonsense somebody would notice. Distinct from L190, which is
  about reading the wrong STORE, and from L84, where a baseline defends whatever was on screen when
  it was recorded: here the address itself is the thing that cannot be trusted.
  (downbeat#403, 2026-08-22: the Settings pixel checker asked System Events where the Settings
  window was and handed those coordinates to screencapture, so with the booking window on top it
  measured the booking window and reported its colours as the Settings panes; it was caught only
  because two different tabs came back byte identical)

- **L190. A read back verifying that another application performed a write must be proved to read
  the store THAT application writes to, never a second system subscribed to the same account.**
  Two subscribers to one server are separate replicas, so the read measures replication lag rather
  than the action, and it reports absent in exactly the window the check runs in.
  (downbeat#305: Fantastical writes through its own CalDAV connections rather than through EventKit,
  so events it had already created were still absent from the macOS calendar half an hour later, and
  the verifier reading EventKit warned that two of two were lost on every single booking)

- **L193. A feature that resolves user supplied values through a stored REFERENCE dataset (a
  postcode to coordinates table, a currency or carrier list, a tax rate table) is only as
  complete as that dataset, and a missing row is indistinguishable from a user who supplied
  nothing, so measure the join's real hit rate against live data before building on it rather
  than treating the table as authoritative because it exists.** Distinct from L113, where a
  code level map over a known vocabulary silently takes a default: here the vocabulary is open,
  the gap is coverage, and the affected records vanish from the feature instead of rendering
  wrongly.
  (nursedex#733: the zip_codes table held 218 rows for a product serving New York State, so
  only 42 of 105 nurses could be placed on a map. The radius filter then dropped every
  unresolvable nurse, which reads on screen as no nurses matching the search)

- **L198. A check that verifies another system's work must match values no more strictly than
  that system does, because a verifier stricter than the actor reports failure on every
  correct run and can never report anything else.** The stricter side is usually the new code,
  written from the value as it appears in your own source, while the loose side is the
  established system that has been quietly succeeding all along, so the verdict accuses the
  half that works. Distinct from L99, where a client mask stricter than its validator blocks
  the person's input at the point of entry: here nothing is blocked and the report is simply
  false. Related to L16, since the two comparisons are one question and belong in one
  predicate, and to L36, which is what the false report costs once it fires every time.
  (downbeat, fixed in 50ea879 during #328's calibration: the seeded templates address
  `/shoots` and `/operations`, the Google account's calendars are named `Shoots` and
  `Operations`, and `GoogleCalendarReader` compared them exactly. Fantastical, which actually
  files the event, does not care about the capitals, so the first real booking to use the new
  check warned that its events might be missing while both had landed correctly, and it would
  have said so on every booking for ever. `CalendarSentenceCheck.calendarNameDisagreements`
  was already comparing the same names case insensitively, so the codebase held two rules for
  one question and the stricter one was the half facing live data)

## Building with AI

- **L27. A rule that lives only in a prompt is a hope.** Every hard constraint on AI
  output also gets a deterministic code check at the boundary, and every field a prompt
  references must provably exist in the payload sent, or the model fabricates it.
  (14 issues, 2 repos)
- **L194. A payload that reduces a stored fact to a FLAG ABOUT ITSELF (a hasProducer boolean, an
  isEmpty, a count) tells its reader the fact exists while denying it the value, so the reader is
  sent to rediscover at cost what the sender already held, and its failure to find it reads as the
  fact never having existed.** Pass the value and let the reader derive the flag. The inverse of
  L27's second clause, where the prompt names a field the payload lacks: here the payload lacks a
  field the prompt was never given a reason to name, so nothing anywhere reports a problem.
  (overture#2983: the contact check's work list derived `onlyTheActIsNamed` from the stored
  `presenter` and dropped the name, so a check on a show credited to Underbelly Theatre Company was
  told a producer existed, never told which, spent 22 web calls drifting onto a different production
  of a similarly titled show, and recorded `nothing_published` about an organisation publishing its
  address on its own contact page. 12 of the 23 no-email cards on the live store were in that state)
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

- **L249. A decision ATTRIBUTED to somebody inside your own artifact (a PR body, a plan, an issue
  comment) must be quoted from the record that holds it and carry that record's own date, because a
  paraphrase with a date on it reads as authority and is the one claim a reviewer will not go and
  check, so a decision nobody made can ship with tests written to defend it.**
  (overture#3159: PR #3142 opened with "Dan's call, 2026-08-22: one number, and the sheet grows a
  section" and merged. No comment of that date exists on #2967, #2968 or #3076. The two real calls
  were both dated 2026-08-21 and the PR went against both, keeping `conversationsToConfirm` in the
  Due total where the call said to take it out, and counting a show dismissed after it was emailed
  where the call said a dismissal stops asking for work. The shipped tests then asserted the
  superseded behaviour, so the guard defended it. The same PR declared `Closes #2967, #2968, #3076`
  and closed only the first, so the issue holding the contradicted decision stayed open with nobody
  reading it. The body is already a gate here (`pr-completeness-guard.sh` refuses one missing its
  four enumerations); the one claim in it that only the person quoted can settle was the one
  unchecked thing)

## Codebase hygiene

- **L217. A guard whose forbidden or expected values are DERIVED from a shipped dataset covers
  only what that dataset happens to contain, so a real value that never enters it is permanently
  exempt from the very check written to catch it.** Being generated rather than typed reads as
  safe, which is why nobody re-examines the source, and where the real values live outside the
  shipped data the list has to be derived from the records the system has actually written.
  Distinct from L96, where a hand written registry forgets an entry: here nothing was forgotten
  and the derivation is correct on its own terms, so every audit of whether the guard works
  passes.
  (downbeat#374: the identity guards read their needles from the shipped seed roster, so a client
  or venue in the seed was covered and nothing else, while the real bookings routinely name venues
  and show titles that never enter it. The machine local list built for exactly that case did not
  exist on this Mac, so the check reported `noList` and examined nothing on the one machine where
  a real name could reach the tree, which is correct for a clone and silently useless here. One
  real venue from a booking committed that week sat in four test files with nothing covering it.
  The list is now generated from the store's own committed bookings, prints counts and never a
  name, and treats a missing or unreadable store as a refusal rather than as an empty file, since
  an empty list turns "no list, said so" into "a list, and everything is clean" (L98). The file of
  needles matched all 26 of its own entries on the first real run, because a file cannot tell a
  line that IS a forbidden value from a line that declares it)

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
- **L210. A check that keeps a document in sync with the code by comparing a machine readable
  token (a number, a name, a version) leaves the sentence beside it unverified, and the passing
  check makes that sentence MORE trusted rather than less.** Assert the behavioural claim the
  prose makes, or move it somewhere the check can reach it, because a doc carrying a green
  freshness check is read as verified in full and the unchecked half is exactly where the claim
  that matters lives. (claude-config#112: a design record justified a nesting limit with "runs
  itself as a subprocess in one place and never deeper" while the check beside it compared only
  the number, so a change making it run two deep would have left both that sentence and the
  README's false with everything still green)
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
- **L247. A sweep that requires every place doing X to also do Y must enumerate its subjects by
  the STATE they reach, never by one spelling of X, because a place reaching that state by
  another route is never enumerated and is exempt from the rule the sweep exists to enforce,
  while the sweep goes on passing the subjects it did find.** Distinct from L96, where the
  subject list is written by hand: here it IS derived, and derived correctly, from a proxy for
  the population rather than the population itself, so it reads as real coverage.
  (PostRoll#872: a sweep required every failure path to announce itself and found its subjects
  by searching for calls to one tracker method. The export manager records a failure by setting
  a failed phase and deactivating instead, so the longest running work in the app was the one
  kind that still failed in silence, and the sweep reported all clear while checking five real
  sites)
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

- **L501. A new thing built by cloning a proven pattern copies that pattern AS FIRST WRITTEN,
  including every value already corrected in the original, so clone the CURRENT version and
  re-check each constant against the rule it has to satisfy.** The clone's own note saying it
  follows a proven pattern is what makes it read as safe, and the correction it missed usually
  lives in a comment on the original, which governs nothing. Distinct from L30, which sweeps a
  found defect's siblings in the same change: here the sibling did not exist when the fix landed,
  so no sweep could have reached it, and distinct from L57, where the correction never reached the
  governing artifact at all.
  (bidspoke#849: workflow_stats_daily's nightly rollup lookback was cut from 90 days to 7 in May to
  match raw retention, with a comment saying it must never exceed it. field_presence_daily was
  added a month later, its header reading "clones the proven refresh_workflow_stats_daily pattern",
  and took the 90. Measured 2026-08-18: 110 days of history in the table with the 7, and 10 in the
  table with the 90, because every successful nightly run deleted 90 days and could only rebuild
  the 8 still in raw)

- **L195. A newly recorded lesson governs only the code written after it, so when you record
  one, sweep the OTHER projects for the same defect at once**, because the instance you just
  fixed is rarely the only one and the rest sit in code that nothing will ever re-examine: the
  rule is consulted while writing something new, never against what already exists.
  (downbeat#336: L108 was recorded from PostRoll, where the Anthropic API key field checked
  only that the value began sk-ant-. Downbeat's copy of that same field checked less than that,
  only that something had been typed, and kept the gap for months until a truncated paste of a
  different credential exposed it by accident)

- **L233. In a list of exclusions or skip cases, an entry carrying no written reason while its
  neighbours each carry one is evidence it was never reasoned about rather than deliberately
  chosen**, so re-derive it from what the list is FOR before trusting it. The reasoned entries
  make the list read as considered in review, and the unexplained one inherits that credibility
  without ever having earned it.
  (claude-config#176: claude-sync's needs_new_session() skipped settings.json outright, beside two
  other skips that each explained themselves. Claude Code reads settings.json only at session
  start, so a pull that registered a brand new hook printed no restart notice and left the hook
  inactive in every open session, while reporting the pull as a plain success)

- **L244. A file that is auto loaded into every session is believed without being re-checked, so
  any status it records (an open question, a pending issue, a not yet done) must be derived from
  the system that owns that truth or carry a check that fails when it drifts.** A question left
  standing after it is answered stops reading as a question and becomes a false claim the next
  session acts on. Distinct from L41, which is about a hand kept mirror drifting: the drift here
  is ordinary and expected, and the harm comes from WHERE it sits, in front of every session
  before anything else runs, so it is trusted rather than looked up.
  (downbeat#411: all nine entries under Open questions in CLAUDE.md were closed issues, and one
  had gone past stale into false, asserting a contrast script had never been run when it had been
  measured the day before. Claude read that line and repeated it to Dan as fact in the same
  session it was found, which is the harm the lesson names)

## Cross-system reliability

- **L512. A process that advances strictly forward and never revisits (a watermark, a cursor, a
  high water mark) needs a targeted redo path built in from the start whenever anything
  downstream requires completeness**, because the first gap is permanent and the only escape
  left is to weaken the completeness requirement itself. The forward-only shape is usually
  correct for the steady state, which is why the missing redo path is invisible until a gap
  exists, and by then the thing that would have fixed it is a feature nobody scheduled.
  (bidspoke#976: the execution archive advances one hour at a time and never goes back, while
  the deletion gate reads a day as unverifiable unless every hour of it was archived, so one
  missed hour holds that day's partition forever and the only sanctioned escape was a human
  release that deletes data with no backup. Numbered by hand at 512 because `next-lesson`
  returned an already-used 511, which is claude-config#164)


- **L240. A background job killed in the same breath it is started can outlive the kill, because
  the signal can arrive before the job has finished starting, and a `wait` on it then blocks for
  that job's whole lifetime while every assertion still passes.** So it reads as a hang rather
  than a failure, and nothing goes red to say otherwise. When you need a pid naming a process
  that has already finished, let a short job exit on its own and wait for that, rather than
  starting a long one and signalling it. Note which way this fails: the run is GREEN, so no
  failure list names it, and the only symptom is a duration nobody is measuring.
  (overture#3125: `sleep 300 & STALE_PID=$!` followed on the very next line by
  `kill "${STALE_PID}"; wait "${STALE_PID}"`, in a fixture that runs in 7 seconds. Measured
  2026-08-22 under the repo's parallel fixture runner: roughly one round in ten took 306
  seconds, every assertion passing. Marks placed either side of those two lines read +1s before
  and +301s after while every other mark in the fixture stayed at +1s, and inserting any command
  between the two lines made it stop happening, which is the race being closed. The first
  diagnosis blamed the stand-in's unredirected stdout, L235's shape, and that was disproved by
  reading the stalled process's open files)

- **L235. A background process inherits the stdout it was started with, so one still running
  holds a `$(...)` capture or a runner's pipe open long after its parent has exited, and the
  caller then waits for the CHILD rather than for the work.** Redirect a background helper's
  output away unless the caller is meant to read it. Two things make this expensive to diagnose:
  the wait presents as a hang in the PARENT, which has already finished, so the investigation
  starts on the wrong process; and any assertion made after the wait can pass for the wrong
  reason, because by then the thing being waited on has expired on its own.
  (overture#3125 was FIRST DIAGNOSED this way and the diagnosis was WRONG, which is worth keeping:
  the stalled process was caught live and its stdout was a regular log file, not a pipe, so
  redirecting would have changed nothing. That stall was L240 instead. What stands here is the
  second case in the same repo the same day, where a `$(...)` capture of a script with an
  unredirected background job stalled for the job's whole sleep and then let an
  is-it-still-alive assertion pass because the job had expired, and `sleep-guard.sh`, which
  documents the trap at its own call site because a capture really did hang on it)

- **L234. A test runner or linter that finds its inputs by a default recursive glob also
  collects every nested checkout inside the repo (an agent worktree, a vendored clone), so name
  the directories your own sources live in rather than trusting the tool's default excludes.**
  Two things go wrong, and neither looks like a failure: the run reports a file count that moves
  with how many agents happen to be running, so the number reads as thorough while being one
  suite counted many times, and a failure from a half finished branch in a worktree is reported
  as the verdict on the change in front of you. An include naming your own directories cannot be
  defeated by a future worktree folder with a different name; an exclude can.
  (overture#3120: `pnpm test` is a bare `vitest run`, whose default include excludes only
  node_modules and dist. Measured 2026-08-22 in the ordinary working checkout: 16 real
  `*.test.ts` files on disk under `src/`, 14 agent worktrees under `.claude/worktrees/`, and
  `Test Files  240 passed (240)`. The sibling runner in the same repo,
  `scripts/run-shell-fixtures.sh`, has the identical exposure and no defect, because it names
  its directories: `find scripts mac/scripts -name '*.test.sh'`)

- **L208. A substitution applied across a whole set of files cannot tell a line that MEANS
  the placeholder from a line that means a value, so any file describing the mechanism has its
  own text rewritten**, and only in the copy that was delivered: the authoring machine's copy
  stays correct, so the damage is invisible exactly where somebody would look for it. A file
  that has to name the placeholder must assemble it from pieces.
  (claude-config#99: the config sync expands its home directory placeholder in every mirrored
  file. A healthcheck running a shell substitution over that placeholder was installed as a
  substitution over a path and reported a scriptPath made of two home directories glued
  together, and two skills shipped a sentence explaining the placeholder that had itself been
  rewritten into a real path. Every one of those files reads correctly in the repository)

- **L245. A script that finds other scripts by searching for a marker phrase will match ITSELF,
  because it has to name the marker in order to search for it, and when the matched list is then
  EXECUTED the result is unbounded recursion rather than a wrong answer.** Exclude the caller in
  the derivation AND refuse re-entry, because the two mistakes look identical right up until one
  of them takes the machine down. The sibling of L208, which is the same self match under a
  SUBSTITUTION and costs a corrupted file; here what is done with the list decides whether the
  cost is an answer nobody can trust or a machine nobody can use.
  (downbeat#417: both halves happened in one afternoon. `test-claude-md-status-claims.sh` matched
  the CLAUDE.md sentence describing what it looks for and accused the issue that built it, which
  was merely wrong. `check-screen-readings.sh` derived its list by grepping scripts for the ones
  needing the app frontmost, its own header says exactly that, so it ran itself: over 300
  processes and a load average of 12 before it was killed by process group, and the test written
  to prove the fix did it a second time by omitting the injected runner and taking the live path.
  claude-config#120 is a third, where a runner found its own suite and recursed until killed by
  hand)

- **L197. A function that returns whether it CLAIMED something (a lock, a slot, a run) is
  only a guard where the caller checks the answer**, and marking that answer discardable
  means the compiler will never say who did not, so the claim reads as protection at every
  call site while protecting only the ones that looked.
  (PostRoll#728: PreviewGraphicsManager.beginDayRegen returns false when a day is already
  rebuilding, and says in its own comment that two runs are two writers on the same MP4. It
  is @discardableResult, and three of the five callers on the caption screen start their run
  regardless, which nothing anywhere reports)

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
- **L226. A timer built by ADDING UP its own sleeps measures iterations, not elapsed time**,
  because every iteration also pays for the processes it starts and for the delay before it is
  scheduled again, and that overhead grows exactly when the machine is loaded, which is when the
  deadline matters most. Anchor to a clock read once at the start and compare against that.
  (claude-config#152: a watchdog counting `waited=$((waited + 2))` once per `sleep 2` did not kill
  a run measured at 1943s of wall clock against its nominal 900s deadline, and the same loop asked
  for 60 seconds ran past 400 under load. Every iteration forks `sleep` and a process check, and
  process launches are what a busy Mac is slowest at, so the deadline silently meant somewhere
  between 900 and several thousand seconds depending on the mood of the machine)
- **L227. A limit cannot be raised on its own**, because any OTHER limit whose safety margin was
  calculated as a multiple of it silently loses that margin, and the sentence recording that
  margin usually stays literally true while describing no headroom at all. Find every number
  derived from the one you are changing, and re-state the ratio as a check rather than as prose.
  (claude-config#160: a test run's ceiling was raised from 15 minutes to 1 hour so a loaded Mac
  would stop being killed as hung. The temp sweep that deletes a running job's own working files
  at 1 hour had been justified in the design record as "4x the longest run the tool permits",
  which became 1x. The record was updated to say "a suite run cannot outlive its own ceiling,
  which is also 1 hour", a true sentence describing zero margin, and it read as reassurance)
- **L519. A repair, backfill or catch-up tool must not take the same exclusion lock as the live
  job it repairs**, because it then displaces that job for as long as it runs, and the only symptom
  is the LIVE job reporting nothing to do, which sends the investigation to the live job's own
  dependencies rather than to the repair. Give the repair its own lock, or lock the unit of work
  rather than the run, and make a repair that stands down SAY so.
  (bidspoke#1027: a backlog walker driving the archive's re-archive route every three minutes for
  three hours took the hourly archiver's run lock on every call, so every hourly run from 19:23 UTC
  answered `skipped-locked` and the live watermark sat at 15:00 while the repair advanced six day
  old days. The standstill alert that eventually fired advised checking Snowflake availability and
  the export credentials, both of which were fine, because the check never read the run outcomes
  that said `skipped-locked` in plain text)
