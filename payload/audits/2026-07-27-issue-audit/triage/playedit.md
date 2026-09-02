# Triage: PlayedItApp/playedit

Counts: total 302 / lesson 296 / feature 0 / chore 6 / unclear 0

Context that matters for the cross-project rollup: all 302 issues are OPEN and were filed in a single 13 minute window on 2026-07-02 by a bulk Claude-run production readiness audit (bodies carry "Audit ID: AUD-nnn", structured severity and priority labels). So this repo is not a history of user-reported regressions; it is a one-shot snapshot of everything Claude built without being asked to make production-grade. That makes it unusually pure evidence of default build habits: every family below is something Claude does by default when nobody demands otherwise. Titles were verified against bodies by spot-check (#5, #37, #65) and are trustworthy.

CHORE (6): #290, #291, #293 (verification note, not a defect), #294, #295, #297 (dead test code, stray assets, duplicate test).

## accessibility-not-built-in (22)
#47, #71, #72, #148, #149, #150, #155, #160, #162, #164, #167, #172, #173, #205, #206, #252, #262, #264, #266, #268, #272, #287
Shared lesson: treat VoiceOver labels, Dynamic Type, 44pt tap targets, AA contrast, and Reduce Motion as part of building each control, not a later pass; an audit found 318 fixed-point fonts, 92 unchecked animations, and icon-only controls with no labels because none of it was ever designed in.
Distinct notes: #149 onTapGesture is invisible to VoiceOver (use Button); #252 never encode meaning by color alone; #205 respect Reduce Motion; #206 put an accessibility conformance check in the release process.

## ux-flow-design-gaps (17)
#36, #45, #46, #138, #144, #151, #152, #161, #181, #230, #251, #257, #259, #260, #261, #270, #286
Shared lesson: walk each flow as the user before calling it done, especially Cancel, Try Again, resume, and destructive paths; a cancel must never discard the whole session (#36, #45), a resume must ask before dropping the user mid-task (#181), and destructive one-taps need confirm or undo (#257, #261).
Distinct notes: #138 clearing a search must not leak placeholder state into confirmed data; #260 never gate a user feature behind a hardcoded developer allowlist; #230 an open list view needs a foreground refresh path.

## concurrency-not-idempotent (16)
#13, #14, #99, #100, #102, #104, #105, #106, #108, #115, #117, #118, #132, #224, #231, #234
Shared lesson: assume every tap fires twice and every fetch races a second one; guard buttons with in-flight flags, upsert instead of insert, put uniqueness in the database, coalesce concurrent fetches, and cancel detached tasks on disappear.
Distinct notes: #13 never read a cache off its serial queue; #100 respect actor isolation when reading @MainActor state; #117 debounce during animation delays or a double-tap corrupts the binary search; #118 wire cold-launch routing before the first event can arrive.

## indistinct-progress-no-three-state (16)
#43, #44, #49, #111, #140, #156, #157, #165, #176, #177, #178, #180, #183, #256, #282, #285
Shared lesson: every action that is not instant must show three visibly distinct states (started, still alive, failed with retry); a bare indefinite spinner that looks identical whether the work is progressing, hung, or dead is a defect, and progress bars must actually advance (#43).
Distinct notes: #183 never lock a button on a hidden timer with no feedback; #176 a failed page load must not leave a permanent spinner; #285 loading and failed must not render identically.

## tests-prove-nothing (16)
#58, #59, #60, #61, #62, #63, #65, #170, #175, #190, #191, #192, #193, #296, #298, #299
Shared lesson: a test must call the real production code and be able to fail; never test a hand-copied reimplementation (#59, #62, #65), never write XCTAssert(true) or vacuous negative assertions that pass when the function returns nil (#58, #192), never XCTSkip on a missing precondition instead of seeding it (#60, #61, #175), and never write a tautology that documents a known bug as passing (#170).

## unbounded-queries-n-plus-1 (16)
#22, #26, #28, #29, #30, #31, #32, #33, #34, #124, #126, #127, #130, #131, #242, #263
Shared lesson: before writing any query path, state its row count at scale; count on the server instead of downloading rows (#22, #124), paginate every list (#26, #130, #242), batch instead of per-item round trips (#29, #33, #126, #263), chunk any whole-library request that can exceed a client timeout (#32), and ship indexes with the queries (#34).
Distinct note: #30 client-side aggregation over all rows also computed the percentiles wrong; #127 patch state locally instead of refetching everything on every event.

## silent-swallowed-failure (14)
#16, #52, #76, #91, #137, #141, #145, #146, #147, #153, #163, #179, #254, #271
Shared lesson: every catch on a user-initiated write must surface the failure to the user or rethrow; a swallowed error that leaves the UI unchanged (block, unblock, avatar upload, save, share) is a defect, not defensive coding.
Distinct notes: #91 moderation must fail closed, not open, on edge function error; #76 an edge function must not report success after swallowing its database write error; #137 partial failures must be reported, not silently dropped.

## duplicated-logic-drift (12)
#158, #213, #214, #235, #236, #237, #241, #249, #250, #255, #258, #269
Shared lesson: consolidate before writing the second copy; five duplicated timeAgo implementations (#236), diverging import completion counts (#249), inconsistent UUID casing between writers (#235, #250), and a teardown duplicated in two places that both forgot the same manager (#214) are all the cost of not sharing one implementation from the start.

## server-trusts-client (11)
#2, #3, #4, #9, #10, #11, #12, #73, #80, #85, #210
Shared lesson: before calling any endpoint or RPC done, state who may call it and whose data it can touch, and enforce both server side; never trust a client-supplied user id (#3, #9), never leave privilege columns client-writable (#10), never enforce paywalls, password policy, upload validation, or moderation only in the client (#11, #80, #85, #210), and verify tokens cryptographically before privileged actions (#4). #2 is the flagship: any authenticated caller could push arbitrary notifications to any user.

## privacy-compliance-gaps (11)
#38, #39, #40, #41, #42, #89, #90, #171, #273, #274, #276
Shared lesson: analytics, consent, retention, and store declarations are build-time requirements; do not initialize analytics before consent (#41, #276), do not declare an empty privacy manifest while collecting user data (#42), do not promise features (data export, lifetime purchase) that the code does not implement (#39, #40), and never route sensitive uploads to a public bucket (#38).

## cache-and-image-pipeline-flaws (10)
#23, #24, #25, #119, #123, #220, #232, #233, #244, #245
Shared lesson: a cache needs a real eviction policy, a size cap, in-flight dedup, and code paths that actually use it; arbitrary eviction (#220, #245), resetting the cache key at the top of every fetch (#232), skipping lastFetched on the empty path (#233), and bypassing the cache from one tab (#123) each silently defeat the cache while it looks implemented. Never decode images on the main actor (#25) or block first paint on full-size downloads (#23, #24).

## failure-masked-as-empty-or-wrong-state (10)
#35, #48, #50, #51, #107, #109, #110, #139, #142, #184
Shared lesson: an error state and an empty state are different screens; rendering "no notifications yet" or "your feed is quiet" on a network failure (#109, #110, #139), mapping any error to "not found" or "no connection" (#50, #51, #142), or masking a server error as an empty library (#35) hides real failures behind reassuring copy. #107 errors must surface where the user is, not in a field only visible in another sheet; #184 do not present a fully-successful outcome as an error.

## brittle-external-data-parsing (9)
#75, #77, #103, #135, #136, #212, #229, #239, #247
Shared lesson: treat every external response as hostile; check response.ok before parsing (#212), never force-decode or force-unwrap server data (#239, #247), make joined or optional fields optional so one null row cannot blank a whole list (#229), tolerate missing fields instead of halting pagination (#75), and handle BOM, encodings, and bare CR in file input (#135, #136). #103 date parsing must not require fractional seconds; #77 do not prune device tokens on any 400.

## wrong-data-source-or-fallback (9)
#37, #101, #133, #134, #226, #227, #246, #248, #284
Shared lesson: never substitute a fabricated or wrong-keyed value when the real one is missing; UUID(uuidString:) ?? UUID() files reports against a random id (#227), missing metadata written as 0 and "" destroys null semantics (#248), filtering Steam appids against RAWG ids compares different key spaces (#134), and persisting the full confirmed set instead of the user's reviewed selection resurrects deselected games on resume (#37). Matching needs a confidence threshold, not first-result-wins or empty-string catch-alls (#133, #246); #101 strict less-than keyset pagination drops boundary rows; #284 measure truncation, do not guess by character count.

## docs-stale-or-missing (9)
#54, #187, #189, #207, #288, #289, #292, #301, #302
Shared lesson: keep the repo self-describing as you build; a two-line README (#54), a stale CLAUDE.md architecture doc (#187), undocumented API contracts (#207), and a roadmap living in an inaccessible chat link (#289) all mean the system's truth exists only in past conversations.

## observability-absent (9)
#69, #70, #93, #201, #202, #203, #204, #223, #300
Shared lesson: production code needs error tracking, alerting, structured logs, and health checks from day one; caught errors that never reach monitoring make every silent failure invisible twice (#93), and a diagnostic buffer that does not survive a crash cannot explain one (#204).

## infra-not-version-controlled (7)
#8, #20, #55, #56, #57, #168, #186
Shared lesson: everything the product depends on belongs in git; database schema, RLS policies, and RPC bodies existing only in a dashboard (#8, #57), production source files and the only migration left untracked (#55), a stale outer repo nested around the real one (#56), and an unversioned daily pipeline (#186) mean there is no rollback path (#20) and no way to audit what is actually deployed.

## false-success-premature-celebration (6)
#5, #17, #53, #159, #166, #228
Shared lesson: never show success before the write commits, and always roll back optimistic UI on failure; the worst case shipped a celebration screen and dismissed the view while the only save ran detached, so a failed save was invisible (#5). Success toasts must be gated on the write result (#159, #166), and an optimistic revert must target the state it modified, not whatever replaced it (#228).

## injection-unvalidated-input (6)
#78, #82, #83, #116, #216, #217
Shared lesson: sanitize at every boundary; escape LIKE wildcards in user input (#116, #216), never build admin API filters from raw user email (#83), HTML-encode interpolated values in transactional email (#217), validate shape and bounds on every edge function input (#82), and make allowlists exact-match so a blocked substring cannot ride along (#78).

## misleading-copy (6)
#143, #154, #182, #253, #267, #280
Shared lesson: read every user-facing sentence cold in the state that produces it; "ranked 0 of 0" with a save that saves nothing (#182), "0 games imported and ranked" on a complete screen (#267), raw status codes and response bodies shown to users (#154), and two different labels on one action (#280) are invisible from inside the code and obvious on screen.

## missing-rate-limiting (6)
#6, #7, #81, #86, #87, #88
Shared lesson: any guessable secret or costly endpoint ships with attempt limits and throttles in the same change; a 6 digit reset code with no lockout is brute-forceable by design (#6), and reset-code claim and consume must be atomic (#7).

## no-ci-quality-gates (6)
#67, #68, #94, #188, #199, #200
Shared lesson: tests that exist but never run in CI (#188), no linting or typecheck gate (#67, #199), and an unprotected main branch (#68) mean nothing structurally prevents regressions; wire the gates when the first test is written, not later.

## partial-feature-coverage (6)
#112, #113, #114, #185, #225, #265
Shared lesson: when adding a cross-cutting behavior, enumerate every surface it must cover before shipping; blocking that filters the feed but not friends lists, notifications, or the reverse direction (#112, #113, #114, #225) is the canonical case, as is a capability built for one importer but not its sibling (#265) and DLC handling on search but not rank (#185).

## secret-exposure (6)
#1, #21, #96, #98, #169, #219
Shared lesson: secrets never belong in logs, repos, or client binaries; the audit found a full Supabase refresh token written to exportable diagnostic logs (#1), the service-role key compiled into DEBUG builds that run against production (#21, #96), and the APNs private key sitting in the repo working directory (#169, #219).

## dead-or-unwired-code (5)
#238, #278, #279, #281, #283
Shared lesson: after building a capability, verify it is actually wired end to end; documented push types that are never routed (#238), a formatting pipeline whose output is never rendered (#283), and populated state never used for rendering (#278) all shipped looking done.

## insecure-defaults (5)
#79, #84, #211, #215, #218
Shared lesson: harden the defaults with the feature; revoke sessions on password reset (#79), do not hardcode CORS * on PII endpoints (#84), do not leak internal error messages to clients (#211), pin the Keychain accessibility class (#215), and set nosniff headers (#218).

## missing-test-coverage (5)
#64, #174, #195, #197, #198
Shared lesson: coverage must include the failure and edge paths that matter; edge functions with zero tests (#174), no regression test for a known insert-conflict race (#195), and no tied-rank case for a rank correlation calculator (#197) leave the riskiest logic unguarded.

## production-readiness-ops (5)
#92, #95, #221, #222, #277
Shared lesson: plan for the operational envelope while building; shared retry with backoff for flaky writes (#92), kill switches for risky changes (#95), and a capacity plan for a finite third-party quota that search fan-out multiplies (#222).

## serial-await-latency (5)
#122, #125, #128, #129, #243
Shared lesson: independent awaits run concurrently, not in sequence; a splash screen blocking on five sequential round trips (#122), serial APNs delivery (#243), and an external RAWG lookup inside every rank-save write path (#125) are all latency chosen by default code shape.

## incomplete-deletion-residual-data (4)
#15, #66, #74, #209
Shared lesson: account deletion must enumerate every store the user touched (storage objects, side tables, redemption rows) and must not destroy moderation evidence others filed about the user (#66); derive the deletion list from the schema, not from memory.

## render-path-performance (4)
#27, #120, #121, #240
Shared lesson: keep O(n*m) work and singleton-wide published state out of the render path; computed properties recomputed per render (#27), non-lazy VStacks sorting on every render (#120), and a singleton publishing auth state to the entire view tree (#240) all turn scrolling into recomputation.

## supply-chain-deps (4)
#18, #19, #97, #275
Shared lesson: pin and lock every dependency and scan it; floating Deno imports with no lockfile make deploys non-reproducible (#18) and nothing alerts on vulnerable versions (#19).

## tests-hit-production (3)
#194, #196, #208
Shared lesson: tests never touch shared production infrastructure or mutate shared singletons; integration suites running against the live Supabase are both a data hazard and non-reproducible (#196, #208).
