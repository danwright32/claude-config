#!/usr/bin/env bash
# The pennie-dev-update skill's first appearance of a product (claude-config#588).
#
# On 2026-09-28 the skill asked Dan for a starting date for Sonar's first run and was about to list
# its merged PRs one by one. Dan answered: "sonar shouldn't announce specific updates. this would
# be the announcement of sonar in general." So a repo with no lastEnd is introduced in general, and
# its window then starts after its newest merge, so later runs report changes only. The skill is
# prose Claude follows, so what is held here is that the prose says so, and that the paragraphs
# contradicting Dan's decision (no launch mode, ask for a starting date) are gone (L252: a reversed
# decision deletes the text defending it).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SKILL="$DIR/../payload/skills/pennie-dev-update/SKILL.md"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
if [ ! -f "$SKILL" ]; then
  echo "FAIL: the skill is not at $SKILL, so nothing was checked."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
# The claims are held to the "### First appearance" section of the skill, never anywhere in the
# file, and each one as the exact sentence that makes it, case and all, inside ONE paragraph of that
# section with its whitespace collapsed (so rewrapping cannot hide it, L278). #790 found the first
# version matched loose words case insensitively anywhere in a paragraph, so a rewording that
# dropped the claim, or unrelated text holding the words, passed (L178, L135). A rewording now
# fails here and the sentence below is updated with it: the wording is the behaviour Claude follows.
section="$(awk '/^### First appearance$/ { f = 1; next } f && /^(#|---)/ { exit } f' "$SKILL")"
paras="$(printf '%s\n' "$section" | awk 'BEGIN { RS = ""; ORS = "\n" } { gsub(/[[:space:]]+/, " "); print }')"
claim(){   # $1 = what it holds  $2 = the exact sentence, inside one paragraph of the section
  if [ -z "$section" ]; then check "$1" "the skill has no '### First appearance' section"; return; fi
  # Matched with `case`, one paragraph at a time, never a producer piped into a quiet grep (L183).
  local p
  while IFS= read -r p; do
    case "$p" in *"$2"*) check "$1" ok; return ;; esac
  done <<< "$paras"
  check "$1" "the section does not say: $2"
}
gone(){   # $1 = what it holds  $2 = a phrase that must appear nowhere in the skill, in any case
  if grep -q -i -F -- "$2" "$SKILL"; then check "$1" "the skill still says: $2"; else check "$1" ok; fi
}

gone "the no launch mode paragraph is gone" "no launch mode"
gone "a first run no longer asks for a starting date" "ask for a starting date"
claim "a repo with no lastEnd is introduced in general" \
  'A repo with no `lastEnd` at all is a product appearing for the first time, and it is introduced in general.'
claim "the introduction never lists the product's merged PRs one by one" \
  "the product's merged PRs are never listed one by one."
claim "Dan's decision is quoted with its date" \
  "Dan decided this on 2026-09-28, when the skill asked him for a starting date for Sonar: \"sonar shouldn't announce specific updates. this would be the announcement of sonar in general.\""
claim "the introduction covers what it is, who uses it, when to open it, what it checks and how to share a result" \
  "what it is, who uses it, when to open it, what it checks, and how to share a result"
claim "the window then starts after the newest merge in production, so later runs report changes only" \
  'set that repo'"'"'s `lastEnd` to the `merged_at` of its newest merged PR that reached production (section 4), so the next run reports changes only'

# The checks above can fail: the same claims against a section that does not make them.
section_real="$section"; paras_real="$paras"
section="An unrelated paragraph mentioning lastEnd, newest, merged_at and changes only, in general, never one by one."
paras="$section"
before_fail=$fail
claim "(control) a section without the claim" 'A repo with no `lastEnd` at all is a product appearing for the first time, and it is introduced in general.' >/dev/null
if [ "$fail" -eq $((before_fail + 1)) ]; then fail=$before_fail; check "the claim check fails on loose words that make no claim" ok
else check "the claim check fails on loose words that make no claim" "it passed text that makes no claim"; fi
section="$section_real"; paras="$paras_real"

# ---- claude-config#679: the defects the October 2026 skills audit found.
CONFIG="$DIR/../payload/skills/pennie-dev-update/repos.json"

# The window starts strictly after lastEnd. The skill said so in section 2 and then filtered on
# `merged_at >= start` in section 3, so the newest change of the last post was listed again. Held
# as a class: no line that talks about a merge may compare with >= at all.
ge_lines="$(grep -n 'merged' "$SKILL" | grep -F '>=' || true)"
if [ -z "$ge_lines" ]; then check "no merge comparison includes the boundary itself (>=)" ok
else check "no merge comparison includes the boundary itself (>=)" "$ge_lines"; fi

