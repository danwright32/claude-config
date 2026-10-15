#!/usr/bin/env bash
#
# feature-discovery-nudge.sh
# Claude Code SessionStart hook (every source: startup, resume, /clear, compaction).
#
# Puts a standing feature-discovery instruction into the session once. It ran on every prompt until
# the hook trim of 2026-10-15, which copied it into the transcript once per prompt (558K characters
# in Slate sessions Oct 1 to 15 2026, each copy re-read by every later request); once per session,
# and again after /clear or a compaction, carries the same rule. The
# instruction is CONDITIONAL ("if this prompt proposes or scopes a new feature"),
# so it only changes behavior on feature-discussion turns and is a no-op for
# bug fixes, research, read-only, or conversational prompts.
#
# Mirrors tdd-nudge.sh: no keyword grepping, the model self-filters on the
# conditional. The substance lives in the `feature-discovery` skill.
#
# A detached headless run (CLAUDE_DETACHED_RUN) has nobody to interview.
#
# stdout on exit 0 is added to the session's context.

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

cat <<'EOF'
[Feature-discovery policy] New-feature prompts: run the `feature-discovery` skill's clarifying interview before any plan or code. No-op for bug fixes, small mechanical edits, research, or conversation.
EOF
