#!/usr/bin/env bash
#
# tdd-nudge.sh
# Claude Code UserPromptSubmit hook.
#
# Injects a standing test-first instruction into every prompt. The instruction
# is CONDITIONAL ("if this task involves writing or changing code"), so it only
# changes behavior on coding turns and is a no-op for research / read-only /
# conversational prompts.
#
# It also points a coding turn at the "Test speed" section of the lessons index,
# because the 2026-08-29 audit of nine repos found the same handful of test-shaped
# mistakes (a fixed sleep instead of a wait on the condition, a seam left real, a
# derivation rebuilt per test) costing minutes per push everywhere, and a rule that
# is only read after the test is written arrives too late (LESSONS.md L27, L524).
# The section name is pinned by test-tdd-nudge.sh against the real LESSONS.md, so
# this line cannot quietly point at a section that no longer exists.
#
# Pairs with require-tests-before-push.sh: this nudges test-first DURING coding;
# that gate is the backstop that blocks a push if tests are missing anyway.
#
# stdout on exit 0 is appended to the prompt context.

cat <<'EOF2'
[Test-first policy] Code changes use TDD: invoke `superpowers:test-driven-development` and write the failing test before the implementation. Before writing any new test, read LESSONS-INDEX-test-speed.md (already loaded) and apply it: wait on conditions rather than fixed times, inject every sleep and clock, set every seam or name why it stays real, compute a shared derivation once per suite. No-op for read-only, research, planning, or non-code prompts.
EOF2
