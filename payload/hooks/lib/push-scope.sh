#!/usr/bin/env bash
#
# push-scope.sh: shared helpers for hooks that act on a `git push`.
#
# Sourced, never executed. Holds the things every push hook has to work out for
# itself, so they exist once rather than once per hook:
#   ps_is_git_push: is this command actually a push (leading tokens, not a
#                      substring, so an `echo "git push"` cannot trigger a hook)
#   ps_repo_dir: which repository the push is about
#   ps_cd_target: the directory a `cd` in command position moves to, which the
#                      merge gates read too (lib/merge-target.sh, claude-config#463)
#   ps_commit_in_chain: does the same command commit before pushing? PreToolUse
#                      runs BEFORE the command, so a `git add … && git commit … &&
#                      git push` has nothing in history yet and the pending work
#                      must be folded in.
#   ps_add_scope / ps_pending_files: what that pending commit will take beyond
#                      the index, as a scope word or as the files themselves
#   ps_add_takes_all: does a git add in the command take more than it names
#   ps_base_ref: the ref a push is judged against
#   ps_merge_base / ps_pending_base / ps_pushed_base: where the range starts, one
#                      per situation a push hook meets (the contract is above them)
#
# Each function is defined exactly once. test-push-scope.sh fails on a second
# definition, because bash keeps the last one without a word (claude-config#440).
#
# Every function is pure: it reads its arguments and echoes or returns, touching
# no globals, so a caller can use one without inheriting the others.

