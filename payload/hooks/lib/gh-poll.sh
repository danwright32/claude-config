#!/usr/bin/env bash
# gh-poll.sh: the one polling policy for every loop here that asks GitHub the same question until
# the answer changes (claude-config#1482). Sourced, never run.
#
# WHY. On 2026-10-22, from about 02:43 to 03:25 UTC, GitHub refused API calls from every Claude
# session on the shared account ("API rate limit exceeded for user ID 241846707"), even right after
# the hourly core allowance had reset to 4,989 remaining: its secondary (burst) limit. A PET session's
# agents were each running merge-when-ready.sh and gh pr view loops at once, and a Bidspoke agent had
# to retry one gh run rerun 8 times over 16 minutes. One session's loops spent what every session on
# the account shares. So every loop that polls GitHub follows the rules below, from this one file,
# never a copy of them (L370, L655):
#
#   1. THE WAIT GROWS while nothing changes (ghp_next_interval): each look that sees what the last one
#      saw doubles the wait, up to a ceiling, and any change starts it again at the base. A check run
#      takes minutes, and while it runs nothing a look reads moves, so a long quiet wait costs a few
#      looks instead of one a minute; and a check finishing is a change, so the rest are watched at the
#      base pace and a merge is never kept waiting by the quiet spell before it.
#   2. A RATE LIMIT ANSWER PAUSES THE SESSION (ghp_rate_limited, ghp_rate_pause): every loop in the
#      session stops asking until GitHub's own time has passed: Retry-After when GitHub names one, the
#      reset time of an allowance it reports as spent, and otherwise, for a burst limit that names no
#      time, a minute, twice as long each time it refuses again while it holds (GitHub's own advice for
#      a secondary limit), up to GH_POLL_RATE_MAX_SECONDS.
#   3. LOOKS ARE CAPPED PER SESSION (ghp_take): at most GH_POLL_PER_MINUTE looks in any minute, shared
#      by every loop in the session, counted in a small state file keyed on the session, so two helpers
#      run by two agents of one session share one budget. Four, the most agents a session runs at once,
#      each looking once a minute at the base pace; the cap bites only when loops look faster than that.
#
# The session is CLAUDE_CODE_SESSION_ID, which every Bash call a session or its agents make carries
# (agents carry their parent's, so a session's whole fleet shares the budget); a loop run by hand,
# outside any session, shares the key no-session with every other such loop.
#
# What it does not do: it decides nothing about what a loop is waiting for, and never sleeps. It
# answers how long to wait and why, and the loop waits through its own injected sleep and says so
# (L524), so a wait on a rate limit is said as one and never as a wait on checks.
#
# Settings, each also a test seam: GH_POLL_STATE_DIR (the state, ${CLAUDE_HOME:-~/.claude}/state/gh-poll),
# GH_POLL_PER_MINUTE (4), GH_POLL_RATE_FIRST_SECONDS (60), GH_POLL_RATE_MAX_SECONDS (960, sixteen
# minutes, five doublings), GH_POLL_LOCK_SLEEP (sleep, the command the state lock waits through).
# The interval's base and ceiling are the caller's (merge-when-ready.sh: MWR_POLL_SECONDS, 60, and
# MWR_POLL_MAX_SECONDS, 180); GHP_BASE_DEFAULT and GHP_MAX_DEFAULT are the defaults it reads. All are
# settings chosen on 2026-10-22, not measurements.

GHP_BASE_DEFAULT=60
GHP_MAX_DEFAULT=180

ghp__num(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
ghp__dir(){ printf '%s' "${GH_POLL_STATE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/gh-poll}"; }

# The session's key: its id kept to a file name's characters, or no-session.
ghp_session_key(){
  local id="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$id" ] || { printf 'no-session'; return 0; }
  printf '%s' "$id" | tr -c 'A-Za-z0-9_-' '_'
}

# The next wait: $1 = this wait, $2 = the base, $3 = the ceiling, $4 = 1 when the look saw a change.
ghp_next_interval(){
  local cur base max next
  base="$(ghp__num "$2" "$GHP_BASE_DEFAULT")"; [ "$base" -ge 1 ] || base=1
  max="$(ghp__num "$3" "$GHP_MAX_DEFAULT")"; [ "$max" -ge "$base" ] || max="$base"
  cur="$(ghp__num "$1" "$base")"
  if [ "${4:-0}" = 1 ]; then printf '%s' "$base"; return 0; fi
  next=$(( cur * 2 ))
  [ "$next" -ge "$base" ] || next="$base"
  [ "$next" -le "$max" ] || next="$max"
  printf '%s' "$next"
}

# Is this gh error text a rate limit answer? The one reading of it (L35), an allow list like
# merge-target.sh's mt_gh_transient, which reads a rate limit as NOT transient, since asking again in
# twenty seconds is exactly what a rate limit forbids. A 403 that names no rate limit is a permission
# answer and is not one.
ghp_rate_limited(){
  local t
  t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ -n "$t" ] || return 1
  case "$t" in
    *"rate limit exceeded"*|*"rate limit already exceeded"*|*"secondary rate limit"*|*"abuse detection"*) return 0 ;;
    *"http 429"*|*"too many requests"*) return 0 ;;
  esac
  return 1
}

