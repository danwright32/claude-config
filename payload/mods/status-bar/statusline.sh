#!/bin/bash
# statusline.sh: the classic status line under the prompt, fed by the status bar mod (#610).
#
# Claude Code runs it with the session's JSON on stdin, as the statusLine setting's command:
#   "statusLine": { "type": "command", "command": "bash ~/.claude/mods/status-bar/statusline.sh", "refreshInterval": 30 }
#
# The always-shown facts, settled with Dan on 2026-10-04 (docs/mods-design.md "Status bar (#610)"),
# in this order, all grey: project (with its Supabase project where it has one, #697), 5 hour
# limit, weekly limit, cache time left, model and effort, account and org. What needs a look is not
# here: the mod draws it in amber in the band above the prompt, since a mod's own status line is
# drawn as a warning notice and cannot be grey.
#
# Where each fact comes from:
#   limits, model, effort   the JSON on stdin, as Claude Code has them
#   project                 the repository's GitHub name, else its folder, else the folder itself
#   Supabase project        SUPABASE_PROJECT_NAME or SUPABASE_URL in the nearest .env, nothing else
#   cache time left         the mod's facts file for this session, the one thing only the mod knows
#   account and org         ~/.claude.json, read again on every refresh, so a login changed in one
#                           window shows in all of them (picker, 2026-10-04); the account room's
#                           nickname for it, from ~/.claude/mods/account-room-nicknames.json, in
#                           their place when one is set (2026-10-05)
# A fact that cannot be read says so ("cache unknown", "account unknown"), never a blank.
#
# STATUSLINE_NOW (seconds since the epoch) stands in for the clock in tests.
GREY=$'\033[90m'
RESET=$'\033[0m'
say(){ printf '%s%s%s' "$GREY" "$1" "$RESET"; }

if ! command -v jq >/dev/null 2>&1; then
  say "status line: could not read the session, because jq is not installed"
  exit 0
fi

