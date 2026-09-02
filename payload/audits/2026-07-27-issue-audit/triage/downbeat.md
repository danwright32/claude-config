# Triage: danwright32/downbeat

Counts: total 107, lesson 88, feature 10, chore 9, unclear 0.

Note on this repo: issues 58 to 131 came from a systematic audit sweep, so titles are unusually precise and most classification was possible from titles alone. Deep reads were done on 7, 6, and 125 (the data-loss postmortem). Issues 7 and 6 are each a bundle of several distinct traps; they are filed under their dominant family with the bundle noted.

## silent-failure-swallowed-error (11 issues)

Shared lesson: every error path, decode failure, skipped step, or unresolved value must surface loudly (throw, log durably, or show the user), never default to a blank result, a silent skip, or fake success.

- #90: A decode failure must never silently substitute defaults and then overwrite the real stored data on the next save; fail loud and preserve the original blob.
- #80: A violated ordering contract must abort with a visible error, not silently skip every launch migration behind it.
- #78: Never swallow persistence save errors with try?; a failed save on a delete or autosave path must be surfaced.
- #62: A malformed callback from an external script must produce an immediate visible error, not be dropped so the operation hangs until a long timeout.
- #81: Failures in a multi-step commit need a durable log, not only a transient truncated in-view message.
- #14: A one-tap UI action (skipping a task) must never silently and permanently destroy downstream state; destructive consequences need visibility and reversibility.
- #105: A malformed deep link must produce feedback, not be silently ignored.
- #106: An action that finds nothing to act on must say so, not complete as a silent no-op.
- #119: A rendered template with a blank settings-backed token must flag the blank, not ship empty output.
- #123: Rendering must warn when output still contains an unresolved token instead of shipping it.
- #131: A token that always renders empty must be wired up or removed; never leave a placeholder that silently produces nothing.

## non-idempotent-retry-or-reentry (8 issues)

Shared lesson: design every multi-step side-effecting operation (external app calls plus a database save) assuming it will be retried, re-entered, double-clicked, or crash midway; persist progress markers and make each step idempotent.

- #11: Retry after a failed commit phase must not re-fire side effects already performed.
- #12: A commit step must be locked against exit and re-entry mid-run; re-entry must not auto-fire a duplicate commit.
- #63: Retry after an external-app timeout or lost callback must not re-run the whole script; record what was created before retrying.
- #67: Persist a marker between firing external side effects and saving, so a quit or crash in the gap cannot cause re-entry to duplicate everything.
- #68: A failure midway through an event list must record which events already fired so retry resumes, not re-fires.
- #69: When an external script errors after partial creation, keep the created IDs; discarding them guarantees duplicates on retry.
- #89: A deep link arriving during an active operation must be queued or refused, not allowed to start a second concurrent orchestrator.
- #118: Primary action buttons must be disabled or debounced on first activation so a double click cannot double-advance or double-commit.

## untested-critical-path (8 issues)

Shared lesson: the highest-risk behaviors (migrations, dedupe contracts, error branches, boundary conditions) need behavioral tests at build time, not after an audit finds the gap.

- #10: Close coverage gaps as part of the feature, not as a later audit follow-up.
- #20: Async continuation lifecycle code needs direct tests, not incidental coverage.
- #84: A dedupe-then-restore contract needs a regression test the day it is written.
- #85: Launch migrations, sweeps, and rollback paths need behavioral tests, not just the happy path.
- #101: A silent behavioral fallback (no defer date disables the cutoff) must be frozen by a test or it is an accident waiting to change.
- #102: Empty-group and nil-condition boundaries of an evaluator must be tested explicitly.
- #103: Every branch of an input normalizer (not just the common case) needs a test.
- #122: Every declared template token must have a test proving the renderer resolves it.

## migration-replay-fragility (6 issues)

Shared lesson: treat launch migrations and store moves as destructive operations: verify against a copy of the real store first, make them atomic, enforce ordering explicitly, and never relocate a store without migrating the data.

- #125: Never relocate a data store "starting fresh" without migrating existing rows, and never leave stored data with no UI surface where its disappearance would be noticed; this destroyed the only committed booking invisibly for five days.
- #7: Replay and reseed paths must be built for re-execution: reseeding must reset migration flags, dedupe keys must not collide across parents, and hard-coded scrub deletes need a run-once flag.
- #15: A migration chain gated on flags must be verified to actually run in the first session after a fresh import, not just on subsequent launches.
- #39: Migration ordering must be an enforced contract with a check, not an implicit convention.
- #48: Verify a lightweight schema migration against the live on-disk store before shipping it, not only against a fresh store.
- #65: A migration that throws must roll back its partial writes; otherwise a later unrelated save flushes half-applied state.

