#!/usr/bin/env bash
#
# check-memory-status.sh: print the memory lines whose pull request or issue status GitHub
# contradicts (claude-config#3552).
#
# A memory folder (`~/.claude/projects/<project>/memory/`, its index MEMORY.md and the entry files
# beside it) loads into every session in that project, and is believed without re-checking (L244).
# Measured on 2026-11-24 on the work MacBook: one index line said a pull request was open and
# waiting on someone, and GitHub had reported it merged since 2026-09-07, so every session on that
# Mac was told for 11 weeks that a merged change was unmerged. Nothing compared memory with GitHub.
# The rule is to keep a pointer rather than a copied status; this is the check that says when a
# line still naming a status has gone stale.
#
# PRINT ONLY. It reads the folder and asks GitHub; it writes no file and changes no memory file.
# Its output goes to the terminal that ran it and nowhere else, because a memory folder holds
# private notes and on the work MacBook names work repositories.
#
# WHAT IT READS. Every line of MEMORY.md and of each other *.md file directly in the folder that
# holds BOTH a status word from STATUS_WORDS (matched as a whole word, any case) AND a pull request
# or issue that names its repository: `owner/repo#N`, or a github.com pull or issues link. GitHub is
# asked once per distinct reference, never once per line. A status word with no number, or a number
# with no status word, is not a pair and is passed over. A status about anything else (a missing
# file, a vendor's check) is not GitHub's to confirm and is out of scope (#3552 step 3).
#
# A NUMBER WITH NO REPOSITORY IS NEVER GUESSED. `#N`, `PR N`, `issue N`, or `repo#N` without its
# owner, on a status line, is skipped and said to be, with the line numbers, so a stale line there
# is not mistaken for a checked one.
#
# VOLUME. In the measured folder 3 index lines named a status at all, so a run is a handful of
# calls. Each call is bounded by MEMORY_STATUS_CALL_SECONDS (default 15) and the run by
# MEMORY_STATUS_TOTAL_SECONDS (default 120): once the overall limit is spent nothing more is
# asked, and every reference not asked is printed as could not check, with that reason.
#
# Run:  bash ~/.claude/hooks/check-memory-status.sh <memory folder>
# It is not wired into anything yet: where it should run is open on #3552.
#
# It answers with an EXIT CODE, and a caller judges by that, never by a line of the output (L184).
# The outcomes are kept apart because a check that reports clean when it could not ask is
# indistinguishable from a memory with nothing stale in it (L98, L11):
#
#   0  every status line naming a repository was checked and agrees with GitHub (or there was no
#      such line, which it says)
#   1  at least one line disagrees with GitHub (printed, and anything below is still printed)
#   2  nothing could be read: no folder named, not a folder, no memory file in it, or an argument
#      it does not know
#   3  no disagreement found, but at least one reference or file could not be checked
#   4  everything checked agrees, but at least one status line named a number with no repository
#
# Environment:
#   MEMORY_STATUS_CALL_SECONDS   the limit on each gh call (default 15)
#   MEMORY_STATUS_TOTAL_SECONDS  the limit on all of them together (default 120)
# gh itself is found on the PATH, which is how the suite puts a stand in in front of it.

set -uo pipefail

# The status words of #3552, in ONE list. Longer phrases first, so "still open" is named as such
# rather than as "open" too.
STATUS_WORDS=("still open" "not merged" "open" "pending" "awaiting")

# What each status word claims about the state GitHub reports (OPEN, CLOSED or MERGED).
word_agrees() { # <status word> <state>  -> 0 when the word is true of that state
  case "$1" in
    "not merged") [ "$2" != MERGED ] ;;
    *) [ "$2" = OPEN ] ;;
  esac
}

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) DIR="${BASH_SOURCE[0]%/*}" ;; *) DIR=. ;; esac
DIR="$(cd "${DIR:-/}" && pwd)"

say() { printf 'check-memory-status: %s\n' "$*"; }
refuse() { say "$*"; exit 2; }

FOLDER=""
for arg in "$@"; do
  case "$arg" in
    -*) refuse "it does not know the argument '$arg' (it takes only a memory folder), so nothing was read." ;;
    *)
      [ -z "$FOLDER" ] || refuse "it takes one memory folder and was given more than one, so nothing was read."
      FOLDER="$arg" ;;
  esac
done
[ -n "$FOLDER" ] || refuse "name the memory folder to read, for example: bash ~/.claude/hooks/check-memory-status.sh ~/.claude/projects/<project>/memory"
[ -d "$FOLDER" ] || refuse "$FOLDER is not a folder, so nothing was read."

# The one bound every caller here shares, which kills the whole process group (lib/bounded-run.sh).
. "$DIR/lib/bounded-run.sh" 2>/dev/null || refuse "$DIR/lib/bounded-run.sh is missing, so gh could not be called with a time limit. Refusing rather than calling it unbounded."

