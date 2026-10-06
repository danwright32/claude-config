#!/bin/bash
# Tests for payload/mods/status-bar/statusline.sh, the classic status line under the prompt that the
# status bar mod feeds (#610). The always-shown facts, settled with Dan on 2026-10-04: project,
# 5 hour limit, weekly limit, cache time left, model and effort, account and org, all grey but a
# limit share past its threshold (amber over 70% for 5h and over 85% for the week, red at 100%).
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

# 2. The line is grey but for a limit share past its threshold (Dan, 2026-10-05): the week's 91%
#    is amber, the number alone, and the line goes back to grey straight after it.
codes="$(printf '%s' "$raw" | grep -o $'\033\\[[0-9;]*m' | sort -u | tr '\n' ' ')"
[ "$codes" = $'\033[0m \033[33m \033[90m ' ] && check "the line is grey but for amber" ok || check "the line is grey but for amber" "$(printf '%q' "$codes")"
case "$raw" in *$'5h 68% (1h 52m) | week \033[33m91%\033[90m (4d 14h) |'*) check "only the week's share is amber, and grey resumes after it" ok ;;
  *) check "only the week's share is amber, and grey resumes after it" "$(printf '%q' "$raw")" ;; esac

# 2b. Each threshold is judged on the share as shown, rounded: over 70% (5h) and over 85% (week) is
#     amber, 100% is red, and at the threshold itself it stays grey.
shares(){   # $1 = 5h used  $2 = week used -> sets raw
  raw="$(printf '{"session_id":"s1","workspace":{"current_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":%s},"seven_day":{"used_percentage":%s}}}' "$REPO" "$1" "$2" \
    | HOME="$H" STATUSLINE_NOW="$NOW" bash "$SCRIPT" 2>&1)"
}
painted(){   # $1 = name  $2 = expected fragment
  case "$raw" in *"$2"*) check "$1" ok ;; *) check "$1" "$(printf '%q' "$raw")" ;; esac
}
shares 70.4 85.4
painted "5h at 70% and week at 85% stay grey" $'5h 70% | week 85% |'
shares 71 86
painted "5h at 71% is amber" $'5h \033[33m71%\033[90m |'
painted "week at 86% is amber" $'week \033[33m86%\033[90m |'
shares 99.6 100
painted "5h at 100% (rounded) is red" $'5h \033[31m100%\033[90m |'
painted "week at 100% is red" $'week \033[31m100%\033[90m |'
shares 80 50
painted "a week under its threshold stays grey beside an amber 5h" $'5h \033[33m80%\033[90m | week 50% |'

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

# 5. With no account recorded for the session (a facts file written before #815, or none yet),
#    the login file is read as it stands, on every refresh.
login Dan Pennie; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "a login changed elsewhere shows at the next refresh" ok ;; *) check "a login changed elsewhere shows at the next refresh" "$out" ;; esac
printf '{"oauthAccount":{"emailAddress":"dan@example.com","organizationName":"Pennie"}}\n' > "$H/.claude.json"; runit "$(input s1)"
case "$out" in *"| dan@example.com, Pennie") check "no display name falls back to the email" ok ;; *) check "no display name falls back to the email" "$out" ;; esac
printf '{}\n' > "$H/.claude.json"; runit "$(input s1)"
case "$out" in *"| Opus 5.5 (high)") check "no login (an API key) shows no account" ok ;; *) check "no login (an API key) shows no account" "$out" ;; esac
printf 'garbage' > "$H/.claude.json"; runit "$(input s1)"
case "$out" in *"| account unknown") check "an unreadable login file is account unknown, never blank" ok ;; *) check "an unreadable login file is account unknown, never blank" "$out" ;; esac

