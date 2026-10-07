#!/usr/bin/env bash
# sleep-queue.sh: sleep mode's overnight queue and per issue claims (claude-config#842, phase 5 of
# the Sleep mode milestone).
#
# Sourced for its functions, or run as a command by an overnight session:
#
#   bash ~/.claude/hooks/lib/sleep-queue.sh next    REPO_ROOT SESSION_ID [GOAL_ISSUE...]
#   bash ~/.claude/hooks/lib/sleep-queue.sh queue   REPO_ROOT SESSION_ID [GOAL_ISSUE...]
#   bash ~/.claude/hooks/lib/sleep-queue.sh claim   REPO_ROOT ISSUE SESSION_ID
#   bash ~/.claude/hooks/lib/sleep-queue.sh release REPO_ROOT ISSUE SESSION_ID free|done|parked|failed [WHY]
#   bash ~/.claude/hooks/lib/sleep-queue.sh claims
#
# `next` is the one an overnight session uses: it builds the queue, claims the first issue nobody
# holds, and gives it a worktree of its own (never a checkout or switch in the primary checkout,
# H7). It prints one line, tab separated, then the queue's skip lines for the report:
#
#   claimed  ISSUE  attempts=N  worktree=PATH  TITLE        exit 0
#   none     -      nothing left to claim tonight            exit 1
#   refused  -      WHY                                      exit 3
#
# The queue (L24): the goal's issues when given, else every open p0 to p3 issue, fetched with an
# explicit limit (SLEEP_QUEUE_LIMIT, 500) and refused when a page comes back that full, sorted here
# by priority then number. Left out, each with its reason on a skip line: needs-dan; a before bed
# question about it that went unanswered (phase 6, #836, writes those to
# ~/.claude/state/sleep/unanswered/GENERATION, one owner/repo#N a line); an open pull request or a
# branch naming it, unless tonight's own claims have touched it, when the claim decides; an issue an
# open session is on (its branch or its request names it); and any issue not opened by one of
# Dan's GitHub accounts, since another person's issue is data, never instructions (L28).
#
# Claims (sleep-queue.py says how they are kept): one directory per issue under
# ~/.claude/state/sleep/claims/GENERATION/OWNER__REPO/ISSUE, holding numbered entries each linked
# into place whole, so two sessions reaching for one issue make exactly one owner. A claim whose
# session has gone from the session registry is free again; the attempts count is every claim the
# issue has had tonight, read by the overnight driver (phase 8, #844) to park an issue at two.
#
# Only while the Mac is asleep, judged by sleep.sh's sleep_active, the one predicate (#840). Every
# GitHub read goes through one source, `gh` here, or the command SLEEP_QUEUE_SOURCE names, which the
# tests use so that nothing reaches GitHub.

_SQ_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! . "$_SQ_LIB/sleep.sh"; then
  echo "refused	-	sleep-queue.sh could not load sleep.sh beside it, so whether the Mac is asleep cannot be read" >&2
  return 3 2>/dev/null || exit 3
fi
_SQ_PY="$_SQ_LIB/sleep-queue.py"

_sq_refuse() { printf 'refused\t-\t%s\n' "$1"; return 3; }

# The night's note of a claim or of its end (#844), written by the one writer (sleep_note in
# sleep.sh, #835) right after the claim folder records it, so every claim and every end has its
# note and the report never calls a finished claim ended unexpectedly. The claim folder is the
# record; a note that cannot be written is said on stderr and never undoes the claim (L561).
# _sq_note KIND SESSION REPO ISSUE WHAT [ATTEMPTS_OR_WHY]
_sq_note() {
  local kind="$1" self="$2" slug="$3" issue="$4" what="$5" extra="${6:-}" line err now
  now="$(_sq_now)"
  line="$(python3 "$_SQ_PY" note "$kind" "$self" "$now" "$slug" "$issue" "$extra")" &&
    err="$(sleep_note "$line" "$(_sq_sleep_dir)/current.json" "$now" 2>&1 >/dev/null)" && return 0
  printf "sleep-queue: the night's note of this %s could not be written, so the report will not show it (%s)\n" "$what" "${err:-the note could not be built}" >&2
  return 0
}
_sq_now() { if [ -n "${SLEEP_NOW_MS:-}" ]; then printf '%s\n' "$SLEEP_NOW_MS"; else printf '%s000\n' "$(date +%s)"; fi; }
_sq_sleep_dir() { printf '%s/.claude/state/sleep\n' "$HOME"; }
_sq_registry() { printf '%s/.claude/state/sessions\n' "$HOME"; }

