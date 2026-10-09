#!/bin/bash
# The premise mod-kit's write reader rests on for a route parameter path (claude-config#1010), measured
# on a real disk. It reads `src/app/booking/[SO_ID]/page.tsx` as that very file, never as a pattern,
# so the design round guard can place the write in its project. That is true only while the shells
# write the literal path: quoted always, and unquoted in bash, which leaves a pattern matching nothing
# as written. zsh refuses an unquoted one outright ("no matches found"), which writes nothing. The one
# place the literal reading is wrong, a folder named by one letter of the brackets holding the same
# file, is measured too, so the comment in writes.ts stays a measured claim (L82).
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
FX="$(mktemp -d "${TMPDIR:-/tmp}/route-bracket.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
PAGE='src/app/booking/[SO_ID]/page.tsx'
mkdir -p "$FX/src/app/booking/[SO_ID]"
printf 'old\n' > "$FX/$PAGE"

# 1. Quoted, every shell writes the literal file.
(cd "$FX" && bash -c "printf 'quoted\n' > '$PAGE'")
[ "$(cat "$FX/$PAGE")" = quoted ] && check "bash, quoted" ok || check "bash, quoted" "$(cat "$FX/$PAGE")"

# 2. Unquoted, bash writes the literal file too.
(cd "$FX" && bash -c "printf 'bare\n' > $PAGE")
[ "$(cat "$FX/$PAGE")" = bare ] && check "bash, unquoted" ok || check "bash, unquoted" "$(cat "$FX/$PAGE")"

# 3. zsh, where there is one (the Mac's login shell, which Claude Code's Bash tool runs): unquoted it
#    refuses and writes nothing; quoted it writes the literal file.
if command -v zsh >/dev/null 2>&1; then
  out="$(cd "$FX" && zsh -c "printf 'zsh\n' > $PAGE" 2>&1)"; code=$?
  { [ "$code" -ne 0 ] && [ "$(cat "$FX/$PAGE")" = bare ]; } && check "zsh, unquoted, refuses" ok || check "zsh, unquoted, refuses" "exit=$code out=$out now=$(cat "$FX/$PAGE")"
  (cd "$FX" && zsh -c "printf 'zsh quoted\n' > '$PAGE'")
  [ "$(cat "$FX/$PAGE")" = "zsh quoted" ] && check "zsh, quoted" ok || check "zsh, quoted" "$(cat "$FX/$PAGE")"
else
  echo "UNMEASURED: zsh is not installed here, so its reading was not measured"
fi

# 4. The exception, measured so it stays known: a one letter sibling holding the same file is where
#    an unquoted bash write goes instead. A route tree has no such folder; the reading is the same
#    project and the same kind of file either way, which is all the guard judges.
mkdir -p "$FX/src/app/booking/S"; printf 'sibling\n' > "$FX/src/app/booking/S/page.tsx"
(cd "$FX" && bash -c "printf 'moved\n' > $PAGE")
[ "$(cat "$FX/src/app/booking/S/page.tsx")" = moved ] && check "bash, unquoted, with a one letter sibling" ok \
  || check "bash, unquoted, with a one letter sibling" "sibling=$(cat "$FX/src/app/booking/S/page.tsx")"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
