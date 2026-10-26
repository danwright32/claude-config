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

# The words that open the minor findings of a lessons review, which are advisory and need no fix
# round (claude-config#1356). Defined once here: lib/pr-review.sh writes them, and the push and merge
# gates (mt_review_allowed in lib/merge-target.sh) find them in an allow, to hand the advisory to the
# session and to Dan rather than print it where neither sees it.
AR_ADVISORY_LEAD="Advisory, minor findings:"
# The words that open a refusal's request to step back after three rounds of findings
# (claude-config#1358), which lib/pr-review.sh writes and lib/merge-when-ready.sh looks for.
AR_STEP_BACK_LEAD="Step back:"

# A finished review's text, capped (claude-config#560). A hook's output reaches the session through
# additionalContext or a refusal reason, and anything past 10,000 characters is cut by the platform
# with nothing said, so a review with two hundred findings would arrive as its first forty and read
# as the whole of it (L351). Both readers, the nudge (push reviews) and the merge gate (whole branch
# reviews), print through this one function: at most as many lines of the review as its second
# argument allows, each cut at the length its third allows, then how many were left out and the
# file holding all of them.
#
# Every line passes through ar_redact first, before it is cut to length, because a cut JWT no
# longer looks like one (claude-config#581).
ar_capped_body() {   # $1 = finished review file, $2 = max lines, $3 = max chars per line
  ar_redact < "$1" | awk -v max="$2" -v w="$3" -v path="$1" '
    found { n++; if (n <= max) { if (length($0) > w) $0 = substr($0, 1, w) "..."; print } ; next }
    /^$/ { found = 1 }
    END { if (n > max) printf "... and %d more line(s) not shown here; the full review is in %s\n", n - max, path }
  ' 2>/dev/null
}

