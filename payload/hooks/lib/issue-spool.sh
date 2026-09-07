#!/usr/bin/env bash
#
# issue-spool.sh: the durable holding place for issue candidates found by
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
#   issue-spool.sh reach-report                which pending keys no session can open
#
# `raw` and `archive` exit 0 on an empty spool. They used to exit non-zero,
# which kills any caller running under errexit on the ordinary empty case, and
# that behaviour was documented for `pending` only.
#
# The spool lives OUTSIDE ~/.claude on purpose. Anything under ~/.claude is
# auto committed and pushed to Dan's other Macs within seconds, and transcript
# derived notes are not config.
set -uo pipefail

# WHERE THE SPOOL LIVES, resolved every time it is needed rather than once when
# this file is read. A caller that SOURCES this library and sets
# CLAUDE_ISSUE_SPOOL_DIR afterwards used to be silently ignored, because the
# root had already been bound to the default: test-blank-check-cost.sh did
# exactly that and wrote a fake finding into the real spool on every run,
# 120 of them on one machine before anyone noticed (L2, L175). Fixing that one
# caller would have left the trap armed for the next, so it is fixed here (L30).
issue_spool_root() { printf '%s' "${CLAUDE_ISSUE_SPOOL_DIR:-$HOME/.claude-issue-spool}"; }

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
# THE 12 HEX CHARACTERS A KEY IS MADE OF (claude-config#281).
#
# `shasum` on macOS is a perl script and costs 11.5ms a call, against openssl's 5.2ms, measured on
# this Mac 2026-09-03. A key is computed on nearly every operation here, so one run of
# test-subagent-issue-harvest.sh made 690 of them, about a quarter of that suite's whole cost, and
# every one of them was followed by a `cut` as well.
#
# THE VALUE MUST NOT CHANGE BY A CHARACTER. A key is a FILENAME, so a different digest strands
# every record already pending under the old name with nothing left that could find it (L92). Both
# tools compute the same SHA-1; only the printing differs, and the two openssl builds a Mac can
# have differ from each other (Homebrew's OpenSSL prints "SHA1(stdin)= <hex>", the system LibreSSL
# prints the bare hex). So the LAST whitespace separated field is taken, and it is accepted only
# when it is exactly 40 hex characters. Anything else, including openssl not being installed at
# all, falls back to shasum, which is the reference implementation the suite pins this against.
#
# The fallback is correct and merely slower, which is why it is silent, and why the suite proves
# the fast path is the one actually being taken rather than trusting an agreement that both halves
# could satisfy by running shasum (L289, L159).
issue_spool_sha12() { # sha12 <text> -> the first 12 hex characters of its SHA-1
  local tool out hex
  tool="${CLAUDE_ISSUE_SPOOL_SHA-openssl}"
  hex=""
  if [ -n "$tool" ] && command -v "$tool" >/dev/null 2>&1; then
    out="$(printf '%s' "$1" | "$tool" dgst -sha1 2>/dev/null)" || out=""
    hex="${out##* }"
    case "$hex" in *[!0-9a-f]*) hex="" ;; esac
    [ "${#hex}" -eq 40 ] || hex=""
  fi
  if [ -z "$hex" ]; then
    out="$(printf '%s' "$1" | shasum 2>/dev/null)"
    hex="${out%% *}"
  fi
  printf '%s' "${hex:0:12}"
}

issue_spool_key() { # key <dir> [session-transcript]
  local dir="${1:-$PWD}" transcript="${2:-}" common root
  if [ -n "$transcript" ]; then
    root="$(dirname "$transcript")"
    if [ -d "$root" ]; then
      root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
      issue_spool_sha12 "$root"
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
  issue_spool_sha12 "$root"
}

issue_spool_path()         { printf '%s/%s.jsonl' "$(issue_spool_root)" "$(issue_spool_key "${1:-$PWD}" "${2:-}")"; }
issue_spool_archive_path() { printf '%s/%s.filed.jsonl' "$(issue_spool_root)" "$(issue_spool_key "${1:-$PWD}" "${2:-}")"; }

# Every key a reader must consult: the session's, plus the directory's, so that
# nothing already spooled the old way is stranded the moment this ships. The
# directory key is a TRANSITION path, not a second home: writes only ever go to
# the first key, so these files drain and stop being written to.
#
# It is still read, and after claude-config#217 it is the ONLY thing that reads what the one time
# migration could not place. Both Macs ran that migration on 2026-09-03 and it was deleted in the
# same change; the other Mac reported five records moved, 158 before and 158 after, and one
# directory it could not place, whose records stay under this key. Removing this read would strand
# them (L92, L211).
#
# Deduplicated, because when no transcript is supplied the two are the same key
# and reading it twice would double every count a person is shown.
issue_spool_path_for_key()    { printf '%s/%s.jsonl' "$(issue_spool_root)" "$1"; }
issue_spool_archive_for_key() { printf '%s/%s.filed.jsonl' "$(issue_spool_root)" "$1"; }

