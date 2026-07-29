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
- **L50. A value parsed from storage or input must never feed a comparison
  directly.** A failed parse yields NaN or an invalid value that compares false
  against every threshold, so the check silently lands on the healthy or
  permissive side with no error ever raised. Parse through one shared helper that
  returns a value or null, and map null to the fail-safe side at each call site.
  (slate#1169, slate#1171)

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

## External systems

- **L23. Treat every external response as hostile and every event stream as unordered,
  late, and duplicated.** Check status and shape before indexing, map the other system's
  vocabulary at the boundary, and give webhook handlers event-timestamp ordering guards.
  (28 issues, 5 repos)
- **L24. State the expected data volume before writing any query or loop.** Count
  server-side, paginate every list (PostgREST caps at 1,000 rows silently), batch N+1s,
  run independent awaits concurrently, keep heavy work out of render paths, ship the
  index with the query. (58 issues, 4 repos)
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