# The READ KEYS of one pull request review's findings (claude-config#788). The one message that
# shows the findings, the merge gate's refusal, ISSUES a fresh random key each time it shows them and
# prints it, and only a MAC of it is kept, one per line, in <file>.readkeys-<finished stamp>. (The
# nudge issued one too while it showed these reviews; it stopped showing them in
# claude-config#1090.) A merge presenting PR_REVIEW_READ=<key> then proves the findings reached
# the session doing the merge, because the plain key exists nowhere but in a message that carried
# them: a session that never saw them cannot read it off the disk (lessons review of #795). Before this the gate judged findings read because
# it had PRINTED them, and on #774 another hook refused the same merge, only that hook's message
# was shown, and the retry merged unread. The stamp in the name means a review written again for
# the same head starts with no valid key. A line under PIPE_BUF is appended atomically, so
# concurrent issuers never lose each other's key. A key that cannot be issued prints nothing and
# fails, and the caller refuses, since no merge can present a key nobody was shown (L42).
#
# A LINE A SESSION CANNOT MINT (claude-config#1719). Each line was the key's plain sha256, so a
# session's own shell could append the hash of a key it made up and present that key, merging with
# the findings never shown. Each line is now the key's HMAC under the secret the typed helper key's
# record uses (#1700, below), and so is the acknowledgement a read leaves beside the review: it held
# only the review's finish time, which a session could write as easily. pr-review-gate.sh refuses any
# Bash command naming a read keys file or these functions, as it does the helper key's record. A
# line or an acknowledgement written before this change is in the old form and no longer counts, so
# a key shown just before an install is asked for again.
ar__readkeys_file() {   # $1 = finished review file -> the MAC file for its current stamp
  local fin
  fin="$(awk 'index($0, "finished=") == 1 { print substr($0, 10); exit } /^$/ { exit }' "$1" 2>/dev/null)"
  case "$fin" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$1.readkeys-$fin"
}
#
# Exits with WHY a key could not be issued, each its own cause and remedy (L11, L111), read back
# into words by ar_review_key_failure: 2 the review records no finish time, 3 a tool it needs
# (od, python3, /dev/urandom) is missing, 4 nothing could be written beside the review, 5 the
# secret the key is kept under could not be made or read.
ar_readkeys_issue() {   # $1 = finished review file -> prints a fresh key
  local kf k h
  kf="$(ar__readkeys_file "$1")" || return 2
  command -v od >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [ -r /dev/urandom ] || return 3
  k="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ "${#k}" -eq 16 ] || return 3
  { mkdir -p "$AR_STATE_DIR"; } 2>/dev/null || return 5
  ar__helper_secret_make || return 5
  h="$(ar__helper_key_mac "$k")"
  [ "${#h}" -eq 64 ] || return 5
  # Braced, so a refused redirection is silenced too: it fails before an inner 2> applies.
  # Only ever appended, never rewritten: a trim raced concurrent appends and dropped keys that had
  # been shown (lessons review of #795). The size is 65 bytes per showing of this one review, so
  # a thousand refusals is 65 KB, and the file goes with the review in the 14 day sweep.
  { printf '%s\n' "$h" >> "$kf"; } 2>/dev/null || return 4
  printf '%s' "$k"
}
# The sentence for an ar_readkeys_issue failure: what went wrong and the remedy that fits it.
ar_review_key_failure() {   # $1 = its exit code, $2 = the review file, $3 = the restart command
  case "$1" in
    2) printf 'this review file records no finish time, so it cannot be given a read key and no merge can show these were read; run it again with: %s' "$3" ;;
    3) printf 'no read key could be issued because od, python3 or /dev/urandom is missing on this machine, so no merge can show these were read; install the missing tool (re-running the review will not help), or merge with the override after telling Dan why' ;;
    4) printf 'no read key could be issued because it could not be written beside %s, so no merge can show these were read; make that folder writable, or merge with the override after telling Dan why' "$2" ;;
    5) printf 'no read key could be issued because the secret it is kept under, in %s, could not be made or read (the folder not writable, or another gate still replacing a damaged one), so no merge can show these were read; try the same command again, and if it is refused the same way make that folder writable, or merge with the override after telling Dan why' "$AR_STATE_DIR" ;;
    *) printf 'no read key could be issued (cause %s unknown), so no merge can show these were read; merge with the override after telling Dan why' "$1" ;;
  esac
}
ar_readkeys_valid() {   # $1 = finished review file, $2 = presented key -> 0 when it was issued
  local kf h
  case "$2" in ''|*[!a-f0-9]*) return 1 ;; esac
  kf="$(ar__readkeys_file "$1")" || return 1
  h="$(ar__helper_key_mac "$2")" || return 1
  [ "${#h}" -eq 64 ] && grep -qxF "$h" "$kf" 2>/dev/null
}
# The acknowledgement a read leaves (claude-config#788, #599): the review's finish time, which names
# the review it read, and a MAC binding that time to the action that presented the key, so a push's
# acknowledgement cannot stand for a merge's. Written by lib/pr-review.sh once a presented key is
# valid, and written again for the later review when a later head carries it over.
#
# WHICH REVIEW IT READ (claude-config#1739). The MAC bound only the finish time and the action, so a
# valid acknowledgement copied beside another review that finished in the same second read that one
# too. It now also binds the review's own identity: the review file's name, which is the repository's
# key and the head it reviewed. A carried review is a new file, so its acknowledgement is signed for
# it afresh, and only from one that is valid for the review it carries.
ar__readkeys_ack_mac() {   # $1 = review file, $2 = finish time, $3 = merge or push -> its MAC, or return 1
  local id="${1##*/}"
  [ -n "$id" ] || return 1
  ar__helper_key_mac "ack:$3:$id:$2"
}
ar_readkeys_ack_write() {   # $1 = acknowledgement file, $2 = review file, $3 = finish time, $4 = merge or push -> 0 once written
  local m
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  m="$(ar__readkeys_ack_mac "$2" "$3" "$4")" || return 1
  [ "${#m}" -eq 64 ] || return 1
  { printf 'finished=%s\nmac=%s\n' "$3" "$m" > "$1"; } 2>/dev/null
}
ar_readkeys_ack_ok() {   # $1 = acknowledgement file, $2 = review file, $3 = finish time, $4 = merge or push -> 0 when it is one
  local m
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  m="$(ar__readkeys_ack_mac "$2" "$3" "$4")" || return 1
  [ "${#m}" -eq 64 ] && [ "$(cat "$1" 2>/dev/null)" = "finished=$3"$'\n'"mac=$m" ]
}

