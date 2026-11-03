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

# --fixture writes a folder of modules, one record per line, that index.ts puts back together
# (#2097): a regenerated month then reads as changed rows, and no one file's diff outgrows a review.
RULES="$DIR/../payload/mods/area-check/hooks/rules.ts"
# Replays the fixture folder in $1 as the mod's replay test does, printing its summary and the replay's.
fixture_replays(){
  node --input-type=module -e "
    const { replay } = await import('$RULES')
    const { MEASURED, PATHS } = await import('$1/index.ts')
    const input = { ...MEASURED.input, sessions: MEASURED.input.sessions.map(s => ({ ...s, files: s.files.map(i => PATHS[i]) })) }
    console.log(JSON.stringify(MEASURED.summary) === JSON.stringify(replay(input).summary) ? 'same ' + JSON.stringify(MEASURED.summary) : 'DIFFERENT')
  " 2>&1
}
mkdir -p "$W/fx"; printf 'export const ROWS = []\n' > "$W/fx/sessions-9.ts"
out="$(PATH="$W/bin:$PATH" node "$TOOL" "$W/app" --repo dan/app --fixture "$W/fx" 2>&1)"; code=$?
r="$(fixture_replays "$W/fx")"
case "$code $r" in "0 same "*'"withHold":1'*) check "--fixture writes a folder whose index replays to the summary it was measured with" ok ;; *) check "--fixture writes a folder whose index replays to the summary it was measured with" "exit $code: $out / $r" ;; esac
[ ! -e "$W/fx/sessions-9.ts" ] && check "a fixture written again replaces the whole folder, so no part from an earlier month is left behind" ok || check "a fixture written again replaces the whole folder, so no part from an earlier month is left behind" "$(ls "$W/fx")"
n="$(grep -c '"day":' "$W/fx/sessions-1.ts" 2>/dev/null)"
[ "${n:-0}" -eq 4 ] && check "each session is a line of its own" ok || check "each session is a line of its own" "${n:-none} session lines in $(ls "$W/fx" 2>&1)"

out="$(PATH="$W/bin:$PATH" AREA_CHECK_FIXTURE_PART_BYTES=300 node "$TOOL" "$W/app" --repo dan/app --fixture "$W/fx2" 2>&1)"; code=$?
r="$(fixture_replays "$W/fx2")"
[ "$code" -eq 0 ] && [ -f "$W/fx2/sessions-2.ts" ] && case "$r" in "same "*) true ;; *) false ;; esac \
  && check "rows past a part's size go on into the next part, and the parts replay the same" ok \
  || check "rows past a part's size go on into the next part, and the parts replay the same" "exit $code: $out / $r / $(ls "$W/fx2" 2>&1)"

printf 'x\n' > "$W/notadir"
out="$(PATH="$W/bin:$PATH" node "$TOOL" "$W/app" --repo dan/app --fixture "$W/notadir/fx" 2>&1)"; code=$?
[ "$code" -eq 3 ] && case "$out" in *"could not write the fixture"*) true ;; *) false ;; esac \
  && check "a fixture that cannot be written exits 3, saying so" ok || check "a fixture that cannot be written exits 3, saying so" "exit $code: $out"

# The committed month itself is in that form: every part within the part size the writer uses, and no
# line long enough to be a whole table, which is what put #1509's branch past the review's limit.
REAL="$DIR/../payload/mods/area-check/tests/replay-fixture"
part="$(node --input-type=module -e "const m = await import('$DIR/area-check-fixture.ts'); console.log(m.PART_BYTES)" 2>&1)"
big="$(find "$REAL" -name '*.ts' -size +"${part:-0}"c 2>/dev/null)"
long="$(awk 'length($0) > 4096 { print FILENAME ":" FNR }' "$REAL"/*.ts 2>/dev/null)"
case "$part" in ''|*[!0-9]*) check "the committed fixture is parts of at most PART_BYTES with no line over 4096 bytes" "PART_BYTES unread: $part" ;;
  *) [ -f "$REAL/index.ts" ] && [ -z "$big" ] && [ -z "$long" ] \
       && check "the committed fixture is parts of at most PART_BYTES with no line over 4096 bytes" ok \
       || check "the committed fixture is parts of at most PART_BYTES with no line over 4096 bytes" "index: $(ls "$REAL/index.ts" 2>&1) big: $big long: $long" ;; esac

out="$(PATH="$W/bin:$PATH" GH_FAILS=1 node "$TOOL" "$W/app" --repo dan/app 2>&1)"; code=$?
[ "$code" -eq 3 ] && case "$out" in *"error connecting to api.github.com"*) true ;; *) false ;; esac && check "issues that cannot be read exit 3, saying why" ok || check "issues that cannot be read exit 3, saying why" "exit $code: $out"

out="$(node "$TOOL" "$W/app" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a replay with no --repo exits 2" ok || check "a replay with no --repo exits 2" "exit $code: $out"
out="$(node "$TOOL" "$W/app" --repo dan/app --days 1.5 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a window that is not a whole number of days exits 2" ok || check "a window that is not a whole number of days exits 2" "exit $code: $out"
out="$(PATH="$W/bin:$PATH" AREA_CHECK_FIXTURE_PART_BYTES=abc node "$TOOL" "$W/app" --repo dan/app --fixture "$W/fx3" 2>&1)"; code=$?
[ "$code" -eq 2 ] && [ ! -e "$W/fx3" ] && check "a part size that is not a whole number exits 2 and writes nothing (L50)" ok || check "a part size that is not a whole number exits 2 and writes nothing (L50)" "exit $code: $out"
out="$(PATH="$W/bin:$PATH" node "$TOOL" "$W/app" --repo dan/app --days 1 2>&1)"; code=$?
case "$out" in *"Replay of dan/app, 1 days"*) check "the window given is the window replayed" ok ;; *) check "the window given is the window replayed" "exit $code: $out" ;; esac

# The repository is public: no part of the committed fixture names a home directory or holds a session id,
# and the writer redacts what an issue body names, so a month measured again is redacted too (#2097).
hits="$(grep -lE '/Users/|/home/[a-z]|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|-Users-' "$REAL"/*.ts 2>/dev/null)"
[ -z "$hits" ] && check "no part of the committed fixture holds a home directory path or a session id" ok || check "no part of the committed fixture holds a home directory path or a session id" "parts: $(basename -a $hits)"
red="$(node --input-type=module -e "
const m = await import('$DIR/area-check-fixture.ts')
const u = ['', 'Users', 'someone', 'x.ts'].join('/')
const enc = ['private/tmp/claude-501', '-Users-someone-proj', '123e4567-e89b-12d3-a456-426614174000', 'scratchpad/f.ts'].join('/')
const out = [m.redactRef(u), m.redactRef(enc), m.redactRef('src/lib/a.ts'), m.redactRef('a.ts')]
console.log(out.join(' '))" 2>&1)"
case "$red" in "/Users/user/x.ts private/tmp/claude-501/project/session/scratchpad/f.ts src/lib/a.ts a.ts") check "the writer redacts personal segments of a ref and leaves repository paths alone" ok ;; *) check "the writer redacts personal segments of a ref and leaves repository paths alone" "$red" ;; esac

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
