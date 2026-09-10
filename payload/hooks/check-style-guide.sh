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
commit_all=0
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' && commit_in_chain=1
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]|$)' && add_in_chain=1
printf '%s' "$cmd" | grep -Eq 'git[[:space:]][^&|;]*commit[[:space:]][^&|;]*-[A-Za-z]*a' && commit_all=1

if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
  mb="$(git merge-base "$base" HEAD 2>/dev/null)"
else
  mb="$(git rev-parse --verify --quiet HEAD~1 2>/dev/null)"
fi

EXCLUDES=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.snap'
  ':(exclude)*.min.js' ':(exclude)*.min.css' ':(exclude)*.svg'
  ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif'
  ':(exclude)*.pdf' ':(exclude)CLAUDE.md' ':(exclude).claude/hooks/check-style-guide.sh')

skip_ext() {  # $1 = a path ; true when it is one of the excluded kinds
  case "$1" in
    *.lock|*-lock.json|*.snap|*.min.js|*.min.css|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.pdf|CLAUDE.md) return 0 ;;
    *) return 1 ;;
  esac
}

# A whole file, in the shape the detector reads, for a file git has never seen.
new_file_block() {  # $1 = path
  [ -f "$1" ] || return 0
  skip_ext "$1" && return 0
  printf '\n--- NEW FILE: %s ---\n' "$1"
  sed 's/^/+/' "$1" 2>/dev/null | head -c 20000
}

# The COMMITTED content this push would carry. This is the whole reading for a push
# run on its own, which is the ordinary case and the one the gate exists for.
committed_diff=""
[ -n "$mb" ] && committed_diff="$(git diff "$mb" HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"

# The PENDING content, when this command commits before it pushes.
#
# It used to be the WHOLE working tree, every modified file and every untracked file
# alike, whether or not the commit was going to take them. On 2026-09-10 that blocked a
# push in the Slate checkout naming two untracked planning documents belonging to a
# different session, neither staged, tracked nor going anywhere; the same push run on
# its own immediately afterwards passed (claude-config#350).
#
# An untracked file nobody staged cannot be pushed, so it can never introduce anything,
# and neither can a tracked file modified but not named in the add. The incident showed
# only the first of those; both are the same fault (L30).
#
# So this reads what the commit would ACTUALLY carry: whatever is already in the index,
# plus what the `git add` in this chain names, plus everything tracked when the commit
# stages for itself with -a. Nothing else.
pending_diff=""
scope_unknown=0
if [ "$commit_in_chain" -eq 1 ]; then
  pending_diff="$(git diff --cached -- . "${EXCLUDES[@]}" 2>/dev/null)"

  add_scope="ALL"
  if [ "$add_in_chain" -eq 1 ]; then
    add_scope="$(HK_CMD="$cmd" python3 -c '
import os, shlex, sys

# What the `git add` invocations in this command actually name. Prints a scope word on
# the first line and, for PATHS, one path per line after it.
#
# UNKNOWN is a real answer, not a failure: it means the caller must fall back to the
# whole working tree AND say so, because a reading that quietly narrows to nothing would
# let a forbidden character through while reporting a clean run (L98).
try:
    toks = shlex.split(os.environ["HK_CMD"], posix=True)
except ValueError:
    print("UNKNOWN"); raise SystemExit

SEP = {"&&", "||", ";", "|", "&"}
EVERYTHING = {"-A", "--all", "--no-ignore-removal"}
TRACKED_ONLY = {"-u", "--update"}
paths = []
scope = "PATHS"
i = 0
while i < len(toks):
    if toks[i] == "rtk":
        i += 1
        continue
    if toks[i].split("/")[-1] != "git":
        i += 1
        continue
    j = i + 1
    while j < len(toks) and toks[j].startswith("-"):
        j += 2 if toks[j] in ("-C", "-c") else 1
    if j >= len(toks) or toks[j] != "add":
        i = j + 1
        continue
    k = j + 1
    while k < len(toks) and toks[k] not in SEP:
        a = toks[k]
        if a in EVERYTHING:
            scope = "ALL"
        elif a in TRACKED_ONLY:
            if scope == "PATHS":
                scope = "TRACKED"
        elif a.startswith("-"):
            pass
        elif a in (".", "./", ":/", "*"):
            scope = "ALL"
        else:
            paths.append(a)
        k += 1
    i = k