## missing-input-validation (6 issues)

Shared lesson: validate and enforce uniqueness, character safety, and non-emptiness at the point of entry, before any value can crash a renderer, corrupt a path, or make lookups nondeterministic.

- #2: Validate the whole booking before any commit side effects run, not after.
- #5: Sanitize path-illegal and URL-structural characters in user-entered names before they reach the filesystem or URLs.
- #13: Enforce name uniqueness at creation; a name-keyed lookup that can see duplicates is a crash waiting to happen.
- #77: Duplicate names across calendar events, templates, and genres double-fire events; uniqueness is a data rule, not a UI nicety.
- #92: Editors must reject empty flag names and empty rule groups instead of persisting rules that silently hide or show tasks.
- #124: Expand or reject a leading tilde in a configured path; never pass it through literally.

## duplicate-implementation-drift (5 issues)

Shared lesson: one behavior gets one implementation; a second copy (a second token syntax, a second email regex, a duplicated literal or date computation) will silently drift from the first.

- #3: Compute a date once and share it; note text and actual task dates drifted because each derived the date separately.
- #21: A sentinel literal shared between Swift and an embedded script must live in one source both sides read.
- #49: The same migration must not carry three different names across code, flags, and docs.
- #72: Email validity must be one shared rule, not three divergent ones across client selection, prompt, and form.
- #95: Folder-name rendering must reuse the one token-substitution engine, not reimplement it with a second syntax and duplicated date formatting.

## stale-docs-mislead (5 issues)

Shared lesson: when a change removes or reshapes a feature, contract, or process, update every document that states it in the same change; measured numbers in docs go stale and should be generated or omitted.

- #98: A PRD must not keep specifying a removed window and success criteria based on it.
- #112: Do not hand-write test counts into docs; they go stale immediately.
- #113: A wire-format doc must be updated in the same change that ships the new version.
- #114: Do not document an integration handoff that is not actually configured anywhere.
- #115: A doc describing a retired routine must say it is archival, not read as active.

## shared-default-resource-collision (5 issues)

Shared lesson: never rely on an OS-default or machine-shared resource (default store path, clipboard, a single build toolchain); give every store an explicit owned path and serialize or isolate shared channels. This family produced the cross-app store collision that also hit Overture.

- #4: A clipboard handoff to another app is a shared mutable channel; it races and clobbers user data, so use a dedicated channel.
- #50: Tests must run against a disposable store, never the host app's live one.
- #116: Concurrent xcodebuild runs across projects on one machine need a shared lock.
- #120: Give the data store an explicit app-owned file path instead of the OS default.
- #129: Guard the store against a foreign file at its path and never use the framework's default filename.

## ui-feedback-missing (4 issues)

Shared lesson: every long or blocked operation must show distinct working, stalled, and failed states, and every disabled or mislabeled control must say why; a bare indefinite spinner or a lying button label is a defect.

- #61: A wait of up to 180 seconds must show elapsed progress and a timeout state, never a bare indefinite spinner (this is the origin of the global progress rule).
- #73: A button labeled Retry must retry; and overlapping buttons on the failure screen make the recovery path ambiguous.
- #74: A disabled Continue must state its reason, and its tooltip must not keep advertising a shortcut that will not work.
- #75: Keyboard navigation must scroll the highlighted row into view; selection the user cannot see is no feedback.

## incomplete-guard-or-stale-state (4 issues)

Shared lesson: a guard or reset must cover every path (all exit routes, all fields, all sessions), and editors must not stamp defaults or persist half-chosen state behind the user's back.

- #1: Discard must reset the entire draft, not just one field; partial resets leak stale state into the next booking.
- #6: Editor bundle: key equivalents must not shadow standard text editing, derived dates must recompute when their input changes, an "Add" control must not stamp a default (9 AM) that silently overrides encoded anchors, and adding a condition must not persist before the user picks one.
- #26: A one-time scrub gate with a residual window is not closed; close the window, do not shrink it.
- #87: Guarding Cancel and Esc but not window close still discards a draft silently; enumerate every exit path when adding a confirmation guard.

## data-loss-exposure-unguarded (3 issues)

Shared lesson: user data needs a backup path from day one, destructive operations need real confirmation, and automatic deletion policies are product decisions, not defaults Claude picks.

