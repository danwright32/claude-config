#!/usr/bin/env bash
#
# issue-spool.sh — the durable holding place for issue candidates found by
# subagents, and the ONE definition of the spool's shape.
#
# Why a spool at all. The end of turn issue review is a Stop hook: it fires when
# the MAIN session stops, on a 30 minute per project cooldown (a window the hook sets, not
# measured), reading the main
# transcript. None of that reaches a subagent. A batch of agents working in
# parallel therefore produced observations that were never offered to anyone,
# and a review suppressed by the cooldown lost whatever that turn found.
#
# So findings are written down the moment an agent finishes, and they stay
# written down until they are FILED. Reading them does not consume them: a
# review that is read and then interrupted has to leave the finding behind for
# the next one. Losing a finding twice over is the failure this exists to stop.
#
# Every consumer goes through this file (the harvest that writes, the review
# that reads, the clear that files) so the format cannot drift between them.
#
# Usage:
#   issue-spool.sh key          <dir>          the project key <dir> belongs to
#   issue-spool.sh path         <dir>          the pending spool file for <dir>
#   issue-spool.sh archive-path <dir>          the archive file for <dir>
#   issue-spool.sh append       <dir> <json>   append one record; non-zero if refused
#   issue-spool.sh note <dir> <text> [who]     record a finding directly, no model call
#   issue-spool.sh raw          <dir>          the pending records, verbatim
#   issue-spool.sh pending      <dir>          what a person should read; exit 1 if nothing
#   issue-spool.sh has-findings <dir>          exit 0 only if a real finding is pending
#   issue-spool.sh archive      <dir>          everything already filed
#   issue-spool.sh clear        <dir>          move pending into the archive
#   issue-spool.sh file-errors  <dir>          file ONLY the harvest failures
#                                              that were shown, once reported
#   issue-spool.sh file-muted   <dir>          file the held-back failures, once
#                                              their periodic count has gone out
#   issue-spool.sh muted-summary <dir>         the periodic count of held-back
#                                              failures; exit 1 if none
#
# `raw` and `archive` exit 0 on an empty spool. They used to exit non-zero,
# which kills any caller running under errexit on the ordinary empty case, and
# that behaviour was documented for `pending` only.
#
# The spool lives OUTSIDE ~/.claude on purpose. Anything under ~/.claude is
# auto committed and pushed to Dan's other Macs within seconds, and transcript
# derived notes are not config.
set -uo pipefail

SPOOL_ROOT="${CLAUDE_ISSUE_SPOOL_DIR:-$HOME/.claude-issue-spool}"

# How many records the archive keeps. It is only history, and nothing reads it
# automatically, but left uncapped it grows for as long as the machine lives.
ARCHIVE_MAX_RECORDS="${CLAUDE_ISSUE_SPOOL_ARCHIVE_MAX:-5000}"
# How large the PENDING file may grow before it is compacted. Findings are
# never dropped by that; only records that repeat are folded together.
PENDING_MAX_RECORDS="${CLAUDE_ISSUE_SPOOL_PENDING_MAX:-500}"

# Failure reasons that are reported as a periodic COUNT rather than on every
# review. One reason qualifies: an agent spawned by another agent fires
# SubagentStop naming a transcript that is never written, anywhere, so the
# harvest can never succeed and there is nothing anybody can do about it.
# Measured 2026-08-29: 235 of one project's 236 pending failures and all 62 of
# another's were this single reason, and it reached the end of almost every
# turn. A notice carrying no action, printed every time, is what teaches a
# person to skip the whole review, so it is held back and counted.
#
# This list is deliberately tiny and deliberately EXACT. Every other reason
# keeps printing every time, because the rest are real faults: the same
# measurement found a "the harvest model exited 1" in the same file, and a mute
# written as "hide the failures" rather than "hide THIS failure" would have
# buried it (L104). Newline separated; override for a test, not to add to it
# casually.
#
# KNOWN GAP (L77): classifying a failure as expected does not excuse anyone from
# watching its RATE, and this reports a count without escalating on one. A
# threshold is deliberately NOT set here, because the real distribution will not
# support one: measured across two projects over eight days, the daily volume ran
# 4, 12, 3, 19, 29, 188, 19. Any threshold lands inside that spread, so it would
# fire on an ordinary busy day and say nothing on a quiet broken one, which is
# the noise a threshold is supposed to remove (L172). The count in the periodic
# line is what a person reads instead; if a real baseline ever exists, this is
# where the escalation belongs.
MUTED_ERROR_REASONS="${CLAUDE_ISSUE_SPOOL_MUTED_REASONS:-the named agent transcript does not exist}"