# True when the command runs a git push, judged by the LEADING TOKENS of each
# shell segment. Substring matching is wrong here: a command whose payload
# merely mentions a push (an echo, a doc write, a commit message) would fire a
# hook that has nothing to act on.
# ---- reading the hook payload, once (claude-config#102) ----
# This lived in five near copies across the hooks, and they had already drifted: three flattened a
# newline into "; " and two did not, which is how claude-config#97 came to live in exactly the
# three that guard a push. A fix applied to one copy was not applied to the others, and nothing
# anywhere reported the difference.
#
# Output is always the command, then a unit separator, then the working directory, whether or not
# the caller wants the second half. One shape means every caller reads it the same way.
#
# MODE decides what happens to a newline, which is the one thing the callers genuinely differ on:
#   segmented  a newline becomes "; ", because it IS a command separator and the caller is about
#              to ask what each segment starts with. Anything that asks "is this a push" needs it.
#   raw        the command is left exactly as typed, for a caller that searches the whole text
#              rather than splitting it, and would otherwise be shown something the person did
#              not write.
ps_parse_payload() {   # $1 = payload JSON  $2 = segmented (default) | raw
  local payload="${1:-}" mode="${2:-segmented}" sep
  case "$mode" in
    segmented) sep="; " ;;
    raw)       sep="" ;;
    # An unknown mode is refused rather than guessed at: guessing here decides whether a gate can
    # see a command at all, and the safe side of that is not a default (L50).
    *)         return 2 ;;
  esac
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -j --arg sep "$sep" '
      ((.tool_input.command // "") | if $sep == "" then . else gsub("\n"; $sep) end)
      + "\u001f" + (.cwd // "")
    ' 2>/dev/null && return 0
  fi
  printf '%s' "$payload" | PS_SEP="$sep" python3 -c '
import os, sys, json
sep = os.environ.get("PS_SEP", "; ")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}
cmd = ti.get("command") or ""
if sep:
    cmd = cmd.replace("\n", sep)
sys.stdout.write(cmd + "\x1f" + (d.get("cwd") or ""))
' 2>/dev/null
}

# WHETHER the machine holds a reader at all, and the sentence a gate refuses with when it does not
# (claude-config#480, L490).
#
# A gate handed a payload nothing can read is handed an EMPTY command, and every question it then
# asks of an empty command answers that there is nothing here to refuse. So it exits 0 on exactly
# the command it exists to stop, with nothing said, which is the one failure indistinguishable from
# a clean run (L42, L98). Three did it: block-red-merge.sh parsed the payload with jq one line
# above the check that names gh, check-add-scope.sh read what a `git add` takes with python3, and
# payload-write-gate.sh read the tool name and the cwd with python3.
#
# ANY ONE of the named tools is enough, because ps_parse_payload above reads a payload with jq or
# with python3: a machine holding either can still read one, and a gate refusing on jq's absence
# alone would refuse on a machine that was never in trouble (L54).
#
# One predicate and one sentence for every gate, rather than a check and a wording per hook: the
# sentence is the same sentence, and a second copy of it is a second thing to keep true (L613).
# lib/merge-target.sh's mt_reader_missing is this predicate with python3 already filled in.
ps_reader_missing() {   # $1.. = the tools, ANY ONE of which can do the reading
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 && return 1; done
  return 0
}

# $1 = the absence, as a clause: "jq is not on PATH"
# $2 = what this gate reads with it, and what goes missing without it, ending in a full stop
# $3 = what to install
ps_reader_absent_why() {
  printf '%s, and %s An absent reader hands this gate an empty payload, and every question it asks of an empty payload answers that there is nothing to refuse, so allowing this would be the gate passing exactly what it exists to stop rather than saying it could not look (L490). Install %s and run the command again.' \
    "$1" "$2" "$3"
}

# The same absence one step further in: the payload WAS legible, and what cannot run is the gate's
# own DETECTOR (claude-config#486).
#
# Ten gates ran their detector through python3 and never asked whether it was installed. The
# detector produced nothing, every one of them tested that nothing for findings, found none, and
# exited 0. check-style-guide.sh is the plainest: its scan of the diff returned an empty string, so
# on a machine with no python3 every push read as style clean, with nothing said.
#
# A separate sentence from ps_reader_absent_why rather than a reworded copy of it, because the two
# describe different failures and a message may claim only what its check measured (L11). That one
# is about a payload nothing could read, so the gate cannot tell WHICH command it is looking at.
# This one is about a command the gate read correctly and then could not judge.
#
# $1 = the absence, as a clause: "python3 is not on PATH"
# $2 = what this gate detects with it, and what goes missing without it, ending in a full stop
# $3 = what to install
ps_detector_absent_why() {
  printf '%s, and %s A detector that cannot run finds nothing, and finding nothing is exactly what a clean run looks like, so allowing this would be the gate passing whatever it exists to catch rather than saying it could not look (L490, L98). Install %s and run the command again.' \
    "$1" "$2" "$3"
}

# True when the command stages with a `git add` and NOTHING here can read what that add takes.
#
# ps__read_adds below is python3 only, and ps_add_takes_all compares its answer against the literal
# "yes": a missing interpreter produced no answer at all, which compared as NO, so check-add-scope.sh
# allowed every unscoped add on such a machine (claude-config#480 item 2). A reading that did not
# happen is a different answer from "this add names its paths", and only the gate can say which of
# the two it is looking at, so the library reports it rather than guessing a direction (L50).
ps_add_scope_unreadable() {   # $1 = command
  ps__git_add_in_chain "$1" || return 1
  ps_reader_missing python3
}

ps_is_git_push() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    ps__segment_is_push "$seg" && return 0
  done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')
  return 1
}