# The session's state folder, made on first use; folders of sessions untouched for two days are
# swept then, so the state never grows past the sessions of the last two days.
ghp__session_dir(){
  local d s
  d="$(ghp__dir)"; s="$d/$(ghp_session_key)"
  if [ ! -d "$s" ]; then
    mkdir -p "$s" 2>/dev/null || return 1
    find "$d" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null
  fi
  printf '%s' "$s"
}

# The state lock, a folder holding its holder's pid. A lock whose holder is dead is broken, and one
# held past about five seconds is taken anyway: a look is never stopped for ever by a crashed loop.
# Every step of a hold is a few file reads and writes, so a live holder is gone well inside that.
ghp__lock(){   # $1 = the session folder
  local l="$1/.lock" i=0 pid
  while ! mkdir "$l" 2>/dev/null; do
    i=$((i + 1))
    pid="$(cat "$l/pid" 2>/dev/null)"
    if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } || [ "$i" -ge 100 ]; then
      rm -rf "$l"; continue
    fi
    "${GH_POLL_LOCK_SLEEP:-sleep}" 0.05
  done
  printf '%s' "$$" > "$l/pid"
}
ghp__unlock(){ rm -rf "$1/.lock"; }

# The pause, read into GHP_P_UNTIL, GHP_P_STRIKES and GHP_P_SAID. Its file is two lines:
# "<until epoch> <strikes>" and the sentence saying why.
ghp__read_pause(){   # $1 = the session folder
  local first
  GHP_P_UNTIL=0; GHP_P_STRIKES=0; GHP_P_SAID=""
  [ -f "$1/pause" ] || return 0
  first="$(sed -n 1p "$1/pause")"
  GHP_P_UNTIL="$(ghp__num "${first%% *}" 0)"
  GHP_P_STRIKES="$(ghp__num "${first#* }" 0)"
  GHP_P_SAID="$(sed -n 2p "$1/pause")"
}
ghp__write_pause(){   # $1 = the session folder, $2 = until, $3 = strikes, $4 = why
  printf '%s %s\n%s\n' "$2" "$3" "$4" > "$1/pause.$$" && mv "$1/pause.$$" "$1/pause"
}

# Take one look for the session at $1 (epoch seconds). Returns 0 when the look may be made, counted
# against the session's minute. Returns 1 when it must wait, setting GHP_WAIT (seconds), GHP_WHY
# (pause: a rate limit is in force, cap: the session's minute is full), GHP_SAID (why the pause was
# set) and GHP_CAP (the looks a minute allowed). A state that cannot be kept never holds a look back:
# the cap is a courtesy to other sessions, and refusing every look over a folder that cannot be
# written would stop a merge for nothing (it says so on standard error).
ghp_take(){
  local now="$1" s cap keep oldest n=0 t
  GHP_WAIT=0; GHP_WHY=""; GHP_SAID=""
  cap="$(ghp__num "${GH_POLL_PER_MINUTE:-}" 4)"; [ "$cap" -ge 1 ] || cap=1
  GHP_CAP="$cap"
  s="$(ghp__session_dir)" || { echo "gh-poll: the state folder $(ghp__dir) could not be made, so this look is not counted against the session's cap." >&2; return 0; }
  ghp__lock "$s"
  ghp__read_pause "$s"
  if [ "$GHP_P_UNTIL" -gt "$now" ]; then
    GHP_WAIT=$(( GHP_P_UNTIL - now )); GHP_WHY=pause; GHP_SAID="$GHP_P_SAID"
    ghp__unlock "$s"; return 1
  fi
  keep=""; oldest=""
  if [ -f "$s/polls" ]; then
    while IFS= read -r t; do
      case "$t" in ''|*[!0-9]*) continue ;; esac
      [ "$t" -gt $(( now - 60 )) ] || continue
      keep="$keep$t"$'\n'; n=$((n + 1))
      { [ -z "$oldest" ] || [ "$t" -lt "$oldest" ]; } && oldest="$t"
    done < "$s/polls"
  fi
  if [ "$n" -ge "$cap" ]; then
    printf '%s' "$keep" > "$s/polls.$$" && mv "$s/polls.$$" "$s/polls"
    GHP_WAIT=$(( oldest + 60 - now )); [ "$GHP_WAIT" -ge 1 ] || GHP_WAIT=1
    GHP_WHY=cap
    ghp__unlock "$s"; return 1
  fi
  printf '%s%s\n' "$keep" "$now" > "$s/polls.$$" && mv "$s/polls.$$" "$s/polls"
  ghp__unlock "$s"
  return 0
}