# The repo paths were typed by hand as they stood before the work MacBook's Documents move on
# 2026-10-02, and pointed at nothing after it (L153). Nothing the skill does needs a local checkout
# once the deploy check asks GitHub, so no entry carries a path at all and no step runs git there.
if [ ! -f "$CONFIG" ]; then check "repos.json carries no machine path" "repos.json is not at $CONFIG"
else
  with_path="$(python3 - "$CONFIG" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(" ".join(r.get("name", "?") for r in data["repos"] if "path" in r))
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ]; then check "repos.json carries no machine path" "repos.json could not be read (exit $rc)"
  elif [ -n "$with_path" ]; then check "repos.json carries no machine path" "these entries still carry one: $with_path"
  else check "repos.json carries no machine path" ok; fi
fi
gone "no step runs git in a local checkout" "git -C"
gone "no step reads a configured path" 'configured `path`'

# The 2026-09-28 edit removed the "backend only" line and the "Update for" opener, while the
# structure rules and the worked example still demanded both (L562: the example wins).
gone "the structure no longer asks for a backend only line" "noting some items are backend only"
gone "the example no longer carries the backend only line" "because they are backend only"
old_opener="$(grep -n 'Update for ' "$SKILL" || true)"
if [ -z "$old_opener" ]; then check "no opener still reads Update for" ok
else check "no opener still reads Update for" "$old_opener"; fi
bad_opener="$(grep -n '^Updates for ' "$SKILL" | grep -v ' :thread:$' || true)"
if [ -z "$bad_opener" ]; then check "every example opener ends with :thread:" ok
else check "every example opener ends with :thread:" "$bad_opener"; fi
openers="$(grep -c '^Updates for .* :thread:$' "$SKILL" || true)"
if [ "${openers:-0}" -ge 2 ]; then check "the post example and the quiet period example both open the current way" ok
else check "the post example and the quiet period example both open the current way" "found ${openers:-0} such openers"; fi

# "Three cases" headed a four row table. The number word is checked against the rows it counts.
counted="$(awk '
  /^## 4\./ { s = 1; next }
  s && /^## / { exit }
  s && /must stay distinct/ { split("one two three four five six seven eight", w, " "); for (i in w) if (tolower($0) ~ ("(^|[^a-z])" w[i] "([^a-z]|$)")) word = i }
  s && /^\|/ { rows++ }
  END { print (word ? word : "none") " " (rows > 2 ? rows - 2 : 0) }
' "$SKILL")"
if [ "${counted%% *}" = "${counted##* }" ]; then check "the deploy table's count word matches its rows" ok
else check "the deploy table's count word matches its rows" "word says ${counted%% *}, table has ${counted##* } rows"; fi

# BBEdit's helper opens the file in the background without --front-window, reports success, and
# Dan sees nothing (global CLAUDE.md, 2026-09-09).
no_front="$(grep -n 'bbedit_tool' "$SKILL" | grep -v -e '--front-window' || true)"
if [ -z "$no_front" ]; then check "every BBEdit open brings its window to the front" ok
else check "every BBEdit open brings its window to the front" "$no_front"; fi

# ---- claude-config#680: the window, gathering and post rules moved into scripts. The prose now
# tells Claude to run them, so every script it names must exist beside it (L3: built is not wired),
# and the sequence must run each one.
SKILL_DIR="$(dirname "$SKILL")"
named="$(grep -o '~/\.claude/skills/pennie-dev-update/[A-Za-z0-9_.-]*' "$SKILL" | sort -u)"
if [ -z "$named" ]; then check "the skill runs its scripts by path" "it names no script under ~/.claude/skills/pennie-dev-update/"
else
  while IFS= read -r ref; do
    f="${ref##*/}"
    [ -z "$f" ] && continue
    if [ -f "$SKILL_DIR/$f" ]; then check "the skill names $f, which exists beside it" ok
    else check "the skill names $f, which exists beside it" "no $f in $SKILL_DIR"; fi
  done <<< "$named"
fi
sequence="$(awk '/^## 10\./ { f = 1; next } f' "$SKILL")"
for step in 'gather.js gather' 'gather.js commit-state' 'lint-post.js'; do
  case "$sequence" in *"$step"*) check "the sequence runs $step" ok ;; *) check "the sequence runs $step" "section 10 never says $step" ;; esac
done

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
