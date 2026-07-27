#!/usr/bin/env bash
#
# feature-discovery-nudge.sh
# Claude Code UserPromptSubmit hook.
#
# Injects a standing feature-discovery instruction into every prompt. The
# instruction is CONDITIONAL ("if this prompt proposes or scopes a new feature"),
# so it only changes behavior on feature-discussion turns and is a no-op for
# bug fixes, research, read-only, or conversational prompts.
#
# Mirrors tdd-nudge.sh: no keyword grepping, the model self-filters on the
# conditional. The substance lives in the `feature-discovery` skill.
#
# stdout on exit 0 is appended to the prompt context.

cat <<'EOF'
[Feature-discovery policy] New-feature prompts: run the `feature-discovery` skill's clarifying interview before any plan or code. No-op for bug fixes, small mechanical edits, research, or conversation.
EOF
