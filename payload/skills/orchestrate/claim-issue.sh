#!/usr/bin/env bash
# claim-issue.sh: claim a GitHub issue on the issue itself before a builder starts on it
# (claude-config#3317).
#
#   claim-issue.sh claim   <owner/repo> <issue> <branch>
#   claim-issue.sh check   <owner/repo> <issue> <branch>
#   claim-issue.sh release <owner/repo> <issue> <branch> <reason>
#   claim-issue.sh takeover <owner/repo> <issue> <branch> <reason>
#
# Why it exists. On 2026-11-19 two sessions, one on each Mac, built the same fix for #3285. A branch
# that exists only in a local worktree is invisible to the other Mac, and nothing on the issue said
# the work was taken, so only a note on the issue can carry the claim. The orchestrate skill's rule
# is to run `claim` before dispatching a builder for an issue and to dispatch only on exit 0.
#
# claim does three reads, and refuses when any of them shows another session holds the issue:
#   1. the claims on the issue: a live claim posted by this script by any other session, on this
#      Mac or the other, and this session's own claim under another branch name;
#   2. open pull requests built for it: a branch or a title that names it, or a body that names it
#      straight after a closing keyword, "Part of" or "Refs". A pull request that only mentions the
#      number is printed as a note and holds nothing (claude-config#3788);
#   3. remote branches that name it.
# A pull request or a remote branch under the very name being claimed holds as well, unless this
# session's own claim accounts for it (see "Whose a branch is" below).
# Which issues a branch names is read by hooks/lib/branch-issues.mjs, the one shared reader.
# When none does, it posts a claim naming the Mac (as Dan names them), the time in ET and the
# branch, then reads the issue back. Two sessions that both found the issue free both post; the
# claim GitHub shows first wins, and the later one posts its own release and exits 1.
#
# check does the same reads and posts nothing. release posts that this session's claim on that
# branch has ended, with the reason, so the claim does not block the next session; it posts nothing
# when there is no live claim of this session's to release, and never ends another session's or one
# that records no session. takeover ends a claim from this Mac on that branch that records no
# session, and never a claim that names another session or the other Mac's; this session's own
# claim on that branch, if it has one, ends with it, because the comment names this session (see
# "Which session a claim belongs to" below).
#
# A claim is held by a hidden marker line, never by the prose around it:
#   <!-- orchestrate-claim branch=<branch> host=<host>,session=<session> -->
#   <!-- orchestrate-release branch=<branch> host=<host>,session=<session> -->
# A claim with no release goes stale after CLAIM_STALE_HOURS (default 24) and stops blocking; it is
# still printed. The open pull request and remote branch reads block whatever a claim's age.
#
# Which session a claim belongs to (claude-config#3804). Until 2026-11-27 a claim was told from
# another session's by the Mac and the branch name alone. Branch names are written from the issue's
# title, so two sessions on one Mac reach the same name, and on 2026-11-26 `claim` answered ALREADY
# CLAIMED, exit 0, for #3674 under a claim that was another session's, with that session's pull
# request open on the branch. So a claim names the session that made it:
#   - The session is the one Claude Code names in CLAUDE_CODE_SESSION_ID, which it gives every
#     command and hook a session runs, the commands of the agents it dispatches included (so a
#     session and its builders are one claimant). It is the id the session's transcript and its
#     notes folder are named by. Measured on the personal MacBook on 2026-11-27, Claude Code
#     2.1.332: a transcript holding two compactions carried that one id on every line that names
#     a session (9,491 of them, before, between and after), and the variable in a command run
#     after both compactions was that same id; one transcript written by two versions of Claude
#     Code (2.1.327, then 2.1.332), which only a restart of the process can produce, carried one
#     id on all 121,546 such lines. So a session is the same session after a compaction, and its
#     transcript goes on under one id after a restart (claude --resume or --continue of that
#     session). The variable itself was not read in a restarted session, so that this script sees
#     the same session after a restart is taken from the transcript and not measured. If a
#     restarted session were given a new id, its earlier claims would read HELD to it, as they do
#     after a /clear: wrong for that session, and nobody else is let in by it. Not the same
#     session: a /clear, which starts a new conversation under a new id (measured on 2.1.292, see
#     mods/session-registry/hooks/register.ts, claude-config#751), and a fork of a session.
#   - What is posted is a short name made from the id, the first 12 hex digits of its SHA-256, never
#     the id itself: the issue is public, and the id is the name of the session's transcript file.
#     The short name says nothing about the person, the Mac's folders or where the session can be
#     read, and the id cannot be worked back from it.
#   - It rides inside the host word, and the marker stays the six words it always was, because every
#     earlier version of this script reads a marker only when it has exactly those six. A Mac still
#     on an earlier version therefore reads the claim as another Mac's and holds; a seventh word
#     would have hidden the claim from it altogether.
#   - A claim whose host word names no session was posted before this change. Nothing says whose it
#     is, so it is never taken for the caller's: it holds, like any other session's, and a release
#     never ends it. The session that knows such a claim is its own takes it over on purpose with
#     takeover, then a claim: the take over ends it in the words it was posted in and names the
#     session that did so. It is a word of its own because the skill's Finish step runs release
#     for every claim a session believes it posted: while release did this too (the first two
#     commits of #3804), a session that had wrongly been told ALREADY CLAIMED under another
#     session's claim would have ended that live claim with its routine release.
#   - A session id that cannot be read (the variable missing or not an id, or the short name not
#     made) stops the script with exit 2 before it reads or posts anything.
#
# Whose a branch is. The builder pushes the claimed branch and opens its pull request, so a session
# resuming its own claim finds both on GitHub, and must not be held by them. Nothing GitHub records
# says which session pushed a branch (every session pushes as the same GitHub user), so the claims
# on the issue are the only evidence there is. A pull request or a remote branch under the name
# being claimed is this session's when the last claim on that name that held the issue (one posted
# while no other session's live claim stood on it, so never one that lost a race) is this session's
# own, live, stale or released; a claim with no session recorded that this session took over counts
# as its own. Anything else under that name, such as a branch another session pushed and left with
# no claim (#3546, 2026-11-26, answered CLAIMED), is not this session's, or cannot be told to be,
# and holds.
#
# Exit codes: 0 claimed by us (or free, for check, or released, or taken over, or nothing of this
# session's to release); 1 held by someone else or closed, do not start it, and for release and
# takeover, nothing was ended: the claim there records no session (release), or there is no claim
# from this Mac that records no session (takeover); 2 could not check, or bad arguments: do not
# start it. After exit 2 nothing was
# claimed unless the message says a claim may have been posted (the post errored, or the claim could
# not be read back); then it names the release command to run.
# A failed read is never taken as "nobody holds it", whether gh failed or a tool that reads what gh
# returned did (claude-config#3788).
#
# Test seams: CLAIM_NOW (epoch seconds) and CLAIM_HOST stand in for the clock and the hostname, and
# CLAIM_READBACK_WAIT (seconds, default 2) and CLAIM_READBACK_TRIES (default 3) for the read back.
# The session is read from CLAUDE_CODE_SESSION_ID itself, which a test sets.
set -uo pipefail

