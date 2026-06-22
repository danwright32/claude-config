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
[Test-first policy] If this task involves writing or modifying code, use test-driven development: invoke the `superpowers:test-driven-development` skill and write a failing test that captures the intended behavior BEFORE writing the implementation, then make it pass, then refactor. Do not write implementation code first. This policy does not apply to read-only, research, planning, or non-code requests.
EOF