# The key must survive a worktree. An agent usually runs in .claude/worktrees/<x>,
# whose path hashes differently from the checkout the session reading the spool
# sits in, so keying on the raw directory would file every agent's findings under
# a project nobody ever opens. Normalise through git: a worktree and its main
# checkout share one common git dir. The result is then resolved to its physical
# path, because /tmp and /private/tmp are the same directory on macOS and the
# writer and the reader do not always arrive by the same route.
# THE KEY COMES FROM THE SESSION, not from whatever directory the writer happens
# to be standing in. A SubagentStop payload's `cwd` is the AGENT's directory, and
# an agent routinely works in a git repo NESTED inside the folder its session was
# started in. Measured 2026-08-29 on a real project: a session in
# ".../Project Enrollment Tracker (PET)" dispatched agents working in
# ".../PET/pet", so the harvest filed under the repo while the review read the
# parent. All 318 records showed the split, and 47 real findings sat in a spool
# that project's reviews have never once opened. Normalising through git makes it
# worse, not better: it resolves the nested repo further away from the folder the
# session is in.
#
# The parent session's transcript path is the one thing BOTH sides are handed
# about the same conversation, so both derive the key from it and cannot
# disagree. A writer and a reader computing a key from two independent guesses
# agree only by luck (L70).
#
# It also subsumes the worktree case this used to solve: an agent in a worktree
# still reports its parent session's transcript, so it lands in the session's
# spool rather than under a path nobody opens.
issue_spool_key() { # key <dir> [session-transcript]
  local dir="${1:-$PWD}" transcript="${2:-}" common root
  if [ -n "$transcript" ]; then
    root="$(dirname "$transcript")"
    if [ -d "$root" ]; then
      root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
      printf '%s' "$root" | shasum | cut -c1-12
      return 0
    fi
  fi
  # No transcript to key on (a direct `note`, a test, an older caller): fall back
  # to the directory, exactly as before.
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common" ] && [ -d "$common" ]; then
    root="$(dirname "$common")"
  else
    root="$dir"
  fi
  root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
  printf '%s' "$root" | shasum | cut -c1-12
}

issue_spool_path()         { printf '%s/%s.jsonl' "$SPOOL_ROOT" "$(issue_spool_key "${1:-$PWD}" "${2:-}")"; }
issue_spool_archive_path() { printf '%s/%s.filed.jsonl' "$SPOOL_ROOT" "$(issue_spool_key "${1:-$PWD}" "${2:-}")"; }

# Every key a reader must consult: the session's, plus the directory's, so that
# nothing already spooled the old way is stranded the moment this ships. The
# directory key is a TRANSITION path, not a second home: writes only ever go to
# the first key, so these files drain and stop being written to.
#
# Deduplicated, because when no transcript is supplied the two are the same key
# and reading it twice would double every count a person is shown.
issue_spool_path_for_key()    { printf '%s/%s.jsonl' "$SPOOL_ROOT" "$1"; }
issue_spool_archive_for_key() { printf '%s/%s.filed.jsonl' "$SPOOL_ROOT" "$1"; }

# The pending records a reader should see, from every key it must consult,
# concatenated into one throwaway file. Every reader goes through this so that
# "which spools count as mine" is answered in ONE place: two readers answering it
# separately is how the split this fixes came about.
#
# Prints the temp file's path. The caller removes it.
issue_spool_collect() { # collect <dir> [session-transcript]
  local tmp key file
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-spool-read.XXXXXX")" || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    file="$(issue_spool_path_for_key "$key")"
    [ -s "$file" ] && cat "$file" >> "$tmp" 2>/dev/null
  done <<COLLECT_KEYS
$(issue_spool_read_keys "${1:-$PWD}" "${2:-}")
COLLECT_KEYS
  printf '%s' "$tmp"
}