ps__segment_is_push() {
  # Tokenize crudely on whitespace: quoting only matters here for arguments we
  # already skip, and a quoted subcommand is not a thing.
  local seg="$1"
  local -a tok
  read -r -a tok <<< "$seg"
  local i=0 n=${#tok[@]} t

  # A subshell or group opening the segment, `(git push)` or `( cd x && git push )`, is
  # not part of the command (claude-config#439): an opener glued to the first word is
  # peeled off it, one standing alone is skipped. Then leading environment assignments,
  # SKIP_TEST_CHECK=1 git push, which can follow an opener.
  local first=1
  while [ "$i" -lt "$n" ]; do
    t="${tok[$i]}"
    if [ "$first" -eq 1 ]; then
      while :; do
        case "$t" in
          \(*|\{*) t="${t#?}" ;;
          *) break ;;
        esac
      done
      tok[$i]="$t"
      first=0
    fi
    case "$t" in
      '') i=$((i+1)) ;;
      [A-Za-z_]*=*) i=$((i+1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1

  # The binary, with any leading path stripped. `rtk git push` is the same push:
  # the rtk-rewrite hook rewrites git commands, so a hook that only knew about
  # bare `git` would silently stop firing.
  t="${tok[$i]##*/}"
  if [ "$t" = "rtk" ]; then
    i=$((i+1))
    [ "$i" -lt "$n" ] || return 1
    t="${tok[$i]##*/}"
  fi
  [ "$t" = "git" ] || return 1
  i=$((i+1))

  # Walk to the subcommand, skipping git's own options. The two-part options
  # must consume their argument, or `git -C /some/path status` would read as a
  # command whose subcommand is a path.
  while [ "$i" -lt "$n" ]; do
    t="${tok[$i]}"
    case "$t" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
        i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      [A-Za-z_]*=*) i=$((i+1)) ;;
      # `(cd x && git push)` leaves `push)` as the last word of its segment.
      push|push\)*|push\}*) return 0 ;;
      *) return 1 ;;   # some other subcommand
    esac
  done
  return 1
}

# Which repository is this push about? The hook payload's cwd is the SESSION's
# directory, which is only the project when the session was started there. A
# session rooted elsewhere reaches a project as `cd <repo> && git push` or
# `git -C <repo> push`, and reading the cwd alone makes every one of those pushes
# invisible to the hook. Invisible is indistinguishable from nothing-to-say, so
# prefer a directory named IN the command and fall back to the cwd.
#
# Echoes the directory, or nothing when neither is a work tree.
ps_repo_dir() {
  local cmd="$1" cwd="${2:-}" cand=""

  # `git -C <path> … push`
  cand="$(printf '%s' "$cmd" | sed -nE 's@.*(^|[[:space:];&|])(rtk[[:space:]]+)?git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*@\3@p' | awk 'NR <= 1')"
  if [ -n "$cand" ] && ps__is_worktree "$cand"; then printf '%s' "$cand"; return 0; fi

  # `cd <path> && … git push`, and the same cd inside a subshell, a brace group or a command
  # substitution: `(cd <path> && git push)`. The cd used to be found by a pattern wanting
  # whitespace or a separator before it, so the subshell form fell through to the SESSION's
  # directory and a gate judged, and refused, a repository the command never touched
  # (claude-config#439, L11).
  cand="$(ps_cd_target "$cmd")"
  if [ -n "$cand" ] && ps__is_worktree "$cand"; then printf '%s' "$cand"; return 0; fi

  if [ -n "$cwd" ] && ps__is_worktree "$cwd"; then printf '%s' "$cwd"; return 0; fi
  return 1
}

