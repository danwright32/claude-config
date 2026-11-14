#!/usr/bin/env bash
#
# lesson-fanout.sh
# For each lesson named, file one "sweep this project for that defect" issue in every repo the
# repo-digest reports cover. A lesson recorded from one project is evidence the same defect may be
# sitting in the others (L195), and nothing else ever goes and looks. The repo the lesson was
# learned in gets one too, worded for it, since it is the likeliest to hold another instance
# (claude-config#2945).
#
#   lesson-fanout.sh L739 [L740 ...]
#   lesson-fanout.sh --source-backfill [L739 ...]
#
# Run by hand or when lesson-fanout-notice.sh asks for it. Safe to run any number of times, from
# either Mac: before filing, each repo's existing lesson-sweep issues are read, and a lesson counts
# as already filed there when an issue's title names its NUMBER or its body carries its stable ID.
# The number survives a reworded rule and the id survives a renumber, so neither files a twin.
# A repo's list is read once per run and kept, with what the run files added to it, and its labels
# and milestone are made sure of once per run, so a run over many lessons does not reread them.
# A list as long as LESSON_FANOUT_LIST_LIMIT (5000) cannot prove a lesson absent, so that repo is
# reported FAILED rather than filed in blind.
#
# --source-backfill files ONLY in the repo each lesson came from, for lessons fanned out before
# #2945 gave the source repo its own sweep. With no numbers it takes every lesson in the ledger,
# baseline entries included. A lesson citing no digest repo costs no GitHub call at all; one that
# does is read and filed exactly as a fan out reads and files it, with the source wording. Before
# each sourced lesson it reads `gh api rate_limit` (which costs nothing) as each account it will
# file with, and stops cleanly, exit 3, when either the REST or the GraphQL allowance is under
# LESSON_FANOUT_RATE_FLOOR (500, a reserve for the other sessions sharing the account), when that
# answer cannot be read, or when GitHub answers a read or a create with a rate limit (gh-poll.sh's
# ghp_rate_limited, the one reading of that text). It then says how many lessons are left and when
# the allowance resets, in ET; the same command run again continues, since everything already filed
# is found as EXISTS. It never writes the ledger: a lesson there means every repo has its sweep,
# and the backfill only files in one. It ends with one line:
#   SUMMARY: checked N, with a source N, CREATED N, EXISTS N, FAILED N
#
# THE REPO LIST is read live from dwright-pennie/repo-digest (repos.json and repos-weekly.json),
# never copied here, so a repo added to the digest with its button is covered from the next run
# (L41). Either list unreadable refuses the whole run: a partial list would quietly skip repos.
#
# THE ACCOUNT is chosen per repo: the first signed in gh account, active one first, that can push
# to it, passed as GH_TOKEN for that repo's calls only. The active account is never switched,
# because other sessions on this Mac depend on it.
#
# WHAT THE ISSUE CARRIES is the rule sentence and the lesson's id, never the evidence paragraph or
# the repo it came from: four of the digest repos are public, and evidence names private systems.
# It also carries the "## Open questions" section every issue must have (claude-config#1279), with
# None, because a sweep leaves nothing for Dan to decide. The filing gate never sees the body file
# this script writes, so nothing else would add it (claude-config#1321).
#
# THE LEDGER ($CLAUDE_HOME/state/lesson-fanout.done, one "Lnnn id" line per lesson) is written only
# once every target repo has the issue, so a lesson that failed anywhere is offered again by the
# notice hook and a rerun fills only the gaps (L368).
#
# A NUMBER NAMING TWO LESSONS is refused before anything is filed, saying which, because the rule
# read for it would be whichever entry comes first (claude-config#1140). In a backfill, a ledger
# number whose recorded id is not the id that number reads as today is refused the same way.
#
# Exit codes: 0 every repo covered; 1 something was not covered (each named with its reason);
# 2 usage; 3 a backfill stopped on GitHub's rate limit (run it again later to continue).
#
# Seams (tests set all of them):
#   LESSON_FANOUT_SYNC_TOOL    claude-sync, for `lesson Lnnn` (default ~/claude-config-sync/claude-sync)
#   LESSON_FANOUT_HELPERS_DIR  where ensure-priority-labels.sh and ensure-milestone.sh live
#   LESSON_FANOUT_LIST_LIMIT   the most existing issues one read asks for (5000)
#   LESSON_FANOUT_RATE_FLOOR   the allowance a backfill leaves unspent (500)
#   CLAUDE_HOME                where the ledger lives
#   gh on PATH

