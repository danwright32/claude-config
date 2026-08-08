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

## Data safety

- **L5. Never destroy good state before its replacement is verified to exist.** Write to
  temp and rename, keep the prior version until the new one is confirmed, defer physical
  deletes until undo expires, and never let a blank value beat real data in a merge.
  (16 issues, 2 repos)
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

## State and identity

- **L14. Derived state re-derives on every input that feeds it, and every action updates
  every surface showing what it changed.** Enumerate the inputs, then the surfaces; a
  correct save that still shows the old value reads as a failed save. (25 issues, 3 repos)
- **L15. Key everything on stable identifiers.** Never mutable strings, display names,
  positional indices, or fabricated fallbacks; when a key must change, record the
  old-to-new mapping for everything still holding the old one. (16 issues, 4 repos)
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
## UX completeness

- **L20. Accessibility is part of building each control.** Labels on icon-only controls,
  real buttons instead of tap gestures, type scaling, tap targets, AA contrast in both
  themes, reduced motion, focus management. (49 issues, 7 repos)
- **L21. Read every new user-facing sentence cold, rendered, in the state that produces
  it.** Copy is a contract: limits, prices, labels, and promises must match what the
  code does, and a control labeled as navigation must never trigger a paid operation.
  (42 issues, 5 repos)
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
- **L25. Pin everything.** Toolchains, dependencies, external API versions, AI models;
  "latest" is an unannounced breaking change. (11 issues, 4 repos)
- **L26. Twin implementations in two languages consume one shared committed fixture**,
  with a declared source of truth that is itself directly tested. (11 issues, 2 repos)

## Building with AI

- **L27. A rule that lives only in a prompt is a hope.** Every hard constraint on AI
  output also gets a deterministic code check at the boundary, and every field a prompt
  references must provably exist in the payload sent, or the model fabricates it.
  (14 issues, 2 repos)
- **L28. Treat a detached AI run as an untrusted subprocess.** Pin its model per task,
  forbid it from asking questions, enforce its tool limits rather than asserting them,
  verify it did the expensive step, and require an honest failure record when it dies.
  (12 issues, 1 repo)

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
