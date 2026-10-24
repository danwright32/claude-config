#!/usr/bin/env bash
#
# load-window.sh: the record of deliberate load windows on this Mac, and the one sentence that names
# one (claude-config#1618).
#
# WHY. On 2026-10-23 the load average reached 342 while four builders ran full suites and one ran a
# deliberate load reproduction, as #1541 had taught builders to do. In that window
# merge-when-ready.sh 1606 stopped five times on GitHub reads (HTTP 401, and
# require-verification-run.sh spending its 15 second read budget), and nothing it said named the load
# somebody had added on purpose. So a deliberate window is now run by ONE helper,
# tools/load-window.sh, which writes its start and end here, and the merge helper and the suite pile
# notice read it back and name it beside what they say (L356: what else was running goes beside the
# failure, not into a log nobody reads with it).
#
# THE FORMAT lives only here, so the writer and both readers cannot drift (L94, L370). One line per
# event, tab separated, appended:
#   start <id> <start epoch> <deadline epoch> <pid> <busy workers> <process launching workers> <label>
#   end   <id> <end epoch> <how it ended>
# A start with no end is judged by its deadline alone, never by its pid: the helper's workers end
# themselves at the deadline even when the helper itself is killed without a chance to write its end,
# so the load lasts until the deadline whatever happened to the helper.
#
# Under this Mac's own state, never synced: ${CLAUDE_HOME:-$HOME/.claude}/state/load-window, or
# LOAD_WINDOW_DIR. CLAUDE_HOME is honoured so a suite pointing it at a fixture home never reads this
# Mac's real windows.
#
# Sourced, never executed. Nothing here reads a clock: every function is handed the time (L524).

load_window_dir(){ printf '%s' "${LOAD_WINDOW_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/load-window}"; }
load_window_record(){ printf '%s/windows.tsv' "$(load_window_dir)"; }

# A time of day in US Eastern, labelled, the way every time is given to Dan. BSD date first, then GNU.
load_window_et(){   # $1 = epoch seconds
  local t
  t="$(TZ=America/New_York date -r "$1" '+%H:%M:%S' 2>/dev/null)" \
    || t="$(TZ=America/New_York date -d "@$1" '+%H:%M:%S' 2>/dev/null)" || t=""
  if [ -n "$t" ]; then printf '%s ET' "$t"; else printf 'epoch %s' "$1"; fi
}

# Appends one start line. Returns non zero when it could not be written, which the helper treats as a
# refusal to start: a window nobody can see is the thing this record exists to prevent.
load_window_begin(){   # id start deadline pid workers spawners label
  local d label
  d="$(load_window_dir)"
  label="$(printf '%s' "$7" | tr '\t\n' '  ' | cut -c1-120)"
  mkdir -p "$d" 2>/dev/null || return 1
  printf 'start\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$label" >> "$(load_window_record)" 2>/dev/null
}

load_window_finish(){   # id end how
  printf 'end\t%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ' | cut -c1-200)" >> "$(load_window_record)" 2>/dev/null
}