# 5a. The session's own account (#815, Dan 2026-10-05: "the status bar must always name the right
#     account for the session"). The mod records the account the session started on in its facts
#     file; the login file names whatever the Mac is logged in to NOW, which another session's
#     Switch changes. The bar names the session's, through a login change mid session.
sfacts(){   # $1 = session id  $2 = the account JSON, or null
  printf '{"v":1,"sessionId":"%s","cacheExpiresAt":null,"account":%s}\n' "$1" "$2" > "$H/.claude/state/status-bar/$1.json"
}
sfacts s9 '{"accountUuid":"acct-1","organizationUuid":"org-1","displayName":"Dan","emailAddress":"dan@example.com","organizationName":"Pennie"}'
login Dan Pennie; runit "$(input s9)"
case "$out" in *"| Dan, Pennie") check "the session's own account is named" ok ;; *) check "the session's own account is named" "$out" ;; esac
login Dan Personal; runit "$(input s9)"
case "$out" in *"| Dan, Pennie") check "and still named after the Mac logs in to another account mid session" ok ;; *) check "and still named after the Mac logs in to another account mid session" "$out" ;; esac
printf 'garbage' > "$H/.claude.json"; runit "$(input s9)"
case "$out" in *"| Dan, Pennie") check "and the login file is not read at all while the session's account is known" ok ;; *) check "and the login file is not read at all while the session's account is known" "$out" ;; esac
sfacts s10 null; login Dan Personal; runit "$(input s10)"
case "$out" in *"| account unknown") check "an account the session could not read at its start is unknown, never the Mac's current one" ok ;; *) check "an account the session could not read at its start is unknown, never the Mac's current one" "$out" ;; esac
sfacts s11 '{}'; runit "$(input s11)"
case "$out" in *"| Opus 5.5 (high)") check "a session started with no claude.ai login shows no account" ok ;; *) check "a session started with no claude.ai login shows no account" "$out" ;; esac
# The nickname follows the session's account too, keyed by its ids.
mkdir -p "$H/.claude/mods"; printf '{"v":1,"names":{"58f60981898d32e8":"Work"}}\n' > "$H/.claude/mods/account-room-nicknames.json"
runit "$(input s9)"
case "$out" in *"| Opus 5.5 (high) | Work") check "the session's account takes its nickname" ok ;; *) check "the session's account takes its nickname" "$out" ;; esac
rm -f "$H/.claude/mods/account-room-nicknames.json"

# 5b. A nickname set in the account room (/accounts rename) replaces the name and org, as Dan
#     expected in the live check on 2026-10-05. The account room keys it by the first 16 hex digits
#     of SHA-256 over "<account id>:<org id>"; 58f60981898d32e8 is that for acct-1 and org-1,
#     computed once with Python's hashlib rather than by the script under test (L70).
NICK="$H/.claude/mods/account-room-nicknames.json"; mkdir -p "$H/.claude/mods"
printf '{"oauthAccount":{"accountUuid":"acct-1","organizationUuid":"org-1","displayName":"Dan","emailAddress":"dan@example.com","organizationName":"Pennie"}}\n' > "$H/.claude.json"
printf '{"v":1,"names":{"58f60981898d32e8":"Work"}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Opus 5.5 (high) | Work") check "a nickname replaces the name and org" ok ;; *) check "a nickname replaces the name and org" "$out" ;; esac
printf '{"v":1,"names":{"58f60981898d32e8":null}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "a skipped nickname (null) keeps the name and org" ok ;; *) check "a skipped nickname (null) keeps the name and org" "$out" ;; esac
printf '{"v":1,"names":{"0000000000000000":"Other"}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "another account's nickname is not used" ok ;; *) check "another account's nickname is not used" "$out" ;; esac
printf 'not json' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "an unreadable nicknames file keeps the name and org" ok ;; *) check "an unreadable nicknames file keeps the name and org" "$out" ;; esac
printf '{"v":1,"names":{"58f60981898d32e8":"Work\\u001b[31m"}}\n' > "$NICK"; runit "$(input s1)"
case "$raw" in *$'\033[31m'*) check "a nickname cannot colour the line" "$(printf '%q' "$raw")" ;; *) check "a nickname cannot colour the line" ok ;; esac
printf '{"v":1,"names":{"58f60981898d32e8":"  \\t "}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "a nickname of only spaces keeps the name and org, never a blank" ok ;; *) check "a nickname of only spaces keeps the name and org, never a blank" "$out" ;; esac
printf '{"v":1,"names":{"58f60981898d32e8":"  Work  "}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Opus 5.5 (high) | Work") check "a nickname is trimmed" ok ;; *) check "a nickname is trimmed" "$out" ;; esac
printf '{"v":1,"names":{"58f60981898d32e8":"\\u0001 \\u0001"}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "spaces between control bytes keep the name and org" ok ;; *) check "spaces between control bytes keep the name and org" "$out" ;; esac
printf '{"v":1,"names":{"58f60981898d32e8":"Work \\u0001"}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Opus 5.5 (high) | Work") check "a control byte after a space is trimmed with it" ok ;; *) check "a control byte after a space is trimmed with it" "$out" ;; esac
# Version 2 (#747): each entry is {"name", "at"}, so a merge can tell a later name from an earlier one.
printf '{\n  "v": 2,\n  "names": {\n    "58f60981898d32e8": {"name":"Work","at":1759671234567}\n  }\n}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Opus 5.5 (high) | Work") check "a version 2 nickname replaces the name and org" ok ;; *) check "a version 2 nickname replaces the name and org" "$out" ;; esac
printf '{"v":2,"names":{"58f60981898d32e8":{"name":null,"at":1759671234567}}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Dan, Pennie") check "a version 2 skip keeps the name and org" ok ;; *) check "a version 2 skip keeps the name and org" "$out" ;; esac
printf '{"v":2,"names":{"58f60981898d32e8":{"name":"  Work  ","at":1759671234567}}}\n' > "$NICK"; runit "$(input s1)"
case "$out" in *"| Opus 5.5 (high) | Work") check "a version 2 nickname is trimmed too" ok ;; *) check "a version 2 nickname is trimmed too" "$out" ;; esac
printf '{"v":1,"names":{"58f60981898d32e8":"Caf\u00e9 \u5bb6"}}\n' > "$NICK"
raw="$(printf '%s' "$(input s1)" | HOME="$H" STATUSLINE_NOW="$NOW" LC_ALL=C LANG=C bash "$SCRIPT" 2>&1)"
out="$(printf '%s' "$raw" | sed $'s/\033\\[[0-9;]*m//g')"
case "$out" in *"| Café 家") check "a non ASCII nickname survives a C locale" ok ;; *) check "a non ASCII nickname survives a C locale" "$out" ;; esac
rm -f "$NICK"
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