ps__is_worktree() {
  [ -d "$1" ] || return 1
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# The argument of the first `cd` in COMMAND position: the start of the command, or straight after
# a separator, an opening parenthesis (a subshell or `$(`), or an opening brace. Read with a shell
# tokenizer rather than a pattern, because a pattern cannot tell `(cd x && git push)` from the same
# words inside a quoted string, and the tokenizer can: `echo "(cd x)"` is one argument to echo, not
# a cd. It also reads a quoted path with a space in it whole.
#
# Tokens are taken one at a time and the walk stops at the first one it cannot read, rather than
# tokenizing the whole command up front. A heredoc commit message with an apostrophe in its body is
# the commonest push there is, and its unbalanced quote fails a whole command read, while the cd it
# needs sits before the heredoc and has already been read by then.
ps_cd_target() {   # $1 = command; prints the path, or nothing
  PS_CMD="$1" python3 -c '
import os, shlex
lex = shlex.shlex(os.environ.get("PS_CMD", ""), posix=True, punctuation_chars=True)
lex.whitespace_split = True
OPENERS = {";", "&&", "||", "|", "&", "(", "{", "|&", ";;"}
at_start, want_arg = True, False
while True:
    try:
        tok = lex.get_token()
    except ValueError:
        break
    if tok is None or tok == lex.eof:
        break
    if want_arg:
        if tok not in OPENERS and tok not in (")", "}"):
            print(tok, end="")
        break
    if at_start and tok == "cd":
        want_arg = True
        continue
    at_start = tok in OPENERS
' 2>/dev/null
}

# The command is handed to grep as a here-string in the three questions below, never piped from
# printf (claude-config#403). A quiet grep leaves on its first match, and with the match near the
# start of a command longer than a pipe buffer (a heredoc commit message) the printf was killed
# holding the rest. Every hook sourcing this file runs under pipefail, so that death became the
# answer and a present override or commit read as absent (L183). This file never says pipefail
# itself, which is how the ratchet for exactly this shape never read it.

# Does the command carry an inline `VAR=1` override, e.g. SKIP_TEST_CHECK=1?
ps_has_override() {
  # $1 command, $2 variable name
  grep -Eq "(^|[[:space:];&|])$2=1([[:space:]]|$)" <<< "$1"
}

ps_commit_in_chain() {
  grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' <<< "$1"
}

# Does the command stage with a git add, and does its commit stage for itself with -a? Two
# questions, because ps_add_scope has to tell them apart: an add names what it stages, a
# `commit -a` stages every tracked change and names nothing. The first is a cheap filter only;
# ps__read_adds decides what an add really is.
ps__git_add_in_chain() {
  grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]|$)' <<< "$1"
}
ps__commit_stages_all() {
  grep -Eq 'git[[:space:]][^&|;]*commit[[:space:]][^&|;]*-[A-Za-z]*a' <<< "$1"
}

# What the git adds in a command stage, read before any of it runs. The one parser behind
# ps_add_scope and ps_add_takes_all (claude-config#442, #457); no hook keeps its own.
#
# Each shell segment is tokenised on its own, split where ps_is_git_push splits them. The whole
# command used to be tokenised at once, so the commonest commit there is, a heredoc message whose
# body holds an apostrophe, failed the read and every gate widened to the whole working tree. Now a
# segment that cannot be tokenised only matters when it is itself a git add, and a git add counts
# only in COMMAND position (after a subshell or brace opener and any inline variables), so an add
# named inside an echo or a message is not one.
#
# $2 is the question:
#   scope  prints ALL, TRACKED, PATHS then the paths one per line, UNKNOWN (an add was seen but
#          could not be read, or it names nothing), or NONE (no add at all)
#   takes  prints yes when any add takes more than the paths it names (ALL or TRACKED), else no
ps__read_adds() {   # $1 = command  $2 = scope | takes
  # The command goes in on stdin, never in the environment: a heredoc commit message can pass the
  # platform's limit on argument and environment size, and python then never starts at all.
  printf '%s' "$1" | PS_MODE="${2:-scope}" python3 -c '
import os, re, shlex, sys
cmd = sys.stdin.read()
mode = os.environ.get("PS_MODE", "scope")
EVERYTHING = {"-A", "--all", "--no-ignore-removal", ".", "./", ":/", "*"}
TRACKED_ONLY = {"-u", "--update"}
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
REDIRECT = re.compile(r"\d*(>>?|<<?)&?")
saw_add, takes_all, tracked, unreadable, paths = False, False, False, False, []
for seg in re.split(r"&&|\|\||;|\||\n", cmd):
    try:
        toks, readable = shlex.split(seg, posix=True), True
    except ValueError:
        toks, readable = seg.split(), False
    i = 0
    while i < len(toks):
        t = toks[i].lstrip("({")
        if t == "" or ASSIGN.match(t):
            i += 1
            continue
        toks[i] = t
        break
    if i < len(toks) and toks[i].split("/")[-1] == "rtk":
        i += 1
    if i >= len(toks) or toks[i].split("/")[-1] != "git":
        continue
    j = i + 1
    while j < len(toks) and toks[j].startswith("-"):
        j += 2 if toks[j] in ("-C", "-c") else 1
    if j >= len(toks) or toks[j] != "add":
        continue
    saw_add = True
    if not readable:
        unreadable = True
    skip = False
    for a in toks[j + 1:]:
        if skip:
            skip = False
            continue
        a = a.rstrip(")}")
        m = REDIRECT.match(a)
        if m:
            skip = m.end() == len(a)
            continue
        if a in EVERYTHING:
            takes_all = True
        elif a in TRACKED_ONLY:
            tracked = True
        elif a and not a.startswith("-") and readable:
            paths.append(a)
if mode == "takes":
    print("yes" if (takes_all or tracked) else "no")
elif not saw_add:
    print("NONE")
elif takes_all:
    print("ALL")
elif unreadable:
    print("UNKNOWN")
elif tracked:
    print("TRACKED")
elif paths:
    print("PATHS")
    for p in paths:
        print(p)
else:
    print("UNKNOWN")
' 2>/dev/null
}

