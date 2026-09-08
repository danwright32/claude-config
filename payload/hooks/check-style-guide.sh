#!/usr/bin/env bash
#
# check-style-guide.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: block a `git push` that introduces an em dash (—), en dash (–), or an
# emoji character on a NEW line, matching the global Writing Style rule. Built
# 2026-07-06 after a cross-project issue audit showed these written rules were
# violated repeatedly (PET issues #542, #179, #178, #176, #146) even after
# being stated in CLAUDE.md -- prose alone wasn't catching it, so this is a
# fast, no-model grep-based backstop for the two unambiguous violations.
#
# Deliberately does NOT try to detect "hyphen used as a sentence connector" --
# that requires natural-language judgment (a hyphen inside "self-aware" is
# fine, one used to join clauses is not) and a regex would false-positive on
# ordinary compound words constantly. Em dash / en dash / emoji are
# unambiguous unicode characters that never appear by accident in normal
# writing or code, so those are the two checks worth automating.
#
# Override: SKIP_STYLE_CHECK=1 git push ...  (docs describing the rule itself
# need to reference the literal characters, or a false positive). Explain why
# to the user first, same as the test gate -- never skip silently.
#
# Fails OPEN: any parse/git error allows the push.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat)"


parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

# Push detection is shared with the other push hooks. The local version this
# replaced could not see `git -C <repo> push` at all (the repo path matched
# neither a flag nor an assignment), so those pushes were never style checked.

ps_is_git_push "$cmd" || exit 0

if ps_has_override "$cmd" SKIP_STYLE_CHECK; then
  exit 0
fi

# The repo is resolved from the COMMAND first and the payload cwd second. The cwd
# is the SESSION's directory, so a session rooted outside the project reaches it
# as `cd <repo> && git push`, and reading the cwd alone let every one of those
# pushes past this check with no style scan at all, looking exactly like a push
# it had cleared. Shared with the other push hooks so the three cannot drift.
repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# The ref to judge against comes from the shared helper, not from a copy here (claude-config#339).
# A second push gate needed the same answer, and two copies of "what is this push being compared
# with" drift invisibly: a wrong base scopes a gate to the wrong diff while still reporting a clean
# run (L70, L613).
base="$(ps_base_ref || true)"

commit_in_chain=0
add_in_chain=0
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' && commit_in_chain=1
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]|$)' && add_in_chain=1
printf '%s' "$cmd" | grep -Eq 'git[[:space:]][^&|;]*commit[[:space:]][^&|;]*-[A-Za-z]*a' && add_in_chain=1

if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
  mb="$(git merge-base "$base" HEAD 2>/dev/null)"
else
  mb="$(git rev-parse --verify --quiet HEAD~1 2>/dev/null)"
fi

EXCLUDES=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.snap'
  ':(exclude)*.min.js' ':(exclude)*.min.css' ':(exclude)*.svg'
  ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif'
  ':(exclude)*.pdf' ':(exclude)CLAUDE.md' ':(exclude).claude/hooks/check-style-guide.sh')

diff=""
[ -n "$mb" ] && diff="$(git diff "$mb" HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"

if [ "$commit_in_chain" -eq 1 ]; then
  diff="${diff}
$(git diff HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"
  if [ "$add_in_chain" -eq 1 ]; then
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      [ -f "$u" ] || continue
      case "$u" in
        *.lock|*-lock.json|*.snap|*.min.js|*.min.css|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.pdf|CLAUDE.md) continue ;;
      esac
      diff="${diff}
--- NEW FILE: ${u} ---
$(sed 's/^/+/' "$u" 2>/dev/null | head -c 20000)"
    done < <(git ls-files --others --exclude-standard 2>/dev/null)
  fi
fi

[ -n "$diff" ] || exit 0

findings="$(printf '%s' "$diff" | python3 -c '
import sys, re

emoji_re = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "⤴⤵⬅-⬇⬛⬜⭐⭕️]"
)
dash_re = re.compile("[—–]")

current_file = "(unknown file)"
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("+++ "):
        f = line[4:]
        if f.startswith("b/"):
            f = f[2:]
        current_file = f
        continue
    if line.startswith("--- NEW FILE: ") and line.endswith(" ---"):
        current_file = line[len("--- NEW FILE: "):-4]
        continue
    if not line.startswith("+") or line.startswith("+++"):
        continue
    content = line[1:]
    if dash_re.search(content) or emoji_re.search(content):
        out.append(f"{current_file}: {content.strip()[:160]}")

for o in out[:25]:
    print(o)
if len(out) > 25:
    print(f"... and {len(out) - 25} more")
' 2>/dev/null)"

[ -n "$findings" ] || exit 0

{
  echo "PUSH BLOCKED: this push introduces an em dash, en dash, or emoji character,"
  echo "which the Writing Style rule in CLAUDE.md forbids."
  echo ""
  echo "Offending lines:"
  printf '%s\n' "$findings"
  echo ""
  echo "Fix the text (use a period, comma, colon, or parentheses instead of a dash;"
  echo "remove the emoji), then push again."
  echo "OVERRIDE: if this is a false positive, or the text genuinely needs to"
  echo "reference the literal character (e.g. documenting this rule itself),"
  echo "re-run with:"
  echo "    SKIP_STYLE_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, WHY skipping is legitimate here, so they can judge whether it"
  echo "makes sense. Never override silently."
} >&2
exit 2
