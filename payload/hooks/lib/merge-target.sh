#!/usr/bin/env bash
#
# merge-target.sh: shared helpers for hooks that gate a pull request merge.
#
# Sourced by the gates. Also runnable, for the one caller that is not bash: see
# the dispatch at the foot of the file. Holds the things every merge gate has to
# work out before it can say anything about a pull request, so they exist once
# rather than once per gate:
#
#   mt_is_pr_merge   is this command actually a merge
#   mt_runs_merge    does it cause one by any route, wrappers included
#   mt_repo_dir      which directory the merge will run in, which is not
#                      necessarily the session cwd
#   mt_checkout_dir  the checkout a directory belongs to, which is the part of
#                      that answer a non-merge caller needs too
#   mt_checkout_candidates
#                    the child checkouts under a directory, so a caller that
#                      cannot resolve one can say which it was torn between
#   mt_pr_number     the pull request the command names, if it names one
#   mt_remote_slug   owner/name from the git remote, read from the CURRENT
#                      directory, so callers cd first
#   mt_pr_view       the pull request's fields, from whichever logged-in
#                      account can actually see the repo, proved to be about
#                      the repo the remote names
#
# Every one of these was learned the hard way by block-red-merge.sh and is
# commented there with the incident that produced it. They are here rather than
# there because a second merge gate copying them would be a second copy that
# drifts, and the drift would be silent: each gate would go on passing its own
# tests while disagreeing with the other about which pull request it is looking
# at.

# Is this command a merge, and which kind.
#
# Two questions, one tokeniser, because they have different answers and both are
# needed:
#
#   mt_is_pr_merge   does a segment run the gh merge command itself
#   mt_runs_merge    does a segment cause a merge by ANY route, including a
#                      repo's own wrapper, which merges internally in a
#                      subprocess no hook can see
#
# The blocking gates ask the first. They must NOT fire on a wrapper:
# block-red-merge.sh TELLS somebody to run the wrapper where a repo has one, so a
# gate that then refused it would name a remedy only that gate forbids, which is
# a refusal nothing can clear (L109). The quiz asks the second, because a quiz
# that only knows the direct form is silently dodged by using the project's own
# recommended merge command.
#
# Both read the LEADING TOKENS of each shell segment, never the whole string. The
# whole string version denied any command that merely TALKED about merging: a
# heredoc, an issue body, a commit message, an echo (L673). Hit twice on
# 2026-09-10 writing issue bodies about merge tooling, and because it is a
# PreToolUse deny the whole command was refused, so the heredoc never ran and the
# failure surfaced one step later as a missing file. This matcher was already
# written correctly in pr-merge-quiz.sh, a hook that only ADVISES, while the
# blocking gates shared the wrong one; it lives here now and that hook calls it,
# so the two cannot drift (claude-config#349).

# The routes a merge actually arrives by, beyond the direct command.
#
# MT_MERGE_WRAPPERS merge whenever they run. MT_MERGE_WAITERS merge only with a flag:
# PET's tool WAITS for the checks and merges nothing without --merge, so matching it
# bare would fire on every look at a pull request. That is why the whole segment is
# read for these and not only its leading tokens.
#
# An interpreter is matched by BASENAME, so a tool run out of a virtualenv
# (venv/bin/python, .venv/bin/python) is the same route as one run by python3.
MT_MERGE_WRAPPERS="merge-when-green.sh merge-pr.sh"
MT_MERGE_WAITERS="wait_for_checks.py"
MT_MERGE_WAITER_FLAG="--merge"
MT_INTERPRETERS="bash sh zsh python python3"

