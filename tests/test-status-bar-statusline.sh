#!/bin/bash
# Tests for payload/mods/status-bar/statusline.sh, the classic status line under the prompt that the
# status bar mod feeds (#610). The always-shown facts, settled with Dan on 2026-10-04: project,
# 5 hour limit, weekly limit, cache time left, model and effort, account and org, all grey.
#
# Every input is a seam this suite sets: HOME (the login file and the mod's facts), the JSON on
# stdin, and STATUSLINE_NOW for the clock (L524). git runs for real, in a throwaway repo.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SCRIPT="$ROOT/payload/mods/status-bar/statusline.sh"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-statusline.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

H="$TMPROOT/home"; mkdir -p "$H/.claude/state/status-bar"
REPO="$TMPROOT/work/agent-worktree"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:danwright32/claude-config.git
NOW=2000000000
login(){   # $1 = display name  $2 = org
  printf '{"oauthAccount":{"displayName":"%s","emailAddress":"dan@example.com","organizationName":"%s"}}\n' "$1" "$2" > "$H/.claude.json"
}
facts(){   # $1 = session id  $2 = cacheExpiresAt in ms, or null
  printf '{"v":1,"sessionId":"%s","cacheExpiresAt":%s}\n' "$1" "$2" > "$H/.claude/state/status-bar/$1.json"
}
input(){   # $1 = session id  [$2 = cwd]
  cat <<JSON
{"session_id":"$1","workspace":{"current_dir":"${2:-$REPO}"},"model":{"display_name":"Opus 5.5 (1M context)"},"effort":{"level":"high"},
 "rate_limits":{"five_hour":{"used_percentage":67.6,"resets_at":$((NOW + 6720))},"seven_day":{"used_percentage":91.2,"resets_at":$((NOW + 4*86400 + 14*3600 + 60))}}}
JSON
}
runit(){   # stdin from $1 -> sets out (colour codes removed) and raw
  raw="$(printf '%s' "$1" | HOME="$H" STATUSLINE_NOW="$NOW" bash "$SCRIPT" 2>&1)"; code=$?
  out="$(printf '%s' "$raw" | sed $'s/\033\\[[0-9;]*m//g')"
}

# 1. Every always-shown fact, in the settled order, the project named by its GitHub repository even
#    in a worktree folder named something else.
login Dan Personal; facts s1 $(( (NOW + 41*60 + 30) * 1000 ))
runit "$(input s1)"
[ "$out" = "claude-config | 5h 68% (1h 52m) | week 91% (4d 14h) | cache 41m | Opus 5.5 (high) | Dan, Personal" ] \
  && check "every fact in the settled order" ok || check "every fact in the settled order" "exit=$code out=$out"
[ "$code" -eq 0 ] && check "and it exits 0" ok || check "and it exits 0" "exit=$code"

# 2. The whole line is grey: one grey code at the start, a reset at the end, no other colour.
codes="$(printf '%s' "$raw" | grep -o $'\033\\[[0-9;]*m' | sort -u | tr '\n' ' ')"
[ "$codes" = $'\033[0m \033[90m ' ] && check "the line is all grey" ok || check "the line is all grey" "$(printf '%q' "$codes")"

# 3. The cache: cold once the hour is up, under a minute at the end, unknown with no facts file (the
#    mod is not running, which is not the same as no cache yet), absent before the first turn.
facts s2 $(( (NOW - 5) * 1000 )); runit "$(input s2)"
case "$out" in *" | cache cold | "*) check "a cache past its hour is cold" ok ;; *) check "a cache past its hour is cold" "$out" ;; esac
facts s3 $(( (NOW + 20) * 1000 )); runit "$(input s3)"
case "$out" in *" | cache <1m | "*) check "under a minute left reads <1m" ok ;; *) check "under a minute left reads <1m" "$out" ;; esac
runit "$(input s-missing)"
case "$out" in *" | cache unknown | "*) check "no facts file is cache unknown" ok ;; *) check "no facts file is cache unknown" "$out" ;; esac
facts s4 null; runit "$(input s4)"
case "$out" in *cache*) check "before the first turn there is no cache to show" "$out" ;; *) check "before the first turn there is no cache to show" ok ;; esac
printf 'not json' > "$H/.claude/state/status-bar/s5.json"; runit "$(input s5)"
case "$out" in *" | cache unknown | "*) check "an unreadable facts file is cache unknown" ok ;; *) check "an unreadable facts file is cache unknown" "$out" ;; esac

# 4. A session id that is not one is never turned into a path.
mkdir -p "$H/.claude/state/x"; facts ../x/evil $(( (NOW + 600) * 1000 )) 2>/dev/null
runit "$(input '../x/evil')"
case "$out" in *" | cache unknown | "*) check "a session id with a path in it is not read" ok ;; *) check "a session id with a path in it is not read" "$out" ;; esac

# 5. The account is whatever the login file names now, read again on every refresh (picker, Dan
#    switches the login in one window expecting every window to follow).
login Dan Pennie; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "a login changed elsewhere shows at the next refresh" ok ;; *) check "a login changed elsewhere shows at the next refresh" "$out" ;; esac
printf '{"oauthAccount":{"emailAddress":"dan@example.com","organizationName":"Pennie"}}\n' > "$H/.claude.json"; runit "$(input s1)"
case "$out" in *"| dan@example.com, Pennie") check "no display name falls back to the email" ok ;; *) check "no display name falls back to the email" "$out" ;; esac
printf '{}\n' > "$H/.claude.json"; runit "$(input s1)"
case "$out" in *"| Opus 5.5 (high)") check "no login (an API key) shows no account" ok ;; *) check "no login (an API key) shows no account" "$out" ;; esac
printf 'garbage' > "$H/.claude.json"; runit "$(input s1)"
case "$out" in *"| account unknown") check "an unreadable login file is account unknown, never blank" ok ;; *) check "an unreadable login file is account unknown, never blank" "$out" ;; esac
login Dan Personal

# 6. Limits: a reset already past shows the share alone; no limits at all (an API key) shows none.
past="$(input s1 | sed "s/\"resets_at\":$((NOW + 6720))/\"resets_at\":$((NOW - 1))/")"
runit "$past"
case "$out" in *"| 5h 68% | week"*) check "a past reset shows the share alone" ok ;; *) check "a past reset shows the share alone" "$out" ;; esac
runit '{"session_id":"s1","workspace":{"current_dir":"'"$REPO"'"},"model":{"display_name":"Sonnet 5"}}'
[ "$out" = "claude-config | cache 41m | Sonnet 5 | Dan, Personal" ] && check "no limits and no effort: only what is known" ok \
  || check "no limits and no effort: only what is known" "$out"

# 7. A folder with no remote is named by its repository folder, and outside a repository by itself.
LOCAL="$TMPROOT/work/scratch-repo"; mkdir -p "$LOCAL/sub"; git -C "$LOCAL" init -q
runit "$(input s1 "$LOCAL/sub")"
case "$out" in "scratch-repo | "*) check "no remote: the repository folder" ok ;; *) check "no remote: the repository folder" "$out" ;; esac
PLAIN="$TMPROOT/plain-folder"; mkdir -p "$PLAIN"
runit "$(input s1 "$PLAIN")"
case "$out" in "plain-folder | "*) check "not a repository: the folder itself" ok ;; *) check "not a repository: the folder itself" "$out" ;; esac

# 8. Input that is not JSON is said, not drawn as an empty line.
runit 'nope'
case "$out" in *"status line"*"could not read"*) check "unreadable input is named" ok ;; *) check "unreadable input is named" "exit=$code out=$out" ;; esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