# A look was answered: the next rate limit starts again at the first wait.
ghp_answered(){
  local s
  s="$(ghp__dir)/$(ghp_session_key)"
  [ -f "$s/pause" ] || return 0
  ghp__lock "$s"
  ghp__read_pause "$s"
  [ "$GHP_P_STRIKES" -eq 0 ] || ghp__write_pause "$s" "$GHP_P_UNTIL" 0 "$GHP_P_SAID"
  ghp__unlock "$s"
}

# How long GitHub said to wait, from an answer that may carry headers (gh api -i): Retry-After in
# seconds, else the latest reset time of an allowance it reports as spent, either in the headers
# (X-RateLimit-Remaining: 0) or in a rate_limit body. Sets GHP_H_WAIT and GHP_H_SAID; returns 1 when
# it says neither.
ghp__said_wait(){   # $1 = the text, $2 = now
  local text="$1" now="$2" ra rem rst body spent
  GHP_H_WAIT=""; GHP_H_SAID=""
  ra="$(printf '%s\n' "$text" | tr -d '\r' | sed -nE 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]: *([0-9]+) *$/\1/p' | head -1)"
  if [ -n "$ra" ]; then
    GHP_H_WAIT="$ra"; [ "$GHP_H_WAIT" -ge 1 ] || GHP_H_WAIT=1
    GHP_H_SAID="GitHub said to wait ${ra}s (Retry-After)"
    return 0
  fi
  rem="$(printf '%s\n' "$text" | tr -d '\r' | sed -nE 's/^[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Mm][Aa][Ii][Nn][Ii][Nn][Gg]: *([0-9]+) *$/\1/p' | head -1)"
  rst="$(printf '%s\n' "$text" | tr -d '\r' | sed -nE 's/^[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Ss][Ee][Tt]: *([0-9]+) *$/\1/p' | head -1)"
  if [ "$rem" = 0 ] && [ -n "$rst" ] && [ "$rst" -gt "$now" ]; then
    GHP_H_WAIT=$(( rst - now )); GHP_H_SAID="its allowance is spent until GitHub's reset time"
    return 0
  fi
  # The body: whatever follows the first blank line when headers are there, else the whole text.
  body="$(printf '%s\n' "$text" | tr -d '\r' | awk 'h { print; next } /^HTTP\// { s = 1 } s && /^$/ { h = 1; next } !s { print }')"
  command -v jq >/dev/null 2>&1 || return 1
  spent="$(printf '%s' "$body" | jq -r --argjson now "$now" '
    [(.resources // {}) | to_entries[] | select((.key == "core" or .key == "graphql") and (.value.remaining == 0) and ((.value.reset // 0) > $now))]
    | if length == 0 then empty else "\(map(.value.reset) | max) \(map(.key) | join(" and "))" end' 2>/dev/null)"
  [ -n "$spent" ] || return 1
  GHP_H_WAIT=$(( ${spent%% *} - now )); GHP_H_SAID="its ${spent#* } allowance is spent until GitHub's reset time"
  return 0
}

# A rate limit answer: pause every loop in the session. $1 = GitHub's answer (gh's error text), $2 =
# now, $3 = a command printing `gh api -i rate_limit` for the account that was refused, asked only
# when the answer itself names no time (rate_limit costs no allowance, and refused, its own headers
# carry Retry-After). Sets GHP_WAIT and GHP_SAID; the pause never shortens one already in force.
ghp_rate_pause(){
  local text="$1" now="$2" probe="${3:-}" s first max strikes wait said until
  first="$(ghp__num "${GH_POLL_RATE_FIRST_SECONDS:-}" 60)"; [ "$first" -ge 1 ] || first=1
  max="$(ghp__num "${GH_POLL_RATE_MAX_SECONDS:-}" 960)"; [ "$max" -ge "$first" ] || max="$first"
  s="$(ghp__session_dir)" || s=""
  if [ -n "$s" ]; then ghp__lock "$s"; ghp__read_pause "$s"; else GHP_P_UNTIL=0; GHP_P_STRIKES=0; fi
  strikes=$(( GHP_P_STRIKES + 1 ))
  if ghp__said_wait "$text" "$now"; then
    wait="$GHP_H_WAIT"; said="$GHP_H_SAID"
  elif [ -n "$probe" ] && ghp__said_wait "$("$probe" 2>&1)" "$now"; then
    wait="$GHP_H_WAIT"; said="$GHP_H_SAID"
  else
    wait="$first"; local k=1
    while [ "$k" -lt "$strikes" ] && [ "$wait" -lt "$max" ]; do wait=$(( wait * 2 )); k=$((k + 1)); done
    [ "$wait" -le "$max" ] || wait="$max"
    said="a burst (secondary) limit that named no time, so ${wait}s, twice as long each time it refuses again"
  fi
  until=$(( now + wait ))
  [ "$GHP_P_UNTIL" -le "$until" ] || { until="$GHP_P_UNTIL"; said="${GHP_P_SAID:-$said}"; }
  if [ -n "$s" ]; then ghp__write_pause "$s" "$until" "$strikes" "$said"; ghp__unlock "$s"; fi
  GHP_WAIT=$(( until - now )); GHP_SAID="$said"
  return 0
}
