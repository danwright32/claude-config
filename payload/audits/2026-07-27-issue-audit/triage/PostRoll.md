# PostRoll issue triage (danwright32/PostRoll)

Counts: total 161, lesson 115, feature 39, chore 7, unclear 0.

Feature issues (not itemized below): 36, 39, 47, 52, 53, 57, 59, 61, 62, 66, 67, 70, 71, 144, 160, 161, 164, 166, 171, 172, plus plan and phase records 129 to 136, 139 to 143, 148 to 153.
Chore issues: 33 (add UI smoke test), 34 (data dir override for tests), 84 (write a README), 114 (add pytest config), 120 (gitignore Xcode user state), 126 (remove debug prints), 170 (gitignore scratch files).

Deep reads performed: 18, 19, 20, 29, 31, 35, 45, 55, 64, 75, 83, 85, 94, 99, 105, 137, 167, plus title and label analysis for the rest (titles in this repo are audit-written and unusually specific).

## external-file-not-copied-into-storage (6)

Shared lesson: any file arriving from a picker, drag-drop, or upload must be copied into app-owned storage synchronously at intake; a raw external, temp, or provider URL is a dangling reference. This regressed repeatedly after the rule was first established, so new intake call sites need an audit habit or a shared intake helper that makes the wrong path unwritable.

- 7: Copy dropped photos out of provider temp URLs before the provider reclaims them.
- 8: Store uploaded reel audio in app storage, not the upload temp directory.
- 43: Same rule for reel audio uploads that were still referencing the temp path.
- 77: Regression, review-screen pickers and Finder drag-drop bypassed the copy rule; route all intake through one helper.
- 145: changeBWPhoto stored a raw NSOpenPanel URL; every NSOpenPanel result must go through the copy-in step.
- 146: After two regressions, audit every remaining NSOpenPanel call site instead of fixing them one at a time.

## cross-language-parity-drift (6)

Shared lesson: when the same logic exists in two languages (Swift preview vs Python export), pin them to one shared golden fixture from day one; hand-synced twin implementations will drift and the user sees one thing in the editor and ships another.

- 21: ffmpeg command construction and crop bias parity needed tests before they drifted.
- 44: SwiftUI collage editor and Python CollageRenderer needed a parity audit.
- 104: Two hand-synced CAPTIONS.txt writers (Swift and Python) with no shared fixture will drift.
- 107: The file declared as source of truth (posting_preset.py) had zero direct tests; only its mirror was pinned. Test the source of truth itself.
- 124: Parity pins exist on both sides but the numeric vectors are duplicated; share the fixture data, not just the assertions.
- 168: Guarantee export matches preview with one crop-geometry fixture consumed by both languages.

## silent-failure-swallowed-error (5)

Shared lesson: an error path that swallows the failure and presents success or emptiness is a defect; every catch, optional-try, and status code must surface loudly.

- 4: A missing API key must fail loudly at the vision call, not produce degraded output.
- 17: Python subprocess failures were invisible; read and surface the log tail on failure.
- 79: Export used try? on asset copies, silently shipping incomplete export folders.
- 92: Generate All silently discarded per-item generation failures.
- 112: KeychainStore ignored the SecItem status, so a failed key save looked successful.

## clobber-before-confirm (5)

Shared lesson: never destroy or overwrite the current good state until the replacement is verified to exist; delete-then-create and clear-then-fetch orderings turn any failure into data loss.

- 5: Enrichment overwrote populated OCR fields with empty values; merge must never let blank beat data.
- 20: A failed review pass discarded the completed paid draft; keep the prior draft and retry transient API errors.
- 78: Undo restored the event record but its media had already been deleted; defer physical deletes until undo expires.
- 80: OCR confirm deleted the page scans without verifying the baked PDF actually existed.
- 118: Swapping audio cleared the uploaded path before the replacement fetch succeeded.

## view-lifecycle-state-loss (5)

Shared lesson: long-running work and its results must be owned by a model object that outlives the view; SwiftUI @State dies on remount and a value captured at task start is stale by write-back time.

- 3: Persist OCR review edits as they are made, not only at a final confirm.
- 9: Read the live event at write-back after a long generation run; the captured copy is stale.
- 41: Audit all views for long-running tasks owned by view @State after the first instance was found.
- 76: Regenerate All results lived in @State and died with the view, so the paid run was silently lost.
- 103: PhotoAssignmentView wrote back the captured event prop instead of reading live AppState.

## naive-text-parsing (5)