# Keeps the record to its last LOAD_WINDOW_KEEP lines (400), called by the helper while it holds the
# turn, so only one writer ever trims. Old windows are of no use to either reader, which looks back
# LOAD_WINDOW_RECENT_SECONDS at most.
load_window_trim(){
  local f tmp keep="${LOAD_WINDOW_KEEP:-400}"
  f="$(load_window_record)"
  [ -f "$f" ] || return 0
  [ "$(wc -l < "$f" | tr -d ' ')" -gt "$keep" ] || return 0
  tmp="$f.trim.$$"
  tail -n "$keep" "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# The windows as one line each: <id> <start> <deadline> <end or -> <pid> <workers> <spawners> <how> <label>,
# tab separated, how and label with their spaces kept. An empty field prints as -, because a tab is
# whitespace to read, so two in a row would fold into one and shift every field after it.
load_window_list(){
  local f
  f="$(load_window_record)"
  [ -f "$f" ] || return 0
  awk -F'\t' '
    $1 == "start" { n++; id[n] = $2; st[$2] = $3; dl[$2] = $4; pid[$2] = $5; w[$2] = $6; s[$2] = $7; lb[$2] = $8 }
    $1 == "end"   { en[$2] = $3; how[$2] = $4 }
    function f(v) { return (v == "" ? "-" : v) }
    END { for (i = 1; i <= n; i++) { k = id[i]; printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", k, f(st[k]), f(dl[k]), (k in en ? f(en[k]) : "-"), f(pid[k]), f(w[k]), f(s[k]), f(how[k]), f(lb[k]) } }
  ' "$f" 2>/dev/null
}

# THE SENTENCE. Prints one sentence naming a deliberate load window that is running now, or else the
# latest one that ended within LOAD_WINDOW_RECENT_SECONDS (900) of now, or NOTHING when there is
# neither, so a caller appends it only when there is something to say. It claims only what the
# record holds (L11): that a window ran, when, and how many workers; never that it caused anything.
load_window_note(){   # $1 = now
  local now="$1" recent="${LOAD_WINDOW_RECENT_SECONDS:-900}" line id st dl en pid w s how lb
  local act="" last="" last_end=0 e
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  case "$recent" in ''|*[!0-9]*) recent=900 ;; esac
  while IFS=$'\t' read -r id st dl en pid w s how lb; do
    case "$st$dl" in ''|*[!0-9]*) continue ;; esac
    if [ "$en" = "-" ] && [ "$now" -lt "$dl" ] && [ "$now" -ge "$st" ]; then act="$id"$'\t'"$st"$'\t'"$dl"$'\t'"$pid"$'\t'"$w"$'\t'"$s"$'\t'"$lb"; continue; fi
    if [ "$en" = "-" ]; then e="$dl"; else e="$en"; fi
    case "$e" in ''|*[!0-9]*) continue ;; esac
    [ "$e" -le "$now" ] || continue
    if [ $(( now - e )) -le "$recent" ] && [ "$e" -ge "$last_end" ]; then
      last_end="$e"; last="$st"$'\t'"$e"$'\t'"$en"$'\t'"$pid"$'\t'"$w"$'\t'"$s"$'\t'"$lb"
    fi
  done < <(load_window_list)
  if [ -n "$act" ]; then
    IFS=$'\t' read -r id st dl pid w s lb <<<"$act"
    printf 'A deliberate load window is running on this Mac (tools/load-window.sh, pid %s, %s busy and %s process launching workers, "%s"), from %s until %s at the latest, so a timing or GitHub read failure here may have measured that load: run it again after %s before treating it as broken.' \
      "$pid" "$w" "$s" "$lb" "$(load_window_et "$st")" "$(load_window_et "$dl")" "$(load_window_et "$dl")"
    return 0
  fi
  if [ -n "$last" ]; then
    IFS=$'\t' read -r st e en pid w s lb <<<"$last"
    if [ "$en" = "-" ]; then
      printf 'A deliberate load window ran on this Mac from %s until %s (tools/load-window.sh, pid %s, %s busy and %s process launching workers, "%s"; its run recorded no end, so this is when its workers end themselves), %s ago, so a timing or GitHub read failure here may have measured that load.' \
        "$(load_window_et "$st")" "$(load_window_et "$e")" "$pid" "$w" "$s" "$lb" "$(load_window_ago $(( now - e )))"
    else
      printf 'A deliberate load window ran on this Mac from %s to %s (tools/load-window.sh, pid %s, %s busy and %s process launching workers, "%s"), ended %s ago, so a timing or GitHub read failure here may have measured that load.' \
        "$(load_window_et "$st")" "$(load_window_et "$e")" "$pid" "$w" "$s" "$lb" "$(load_window_ago $(( now - e )))"
    fi
  fi
  return 0
}

load_window_ago(){ if [ "$1" -ge 60 ]; then printf '%dm %02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; else printf '%ds' "$1"; fi; }