STALE_HOURS="${CLAIM_STALE_HOURS:-24}"
# A claim posted again this many seconds or less after its own unreleased post keeps that post's
# place among the claims (see live_claims). Ten minutes, chosen and not measured, and not a setting,
# since two sessions that read the same comments must agree who was first. It has to be longer than
# the gap between two runs of one session that did not see each other's post: one run's reads and
# its post, where the script itself allows a post READBACK_TRIES waits of READBACK_WAIT seconds to
# be seen. And it has to be much shorter than the stale window less any error in the Mac's clock,
# because a claim the Mac judged stale and posted again must never keep its old place: at ten
# minutes that takes a clock more than the window less ten minutes ahead of GitHub's, which a wrong
# time zone (hours) does not reach under the default window.
AGAIN_SECONDS=600
READBACK_WAIT="${CLAIM_READBACK_WAIT:-2}"
READBACK_TRIES="${CLAIM_READBACK_TRIES:-3}"
BRANCH_READER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/branch-issues.mjs"

usage() {
  echo "usage: claim-issue.sh claim|check <owner/repo> <issue> <branch>" >&2
  echo "       claim-issue.sh release|takeover <owner/repo> <issue> <branch> <reason>" >&2
  exit 2
}

mode="${1:-}"
repo="${2:-}"
issue="${3:-}"
branch="${4:-}"
reason="${5:-}"
case "$mode" in claim|check|release|takeover) ;; *) usage ;; esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "COULD NOT CHECK: '$repo' is not owner/repo." >&2; usage; }
[[ "$issue" =~ ^[0-9]+$ ]] || { echo "COULD NOT CHECK: '$issue' is not an issue number." >&2; usage; }
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "COULD NOT CHECK: '$branch' is not a branch name this script can record." >&2; usage; }
if [ "$mode" = release ] && [ -z "$reason" ]; then
  echo "COULD NOT CHECK: a release needs a reason, such as 'handed back unfinished'." >&2
  usage
