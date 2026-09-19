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
#   mt_runs_merge    does it cause one by any route, a repo's own tool included
#   MT_MERGE_TOOLS   the one declaration of those tools, and the helpers
#                      mt_pinned_tool / mt_pinned_how that read it
#   mt_repo_flag     the repository the merge names with --repo, -R or a pull
#                      request link, which gh takes before anything about the
#                      directory
#   mt_searched_repo / mt_searched_why / mt_pr_label
#                    what a gate says about where it looked and what it looked
#                      for, in one vocabulary rather than one per gate
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
#   mt_remote_path   whether a repository on GitHub holds a path, for a merge
#                      naming a repository that is not the checkout it runs in
#   mt_pinned_tool_remote
#                    the same question as mt_pinned_tool, asked of GitHub
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

# The reading of a `cd` in a command lives in lib/push-scope.sh (ps_cd_target), written for the
# push gates and already right about subshells, quoted strings and a cd that does not lead the
# command. This file had a second reader of its own that saw only a LEADING cd, so a merge written
# after an assignment was judged in the session's folder (claude-config#463). One reader, not two
# (L613, L370).
# shellcheck source=push-scope.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/push-scope.sh"

# THE ONE DECLARATION of a repo's own merge tool. Every question anybody asks about
# these tools is answered from here.
#
# There used to be two lists. This library decided which COMMANDS count as a merge, and
# block-red-merge.sh decided which REPOS must merge through their own tool, each naming
# the same tools separately and overlapping without being identical. That is how
# claude-config#351 happened: wait_for_checks.py sat in the second list and not the
# first, so the changelog gate enforced nothing in PET, the repo it was built for. A list
# that must mirror another is derived from it, never maintained beside it (L41).
#
# Four fields, pipe separated:
#
#   1  the repo relative PATH whose presence marks a repo as carrying this tool, and
#        whose basename is what the command matcher looks for
#   2  how to INVOKE it, with %s where the pull request number goes, because the refusal
#        quotes this at somebody and a remedy nobody can run is a refusal nothing can
#        clear (L109, L406)
#   3  `pinned` when block-red-merge.sh must INSIST on it, `route` when it merges but
#        makes no commit pin promise. merge-when-green.sh is the second kind: the quiz
#        has to fire on it, and refusing a plain merge in its favour would be demanding
#        a guarantee it does not give. Keeping both facts in one row is the whole point.
#   4  a FLAG the command must carry to count as a merge, or empty for a tool that
#        merges whenever it runs. wait_for_checks.py without --merge only WAITS for the
#        checks, so matching it bare would fire on every look at a pull request.
#
# ORDER IS LOAD BEARING: mt_pinned_tool takes the first pinned tool present, which
# preserves the branch this replaced, where the python tool won over the shell one.
MT_MERGE_TOOLS=(
  "tools/wait_for_checks.py|venv/bin/python tools/wait_for_checks.py %s --merge|pinned|--merge"
  ".github/scripts/merge-pr.sh|npm run merge -- %s|pinned|"
  "scripts/merge-when-green.sh|./scripts/merge-when-green.sh %s|route|"
)

# An interpreter is matched by BASENAME, so a tool run out of a virtualenv
# (venv/bin/python, .venv/bin/python) is the same route as one run by python3.
MT_INTERPRETERS="bash sh zsh python python3"

mt_declared_tool_paths() {
  local row
  for row in "${MT_MERGE_TOOLS[@]}"; do printf '%s\n' "${row%%|*}"; done
}

# The invocation for one declared path, with the number filled in. `<pr>` rather than an
# empty slot when the number is not known, so the sentence still reads as a command.
mt_pinned_how_for() {  # $1 = a declared path, $2 = pr number or empty
  local row rest how pr="${2:-<pr>}"
  [ -n "$pr" ] || pr="<pr>"
  for row in "${MT_MERGE_TOOLS[@]}"; do
    [ "${row%%|*}" = "$1" ] || continue
    rest="${row#*|}"
    how="${rest%%|*}"
    # shellcheck disable=SC2059
    printf "$how" "$pr"
    return 0
  done
  return 1
}