# Tonight's generation, only while asleep. Read from the record that sleep_active has just judged.
_sq_generation() {
  local rec now gen
  rec="$(_sq_sleep_dir)/current.json"
  now="$(_sq_now)"
  if ! sleep_active "$rec" "$now"; then
    printf 'the Mac is not asleep (the sleep record reads %s), so there is no night to queue or claim for\n' "$(sleep_state "$rec" "$now")"
    return 1
  fi
  gen="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("generation") or "")' "$rec" 2>/dev/null)"
  case "$gen" in
    ''|*[!A-Za-z0-9._-]*) printf 'the sleep record names no generation this reader accepts\n'; return 1 ;;
  esac
  printf '%s\n' "$gen"
}

# owner/repo of a checkout, lower case, from its origin as configured (never rewritten by insteadOf).
_sq_slug() {
  local url
  url="$(git -C "$1" config remote.origin.url 2>/dev/null)" || return 1
  python3 "$_SQ_PY" slug "$url"
}

# ---- deadlines ----

# _sq_deadline SECONDS COMMAND...: runs it in a process group of its own and stops the whole group
# once SECONDS pass, saying so on stderr and exiting 142. Everything this tool waits on from outside
# (GitHub, a fetch) goes through it: it runs unattended, and a wait with no deadline only hangs
# (L110). perl, since macOS has no timeout command.
_sq_deadline() {
  perl -e 'my $t = shift; my $pid = fork; exit 127 unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; waitpid($pid, 0);
      print STDERR "took longer than ${t}s and was stopped\n"; exit 142 };
    alarm $t; waitpid($pid, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}
_sq_gh_limit() { printf '%s\n' "${SLEEP_GH_TIMEOUT:-60}"; }

# ---- the issue source ----

# gh, as an account that can see the repository: the active one first, then each other signed in
# account, its token scoped to the call (never gh auth switch, which other sessions share). The
# token is exported only inside the subshell running that one call, never into argv.
_sq_gh_as() { # TOKEN-or-empty gh-arguments...
  local tok="$1"
  shift
  if [ -n "$tok" ]; then ( export GH_TOKEN="$tok"; _sq_deadline "$(_sq_gh_limit)" gh "$@" ); else _sq_deadline "$(_sq_gh_limit)" gh "$@"; fi
}
# Exit 0 with the token (empty for the active account), 1 when no account can see it, 4 when
# GitHub did not answer within the deadline, which is said as itself, never as no account.
_sq_gh_token() {
  local slug="$1" acct tok rc accts
  _sq_gh_as "" repo view "$slug" --json nameWithOwner >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 142 ] && return 4
  accts="$(_sq_gh_as "" auth status 2>/dev/null)"; rc=$?
  [ "$rc" = 142 ] && return 4
  for acct in $(printf '%s\n' "$accts" | grep -oE 'account [A-Za-z0-9_.-]+' | awk '{print $2}' | sort -u); do
    tok="$(_sq_gh_as "" auth token -u "$acct" 2>/dev/null)"; rc=$?
    [ "$rc" = 142 ] && return 4
    [ "$rc" = 0 ] && [ -n "$tok" ] || continue
    _sq_gh_as "$tok" repo view "$slug" --json nameWithOwner >/dev/null 2>&1; rc=$?
    [ "$rc" = 142 ] && return 4
    if [ "$rc" = 0 ]; then
      printf '%s\n' "$tok"
      return 0
    fi
  done
  return 1
}
_sq_gh() { _sq_gh_as "${_SQ_TOKEN:-}" "$@"; }
_sq_gh_source() {
  case "$1" in
    accounts) _sq_gh_as "" auth status --json hosts 2>/dev/null | python3 -c '