- #64: Never ship a store holding irreplaceable user data with no backup, export, or restore path.
- #66: An automatic sweep that deletes committed records one day after the event is a retention policy; ask the user before building it.
- #79: A wizard that purges all user data on re-run must have an explicit confirmation, not a single flag as its only guard.

## false-success-reporting (3 issues)

Shared lesson: report what actually happened, verified, not what was attempted; acceptance of a request is not completion, and a gate that checks a proxy gives false assurance.

- #70: Do not report events as sent because the URL was accepted; verify the external app actually created them.
- #96: A pre-push gate that checks test presence but never runs the suite lets red pushes look guarded.
- #104: A success screen must report the count of events actually fired, not the raw template count.

## ui-overflow-scaling (3 issues)

Shared lesson: lay out for the small window and the growing dataset from the start; fixed-size controls and unscrollable sheets break as content scales.

- #108: A segmented control for a user-extendable list will crowd and truncate; pick a control that scales.
- #109: A sheet whose content can expand needs a scroll fallback so the footer cannot be pushed off short displays.
- #127: Duplicating a row must not resize the whole window; content changes should not drive window geometry.

## env-dependent-or-flaky-tests (3 issues)

Shared lesson: tests must not depend on a specific machine's folders or on wall-clock timing windows; isolate disk-dependent tests from the default run.

- #83: A test that hardcodes one machine's folder path fails everywhere else; use fixtures or temp dirs.
- #97: Disk and fixture dependent importer tests belong in a quarantined target, not the default run.
- #100: Lifecycle tests built on 50ms wall-clock windows are flaky by construction; use injected clocks or deterministic signals.

## referential-integrity-on-delete (2 issues)

Shared lesson: deleting an entity must handle every reference to it; a dangling reference that silently changes behavior (or resolves to a random id) is data corruption.

- #76: Deleting a genre still referenced by a draft must not silently drop the genre level from the rendered folder path.
- #91: A visibility rule referencing a deleted client must be cleaned up or flagged, not left to default to a random non-matching id.

## unverified-external-assumption (2 issues)

Shared lesson: verify an external API surface or a real-world default against the live system or the user before building on it; a guess baked into code is a latent defect.

- #60: An embedded automation script's API surface must be verified against the live target app before first real use.
- #82: A default enum value that encodes a business assumption (contract intake state) must be confirmed with the user, not guessed.

## time-and-locale-assumptions (2 issues)

Shared lesson: date and time code must handle boundary cases (cross-midnight ranges) and pin locale explicitly; system settings must not change rendered output.

- #59: An end-time picker must support ending after midnight; silently snapping to start plus 2 hours corrupts real shoots.
- #94: Human-readable formatters need an explicit locale or their output shifts with system settings.

## display-string-as-identifier (1 issue)

- #86: Never key behavior off an exact display name (clientIsDCINY matching a rendered string); use stable identifiers, and test the coupling so a rename cannot silently drop tasks.

## draft-mutates-live-record (1 issue)

- #71: Draft-screen edits must write to the draft, not directly to the saved record on every keystroke; otherwise a discarded booking still mutates the roster.

## derived-name-collision (1 issue)

- #88: A filesystem name derived from user data is not unique; detect collisions instead of letting two bookings silently share one folder.

## hardcoded-instead-of-derived (1 issue)

- #130: Do not hardcode values (genre, year) in a destination path that the booking already carries; derive them.

## pii-committed-to-repo (1 issue)

- #99: Never commit real client PII (research dumps) to the repo; scrub before commit, not before a later visibility change.

## accessibility-omitted (1 issue)

- #93: Icon-only buttons need accessibility labels at creation time, not in a later accessibility pass.

## unbatched-side-effect (1 issue)

- #110: A save observer that rewrites a full export file must be debounced; a migration-heavy launch should not write the same file dozens of times.

## copy-render-artifact (1 issue)

- #107: UI copy authored in markdown must be rendered or stripped; literal backticks must never reach the screen.

## FEATURE (10 issues)

9, 29, 51, 52, 53, 56, 117, 121, 126, 128 (enhancements, export bridge work, product decisions to add capability; #121 backup automation is the feature side of lesson #64).

## CHORE (9 issues)

8, 25, 30, 44, 47, 54, 55, 58, 111 (cleanup sweeps, dead code and flags, doc authoring, lint, test target split, refactor to a migration registry).

## UNCLEAR (0 issues)

None; the audit-sweep titles were specific enough to classify everything.