input="$(cat)"
# One jq pass, one field per line, so a value with a space in it stays whole.
fields="$(printf '%s' "$input" | jq -r '
  (.session_id // ""),
  (.workspace.current_dir // .cwd // ""),
  ((.model.display_name // "") | sub(" \\([^)]*context\\)"; "")),
  (.effort.level // ""),
  (.rate_limits.five_hour.used_percentage // "" | tostring),
  (.rate_limits.five_hour.resets_at // "" | tostring),
  (.rate_limits.seven_day.used_percentage // "" | tostring),
  (.rate_limits.seven_day.resets_at // "" | tostring)
' 2>/dev/null)"
if [ -z "$fields" ]; then
  say "status line: could not read the session Claude Code sent"
  exit 0
fi
{
  IFS= read -r sid
  IFS= read -r cwd
  IFS= read -r model
  IFS= read -r effort
  IFS= read -r five_pct
  IFS= read -r five_reset
  IFS= read -r week_pct
  IFS= read -r week_reset
} <<EOF
$fields
EOF
now="${STATUSLINE_NOW:-$(date +%s)}"

# 2h 05m, or 4d 14h past a day: the old status line's form, which the design rounds drew.
left(){
  local s=$1
  if [ "$s" -ge 86400 ]; then printf '%dd %dh' $((s / 86400)) $(((s % 86400) / 3600))
  else printf '%dh %02dm' $((s / 3600)) $(((s % 3600) / 60)); fi
}
limit(){   # $1 = label  $2 = percent  $3 = reset (epoch seconds)
  [ -n "$2" ] || return 0
  local pct reset
  pct="$(printf '%.0f' "$2" 2>/dev/null)" || return 0
  reset="${3%%.*}"
  if [ -n "$reset" ] && [ "$reset" -gt "$now" ] 2>/dev/null; then
    parts+=("$1 $pct% ($(left $((reset - now))))")
  else
    parts+=("$1 $pct%")
  fi
}

parts=()

project=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  url="$(git -C "$cwd" --no-optional-locks remote get-url origin 2>/dev/null)"
  if [ -n "$url" ]; then
    project="${url%.git}"; project="${project##*/}"; project="${project##*:}"
  else
    top="$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)"
    project="$(basename "${top:-$cwd}")"
  fi
fi
[ -n "$project" ] && parts+=("$project")

# The Supabase project, beside the repository, where the project has one (#697): kept by #610's spec
# and read as the old status line read it. SUPABASE_PROJECT_NAME, else the subdomain of SUPABASE_URL
# (a local one by its address), from the first .env found in the folder or the three above it; the
# first .env decides even with no Supabase in it. Only those two names are ever read from the file.
envval(){   # $1 = file  $2 = name -> the value, quotes, spaces and a Windows line end removed
  local v
  v="$(grep -E "^(export[[:space:]]+)?$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
  printf '%s' "$v" | tr -cd '[:print:]'
}
supabase=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  d="$cwd"
  for _ in 1 2 3 4; do
    if [ -f "$d/.env" ]; then
      sb_url="$(envval "$d/.env" SUPABASE_URL)"
      if [ -n "$sb_url" ]; then
        supabase="$(envval "$d/.env" SUPABASE_PROJECT_NAME)"
        if [ -z "$supabase" ]; then
          host="${sb_url#*://}"; host="${host%%/*}"
          case "$host" in *.supabase.co) supabase="${host%%.*}" ;; *) supabase="$host" ;; esac
        fi
      fi
      break
    fi
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
fi
[ -n "$supabase" ] && parts+=("SB $supabase")

limit 5h "$five_pct" "$five_reset"
limit week "$week_pct" "$week_reset"

# The cache: an id that is not one is never made into a path.
cache="unknown"
case "$sid" in
  ''|*[!A-Za-z0-9-]*) ;;
  *)
    f="$HOME/.claude/state/status-bar/$sid.json"
    if [ -f "$f" ]; then
      exp="$(jq -r 'if .v == 1 then (.cacheExpiresAt // "none" | tostring) else empty end' "$f" 2>/dev/null)"
      case "$exp" in
        none) cache="" ;;
        ''|*[!0-9]*) ;;
        *)
          secs=$((exp / 1000 - now))
          if [ "$secs" -le 0 ]; then cache="cold"
          elif [ "$secs" -lt 60 ]; then cache="<1m"
          else cache="$((secs / 60))m"; fi
          ;;
      esac
    fi
    ;;
esac
[ -n "$cache" ] && parts+=("cache $cache")

if [ -n "$model" ]; then
  if [ -n "$effort" ]; then parts+=("$model ($effort)"); else parts+=("$model"); fi
fi

login="$HOME/.claude.json"
if [ -f "$login" ]; then
  if account="$(jq -r '.oauthAccount // empty | [(.displayName // .emailAddress // empty), (.organizationName // empty)] | map(select(. != "")) | join(", ")' "$login" 2>/dev/null)"; then
    # A nickname given in the account room (/accounts rename) replaces the name and org (Dan, live
    # check 2026-10-05). It is keyed as the account room keys it: the first 16 hex digits of
    # SHA-256 over "<account id>:<org id>". No nickname, a skipped one (null) or a file that cannot
    # be read leaves the name and org as they are.
    ids="$(jq -r '.oauthAccount // empty | select(.accountUuid and .organizationUuid) | "\(.accountUuid):\(.organizationUuid)"' "$login" 2>/dev/null)"
    nicks="$HOME/.claude/mods/account-room-nicknames.json"
    if [ -n "$ids" ] && [ -f "$nicks" ] && command -v shasum >/dev/null 2>&1; then
      key="$(printf '%s' "$ids" | shasum -a 256 | cut -c1-16)"
      # Control bytes only are removed, which reads the same in every locale; a printable class
      # would drop every byte of "Café" under the C locale a status line may run in.
      # Tabs and newlines become spaces before control bytes go, then the ends are trimmed, so a
      # nickname of only spaces leaves the name and org rather than a blank segment.
      nick="$(jq -r --arg k "$key" '.names[$k] // empty | strings | gsub("[\t\n\r]"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "")' "$nicks" 2>/dev/null | head -1 | LC_ALL=C tr -d '\000-\037\177')"
      [ -n "$nick" ] && account="$nick"
    fi
    [ -n "$account" ] && parts+=("$account")
  else
    parts+=("account unknown")
  fi
fi

line=""
for p in "${parts[@]}"; do
  if [ -z "$line" ]; then line="$p"; else line="$line | $p"; fi
done
say "$line"