Shared lesson: never manipulate structured or natural text with bare string matching; use a real parser, anchor-aware matching, and test the inputs that contain the delimiter characters.

- 1: CSV import failed on naive ISO dates; parse dates with a tolerant, tested parser.
- 13: HEIC filenames were mangled by blog PHOTO marker string handling.
- 28: _fix_wrong_names blind-replaced substrings and corrupted venue and place names.
- 109: Backstops spliced with str.replace after .strip(), so indented or duplicated paragraphs were silently never fixed.
- 121: The JSON brace matcher ignored string contents, so prose containing a stray brace mis-parses the payload.

## duplicated-logic-drift (5)

Shared lesson: two implementations of the same job diverge silently, and the unsafe copy bypasses every guarantee the hardened one added; consolidate to one implementation at creation time, not as later cleanup.

- 38: Per-photo remove had its own path instead of routing through PostingDay.removingPhotos.
- 83: The Makefile rebuilt install without the codesign and xattr steps build-install.sh added specifically to stop TCC prompt storms; the discoverable path reintroduced the fixed bug.
- 138: PythonBridge grew two independent manifest-builder functions.
- 162: Brand design tokens were re-declared per media generator instead of shared.
- 165: The org equals event-name collapse logic existed in multiple places.

## dead-code-misleads (5)

Shared lesson: unused code with live tests is worse than deleted code; it costs review time and actively misleads planning (a feature plan was scoped around export.py before a fact-check found nothing calls it). Wire it up or delete it the moment it stops being called.

- 22: Batch week caption path was unwired; wire or delete.
- 26: Music picker bridge code was unused.
- 49: In-app DataMigration code outlived the migration.
- 125: An empty scripts/ directory pointed at entry points that actually live under postroll/.
- 137: export.py plus its 44-function test suite was never invoked by the app and derailed a plan draft.

## concurrency-unguarded (4)

Shared lesson: assume every operation can run twice; guard auto-started work with an in-flight check, block conflicting actions while a run is live, and never share an append target between concurrent writers.

- 64: Rapid re-open raced the candidate render and orphaned a temp directory; track or reuse the in-flight render.
- 75: Preview generation auto-started on every remount with no in-flight guard, spawning duplicate Python runs writing the same files.
- 89: Approve and Export was not blocked while a regeneration was still writing the assets being exported.
- 90: Concurrent subprocesses shared one log file with truncate-then-append, corrupting the error tail shown on failure.

## external-call-response-unguarded (4)

Shared lesson: every external call (API, subprocess, network) can fail or return an unexpected shape; check status codes and response structure before indexing into results, and map failures to typed errors instead of raw tracebacks.

- 30: Detect truncated Claude responses via stop_reason instead of trusting the text.
- 93: Jamendo search had no network error handling; an outage crashed auto-fetch with a raw traceback.
- 122: message.content[0].text was read unguarded; a non-text first block raised AttributeError instead of a typed ClaudeError.
- 123: ffprobe output was parsed without checking returncode, crashing on probe failure.

## unhandled-edge-case (4)

Shared lesson: enumerate the degenerate inputs (fewer items than expected, cancel pressed, missing files, overlong media) at design time and give each a deliberate behavior; the happy path alone is not the feature.

- 10: Screen reel duration was uncapped in the closing frame encode path.
- 16: Cancel in photo picker and export dialogs was mishandled.
- 51: Missing audio files were not flagged and handled the way missing photos already were; matching failure classes deserve matching handling.
- 63: Days with fewer photos than the preset count broke changeCollagePhotos.

## data-root-misplacement (4)

Shared lesson: choose the platform-correct data home (Application Support) before writing the first byte; app data inside TCC-protected user folders causes permission prompt storms, and every stray cache or log outside the one data root becomes unmanaged.

- 42: App data in ~/Documents caused repeated TCC prompts; move to Application Support.
- 46: brand-voice.md left in the Documents checkout kept triggering generation-time TCC prompts.
- 56: Generation logs were written into the Documents checkout instead of the data root.
- 111: Jamendo audio cache lived in ~/.postroll outside the data root and was never pruned.

## destructive-recovery-on-decode-failure (3)

Shared lesson: a load failure is not proof of corruption; distinguish transient read and permission errors from bad data, and never wipe or set aside the live file without a surfaced warning and a verified backup.

- 2: events.json was silently wiped on decode failure.
- 74: EventStore.load misclassified transient errors as corruption, set the real file aside, and started empty.
- 88: AnalyticsStore wiped all imported history on decode failure with no UI surfacing and no backup.

## destructive-cleanup-without-safeguards (3)