import json, sys
for a in json.load(sys.stdin).get("hosts", {}).get("github.com", []):
    if a.get("state") == "success" and a.get("login"):
        print(a["login"])' ;;
    issues) _sq_gh issue list -R "$2" --state open --limit "$3" --json number,title,labels,author ;;
    issue) _sq_gh issue view "$3" -R "$2" --json number,title,labels,author,state ;;
    prs) _sq_gh pr list -R "$2" --state open --limit "$3" --json number,title,body,headRefName ;;
    branches) _sq_gh api --paginate "repos/$2/branches?per_page=100" --jq '.[].name' ;;
    *) echo "unknown source call $1" >&2; return 2 ;;
  esac
}
# Each gh call above carries its own deadline; an injected source is held to the same one.
_sq_source() { if [ -n "${SLEEP_QUEUE_SOURCE:-}" ]; then _sq_deadline "$(_sq_gh_limit)" "$SLEEP_QUEUE_SOURCE" "$@"; else _sq_gh_source "$@"; fi; }

# One fetch into a file; a failure is a refusal carrying the source's own first line (L215).
_sq_fetch() {
  local out="$1" what="$2" err
  shift 2
  if ! _sq_source "$@" > "$out" 2> "$out.err"; then
    err="$(awk 'NF { print; exit }' "$out.err")"
    _sq_refuse "the $what could not be read from GitHub (${err:-no reason given})"
    return 3
  fi
}

# ---- the queue ----

