#!/usr/bin/env bash
#
# ai-review-common.sh: what the two halves of the advisory AI review share (claude-config#433).
#
# Sourced, never executed. ai-review-on-push.sh STARTS a review after a push and ai-review-nudge.sh
# SHOWS it on a later prompt, and the two meet only through files in one state directory. Everything
# that decides whether they meet lives here once: where that directory is, how a repository is keyed,
# how long a review may take, and how the hook payload is read. Two copies of "which repository is
# this" would drift, and the drift is silent in the worst direction: a review written under one key
# and looked for under another is never shown, which reads exactly like a review that found nothing
# (L98, L613).
#
# The state lives under $HOME, never in the project (the brief's rule): a review is about a push,
# not part of the tree it reviewed, and a file in the project would be swept up by the next add.
#
# Environment:
#   AI_REVIEW_STATE_DIR         where reviews are kept (default $HOME/.claude/state/ai-review)
#   AI_REVIEW_DEADLINE_SECONDS  how long one review may run before it is recorded as unfinished
#                               (default 240; the test sets it to one second to drive the expiry)

AR_STATE_DIR="${AI_REVIEW_STATE_DIR:-$HOME/.claude/state/ai-review}"
AR_DEADLINE="${AI_REVIEW_DEADLINE_SECONDS:-240}"
case "$AR_DEADLINE" in ''|*[!0-9]*) AR_DEADLINE=240 ;; esac

# A finished review's name is <repo key>-<head sha>.txt, and while it runs the same name carries
# .pending on the end. The key is a hash of the repository's ORIGIN URL, so every checkout and
# worktree of one repository shares one key and a review started from a worktree is shown to a
# session sitting in the main checkout. A repository with no origin falls back to its top level
# path, which keys it as itself and nothing else.
#
# cksum rather than shasum, deliberately: the nudge runs on every prompt and shasum is a perl
# program that costs about 12 ms to start (measured 2026-09-18), while cksum is a C tool at about
# 2 ms with the same output on macOS and Linux (the POSIX CRC). A dozen repositories cannot collide
# on a 32 bit checksum in any way that matters here, and the two hooks share this one function so
# they can never disagree about a key.
ar_repo_key() {   # $1 = a directory inside the repository -> decimal checksum, or return 1
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)"
  if [ -z "$url" ]; then
    url="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$url" ] || return 1
    url="path:$url"
  fi
  printf '%s' "$url" | cksum | cut -d ' ' -f1
}