fi
if [ "$mode" = takeover ] && [ -z "$reason" ]; then
  echo "COULD NOT CHECK: a take over needs a reason, such as 'this session posted it before claims named their session'." >&2
  usage
fi

now="${CLAIM_NOW:-$(date +%s)}"
host="${CLAIM_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"

mac_name() { # the Mac as Dan names it (global CLAUDE.md, Projects)
  case "$1" in
    Dans-MacBook-Pro) echo "the work MacBook" ;;
    Daniels-MacBook-Pro-2) echo "the personal MacBook" ;;
    *) echo "the Mac named $1" ;;
  esac
}
et_time() { # epoch seconds to "11:25 AM ET on 2026-11-19", on macOS date or GNU date
  TZ=America/New_York date -r "$1" '+%-I:%M %p ET on %Y-%m-%d' 2>/dev/null ||
    TZ=America/New_York date -d "@$1" '+%-I:%M %p ET on %Y-%m-%d'
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- which session is calling ----
# The short name this session's claims carry (see "Which session a claim belongs to" above). Read
# before anything is read from GitHub or posted there: with no session the script can neither claim
# as anybody nor tell a claim of its own from another session's, so it stops.
no_session() { # no_session <why>
  if [ "$mode" = release ]; then
    echo "COULD NOT RELEASE: this session's id could not be read ($1), so which claim on $repo#$issue is its own is unknown. Nothing was posted, and any claim of this session's still stands."
  elif [ "$mode" = takeover ]; then
    echo "COULD NOT TAKE OVER: this session's id could not be read ($1), so the take over on $repo#$issue could not name the session doing it. Nothing was posted, and every claim there still stands."
  else
    echo "COULD NOT CHECK: this session's id could not be read ($1), so a claim of its own on $repo#$issue could not be told from another session's. Do not start it, and nothing was claimed."
  fi
  [ -s "$tmp/session.err" ] && sed 's/^/  /' "$tmp/session.err"
  exit 2
}
session_id="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$session_id" ] || no_session "CLAUDE_CODE_SESSION_ID is not set, which Claude Code sets for every command a session runs"
[[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,}$ ]] || no_session "CLAUDE_CODE_SESSION_ID does not hold a session id"
# One tool is chosen and its exit status read. Falling through from a tool that failed to another
# would hash the empty input the first one left, and that is one name for every session.
if command -v shasum >/dev/null 2>&1; then
  session="$(printf '%s' "$session_id" | shasum -a 256 2>"$tmp/session.err")" || no_session "shasum could not make its short name"
elif command -v sha256sum >/dev/null 2>&1; then
  session="$(printf '%s' "$session_id" | sha256sum 2>"$tmp/session.err")" || no_session "sha256sum could not make its short name"
else
  no_session "neither shasum nor sha256sum is here to make its short name"
fi
session="${session:0:12}"
[[ "$session" =~ ^[0-9a-f]{12}$ ]] || no_session "its short name came out as something other than 12 hex digits"

# ---- the reads ----
# The issue's state, then every marker line in its comments, each prefixed with its comment's time.
issue_jq='"STATE " + .state, (.comments[] | (.createdAt | fromdateiso8601 | tostring) as $t | .body | gsub("\r"; "") | split("\n")[] | select(startswith("<!-- orchestrate-")) | $t + " " + .)'
read_issue() { # fills $tmp/issue; returns non zero, with the reason in $tmp/issue.err, when it cannot
  if ! gh issue view "$issue" --repo "$repo" --json state,comments --jq "$issue_jq" >"$tmp/issue" 2>"$tmp/issue.err"; then
    return 1
  fi
  # No STATE line means gh printed nothing it was asked for, which is not an empty issue.
  if ! grep -q '^STATE ' "$tmp/issue"; then
    echo "gh returned no state for the issue" >"$tmp/issue.err"
    return 1
  fi
}

