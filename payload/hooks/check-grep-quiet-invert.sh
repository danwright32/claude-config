#!/bin/bash
# PreToolUse gate: block a `git push` that ADDS a quiet inverted grep (L645).
#
# WHY. `grep` in Dan's shells is a FUNCTION that shims to ugrep, and ugrep's quiet
# flag combined with the invert flag reports whether the PATTERN matched rather than
# whether any line was SELECTED. Measured 2026-09-08, wanted / ugrep / real grep:
#
#   pattern matches nothing, lines survive        0 / 0 / 0
#   pattern matches some, others still survive    0 / 1 / 0   <- the ordinary case
#   pattern matches every line, none survive      1 / 1 / 1
#
# So the construct answers "no" whenever the pattern matches anything at all. It is
# silent, deterministic, and always wrong in the same direction, which is why a CI
# wait loop built on one polled a merged pull request for two and a half hours.
#
# `command grep` is the REAL binary and is correct, so it is deliberately NOT
# flagged: it is the remedy as well as the exemption.
#
# Distinct from test-pipefail-shortcircuit.sh, which ratchets the neighbouring
# defect (L183): there the PIPELINE's status is corrupted by SIGPIPE under pipefail
# and it depends on the input's size. This is grep's own answer and is deterministic.
#
# Override: SKIP_GREP_QV_CHECK=1 git push ...
# Fails OPEN: any parse or git error allows the push.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0
ps_has_override "$cmd" SKIP_GREP_QV_CHECK && exit 0

repo="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo" ] || exit 0
cd "$repo" 2>/dev/null || exit 0

mb="$(ps_merge_base)"
diff=""
[ -n "$mb" ] && diff="$(git diff "$mb" HEAD 2>/dev/null)"
diff="${diff}
$(git diff HEAD 2>/dev/null)"
[ -n "$diff" ] || exit 0

findings="$(printf '%s' "$diff" | python3 -c '
import sys, re

# The literal being banned is never written in this file: it is assembled from the
# flag letters, so this guard and the style gate have nothing to catch in the code
# that implements them (the same trick CLAUDE.md records for the dash rule).
QUIET = {"q", "quiet", "silent"}
INVERT = {"v", "invert-match"}

# grep, then every following token that starts with a dash. Stops at the pattern.
CALL = re.compile(r"(?<![\w./-])(command\s+|/\S*/)?grep((?:\s+--?[A-Za-z][\w-]*)*)")

def flags(blob):
    got = set()
    for tok in blob.split():
        if tok.startswith("--"):
            got.add(tok[2:])
        elif tok.startswith("-"):
            got.update(tok[1:])
    return got

current = "(unknown file)"
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("+++ "):
        f = line[4:]
        current = f[2:] if f.startswith("b/") else f
        continue
    if not line.startswith("+") or line.startswith("+++"):
        continue
    content = line[1:]
    for m in CALL.finditer(content):
        # `command grep` and an absolute path reach the real binary, which is right.
        if m.group(1):
            continue
        got = flags(m.group(2))
        if (got & QUIET) and (got & INVERT):
            out.append(f"{current}: {content.strip()[:160]}")
            break

for o in out[:25]:
    print(o)
if len(out) > 25:
    print(f"... and {len(out) - 25} more")
' 2>/dev/null)"

[ -n "$findings" ] || exit 0

{
  echo "PUSH BLOCKED: this push adds a grep that is both quiet and inverted."
  echo ""
  echo "In Dan's shells grep is a function shimming to ugrep, and that flag pair asks"
  echo "whether the PATTERN matched rather than whether any line SURVIVED the filter."
  echo "So it answers no whenever the pattern matches anything at all, which is the"
  echo "ordinary case. It is silent and always wrong in the same direction (L645)."
  echo ""
  echo "Offending lines:"
  printf '%s\n' "$findings"
  echo ""
  echo "Fix it one of two ways:"
  echo "  1. filter and count:  n=\$(... | grep -cE 'pat'); [ \"\$n\" -gt 0 ]"
  echo "  2. call the real binary, which behaves correctly:  command grep ..."
  echo ""
  echo "OVERRIDE: if this line is documenting the rule itself, or genuinely wants the"
  echo "shim's semantics, re-run with:"
  echo "    SKIP_GREP_QV_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, WHY skipping is legitimate here. Never override silently."
} >&2
exit 2
