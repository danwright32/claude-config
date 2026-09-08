# Build-time lessons

Distilled from the 2026-07-27 audit of 3,506 GitHub issues across 9 repos (1,721 carried
a lesson). Apply these by default in every project, alongside the rules in CLAUDE.md.
Full provenance per rule: ~/.claude/audits/2026-07-27-issue-audit/. Numbering is stable
for reference; L6 was reviewed and deliberately not adopted.

## Proof over green

- **L394. In Python a default argument binds ONCE, when the function is defined, so writing a
  collaborator or a path as a default (`def f(run=measure)`, `def f(path=RECORD)`) gives you the
  parameter without the replaceability**: a test that swaps that name on the module is silently
  ignored and the real collaborator runs, which is the whole suite, the real file or the paid
  API. Default it to `None` and resolve inside the body. Distinct from L284, where the seam
  exists and the test forgot to set it, and from L196, where there is no seam at all: here the
  seam exists, the test DID set it, and the setting cannot take effect, so it fails in the
  direction that looks fine.
  (PostRoll#1325, 2026-09-04, twice in one session: `record_test_durations.measure_repeatedly`
  would have run the entire Python suite three times instead of counting the passes a fake was
  asked for, and `check_no_such_account_calibration.observations` read the real fixture while
  the test pointed it at a temporary one. Both were caught by a test that DROVE them, never by
  reading the code)

- **L277. A defect's output can be the only record of a fact the system never stored
  deliberately, so shipping the fix silently removes the evidence the diagnosis was made from.
  Before shipping one, name what the failure was incidentally reporting and record that fact
  directly.** Distinct from L507, which is about a selection whose members were never recorded at
  all: here they WERE recorded, by accident, in the wrong place, and the repair is what deletes
  them. (PostRoll#962, #972: a blog post is written around seven photos subsampled from the twelve
  assigned, and which seven is discarded. It was recoverable only because a filename bug reported
  every unplaced photo by its true on-disk name, which is how the fix was verified at all; the fix
  stops those findings firing, and with them the only trace of the choice. Re-deriving the seven
  from the stored list gave a different seven, so the stored list cannot answer for it either)

- **L284. A test that sets some of a script's seams runs every unset collaborator for real, and
  the real ones are the slow and the dangerous ones, so enumerate every seam the script honours
  beside the test and assert each is either set once for the whole suite or deliberately left real
  by a section that tests it.** A seam that exists is not a seam that is set: the test author
  stubs the collaborators they were thinking about, and the one they were not stays live, where it
  is both the time (a real process list walk, a real registration dump) and the write nobody
  authorised (L2, L52, L196). The check is mechanical: list the seams the script reads, list the
  ones the test sets, and refuse the difference.
  (claude-config#220, 2026-08-29: 65 of 343 tool invocations in the sync suite carry no
  SYNC_NO_NOTIFY on a Mac where the notifier is installed, found clean only by sampling; the same
  audit's Downbeat installer test stubbed the build, codesign and open and forgot the LaunchServices
  cleanup, so eleven runs per push unregistered bundles from the live database.)