# The claims on the issue, read out of its marker lines in the order GitHub shows them. Two kinds of
# line come out:
#   LIVE <epoch> <branch> <host> <session>   a claim no release has ended, stale or not, in the
#                                            order of each claim's latest post, or of the post
#                                            before it when the two are AGAIN_SECONDS or less apart
#   NAME <branch> <host> <session>           whose that branch name is (see "Whose a branch is")
# <session> is "-" for a claim posted before claims named their session. A claim is one branch, host
# and session; a release ends the claim with the same three. A host word that is not a Mac's name
# alone, or a Mac's name and ",session=" and 12 hex digits, is read whole as a Mac nobody here is.
# A branch name passes to the session whose claim on it held the issue: one posted while no other
# claim stood live on it (within the stale window of its own time). And it passes from a claim with
# no session recorded to the session that took that claim over: a release that ended it, followed
# in the same comment by the release naming the session.
# awk, not a bash associative array, which the bash 3.2 macOS ships does not have.
live_claims() {
  awk -v window="$((STALE_HOURS * 3600))" -v again="$AGAIN_SECONDS" '
    NF == 6 && $2 == "<!--" && $6 == "-->" &&
      $1 ~ /^[0-9]+$/ &&
      $4 ~ /^branch=/ && $5 ~ /^host=/ {
      b = substr($4, 8); h = substr($5, 6); s = "-"
      if (h ~ /^[^,]+,session=[0-9a-f]+$/ && length(h) - index(h, ",session=") - 8 == 12) {
        s = substr(h, index(h, ",session=") + 9); h = substr(h, 1, index(h, ",session=") - 1)
      }
      key = b " " h " " s
      if ($3 == "orchestrate-claim") {
        held = 1
        for (k in when) if (k != key && $1 - when[k] <= window) held = 0
        if (held) { if (!(b in name)) { m++; names[m] = b }; name[b] = h " " s }
        # A claim posted again over one its session judged over takes the place of this, its
        # latest post, never the place of the earlier one: another session that judged the same
        # may have claimed in between, and keeping the earlier place let the claim posted again
        # read as first, so both sessions were told CLAIMED. A session judges a claim of its own
        # over only when it is past the stale window on the clock of its Mac. With the clock at
        # GitHub behind that one, such a claim is posted again inside the window by the times
        # GitHub stamps, so the window is not the test (section 12 of the suite, 12a to 12c).
        # A claim is also posted again when the earlier post was never judged at all: a second
        # run of the same session read the issue before the first post could be seen. The first
        # run may already have been told CLAIMED, so that post keeps its place, or a session that
        # claimed between the two is told CLAIMED as well (12e to 12h). The two are told apart by
        # the gap between the posts, both times stamped by GitHub: AGAIN_SECONDS or less is a
        # post that was not seen. No apostrophe in this program: it sits in single quotes.
        if (!(key in when) || $1 - when[key] > again) { n++; order[n] = key; pos[key] = n }
        when[key] = $1
        ended = ""
      } else if ($3 == "orchestrate-release") {
        if (s == "-") {
          ended = (key in when) ? b " " h " " $1 : ""
        } else {
          # (b in name) first: reading name[b] alone would create it empty, and a name that
          # exists is never listed again, so a later claim that holds the issue would not get it.
          if (ended == b " " h " " $1 && (b in name) && name[b] == h " -") name[b] = h " " s
          ended = ""
        }
        delete when[key]
      }
    }
    END {
      for (i = 1; i <= n; i++) { k = order[i]; if ((k in when) && pos[k] == i) print "LIVE", when[k], k }
      for (i = 1; i <= m; i++) print "NAME", names[i], name[names[i]]
    }
  ' "$tmp/issue"
}