# sleep_queue REPO_ROOT SESSION_ID [GOAL_ISSUE...]: next and skip lines, as the header says.
sleep_queue() {
  local root="${1:-}" self="${2:-}" gen slug tmp limit="${SLEEP_QUEUE_LIMIT:-500}" n rc goal="" goalskips="" why
  [ $# -ge 2 ] || { _sq_refuse "sleep_queue needs a repository root and a session id"; return 3; }
  shift 2
  gen="$(_sq_generation)" || { _sq_refuse "$gen"; return 3; }
  slug="$(_sq_slug "$root")" || { _sq_refuse "$root has no GitHub origin, so its issues cannot be named"; return 3; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sleep-queue.XXXXXX")" || { _sq_refuse "no temporary folder could be made"; return 3; }
  _SQ_TOKEN=""
  if [ -z "${SLEEP_QUEUE_SOURCE:-}" ]; then
    _SQ_TOKEN="$(_sq_gh_token "$slug")"
    case $? in
      0) ;;
      4) rm -rf "$tmp"; _sq_refuse "GitHub did not answer within $(_sq_gh_limit)s while finding an account that can see $slug, so the call was stopped"; return 3 ;;
      *) rm -rf "$tmp"; _sq_refuse "no signed in GitHub account can see $slug"; return 3 ;;
    esac
  fi
  rc=0
  _sq_fetch "$tmp/accounts" "list of Dan's GitHub accounts" accounts || rc=3
  if [ "$rc" = 0 ] && [ $# -gt 0 ]; then
    : > "$tmp/goal.jsonl"
    for n in "$@"; do
      case "$n" in ''|*[!0-9]*) rm -rf "$tmp"; _sq_refuse "goal issue $n is not an issue number"; return 3 ;; esac
      # One goal issue that cannot be read is a skip line with the source's reason; the rest of
      # the goal is still worked.
      if ! why="$(_sq_fetch "$tmp/one" "goal issue #$n" issue "$slug" "$n")"; then
        goalskips="$goalskips$(printf 'skip\t%s\t%s' "$n" "${why#$'refused\t-\t'}")"$'\n'
        continue
      fi
      cat "$tmp/one" >> "$tmp/goal.jsonl"; echo >> "$tmp/goal.jsonl"
      goal="$goal${goal:+,}$n"
    done
    [ "$rc" = 0 ] && { python3 -c '
import json, sys
print(json.dumps([json.loads(l) for l in open(sys.argv[1]) if l.strip()]))' "$tmp/goal.jsonl" > "$tmp/issues.json" 2>"$tmp/goal.err" || { _sq_refuse "a goal issue came back as something other than JSON"; rc=3; }; }
  elif [ "$rc" = 0 ]; then
    _sq_fetch "$tmp/issues.json" "open issues of $slug" issues "$slug" "$limit" || rc=3
  fi
  [ "$rc" = 0 ] && { _sq_fetch "$tmp/prs.json" "open pull requests of $slug" prs "$slug" "$limit" || rc=3; }
  [ "$rc" = 0 ] && { _sq_fetch "$tmp/branches" "branches of $slug" branches "$slug" || rc=3; }
  if [ "$rc" = 0 ]; then
    python3 "$_SQ_PY" queue "repo=$slug" "limit=$limit" "issues=$tmp/issues.json" "prs=$tmp/prs.json" \
      "branches=$tmp/branches" "accounts=$tmp/accounts" "unanswered=$(_sq_sleep_dir)/unanswered/$gen" \
      "claims=$(_sq_sleep_dir)/claims/$gen/${slug%%/*}__${slug#*/}" "registry=$(_sq_registry)" \
      "now=$(_sq_now)" "self=$self" "goal=$goal"
    rc=$?
    [ "$rc" = 0 ] && printf '%s' "$goalskips"
  fi
  rm -rf "$tmp"
  return "$rc"
}

# ---- claims ----

_sq_issue_dir() { printf '%s/claims/%s/%s__%s/%s\n' "$(_sq_sleep_dir)" "$1" "${2%%/*}" "${2#*/}" "$3"; }
_sq_valid() {
  case "$1" in ''|*[!0-9]*) printf 'issue %s is not an issue number\n' "$1"; return 1 ;; esac
  case "$2" in ''|*[!A-Za-z0-9-]*) printf 'session id %s is not one the registry uses\n' "$2"; return 1 ;; esac
}

# Links one entry into place as number N: written whole beside it first, so it is never seen half
# written, and `ln` refuses when N exists, so of two writers exactly one makes it. Exit 0 linked,
# 1 the number was taken (another session wrote first), 2 nothing could be written, the reason on
# stdout: a full disk or a folder that cannot be written to is never reported as a lost race (L11).
_sq_link() {
  local dir="$1" n="$2" json="$3" tmp err
  # mktemp makes the file itself, exclusively, so two writers never share one, even forked ones
  # that share $$ and RANDOM state: a shared name would let one link the other's entry as its own.
  if ! tmp="$(mktemp "$dir/.tmp.XXXXXXXX" 2>&1)"; then
    printf 'the entry could not be written in %s (%s)\n' "$dir" "${tmp:-no reason given}"
    return 2
  fi
  if ! err="$( { printf '%s\n' "$json" > "$tmp"; } 2>&1)"; then
    rm -f "$tmp"
    printf 'the entry could not be written in %s (%s)\n' "$dir" "${err:-no reason given}"
    return 2
  fi
  if err="$(ln "$tmp" "$dir/$n" 2>&1)"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  [ -e "$dir/$n" ] && return 1
  printf 'the entry could not be linked into %s (%s)\n' "$dir" "${err:-no reason given}"
  return 2
}