# The fields of a hook payload these hooks read, in one line separated by the unit separator:
#   cwd, session_id, tool_response.exit_code, tool_response.interrupted
# A field that is not there is empty. tool_response is an object for the Bash tool and may be a
# string for others, so a string is treated as carrying neither field rather than erroring.
ar_payload_fields() {   # $1 = payload JSON
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -j '
      ((.tool_response // {}) | if type == "object" then . else {} end) as $r
      | (.cwd // "") + "" + (.session_id // "") + ""
        + (($r.exit_code // "") | tostring) + "" + (($r.interrupted // "") | tostring)
    ' 2>/dev/null && return 0
  fi
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
r = d.get("tool_response")
if not isinstance(r, dict):
    r = {}
def s(v):
    return "" if v is None else str(v)
sys.stdout.write("\x1f".join([s(d.get("cwd")), s(d.get("session_id")), s(r.get("exit_code")), s(r.get("interrupted"))]))
' 2>/dev/null
}

# A finished review's text, capped (claude-config#560). A hook's output reaches the session through
# additionalContext or a refusal reason, and anything past 10,000 characters is cut by the platform
# with nothing said, so a review with two hundred findings would arrive as its first forty and read
# as the whole of it (L351). Both readers, the nudge and the merge gate, print through this one
# function: at most as many lines of the review as its second argument allows, each cut at the
# length its third allows, then how many were left out and the file holding all of them.
ar_capped_body() {   # $1 = finished review file, $2 = max lines, $3 = max chars per line
  awk -v max="$2" -v w="$3" -v path="$1" '
    found { n++; if (n <= max) { if (length($0) > w) $0 = substr($0, 1, w) "..."; print } ; next }
    /^$/ { found = 1 }
    END { if (n > max) printf "... and %d more line(s) not shown here; the full review is in %s\n", n - max, path }
  ' "$1" 2>/dev/null
}

# Appends the full text at $3 of each file changed between $2 and $3 (added or modified, matching the
# pathspecs after $5, or every file when none are given) to $1, smallest first, while $4 bytes of
# budget last. Prints "<files in> <files out> <names left out>" for the caller's start line. Moved
# here from ai-review-on-push.sh when the pull request review needed the same context (#560): two
# copies of "which files fit" would drift (L613). Smallest first, because a change touching one
# large generated file and five small real ones should still show the five, and a file that does
# not fit is named rather than silently absent (L98).
ar_append_full_files() {   # $1 = input file, $2 = base, $3 = head, $4 = byte budget, $5.. = pathspecs
  local out="$1" base="$2" head="$3" budget="$4" line fsize f in=0 left=0 names="" short
  shift 4
  short="$(git rev-parse --short "$head" 2>/dev/null || printf '%s' "$head")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fsize="${line%% *}"; f="${line#* }"
    case "$fsize" in ''|*[!0-9]*) continue ;; esac
    if [ "$fsize" -le "$budget" ] \
       && { printf '\n\n===== FULL FILE at %s: %s =====\n' "$short" "$f"; git show "$head:$f"; } >> "$out" 2>/dev/null; then
      budget=$((budget - fsize)); in=$((in + 1))
    else
      left=$((left + 1)); names="$names $f"
    fi
  done < <(git diff --name-only --diff-filter=AM "$base" "$head" -- "$@" 2>/dev/null \
           | while IFS= read -r f; do [ -n "$f" ] && printf '%s %s\n' "$(git cat-file -s "$head:$f" 2>/dev/null || echo x)" "$f"; done \
           | sort -n)
  printf '%s %s%s' "$in" "$left" "$names"
}

# The durable record of every lessons review of a pull request's branch (claude-config#562). The
# review files themselves are swept after 14 days, and the measurement #562 gates the lessons core on
# runs for two to three weeks per Mac, so each finished pr review also appends ONE line here, which
# nothing sweeps. Written from the finished file, by every path that finishes one (the runner, the
# refusals lib/pr-review.sh records itself, the nudge's abandoned conversion), so no outcome has a
# second spelling (L613). Bash rather than python so a review that could not run BECAUSE python3 is
# missing is still counted.
#
# Tab separated: finished, host, repo, repo dir, sha, base, status, findings, seconds, files the
# findings name (comma joined), lessons they cite (comma joined).
AR_PR_LEDGER="$AR_STATE_DIR/pr-reviews.tsv"
AR_PR_OPENED="$AR_STATE_DIR/pr-opened.tsv"

ar_host() { local h; h="${AI_REVIEW_HOST:-$(hostname 2>/dev/null)}"; printf '%s' "${h%.local}"; }

ar_pr_ledger() {   # $1 = a finished pr review file, $2 = the repository's directory
  [ -f "$1" ] || return 1
  mkdir -p "$AR_STATE_DIR" 2>/dev/null
  awk -v host="$(ar_host)" -v dir="$2" -F '\t' '
    BEGIN { FS = "\n" }
    !body && /^$/ { body = 1; next }
    !body { i = index($0, "="); if (i) m[substr($0, 1, i - 1)] = substr($0, i + 1); next }
    body && match($0, /^[^ :]+:[0-9]+: /) {
      f = substr($0, 1, RLENGTH); sub(/:[0-9]+: $/, "", f)
      if (!(f in seen)) { seen[f] = 1; files = files (files == "" ? "" : ",") f }
      rest = $0
      while (match(rest, /\(L[0-9]+\)/)) {
        l = substr(rest, RSTART + 1, RLENGTH - 2)
        if (!(l in cited)) { cited[l] = 1; lessons = lessons (lessons == "" ? "" : ",") l }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    END {
      secs = (m["finished"] ~ /^[0-9]+$/ && m["started"] ~ /^[0-9]+$/) ? m["finished"] - m["started"] : ""
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", m["finished"], host, m["repo"], dir, m["sha"], m["base"], m["status"], m["findings"], secs, files, lessons
    }' "$1" >> "$AR_PR_LEDGER" 2>/dev/null
}

ar_pr_opened() {   # $1 = repository label, $2 = its directory, $3 = the head sha
  mkdir -p "$AR_STATE_DIR" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(ar_host)" "$1" "$2" "$3" >> "$AR_PR_OPENED" 2>/dev/null
}