# 9. The Supabase project (#697): kept by #610's spec ("Kept: repo, Supabase project") and never
#    dropped, so where a project has one it sits beside the repository, labelled as the old status
#    line labelled it. Read as the old line read it: SUPABASE_PROJECT_NAME, else the subdomain of
#    SUPABASE_URL, from the first .env found in the folder or the three above it. Nothing else in
#    the .env is ever read, and a project with none shows none (case 1's exact line).
printf 'OTHER=1\nSUPABASE_URL=https://abcdefghijklmnop.supabase.co\nSUPABASE_SERVICE_ROLE_KEY=never-shown\n' > "$REPO/.env"
runit "$(input s1)"
[ "$out" = "claude-config | SB abcdefghijklmnop | 5h 68% (1h 52m) | week 91% (4d 14h) | cache 41m | Opus 5.5 (high) | Dan, Personal" ] \
  && check "a Supabase project sits beside the repository" ok || check "a Supabase project sits beside the repository" "$out"
case "$out" in *never-shown*) check "nothing else in the .env is shown" "$out" ;; *) check "nothing else in the .env is shown" ok ;; esac
printf 'SUPABASE_URL="https://abcdefghijklmnop.supabase.co"\r\nSUPABASE_PROJECT_NAME="bidspoke-prod"\r\n' > "$REPO/.env"
runit "$(input s1)"
case "$out" in "claude-config | SB bidspoke-prod | 5h"*) check "a named project wins, quotes and Windows line ends removed" ok ;; *) check "a named project wins, quotes and Windows line ends removed" "$out" ;; esac
rm -f "$REPO/.env"
mkdir -p "$REPO/app/src"; printf 'SUPABASE_URL=https://parentref.supabase.co\n' > "$REPO/.env"
runit "$(input s1 "$REPO/app/src")"
case "$out" in *" | SB parentref | "*) check "a .env two folders up is found" ok ;; *) check "a .env two folders up is found" "$out" ;; esac
printf 'NODE_ENV=dev\n' > "$REPO/app/.env"
runit "$(input s1 "$REPO/app/src")"
case "$out" in *"SB "*) check "the first .env found decides, even with no Supabase in it" "$out" ;; *) check "the first .env found decides, even with no Supabase in it" ok ;; esac
rm -rf "$REPO/app" "$REPO/.env"
printf 'SUPABASE_URL=http://127.0.0.1:54321\n' > "$REPO/.env"
runit "$(input s1)"
case "$out" in *" | SB 127.0.0.1:54321 | "*) check "a local Supabase is named by its address" ok ;; *) check "a local Supabase is named by its address" "$out" ;; esac
rm -f "$REPO/.env"

# 8. Input that is not JSON is said, not drawn as an empty line.
runit 'nope'
case "$out" in *"status line"*"could not read"*) check "unreadable input is named" ok ;; *) check "unreadable input is named" "exit=$code out=$out" ;; esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
