# Triage: nursedexapp/nursedex

Counts: total 305, lesson 216, feature 70, chore 18, unclear 1.

Context: a Next.js + Supabase + Stripe nurse directory marketplace. Two large systematic audits (the AUD-0xx security and reliability audit around #384 to #429, and a test-coverage audit around #473 to #495) generated most lesson issues, so the lessons here are unusually well diagnosed in the issue bodies themselves. Deep reads confirmed the diagnoses on #384, #385, #391, #408, #412, #414, #417, #419, #421, #424, #426, #428, #444, #515, #518, #354, #616, #634, #649, #651, #665, #691, #705, #227.

## untested-critical-path (32)

Shared lesson: when a money, auth, PII, or abuse-control path ships, its tests ship in the same change; an entire audit sweep found the Stripe webhook, checkout, reveal paywall, rate limit, cron guards, and hire flows all live in production with zero tests.

- #473 Stripe webhook route had zero tests.
- #474 Checkout session creation untested.
- #475 revealNurse payment gating, rate limit, and captcha untested (the core revenue gate).
- #476 Hire claim-token single-use and cooldown untested.
- #477 Ten of twelve cron routes had no tests.
- #478 Email idempotency helper untested.
- #479 Subscription paywall gate untested.
- #480 Review submit-to-publish verification untested.
- #481 Slack webhook signature auth untested at route level.
- #485 No e2e for any core money journey.
- #487 Open-redirect protection untested.
- #488 Gated PII RPC path untested.
- #489 Cron 401 guard only exercised through mocks.
- #490 Reveal rate-limit cap logic untested.
- #491 No replay test for duplicate Stripe webhook delivery.
- #493 Admin actions lacked negative authz tests (non-admin caller).
- #494 Newsletter token routes lacked route-level tests.
- #495 recordFamilyHire eligibility and duplicate guards untested.
- #554 #555 #556 #557 Checkout branches (already-subscribed, missing price id, Stripe API failure, customer reuse) each needed an explicit failure-path test.
- #617 Access-expiry and payment-failure crons lacked 401 tests.
- #622 Date-window math in scheduled email crons untested.
- #633 Six remaining admin actions lacked boundary tests.
- #712 Contact form submit not covered in e2e (Turnstile test keys exist for this).
- #313 Editor React node views untested.
- #283 No round-trip test that post content survives save.
- #269 No smoke tests catching render-time crashes on key pages.
- #177 Authenticated blog author flow had no e2e.
- #162 Slack signature verification had no unit tests.
- #151 Signup duplicate handling untested.

## rls-authorization-not-in-db (16)

Shared lesson: authorization and tenant scoping must be enforced at the database layer (RLS WITH CHECK, column guards, least-privilege grants), never only in the server action; every app-layer-only check here was a live bypass.

- #384 Any authenticated user could self-escalate to super_admin via direct users UPDATE (FOR UPDATE policy with USING only, no WITH CHECK, no column restriction).
- #385 Family could bypass the paywall and exfiltrate nurse contact PII via direct reveals INSERT because subscription checks lived only in the server action.
- #386 Nurse could self-verify and self-grant featured tier via direct UPDATE.
- #388 Anon could INSERT arbitrary rows into public.users (WITH CHECK true plus anon grant).
- #387 GRANT ALL to anon and authenticated is over-broad; grant least privilege explicitly.
- #389 #523 Audit every self-write RLS policy for missing WITH CHECK; one gap means siblings likely share it.
- #512 hires had no WITH CHECK, so parties could tamper with status on their own row.
- #514 A policy must encode the real business relationship (a nurse could self-claim a hire without a real reveal).
- #517 Tighten EXECUTE grants on public functions to least privilege.
- #513 #524 #541 Add CI checks so a future policy or grant cannot regress (WITH CHECK presence, un-guarded self-write policies, grant widening).
- #520 Automated check for tables missing an explicit Data API grant.
- #540 RLS policies need explicit TO role scoping for auditability.
- #381 Gate sensitive identity fields at the DB/RPC layer, not in page code.

## performance-scale-unconsidered (16)

Shared lesson: write the query for the data volume and platform limits it will actually meet (row caps, N+1, serial awaits, unbounded scans, sync deadlines), not for the seed data it was built against.

- #436 Directory fetched 500 rows and ranked, filtered, and paginated in JS per request, uncached.
- #442 Sitemap fetched all nurse profiles unbounded each hour.
- #437 Blog lists selected full body and tsvector for 9-item cards.
- #433 #434 #435 Photo URL signing ran sequentially inside for-await loops (N+1) and repeated per call site.
- #432 Profile RPC ran twice per view with no request-level cache.
- #431 Two auth round trips per navigation (middleware plus Header).
- #430 Header auth lookup forced all public marketing pages dynamic.
- #438 canvas-confetti bundled into every page via a root-layout client component.
- #439 Cron scans had no index on the columns they filter by.
- #440 Crons emailed serially with a per-row dedup query, bounded by maxDuration.
- #441 Per-family query inside a cron loop (N+1).
- #409 Five crons scheduled at the same minute burst service-role DB load.
- #217 Reading time recomputed from the full body every render.
- #168 GitHub API calls sat on the synchronous Slack handler path with its hard response deadline.

## concurrency-not-idempotent (15)

Shared lesson: every multi-step write must assume it runs twice concurrently and be guarded by a database constraint or a status-guarded UPDATE, never by a JS read-then-check; check-then-act raced in every surface it was used.

- #651 hires had no unique constraint, so a double fire created two hires and two emails (neighbouring tables had the constraint; this one was simply missed).
- #653 #691 Concurrent reveal burned two capped daily slots for one nurse and errored on a reveal that worked; the cap consume and the insert were not atomic.
- #419 Hire confirm/reject updated by id only with no status guard in the UPDATE, double-firing the nurse email.
- #652 Admin approve, reject, suspend were unguarded read-then-write, re-sending email on a second apply.
- #417 First-time checkout had no row to check, so two rapid clicks created two active subscriptions and double-billed; fixed with a partial unique index.
- #562 Consulting approval repeated the same race shape as #419.
- #563 #418 Reveal rate-limit counter was a lost-update read-then-bump that could exceed the cap.
- #427 A concurrent duplicate reveal should succeed idempotently, not return a generic error.
- #696 Blog post creation could mint two posts on a repeat.
- #708 Three form inserts needed a per-form idempotency token.
- #663 After finding one race, audit every remaining write path for the same shape.
- #711 Guard the INSERT side of idempotency in CI, not only status updates.
- #165 Slack completion endpoint needed idempotency.

## docs-not-kept-with-code (13)

Shared lesson: runbooks, env references, pricing, legal copy, and architecture docs are part of the feature; write them in the same PR and treat any doc that states a fact the code no longer matches as a bug.

- #496 PRD stated a price the product no longer charges.
- #497 Systems Guide went stale within months and mislabeled what analytics collects.
- #501 e2e README said CI runs no Playwright while a workflow ran the authenticated suite.
- #502 Roadmap doc said a phase was unscheduled after it fully shipped.
- #317 Privacy and Terms still described a retired waitlist.
- #500 Terms omitted auto-renewal and cancellation policy the product enforces.
- #503 #504 #506 #411 Whole ops subsystems (consulting, twelve crons, backups, webhook failure) shipped with no runbook at all.
- #505 No committed env var reference; .env.example omitted five live keys.
- #507 No committed AI-contributor or architecture guide (AGENTS.md was gitignored boilerplate).
- #510 FAQ never covered flows the product actually has.

## guard-or-test-cannot-fail (12)

Shared lesson: a test or CI guard is only real once it has been seen to fail; prove each guard fallible (mutation, seeded data, real implementations) and lint away the pattern of mocking the very thing under test.

- #634 Four cron tests mocked the auth guard and asserted the mock's own 401; stripping the guard failed no test.
- #642 Add a CI job that proves each auth guard test can actually fail.
- #681 #683 Mutation gate never proved the server-action auth guard fallible.
- #644 Guard detection matched guard names inside comments.
- #645 Boundary suite watched a fixed list of side effects, so a new one went unasserted.
- #648 Mutation gate judged a whole test file, letting a hollow test hide behind a sibling.
- #649 A hand-rolled getCurrentUser redirect was invisible to both boundary checks; make the unguardable pattern unwritable instead of detecting it.
- #629 401-guard no-side-effect assertions were vacuous until the DB was seeded.
- #486 e2e redirect tests could pass vacuously.
- #647 Stripe webhook guard test not proven able to fail.
- #698 Make a retry-mode button that cannot actually retry impossible to write.

## duplicated-logic (10)

Shared lesson: the second hand-copied instance of a behavior is the moment to extract the shared implementation; every duplicated pattern here drifted or bloated before it was consolidated.

- #697 Retry pattern hand-copied across components.
- #673 Fourteen near-identical stalled-action strings.
- #549 #484 Supabase query-builder mock duplicated across many tests.
- #618 #630 Cron route-test boilerplate and auth-guard helper copied per route.
- #564 Status-transition guarded-update logic repeated per action.
- #257 Transactional email route handlers duplicated.
- #363 Two subscription-management UIs shared unextracted logic.
- #139 Public header/nav duplicated per page instead of living in the layout.

## accessibility-not-built-in (9)

Shared lesson: semantics, focus management, reduced motion, and assistive-tech affordances are build-time requirements for every new surface, not a retrofit sweep.

- #454 Custom choice groups lacked radio semantics, group labels, and arrow-key navigation across seven components.
- #455 Onboarding wizard never moved focus on step change.
- #462 No global prefers-reduced-motion block; animations always ran.
- #450 Confetti ignored prefers-reduced-motion (and was duplicated).
- #463 Auth pages had no h1.
- #464 Errors rendered in muted gray with no alert semantics.
- #470 Disabled locked options gave no accessible explanation.
- #471 Skeleton primitive not hidden from assistive technology.
- #456 Identity fields across seven forms lacked autocomplete attributes.

## async-feedback-missing (8)

Shared lesson: any action that does not return instantly must visibly distinguish started, still alive, and failed; a button that looks the same while working, hung, or dead is a defect on every surface, not just the one reported.

- #443 App-wide: async buttons never distinguished still-alive from stalled or failed.
- #451 Directory filtering left stale results with no busy or failed signal.
- #452 Inline admin and nurse toggles showed no started state.
- #457 Multi-second photo upload had no progress indication.
- #458 Email token landing pages had no loading state while their action ran.
- #465 Role select had no error handling, stuck loading forever on failure.
- #466 Forgot-password sent page was a dead end with no recovery path.
- #467 Form field errors persisted while the user was fixing them.

## copy-and-brand-inconsistency (8)

Shared lesson: user-facing copy is part of the contract; every sentence must match what the code actually does and the brand's stated style rules, checked by reading the rendered surface, not the source.

- #445 Upload guard accepted 10MB while the error copy promised a 5MB max.
- #447 Profile preview showed the unmasked view and misstated what families see.
- #498 #499 Privacy copy claimed anonymous analytics and DNT support that the analytics config did not implement.
- #459 Same concept named reveal on buttons and unlock in descriptions.
- #460 Empty state said Long Island while the product says New York.
- #461 Rate range rendered with a spaced hyphen connector, violating the brand dash rule.
- #568 Slack alerts shipped with emojis against the style rule.

## silent-failure-swallowed-error (7)

Shared lesson: never discard a returned error; a Supabase write returns error rather than throwing, so an unchecked write plus an HTTP 200 converts an outage into permanent silent data loss.

- #412 Stripe webhook DB writes were unchecked, so a failed write acked 200 and Stripe never retried; a customer could pay and get nothing.
- #616 SLA cron destructured only data, reported queue_clean on a query error, and never alerted admins.
- #444 Google sign-in action did if (error) return, leaving the button on Connecting forever.
- #416 Dunning cron marked the email sent without checking the downgrade write, so a failed downgrade was never retried.
- #422 Newsletter send silently dropped failed batches with no idempotency.
- #344 Checkout actions returned nothing clean when Stripe calls failed.
- #399 Missing env secrets failed silently at runtime with no startup validation.

## observability-alerting-missing (7)

Shared lesson: a scheduled job or webhook that can fail must alert on failure and on absence of a run; unmonitored background work fails invisibly by default.

- #397 Eleven of twelve crons did not notify on error.
- #420 Cron failures returned 500 with no alert, and a missed daily run was never noticed.
- #396 Stripe webhook failures only console.errored.
- #401 Top-level React error boundary never reported to Sentry.
- #407 No health endpoint for external uptime monitoring.
- #400 Sentry traces sampled at 100 percent in production (cost defect from an unreviewed default).
- #425 Flag digest counted all historical flags forever, so the daily admin alert never cleared.

## web-hardening-missing (7)

Shared lesson: public endpoints and pages need their standard protections (CSP, redirect validation, rate limiting, enumeration resistance, PII masking) specified at build time, not discovered by audit.

- #393 No security headers or CSP at all.
- #392 Auth callback next parameter not validated as same-origin.
- #538 CSP style-src left on unsafe-inline.
- #537 No CSP violation reporting to catch future gaps.
- #150 Auth flows leaked email existence inconsistently.
- #222 Newsletter subscribe had no IP rate limit.
- #714 PII masking in session replay unguarded in CI, so a new surface could leak.

## secret-auth-fails-open-or-weak (6)

Shared lesson: secret checks must fail closed when the secret is unset and compare in constant time through one shared verifier that lint enforces everywhere.

- #391 Cron auth compared against Bearer undefined when CRON_SECRET was unset, so any caller sending that literal passed.
- #390 #406 Cron, email, and admin secret comparisons used non-constant-time equality.
- #547 #584 #585 One shared verifier plus a lint rule spanning src/ and scripts/, covering TOKEN and KEY vars, not only SECRET.

## external-event-ordering-assumed (5)

Shared lesson: external webhooks arrive out of order, late, and twice; every handler must carry an event-timestamp ordering guard and tolerate the companion event not having landed yet.

- #414 Last-writer-wins on unordered Stripe events could re-activate a cancelled subscription; fixed with a last_event_at guard.
- #428 Delete handler used .single() and bailed when the create had not landed; fall back to event metadata.
- #423 invoice.paid did not refresh period dates, leaving them stale until another event.
- #426 Checkout success redirected to the celebration before the webhook granted access, so the paywall reappeared right after paying.
- #528 The ordering guard itself had a same-instant race.

## visibility-filter-scattered (5)

Shared lesson: a cross-cutting predicate like "publicly visible nurse" must be one named shared filter that every query path (pages, crons, analytics) is forced through, with enforcement so a new query cannot skip it.

- #320 Add the dedicated visibility flag. #328 Centralize the filter. #324 #331 Crons and analytics were still including hidden and deleted nurses. #621 Enforce via lint that every service-role query applies it.

## side-effect-ordering-unsafe (5)

Shared lesson: order multi-system writes so a mid-way failure leaves a recoverable state (DB first, then storage or external calls, or clean up on failure), and delete across every system the entity touches.

- #429 Photo delete removed the storage object before the DB update.
- #415 Email dedup log was written before the send, so a transient failure lost the email permanently.
- #413 Account deletion did not cancel the Stripe subscription; deleted users kept getting billed.
- #160 Slack thread message orphaned when the consulting insert failed.
- #176 Blog images orphaned on delete and replace.

## ci-not-running-real-check (5)

Shared lesson: a test suite, build step, or guard that exists but is not wired into CI provides zero protection; wire every gate in and verify against the real system, then smoke test production after deploy.

- #482 The RLS security guard suite was not wired into CI.
- #312 Authenticated e2e suite existed but CI never ran it.
- #398 CI had no build step, so build breakage surfaced only at deploy.
- #575 Database-level guards were never executed against a real database in CI.
- #521 No post-deploy smoke test of core flows against production.

## soft-404-http-semantics (5)

Shared lesson: a page that cannot show its entity must return real not-found semantics on every path (hidden entities, streamed routes, redirect chains, transient errors), because a 200 shell page misleads users and search engines alike.

- #323 Hidden or unverified profiles returned HTTP 200.
- #326 Streamed routes turned notFound() into soft 404s.
- #213 Old slug redirected to a target that no longer resolved.
- #291 not-found pages showed the wrong route group's chrome.
- #468 A transient DB error rendered as a misleading 404.

## framework-api-misuse (4)

Shared lesson: know the framework API's actual contract before pairing it with other state; verify the composite behavior rather than assuming the pieces compose.

- #665 Local state added to the component calling useFormStatus destroyed the pending signal, so the signup button never showed pending and allowed double submits.
- #446 global-error used next/link outside a working router and told users to reload with no reload control.
- #566 Copyright year computed in a Server Component render path (frozen at build).
- #280 Base UI DropdownMenuItem onSelect needed a guard against its actual event contract.

## unpinned-toolchain (4)

Shared lesson: pin every toolchain and API version that production or CI depends on and bump deliberately by PR; version latest means the next breaking release lands unannounced.

- #354 Supabase CLI at latest broke every e2e query when v2.106.0 changed a default.
- #408 The same workflow drifted back to latest after the fix, re-arming the identical failure.
- #403 next pinned to a canary prerelease with a caret range in production.
- #340 Stripe API version left unpinned in the server client.

## migration-drift (3)

Shared lesson: a merged migration is not a deployed migration; CI must apply or at least detect drift, because a critical security fix sat merged but unapplied in production until found by accident.

- #518 Migration 043 (the fix for the P0 privilege escalation and paywall bypass) was merged but never pushed to production, discovered only during unrelated work.
- #402 Migrations applied manually with no CI step or drift check.
- #542 Automate the production migration push behind an approval gate.

## integration-not-wired (3)

Shared lesson: after installing an SDK or writing an init function, prove end to end that it actually runs in each runtime; an integration that is never called fails silently forever.

- #227 initPostHog was defined but never called, so every analytics event silently no-oped.
- #394 Sentry was never wired into next.config.ts, so server and edge tracking never initialized.
- #395 Client Sentry config read a server-only env var, so browser capture was disabled.

## verify-in-real-environment (2)

Shared lesson: verify behavior against the environment that ships (a production build, a real browser) before filing or fixing; the dev server and component test DOM both lie.

- #705 Filed as "missing profile renders an empty page" from the dev server; the production build rendered not-found correctly and the issue was closed as wrong.
- #699 Stalled and retry states passed component tests but were never exercised in a real browser.

## dual-source-of-truth (2)

Shared lesson: a value stated in two places will drift; derive it or generate one side from the other.

- #576 Reveal rate limits hardcoded in both constants.ts and the SQL functions.
- #716 Privacy policy Last updated date hand-maintained instead of derived.

## fragile-time-window-math (2)

Shared lesson: schedule logic must use threshold-plus-not-yet-done conditions, never exact-day equality or hardcoded future dates, so a missed run catches up instead of skipping forever.

- #421 Dunning branched on daysPast exactly 1 or 2, so one missed cron run permanently skipped that step.
- #338 Annual coupon math broke for expiry before a hardcoded end-of-2026 date.

## external-api-contract-mismatch (2)

Shared lesson: never compare a value from one system against another system's spelling or event vocabulary; map at the boundary and test the mapping.

- #424 Skip-check compared Stripe's canceled against the app's stored cancelled, so the guard was dead and every call relied on a catch to absorb the error.
- #350 Webhook subscribed to invoice.deleted instead of invoice.paid.

## over-strict-guard (1)

- #515 The role-column hardening trigger had no exemption for the legitimate NULL-to-role onboarding transition; when adding a guard, test the legitimate first-time flow it must still permit.

## destructive-action-unguarded (1)

- #453 Destructive actions across four surfaces executed with no confirmation; destructive mutations require confirmation (and ideally undo) from the first build.

## misc-one-off (1)

- #258 Floated article images could fail to clear following content; verify rich-content CSS against real long-form documents, not fixture snippets.

## FEATURE (70)

715, 695, 692, 675, 674, 671, 670, 669, 659, 658, 657, 656, 655, 654, 472, 469, 449, 448, 383, 374, 373, 365, 364, 358, 356, 355, 351, 345, 341, 274, 271, 249, 248, 243, 239, 238, 235, 233, 232, 228, 226, 221, 214, 208, 204, 203, 202, 201, 200, 199, 198, 197, 196, 195, 194, 193, 192, 191, 190, 189, 188, 187, 186, 185, 179, 178, 175, 170, 169, 137

## CHORE (18)

623, 509, 508, 492, 483, 410, 405, 404, 382, 379, 369, 339, 284, 209, 166, 161, 152, 140

## UNCLEAR (1)

709 (open domain-model question: can a consulting request have more than one billable session; a decision record, not a defect)
