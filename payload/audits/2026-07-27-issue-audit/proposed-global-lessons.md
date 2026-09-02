# Proposed global lessons (full synthesis, 2026-07-27)

Source: 3,506 GitHub issues across nine repos, of which 1,721 carried a lesson.
Personal side: overture 864, playedit 302, nursedex 305, PostRoll 161, downbeat 107
(1,018 lessons of 1,739). Work side: slate 552, project-enrollment-tracker 489,
bidspoke 483, new-agent-onboarding 243 (703 lessons of 1,767). Manager Goal Tracking
has no GitHub repo and is excluded. Full per-repo triage files sit next to this document.

What the work-side data changed: every theme below except L26 and L28 was independently
confirmed by at least two work repos, and the earlier caveat about the accessibility and
query-scale rules resting mostly on playedit's unverified audit is now moot (accessibility
recurs in all four work repos, 26 more issues; query and platform limits recur in all
four, about 45 more). The deploy-verification rule L4 gained its strongest evidence:
production silently serving an old commit under fully green CI, twice. Rules L33 to L39
are new from the work side. One caveat stands: playedit's own 302 issues remain
Claude-audited and human-unverified, but no rule now rests mainly on them.

Each rule is marked NEW (nothing in the current global CLAUDE.md covers it) or SHARPENS
(an existing rule covers the idea but the evidence shows it needs teeth it lacks).
Provenance counts issues per repo, so you can judge how earned each rule is. Rules are
numbered L1 to L32 for review; cut freely. Your existing rules that the audit fully
validated with no change needed (fail loud, assume it runs twice, three-state progress,
consolidate from the start) are not restated here.

## 1. Proof over green

**L1. NEW. A test or guard is only real once it has been seen to fail.** Mocked guards
asserting their own mock's 401, wrappers treating exit 0 as a pass, XCTAssert(true),
skipped preconditions instead of seeded ones, and tests of hand-copied reimplementations
all sat green while protecting nothing. Break the code once and watch the test go red
before trusting it. (nursedex 12, playedit 16, overture 13, PostRoll 3, downbeat 1)

**L2. NEW. Tests must be structurally unable to touch live data, production services, or
paid APIs.** Inject seams for stores, directories, clocks, and external calls, and add a
belt-and-braces refusal inside the service itself. A suite here launched real paid AI
runs on every invocation; another mutated the live store. (overture 3, playedit 3,
downbeat 1, PostRoll 1)

**L3. NEW. Built is not wired, and wired is not proven.** After adding any guard, filter,
integration, or SDK, prove end to end that the call site executes in the shipping
runtime. An analytics init nobody called, a security suite never added to CI, and a
detector wired to the wrong ingest path (silently skipping 37 of 38 sources) all shipped
looking done. Wire the CI gate the same day the first test lands. (overture 9, nursedex
8, playedit 11, PostRoll 3)

**L4. NEW. A merged fix is not a deployed fix.** Verify the change is live in the
environment that ships: the production migration actually applied, the installed build
actually the one just built, the behavior confirmed in a production build rather than the
dev server. A P0 security fix here sat merged but unapplied in production until found by
accident. (nursedex 5, overture 5)

## 2. Data safety

**L5. NEW. Never destroy good state before its replacement is verified to exist.** Write
to a temp file and rename, keep the prior version until the new one is confirmed, defer
physical deletes until undo expires, and never let a blank value beat real data in a
merge. A failed review pass here discarded a completed paid draft. (PostRoll 10,
downbeat 6)

**L6. NEW. A load failure is not corruption.** Distinguish transient read and permission
errors from genuinely bad data; never wipe, reset, or set aside the live file on a decode
failure without a surfaced warning and a verified backup. Two stores here started empty
over real data. (PostRoll 3, downbeat 2, overture 2)

**L7. NEW. User data gets a backup and restore path from day one, and backups rotate.**
A single .bak copied from the possibly-already-bad current file is not a backup. Rehearse
every destructive migration against a copy of the real store, never only against fresh
data; a store relocation that "started fresh" destroyed the only committed booking.
(downbeat 6, PostRoll 3, overture 3)

**L8. NEW. Own your paths.** Never leave data at a framework or OS default location or
name, never share a default resource (clipboard, default store file, one appended log)
between concurrent writers, and put app data in the platform-correct home before writing
the first byte. The default-store habit cost live data twice across two apps. (downbeat
5, PostRoll 4, overture 5)

**L9. NEW. Destructive actions get confirmation, and retention policies are the user's
decision.** Any one-tap action that destroys state needs confirm or undo from the first
build, and an automatic deletion or cleanup policy is a product decision to ask about,
never a default to pick silently. (downbeat 3, nursedex 1, playedit 2, PostRoll 3)

## 3. Honest failure (extends "Fail loud, not silent")

**L10. SHARPENS fail-loud. An error state and an empty state are different screens.**
Rendering "no results yet" or a cheerful empty feed over a network failure hides an
outage behind reassuring copy; a page that cannot show its entity returns real not-found
semantics, not a 200 shell. (playedit 10, nursedex 5, overture 1)