issue_spool_read_keys() { # read-keys <dir> [session-transcript]
  local primary legacy
  primary="$(issue_spool_key "${1:-$PWD}" "${2:-}")"
  printf '%s\n' "$primary"
  [ -n "${2:-}" ] || return 0
  legacy="$(issue_spool_key "${1:-$PWD}")"
  [ "$legacy" = "$primary" ] || printf '%s\n' "$legacy"
}

# A record is one line of JSON. Anything else breaks the one-record-per-line
# invariant every reader depends on, and a broken line is then dropped by the
# reader, so a bad caller would corrupt the spool and see no complaint. Refusing
# here means the caller can fall back to somewhere the record still survives.
issue_spool_append() { # append <dir> <json-record>
  local file record count; file="$(issue_spool_path "$1" "${3:-}")"; record="${2:-}"
  [ -n "$record" ] || return 2
  case "$record" in *$'\n'*) return 2 ;; esac
  printf '%s' "$record" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null || return 2
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || return 1
  printf '%s\n' "$record" >> "$file" 2>/dev/null || return 1

  # Keep the pending file bounded (claude-config#19). A fault that recurs adds a
  # record every time it happens, and while those collapse to one line when read,
  # the file itself grows for as long as the condition lasts.
  count="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
  if [ -n "$count" ] && [ "$count" -gt "$PENDING_MAX_RECORDS" ]; then
    issue_spool_compact "$file"
  fi
  return 0
}

# Collapse what can be collapsed without losing anything a person needs.
# FINDINGS ARE NEVER TOUCHED: losing one is the single outcome this whole
# mechanism exists to prevent, so compaction is only ever allowed to fold the
# records that repeat. A folded error carries its own `count`, so the number a
# person reads stays the true number of occurrences rather than becoming 1.
issue_spool_compact() { # compact <pending-file>
  local file="$1" tmp="$1.compacting.$$"
  python3 - "$file" "$tmp" <<'PY_COMPACT' || return 1
import json, sys

src, dst = sys.argv[1], sys.argv[2]
KEEP_NONE = 25          # enough to show harvests ran, not enough to matter

findings, unparsed, nones, corrupt = [], [], [], []
errors = {}

for line in open(src, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        corrupt.append(line)          # kept, so the reader still reports them
        continue
    if not isinstance(rec, dict):
        corrupt.append(line)
        continue
    status = rec.get("status")
    if status == "found":
        findings.append(rec)
    elif status == "unparsed":
        unparsed.append(rec)
    elif status == "error":
        reason = rec.get("error") or "no reason recorded"
        prev = errors.get(reason)
        if prev is None:
            rec["count"] = rec.get("count", 1)
            errors[reason] = rec
        else:
            prev["count"] = prev.get("count", 1) + rec.get("count", 1)
            prev["ts"] = rec.get("ts", prev.get("ts"))
    else:
        nones.append(rec)

with open(dst, "w", encoding="utf-8") as fh:
    for rec in findings + unparsed + list(errors.values()) + nones[-KEEP_NONE:]:
        fh.write(json.dumps(rec) + "\n")
    for line in corrupt[-KEEP_NONE:]:
        fh.write(line + "\n")
PY_COMPACT
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Record a finding DIRECTLY, with no transcript involved (claude-config#18).
# A nested subagent leaves no transcript anywhere, so it cannot be harvested at
# all; this is the only capture path that works for one. It is also the cheaper
# path for any agent, since it costs no model call.
issue_spool_note() { # note <dir> <finding text> [who reported it] [session-transcript]
  local dir="${1:-$PWD}" text="${2:-}" source="${3:-self-reported}" transcript="${4:-}" record
  # `case` rather than a substitution that strips every space out of the text. The text is a
  # finding written by a model and has no bounded length, and that substitution's cost is
  # superlinear in the number of matches under the bash macOS ships (claude-config#117).
  case "$text" in *[![:space:]]*) ;; *) return 2 ;; esac
  record="$(python3 -c '
import json, sys, datetime
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": "found",
    "agent": sys.argv[1] or "self-reported",
    "cwd": sys.argv[2],
    "findings": [sys.argv[3].strip()[:500]],
    "self_reported": True,
}))' "$source" "$dir" "$text" 2>/dev/null)"
  [ -n "$record" ] || return 1
  issue_spool_append "$dir" "$record" "$transcript"
}