# What the commit in a chained `… git commit … && git push` will take BEYOND what is already in the
# index, read from the command before any of it runs (claude-config#442). This lived as inline
# python in check-style-guide.sh (written for claude-config#350) and again in a second push hook
# that needed the same reading of pending work; two copies of one rule drift, and the drift is
# silent in the worst direction, one gate reading a push's pending work one way and its sibling
# another (L370, L613).
#
# Prints a scope word on the first line and, for PATHS, one path per line after it:
#   INDEX    no add and no -a: the commit takes the index and nothing else
#   TRACKED  `git add -u`, or a `commit -a`: every tracked change. When an add also names paths
#            beside a `commit -a`, they follow one per line, and the caller reads them too,
#            because a named path may be untracked and -a alone never takes one.
#   ALL      `git add -A`, `.`, `:/` or `*`: every change, untracked files included
#   PATHS    the paths the add names, exactly as written, for the caller to resolve
#   UNKNOWN  an add this cannot account for (it names nothing, or it cannot be tokenised)
# UNKNOWN is an answer, not a failure: the caller must widen to the whole working tree AND say so,
# because a reading quietly narrowed to nothing reports a clean push it never measured (L98).
#
# Only meaningful for a command that commits; a caller asks ps_commit_in_chain first.
ps_add_scope() {   # $1 = command
  local out=""
  # The pattern is a cheap filter only: the parser decides, so an add named inside a message
  # (`git commit -m "fix git add"`) is not taken for one.
  if ps__git_add_in_chain "$1"; then
    out="$(ps__read_adds "$1" scope)"
    # No answer at all (python missing or dead) is the same as an add nobody can account for.
    [ -n "$out" ] || out="UNKNOWN"
  fi
  case "$out" in
    ''|NONE)
      if ps__commit_stages_all "$1"; then printf 'TRACKED\n'; else printf 'INDEX\n'; fi
      return 0 ;;
    # An add naming paths beside a `commit -a`: the commit takes every tracked change too, so
    # reporting the paths alone left a tracked edit nobody named unread (claude-config#457).
    PATHS*) ps__commit_stages_all "$1" && out="TRACKED${out#PATHS}" ;;
  esac
  printf '%s\n' "$out"
}

# Does a git add in this command take more than the paths it names: `-A`, `--all`, `.`, `:/`, `*`
# or `-u` (claude-config#457 item 6)? check-add-scope.sh answered this with a detector of its own.
# It is a different question from ps_add_scope's, because a `commit -a` is not an add and an add
# that names paths is scoped whatever the commit does, so it is its own entry point over the same
# parser rather than a second parser (L342). Returns 0 for yes.
ps_add_takes_all() {   # $1 = command
  ps__git_add_in_chain "$1" || return 1
  [ "$(ps__read_adds "$1" takes)" = "yes" ]
}