set -uo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SYNC_TOOL="${LESSON_FANOUT_SYNC_TOOL:-$HOME/claude-config-sync/claude-sync}"
HELPERS="${LESSON_FANOUT_HELPERS_DIR:-$CLAUDE_HOME/skills/milestone}"
LIST_LIMIT="${LESSON_FANOUT_LIST_LIMIT:-5000}"
RATE_FLOOR="${LESSON_FANOUT_RATE_FLOOR:-500}"
LEDGER="$CLAUDE_HOME/state/lesson-fanout.done"
DIGEST_REPO="dwright-pennie/repo-digest"
DIGEST_LISTS="repos.json repos-weekly.json"
LABEL="lesson-sweep"
PRIORITY="priority-p2"
MILESTONE="Ungrouped"

usage(){ echo "Usage: lesson-fanout.sh L739 [L740 ...]   or   lesson-fanout.sh --source-backfill [L739 ...]" >&2; exit 2; }
mode=fanout
if [ "${1:-}" = "--source-backfill" ]; then mode=backfill; shift; fi
[ "$mode" = backfill ] || [ "$#" -gt 0 ] || usage
for a in "$@"; do [[ "$a" =~ ^L[0-9]+$ ]] || usage; done

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "REFUSED: $tool is not installed, so nothing was filed." >&2; exit 1; }
done
# shellcheck source=gh-poll.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-poll.sh" || {
  echo "REFUSED: gh-poll.sh is missing beside this script, so a rate limit answer could not be told from any other failure. Nothing was filed." >&2
  exit 1
}

# ---- a backfill with no numbers takes every lesson in the ledger ----
if [ "$mode" = backfill ] && [ "$#" -eq 0 ]; then
  if [ ! -f "$LEDGER" ]; then
    echo "REFUSED: there is no ledger at $LEDGER, so there is no list of fanned out lessons to backfill. Name the lessons instead: lesson-fanout.sh --source-backfill L739 [L740 ...]" >&2
    exit 1
  fi
  set -- $(awk '$1 ~ /^L[0-9]+$/ { print $1 }' "$LEDGER")
  if [ "$#" -eq 0 ]; then
    echo "Nothing to backfill: $LEDGER lists no lessons."
    echo "SUMMARY: checked 0, with a source 0, CREATED 0, EXISTS 0, FAILED 0"
    exit 0
  fi
fi
# A number named twice is one lesson, handled once.
set -- $(printf '%s\n' "$@" | awk '!seen[$0]++')
given=$#

# ---- a number naming two lessons is refused before anything reaches GitHub (claude-config#1140) ----
# `claude-sync lesson Lnnn` used to answer with the FIRST entry under a number, so a number two lessons
# shared filed the first one's rule: on 2026-10-13 L762 was minted twice on one Mac and twelve sweep
# issues went out carrying another project's lesson. The reader now refuses a shared number too, but
# this asks first, so the refusal names the duplicate before any account or repo is touched. The question is asked of `lesson-faults`, the same list
# the send refuses on, rather than a second copy of the duplicate rule here (L41), and of the same
# home `lesson` reads below. SYNC_NO_NOTIFY because the tool notifies on a non interactive failure,
# and this prints the fault itself.
#
# Only two answers are taken as answers: exit 0 (nothing is wrong, so no number is shared), or a
# report that carries the duplicate sentence (every fault kind is reported together, so a number
# absent from it is not shared). Any other failure, an older clone without the command, a lock or
# home error, or a report of other faults only, cannot be told apart from the check not having run,
# so every number is refused with what the tool said: the question is whether twelve issues, some
# in public repos, carry the right rule, and not knowing is not a yes (L42, L11).
overall=0
faults_rc=0
faults="$(CLAUDE_HOME="$CLAUDE_HOME" SYNC_NO_NOTIFY=1 "$SYNC_TOOL" lesson-faults 2>&1)" || faults_rc=$?
dup_reported=0
case "$faults" in *"the same lesson number is used"*) dup_reported=1 ;; esac
sound=()
for num in "$@"; do
  if [ "$faults_rc" -ne 0 ] && [ "$dup_reported" -eq 0 ]; then
    echo "REFUSED $num: could not check whether $num names two lessons, because '$SYNC_TOOL lesson-faults' exited $faults_rc without reporting on duplicates, which reads the same whether it found other faults or could not run at all. What it said: ${faults:-<nothing>} Fix what it names, or pull that clone of claude-sync if it does not know the command, then run this again."
    overall=1
    continue
  fi
  if [ "$faults_rc" -ne 0 ] && grep -qE "(^|[^0-9A-Za-z])$num used [0-9]+ times" <<<"$faults"; then
    echo "REFUSED $num: $num names more than one lesson in $CLAUDE_HOME/LESSONS.md, so which rule the sweep issues should carry cannot be known from the number. What lesson-faults said: ${faults#claude-sync: } Then fan out each lesson under its own number."
    overall=1
    continue
  fi
  sound+=("$num")