# READ KEYS TYPED IN FRONT OF THE MERGE HELPER (claude-config#1673). A gate reads a typed merge's key
# from the command's own text, so only a session that was shown the key can present it. The merge
# helper, lib/merge-when-ready.sh, takes its key from its ENVIRONMENT, and no gate counts the helper
# as a merge, so a Bash call that ran it, grepped the key out of its refusal and ran it again with
# PR_REVIEW_READ="$key" merged with nobody having read the findings (found 2026-10-24 by the #1587
# builder; #1587 closed only the Monitor form). So pr-review-gate.sh, which sees each Bash command
# before it runs, records a key TYPED as a literal in front of the helper, and the helper takes a key
# from its environment only when it was recorded. A key in a variable, an export or a substitution is
# unknown when the command is read, so it is never recorded. Each record is one empty file, swept
# after 14 days with the reviews themselves.
#
# A RECORD A SESSION CANNOT MINT (claude-config#1700). The record was named by the key's sha256, so
# a session's own shell command could make one by hand for a key it had grepped, which is the very
# merge the gate exists to stop. It is now named by an HMAC-SHA256 of the key under a secret that only
# the gate creates, kept beside the folder as helper-keys.secret, readable by its owner alone, and
# pr-review-gate.sh refuses any Bash command naming the folder, the secret or the functions below that
# write them. A file made without the secret is named by nothing the helper looks for. The helper
# reads the secret to check a record and never creates one, so with no secret no key is accepted.
# What this does not stop, being one user's files: a session that hides the name from the gate (a
# glob, an escape, a script file written first) can still read the secret or call the recorder.
ar__helper_keys_dir() { printf '%s/helper-keys' "$AR_STATE_DIR"; }
ar__helper_secret_file() { printf '%s/helper-keys.secret' "$AR_STATE_DIR"; }
ar__helper_secret_ok() {   # $1 = the secret file -> 0 when it holds a secret (64 lowercase hex)
  local s
  s="$(cat "$1" 2>/dev/null)" || return 1
  [ "${#s}" -eq 64 ] || return 1
  case "$s" in *[!a-f0-9]*) return 1 ;; esac
  return 0
}
# Made by the gate alone, the first time it records a key, and in both cases the FIRST maker wins, so
# no gate records under a secret another then replaces (assume it runs twice):
# With none there, each links its own under the name, which only one link can take, and the others
# drop theirs and read the winner's. With one there that is not a secret (cut short, emptied), which
# could check nothing anyway, it is replaced only under a lock (a mkdir, which only one can make),
# and the holder looks again once it has the lock, so a gate that saw it damaged after another had
# already replaced it leaves the new one alone. The rename puts the new secret in place in one step,
# so it is never missing. A gate that finds the lock held waits for the holder and reads its secret,
# and never replaces it itself. A lock over a minute old was left by a gate that died holding it, and
# is cleared.
# AR_HELPER_SECRET_SLEEP and AR_HELPER_SECRET_PAUSE are the test's: the sleep between looks at a held
# lock (L524), and a pair of fifos holding a gate just after it has seen the secret damaged, so the
# race above can be run in a set order. Neither changes what is recorded.
ar__helper_secret_make() {   # -> 0 once a secret is in place
  local f t s lock tries
  f="$(ar__helper_secret_file)"
  ar__helper_secret_ok "$f" && return 0
  if [ -n "${AR_HELPER_SECRET_PAUSE:-}" ]; then
    printf 'reached\n' > "$AR_HELPER_SECRET_PAUSE.reached"; read -r _ < "$AR_HELPER_SECRET_PAUSE.go"
  fi
  command -v od >/dev/null 2>&1 && [ -r /dev/urandom ] || return 1
  s="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ "${#s}" -eq 64 ] || return 1
  t="$f.$$.tmp"
  { ( umask 077 && printf '%s' "$s" > "$t" ) && chmod 600 "$t"; } 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
  if ! [ -e "$f" ]; then
    ln "$t" "$f" 2>/dev/null
    if ar__helper_secret_ok "$f"; then rm -f "$t" 2>/dev/null; return 0; fi
  fi
  lock="$f.lock"
  [ -n "$(find "$lock" -maxdepth 0 -type d -mmin +1 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
  if mkdir "$lock" 2>/dev/null; then
    ar__helper_secret_ok "$f" || mv -f "$t" "$f" 2>/dev/null
    rm -f "$t" 2>/dev/null
    rmdir "$lock" 2>/dev/null
    ar__helper_secret_ok "$f"
    return
  fi
  rm -f "$t" 2>/dev/null
  # Fifty looks a fiftieth of a second apart (set here, not measured): the holder only looks again
  # and renames, so a wait longer than that means it died, and its lock is cleared on a later try.
  tries=0
  while [ "$tries" -lt 50 ]; do
    ar__helper_secret_ok "$f" && [ ! -d "$lock" ] && return 0
    "${AR_HELPER_SECRET_SLEEP:-sleep}" 0.02
    tries=$((tries + 1))
  done
  return 1
}
# The HMAC, in python so the secret is read from its file and never passed on a command line, where
# any process could read it while it ran.
ar__helper_key_mac() {   # $1 = a key -> its HMAC-SHA256 under the secret, or return 1
  local f
  f="$(ar__helper_secret_file)"
  ar__helper_secret_ok "$f" || return 1
  printf '%s' "$1" | python3 -c '
import hashlib, hmac, sys
with open(sys.argv[1], "rb") as fh:
    secret = bytes.fromhex(fh.read().decode("ascii").strip())
sys.stdout.write(hmac.new(secret, sys.stdin.buffer.read(), hashlib.sha256).hexdigest())
' "$f" 2>/dev/null
}
ar_helper_key_record() {   # $1 = a key typed in front of the helper -> 0 once recorded
  local d m
  case "$1" in ''|*[!a-f0-9]*) return 1 ;; esac
  d="$(ar__helper_keys_dir)"
  { mkdir -p "$d"; } 2>/dev/null || return 1
  ar__helper_secret_make || return 1
  m="$(ar__helper_key_mac "$1")"
  [ "${#m}" -eq 64 ] || return 1
  { : > "$d/$m"; } 2>/dev/null || return 1
  find "$d" -mindepth 1 -maxdepth 1 -type f -mtime +14 -delete 2>/dev/null || true
  return 0
}
ar_helper_key_typed() {   # $1 = the key the helper was given -> 0 when a typed command presented it
  local m
  case "$1" in ''|*[!a-f0-9]*) return 1 ;; esac
  m="$(ar__helper_key_mac "$1")" || return 1
  [ "${#m}" -eq 64 ] && [ -f "$(ar__helper_keys_dir)/$m" ]
}

