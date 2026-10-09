#!/usr/bin/env bash
#
# run-lessons-core-rerank.sh: the daily job behind the MONTHLY re-rank of the lessons core
# (claude-config#566). Installed on each Mac by install-lessons-core-rerank-schedule.sh.
#
# Each run, in order:
#   1. If this Mac's own counts in lesson-counts/<host>.tsv are RECOUNT_DAYS (7) old, missing, or dated
#      in the future, recount its prose citations (tools/lesson-citations.py) and record them with
#      `claude-sync record-lesson-counts`, which commits them under the sync lock so the next sync
#      carries them to the other Mac. A counter that read nothing records nothing (L98).
#   2. Unless this month's proposal has already been delivered, re-rank (tools/lessons-core-rerank.py)
#      against both Macs' counts, writing the page, the moves and the list to apply into the state
#      folder, one set per month.
#   3. Tell Dan with ONE notification per month per outcome (a proposal, refused, not measured), which
#      opens the page in Chrome when clicked. A notice is recorded as given only once it was really
#      posted: not while Dan is asleep (sleep mode, #840), not when the notifier is missing or fails,
#      so the next day tries again (L368). A core that is not in use is logged and never notified, so
#      the job can be installed before the cutover.
#
# Daily rather than monthly because the delivery is what is monthly: a daily wake is the re-attempt
# when a Mac was off, or the other Mac's counts had not arrived yet (L533), and it is what keeps each
# Mac's counts at most a week old, which the re-rank's 14 day freshness limit is derived from (L614).
# Two jobs are never ordered by clock arithmetic between them (L386): the re-rank simply waits until
# both Macs' counts are fresh.
#
# It writes nothing into the repository itself: the counts go through claude-sync, which holds the
# lock every sync takes. It never runs core-set: Dan approves.
#
# Seams, every one for the tests (L284):
#   RERANK_REPO       the clone to read (default: the checkout this file is in)
#   RERANK_HOST       this Mac's name (default: hostname -s, what claude-sync files counts under)
#   RERANK_NOW        the UTC instant to act as (default: now)
#   RERANK_STATE      where the pages go (default: ~/.claude/state/lessons-core-rerank)
#   RERANK_LOG        the log (default: ~/.claude-lessons-core-rerank.log)
#   RERANK_COUNTER, RERANK_AGES, RERANK_SYNC, RERANK_NOTIFIER   the four outside programs
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # before any cd (L372)
SELF="$(cd "$HERE/.." && pwd)"
REPO="${RERANK_REPO:-$SELF}"
HOST="${RERANK_HOST:-$(hostname -s)}"
NOW="${RERANK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
CH="${CLAUDE_HOME:-$HOME/.claude}"
STATE="${RERANK_STATE:-$CH/state/lessons-core-rerank}"
LOG="${RERANK_LOG:-$HOME/.claude-lessons-core-rerank.log}"
NOTIFIER="${RERANK_NOTIFIER:-terminal-notifier}"
SLEEP_RECORD="$CH/state/sleep/current.json"
RECOUNT_DAYS=7
MONTH="${NOW:0:7}"

say(){ printf '%s lessons-core-rerank: %s\n' "$NOW" "$*" >> "$LOG" 2>/dev/null; printf '%s\n' "$*"; }
counter(){ if [ -n "${RERANK_COUNTER:-}" ]; then "$RERANK_COUNTER" "$@"; else python3 "$HERE/lesson-citations.py" "$@"; fi; }
ages(){ if [ -n "${RERANK_AGES:-}" ]; then "$RERANK_AGES" "$@"; else python3 "$HERE/lesson-ages.py" "$@"; fi; }
sync_tool(){ if [ -n "${RERANK_SYNC:-}" ]; then "$RERANK_SYNC" "$@"; else "$REPO/claude-sync" "$@"; fi; }

