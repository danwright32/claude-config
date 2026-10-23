#!/usr/bin/env bash
# Tests for match-open-issues.py --paths, the one reader of the file paths an issue names
# (claude-config#1508). The area check mod (mods/area-check) asks it for every open issue's paths
# rather than keeping a second extractor of its own (L655, L370): the end of turn review's duplicate
# matcher and the area check read an issue's paths one way, through the same function.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
MATCHER="$DIR/lib/match-open-issues.py"
paths(){ printf '%s' "$1" | python3 "$MATCHER" --paths; }
same(){ # same <description> <expected> <actual>
  if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" "expected $2, got $3"; fi
}

same "an issue's paths, title and body, each once, in the order they appear" \
  '{"5": ["lib/foo.ts", "app/page.tsx", "slack.ts"]}' \
  "$(paths '[{"number": 5, "title": "Split lib/foo.ts", "body": "app/page.tsx calls lib/foo.ts; see slack.ts"}]')"
same "a line or a range after a path is not part of it" \
  '{"7": ["src/a.ts", "src/b.py"]}' \
  "$(paths '[{"number": 7, "title": "t", "body": "src/a.ts:12-40 and src/b.py:9"}]')"
same "a longer extension is read whole, never cut to a shorter one" \
  '{"8": ["lib/foo.tsx"]}' \
  "$(paths '[{"number": 8, "title": "t", "body": "lib/foo.tsx only"}]')"
same "a leading ./ is not part of the path" \
  '{"9": ["hooks/x.sh"]}' \
  "$(paths '[{"number": 9, "title": "t", "body": "run ./hooks/x.sh"}]')"
same "a path in backticks, a markdown link or after a line range's own dot is read whole" \
  '{"10": ["src/a.ts", "docs/b.md", "lib/c.py"]}' \
  "$(paths '[{"number": 10, "title": "t", "body": "see `src/a.ts`, [b](docs/b.md) and lib/c.py:3."}]')"
same "an issue naming no path is listed with none, never left out" \
  '{"3": []}' \
  "$(paths '[{"number": 3, "title": "Make it faster", "body": null}]')"
same "several issues, each by its number" \
  '{"1": ["a.rb"], "2": ["b/c.go"]}' \
  "$(paths '[{"number": 1, "title": "a.rb", "body": ""}, {"number": 2, "title": "", "body": "b/c.go"}]')"

# A list that is not one is refused, never read as issues naming nothing (L10).
out="$(printf 'not json' | python3 "$MATCHER" --paths 2>&1)"; code=$?
[ "$code" -ne 0 ] && check "a list that cannot be read exits non zero" ok || check "a list that cannot be read exits non zero" "exit 0: $out"
out="$(printf '{"number": 1}' | python3 "$MATCHER" --paths 2>&1)"; code=$?
[ "$code" -ne 0 ] && check "a list that is not a list exits non zero" ok || check "a list that is not a list exits non zero" "exit 0: $out"

# Every extension the area check counts as source is one this reader finds, or an issue naming such a
# file could never match it. Read from the mod's own list, so a new one there fails here first.
RULES="$DIR/../mods/area-check/hooks/rules.ts"
if [ ! -f "$RULES" ]; then
  check "the area check's rules are beside these hooks" "$RULES is missing"
else
  exts="$(grep -E '^export const SOURCE_EXTENSIONS' "$RULES" | grep -oE "'[a-z0-9+]+'" | tr -d "'")"
  [ -n "$exts" ] && check "the area check's source extensions are read" ok || check "the area check's source extensions are read" "no SOURCE_EXTENSIONS line in $RULES"
  missed=""
  for e in $exts; do
    got="$(paths "[{\"number\": 1, \"title\": \"\", \"body\": \"see dir/name.$e now\"}]")"
    [ "$got" = "{\"1\": [\"dir/name.$e\"]}" ] || missed="$missed $e"
  done
  [ -z "$missed" ] && check "every source extension the area check counts is found in an issue" ok || check "every source extension the area check counts is found in an issue" "not found:$missed"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
