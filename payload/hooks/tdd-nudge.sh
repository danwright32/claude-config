#!/usr/bin/env bash
#
# tdd-nudge.sh
# Claude Code SessionStart hook (every source: startup, resume, /clear, compaction).
#
# Puts a standing test-first instruction into the session once. The instruction is CONDITIONAL
# ("code changes"), so it only changes behavior on coding work.
#
# ONCE PER SESSION, not once per prompt (hook trim, 2026-10-15). It ran on UserPromptSubmit until
# then, which copied the line into the transcript on every prompt: a session of P prompts carried P
# copies, each re-read by every later request, 1.14M characters in Slate sessions Oct 1 to 15 2026.
# SessionStart delivers it at the start, after /clear and after each compaction, which is exactly
# when the earlier copy is gone. Global CLAUDE.md states the same rule on every request as well.
#
# It also points a coding session at the "Test speed" section of the lessons index, because the
# 2026-08-29 audit of nine repos found the same handful of test-shaped mistakes (a fixed sleep
# instead of a wait on the condition, a seam left real, a derivation rebuilt per test) costing
# minutes per push everywhere, and a rule that is only read after the test is written arrives too
# late (LESSONS.md L27, L524). The section name is pinned by test-tdd-nudge.sh against the real
# LESSONS.md, so this line cannot quietly point at a section that no longer exists.
#
# Pairs with require-tests-before-push.sh: this nudges test-first DURING coding; that gate is the
# backstop that blocks a push if tests are missing anyway.
#
# A detached headless run (CLAUDE_DETACHED_RUN) has nobody to nudge and is not a coding request.
#
# stdout on exit 0 is added to the session's context.

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

cat <<'EOF2'
[Test-first] Code changes: TDD via `superpowers:test-driven-development`, failing test first. Before writing a test, read ~/.claude/LESSONS-INDEX-test-speed.md and apply it.
EOF2