mkdir -p "$STATE" || { say "could not make $STATE, so nothing was done."; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lessons-core-rerank.XXXXXXXX")" || { say "could not make a scratch folder, so nothing was done."; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# 1. THIS MAC'S COUNTS.
own="$REPO/lesson-counts/$HOST.tsv"
age="$(python3 "$HERE/lib/lessons_core.py" counts-age "$own" "$NOW")" || { say "could not read the age of $own, so nothing was done."; exit 1; }
if [ "$age" = NONE ] || [ "$age" -ge "$RECOUNT_DAYS" ] || [ "$age" -lt 0 ]; then
  counter --now "$NOW" > "$TMP/counts.tsv" 2> "$TMP/counter.err"; crc=$?
  if [ "$crc" -ne 0 ]; then
    say "the citation counter failed (exit $crc: $(head -c 300 "$TMP/counts.tsv" "$TMP/counter.err" 2>/dev/null | tr '\n' ' ')), so no counts were recorded for $HOST; the old ones stand."
  elif ! rec="$(sync_tool record-lesson-counts "$TMP/counts.tsv" 2>&1)"; then
    say "claude-sync would not record the counts for $HOST: $rec"
  else
    say "recounted and recorded the counts for $HOST ($age days old before): $rec"
  fi
fi

# 2. THE RE-RANK, unless this month's proposal is already out.
DELIVERED="$STATE/delivered"
if grep -qx "$MONTH proposal" "$DELIVERED" 2>/dev/null; then
  say "the re-rank for $MONTH was already delivered."
  exit 0
fi
PAGE="$STATE/rerank-$MONTH.html"
if ! ages --repo "$REPO" --today "${NOW:0:10}" > "$TMP/ages.txt" 2>&1; then
  out="REFUSED: the lesson ages could not be read from the history of $REPO: $(head -c 300 "$TMP/ages.txt" | tr '\n' ' ')"
  rc=1
else
  second=()
  [ -f "$REPO/lesson-tags-second.tsv" ] && second=(--second-tags "$REPO/lesson-tags-second.tsv")
  out="$(python3 "$HERE/lessons-core-rerank.py" --index-dir "$REPO/payload" --core "$REPO/payload/LESSONS-CORE.txt" \
    --counts-dir "$REPO/lesson-counts" --bands-dir "$REPO/lesson-bands" --ages "$TMP/ages.txt" \
    --tags "$REPO/lesson-tags.tsv" ${second[@]+"${second[@]}"} --now "$NOW" \
    --seats "$REPO/lesson-core-seats.txt" --out-seats "$STATE/seats-$MONTH.txt" \
    --out-tsv "$STATE/moves-$MONTH.tsv" --out-html "$PAGE" --out-list "$STATE/core-$MONTH.txt" 2>&1)"; rc=$?
fi
printf '%s\n' "$out" | sed "s/^/$NOW lessons-core-rerank:   /" >> "$LOG" 2>/dev/null
# The first line of the re-rank's output matching $1, else its first line. awk reads to the end,
# so nothing in the pipeline is cut short under pipefail (L183).
first(){ printf '%s\n' "$out" | awk -v re="$1" 'NR == 1 { top = $0 } !hit && $0 ~ re { hit = $0 } END { print (hit != "" ? hit : top) }'; }
case "$rc" in
  0) outcome=proposal
     n="$(printf '%s\n' "$out" | awk '/ moves \(/ && !n++ { print $1 }')"
     msg="Lessons core re-rank for $MONTH: ${n:-?} moves proposed. Nothing changes until you approve." ;;
  3) say "INACTIVE: the lessons core is not in use, so there is nothing to re-rank and nothing was posted."
     exit 0 ;;
  2) outcome=unmeasured; msg="Lessons core re-rank for $MONTH not measured. $(first UNMEASURED)" ;;
  1) outcome=refused; msg="Lessons core re-rank for $MONTH refused. $(first '^(REFUSED|UNTAGGED|NO |NOT A|SEAT|BADTAG|UNDATED|WINDOWS)')" ;;
  *) outcome=failed; msg="Lessons core re-rank for $MONTH could not run (exit $rc). See $LOG." ;;
esac
say "$msg"

# 3. TELL DAN, once a month per outcome, and record it only once it was really posted.
if grep -qx "$MONTH $outcome" "$DELIVERED" 2>/dev/null; then
  say "Dan was already told this month ($outcome), so nothing was posted."
  exit 0
fi
if [ -r "$SELF/payload/hooks/lib/sleep.sh" ] && ( . "$SELF/payload/hooks/lib/sleep.sh" && sleep_active "$SLEEP_RECORD" ); then
  say "Dan is asleep, so nothing was posted; the next run tries again."
  exit 0
fi
if ! command -v "$NOTIFIER" >/dev/null 2>&1; then
  say "could not post the notification: $NOTIFIER is not installed. The page is at $PAGE; the next run tries again."
  exit 1
fi
if ! "$NOTIFIER" -title "Lessons core re-rank" -message "$msg" -execute "open -a 'Google Chrome' '$PAGE'" >/dev/null 2>&1; then
  say "could not post the notification ($NOTIFIER failed). The page is at $PAGE; the next run tries again."
  exit 1
fi
printf '%s %s\n' "$MONTH" "$outcome" >> "$DELIVERED"
say "posted ($outcome). Page: $PAGE"
exit 0