Shared lesson: automatic cleanup that mutates or deletes on launch needs a dry-run, an audit trail, and defensive handling of records that predate its own fields; a missing timestamp must never mean eligible for deletion.

- 32: Archive cleanup deleted a live duplicated event's preview folder.
- 35: Events exported before archivedAt existed fell back to shoot date and could be swept on first launch after updating.
- 108: ArchiveCleanup ran at load and persisted mutations with no dry-run or audit trail.

## no-liveness-signal (3)

Shared lesson: any multi-minute operation must show started, still alive (elapsed time or per-step heartbeat), and failed as visibly distinct states; a static spinner identical when progressing, hung, or dead is a defect.

- 40: Background runs were invisible from the sidebar.
- 95: Multi-minute Claude and ffmpeg operations showed static spinners with no elapsed time.
- 96: Multi-pass blog generation fired up to ten sequential calls silently, so alive and hung were indistinguishable.

## missing-ci-enforcement (3)

Shared lesson: a test suite or style rule that nothing runs before ship is decoration; wire the gate (CI or a mandatory local step) the same day the first test lands, and gate the install path, not just the push path.

- 82: CI never built or ran Swift tests, so every data-safety suite was unenforced.
- 98: Nothing ran the Swift tests before installing a build; Makefile and build-install.sh went straight from compile to /Applications.
- 113: No lint or typecheck existed anywhere for the Python pipeline.

## fragile-or-false-green-tests (3)

Shared lesson: a green run only counts if the tests actually executed against fresh code; silent skips, stale module links, and shared global state all produce convincing false greens.

- 45: @testable import in a self-contained test bundle silently linked a stale module, producing misleading missing-member errors.
- 106: ffmpeg end-to-end tests almost certainly skip silently in CI with no install step and no skip-count guard; count skips and fail on unexpected ones.
- 116: Tests mutated the real UserDefaults.standard, leaking state across tests.

## inadequate-backup-strategy (3)

Shared lesson: one .bak copied from the possibly-already-bad current file is not a backup; rotate generations, back up before risky writes, and document the restore procedure while designing the store.

- 25: Rotate events.json backups on save instead of keeping one.
- 97: No documented backup or restore procedure existed and media was never backed up.
- 102: The single .bak generation was copied from the current file on every save, so a bad save destroyed the only backup.

## incomplete-migration (3)

Shared lesson: a data-location move is not done until every derived artifact, leftover file, and user-facing path reference has moved with it; sweep messages, docs, and the old location as part of the same change.

- 48: Previews went missing after migration with no detection or regeneration.
- 94: Live client data and stale duplicates stayed in the git checkout after the data root moved.
- 101: Error and recovery messages still pointed users at the old ~/Documents/PostRoll/logs path.

## docs-contradict-implementation (3)

Shared lesson: treat the PRD and docstrings as testable claims; when the implementation changes approach (or never matched), reconcile the docs in the same change, especially claims about cost.

- 58: A stale 10-photo comment survived the adaptive generator.
- 85: The PRD's core premise (zero API cost via Claude Code CLI) was false in the shipped app, which defaults to the metered SDK; cost claims must be verified against the real call path.
- 115: The PRD claimed Tesseract for OCR; the implementation uses Claude Vision plus sips.

## visual-output-unverified (3)

Shared lesson: rendered media needs pixel-level reference checks (contrast of a mark over both dark and bright frames, no black bands); code that renders without error can still look broken, and only a reference-frame test catches it. Fixing one surface must trigger a sweep of sibling surfaces with the same construction.

- 27: Short collage strips showed a black band in scroll reels; pad deliberately.
- 163: Templates that render but look broken needed reference-frame checks.
- 169: The white wordmark washes out on bright footage, the same class of bug already fixed on the Thursday reel but not swept to Tuesday.

## ui-promise-vs-behavior (3)

Shared lesson: every label, placeholder, and hardcoded number in the UI is a promise; verify it against what the code actually does, and never let a button labeled as navigation trigger a paid operation.

- 18: The re-upload button promised the upload screen but immediately started a fresh paid OCR run.
- 119: Collage copy hardcoded a 10-photo requirement contradicting the adaptive generator.
- 128: The API key placeholder misled about the sk-ant- prefix.

## llm-rule-without-deterministic-check (2)

Shared lesson: a hard-checkable output constraint (banned phrases, marker preservation) enforced only by LLM self-review is not enforced; add a deterministic code backstop after the final pass, and never remove one without a replacement.