# The commit pinned tool this directory carries, if any, as its repo relative path.
# Only a `pinned` row counts: a route that merges without pinning is not something to
# refuse a plain merge in favour of.
mt_pinned_tool() {  # $1 = a directory
  local row path kind rest d="${1:-$PWD}"
  for row in "${MT_MERGE_TOOLS[@]}"; do
    path="${row%%|*}"
    rest="${row#*|}"; rest="${rest#*|}"
    kind="${rest%%|*}"
    [ "$kind" = "pinned" ] || continue
    if [ -f "$d/$path" ]; then printf '%s' "$path"; return 0; fi
  done
  return 1
}

mt_pinned_how() {  # $1 = a directory, $2 = pr number or empty
  local path
  path="$(mt_pinned_tool "$1")" || return 1
  mt_pinned_how_for "$path" "${2:-}"
}

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
#
# Reads MT_MERGE_TOOLS, so a tool added to the declaration is recognised here with
# nothing to remember. The whole segment is passed rather than its leading tokens,
# because a tool's required flag sits after its arguments.
mt_segment_runs_wrapper() {  # $1 = a cleaned segment
  local seg="$1" first second third rest target row path flag
  # Four variables for three tokens, deliberately: `read` gives the LAST variable
  # everything that is left, so reading three would make `third` the whole remainder
  # and `npm run merge -- 680` would never match `merge` exactly.
  read -r first second third rest <<MTEOF
$seg
MTEOF
  [ -n "$first" ] || return 1

  # The tool is either the command itself, or the argument to an interpreter.
  target="$first"
  case " $MT_INTERPRETERS " in
    *" ${first##*/} "*) target="$second" ;;
  esac
  [ -n "$target" ] || return 1

  for row in "${MT_MERGE_TOOLS[@]}"; do
    path="${row%%|*}"
    [ "${target##*/}" = "${path##*/}" ] || continue
    flag="${row##*|}"
    [ -n "$flag" ] || return 0
    case " $seg " in
      *" $flag "*|*" $flag") return 0 ;;
    esac
  done

  # `npm run merge`, exactly. This one route cannot be matched from the declaration:
  # what follows `npm run` is a script NAME rather than a path, so no basename of any
  # declared file appears in the command at all. It reaches .github/scripts/merge-pr.sh,
  # which is why that row's invocation is written as the npm form. `merge-ready` only
  # reports, so the match has to be exact rather than a prefix.
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
#
# The heads are CAPTURED and then searched, never piped into the search. A quiet
# grep leaves on its first match, so a merge with commands after it killed the
# writer still holding their heads, and under the pipefail both gates run with
# that death made the answer "not a merge": `<merge> && echo merged` walked past
# both gates on most runs (found testing #382, L183).
mt_is_pr_merge() {  # $1 = command
  case "$1" in *merge*) ;; *) return 1 ;; esac
  local heads
  heads="$(mt_command_heads "$1")"
  grep -Eq '(^|/)gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' <<MTEOF