# Prints nothing. Fills these globals from the claims: blocking (one line per claim that holds the
# issue against this call), stale (one line per claim past the stale window, which does not block),
# first_holder ("ours" or "other" for whoever holds the first live claim GitHub lists, "" for none),
# takeover (the branch of each unreleased claim from this Mac with no session recorded, which this
# session can take over if it is its own) and name_is_ours (yes when the branch name being claimed
# is this session's, so a pull request or a remote branch under it is its own).
blocking=()
stale=()
takeover=()
first_holder=""
name_is_ours=no
# Returns non zero, with the reason in $tmp/live.err, when the claims could not be read out of the
# issue: no claim seen is then not the same as no claim there (claude-config#3788).
judge_claims() {
  local kind t b h s who
  blocking=(); stale=(); takeover=(); first_holder=""; name_is_ours=no
  live_claims >"$tmp/live" 2>"$tmp/live.err" || return 1
  while read -r kind t b h s; do
    if [ "$kind" = NAME ]; then # NAME <branch> <host> <session>, read here as t, b and h
      [ "$t" = "$branch" ] && [ "$b" = "$host" ] && [ "$h" = "$session" ] && name_is_ours=yes
      continue
    fi
    [ "$kind" = LIVE ] || continue
    who="$(mac_name "$h") claimed it at $(et_time "$t"), branch $b"
    if [ "$h" = "$host" ] && [ "$s" = - ]; then
      who="$who, with no session recorded"
      takeover+=("$b")
    elif [ "$h" = "$host" ] && [ "$s" != "$session" ]; then
      who="another session on $who"
    fi
    if [ $((now - t)) -gt $((STALE_HOURS * 3600)) ]; then
      stale+=("stale claim, older than $STALE_HOURS hours with no release, so not counted: $who")
      continue
    fi
    if [ "$b" = "$branch" ] && [ "$h" = "$host" ] && [ "$s" = "$session" ]; then
      [ -n "$first_holder" ] || first_holder=ours
    elif [ "$h" = "$host" ] && [ "$s" = "$session" ]; then
      [ -n "$first_holder" ] || first_holder=other
      blocking+=("claim: this session's own claim, under another branch name, posted at $(et_time "$t"), branch $b: claim under that name, or release that claim first")
    else
      [ -n "$first_holder" ] || first_holder=other
      [ "$s" = - ] && [ "$h" = "$host" ] && who="$who, so it is not taken for this session's own"
      blocking+=("claim: $who")
    fi
  done <"$tmp/live"
  return 0
}

fail_read() { # fail_read <what> <error file>
  if [ "$mode" = release ]; then
    echo "COULD NOT RELEASE: could not read $1 for $repo#$issue, so nothing was posted and any claim of this session's still stands. Run the release again."
  elif [ "$mode" = takeover ]; then
    echo "COULD NOT TAKE OVER: could not read $1 for $repo#$issue, so nothing was posted and every claim there still stands. Run the take over again."
  else
    echo "COULD NOT CHECK: could not read $1 for $repo#$issue, so whether another session holds it is unknown. Do not start it, and nothing was claimed."
  fi
  sed 's/^/  /' "$2"
  exit 2
}

post() { # post <body file>
  gh issue comment "$issue" --repo "$repo" --body-file "$1" >/dev/null 2>"$tmp/post.err"
}

claim_marker="<!-- orchestrate-claim branch=$branch host=$host,session=$session -->"
release_marker="<!-- orchestrate-release branch=$branch host=$host,session=$session -->"
release_body() { # release_body <reason> <file>
  {
    echo "Released by the session on $(mac_name "$host") at $(et_time "$now"): work on branch \`$branch\` stopped ($1). Another session may take this issue."
    echo ""
    echo "$release_marker"
  } >"$2"
}
# takeover_body <reason> <file>: ends a claim from this Mac that names no session, in the words
# that claim was posted in. That line comes first and the line naming this session straight after
# it, which is how a later read knows who took it over.
takeover_body() {
  {
    echo "Taken over by a session on $(mac_name "$host") at $(et_time "$now"): the claim on branch \`$branch\` that recorded no session is ended by the session that says it is its own ($1). That session claims again, in its own name, if it carries on."
    echo ""
    echo "<!-- orchestrate-release branch=$branch host=$host -->"
    echo "$release_marker"
  } >"$2"
}

read_issue || fail_read "the issue's comments" "$tmp/issue.err"