# Text from the reviewer, made safe to print (claude-config#581): stdin to stdout through the one
# rule file, lib/review-redact.sed, which says what it drops and what it redacts. The runner
# (lib/ai-review-run.py) sends the reviewer's stderr and any unparsed answer through this BEFORE
# writing them, and ar_capped_body sends every display through it again, so a review file written
# before this existed is redacted on the way out. With the rule file missing it prints NOTHING and
# fails, never the raw text: a redactor that cannot run must withhold, not pass through (L42).
#
# --stderr is for the reviewer's stderr only: it also drops every line that is a settings or
# permission rule warning. Claude Code's warning about a wildcard permission rule quotes the rule
# verbatim, the rule is the person's own configuration and never the reason a review failed, and
# on 2026-09-24 in Bidspoke one held a live Supabase secret key inside a curl command. It is not
# applied to a review's findings, which may legitimately name a settings file.
ar_redact() {   # [--stderr]
  local rules drop='/[Pp]ermission rule|[Pp]ermissions?\.(allow|deny|ask)|settings(\.local)?\.json|[Ss]ettings warning|Bash\(/d'
  # The folder of this file by parameter expansion, never dirname (claude-config#1104).
  rules="${BASH_SOURCE[0]%/*}"; [ "$rules" != "${BASH_SOURCE[0]}" ] || rules=.
  rules="$(cd "${rules:-/}" && pwd)/review-redact.sed"
  if [ ! -r "$rules" ]; then
    cat >/dev/null
    printf '\n(withheld: lib/review-redact.sed is missing, so this text could not be redacted)\n'
    return 1
  fi
  if [ "${1:-}" = "--stderr" ]; then
    LC_ALL=C sed -E -e "$drop" -f "$rules"
  else
    LC_ALL=C sed -E -f "$rules"
  fi
}

# GENERATED FILES, as the repository itself marks them (claude-config#591). A file .gitattributes
# sends to a merge driver of its own (`merge=<name>`, other than git's built in text, binary and
# union, which hand written files use too) or marks `linguist-generated` is produced from the tree,
# so at twenty lines of context its diff is mostly text nobody wrote: on overture PR #4401 the
# generated project.pbxproj (measured 2026-09-30), 30 added lines, was 145 KB of the 373 KB that put an ordinary branch
# over the review cap. Read from the attributes AT the head being reviewed, never the checkout's,
# which may be on another branch entirely (L398). Prints the changed paths so marked, one per line.
ar_generated_paths() {   # $1 = base, $2 = head, $3.. = pathspecs (none means every file)
  local base="$1" head="$2" names
  shift 2
  names="$(git -c core.quotepath=false diff --name-only "$base" "$head" -- "$@" 2>/dev/null)"
  ar_generated_among "$names" "$head"
}