# sleep_claim REPO_ROOT ISSUE SESSION_ID: `claimed ISSUE attempts=N STATE` (exit 0), or
# `not-claimed ISSUE WHY` (exit 1), or refused (exit 3).
sleep_claim() {
  local root="${1:-}" issue="${2:-}" self="${3:-}" gen slug dir line st nxt attempts why bad try entry err
  bad="$(_sq_valid "$issue" "$self")" || { _sq_refuse "$bad"; return 3; }
  gen="$(_sq_generation)" || { _sq_refuse "$gen"; return 3; }
  slug="$(_sq_slug "$root")" || { _sq_refuse "$root has no GitHub origin, so its issues cannot be named"; return 3; }
  dir="$(_sq_issue_dir "$gen" "$slug" "$issue")"
  mkdir -p "$dir" || { _sq_refuse "the claim folder $dir could not be made"; return 3; }
  # A claimer killed between writing its temp file and linking it leaves the file behind. A live
  # writer links within milliseconds, so one ten minutes old is a dead one's, and goes.
  find "$dir" -maxdepth 1 -name '.tmp.*' -type f -mmin +10 -exec rm -f {} + 2>/dev/null
  # A lost race means another entry landed first: judge again from what is there now.
  for try in 1 2 3 4 5; do
    line="$(python3 "$_SQ_PY" state "$dir" "$self" "$(_sq_registry)" "$(_sq_now)")" || { _sq_refuse "the claim on #$issue could not be judged"; return 3; }
    IFS=$'\t' read -r st nxt attempts why <<< "$line"
    case "$st" in
      mine) printf 'claimed\t%s\tattempts=%s\tmine\n' "$issue" "$attempts"; return 0 ;;
      free)
        entry="$(python3 "$_SQ_PY" entry claim "$self" "$(_sq_now)")" || { _sq_refuse "the claim entry could not be written"; return 3; }
        err="$(_sq_link "$dir" "$nxt" "$entry")"
        case $? in
          0)
            _sq_note claim "$self" "$slug" "$issue" claim "$((attempts + 1))"
            printf 'claimed\t%s\tattempts=%s\t%s\n' "$issue" "$((attempts + 1))" "$why"; return 0 ;;
          2) _sq_refuse "$err"; return 3 ;;
        esac ;;
      *) printf 'not-claimed\t%s\t%s: %s\n' "$issue" "$st" "$why"; return 1 ;;
    esac
  done
  printf 'not-claimed\t%s\tanother session kept writing to this claim first\n' "$issue"
  return 1
}

# sleep_release REPO_ROOT ISSUE SESSION_ID free|done|parked|failed [WHY]: only the holder ends its
# own claim. free puts the issue back for anyone; the others end it for the night.
sleep_release() {
  case "${4:-}" in free|done|parked|failed) ;; *) printf 'refused\t-\ta claim ends as free, done, parked or failed, never %s\n' "${4:-}"; return 2 ;; esac
  _sq_end "$@"
}

# The one writer of a claim's end. `unstarted` (given back because its worktree could not be made
# just now, which count_attempts does not count) is written only by sleep_next, through here, and
# sleep_release refuses it, so no caller can erase an attempt the driver parks on.
_sq_end() {
  local root="${1:-}" issue="${2:-}" self="${3:-}" state="${4:-}" why="${5:-}" gen slug dir line st nxt attempts reason bad entry err
  bad="$(_sq_valid "$issue" "$self")" || { _sq_refuse "$bad"; return 3; }
  gen="$(_sq_generation)" || { _sq_refuse "$gen"; return 3; }
  slug="$(_sq_slug "$root")" || { _sq_refuse "$root has no GitHub origin, so its issues cannot be named"; return 3; }
  dir="$(_sq_issue_dir "$gen" "$slug" "$issue")"
  line="$(python3 "$_SQ_PY" state "$dir" "$self" "$(_sq_registry)" "$(_sq_now)")" || { _sq_refuse "the claim on #$issue could not be judged"; return 3; }
  IFS=$'\t' read -r st nxt attempts reason <<< "$line"
  if [ "$st" != mine ]; then
    printf 'not-released\t%s\tthis session does not hold it (%s: %s)\n' "$issue" "$st" "$reason"
    return 1
  fi
  entry="$(python3 "$_SQ_PY" entry "$state" "$self" "$(_sq_now)" "$why")" || { _sq_refuse "the release entry could not be written"; return 3; }
  err="$(_sq_link "$dir" "$nxt" "$entry")"
  case $? in
    0) ;;
    1) printf 'not-released\t%s\tanother session wrote to this claim first, so it was taken over\n' "$issue"; return 1 ;;
    *) _sq_refuse "$err"; return 3 ;;
  esac
  _sq_note "$state" "$self" "$slug" "$issue" "end ($state)" "$why"
  printf 'released\t%s\t%s\n' "$issue" "$state"
}