# What a person should read. Records that looked and found nothing are kept in
# the file (they are the evidence a harvest ran) but are not printed, because
# there is nothing to act on. Everything else is printed and says which it is: a
# harvest that could not run is not a project with no findings, and neither is a
# reply nobody could parse.
issue_spool_pending() { # pending <dir> [session-transcript] -> exit 1 when there is nothing to show
  local file rc; file="$(issue_spool_collect "$1" "${2:-}")" || return 1
  if [ ! -s "$file" ]; then rm -f "$file"; return 1; fi
  CLAUDE_SPOOL_MUTED="$MUTED_ERROR_REASONS" python3 - "$file" <<'PY'
import json, os, sys

MAX_FINDINGS = 200
# How many characters of FINDINGS one review may carry. Measured 2026-08-29: a
# real project's pending list rendered to 50,030 characters, all of which would
# have gone into a single message. A count cap does not bound that, because one
# 500 character finding costs what twenty short ones do, so the limit is on size.
FINDING_BUDGET = int(os.environ.get("CLAUDE_ISSUE_SPOOL_FINDING_BUDGET") or 8000)
MUTED = {r for r in (os.environ.get("CLAUDE_SPOOL_MUTED") or "").split("\n") if r.strip()}
shown = 0
seen = set()
errors = {}
unparsed = []
corrupt = 0
findings = []

for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        corrupt += 1          # counted, never silently skipped
        continue
    if not isinstance(rec, dict):
        corrupt += 1
        continue
    where = rec.get("agent") or "subagent"
    status = rec.get("status")
    if status == "found":
        for f in rec.get("findings") or []:
            # Exact repeats only. A fold that normalised case, punctuation and
            # whitespace was tried and REMOVED: measured against one project's
            # real spool it collapsed nothing at all (246 finding texts in, 246
            # out), because genuine restatements by different agents share none
            # of those differences. It bought no reduction and added a way to
            # hide a finding, which is the one thing this must never do.
            if f in seen:
                continue
            seen.add(f)
            findings.append((where, rec.get("ts", "?"), f))
    elif status == "error":
        # Deduped by REASON, and counted. A recurring fault (a subagent kind that
        # leaves no transcript fires every few minutes, measured 2026-08-16)
        # otherwise appends a fresh record every time, the spool is never empty,
        # and the review would carry N copies of one line.
        reason = rec.get("error") or "no reason recorded"
        # A reason with no remedy is held back for the periodic count instead of
        # being printed here. It stays in the spool: held back is not discarded,
        # and `muted-summary` reads these same records.
        if reason in MUTED:
            continue
        e = errors.setdefault(reason, {"count": 0, "agents": set(), "last": "?"})
        e["count"] += rec.get("count", 1)
        e["agents"].add(where)
        e["last"] = rec.get("ts", "?")
    elif status == "unparsed":
        # Held back for the periodic count, like the failures with no remedy.
        # The harvest model replying that it cannot read a transcript is the
        # SAME dead end wearing a different status, and it reached the reader at
        # every single review by this route while the mute was busy stopping the
        # other one (L173).
        unparsed.append((where, rec.get("ts", "?"), (rec.get("raw") or "")[:400]))

spent = 0
printed = 0
for where, ts, f in findings[:MAX_FINDINGS]:
    line = "FINDING (%s, %s): %s" % (where, ts, f)
    # The budget is checked BEFORE printing, so one very long finding cannot
    # overrun it, and at least one is always printed however long it is: a report
    # that carries nothing is worse than one that carries a single item.
    if printed and spent + len(line) > FINDING_BUDGET:
        break
    print(line)
    spent += len(line)
    printed += 1
    shown += 1
if printed < len(findings):
    shown += 1
    print("...and %d more findings not shown here. They stay in the spool until filed."
          % (len(findings) - printed))

for reason, info in errors.items():
    shown += 1
    times = "" if info["count"] == 1 else ", %d times" % info["count"]
    print("HARVEST FAILED (%s, last %s%s): %s. Nothing was read from those agents, so this "
          "is not the same as them finding nothing."
          % (", ".join(sorted(info["agents"])), info["last"], times, reason))

# Deliberately NOT printed here. The raw text is kept in the record and reaches
# the archive, so a prompt fix can still be informed by it; what stops is the
# interruption at every review.

if corrupt:
    shown += 1
    print("UNREADABLE SPOOL RECORDS: %d line(s) in the spool are not valid records and were "
          "skipped. Something wrote to it that should not have." % corrupt)

sys.exit(0 if shown else 1)
PY
  rc=$?
  rm -f "$file"
  return $rc
}