# The pending records a reader should see, from every key it must consult,
# concatenated into one throwaway file. Every reader goes through this so that
# "which spools count as mine" is answered in ONE place: two readers answering it
# separately is how the split this fixes came about.
#
# Prints the temp file's path. The caller removes it.
# Beside the collected records it writes a "<tmp>.sources" file naming each spool file it actually
# read and how many records it held. A reader that shows a person a list of findings has to be
# able to name where they came from, because the one question a re-served list raises is whether
# it is the same file a clear already emptied, and nothing could answer it (claude-config#260).
#
# A FILE rather than a variable, and that is not a style choice: every caller here takes the tmp
# path through `$(...)`, which is a subshell, so a global set in this function is discarded on the
# way out. The first version did exactly that and the source line silently never appeared.
issue_spool_collect() { # collect <dir> [session-transcript]
  local tmp key file n
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-spool-read.XXXXXX")" || return 1
  : > "$tmp.sources"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    file="$(issue_spool_path_for_key "$key")"
    if [ -s "$file" ] && cat "$file" >> "$tmp" 2>/dev/null; then
      n="$(grep -c . "$file" 2>/dev/null || true)"
      printf '%s (%s records)\n' "$(basename "$file")" "${n:-0}" >> "$tmp.sources"
    fi
  done <<COLLECT_KEYS
$(issue_spool_read_keys "${1:-$PWD}" "${2:-}")
COLLECT_KEYS
  printf '%s' "$tmp"
}

issue_spool_read_keys() { # read-keys <dir> [session-transcript]
  local primary legacy
  primary="$(issue_spool_key "${1:-$PWD}" "${2:-}")"
  printf '%s\n' "$primary"
  if [ -n "${2:-}" ]; then
    legacy="$(issue_spool_key "${1:-$PWD}")"
    [ "$legacy" = "$primary" ] || printf '%s\n' "$legacy"
  fi
  # Every OTHER pending key whose records were written from this project.
  #
  # A harvested agent's records are keyed by its TRANSCRIPT's directory, and a review that has a
  # transcript therefore reads two keys. The `clear` it then tells Claude to run carries no transcript,
  # so it computed only the directory key and filed only that one: measured 2026-08-31 in the Overture
  # repo, the clear reported success and the identical 27 findings came back at the very next review,
  # with 56KB still pending under the transcript key. A clear that leaves behind what the reader just
  # showed is worse than one that fails, because it reports the work as settled and the same list
  # arrives again indistinguishable from new findings (L98).
  #
  # Matched on the record's OWN `cwd` resolved through `issue_spool_key`, not on the raw path, so an
  # agent that ran in a git worktree is matched to the checkout it belongs to exactly as the append path
  # keys it. That is also what keeps this from being "file everything": another project's pending
  # findings resolve to a different key and are left alone, which has its own test.
  issue_spool_keys_written_from "${1:-$PWD}" "$primary" "${legacy:-}"
}