# Which of the newline separated names in $1 the repository marks generated, one per line in the
# order asked, read from the attributes at commit $2, or from the working tree when $2 is empty (a
# change not yet committed, which is what the push lessons advisory reads for a commit then push,
# claude-config#1525). The one reader of the signal: the push review and the advisory both ask here.
ar_generated_among() {   # $1 = names, $2 = a commit, or empty for the working tree
  local names="$1" attrs
  [ -n "$names" ] || return 0
  if [ -n "${2:-}" ]; then
    # --source needs git 2.40; an older git reads the working tree's attributes instead, which is the
    # checkout rather than the head and is said nowhere, so it is the fallback and not the rule.
    attrs="$(ar__check_attr "$names" --source "$2")" || attrs="$(ar__check_attr "$names")"
  else
    attrs="$(ar__check_attr "$names")"
  fi
  ar__marked_generated "$attrs"
}

# The attributes that mark a file generated, for each of the newline separated names in $1, read
# with any further arguments (--source <commit>) handed to check-attr. NUL separated both ways (-z),
# because check-attr C-quotes a non-ASCII name in its ordinary output whatever core.quotepath says,
# and a quoted name matches no file. Each answer is then three fields, path, attribute, value,
# turned into three lines. pipefail inside, or the status is tr's and a git refusing --source would
# read as an answer and never reach a fallback.
ar__check_attr() {   # $1 = names, $2.. = check-attr options
  local names="$1"
  shift
  (set -o pipefail; printf '%s\n' "$names" | tr '\n' '\0' \
    | git check-attr -z "$@" --stdin linguist-generated merge 2>/dev/null | tr '\0' '\n')
}

# The names an ar__check_attr answer marks generated, one per line, in the order asked.
ar__marked_generated() {   # $1 = ar__check_attr output
  printf '%s\n' "$1" | awk '
    NR % 3 == 1 { p = $0; next }
    NR % 3 == 2 { a = $0; next }
    {
      v = $0
      if (a == "linguist-generated" && (v == "set" || v == "true")) gen[p] = 1
      if (a == "merge" && v !~ /^(unspecified|unset|set|text|binary|union)$/) gen[p] = 1
      if (!(p in seen)) { seen[p] = 1; order[++n] = p }
    }
    END { for (i = 1; i <= n; i++) if (order[i] in gen) print order[i] }'
}

# A size as the review's messages give it, "812 bytes" or "145.3 KB": one awk function, so the file
# list, the start line, the verdict and the nudge cannot spell one size two ways.
AR_AWK_SIZE='function size(b) { return b >= 1024 ? sprintf("%d.%d KB", int(b / 1024), int((b % 1024) * 10 / 1024)) : sprintf("%d bytes", b) }'
ar_size_text() {   # $1 = bytes
  case "$1" in ''|*[!0-9]*) printf 'an unknown size'; return ;; esac
  awk -v b="$1" "$AR_AWK_SIZE"' BEGIN { printf "%s", size(b) }'
}

# The one sentence naming what a pull request review left out (claude-config#583), from the
# "<bytes><TAB><path><TAB><kind><TAB><why>" rows lib/pr-review.sh writes beside the review as
# <review>.leftout. Largest first, by name only while the names stay under 1,500 characters and ten
# files, then how many more and the file holding them all: a branch with hundreds of fixtures must
# not push a refusal past the 10,000 character hook output cap, which cuts it silently so the first
# names read as the whole list (L351). Prints nothing when nothing was left out. Every surface that
# reports a review prints it (the gate's verdicts and the start line; the nudge no longer reports
# these reviews, claude-config#1090), so none reports a review without saying what it did not
# read. A review refused as too large never ran, so for that outcome ($2) it says what WOULD have
# been left out, never that a review left it out (L11).
#
# The sorted rows reach awk as a here-string rather than through a pipe (claude-config#1120): the
# program starts with $AR_AWK_SIZE, so the pipefail check cannot read all of it and names a pipe
# into it as unjudged. A here-string has no writer that awk could leave behind.
ar_left_out_note() {   # $1 = the .leftout file, $2 = the review's status
  [ -s "$1" ] || return 0
  local rows
  rows="$(LC_ALL=C sort -t "$(printf '\t')" -k1,1nr "$1" 2>/dev/null)"
  LC_ALL=C awk -F '\t' -v file="$1" -v max=10 -v chars=1500 -v status="${2:-}" "$AR_AWK_SIZE"'
    NF >= 4 && $2 != "" {
      n++; total += $1
      item = $2 " (" $4 ", " size($1) ")"
      if (shown < max && length(list) + length(item) <= chars) { list = list (list == "" ? "" : "; ") item; shown++ }
    }
    END {
      if (!n) exit
      more = (n > shown) ? sprintf("%s%d %s, all listed in %s", shown ? "; and " : "", n - shown, shown ? "more" : "file(s)", file) : ""
      if (status == "too-large")
        printf "Would have been left out of the review as proven to need no reading, had the rest fitted: %d file(s), %s in all: %s%s.\n", n, size(total), list, more
      else
        printf "Not read by this review: %d file(s), %s in all, left out because the branch was over the size cap and each is proven to need no reading: %s%s.\n", n, size(total), list, more
    }' <<< "$rows"
}