# The command with every heredoc BODY removed, so text nobody is executing is not
# read as something somebody is. Done BEFORE the segment split rather than during
# it, because a body is ordinary prose and prose carries semicolons: splitting
# first turns the sentence after a semicolon into a segment of its own.
#
# A herestring is blanked first. Three angle brackets hold two starting at the
# second character, so a herestring whose word follows immediately would
# otherwise be read as opening a heredoc named for that word, and would swallow
# the rest of the command.
#
# Its one blind spot, stated rather than hidden: two angle brackets inside a
# quoted string open a heredoc here that the shell would not. That direction
# loses lines, so it can only make a matcher fail to fire, never fire wrongly.
mt_strip_heredocs() {  # $1 = command
  local line probe delim="" trimmed in_body=0 out=""
  local opener='<<-?[[:space:]]*("[A-Za-z_][A-Za-z0-9_]*"|'"'"'[A-Za-z_][A-Za-z0-9_]*'"'"'|[A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" = 1 ]; then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [ "$trimmed" = "$delim" ] && in_body=0
      continue
    fi
    out="$out$line"$'\n'
    probe="${line//<<</   }"
    if [[ "$probe" =~ $opener ]]; then
      delim="${BASH_REMATCH[1]}"
      delim="${delim%\"}"; delim="${delim#\"}"
      delim="${delim%\'}"; delim="${delim#\'}"
      in_body=1
    fi
  done <<MTEOF
$1
MTEOF
  printf '%s' "$out"
}

# The first three tokens of every shell segment, one segment per line, with any
# leading environment assignments dropped. Three because the longest thing being
# looked for is three tokens.
#
# Split on `&&`, `||` and `;` only. A pipe and a bare `&` also start a command,
# and are deliberately left alone: nothing ever pipes into a merge, so splitting
# on them buys nothing while giving a quoted payload one more way to be cut into
# a segment that starts with the phrase.
mt_command_segments() {  # $1 = command
  local body seg
  body="$(mt_strip_heredocs "$1")"
  body="${body//&&/$'\n'}"
  body="${body//||/$'\n'}"
  body="${body//;/$'\n'}"
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    while [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do
      seg="${BASH_REMATCH[1]}"
    done
    printf '%s\n' "$seg"
  done <<MTEOF
$body
MTEOF
}

mt_command_heads() {  # $1 = command
  local seg first second third rest
  while IFS= read -r seg; do
    first=""; second=""; third=""; rest=""
    read -r first second third rest <<MTEOF
$seg
MTEOF
    printf '%s %s %s\n' "$first" "$second" "$third"
  done < <(mt_command_segments "$1")
}

# True when this ONE segment causes a merge, by any route other than the direct command.
mt_segment_runs_wrapper() {  # $1 = a cleaned segment
  local seg="$1" first second third rest target wrapper
  # Four variables for three tokens, deliberately: `read` gives the LAST variable
  # everything that is left, so reading three would make `third` the whole remainder
  # and `npm run merge -- 680` would never match `merge` exactly.
  read -r first second third rest <<MTEOF
$seg
MTEOF
  [ -n "$first" ] || return 1

  # The wrapper is either the command itself, or the argument to an interpreter.
  target="$first"
  case " $MT_INTERPRETERS " in
    *" ${first##*/} "*) target="$second" ;;
  esac

  for wrapper in $MT_MERGE_WRAPPERS; do
    [ -n "$target" ] && [ "${target##*/}" = "$wrapper" ] && return 0
  done
  for wrapper in $MT_MERGE_WAITERS; do
    if [ -n "$target" ] && [ "${target##*/}" = "$wrapper" ]; then
      case " $seg " in
        *" $MT_MERGE_WAITER_FLAG "*|*" $MT_MERGE_WAITER_FLAG") return 0 ;;
      esac
    fi
  done

  # `npm run merge`, exactly: what follows `npm run` is a script name rather than a
  # path, so a basename match cannot see it, and `npm run merge-ready` only reports.
  [ "$first" = "npm" ] && [ "$second" = "run" ] && [ "$third" = "merge" ] && return 0
  return 1
}