# Echo the pending keys, other than the ones already named, whose first record names a cwd belonging to
# this project. One line read per pending file, so the cost is a handful of reads.
issue_spool_keys_written_from() { # keys-written-from <dir> [already-named...]
  local dir="${1:-$PWD}" root mine file key cwd named matched
  shift || true
  named=" $* "
  mine="$(issue_spool_key "$dir")"
  root="$(issue_spool_root)"
  [ -d "$root" ] || return 0
  for file in "$root"/*.jsonl; do
    [ -f "$file" ] || continue
    case "$file" in *.filed.jsonl) continue ;; esac
    [ -s "$file" ] || continue
    key="$(basename "$file" .jsonl)"
    case "$named" in *" $key "*) continue ;; esac
    # EVERY record, not just the first (claude-config#294). Reading only the head meant a single
    # unattributable record at the top of a file stranded every record behind it, whatever their
    # own cwd said, and that is how 106 findings sat in one file nothing could reach.
    #
    # The stamped project key first, because it needs no resolution at all and is right even when
    # the directory has been deleted outright.
    if grep -q "\"project\"[[:space:]]*:[[:space:]]*\"$mine\"" "$file" 2>/dev/null; then
      printf '%s\n' "$key"
      continue
    fi
    # Then the cwds, for every record written before the stamp existed. Deduplicated, because a
    # file holds one cwd repeated far more often than it holds many, and each distinct one costs a
    # digest.
    matched=0
    while IFS= read -r cwd; do
      [ -n "$cwd" ] || continue
      [ "$matched" -eq 1 ] && continue
      [ "$(issue_spool_key "$cwd")" = "$mine" ] && { matched=1; continue; }
      # A worktree resolves through the checkout it belongs to, which is what its own key would
      # have been while it still existed. Pure string work, so it costs nothing and it is the only
      # thing that can reach the backlog written from a worktree that has since been removed.
      case "$cwd" in
        */.claude/worktrees/*)
          [ "$(issue_spool_key "${cwd%/.claude/worktrees/*}")" = "$mine" ] && matched=1 ;;
      esac
    done <<KEYS_FROM_CWDS
$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | sort -u)
KEYS_FROM_CWDS
    [ "$matched" -eq 1 ] || continue
    printf '%s\n' "$key"
  done
}

# A record is one line of JSON. Anything else breaks the one-record-per-line
# invariant every reader depends on, and a broken line is then dropped by the
# reader, so a bad caller would corrupt the spool and see no complaint. Refusing
# here means the caller can fall back to somewhere the record still survives.
issue_spool_append() { # append <dir> <json-record>
  local file record count
  # A TEST RUN may not write into the real store (claude-config#278, L2). The bracket in
  # run-all-tests.sh is a DETECTION: it says afterwards that a record landed in Dan's live spool,
  # by which time it has. Two were sitting there when this was written, agent `suite-fixture`, from
  # a scratch copy of the suite assembled by hand, which carried no CLAUDE_ISSUE_SPOOL_DIR and so
  # wrote where the library defaults to. Asking every suite to remember the seam leaves the ones
  # that forget writing into live data, and those are the ones nobody is looking at.
  #
  # So it is refused here, in the one function every writer goes through, which is the one place it
  # can be applied and the one place it can be forgotten from (L30). claude-sync's
  # apply_payload_to_local made the same decision one layer along in claude-config#277 and this is
  # deliberately the same shape.
  #
  # Judged on the ROOT that was actually resolved rather than on whether the override was set, so a
  # suite that sets it and points it at the live store is refused too: the override is not the
  # question, the destination is.
  if [ -n "${CLAUDE_SUITE_RUN_ID:-}" ] && [ "$(issue_spool_root)" = "${HOME%/}/.claude-issue-spool" ]; then
    echo "issue-spool: refusing to write into the real spool at $(issue_spool_root): this is running under a test suite (CLAUDE_SUITE_RUN_ID=$CLAUDE_SUITE_RUN_ID). Set CLAUDE_ISSUE_SPOOL_DIR to that suite's own throwaway directory before writing." >&2
    return 3
  fi
  file="$(issue_spool_path "$1" "${3:-}")"; record="${2:-}"
  [ -n "$record" ] || return 2
  case "$record" in *$'\n'*) return 2 ;; esac
  # STAMPED while a test run is in progress (claude-config#275). run-all-tests.sh brackets a run
  # with a listing of the real spool and fails the run if anything was added, and it used to decide
  # WHO added it from the directory the record names. That cannot tell a suite from a second Claude
  # session working in the same repo, which is the normal case on this machine, so a green run was
  # failed by another session's harvest.
  #
  # The stamp answers it positively instead: a record carrying one was written under a test run and
  # is the L2 violation the bracket exists to catch, and a record carrying none was not, wherever it
  # came from. Every writer goes through this function, so this is the one place it can be applied
  # and the one place it can be forgotten from (L30).
  #
  # Nothing is added when the variable is unset, so a record written in ordinary use is byte for
  # byte what it was before this existed.
  # Stamped with the run id while a test run is going, and with the SESSION that produced it, so a
  # clear can file its own records and leave everybody else's pending (claude-config#222). Neither
  # is written when it is not known, so a record made where there is no session is byte for byte
  # what it was before this existed, and a record that already names a session keeps it: the
  # harvest reads the AGENT's session out of the hook payload and knows better than a lookup does.
  #
  # AND THE PROJECT KEY, resolved HERE, while the directory the record names is guaranteed to still
  # exist (claude-config#294). Attribution used to re-resolve a record's `cwd` when a clear went
  # looking, and an agent's cwd is routinely a git worktree that every AGENTS.md tells people to
  # remove once the PR merges. Once it is gone the resolution falls back to hashing a path that is
  # not there and the record belongs to no project. Measured on this Mac 2026-09-03: 111 of 170
  # pending records were written from a worktree cwd, so this was the majority case.
  #
  # Stamping it cannot help a record already written, which is the whole backlog (L223), so the
  # reader still resolves `cwd` as well. This is the half that will be right from now on.
  #
  # ONE python3 for all of it. The two branches this replaces did the same parse and dump, and the
  # second existed only to validate, so folding them costs nothing and the validation still happens:
  # a record that does not parse fails here exactly as before.
  local _sp_sid _sp_proj
  _sp_sid="$(issue_spool_session_id "${3:-}")"
  _sp_proj="$(issue_spool_key "${1:-$PWD}")"
  record="$(printf '%s' "$record" | CLAUDE_SUITE_RUN_ID="${CLAUDE_SUITE_RUN_ID:-}" \
      CLAUDE_SPOOL_SESSION="$_sp_sid" CLAUDE_SPOOL_PROJECT="$_sp_proj" python3 -c '
import json, os, sys
rec = json.loads(sys.stdin.read())
if isinstance(rec, dict):
    if os.environ.get("CLAUDE_SUITE_RUN_ID"):
        rec["suite_run"] = os.environ["CLAUDE_SUITE_RUN_ID"]
    if os.environ.get("CLAUDE_SPOOL_SESSION") and not rec.get("session"):
        rec["session"] = os.environ["CLAUDE_SPOOL_SESSION"]
    if os.environ.get("CLAUDE_SPOOL_PROJECT") and not rec.get("project"):
        rec["project"] = os.environ["CLAUDE_SPOOL_PROJECT"]
print(json.dumps(rec))' 2>/dev/null)" || return 2
  [ -n "$record" ] || return 2
  case "$record" in *$'\n'*) return 2 ;; esac
  mkdir -p "$(issue_spool_root)" 2>/dev/null || return 1
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
# This session's transcript, resolved from the environment, or nothing when it cannot be resolved.
#
# CLAUDE.md tells every dispatched agent to record a finding with the three argument
# `note "$PWD" "<finding>" "<who>"`, which passes no transcript, so the key fell back to the
# agent's own directory. For an agent working in a repo NESTED inside its session's folder that is
# a different key from the one every review reads, so the documented capture path filed where
# nobody looks (claude-config#214). The instruction and the mechanism disagreed, and the
# instruction is the half a person follows.
#
# A Bash tool call carries CLAUDE_CODE_SESSION_ID but not the transcript path, and the transcript
# is `<projects root>/<encoded project>/<session id>.jsonl`, so the id is enough to FIND it without
# knowing which project directory encoded it.
#
# Exactly one match, or nothing: two files answering to one session id is a question this cannot
# resolve, and picking the first would key on whichever the glob happened to sort first (L521).
# Nothing is not a failure here, it is the fallback to the directory key, which is what every
# caller did before this existed.
# WHICH SESSION a record belongs to (claude-config#222).
#
# The spool is keyed on the PROJECT, deliberately, so an agent working in a worktree reaches the
# same spool as the session that reads it. Dan routinely runs several sessions against one project,
# and that keying cannot tell them apart: whichever session's Stop hook fires first is handed EVERY
# session's findings and is then told to clear, which files the others' before they have ever been
# seen. Measured in one PostRoll session on 2026-08-29: four consecutive reviews were each handed
# the same 25 findings about work that session had never touched, and the findings had to be copied
# aside by hand each time.
#
# A record therefore carries the session that produced it, and a clear files only its own. The
# project keying is untouched, so the worktree case it was written for still works.
issue_spool_session_id() { # [transcript] -> the session's id, or nothing when it cannot be known
  # GIVEN ONE WINS, the same rule issue_spool_note follows for the transcript itself: a caller that
  # names a transcript is telling this which session it means, and a lookup through the environment
  # answers about whichever session happens to be running the command. A hook clearing on behalf of
  # a session is not always that session's own process.
  local t="${1:-}"
  if [ -n "$t" ]; then
    t="${t##*/}"
    printf '%s' "${t%.jsonl}"
    return 0
  fi
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && printf '%s' "$CLAUDE_CODE_SESSION_ID"
  return 0
}