**L11. NEW. Distinct causes get distinct messages, and a message may claim only what its
check actually measured.** Collapsing a TLS failure, a malformed feed, and a dead link
into one sentence sends the user to fix the wrong thing; a fallback or unreadable value
must present as "could not read", never be silently scored as an answer. (overture 18,
downbeat 2, nursedex 1)

**L12. SHARPENS fail-loud. Show success only after the write commits, and report what
verifiably happened, not what was attempted.** No celebration screen over a detached
save; success toasts gate on the write result; "sent" means the external system
confirmed, not that the request was accepted. (playedit 6, downbeat 3, nursedex 1,
overture 2)

**L13. NEW. Background jobs and webhooks alert on failure and on the absence of an
expected run.** Unmonitored scheduled work fails invisibly by default, and a caught error
that never reaches monitoring is invisible twice. Eleven of twelve crons in one repo
notified nobody on error. (nursedex 14, playedit 9, overture 7)

## 4. State and identity

**L14. NEW. Derived state re-derives on every input that feeds it, and every action
updates every surface showing what it changed.** Wiring the recompute to only the trigger
you were thinking about leaves silent staleness on the others, and a correct save that
still shows the old value reads as a failed save. Enumerate the inputs, then the
surfaces. (overture 22, PostRoll 2, playedit 1)

**L15. NEW. Key everything on stable identifiers.** Natural keys built from mutable
strings, display names driving behavior, positional indices in drag payloads, and
fabricated fallbacks (a random UUID when parsing fails) all silently orphan or corrupt
data; when a key must change, record the old-to-new mapping for everything still holding
the old one. (overture 10, downbeat 3, playedit 2, PostRoll 1)

**L16. NEW. A count and the rows it promises come from one shared predicate.** Any badge
number, cross-cutting visibility filter, or shared threshold is one named implementation
every consumer is forced through; a constant that exists in two places is already wrong
in one of them. (overture 9, nursedex 7)

**L17. NEW. Long-running work belongs to an owner that outlives the screen that started
it.** State owned by a view dies with the view (a paid regeneration was silently lost);
values captured when work began are stale at write-back, so re-read the live record.
(PostRoll 5, playedit 1)

## 5. Security and privacy (extends "Security scoping by default")

**L18. SHARPENS security-scoping. Enforce authorization in the database layer, not only
in application code.** Row-level security with WITH CHECK on every self-write policy,
column guards on privilege fields, least-privilege grants. Every app-layer-only check
audited was a live bypass, including self-escalation to admin and a paywall bypass that
exposed PII. (nursedex 16, playedit 11)

**L19. NEW. Secret checks fail closed; secrets and PII never leave their lane.** A guard
comparing against the literal "Bearer undefined" when its secret was unset passed anyone;
compare constant-time, through one shared verifier. Secrets never appear in logs, process
arguments, repos, client binaries, or diagnostic exports; PII is never committed, logged
loosely, or uploaded to a public bucket. (nursedex 6, playedit 6, PostRoll 1, downbeat 1,
overture 8)

## 6. UX completeness

**L20. NEW. Accessibility is part of building each control.** Labels on icon-only
controls, real buttons instead of tap gestures, Dynamic Type, 44 point targets, contrast,
reduced motion, focus management on step change. One audit found 318 fixed-size fonts
because none of it was ever designed in. (playedit 22, nursedex 9, downbeat 1)

**L21. SHARPENS the docs/copy rules. Read every new user-facing sentence cold, rendered,
in the state that produces it.** Copy is a contract: limits, prices, labels, and promised
features must match what the code actually does, and a button labeled as navigation must
never trigger a paid operation. Restated and lying copy is invisible in source and
obvious on screen. (overture 24, nursedex 8, playedit 6, PostRoll 3, downbeat 1)

**L22. NEW. Walk the whole flow as the user before calling it done.** Cancel, Try Again,
resume, and every exit path of a guarded action get deliberate behavior; a cancel must
never discard the whole session, and a confirmation guard that covers Cancel and Esc but
not window close still loses the draft. Enumerate degenerate inputs (zero items, missing
files, overlong media) at design time. (playedit 17, downbeat 8, PostRoll 4, overture 3)

## 7. External systems (extends "Check platform limits")

**L23. NEW. Treat every external response as hostile and every event stream as unordered,
late, and duplicated.** Check status and shape before indexing into a response, map the
other system's vocabulary at the boundary (one guard compared Stripe's "canceled" to a
stored "cancelled" and was dead), and give webhook handlers an event-timestamp ordering
guard. (playedit 9, nursedex 9, PostRoll 4, overture 4, downbeat 2)

**L24. SHARPENS platform-limits. State the expected data volume before writing any query
or loop.** Count on the server, paginate every list, batch instead of per-row round
trips, run independent awaits concurrently, keep heavy work out of render paths, and ship
the index with the query. One directory fetched 500 rows per request to rank in
JavaScript. (playedit 25, nursedex 16, overture 4, PostRoll 1)