# ---- release and takeover ----
# release ends this session's claim on the branch and no other: never another session's, which
# only that session can release, and never one from this Mac that names no session, which nothing
# says is this session's. takeover ends a claim from this Mac on the branch that names no session,
# and posts nothing unless there is one. Its comment names this session, so a claim of this
# session's own on that branch ends with it, which the answer says; no other session's claim does
# (see "Which session a claim belongs to" in the header).
if [ "$mode" = release ] || [ "$mode" = takeover ]; then
  ours=no
  unnamed=no
  others=no
  name_held_by="" # whose the branch name is: "unnamed" (a claim from this Mac with no session), "ours", or neither
  live_claims >"$tmp/live" 2>"$tmp/live.err" || fail_read "the claims on the issue" "$tmp/live.err"
  while read -r kind t b h s; do
    if [ "$kind" = NAME ]; then # NAME <branch> <host> <session>, read here as t, b and h
      if [ "$t" = "$branch" ] && [ "$b" = "$host" ]; then
        [ "$h" = - ] && name_held_by=unnamed
        [ "$h" = "$session" ] && name_held_by=ours
      fi
      continue
    fi
    [ "$kind" = LIVE ] && [ "$b" = "$branch" ] && [ "$h" = "$host" ] || continue
    case "$s" in
      "$session") ours=yes ;;
      -) unnamed=yes ;;
      *) others=yes ;;
    esac
  done <"$tmp/live"
  others_line="  another session on $(mac_name "$host") holds a claim on that branch, and only that session can release it"
  takeover_cmd="claim-issue.sh takeover $repo $issue $branch \"<reason>\""

  if [ "$mode" = takeover ]; then
    if [ "$unnamed" = no ]; then
      echo "NOTHING TO TAKE OVER: $repo#$issue has no live claim from $(mac_name "$host") on branch $branch that records no session. Nothing posted."
      [ "$others" = yes ] && echo "$others_line"
      [ "$ours" = yes ] && echo "  this session's own claim on that branch names it and still stands: release ends it"
      exit 1
    fi
    takeover_body "$reason" "$tmp/release"
    if ! post "$tmp/release"; then
      echo "COULD NOT TAKE OVER: the take over was not posted on $repo#$issue, so the claim still stands."
      sed 's/^/  /' "$tmp/post.err"
      exit 2
    fi
    echo "TAKEN OVER: $repo#$issue, branch $branch. The claim had no session recorded; it is ended, and the comment names this session as the one that took it over."
    case "$name_held_by" in
      unnamed) echo "  The branch name was that claim's, so a claim this session posts on that branch next counts the branch and its pull request as its own. Claim again." ;;
      ours) echo "  The branch name was this session's already, by a claim of its own, and still is." ;;
      *) echo "  The branch name was not that claim's to pass on (it was posted under another live claim, or a later claim took the name), so a pull request or a branch already up under that name still holds." ;;
    esac
    [ "$ours" = yes ] && echo "  this session's own claim on that branch ended with it: the comment that names this session ends both"
    exit 0
  fi

  if [ "$ours" = no ] && [ "$unnamed" = yes ]; then
    echo "NOT RELEASED: the claim on $repo#$issue from $(mac_name "$host") on branch $branch records no session, so nothing says it is this session's own. Nothing posted, and that claim still stands."
    echo "  only if that claim is this session's own, posted before claims named their session, run: $takeover_cmd"
    [ "$others" = yes ] && echo "$others_line"
    exit 1
  fi
  if [ "$ours" = no ]; then
    echo "NOTHING TO RELEASE: $repo#$issue has no live claim of this session's from $(mac_name "$host") on branch $branch. Nothing posted."
    [ "$others" = yes ] && echo "$others_line"
    exit 0
  fi
  release_body "$reason" "$tmp/release"
  if ! post "$tmp/release"; then
    echo "COULD NOT RELEASE: the release was not posted on $repo#$issue, so the claim still stands."
    sed 's/^/  /' "$tmp/post.err"
    exit 2
  fi
  echo "RELEASED: $repo#$issue, branch $branch."
  [ "$unnamed" = yes ] && echo "  a claim on that branch that records no session still stands, and this release did not end it; only if it is this session's own, run: $takeover_cmd"
  exit 0
fi

# ---- claim and check: the other two reads ----
pr_jq='.[] | [(.number | tostring), .headRefName, .title, ((.body // "") | gsub("\\s+"; " "))] | @tsv'
gh pr list --repo "$repo" --state open --limit 1000 --json number,headRefName,title,body --jq "$pr_jq" \
  >"$tmp/prs" 2>"$tmp/prs.err" || fail_read "the open pull requests" "$tmp/prs.err"