# True when a segment runs the gh merge command itself. The leading `(^|/)` lets
# gh be called by an absolute path without letting the phrase match inside a
# quoted word.
#
# The cheap substring test comes first, so an ordinary command (which is every
# command in every session, since both blocking gates ask this before anything
# else) is answered by one glob and no subshell.
mt_is_pr_merge() {  # $1 = command
  case "$1" in *merge*) ;; *) return 1 ;; esac
  mt_command_heads "$1" \
    | grep -Eq '(^|/)gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
}

# True when a segment causes a merge by any route: the direct command, a repo's
# own merge wrapper in command position (as the first token, or the second when
# the first is an interpreter), or `npm run merge`, which is how one of those
# wrappers is invoked and which a basename match cannot see, because what follows
# `npm run` is a script name rather than a path.
#
# `merge` has to match EXACTLY there: `npm run merge-ready` only reports and
# merges nothing, so a prefix match would fire on every look at a pull request.
mt_runs_merge() {  # $1 = command
  case "$1" in *merge*) ;; *) return 1 ;; esac
  mt_is_pr_merge "$1" && return 0
  local seg
  while IFS= read -r seg; do
    mt_segment_runs_wrapper "$seg" && return 0
  done < <(mt_command_segments "$1")
  return 1
}

# The pull request number if the command names one; empty otherwise, in which
# case gh resolves it from the current branch, which is also what the merge
# itself would do.
mt_pr_number() {  # $1 = command
  local direct seg first second third rest prev tok target
  local -a MT_TOKENS
  direct="$(mt_strip_heredocs "$1" \
    | grep -oE 'gh pr me''rge[[:space:]]+(--[^[:space:]]+[[:space:]]+)*([0-9]+)' \
    | grep -oE '[0-9]+$' | awk 'NR <= 1')"
  [ -n "$direct" ] && { printf '%s' "$direct"; return; }

  # A wrapper takes the number as its FIRST POSITIONAL argument, and reading it beats
  # inferring one from the current branch, which after a merge is the thing most likely
  # to have moved (claude-config#351).
  #
  # A token is positional when the token before it is not a flag. `--` is the end of
  # options marker rather than a flag, so `npm run merge -- 680` still names 680.
  #
  # When no positional number can be found it answers EMPTY, deliberately, so gh
  # resolves from the branch. The tempting fallback, taking the first run of digits
  # anywhere in the segment, reads `--timeout 900 42` as pull request 900, and a gate
  # that reads the wrong pull request's record is worse than one that reads none (L75).
  while IFS= read -r seg; do
    mt_segment_runs_wrapper "$seg" || continue
    read -r first second third rest <<MTEOF
$seg
MTEOF
    target="$first"
    case " $MT_INTERPRETERS " in
      *" ${first##*/} "*) target="$second" ;;
    esac
    prev=""
    # Read into an array rather than looping over an unquoted expansion, which would
    # let a `*` in the command glob against the working directory.
    read -ra MT_TOKENS <<MTEOF
$seg
MTEOF
    for tok in "${MT_TOKENS[@]}"; do
      case "$tok" in
        [0-9]*[!0-9]*|"") prev="$tok"; continue ;;
        [0-9]*) ;;
        *) prev="$tok"; continue ;;
      esac
      case "$prev" in
        --) printf '%s' "$tok"; return ;;
        -*) prev="$tok"; continue ;;
        "") prev="$tok"; continue ;;
        *) printf '%s' "$tok"; return ;;
      esac
    done
  done < <(mt_command_segments "$1")
}