is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
CALL_SECONDS="${MEMORY_STATUS_CALL_SECONDS:-15}"
TOTAL_SECONDS="${MEMORY_STATUS_TOTAL_SECONDS:-120}"
is_number "$CALL_SECONDS" && [ "$CALL_SECONDS" -gt 0 ] || refuse "MEMORY_STATUS_CALL_SECONDS is '$CALL_SECONDS', which is not a number above zero."
is_number "$TOTAL_SECONDS" && [ "$TOTAL_SECONDS" -gt 0 ] || refuse "MEMORY_STATUS_TOTAL_SECONDS is '$TOTAL_SECONDS', which is not a number above zero."

# The index first, then each entry file beside it, in name order.
FILES=()
[ -f "$FOLDER/MEMORY.md" ] && FILES+=("$FOLDER/MEMORY.md")
for f in "$FOLDER"/*.md; do
  [ -f "$f" ] || continue
  [ "${f##*/}" = MEMORY.md ] && continue
  FILES+=("$f")
done
[ "${#FILES[@]}" -gt 0 ] || refuse "$FOLDER holds no MEMORY.md and no other .md file, so there was nothing to read."

URL_RE='https?://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/(pull|issues)/([0-9]+)'
SHORT_RE='([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)#([0-9]+)'
BARE_RE='(#[0-9]+|(^|[^[:alnum:]_])(pr|pull request|issue)s? +#?[0-9]+)'
B='(^|[^[:alnum:]_])'; E='([^[:alnum:]_]|$)'

PAIRS=""      # "<key>|<file name>|<line number>|<status words>" per pair, in reading order
KEYS=$'\n'    # each distinct reference once, between newlines
SKIPPED=""    # "<file name> line(s) <numbers>" per file, for lines naming only a bare number
skipped_n=0
UNREADABLE=""
status_lines=0

shopt -s nocasematch
for f in "${FILES[@]}"; do
  name="${f##*/}"
  if [ ! -r "$f" ]; then UNREADABLE="$UNREADABLE $name"; continue; fi
  ln=0; file_skips=""
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    words=""
    for w in "${STATUS_WORDS[@]}"; do
      [ "$w" = open ] && [[ "$words" == *"still open"* ]] && continue
      [[ "$line" =~ $B$w$E ]] && words="${words:+$words, }$w"
    done
    [ -n "$words" ] || continue
    rest="$line"; refs=""
    while [[ "$rest" =~ $URL_RE ]]; do
      refs="$refs ${BASH_REMATCH[1]}/${BASH_REMATCH[2]}#${BASH_REMATCH[4]}"
      rest="${rest/"${BASH_REMATCH[0]}"/ }"
    done
    while [[ "$rest" =~ $SHORT_RE ]]; do
      refs="$refs ${BASH_REMATCH[1]}/${BASH_REMATCH[2]}#${BASH_REMATCH[3]}"
      rest="${rest/"${BASH_REMATCH[0]}"/ }"
    done
    bare=0; [[ "$rest" =~ $BARE_RE ]] && bare=1
    [ -n "$refs" ] || [ "$bare" -eq 1 ] || continue
    status_lines=$((status_lines + 1))
    if [ "$bare" -eq 1 ]; then
      skipped_n=$((skipped_n + 1)); file_skips="${file_skips:+$file_skips, }$ln"
    fi
    for r in $refs; do
      # Owner and repository are case blind on GitHub, so one reference written two ways is still
      # one call.
      key="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')"
      PAIRS="$PAIRS$key|$name|$ln|$words"$'\n'
      [[ "$KEYS" == *$'\n'"$key"$'\n'* ]] || KEYS="$KEYS$key"$'\n'
    done
  done < "$f"
  if [ -n "$file_skips" ]; then
    case "$file_skips" in *,*) SKIPPED="$SKIPPED; $name lines $file_skips" ;; *) SKIPPED="$SKIPPED; $name line $file_skips" ;; esac
  fi
done
shopt -u nocasematch

# ---------- asking GitHub, once per reference ----------
# The issues endpoint answers for a pull request too, carrying its merge time, so one call settles
# either. Every failure is put in words here, once (L35), and none of them reads as agreeing.
JQ='(if .pull_request then "pull-request" else "issue" end) + " " + .state + " " + (.pull_request.merged_at // "none")'
ask_github() { # <owner/repo> <number> <seconds>  -> BOUNDED_OUT, BOUNDED_RC
  bounded_run "$3" gh api "repos/$1/issues/$2" --jq "$JQ"
}
why_not() { # <exit code> <what gh printed> <seconds>  -> the reason, in words
  local rc="$1" out="$2"
  if [ "$rc" -eq 124 ]; then printf 'gh did not answer within %s second(s)' "$3"
  elif [ "$rc" -eq 4 ] || [[ "$out" == *"gh auth login"* ]] || [[ "$out" == *"HTTP 401"* ]]; then printf 'gh is not signed in, or GitHub refused its token'
  elif [[ "$out" == *"rate limit"* ]] || [[ "$out" == *"HTTP 429"* ]]; then printf 'GitHub refused it with a rate limit'
  elif [[ "$out" == *"HTTP 404"* ]]; then printf 'GitHub answered not found: the repository is not visible to this account, or it has no such number'
  elif [[ "$out" == *"error connecting"* ]] || [[ "$out" == *"no such host"* ]] || [[ "$out" == *"could not resolve"* ]] || [[ "$out" == *"network is unreachable"* ]]; then printf 'could not reach GitHub'
  else printf 'gh exited %s' "$rc"
  fi
}