done
if [ "${#sound[@]}" -eq 0 ]; then
  echo "NOT COMPLETE: the lines marked FAILED or REFUSED above were not filed. Rerunning files only those."
  exit 1
fi
refused_dup=$((given - ${#sound[@]}))
set -- "${sound[@]}"

RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT
repo_key(){ printf '%s' "$1" | tr '/' '_'; }

# ---- accounts and the repo list, read once per run ----
# A fan out needs them at once. A backfill asks for them only when it first meets a lesson citing
# some repo, so a run over lessons that cite none touches GitHub not at all.
repos_loaded=0
tokens=""
repos=""
load_repos(){
  [ "$repos_loaded" -eq 0 ] || return 0
  local accounts login tok list got found raw
  accounts="$(gh auth status --json hosts 2>/dev/null \
    | jq -r '.hosts["github.com"] // [] | sort_by(if .active then 0 else 1 end) | .[] | select(.state == "success") | .login' 2>/dev/null)"
  if [ -z "$accounts" ]; then
    echo "REFUSED: no GitHub account is signed in to gh on this Mac, so nothing was filed." >&2
    exit 1
  fi
  for login in $accounts; do
    tok="$(gh auth token --hostname github.com -u "$login" 2>/dev/null)" || continue
    [ -n "$tok" ] && tokens="$tokens$login $tok"$'\n'
  done
  for list in $DIGEST_LISTS; do
    # An unreadable list refuses the run now, because a run over half the repos reads like a run over
    # all of them. A readable but empty one is allowed here and judged with the other list below.
    got="" found=0
    while IFS=' ' read -r login tok; do
      [ -n "$tok" ] || continue
      raw="$(GH_TOKEN="$tok" gh api -H "Accept: application/vnd.github.raw" "repos/$DIGEST_REPO/contents/$list" 2>/dev/null)" || continue
      printf '%s' "$raw" | jq -e '.repos | type == "array"' >/dev/null 2>&1 || continue
      got="$(printf '%s' "$raw" | jq -r '.repos[] | "\(.owner)/\(.name) \(.label // "")"')" found=1
      break
    done <<<"$tokens"
    if [ "$found" -eq 0 ]; then
      echo "REFUSED: could not read $list from $DIGEST_REPO with any signed in account, so nothing was filed." >&2
      exit 1
    fi
    repos="$repos$got"$'\n'
  done
  # Each line is "owner/name label": the label is the digest's short name, which a lesson's
  # provenance may cite instead of the repo's own (PET#12 for project-enrollment-tracker).
  repos="$(printf '%s' "$repos" | sed '/^$/d' | sort -uf)"
  if [ -z "$repos" ]; then
    echo "REFUSED: $DIGEST_REPO lists no repos in $DIGEST_LISTS, so there is nowhere to file." >&2
    exit 1
  fi
  repos_loaded=1
}

# ---- per repo account, resolved the first time the run needs that repo ----
token_for(){   # $1 = owner/name -> the token of the first account that can push, or nothing
  local login tok
  while IFS=' ' read -r login tok; do
    [ -n "$tok" ] || continue
    if [ "$(GH_TOKEN="$tok" gh api "repos/$1" 2>/dev/null | jq -r '.permissions.push // false' 2>/dev/null)" = "true" ]; then
      printf '%s' "$tok"; return 0
    fi
  done <<<"$tokens"
  return 1
}
repo_token(){   # $1 = owner/name -> its token, or "-" when no signed in account can push to it
  local f
  f="$RUN_DIR/token-$(repo_key "$1")"
  if [ ! -f "$f" ]; then
    token_for "$1" >"$f" || printf '%s' "-" >"$f"
  fi
  cat "$f"
}

# ---- one lesson, read the one way both modes read it ----
# Sets L_ID, L_RULE, L_TITLE and L_SOURCES, the lowercased repo names the entry cites as name#N.
# Any digest repo among them, by repo name or by digest label (is_source), is where the lesson came
# from. That repo gets a sweep worded for it: it is the one most likely to hold more of the same
# defect, since the fix that taught the lesson covered only the case in front of it (#2945).
read_lesson(){   # $1 = Lnnn
  local num="$1" entry short
  if ! entry="$(CLAUDE_HOME="$CLAUDE_HOME" "$SYNC_TOOL" lesson "$num" 2>&1)"; then
    echo "REFUSED $num: could not read it: $entry"
    return 1
  fi
  L_ID="$(printf '%s\n' "$entry" | sed -n '1s/^id: \([0-9a-f]*\).*/\1/p')"
  L_RULE="$(printf '%s\n' "$entry" | sed '1d' | tr -s '[:space:]' ' ' \
    | sed -n "s/^ *- \*\*$num\. \([^*]*\)\*\*.*/\1/p" | sed 's/ *$//')"
  if [ -z "$L_ID" ] || [ -z "$L_RULE" ]; then
    echo "REFUSED $num: could not find its id and rule sentence in what claude-sync printed."
    return 1
  fi
  short="$(awk 'sub(/^[[:space:]]*SHORT:[[:space:]]*/, "") { print; exit }' <<<"$entry")"
  L_TITLE="Lesson $num sweep: ${short:-$L_RULE}"
  L_SOURCES="$(printf '%s\n' "$entry" | grep -oE '[A-Za-z0-9_.-]+#[0-9]+' | sed 's/#.*//' | tr '[:upper:]' '[:lower:]' | sort -u)"
  return 0
}
is_source(){   # $1 = owner/name, $2 = its digest label: did the lesson read last come from it?
  [ -n "$L_SOURCES" ] || return 1
  grep -qixF -e "${1#*/}" ${2:+-e "$2"} <<<"$L_SOURCES"
}

L_BODY_OTHER="$RUN_DIR/body-other.md"
L_BODY_SOURCE="$RUN_DIR/body-source.md"
write_body(){   # $1 = file, $2 = Lnnn, $3 = opening paragraph, $4 = what to look for
  cat >"$1" <<BODY
$3

**$2.** $L_RULE

What to do: look for $4, fix any instance found, and close this issue saying where you looked. If nothing here can hit it, close it with that reason. The full lesson, with its evidence, is \`claude-sync lesson $L_ID\` on Dan's Macs.

## Open questions
None

<!-- lesson-id: $L_ID -->
BODY
}
write_bodies(){   # $1 = Lnnn
  write_body "$L_BODY_OTHER" "$1" "A new lesson was recorded in another project. Check whether this project has the same defect." \
    "code in this project that matches the situation the rule describes"
  write_body "$L_BODY_SOURCE" "$1" "This lesson was recorded from a defect found in this project. The fix that taught it covered the case in front of it, so check this project for other places with the same defect." \
    "other code in this project that matches the situation the rule describes, beyond the instance already fixed"
}

# ---- one lesson in one repo ----
# Prints one CREATED, EXISTS or FAILED line and sets OUTCOME. Returns 0 when the repo has the
# issue, 1 when it does not, and 3, printing nothing, when GitHub answered with a rate limit:
# STOP_WHY then says so in GitHub's words, and the caller decides what a rate limit means for it.
file_in(){   # $1 = Lnnn, $2 = owner/name, $3 = token or "-", $4 = body file
  local num="$1" r="$2" tok="$3" body="$4" key cache existing n hit url err
  OUTCOME=FAILED
  if [ "$tok" = "-" ]; then
    echo "FAILED $num $r: no signed in account can write to it"; return 1
  fi
  key="$(repo_key "$r")"
  cache="$RUN_DIR/issues-$key.json"
  if [ ! -f "$cache" ]; then
    if ! existing="$(GH_TOKEN="$tok" gh issue list --repo "$r" --label "$LABEL" --state all --limit "$LIST_LIMIT" \
        --json number,title,body 2>&1)"; then
      if ghp_rate_limited "$existing"; then
        OUTCOME=STOPPED; STOP_WHY="GitHub answered the read of $r's issues with a rate limit: $existing"; return 3
      fi
      echo "FAILED $num $r: could not read its existing issues, so nothing was filed blind: $existing"; return 1
    fi
    if ! n="$(printf '%s' "$existing" | jq -er 'length' 2>/dev/null)"; then
      echo "FAILED $num $r: its existing issues came back in a form that could not be read, so nothing was filed blind: $existing"; return 1
    fi
    if [ "$n" -ge "$LIST_LIMIT" ]; then
      echo "FAILED $num $r: it holds $LIST_LIMIT or more $LABEL issues, the most one read asks for, so whether $num is already there cannot be known and nothing was filed blind. Run again with a higher LESSON_FANOUT_LIST_LIMIT."
      return 1
    fi
    printf '%s' "$existing" >"$cache"
  fi
  hit="$(jq -r --arg t "Lesson $num sweep" --arg m "lesson-id: $L_ID" \
    '[.[] | select((.title | startswith($t + ":")) or ((.body // "") | contains($m)))][0].number // empty' "$cache" 2>/dev/null)"
  if [ -n "$hit" ]; then
    OUTCOME=EXISTS; echo "EXISTS $num $r#$hit"; return 0
  fi
  if [ ! -f "$RUN_DIR/ensured-$key" ]; then
    if ! err="$(GH_TOKEN="$tok" bash "$HELPERS/ensure-priority-labels.sh" "$r" 2>&1)"; then
      echo "FAILED $num $r: could not make sure the priority labels exist: $err"; return 1
    fi
    if ! err="$(GH_TOKEN="$tok" gh label create "$LABEL" --repo "$r" --color C5DEF5 \
        --description "Check this project for a defect a recorded lesson describes" --force 2>&1)"; then
      echo "FAILED $num $r: could not make sure the $LABEL label exists: $err"; return 1
    fi
    if ! err="$(GH_TOKEN="$tok" bash "$HELPERS/ensure-milestone.sh" "$r" "$MILESTONE" 2>&1)"; then
      echo "FAILED $num $r: could not resolve the $MILESTONE milestone: $err"; return 1
    fi
    : >"$RUN_DIR/ensured-$key"
  fi
  if ! url="$(GH_TOKEN="$tok" gh issue create --repo "$r" --title "$L_TITLE" --body-file "$body" \
      --label "$PRIORITY,$LABEL" --milestone "$MILESTONE" 2>&1)"; then
    if ghp_rate_limited "$url"; then
      OUTCOME=STOPPED; STOP_WHY="GitHub answered the create in $r with a rate limit: $url"; return 3
    fi
    echo "FAILED $num $r: the create was refused: $url"; return 1
  fi
  url="$(printf '%s' "$url" | tail -1)"
  # The run's copy of the list learns what the run filed, so nothing later in it files a twin.
  jq --arg n "${url##*/}" --arg t "$L_TITLE" --arg b "<!-- lesson-id: $L_ID -->" \
    '. + [{number: (($n | tonumber?) // null), title: $t, body: $b}]' "$cache" >"$cache.new" 2>/dev/null \
    && mv "$cache.new" "$cache"
  OUTCOME=CREATED; echo "CREATED $num $r $url"; return 0
}

# ---- fan out: every digest repo ----
# overall was set above, and is already 1 when a duplicated number was refused there.
fan_out(){   # $1 = Lnnn
  local num="$1" r label body tok rc ok=0
  read_lesson "$num" || return 1
  write_bodies "$num"
  while IFS=' ' read -r r label; do
    [ -n "$r" ] || continue
    body="$L_BODY_OTHER"
    if is_source "$r" "$label"; then body="$L_BODY_SOURCE"; fi
    tok="$(repo_token "$r")"
    file_in "$num" "$r" "$tok" "$body"; rc=$?
    [ "$rc" -eq 3 ] && echo "FAILED $num $r: $STOP_WHY"
    [ "$rc" -eq 0 ] || ok=1
  done <<<"$repos"

  if [ "$ok" -eq 0 ]; then
    mkdir -p "$(dirname "$LEDGER")"
    grep -qxF "$num $L_ID" "$LEDGER" 2>/dev/null || printf '%s %s\n' "$num" "$L_ID" >>"$LEDGER"
  fi
  return "$ok"
}

# ---- source backfill: only the repo each lesson came from ----
RATE_WHY=""
allowance_ok(){   # $1 = token -> 0 when both allowances are at or above the floor, else RATE_WHY says why not
  local raw rem reset when
  if ! raw="$(GH_TOKEN="$1" gh api rate_limit 2>&1)"; then
    RATE_WHY="could not read GitHub's rate limit, so nothing more was spent blind: $raw"; return 1
  fi
  rem="$(printf '%s' "$raw" | jq -r '[.resources.core.remaining, .resources.graphql.remaining] | min' 2>/dev/null)"
  reset="$(printf '%s' "$raw" | jq -r '[.resources.core, .resources.graphql] | min_by(.remaining) | .reset' 2>/dev/null)"
  case "$rem" in
    ''|*[!0-9]*) RATE_WHY="could not read GitHub's rate limit answer, so nothing more was spent blind: $raw"; return 1 ;;
  esac
  [ "$rem" -ge "$RATE_FLOOR" ] && return 0
  when="at its hourly reset"
  case "$reset" in
    ''|*[!0-9]*) ;;
    *) when="at $(TZ=America/New_York date -r "$reset" '+%-I:%M %p') ET" ;;
  esac
  RATE_WHY="the account that files in the next lesson's repo has $rem GitHub API requests left this hour, under the $RATE_FLOOR this run leaves for the other sessions using it; GitHub restores the allowance $when"
  return 1
}

backfill(){
  local num ledger_id r label tok targets rc stop_reason=""
  local checked=$refused_dup sourced=0 created=0 exists=0 failed=$refused_dup stopped=0
  for num in "$@"; do
    if [ "$checked" -gt 0 ] && [ $((checked % 100)) -eq 0 ]; then
      echo "... $checked of $given lessons checked"
    fi
    if ! read_lesson "$num"; then
      failed=$((failed + 1)); checked=$((checked + 1)); continue
    fi
    ledger_id="$(awk -v n="$num" '$1 == n { print $2; exit }' "$LEDGER" 2>/dev/null)"
    if [ -n "$ledger_id" ] && [ "$ledger_id" != "baseline" ] && [ "$ledger_id" != "$L_ID" ]; then
      echo "REFUSED $num: the ledger records $num as lesson $ledger_id, but $num reads today as lesson $L_ID, so the number now names a different lesson from the one fanned out. Backfill that lesson under its current number instead."
      failed=$((failed + 1)); checked=$((checked + 1)); continue
    fi
    if [ -z "$L_SOURCES" ]; then
      checked=$((checked + 1)); continue
    fi
    load_repos
    targets=""
    while IFS=' ' read -r r label; do
      [ -n "$r" ] || continue
      if is_source "$r" "$label"; then targets="$targets$r"$'\n'; fi
    done <<<"$repos"
    if [ -z "$targets" ]; then
      checked=$((checked + 1)); continue
    fi
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      tok="$(repo_token "$r")"
      [ "$tok" = "-" ] && continue
      if ! allowance_ok "$tok"; then stop_reason="$RATE_WHY"; break; fi
    done <<<"$targets"
    if [ -n "$stop_reason" ]; then
      STOP_WHY="$stop_reason"; stopped=1; break
    fi
    write_bodies "$num"
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      tok="$(repo_token "$r")"
      file_in "$num" "$r" "$tok" "$L_BODY_SOURCE"; rc=$?
      case "$rc" in
        0) if [ "$OUTCOME" = CREATED ]; then created=$((created + 1)); else exists=$((exists + 1)); fi ;;
        3) stopped=1; break ;;
        *) failed=$((failed + 1)) ;;
      esac
    done <<<"$targets"
    # A lesson stopped part way is still left to check, so it is counted in neither total.
    [ "$stopped" -eq 0 ] || break
    sourced=$((sourced + 1))
    checked=$((checked + 1))
  done

  if [ "$stopped" -eq 1 ]; then
    echo "STOPPED: ${STOP_WHY%.}. Lessons left to check: $((given - checked)). Run the same command again once the allowance is back: every lesson already filed is found as EXISTS, so it carries on from here."
  elif [ "$failed" -ne 0 ]; then
    echo "NOT COMPLETE: the lines marked FAILED or REFUSED above were not filed. Rerunning files only those."
  fi
  echo "SUMMARY: checked $checked, with a source $sourced, CREATED $created, EXISTS $exists, FAILED $failed"
  if [ "$stopped" -eq 1 ]; then return 3; fi
  [ "$failed" -eq 0 ]
}

if [ "$mode" = backfill ]; then
  backfill "$@"
  exit $?
fi

load_repos
for num in "$@"; do
  fan_out "$num" || overall=1
done
if [ "$overall" -ne 0 ]; then
  echo "NOT COMPLETE: the lines marked FAILED or REFUSED above were not filed. Rerunning files only those."
fi
exit "$overall"