# Resolve the directory the merge will actually run in.
#
# Not necessarily the session cwd: PET keeps its git repo in a pet/ subdirectory,
# so a hook started outside any repo and gh could not resolve the pull request at
# all. That produced a false block on a green pull request the first time this
# ran.
#
# Order: an explicit `cd` at the head of the command wins, because that is where
# the merge itself will run. Otherwise the session cwd, then walk up for a repo,
# then look one level down.
mt_repo_dir() {  # $1 = command, $2 = session cwd
  local command="$1" d="$2" from_cd=""

  # Bash's own regex, not sed: macOS sed is BRE and treats \+ as a literal plus,
  # so a sed version of this silently matched nothing and every merge was blocked.
  if [[ "$command" =~ ^[[:space:]]*cd[[:space:]]+(\"[^\"]+\"|\'[^\']+\'|[^[:space:]\&\|\;]+) ]]; then
    from_cd="${BASH_REMATCH[1]}"
    from_cd="${from_cd%\"}"; from_cd="${from_cd#\"}"
    from_cd="${from_cd%\'}"; from_cd="${from_cd#\'}"
  fi
  if [ -n "$from_cd" ] && [ -d "$from_cd" ]; then printf '%s' "$from_cd"; return; fi

  [ -n "$d" ] && [ -d "$d" ] || d=$PWD
  mt_checkout_dir "$d"
}

# The checkout a directory belongs to: the directory itself, else the first
# ancestor holding a .git, else its ONE child holding one. When there is none
# anywhere, or more than one, the directory itself, unchanged, so a caller is
# still handed somewhere it can run and reports the refusal in its own words.
#
# More than one child is a refusal rather than a choice. The walk used to take
# whichever the glob yielded first, which answers ANY where the question needs
# exactly ONE (L521) and addresses a thing by its position rather than its
# identity (L237). Harmless while only the merge gate used it; not harmless once
# the issue review resolved its repository this way, because the wrong answer
# there is another project's issue numbers stamped onto this project's findings,
# and match-open-issues.py rests on a wrong "already #N" being worse than none
# (claude-config#346). An ancestor still wins: a directory INSIDE a checkout
# belongs to it whatever its own children look like.
#
# Named and separate because a second caller asks the same question for a
# different reason: the issue review's duplicate check has to find the checkout
# before it can ask gh anything, and it used to assume the project directory was
# one. In PET it is not, the workspace root sits above pet/, so gh refused there
# and the check had never once run in that project (claude-config#344). Two
# copies of this walk, one of them in Python, would be two rules that drift with
# each suite passing its own (L263, L370), so the copy in Python is a call to
# the executed mode at the foot of this file instead.
mt_checkout_dir() {  # $1 = a directory
  local d="$1" up sub
  [ -n "$d" ] && [ -d "$d" ] || d=$PWD

  up=$d
  while [ "$up" != "/" ]; do
    [ -e "$up/.git" ] && { printf '%s' "$up"; return; }
    up=$(dirname "$up")
  done

  local found="" n=0
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    found=$sub; n=$((n + 1))
  done <<EOF
$(mt_checkout_candidates "$d")
EOF
  [ "$n" = 1 ] && { printf '%s' "$found"; return; }
  printf '%s' "$d"
}

# The child directories of $1 that are themselves checkouts, one per line, in
# glob order. Separate from the resolution above so a caller that has to REFUSE
# can name what it found: without it, an ambiguous directory reports through
# whatever generic "nothing answered" its caller falls back to, which is a
# different fault with a different remedy (L11).
mt_checkout_candidates() {  # $1 = a directory
  local d="$1" sub
  [ -n "$d" ] && [ -d "$d" ] || return 0
  for sub in "$d"/*/; do
    [ -e "${sub}.git" ] && printf '%s\n' "${sub%/}"
  done
  return 0
}

# owner/name from the git remote of the CURRENT directory.
#
# The identity comes from the remote, not from gh, because a check whose two
# sides come from one lookup can only confirm that lookup is self-consistent,
# never that it is correct (L70).
mt_remote_slug() {
  git config --get remote.origin.url 2>/dev/null \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##'
}

# An answer is usable when it is non-empty AND names the repo the remote names.
# With no parseable remote there is nothing to compare against, so the identity
# half is skipped rather than failing every repo that has no GitHub origin.
mt_usable_answer() {  # $1 = json, $2 = remote slug
  [ -n "$1" ] || return 1
  [ -n "$2" ] || return 0
  local url; url=$(printf '%s' "$1" | jq -r '.url // ""' 2>/dev/null)
  [ -n "$url" ] || return 0
  case "$url" in
    "https://github.com/$2/pull/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The pull request's fields, as JSON, or empty.
#
# The account gh has ACTIVE cannot necessarily see this repo. Dan runs concurrent
# sessions under different GitHub accounts, and a repo owned by one 404s under
# the other: gh then returns nothing, which is indistinguishable from a pull
# request that does not exist. Measured 2026-08-30 on nursedexapp/nursedex, where
# it blocked every merge.
#
# So: try the active account, then each other logged-in account, scoping the
# token PER CALL. Never `gh auth switch`, which changes the shared keyring's
# active account and would break whatever other session is using it.
#
# Answers with an ENVELOPE rather than the bare view, and with a global:
#
#   {"found":true,"view":{...}}
#   {"found":false,"wrongRepo":"https://github.com/someone/else/pull/7"}
#
# because callers read this through a command substitution, which runs it in a
# subshell, so anything it assigns to a variable is discarded on the way out. The
# first version set a global here and the caller always saw it empty: an answer
# about the WRONG repo was reported as gh having said nothing at all, which is a
# different fault with a different remedy (L11). Its own test caught that.
#
# wrongRepo lets a caller tell "gh said nothing" from "gh answered about
# something else" and refuse each in its own words.
mt_pr_view() {  # $1 = pr number or empty, $2 = --json field list, $3 = remote slug
  local pr="$1" fields="$2" slug="$3" answer candidate account token wrong=""

  if [ -n "$pr" ]; then
    answer=$(gh pr view "$pr" --json "$fields" 2>/dev/null)
  else
    answer=$(gh pr view --json "$fields" 2>/dev/null)
  fi
  if mt_usable_answer "$answer" "$slug"; then
    printf '%s' "$answer" | jq -c '{found: true, view: .}'
    return 0
  fi

  [ -n "$answer" ] && wrong=$(printf '%s' "$answer" | jq -r '.url // ""' 2>/dev/null)

  for account in $(gh auth status 2>/dev/null \
      | grep -oE 'account [A-Za-z0-9_.-]+' | awk '{print $2}' | sort -u); do
    token=$(gh auth token -u "$account" 2>/dev/null) || continue
    [ -n "$token" ] || continue
    if [ -n "$pr" ]; then
      candidate=$(GH_TOKEN="$token" gh pr view "$pr" --json "$fields" 2>/dev/null)
    else
      candidate=$(GH_TOKEN="$token" gh pr view --json "$fields" 2>/dev/null)
    fi
    if mt_usable_answer "$candidate" "$slug"; then
      printf '%s' "$candidate" | jq -c '{found: true, view: .}'
      return 0
    fi
    if [ -n "$candidate" ] && [ -z "$wrong" ]; then
      wrong=$(printf '%s' "$candidate" | jq -r '.url // ""' 2>/dev/null)
    fi
  done

  jq -nc --arg wrong "$wrong" '{found: false, wrongRepo: $wrong}'
  return 1
}

# EXECUTED mode, for a caller that cannot source bash. Guarded on this file
# being the script rather than the source, because both merge gates source it
# and a dispatch that ran on the way in would run with whatever positional
# arguments the gate was holding.
#
# It refuses a subcommand it does not know rather than falling back to a default
# answer: a run about the wrong thing is indistinguishable afterwards from a run
# about the right one (L320).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    checkout-dir) mt_checkout_dir "${2:-}" ;;
    checkout-candidates) mt_checkout_candidates "${2:-}" ;;
    *)
      echo "merge-target.sh: unknown subcommand [${1:-}] (known: checkout-dir <dir>, checkout-candidates <dir>)" >&2
      exit 2
      ;;
  esac
fi