# Does the spool hold an actual FINDING, as opposed to only records of harvests
# that failed or looked and found nothing? The review bypasses its cooldown on
# this answer alone: a recurring failure keeps the spool permanently non-empty,
# and interrupting every turn over it would train the review to be ignored.
issue_spool_has_findings() { # has-findings <dir> [session-transcript] -> exit 0 when a finding is pending
  local file rc; file="$(issue_spool_collect "$1" "${2:-}")" || return 1
  if [ ! -s "$file" ]; then rm -f "$file"; return 1; fi
  python3 - "$file" <<'PY_HF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if isinstance(rec, dict) and rec.get("status") == "found" and (rec.get("findings") or []):
        sys.exit(0)
sys.exit(1)
PY_HF
  rc=$?
  rm -f "$file"
  return $rc
}

# The periodic count for the failures `pending` holds back. Reads the SAME
# records `pending` skips, so the two cannot disagree about what is muted, and
# sums each record's folded `count` rather than counting lines: compaction folds
# repeats into one record carrying the true total, and counting lines would
# understate the fault by exactly the amount compaction tidied away.
#
# Exits 1 when nothing is held back, so a caller can tell "still happening" from
# "stopped" rather than printing a reassuring zero (L98).
issue_spool_muted_summary() { # muted-summary <dir> [session-transcript] -> exit 1 when nothing is held back
  local file rc; file="$(issue_spool_collect "$1" "${2:-}")" || return 1
  if [ ! -s "$file" ]; then rm -f "$file"; return 1; fi
  CLAUDE_SPOOL_MUTED="$MUTED_ERROR_REASONS" python3 - "$file" <<'PY_MUTED'
import json, os, sys

MUTED = {r for r in (os.environ.get("CLAUDE_SPOOL_MUTED") or "").split("\n") if r.strip()}
unreadable = 0      # a transcript that was never written: nothing can fix this
unparsed = 0        # a reply the harvest could not parse: a prompt CAN fix this
first = None

for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if not isinstance(rec, dict):
        continue
    status = rec.get("status")
    if status == "error" and (rec.get("error") or "no reason recorded") in MUTED:
        unreadable += rec.get("count", 1)
    elif status == "unparsed":
        unparsed += rec.get("count", 1)
    else:
        continue
    ts = rec.get("ts")
    if ts and (first is None or ts < first):
        first = ts

if not (unreadable or unparsed):
    sys.exit(1)

# The two are REPORTED SEPARATELY on purpose. An unwritten transcript can never
# be fixed; a reply the harvest could not parse is a prompt that can be. One
# combined number would bury the fixable half inside the hopeless one, which is
# exactly the mistake this mute was written to avoid.
parts = []
if unreadable:
    parts.append("%d agent harvest(s) could not be read (agents spawned by other agents leave no "
                 "transcript anywhere, so there is nothing to fix)" % unreadable)
if unparsed:
    parts.append("%d harvest reply/replies could not be parsed (their words are kept in the "
                 "archive, and a prompt change could reduce these)" % unparsed)
print("HARVEST UNREADABLE, since %s: %s. This is a periodic count, not a new problem, and it is "
      "held back from every other review so it does not become noise."
      % (first or "an unrecorded time", "; ".join(parts)))
sys.exit(0)
PY_MUTED
  rc=$?
  rm -f "$file"
  return $rc
}

# Filing RENAMES the pending file out of the way first, then drains the renamed
# copy into the archive. Copying and then truncating is two steps with no lock,
# and anything a finishing agent appends between them is destroyed: not
# archived, not shown, gone. Filing runs exactly when background agents are most
# likely to be finishing (right after the picker is answered), so that window is
# the normal case rather than a corner. After the rename an appender writes to a
# fresh file and cannot be caught by the drain at all.
issue_spool_clear() { # clear <dir> [session-transcript] -> file the pending records
  local key rc=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    issue_spool_clear_key "$key" || rc=1
  done <<CLEAR_KEYS
$(issue_spool_read_keys "${1:-$PWD}" "${2:-}")
CLEAR_KEYS
  return $rc
}