# FILES A REVIEW OVER THE CAP MAY LEAVE OUT, because each is PROVEN to need no reading
# (claude-config#583). Slate PR #2794 was refused at 314 KB when 219 KB of it was one regenerated
# test fixture, and on 2026-10-08 four claude-config branches went over the cap (315 to 472 KB)
# mostly on byte for byte copies of mod-kit's readers. Prints "<path><TAB><kind><TAB><reason>" for
# each file changed between $1 and $2 that is one of:
#   generated   marked so by .gitattributes (ar_generated_paths' rule) at BOTH the base and the
#               head, so a branch cannot excuse its own file from review by adding the mark in the
#               same branch; a git that cannot read attributes from a commit proves nothing
#   fixture     a data file (json, jsonl, ndjson, csv, tsv, xml, txt) under a fixtures or
#               __fixtures__ folder; code there (a script, a test) is read like any other
#   copy        <prefix>mods/<mod>/tests/mod-kit/<path> whose content at the head is byte for byte
#               that of <prefix>mods/mod-kit/<path> at the head (the copy that
#               tools/check-mod-shared-parts.sh holds identical), proven here by comparing the two
#               blobs, never by trusting that check
#   design      a settled design round page (claude-config#1696): an HTML file under docs/design at
#               the repository's top, the place the design round guard calls a settled design's
#               (isDesignRecord), whose text at the head the design rounds skill's own check,
#               design_file.py --sealed (#1524), answers "sealed": exactly what make-settled.py wrote,
#               the captured product page with the round drawn in, settled by Dan. Slate's #4212 was
#               refused whole for one 521 KB page. The seal proves the text is unchanged since it was
#               sealed, on either Mac; it does not prove who sealed it, since anyone can compute the
#               hash, so a page is left out only on a branch over the cap, and named wherever the
#               review is reported. A hand edited or unsealed page, or one the check cannot be run on
#               (no python3, no design_file.py, an older one that answers in another shape), is read.
# Anything not proven is not printed, and so is read: an unproven file is never left out (L93).
AR_FIXTURE_DATA_RE='(^|/)(fixtures|__fixtures__)/(.*/)?[^/]+\.(json|jsonl|ndjson|csv|tsv|xml|txt)$'
AR_MODKIT_COPY_RE='^(.*/)?mods/([^/]+)/tests/mod-kit/(.+)$'
AR_DESIGN_RECORD_RE='^[Dd][Oo][Cc][Ss]/[Dd][Ee][Ss][Ii][Gg][Nn]/[^/].*\.[Hh][Tt][Mm][Ll]?$'
# The skill's check, beside these hooks in the checkout (payload/skills) and once installed
# (~/.claude/skills) alike, and no setting points it anywhere else: one would let a caller name a
# program that calls every page sealed, so a branch over the cap skips reading any docs/design page,
# and a marker gating it stops nothing, since whoever sets one can set the other. A test of another
# checker sources a copy of this lib with its stand-in beside it (test-pr-review.sh). Made absolute
# here, by parameter expansion and builtins only (test-lib-self-locate.sh), because a caller may cd
# before asking (the lessons advisory reads from the repository's top).
AR_COMMON_DIR="${BASH_SOURCE[0]%/*}"; [ "$AR_COMMON_DIR" != "${BASH_SOURCE[0]}" ] || AR_COMMON_DIR=.
AR_COMMON_DIR="$(cd "${AR_COMMON_DIR:-/}" 2>/dev/null && pwd)"