RESULTS=$'\n'   # "<key> <STATE>" or "<key> ? <reason>" per reference
have_gh=1; command -v gh >/dev/null 2>&1 || have_gh=0
start=$SECONDS
while IFS= read -r key; do
  [ -n "$key" ] || continue
  repo="${key%#*}"; num="${key##*#}"
  if [ "$have_gh" -eq 0 ]; then
    RESULTS="$RESULTS$key ? gh is not installed on this PATH"$'\n'; continue
  fi
  left=$((TOTAL_SECONDS - (SECONDS - start)))
  if [ "$left" -le 0 ]; then
    RESULTS="$RESULTS$key ? the overall limit of $TOTAL_SECONDS second(s) ran out before it was asked"$'\n'; continue
  fi
  secs="$CALL_SECONDS"; [ "$left" -lt "$secs" ] && secs="$left"
  ask_github "$repo" "$num" "$secs"
  kind=""; state=""; merged=""
  read -r kind state merged _x <<< "$BOUNDED_OUT"
  if [ "$BOUNDED_RC" -ne 0 ]; then
    RESULTS="$RESULTS$key ? $(why_not "$BOUNDED_RC" "$BOUNDED_OUT" "$secs")"$'\n'
  elif [ "$kind" = pull-request ] && [ "$state" = closed ] && [ -n "$merged" ] && [ "$merged" != none ]; then
    RESULTS="$RESULTS$key MERGED"$'\n'
  elif { [ "$kind" = pull-request ] || [ "$kind" = issue ]; } && { [ "$state" = open ] || [ "$state" = closed ]; } && [ -n "$merged" ]; then
    state_up="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
    RESULTS="$RESULTS$key $state_up"$'\n'
  else
    RESULTS="$RESULTS$key ? gh answered something that is not a state"$'\n'
  fi
done <<EOF
$KEYS
EOF

result_of() { # <key>  -> the line after the key: a STATE, or "? <reason>"
  local l
  while IFS= read -r l; do
    [ "${l%% *}" = "$1" ] && { printf '%s' "${l#* }"; return 0; }
  done <<EOF
$RESULTS
EOF
}

# ---------- the verdict ----------
agree=0; disagree=0; unchecked=0
STALE=""; CANNOT=""
while IFS='|' read -r key name ln words; do
  [ -n "$key" ] || continue
  res="$(result_of "$key")"
  case "$res" in
    '?'*) unchecked=$((unchecked + 1))
          CANNOT="${CANNOT}could not check $key ($name line $ln): ${res#\? }."$'\n'
          continue ;;
  esac
  bad=""
  IFS=',' read -r -a wl <<< "$words"
  for w in "${wl[@]}"; do
    w="${w# }"
    word_agrees "$w" "$res" || bad="${bad:+$bad, }\"$w\""
  done
  if [ -z "$bad" ]; then
    agree=$((agree + 1))
  else
    disagree=$((disagree + 1))
    case "$res" in
      MERGED) said="merged" ;; CLOSED) said="closed" ;; *) said="open" ;;
    esac
    STALE="${STALE}$name line $ln: says $bad of $key, and GitHub reports it $said."$'\n'
  fi
done <<EOF
$PAIRS
EOF

[ -n "$STALE" ] && printf '%s' "$STALE" | while IFS= read -r l; do say "$l"; done
[ -n "$CANNOT" ] && printf '%s' "$CANNOT" | while IFS= read -r l; do say "$l"; done
for u in $UNREADABLE; do say "could not read $u, so any status in it was not checked."; done
if [ "$skipped_n" -gt 0 ]; then
  say "skipped $skipped_n line(s) naming a number with no repository (${SKIPPED#; }). A repository is never guessed, so write it as owner/repo#N, or a pointer with no status word."
fi

if [ "$status_lines" -eq 0 ] && [ -z "$UNREADABLE" ]; then
  say "no line in the ${#FILES[@]} file(s) read pairs a pull request or issue number with a status word, so there was nothing to check."
  exit 0
fi
say "$status_lines line(s) pair a number with a status word. Of the references on them, $agree agree with GitHub, $disagree disagree and $unchecked could not be checked; $skipped_n line(s) were skipped."

[ "$disagree" -gt 0 ] && exit 1
{ [ "$unchecked" -gt 0 ] || [ -n "$UNREADABLE" ]; } && exit 3
[ "$skipped_n" -gt 0 ] && exit 4
exit 0