- 31: Em dash bans and PHOTO marker preservation relied on LLM self-scan after deterministic backstops were removed; restore code-level asserts.
- 110: Captions had no deterministic backstop for hard-checkable bans while blog did; matching constraint classes deserve matching enforcement.

## prompt-payload-contract-mismatch (2)

Shared lesson: a prompt that references a field is a contract with the payload builder; if the compact summary omits the field, the model fabricates the finding by construction, so test that every field the prompt names is actually sent.

- 6: swap_blog_photos omitted image_labels, breaking photo correlation.
- 29: The analysis prompt referenced is_personal and story metrics the payload never included, and a comment claimed Claude sets a field it never sees.

## subprocess-lifecycle-gaps (2)

Shared lesson: every spawned process needs a watchdog timeout and an escalating kill (SIGTERM then SIGKILL); a process that ignores the polite signal must not survive as a zombie.

- 24: PythonBridge invocations had no watchdog timeout.
- 100: The watchdog only sent SIGTERM, so an ignoring process outlived the timeout.

## platform-limits-unchecked (2)

Shared lesson: check the real operational limits of the platform (request payload sizes, token budgets) before shipping code that scales with user data, and test at realistic scale, not toy fixtures.

- 23: Full-size photos were attached to Claude API calls; downscale first.
- 147: Stage 2's clip payload size had no realistic-scale synthetic test.

## ffmpeg-implicit-defaults (2)

Shared lesson: never rely on ffmpeg's implicit stream selection or duration behavior; pass explicit -map flags and never use -shortest where the audio track may be shorter than the video.

- 14: Reel mux commands lacked explicit -map flags.
- 117: The audio fallback path used -shortest, truncating the reel when the raw track was shorter.

## non-atomic-write (2)

Shared lesson: write to a temp file and rename on success for any output another reader may consume; a partial file must be impossible to observe or cache.

- 11: Partial audio downloads could poison the cache; download atomically.
- 12: Reel encodes wrote in place; encode to temp and rename on success.

## stale-derived-artifact (2)

Shared lesson: any cached or baked artifact derived from editable inputs needs invalidation keyed to those inputs (fingerprint the source set); a bake-once path silently serves stale output after the user edits.

- 15: Export folders were not cleaned before re-export, mixing stale and fresh files.
- 55: The baked program PDF went stale when program pages changed after OCR.

## build-signing-tcc-persistence (2)

Shared lesson: macOS keys TCC grants to the code signature; local builds must sign with a stable identity and verify the installed bundle, or every rebuild silently drops permissions.

- 37: Sign local dev builds with a stable identity to persist TCC grants.
- 50: Verify the installed app signature in build-install.sh.

## dependency-management-gaps (2)

Shared lesson: declare and pin every runtime and build dependency; a floor-only constraint lets an upstream release break CI on untouched code, and an undeclared binary dependency degrades features silently per call.

- 87: ffmpeg and ffprobe were hard runtime dependencies but undeclared and only checked per call, so reels silently degraded.
- 105: Unpinned Pillow, anthropic, and pytest broke CI on upstream releases, which had already happened once.

## resource-cleanup-gaps (2)

Shared lesson: every resource an entity owns (temp renders, program files) must be reclaimed when the entity is deleted or the surface closes; plan the cleanup when creating the resource.

- 54: Program files were orphaned when their event was deleted.
- 60: Candidate collage PNGs were left behind after the layout gallery closed.

## ui-state-and-identity (2)

Shared lesson: UI interactions must key on stable content identity, not positional indices, and transient controls must reset their state when the operation ends.

- 19: Drag payloads were bare index strings, so cross-day drops silently reordered the wrong day; use content identifiers.
- 127: The audio play button never reset when the track finished.

## untested-failure-path (1)

- 86: A 1538-line PythonBridge had zero test coverage including the watchdog, cancel, and log-tail error paths; failure paths need tests before the happy path is trusted.

## secret-in-process-args (1)

- 81: The API key was exported inline in the zsh command string, visible in the process argument list; pass secrets via environment injection or file descriptors, never argv.

## unbatched-persistence-io (1)

- 91: Every keystroke re-encoded and rewrote the whole events.json; debounce and batch persistence instead of writing per input event.

## roadmap-not-tracked (1)

- 99: The PRD's headline phase had zero backlog representation once all issues closed; remaining scope must live as tracked issues, not PRD prose.

## wrong-domain-default (1)

- 167: Centered crop defaults quietly ate the composed upper third of performance photos; derive defaults from the user's actual craft, and change a cross-language default in both implementations together with a shared fixture.