# Whether the file at $2 in commit $1 is a settled design exactly as make-settled.py sealed it. Only
# an exit 0 that says "sealed" counts, as the design round guard reads it: a design_file.py from
# before #1524 ignores --sealed and exits 0 saying nothing.
ar__design_sealed() {   # $1 = commit, $2 = path
  local py="$AR_COMMON_DIR/../../skills/design-rounds/design_file.py" out
  [ -f "$py" ] || return 1
  out="$(git show "$1:$2" 2>/dev/null | python3 -I "$py" --sealed 2>/dev/null)" || return 1
  [ "$out" = sealed ]
}
ar_left_out_candidates() {   # $1 = base, $2 = head
  local base="$1" head="$2" names gen p src a b
  names="$(git -c core.quotepath=false diff --name-only "$base" "$head" 2>/dev/null)"
  [ -n "$names" ] || return 0
  gen="$(ar_generated_paths "$base" "$head")"
  if [ -n "$gen" ]; then
    # Marked at the base too, read from the base commit itself, or it is not proven.
    if gen="$(ar__check_attr "$gen" --source "$base")"; then gen="$(ar__marked_generated "$gen")"; else gen=""; fi
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "
$gen
" in *"
$p
"*) printf '%s\tgenerated\tmarked generated in .gitattributes\n' "$p"; continue ;; esac
    if [[ "$p" =~ $AR_FIXTURE_DATA_RE ]]; then
      printf '%s\tfixture\tfixture data\n' "$p"; continue
    fi
    if [[ "$p" =~ $AR_DESIGN_RECORD_RE ]] && [[ "/$p/" != */../* ]] && ar__design_sealed "$head" "$p"; then
      printf '%s\tdesign\ta settled design round page, sealed by make-settled.py\n' "$p"; continue
    fi
    if [[ "$p" =~ $AR_MODKIT_COPY_RE ]] && [ "${BASH_REMATCH[2]}" != "mod-kit" ]; then
      src="${BASH_REMATCH[1]}mods/mod-kit/${BASH_REMATCH[3]}"
      a="$(git rev-parse -q --verify "$head:$p" 2>/dev/null)"
      b="$(git rev-parse -q --verify "$head:$src" 2>/dev/null)"
      if [ -n "$a" ] && [ "$a" = "$b" ]; then
        printf '%s\tcopy\tidentical to %s\n' "$p" "$src"; continue
      fi
    fi
  done <<NAMES
$names
NAMES
}

# The review diff: every file at -U20, except the generated ones, which follow under a header saying
# so, at -U0, every changed line and none of the context (claude-config#591). Printed to stdout.
ar_review_diff() {   # $1 = generated paths (newline list, from ar_generated_paths), $2 = base, $3 = head, $4.. = pathspecs
  local gen="$1" base="$2" head="$3" p short rc=0
  local -a excl=() incl=()
  shift 3
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    excl+=(":(exclude,literal)$p"); incl+=(":(literal)$p")
  done <<GEN
$gen
GEN
  git diff --no-color -U20 "$base" "$head" -- "$@" ${excl[@]+"${excl[@]}"} || rc=$?
  [ "${#incl[@]}" -gt 0 ] || return "$rc"
  short="$(git rev-parse --short "$head" 2>/dev/null || printf '%s' "$head")"
  printf '\n===== GENERATED FILES (marked so by .gitattributes at %s): only the changed lines, no context, and their full text is left out: %s =====\n' \
    "$short" "$(printf '%s\n' "$gen" | sed '/^$/d' | paste -sd ' ' -)"
  git diff --no-color -U0 "$base" "$head" -- "${incl[@]}" || rc=$?
  return "$rc"
}

# Appends the full text at $3 of each file changed between $2 and $3 (added or modified, matching the
# pathspecs after $5, or every file when none are given) to $1, smallest first, while $4 bytes of
# budget last. Prints "<files in> <files out> <names left out>" for the caller's start line. Moved
# here from ai-review-on-push.sh when the pull request review needed the same context (#560): two
# copies of "which files fit" would drift (L613). Smallest first, because a change touching one
# large generated file and five small real ones should still show the five, and a file that does
# not fit is named rather than silently absent (L98).
ar_append_full_files() {   # $1 = input file, $2 = base, $3 = head, $4 = byte budget, $5.. = pathspecs
  local out="$1" base="$2" head="$3" budget="$4" line fsize f in=0 left=0 names="" short gen
  shift 4
  short="$(git rev-parse --short "$head" 2>/dev/null || printf '%s' "$head")"
  # A generated file's full text is the bulk ar_review_diff exists to leave out (claude-config#591),
  # and its header already says so, so it is skipped here rather than counted as not fitting.
  gen="$(ar_generated_paths "$base" "$head" "$@")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fsize="${line%% *}"; f="${line#* }"
    case "$fsize" in ''|*[!0-9]*) continue ;; esac
    case "
$gen
" in *"
$f
"*) continue ;; esac
    if [ "$fsize" -le "$budget" ] \
       && { printf '\n\n===== FULL FILE at %s: %s =====\n' "$short" "$f"; git show "$head:$f"; } >> "$out" 2>/dev/null; then
      budget=$((budget - fsize)); in=$((in + 1))
    else
      left=$((left + 1)); names="$names $f"
    fi
  done < <(git -c core.quotepath=false diff --name-only --diff-filter=AM "$base" "$head" -- "$@" 2>/dev/null \
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
# findings name (comma joined), lessons they cite (comma joined), and since claude-config#1168 what
# reading the pull request's description and comments at the review's start came to (read, none for
# no open pull request, failed, or empty where it was never asked, as on every row written before)
# and what gh said, from <review>.prread beside the review. A failed read is counted here, with the
# review's other outcomes, so a read that keeps failing shows in pr-review-report.sh (L77).
AR_PR_LEDGER="$AR_STATE_DIR/pr-reviews.tsv"
AR_PR_OPENED="$AR_STATE_DIR/pr-opened.tsv"

ar_host() { local h; h="${AI_REVIEW_HOST:-$(hostname 2>/dev/null)}"; printf '%s' "${h%.local}"; }

ar_pr_ledger() {   # $1 = a finished pr review file, $2 = the repository's directory
  [ -f "$1" ] || return 1
  mkdir -p "$AR_STATE_DIR" 2>/dev/null
  # The outcome is what precedes the first tab; what gh said is the rest, put on one line with no
  # tab, so it can never add a column or a row.
  local pr_read="" pr_said="" rec=""
  [ -f "$1.prread" ] && rec="$(cat "$1.prread" 2>/dev/null)"
  if [ -n "$rec" ]; then
    pr_read="${rec%%$'\t'*}"; pr_read="${pr_read%%$'\n'*}"
    case "$rec" in *$'\t'*) pr_said="${rec#*$'\t'}" ;; esac
    pr_said="$(printf '%s' "$pr_said" | tr '\t\r\n' '   ' | awk '{ $1 = $1; print substr($0, 1, 300) }')"
  fi
  # Through the environment, never -v, which would turn a backslash gh printed into an escape.
  AR_PR_READ="$pr_read" AR_PR_SAID="$pr_said" awk -v host="$(ar_host)" -v dir="$2" -F '\t' '
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
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", m["finished"], host, m["repo"], dir, m["sha"], m["base"], m["status"], m["findings"], secs, files, lessons, ENVIRON["AR_PR_READ"], ENVIRON["AR_PR_SAID"]
    }' "$1" >> "$AR_PR_LEDGER" 2>/dev/null
}

# pr-opened.tsv, tab separated: when, host, repo label, repo dir, head sha, and since
# claude-config#1006 the pull request URL gh printed (empty when it printed none). The URL is what
# lets lib/pr-review-report.sh count by pull request without asking GitHub; rows written before it
# have five columns, and the report looks those up.
ar_pr_opened() {   # $1 = repository label, $2 = its directory, $3 = the head sha, $4 = pull request URL
  mkdir -p "$AR_STATE_DIR" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(ar_host)" "$1" "$2" "$3" "${4:-}" >> "$AR_PR_OPENED" 2>/dev/null
}

# The pull request URL a `gh pr create` printed, from a PostToolUse payload's stdout and stderr. gh
# prints it on stdout when it opens one, and on stderr when it refuses because one already exists
# ("a pull request for branch ... already exists:" then the URL), which is the repeat that records a
# second opening of the same pull request. Prints nothing when there is none.
ar_payload_pr_url() {   # $1 = payload JSON
  local text
  if command -v jq >/dev/null 2>&1; then
    text="$(printf '%s' "$1" | jq -r '(.tool_response // "") | if type == "object" then ((.stdout // "") + "\n" + (.stderr // "")) elif type == "string" then . else "" end' 2>/dev/null)"
  else
    text="$(printf '%s' "$1" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin).get("tool_response") or ""
except Exception:
    sys.exit(0)
if isinstance(r, dict):
    r = str(r.get("stdout") or "") + "\n" + str(r.get("stderr") or "")
sys.stdout.write(r if isinstance(r, str) else "")' 2>/dev/null)"
  fi
  printf '%s\n' "$text" | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' | tail -1
}