issue_spool_clear_key() { # clear-key <key>
  local file archive staged count
  file="$(issue_spool_path_for_key "$1")"
  archive="$(issue_spool_archive_for_key "$1")"
  [ -s "$file" ] || return 0
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || return 1
  staged="${file}.filing.$$"
  mv "$file" "$staged" 2>/dev/null || return 1

  # Test seam: the one instant that decides whether a concurrently arriving
  # record survives. Racing real processes proved nothing here, because the
  # window happened not to open (measured 2026-08-16, the broken version passed).
  [ -n "${CLAUDE_ISSUE_SPOOL_MIDCLEAR:-}" ] && eval "${CLAUDE_ISSUE_SPOOL_MIDCLEAR}"

  cat "$staged" >> "$archive" 2>/dev/null && rm -f "$staged"

  issue_spool_cap_archive "$archive"
}

# Cap the archive. It is history that nothing reads automatically, so the only
# thing unbounded growth buys is a file that eventually matters. One definition,
# called by both filing paths, so they cannot drift into capping differently.
issue_spool_cap_archive() { # cap-archive <archive-file>
  local archive="$1" count
  [ -f "$archive" ] || return 0
  count="$(wc -l < "$archive" 2>/dev/null | tr -d ' ')"
  if [ -n "$count" ] && [ "$count" -gt "$ARCHIVE_MAX_RECORDS" ]; then
    tail -n "$ARCHIVE_MAX_RECORDS" "$archive" > "${archive}.trimmed" 2>/dev/null \
      && mv "${archive}.trimmed" "$archive"
  fi
  return 0
}

# File away the records a person cannot act on, once they have actually been
# REPORTED (claude-config#85).
#
# A HARVEST FAILED record used to be unsettleable. The spool is emptied only by
# `clear`, and the review tells Claude to run that AFTER the picker is answered;
# a spool holding nothing but failures gives the review nothing to put in a
# picker, so no picker appears and nothing ever runs clear. The record then rode
# along on every review for that project until somebody cleared the spool by
# hand (measured 2026-08-18: one from 18:18 UTC still being reported at 19:13).
# The fault underneath is real and recurring and cannot be fixed at the source: a
# nested subagent leaves no transcript anywhere to read.
#
# There is nothing to do about one, so being told once is the whole of its value.
# FINDINGS ARE NOT TOUCHED: those keep the old rule and survive until the picker
# is answered, because a finding a person has not decided about is exactly what
# this spool exists to protect. Neither is an UNREADABLE line: nothing classified
# it, so filing it would settle something nobody has read (L11).
#
# The known cost, worth stating: a review that is interrupted before it is read
# files that failure unseen. That is why the caller may only run this once the
# report has actually gone out, and why nothing else is settled this way.
#
# Same rename-then-drain shape as issue_spool_clear, for the same reason: a
# record appended by a finishing agent between a read and a rewrite would be
# destroyed, and filing runs exactly when agents are finishing. After the rename
# an appender is writing to a fresh file, and the records kept back are APPENDED
# to whatever is there rather than written over it.
# Both filing paths are ONE implementation with one predicate, because they are
# the same delicate rename-then-drain and a second copy of it would drift in the
# half nobody re-reads. `errors` files the failures a review actually carried;
# `muted` files the held-back ones, and only once their periodic count has gone
# out.
issue_spool_file_errors() { # file-errors <dir> [session-transcript]
  issue_spool_file_subset "$1" errors "${2:-}"
}

issue_spool_file_muted() { # file-muted <dir> [session-transcript]
  issue_spool_file_subset "$1" muted "${2:-}"
}

issue_spool_file_subset() { # file-subset <dir> <errors|muted> [session-transcript]
  local key rc=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    issue_spool_file_subset_key "$key" "${2:-errors}" || rc=1
  done <<SUBSET_KEYS
$(issue_spool_read_keys "${1:-$PWD}" "${3:-}")
SUBSET_KEYS
  return $rc
}

