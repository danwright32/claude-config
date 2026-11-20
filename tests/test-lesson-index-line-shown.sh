#!/usr/bin/env bash
# The line the lessons index renders for an approved entry is the text Dan was shown
# (claude-config#3320, independent review).
#
# Two readers take one line from a lesson entry. Ask before saving lets an approved entry through
# only when that line is what Dan read in the lesson picker: his SHORT line, or the whole rule where
# he was shown none. The generator (lesson_entries_render in claude-sync) writes the line every
# session loads. The review found them disagreeing: a rule approved with no SHORT line went through
# with its bold closed after five words, and the index rendered those five words as the lesson.
#
# The mod now takes such an entry only in a shape the generator reads one way. This suite is the
# half of the proof the mod's own suite cannot give, since it cannot run a shell: it runs the REAL
# generator, cut from claude-sync as it stands, over the entries listed in
# payload/mods/ask-before-saving/tests/index-lines.ts, and holds what it renders to the line that
# list records. The mod's suite (tests/rules.test.ts there) holds the mod to the same list: which
# entries it approves, and that an approved entry's line is the text shown. So an approved entry
# rendering anything else fails here, and an entry the mod wrongly approves fails there.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

SYNC="$ROOT/claude-sync"
CASES="$ROOT/payload/mods/ask-before-saving/tests/index-lines.ts"
pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
finish() {
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-lesson-index-line-shown.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The generator itself, as claude-sync holds it today: the function's own lines, defined here.
# Cut by its first line and the first closing brace at the start of a line after it. A cut that
# finds nothing would leave every case below comparing an empty rendering, so it is checked first,
# and then on an entry whose line is known (a positive control: L98, L100).
fn="$(sed -n '/^lesson_entries_render(){/,/^}$/p' "$SYNC" 2>/dev/null)"
case "$fn" in
  'lesson_entries_render(){'*) eval "$fn" ;;
  *) check "the generator could be read out of claude-sync" "no function starting 'lesson_entries_render(){' in $SYNC"; finish; exit 1 ;;
esac
render() { # render <a lesson entry> -> the index line of L753, or nothing
  {
    printf '# Lessons\n\n## Data safety\n\n'
    printf '%s\n' "$1"
    printf '\n## Honest failure\n\n- **L902. An error state and an empty state are different screens.** (claude-config#10, 2026-06-01)\n'
  } > "$WORK/LESSONS.md"
  lesson_entries_render "$WORK/LESSONS.md" index | grep '^- L753\.'
}
control="$(render '- **L753. A rule with a short form.** Its evidence. (slate#9, 2026-11-20)
  SHORT: The short form.')"
check "the generator renders an entry's SHORT line as its index line" "$([ "$control" = '- L753. The short form.' ] && echo ok || echo "rendered: $control")"
other="$(lesson_entries_render "$WORK/LESSONS.md" index | grep -c '^- L902\. An error state and an empty state are different screens\.$')"
check "and the entry after it is still rendered whole" "$([ "$other" = 1 ] && echo ok || echo "lines: $other")"

# The cases, one a line in the list's fixed shape. Every line that opens a case must be read, or
# the unread ones would be cases nobody ran.
S=$'\x1f'
opened="$(grep -c "^  { name: '" "$CASES" 2>/dev/null || true)"
parsed="$(sed -E -n "s/^  \{ name: '([^']*)', approved: (true|false), rule: '([^']*)', check: '([^']*)', short: '([^']*)', entry: '([^']*)', line: '([^']*)' \},\$/\1$S\2$S\3$S\4$S\5$S\6$S\7/p" "$CASES" 2>/dev/null)"
read_n="$(printf '%s\n' "$parsed" | grep -c "$S" || true)"
check "every case in the list was read (at least 8)" "$([ "${opened:-0}" -ge 8 ] && [ "$read_n" = "$opened" ] && echo ok || echo "$read_n read of ${opened:-0} opened in $CASES")"

approved_n=0; refused_n=0
while IFS="$S" read -r name approved rule ck short entry line; do
  [ -n "$name" ] || continue
  got="$(render "$(printf '%b' "$entry")")"
  check "the index renders the recorded line for: $name" "$([ "$got" = "$line" ] && echo ok || echo "rendered '$got', the list records '$line'")"
  # What Dan was shown for this entry: his SHORT line's text, or the whole rule.
  if [ -n "$short" ]; then shown="- L753. ${short#SHORT: }"; else shown="- L753. $rule"; fi
  if [ "$approved" = true ]; then
    approved_n=$((approved_n + 1))
    check "an approved entry's index line is the text Dan was shown: $name" "$([ "$got" = "$shown" ] && echo ok || echo "rendered '$got', he was shown '$shown'")"
  else
    refused_n=$((refused_n + 1))
    check "a refused entry is one whose index line is not the text Dan was shown: $name" "$([ "$got" != "$shown" ] && echo ok || echo "rendered the text shown, so the list calls a sound entry refused")"
  fi
done <<EOF
$parsed
EOF
check "the list holds approved entries and refused ones (at least 3 of each)" "$([ "$approved_n" -ge 3 ] && [ "$refused_n" -ge 3 ] && echo ok || echo "$approved_n approved, $refused_n refused")"

finish
