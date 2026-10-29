#!/usr/bin/env bash
# The class guard for claude-config#1885: under a UTF-8 locale bash's =~ and the system grep stop
# matching at a byte that is not UTF-8, so a hook matching its raw payload that way reads every word
# after such a byte as absent. Each hook that matches its raw payload does it through payload_match
# (session locale, then C), or asks grep in the C locale as well. This scan fails on the next hook
# that writes [[ $payload =~ ... ]] or [[ $input =~ ... ]] directly, or greps a here string of the
# payload with no C locale grep on the same line.
#
# What it cannot see: a match over the payload once it has been handed to a function as $1 (as
# pc_call_id in lib/push-changes.sh takes it), or held under another name. The gates' matches on the
# command AFTER jq has parsed the payload need none of this, since jq writes a bad byte as U+FFFD.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

RAW_RE='\[\[[[:space:]]*"?\$\{?(payload|input)\}?"?[[:space:]]*=~'
GREP_RE='grep[^|]*<<<[[:space:]]*"?\$\{?(payload|input)\}?'
raw_matches(){ # raw_matches <file>... -> file:line of every raw match of a payload in the session locale
  grep -n -E "$RAW_RE" "$@" /dev/null 2>/dev/null
  grep -n -E "$GREP_RE" "$@" /dev/null 2>/dev/null | grep -v 'LC_ALL=C grep'
}

# Every hook and library, never a suite (a suite feeds the hooks such payloads on purpose).
files=()
for f in "$DIR"/*.sh "$DIR"/lib/*.sh; do
  case "${f##*/}" in test-*) continue ;; esac
  files+=("$f")
done
[ "${#files[@]}" -gt 20 ] && ok || bad "the scan found only ${#files[@]} hook files, so it is not looking where the hooks are"
found="$(raw_matches "${files[@]}")"
if [ -z "$found" ]; then ok; else bad "a hook matches its raw payload in the session locale, where a byte that is not UTF-8 hides every word after it (claude-config#1885); use payload_match, or ask grep under LC_ALL=C too:"; echo "$found"; fi

# The scan is seen to fire (L1): the lines the hooks held before #1885 are each found, and the fixed
# forms are not.
OLD="$WORK/old-hook.sh"
cat > "$OLD" <<'EOF'
if [[ $payload =~ (^|[^A-Za-z0-9_.-])(git|gh|rtk)([^A-Za-z0-9_.-]|$) ]]; then :; fi
  *) [[ "$payload" =~ $fast_re ]] || exit 0 ;;
if [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then :; fi
  grep -Eiq 'DELETE.*refs/heads' <<< "$payload"
EOF
n="$(raw_matches "$OLD" | grep -c .)"
[ "$n" = 4 ] && ok || bad "the scan found $n of the 4 raw matches the hooks held before #1885"
NEW="$WORK/new-hook.sh"
cat > "$NEW" <<'EOF'
if payload_match "$payload" "$GUARDED_WORD"; then :; fi
  grep -Eiq "$re" <<< "$payload" || LC_ALL=C grep -Eiq "$re" <<< "$payload"
EOF
[ -z "$(raw_matches "$NEW")" ] && ok || bad "the scan flags the fixed forms: $(raw_matches "$NEW")"

# The helper itself: a byte that is not UTF-8 in front of a word does not hide it, and a Unicode
# space the session's locale counts as [[:space:]] still counts, so switching locale only adds.
eval "$(grep -h -m1 '^payload_match()' "$DIR/check-wrapped-commands.sh")"
same=1
for f in "${files[@]}"; do
  line="$(grep -h -m1 '^payload_match()' "$f")" || continue
  [ "$line" = "$(grep -h -m1 '^payload_match()' "$DIR/check-wrapped-commands.sh")" ] || { same=0; echo "  $f defines payload_match differently: $line"; }
done
[ "$same" = 1 ] && ok || bad "every hook's payload_match is the same one line"
probe(){ (export LC_ALL=en_US.UTF-8; payload_match "$1" "$2" && echo yes || echo no); }
[ "$(probe "x$(printf '\377') git" '(^|[^A-Za-z0-9_])git')" = yes ] && ok || bad "payload_match misses a word behind a byte that is not UTF-8"
[ "$(probe "x$(printf '\302\240')-d" '[[:space:]]-d')" = yes ] && ok || bad "payload_match lost the session locale's reading of a Unicode space"
[ "$(probe "x git" 'svn')" = no ] && ok || bad "payload_match matched what is not there"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