gh api --paginate "repos/$repo/branches?per_page=100" --jq '.[].name' \
  >"$tmp/branches" 2>"$tmp/branches.err" || fail_read "the remote branches" "$tmp/branches.err"

# gh answering is half of a read. Each tool that then reads what gh returned (sed, awk, cut, cat,
# grep below) has its own exit status checked, because a tool that fails leaves its answer empty and
# an empty answer reads as nobody holding the issue (claude-config#3788).
state="$(sed -n 's/^STATE //p' "$tmp/issue" 2>"$tmp/state.err")" || fail_read "the issue's state" "$tmp/state.err"
if [ "$state" != OPEN ]; then
  echo "CLOSED: $repo#$issue is $state. Do not start it."
  exit 1
fi

judge_claims || fail_read "the claims on the issue" "$tmp/live.err"

# Which issues a branch's name names is read by the one shared reader, mod-kit's issuesOfBranch
# through hooks/lib/branch-issues.mjs, never a pattern kept here (claude-config#1475): an agent
# worktree's random id and a branch on two issues are where hand written readings drifted.
{ cut -f 2 "$tmp/prs" && cat "$tmp/branches"; } >"$tmp/names" 2>"$tmp/names.err" ||
  fail_read "the branch names of the pull requests and the remote" "$tmp/names.err"
if ! node --experimental-strip-types --no-warnings "$BRANCH_READER" <"$tmp/names" >"$tmp/named.json" 2>"$tmp/named.err" ||
  ! jq -r --argjson n "$issue" 'to_entries[] | select(any(.value[]; . == $n)) | .key' \
    "$tmp/named.json" >"$tmp/naming" 2>>"$tmp/named.err"; then
  fail_read "which issues the remote branches name" "$tmp/named.err"
fi
names_it() { # names_it <branch>: grep's 1 is no match, and anything above it is a read that failed
  local found=0
  grep -q -x -F -- "$1" "$tmp/naming" 2>"$tmp/naming.err" || found=$?
  [ "$found" -le 1 ] || fail_read "which branches name the issue" "$tmp/naming.err"
  return "$found"
}

# A pull request holds the issue only when it is built for it (claude-config#3788): its branch or
# its title names the issue, or its body names it straight after one of the words in built_re. Any
# other mention of the number is printed as a note and holds nothing. Until 2026-11-26 every mention
# held, and three priority p1 issues could not be started because pull requests built for other
# issues named them as related or left over work.
# The words were measured on 2026-11-26 from the repository's 68 open and 300 most recently merged
# pull requests: "Closes" (258 lines), "Part of" (132) and "Refs" (9, the word used here for a pull
# request built for an issue it will not close) were the only ones that named what a pull request
# was built for. GitHub's other closing keywords are held as well. The issue may be written #N,
# owner/repo#N or repo#N; another repository's issue of the same number is a mention.
ref_re="#${issue}([^0-9]|$)"
this_repo="${repo//./[.]}"
built_re="(^|[^a-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?|part of|refs):? (${this_repo}|${this_repo#*/})?#${issue}([^0-9]|$)"
built_for() { # built_for <body>: does the body say its pull request is built for the issue?
  local found=1
  shopt -s nocasematch
  [[ "$1" =~ $built_re ]] && found=0
  shopt -u nocasematch
  return "$found"
}
# A pull request or a remote branch under the very name being claimed is this session's only when
# its own claim accounts for it (name_is_ours, see "Whose a branch is" in the header). Then it is
# said as a note. Otherwise it holds, whether or not the name carries the issue's number: a name
# already on GitHub that this session did not make is no name to start a builder on
# (claude-config#3804; until then both were passed over as the caller's own, whoever made them).
own_note="this session's own, by its claim on the issue"
not_ours="the branch name being claimed, which no claim of this session's accounts for"
notes=()
while IFS=$'\t' read -r n head title body; do
  [ -n "$n" ] || continue
  if [ "$head" = "$branch" ]; then
    if [ "$name_is_ours" = yes ]; then
      notes+=("$own_note: pull request #$n ($head)")
    else
      blocking+=("pull request: #$n ($head) $title ($not_ours)")
    fi
    continue
  fi
  if names_it "$head" || [[ "$title" =~ $ref_re ]] || built_for "$body"; then
    blocking+=("pull request: #$n ($head) $title")
  elif [[ "$body" =~ $ref_re ]]; then
    notes+=("mentioned, not held: pull request #$n ($head) names #$issue without being built for it: $title")
  fi
