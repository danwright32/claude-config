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
# Pairs with require-tests-before-push.sh: this nudges test-first DURING coding;
# that gate is the backstop that blocks a push if tests are missing anyway.
#
# stdout on exit 0 is appended to the prompt context.

cat <<'EOF'
[Test-first policy] Code changes use TDD: invoke `superpowers:test-driven-development` and write the failing test before the implementation. No-op for read-only, research, planning, or non-code prompts.
EOF