issue_spool_session_transcript() { # session-transcript
  local id="${CLAUDE_CODE_SESSION_ID:-}" f found="" n=0
  [ -n "$id" ] || return 0
  for f in "${CLAUDE_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"/*/"$id".jsonl; do
    [ -f "$f" ] || continue
    found="$f"; n=$(( n + 1 ))
  done
  [ "$n" -eq 1 ] && printf '%s' "$found"
  return 0
}

issue_spool_note() { # note <dir> <finding text> [who reported it] [session-transcript]
  local dir="${1:-$PWD}" text="${2:-}" source="${3:-self-reported}" transcript="${4:-}" record
  # Given one wins. A caller that knows its transcript is the harvest, and it knows better than a
  # lookup through the environment does.
  [ -n "$transcript" ] || transcript="$(issue_spool_session_transcript)"
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
  if [ ! -s "$file" ]; then rm -f "$file" "$file.sources"; return 1; fi
  CLAUDE_SPOOL_MUTED="$MUTED_ERROR_REASONS" \
    CLAUDE_SPOOL_READER_SESSION="$(issue_spool_session_id "${2:-}")" python3 - "$file" "${1:-}" <<'PY'
import datetime, json, os, re, sys

MAX_FINDINGS = 200
# How many characters of FINDINGS one review may carry. Measured 2026-08-29: a real project's
# pending list rendered to 50,030 characters, all of which would have gone into a single MESSAGE. A
# count cap does not bound that, because one 500 character finding costs what twenty short ones do,
# so the limit is on size.
#
# Raised from 8,000 to 40,000 by claude-config#241, because the reason for the small number went
# away and the number stayed. Since claude-config#243 the findings go to a FILE the reader opens,
# not into the reason, so the cost of showing one is a line in a file rather than a line on Dan's
# screen. At 8,000 a spool holding 219 findings showed 4 and said "and 215 more not shown here",
# and the clear that follows the picker files ALL of them, so everything past the first few was
# archived unread. Showing them is what makes it possible to act on more than four (L526).
FINDING_BUDGET = int(os.environ.get("CLAUDE_ISSUE_SPOOL_FINDING_BUDGET") or 40000)
MUTED = {r for r in (os.environ.get("CLAUDE_SPOOL_MUTED") or "").split("\n") if r.strip()}
# Whose review this is. Empty when it cannot be known, and then nothing is marked: marking every
# finding as somebody else's would be worse than marking none (L11).
READER_SESSION = os.environ.get("CLAUDE_SPOOL_READER_SESSION") or ""
# WHEN OWNERSHIP EXPIRES (claude-config#326). A record belongs to the session that produced it, and
# only that session may settle it, which is right while that session is still running. A session
# that has ended never runs another review, so past this window the record is treated exactly like
# one naming no session at all: shown to whoever is reviewing, and filed by whoever clears. Filing
# it away unread instead would empty the spool while losing the finding, which is worse.
CLAIM_AFTER = int(os.environ.get("CLAUDE_ISSUE_SPOOL_CLAIM_AFTER") or 604800)

# ---- how old a finding is, and whether the code it names has moved (claude-config#202) ----
# A finding was offered as current however old it was, and one project's oldest pending findings
# cited file and line references from eleven days earlier. Code moves, so a finding can send you
# to a line number that no longer means what it did, and the time is spent before you find out.
#
# There is deliberately NO AGE THRESHOLD. The archived findings on this Mac were measured on
# 2026-09-02: 618 of them, ages spanning 1.0 to 17.2 days, median 13.0, with p25 at 3.9 and p75 at
# 15.6. Every one of those days is inside the dense middle of that distribution, so any threshold
# picked from it would move dozens of findings across at once on a small shift and report the same
# population as a sudden regression (L172). The range is also bounded by the spool's own age
# rather than by anything about findings, so it cannot support one yet.
#
# What CAN be measured is the thing the issue is actually about: whether the file a finding names
# has changed since the finding was written. That is evidence rather than a guess, it needs no
# number, and it says exactly what has gone stale. A finding naming no file that resolves gets no
# claim either way, because silence is better than a guess about which files matter (L93).
PROJECT = sys.argv[2] if len(sys.argv) > 2 else ""
PATH_RE = re.compile(
    r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:py|js|ts|tsx|jsx|sh|swift|rb|go|rs|java|kt|"
    r"md|json|yml|yaml|sql|css|html|txt)\b")


def _parsed(ts):
    try:
        return datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except Exception:
        return None


def age_words(ts):
    t = _parsed(ts)
    if t is None:
        return ""
    now = datetime.datetime.now(datetime.timezone.utc)
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    secs = (now - t).total_seconds()
    if secs < 0:
        # A timestamp in the FUTURE is not "brand new": it is a clock nobody can rely on, and
        # rendering it as an age would be the most reassuring reading available (L11).
        return "its timestamp is in the future"
    for cut, div, word in ((3600, 60, "minute"), (86400, 3600, "hour"), (10 ** 9, 86400, "day")):
        if secs < cut:
            n = int(secs // div)
            return "%d %s%s ago" % (n, word, "" if n == 1 else "s")
    return ""


def unclaimed(ts):
    """Has nobody claimed this for long enough that anybody may?"""
    t = _parsed(ts)
    if t is None:
        # An unreadable timestamp cannot be aged, so it stays owned. Erring the other way would
        # hand a record to a stranger on the strength of a field nothing could read (L50).
        return False
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() >= CLAIM_AFTER


def moved_since(text, ts):
    t = _parsed(ts)
    if t is None or not PROJECT:
        return ""
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    for m in PATH_RE.finditer(text):
        rel = m.group(0).lstrip("./")
        full = os.path.join(PROJECT, rel)
        if not os.path.isfile(full):
            continue
        try:
            mt = datetime.datetime.fromtimestamp(os.path.getmtime(full), datetime.timezone.utc)
        except OSError:
            continue
        if mt > t:
            return rel
    return ""

shown = 0
seen = set()
errors = {}
unparsed = []
corrupt = 0
already_seen = 0
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
    # ALREADY SHOWN TO THIS READER, AND NOT ITS TO SETTLE (claude-config#322). A clear stamps the
    # records it had to leave behind with the session that was shown them, so a review is not
    # handed the same unsettleable finding every time it runs. The record is untouched for the
    # session that owns it: this only stops the repeat here.
    #
    # Counted rather than dropped, and the count is printed at the end only when something else was
    # shown, so these can never be the reason a review fires. A notice carrying no action,
    # delivered every turn, is what teaches a person to skip the whole panel (L36).
    if READER_SESSION and READER_SESSION in (rec.get("seen_by") or []) \
       and not unclaimed(rec.get("ts", "")):
        already_seen += 1
        continue
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
            findings.append((where, rec.get("ts", "?"), f, rec.get("session") or ""))
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
for where, ts, f, sess in findings[:MAX_FINDINGS]:
    age = age_words(ts)
    line = "FINDING (%s, %s%s): %s" % (where, ts, (", " + age) if age else "", f)
    # A finding another session's agents produced is SAID to be one (claude-config#222). The spool
    # is keyed on the project, so a review sees every session's findings, and the reviewing session
    # has no context for judging one it did not cause: it will either file it badly or drop it. Its
    # own review will still be offered it, because a clear now files only its own session's.
    if READER_SESSION and sess and sess != READER_SESSION:
        if unclaimed(ts):
            # The advice above would be wrong here: the session that owns it has had its window and
            # is not coming back, so telling this reader to leave it to that review names an event
            # that will not happen (L111).
            line += ("  [from another session working in this project, which has not settled it in "
                     "long enough that nobody is going to, so it is yours to judge and yours to "
                     "file]")
        else:
            line += ("  [from another session working in this project, which has not seen it yet, "
                     "so leave it to that session's own review unless you can judge it]")
    moved = moved_since(f, ts)
    if moved:
        line += ("  [%s has changed since this was written, so any line number in it "
                 "may have moved]" % moved)
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
    print("...and %d more findings not shown here. THEY ARE STILL FILED AWAY by the clear that "
          "follows the picker, so say in your reply that this many went unread."
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

# Only when the review is happening anyway: `shown` is what decides whether one fires at all, so
# this deliberately does not increment it. A run whose whole content is records somebody else must
# settle produces no review, which is the correct outcome (L36).
if already_seen and shown:
    print("(%d finding(s) here belong to other sessions and have already been shown to this one, "
          "so they are not repeated. They stay pending for those sessions' own reviews.)"
          % already_seen)

if corrupt:
    shown += 1
    print("UNREADABLE SPOOL RECORDS: %d line(s) in the spool are not valid records and were "
          "skipped. Something wrote to it that should not have." % corrupt)

sys.exit(0 if shown else 1)
PY
  rc=$?
  # Named only when something was actually shown, because a source line over an empty report is a
  # line about nothing. It goes LAST, so it cannot be mistaken for a finding, and it names the
  # same files `clear` names when it files them: the two are meant to be compared.
  if [ "$rc" -eq 0 ] && [ -s "$file.sources" ]; then
    printf 'SPOOL SOURCE: %s, under %s. A clear files exactly these, and says how many it filed; if this list comes back after one, that is the fact to report.\n' \
      "$(tr '\n' ';' < "$file.sources" | sed 's/;$//; s/;/, /g')" "$(issue_spool_root)"
  fi
  rm -f "$file" "$file.sources"
  return $rc
}

# CAN ANYBODY READ THIS? (claude-config#242)
#
# A review opens exactly one key, the one derived from its own session's transcript directory, so a
# finding written under a key no session ever resolves to is never offered to anybody. The harvest
# reports success, the review reports nothing to show, and both are telling the truth about
# different files (L98). Measured on 2026-08-31: 142 distinct keys, and the records inside named
# about 42 distinct working directories, which says nothing about WHERE the split is (L203) but does
# establish that nothing anywhere reports whether a written finding is reachable.
#
# This answers it by construction rather than by inference: every directory under the transcript
# root is a key a session can resolve to, so a pending key that is not one of them is a key no
# review will ever open.
issue_spool_reach_report() { # reach-report -> 0 when every pending key is reachable
  local root reachable file key n unreachable="" total=0 held=0 empty=0 dirs=0 d
  root="$(issue_spool_root)"
  [ -d "$root" ] || { echo "issue-spool: there is no spool at $root, so there is nothing to report on."; return 0; }
  reachable="$(mktemp "${TMPDIR:-/tmp}/claude-spool-reach.XXXXXX")" || return 1
  for d in "${CLAUDE_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"/*; do
    [ -d "$d" ] || continue
    dirs=$(( dirs + 1 ))
    printf '%s\n' "$(issue_spool_key "" "$d/x.jsonl")" >> "$reachable"
  done
  # Reading NO transcript directory is not a clean answer: every key would read as unreachable and
  # the report would be a wall of false alarms (L98, L36).
  if [ "$dirs" -eq 0 ]; then
    rm -f "$reachable"
    echo "issue-spool: no session transcript directory was found under ${CLAUDE_TRANSCRIPT_ROOT:-$HOME/.claude/projects}, so which keys are reachable could not be worked out. Nothing is being reported as unreachable." >&2
    return 1
  fi
  for file in "$root"/*.jsonl; do
    [ -e "$file" ] || continue
    case "$file" in *.filed.jsonl) continue ;; esac
    total=$(( total + 1 ))
    if [ ! -s "$file" ]; then empty=$(( empty + 1 )); continue; fi
    held=$(( held + 1 ))
    key="$(basename "$file")"; key="${key%.jsonl}"
    grep -qx -- "$key" "$reachable" 2>/dev/null && continue
    n="$(grep -c . "$file" 2>/dev/null || true)"
    unreachable="$unreachable
  $key.jsonl (${n:-0} record(s))"
  done
  rm -f "$reachable"
  echo "issue-spool: $total pending file(s) under $root, $held holding records and $empty empty, against $dirs session transcript director(ies)."
  if [ -n "$unreachable" ]; then
    echo "issue-spool: these hold findings under a key NO session resolves to, so no review will ever open them:$unreachable" >&2
    echo "  They were written by an agent whose session's transcript directory no longer exists, or under the older directory key. 'issue-spool.sh raw <dir>' reads one by hand." >&2
    return 1
  fi
  echo "issue-spool: every key holding a finding is one a session can resolve to."
  return 0
}

# Does the spool hold an actual FINDING, as opposed to only records of harvests
# that failed or looked and found nothing? The review bypasses its cooldown on
# this answer alone: a recurring failure keeps the spool permanently non-empty,
# and interrupting every turn over it would train the review to be ignored.
issue_spool_has_findings() { # has-findings <dir> [session-transcript] -> exit 0 when a finding is pending
  local file rc; file="$(issue_spool_collect "$1" "${2:-}")" || return 1
  if [ ! -s "$file" ]; then rm -f "$file" "$file.sources"; return 1; fi
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
  rm -f "$file" "$file.sources"
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
  if [ ! -s "$file" ]; then rm -f "$file" "$file.sources"; return 1; fi
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
  rm -f "$file" "$file.sources"
  return $rc
}

# Filing RENAMES the pending file out of the way first, then drains the renamed
# copy into the archive. Copying and then truncating is two steps with no lock,
# and anything a finishing agent appends between them is destroyed: not
# archived, not shown, gone. Filing runs exactly when background agents are most
# likely to be finishing (right after the picker is answered), so that window is
# the normal case rather than a corner. After the rename an appender writes to a
# fresh file and cannot be caught by the drain at all.
# It SAYS what it did (claude-config#260). Exiting 0 in silence made "it filed 49 records" and "it
# matched nothing" the same event at the call site, and CLAUDE.md tells Claude to run this by hand
# after a picker, so the call site is a person reading a terminal. When the same findings then
# came back at the next review there was no way to tell a clear that had missed them from a
# harvest that had written them again.
issue_spool_clear() { # clear <dir> [session-transcript] -> file the pending records
  local key rc=0 total=0 left_total=0 n nleft pair keys=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    keys="${keys:+$keys, }$key"
    if pair="$(issue_spool_clear_key "$key" "$(issue_spool_session_id "${2:-}")")"; then
      n="${pair%% *}"; nleft="${pair##* }"
      [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && total=$(( total + n ))
      [ -n "$nleft" ] && [ "$nleft" -gt 0 ] 2>/dev/null && left_total=$(( left_total + nleft ))
    else
      # The counts still matter on a failure: the records this could not file are named by the
      # message clear_key already printed, and the ones it LEFT for other sessions are a separate
      # fact that a failure elsewhere does not make untrue.
      pair="${pair:-0 0}"; nleft="${pair##* }"
      [ -n "$nleft" ] && [ "$nleft" -gt 0 ] 2>/dev/null && left_total=$(( left_total + nleft ))
      rc=1
    fi
  done <<CLEAR_KEYS
$(issue_spool_read_keys "${1:-$PWD}" "${2:-}")
CLEAR_KEYS
  # "nothing was pending" is only true when nothing FAILED. A key whose records could not be
  # appended to its archive also totals zero, and saying nothing was pending over that would be an
  # empty answer printed over a failure, with the loud message just above it contradicted by the
  # reassuring one below (L10, L11). The failure has already named itself and where the records
  # are; what this must not do is add a sentence saying there were none.
  # WHAT IT LEFT, and why it could not take it (claude-config#322). Said whether or not anything
  # was filed, because "I filed three of yours" and "and four here are not yours to settle" are two
  # different facts and the second is the one that explains why the same findings keep appearing.
  # The records have been marked as seen by this session, so this review will not be handed them
  # again; they are untouched for the session that owns them.
  if [ "$left_total" -gt 0 ]; then
    echo "issue-spool: left $left_total record(s) that belong to other sessions working in this project. A clear files only the calling session's, so these are not yours to settle: they stay for those sessions' own reviews. They are now marked as seen by this session, so they will not be shown here again."
  fi
  if [ "$total" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$left_total" -gt 0 ]; then
    # DISTINCT from "nothing was pending" (claude-config#322). Both used to read identically, and
    # the second told the reader to run the line the findings file names, which is exactly the line
    # they had just run: a remedy that cannot change the state it names (L11, L111). Everything
    # under this key was somebody else's, which is not the same event as an empty key and does not
    # share its advice.
    echo "issue-spool: nothing of THIS session's was pending under the key(s) this project reads (${keys:-none}), so nothing was filed. That is not an empty spool and not a wrong key: the records under those key(s) belong to other sessions, and no command run here can settle them."
  elif [ "$total" -eq 0 ] && [ "$rc" -eq 0 ]; then
    # AND WHETHER THE SPOOL IS STILL HOLDING SOMETHING THIS DID NOT MATCH (claude-config#287).
    # "nothing was pending" and "nothing was pending under the key I happened to compute" read
    # identically, and only the second was ever true in the failure this comes from: 138 records
    # sat under nine keys while a clear reported an empty answer and everybody believed it (L11,
    # L98). A count of what is left turns that silence into something a reader can act on.
    #
    # An empty spool gains no such sentence: on the normal case it would be noise, and a line
    # printed every time distinguishes nothing (L36).
    local elsewhere=0 f n
    for f in "$(issue_spool_root)"/*.jsonl; do
      [ -e "$f" ] || continue
      case "$f" in *.filed.jsonl) continue ;; esac
      [ -s "$f" ] || continue
      n="$(grep -c . "$f" 2>/dev/null || true)"
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      elsewhere=$(( elsewhere + n ))
    done
    if [ "$elsewhere" -gt 0 ]; then
      echo "issue-spool: nothing was pending under the key(s) this project reads (${keys:-none}), so nothing was filed. The spool at $(issue_spool_root) is still holding $elsewhere pending record(s) under other key(s), so if a review has just shown you findings, this command was not given the same key it read them from: run the line the findings file names instead."
    else
      echo "issue-spool: nothing was pending under the key(s) this project reads (${keys:-none}), so nothing was filed."
    fi
  fi
  return $rc
}

# Prints the number of records it filed, so the caller can total them. Says nothing on stdout when
# there was nothing to file; the caller reports that once for the whole run rather than once per key.
# Prints TWO numbers, "<filed> <left for other sessions>". The second exists because a clear that
# files nothing and a clear that files nothing because everything under this key belongs to another
# session had the same answer, and the advice given for the second was to run the command that had
# just been run (claude-config#322).
issue_spool_clear_key() { # clear-key <key> [session id]
  local file archive staged count mine others sid="${2:-}" left=0
  file="$(issue_spool_path_for_key "$1")"
  archive="$(issue_spool_archive_for_key "$1")"
  [ -s "$file" ] || { printf '0 0'; return 0; }
  mkdir -p "$(issue_spool_root)" 2>/dev/null || return 1
  staged="${file}.filing.$$"
  mv "$file" "$staged" 2>/dev/null || return 1

  # Test seam: the one instant that decides whether a concurrently arriving
  # record survives. Racing real processes proved nothing here, because the
  # window happened not to open (measured 2026-08-16, the broken version passed).
  [ -n "${CLAUDE_ISSUE_SPOOL_MIDCLEAR:-}" ] && eval "${CLAUDE_ISSUE_SPOOL_MIDCLEAR}"

  # SPLIT by session (claude-config#222). A record naming a different session belongs to a review
  # that has not happened yet, and filing it destroys work nobody has seen. A record naming NO
  # session cannot be attributed, so it is filed by whoever clears first, which is what every
  # record did before this existed.
  if [ -n "$sid" ]; then
    mine="${file}.mine.$$"; others="${file}.others.$$"
    CLAUDE_SPOOL_SESSION="$sid" python3 -c '
import datetime, json, os, sys
sid = os.environ["CLAUDE_SPOOL_SESSION"]
src, mine, others = sys.argv[1], sys.argv[2], sys.argv[3]
# OWNERSHIP EXPIRES (claude-config#326), on the same window and by the same reading as the render,
# or a record would be shown to this reader as theirs to file and then put back by the clear that
# follows, which is a worse loop than the one #322 removed (L70).
CLAIM_AFTER = int(os.environ.get("CLAUDE_ISSUE_SPOOL_CLAIM_AFTER") or 604800)


def unclaimed(ts):
    try:
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except Exception:
        # Unreadable age keeps it owned, so nothing is handed to a stranger on a field nothing
        # could read (L50).
        return False
    return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() >= CLAIM_AFTER
with open(src, encoding="utf-8", errors="replace") as fh,      open(mine, "w", encoding="utf-8") as m, open(others, "w", encoding="utf-8") as o:
    for line in fh:
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
            s = rec.get("session") if isinstance(rec, dict) else None
        except Exception:
            # An unreadable line has no session to read. It is filed rather than left pending for
            # ever, because nothing can ever claim it and the reader already reports it (L11).
            s = None
            rec = None
        if s and s != sid and not unclaimed(rec.get("ts", "") if isinstance(rec, dict) else ""):
            # MARKED AS SEEN BY THIS SESSION (claude-config#322), and nothing else about it is
            # touched: not filed, not moved, still owned by the session that produced it, still
            # offered to that session'"'"'s own review. What stops is being handed the same
            # unsettleable finding at every review here, which is what teaches a reader to skip
            # the whole panel.
            if isinstance(rec, dict):
                seen = rec.get("seen_by")
                if not isinstance(seen, list):
                    seen = []
                if sid not in seen:
                    seen.append(sid)
                rec["seen_by"] = seen
                o.write(json.dumps(rec, ensure_ascii=False) + "\n")
            else:
                o.write(line)
        else:
            m.write(line)
' "$staged" "$mine" "$others" 2>/dev/null || { mine=""; others=""; }
    if [ -n "$mine" ] && [ -f "$mine" ]; then
      # Appended, never written over: a record that arrived while this was going created a NEW
      # pending file, and replacing it would destroy exactly what the rename was protecting.
      if [ -s "$others" ]; then
        left="$(grep -c . "$others" 2>/dev/null || true)"
        case "$left" in ''|*[!0-9]*) left=0 ;; esac
        cat "$others" >> "$file" 2>/dev/null || true
      fi
      rm -f "$others" 2>/dev/null || true
      mv "$mine" "$staged" 2>/dev/null || true
    fi
  fi

  count="$(grep -c . "$staged" 2>/dev/null || true)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -eq 0 ]; then
    rm -f "$staged" 2>/dev/null || true
    printf '0 %s' "$left"
    return 0
  fi

  if cat "$staged" >> "$archive" 2>/dev/null; then
    rm -f "$staged"
    echo "issue-spool: filed $count record(s) from $(basename "$file") into $(basename "$archive"), under $(issue_spool_root)." >&2
  else
    # The staged copy is deliberately LEFT, and named. It is the only copy of those records, and a
    # drain that failed in silence is how an archive stops being written to without anybody
    # noticing, which is half of what claude-config#260 reported (L98, L11).
    echo "issue-spool: could NOT append $count record(s) to $(basename "$archive"). They are not lost: they are in $staged, and nothing has been added to the archive. Move that file by hand once you know why." >&2
    printf '0 %s' "$left"
    return 1
  fi

  issue_spool_cap_archive "$archive"
  printf '%s %s' "$count" "$left"
  return 0
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
  mkdir -p "$(issue_spool_root)" 2>/dev/null || return 1
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
  # Only when there is something to keep. `cat empty >> file` CREATES the pending file empty, and
  # that is where the spool's zero byte files come from: 131 of 157 on this Mac on 2026-08-31, one
  # per project whose failures were filed with no finding left behind (claude-config#242). They
  # make the spool look like it holds 157 keys when 26 hold anything, which is what made the
  # reachability question hard to answer in the first place.
  if [ -s "$keep" ]; then
    cat "$keep" >> "$file" 2>/dev/null && rm -f "$keep"
  else
    rm -f "$keep" "$file" 2>/dev/null || true
  fi
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
    sha12)        issue_spool_sha12 "${1:-}" ;;
    read-keys)    issue_spool_read_keys "${1:-$PWD}" "${2:-}" ;;
    path)         issue_spool_path "${1:-$PWD}" "${2:-}" ;;
    archive-path) issue_spool_archive_path "${1:-$PWD}" "${2:-}" ;;
    append)       issue_spool_append "${1:-$PWD}" "${2:-}" "${3:-}" ;;
    note)         issue_spool_note "${1:-$PWD}" "${2:-}" "${3:-}" "${4:-}" ;;
    raw)          f="$(issue_spool_collect "${1:-$PWD}" "${2:-}")"; [ -s "$f" ] && cat "$f"; rm -f "$f" "$f.sources"; exit 0 ;;
    pending)      issue_spool_pending "${1:-$PWD}" "${2:-}" ;;
    has-findings) issue_spool_has_findings "${1:-$PWD}" "${2:-}" ;;
    archive)      f="$(issue_spool_archive_path "${1:-$PWD}" "${2:-}")"; [ -s "$f" ] && cat "$f"; exit 0 ;;
    clear)        issue_spool_clear "${1:-$PWD}" "${2:-}" ;;
    file-errors)  issue_spool_file_errors "${1:-$PWD}" "${2:-}" ;;
    file-muted)   issue_spool_file_muted "${1:-$PWD}" "${2:-}" ;;
    muted-summary) issue_spool_muted_summary "${1:-$PWD}" "${2:-}" ;;
    reach-report) issue_spool_reach_report ;;
    *)            echo "issue-spool.sh: unknown command '${cmd}'" >&2; exit 2 ;;
  esac
fi