# sleep_claims_json: every claim of tonight, one JSON line each (repo, issue, attempts, entries).
# The seam the nightly report (phase 4, #835) reads claims through, so it never parses the folders.
sleep_claims_json() {
  local gen
  gen="$(_sq_generation)" || { _sq_refuse "$gen"; return 3; }
  python3 "$_SQ_PY" claims "$(_sq_sleep_dir)/claims/$gen"
}

# ---- worktrees ----

# sleep_worktree REPO_ROOT ISSUE: the issue's own worktree, PRIMARY/.claude/worktrees/sleep-ISSUE on
# branch sleep/ISSUE, made from the remote default branch, or the one already there when it is this
# repository's worktree. Anything else at that path is never adopted (L421).
#
# Exit 1 when it never can be made here (something else at the path, a bare repository), which
# ends the issue for the night; exit 2 when it could not be made just now (a fetch or git worktree
# add failing), which gives the issue back for a later pass rather than losing it to a network drop.
sleep_worktree() {
  local root="$1" issue="$2" common primary path branch base have list
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { echo "$root is not a git checkout" >&2; return 1; }
  # The primary checkout is the first worktree git lists, wherever its git folder lives.
  list="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || { echo "git worktree list failed in $root" >&2; return 2; }
  primary="${list%%$'\n'*}"
  primary="${primary#worktree }"
  case "$list" in
    *$'\nbare'*|bare*) echo "$primary is a bare repository, with no checkout to put a worktree beside" >&2; return 1 ;;
  esac
  # With a separate git folder git lists that folder, not the checkout; then the checkout asked
  # about is the primary one when its own git folder is the common one. Anything else is refused.
  if [ "$(git -C "$primary" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$common" ] ||
     [ "$(git -C "$primary" rev-parse --show-toplevel 2>/dev/null)" != "$primary" ]; then
    if [ "$(git -C "$root" rev-parse --path-format=absolute --git-dir 2>/dev/null)" = "$common" ]; then
      primary="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"
    else
      echo "the primary checkout of $root could not be found (git names $primary)" >&2
      return 1
    fi
  fi
  path="$primary/.claude/worktrees/sleep-$issue"
  branch="sleep/$issue"
  if [ -e "$path" ]; then
    have="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [ "$have" = "$common" ] && [ "$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" = "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
    echo "$path is there already and is not a worktree of $primary, so it was left alone" >&2
    return 1
  fi
  # A branch already here (a session that died before its worktree was made) needs no fetch.
  if git -C "$primary" show-ref --verify -q "refs/heads/$branch"; then
    git -C "$primary" worktree add -q "$path" "$branch" >/dev/null 2>&1 || { echo "git worktree add $path $branch failed" >&2; return 2; }
  else
    # Unattended, so the fetch has a deadline (L110): a hung network gives the issue back rather
    # than holding the claim with no end. The whole process group is stopped, so its ssh goes too.
    local limit="${SLEEP_FETCH_TIMEOUT:-120}" frc
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4" \
      _sq_deadline "$limit" \
      git -C "$primary" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch -q origin 2>/dev/null
    frc=$?
    if [ "$frc" = 142 ]; then echo "git fetch from origin in $primary took longer than ${limit}s and was stopped" >&2; return 2; fi
    [ "$frc" = 0 ] || { echo "git fetch from origin failed in $primary" >&2; return 2; }
    base="$(git -C "$primary" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
    [ -n "$base" ] || base=origin/main
    if git -C "$primary" show-ref --verify -q "refs/remotes/origin/$branch"; then base="origin/$branch"; fi
    git -C "$primary" worktree add -q -b "$branch" "$path" "$base" >/dev/null 2>&1 || { echo "git worktree add $path from $base failed" >&2; return 2; }
  fi
  printf '%s\n' "$path"
}