# The working tree files the commit in this command takes BEYOND the index, from ps_add_scope, as
# one list (claude-config#457). Three hooks each turned the scope into files their own way, and one
# read the whole working tree for every commit then push, which is how another session's untracked
# files came to be judged as this push's work (claude-config#350).
#
# Run inside the repository. The first line is a verdict:
#   EXACT    the list is what the commit will take
#   WIDENED  the add could not be accounted for (UNKNOWN, or a named path that is not there), so
#            the whole working tree was listed instead. The caller must say so (L98, L11).
# Then one path per line, relative to the repository root wherever the command runs: tracked files
# changed against the index (a deletion included, so a caller checks the file exists) and untracked
# files. Nothing for a command with no commit's worth of extra work (INDEX).
ps_pending_files() {   # $1 = command
  local scope kind pth verdict=EXACT
  scope="$(ps_add_scope "$1")"
  kind="${scope%%$'\n'*}"
  case "$kind" in
    UNKNOWN) verdict=WIDENED ;;
    PATHS)
      while IFS= read -r pth; do
        [ -n "$pth" ] || continue
        [ -e "$pth" ] || { verdict=WIDENED; break; }
      done < <(printf '%s\n' "$scope" | tail -n +2) ;;
  esac
  printf '%s\n' "$verdict"
  {
    if [ "$verdict" = WIDENED ] || [ "$kind" = ALL ]; then
      git diff --name-only 2>/dev/null
      git ls-files --others --exclude-standard --full-name -- ':/' 2>/dev/null
    else
      case "$kind" in
        TRACKED)
          git diff --name-only 2>/dev/null
          while IFS= read -r pth; do
            [ -n "$pth" ] || continue
            git ls-files --others --exclude-standard --full-name -- "$pth" 2>/dev/null
          done < <(printf '%s\n' "$scope" | tail -n +2) ;;
        PATHS)
          while IFS= read -r pth; do
            [ -n "$pth" ] || continue
            git diff --name-only -- "$pth" 2>/dev/null
            git ls-files --others --exclude-standard --full-name -- "$pth" 2>/dev/null
          done < <(printf '%s\n' "$scope" | tail -n +2) ;;
      esac
    fi
  } | awk 'NF && !seen[$0]++'
}

# ---- where a push's range starts: the contract (claude-config#441) ----
# A push hook meets three situations, and each needs a different answer when the merge base with the
# base ref comes back as HEAD itself. One helper with one fallback served the first and was wrong
# for the other two, so each has its own entry point, and a caller picks the one for its situation:
#
#   ps_merge_base   A PLAIN push, read before it runs (PreToolUse). A merge base at HEAD means the
#                   base fell through to a local branch that IS the current one (no upstream), so
#                   the most recent change is read instead of an empty range. What it gets wrong:
#                   on a branch whose real upstream is already HEAD, a push that carries nothing
#                   re-reads the last commit, which is already on the remote.
#   ps_pending_base A command that COMMITS before it pushes, read before it runs. The pending commit
#                   is not in history yet and is the change, so when the base is a REMOTE ref and
#                   the merge base is HEAD, the range starts at HEAD and the caller adds the pending
#                   work. HEAD~1 there blamed the push for the last commit already on the remote,
#                   and in a one commit repository did not exist, so the gate skipped. Against a
#                   LOCAL base a merge base at HEAD says nothing about what the remote holds, so it
#                   gives the plain push answer and reads one commit more, the safe side for a gate.
#   ps_pushed_base  AFTER the push (PostToolUse). The upstream now IS HEAD, so the merge base is HEAD
#                   and the plain push answer read one commit however many the push carried. It
#                   takes the upstream's previous tip from its reflog when that is an ancestor of
#                   HEAD (exactly what this push added), then the fork point from the remote's
#                   default branch (a first push of a branch), and only then the plain push answer.
#
# ps_merge_base and ps_pending_base both read the merge base through ps__base_merge_base, so a branch
# rebased onto a newer main and force pushed is judged from where it now leaves main, never from its
# pre rebase upstream tip (claude-config#456). ps_pushed_base already reaches the same answer: after
# a force push the reflog's previous tip is not an ancestor, so it falls to the default branch.
#
# Each prints a commit and returns 0, or prints nothing and returns 1 when there is no range at all
# (no commits, or nothing earlier than HEAD to start from). A caller getting nothing decides for
# itself what that means, and must say so rather than read it as a clean result (L98).