$heads
MTEOF
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
  direct="$(mt__merge_selector "$1")"
  direct="${direct#*$'\t'}"
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
# Order: a `cd` in command position wins, because that is where the merge itself
# will run: at the head, after an assignment, or inside a subshell, as
# ps_cd_target reads it. This used to honour only a LEADING cd, so
# `H=$(...) ; cd <repo> && <merge>` was judged in the session's folder
# (claude-config#463). A relative cd is relative to the session cwd, where the
# command runs, not to wherever the hook process stands. A cd to a directory that
# does not exist is ignored. Otherwise the session cwd, then walk up for a repo,
# then look one level down.
#
# This answers WHERE the merge runs. WHICH repository it is about can still be
# named with --repo, which gh honours first: that is mt_repo_flag's question.
mt_repo_dir() {  # $1 = command, $2 = session cwd
  local command="$1" d="$2" from_cd=""
  [ -n "$d" ] && [ -d "$d" ] || d=$PWD

  from_cd="$(ps_cd_target "$command")"
  case "$from_cd" in
    "~") from_cd="$HOME" ;;
    "~/"*) from_cd="$HOME/${from_cd#"~/"}" ;;
    ""|/*) ;;
    *) from_cd="$d/$from_cd" ;;
  esac
  if [ -n "$from_cd" ] && [ -d "$from_cd" ]; then printf '%s' "$from_cd"; return; fi

  mt_checkout_dir "$d"
}

# WHICH pull request, and in WHICH repository, the gh merge invocation itself names. One
# reading, because gh takes both from that one command and a gate that reads either without
# the other asks one repository about another repository's pull request (claude-config#470).
#
# Prints "<repository>\t<number>", either side empty when the command does not name it.
#
# gh takes the repository from --repo or -R before anything about the directory it runs in,
# so a gate asking gh about the directory is asking about a different repository whenever the
# two differ. Measured 2026-09-19 merging danwright32/backstage#26 from an Ovation session:
# refused as "gh returned nothing", because Ovation has no pull request 26.
#
# A pull request given as a LINK names both, and the link wins over a --repo beside it, which
# is what gh does with the two together: measured 2026-09-19, gh pr view with the cli/cli
# link and --repo danwright32/claude-config answered about cli/cli.
#
# Only the merge's own arguments count: a `gh pr view --repo x` earlier in the same command is
# about that view. Read with a shell tokenizer, in command position only, so a merge quoted
# inside an echo names nothing, and the walk stops at the first token it cannot read, as
# ps_cd_target's does. Heredoc bodies are removed first, so prose about merging names nothing
# and a real merge written after a heredoc is still read (L673).
#
# The spellings gh accepts for one repository (owner/name, github.com/owner/name, a URL, a
# trailing .git) come back as one. A host other than github.com is kept whole, so it can never
# compare equal to a github.com remote and is refused downstream rather than read as one.
mt__merge_selector() {  # $1 = command
  MT_CMD="$(mt_strip_heredocs "$1")" python3 -c '
import os, re, shlex
cmd = os.environ.get("MT_CMD", "")
# A newline starts a new command the way a semicolon does, and a backslash before one does not.
# shlex reads both as ordinary whitespace, so they are rewritten before it sees them.
cmd = cmd.replace("\\\n", " ").replace("\n", " ; ")
lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
lex.whitespace_split = True
OPENERS = {";", "&&", "||", "|", "&", "(", "{", "|&", ";;"}
ENDERS = OPENERS | {")", "}"}
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# The flags gh pr merge takes a VALUE for. A value is neither a flag nor the pull request, so
# without this list a commit sha or a message would be read as the thing being merged.
VALUED = {"--repo", "-R", "--body", "-b", "--body-file", "-F", "--subject", "-t",
          "--match-head-commit", "--author-email", "-A"}
LINK = re.compile(r"^(?:[a-z]+://)?([^/\s]+[.][^/\s]+)/([^/\s]+)/([^/\s]+)/pull/([0-9]+)(?:[/?#].*)?$")
def norm(v):
    v = re.sub(r"^[a-z]+://", "", v.strip())
    v = re.sub(r"[.]git$", "", v.rstrip("/"))
    if v.lower().startswith("github.com/"):
        v = v[len("github.com/"):]
    return v
toks = []
while True:
    try:
        t = lex.get_token()
    except ValueError:
        break
    if t is None or t == lex.eof:
        break
    toks.append(t)
repo, link_repo, number = "", "", ""
at_start, i, n = True, 0, len(toks)
while i < n:
    t = toks[i]
    if at_start and ASSIGN.match(t):
        i += 1
        continue
    if at_start and t.split("/")[-1] == "gh" and toks[i + 1:i + 3] == ["pr", "merge"]:
        j = i + 3
        while j < n and toks[j] not in ENDERS:
            a = toks[j]
            if a in ("--repo", "-R") and j + 1 < n and toks[j + 1] not in ENDERS:
                repo = repo or norm(toks[j + 1])
                j += 2
                continue
            if a.startswith("--repo="):
                repo = repo or norm(a[len("--repo="):])
            elif a.startswith("-R") and len(a) > 2:
                repo = repo or norm(a[2:])
            elif a in VALUED:
                j += 2
                continue
            elif a.startswith("-"):
                pass
            else:
                m = LINK.match(a)
                if m and not link_repo:
                    host, owner, name = m.group(1), m.group(2), re.sub(r"[.]git$", "", m.group(3))
                    link_repo = owner + "/" + name
                    if host.lower() != "github.com":
                        link_repo = host + "/" + link_repo
                    number = number or m.group(4)
                elif a.isdigit() and not number:
                    number = a
            j += 1
        break
    at_start = t in OPENERS
    i += 1
print((link_repo or repo) + "\t" + number, end="")
' 2>/dev/null
}

# The repository the merge NAMES, as owner/name; empty when it names none (claude-config#463,
# #470). The flag or the link, read by mt__merge_selector above, which holds the reasoning.
mt_repo_flag() {  # $1 = command ; prints owner/name, or nothing
  local sel
  sel="$(mt__merge_selector "$1")"
  printf '%s' "${sel%%$'\t'*}"
}

# WHERE a gate looked for the pull request, and WHY it looked there, as one vocabulary for
# every gate that has to report finding nothing (L11, L605). Written inline in
# block-red-merge.sh first; a second gate needing the same sentence is a second copy that
# drifts, with each suite passing its own (L613, L370).
mt_searched_repo() {  # $1 = the repository the command names, $2 = the directory's slug, $3 = the directory
  if [ -n "$1" ]; then printf '%s' "$1"
  elif [ -n "$2" ]; then printf '%s' "$2"
  else printf 'the repository gh resolves from %s' "$3"
  fi
}

mt_searched_why() {  # the same arguments
  if [ -n "$1" ]; then printf 'the command names it'
  elif [ -n "$2" ]; then printf 'that is the repository of %s, where this merge runs' "$3"
  else printf 'that is where this merge runs'
  fi
}

# What to call the pull request in a message: no number named means gh resolves it from the
# current branch, which is a different thing to say than a number nobody could find.
mt_pr_label() {  # $1 = pr number or empty
  if [ -n "$1" ]; then printf 'pull request #%s' "$1"
  else printf 'pull request for the current branch'
  fi
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
  # GitHub names are case insensitive, and a slug typed with --repo keeps whatever case it was
  # typed in while gh answers with the canonical one, so both sides are compared in lower case.
  url=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
  case "$url" in
    "https://github.com/$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')/pull/"*) return 0 ;;
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
#
# And "gh said nothing" is itself two causes (claude-config#463). notFound is true
# when every attempt was answered with gh's own not found (no such pull request,
# no such repository, a 404): the pull request is not there to judge. Anything
# else, a network or auth failure, leaves notFound false and puts gh's first
# line in `error`, because that is "could not confirm", a different fault with a
# different remedy (L11). A found answer carries `account`, empty for the active
# one, so a caller that must ask GitHub more about the same repository asks as
# the account that could see it.
#
# $4 is the repository the merge names with --repo, passed to gh the same way,
# so the question is about the repository the merge is about.
mt_pr_view() {  # $1 = pr number or empty, $2 = --json field list, $3 = remote slug, $4 = --repo value or empty
  local pr="$1" fields="$2" slug="$3" repo="${4:-}" answer account token wrong="" errf err
  local notfound=0 other=""
  local -a args=(pr view)
  [ -n "$pr" ] && args+=("$pr")
  [ -n "$repo" ] && args+=(--repo "$repo")
  args+=(--json "$fields")
  errf=$(mktemp "${TMPDIR:-/tmp}/mt-pr-view.XXXXXX" 2>/dev/null) || errf=""

  # The empty first entry is the ACTIVE account, asked with no token of our own.
  for account in "" $(gh auth status 2>/dev/null \
      | grep -oE 'account [A-Za-z0-9_.-]+' | awk '{print $2}' | sort -u); do
    if [ -z "$account" ]; then
      answer=$(gh "${args[@]}" 2>"${errf:-/dev/null}")
    else
      token=$(gh auth token -u "$account" 2>/dev/null) || continue
      [ -n "$token" ] || continue
      answer=$(GH_TOKEN="$token" gh "${args[@]}" 2>"${errf:-/dev/null}")
    fi
    if mt_usable_answer "$answer" "$slug"; then
      [ -n "$errf" ] && rm -f "$errf"
      printf '%s' "$answer" | jq -c --arg account "$account" '{found: true, view: ., account: $account}'
      return 0
    fi
    if [ -n "$answer" ]; then
      [ -z "$wrong" ] && wrong=$(printf '%s' "$answer" | jq -r '.url // ""' 2>/dev/null)
      continue
    fi
    err=""
    [ -n "$errf" ] && err=$(awk 'NF { print; exit }' "$errf")
    case "$err" in
      *"Could not resolve to a PullRequest"*|*"Could not resolve to a Repository"*|*"no pull requests found"*|*"HTTP 404"*)
        notfound=1 ;;
      *) [ -z "$other" ] && other="${err:-gh printed nothing}" ;;
    esac
  done
  [ -n "$errf" ] && rm -f "$errf"

  local nf=false
  [ "$notfound" = 1 ] && [ -z "$other" ] && [ -z "$wrong" ] && nf=true
  jq -nc --arg wrong "$wrong" --argjson nf "$nf" --arg error "$other" \
    '{found: false, wrongRepo: $wrong, notFound: $nf, error: $error}'
  return 1
}

# Does a repository on GitHub hold this path? Prints present, absent or unknown.
#
# For a merge that names, with --repo, a repository other than the checkout it
# runs in: the folder's own files say nothing about that repository, so what the
# gate would read from disk (a merge tool, a workflow) has to be read from GitHub
# instead (claude-config#463). Asked as the account that could see the pull
# request. Only gh's own 404 is absent; any other failure is unknown, and a
# caller must refuse on unknown rather than read it as absent (L42).
mt_remote_path() {  # $1 = owner/name, $2 = a repo relative path, $3 = account or empty for the active one
  local slug="$1" path="$2" account="${3:-}" token="" errf err rc
  errf=$(mktemp "${TMPDIR:-/tmp}/mt-remote-path.XXXXXX" 2>/dev/null) || { printf 'unknown'; return 0; }
  if [ -n "$account" ]; then
    token=$(gh auth token -u "$account" 2>/dev/null) || token=""
    if [ -z "$token" ]; then rm -f "$errf"; printf 'unknown'; return 0; fi
    GH_TOKEN="$token" gh api "repos/$slug/contents/$path" >/dev/null 2>"$errf"; rc=$?
  else
    gh api "repos/$slug/contents/$path" >/dev/null 2>"$errf"; rc=$?
  fi
  err=$(cat "$errf"); rm -f "$errf"
  if [ "$rc" = 0 ]; then printf 'present'; return 0; fi
  case "$err" in
    *"HTTP 404"*) printf 'absent' ;;
    *) printf 'unknown' ;;
  esac
}

# mt_pinned_tool, asked of a repository on GitHub rather than a directory on disk.
# Prints the tool's path and returns 0 when the repository carries one, returns 1
# when it carries none, and prints the path it could not read and returns 2 when
# it cannot tell. Reads MT_MERGE_TOOLS, so there is still one declaration (L41).
mt_pinned_tool_remote() {  # $1 = owner/name, $2 = account or empty
  local row path kind rest state
  for row in "${MT_MERGE_TOOLS[@]}"; do
    path="${row%%|*}"
    rest="${row#*|}"; rest="${rest#*|}"
    kind="${rest%%|*}"
    [ "$kind" = "pinned" ] || continue
    state="$(mt_remote_path "$1" "$path" "${2:-}")"
    case "$state" in
      present) printf '%s' "$path"; return 0 ;;
      absent) ;;
      *) printf '%s' "$path"; return 2 ;;
    esac
  done
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