issue_spool_file_subset_key() { # file-subset-key <key> <errors|muted>
  local file archive staged keep errs mode
  mode="${2:-errors}"
  file="$(issue_spool_path_for_key "$1")"
  archive="$(issue_spool_archive_for_key "$1")"
  [ -s "$file" ] || return 0
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || return 1
  staged="${file}.filing-errors.$$"
  keep="${staged}.keep"
  errs="${staged}.errors"
  mv "$file" "$staged" 2>/dev/null || return 1

  # The same named seam clear() carries, at the same instant, so the concurrent
  # append can be tested here rather than raced for.
  [ -n "${CLAUDE_ISSUE_SPOOL_MIDCLEAR:-}" ] && eval "${CLAUDE_ISSUE_SPOOL_MIDCLEAR}"

  if ! CLAUDE_SPOOL_MUTED="$MUTED_ERROR_REASONS" python3 - "$staged" "$keep" "$errs" "$mode" <<'PY_SPLIT'
import json, os, sys

src, keep_path, err_path, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
MUTED = {r for r in (os.environ.get("CLAUDE_SPOOL_MUTED") or "").split("\n") if r.strip()}

with open(keep_path, "w", encoding="utf-8") as keep, \
     open(err_path, "w", encoding="utf-8") as errs:
    for line in open(src, encoding="utf-8", errors="replace"):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            rec = json.loads(stripped)
        except Exception:
            keep.write(stripped + "\n")     # unreadable: nobody has classified it
            continue
        take = False
        if isinstance(rec, dict):
            status = rec.get("status")
            # Held back from every review, so settled only by the periodic
            # report: filing either here would settle something nobody read AND
            # reset the count that report reads, making a continuing fault look
            # like one that stopped.
            held = (status == "error"
                    and (rec.get("error") or "no reason recorded") in MUTED) \
                or status == "unparsed"
            if mode == "muted":
                take = held
            else:
                take = status == "error" and not held
        if take:
            errs.write(stripped + "\n")
        else:
            keep.write(stripped + "\n")
PY_SPLIT
  then
    # Nothing was moved anywhere, so everything goes back. Failing towards
    # keeping a record is the only safe direction here.
    cat "$staged" >> "$file" 2>/dev/null
    rm -f "$staged" "$keep" "$errs"
    return 1
  fi

  cat "$errs" >> "$archive" 2>/dev/null && rm -f "$errs"
  # Appended, never moved into place: a record written by an agent that finished
  # after the rename above is already sitting in this file.
  cat "$keep" >> "$file" 2>/dev/null && rm -f "$keep"
  rm -f "$staged"

  issue_spool_cap_archive "$archive"
  return 0
}

# Direct invocation dispatch. Sourcing the file defines the functions and runs
# nothing, so the hooks can source it or shell out to it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    key)          issue_spool_key "${1:-$PWD}" "${2:-}" ;;
    read-keys)    issue_spool_read_keys "${1:-$PWD}" "${2:-}" ;;
    path)         issue_spool_path "${1:-$PWD}" "${2:-}" ;;
    archive-path) issue_spool_archive_path "${1:-$PWD}" "${2:-}" ;;
    append)       issue_spool_append "${1:-$PWD}" "${2:-}" "${3:-}" ;;
    note)         issue_spool_note "${1:-$PWD}" "${2:-}" "${3:-}" "${4:-}" ;;
    raw)          f="$(issue_spool_collect "${1:-$PWD}" "${2:-}")"; [ -s "$f" ] && cat "$f"; rm -f "$f"; exit 0 ;;
    pending)      issue_spool_pending "${1:-$PWD}" "${2:-}" ;;
    has-findings) issue_spool_has_findings "${1:-$PWD}" "${2:-}" ;;
    archive)      f="$(issue_spool_archive_path "${1:-$PWD}" "${2:-}")"; [ -s "$f" ] && cat "$f"; exit 0 ;;
    clear)        issue_spool_clear "${1:-$PWD}" "${2:-}" ;;
    file-errors)  issue_spool_file_errors "${1:-$PWD}" "${2:-}" ;;
    file-muted)   issue_spool_file_muted "${1:-$PWD}" "${2:-}" ;;
    muted-summary) issue_spool_muted_summary "${1:-$PWD}" "${2:-}" ;;
    *)            echo "issue-spool.sh: unknown command '${cmd}'" >&2; exit 2 ;;
  esac
fi