# The merge base of the base ref with HEAD, corrected for a REWRITTEN branch (claude-config#456).
# After a rebase onto a newer main, the upstream still names the pre rebase tip, which is no longer
# an ancestor of HEAD, and its merge base is the OLD fork point: every commit main gained since was
# judged as part of the push. So when the base is not an ancestor of HEAD, the merge base with the
# remote's default branch is taken too, and the NEWER of the two wins. The newer one, rather than
# always the default branch's: a branch that diverged because somebody else pushed to it was not
# rebased, and its upstream merge base is still the closer, correct start. Prints nothing when
# there is no base or no merge base; what a merge base at HEAD means is left to each entry point.
ps__base_merge_base() {   # $1 = the base ref
  local base="${1:-}" mb="" def cand
  [ -n "$base" ] || return 0
  git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || return 0
  mb="$(git merge-base "$base" HEAD 2>/dev/null)"
  if [ -n "$mb" ] && ! git merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    def="$(ps__default_ref)"
    if [ -n "$def" ]; then
      cand="$(git merge-base "$def" HEAD 2>/dev/null)"
      if [ -n "$cand" ] && [ "$cand" != "$mb" ] && git merge-base --is-ancestor "$mb" "$cand" 2>/dev/null; then
        mb="$cand"
      fi
    fi
  fi
  printf '%s' "$mb"
}

# The remote's default branch as a remote tracking ref: what origin/HEAD names, then the usual
# names. Remote refs only, never a local branch, because the question is where the branch leaves
# what the remote holds.
ps__default_ref() {
  local def c
  def="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/##')"
  if [ -n "$def" ]; then printf '%s' "$def"; return 0; fi
  for c in origin/main origin/master; do
    if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

ps_merge_base() {   # $1 = the base ref, usually from ps_base_ref
  local base="${1:-}" mb=""
  mb="$(ps__base_merge_base "$base")"
  if [ -z "$mb" ] || [ "$mb" = "$(git rev-parse HEAD 2>/dev/null)" ]; then
    mb="$(git rev-parse --verify --quiet HEAD~1 2>/dev/null)"
  fi
  [ -n "$mb" ] || return 1
  printf '%s' "$mb"
}

ps_pending_base() {   # $1 = the base ref, usually from ps_base_ref
  local base="${1:-}" head mb full
  head="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || return 1
  [ -n "$head" ] || return 1
  if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    mb="$(ps__base_merge_base "$base")"
    full="$(git rev-parse --symbolic-full-name "$base" 2>/dev/null)"
    case "$full" in
      refs/remotes/*)
        if [ "$mb" = "$head" ]; then printf '%s' "$head"; return 0; fi ;;
    esac
  fi
  ps_merge_base "$base"
}

ps_pushed_base() {
  local head prev def cand
  head="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || return 1
  [ -n "$head" ] || return 1
  prev="$(git rev-parse --verify --quiet '@{u}@{1}' 2>/dev/null)"
  if [ -n "$prev" ] && [ "$prev" != "$head" ] && git merge-base --is-ancestor "$prev" HEAD 2>/dev/null; then
    printf '%s' "$prev"; return 0
  fi
  def="$(ps__default_ref)"
  if [ -n "$def" ]; then
    cand="$(git merge-base "$def" HEAD 2>/dev/null)"
    if [ -n "$cand" ] && [ "$cand" != "$head" ]; then printf '%s' "$cand"; return 0; fi
  fi
  ps_merge_base "$(ps_base_ref)"
}

# The ref a push should be judged AGAINST (claude-config#339). The upstream if there is one, then
# the remote's own default branch, then the usual names, then nothing. Written once here because
# three push hooks each need the same answer and three copies of it would drift, and this is the
# half whose drift is invisible: a wrong base scopes a gate to the wrong diff while still reporting
# a clean run (L70, L613).
#
# Prints the ref and returns 0, or prints nothing and returns 1. A caller that gets nothing must
# decide for itself what to do; there is no fallback here, because "judge against HEAD~1" and
# "judge nothing" are different decisions and the gates do not make them the same way.
ps_base_ref() {
  local up base c
  up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  if [ -n "$up" ]; then printf '%s' "$up"; return 0; fi
  base="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/##')"
  if [ -n "$base" ]; then printf '%s' "$base"; return 0; fi
  for c in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}