if scope == "PATHS" and not paths:
    # An add that named nothing is an add nobody can account for.
    scope = "UNKNOWN"
print(scope)
if scope == "PATHS":
    for pth in paths:
        print(pth)
' 2>/dev/null)"
    [ -n "$add_scope" ] || add_scope="UNKNOWN"
  elif [ "$commit_all" -eq 1 ]; then
    add_scope="TRACKED"
  else
    # A commit with no add and no -a takes exactly what is already in the index, which
    # `git diff --cached` above has already read.
    add_scope="INDEX"
  fi

  case "$(printf '%s' "$add_scope" | head -1)" in
    INDEX) : ;;
    TRACKED)
      pending_diff="${pending_diff}
$(git diff HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"
      ;;
    ALL|UNKNOWN)
      [ "$(printf '%s' "$add_scope" | head -1)" = "UNKNOWN" ] && scope_unknown=1
      pending_diff="${pending_diff}
$(git diff HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        pending_diff="${pending_diff}$(new_file_block "$u")"
      done < <(git ls-files --others --exclude-standard 2>/dev/null)
      ;;
    PATHS)
      while IFS= read -r pth; do
        [ -n "$pth" ] || continue
        # A path that is not there cannot be read, and narrowing to nothing on a path
        # nobody can resolve would report a clean run it never measured (L98, L11).
        if [ ! -e "$pth" ]; then scope_unknown=1; continue; fi
        pending_diff="${pending_diff}
$(git diff HEAD -- "$pth" "${EXCLUDES[@]}" 2>/dev/null)"
        while IFS= read -r u; do
          [ -n "$u" ] || continue
          pending_diff="${pending_diff}$(new_file_block "$u")"
        done < <(git ls-files --others --exclude-standard -- "$pth" 2>/dev/null)
      done < <(printf '%s\n' "$add_scope" | tail -n +2)
      if [ "$scope_unknown" -eq 1 ]; then
        pending_diff="${pending_diff}
$(git diff HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"
        while IFS= read -r u; do
          [ -n "$u" ] || continue
          pending_diff="${pending_diff}$(new_file_block "$u")"
        done < <(git ls-files --others --exclude-standard 2>/dev/null)
      fi
      ;;
  esac
fi

[ -n "$committed_diff$pending_diff" ] || exit 0

# The detector, as a function over one body of diff text, so the two readings below
# cannot drift into two copies of it. Kept unindented and in this exact shape because
# test-check-style-guide.sh lifts the python out of this file and drives it directly,
# which is what stops the suite testing a re-implementation of the rule (L52).
scan() {  # $1 = diff text ; prints one line per finding
findings="$(printf '%s' "$1" | python3 -c '
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
printf '%s' "$findings"
}

committed_findings="$(scan "$committed_diff")"
pending_findings="$(scan "$pending_diff")"

[ -n "$committed_findings$pending_findings" ] || exit 0

# The refusal may claim only what it actually measured (L11).
#
# It used to say "this push introduces an em dash", always, including when the reading
# came from the working tree because the commit had not happened yet. A reader believes
# their own change is at fault and goes looking in the wrong place, and the only remedy
# offered was the override, which is the one habit this gate cannot afford
# (claude-config#350).
{
  if [ -n "$committed_findings" ]; then
    echo "PUSH BLOCKED: this push introduces an em dash, en dash, or emoji character,"
    echo "which the Writing Style rule in CLAUDE.md forbids."
    echo ""
    echo "In the commits being pushed:"
    printf '%s\n' "$committed_findings"
  fi

  if [ -n "$pending_findings" ]; then
    [ -n "$committed_findings" ] && echo ""
    if [ -z "$committed_findings" ]; then
      echo "PUSH BLOCKED: the commit this command is about to make would introduce an"
      echo "em dash, en dash, or emoji character, which the Writing Style rule in"
      echo "CLAUDE.md forbids."
      echo ""
    fi
    echo "In content that has not been committed yet, read from what this command is"
    echo "about to stage and commit:"
    printf '%s\n' "$pending_findings"
  fi

  if [ "$scope_unknown" -eq 1 ]; then
    echo ""
    echo "Which paths that commit would take could not be worked out from the command,"
    echo "so the whole working tree was read and a line above may belong to a file this"
    echo "commit will not carry. To find out, run the commit and the push as"
    echo "two separate commands: a push on its own judges the commits only."
  fi

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