**L25. NEW. Pin everything.** Toolchains, dependencies, external API versions, and the
models of AI runs; "latest" is an unannounced breaking change, and an unpinned version
has already broken CI here twice on untouched code. (nursedex 4, playedit 4, PostRoll 2,
overture 1)

**L26. NEW. Twin implementations in two languages consume one shared committed fixture.**
Declare which side is the source of truth and test that side directly; hand-synced
mirrors always drift, and here the declared source of truth was the only untested file.
(PostRoll 6, overture 5)

## 8. Building with AI

**L27. NEW. A rule that lives only in a prompt is a hope.** Every hard constraint on AI
output (banned recipients, banned phrases, required markers) also gets a deterministic
code check at the boundary, and every field a prompt references must provably exist in
the payload sent, or the model fabricates the finding by construction. (overture 10,
PostRoll 4)

**L28. NEW. Treat a detached AI run as an untrusted subprocess.** Pin its model per task,
forbid it from asking questions, enforce its tool limits rather than asserting them,
verify it actually performed the expensive step it was told to, and require an honest
failure record when it dies so a dead run never looks like a quiet success. (overture 12)

## 9. Codebase hygiene

**L29. NEW. Dead code is worse than deleted code.** An unused module with a maintained
44-function test suite derailed real feature planning before a fact-check found nothing
calls it. Wire it or delete it the moment nothing calls it; git remembers. (PostRoll 5,
playedit 5)

**L30. NEW. Fix the class, not the instance.** When a defect is found, sweep for its
siblings in the same change: the same root cause exists everywhere the pattern was
copied, and a cross-cutting behavior (blocking, filtering, a progress fix) must enumerate
every surface it covers before shipping. (overture 10, playedit 6, PostRoll 4, nursedex 2)

**L31. NEW. Everything the product depends on lives in git.** Schema, row-level security
policies, RPC bodies, migrations, scheduled pipelines. An artifact that exists only in a
dashboard has no rollback path and no way to audit what is deployed. (playedit 7,
nursedex 2)

**L32. SHARPENS docs-in-sync. Docs state testable claims.** Any document stating a fact
the code no longer matches (a price, a command, an architecture, a cost premise) is a bug
to fix in the same PR, and measured numbers are generated or omitted, never hand-written.
(nursedex 13, overture 8, playedit 9, downbeat 5, PostRoll 3, slate 7, bidspoke 8,
new-agent-onboarding 3)

## 10. New from the work-side repos

**L33. SHARPENS assume-it-runs-twice. Make the pair of a database write and an external
side effect crash-safe.** Record intent durably before firing the external call, confirm
after, and consume caps or dedup budgets only when the effect verifiably happened; a
crash in the gap must neither lose the side effect nor repeat it, and a must-not-lose
write never rides a best-effort mechanism. (slate 8, bidspoke 10, new-agent-onboarding 3,
overture 2, downbeat 4)

**L34. NEW. Verify domain and vendor data semantics against real samples before building
on them.** A field's meaning (which date is immutable, whether a status ever reports
failure, what a calendar's ownership implies, the real business week) is measured from
captured live data or confirmed with the user, never assumed; a wrong guess here
corrupted rankings, rates, and availability. (project-enrollment-tracker 15, slate 4,
bidspoke 4, new-agent-onboarding 4, downbeat 2)

**L35. NEW. Classify errors once, explicitly.** One shared classifier decides transient
versus permanent and maps every known failure mode to a typed status; never branch on
message substrings, never default an unknown error to retryable, and never flatten
distinct outcomes into one generic code. Misclassification re-fired non-idempotent
partner calls and hid outages inside 409s. (bidspoke 18, slate 5)

**L36. SHARPENS the alerting rule L13. An alert that cries wolf gets ignored.** Design
every alert against its false-positive sources at creation (partial current day, preview
traffic, normal in-flight windows, expected drift), give it a window longer than the
thing it measures, aggregate during broad outages, dedupe repeats, and never embed canned
remediation text that can steer a diagnosis wrong. Also alert on zero work done while a
backlog grows; no error is not the same as worked. (bidspoke 9, slate 5,
project-enrollment-tracker 6)

**L37. NEW. History is stamped at write time.** A record about the past carries the
point-in-time attributes captured then (team, status, structure); rendering or
finalizing a past period must read that period's stored state, never the live present,
or a mid-month change rewrites history. (project-enrollment-tracker 8, slate 2)

**L38. NEW. Deletes, renames, and state exits enumerate every derived resource.** An
operation that must touch N linked things (references, external artifacts, watch
channels, caches, sibling stores) reliably touches N minus 1 unless the full list is
enumerated and covered in the same change; sweep for the dangling one before shipping.
(bidspoke 10, slate 7, downbeat 2, PostRoll 2)

**L39. NEW. One timezone, one date helper.** Compute every business date in one
explicitly chosen zone through one shared helper, never the host clock's UTC default;
render each surface in a declared zone, expand all-day events in the owner's zone, and
test month, DST, and midnight boundaries with a pinned clock.
(project-enrollment-tracker 8, slate 2, overture 2, downbeat 2, bidspoke 1)