# ---- next ----

# sleep_next REPO_ROOT SESSION_ID [GOAL_ISSUE...]: see the header. Exactly one result line comes
# first; issues it claimed but could not start follow as skip lines, with the queue's own. A claim
# refused outright (the night ended, the claim folder cannot be written) stops it with that refusal,
# never read as an issue someone else holds.
sleep_next() {
  local root="${1:-}" self="${2:-}" q rc lines n title got attempts wt err failed="" crc
  q="$(sleep_queue "$@")"; rc=$?
  if [ "$rc" != 0 ]; then printf '%s\n' "$q"; return 3; fi
  lines="$(printf '%s\n' "$q" | awk -F'\t' '$1 == "next" { print $2 "\t" $6 }')"
  while IFS=$'\t' read -r n title; do
    [ -n "$n" ] || continue
    got="$(sleep_claim "$root" "$n" "$self")"; crc=$?
    if [ "$crc" = 1 ]; then
      # Taken or ended between the queue and the claim: said, never dropped from every line.
      failed="$failed$(printf 'skip\t%s\tnot claimed: %s' "$n" "$(printf '%s' "$got" | cut -f3-)")"$'\n'
      continue
    fi
    if [ "$crc" != 0 ]; then printf '%s\n' "$got"; return 3; fi
    attempts="$(printf '%s\n' "$got" | awk -F'\t' '{ print $3 }')"
    # Its one line on stdout on success, its reason on stderr on failure: captured together, so no
    # temp file is needed for the reason.
    wt="$(sleep_worktree "$root" "$n" 2>&1)"; crc=$?
    if [ "$crc" != 0 ]; then
      err="$wt"
      # Never here (exit 1) ends it for the night; not just now (exit 2) gives it back.
      local end=failed
      [ "$crc" = 2 ] && end=unstarted
      if ! got="$(_sq_end "$root" "$n" "$self" "$end" "no worktree: $err")"; then
        err="$err; and the claim could not be ended as $end, so it is still held ($(printf '%s' "$got" | cut -f3-))"
      fi
      failed="$failed$(printf 'skip\t%s\tclaimed but could not start (%s): %s' "$n" "$([ "$end" = unstarted ] && echo 'given back for a later pass' || echo 'ended for tonight')" "$err")"$'\n'
      continue
    fi
    printf 'claimed\t%s\t%s\tworktree=%s\t%s\n' "$n" "$attempts" "$wt" "$title"
    printf '%s' "$failed"
    printf '%s\n' "$q" | awk -F'\t' '$1 == "skip"'
    return 0
  done <<< "$lines"
  printf 'none\t-\tnothing left to claim tonight\n'
  printf '%s' "$failed"
  printf '%s\n' "$q" | awk -F'\t' '$1 == "skip"'
  return 1
}

# ---- run as a command ----

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  shift 2>/dev/null
  case "$cmd" in
    next) sleep_next "$@" ;;
    queue) sleep_queue "$@" ;;
    claim) sleep_claim "$@" ;;
    release) sleep_release "$@" ;;
    claims) sleep_claims_json ;;
    *) echo "usage: sleep-queue.sh next|queue|claim|release|claims ... (see the header of $0)" >&2; exit 2 ;;
  esac
  exit $?
fi
