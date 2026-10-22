#!/usr/bin/env bash
# Tests for tools/area-check-replay.ts, the replay of a repository's commits through the area check's
# own rules (claude-config#1508). A throwaway repository with an origin, and a stand-in gh on PATH
# answering the open issue list, so the replay is judged on a history whose answer is known.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
if ! command -v node >/dev/null 2>&1; then
  echo "SUITE-UNMEASURED node is not installed, so the replay could not be run"
  exit 0
fi
pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
TOOL="$DIR/area-check-replay.ts"
W="$(mktemp -d "${TMPDIR:-/tmp}/area-check-replay.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT

# The origin and a clone of it, each commit dated today so it falls in the window.
git init -q --bare -b main "$W/origin.git"
git clone -q "$W/origin.git" "$W/app" 2>/dev/null
g(){ git -C "$W/app" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$W/app/src/lib" "$W/app/docs"
printf 'a\n' > "$W/app/src/lib/slack.ts"; printf 'b\n' > "$W/app/src/other.ts"; printf 'd\n' > "$W/app/docs/x.md"
g add -A && g commit -q -m "Start"
printf 'a\na\n' > "$W/app/src/lib/slack.ts"; g commit -q -am "Change slack (#41)"
printf 'b\nb\n' > "$W/app/src/other.ts"; printf 'd\nd\n' > "$W/app/docs/x.md"; g commit -q -am "Change other"
printf 'a\na\na\n' > "$W/app/src/lib/slack.ts"; printf 'n\n' > "$W/app/src/new.ts"; g add -A; g commit -q -m "Slack again, a new file"
g push -q origin main 2>/dev/null
git -C "$W/app" remote set-head origin main >/dev/null 2>&1

# gh, standing in: the open issues (41 is tech-debt and names slack.ts), or a failure when asked to.
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "issue list" ]; then
  [ -n "${GH_FAILS:-}" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
  echo '[{"number":41,"title":"Split slack","body":"src/lib/slack.ts does three jobs","labels":[{"name":"tech-debt"}]},{"number":7,"title":"Other","body":"nothing named","labels":[]}]'
  exit 0
fi
if [ "$1 $2" = "auth token" ]; then echo "tok"; exit 0; fi
echo "unexpected gh $*" >&2; exit 9
EOF
chmod +x "$W/bin/gh"

out="$(PATH="$W/bin:$PATH" node "$TOOL" "$W/app" --repo dan/app --names 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a replay exits 0" ok || check "a replay exits 0" "exit $code: $out"
case "$out" in *"Sessions (commits): 4; with a judged source or test file: 3."*) check "each commit is a session, and a commit with only docs or a new file judges nothing" ok ;; *) check "each commit is a session, and a commit with only docs or a new file judges nothing" "$out" ;; esac
case "$out" in *"Would hold at least once: 1 (33% of judged sessions)"*) check "the commit naming its own issue is not held by it, the later one is" ok ;; *) check "the commit naming its own issue is not held by it, the later one is" "$out" ;; esac
case "$out" in *"src/lib/slack.ts (issues)"*) check "--names lists the held file and why" ok ;; *) check "--names lists the held file and why" "$out" ;; esac
case "$out" in *"Open issues read today: 2, 1 with a structural label."*) check "the issues read are counted, structural ones apart" ok ;; *) check "the issues read are counted, structural ones apart" "$out" ;; esac

out="$(PATH="$W/bin:$PATH" node "$TOOL" "$W/app" --repo dan/app 2>&1)"
case "$out" in *"slack.ts"*) check "without --names no file is named" "$out" ;; *) check "without --names no file is named" ok ;; esac

PATH="$W/bin:$PATH" node "$TOOL" "$W/app" --repo dan/app --fixture "$W/fx.ts" >/dev/null 2>&1
grep -q '^export const MEASURED' "$W/fx.ts" 2>/dev/null && grep -q '"withHold":1' "$W/fx.ts" && check "--fixture writes the measured input with its summary" ok || check "--fixture writes the measured input with its summary" "$(head -c 300 "$W/fx.ts" 2>&1)"

out="$(PATH="$W/bin:$PATH" GH_FAILS=1 node "$TOOL" "$W/app" --repo dan/app 2>&1)"; code=$?
[ "$code" -eq 3 ] && case "$out" in *"error connecting to api.github.com"*) true ;; *) false ;; esac && check "issues that cannot be read exit 3, saying why" ok || check "issues that cannot be read exit 3, saying why" "exit $code: $out"

out="$(node "$TOOL" "$W/app" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a replay with no --repo exits 2" ok || check "a replay with no --repo exits 2" "exit $code: $out"
out="$(node "$TOOL" "$W/app" --repo dan/app --days 1.5 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a window that is not a whole number of days exits 2" ok || check "a window that is not a whole number of days exits 2" "exit $code: $out"
out="$(PATH="$W/bin:$PATH" node "$TOOL" "$W/app" --repo dan/app --days 1 2>&1)"; code=$?
case "$out" in *"Replay of dan/app, 1 days"*) check "the window given is the window replayed" ok ;; *) check "the window given is the window replayed" "exit $code: $out" ;; esac

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