- **L524. Any retry, backoff or poll delay takes an injectable sleep or clock from the day it is
  written, because a hard-coded setTimeout forces every end-to-end test that crosses it to wait
  for real.** A test that records the delays the code asked for is both instant and stronger than
  one that survives them: it asserts the schedule (500 then 1000) rather than the fact of a wait,
  and it cannot become the suite's slowest test or its first flake under load. Retrofitting the
  seam works, but building it in means never paying the tax.
  (bidspoke#1063, 2026-08-29: the three slowest tests in the worker suite each sat at exactly
  1,500ms, the engine's default backoff lived through for real, because engine/retry.ts sleeps
  through a private setTimeout with no seam; the retry tests that call withRetry directly already
  used fake timers, the three that go through the engine could not. PET carries about 11 seconds
  of the same shape for the same reason; Slate carries none because every retry path there takes
  a clock.)

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
- **L557. A monitor or validator that has never once PASSED is not measuring anything,
  because every failure it reports reads as a finding about the data rather than about
  itself. Record its outcomes so a lifetime success count of zero is detectable, and treat
  that as the check being broken.** L1 is the mirror image and does not cover this
  direction: a guard seen to fail is calibrated against the defect, and one never seen to
  pass is calibrated against nothing. The archive deletion gate's payload probe failed on
  all 16 days it ever measured, from the day it shipped, always with the same message
  naming a real execution id, and each alert was read as a claim that production data was
  missing. The cause was in the Snowflake client, which returned only the first partition
  of a large result, so the probe asked for 60 bundles, received a prefix, and reported the
  rest as absent. Nothing said the check had never succeeded, and the evidence was sitting
  in the check's own stored rows the whole time (`probe_ok` false on every one), so it was
  queryable from day two and was instead found on day 16 by a person reading Slack.
  (bidspoke#986, bidspoke#1126)
- **L584. Data archived as a serialized bundle (a gzipped payload in one column, an object in
  a blob store) is recoverable one record at a time and cannot be aggregated, so reaching the
  warehouse is not the same as being analysable.** Before concluding a value is available for
  analysis, confirm it is stored as its own column rather than inside a bundle, because the
  archive's existence is what everyone cites and its shape is what nobody checks. The two
  purposes pull opposite ways: a bundle is the cheap, faithful, schema-free way to make a
  record RECOVERABLE, and it is the one form no query can group by.
  (bidspoke#1158: the execution archive ships every step's output to Snowflake, so the rate
  quoted to each lead's source was described as already in the warehouse. It is in
  bundle_gz_b64, one gzipped blob per execution, so no query could total it over any period,
  and a column had to be added anyway)
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
- **L439. A variable one test EXPORTS is inherited by every later test's subprocesses, so a
  fixture that is correct on its own silently changes what the code under test BELIEVES in
  every test after it, and the symptom surfaces far away with nothing naming the cause.**
  Export only from the shared setup, and have a test that must set one set it back.
  (claude-config#341. A section of the sync suite exported a GitHub repository name at top
  level, for its own fixtures. Every section after it in the same worker then handed that
  name to every invocation of the tool, so ordinary fixtures believed they were a repository
  that is not this one. It sat harmless until a CI verdict lookup landed on the path every
  mutating run takes, at which point those fixtures began asking the operator's real
  authenticated GitHub CLI about it: the suite went from 190 to 351 seconds and twenty nine
  timing sensitive checks failed, not one of them anywhere near the section responsible, and
  none of them naming CI at all)

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

- **L322. Isolation set through an ENVIRONMENT VARIABLE is only real if the tool being isolated
  actually honours it, so measure where the writes LAND rather than trusting the variable.** A tool
  that ignores it sends the work somewhere else entirely, and any guard inspecting the isolated
  location then reports clean while seeing none of its subjects, which is worse than no guard because
  everyone believes it. The guard's own test is no help: it is usually written with a subject shaped
  so the rule fires (L48), which is exactly the shape that honours the variable.
  (overture#3249, measured 2026-08-30. macOS `mktemp` ignores `TMPDIR` unless the path is spelled out:
  `TMPDIR=$H mktemp -d` and even `TMPDIR=$H mktemp -d -t probe` land in the real shared folder, only
  `mktemp -d "$TMPDIR/tpl.XXXXXX"` lands in $H. The fixture runner scoped `TMPDIR` per fixture and then
  inspected that directory for leftovers, so the 56 of 81 fixtures using the bare form were invisible
  to it, on every path. Giving the check its sight back exposed three real leaks that had each been
  running once per run for months. The issue's own proposed remedy, scoping `TMPDIR` on source, would
  have shipped a no-op for the same reason)

- **L323. A duration compared against its own history measures the SYSTEM only while the
  workload is constant, so a job whose cost varies with its input must be divided by a measure of
  that input before any trend is read from it.** Otherwise a quiet week is indistinguishable from a
  real improvement and a busy one from a regression, and the reading is delivered with exactly the
  same confidence either way, so it is believed. This is distinct from the runner measuring itself
  (L294) and from comparing against a fixed number (L224): here the machine and the code are both
  steady, and it is the WORK ARRIVING that moved.
  (postroll#1041, measured 2026-08-30. A duration series comparing each CI job's recent half against
  its older half reported the per-PR guard job as having gone from 227s to 50s, a 78% improvement,
  and that was used to argue an open sharding issue was obsolete. That job proves only the registry
  entries a diff touches. Reading all 21 successful runs instead gave median 181s, p90 501s against
  the 154s and 450s recorded in the issue: it had got slightly SLOWER, and the recent window merely
  held small pull requests. The tool had shipped less than an hour earlier and was built to judge two
  other performance issues, either of which it would have mis-attributed the same way)

- **L3. Built is not wired, and wired is not proven.** Prove every guard, integration,
  and gate actually executes in the shipping runtime, and wire the CI gate the day the
  first test lands. (45 issues, 8 repos)
- **L4. A merged fix is not a deployed fix.** Verify the change is live where it ships:
  migration applied in production, the live site serving the new commit, behavior
  confirmed in a production build. CI must exercise the artifact production actually
  runs. (20 issues, 5 repos)
- **L581. A merge or conflict resolution that writes its result to the LOCAL copy must read
  back the SHARED copy and confirm the merged entries are there before reporting success,
  because a merge that resolved correctly and a merge that also propagated produce the
  identical message.** A reconcile on one Mac merged LESSONS.md, printed "nothing was dropped"
  and "sent local changes", and both were true about the live copy at 472 lessons while the
  committed copy held 468: L575 to L578 existed on that machine alone, so the other Mac would
  never have received them and an overwrite of the live file would have destroyed them. The
  derived index made it plainer by sitting in three states at once, 463 committed, 468
  uncommitted, 472 live. Entries that exist on one side only are by definition the ones nobody
  is looking at, so compare in the unit the meaning lives in (the identifiers, not whole lines)
  and refuse the success line until the shared side answers. (claude-config#312)
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
- **L420. Two artefacts describing ONE run (its results and its logs, an artifact and its
  metadata) must be paired by the run's own identifier, never by each being the newest of its
  kind in its own directory**, because the store holds several runs and a mismatched pair
  produces a confident number that is pure artefact and reads as a finding. Pairing a check
  run's results with another run's event streams reported "83 of 83 named people never had
  their own site looked up", which was caught only by comparing the two files' session ids;
  the correctly paired run read 0 of 9.
  (overture#3345)
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
- **L345. A guard that can REFUSE a reading must not draw on the same source as the reading
  itself, because the guard then falls silent exactly when that source fails and the unrefused
  reading is at its least trustworthy.** Give it an independent second signal, or the failure it
  exists for is the one case it cannot see. The shape is a validity check that reads the same file,
  response or API as the data it judges: it looks like defence in depth and is a single point of
  failure wearing two hats.
  (overture#3385, 2026-08-31: a check added so a truncated test run would state no size and name the
  test that killed it read the run's result bundle, and the count it would have refused fell back to
  the same bundle. On the first real truncated run after it shipped the bundle could not be read, so
  the check said nothing and the readout printed 5,035 tests of 8,643 as an ordinary size. The
  separate short-run gate, which reads a different source, caught it.)
- **L561. A record written so that a failure can be RECOVERED from must be written by a
  DIFFERENT operation than the one that fails**, because a projection, checkpoint or breadcrumb
  riding inside the failing write is absent from precisely the cases it exists for, while its
  presence on every healthy run makes it look like it works. The write-side twin of L345: there a
  guard reads the same source as the reading it judges, here a safeguard shares a transaction with
  the thing it is meant to outlive.
  (bidspoke#1132, 2026-09-03: buildSightingFinalizeProjection's own docstring called it "the write
  that survives isolate eviction" and said the strand drain reconstructs a stranded outcome from it
  "with full fidelity", but it was set as one field of the finalize UPDATE, which is the write
  eviction destroys. Measured across 119 stranded rows over 14 days, it was null on every single
  one, and the drain had to fall back to lead_sightings, written independently at the trigger
  boundary.)
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
- **L572. A limit that governs an operation already under way cannot be set from INSIDE that
  operation, because the mechanism enforcing it was armed when the operation began and read the
  value at that moment, so the assignment silently applies only to the next one.** Set such a
  bound before the work starts, and prove it fires by exceeding it deliberately. This is not
  L188, where something downstream overwrites the value: here nothing overwrites anything, the
  assignment simply lands too late, and the inert line leaves the safe number sitting in the
  source where every reader takes it for protection.
  (bidspoke#1147, probed both ways 2026-09-04. A pg_cron rollup was being killed at the cluster
  default statement_timeout of 120s, and the obvious fix was a SET LOCAL statement_timeout inside
  the refresh function. A probe function setting it to 1s and then sleeping 3s slept the full 3s;
  the same pair written as two separate statements cancelled at 1s. The budget went into the cron
  command instead, and the guard asserts the PLACEMENT rather than that the setting appears
  somewhere, because a grep for the setting cannot tell the working form from the inert one)
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
- **L362. An exemption written as ONE NAMED CASE rather than as the reason for exempting stops
  covering the moment a second case satisfies that reason, and where the exemption exists to keep a
  REMEDY reachable the result is a deadlock: the tool refuses while naming a condition only that
  tool could clear. Write the condition as the reason, and hold the list of names to it with a
  test.** The mirror of L324, and it fails in the opposite direction: too broad switches the guard
  off silently, too narrow switches the REMEDY off loudly, and the loud version is worse to be
  caught by because it arrives while somebody is already blocked. The tell is an exemption spelled
  as a single constant naming one file or one check, where the comment beside it describes a class
  ("the guards that read this record"). (PostRoll#1165, measured 2026-09-01: the test duration
  recorder refuses to write from a red suite, exempting the guard that goes red precisely when the
  record is stale. Two guards do that, only one was named, so adding any new test file deadlocked
  the tool through two full suite runs, each time refusing over a failure nothing but the tool
  could clear)

- **L324. A guard's STAND DOWN condition must be no broader than the reason for standing down, because
  the broader form silently disables it in cases nobody meant to exempt, and those are the runs least
  like the ones it was tested on.** Write the condition as the exemption itself (this run was
  deliberately narrowed) rather than as a proxy for it (this run was given any argument at all). The
  failure is invisible from both sides: the guard's own tests pass, because they exercise the case it
  was written for, and the exempted runs look ordinary, because a guard that says nothing and a guard
  that is switched off are the same silence.
  (overture#3264, measured 2026-08-30. A short-run gate compared each test run against the last green
  one and refused a materially short one, standing down for a deliberately scoped run by asking whether
  ANY argument had been passed. Every parallel-testing experiment passed a flag, so every one ran with
  the gate off: one executed 5,217 tests against a baseline of 8,618, lost an entire worker's share with
  no crash line anywhere, and printed an ordinary verdict. The same thing had already happened silently
  to an earlier experiment nobody re-examined)

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

- **L398. A gate that decides whether a subject passes must read its criteria from the SAME
  revision it is judging, never from the checkout the gate happens to run in, because the two drift
  with no symptom and a criteria list short by one entry is a requirement nobody is waiting on.**
  Distinct from L179, which is about the ANSWER being scoped to the right revision: this tool was
  already compliant with that, asking only about runs at the head commit, and the defect was that
  the QUESTION came from somewhere else. Anywhere a gate's rules live in the repository it inspects
  (a required checks list, a lint config, a schema, an allowlist), the rules and the subject are two
  reads that can name different revisions, and the failure is silent in the direction that matters:
  a short list is a check nobody waits for.
  (2026-09-04, PostRoll#1342: `tools/wait_for_checks.py` derives the checks a pull request must
  clear by reading `.github/workflows/*.yml` out of its own working directory. Run from a checkout
  sitting on another branch, it derived 7 checks for a pull request that reported 8, because that
  pull request had added a job. The missing one was a real check it would not have waited for)

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

- **L331. A measurement written into a store that later DECIDES something (a launch order, a
  shard balance, a retry budget) must record whether the run it came from actually did the
  work, because a run that refused, was locked out or died early reports a real and very small
  number, and nothing downstream can tell that from a genuinely fast one.** The store holds
  only the number, so one moment of overlap governs every run afterwards, and the line saying
  how the order was decided counts the poisoned record as a measurement like any other.
  (claude-config#229: the suite timing store held 0 for tests/test-claude-sync.sh, measured at
  231 seconds in the same session and the slowest of 44 by a factor of four, because that suite
  exits at once when it refuses its own lock. The launch order put it 41st of 44, so the slowest
  suite ran last on the smallest share of the budget while the runner reported "launch order
  from measured wall clock for 44 of 44 suite(s)")

- **L289. A fast path that falls back to doing the work when it cannot read its own record
  (a cache, a memo, a skip if unchanged gate) fails SILENTLY, because the fallback is
  correct and merely slower, so every test stays green while the saving quietly stops
  happening.** Any change to that record's format needs a test asserting the fast path
  still FIRES, not merely that the work still passes. (downbeat#471: adding a test count as
  a third field to the green suite memo broke the reader, which used `read -r fingerprint
  stored_at` and so absorbed "1788042511 3281" into the timestamp and rejected it as
  corrupt; every push then re-ran a full suite it had just been told was green, which is
  the exact cost the memo exists to avoid, and it was inside the milestone whose whole
  subject was what a push waits for. The memo file was present, the fingerprint matched and
  could be shown to match by hand, the count was recorded correctly, all 43 guard scripts
  passed and the suite was green. It was found only by asking why the gate said it was
  running the suite on a push where nothing had changed)

- **L361. A filter that EXCLUDES content by testing a property of its whole container (a
  paragraph that starts with a marker, a block beginning with a comment character) fails in
  both directions as soon as one container mixes excluded and wanted content: the excluded
  thing leaks in wherever it is not first, and the wanted thing is discarded with it wherever
  it is. Strip the excluded elements from inside the container rather than judging the
  container by its start.** Both directions are silent. The leak makes a rule report on text
  nobody wrote, and the discard makes a rule report on nothing at all while still reading as
  a rule that ran (L98). Distinct from L104, which is about a filter's PATTERN matching too
  much, and from L278, which is about a COMPARISON judged in the wrong unit; this is about an
  exclusion applied at the wrong granularity. (PostRoll#1163: `_prose_paragraphs` dropped a
  paragraph only when the whole block started with `[PHOTO:`, so a marker at the end of a
  paragraph carried its filename digits into every prose rule. The invented number check then
  reported `-189.jpg` and `-330.jpg` as invented counts in Dan's prose, 8 of that check's 32
  firings across the 21 stored posts, every one a false positive)

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
- **L535. Code behind a flag that shipped OFF has never run, so turning it on is shipping
  untested code, and its ERROR paths are the least exercised part of it because the observe
  phase existed precisely to stop them executing.** Audit the disabled half as NEW code at the
  flip, and check in particular that it handles failure the way its already live siblings do.
  Distinct from L142, which is about drawing the observe/enforce boundary in the wrong place:
  here the boundary was drawn CORRECTLY, along blast radius, and the gap is a consequence of
  doing that right, because the half you deferred is the half with no production history.
  (project-enrollment-tracker#1196: promotion writing shipped observe only on 2026-08-14 and
  was turned on 2026-09-01. The write loop it enabled had sat in the repo for three weeks
  looking reviewed and had never once executed, and it was the only write in that script with
  no try/catch, so a transient failure would abort the whole morning sync including the team
  registry write and the Slack summary. Every sibling write recorded its failure and carried
  on. Nothing caught it in review because the code read as existing rather than as new.)
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

- **L401. A fixture whose meaning is its relationship to a CONFIGURABLE threshold (a lead time window,
  a cap, a retention period, a rate limit) must be DERIVED from that threshold rather than written as a
  literal chosen to sit at its edge, because pinning both ends of the fixture does not help when the
  third party to the relationship is a constant somebody can change: the day it moves, the fixture
  silently stands for a different case.** This is L130's blind spot rather than a restatement of it.
  L130's remedy, pin both ends, was correctly applied in every one of the cases below and did not help,
  because both ends were pinned to each other and neither was pinned to the number that actually
  decided the verdict. The failure is worst where a test SKIPS a subject it cannot place: eight suites
  went red when a queue's lead time window went from 90 days to nine weeks, which is the safe
  direction, while a ninth had a `guard let stage else { continue }` and would have gone green having
  quietly covered fewer states. Where the fixture cannot be derived, assert the relationship instead,
  so the next move of the constant fails loudly rather than hollowing the test out.
  (overture#3546, overture#3423: the ninth was the guard that exists to prove every stage is reachable
  from a pill, after a real incident where an approved draft vanished from every view its owner used)

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

- **L551. A precise branch added beside an HONEST fallback is invisible when it never fires,
  because the fallback's label is truthful and reads as the system working rather than as a
  signal that never matched**, so measure the ratio between the two branches on real data
  before treating the precise one as live. Distinct from L506, where the branch is dead
  because an external field is absent; here every input is internal and the branch is simply
  never satisfied, and the conservative label beside it is what removes any reason to look.
  (bidspoke#1112: the stranded-execution drain claims 'completed' only when the last completed
  step lands on a graph dead end (#571), and otherwise labels the row honestly as "outcome
  could not be confirmed". Over 14 days all 117 recovered rows took the honest fallback, none
  took the dead-end branch and none took the failed-step branch, so a signal shipped as the
  precise one has never once fired in production, while the authoritative outcome sat unread
  in lead_sightings the whole time)

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

- **L430. A test that has started failing because the code moved underneath it is a claim that one of
  the two is wrong, and deleting or rewriting it to match the code silently rules that the code is
  right. Before doing either, find the decision that test was written to defend and confirm it was
  actually reversed, because a behaviour lost by accident and one removed on purpose produce the
  identical red.**
  (overture#3639, overture#3642: #133 gave a cancelled show two behaviours, hide it if Dan never
  triaged it, strike it through if he was pursuing it. The hiding half was enforced in
  `QueueModel.queueOrder`. #1567 moved queue membership to `StageNavigation`, which does not ask that
  question, so the hiding stopped happening with no error and no red anywhere except the one test
  asserting it. #2348 then deleted that test and wrote a comment recording the NEW answer as what
  Overture does, citing the live behaviour as the authority. Both steps read as tidying: the test
  genuinely was asserting something untrue of the code. What nobody asked was whether the code had
  become wrong. Dan saw the result on 2026-09-07, two struck-through cards asking him to triage shows
  the app already believed were cancelled, and said they should not be there, which is what #133 had
  built and #1567 had removed. This is the INVERSE of L252, and the two are easy to confuse: there,
  somebody deliberately reversed a rule and the old tests had to be hunted down; here nobody reversed
  anything, and the deletion is what performed the reversal. The tell is that the test is older than
  the change that made it fail and nothing in that change's history mentions the rule)

- **L253. A detector whose signature is a small TIME GAP between two stored instants is answered by
  any single write that stamps both from one clock variable, so the gap measures the WRITE rather
  than the events, and such a row must be told apart by evidence of that write (a third field
  carrying the same instant) rather than by treating the suspicious value as noise.**
  (overture#3171: an invariant looked for an answer recorded within 90 seconds of the message it
  answers, which is what an autoresponder stamping "Dan answered" looks like. It found one row on the
  live store with a gap of exactly 0.0 seconds. The attach path writes `conversationAttachedAt`,
  `repliedAt` and `replyHandledAt` from a single `now`, so a conversation Dan answered in Gmail and
  then attached has those instants equal by construction, and its gap is arithmetic rather than a
  measurement of anything. The trap in the obvious remedy: excluding a gap of zero as "too round to
  be real" would have blinded the rule to the fastest possible autoresponder, which is the worst case
  it exists for, so the exclusion has to key on the third field proving one write happened. Related to
  L203, which is the same coincidence read the other way round: there, near simultaneous events in a
  log read as a mechanism; here, one write reads as two events)

- **L254. A control whose press only RECORDS a request, while the work happens later in a shared
  batch, must not have its progress timed from the press against a window sized for the work,
  because that window then spans a queue wait the control does not govern and accuses a healthy
  run of being stuck.**
  (overture#3186: a card's "Check again" button sets a flag and nothing else; the research arrives
  from the next batch run, which can carry any number of shows and may not start for a while. The
  row's spinner counted from the press against a flat ten minutes drawn from what one lookup costs,
  so the clock covered three different things at once: the wait for a run to start, the depth of
  whatever run picked it up, and the lookup itself. The sibling surface had just been fixed to scale
  its window with the run's depth, and this one was explicitly scoped OUT on the reasoning that a
  row's re-check is one lookup, which reads as obviously true and is about the REQUEST rather than
  about the work. The tell is that the control cannot name the run it is waiting for. Related to
  L106, which is the same confusion the other way round: there a live signal proves only its emitter
  is alive, here an elapsed clock is read as proof of what the work is doing)

- **L257. A check that decides whether a value is VALID by listing the values that are NOT valid
  (a sentinel blacklist, a set of known placeholders) admits every malformed value nobody thought
  to list, and because it is named for the question it appears to answer, every call site treats
  it as real validation.** Judge the value against the SHAPE its consumer can actually parse
  instead, so an unlisted bad value is refused where it is entered rather than carried onward.
  Related to L150, which catches a writer LOOSER than its reader; this catches the looseness
  hiding inside something that reads as a validator. (postroll#899: `isRealHandle` rejected only
  `unknown`, `n/a`, `na`, `none`, `-`, `no` and `skip`, so a dance company whose Instagram handle
  field held its own name, `DPR Dance`, passed as a real handle at all eight call sites across five files, went into
  the caption prompt as a handle to mention, and was written into a caption bound for Instagram
  where `@DPR` resolves to a stranger. The credit checker's own regex, `@[A-Za-z0-9._]+`, is the
  shape that should have been asked for, and it then reported the pipeline's own bad value as a
  handle the model had invented)

- **L278. A check that decides whether content was LOST by comparing whole LINES is defeated by
  reformatting, because re-wrapping a paragraph changes every line boundary while losing no words,
  so compare in the unit the meaning lives in (words, or a whitespace collapsed body) rather than
  the unit the file happens to be stored in.** The failure is a FALSE loss, which is the expensive
  direction here: the report goes on naming files that need no action, and a warning that fires on
  files needing nothing trains the reader to skim the one case that matters (L36). Distinct from
  L251, which is about a substitution PRODUCING wrapped text; this is about a comparison JUDGING
  it. (claude-config#212: the unresolved conflict report kept insisting a set aside copy of
  `test-pipefail-shortcircuit.sh` held 4 lines found in no loaded file, and all four sentences were
  present verbatim in the live header, merely wrapped across different line breaks. That report is
  the only thing anywhere that names content surviving in no file the tool loads, and its own
  comment records a lesson that survived only because somebody read it once)

- **L288. A test run is judged first by the count it EXECUTED against the count expected, and only
  then by its failures, because a run that loses a worker's share or matches half a selection still
  prints a verdict, and a check for zero catches none of it. Record the expected count, refuse a run
  below it, and do that BEFORE any change to how the suite runs (parallel workers, sharding, a new
  scheme or reporter), which is the moment the half run appears.** The failures are the visible
  half of a run and the absences are the half that matters (L98, L11): nothing in a summary naming
  twelve failures says three thousand tests never ran. A zero check is the special case that is
  easy to write and does not generalise, because the runs that lose part of a suite are exactly the
  ones that changed how the suite is divided. (postroll#1017: `suite_counts.py` refuses a leg that
  ran zero tests and passes one that ran half, and the CI Swift step never reads a count at all,
  in the same milestone that queues a switch to parallel execution. overture#3233: the parallel
  experiment executed 4,875 of 8,595 tests with no crash line and reported twelve failures; the
  baseline gate built for this could not parse the new format and said so in a line nobody read.
  Found by the 2026-08-29 test speed audit across nine repos)

- **L320. A tool that takes a target as an argument must REFUSE one it cannot use, never fall back
  to its default scope, because a silently ignored target makes a run about everything look exactly
  like a run about the one thing that was asked for.** The output is full of real passing work, so
  nothing on screen says the question was changed, and the reader takes the verdict as being about
  their target. It has bitten in both directions: an argument DROPPED, and an argument FORWARDED to
  an inner command that did not understand it either.
  (Overture#3245, 2026-08-29: `run-shell-fixtures.sh` globs its own list and ignores its arguments,
  so a run asked for one fixture ran all 81 and reported on them; earlier, Overture#2993, `mutate.sh`
  passed a misplaced `--at` through as a test scope, xcodebuild rejected it as an unknown option and
  ran the PURE suite instead, so a targeted proof became a full-suite run with the aim check off)

- **L329. A tool that scans a file for matching lines stops printing them and reports only that
  the file MATCHED once that file contains a byte it treats as binary**, and build and test logs
  routinely carry such bytes, so any list built by parsing that output comes back EMPTY while the
  scan itself still reports success, and the empty list then reads as a genuine negative answer.
  (overture#3288: `mutation_scope_reached_file` reads which test suites executed by grepping a
  `run-tests-locked.sh` log with `grep -oE 'Suite "[^"]+" (started|passed|failed)'`. xcodebuild
  writes NUL bytes into that log, measured at 88 in a 119KB log from one scoped run, so grep
  printed `Binary file ... matches` instead of the suite lines, the executed-suite list was
  empty, every membership test failed, and mutate.sh refused a scope that had in fact run the
  right suite. The verdict it owed was SURVIVED, a real finding about the code, and what it
  printed was SCOPE MISSED THE FILE, which reads as the operator having typed the command wrong,
  so the response it invites is to re-run rather than to read the finding. Believed and reported
  onward as fact, caught only by opening the log by hand. Reads that consume only an EXIT STATUS
  are unaffected, which is why the same script's `grep -q` calls were fine and only the `-o` ones
  lied. L184 says judge a command by its exit code rather than a line of its output and is the
  opposite case, since here the output IS the answer being sought; the remedy is to read such a
  file as text explicitly, `grep -a`)

- **L336. A check satisfied by PROOF that it already passed never runs again, so it can
  only catch a change in its inputs and never drift in what it depends on (a date, seeded
  data, an upstream image, a dependency resolved at run time).** Anything that can start
  failing with no input change needs a scheduled run that ignores the proof.
  (nursedexapp/nursedex#843, 2026-08-30: a merge to main proves the merged tree is the tree
  the pull request already tested and skips the end to end suite, taking it from 8m50s to
  20s, which is correct for catching bad code. The reveal spec then passed at 18:50 and
  failed on all three attempts from 19:31 with no application code merged in between, and
  nothing reported it: main never runs the suite, so the only two runs that surfaced it were
  incidental pull requests opened for unrelated reasons. Distinct from L289, which is a fast
  path silently FAILING and doing the work anyway; this is one silently SUCCEEDING and the
  work never being done again)

- **L528. A detector that reads production counters also reads whatever your own smoke canary
  or synthetic monitor writes into them, so check whether the canary ALONE can satisfy its
  floor before trusting any verdict it reaches.** A threshold sitting near the canary's own per
  run volume makes the detector conclude on the canary's schedule rather than on customer
  behaviour, and that conclusion then reads as evidence about production.
  (Try-Pennie/slate#1616, 2026-08-31: the booking failure rate check needs 20 attempts in a
  rolling hour, and every attempt Slate has before cutover is the canary's. One full canary pass
  records exactly 16 of them inside about two minutes, four short of the floor, so a pass never
  concludes; but the canary runs four or five times a day and two drifting inside one hour clear
  the floor between them. That happened once, and it was the ONLY verdict the detector ever
  reached. A page then fired asking for the detector to be armed because the reason it was parked
  had "stopped being true", which is what the arrival of real customers was supposed to look
  like, and it repeated daily over a detector that concluded nothing for the next two and a half
  days. The measured share was 100 percent synthetic and its only failure was a reschedule
  conflict the canary raises on purpose. Related to L172, which says measure where a threshold
  lands in the real distribution: here the whole distribution was the harness, so there was no
  real one to land in and the threshold had been fitted to nothing at all)

- **L347. A test that asserts a message does not use a forbidden WORD does not assert that it
  does not make the forbidden CLAIM**, because any synonym passes it, so check the claim the
  sentence makes against what the code actually measured rather than listing the vocabulary you
  do not want.
  (PostRoll#1111: #925 was explicit that the sweep may only say a day was EXPORTED, never that it
  was posted, because the app records a write into a folder and cannot know it reached Instagram.
  The test asserted that the words "posted" and "published" were absent, and passed, over a
  sentence reading "rebuilding it would not change anything that has gone out", which is the same
  claim in different words. Dan's own filing proves the two differ: he keeps a folder called
  "Done: Waiting to post", so a day can be exported and still not have gone anywhere, and for
  those days the sentence was false and the conclusion it drew was backwards)
- **L348. A build or compile check aimed at ONE target of a multi target project says nothing about the
  others**, so a sweep asking whether the tree still compiles has to build every target that holds the
  code it changed, or name in its own output which target it asked, because the whole purpose of a
  narrow target is that a fault elsewhere cannot fail it.
  (overture#3386, 2026-08-31: to answer whether the test suite's `@MainActor` annotations were needed, a
  script stripped all 504 of them, built, restored every file the compiler named, and repeated until it
  built clean. It built the `OvertureCore` scheme, which exists precisely so a broken app cannot fail it
  and which does not compile the hosted test target at all. The answer it produced was "41 of 461 files
  can drop it". Building the full scheme over that same 41 file strip rejected all 41: the real answer is
  ZERO, and every file it cleared was in the target the scheme never touched. The wrong number was
  already written into the issue as a measured finding before the full build was run)

- **L350. An optimisation that lets work be SKIPPED also removes that work's observations from
  every instrument whose rate is computed over them, so the sample shrinks as the optimisation
  succeeds and a threshold calibrated on the old sample turns into noise while still reading as a
  measurement.** When adding a skip, count what still reports and re-measure any threshold judged
  over it, because the instrument goes on printing a percentage either way.
  (nursedex#818 and nursedex#859, 2026-09-01: the CI health counter judges the Playwright flake
  rate over the last 20 E2E runs. Measured that day, only 10 of the 20 reported at all and only 7
  were push runs, because nursedex#812's merged tree proof lets a main run satisfy itself without
  running the suite. The verdict came back 4 of 10, exactly the 40% threshold, so one flake either
  way decided it, and the four bad runs it was counting were a single fixed defect.)

- **L352. A validator that compares a step's output against the PREVIOUS step's output can only
  see damage that step did, so anything broken before it becomes the baseline every later guard
  defends as correct.** Chain every guard in a rewrite pipeline back to the ORIGINAL, and guard the
  first step too, because the step doing the most rewriting is usually the one nobody wrapped.
  (postroll#1140, 2026-08-31: a blog revision makes three model calls. The two review passes both
  carry markers_preserved_validator and both compare against `data`, which is already the output of
  the first call, and that first call, the one whose whole job is rewriting the body, has no
  validator at all. So a photograph renamed, dropped or reordered by pass one is the baseline passes
  two and three are held to, and the post ships one picture short with nothing red and nothing
  printed. Adjacent to L84, which is this shape for a recorded expectation, and to L280, which is a
  rule enforced at one stage being undone at a later one.)

- **L353. A comment estimating that some work is small enough to run somewhere costly (briefly on
  the UI thread, inside a lock, in a request handler, on the hot path) is a measurement nobody took,
  and it licenses the same choice at every later call site, so name the quantity the cost scales with
  and what bounds it, because the costs that grow with usage are exactly the ones that read as small
  on the day they are written.** The tell is a comment that concedes the cost and then dismisses it
  in the same sentence, since conceding it is what makes it look considered. Distinct from L107,
  where a number justifying a decision WAS measured but by a second definition written beside the
  code, and from L102, where it was measured with the expensive path switched off: here nothing was
  measured at all, and the sentence is doing the work a measurement would have done. Distinct from
  L316, which is a premise that expires: this one can be false on the day it is written.
  (overture#3419, 2026-08-31: `RootView.syncOmniFocus` runs a synchronous AppleScript call to
  OmniFocus on the main actor under the comment "The work is a handful of Apple events, so the brief
  main-actor occupancy is acceptable". It is one Apple event per completed OmniFocus task, over a set
  nothing prunes, so it grows every time Dan ticks one off. Sampled live during a freeze Dan reported,
  2,646 of 2,646 samples over three seconds were inside that call and the freeze lasted minutes. The
  same sentence, alongside an unverified "NSAppleScript must run on the main thread", is why a SECOND
  call site was written the same way in `ReconcileScheduler.syncOmniFocus`, which is the one that
  froze: the comment read as a considered decision, so the pattern was copied rather than questioned.
  Note the shared function underneath both, `OmniFocusSync.apply`, carries a comment saying it takes
  value types "so it can run off the main actor", which is L3: neither caller ever did.)

- **L354. A fixture sized by a number measured once from real data silently under-represents
  production as that data grows, and it fails in the GREEN direction, so a cost or scale guard goes
  on passing while protecting a smaller world than the one that ships.** Derive the size from a
  measurement something refreshes, or guard the hardcoded figure against the real count. Measured
  2026-08-31 (overture#3426): the two tests guarding the cost of a queue rebuild were sized 724 and
  893, each correct against the live store when written, while that store had grown to 1,140 and
  grows every scout run. Nothing reported it, because a guard exercising a smaller corpus than
  production cannot fail for being too small. It compounds wherever any part of the work is
  superlinear in the count, since the gap in cost is then worse than the gap in rows. L48 requires
  the fixture to be MEASURED from real data; this is that measurement expiring afterwards.

- **L355. A sampled profile shows the SHAPE of one stack, and only becomes a measurement of COST
  once the sample count is read, so a stack seen a handful of times cannot support a claim about
  where the time went.** Read the instrument's depth before quoting its output, because eleven
  samples and eleven thousand render as the same picture. Measured 2026-08-31 (overture#3425): a
  macOS `.hang` report was read as proof the main thread was "pinned" in a queue rebuild, and the
  whole subtree it was attributed to weighed 3 samples out of 11, taken over 1.1 seconds at the end
  of a 58 second freeze. The same session's live `sample` runs, at 1ms over 2,446 and 2,580 samples,
  did support that kind of claim, so the fault was not the method but quoting a detection instrument
  as if it were a measurement one. State the sample count beside any figure taken from a profile.

- **L356. A performance measurement taken on the machine that also builds and tests the product
  measures both, so record what else was running at the moment of the reading rather than filtering
  it out afterwards.** A contaminated sample is indistinguishable from a real regression, and work
  done to "fix" one can never be shown to have worked. Measured 2026-08-31 (overture#3442): a 58
  second application freeze carried frames from six concurrently running xctest processes, because
  the app under test sits in the menu bar all day on the Mac whose mandatory pre-push gate runs the
  whole Swift suite from several worktrees. The load was invisible in every summary of the freeze
  and was found only by reading the raw report. This is L294 pointed the other way: that one is the
  test suite mismeasured on a loaded runner, this one is the product mismeasured beside its own
  suite.

- **L537. A "how far behind" reading computed as the newest item minus the last processed one
  measures the interval between the two most recent items, not elapsed delay, so on a sparse
  stream an item seconds old reads as hours behind and a genuinely stalled lane is
  indistinguishable from a healthy one.** Measure a backlog's age against the CLOCK, as now minus
  the oldest unprocessed item's stamp, and read a large lag standing beside a tiny backlog as
  evidence the metric is wrong rather than the lane. Measured 2026-09-02 (slate#1713): Slate's PII
  retention lanes refuse to delete unless the Snowflake export lane is current, and the gate
  computed lag as `newestTs - cursorTs`. A time off request written at 02:53:14 UTC, with the
  previous audit row at 00:11:36, scored "3 hours behind" at 03:00:04 while being under seven
  minutes old, and all three retention lanes stopped for a day. The bound it was compared against
  was reasoned about in its own comment as "six consecutive missed ticks", which is not the
  quantity being computed: on a sparse table the reading is unbounded above however healthy the
  lane is. The message carried its own refutation, "3 hours behind, with 1 rows waiting", since a
  lane three hours behind a ten minute tick would have eighteen ticks of rows queued.

- **L539. A detector comparing a PERIOD TO DATE cumulative rate against a per period baseline lets
  a burst heal itself as the denominator grows, so it clears with nothing fixed, never fires at all
  later in the period, and reports a duration set by the check's tick rather than by the event.**
  Judge a trailing window instead, and report the window that was actually measured rather than the
  interval between ticks. Measured 2026-09-02 (bidspoke#1101): Main Flow's
  `trades_request.body.pennieLeadCalculations` missed 168 of 261 runs inside the single hour 12:00
  to 13:00 UTC, from a Salesforce Apex deploy that broke the trades path between 12:20 and 12:50.
  The hourly field presence check compares midnight to now against a seven day daily baseline, so
  it alerted at 13:00, then posted "back within normal range" at 14:00 because the day's average
  had climbed back over the 0.90 floor as later good runs arrived, which is dilution rather than
  repair. The recovery notice reported the incident as lasting one hour, an artifact of the tick,
  against a real outage of thirty minutes, and the identical 168 misses inside a busier hour would
  never have crossed the floor at all.

- **L540. A reconciliation that declares everything accounted for by summing named buckets is
  satisfied by the very defect it hunts, as long as that item lands in the bucket standing for
  legitimate cases, because the arithmetic balances whatever the labels claim. So every member of
  an expected absence bucket must carry a measured reason, never membership earned by failing to
  match the good case.** (project-enrollment-tracker#1219, 2026-09-02: the #1084 attribution
  cross-check read 85 September feed rows, put 84 on a board and 1 in `offBoard`, documented as
  rows "legitimately not on any board", and printed "every feed row is accounted for" on a run
  where a rep's unit was genuinely missing from Team Whitaker. `offBoard` membership is earned by
  the resolved name not being in `boardNames`, which is precisely the #1081 and Sean Murakami
  defect shape, so the bucket named for legitimate absences is the one that absorbs the silent
  drop. The roster coverage guard alerted on the same row in the same run, one log line above the
  balanced verdict, so the two guards shipped opposite answers to one question. L517 does not
  cover it: the item landed in exactly one bucket and the count was correct, and only the bucket's
  NAME asserted a legitimacy nothing had measured.)

- **L548. A record still holding a seeded default does not merely escape detection, it COUNTS
  TOWARD any coverage or health measure computed over its population, so the placeholder makes
  the system read healthier than it is and can mask the very gap the measure exists to find.
  Exclude never-set records from such measures, or record whether a value was ever set by
  anyone.** (slate#1753, 2026-09-02: every one of 117 agents carried the seeded working week,
  Monday to Friday 08:00 to 17:00 in America/New_York, because nobody had edited it; measured
  against cal.com, 81 of 100 had different hours and 74 of 103 were in another timezone, one of
  them Phoenix, three hours out. Two agents whose hours nobody has ever set are still on that
  default, and `roster-coverage` (#1454) pages when the org's advertised hours are not covered
  by somebody on shift, so those two CONTRIBUTE 08:00 to 17:00 of coverage each and make the
  roster read better than it is, hiding whatever gap their real hours would have left. L113 says
  a default is indistinguishable from a deliberate choice, which is the passive half; this is the
  active half, where the placeholder feeds the health metric. The root fix is a stamp recording
  who set a value and when, since `availability_schedules` carried `created_at` and nothing about
  whether a human had ever touched the row, so "never set" was not a state anything could query.)

- **L364. A check deciding whether a machine is clean enough to measure on must judge by what is
  UNUSUAL for that machine, never by what is running on it, because the always-present load (a sync
  daemon, a backup agent, an indexer) makes an absolute-quiet rule refuse every measurement anybody
  ever takes.** Keep the resting baseline in a file carrying its own measurement date, so it can be
  re-derived on another machine rather than believed. Measured 2026-09-01 (overture#3434): the plan
  defined a quiet Mac as no build or test process running, and on a machine with none of those the
  load averages read 13.01 / 28.35 / 28.97 with a Synology daemon at 99.4% and a Backblaze agent at
  84.0%, so the check would have stamped a badly contaminated control as clean. The obvious
  correction is worse: Dan's own words were that those two are always running and that banning his
  photo editor was not acceptable either, so a rule refusing on any of them refuses everything and
  is switched off within a day (L93, L36). The working shape is three outcomes rather than two,
  BASELINE against ELEVATED against UNMEASURED, where ELEVATED names what was busy and STILL writes
  the record, because a reading nobody can re-examine is worse than one carrying its own caveat.
  This is L356 one level down: that one says record what else was running, this one says how to
  decide what counts as running.

- **L367. An alert or threshold on a SUM cannot see one of its components collapsing while another
  grows to replace it, because the total never moves.** Wherever the sum is composed of sources that
  can substitute for one another (acquisition channels, plans, queues, regions, providers), alert on
  the COMPONENTS, because the substitution is the commonest way a healthy looking number hides a dead
  one, and it hides it for exactly as long as the replacement lasts. Measured 2026-09-02
  (nursedexapp/nursedex#872, #898): NurseDex lost the only traffic channel that ever produced engaged
  visitors, organic Facebook falling from 538 visits in June to 10 in August, while tagged Instagram
  and Facebook links grew from 292 to 1,390. Total weekly social visits held near 320 the whole time
  and moved less than 30% week to week, so a collapse alert on the total would have stayed silent for
  three months, which is exactly what happened with no alert at all. The headline conversion rate did
  fall seventeen fold, but that is a weighted average of two roughly STABLE rates whose mix inverted,
  so it read as a product regression and sent the investigation at page speed rather than at the
  channel. Distinct from L209, which is about calibrating a threshold while a co-varying component is
  held constant: this one is about a threshold that is correctly calibrated on a quantity that cannot
  express the failure.

- **L543. A feature whose data is a list of EXCEPTIONS (holidays, overrides, blocked
  entries, allowlisted cases) ships INERT when that list is empty, and empty is a
  legitimate domain value meaning no exceptions apply, so nothing can distinguish a
  correctly quiet feature from one whose data was never entered.** Ship the first real
  entries in the same change as the mechanism, or make the empty state a refusal
  somewhere, because the harm lands on exactly the case the feature was built for.
  Neither L96 nor L65 covers it: there the incomplete list drives a GUARD, and here the
  mechanism works perfectly and is simply never consulted, so every test of it passes.
  (slate#1742, found 2026-09-02 five days before the holiday it would have closed: the
  org closure feature shipped in slate#1363 explicitly naming a holiday shutdown as the
  case it was for, `business_hours_exceptions` still held zero rows months later, and
  production was offering 53 bookable times on Labor Day while the incumbent cal.com
  was closed. The admin surface read "No dates are set. Every day follows the weekly
  pattern above.", which is the truth and is also indistinguishable from a gap, and the
  availability canary scored the day healthy because the times really were computable.)



- **L373. A test whose premise is that a change has NOT yet been made (a migration rehearsal, a dry
  run, an assertion that the thing about to be dropped is still there) is CONSUMED by that change
  shipping, so retire or invert it in the same commit that ships the change. Left behind it goes
  permanently red for a reason that looks exactly like a real defect, and a standing red makes every
  other failure in the same list unreadable.**
  (overture#3482: `RetiredColumnsDryRunTests` rehearsed the app's first subtractive migration against a
  clone of the live store, and step one asserted the column being dropped was still on the clone,
  deliberately, so the rehearsal could not pass on a store that never carried it. The drop then shipped.
  Measured 2026-09-02 on a WAL inclusive copy, `ZWEBSITEURL` is gone from `ZPROSPECT` and `websiteURL`
  is gone from the Swift model, leaving three past-tense comments behind it. So the suite failed on
  every run with its own wording, "rehearsed dropping a column that was already gone", on the one gate
  that verifies the Mac app at all, since CI does not run the Swift suite. The half of the same suite
  that is still live, asserting the two columns Dan chose to KEEP are still there holding their values,
  was unreadable behind it. Note this is not L252: that is a decision REVERSED, where the test defends
  the rejected behaviour, and this is a decision CARRIED OUT, where the test defends a precondition
  that was true only until the work was done)

- **L375. A before and after comparison of shared state attributes every change it sees to whatever
  it was bracketing, so on any store with a second legitimate writer it accuses rather than finds,
  and it accuses loudest exactly when that writer is busiest.** Identify your own writes positively,
  by a marker you stamp or by evidence the other writer leaves, rather than inferring authorship
  from the change itself.
  (claude-config#275, #272, #277: run-all-tests.sh brackets a run with a fingerprint of the live
  findings spool, the rule files, the settings and the watcher's own markers, and fails the run if
  any changed. Three separate false reds on green runs in one day, each costing a full re-run of
  roughly three minutes: two HARVEST FAILED records another Claude session's SubagentStop hook wrote
  while working in the same repo, the watch daemon restarting under launchd and rewriting its pid
  marker, which it had done 562 times by then, and the same daemon pulling a lesson from the other
  Mac and applying it into LESSONS.md mid run. The guard's own comment stated the assumption it
  rested on, that nothing else on the machine legitimately writes these during a run, and all three
  writers were doing exactly their job. The fix in each case was positive identification rather than
  a wider exemption: the run exports an id and the spool library stamps it into every record, the
  watcher marker is judged by whether the pid it names descends from this run, and an apply is read
  from the timestamp the sync itself writes. The stamping is proved on a throwaway store before an
  absence is read as evidence, because a stamp that had quietly stopped would make every write read
  as somebody else's and the guard would be the last thing to say so)

- **L376. A guard that compares the current environment against the ONE it was calibrated in
  fails on every machine that legitimately differs, because a developer machine and a CI runner
  never upgrade together.** Record the SET of environments there is a reading for, each with its
  evidence, and keep a test that an unmeasured one is still refused, since widening such a list is
  how it stops guarding.
  (postroll#1226: the reference frame checks deliberately do not pin ffmpeg, and instead assert the
  running major matches the single build MAX_CHANGED_FRACTION was measured against. Homebrew moved
  the pinned runner image from 8.1.2 to 9.0.1 between two runs an hour apart, with nothing
  committed in between, and every reference frame job on every branch refused to run. The new major
  turned out to render all eleven frames identically, 0.0000% each, so the limit did not move; but
  recording 9.0.1 as the single value would have turned the same check red on Dan's Mac, which was
  on 8.1 that same afternoon. The record became the majors there is evidence for, each naming the
  run behind it)

- **L378. A guard that exists to save an EXPENSIVE step must run on every entry point that reaches
  that step, because wiring it only into the thorough path leaves it absent from the quick one
  people use while iterating, which is exactly when the mistake it catches is made. Its own cost is
  the wrong thing to weigh: two seconds on every fast run is nothing against one doomed build it
  prevents.**
  (overture#3490: `check-pure-suite-imports.sh` catches a test file importing the app as a module,
  which the unhosted target cannot resolve, and its own header says it runs ahead of the build
  because "its whole value is saving a doomed build". It was called only from the full pre-push
  gate. The scoped runner, which is what anyone reaches for while iterating on a NEW test file, never
  called it. On 2026-09-03 one stray `@testable import Overture` cost two failed scoped builds and a
  needless 1.3 GB DerivedData wipe before the full gate finally named it in a single line; the two
  build errors read `malformed compiled module` and `unable to resolve module dependency`, neither of
  which points at an import and both of which read like a corrupt cache. The check itself takes 2.28s
  over 943 files and was the only file in the tree that tripped it)

- **L382. A poll that repeats an IDENTICAL request can be served the same cached answer every
  time, so it re-reads its own first attempt and can never observe the change it is waiting for.
  Make each attempt demand a fresh read, and prove the value can change inside one run rather than
  trusting that the loop is looking again.**
  (nursedex#913: the PostHog ingestion health check sent a probe event and then polled every 3
  seconds for it, with a byte identical HogQL query each time. PostHog caches a query answer against
  the text of the query. The first attempt ran 179ms after the capture, when zero was the honest
  answer, and all 51 later attempts were handed that cached zero. The check waited 182 seconds, made
  52 requests, and reported that ingestion was not recording, while the event sat in PostHog the
  whole time, timestamped the same second the check started. It could never have passed. The cached
  answer was still being served twenty minutes later, with `is_cached: true` and `last_refresh`
  stamped at the first attempt, which is how it was finally seen. Adding `refresh: "force_blocking"`
  made the same query return 1 immediately. The same run also invalidated the measurement the
  design rested on: a recorded ingestion lag of about 90 seconds had itself been measured through
  that cache, so it was timing the cached answer expiring rather than the event arriving; the real
  lag, measured with the cache bypassed, was between 31 and 35 seconds)


- **L385. A test asserting an invariant that a SCHEDULED repair restores (a launch migration, a
  nightly cleanup, a periodic reconcile) must RUN that repair first and assert what is LEFT,
  because between two runs of the repair the violated state is the system's normal one, so the
  test reports the interval rather than a defect and goes red on ordinary days.** (overture#3496,
  2026-09-03: two live-store suites asserted that Dan's store held no show stored twice. The
  scout mints duplicates all day and the merge passes run only at launch, so both went red the
  morning a venue renamed two of its own listings, blocking every push in the repository and
  costing a full diagnostic detour to establish the change under test was innocent. A sibling
  suite in the same directory had it right and said so in its header: it runs the pass on the
  clone first, then asserts the invariant that holds before AND after, and it passed on the same
  run over the same two pairs. L332 is the app side of this, a repair wired to startup being
  blind to what the running system writes afterwards; L538 is the consequence, a standing red
  making every other failure unreadable.)

- **L564. An empty search result proves the SPELLING is absent, never the concept, so a conclusion
  drawn from it may claim only what was actually searched for.** Before treating something as the
  last copy of a fact, look for where the fact is SERVED rather than where its wording appears: the
  search that found nothing is the same search whether the thing is missing or merely worded
  differently.
  (Try-Pennie/slate#1795 then #1836, 2026-09-03: removing an admin panel meant deciding whether its
  warning sentence about impersonation was the only explanation of what impersonation does. A grep
  for the sentence found it nowhere else, so I concluded the explanation was unique, lifted it into
  its own module with a docstring arguing for its own necessity, and left it rendering as two lines
  of prose on a page where nobody was impersonating. The header banner had said it all along, and
  better, naming the person being impersonated, which the preserved sentence could not. Dan: "Warning
  isn't needed when I'm not impersonating someone and when I am I'll see the banner")

- **L391. A cost guard's fixture must record the dimension the COST scales with, which is routinely a
  PAIRING or a MAXIMUM rather than a total, because a fixture matching every recorded total can still
  exercise an entirely different load while every drift check passes. Name what the cost is quadratic
  or conditional in, and record THAT.** (overture#3506 and overture#3516, 2026-09-03, twice in one
  day. A render cost fixture matched the live store exactly on recipients, contacts, pending count and
  draft bodies, all five verified against the real store on every push, and ran the draft lint 402
  times against the store's 73: the lint is reached only through a PENDING recipient carrying a body,
  and nothing recorded that pairing, so the seed gave every body-carrying row two pending contacts
  where the store has sixteen in total. The same fixture spreads its dates evenly, so its busiest date
  holds 11 shows against the store's 19, and the self-booking check is quadratic in exactly that
  maximum. L48 is about a fixture shaped to make the rule fire and L354 about one going stale as the
  data grows; both assume the recorded dimensions are the right ones, and this is the case where they
  are not.)

- **L588. A displayed share or percentage must be ASSERTED to lie within its own range, because
  a value outside it is the only self-evident proof that the numerator and denominator measure
  different things, and nothing else will ever report it.** Beware in particular a denominator
  that models ONE ideal member against a numerator counting a UNION across many: the two agree
  while the members are identical and diverge as the real population becomes varied, so it ships
  correct and rots without any code changing.
  (Try-Pennie/slate#1937, 2026-09-04: the bucket availability page rendered 117%, 168% and 189%
  under a header promising "every number is a share of what was possible". The numerator counted
  distinct slot instants offered across a pool of 84 agents; the denominator, named
  `userId: "theoretical-maximum"`, was a single synthetic agent on the org's hours and the event
  type's slot interval. Agents' windows begin at different minutes in seven timezones (#1739,
  #1454), so the union holds more instants than any one grid. It read as roughly 100% for months
  while every schedule said America/New_York with identical hours. Worse, `open >= max` counted a
  189% bucket as "offering the whole of today" in the page's own summary line, so the headline
  numbers were wrong too. Dan read it as "did we book more than we offered". A clamp to 100% would
  have hidden it; the range assertion is what surfaces it)

- **L396. A count of people who reached a LATE stage of a funnel (signups, checkouts, completions)
  is not a measure of how many ARRIVED, so never conclude that traffic has collapsed from a
  downstream number. Read arrivals at the entry point first, because a stage count falls both when
  fewer people come and when the same crowd stops converting, and those two demand opposite work.**
  (nursedexapp/nursedex#980, 2026-09-04. Asked which milestone was most valuable, the answer given
  was that nobody was arriving and the whole backlog therefore served an audience that did not
  exist, drawn from sessions reaching the signup path falling from 236 in June to 2 in September.
  Measuring arrivals directly showed about 325 visits a WEEK still landing, so the recommendation
  was wrong in the way that mattered: the work is not to restart a channel but to fix what the
  arrivals meet, since 96% of them left from the first page after a median of 20 seconds. Distinct
  from L367, which is about a SUM hiding one component collapsing: here no component was hidden and
  the number read was simply several steps downstream of the question being asked.)

- **L400. A check's NAME is not a statement of its coverage, so read what a monitor, smoke test or
  guard actually does before counting it as protection. A job named for the thing it does not check
  makes the gap permanently invisible, because nobody writes the missing check while a green tick
  with the right name is already on the board.** (nursedexapp/nursedex#1017, 2026-09-04. After
  promoting 35 dependency bumps including a Next minor to production, the deploy was read as
  verified partly because a workflow named "Production Smoke" had gone green. It checks the
  database permission surface, that the legacy Supabase host is serving, and how much of the plan's
  usage is left. It never fetches a page, and a search of every workflow in the repo found nothing
  that requests the live site at all, so a build serving errors on every route would have left the
  whole pipeline green. The name had been doing the reassuring for an unknown length of time.
  Distinct from L4, which is about verifying that YOUR change went live, and from L263, where a
  shared name suppresses comparison between two implementations: here one name suppressed the
  question of whether the thing existed.)

- **L411. A test that depends on a machine state it cannot SET from inside itself (a display awake,
  a device attached, a network reachable, a screen unlocked) must DETECT that state and report
  UNMEASURED rather than failing, because a failure there is indistinguishable from a real one and
  a standing red makes every other failure in the list unreadable.** (overture#3580, 2026-09-06.
  Three hosted tests drive a real CGEvent scroll wheel into a real NSScrollView and assert the
  content moved. At 00:10 the display went to sleep and from then on all three timed out, having
  polled their condition about 4,800 times each, which is a healthy poll rate: the content genuinely
  did not move, because the window is borderless and deliberately never ordered front, so AppKit
  lays it out only while the screen is awake. They failed identically on main, and event creation
  itself still worked, so the obvious suspect was wrong. Since that suite is the mandatory pre-push
  gate and the only thing verifying the Mac app, no Swift change could be merged at all while the
  screen was off, and nobody hitting it could tell an environmental red from a real one. Distinct
  from L504, which says to SET the ambient configuration the test depends on: the case this covers
  is the one where it cannot be set, and the answer is then a third outcome rather than a pass or a
  fail. The wrong fix, named because it is the tempting one, is to assert something weaker that
  passes with the screen off, which is the false negative the rig was built to prevent (L159).)


- **L412. A guard that DERIVES its search terms from live data inherits that data's own
  placeholder values (TBD, N/A, Unknown, Untitled), which identify nothing and are by
  construction ordinary words, so it matches plain text everywhere and its noise reads as
  the guard working rather than as a defect in the guard.** Exclude sentinel values before
  searching, and report how many were dropped, because a needle set silently thinned is a
  coverage claim nobody can check. (ovation#5, 2026-09-06: Ovation's identity guard derives
  needles from the live Downbeat export so it cannot go blind when a hand maintained list is
  missing, which is the L217 correction. On its first real run it refused on PRD.md, twice on
  one line. The needle was `TBD`: one of nineteen real bookings carries venueName "TBD"
  because its venue is not decided yet, and the PRD says TBD twice meaning to be decided. The
  fix is the rule rather than an exemption naming that file (L362), and the count of dropped
  placeholders is printed, because a guard reporting "derived 110 needles, found nothing" is
  making a claim about coverage that the reader cannot otherwise check)

- **L413. A test runner that DISCOVERS its suites by glob, directory walk or naming
  convention can only invoke each one ONE way, so any suite taking a parameter runs for
  ever in its DEFAULT mode while its other cases never run at all, and its name still
  appears in every green report.** Give the runner a way to enumerate a parameterised
  suite's cases, or split it into files the discovery can see, and never let one file
  stand for several subjects. (ovation#25, 2026-09-06: `run-tests.sh` runs
  `scripts/test-*.sh` with no arguments, and `test-built-bundle-identity.sh` takes the
  build configuration as `$1` defaulting to Debug, so its RELEASE assertions ran in no
  suite and in no pre push gate. Those were the assertions that had caught a real defect
  hours earlier: with a stable signing identity, Xcode added
  `com.apple.security.get-task-allow` to BOTH configurations, letting any process attach a
  debugger to the shipping build, while ENABLE_HARDENED_RUNTIME was YES throughout and both
  bundles carried the runtime flag. It was found by running the Release case by hand during
  the fix, and nothing would have found it again. The suite's name was in every green run
  the whole time, which is L400 one step along: not a check whose name overstates it, but a
  check half of which the runner cannot reach)

- **L414. A build product's mtime records when it was last WRITTEN, not when it was last
  built, and a source file's mtime records when it was last touched, not when it changed,
  so a freshness check comparing the two is red on a healthy tree in BOTH directions: a
  correct incremental build that relinks nothing leaves the product reading as permanently
  stale, and any generator that rewrites a source on every run leaves it permanently
  newer.** Assert the property you actually care about against something that is always
  current, such as the resolved configuration the tool reports, rather than inferring
  currency from timestamps. (ovation#25 and ovation#26, 2026-09-06: a suite judging the
  signed Debug and Release bundles added an mtime check so a bundle built before an
  entitlements change could not pass while saying nothing about the current configuration.
  It fired on its first run for a real reason, then never stopped: `test-project-configuration.sh`
  runs `xcodegen` on every run, so `project.pbxproj` was newer than every product within
  seconds of a green suite, and rebuilding both configurations did not clear it either,
  because the incremental build correctly relinked nothing and left the executable's mtime
  where it was. L40 is the same comparison failing the other way, toward a false green, and
  reading it as "timestamps are merely weak" is what produces this one: the honest cover is
  the OTHER side of the pair, asserting the same properties against the resolved build
  settings, which need no build and are never stale)
- **L621. A behaviour each call site must OPT INTO cannot be enforced by any scan, because a
  site that never opts in is indistinguishable from one where the condition never arises, so it
  must be owned by a shared component that makes omission impossible rather than written as a rule
  each site is asked to follow.** Consolidating existing copies (L613) does not help here: the
  failure is an ABSENCE, not a copy, and it lands hardest on the sites nobody thought about.
  (paperboi#72, 2026-09-07: a working, still alive and failed treatment was designed and written
  into the design document, and it appears only on a control that marks itself busy. One button in
  the product did. Every slow action still to be built has to remember, a forgetting one looks
  entirely normal, and no test can tell a button that is never busy from one that never says so)
- **L614. A freshness window between a job that PRODUCES a measurement and a job that ACTS on it
  must be derived from the worst-case gap between their two schedules at the instant of use, and
  proved by a test that evaluates the predicate at the consumer's scheduled instant against a row
  stamped at the producer's.** A window sized by feel fails in one of two silent ways: narrower than
  the gap, the consumer refuses every reading as stale and never acts, which reads as a quiet
  night; wider than the gap, it protects nothing. L51 says to check the evaluating schedule and
  L567 says to refuse a stored verification on its age; this is how large that age has to be.
  (bidspoke#1196, 2026-09-06. The execution archive's deletion gate measures each day at 13:00 UTC
  and looks back retention minus one days; a day becomes eligible for deletion two days after it
  leaves that window, so at the 03:30 UTC purge every eligible day's last measurement is 38.5
  hours old against a 36 hour allowance. Both purge jobs had run gated for two nights and reported
  "truncated 0 partition(s)" because nothing was yet eligible, so the design had only been observed
  on its safe half (L142). Found by computing the refusal at tomorrow's cron instant against the
  real stored row before the first real deletion, which then had to be run by hand inside the
  window. Step partitions had a second, circular block: a day's steps need the previous day
  verified, but the previous day's execution partition was truncated the night before and a
  truncated day re-measured refuses as a surplus.)



- **L416. A provenance record naming the COMMIT an artifact was built from describes what was
  committed, never what was compiled, so an install or deploy made from a checkout with
  uncommitted changes records a truthful commit while the artifact contains code that
  exists in no commit anywhere.** Record the working tree state in the same write that
  records the commit, and assert the CLEAN case too, because a field that is never written
  cannot be told from a genuinely clean build (L98). (overture#3584, 2026-09-06:
  `mac/build-install.sh` writes version, commit, commitDate, repoPath and provenance, and
  no dirty count. Its `build-provenance.sh` exists because of #2553, where the freshness
  panel could not tell a build from an unmerged branch from a current one and said "up to
  date" in exactly the words a correct install uses. That was fixed on ancestry rather than
  on a branch name and answers WHICH COMMIT, one step short of what was compiled. Measured
  the same day: the checkout stood on a non-main branch with one uncommitted file, so an
  install from it would have recorded a truthful commit and a provenance of main with
  nothing saying the bundle did not match. Downbeat records the count, citing downbeat#424,
  and Ovation records the union of both siblings' fields, so the gap had already been
  noticed twice from outside without ever being closed at the source)

- **L417. Turning on a platform security control imposes requirements on parts of the build you
  never touched, and the resulting refusal happens only when the artifact RUNS, so a
  configuration nothing ever launches stays broken while every check that reads the
  configuration is green.** Launch every configuration you ship OR develop in, not only the
  one you ship. (ovation#20 and ovation#30, 2026-09-06: the Debug build could not start at
  all. Three individually correct settings combined. Xcode's default `ENABLE_DEBUG_DYLIB`
  splits Debug's code into a separate dylib; `ENABLE_HARDENED_RUNTIME` requires a loaded
  library to validate against the loading process's Team ID; and the deliberate self signed
  identity from ovation#9 has no Team ID at all. Both binaries were signed by the same
  identity and both reported `TeamIdentifier=not set`, so nothing in the configuration read
  as wrong, and the suite that asserts the signed bundle's identity passed throughout. Release
  builds no such dylib and opened one window and quit cleanly, so the half everyone verifies
  was the healthy half and the harm sat in the other (L142). It was found the first time
  anything launched the app, by the smoke check written for exactly that gap, and the fix is
  to remove the thing needing the exemption rather than to grant it)

- **L418. A count taken over a STORED field is a claim about the store rather than about what
  anybody sees, because a surface that recomputes that value at display time ignores what is
  stored, so measure through the predicate the surface itself uses or the number describes data
  nothing renders.** Distinct from L107, which is about reimplementing a predicate beside the code:
  this one survives a faithful reimplementation, because the predicate was right and the COLUMN was
  the wrong subject. Overture#3345 was filed at p1 on "37 shows badged as unreachable, 31 of them
  holding a route", counted in SQL over the stored reason column, and worked from for a week. The
  badge is drawn only under the no-email arm of a verdict that recomputes from the row's own
  contacts, so on 24 of those 37 the stored reason was never rendered at all: measured through the
  app's own predicate, 31 of 1,153 shows drew the sentence and not one held a route. The tell is a
  field whose reader RECOMPUTES rather than reads back, which is ordinary wherever a value is
  derived at display time (a computed property, a denormalised status, a cached count), and the
  stored copy then goes on reading as a current measurement to anything that queries it.
  (overture#3345, overture#3598)

## Data safety

- **L285. A store that several independent consumers draw from must be drained by the same key
  it is written by, because a clear keyed more coarsely than the writes destroys work belonging
  to consumers the clearing one does not represent, and the loss is silent on both sides: the
  clearer sees a successful cleanup and the others simply never receive anything.** Distinct from
  L258, which is one producer and one consumer disagreeing about whether a record was ever
  written, and from L211, which deletes what a short read failed to mention: here every read is
  complete and the delete is exactly as instructed, and it is the KEY that is wrong. The tell is a
  store keyed on a container (a project, a tenant, a day) while its writers and readers are
  something finer inside it. (claude-config#222: the subagent finding spool is keyed on the
  project through git's common dir, correctly, so a worktree reaches its spawning session's
  spool. But several sessions run against one project at once, so the first to finish a task is
  handed every session's findings and told to clear the project spool. Measured on PostRoll on
  2026-08-29: four consecutive reviews in one session were each offered the same 25 findings
  belonging to a different session's work, and only survived because they were copied aside by
  hand each time)

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
- **L567. A stored verification result that AUTHORISES an irreversible action (a backup proved
  complete, a lock confirmed free, a health check passed) must be refused on its AGE at the point
  of use, because a truthful measurement of a past state is indistinguishable from a current one
  and the record says nothing about when it stopped being true.** Give the staleness refusal its
  own reason, distinct from a failed verification, so an unmeasured subject and a disagreeing one
  do not read alike. L331 is the completeness twin, whether the run that produced the number did
  the work; this is the age of a number whose run did everything right.
  (bidspoke#1137: the execution archive's deletion gate writes a per day measurement that
  `verified_purgeable_days` will read to authorise truncating a partition, and the gate's own pass
  dies partway when its caller disconnects, leaving some days measured today and others carrying
  readings up to six days old with nothing recording that the pass was cut short. The spec requires
  a "fresh" row and defines fresh nowhere)
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
- **L574. An undo, revert or reactivate that restores FEWER fields than the action changed is not
  the inverse of that action, so any copy calling it reversible is a claim about two separate
  writes and has to be checked against both.** The fields it does restore make the reversal look
  complete, so the one it leaves behind is found later by its absence rather than by anything
  reporting it, and the person who trusted the word reversible is the one who finds it.
  (slate#1875)
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

- **L256. Before dropping a stored column, measure what it holds against its DECLARED DEFAULT rather
  than against null, because a defaulted column is non-null on every row whether anybody set it or
  not, and a never-written optional is null on every row, so a null test reports a harmless column as
  full of data and can equally let a column holding real values read as empty.**
  (overture#1665/#1640: a rehearsal for the app's first subtractive migration asked "how many rows
  hold a value" as `IS NOT NULL`. It reported 1018 of 1018 prospects about to lose data on two
  columns, and the truth was 1018 copies of a Swift property's default that nothing had ever written.
  Asked against the default instead, the same columns came back with 505 rows really marked
  `uncertain` by a retired classifier and two marked reviewed by the owner, which is the opposite
  finding and the one that changed what the change was allowed to delete: the issue had described
  those columns as "read and written by nothing" and they held records of his own judgement. The
  third column in the same change was an optional nothing ever wrote, where null genuinely does mean
  empty, so one query shape could not answer for both. Make the default a required argument of
  whatever asks, so the easier question cannot be asked by accident)

- **L260. Two outcomes a guard gives distinct MESSAGES but the same CONSEQUENCE are one outcome
  in practice**, because nothing downstream reads the wording, so a state that needs somebody to
  act must change what the guard DOES and not only what it says. (downbeat#430, #435: a push gate
  comparing this repo's export version against a consumer in another repository had two carefully
  separated answers for "no Overture checkout on this machine" and "Overture is here and its
  version gate could not be found", the second being the alarming one, since the check had gone
  blind to a consumer that still exists and that somebody is evidently in the middle of changing.
  Both printed a paragraph and both exited 0. The issue filed against it described the two as
  "indistinguishable in their effect", which was exactly right and was not what the code looked
  like: read the source and the two branches are visibly different, each with its own sentence,
  which is what made it read as handled. The fix was not more wording, it was making the blind
  case block, with the existing one-command override as the way past it. L11 asks for distinct
  messages and L98 for an absent answer not to read as a pass; both were already satisfied here,
  and neither noticed that the two states were the same event to everything except a reader)

- **L598. A page already open in somebody's browser is a client from whichever version was live
  when it loaded, so every deploy turns every open page into a stale client, and anything that
  page holds which was minted at BUILD time (a server action id, a chunk name, an asset hash)
  stops resolving against the running server.** The more often you deploy the more routine this
  is, so a long lived form needs a recoverable version mismatch path (reload and re-present the
  work) rather than an error, and the failure only shows up for somebody who left a tab sitting,
  which is nobody testing it.
  (slate#1970: thirty deploys in a day, a form left open 20 minutes, the save fell through to the
  framework's own unstyled error screen and the typed hours were lost.)
- **L267. Running a new version that AUTO MIGRATES a shared store consumes your ability to run
  the PREVIOUS version against it**, so take any baseline measurement, comparison or rollback you
  may want BEFORE the new version opens that store for the first time. The migration is one way,
  nothing warns you, and the moment you need the old version to answer a question it will no
  longer start.
  (downbeat#446: a Data tab was found to take 64 seconds to walk through accessibility, and the
  obvious question was whether that change had caused it. The previous build had already been
  installed and launched, which migrated the real store forward, so it then died at launch on
  `Could not create local ModelContainer` and could not be measured at all. Attribution was
  recovered only by building the SAME commit with the one suspect change removed, which is a
  better experiment anyway since it moves one variable, but it was reached by luck rather than
  by plan. L7 already says to rehearse a destructive migration against a copy of the real store,
  and that was done; what it does not say is that the FIRST REAL LAUNCH spends the old version)

- **L338. Archiving a run's INPUTS and OUTPUTS but not the record of what it DID leaves the
  question anybody actually asks later, whether it did the work, unanswerable, and the surviving
  pair reads as complete evidence rather than as a gap, so decide explicitly what carries the
  process record and how long it lives instead of letting it default to the live file's
  lifetime.**
  (overture#3346: each paid run's queue and results are copied into a dated folder, and the run's
  own event log is deliberately left out as "a separate retention decision", which was correct
  when written and never revisited. Diagnosing overture#3345 needed to know whether a reachability
  check had SEARCHED for the two people it returned or skipped them; the queue says what it was
  given and the results say what it produced, and neither says what it did. The events had been
  overwritten by the next run about half an hour later. The archived pair made this worse rather
  than better, because a folder holding a run's inputs and outputs looks like the run's evidence)

- **L377. Retiring a feature must delete the STORED POINTERS to what it produced, not only
  its writer and its screen, because a consumer written to be generic over those pointers
  has no list anybody could have updated and goes on acting on every one left behind.**
  Genericity raises the cost of an incomplete retirement rather than lowering it.
  (postroll#1240: Thursday's grid cover was removed, the renderer, the panel and the
  regenerate path all went, and every Thursday generated before that still named a `cover`
  in its stored preview paths. The export does not always re-render: it copies approved
  previews, and its merge policy was deliberately generic over asset key, documented as
  "copies exactly like reel or story, no exclusions needed". So the retired asset would
  have gone on reaching the folder Dan uploads from, and the pull request removing it
  asserted the opposite, because a fresh generation DID clear the entry and the case that
  mattered was the day nobody regenerates)

- **L381. A directory kept in step by an automatic mirror has ONE authoritative side, and an edit
  made to the other side is not merged but silently reverted, with a new file there deleted
  outright because the mirror has never heard of it.** Nothing warns before it, and the tests pass
  afterwards, because they were reverted alongside the code they covered. Hold the mirror or edit
  the source.
  (claude-config#221, 2026-09-03: most of a day's work was made in the development checkout and
  pushed to GitHub, and at 11:03 the watch daemon on the SAME Mac mirrored its ~/.claude up over
  the payload and reverted 84 files in one commit: a whole style sweep, two finished issues, part
  of a third, part of a fourth, and lib/match-open-issues.py deleted outright. The mechanism is not
  a bug, it is the mirror doing its job with --delete, and none of the machinery that protects
  against the TWO MAC merge applies, because both copies are on one machine and only one is the
  source. It was found by a ratchet reporting 204 short circuiting pipelines where 79 had been
  recorded, not by anything watching the sync. Recovery is to find the mirror's own commit, take
  the file list it touched, and check those paths out of the commit BEFORE it, keeping whatever
  genuinely arrived from elsewhere)

- **L559. A rule that decides whether a record COUNTS (an eligibility test, a visibility
  window, an exclusion) must be applied where the record is READ, never also where it is
  WRITTEN, because the read-time application is the visible one and reads as the whole
  enforcement while the write-time copy silently withholds the record itself, so correcting
  or reversing the rule later recovers nothing.**
  (project-enrollment-tracker#1247: a rep terminated on the 1st was excluded at write time as
  well as at read time, so no enrollment_history row was ever created for their termination
  month. The board rule says that month's production COUNTS toward team MTD, and the read-time
  eligibility check was correct, but the units had never reached the store. Measured across all
  20 stored months on 2026-09-03: four rep-months missing, holding 24 top-out and 16 cleared
  units, invisible because every surface agreed with every other surface about a number that was
  never captured)
- **L392. A one time correction that skips rows because of a state that can END (hidden,
  suspended, deleted, archived, paused) does not exempt them, it postpones them, and nothing
  re runs when that state ends, so either correct them anyway or make leaving that state
  re apply the rule.**
  (nursedex#912, #948, 2026-09-03: verification could be granted before a nurse had finished
  signing up, and 29 of 32 verified home health aides held the badge with no licence number.
  A backfill sent 25 of them back and asked for the number, deliberately skipping four whose
  accounts were hidden, deleted or suspended, on the correct grounds that nothing of theirs is
  shown to families and no email should go to a deleted account. The exclusion is right on the
  day and wrong the moment somebody unhides or unsuspends one, which puts a publicly verified
  profile in front of families on a credential nobody ever checked, with nothing watching for
  it. The gate that now refuses such an approval runs on the approve path only, and coming out
  of hidden or suspended is not that path)

- **L601. A claim that there is NOTHING TO CORRECT, used to justify skipping a backfill or
  migration, must be measured across every field the change can touch, never only the one the
  change was framed around**, because a row that is empty in that field routinely carries real
  values in the others and the skip reads as clean either way.
  (pet#1244, #1299, 2026-09-05: a rep who left on the 1st had her month reattributed away from
  her manager. The issue checked the five other reps termed on a 1st, found zero enrolled_units
  and zero enrolled_volume in each of their termination months, and recorded "no backfill
  needed: there is nothing to reattribute historically". Both numbers were right. Re-measured
  with the commission columns included, four of the five carry real activity on those same rows,
  6 and 8 and 9 and 1 top-out units against managers they had left, because a different job
  writes those columns and creates the row when the enrolled half is empty. The framing of the
  change decided which columns anybody looked at, and the answer it gave was the reassuring one)

- **L575. Deleting cached content must clear the marker that RECORDS that content's coverage
  (a sync token, a cursor, a window bound, a last refreshed stamp) in the same write**, because
  the surviving marker is a positive claim about data that no longer exists: it tells the refill
  path there is nothing to fetch and tells the monitor the coverage is healthy, so the gap is
  both unrepaired and unreported.
  (slate#1879: leaving the bookable pool deletes an agent's cached busy_blocks but leaves
  agent_calendars.sync_token and sync_window_to untouched. The retained token makes every later
  pass incremental, and a calendar delta delivers an unchanged event exactly once, so nothing
  ever re-sends the deleted rows; the retained window makes the coverage monitor score the agent
  as fully hydrated. Measured 2026-09-04 two minutes after an admin deactivated and reactivated
  one agent: 0 cached blocks against 101 of 101 peers holding a mean of 536, a sync_window_to
  reading three weeks ahead, no alert, and the daily hydration rotation 67 calendars away, so
  roughly 8 hours during which the booker offered that agent's whole working day as free. A
  brand new agent is unaffected and heals correctly, because they have no token to retain, which
  is why the neighbouring issue read as if this repaired itself)

- **L592. Two datasets meant to be read TOGETHER must be retained on the same boundary**,
  because the shorter one empties first and every query pairing them is then silently wrong in
  its oldest window, in the direction that looks exactly like the data being broken rather than
  the retention. State the pair's shared boundary where the retention is set, and window any
  such query to the shorter of the two. (Bidspoke, 2026-09-04, bidspoke#1167: lead_sighting_bids
  is drained about 25 hours back while lead_sightings keeps roughly two days, both export gated
  but on separate crons. Measured across all workflows, the 16:00 and 17:00 hours of the previous
  day held 2,315 and 6,382 sightings against ZERO bid rows, 18:00 was partial at 1,134, and the
  ratio was normal from 19:00 on. A detector comparing a workflow's sightings against its
  recorded bids over 24 hours therefore reads a healthy workflow whose traffic sits in that
  stretch as having recorded nothing, which is indistinguishable from the real defect it was
  built to find. It cost a 6 hour window plus a peer check, proving some OTHER workflow recorded
  in the same window, before any accusation could be made at all)

- **L595. A configuration value that can live in more than one store** (a platform secret, a
  settings table, a file) must be resolved by ONE reader that consults them all, because the path
  somebody exercises interactively reads the merged view and works, while a background path
  reading a single store silently sees a subset and refuses only where nobody is watching.
  (Bidspoke, 2026-09-04, bidspoke#1174: SALESFORCE_INSTANCE_URL and SALESFORCE_CLIENT_ID exist
  ONLY in the environment_variables table, while SALESFORCE_CLIENT_SECRET is in that table AND as
  a Cloudflare Worker secret. The engine's Salesforce steps read the merged env the executor
  injects and patch Salesforce thousands of times a day; two scheduled jobs read the Cloudflare
  env alone, see one value of three, and throw before any query runs. One of them, the hourly bid
  matrix sync, had failed every hour since 2026-08-22 with nothing surfacing it, and a brand new
  job written on 2026-09-04 inherited the identical defect within the hour because it copied the
  scheduled reader rather than the working one. The tell is that the failure appears only in the
  context nobody watches: the interactive path is the merged one, so testing by hand proves
  nothing about the cron)

- **L599. Repairing a monitor that compares against a STORED BASELINE makes its first run a
  report about the OUTAGE rather than about the present**, because the baseline is as old as the
  failure, so a restored comparison must refresh its baseline and stay silent on that run rather
  than announce the whole gap as a single change. (Bidspoke, 2026-09-04, bidspoke#1176: the
  hourly Salesforce bid matrix audit had been failing since at least 2026-08-22 on a credential
  bug, and its snapshot table held 1,230 rows last updated 2026-05-07, nearly four months
  earlier. Fixing the credentials re-enabled the comparison, so its next run would diff the live
  matrix against a four month old picture and report every accumulated edit as an edit that just
  happened, through an alert built specifically because one mid-day matrix edit had broken three
  hours of bidding. The alert path has no cooldown and no mute, so there was no lever to hold it
  back either. Noticed only because the snapshot's date was checked while writing up something
  else; the repair itself looked complete and correct)

- **L615. Write a RESTRICTION's condition as the reason for restricting, never as a broader
  property that happens to include it**, because the extra records lose an ability nobody meant
  to take, and unlike a too broad exemption, which merely fails to protect, a too broad
  restriction leaves no route out at all.
  (slate#2006: a bucket's code, name and criteria were made read only because a seeder rewrites
  them on every run, and the condition used was "this bucket already exists". The seeder writes
  only the sixty codes of the XBC matrix, so a bucket created by hand outside it was never going
  to be overwritten, and it was frozen anyway. The create form is the only place those fields
  can be set, so a typo made once became permanent and the only route out was SQL. L324 is the
  same mistake in the other direction, where a stand down condition broader than its reason
  silently disables a guard; that one fails permissively and this one fails restrictively, which
  is why the person is left with nothing they can do)

- **L436. The completeness of an import is a property of the PERIOD it must cover, not of the
  source it reads, and a source that is complete about itself says nothing about the years before
  it existed. Establish the earliest record the business actually has before scoping an import to
  whichever system holds the data today.** (ovation#118, 2026-09-07: Ovation's QuickBooks
  migration milestone was scoped on the assumption that Dan's invoice history lives in QuickBooks,
  and it pauses until a QuickBooks sample arrives. A Freshbooks export turned up on his disk
  covering 2019-01-06 to 2024-12-20, 171 invoices across 41 clients, from before he moved tools.
  Nothing would have reported the hole: the importer would succeed, the year end export would run,
  and whole tax years would simply be absent, which under an accrual basis are years with real
  income in them (L98). The tell is that nobody had asked what the earliest invoice in the CHOSEN
  source is, only whether that source could be parsed. Adjacent to L171, which is the same
  confusion one stage later: there a control proves the query's shape and not that it reached the
  period, here a source proves its own completeness and not that it covers the period.)

## Honest failure

- **L415. A screen that shows a change BEFORE the write lands owes a failure path that reverts it AND
  says so, because without one a failed write is indistinguishable from a slow one and the revert
  arrives long after the person has looked away.** (overture#3583, 2026-09-06. Striking an email
  address off a card hides it on the press, so the control answers immediately instead of after the
  860 ms the queue takes to rebuild. The mark is cleared only by a thirty second ceiling borrowed from
  another transient state, so a write that failed put the address back half a minute later with nothing
  said. Dan, answering the post-merge quiz, expected "an error, address stays"; what shipped was a
  silent return. Distinct from L12, which says to show success only after the write commits: that
  forbids the pattern rather than saying how to do it safely, and latency routinely makes it worth
  doing. The revert must be driven by the write's own answer rather than by a timer, because a timer
  long enough not to flicker is always long enough to be missed.)

- **L586. A redirect whose target is ITSELF a redirect drops the query string, so any outcome
  carried in it (a saved flag, a refusal message) is destroyed while both redirects read as
  correct in isolation, and the receiving page's notice becomes dead code that looks like
  working feedback.** Point an action at the route its own form is on, and assert the TARGET
  rather than the fact of a redirect, because a test that only checks a redirect happened
  passes on every wrong target.
  (slate#1922, 2026-09-04: six admin actions redirected to /admin/settings, which #1748 had
  reduced to a bare redirect to /admin when it split that hub into its own routes. Measured in
  a browser, `/admin/settings?ok=1` and `/admin/settings?error=...` both landed on the Health
  page with no notice anywhere, so a successful save said nothing and a REFUSED save destroyed
  the sentence explaining why. Both pages already rendered SettingsSaveNotice, mounted and
  unreachable, which is why nobody noticed.)

- **L583. A fallback that relaxes only ONE dimension of a multi dimensional match does nothing
  wherever the shortage lives in another dimension, so name which dimension is actually thin
  before choosing what the fallback relaxes.** It fails green: the fallback runs, walks every
  rung, and reports a legitimate miss, so the safety net reads as present while covering nothing.
  The tell is a ladder built by stepping one field of a compound predicate while the rest stay
  pinned. (slate#1909: `tierLadder` walks 522, 422, 322, 222, 122 stepping only the debt tier and
  never the backend service, and with one bookable Beyond agent all five rungs resolve to the
  same person; measured against prod, all twelve non Low Beyond buckets returned the identical 39
  slots, and the three Low Beyond buckets returned zero with nowhere left to fall)

- **L529. An audit entry must record the old and new values of what changed, not merely which
  thing changed, because the question an audit exists to answer is what the state was at a given
  moment, and an entry without values can never answer it no matter how many entries there are.**
  Mask the value for secrets rather than omitting it for everything. A key-only trail also fails
  in the worst direction: it looks like an audit, so nobody notices it answers nothing until the
  incident that needs it. (bidspoke#1085: eight audit entries for ACHIEVE_MIN_VANTAGE_SCORE
  recorded only {"key": ...}, so whether the Achieve pipe was live in August could not be
  reconstructed from the audit at all and was inferred from when sends actually happened, after a
  wrong first answer had already been given)

- **L283. A guard asserting that a rewrite does not CONTAIN something is satisfied by a rewrite
  that DELETED it, so wherever the thing is a reference to a resource (a photo marker, a link, a
  citation, a merge field), check for its LOSS as well as its presence, because disappearance is
  the worse failure and the only one the guard cannot see.** Distinct from L104, which is about a
  shape filter over-matching what it must preserve: here the filter is correct and simply faces
  the wrong way. The tell is a guard phrased as a negative over the output alone, with no
  comparison against the input. (PostRoll#998: `_fix_second_person` splices a reworded paragraph
  back only `if "[PHOTO:" not in reworded`, which refuses the harmless case, a model that kept the
  marker, and accepts the harmful one, a model that dropped it, so a photograph vanishes from the
  post with nothing printed and nothing red. The same repo had already written the correct shape
  on the caption side, `rewrite_lost_a_credit`, which compares against the original and refuses a
  rewrite that LOST a credit, and it was never carried across)

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

- **L404. A tool put on the path IN PLACE of another (a proxy, a compact output filter, a shim, an
  alias, a rewriting hook) must be proved to reproduce the original's EXIT CODE on a case that
  genuinely FAILS**, because every script and agent downstream judges by that code, and a
  substitute that only reproduces the output turns the one signal L184 says to trust into a lie
  that reads as a pass.
  (claude-config#318, 2026-09-05: a PreToolUse hook rewrote `diff a b` into `rtk diff a b`, which
  printed the difference correctly and exited 0 where the real diff exits 1, measured on rtk
  0.31.0. Anything judging the comparison by its exit code read "different" as "same", and the
  output being right is exactly what stopped anyone looking. The same substitute also printed
  "[ok] Files are identical" for two files that genuinely differ, intermittently, caught only
  because the line was read by hand afterwards. The hook already refused two other destinations
  for corrupting output, both found the same way, so the missing thing was never a third refusal
  but a check that MEASURES fidelity: claude-config#319 tracks running a known failing case
  through both the real tool and its substitute. L184 is the reader side of this and is defeated
  by it, since it tells you to trust the exit code and this is the exit code lying)

- **L406. A REMEDY a failure message tells somebody to RUN is executed by nothing until the
  moment it is needed, so a test must run it and assert what it produces**, because it is written
  once, read afterwards as authoritative, and its first real use is by somebody already dealing
  with a failure and in no position to audit the fix they were handed.
  (claude-config#319, 2026-09-05: rtk keeps a sha256 of its own hook beside it and refuses to run
  at all when the two disagree. The suite's failure message named the re-record command as
  `shasum -a 256 rtk-rewrite.sh | sed 's| .*| rtk-rewrite.sh|'`, which writes ONE space between
  the hash and the name. rtk requires TWO, which is what shasum itself emits, and answered
  "Invalid hash format (expected 'hash  filename')" and exited 1 on every command on the machine.
  The suite stayed green throughout because the check beside that remedy read only the FIRST FIELD
  with awk, so the format it demanded was never the format it checked (L63). It was found by
  mistaking one of those exit 1s for a real verdict while measuring something unrelated. The fix
  runs the remedy in a throwaway directory and requires its output to be byte for byte the
  committed file, and holds the command in ONE string that both the message and that check read,
  rather than two spellings that have to stay in step (L70). Related to L562, which is a worked
  example teaching the inverse of its rule; this is the narrower and commoner case where the
  example is a command and nothing ever runs it)

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

- **L319. A marker that exists to prove a run is in a SPECIAL mode (a synthetic or test
  store banner, a staging watermark, a dry run notice) must be produced by whatever
  ESTABLISHES that mode, never by one surface that happens to display it, because a
  surface that never opens makes the marker's absence mean both "not in that mode" and
  "in it, and saying nothing".** Absence is the reading people actually rely on, so the
  announcement belongs to the state's own lifetime rather than to a view's.
  (downbeat#478, 2026-08-29: the synthetic store banner and the seeding both sat in one
  `.task` on the MAIN window. Launched with the store variable set and only Settings
  opened, which is the state a fresh launch lands in, neither ran: Settings showed "No
  clients yet" with no banner, on a launch that really was synthetic. The banner is
  absent on a real launch too, so its absence had stopped distinguishing them, and
  somebody checking a screen they believed was invented could have been reading the real
  client roster, which is the exposure downbeat#447 had already cost once. The store
  itself was correct and in memory throughout, and the real file was never touched, so
  every test passed and only launching it and looking showed the silence, which is L3)
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
- **L71. A watchdog's own liveness must never depend on the health of what it watches**, in
  either direction. It must not share the abort-on-error behaviour of the work, because an
  incidental failure then kills the watchdog silently and leaves the work running unobserved,
  which looks exactly like a healthy system. And it must not be judged by the same instrument
  it applies to that work: a watchdog that REPORTS BY FAILING, and that reads its own last
  SUCCESS, is marked unhealthy by its own correct alarm and can never clear itself, because
  every later run finds the gap one interval wider than the last. So give it its own error
  handling, a fail-safe exit that stops the work it can no longer vouch for, and where it
  judges itself, judge it on whether it still RUNS rather than on whether it passed. A run
  that ran and failed is already reporting through its own failure; being dispatched at all is
  the only thing about itself that nothing else would say.
  (overture#2106, overture#2109; nursedex#1039: the scheduled job watchdog derives its watched
  set from the workflow files, so it has always included itself, and it judged every entry on
  its last successful scheduled run. It correctly reported a failing daily health check and
  exited 1, which stopped its own success clock, so the next day it found ITSELF 47 hours
  overdue, failed for that reason, and pushed its own clock a further day out. The health
  check had recovered within hours of being reported and nothing else was ever wrong, while
  nothing was watching the other 21 jobs for two days. A hand started run could not clear it
  either, because the reading deliberately counts only scheduled runs)
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
  A SECOND tell, on the UI thread specifically: a call that crosses a process boundary and waits
  looks exactly like an ordinary local method call at the site that decides where to run it. Nothing
  in `client.completedOvertureTasks()` says it sends a message to another application and blocks
  until that application answers, so the reviewer who would have caught it has nothing to see. Name
  the boundary where the decision is made (in the type, the call's own name, or an await that cannot
  be skipped), never only in a comment beside the definition.
  (downbeat#406, 2026-08-22: the fix for a keychain hang ran the blocking call with `Task.detached`,
  putting it on the cooperative pool; a suite whose fixtures blocked a handful of them killed the
  test process partway through and reported 1835 failures that were one starved runtime. The same
  trap was already documented in a comment two files away, which did not prevent the repeat, L57)
  (overture#3419, 2026-08-31, the same class in a second project nine days later, which is L195
  unapplied: both OmniFocus sync call sites run a synchronous AppleScript round trip on the main
  actor, so the whole app stops drawing and stops accepting clicks for the length of the call. Dan
  reported it as a freeze and it was still frozen when sampled, which is what made it provable:
  2,646 of 2,646 samples in `NSAppleScript.executeAndReturnError` waiting on an Apple event. Reached
  from launch, a 30 minute timer and every data change, so it freezes unprompted, not only on the
  menu item that surfaced it. The premise both sites were built on, that AppleScript requires the
  main thread, had never been checked; the cost claim beside it is L353)

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
- **L523. A suppression set by hand (a mute, a snooze, a maintenance window, a disabled
  check) must carry an EXPIRY and be listed somewhere visible.** It produces exactly the
  same silence as a healthy system, and usually only the person who set it knows it
  exists, so one without a deadline is not temporary, it is permanent and undetectable.
  (bidspoke#1047: muting an archive's alerts for a week meant setting seven separate
  suppression keys found across five files, and three were missed on the first pass,
  including the two conditions most likely to fire. Nothing anywhere lists an active mute
  or when it lifts. The suppression mechanism was a cooldown key whose normal life is 8
  hours, so writing one with no TTL would have silenced those alerts forever with no
  trace. Two write attempts also failed silently first, an unknown CLI flag and an
  ambiguous account, and reading each key back is the only reason that was noticed)

- **L251. A substitution can only rewrite text that is PRESENT, so one used to also supply a
  separator when joining two pieces inserts nothing at all on the input that lacks it, and the
  pieces fuse into a single corrupted value.** Join explicitly and normalize separately, because
  the inputs that DO carry the whitespace join correctly and make the defect intermittent, which
  is what keeps it out of the case anyone thinks to test.
  (claude-config#192: the lessons index generator joined a wrapped rule by replacing a
  continuation line's leading whitespace with a single space, which does the right thing for an
  indented line and nothing whatever for an unindented one, so those fused onto the previous word
  and shipped into the index that loads into every session in every project)

- **L264. A durable record that exists only because a CALLER redirects the tool's output belongs
  to that caller, not the tool**, so every invocation started another way does the work and
  leaves nothing behind, and the record then understates what has been verified at exactly the
  moments somebody checked by hand. (downbeat#444: a scheduled agent ran the clean Release build
  nightly and its plist redirected stdout into a log; a push then read that log to say when the
  invariant was last confirmed. Running the check by hand, which is what you do after changing a
  lot of code, printed the same stamp to a terminal and recorded nothing. Measured 2026-08-28,
  five clean manual runs after substantial changes, and the next push still named a scheduled
  check from fourteen hours earlier that predated all of them. The fix is for the tool to write
  its own record. L164 is the inverse, recording inside a program cannot capture its launcher's
  failures; this is the launcher owning a record of runs it did not start)

- **L282. Seeded, demo or fixture data that sets a STATUS field must also satisfy every
  record that status implies, because the schema does not enforce a derived invariant and
  the app's own checks will correctly report the fabricated rows as corrupt.** Read what
  the code DERIVES from that status, not only what the columns require.
  (downbeat#450, 2026-08-29: a synthetic store seeded four bookings with
  `commitStatus: .committed` and no handoff mark. Every NOT NULL, every foreign key and
  every enum was satisfied, and the whole unit suite passed. Launching the app showed a
  warning over its own invented data: `BookingHandoffMark` reads a row created after the
  mark shipped with no intent as DAMAGED, since reporting it as written would launder
  corruption into success. The check was right and the fabricated data was wrong. A demo
  store whose rows trip the product's own warnings is worse than none, because every
  screen on it then carries a warning nobody can act on and the reader learns to skim the
  banner. Found only by running the thing, which is L3; the existing seeder rule about
  reading the full schema first cannot catch this, because the schema was never violated)

- **L325. A measurement a process reports by PRINTING reaches its reader only while that
  process's stdout does, so any change in how the work is EXECUTED (a worker process, a
  background job, a sandbox, a parallel lane) silently removes the measurement while the work
  itself still succeeds.** Carry a measurement somebody must read on a channel the reader owns,
  such as a file, rather than on the output stream of whatever happened to run it.

  Overture #3276, found while working #3266 (2026-08-30). `ReplyInvariantsLiveStoreTests` prints
  a corpus line saying how many rows each live-store invariant could examine, and the test runner
  reads it out of xcodebuild's output. That readout exists (#2991) because both invariants had sat
  at zero for months while passing, and only a printed line thousands of lines up a log nobody
  reads separated that from a clean bill of health (L182). Running the same suite under
  `-parallel-testing-enabled YES` put those tests in worker processes whose stdout xcodebuild does
  not forward: measured over a full run, the suite RAN and passed, its per-test lines are in the
  log, and the corpus line appears ZERO times in 10,059 lines. Nothing failed. The verdict was
  green. The one thing built to notice a silently empty corpus had been switched off by a flag
  about scheduling, and the readout's own message then blamed a scope the run did not have, which
  is the same absence wearing a second wrong explanation (L11).

- **L337. Making a reader that silently returned a benign default THROW instead re-audits
  every caller, because the same refusal that is right behind an error screen leaves a
  caller driving a control with a pending state it never clears.** Decide per caller
  whether a failed read should throw or return a typed failure.
  (nursedexapp/nursedex#847, 2026-08-30: hasRevealedNurse and getActiveSubscription read
  only `data` and ignored `error`, so a failed read told a family who had spent a capped
  daily reveal that they had not revealed the nurse, and told a paying family they had no
  subscription. Making both throw was right for the page renders, which sit behind
  error.tsx. revealNurse calls the same function and RevealCTA awaits it in a void async
  IIFE with no catch, so the rejection skipped setIsPending(false) and left the button
  spinning forever with no message, trading a wrong message for none at all. Found by
  reading the changed function's callers, not by any test failing. Distinct from L95, which
  is adding a WRITE to an error path; this is converting a silent default into a refusal)

- **L344. A counter that ACCUSES once it passes a threshold (N consecutive misses means
  cancelled, N failures means dead) has no upper bound, so an input that merely stopped
  MATCHING goes on incrementing and the verdict reads as more certain the more broken the
  match is.** Give it a ceiling past which it reports the matcher rather than the thing, and
  a share based signature (most of one source's items accused at once) that says the same.
  (danwright32/overture#3379 and #3383, 2026-08-30: a venue moved its calendar to a new feed
  that spells titles without the marketing subtitle, so every saved show from the old feed
  stopped matching. missedScoutCount reached 53 on a show the feed listed on every single
  run, and 26 future cards were struck through as "may be cancelled" while on sale. Two
  rows for one night in one hall sat at 53 and 48. Nothing anywhere read the number, and the
  threshold that renders the flag is 2, so past that point every further increment only made
  a wrong verdict look better established. Distinct from L182, which is a count driven to
  ZERO ceasing to be read as a measurement; this is a count with no top)

- **L530. A surface whose content is derived by JOINING two or more reads must gate its
  could-not-measure state on EVERY one of them.** A failure in an ungated read empties the
  joined result, so the surface renders as a genuine all clear, and the gated read's own
  notice sits above it explaining something else entirely, which makes the screen look like
  it is already telling you what went wrong. (Try-Pennie/slate#1646, 2026-08-31: the admin
  calendar sync health panel gated on the calendar read but not the roster read. With the
  users read failing, every failing calendar mapped to a row with a null email, the dedupe
  dropped all of them for having no email, the panel's length went to zero and the panel was
  not drawn. The roster notice rendered directly above it, correctly, about the agent list.
  The PR that added the gate had stated the rule in a comment two lines above it. Its own
  control fixture carried a calendar with zero failures, so the panel never rendered in the
  healthy case either and the test could not see it vanish, which is L159. Distinct from L98,
  a watcher reporting success having found nothing to watch, and from L215, a reader
  answering empty when its own accessor throws: here the guard is present and correct and
  simply covers one of two inputs)

- **L531. A validator placed on the path an input is ASSUMED to arrive by is absent on every
  other path that can produce the same input, and its message inherits the same assumption, so
  it names an origin it never measured.** Put the check on whatever CREATES the value, and let
  the message say where the bad value actually is rather than where it is presumed to have come
  from. (claude-config#248 and #249, 2026-08-31: the malformed lesson check ran only on the pull
  path, on a stated assumption recorded in a comment beside it, that the other Mac is where
  somebody wrote it. L530 was written on this Mac and sat unreadable for hours: missing from the
  index that loads into every session, unreachable by the lookup command, the duplicate check and
  the number minter, with nothing anywhere reporting it, until an unrelated pull happened to run.
  The message then said the entry had arrived, which sends the reader to investigate the machine
  that had nothing wrong with it. Distinct from L332, a pass wired to startup being blind to what
  is written later, and from L280, one stage of a pipeline not enforcing a rule for the pipeline:
  here the check is correct and simply sits on one of two ways in)

- **L351. A reporter that folds a child's failure into a single summary row keeps only the FIRST
  line of that failure's message, so a message written summary first, with the files, counts and
  remedy beneath, loses precisely the part that says what to do.** Carry every line of a captured
  failure, or the reader rediscovers at cost what the reporter already held.
  (claude-config#253, 2026-08-31: run-all-tests.sh printed `FAIL: no file has gained a short
  circuiting pipeline (these have:` and stopped there, on an open parenthesis. The ratchet had
  already named both offending files, both counts and the fix for each, and none of it reached
  the CI log, so diagnosing the red build meant checking the failing commit out into a worktree
  and running the suite by hand to read a message the runner had been handed three minutes
  earlier. Distinct from L148, where the reason dies with a transient surface, and from L194,
  where a payload reduces a fact to a flag: here the whole message was durable and present, and
  a formatter that renders one line per suite took line one)

- **L357. A counter that renders its number on a screen is not a detector, because detection
  requires something that speaks on its own when the number is wrong.** Until then the instrument
  and its absence are the same thing and the defect is still found by the person noticing, which is
  the state the instrument was built to end. Measured 2026-09-01 (overture#3435): Overture already
  held `QueueRenderCounter`, which counts every whole store derivation, records which input
  triggered each one, compares the rows produced, writes a rotating log and draws "derived N,
  reason" on screen. It had been there for months while the app froze for up to 58 seconds at a
  time, and a planning panel reading the same code proposed building it. Nothing read it, nothing
  alerted on it, and so nothing about it was detection (L13, L98).

- **L532. A form that falls back to a DEFAULT when nothing is stored cannot show that a save
  failed**, because on the action whose whole job is to write that very default, the fallback
  and the saved value render identically. Confirm such a write by reading back the STORED
  value, and make any monitor look for the empty CONTENT rather than the missing container.
  (Try-Pennie/slate#1670, 2026-08-31: the admin "apply company default hours" button ran a
  delete then an insert with neither error bound and no transaction, while every other writer
  on that path went through an atomic RPC that refuses unless the row count matches. A failed
  insert left the agent with a schedule row holding no rules, so `isWithinWorkingHours`
  rejected every instant and they offered no times at all, permanently. The reloaded page
  rendered `workingHoursDays(rules, org.default_weekdays)`, so zero rules ticked the org
  default week and the admin saw exactly the week they had asked for. The coverage monitor
  missed it too, because it looked for agents with no `availability_schedules` ROW and this is
  a row with nothing in it. A pure `planUniformSchedule` already existed, was tested, said in
  its own docstring that it was what this button meant, and was called by nothing. Distinct
  from L67, a placeholder standing in for a missing required value, and from L138, a missing
  setting rendering as empty: here the fallback COINCIDES with what the person intended, so
  there is no discrepancy for them to notice)


- **L536. A language or API that silently yields NOTHING for a construct it does not support
  makes the FIX indistinguishable from the BUG**, because the natural remedy for a missing
  value (a default, a fallback, a coalesce) produces that same missing value. Support the
  obvious spelling or refuse it loudly, but never accept it and return nothing.
  (bidspoke#1097, 2026-09-01: 23,786 Salesforce patches in three days dropped a field whose
  template resolved to undefined, and the obvious fix, `{{steps.x.output.bid ?? 0}}`, resolves
  to undefined as well: a bare number is not a valid reference root, and the number literal
  rule is consulted only inside the arithmetic branch, so `?? 0 + 0` yields 0 while `?? 0`
  yields nothing. Someone applying that fix would see the same dropped-field warning
  afterwards and have no way to tell a fix that did nothing from one that worked. The
  limitation was already known: the code node beside it carries the comment "Templates can't
  do math / ?? / || / dynamic keys, so we compute here". The platform simply never said so.
  Distinct from L111, which is about a recovery MESSAGE naming a step that does not change the
  state: here the remedy itself is accepted and quietly does nothing)

- **L550. A component that omits a state because of an assumption about ALL its callers (every
  action redirects with an outcome, every parent supplies the context, every input was validated
  upstream) is correct only while that assumption holds, and nothing enforces it, so it breaks at
  the first caller that does not honour it.** Enforce the assumption in the type or a guard,
  because the comment explaining the omission makes the gap read as a considered decision and
  nobody re-examines it.
  (Try-Pennie/slate#1769, 2026-09-02: SubmitButton reports started, still alive, and stalled, and
  deliberately has NO success state. Its docstring gives the reason: "A real failure comes back on
  the page as its own message (every admin action redirects with an outcome), so this covers the
  case where nothing comes back at all." True of the actions it was written for. setBookable
  returns void and calls revalidatePath on a different route than the form is on, so pressing Make
  bookable made an agent bookable and said nothing at all, which Dan reported as "it worked but it
  didn't immediately look like it did anything". The docstring is why nobody added a success
  state: the omission looked answered. Nineteen files adopted the component and eight still have
  bare buttons, so the assumption was never enforced anywhere)

- **L589. A relative time or magnitude ("4 hours before", "2 days late") must name what it is
  relative TO, and where that anchor can MOVE between records it must name WHICH anchor it used,
  because otherwise a perfectly truthful history reads as corrupt.** The numbers change while the
  wall clock does not, so the reader concludes the data is wrong rather than that the reference
  moved, and the record loses its authority at the moment somebody is relying on it.
  (Try-Pennie/slate#1943, 2026-09-04: a booking's history showed three entries all stamped
  `Fri, Sep 4, 11:18am` and then `4 hours before`, `3 hours before`, `2 hours before` down the
  page. Every value was right: `formatLeadTime` measures notice given relative to THE APPOINTMENT,
  and each reschedule had moved the appointment later, so the notice period grew while the
  recording clock stayed inside one minute. Dan read it as a defect. The phrase also named no
  object at all, and the reader's only available guess, that it was relative to the neighbouring
  entry, is wrong. Two fixes, and the second is the one nobody thinks of: state the anchor, and
  state which value of it)

- **L593. Write an audit or provenance record at the LOWEST layer every invocation path shares,
  usually the database function or the store itself, never in the API route or the UI handler.**
  The record then survives the same action being done by hand, by script, or by a future second
  entry point. A record written in the route is lost precisely when somebody bypasses the route,
  which is the occasion it was most needed. This is the prescriptive half of L379, which describes
  the failure; this says where to put the write so it cannot be omitted.
  (Try-Pennie/slate#1961, 2026-09-04: a data subject erasure is audited in two halves.
  `src/lib/audit.ts:59` records that the Supabase half, `pii.erasure`, is written INSIDE the
  `erase_booking_pii` database function, so it lands however the function is called, including from
  a hand-run statement. The Snowflake half, `pii.warehouse_purge`, is written by
  `/api/admin/erasure-purge`, so it exists only when somebody clicks the button. Dan asked to remove
  the UI control and run erasures through Claude instead, and the same compliance action would then
  keep one audit entry and silently lose the other. One codebase, one action, both designs, and the
  difference decided whether his plan was safe)

- **L612. In a shell running with `set -e`, a bare assignment from a command substitution carries
  that command's exit status, so a capture-then-classify step dies on the capture line, the captured
  output is never printed, and every branch of the classifier below it is unreachable dead code.**
  Capture the status explicitly whenever the failure is something the code means to INSPECT rather
  than abort on, because the classifier reads as the careful handling and its unit tests pass while
  nothing can ever reach it.
  (project-enrollment-tracker#1305, 2026-09-06: the daily build's feed gate ran
  `SFTP_OUT=$(echo "ls ..." | sftp ... 2>&1)` and then classified the output into found, not-yet and
  broken. Verified against the live server, sftp exits 1 on a clean not-found, so the step aborted
  on the assignment. The not-yet branch, added by #462 precisely to tell a missing file apart from a
  broken connection, had never once executed, and a real two minute connection timeout on 2026-08-25
  left a log holding nothing but the exit code, because the diagnosis was sitting in the variable)

- **L622. A state meaning NEVER RECORDED, separated from the failure state only in the WORDING of
  the response while taking the same ACTION, is not separated at all**, so the first run after a
  stamp based check ships fires on every subject at once. Seed the stamps in the same change, or
  keep the never state silent until one full cadence has passed.
  (project-enrollment-tracker#1335, 2026-09-07: #1185 replaced a silent webhook probe with a real
  delivery, so a Slack connection quiet past its window gets a check message and only a failed
  check speaks. `staleConnections` returned `never` and `stale` as separate reasons, with a comment
  citing L11 saying a never proven connection on a fresh rollout must not page, but the caller
  looped over both and sent to each. No delivery stamp existed yet, so the first scheduled run
  posted a machine line into both channels at once, one of them #management, which the seven sales
  team leads read. The wording was ready for the case; the control flow had never been)

- **L427. A probe posted on a fixed interval that does not wait for the previous one to return
  records one event per interval that a single outage lasts**, so the outage's DURATION becomes its
  event COUNT and every total taken from that log scales with how long things were broken rather
  than how often. Make each probe wait on the last, and count the ones it skipped, because a
  skipped probe that is silently dropped makes a wedged prober look like a healthy one.
  (overture#3635, 2026-09-07: `MainThreadWatchdog` posted a ping to the main queue every 250ms and
  never waited, so during a freeze the pings queued and all ran in the same instant when the main
  thread drained, each recording its own lateness. One freeze wrote a strictly decreasing series
  D, D-0.25, D-0.5 down to the floor, one record each. Measured on Dan's live log: 611 records for
  129 real freezes, 79% duplicates, one 13.95s freeze wrote 47 of them, and the summed unresponsive
  time read 1,629s against a real 254s. The app told him in its own voice that it had stopped
  responding 611 times. The MAXIMUM was untouched, which is why every conclusion resting on the
  worst stall survived and only the counts and totals were wrong)

- **L431. A guard that skips expensive work when its inputs are unchanged saves nothing unless
  computing its KEY is cheaper than the work**, and a key derived by walking the whole dataset is the
  same sweep the cache was meant to avoid, paid on every pass whether anything changed or not. Price
  the key against the work it gates, and build it from something already maintained rather than from
  a fresh scan.
  (overture#3645, 2026-09-07: the Sources sheet cached three expensive derivations behind SwiftUI
  `.onChange` keys, added by three separate issues that each measured a real freeze. But SwiftUI
  evaluates a change key on every body pass, and all three keys were themselves whole-store
  derivations: one hashed every prospect and sorted each row's source ids, one filtered all 1,224 rows
  with two string trims each and then faulted their contacts and ran the full stage predicate, and the
  third built and sorted a facet array per source and per client. A fourth, an O(clients x sources)
  fuzzy match whose own source says a previous issue measured it freezing this sheet, was passed as an
  argument to one of the keys and so evaluated at the call site every pass, uncached. Measured by the
  app's own watchdog: 30 freezes on that surface in one day, median 1.34s, which is worse than the
  queue every performance issue so far had been about. Nothing reported it because that surface has no
  lifted pass, no counted corpus and no cost test, unlike the queue beside it)

- **L440. A message softened so it stops claiming something the check did not measure must then STATE
  what the check DID measure**, or the vaguer sentence is truthful and uninformative at once, and it
  sends the reader hunting for a fact the code was already holding at the moment it composed the
  sentence. Refusing to overclaim is only half the rule (L11): the other half is naming what was
  found.
  (overture#3672, 2026-09-07: a date header in Overture's queue reads "Another pitch is already in
  progress on a night one of these runs plays". The wording is deliberate, because the check reads
  every night of a multi night run and the clash it reports is often not the header's own date, so
  the earlier "on this date" would have been a claim about the date printed directly above it that
  the check never made. What it gave up is the night itself, which the same code has in hand: the
  function deciding which of the two wordings to use walks the very overlaps that carry the night,
  and the sibling sentence on the row below already renders one as "Oct 29". Dan read the banner,
  could not tell whether the clash was on the header's date or a later night of a run filed there,
  and asked. The fix is not to restore the false claim, it is to say "on Oct 2")

## State and identity

- **L339. A generator that seeds from system entropy when no seed is supplied produces a
  different artifact on every run, so any comparison between two versions of it measures the
  seed rather than the change, and any cache keyed on its inputs is silently wrong.** Persist
  the seed at first use and treat an absent one as a defect rather than a default.
  (postroll#1061, 2026-08-30: proving a render refactor was a no-op by diffing the old and new
  mp4s showed 23% of pixels differing, which reads exactly like a broken renderer; the cause was
  `random.Random(None)` in the collage layout, because the event stored `reelSeed: null`. The
  same absence is a live product defect: every regenerate reshuffles the whole gallery, so
  changing one photo re-lays-out all 234, and the pre-render cache fingerprints the inputs as
  `seed:nil` so it can adopt a render of a different collage entirely.)
- **L602. A bound applied to ONE derived value (a clip to an active window, a cap, a cutoff)
  must be applied to every SIBLING derived from the same input**, because the surface then
  shows the bounded figure beside unbounded ones about the same subject, and the careful one
  is the only evidence anybody looked.
  (pet#1300, 2026-09-05: a rep's days-worked count is clipped at the day they left the company,
  deliberately and with its own issue behind it, so a departed rep stops accruing days they
  were not employed for. Their pace and their end-of-month forecast are derived from the same
  rep and the same month and were never clipped: pace divides by the whole month elapsed so
  far and the forecast multiplies by the whole month's working days. A rep who left on the 1st
  having sold two deals reads as 1 day worked and 4.4 units projected, and that forecast feeds
  the headline number at the top of the board)

- **L14. Derived state re-derives on every input that feeds it, and every action updates
  every surface showing what it changed.** Enumerate the inputs, then the surfaces; a
  correct save that still shows the old value reads as a failed save. (25 issues, 3 repos)
- **L15. Key everything on stable identifiers.** Never mutable strings, display names,
  positional indices, or fabricated fallbacks; when a key must change, record the
  old-to-new mapping for everything still holding the old one. (16 issues, 4 repos)
- **L421. A write that SKIPS because its destination already exists must verify that the destination
  holds what it expects, or a damaged or foreign file at that path is silently adopted as this write's
  own result and the record pointing at it carries a value nothing checked.** The moment of writing is
  the only one where the correct content is in hand, and every later check can say the record and the
  file disagree without being able to repair it. The mirror of L145: that one covers a write landing on
  an occupied destination, this one covers a write declining to happen because the destination is
  occupied. Applies to content addressed storage, caches, uploads that skip on a matching name, and any
  "already done" test in an idempotent job.
  (ovation#90: documents are stored under a path derived from their content hash, so storing the same
  receipt twice correctly reuses the existing file, and it returned on a bare file-exists test without
  reading the bytes)

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
- **L342. Share a predicate only where both call sites ask the SAME question.** Reused for a
  DIFFERENT question that merely agrees with it today, it silently imports every unrelated
  condition it carries, and because consolidating a predicate is normally right (L16), the
  reuse reads as good practice and survives review. (overture#3367: the card's reachability
  verdict asked `isSendablePending`, which requires no uncleared calendar conflict, no missing
  subject line and four content guards, so blocking a night made 11 prospects report no
  address while their addresses sat in the store)
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
- **L275. An image drawn small must be DECODED small, because the renderer decodes the WHOLE
  source file to build its texture, and the platform discards that texture whenever the app
  leaves the foreground.** The full decode is then repaid on the main thread every time the
  person comes back, so a grid of thumbnails backed by originals blocks the window on every
  return to it, and nothing in the code reads as expensive: the cost sits inside the draw
  rather than inside anything the app calls. Produce a copy at the size it will actually be
  shown, cache that, and hand the view the copy. Related to L91, which is a derivation the
  app itself runs; here the app runs nothing and the platform charges it anyway.
  (PostRoll#966: switching away from the app and back froze it for a second or two. A 24
  second sample over three activations put 890 of 1051 main thread samples in the
  CoreAnimation commit, inside JPEGDecompressSurface, while the app's own Swift code took 16
  samples in the whole profile. Photos were 2500x1667 drawn into 80pt cells, with no
  downsampling anywhere in the codebase, and a RenderBox SurfacePool thread was visibly
  collecting the cached surfaces)
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


- **L318. A setting that acts as a DEFAULT is usually read at USE time by every item that never
  overrode it, so changing the setting silently rewrites all of them**, which is the opposite of
  what the word default leads everyone to expect. Either stamp the value onto each item as it is
  created, or make changing the setting name the existing items it changes and what that rebuilds.
  The trap is that the read looks obviously correct (`override ?? current`) and the copy beside the
  control usually says "for new items", so the code and the wording agree with each other and both
  are wrong about what happens. It bites hardest where the value has downstream artifacts: the
  items change meaning while their generated output was built for the old value, and nothing
  reports the mismatch because nothing ran.
  (PostRoll#1025: the app wide posting layout changes the layout of every event that never touched
  its own control, rebuilding nothing, so those events keep images and captions built for the
  previous layout. Found while putting the per event control on more screens, which made the
  asymmetry visible: the per event control confirms and rebuilds, the app wide one does neither)


- **L317. A type whose two halves of a round trip are maintained differently, one generated by the
  compiler and one written by hand, silently drops every field added afterwards**: the generated
  half writes it and the hand written half never reads it back, so the value saves and then resets
  to its default with nothing failing. Keep both halves generated, or assert an encode, decode and
  compare round trip in a test.
  Distinct from L510, which is about rebuilding an object from a list of the fields somebody
  happened to name: here nothing is rebuilt and no list is written, the two directions are simply
  authored by different people at different times, and the hand written one is usually there for a
  narrow reason (tolerating a missing key on an old save) that has nothing to do with the field
  being lost. The field is present in the model, present in the key list, and absent from exactly
  one function, which is why review does not catch it.
  (PostRoll#1022: 34 hand written decoders across 10 files, every one paired with a synthesized
  encoder. PostRoll#1001 is two account types with the same shape, and PostRoll#1008 walked into it
  again on a caption type the same day, avoided only because the decoder line was added by hand at
  the time)


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

- **L326. A chain of fallback matchers gives no redundancy when every arm reads a field from the
  SAME upstream payload**, because one change at that source moves all of them together and the
  chain falls through to create a duplicate. List what each arm actually depends on, and keep at
  least one keyed on something the source does not restate (its own id, a stored relationship, an
  overlap in time).
  (overture#3278: five ways to recognise a stored show, the natural key of title plus date plus
  venue, two URL arms, a production-id arm and a stable-source arm, and one source changing its
  listing URLs and dropping a subtitle from every title on 2026-08-09 defeated all five in a single
  sweep. Ten duplicate rows were minted, the orphans then accrued a miss per scout and rendered as
  "No longer in the feed, may be cancelled" on shows still playing: 13 of the 31 warnings on screen
  were wrong, and Dan dismissed three shows twice.)

- **L261. Several behaviours a design treats as ONE condition (this run is not real, this
  tenant is internal, this build is disposable) must all read ONE predicate**, because separate
  predicates drift into disagreement in silence and the safety reasoning written for one then
  ships attached to the other. (downbeat#436: "this launch is not a real one" drove two
  behaviours. The database asked `isRunningUnderTests()` and the Ovation invoice queue asked
  `isDebugBuild`, and nothing anywhere put the two side by side. A Debug run from Xcode is not a
  test process, so it opens the REAL database while its invoice records go to a throwaway
  directory the consumer never reads: a real booking, with real folders, real tasks and real
  calendar events, structurally guaranteed never to be invoiced. The comment justifying the
  queue split had been written as though both gates were the same one, asserting "launched from
  Xcode with a throwaway in-memory store, so anything it commits is fictional", which was never
  true of any build. Nothing could have caught it, because each gate is correct read alone and
  the contradiction exists only between two files. L32 covers a doc that has gone stale and L204
  an invariant a change removed; this is neither, the two gates were never the same)

- **L327. When a record's identifier is minted from whichever route it happens to carry (an
  email, else a prefixed URL, else a generated handle), any sort that breaks ties on that
  identifier orders by which KIND of route the record has** rather than by anything anybody
  chose, so which item comes first is an alphabetical accident between two namespaces while the
  code reads as a deliberate ranking. (overture#3284: `Recipient.makeId` mints the canonical
  email when there is one and the literal string "form:" plus the URL otherwise. Contacts sort
  by role rank with ties broken by id, and on a self produced show every performer shares one
  rank, so the tie break decides. "form:https://..." sorts ahead of every address beginning g
  through z, which meant the card's "who this draft is addressed to" line named a contact with
  no address, and therefore one the send path structurally excludes, on both live cards Dan
  looked at. The two ordering rules are each defensible alone: rank by role, then something
  stable. Nothing said the stable thing sorts by route type. L15 is about keying on a stable
  identifier and L170 about a criterion that never fires; this is a criterion that fires and
  ranks by an attribute nobody meant to rank by)

- **L332. A repair or cleanup pass wired to STARTUP is blind to everything the running system
  writes after it, so the state a person actually works in is the un repaired one.** Schedule it
  on the event that CREATES the mess (an import finishing, a sync, a background run) rather than
  on the process starting, and remember that every sibling pass in the same startup block carries
  the identical blind spot. L175 is the read side twin, a value read once at startup going stale;
  this is the write side, where the pass runs correctly and simply never sees the newest rows.
  (overture#3316: `SameNightTitleVariantMerge` collapses one show billed two ways on one night and
  has exactly one caller, `LaunchMigrations`. Measured on the live store 2026-08-30: the launch ran
  at 13:03:58, the scout wrote a second card for the same Sep 8 show at 13:07:36, and 16 of the 19
  duplicate clusters in the store were minted after that launch. The matching rule already called
  every one of them one show; nothing had run it since they arrived, so Dan met 16 shows twice in
  the queue he triages and asked why)

- **L334. A deduplication that breaks a tie by AGE systematically keeps the copy holding the
  STALEST picture of the outside world, because being stored longest is exactly what gave it time
  to go stale.** Rank survivors by what each copy still asserts about that world (is it still
  listed, still valid, still reachable, still scoring what it scored) and let age decide only when
  nothing else separates them. The ladder reads as careful precisely because every rung above the
  tie break is about something real, so nobody re-examines the rung that actually fires.
  (overture#3328: `SameNightTitleVariantMerge` prefers an outreach record, then the richest contact
  list, then a probed row, then `candidates[0]` of a cluster sorted by `ingestedAt` ascending.
  Measured across a real launch 2026-08-30, 15 groups collapsed and 7 kept the worse copy; in 4 the
  survivor was a show the feed had stopped listing 2, 14, 22 and 48 sweeps earlier while the copy
  currently on sale was deleted, so Dan's card now reads "may be cancelled" and scores 0 for a show
  still selling tickets)

- **L335. A deduplication that deletes the copy whose identity the UPSTREAM SOURCE publishes gets
  that duplicate back on the very next sync, so the merge repeats forever and destroys the fresher
  row every time.** The survivor must adopt the live copy's key, link or external id before the
  loser is deleted, or the collapse is undone by the next import and nothing anywhere reports a
  loop. Distinct from L186, which is about a suppression record keyed too weakly: here the merge
  succeeds completely and is simply reversed from outside.
  (overture#3328: the surviving row kept its own `naturalKey` and `sourceListingURL`, pointing at
  the venue's own page under a long title, while the row deleted was the ticketing feed's listing
  under a short one. The next scout misses all three re-key arms, inserts again, and the following
  launch merges it back into the stale row, once a day until the show passes)

- **L343. A collection read from a store carries no order unless the read declares one, so a list
  rendered straight from a query result appears in whatever order the store happened to return.** That
  order is not a promise: it can differ between runs and between machines, and no test notices, because
  a test that asserts membership says nothing about sequence (L228). Declare the sort at the read, or
  sort between the read and the screen, and declare where a record missing the sort key goes and what
  breaks a tie, since both are otherwise decided by the same non-promise.
  (overture#3375: the prep picker listed eleven kept shows as Sep 16, 14, 11, 19, 8, 21, 14. Its source
  was a `@Query` carrying an eligibility filter and no sort descriptor; measured the same day, 7 of the
  app's 70 store reads declare an order. Dan found it by looking at the screen. overture#3378 covers the
  class)

- **L349. A result the mutating action ALREADY RETURNED must be rendered from that return value,
  never left to a re-fetch or refresh to bring it back, because that read races the write it is
  reading and, when it loses, the person sees nothing from an action that fully succeeded, which
  is indistinguishable from the action having failed.** The action holds the answer at the moment
  the person is still looking at the control, so keep the re-fetch for whatever ELSE the change
  affects and never let the result itself depend on it.
  (nursedex#831, 2026-08-30: the family reveal spec failed all three attempts on a tree with no
  application changes. The reveal row was written, the slot spent, the action returned 200 and the
  refresh fetched a fresh render 770ms later, and the page still rendered the un-revealed state for
  the full fifteen seconds the spec waited, while the retry passed in 4.2s. `revealNurse` returns
  the contact on success and the button threw it away, so at the moment the family was looking at a
  button the browser was holding the email. nursedex#857 covers the class)

- **L358. A unique user count from a client side analytics tool counts the identities that tool
  has ISSUED, never people, and any environment that isolates or clears storage (an in app
  browser, a private window, a fresh device) turns one person into several, always inflating the
  figure. Near zero overlap between two populations that plainly SHOULD overlap is evidence of
  that fragmentation rather than of independent audiences, so measure the overlap before
  reporting either count as a headcount.**
  (nursedex#870, 2026-09-01: PostHog reported 1,189 social visitors in 30 days, and exactly ONE
  of them carried both an Instagram and a Facebook referrer. That is impossible as a fact about
  people and is entirely an artifact: each app opens links in its own in app browser with
  isolated storage, so one person arriving through both, or returning through one, lands as
  separate anonymous ids, and the tool can only join them once somebody logs in, which 142 people
  ever had. A message quoting the figure as people had already been drafted for a third party
  before the overlap was measured. The conversion RATIO survived, because the same inflation
  applies to both ends of the funnel, but the audience size did not)

- **L359. A URL that carries a freshly minted credential (a signed storage URL, a presigned
  link, a tokenised CDN path) is a NEW cache key on every render, so every cache downstream of
  it, the CDN, the image optimiser and the visitor's own browser, MISSES forever while still
  returning the correct bytes. Re-sign on a schedule and reuse the URL, or put a stable path in
  front of the signing, and prove it with a cache HIT on a second load rather than by reading
  the code.**
  (nursedex#871, 2026-09-01: nurse photos live in a private Supabase bucket, and
  `getSignedPhotoUrl` minted a fresh signed URL per render. The token was good for four hours
  but a new one was issued every request, so Vercel's image optimiser saw a new source URL every
  time: `x-vercel-cache` was MISS on 30 of 30 photo requests, and two loads seconds apart
  produced different URLs for the same nurse. A phone downloaded only 6 KB of images and spent
  5,247 ms waiting for 7 of them, 928 ms for a single 1 KB avatar, because the optimiser refetched
  and re-encoded each one from scratch; on LTE the directory sat on skeletons for about thirty
  seconds. Nothing was broken, every byte was correct, and it was invisible for months: it
  surfaced only when Dan opened the page on his own phone. Vercel also bills per transformation,
  so the same photos were paid for on every view. L289 says such a fast path fails silently; this
  is the construction that guarantees it)

- **L368. A one-shot observer or trigger that records itself as FIRED before confirming its work
  succeeded turns a transient failure into a permanent loss, because nothing will ever try again.**
  Set the done flag from the RESULT, not from the attempt, and leave the watcher connected until the
  work is confirmed. Measured 2026-09-02 (nursedexapp/nursedex#869, #894): an IntersectionObserver on
  a homepage call to action captured an analytics event the moment the button appeared, set its fired
  ref, and disconnected. PostHog initializes inside a Suspense boundary, so the capture ran before the
  client had loaded, returned silently, and the sighting could never be recorded for the rest of that
  visit. The instrument would have reported that nobody reaches the button no matter what was true,
  and a homepage redesign was about to be decided on that number. Two halves to the fix and both are
  needed: the capture helper reports whether it actually sent, and the one-shot only marks itself done
  when it did. The sibling of L121, where a recorded success marker suppresses a later repair: there
  the marker outlives the artifact, here it outlives nothing at all because the work never happened.

- **L544. A value and the flag describing how it was obtained (the load failed, it is stale, it is
  a built in default) are ONE fact and must be one discriminated value, never two pieces of state
  beside each other.** Two can disagree about the same reading, and the screen then contradicts
  itself while each half is correct in isolation. Deriving one from the other's contents is the
  same trap wearing a disguise: an empty list is a real answer, not evidence that nothing arrived,
  so a "has anything loaded" test written as "is the list non empty" reports a genuinely empty
  list as a failed load. (new-agent-onboarding#711 held a trainer list and a trainersFailed flag
  as separate props, which is what makes the wrong one of two opposite warnings expressible; the
  same session shipped the emptiness version of it in a checklist re-read and a test caught the
  screen blaming the network for a trainer who had genuinely been removed)


- **L594. A control holding several values in ONE text box (a time with its am or pm, an amount
  with its currency, a number with its unit) is edited a fragment at a time, and deleting one
  fragment leaves a value that is still WELL FORMED under a different interpretation, so every
  refuse the invalid guard passes it silently.** Validate what a PARTIAL EDIT can leave behind,
  not only what somebody types from scratch, because the value that survives is readable, in
  range, and means something the person never asked for.
  (slate#1964: double clicking the minutes in "5:00pm" selects "00pm" by the browser's word
  rules, so typing 15 leaves "5:15", which parses as a 24 hour reading and saves 5:15 AM.)
- **L555. Matching a query against several fields CONCATENATED into one string makes the joining
  separator matchable, so a query spanning the boundary matches text that exists in no record.**
  Match each field separately. Note which way this one hides: stripping the separator from the
  query means no query can ever reach it, so the defect is unreachable until somebody removes the
  stripping, and the change that IMPROVES the search is what exposes it.
  (Try-Pennie/slate#1791, 2026-09-03: the roster search built `${name} ${email}` and substring
  matched a trimmed, lowercased query against it. Dan asked for a trailing space to mean end of
  word, so "John " would find John Kite and not Andrew Johnson. Honouring the space makes the
  invented join space reachable too, so "kite jkite" would have matched John Kite across the gap
  between his name and his address. The two other search boxes in the same app already matched
  name and email separately, so the joined one was the outlier and nothing compared them)
- **L384. A field stamped on the UPDATE path and not on the INSERT path leaves every freshly
  created record without it, and the gap is invisible because every record that has ever been
  updated looks correct, so the population missing it is exactly the newest one. Stamp it where
  the record is CONSTRUCTED, and measure the field's presence against record age rather than
  reading the writer.** (overture#3495, 2026-09-03: `ScoutService.apply` set `scoutGroupName`
  and `scoutVenue` on every re-ingest while `ScoutService.make`, the insert, set neither. Those
  two fields are the anchor the natural key is computed from, added by #1886 precisely so a
  display rename could not move a row's key, so a freshly minted row had no anchor at all.
  Measured on the live store: 9 of 9 rows first seen that day carried neither field, against 372
  of 381 rows re-ingested the same day carrying both, which is the shape this defect always has.
  The same function already carried the correct version of the rule one field over, in a comment
  from #1663: "stamp the decider on the way in, so the FIRST time a second source touches this
  row the precedence rule already knows whose genre is sitting there. Without it every new row
  would spend its first collision unprotected." A repair elsewhere, `ProspectMutations.renameGroup`
  backfilling the name half when it happens to be nil, hid the name half of it and left the venue
  half uncovered.)


- **L563. A sync that refreshes only the records its upstream QUERY returned leaves every
  record that query stopped matching frozen at its last synced values, and a frozen copy is
  indistinguishable from a freshly confirmed one.** Reconcile the rows you already hold
  against the rows the query returned, and either clear what you can no longer confirm or
  report the divergence. (Try-Pennie/slate#1833, 2026-09-03: the roster sync selects
  Salesforce users with IsActive true AND at least one debt tier flag set. A Sales Manager
  whose tier flags were all cleared dropped out of the result set, so his Slate row kept its
  2026-08-04 attributes, including a backend servicer of Beyond that Salesforce now says is
  false. Slate went on presenting the month old copy as current fact on the admin surfaces,
  and it was one of only two rows making the Beyond tiers look staffed at all. The sharper
  cost is that the row's own routing flag is frozen too: clearing those tiers is how somebody
  is taken off rotation for leave, and the reap step deliberately acts only on a positive
  inactive from upstream, so the person stays flagged bookable and keeps being routed leads
  while away. The sync lane
  reported success every hour throughout, because from its side nothing had failed. Found by
  comparing three systems by hand, not by any check. Distinct from L344, a counter that keeps
  incrementing once an input stops matching, and from L211, a cleanup that deletes whatever
  its read did not mention: here the omitted record is neither accused nor deleted, it is
  silently preserved)

- **L565. A key recomputed from a record's own data is only as durable as whatever the
  recomputation CONSULTS, so an attribution resolved by asking the filesystem or a tool about a
  path stops resolving once that path is removed, and a temporary working directory is removed
  by design.** Resolve it at write time, when the location is guaranteed present, and store the
  result on the record. (danwright32/claude-config#294, 2026-09-03: the issue spool attributes a
  pending file to a project by resolving the first record's cwd through a git common dir lookup.
  Agent findings carry the worktree they ran in, AGENTS.md tells contributors to remove a
  worktree once its PR merges, so the lookup fails and the key falls back to hashing a path that
  no longer exists and belongs to no project. clear reported nothing pending, twice, with 106
  unfiled findings sitting in the very file the review names as its source, and 111 of 170
  pending records across the spool were written from a worktree cwd. Complements L186, which
  says to key on something recomputable from the data itself: here that was satisfied in letter,
  the cwd was on the record, and the recomputation still failed because it needed the world
  outside the record. Distinct from L153, a path recording where something happened to be
  rather than what it is: this path was correct when written)
- **L576. A stamp recording WHEN something was first seen must be keyed on the identity that
  DISAPPEARS when that thing is replaced, never on its descriptive attributes.** A replacement
  carrying the same description inherits the old stamp and reads as having existed all along,
  which is the one case the stamp exists to distinguish. The inverse of L186 (a key too
  ephemeral to be found again) and not what L15 asks for: the trap here is a key MORE stable
  than its subject. (bidspoke#1152, where a pg_cron watcher grants a rescheduled job a grace
  period before paging that it has never succeeded, and keys the grace stamp on the job's name
  plus its schedule. A migration changed the job's COMMAND and kept its timetable, which
  recreates the job under a new jobid and orphans its whole run history, so the job correctly
  read as never having succeeded while the stamp beside it, written 17 days earlier for the
  job's previous incarnation under the identical name and schedule, said it had been around all
  along. Both nightly rollups paged as broken 30 minutes after a healthy deploy. The code
  comment named jobid as the true identity and judged the case too rare to widen the function's
  contract for, but rescheduling to change a command while keeping the timetable is the ordinary
  way that repo tunes a job)


- **L389. A writer that only fills records going FORWARD leaves every record that existed
  when it shipped permanently unfilled, and each consumer of that data then runs correctly
  over an empty set, so the whole feature reads as working while producing nothing. Measure
  how much of the store the writer can never reach before building anything that depends on
  it.** Forward only is usually the right default for the writer itself: it fills each record
  as it is worked on, with no launch sweep and no wasted calls (L332 is the neighbouring
  mistake, a pass wired to startup that never sees the newest rows; this is the mirror, a pass
  wired to new rows that never sees the oldest). What is easy to miss is that the population
  which predates it is not a small remainder, it is EVERYTHING, because the store was complete
  before the feature and empty of the new field afterwards. L223 is the read side twin, a check
  keyed on a marker that cannot see the backlog; here nothing is even looking, and the consumer
  cannot tell an empty answer from a considered one. (PostRoll#1268, 2026-09-03: the Instagram
  account figures fetch fires only when an event's handle list settles, and #1004 shipped that
  as "No backfill of the archive; forward only", which was a deliberate and defensible choice.
  Measured on the live store five days later: `accounts.json` held 9 records, every one carrying
  a follower count and nothing else, 0 of 9 rankable against the app's own `hasEngagementData`
  predicate, and no record carrying a fetch outcome or attempt at all, so the fetch had never
  run against that book. The collaborator ranking it feeds was therefore scoring nobody on any
  real day, and three further issues in the same milestone, a photo promotion suggestion, a
  reel membership check and an accepted or declined mark, were all built to rank accounts that
  could not be ranked. Nothing anywhere reported it: every surface honestly said "not counted
  yet", which is a legitimate value for an account nobody has counted.)
- **L580. Editing something by DELETING and RECREATING it discards everything accumulated
  ALONGSIDE it, its run history, its metrics, its audit trail, so where the platform offers an in
  place alter, use that for an edit and reserve delete plus create for real creation and
  removal.** The loss is silent, and what it takes is usually exactly what the health check reads.
  (bidspoke#1156, where every migration that retuned a scheduled database job unscheduled it and
  scheduled it again even to change one setting. pg_cron mints a new job id each time and the run
  history table is keyed on that id, so each retune silently emptied the job's whole record. The
  health check reads that record, so a freshly retuned job reported as never having succeeded and
  paged, and the before and after runtime comparison that justified the retune became impossible
  for any job retuned since. An in place alter existed the whole time. Distinct from L15, whose
  remedy is to record the old to new mapping: no mapping recovers history keyed on the id that
  was thrown away)

- **L402. A control that EDITS a value must write the exact field the consuming path READS, so where a
  per item override beats a shared default at the point of use, an edit control offered over the default
  silently discards the edit for every item holding an override, while the surface reports it as
  applied.** The review surface can be perfectly honest and the defect still ships, which is what makes
  it hard to see.
  (overture#3549, where a queue card previewed a show's shared draft with the Edit button and an
  "Edited" badge under it, while the send path composed from a per recipient override that beat that
  shared body for any directly addressed performer. The confirmation sheet and a smaller "will instead
  receive" block both showed the real outgoing text, so nothing was lying, and an edit that added the
  one sentence naming a recital Dan had already photographed for that performer would have been
  discarded on send. The override had been read only since the phase that would have made it editable
  was deferred and never built, so no control anywhere wrote the field the send reads. Distinct from
  L64, which is about the reviewed artifact matching what ships: here it did)


- **L419. A sort whose primary key TIES across most of its real inputs is actually ordered by its
  tie-break, so a tie-break chosen for stability rather than meaning (an id, an insertion order, a
  hash) silently becomes the order people see, and where that id is minted from the record's own
  content it orders by that content's SPELLING.** The mirror of L170, which warns that a last-place
  criterion never fires when an earlier one carries many distinct values: here the earlier one
  carries ONE value on the shapes that matter, so the last place is the only place. Overture sorted a
  show's contacts by `sendOrderRank` and broke ties on the recipient id. On a self-produced show every
  performer shares rank 0, so the id decided everything, and `Recipient.makeId` mints the address when
  there is one and the literal `"form:" + url` otherwise, so `form:` precedes any address from g to z
  and every contact that could NOT receive the email sorted above the one that could. Measured on the
  live store 2026-08-30: four performer contacts, three ids beginning `form:` and one address
  beginning `s`. The card then named a contact with no address above a draft going to somebody else,
  and nothing about role, seniority or billing was involved. The tell is a rank field whose
  distribution you have never looked at: check how many distinct values it really takes on live data
  before trusting anything above the tie-break. (overture#3284, overture#3603)

- **L432. A default that is RE-DERIVED from a sibling field whenever that field changes hides
  itself, because the values it produces vary and read as entered, and only the constant
  DIFFERENCE between the two fields reveals it. Check any derived looking field for a fixed
  offset across the whole population before pricing, billing or deciding anything from it.**
  (ovation#112, 2026-09-07: Ovation prices every invoice from `endsAt` minus `startsAt`, and PRD
  5.3 records those as when Dan starts and stops shooting. Measured on the custody export, 16 of
  19 real bookings carried a duration of exactly 3600 seconds. `BookingDraft.defaultEnd()` in
  Downbeat is `defaultStart().addingTimeInterval(3600)`, and `BookingDraft.swift:499` re-derives
  the end as start plus 3600 whenever the start is resolved, so the end follows the start and
  nobody had ever set it. What made it invisible is that it MOVED: the 19 bookings carried 9
  distinct start times of day, so the end times were all different and all plausible, and a
  scan for a repeated constant would have found nothing. CORRECTED the same day, and the
  correction is the more useful half: Dan's process DEFAULTS every booking to an hour on purpose
  and adjusts it after the shoot, because a performing arts event runs long or short and its real
  length is not known until it ends, and all 19 of those bookings were in the FUTURE. So the
  value was a deliberate placeholder rather than an untouched default, and the first conclusion
  drawn from it, that every invoice would bill $250.00 whatever the shoot took, was wrong: it set
  19 future placeholders against 173 completed invoices and read the difference as a defect
  (L171, a control that is not scoped to the same population proves nothing). What survives is
  exactly the rule above. A provisional value and a final one that happen to agree are byte
  identical, so nothing can refuse to bill on the first, and the guard already planned for this
  (ovation#43, refuse a zero, negative or implausibly long duration) cannot fire because one hour
  is the most plausible value on the page. L548 and L113 both cover a
  default that never moves, which shows up as a column of identical values; this is the half
  that varies. The root fix is the same as L548's: record whether the value was ever set by
  anyone, since "never touched" was not a state anything could query.)

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
- **L397. A control made of two halves, a write that ARMS it (adding to a block list, recording a
  suppression, stamping that a message was sent) and a read that ENFORCES it, must have BOTH halves
  checked, because the enforcing half is the one every audit looks at and a silently failed arming
  write leaves a correctly hardened enforcement point with nothing to enforce.** The failure is
  self concealing: the evidence that the control was never armed would have been the row that was
  not written. (nursedexapp/nursedex#982, 2026-09-04. Removing a user cancels their subscription,
  upserts their address into blocked_emails and inserts the audit row, and neither write checked
  its result, so a failed ban read as a successful removal and the person could sign up again
  immediately. The enforcing read had the L42 defect as well, which is what drew the eye: hardening
  only that side would have left a refusal that is never reached because the list is empty.)
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

- **L541. A REVOKE that is PRESENT can still be ineffective, because revoking from PUBLIC does
  not remove a grant made DIRECTLY to a role, so a platform's default grants to its own roles
  survive it untouched.** Name every role in the revoke, and confirm by querying the live
  privilege ROLE BY ROLE rather than by reading the migration, because the line that looks like
  the protection is the same line that gives the false assurance. Distinct from L124, which
  frames the missing evidence as a revoke that is ABSENT: that framing is exactly what makes a
  present but narrowly scoped revoke read as done.
  (bidspoke#1101, #1107, 2026-09-02: a new function shipped carrying
  `REVOKE ALL ON FUNCTION ... FROM PUBLIC` and was still executable by `anon` and
  `authenticated`, because Supabase's default privileges grant EXECUTE on every new public
  function to both roles directly. Measured minutes after applying, with
  `has_function_privilege` per role; the sibling function called two lines away in the same code
  path was correctly closed, because #762 had already had to revoke all three by name. The
  function enumerated every watched field path on every workflow with its run counts, and the
  anon key ships in the client bundle.)

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

- **L268. A BULK query over a protected collection leaks the WHOLE collection in its ERROR
  message**, because an error quotes the operand it could not handle, so a tool's safe path and
  its failing path have OPPOSITE disclosure properties and no guard written for the safe path
  can see it. Query one element at a time, or discard the error text and report only its code,
  wherever the collection is the thing being protected.
  (downbeat#446: `drive-downbeat.sh` exists so automation cannot put Dan's client roster into a
  transcript, and it reads text ONLY where an identifier has already matched. Bypassing it with a
  raw `osascript` asking for one attribute across `entire contents as list` failed with -1728,
  because many nodes lack that attribute, and the refusal quoted every node it had been given:
  the entire Settings window, every booking row, real client names, show titles and venues, into
  the session. The tool's own guard was irrelevant, since the leak came from the error path of a
  query the tool would never have made. Related to L156, where a failure message quoting its
  target defeats a substring success check; here the same property defeats a privacy control)

- **L360. A value redacted where an object is CONSTRUCTED is unredacted by any later step that
  ENRICHES that same object, because the gate lives in the construction and the enrichment runs
  afterwards with no viewer to consult. Give the enriching function the same gate as an argument
  rather than letting it be called ungated, since every call site reads as correct and only the
  field added last escapes.**
  (nursedex#873, 2026-09-01: `shapeNurseCard` blanks a nurse's surname for a viewer without
  entitlement, carrying a comment that it is gated in the data "so no producer can ship the raw
  value by forgetting a presentational prop". It sets `photo_url: null` too, but as an initial
  value: `attachNurseCardPhotos` fills it in afterwards for every card with a photo and takes no
  viewer argument at all. So a logged out visitor saw the nurse's FACE while her surname was
  withheld, and a face identifies far better than a surname. Bio, rate and availability were all
  correctly gated in the shaper; only the field written after the shaping escaped. The survey
  result card even advertised "Full profiles, credentials, and photos" as the thing you unlock,
  beside the photo it was already showing)

- **L388. A search or filter that matches a field the viewer is not permitted to READ hands that
  field's content back one guess at a time through the result count, without ever displaying it, so
  every searchable field must be gated by the same predicate that decides whether it is shown.**
  (nursedex#935, 2026-09-03: a keyword search shipped matching `bio` and `care_philosophy` for every
  viewer. Bio was safe by accident, being the profile page's public meta description, but the care
  philosophy is hidden from anyone who has not signed up, and 30 listed nurses had written one. The
  same change had correctly gated LAST NAMES on exactly this reasoning, so the rule was understood
  and applied to one field and not to its neighbour in the same clause)

- **L616. A product whose access model is a fixed list of named users needs, from the first
  migration, a maintainer identity that can sign in and act with attribution but is excluded from
  the users' notifications and from their irreversible or money moving actions.** The builder always
  has to test the live system, and a plain extra user row puts them on every alert and lets a test
  reach the real world. Model the role in the schema and derive the notification recipients and the
  money predicate from it, never from the row count.
  (paperboi#54, 2026-09-06: PaperBoi was designed around exactly two people. Every people row
  received every reminder and Slack mention, the reminder fan-out asserted a recipient count of
  two, and anyone in the table could approve and email a payment instruction to Chase. Dan needed
  to sign in to troubleshoot; adding him as a third row would have put him on every nag and let a
  test send reach the bank. Slate had already grown an impersonation and dev preview layer for the
  same need)

## UX completeness

- **L341. A curve assembled from piecewise segments must be checked for continuity of its RATE
  OF CHANGE, not only of its value, because matching the values at each seam is what everyone
  verifies while a step in the rate is what the person actually sees.** Sample it finely and
  assert the successive differences never jump. (postroll#1061 and #1073, 2026-08-30: the scroll
  reel's `ease_in_out` was three formulas whose speed dropped 8% instantly at t=0.12 and jumped
  back at t=0.88, reported by Dan as part of the reel feeling jittery and measurable in the
  delivered mp4 as 33px a frame becoming 30. Each seam joined correctly in POSITION, so nothing
  looked wrong in the source and no check existed. Fixing it and then sampling the two sibling
  templates found the same defect in `generate_reel_slider`, ten times larger at a 75% jump, sat
  there unreported; `generate_reel_morph` was clean. The replacement ramps with smoothstep,
  whose own slope is zero at both ends, so the pieces meet without a step.)
- **L20. Accessibility is part of building each control.** Labels on icon-only controls,
  real buttons instead of tap gestures, type scaling, tap targets, AA contrast in both
  themes, reduced motion, focus management. (49 issues, 7 repos)
- **L560. An ARIA role that names a STRUCTURE (menu, tablist, list, radiogroup, table) is a
  promise about the element's CHILDREN**, so putting it on a container of mixed content tells
  assistive tech to expect a set of items and hands back a panel. Nothing catches it: the
  screen renders identically and an accessible-name test still passes. Give the container the
  role its content actually has, or make the children the items the role requires.
  (slate#1816: the header account menu was marked role="menu" while holding an email, a
  calendar status line and a theme fieldset, with only sign out as a menuitem.)
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
- **L566. An element positioned absolutely inside a scrolling container is CLIPPED by that
  container, and setting overflow on ONE axis makes the other axis clip too, because a `visible`
  axis computes to `auto` beside a non-visible one.** So a menu, popup or tooltip anywhere inside a
  scroll region must escape to the top layer (the popover API, a portal) rather than be positioned
  within it: an `overflow-x-auto` wrapper added only to let a wide table scroll sideways silently
  cuts a row's dropdown off at the bottom edge as well, and the clipping hides the focus ring, so a
  keyboard user is focused on something they cannot see.
  (slate#1843)
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

- **L399. An instruction to a person must be written in the vocabulary of the place they will
  act, never in the terms of the constraint that motivated it.** A phrase that names where
  something must NOT go has no referent at the destination, so it reads as accurate inside the
  app that wrote it while being unusable at the surface where the person is standing, and the
  test that would catch it is reading the sentence there rather than in the code.
  (PostRoll#1367: the details block's help text said "Paste below the post, outside the post
  body", which describes the app's own rule that the block must stay out of the AI round trip;
  Squarespace has one content area and no "post body", so Dan pasting into it was left asking
  what to do with the block)

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

- **L568. Replacing a native form control with a custom one silently drops everything the platform
  was supplying for free: submission by `name` inside the form, keyboard operation, type ahead,
  screen reader semantics, and freedom from being clipped by an ancestor.** Every one of those
  losses is invisible on screen, because the replacement still looks correct and only stops
  WORKING, so enumerate what the native control was doing and test each item rather than testing
  that the new one renders.
  (slate#1849)
- **L596. A custom control placed inside a form also INHERITS the platform's form behaviours, so
  every key the control handles for its own purposes must decide explicitly whether that key still
  reaches the form.** Handling it on only some branches makes one keystroke mean "commit this
  field" sometimes and "save everything" the rest of the time, with nothing on screen saying
  which, and the branch that writes is the one nobody tested. The mirror of L568, which is about
  what such a control LOSES; this is what it silently gains.
  (slate#1968: Enter in a typeable time field called preventDefault only when a dropdown row
  happened to be highlighted, so pressing it after typing a time submitted the whole business
  hours form and wrote the org's opening hours to live data, twice, before anybody noticed)
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

- **L569. A surface token (a hover tint, a zebra stripe, a card, a header row) is one half of a pair
  with the surface BEHIND it, so a contrast check that only measures what sits ON it proves the
  text is readable while saying nothing about whether the surface is visible at all.** A one point
  colour difference then ships under a green suite, and every place relying on that surface to
  separate content separates nothing, so measure each surface against its parent as well as
  against its contents.
  (slate#1851)
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

- **L269. A finding the system cannot verify was acted on (an advisory check, a review
  warning, a flagged suggestion) must carry its own resolve and dismiss controls, because the
  person acts on it in text or in the world where nothing can observe the fix, so the notice goes
  on standing after the work is done and teaches them to ignore the whole panel.**
  (postroll#958, 2026-08-29: a caption check correctly reported a handle that was not on the tag
  list. Dan deleted the handle, and the panel's only response was to call itself stale, which says
  the text moved and not that the finding was dealt with. Stale reads identically whether he fixed
  the exact thing named or edited an unrelated word, so the panel went on quoting a handle that was
  no longer in the caption. The stale wording exists precisely to stop the panel outliving the fix,
  and it cannot, because only the person knows whether the fix was the one asked for)

- **L272. A check that can DERIVE the correct value it is demanding must APPLY it rather than
  report it, because a panel of findings the system could have fixed itself is work handed back to
  the person, and it teaches them to skim the panel where the findings that genuinely need their
  judgement live.**
  (postroll#962, 2026-08-29: one blog post came back with 23 checks to fix. Seven markers naming a
  file that was never sent, the same seven photos reported as never placed, seven alt texts over
  the app's own 25 word cap, one repeated opening, one stacked pair. Not one needed Dan's
  knowledge: every one was a rule the app wrote, evaluated, and stated precisely enough to act on.
  The code's stated reason for reporting rather than rewriting was that alt text cannot be
  rewritten without seeing the photograph, which was already false in the same repository, since
  the photo swap path writes alt text with the images attached. The genuine risk, stacking a second
  guess on the first, is answered by re-running the check and keeping the original unless the fault
  is gone, which the caption side was already doing. Distinct from L269, where the system CANNOT
  observe the fix and so needs the person to close the finding: here it can compute the fix, so
  asking at all is the defect)

- **L526. A store that collects items for a PERSON to act on is only as useful as the rate they
  can be taken out of it, so size the drain against the rate it fills.** A surface offering four at
  a time on a cooldown cannot empty a store gaining hundreds, and an item that is never offered is
  indistinguishable from one that was never captured, which is the loss the store was built to
  prevent.
  (claude-config#201: the subagent finding spool held 246 pending findings for one project while
  the only way out of it was an end of turn picker showing 4, on a 30 minute cooldown, so clearing
  the backlog would have taken sixty odd reviews and in practice never happened)

- **L279. A record's usefulness that depends on a COMBINATION of individually optional inputs is
  stated nowhere, because each field reads as independently optional at the point of entry, so
  name the requirement on the form itself and give the partly filled state its own label saying
  what is still missing.** Otherwise somebody enters a real value and is told, correctly by the
  rule and falsely as English, that nothing was entered. L11 covers the label once the record
  exists; this covers the requirement being invisible while the person is still filling the form,
  which is the only moment they could act on it.
  (PostRoll#977: the collaborator numbers dialog takes followers, likes and comments, all
  optional, and ranks only on an engagement rate needing followers plus at least one of the other
  two. Its copy said "Leave a field empty if you do not know it", true of each field alone and
  silent about the pairing, and a followers only record then reported "Not counted yet", the same
  string used for an account nobody had ever opened, immediately after a follower count and a date
  had been stored for it)

- **L287. A notice computed over a WIDER scope than the screen it is placed on inherits that
  screen's scope from its position, so a sentence that is accurate about the whole collection
  reads as a false claim about the one record on view. State the scope inside the message rather
  than trusting the reader to know where its numbers came from.** The message itself is never
  wrong, which is why nothing catches it: the check measured the right thing and the wording
  reports it faithfully, and the falsehood is created entirely by where it was rendered. L11
  covers a message claiming more than its check measured; this is the opposite failure, a
  message whose check measured MORE than the surface implies, and the reader closes the gap in
  the wrong direction. The tell is a surface where every other element is about one record.
  (PostRoll#1012: the export screen for one event showed "@carnegiehall, @dciny, and
  @decodamusic and 4 more are tagged again and again with no numbers yet", between a banner
  describing that event's export and a list of that event's posting days. The seven accounts are
  counted across the whole library and none of the three appear anywhere in the event on screen,
  so it was read as a claim about photographs that do not exist)

- **L330. An acknowledgement a person gives must be consulted by EVERY rule that raises the
  question it answers, not only the one whose control recorded it, because a second rule
  computing that question from raw state goes on asking after it has been answered, and no
  action is then left that could ever satisfy it.** L269 is the neighbouring failure, a finding
  with no way to say it was dealt with; this is worse, because the way to say it EXISTS, the
  person used it, and the answer was written durably to a field the second rule never reads. The
  tell is a surface that shows a settled state and an open question about the same fact side by
  side. (overture#3307, 2026-08-30: Dan pressed "This page is right" on two watched calendars
  that are correct pages with no listings yet. The confirmation is live and still anchored to the
  bytes on the page, and it silences the failure. A separate never-read rule asks only whether a
  run has ever ingested shows, which a confirmed empty read deliberately never records, so both
  rows went on being counted as work he owed. Reading it again cannot help, since every read of
  such a page is another confirmed empty read, and the control that recorded his answer is not
  drawn on the row any more, so there was nothing left to press)

- **L545. A set of values whose meaning is their ORDER relative to each other (medal colours,
  severity tints, tier sizes, ranked weights) is broken by changing ONE member for an unrelated
  reason such as a contrast fix, because every member stays individually valid and nothing
  compares them, so assert the ordering itself rather than each value.** L213 is the neighbouring
  failure for a PAIR, where the two halves have to be overridden together; this is the N member
  version, and it is quieter, because what breaks it is a correct accessibility fix applied to
  exactly one member for a good reason. The tell is a palette or scale whose members are each
  named for their rank while no test mentions more than one of them at a time. (PET#1232,
  2026-09-02: Power Rankings first place was gold #D69938 until #879 darkened it to #8D6525 for
  AA, since the gold measured 2.30:1 on the page background. Nothing touched second or third, so
  third place at #B08050 was left at luminance 0.252 against first place's 0.151 and second
  place's 0.153. Dan read it off the screen as first place looking bronze and third place looking
  gold, which is exactly what the numbers say. The size ordering, 28 then 26 then 22px, still
  descended, so the row asserted one hierarchy by size and the opposite by colour)
- **L546. A screen that no navigation links to works perfectly for whoever built it, because
  they have the address, so it is invisible to every test, review and build and is found only by
  somebody hunting for it under pressure.** Enumerate the routes and assert each is reachable
  from the navigation source, exempting detail routes reached from a row by name; judging
  reachability by any link anywhere in the tree instead satisfies the check with a stray link on
  an unrelated page and measures nothing.
  (slate#1751, slate#1750, slate#1742, 2026-09-02: the PII erasure worklist, the agent pool
  drain, booking outcomes and booking reasons were reachable only through /admin/settings, whose
  own only entry point was a card labelled "Alert settings" because #1297 moved the business
  hours onto that page and renamed the page but not the door. Slate was offering times on Labor
  Day and the person who needed to close the date could not find the screen that does it)
- **L619. Every destination a navigation OFFERS must be asserted to resolve to a real screen,
  enumerated from the navigation rather than from the list of screens, because a nav entry is
  written once and then read by everyone afterwards as proof its destination exists.** This is the
  opposite direction from checking that every screen is reachable (L546), and neither check finds
  the other's failure: enumerating routes cannot see a nav entry pointing at nothing, because
  there is no route to enumerate.
  (paperboi#68, 2026-09-07: the masthead had offered Invoices, Vendors and Spend since the first
  comp, and six artboards and a full design system were built and reviewed without anyone noticing
  that no vendors list had been drawn or routed. It was found by comparing the nav against the
  artboard filenames, not by any of the guards, the suite, or three design review passes)
- **L547. A control whose work is pure computation over data the page already holds must not be
  routed through a server round trip, because on a dynamic page that round trip re-runs every
  UNRELATED read on the page, so the control's cost becomes the whole page's cost and nothing at
  the point it is written says so.** The code at the filter reads as correct and cheap, and the
  expense lives in a list of reads several hundred lines away that nobody consults when adding a
  filter, so the tell is a control that narrows no query and still costs a page load.
  (slate#1752, 2026-09-02: the admin agent search is an in memory `includes` over a roster of 136
  already in the payload, but submitting it re-rendered the force-dynamic admin page, re-running
  about twelve reads including the audit log and its exact count, webhook deliveries and cron lane
  health, before one row could change. Dan reported it as search taking too long to do anything)
- **L549. A row aligned on its children's top or bottom EDGES aligns the CONTAINERS, not the
  controls inside them, so a column carrying a hint, an error or a second label line has its
  control silently pushed out of line while every column still reads as correctly aligned when
  read on its own.** The alignment property sits on the row and each column's own markup is
  unremarkable, so the defect is invisible at both places a reader looks, and it appears the
  moment somebody adds helper text under one field. Align the control boxes rather than the
  column bottoms, either by lifting the hint out of the aligned child or by giving every column
  the same reserved space above and below its control.
  (slate#1761, 2026-09-02: the Team access row was `flex items-end`, and the email column's
  bottom edge was the bottom of its "The address they sign in to Google with" hint rather than
  the bottom of the input, so the Access select and the Give access button beside it were pushed
  down by the hint's height. Dan reported it as the right side not being centered)

- **L553. A column's header alignment and its cells' alignment are ONE fact set at two
  independent declaration sites, so they diverge silently while each site reads as correct on
  its own.** The header rule usually lives in a stylesheet keyed on the table, and the cells
  take theirs from a per column class, so nobody comparing the two is ever looking at one
  screen. Carry the alignment on the column's own class so a header cannot be set apart from
  its data, and assert that the two MATCH rather than asserting any particular value, so the
  check survives a later change of convention. The near sibling of L213, where a pair token is
  overridden by halves, and of L549, where the aligned thing is the container rather than the
  control.
  (project-enrollment-tracker#1242, 2026-09-03: ten tables across PET each decided header
  alignment independently, three conventions shipping side by side, and the All Teams
  leaderboard rendered a centred Units header over a right aligned column of numbers because
  its `sortableTh()` omitted the `th-metric` class the team board's renderer applies. Dan
  reported it from a screenshot of the column edges)

- **L558. A mark drawn BESIDE a caption of the same fact is decoration, so a spec that asks for
  BOTH ships the duplication as a requirement and no implementation can avoid it.** Decide which
  one carries the fact. A per-row mark also needs an axis shared with the rows above and below, or
  it cannot be compared vertically, which is the only thing it can do that the words cannot.
  (Try-Pennie/slate#1796 then #1812, 2026-09-03: an agent's debt tier coverage was a wrapping comma
  list of raw keys, and the replacement specced a five rung ladder glyph AND the sentence "Covers
  Low to High" in the same cell. Every row then said it twice, so the eye read the words and the
  bars were noise. The rungs ascended in height, so the commonest case, Low only, drew the smallest
  possible mark, and with no axis shared between rows nothing could be compared down the column.
  Dan's verdict on seeing it was "I hate the change made to the teams". The spec, not the build, is
  where it was decided: asking for both was the defect, and the note in the same issue saying to
  screenshot it early was the only safeguard, which is L27)

- **L577. A request to remove ON SCREEN text can be removing a control's only accessible name,
  or the target of an `aria-describedby`, and both failures are silent.** The control still draws
  and still works, so nothing on screen and no error anywhere reports that a screen reader now
  announces an unnamed box, or no description at all. Before deleting any label, hint or
  placeholder, read what NAMES the control and what POINTS AT the element being deleted.
  (Try-Pennie/slate#1889, 2026-09-04: Dan asked for three pieces of copy off the Team access email
  field, the `Work email address` label, a `firstname.lastname@trypennie.com` placeholder that was
  not even our address format, and a hint reading "The address they sign in to Google with". Every
  one of the three was a fair call on its own. The label was also the field's whole accessible name
  under WCAG 4.1.2, and the hint was the element the input's `aria-describedby` pointed at, so the
  literal reading of the request shipped an unnamed input with a dangling reference. Removing all
  three from the SCREEN while keeping a visually hidden label, and dropping the describedby in the
  same change, is identical to what was asked for and costs nothing)

- **L578. A list of RECORDS laid out as flow rows, one flex row per record, has no columns at
  all: each field's position is set by the width of everything before it, so it reads as aligned
  only while that leading field is a uniform width, which a fixture always is and real data never
  is.** Where fields are meant to be compared down the page, reach for a table or a grid from the
  start, because no spacing value can align a flow row: there is nothing there to align. This is
  the cross-row twin of L549, which is about alignment INSIDE one row.
  (Try-Pennie/slate#1891, 2026-09-04: the Team access waiting list rendered each person as one
  `flex flex-wrap items-center` row, so the access pill, the wait text and the "Check this address"
  flag started at a different position on every row, set by the length of the address before them.
  `geoff@trypennie.com` against `mrasmussen@trypennie.com` is nine characters, so the three later
  fields sat nine characters apart. `flex-wrap` made it worse than a misalignment: on a narrow
  window the flag dropped to a second line on some rows and not others, so the rows stopped
  sharing a shape as well as a grid. Dan reported it from a screenshot of five real rows; two
  seeded rows of similar length would have looked correct)

- **L579. An explanation added because ONE record's value was confusing gets attached to the
  record TEMPLATE, so it is correct at one row and becomes a wall of identical text at the real
  record count, which no fixture reaches.** Put a caveat at the level the caveat is ABOUT, usually
  the section or the column header, not the level you happened to notice it on. The placement is
  invisible at the moment of writing, because the row that prompted it is the only one in front of
  you, and it is invisible in review for the same reason.
  (Try-Pennie/slate#1760 then #1896, 2026-09-04: two numbers on the bucket editor did not say what
  they measured, one being the bucket's depth and the other the whole org roster, so #1760 added two
  clarifying paragraphs. They went inside the per bucket form. Against the live 3 digit XBC matrix
  that is about sixty forms in one scroll, so the page carries roughly 120 lines of the same grey
  text, and Dan's report was that the section is "unreadable and ugly and just unpleasant". The
  content of the fix was right and only its level was wrong. Related to L558, which is duplication
  WITHIN one row; this is duplication ACROSS rows)

- **L587. A key, legend or swatch and the THING it describes are two consumers of one style
  record, so any field only ONE of them reads makes the key describe a treatment the thing does
  not have, and both call sites read as correct in isolation.** Give the shared record no field
  that a single consumer applies, or assert that the two render the same treatment. The failure is
  silent in both directions: the legend draws, the content draws, and only somebody holding the
  two side by side can see they disagree.
  (Try-Pennie/slate#1927, 2026-09-04: the availability grid's `CELL_TREATMENTS` carries `cell` and
  `swatchExtra`, and only the LEGEND applies `swatchExtra`. The Closed state is `cell:
  "bg-transparent"` with `mark: ""`, so its key showed a bordered empty box while the grid cell
  drew no fill, no border and no glyph, indistinguishable from a cell that failed to render. Dan
  reported it as "make closed a grey, more inert than just white", which is a colour request about
  a cell that had no treatment at all. The `?` state had the same split, and its dashed border in
  the key reached no cell either. Related to L370, which is about duplicating the code that applies
  shared data; this is one field of the shared data being applied by one consumer only)

- **L590. A display gated on a derived identifier being PRESENT hides it on precisely the record
  where the user's input is still choosing it, and shows it on every record where it can no longer
  change.** Gate on whether the value is still being DECIDED, not on whether it exists yet. The
  condition reads as obviously correct at the call site ("show the code when we have one") while
  producing the exact inverse of what is useful, so nothing about the code looks wrong.
  (Try-Pennie/slate#1947, 2026-09-04: the booking reasons editor gated both its `Code: ...` line
  and its usage line on `r.code` being non-empty. A new row is created with a blank code, and
  `reason-options.ts:142` mints the permanent code from the label server side, only for a new row.
  So the code was printed on every existing row, where renaming the label can never change it, and
  hidden on the add row, where what the manager types was choosing it forever. The codes are what
  reach the booking history and the Regal webhook payload, so the one row where the mapping was
  being fixed was the one row that showed nothing. Dan's report was that the list was too tall and
  the codes were not needed, which is true of the rows that had them)

- **L591. Vertically centring text centres its LINE BOX, which reserves descender space that an
  all-caps label never uses, so the capitals sit visibly high and any dot or icon centred beside
  them appears to sit low.** Symmetric padding and `align-items: center` both read as correct at
  every place a reader looks, and the error is under a pixel, so it survives review and is only
  ever reported as the thing next to the text looking wrong. Rebalance the padding until the
  MEASURED centre of the letters matches the container's, keeping the total unchanged so the
  element's height does not move, and re-derive those numbers if the typeface or size changes.
  (pet#1288, 2026-09-04: the Power Rankings status badges centred a 7px dot exactly while the
  uppercase label sat 0.7px high, in all seven statuses including the two with no dot. Dan
  reported it as the dot being centred and the words not being)

- **L597. When markup carries BOTH outcomes of a choice a client script will make, the state
  rendered by default must be the one that is correct if that script never runs, because a script
  that fails is silent and leaves a page that still looks finished while showing the wrong
  half.** The server cannot decide anything that depends on rendered geometry, so pre-rendering
  both branches and letting the browser pick is often the only design available; what is optional
  is which branch the markup ships in. Pick the one that is safe to be stuck on, and have the
  script promote rather than demote, so the degraded page is correct instead of corrupt.
  (pet#1293, 2026-09-04: the Power Rankings bar renders each number inside its colour band and
  again in the bar's grey tail, and a browser pass hides whichever does not fit. With scripts
  off, 9 of 15 bands showed their number clipped mid-figure and no tail copy appeared at all,
  while the rest of the board, which is baked, rendered perfectly. The fix is to default to the
  tail, which always has room)

- **L408. A control that acts on the TOP of a shared stack (undo, back, revert last) is silently
  redirected to an unrelated earlier entry by any action that records nothing onto that stack, so
  either every action on the surface records one, or a non recording action must block the control
  rather than let it reach past.** The person names the action by having just done it, never by
  naming the entry, so the control cannot tell "there is nothing of yours to act on" from "the top
  of the stack is somebody else's". Enabling the control unconditionally, which is usually forced by
  something else riding the same shortcut, removes the last signal that anything is wrong.
  (overture#3566, 2026-09-05: closing a pitch out from the Reached Out row records no undo entry,
  because undo was deliberately narrowed to keep and dismiss and the wall that used to stop Cmd+Z
  reaching past a non recording action was deleted with that narrowing. Pressing Cmd+Z after a close
  out does nothing with an empty stack, and with an earlier keep or dismiss in the session it
  reverses that instead, on a different show)

- **L410. An automatic pass running beside a manual control hides every case the control's gate
  cannot express, so compare the two predicates case by case before removing the pass: whatever only
  the pass reached has no route at all once it goes.** The control goes on looking complete, because
  its gate was written for the common case and the pass quietly served the rest, so the divergence
  has no symptom for as long as both exist. Read the batch's predicate and the control's side by
  side and name every state one admits and the other does not.
  (overture#3573, 2026-09-05: the reply drafter ran automatically on every window open and also had
  a per conversation button. The batch redrafted two cases, no draft yet AND a newer message arriving
  after the last draft was requested; the button is gated on a mode that returns "ready to send" the
  moment any draft text exists, with no comparison against when the newest message arrived. Removing
  the automatic pass, which is what Dan asked for, would have left a contact who wrote again looking
  at a draft written against their previous message with Send under it)
- **L604. Copy that tells the reader what a CONTROL IS or what the SCREEN IS DOING (what this field
  holds, what this heading contains, what the banner will say, which system owns this value) is
  removed on sight by the person it was written for, while a DOMAIN term they cannot know (a lane
  name, a field called Grid, "84 (75 today)") is left unexplained beside it.** The inclination is to
  explain the interface defensively and leave the vocabulary bare, and a reader who knows the
  business needs the opposite. Explain a term once, on the term, reachable by keyboard and screen
  reader (a definition on the header, a `title` plus `sr-only` span), never as a paragraph over a
  repeated row (L579), and write nothing about the interface at all. The test before shipping a
  sentence: would a first time reader who knows the business still need it once they can see the
  heading, the row and the shape of the control? If not, delete it.
  (Try-Pennie/slate#1836, #1877, #1889, #1890, #1892, #1907, #1915, #1923, #1947, 2026-09-03 to
  04: nine issues in one walk removed interface copy, among it a "Work email address" label with a
  hint reading "The address they sign in to Google with", a standing two line warning describing a
  banner the reader was not looking at, "Set in Salesforce (Agent Manager), and synced hourly",
  the word "Label" over every row of a list, and a heading that was a sentence, "Coverage in the
  hours currently saved". Dan: "I don't need to be told what waiting for a first sign in means."
  In the same walk #1872, #1950 and #1938 asked FOR explanations: what each cron lane does and how
  often it should run, what Grid, Notice and Buffer mean, what "84 (75 today)" means. Both
  requests came from one reader on one day, so they are one rule rather than a contradiction)

- **L605. A component that is correct in isolation names and explains itself, so a page COMPOSED
  of such components states every fact twice, and the duplication exists only in the composition,
  which is the one place nobody reads.** The page header and its only section share a title; a
  column header and every value under it carry the same word; a mark sits beside its own caption
  (L558); a status pill sits beside the control that shows and changes the same status; a unit
  appears in the heading, the placeholder and the hint. Before shipping a page, read the RENDERED
  whole as one surface and delete every second statement of a fact. A self titling panel that
  becomes the whole page loses its own heading, a value under a header carrying the noun becomes
  Yes or No, and a set of states gets one vocabulary derived from one list for the summary, the
  headers and the key.
  (Try-Pennie/slate#1915, 2026-09-04: five admin pages stated their own title twice, header then
  first section, and two duplicated the description too. #1823: a column headed Bookable where
  every value read Bookable. #1878: a role pill in the page header beside a Role select under it.
  #1955: the unit stated three times per row, thirty times per section. #1799 and #1810: "showing
  1 to 5 of 5 (of 136)" and "Agents (102 bookable / 136)". #1928 and #1938: the counts strip, the
  key and the column headers each held their own vocabulary for one set of seven states)

- **L606. UI ships unseen by two routes, a two row fixture and a green suite, and each reads as
  having looked.** A fixture of two rows says nothing about a list at 136 agents or 60 buckets,
  where a per row explanation becomes a wall, a name inside a button wraps to three lines, a glyph
  becomes texture and sixty forms become one unreadable scroll; and a suite proves only the
  property it measures, so a contrast suite green on every text against surface pairing shipped a
  hover tint at 1.009:1, a badge with no visible fill and a dark theme whose muted text matched its
  primary. Every list, table, picker and repeated row is screenshotted at the REAL record count, in
  both themes, at a wide window and a laptop window, before merge, and the screenshot goes in the
  PR body so the reviewer judges the picture. When a person finds by eye what a suite passed, the
  suite's blind spot is the finding (L63).
  (Try-Pennie/slate#1760, #1784, #1794, #1796 then #1812, #1896, #1947, #1955, 2026-09-02 to 04:
  126 raw checkboxes and 8,755 `<option>` elements on one page, "View as Kenneth Johnson"
  wrapping to three lines so every row was a different height, a tier glyph whose own issue said
  to screenshot it against the full roster first and which shipped anyway and was replaced ("I
  hate the change made to the teams"), sixty bordered forms in one scroll ("I don't even know
  where to start with it"), thirty rows of page for ten numbers. And by eye under green suites:
  #1851 a hover tint at 1.009:1, #1881 a badge fill at 1.08:1 against its header, #1958 muted text
  at 13.70:1 beside primary at 13.73:1 in dark, #1821 a pill 9px off its header, #1945 no gap
  between a textarea and its button, #1921 a digit optically off centre. Dan found every one of
  those in one afternoon)

- **L607. The browser's native control and the framework's default surface are what SHIP when
  nothing replaces them, and to the person they read as a piece of the operating system pasted
  into the product.** A native `<select>` drops the OS menu over a branded page and at several
  hundred options fills the viewport; a select given the text input's class crowds its arrow
  against the edge, because a select spends its right padding on the arrow; a textarea given the
  input's class has its height fixed at one line and its text against the border; a product with
  no error boundary shows the framework's raw dark error screen; a route with no loading boundary
  leaves the old page on screen under a spinner. Every control the person touches and every
  fallback surface (error, loading, not found) is a design system one from the first commit, with
  its own class wherever its geometry differs (a select is not an input, a textarea is not an
  input). Keep what the native control gave for free when replacing it (L568).
  (Try-Pennie/slate#1746, #1849, #1854, #1945, #1970, #1848, #1792, 2026-09-02 to 04: a native
  select inside the product's own account menu ("it looks like a piece of the OS pasted into the
  page, not part of Slate"), 19 native selects across 13 files with the timezone one covering the
  whole browser window, every select in the app borrowing `inputCls`, two admin textareas
  rendered 44px tall with their `rows` ignored, no `error.tsx` or `global-error.tsx` anywhere so a
  failed save after a deploy showed Next's black "This page couldn't load", no `loading.tsx` in
  the admin tree, and a spinner drawn as a circle with one border edge turned transparent)

- **L608. A server action that returns void and revalidates a route has told the person nothing:
  the only sign it worked is a control somewhere on the page having changed, which is a
  difference they would have to be already looking for, and a refusal it computed has nowhere to
  land.** Every action returns an outcome, the page the form is on renders it, and the redirect
  and the revalidate name THAT page rather than a hub or a landing page. A destructive or
  irreversible control looks like one and confirms with the specific consequence, never a generic
  "are you sure". Unsaved edits are guarded on refresh AND on in app navigation, which are
  different mechanisms and the second is the common case in a console. And a key that commits a
  field must not also submit the form, or the difference between picking a value and writing the
  org's hours is one faint highlight.
  (Try-Pennie/slate#1769, #1922, #1966, #1968, #1873, #1875, #1970, 2026-09-02 to 04: "Make
  bookable", the slowest admin action in the app with a live Google call inside it, had no pending
  state and returned void with `revalidatePath("/admin")` from a form on another route ("it
  worked but it didn't immediately look like it did anything"); six saves redirected to
  `/admin/settings`, a bare redirect since the hub split, so the outcome query and every
  validation refusal were destroyed by the second redirect and the person landed on Health
  believing they had saved; a refresh threw away a week of typed hours with no warning; Enter in a
  time field saved the org's business hours to live data twice before anyone noticed; "Apply
  company default hours", which overwrites a schedule, was styled identically to a reversible
  local convenience; Deactivate was the same neutral button as Reactivate and its copy claimed
  "fully reversible", which the code says it is not)

- **L609. Ordering a screen, a row or a menu by the shape of the DATA (the code's digit order, the
  column order the schema happens to have, the order the controls were written) puts what the
  reader scans for wherever it happens to fall, and gives the commonest value the heaviest
  treatment because it was styled without asking how often it appears.** First is the thing done
  most often or the thing most in trouble; the rare, the dangerous and the irreversible go last,
  so a keyboard user's default landing is never on them; and the commonest value gets the quietest
  treatment so the exceptions are what stand out. Decide the axis by asking what question the
  person arrives with, and write the chosen order down as a convention so the next table copies it
  rather than picking its own.
  (Try-Pennie/slate#1942, #1963, #1844, #1749, #1875, #1938, #1748, 2026-09-02 to 04: sixty
  buckets sorted with the backend digit weighted 100 and the debt tier 10 ("that's not the
  important part. we want to see debt bucket desc"); a row menu opening with keyboard focus on
  "View as", the audited impersonation action, above Manage, the routine one; a roster whose Role
  column rendered "agent" as a bold pill on 117 of 121 rows, placed ahead of Team; "View as
  another user" as the first card on the admin landing page; Deactivate above the ordinary
  editing controls; sixty rows in code order on a page whose only question is "which of these is
  in trouble"; fifteen sections stacked in one 1,723 line page in the order they were added)

- **L610. Collapsing content behind a disclosure, a toggle or a lazy fetch for tidiness, and
  rendering nothing on the healthy day because every element was conditional on something being
  wrong, both hide the thing the page exists to show, and a fully healthy page becomes
  indistinguishable from one that failed to render.** What the reader came for renders open and
  always, with a positive statement of what was checked and when on a good day. The inverse is
  applied as firmly: a control used rarely is demoted or deleted rather than kept prominent and
  re-explained, and a page that is empty by construction becomes a panel on the page people
  already land on, not a route somebody has to remember.
  (Try-Pennie/slate#1943, #1872, #1767, #1960, #1749, #1795, #1836, 2026-09-02 to 04: a booking's
  history behind a toggle that fetched only when opened ("don't hide history. there should be no
  toggle there"); nine cron lanes inside a closed `<details>` ("show the cron lanes all the
  time"); a health page whose sync panel and notices rendered nothing when healthy, so the better
  the fleet did the emptier the page got; a stuck deliveries route whose rows could only exist
  after an alert had already fired ("feels like this page is meant to be empty so we probably
  don't need to give it its own page"); the free text View as panel kept after the per row control
  existed, with its copy rewritten to justify it, whose only unique reach turned out to be
  offboarded employees)

- **L611. A free text box for a value whose valid set already exists as a constant in code offers
  every typo as an option and reports none of them, because the value is matched downstream rather
  than validated, and the only symptom is a pool one person shorter.** If the valid values are
  enumerable, the control enumerates them, derived from the same constant the reader uses so a
  sixth value cannot exist in routing and be missing from the form, and the server refuses anything
  outside the set because the form is never the only writer. An identifier nobody knows by heart
  (a channel id, a zone name) is shown and chosen by its name.
  (Try-Pennie/slate#1874, #1957, #1849, 2026-09-03 to 04: debt team and backend, the two
  attributes every one of sixty buckets matches on, were comma separated text boxes with a
  placeholder, beside a `role` field nothing reads, while `DEBT_TIER` and `BACKEND` sat in
  `src/lib/xbc.ts` ("they should be idiot proof, with no typos possible"); the Slack destination
  field asked for a channel id with the placeholder `default C09F4L6PLQP` ("nobody knows the
  channel IDs offhand"); the timezone select offered every zone the runtime knew, several hundred,
  to a roster spread over seven US zones)

- **L613. A shared component created to end N copies converts the one site in front of whoever
  built it and leaves the rest standing, and a superseded control is kept with its justification
  rewritten rather than deleted, so the product ends up half converted with the old thing arguing
  for itself in a docstring.** Consolidation is the component AND a guard that fails on the next
  hand written copy, shipped in the same change, with a positive control proving the guard catches
  the shape it exists to catch; a component alone is a suggestion. When a second way to do
  something exists, the first is deleted along with the module, the comment and the test that
  defended it, because a reason left standing over code nothing needs is read as a decision (L346,
  L562).
  (Try-Pennie/slate#1838, 2026-09-03: `AdminPageHeader`'s docstring said it existed because
  "thirteen copies of it is how the widths in #1745 ended up disagreeing", and ten pages still
  carried the hand written band it replaced, so restyling the component would have left the
  console visibly half converted. #1745, #1765, #1768, #1792 and #1888: thirteen page widths, two
  time pickers disagreeing about rounding, two focus ring recipes disagreeing about contrast, two
  spinners, two spellings of one reading width, all found in one week. #1795 then #1836: the
  older View as panel was kept and its copy rewritten to explain why it survived; when it was
  finally removed, its one sentence was lifted into its own module whose docstring argued for its
  own necessity, and a third issue had to remove that. #1774 and #1949: the components and the
  back links a restructure made dead were left in place)

- **L424. An action taken from ONE row whose write reaches a whole population must say whether
  THAT row was among the ones it changed, because a truthful count of the others is
  indistinguishable from success on the one the person was looking at.** The acknowledgement is
  never wrong, which is what makes it so convincing: the write really did land, the number really
  is the number, and the only thing missing is the one fact the person is standing there checking.
  It bites hardest where the control is offered on a WIDER set of rows than the write can reach,
  since the row that offered it is then the row guaranteed not to be in the count. Distinct from
  L287, where a notice's scope is wider than its surface and every number in it is about somewhere
  else: here the action genuinely acted, just not on the thing that invoked it. Report the row's
  own outcome first and the population second.
  (overture#3623, 2026-09-07: Dan pressed "Say where it is" on a 54 Below card, typed a city, and
  the card did not change. His answer for that room had stood since 9 August and the press placed
  nothing, because a scout run that morning had given every show there an address the fill only
  ever skips. The banner truthfully said no show was waiting on it, which is the sharpest form of
  this: the count was right, it was zero, and the one fact he was standing there to check, whether
  THIS card had moved, was the one thing it did not say, while the same button sat under it
  offering to try again. Measured against the app's own launch backup from the previous day; a
  first reading taken from the current store alone inferred the opposite story and was filed
  before the backup was consulted)
- **L623. A banner or badge announcing that the product is in a DANGEROUS or SPECIAL mode
  (impersonating somebody, a staging or test store, a dry run, an admin override) must be drawn
  in a treatment that appears nowhere else in the product, because one built from the ordinary
  palette reads as chrome and is looked past by exactly the person it is warning.** Reserve that
  treatment before spending the palette's one alarm colour on an everyday condition, since a
  colour a routine state already uses cannot make the rare one stand out and may end up stacked
  beside it.
  (Try-Pennie/slate#2037, 2026-09-07: the "Viewing as <name>. Actions you take happen as them."
  banner was bg-pennie-navy with a pn-btn--primary sky button, and navy also drew the login hero,
  the account and roster avatars, two Pill variants and the OOO stat grid, while sky primary
  buttons appeared at nine sites, so the one surface saying every action lands on somebody else
  read as ordinary Slate chrome. Dan: "the viewing as button and banner fit into the color scheme
  too well. It should be jarring and obvious. Not anything that exists somewhere else in slate."
  Making it red was not available either: the calendar-not-syncing banner directly below it in
  the same header slot was already bg-[var(--error)], so the routine condition had spent the one
  alarm colour and the two would have stacked as matching red bars)

- **L626. A rule that conditionally OMITS a label (a group heading, a caption, a legend) does not
  remove the SPACE that label occupied, so wherever it fires the surface shows a gap with nothing
  in it, which reads as a layout fault rather than as the boundary it still is.** Whatever the
  label was carrying, the separation and the meaning of the break, has to be carried by something
  else in the same change, and the omission rule and the spacing live in different files so
  neither call site looks wrong on its own.
  (Try-Pennie/slate#2043, 2026-09-07: the admin sidebar suppresses a group's heading when the
  group collapses to one item, because a heading over a single entry promises a section that is
  not there (#1790). "Alerts and floors" became the only Monitoring item when #1960 moved stuck
  deliveries to the health page, so the heading vanished while the 24px between groups margin
  stayed, and Dan asked "why is there a space between webhooks and alerts/floors". The
  compensating mark that did exist, a bottom rule under a headingless group (#1841), was written
  for the first item in the list where there is no space above, so it sat on the wrong side of
  the gap)

- **L627. A transient indicator placed INSIDE a row (a spinner, a badge, a count) takes its width
  from the flow, so showing it moves every sibling beside it, and the feedback for the thing
  somebody clicked is delivered by making the things they did not click jump.** Give it a reserved
  or an out of flow slot, and check every surface the shared component lands on, because a
  vertical list hides the fault a row exposes.
  (Try-Pennie/slate#2045, 2026-09-07: `LinkPending` renders a spinner as an ordinary child of the
  nav link, and the spinner owns a horizontal margin by design (#1792). In the admin sidebar, a
  stacked list, that is invisible and had been shipped and reviewed. In the header, a flex row,
  clicking "My Availability" pushed "Team Requests" sideways for the length of the navigation.
  Dan: "I don't like that the loader pushes other nav items out of the way." The obvious remedy,
  positioning it absolutely, has its own catch on the second surface: the sidebar nav is a
  horizontal scroller below lg, which clips an absolutely positioned child (L566))

- **L628. An incidental dismissal (a click outside, a page scroll, a resize) must not be wired to
  the same handler as an explicit Cancel, because dismissing a surface is not a decision to discard
  what is in it**, and the person whose click was never aimed at the picker gets no warning and no
  undo. Closing on a gesture nobody made about the content keeps the content; only the Cancel
  control and Escape restore the snapshot.
  (Try-Pennie/slate#2048, 2026-09-07: `DateTimeField` snapshots its six segments when the popup
  opens and passes `onClose={cancel}` to `AnchoredPanel`, which fires that on an outside mousedown
  AND on any page scroll outside the panel. So picking a date and then clicking anywhere else, or
  merely scrolling, wrote the old value back over it silently. Dan: "unless I click confirm, it
  reverts. It shouldn't erase the date and time if I just click out of the picker")










- **L426. An item held on screen past its own removal (a row fading out, a card playing an
  exit) must be reinserted at its OWN position rather than appended to the end, because
  anything anchored to it or to the group it belongs to (a scroll pin, a selection, a focus
  ring) follows it to wherever it lands.** Appending is the spelling everyone reaches for
  (`surviving.filter { notLeaving } + Array(leaving.values)`) and it is invisible for as long
  as something else in the group survives, because the group's position is registered by that
  survivor and the departing row merely rejoins it. The day the departing item is the LAST one
  in its group, the group itself first appears among the appended values and is rebuilt at the
  bottom of the list. (overture#3634, 2026-09-07: Dan dismissed a whole night in the scout
  queue, which takes every show on that date by construction, and the queue scrolled from
  September to May. The scroll position is pinned to the date heading at the top of the screen,
  that heading had just been rebuilt below every later night, and the ScrollView obediently
  followed it to the end. Three call sites shared the one splice, so closing out or sending the
  ONLY show on a night did it too and nobody had noticed, since those are one card rather than
  a whole screen of them. The comment above the splice even named the ordering, "a night that
  exists only for a departing card last", written to solve the different problem that the night
  must exist AT ALL so the card has somewhere to land; no test asserted the position)




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
- **L425. A decoder that declares only the fields it needs today silently discards every sibling
  in the same object, and nothing anywhere reports the loss**, so before any surface asks a person to
  supply a value, check whether the payload it was read from already carries that value one field
  over. The third case in a family: L506 is a field that is ABSENT, L194 is a sender that reduces a
  fact to a FLAG about itself, and here the fact is present, complete, and never declared by the
  reader.
  (overture#3625: the Squarespace reader declared `addressTitle` and nothing else, so a chorus whose
  own event block published "New York City Children's Chorus / 921 Madison Avenue / New York, NY,
  10021" reached the store with the confusing first line as its venue and no location at all. The app
  then put a panel in front of Dan asking him to say where that room is, which is a city sitting two
  fields away in the same JSON object it had already fetched and parsed. His words on being shown the
  panel: "that doesn't feel good though. why is it a venue at all?")

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

- **L265. Before building a path that carries on past an external service's negative verdict, check
  whether that service is also the GATE on the action**, because a verdict you can prove wrong locally
  still refuses the action and everything done past it is spent and then thrown away. The tempting
  shape is a local check with more context than the service has: it is genuinely right, and being
  right buys nothing while the service is the one that has to say yes. What such a finding is worth
  is the DIAGNOSIS, told in seconds, rather than a longer road to the same refusal.
  (overture#3210: GitHub computes a PR's `mergeable` flag with a plain text merge and cannot see the
  repo's `.gitattributes` merge driver, so a PR whose only collisions are generated files reports as
  CONFLICTING while `git merge-tree` resolves it locally and exits 0. The plan was to notice that and
  carry on. GitHub will not merge a PR it reports as CONFLICTING however the local clone merges it, so
  carrying on would have run the full eleven minute suite and then failed at `gh pr merge`, worse than
  refusing in two seconds. The evidence was in the incident's own PR: #3196 carries a pushed
  `Merge remote-tracking branch 'origin/main'` AND a pushed `Regenerate project.pbxproj after merging
  main` before GitHub would take it. What shipped instead names which of the two kinds of collision it
  is and hands over the three commands, and the automatic branch update became overture#3216, because
  it means pushing a regenerated file to somebody's branch)

- **L266. Removing a prefix by SUBSTRING REPLACEMENT matches anywhere in the value, not only at the
  start**, so when the two sides come from sources that can disagree about it (a compile time path
  against a resolved one, a symlink against its target) the removal takes a bite out of the middle
  and produces a plausible wrong value rather than an error. Resolve both sides to one canonical
  form before comparing them, or ask the API for the relative part rather than computing it.
  (PostRoll#941: `DeepLinkWiringTests` derives each source file's relative path by replacing
  `root.path + "/"` with nothing, where `root` comes from `#filePath`, recorded by the compiler, and
  the file URLs come from a `FileManager` enumerator, which resolves symlinks. On macOS `/tmp` is a
  symlink to `/private/tmp`, so a checkout under `/tmp` left the trim removing a substring from the
  middle: `/private/tmp/.../Sources/AppState.swift` became `/private` + `AppState.swift`, fused into
  `privateAppState.swift`, and the test failed naming a file nobody had written. It refused loudly
  only because that fused name happened not to exist; a trim landing on a real file would have read
  the wrong one and reported about it)

- **L271. A cross repository deliverable phrased as what YOUR side must WRITE says nothing about
  whether the consuming side can READ it**, so check the consumer's access to the value before
  calling it done. Writing exactly what was asked satisfies the letter while leaving the
  comparison it exists for with one unreachable side, and nothing reports that until somebody
  tries to build the comparison, which is the expensive moment to find a missing field.
  (downbeat#452: Ovation's implementation plan named, as a cross-repo deliverable, that Downbeat
  write a durable per-booking handoff-intended mark. Downbeat wrote exactly that, in the same
  save transaction as the row, with a reader and tests. The mark lives in Downbeat's SwiftData
  store, which Ovation cannot read, and it appears in neither the export nor the queue record,
  while the same Ovation plan specifies a reconciliation with that mark as ONE SIDE of the
  comparison. Both repositories read as complete on their own, which is why neither reports it.
  Distinct from L3: nothing here is unwired inside either codebase, the gap is only visible from
  the boundary, and the deliverable's own wording is what hid it by naming a write and no reader)

- **L273. A normalization written to make a comparison forgiving covers only the character class
  its author happened to think of, so state the reason it exists and apply it to EVERY class that
  reason covers, because the classes left out are total mismatches rather than near misses.**
  Distinct from L147, where the too-strict comparison makes a guard NEVER fire and so look like it
  has nothing to catch: here it makes the guard fire on everything, and the false report is
  indistinguishable from the fault it names. Distinct from L185, which is about grouping by the
  normalized form once you have one.
  (postroll#963, 2026-08-29: the blog photo check folds CASE before matching a marker's filename
  against the photos actually sent, and says why in its own docstring, that a case difference is not
  a different photo on this filesystem and reporting it would be the check crying wolf. Dan's event
  was named with typographic quotes, the model wrote the marker with ASCII ones, and casefold
  normalizes letters and nothing else, so all seven photos reported BOTH "names a file that was not
  sent" and "was never placed", 14 of the 23 findings on one post. The stated reason covers quotes,
  apostrophes and accents exactly as well as it covers case; only case was written. The next event
  named with a possessive would have hit it again)

- **L280. A rule enforced at ONE stage of a pipeline is not enforced by the pipeline, because
  every later stage that rewrites the same content can reintroduce exactly what the rule removed,
  and the enforcing stage has already run, so nothing reports the regression.** Enforce at the
  last stage that can write, or re-check after every writer. The failure is silent by
  construction: the only thing that ever measured the property ran before the property changed,
  so the artifact ships violating a rule the codebase visibly contains.
  (PostRoll#979: a repair pass shortens over-long alt text at generation, and the revise and
  photo swap paths both rewrite the body afterwards with no length check, so a revision can put a
  long image description straight back. Nobody sighted notices, which makes it the defect class
  least likely to be caught by review)

- **L534. A platform setting whose DEFAULT is derived from another setting flips silently when you
  flip that other one**, so a config change has to be checked for a second key whose default tracks
  it, and both set explicitly. The derived key's absence from the file reads as deliberately
  untouched while its value is actually being decided by the line you just edited, and the platform
  reports no conflict because nothing is in conflict: one key simply had no opinion.
  (slate#1052, slate#1692: `workers_dev: false` closes the production Worker's second origin, and
  Wrangler defaults `preview_urls` to whatever `workers_dev` is, so the same line would have
  disabled `wrangler versions upload` preview URLs as a side effect, and would silently re-enable
  them for anybody who ever turned workers.dev back on. Caught by reading the platform docs for the
  flag being changed rather than applying the one line direction the issue named)

- **L552. Pinning a tool's VERSION pins its output only when that tool does the work locally,
  so a command that delegates to a hosted service (a generator invoked with a project id and an
  access token rather than a database or a file) emits whatever the server currently produces,
  and the pin, the comment explaining it, and every check built on comparing the result character
  for character go on reading as reproducibility. Pin the thing that PRODUCES the artifact, or
  normalise what you cannot pin.** The pin being HONOURED is what makes this invisible: the
  version really is the one named, so measuring that it is in force passes, and the output changes
  anyway. This is the case L188 and L322 do not reach, because there the control was overridden.
  (bidspoke#1105 and #1115, 2026-09-03: `supabase gen types --project-id` generates on Supabase's
  servers, so the CLI pinned to 2.107.0 in two workflow files produced one format at 09:00 UTC and
  another at 12:22 the same day, on the identical commit. The nightly drift check went red for
  three runs over two days on five added parentheses in boilerplate, alerting Slack each time with
  a sentence blaming a migration that never happened, while a real schema change would have been
  invisible behind it. The comments in both files stated that the pin guarded against exactly this)

## Building with AI

- **L270. A rule stated in a prompt is contradicted by every example, reference document and
  line of surrounding prose that breaks it, and the demonstration outweighs the instruction, so
  anything a prompt BANS must be absent from the whole payload the model receives, not merely
  forbidden in one sentence of it.** The ban reads as satisfied because the sentence is there, and
  the only thing that would reveal otherwise is counting the banned thing in the rest of the
  payload, which nobody does once the rule is written. Distinct from L27, where the rule reaches
  no code at all: here the rule reaches the model and is outvoted by its own context.
  (postroll#959, 2026-08-29. The caption prompt, the blog prompt and the brand voice document all
  instruct Claude "NO em dashes anywhere. Ever." and are themselves written with em dashes
  throughout: 66, 56 and 63 of them respectively in text sent to the model, plus the brand voice
  file which is the single strongest example of how the writing should read. Nothing had gone
  visibly wrong only because a deterministic cleaner strips them from what comes back, so a
  backstop was quietly doing the prompt's job. Found while measuring an unrelated backlog, not by
  reading the prompts, because a prompt is read for what it SAYS)

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

- **L328. A reader that can INDEPENDENTLY source what the payload failed to send produces a correct
  looking result for a reason the sender never supplied, so its success is no evidence the payload is
  complete, and the omission surfaces only on the inputs where that independent sourcing fails.**
  Check what the payload CARRIES against what the reader NEEDS, never by reading its output. The
  mirror of L194, which is about a reader that FAILS to rediscover what it was not sent and misreports
  the fact as absent: that failure is loud and costly, where this one is silent and looks like the
  system working, so it survives far longer.
  (overture#3285: the prep handoff sends a run's first and last date only and the runbook tells the
  drafter to write a span, but the drafter fetched the venue's own listing page and named both exact
  nights, so a pitch that looked perfect was correct only because the model went and got what Overture
  never sent. Measured on the live store the same day: the long tail is 23 nights on one run and 18 on
  another, where a span names weeks nobody chose)

- **L333. Agents dispatched on ONE brief each reach the same finding, so any outward action they can
  take alone (filing an issue, commenting, pushing) is multiplied by the batch size and the finding
  arrives as N records of one defect.** Route what a batch discovers through something that
  deduplicates before it acts, and say so in the brief, because each agent is individually correct and
  cannot see the others. The subagent spool (`~/.claude/hooks/lib/issue-spool.sh`) exists for exactly
  this and is the thing to point a batch at. Distinct from L28, which treats a detached run as an
  untrusted subprocess: here every agent behaved well and the duplication came from the fan out itself.
  (overture, 2026-08-30: a /plan-council run of 23 agents filed its own GitHub issues while running,
  and four of them, #3300 #3301 #3306 #3320, independently reported that the self-booking check reads
  only a run's opening night. A fifth was then filed by the parent session on top, and one agent was
  still filing at the same minute the parent filed its phase issues. #3296 duplicated #3312 the same
  way. The brief never told them not to file, and nothing deduplicated)

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

- **L340. A defensive normalization that coerces a response into the shape you asked for
  (truncating a list to its first entry, taking the first match, clamping a count) destroys the only
  evidence that the instruction was ignored, and the coerced value is indistinguishable from a
  compliant one, so record the violation as a finding rather than quietly trimming it.**
  (postroll#1067: a Thursday scroll reel gets one alt text for the whole reel, and the prompt says
  so. `generate_captions.py` then does `alt_texts = alt_texts[:1]` for every single alt post type,
  commented "defensively in case Claude wrote one per photo anyway". When the model did write one
  per photo, the shipped alt was photo 1's alt: a well formed single photo description that reads
  exactly like a compliant reel level one. Measured across the live store, 12 of 21 Thursday reels
  had shipped an alt describing one frame, and 7 were under the word floor the reel rule sets, with
  nothing anywhere reporting it. One event predating the trim still held all 20 per photo alts,
  which is how the shape violation was seen at all)

- **L363. A deduplication that runs before findings are filed must compare against the store they
  are filed INTO, never only against the batch that produced them, because any audit of that store
  restates its records and each one then arrives as a fresh finding.** L333 covers agents in one
  batch duplicating each other, and the spool answers that; this is the batch duplicating what was
  already recorded, which the spool cannot see. Wherever a pipeline files into a durable store (an
  issue tracker, an alert channel, an error tracker) the last step before filing reads that store.
  (claude-config#256: eight read only agents audited every open PostRoll issue against main on
  2026-09-01. The harvest spooled their observations, another session's review offered them as new
  findings, and PostRoll #1173 to #1176 were filed within minutes, each a twin of the issue its agent
  had been reading, #959, #1023, #1156 and #1115. The eight findings the auditing session's own
  review then received were all restatements of open issues too)

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
- **L346. A recorded reason for LEAVING something as it is (a docstring saying why a check is
  not tightened, a comment saying why a value is kept) is read by everyone afterwards as a
  considered decision, so confirm the thing is still on a live path before writing one. A
  justification attached to code nothing calls converts dead code into a decision nobody
  revisits, and the next person argues with the reason instead of deleting the code.**
  `generate_captions._is_real_handle` lost its only caller on 2026-05-24, when handles were
  dropped from the caption prompt's performers block. Three months later #917 imported the
  shared sentinel list into it and wrote into its docstring that it was "kept as it was
  because tightening it changes what reaches the caption prompt, which is its own change
  with its own tests". Nothing reached the caption prompt through it, so no version of that
  sentence could have been true. #926 was then filed on the strength of it, describing the
  function as a live second answer to a question it was not on any path to answer, and
  proposing work to reconcile it. Both readers were careful; neither ran a search for
  callers, because a function carrying a reason does not look like a function to check.
  The check is one command (`git log -S` names the commit that took the last caller away),
  and the state L29 already forbids is exactly the state a reason makes invisible.
  (PostRoll#926, #1105)
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
- **L582. When one fact is recorded by two mechanisms that deliberately exclude each other's
  territory, assert their union against the real population, because each exclusion can be
  correct while a third group belongs to neither and is recorded zero times.** Both mechanisms
  go on reporting success on the cases they do cover, so the gap has no failure to surface it,
  and an absence of records is indistinguishable from a population that genuinely never does the
  thing. Distinct from L129, which says to name what WILL cover the exempted category: here both
  halves were named and each is right, and nobody checked that the two named halves add up to
  the whole. Applies to every fast path beside a fallback, native beside derived, primary handler
  beside catch-all.
  (bidspoke#1157: bid recording is split between a native path firing only on partner_bid and
  bid_group nodes and a derivation that deliberately excludes those to avoid double counting and
  only inspects code nodes. The Lead Economy workflow bids from a branch node, so neither fired,
  and 41,747 runs a week produced zero bid rows and zero recorded winners while the workflow
  succeeded every time)
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
  And when the remedy was a shared HELPER rather than a rule, port the HELPER too, because a
  sibling project that has the lesson but not the code reinvents the very mechanism the lesson
  exists to forbid.
  (downbeat#336: L108 was recorded from PostRoll, where the Anthropic API key field checked
  only that the value began sk-ant-. Downbeat's copy of that same field checked less than that,
  only that something had been typed, and kept the gap for months until a truncated paste of a
  different credential exposed it by accident)
  (2026-08-31, the helper half, found by sweeping all four Swift and TypeScript projects on this
  Mac after Dan reported Overture freezing: Downbeat answered downbeat#402 and #406 by building
  `Integration/BlockingWork.swift`, which runs blocking work on a dispatch queue under a deadline
  and is wired at 13 call sites. Nine days later Overture was blocking the main thread outright
  (overture#3419) and PostRoll was reaching for `Task.detached` (postroll#1143), which is the exact
  mechanism downbeat#406 had measured as wrong. Three Swift apps, one author, one machine, and the
  file that solved it existed the whole time in one of them. Note PostRoll had the INSTINCT right
  and said so in a comment, off the main actor deliberately, so the lesson had travelled and only
  the code had not: that is the case this clause is for)

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

- **L262. A constraint that has only ever been satisfied as a side effect of somebody doing the
  work by hand is recorded nowhere and checked by nothing, so the first time that work is
  GENERATED rather than placed the constraint silently stops holding, and every existing check
  passes because each one was written against the hand made cases.** The constraint is invisible
  precisely because it has never once been violated: there was no moment at which anyone had to
  state it, so it lives in the muscle memory of whoever positioned each instance and in no
  artifact at all. Distinct from L96 and L129, which are about a rule that IS written down and
  whose coverage has holes: here nothing was ever written, and the generated case is not an
  omission from a list, it is the first member of a category the list was never asked about.
  (postroll#921: five full frame templates are laid out by hand and each clears the band
  Instagram lays its caption over, so the phone chrome check only ever measured TEXT. The collage
  is the one template whose arrangement the program picks, and its pool included one that put
  three of seven photographs behind the caption. The picture file was correct, every test was
  green, and it was found only by drawing the phone chrome over a render by hand)

- **L570. A sequence applied only incrementally forward (database migrations, an append-only
  provisioning or setup script) is never run from empty, so a step that quietly depends on
  state one particular machine already had keeps passing there while failing on every fresh
  environment, and the rot surfaces only when somebody first needs one.** Rehearse the whole
  sequence from empty on a schedule, and have each step address what it changes by a property
  it can look up rather than by a name the platform generated. The second half is where these
  break: a constraint or index nobody named explicitly is named BY the platform from the
  columns and from how many siblings already exist, so a hardcoded one is an assertion about a
  database the step did not build. Distinct from L262, which is a constraint satisfied by hand
  placement being violated once the work is generated: here the hand made state is what the
  step DEPENDS on, so it is correct exactly once, on the machine that has it.
  (bidspoke#1139: applying supabase/migrations to an empty database stopped at 22 of 119 from
  2026-04-24 to 2026-09-03. 20260424000001 opened by dropping a foreign key by a name that
  appears nowhere earlier in the history, because core_tables declares that key inline and
  unnamed and Postgres auto-names it; the dropped name existed only in production, made by
  hand, so the statement could only ever succeed there. Nothing noticed for four months because
  nothing ever replays the directory. The compounding cost is the tell: with no way to build an
  empty database, nothing in the repo had ever been tested against real Postgres, so every SQL
  guard read migration TEXT instead of executing it, and the procedures that TRUNCATE
  production partitions had to be tested on a throwaway database created by hand)

- **L263. A shared NAME is read as evidence of shared BEHAVIOUR, so two same-named functions on
  either side of a boundary are never compared and can implement different rules indefinitely,
  while every caller on each side reads as correct in isolation.** The name is what suppresses
  the check: nobody diffs two things they already believe are the same, and no reviewer of
  either half sees anything wrong, because each half is internally consistent. Distinct from
  L26, which is the REMEDY (twins share one committed fixture) without saying why nobody
  reaches for it, and from L198, where the stricter side reports a false failure and is at
  least LOUD: here both sides simply carry on, each right about a different question.
  (postroll#926: `PythonBridge.isRealHandle` in Swift required a value to be handle SHAPED and
  not a sentinel; `generate_captions._is_real_handle` in Python checked only the sentinel half,
  so 'DPR Dance' was a real handle to Python and not to Swift. The two sit on either side of the
  bridge that assembles CAPTIONS.txt, nothing asserted they agreed, and the divergence was found
  only by reading both while fixing something else)

- **L370. Sharing a rule's DATA while copying the code that APPLIES it is not consolidation: the
  shared constant reads as the single source of truth, so nobody asks whether the logic beside it
  was duplicated, and a change to how the data is applied lands in one copy only.** Share the
  function that applies it, not just the list it reads. The half measure is worse than two frank
  copies, because the shared list is visible evidence of consolidation and answers the question
  before it is asked: a reviewer sees one definition of the vocabulary and stops looking. Distinct
  from L263, where a shared NAME is the thing suppressing the comparison, and from L41, which is
  about a list that must MIRROR another and should be derived from it; here the list is already
  genuinely shared and it is the matcher around it that is twinned. The remedy differs too: not a
  fixture, not derivation, but lifting the application into one function and leaving each caller
  only what genuinely differs.
  (postroll#1224, 2026-09-02: `INFERRED_STATE` and `DIRECTED_INTENT` are imported by both blog and
  caption alt text checks, and the two lines of regex matching built on them were copied byte for
  byte into `caption_quality.py:170` beside the original at `blog_quality.py:708`, in the same
  change that imported the lists in order to avoid duplicating them)

- **L274. An exception a collection singles out for ONE item (skip this one, do not touch that
  one) must be answered by the ITEM itself, never by a predicate repeated inline at each place
  that iterates the collection, because a second loop written later omits it and the item is then
  protected at one site and handled normally at the other.** Both sites read as correct alone, so
  the gap is invisible until somebody exercises the unprotected one. Related to L233 (an
  unexplained entry in a skip list) and L129 (an exemption with no reviewer named), but distinct
  from both: here the exemption IS reasoned about and IS written down, in the item's own type, and
  it still fails to reach one of its consumers.
  (postroll#965: `CollageDivider.actualGapPx` carries the comment "~90 for the strip divider
  (which should not be dragged or filled)". The gap fill loop enforced it with
  `if div.actualGapPx <= 16`; the divider handle loop twenty lines further down the same file
  iterated every divider with no filter, so the branded title strip got a drag handle and Dan
  dragged a photo straight over the collage's title and logo. Had the exception been a property
  on the divider, the handle loop could not have missed it)

- **L281. Behaviour that is correct only as a SIDE EFFECT of an unrelated rule has no test, no
  comment and no owner, so the first change to that rule removes it silently while every check
  stays green.** When you find the code already doing the right thing, establish which rule says
  so, and if none does, write it and test it before building on it. The absence is hidden by the
  behaviour being right: nobody writes a test for an outcome they have just observed working, and
  no reviewer questions a decision that was never made. Distinct from L262, where the constraint
  is held by somebody's hand work outside the code, and from L96, where a rule IS written and its
  registry has holes: here the rule was never stated at all, and the code that happens to enforce
  it is answering a different question.
  (postroll#982: a private Instagram account was never suggested as a collaborator, but only
  because ranking needs an engagement rate, which needs likes or comments, which a private
  profile shows to nobody. Nothing anywhere decided private accounts should be excluded, and
  postroll#977 proposes making a followers only entry rankable, which would have started
  suggesting them with no test failing)

- **L286. A derivation every test in a suite needs (a tree walk, a parse, a store clone) is
  recomputed once per test unless its default input is memoised, so memoise the no-argument form,
  keep the callers that inject their own input building, and make the memo unable to capture an
  empty result, because a memoised empty scan passes every guard at once.** Each test legitimately
  needs the result and none knows the others exist, so the cost is invisible from any one test and
  only shows as a suite that is slower than the sum of what its tests do. The callers that inject
  their own input are the tests OF the builder and must keep building, and the memo needs the
  same refusal an empty scan already has (L98), or one bad walk is remembered as clean for the
  whole run.
  (overture#3235: the copy inventory built twelve times a run, its surfaces reported four times and its
  source walk four, 130 seconds of a 507 second suite recomputing one document. downbeat#470: a
  repository walk that 24 guard suites each recompute per test, 206 tests taking 10.9 of the
  suite's 27 seconds, a `static func` where a `static let` would do. Found by the 2026-08-29 test
  speed audit, combined lesson 30)

- **L542. Two similar rules that DIFFER may each be a recorded decision rather than an
  inconsistency, and the comment beside one documents only that one, so a change that
  aligns them can silently delete a product rule while reading as a cleanup. Before making
  two such rules agree, find the decision record for EACH side, and treat an observed
  divergence as evidence of a defect only once both records are in hand.**
  (project-enrollment-tracker#1217, 2026-09-02: two predicates decided a week apart with
  deliberately different answers at the 1st of the month, board visibility with a strict
  comparison and commission eligibility with on-or-before. #612 found the difference, read
  the eligibility comment as documenting THE intended boundary, wrote "generate.js looks
  like the side that is wrong", and routed the board through the commission one. The
  evidence it cited as proof of a defect, two reps sitting on the June board while
  commission ineligible for June, is exactly what the two decisions together prescribe. It
  cost nothing visible for three months because neither rep had production that month, then
  a rep termed on the 1st sold that day and $22,107 vanished from a team board. L342 does
  not cover it: nothing here was being consolidated for convenience, the change believed it
  was repairing an inconsistency.)

- **L374. A gitignore or exclude entry without a leading slash matches at EVERY depth, so a
  rule written for one top level folder silently swallows any same named directory anywhere
  in the tree, and the loss is invisible to status, diff and commit alike.** Anchor such
  entries, and assert that nothing under the directories holding committed work is ignored.
  (nursedex#906, 2026-09-02: `.gitignore` carried `Legal/` for the repo root folder of legal
  documents. A new `src/lib/legal/` was created for a module two pages import, and the rule
  matched it. `git add -A` reported nothing, `git status` was clean, the commit contained
  only the two files that IMPORT the module, and it was caught by hand before pushing; the
  first automatic sign would have been CI failing on an import of a file that was never
  pushed. The same accident under `supabase/migrations/` means production silently never
  receives a migration, and the symptom surfaces far away as a column that does not exist.
  L250 is a different failure on the same file: it is about OTHER tools reading `.gitignore`
  as an instruction it was not written to give, not about the pattern's own reach.)

- **L554. A generated file committed beside its source conflicts on every aggregate it
  carries (a total, a count, a checksum, a timestamp), so two independent edits to the
  source that merge cleanly still collide there and block the merge over content nobody
  wrote.** Either keep the derived file out of version control, or give it a merge rule that
  regenerates it from the merged source rather than reconciling it line by line.
  (claude-config#282, 2026-09-03: `LESSONS-INDEX.md` is regenerated from `LESSONS.md` on
  every apply, and its header carries a lesson total. Both Macs added lessons, `LESSONS.md`
  auto-merged with no conflict, and the index was the only conflicted path, purely on the
  count line. The sync died with "both Macs changed the same config and it couldn't
  auto-merge... reconcile by hand", which Dan cannot act on, so the whole two way sync was
  blocked by a line no person had written. `is_derived_rule_file` already existed and three
  other readers skipped derived files for exactly this reason; the rebase was the fourth
  site and was left out. L41 is the opposite concern, deriving rather than hand
  maintaining, and says nothing about the derived artifact's own merges.)
- **L422. A derived artifact COMMITTED alongside its source is a standing claim that it is
  current, and nothing enforces that claim, so the check that regenerates it and compares
  ships in the same change that first commits it.** A stale copy is invisible in review,
  because the diff shows a plausible file while the source it no longer matches changed in a
  different commit, and every test that reads the artifact goes on passing over the old
  content. L41 says derive it rather than hand maintain it and L554 covers how it merges;
  neither asks whether the committed copy is still what the source produces.
  (ovation#102, 2026-09-07: `Ovation/Assets.xcassets` is generated from
  `icon/ovation-app-icon.png` by `scripts/build-app-icon.sh`, and both are committed so a
  machine without Pillow can still build the app, which is a real reason and is exactly what
  creates the gap. The suite asserts the built bundle carries a full size icon, never that it
  is the icon the artwork specifies, so replacing the artwork without re-running the script
  ships the previous icon while the repository shows the new one, with every check green.)
- **L383. A derived value exposed as a computed property or a getter is re-run in full by
  EVERY reader, and a reader's call site reads as a free field access, so nothing at the point
  of use says what it costs. Where the derivation walks a whole collection, compute it once at
  the top of the pass and hand the value down, and assert the NUMBER of call sites, because
  the shape alone cannot be read.** (overture#3492, 2026-09-03: `ArchiveView.filtered` was a
  computed property running a 1,139 row derivation, read twice in one body pass, once for the
  count beside the title and once for the empty check, so every render of that screen paid for
  the corpus twice. One rebuild is 533ms. It was invisible because both readers look like
  ordinary property reads, and it survived #3479, which removed a THIRD read on the empty path
  without anyone counting the other two. The fix names it as a call, `filteredItems()`, bound
  once in `body`, precisely so the guard can count call sites; a property access cannot be
  counted. The sibling sweep found the same shape in `RootView.searchableItems`, which reads
  `nonDismissedProspects` directly and again through `reachedOutKeys`, walking the store twice
  for one search scope (overture#3493). L286 is the same mechanism inside a test suite; this is
  the production half.)


- **L556. When asking a stakeholder to rule on whether two surfaces should agree, enumerate
  every place they ALREADY disagree before asking, because the answer comes back as a rule
  about agreement rather than about the single case you showed, and it gets applied to the
  cases you never mentioned. Showing one instance also makes the decision look smaller than
  it is, so the reply is given on a smaller picture than the change it authorises.**
  (project-enrollment-tracker#1244 and #1245, 2026-09-03: the question put to the director
  showed ONE divergence between the team board and the commission report, a rep terminated
  on the 1st of the month, and he replied "I would like them both to match actually. Make
  them both match the commission report." The board and the commission report also disagree
  about NEW HIRES, because the board's roster is filtered only by departures and never by
  the floor date, and that population is larger: 2 reps in September and 11 in August out
  of 103 active. So a one line answer now either authorises removing every new hire from
  their team's board for their first partial month, which would make the #484 goal
  proration built for exactly that month pointless, or it does not, and nobody can tell
  which from the reply. Enumerating both cases in the original message would have cost one
  sentence and returned a decision that covered them.)

- **L562. A named rule is copied through its WORKED EXAMPLE, so an example that contradicts the
  rule teaches the inverse and is then defended with the rule's own authority.** Check the example
  against the rule when writing it. And when a premise turns out wrong, hunt it down in every place
  it was recorded rather than only where it was implemented.
  (Try-Pennie/slate#1824, 2026-09-03: a tier coverage column drew five letters, covered ones dark
  and uncovered ones faint. I claimed the faint letters had to clear 3:1 because they established
  which position was which, and wrote a contrast guard, a component docstring, two design system
  colour entries and a named rule around it. The premise was wrong: the covered letters are their
  own labels, so "M H V" says Medium, High, Very High and nothing is ever counted. The rule itself
  read correctly ("a mark is decoration only if removing it loses nothing a reader needs") and cited
  these letters as its canonical example of a mark that must stay legible, which is the clearest
  case of one that need not. Five recording sites for one wrong sentence, and the guard then blocked
  the correction)

- **L387. A change that fixes a defect CLASS must be searched for a fresh instance of that same
  class before it ships. The fix is written by somebody holding the class in mind, which makes it
  the likeliest place to repeat it, and the new instance arrives carrying the authority of the
  remedy so nobody re-examines it. Sweep the DIFF, not only the existing code.** (overture#3508
  and overture#3500, 2026-09-03, twice in one session. #2597 gave an opt in cost measurement a
  freshness record so its figure could not go stale unnoticed, and the same change added a SECOND
  opt in measurement, the richer one, with no record at all. Separately, a milestone whose whole
  subject is main thread cost gained a counter firing about 2,700 times per render whose own cost
  was never measured, described in its source comment as "one task local read, which is nil, and
  then nothing", which is an estimate nobody took. Both were caught by the end of turn review
  rather than by any check. L30 is the neighbouring rule and does not cover this: it says sweep
  for a found defect's SIBLINGS in the same change, which is about the code that already exists.)
- **L585. A guard that bans raw values in favour of named tokens is structurally blind to a token
  that is REFERENCED but never DEFINED, because there is no literal for it to find, so the
  declaration reads as correct while the runtime silently substitutes its own fallback.** Check
  that every name used is also declared, in the same pass that bans the literals: the two halves
  of a token system are the declaration and the use, and a scan that only polices the use can
  only ever confirm nobody wrote a raw value. L113 is the neighbouring rule and does not cover
  this: it is about a lookup table taking its DEFAULT branch on a missing key, where a default at
  least exists. Here nothing exists at all.
  (project-enrollment-tracker#1276, 2026-09-04: dist/styles.css uses var(--border) in five rules
  and never declares --border in any :root block, so the "Achieve data is behind" banner under
  the dashboard header draws its border in whatever the text colour happens to be rather than the
  intended hairline. The project has tests/palette-tokens.spec.js specifically to police colours
  written outside the palette, and it passed the whole time, because an undefined token leaves no
  colour in the file to catch. Found only because a new notice was being styled beside it and the
  token was reached for by name.)

- **L407. A constraint recorded only as a COMMENT beside the code it governs is enforced by
  nothing, and sitting there makes it read as binding, so the first person to break it does so
  with every check green.** Write the check that fails when it is broken in the same change as
  the comment, or say in the comment that nothing enforces it. Distinct from L27, which is about a
  rule living in a PROMPT, and from L262, which is about a constraint recorded nowhere at all: this
  one is written down clearly, repeatedly, and in exactly the right place, which is what makes it
  feel handled.
  (overture#3558, 2026-09-05: three files said a stored property must never be dropped, because the
  app has no MigrationPlan and every schema change so far had been additive, against a live store
  whose only net is the launch backup. A change then dropped one and opened a pull request with
  8,960 tests passing and every guard green. It was caught only because somebody happened to read
  one of those comments while sweeping an unrelated issue, and it would otherwise have run its first
  subtractive migration against real data.)

- **L624. A step whose work list is what an earlier mechanism REPORTED as a problem (the
  conflicted paths, the failed items, the flagged files) loses every subject a later fix stops
  that mechanism reporting, and it still has to act on them, so a rule added to SILENCE a report
  must be checked against every step that consumed that report as its queue.** Both changes are
  correct on their own, and the second one makes the world quieter, which is why it reads as a
  fix rather than as a removal. Distinct from L129, where an exemption leaves a CHECK with no
  reviewer, and from L247, where the subject list is derived from a proxy spelling: here the list
  is derived correctly from a live report, and the report itself was deliberately shortened
  afterwards.
  (claude-config#329, 2026-09-07: resolve_derived_conflicts stages the paths git reported as
  conflicted, and a later .git/info/attributes rule made LESSONS-INDEX.md resolve as merge=ours
  so it is never reported. The recovery still regenerates that index from the merged lessons and
  never stages it, so rebase --continue refuses, and the Mac could neither send nor receive
  config for four hours while telling the operator to settle the rebase by hand. Found only
  because a sync was run by hand to push an unrelated skill rename.)

- **L428. Adding a new threshold BESIDE an existing one, rather than changing it, leaves every
  reader of the old constant silently answering a question that has been superseded, and no rule
  about changing a limit fires because nothing was changed. When a rule's meaning splits across
  two constants, audit every reader of the old one and state which of the two questions it is
  asking.** The old constant keeps its name, its comment and its callers, so each call site still
  reads as correct, and the divergence exists only in the pair. Distinct from L227, where a limit
  is RAISED and a margin derived from it silently shrinks, and from L542, where two rules differ
  because each was decided separately: here one rule was split in two and its readers were left
  pointing at the half that no longer governs.
  (overture#3636, 2026-09-07: #1558 widened how far apart two nights of one show can be and still
  read as one engagement, from 3 days to 56, by ADDING sameShowGapDays beside the existing
  gapDays rather than moving it. DuplicateContactGuard, the only net against pitching one
  production twice, still reads the 3, and its own comment still says it mirrors the grouping
  window. The Infinite Wrench is stored as 15 cards for one weekly show at one venue, every
  fragment weeks from its neighbour, so the guard cannot fire on any of them and a second pitch
  to the same producer would go out with no warning.)

- **L429. A file the platform loads AUTOMATICALLY into every session grows one entry at a time
  and has a size ceiling nothing in the project measures, so put a check on its size: past the
  ceiling the rules stop arriving rather than failing, and a rule that never arrived is
  indistinguishable from one that was followed.** Distinct from L244, which is about such a
  file's CONTENT going stale: here the content is perfectly correct and simply does not reach
  the session. Every contributor adds a paragraph and none of them can see the total, so the
  growth is nobody's decision, and the only thing that reports the crossing is a warning
  somebody happens to have on screen at the time.
  (overture#3640, 2026-09-07: AGENTS.md reached 150,888 characters against a 150,000 limit,
  growing about 4,500 a day over the preceding week, and the crossing was found because Dan
  saw the editor's warning. It still loaded in full at that size, verified by checking the
  file's last line against what reached the session, so what the ceiling does above the warning
  is still unmeasured. The same day, ~/.claude/LESSONS-INDEX.md measured 130,844 against the
  same limit, growing one line per lesson, which is a second instance in a different config
  system with roughly 80 lessons of headroom.)


- **L437. Code lifted out of a file to be reused elsewhere leaves behind everything it was
  inheriting from that file's AMBIENT SCOPE (a stylesheet's `body` or `:root` rule, a module's
  top level setup, a test file's shared fixture), and because the inherited thing is usually a
  DEFAULT, the extracted copy still runs and still looks finished while quietly using the
  platform's default instead. Prove it by reading back what the running system actually
  applied, never by checking that the extraction renders.** Distinct from L218, which is about
  an OMITTED rule falling back to a neighbouring rule inside one policy chain: here nothing was
  omitted from the thing extracted, the loss is in what surrounded it. Distinct from L501,
  where the clone carries stale VALUES: here the values are correct and a rule is simply absent.
  (ovation#120, 2026-09-07: the settled screen was lifted out of a committed design file to
  build a design round on it, taking the fonts, the palette and every screen rule but not the
  page chrome those rules sat beside. The settled typeface was set on `body`, so the whole
  window rendered in the system face. All four faces still LOADED, since the mono and serif
  rules named their families directly, so a check that the embedded fonts were present passed;
  what caught it was reading `document.fonts` back and seeing Archivo reported `unloaded`
  because nothing was asking for it. A class name collided in the same extraction, `.nrow`
  already being the neighbouring screen's names column.)


## Cross-system reliability

- **L405. A check deciding whether anything is NEW must compare what the artifact MEANS, never its
  whole serialized form, because a record routinely carries provenance that changes on every run
  (a timestamp, a run id, a commit), so the check fires every time, the work repeats, and any
  verification already earned against the previous version is silently invalidated.** L40 is this
  same comparison failing the other way, and reading it as "compare the whole file" is what
  produces this one, so the thing being compared has to be the measurement rather than the bytes
  around it.
  (postroll#1392, 2026-09-05: `propose_recorded_change.sh` asks `git diff --cached --quiet` over
  the whole record. PR #1383's head moved three times in half an hour, every commit recording the
  identical count of 3175 and differing only in `measured_at_commit` and `measured_from_run`. One
  of those greens was refused at the merge because the branch had moved under it, and the script's
  own "already carries this record" branch, written to prevent exactly this, could never be
  reached)

- **L403. An automated flow that both PUSHES a branch and OPENS a pull request must use the ONE
  credential for both halves, because a platform gates or suppresses the workflow runs triggered
  by its own default identity, so the update silently carries no checks and an empty check list is
  indistinguishable from one whose checks have not started yet (L98).** The first proposal looks
  fine, because opening the pull request is the half that carries the real token; it is every
  later update to that same branch that arrives attributed to the bot and stalls. So the failure
  appears only on a re-push, which is exactly when the newest measurement is the one waiting.
  CHECK THAT THE ONE CREDENTIAL CAN ACTUALLY DO BOTH before shipping the change, because the
  obvious fix moves the push onto the pull request's token and a token scoped to OPEN pull
  requests cannot PUSH. That trades a silent stall for a hard failure, and it fails on precisely
  the runs that had work to do, so it reads as green on every quiet run in between.
  (PostRoll#1390, 2026-09-05: `propose_recorded_change.sh` opens with `RECORD_UPDATE_TOKEN` and
  then pushes with whatever `actions/checkout` persisted, the default `GITHUB_TOKEN`. PR #1387,
  freshly opened, ran 8 checks as `danwright32`. PR #1383, re-pushed the same day, sat at
  `action_required` as `github-actions[bot]` with 0 checks reported, and `wait_for_checks.py`
  correctly refused to call that green, so it could never merge. The fix that gave
  `actions/checkout` that token was reverted the same hour: the first recorder run after it
  merged died with `Permission to danwright32/PostRoll.git denied to danwright32`, a 403 at the
  push, because the token could open a pull request and not push)

- **L393. An automated job that creates a NAMED outside thing somebody has to act on (a pull
  request, an issue, a draft, a branch keyed on a date) collides with its OWN previous output
  for as long as that output sits unconsumed**, and the collision surfaces as a hard failure
  rather than as waiting, so the job goes red for a reason unrelated to the work it does and
  every genuinely new failure afterwards arrives indistinguishable from it (L538). This is not
  the concurrency case: the earlier run SUCCEEDED, and what blocks the next one is a person not
  having got to it yet. Update the existing artefact in place, or make the second run a success
  that says it is waiting.
  (PostRoll#1321, 2026-09-04: `record-suite-count.yml` pushes a branch named for the day. Its
  own proposal from 09:49 was still open, so every run after it was refused at the push and
  died, 37 failed runs and 37 emails in one day, none of them about the count it measured.
  PostRoll#1011's failure reporter, written the same day, had already reached the other answer
  independently: one issue per workflow, comment on it rather than file again, and converge if
  two shards race to create it)

- **L365. A retry must read what the refusal itself says about when it could succeed, because a
  backoff measured in seconds cannot outlast a limit measured in hours, and every attempt against
  a spent allowance spends more of the exhausted thing to be told the same answer.** A metered API
  reports its own state (Meta's `x-app-usage`, a `Retry-After` header, a quota field), and that
  reading is the answer the retry would otherwise spend a call to rediscover. Read it, and when it
  says the window cannot clear, report the refusal rather than attempting again.
  (PostRoll#1002, 2026-09-01: a sweep of 122 handles retried 82 rate limited accounts three times
  each, one and two seconds apart, while every response carried `call_count` 275, meaning 275% of
  the rolling hour's allowance already spent. 246 calls that could not have succeeded, and the
  original probe's "114 calls in 2 minutes with no rate limiting" was never evidence either,
  because 80 of those 120 seconds were its own sleep)

- **L276. A CI job is priced in allowance minutes, which is the runner's multiplier (macOS ten,
  Windows two) times its rounded-up minutes, and that price is set before the job is added**,
  because an exhausted allowance refuses every later run before its first step, and a refused
  run is indistinguishable from a failed one in every list, so the remaining allowance must also
  be visible somewhere before the day it is zero.
  (playedit#344, 2026-08-29: the Swift job runs on a macOS runner at ten to one. Fourteen
  ordinary runs on 27 and 28 July, 197 macOS minutes, drew 1,970 of a personal account's 2,000
  free minutes in 26 hours, and the fifteenth run was refused with a billing message before
  either job started. For a month the only trace was a red check on one PR, read as a failing
  test; no push happened in that month, so the shortfall was never noticed as one. With no
  timeout on the job, a single six hour hang would have cost 3,600 allowance minutes)

- **L525. A retry wrapper re-runs its whole body, so an action inside it that TOGGLES state (an
  open that is also a close, a mute that is also an unmute) is inverted by the second attempt,
  and the loop can report success while leaving the state nobody asked for.** Retry only
  idempotent bodies: test whether the target state already holds before acting, or move the
  toggle outside the loop and retry only the wait. Raising the inner timeout only moves the load
  level at which it races, which is why this survives being "fixed" once.
  (project-enrollment-tracker#1161, 2026-08-29: a browser test wrapped focus, press Enter and
  "the picker exists" in a toPass loop. Under load the picker took longer than the inner 600ms
  to appear, so the attempt failed, the loop pressed Enter again on a picker that was now open,
  and the assertion after the loop found nothing on the page)

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

- **L321. The pid a shell records for a background job names the WRAPPER, not the work, because the
  command it is sleeping in is a child of that pid and survives a kill aimed at it, so start such a
  job under job control and signal its process GROUP.** Keep a plain kill of the pid beside the group
  kill: a group that was never created makes the group kill a silent no op and the wait behind it an
  unbounded hang, which is the one failure the guard written to catch it can never report, since it
  can only speak once the run is over. Reading the children with `pgrep -P` first is not the same
  remedy and looks like one: it reaches a single generation and races the fork between the read and
  the kill.
  (overture#3248, measured 2026-08-29. Three helpers in one repo had the pgrep shape or no remedy at
  all. A fixture leaked two `sleep 300` processes per run into a folder macOS clears only at boot,
  and its own comment claimed it left no process behind. Taking job control away from the fixed
  version with only the group kill present turned the proof run into an endless hang rather than a
  red, which is what the plain kill beside it is for. overture#3253 covers the same shape in three
  POSIX `sh` runners, where the group behaviour has not been measured yet)

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

- **L366. A lock must be released as soon as the writes it protects are done**, because any
  verification, reporting or notification step left inside the critical section makes every other
  waiter's latency depend on work that never needed exclusion, and that coupling grows silently as
  the trailing step grows. Distinct from L519, which is about two jobs sharing one lock; this is one
  job holding its own lock across work that does not write what the lock guards.
  (claude-config#269: `do_send` runs the suites covering a changed hook while holding the sync
  lock, so editing `run-all-tests.sh` pays roughly three to five minutes per save (the suites naming
  it include the two slowest in the tree, 85s and 125s idle, 211s under load), and the watcher fires
  on every save. The suites write nothing the lock protects. Corrected 2026-09-02: this lesson was
  first written from claude-config#267 against the PULL path, and that was wrong. `with_lock`
  releases the lock and only then calls the suite, with a comment saying so and citing #181 as the
  measurement that drove it, so the pull was already right when the lesson was recorded and #267 was
  closed as already done. The rule is unchanged; the instance moved to the path that actually has
  it, which is the one added afterwards)

- **L371. A gate added to a shared delivery path refuses the WHOLE payload, so a failure in one
  item stops every unrelated thing travelling with it**, and a delivery that has silently stopped is
  indistinguishable from one with nothing to send. Scope the refusal to the item that failed, or
  state plainly that the gate can halt everything and give the stoppage its own visible signal.
  (claude-config#244 and #269: a send that publishes `~/.claude` to the other Mac now runs the test
  suites covering any changed hook and refuses to commit when one fails. The refusal is total for
  that send rather than scoped to the hook, so an unrelated red suite also stops rule files, skills
  and lessons reaching the other machine. claude-config#196 had already recorded that a watcher
  which stopped sending is hard to notice, because the log writes a line only on failure, so this
  added a new way to stop that looks the same from outside as working normally)

- **L255. A consumer that gates on an exact SET of accepted format versions turns the producer's
  next additive bump into a total outage of itself**, because an unrecognised version is refused
  WHOLE rather than read partially, and the consumer then reports EMPTY data that is
  indistinguishable from the data genuinely being gone. Gate on a minimum and accept anything
  above it wherever the format's own contract says changes are additive. Distinct from L113,
  where a missing key takes a silent DEFAULT branch: here the whole payload is rejected, and the
  rejection is correct behaviour for a gate that was simply written too narrow.
  (overture#3193, 2026-08-27: `DownbeatBridge.supportedVersions` is `[1, 2]`, so Downbeat bumping
  its shared export to v3 for a third consumer would make `loadWithHealth` return empty clients,
  empty bookings and empty blockedDates, and the scout would stop suppressing nights Dan is
  already shooting. The same repository had already learned this in `PrepResultsDecoder`, which
  gates on `minimumVersion...supportedVersion` and carries a comment that an exact match gate
  "was the brittle pattern that broke the results reader when its version bumped (#132)". The
  fix was never generalised to the second decoder, which is L30 in the same codebase)

- **L258. A consumer that acknowledges work by DELETING the record makes an absent record mean
  both "consumed successfully" and "never written"**, so the producer can never detect a handoff
  it failed to write, and no amount of looking at the queue will tell it. The usual crash safe
  remedy of recording intent and confirming afterwards does not close this on its own, because
  the intent marker has the same two step problem it was added to solve: set it before the write
  and a crash leaves it claiming a record that does not exist, set it after and a crash leaves a
  written record reading as unwritten. What closes it is the pair, a durable mark on the
  producer's side that it wrote, plus a consumer that ignores an identifier it has already
  consumed, and the second half has to actually exist before the first is built against it.
  (downbeat#432, 2026-08-27: the Ovation handoff queue saves the Booking row and then writes the
  queue file, two steps with no lock. Ovation deletes each file once it has saved the invoice, so
  a booking lost to a crash between the two is invisible from Downbeat, and the seven day
  retention sweep then removes it from both apps. Re-queueing anything with no file, the obvious
  repair, would draft a duplicate invoice carrying a real invoice number for every booking
  already consumed. Ovation PRD 36 commits to the consumed-identifier record that makes the
  repair safe, citing L512, and it is not built yet)

- **L259. An escape hatch that switches a gate OFF is inherited by every process that command
  starts, including the gate's OWN self-test**, so reaching for it silently reduces the checking
  that polices the very gate being escaped, at the one moment somebody has already decided to
  push past a refusal. The variable is written to mean "skip this gate for this push" and is
  read by anything downstream that consults it, which includes the harness that drives the gate
  as a subprocess and asserts it BLOCKS. Scope it where the gate is invoked, and have any
  harness driving that gate UNSET it, setting it back explicitly only for the cases that are
  about the override. Distinct from L504, which is a test inheriting ambient configuration in
  general: this is a bypass flag having a blast radius wider than the single gate it names.
  (downbeat#433, 2026-08-27: `scripts/test-pre-push-hook.sh` reports 36 passed and 0 failed on a
  clean environment, and 15 passed with 21 failed under `SKIP_TEST_RUN=1`, so the documented one
  push escape hatch switches off 21 of the checks verifying the gate it escapes. Found because
  the identical shape had just bitten a newly written gate's harness, where `env -u` fixed it;
  the class was only visible by asking whether the older harnesses had the same hole)
- **L522. A time or size budget calibrated for ONE execution context is wrong when the same
  code is reached from another (a scheduled job versus a request, a worker versus a CLI, a
  foreground run versus a background one), because the platform ceiling differs**, so the
  code commits to work it will not be allowed to finish and dies mid task instead of
  stopping cleanly, leaving whatever its cleanup would have released.
  (bidspoke#1048: the archive's 10 minute wall budget is documented as sized "inside the
  platform's cron limit", and the manual recovery route runs that same run loop from a
  fetch handler. Measured, the scheduled path did two hours in 390 s while the request path
  was killed at 218 s with "exceeded resource limits" partway through its second hour. A
  killed isolate never runs its `finally`, so its lock stayed held and the next scheduled
  run reported a killed predecessor, which is where the operator's alerts came from. Note
  the trap in fixing it: WHICH ceiling fires has to be measured, because if it is CPU then
  changing a wall clock budget cannot prevent the kill and reads as a fix that changed
  nothing)
- **L527. A retry that CHANGES the request on the assumption of one particular cause (stripping
  an id it guesses collided, dropping a field it guesses was rejected, narrowing a scope) must
  confirm that cause from the actual error before altering anything**, because every other
  failure, a timeout above all, then silently produces a different and degraded write rather
  than the one that was asked for. A plain retry is idempotent in intent; a rewriting retry is
  a second, unreviewed code path that only ever runs when something is already wrong, which is
  exactly when nobody is watching what it sent.
  (project-enrollment-tracker#1176, 2026-08-31: the roster sync strips Salesforce ids off a
  batch of new hires and re-POSTs on ANY insert failure, so a network blip writes them id-less,
  and a timeout that landed AFTER the write committed produces a 409 plus an alert claiming the
  reps were not written when they were. Compounding it, the lookup that would have proved a real
  collision is an unpaginated read capped at 1,000 rows, so the strip-ids path masks that
  truncation instead of surfacing it)

- **L533. A job on a sparse schedule (weekly, monthly) whose only failure remedy is running it
  again needs an automatic re-attempt within the same period, because an in-process retry
  measured in seconds cannot outlast a real outage, and a transiently failed run otherwise
  silently costs the whole schedule interval.** The alert on the failure is not the remedy: it
  hands a person a manual re-run whose omission nothing will ever report, and the checks read
  as covered the entire week they never ran.
  (project-enrollment-tracker#1192, 2026-08-31: the weekly data-integrity run failed both
  feed-reading checks because the Beyond SFTP handshake timed out for the whole run; the
  in-process retry spans about six seconds across three attempts, the outage lasted longer than
  the four minute run, and the next scheduled attempt was seven days away. A manual dispatch an
  hour later passed clean, so one automatic re-attempt a few hours later would have healed it
  with nobody involved)

- **L369. A lock that serialises heavy work must be scoped to the RESOURCE it protects, never to the
  project that created it, because another project on the same machine does the same heavy work and
  cannot take a lock it has never heard of.** A per-repo lock over a machine-wide resource reads as
  protection while protecting only against itself. Measured 2026-09-02 (overture#3478): Overture
  serialises its Swift suite through one machine-wide file lock, so two Overture runs can never
  collide, and while a Phase 0 control measurement was being taken PostRoll launched
  `pytest -n auto` from another checkout, spawned 13 workers and took the Mac from load 4.03 to
  69.51. The lock was working perfectly and was irrelevant. This is the PREVENTION half of L364,
  which covers only how to notice a dirty machine, and it applies wherever several projects share
  one Mac: the lock belongs outside any checkout and every project doing that class of work has to
  take it.

- **L372. A script that changes its own working directory must capture its own location BEFORE the cd,
  because a path re-derived from `$0` afterwards is relative to where the script was INVOKED from
  rather than where it now is, so it resolves for one invocation and silently misses for another.**
  The failure is PARTIAL, which is what hides it: the script's main job succeeds and only a later
  step is skipped. Measured 2026-09-02 (overture#3481): `mac/build-install.sh` cds into its own
  directory on line 10, then sources `"$(dirname "$0")/scripts/lib/build-provenance.sh"` on line 131.
  Run the way the project's own docs say, from the repo root, that resolves to `mac/mac/scripts/...`
  and fails. The build succeeded, the bundle was replaced and correctly signed, the app ran, and the
  only casualty was the provenance record the in-app freshness panel reads, which was simply never
  written. Capture the directory once at the top, or make it absolute, and cover it with a test that
  invokes the script the way the documentation says to, since that is the invocation nothing was
  exercising (L52, L96).

- **L386. A scheduled job's DECLARED time is not when it runs, because platforms delay
  scheduled work by hours under load, so two scheduled jobs must never be ordered by clock
  arithmetic between their crons.** Key the later one off the earlier one's COMPLETION, and
  where that is impossible, measure the real start times before writing a cadence down.
  (PostRoll#1262, 2026-09-03: a recorder was scheduled at 09:00 "two hours after the sweep's
  own 07:00", and the last six scheduled runs of that sweep actually started at 11:55, 11:57,
  12:21 and 14:50, so the recorder ran hours BEFORE the thing it was written to follow, every
  day. The behaviour degraded quietly, the record simply stayed a day behind, and what was
  actually wrong was a confident sentence beside a cron that the next person would reason
  from, which is L316 and L244 in a different costume.)
- **L379. Doing by hand what a tool normally does performs the visible change and silently
  omits the tool's OTHER writes, and the one most often omitted is the record some monitor
  reads, so the system ends up correct while the monitor is permanently wrong.** Before
  substituting a manual step for a tool, enumerate every write the tool makes, not only the
  one you wanted. (nursedex#909, 2026-09-02: `supabase db push` is unavailable both to Dan
  and from the dev machine, so migration 068 was applied by pasting its SQL into the Supabase
  dashboard. That added the column correctly and skipped the row the CLI writes into
  `supabase_migrations.schema_migrations`. Nothing about the schema was wrong; Migration
  Drift would simply have reported 068 as committed to git but never applied, indefinitely,
  and that channel's whole value came from catching migration 043 merged but unapplied
  (#518), so a permanent false entry is how the next real one gets overlooked. Caught before
  it shipped only by asking what else `db push` does. Note the recording query must not be
  written from a guess at the table's columns: it was read first, and it turned out to be
  `version` text holding the numeric prefix, `name` text holding the rest of the filename,
  and a `statements` array that is null on every real row.)

- **L390. In a two way sync, a file REGENERATED from one side rather than mirrored gets none of the
  protection the mirrored files beside it get, so a merge rule written for the receiving direction
  has to be written again for the sending one.** The loss is silent in the sending direction,
  because the regeneration always succeeds and simply produces the older content.
  (claude-config#300, 2026-09-03: `payload/settings.hooks.json` is rebuilt wholesale from
  `~/.claude/settings.json` on every send, while the APPLY side merges it three ways and its own
  comment says why. `do_sync` stages before it pulls, so a clone twelve commits behind committed
  the older hooks block and the rebase replayed it over the newer remote. A hook that had just
  shipped, with its file and its test both present on the shared repo, was left registered nowhere
  and therefore inert. The sync reported success; the only thing that noticed was the wiring check
  inside that hook's own suite, going red on the deployed Mac)

- **L625. A two way mirror transmits what EXISTS and has no way to transmit what was REMOVED, so a
  replica that has not yet received a deletion restores the deleted item on its next send, and the
  restoration is indistinguishable from a legitimate addition.** Carry deletions explicitly, as a
  tombstone or as a refusal to re-add anything deleted since that replica last received, rather
  than trusting the mirror to convey an absence. Distinct from L390, which is about a REGENERATED
  file beside mirrored ones: this item was mirrored, and mirroring is exactly what reversed it.
  Distinct from L381, where the mirror has ONE authoritative side and the other side's edit is
  correctly reverted: here both sides are authoritative and the stale one wins.
  (claude-config#331, 2026-09-07: skills/running-design-rounds was renamed to skills/design-rounds
  on one Mac and published. The other Mac, whose published apply state predated the rename, then
  sent three times, and stage_local_to_payload re-added the old folder from its own home, putting
  it back on both Macs. Two loadable skills then carried identical description frontmatter, so the
  assistant saw two skills competing for one job. The receive reported the restored files as
  ordinary additions, and it was noticed only because a name that had just been deleted reappeared
  in the session's skill list.)

- **L409. Two primitives that provide the same visible exclusion or ownership (a file lock against a
  directory used as a mutex, a lease against a flag, a transaction against a hand rolled guard)
  routinely differ in what happens when their HOLDER DIES, because some are released by the kernel
  and some need cleanup that nobody runs after a crash, so swapping one for the other ships a
  regression no test that does not crash can see.** Name the crash behaviour of BOTH before the
  swap, and prove it by killing a holder rather than by reading the docs. (overture#3571,
  2026-09-05: three Mac apps share one build machine, and Downbeat's runner asserts in a comment
  that its lock "is shared with Overture deliberately" while `xcodebuild-tests.lock` appears
  nowhere in Overture's tree, so the two have never excluded each other. The tidy fix, and the one
  the implementation plan recommended, was to point Overture's runner at Downbeat's path. It is a
  mechanism rewrite, not a path edit: Downbeat takes the lock by `mkdir` on a DIRECTORY, Overture
  by `flock` on a FILE, and they cannot coexist at one path. The cost nobody had priced is that
  `flock` is released by the kernel when its holder dies while a `mkdir` lock is not, which is
  exactly why Downbeat carries `claim-stale-lock.sh` and a 1800 second timeout. Converting Overture
  without bringing that machinery across would have traded a crash safe lock for one that parks a
  stuck lock in front of the next run for half an hour, in exchange for a tidier estate. Ovation
  took both locks instead, by the mechanism each one uses, in a fixed order)
- **L600. A lock guarding a job the platform RETRIES must let the retry recognise its dead
  predecessor, because a retry arrives seconds after the kill carrying the same event identity, and
  a lock that can only expire by deadline refuses the platform's own recovery while reading as
  correct behaviour.** Stamp the lock with the event identity, so a holder carrying the retry's own
  identity is proven dead: the platform only retries after the previous attempt has ended.
  (bidspoke#1181, 2026-09-05: Cloudflare terminated the hourly archive invocation three times in
  ten days, each shown in analytics as one `clientDisconnected` invocation with CPU far under the
  limit, and re-dispatched the cron 43 seconds to 3 minutes later with the same `scheduledTime`.
  Every retry read the dead run's lock as a live holder with nine minutes of deadline left,
  recorded `skipped-locked`, and the hours waited a full cadence for the deadline rule. Two of the
  three were never alerted because archive alerts were muted at the time)
- **L617. An operation that keeps its progress in an on disk resumable state (a git rebase or
  merge, a migration runner, a batch cursor) leaves that state behind when its process is killed,
  and the leftover reads as HEALTHY to every check that examines content, because the queue is
  empty, the tree is clean and nothing conflicts, so the next run must inspect the operation's own
  progress marker rather than the data it was moving.** The leftover is neither a failure nor a
  conflict, which is what makes it invisible: there is nothing to resolve and nothing red. Check
  for the marker at the START of a run, conclude it where it is clean, and refuse loudly where a
  real conflict is pending.
  (claude-config#324, 2026-09-07: `~/claude-config-sync` sat on `(no branch, rebasing main)` for
  23 hours after a run was killed just after its rebase applied its one commit and just before it
  concluded. `.git/rebase-merge/git-rebase-todo` was EMPTY, `git status` was clean, and no path was
  unmerged, so every content check agreed the repo was fine; the only anomaly was `main` still
  pointing at the pre rebase commit while `HEAD` held the rebased one, and nothing read that.
  `git rebase --continue` fixed it and changed no content. Meanwhile the clone reached 26 commits
  behind, 15 lessons written on that Mac went unpublished, and `pull` blamed a two Mac divergence
  that had not happened, per claude-config#325)

- **L618. A one time import or correction that copies data between two systems which both stay
  live is a snapshot rather than a fix, so the check that proves the two still agree ships in the
  same change.** The import's own idempotency re-run proves only that it was right at that moment,
  and it is the most convincing possible evidence that nothing further is needed.
  (slate#1738, slate#2031: 97 agent schedules were imported from cal.com into Slate on 2026-09-02
  and the second dry run reported `would change: 0, already matching: 97`, which read as the job
  being finished. Nothing re-checked them. Five days later 21 of 102 agents had drifted: 6 with a
  different set of working days, 6 with different hours, 9 with a renamed timezone. Three were not
  being offered a day they work and two were being offered a Saturday they do not, and no surface
  in Slate could report any of it, because a stored week saying 08:00 is indistinguishable from an
  agent who really starts at 08:00. It was found only because a comparison command was built for a
  different reason, and the first thing it did was find it)

- **L620. When replicating a system's behaviour, enumerate its inputs from what it ACTUALLY
  consults at decision time, never from the upstream source those inputs are supposed to come
  from.** The ones maintained by hand inside the incumbent have no source anybody thinks to list,
  so they are the ones that get missed, and the replica looks complete because every input that
  did have a source was ported correctly.
  (slate#2033, 2026-09-07: Slate replaces cal.com's booking routing, and its routing attributes
  were built from the Salesforce User fields both systems read: the five debt tier booleans and
  the two backend servicer ones. Every one of those was ported faithfully. cal.com ALSO excludes
  any agent whose `Redistribute Team` attribute is YES from every routing decision it makes, and
  that attribute exists only in cal.com: the Salesforce User object has no such field, so it is
  maintained by hand and nothing in Slate has ever heard of it. The consequence is that Slate's
  routing pools are wider than cal.com's by however many agents are marked, so at cutover Slate
  would route real leads to people deliberately held out of rotation, and an agent receiving a
  booking looks identical whether or not they were meant to be excluded. It surfaced only because
  cal.com stamps the rule it matched onto each booking as an `assignmentReason` string, which was
  read while building an unrelated comparison; nothing else in either system would have said it.
  Note the count could not then be measured, because cal.com's API returns 404 for per-user
  attribute values, so the input that was invisible is also the one hardest to audit. The remedy
  turned out to be cheap, since Slate's existing `bookable` flag already expresses exactly that
  exclusion and the fix is a data correction rather than a new field: the entire cost was in not
  knowing the input existed, which is the point)

- **L423. Configuration INSTALLED into the platform (a launch agent, a cron entry, a systemd unit,
  a git hook, a shell alias) is a COPY, so changing its definition in the source changes nothing on
  any machine until that machine re-runs the installer, and nothing reports a machine still running
  the old copy.** Record what each machine actually has installed and compare it against what the
  current source would write, rather than assuming a definition change has travelled.
  (claude-config#328. On 2026-09-07 the shared config tool's catch up timer was shortened from
  weekly to daily because a weekly job could not bound a drift that appeared daily. The change
  landed in the source, was committed and pushed, and both Macs pulled it within minutes, so every
  signal said it had shipped. It had not: the launch agent is written only by `install-autosync`,
  which nothing re-runs, so one Mac was on the new interval and the other was still on the old one
  with nothing anywhere reporting the difference. The same shape covers this repo's own git hooks,
  which are installed per checkout, and pg_cron jobs in bidspoke, where changing one setting mints
  a new job id rather than editing the running one)

- **L434. A character written as a backslash escape INSIDE a pattern handed to grep or sed is read
  one way by the BSD tools a Mac has and another by the GNU tools every Linux runner has, and
  neither errors, so the pattern silently stops matching and whatever consumed the result reads as
  zero.** Produce the character instead (a tab from `printf`, a class like `[[:space:]]`), and
  remember that a portable TOOL is not a portable PATTERN: a scan for tools only one platform has
  cannot see this, because the tool is the same tool on both.
  (claude-config#335. A count of tab separated records was written `grep -cE '^(diff|topdiff)\t'`.
  BSD grep matches that as a tab; GNU grep matches a literal `t`, so on the runner the count came
  back 0 whatever the enumerator had found, and `verify` called a Mac holding unsent work up to
  date and exited 0, which was the exact reassuring answer the feature had just been written to
  stop it giving. Green on both Macs and red on every Linux run for seven hours, with nothing
  anywhere reporting an error)

- **L435. A tool that writes commits of its own must pass its OWN identity on every git call that
  can create a commit, because a machine may have none configured (every CI runner, any freshly set
  up machine) and git REFUSES rather than defaulting.** A call without it works wherever git can
  find or guess an identity, so it passes on the developer machine by silently borrowing the
  operator's and fails on exactly the machines nobody is watching. Write the rule as the class,
  every commit writing call, rather than as the one line that was caught.
  (claude-config#335. `recover_unfinished_rebase` ran `git rebase --continue`, which writes a
  commit, with no identity, while the same tool carried a `SYNC_GIT_IDENTITY` it used for every
  other commit it made. On the runner git answered "Committer identity unknown", so the tool
  declared the clone unable to send or receive and changed nothing. It could not be reproduced on
  either Mac until the fixture took the machine's own git config out of reach and stopped git
  guessing one from the username and hostname)


## Test speed

Distilled from the 2026-08-29 test speed audit of nine repos (Bidspoke, PET, Slate, NurseDex,
PlayedIt, claude-config, Downbeat, PostRoll, Overture). Full text with the measurements:
~/.claude/audits/2026-08-29-test-speed-audit/. These are the rules that apply while WRITING a
test; the ones that apply while shaping CI or a pre-push hook are in "Pipeline speed" below.
Read alongside L524 (an injectable sleep from day one), L284 (every seam set or named), L286
(one derivation per suite) and L288 (judge a run by its executed count first).

- **L290. A test that waits a FIXED time for something (a click to land, a clock to move, a poll
  to fire) is asserting about the machine's load, so wait on the condition itself, or SET the
  clock, and the instant version is the stronger test.** A fixed 300ms after a click is a budget
  that stops being enough under CI load, which is exactly when it is judged (L522), while a wait
  on the row appearing is faster on the happy path and cannot flake for that reason. A fixture
  that sleeps so two timestamps differ can set them instead (GIT_AUTHOR_DATE and
  GIT_COMMITTER_DATE), which pins both ends (L130, L134). A poll interval is a sleep with a
  condition attached, and its granularity is the seam: a watchdog that polls every 2 seconds
  makes the smallest stall a test can stage several seconds long.
  (PET, 2026-08-29: about 28 seconds of its browser suite is fixed timer sleeps, fourteen specs
  sleeping 100 to 600ms after a click and two waits with nothing conditional after them at all.
  PostRoll: one Swift file sleeping 2.05 seconds between git commits, 24 seconds a run.
  claude-config and Downbeat: lock and tracker polls fixed at 1 and 2 seconds, about 40 and 25
  seconds of their shell suites)

- **L291. A test that can only pass by REACHING something (a network, a live service, a real
  client) is either an integration test that lives with the others, or a test with a missing
  seam, and one that asserts only that a failure happened is satisfied by the environment failing
  and pays a timeout to prove nothing.** L140 says any throw satisfies "it threw"; the speed form
  is that the throw it gets in CI is a network timeout, so the test waits for the timeout on the
  way to a pass that means nothing. A file comment saying "no protocol seam, so test the real
  thing" is the whole cost written down as a design.
  (playedit#344, 2026-08-29: the Apple sign-in tests call the real client with a junk token and
  assert it returned false and set an error. In CI the client points at a placeholder host, so
  the network fails, the assertion passes, and four tests wait 10 to 308 seconds per run)

- **L292. A subsumption sweep (which tests are strictly weaker than a neighbour, which titles are
  duplicated) is worth running even when it finds nothing, and when it does find a deletion, name
  which surviving test covers each deleted assertion.** A clean sweep is not wasted: it is what
  licenses spending the whole speed effort on the pipeline instead of the tests, and in eight of
  nine repos that is where the time was. A deletion without a named survivor is coverage removed
  on a promise.
  (2026-08-29 audit: PET found weak tests standing beside strictly stronger neighbours and the
  same auth-gate tests copied into six files; Bidspoke's 400 file sweep, Slate's 499, NurseDex's
  226, and the sweeps at Downbeat, PostRoll and Overture all came back clean. Bidspoke's first
  pass had CLAIMED the sweep without doing it, which the second pass caught)

- **L293. A flake is a speed cost priced at a full re-run, and a retry hides the price, so count
  flakes on every run, put the count where a reviewer looks, and rank a recurring one with the
  speed findings rather than the reliability backlog.** Retries are the right call (a red PR and a
  manual re-run is worse), but they convert a failure that would have been investigated into a
  delay nobody sees, and an html reporter nobody opens is the same as no reporter. The opposite
  failure hides the same way: a parallel run that loses a whole worker's share has no retry and
  no crash line, and only a count against a baseline sees either (L288).
  (project-enrollment-tracker#931, 2026-08-29: filed as a flake and priced a month later at a 7
  to 9 minute re-run in both currencies. NurseDex: two of ten E2E runs took 413 and 462 seconds
  against 210 to 230, both green, because `retries: 2` absorbed the failure. Overture: 4,875 of
  8,595 tests executed and a verdict naming twelve failures)

- **L294. On a starved runner, per-test durations measure the runner, not the tests, and some
  runner formats print elapsed-since-start rather than cost, so read the format and the core
  count before reading the numbers, and keep only what is slow in every one of several runs.**
  A 3 or 4 core machine hosting a build toolchain, two simulator clones and the test process
  reports whichever test happened to be running while it was frozen (L203). xcodebuild's parallel
  format and Swift Testing under Xcode 26 print `passed after N seconds` where N is elapsed since
  the worker began, so a one line boolean reads as 64 seconds and the column sums to ten times
  the wall clock: that table is a start order, not a cost table.
  (PlayedIt, 2026-08-29: a struct constructor at 70.8 seconds and a one-line boolean at 21.8,
  and the next run names a different set of trivial tests; exactly one group survived the
  several-run filter and it was the real finding. Downbeat: 3,211 of 3,267 tests read as half a
  second or more inside a 27 second run. Overture: the same suite prints real costs in its serial
  log and elapsed-since-start in its parallel one)

- **L295. When the tests are the time, the suite's own concurrency setting is the first thing to
  read, in the runner you actually use, and the reading is arithmetic: sum the per-test durations
  and compare with the wall clock, because equal means one core and no reading of the source will
  tell you that.** Swift Testing runs in parallel under `swift test` and serially under an Xcode
  scheme whose testable says `parallelizable = "NO"`, which is what the generator writes when
  nobody says otherwise, and a belief about the default can be recorded in a lock's own header as
  fact for months.
  (Overture, 2026-08-29: a process-wide lock written on the belief that suites run concurrently
  by default, in a scheme where nothing ever had. PostRoll: 416.7 seconds of summed test bodies
  against a 417.8 second testing phase, both numbers already printed in the log, in a project
  whose scheme carries no `parallelizable` at all because xcodegen wrote none)

- **L296. Anything that divides work between workers (shards, a launch order, a balance check)
  divides by a MEASURED cost, never by a count of items, and the check that guards the balance
  measures in the same unit (L63), or it passes while measuring the wrong thing.** Counting
  sections balances nothing when the slowest five are 52, 38, 27, 27 and 24 seconds against a
  median under 2. And a measurement that only exists on the machine it was taken on is not in
  CI: a timing store under `~/.cache` orders nothing on a runner that starts cold, and an `npm ci`
  deletes vitest's own results cache on every run, so both order by file size every time and
  happen to be right until the day they are not.
  (claude-config#144 and #107, 2026-08-29: the runner one level up kept a per-suite timing store
  and ordered by it, the suite one level down printed every section's duration and used none of
  it; at four shards one carried 165 seconds and the lightest 76. Every CI run prints "measured
  wall clock for 0 of 42 suites, file size for the rest")

- **L297. A scanner that guards a class of fault across the whole tree pays per line, so it is
  written as one pass per file from the start, and a failing guard's full output is kept (L148)
  so an intermittent failure can be diagnosed instead of retried.** A per line subprocess loop is
  fine at a hundred lines and is the whole wait at twenty thousand, and its cost grows with the
  tree it guards, which is the one thing about it that never stops growing.
  (Downbeat, 2026-08-29: the pipefail scanner is the right guard (four hand fixes, then a check,
  L30) and it spawned a `sed` and a `grep` per line for 17,353 lines of shell: 80 to 177 seconds,
  and one unexplained failure in three runs that nothing kept the output of)

- **L298. A harness that reruns the suite once per case (a mutation sweep, a property sweep, a
  matrix, a suite that tests itself by launching itself) pays the boot once per case, so the
  lever is the boot, then the cadence, and never the tests; the per-case verdict semantics that
  make the tool trustworthy must survive the change unchanged.** N boots dominate N runs of a
  24 second suite. After the boot is as cheap as it gets, ask how often the sweep runs: a proof
  that changes only when a guard or its target changes does not need re-proving on every merge.
  (NurseDex, 2026-08-29: 105 mutants, each a fresh vitest process, 207 to 219 seconds on every
  push to main for about 24 seconds of test bodies. claude-config: 39 launch sites at 1.4 seconds
  each before the first section runs. PostRoll: 433 guards re-proved 33 times a week at four
  macOS runners for 23 minutes, for facts the per-pull-request job already proves)

- **L433. Work a runner SPLITS across parallel workers must be self contained per unit, because the
  split is chosen at run time from measured cost and moves between runs, so a unit that reads what
  its neighbour set up passes until the day the two land in different workers.** It then fails by
  DYING rather than by failing, and a worker that dies reports no verdict at all, which reads as
  nothing wrong unless something counts the verdicts.
  (claude-config#333, 2026-09-07: a suite section was added that read a variable the section above
  it defined. The suite deals its sections to four workers by measured section time, so the pair
  landed together in some runs and apart in others: under `set -u` the orphaned one died, its
  worker printed no result line, and the total came back 1,232 instead of 1,590. Which worker died
  moved from run to run, and three separate theories were measured and disproved before the run log
  was read far enough to find the unbound variable message. The suite's own count guard is the only
  reason it was caught at all, which is L288 working; nothing catches the cause)

- **L438. A measurement taken by SAMPLING from inside the same context as the thing being measured
  (polling in a script that shares the browser's frames, a profiler on the thread it profiles, a
  logger on the loop it watches) can itself be the load that changes the result, so a reading
  saying the thing under test is slow or dead is first evidence about the MEASUREMENT. Judge by
  the events the platform emits for that work rather than by observing it from beside it.**
  Distinct from L356 and L294, which are about what ELSE the machine is running: here the observer
  is the load, so the reading is true about that run and false about the code, and it gets worse
  the harder you look.
  (ovation#111, 2026-09-07: four transitions were checked by clicking a row and then sampling the
  computed style every few frames from the same script. One option read as never moving at all,
  and it was reported to Dan as broken. Re-measured with the browser's own `transitionstart` and
  `transitionend` events, with the script doing nothing in between, that same option ran from 33ms
  to 307ms, which is the 280ms it was written to take. The three options that appeared fine were
  simply shorter than the sampling was slow.)


## Pipeline speed

- **L395. A speed improvement claimed from ONE reading per arm cannot be told from noise**, because
  the same code run twice on the same machine routinely differs by more than the effect being
  claimed. Measure the run to run spread of the UNCHANGED code first and record it as a FLOOR
  (two runs prove the noise is at least that wide, never that it is only that wide), then
  require several runs per arm compared at the median to clear it. Distinct from L224, which is
  about comparing against a fixed number, and L316, which is about recording where a figure came
  from: those say where a reading came from, this says how many readings it takes before a
  DIFFERENCE means anything.
  (PostRoll#1257, 2026-09-04: a test suite change was reported as a 10.8% improvement to the CI
  job, 188.99s against 168.67s, from one dispatched run per arm, and the claim shipped in a
  merged commit and a pull request body. Two runs of identical code on the same runner then
  measured 183.4s and 157.5s, a 25.9 second spread, so the gap claimed was inside the noise and
  had to be withdrawn. What survived was the STRUCTURAL half, that the heaviest test class went
  from 55.2s to under 30s, which is arithmetic over per class sums rather than a timing
  comparison and is therefore immune to the noise. PostRoll#1328 and #1329 are the sweep for
  every other figure in that repo taken once)

  The rules that apply while shaping CI, a deploy workflow or a pre-push hook. Same audit as
  "Test speed" above. The recurring shape: the tests took seconds, the wait took minutes, and the
  difference was plumbing.

- **L299. The tests are innocent until measured guilty and the pipeline rarely is, so the first
  move in any speed pass is per-step timing of every stage a push or merge waits on, read off the
  CI API, before a single test is opened.** In every repo audited the suites ran in seconds to a
  minute locally while pull requests waited minutes, and an audit that started from the test code
  would have found almost nothing. When there is no CI, the gate's own guards ARE the pipeline
  and need the same per-step timing.
  (2026-08-29 audit: Bidspoke 9 seconds of tests against a 3.2 minute wait, PET 71 seconds
  against 7 to 9.5 minutes, Slate 15 seconds against 5.5, NurseDex 12 seconds against 8.5.
  PlayedIt could not be timed locally at all and the CI log still told the story: one to eight
  minutes of test bodies inside a 10 to 35 minute job)

- **L300. A gate's own guards are a pipeline and they are never timed because nobody thinks of
  them as tests, so time every stage a push waits on including the ones that guard the guards,
  and put the measurement where the claim about it lives, so the next drift is a diff rather
  than a discovery.** The only number anyone sees is the whole push, and a comment saying the
  self tests take about a second was true the day it was written and wrong by a factor of four
  hundred for weeks (L32, L210). A receive-path run that records a verdict with no duration has
  only a comment beside its timeout to say how long it is.
  (Downbeat#190, 2026-08-29: the pre-push hook runs 45 shell self tests, serially, before the 27
  second suite it exists to run, and they took 402 seconds under that comment. Overture's merge
  script records nothing about its own length, so its 13.6 minutes was reconstructed from the
  API, a build log's timestamp and an xcresult)

- **L301. Look for the same work done twice per event: a suite run by two jobs, an artifact built
  twice per pull request, a merge verified by two workflows, migrations applied by two adjacent
  steps, a target compiled for a runner that never launches it.** In all nine repos the
  redundancy at the pipeline level dwarfed redundancy at the assertion level, and the duplicate
  title sweep came back clean in most of them. `-only-testing` chooses what executes, not what
  builds.
  (2026-08-29 audit: Bidspoke's guard suite ran twice per CI run and every merge was verified by
  ci.yml and deploy.yml at once; Slate's coverage job re-ran the entire suite per PR; NurseDex
  applied 65 migrations in `supabase start` and again in `supabase db reset` the next step, 47
  times a month; PlayedIt compiled and signed a UI test runner for 425 tests the job never ran)

- **L302. Serial steps with no dependency on each other are free wall clock, so split them, but
  only what is independent and only when the split leg is on the critical path, because a split
  buys the shorter leg at the price of a duplicated setup.** Two steps that each need the
  service the job just started are not independent: splitting them starts the service twice. A
  loop of self-sandboxed cases run one after another waits their sum when it could wait their
  maximum.
  (Bidspoke#1063 area, 2026-08-29: worker and web suites back to back in one job, the single
  biggest wall-clock win in the first three audits. NurseDex is the limit: its steps share one
  Supabase, and a split would win 30 seconds on a PR that waits 8 minutes for the other job.
  Downbeat: 45 self tests at 402 seconds summed against about 22 at their maximum)

- **L303. Cache or kill the cold starts (a build cache, a browser download, container images,
  package checkouts), keyed on the thing that invalidates them; a tool invoked through `npx` that
  is not in `package.json` is downloaded on every run at whatever version is latest that day and
  wants a pinned devDependency, not a cache; a cold start that cannot be cached can often be
  started earlier; and a cache that RESTORES on every run is only a log line until a measured
  difference in what gets rebuilt says it saves anything (L3, L98).** The cheapest cache is the
  work not done: exclude the services the suite never reaches rather than cache their images.
  (2026-08-29 audit: NurseDex pulled twelve Docker images cold per run, 115 of a 160 second step,
  seven of them for services nothing in the suite reaches. PET's wrangler and Bidspoke's vercel
  were both npx downloads. PlayedIt booted its simulator after a two to six minute build instead
  of during it. PostRoll restored a DerivedData cache on all 16 recent runs, two exact hits, and
  all 16 recompiled every one of about 527 units, while the 58 copies at 276 MB each evicted the
  caches that did work)

- **L304. A report-only check still gates in practice: if the merge flow waits for every check
  to go green, "report-only" describes the workflow file and not the waiting, so price an
  informational job as if it were a gate, because to the person waiting it is one.** It also
  becomes the critical path silently the moment the real gate gets faster.
  (Slate, 2026-08-29: a coverage job that gates nothing on paper re-ran the whole suite on every
  PR and delayed every merge in fact)

- **L305. Job and check names are load-bearing: workflow files, guard scripts and branch rulesets
  all key on them, and the ruleset is the one a search of the repo cannot find, so a job split
  or rename ships a fan-in job holding the old name plus a pin that its requirements list stays
  complete.** A rename that breaks an automation is a coverage loss wearing a speed win's
  clothes.
  (2026-08-29 audit: Bidspoke's deploy re-asserts `needs.verify.result` by hand inside an
  `always()`; Slate's merge guard reads the check literally named "ci"; NurseDex's required
  checks are named in a branch ruleset)

- **L306. Wall-clock minutes and billed minutes are different budgets, so price every pipeline
  change in both, read the paid currency off the billing system rather than the plan page, and
  read the multiplier off the runner label, because a macOS runner draws ten allowance minutes
  per minute and a self-hosted one draws none.** Which currency bites is a fact about the
  account the repo lives in: an org allowance shared by every repo can be gone by the 7th of the
  month, a personal private repo may pay nothing, and the largest lever on a metered Mac runner
  is the choice of runner rather than any cache or split.
  (2026-08-29 audit: the org's 2,000 free minutes were gone by 7 August and every minute after
  was metered, 16,341 minutes and $82.53 across the org; PlayedIt spent 1,970 of a personal
  2,000 minute allowance in 26 hours on fourteen ordinary macOS runs and the fifteenth was
  refused. Every audit had at least one recommendation declined or reshaped by the paid
  currency)

- **L307. On a free public repository the runner concurrency limit is the budget, so a job is
  priced in the slots it holds times how long it holds them, whoever is waiting, and every job
  launched over the limit delays every other.** Neither currency in L306 is non-zero there and
  the wait can still be the longest of all, because a workflow comment pricing a duplicate job at
  "nothing else" is right about money and wrong about the pool; the queue shows up attributed to
  GitHub rather than to the jobs filling it, and only a minute by minute model of the pool shows
  which job is the cause.
  (PostRoll, 2026-08-29: five concurrent macOS jobs allowed, six launched per pull request and
  ten per merge, median PR wait 18.6 minutes and p90 35; in 524 of the 877 minutes something was
  queued exactly five of its own jobs were running, the post-merge sweep alone holding 48
  percent of the contended slot-minutes)

- **L308. The speed lever you refuse is part of the audit: name in writing the biggest lever you
  deliberately did not pull and what it would change in what is measured or caught, so a future
  speed pass does not "discover" it.** Each repo's largest available lever changed the meaning of
  a check (vitest `isolate:false`, killing animations before accessibility scans, rewriting
  rendered-style checks as text greps, dropping a double check).
  (2026-08-29 audit, one per repo, each recorded under "What was deliberately not proposed")

- **L309. A structural change to how a suite runs (a job split, a worker count, a shard scheme,
  a new reporter) rides on an instrument that already reports the thing the change could break,
  and if no instrument exists, or the existing one only reads the shape of run it has already
  seen, building or re-fitting it is the first issue, ahead of anything it would judge.** A flake
  count nobody publishes cannot judge a worker-count experiment; a baseline gate that cannot
  parse the new log format goes quiet exactly when it is needed.
  (2026-08-29 audit: NurseDex's reporter was html only, so the flake count was made the first
  issue in its milestone. Overture HAD a short-run gate and the parallel experiment changed the
  format under it, so it printed that it could not read the totals while 3,720 tests went
  unexecuted behind a verdict)

- **L310. Every job bills a minimum of one minute, so a tiny always-on job is expensive when its
  isolation is decorative and worth keeping when the isolation does work (it gates something on
  its own, it must be able to fail alone); and a job sitting just OVER the minute is worth the
  same look as one just under it.** Three read-only comparisons as three jobs bill three minutes
  for under 30 seconds of work; a job-level `if` learns "this PR is not Dependabot's" for free
  where a job bills a minute to learn it; a 30 second `npm ci` whose only purpose is to make one
  script runnable tips a 65 second job into a two minute bill.
  (2026-08-29 audit: PET's 5 second lint job burned about 100 minutes a month and folded away;
  Slate's 11 second migration gate bills the same minute and stays because it gates deploys
  alone; NurseDex's Production Smoke bills two minutes 48 times a month)

- **L311. An audit of "PR testing" stops at the PR unless it walks to production, so time the
  path from merge to live as carefully as the path from push to green, because it is the wait a
  person actually sits through after clicking merge, and it may hold the largest serial block in
  the whole pipeline.** The walk can come back with the opposite answer (a deploy gated on
  nothing, so the post-merge runs are signals after the fact, and whether production should ship
  before its sweep finishes is a product decision for its own issue), and that answer has to be
  written down too, or someone optimises the main-push jobs on the belief that they hold the
  deploy.
  (Bidspoke, 2026-08-29: the first pass timed every PR job to the second and never timed Deploy's
  Verify job, 250 serial seconds every deploy waits on. NurseDex: merge-to-live is one minute and
  the 6.5 minute CI run on main gates nothing)

- **L312. Name the consumer of every run before ranking anything, because a run whose only
  reader is a person is priced in that person's minutes and a run with no reader is priced
  entirely in the paid currency; and when the merge tool proves the merged tree is byte for byte
  the pull request's tree (linear history, up to date branch, squash merge, identical tree
  hash), the post-merge re-run is provably redundant and can be skipped fail closed on that
  proof, never on a path or a trigger.** The proof matters: where the two runs prove the branch
  beside two different bases they are not redundant, and one PR has been green on one and red on
  the other.
  (2026-08-29 audit: PostRoll's, NurseDex's and PlayedIt's last six merges each have tree hashes
  identical to their PR heads, 27 macOS runner-minutes a merge re-testing for nobody; Overture's
  PR #2345 is the counterexample, so its answer was to make both runs faster)

- **L313. Every CI job carries an explicit timeout (a hang is worse than a failure: L110, and on
  a metered Mac runner a six hour default costs two months of allowance), and the guard that
  requires it points at the directory and at every repo the class can appear in, not at the one
  file it was written for.** A guard scoped to one file passes forever while the defect it names
  sits next door (L135, L30), and a FIX obeys the same law until the class is swept in the same
  change (L195). Where there is no CI the class lives in the pre-push hook: a self test stuck on
  a machine wide `lsof` hangs the push with nothing printed.
  (2026-08-29 audit: nine for nine. Bidspoke's guard covers ci.yml with a comment explaining why,
  and three sibling workflow files had no timeout on any job; Slate, NurseDex, PlayedIt and
  claude-config had files with none; PostRoll's guard names three of its four files in a tuple)

- **L314. CI that has stopped is the slowest test suite there is and it stops quietly: a refused
  run looks like a failed run in every list, nothing alerts on an exhausted allowance, and a repo
  that goes quiet for a month looks like a repo nobody is working on, so a speed pass begins by
  confirming the tests are running at all, and a repo on a capped or metered runner needs a
  visible surface showing how much of the month is left before the day it is zero (L13, L523).**
  (PlayedIt, 2026-08-29: the allowance ran out on 28 July and every run since was refused before
  its first step; the only trace was a red check on one PR. NurseDex is the same account type one
  step earlier, at 38 percent with no surface showing it)

- **L315. Anything divided into fixed-size pieces under a fixed deadline needs a test holding the
  measured size of the largest piece to a fraction of the deadline (L172, L224) and pieces dealt
  by measured cost rather than by count (L296), because a sweep sized by count grows into its
  own deadline and the red it then produces names the sweep's size as a broken guard (L11).**
  The mirror image is a platform deadline set BELOW the suite's own, so the deadline that exists
  to name the section never gets to speak.
  (PostRoll, 2026-08-29: four shards of about 100 entries under 1,800 seconds, medians at 1,264
  to 1,391 and a p90 near 1,500, four shards red in one week with entries "never reached before
  the deadline, so they are UNPROVEN". claude-config: the job timeout stayed at 20 minutes while
  the suite's own ceiling was raised to an hour)

- **L316. A recorded decision carries the premise it was made on, and the premise can expire
  while the decision stands, so record the premise in a form that can be re-measured (a pin, a
  command, a number with its source) rather than as a dated sentence, because a date on a number
  makes it MORE trusted, not less (L61, L244, L210).** "Do not re-open this on the strength of
  the wall clock alone" was true when the runners had spare slots; a closed issue rejecting a
  lighter scheme on the premise that the build was the cost was never measured before the
  decision and measured months later to save nothing; a design justified by "a Swift suite of
  177s" was three times wrong sixteen days later in the one file that elsewhere refuses to state
  the run time for exactly this reason.
  (2026-08-29 audit: PostRoll#571 priced a duplicate render at "about 200s and nothing else";
  Overture#2487 and its AGENTS.md; claude-config had seven dated numbers all a week stale;
  Downbeat's gate still says two to three minutes in six places against 46 seconds measured)

- **L538. A build left red for a known unrelated reason stops being a signal for everything
  else, because a genuinely new failure then arrives indistinguishable from the standing one in
  every list. Fix or quarantine the standing failure rather than working alongside it, since the
  longer it stands the more changes get merged with nothing actually judging them.**
  (danwright32/claude-config#263, 2026-09-02: test-pipefail-shortcircuit.sh had recorded 318
  short circuiting pipelines against 322 present since 7c16c15, so every run failed. A change
  that day genuinely added two such pipelines to a new file, the suite correctly caught them, and
  in the run list that real failure and the stale one were one line apart and indistinguishable.
  Nearest neighbours are L314, which is CI that has stopped rather than CI that always fails, and
  L179 on a superseded run answering for the wrong revision.)

- **L380. Two build or test invocations that share an output or cache directory share no work
  unless every setting that keys that output also matches, so a differing configuration, flag or
  compilation condition makes the shared path share nothing while still reading as evidence of
  reuse. Measure what actually recompiles rather than concluding reuse from the shared path.**
  The shared path is the part everybody checks, because it is visible in the command line, and
  the keying is the part nobody checks, because it lives in the build settings. Docker build
  args, NODE_ENV on a webpack or Next cache, Gradle and ccache all behave this way. Nearest
  neighbour is L303, which is a declared cache that restores and saves nothing; this one is two
  invocations nobody ever cached, believed to be sharing.
  (PostRoll#1242, 2026-09-03: swift.yml's three xcodebuild calls share -derivedDataPath, and a
  comment plus the docstring of test_every_xcodebuild_in_the_job_shares_one_derived_data_path
  both recorded that the test step therefore reuses the app build. The app build is forced to
  Release with whole module optimisation and the test build resolves to Debug with
  POSTROLL_TESTS set, so they share nothing. Measured on run 33760431737: 0 individual file
  compile tasks in the Release build against 541 in the test step and 235 more for the same 229
  app files in the GUI step, so the app source is compiled three times in one job while the
  shared path read as reuse.)

- **L571. A gate that performs an external network call BEFORE the check it is named for can
  fail without ever running that check, so its red is indistinguishable from the failure it
  exists to report and merging becomes dependent on a third party being up.** Put the network
  step in its own job, or run it after the check. A gate that goes red for a reason unrelated
  to what it measures teaches people to re-run rather than look, which is how a real failure
  arriving during an outage gets re-run past.
  (slate#1868, 2026-09-04: the CI `typecheck` job runs `pnpm audit --prod` against
  registry.npmjs.org before `tsc --noEmit` in the same job. Three consecutive runs failed with
  ERR_SOCKET_TIMEOUT at the audit step, so tsc never executed once, and a merge was blocked
  about twenty minutes for a reason that had nothing to do with the code. Reproduced
  independently from a laptop: curl to the audit endpoint timed out at 25s while everything
  else was fine, then recovered.)

- **L573. Before running a pure check once per item, count the DISTINCT inputs it will
  actually see, because a loop that reads as once per thing is usually mostly repeats. Cache
  on the WHOLE input, never a coarser key, since a coarser one is fast and silently wrong in
  exactly the cases a uniform fixture never contains.** The repeats hide because the loop is
  correct: every call is a real question, and nothing says the answer was already known. The
  coarser key hides for the opposite reason, that it is right on every case anybody thought to
  write down.
  (slate#1846, #1864, #1871, all found in one day in one codebase. The availability grid asked
  the business hours judge once per cached appointment time, 13,538 questions for 396 distinct
  windows, and separately rebuilt each agent's shift window once per hour per day, 17,136 for
  five distinct timezones. The every minute health check still does the first of those on the
  budget four cron lanes share. Both fixes were nearly keyed too loosely: on the HOUR rather
  than the exact start and duration, which admits a slot running past the close, and on the
  ORG's date rather than the agent's own zone and instant, which collapses the boundary where
  one company day falls on two different local weekdays for the same person. Neither is
  reachable from a single zone fixture on an ordinary week.)