done <"$tmp/prs"
while IFS= read -r b; do
  [ -n "$b" ] || continue
  if [ "$b" = "$branch" ]; then
    if [ "$name_is_ours" = yes ]; then
      notes+=("$own_note: remote branch $b")
    else
      blocking+=("remote branch: $b ($not_ours)")
    fi
    continue
  fi
  names_it "$b" && blocking+=("remote branch: $b")
done <"$tmp/branches"

print_list() { local l; for l in "$@"; do echo "  $l"; done; }
# What was seen and does not hold the issue, printed under every outcome: stale claims, the pull
# requests that only mention it, and what is up on GitHub under this session's own claim.
print_unheld() {
  print_list "${stale[@]+"${stale[@]}"}"
  print_list "${notes[@]+"${notes[@]}"}"
}
# Under a held outcome: how to take over a claim from this Mac that names no session, which only
# the session that posted it before claims named their session can know to be its own.
print_takeover() {
  local b
  for b in "${takeover[@]+"${takeover[@]}"}"; do
    echo "  only if the claim on branch $b with no session recorded is this session's own, posted before claims named their session, take it over on purpose: claim-issue.sh takeover $repo $issue $b \"<reason>\", then claim again (a plain release leaves it standing)"
  done
}

if [ "${#blocking[@]}" -gt 0 ]; then
  echo "HELD: $repo#$issue is held by another session, so do not start it."
  print_list "${blocking[@]}"
  print_takeover
  print_unheld
  exit 1
fi

if [ "$first_holder" = ours ]; then
  echo "ALREADY CLAIMED: $repo#$issue already carries this session's claim on branch $branch. Nothing posted."
  print_unheld
  exit 0
fi

if [ "$mode" = check ]; then
  echo "FREE: nothing holds $repo#$issue. Nothing posted."
  print_unheld
  exit 0
fi

# ---- post the claim, then read it back ----
{
  echo "Claimed for building by an orchestrating session on $(mac_name "$host") at $(et_time "$now"), on branch \`$branch\`. Another session should not start on this issue while the claim stands. If the work is dropped or handed back unfinished, a release is posted here; a claim with no release stops counting after $STALE_HOURS hours."
  echo ""
  echo "$claim_marker"
} >"$tmp/claim"
# A post that errored (a timeout, a 5xx) may still have landed, and GitHub's read path can lag its
# write, so the issue is read back after a pause, up to READBACK_TRIES times, whatever the post said.
posted=yes
post "$tmp/claim" || posted=no
attempt=0
first_holder=""
while [ "$attempt" -lt "$READBACK_TRIES" ]; do
  attempt=$((attempt + 1))
  sleep "$READBACK_WAIT"
  : >"$tmp/live.err"
  if ! read_issue || ! judge_claims; then
    first_holder=""
  fi
  [ -n "$first_holder" ] && break
done
release_cmd="claim-issue.sh release $repo $issue $branch \"<reason>\""
case "$first_holder" in
  ours)
    echo "CLAIMED: $repo#$issue for branch $branch, from $(mac_name "$host") at $(et_time "$now"). Start the builder."
    print_unheld
    exit 0 ;;
  other)
    release_body "another session claimed it first" "$tmp/release"
    post "$tmp/release" || echo "  (the release of this session's claim could not be posted either; post it with the release command)"
    echo "HELD: another session claimed $repo#$issue a moment before this one, so this claim was released. Do not start it."
    print_list "${blocking[@]}"
    print_unheld
    exit 1 ;;
  *)
    if [ "$posted" = no ]; then
      echo "COULD NOT CHECK: posting the claim on $repo#$issue failed, and no claim of this session's could be read back. Do not start it. A claim may still have landed: run $release_cmd so it does not block the next session."
      sed 's/^/  /' "$tmp/post.err"
    else
      echo "COULD NOT CHECK: the claim was posted on $repo#$issue but could not be seen on reading it back $READBACK_TRIES times. Do not start it, and run $release_cmd so it does not block the next session."
      [ -s "$tmp/issue.err" ] && sed 's/^/  /' "$tmp/issue.err"
      [ -s "$tmp/live.err" ] && sed 's/^/  /' "$tmp/live.err"
    fi
    exit 2 ;;
esac
