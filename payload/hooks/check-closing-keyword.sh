#!/usr/bin/env bash
#
# check-closing-keyword.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: block a `gh pr create` / `gh pr edit` / `git commit` whose text contains a NEGATED
# closing keyword next to an issue reference ("this does not close #897"), because GitHub
# closes the issue anyway. Since claude-config#1550 also a conditional, "which" or partial one
# ("would also have closed #2584"), and a close of an issue the same text calls "Part of" or says
# stays open, all read by lib/closing-keyword.py. Since claude-config#2464 also a closing word before
# an open pull request anywhere, or before an open issue in the middle of a sentence ("the p0 fix
# #2451" closed pull request #2451 unmerged), each number looked up with gh, and a lookup that fails
# refuses. check-closing-merge.sh asks the same detector
# about the body GitHub holds when the pull request merges, which catches a body this hook never
# saw (--body-file, the web, a later edit).
#
# Built 2026-07-13 after exactly that happened on Overture #912: a PR body that said, in as
# many words, "It does not close #897" closed #897 on merge and it had to be reopened by
# hand. GitHub's linked-issue parser matches the keyword plus the reference and does no
# negation handling at all. The "not" is invisible to it.
#
# The cruel part, and the reason a hook is worth it: the sentence is one a CAREFUL author
# wants to write. A PR that deliberately fixes only part of an issue should say so. The
# clearer you are about not finishing the issue, the likelier you are to trip this. It is
# silent, and only detectable after the merge.
#
# Safe phrasings the hook points you at: "part of #897", or "#897 stays open", "Supersedes #N" for a
# pull request, and a line of its own starting "Closes #N" for an issue the change does finish.
#
# Override: SKIP_CLOSING_CHECK=1 gh pr create ...   (a doc that has to quote the broken
# phrasing itself, e.g. this hook's own tests). Explain why to the user first, never skip
# silently, same rule as the test gate and the style gate.
#
# Fails CLOSED on a parse error for a command whose raw text names a pull request or a commit (it
# failed open until claude-config#1922), and open for any other. Fails CLOSED too when
# the detector itself cannot run: python3 or lib/closing-keyword.py missing, or the detector
# exiting with an error, refuses a command that could link an issue, because a detector that
# did not run finds nothing (L98).

payload="$(cat)"


# The library, not a copy: six near copies of this had already drifted (claude-config#102).
# `raw` because this hook searches the whole command rather than splitting it.
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/push-scope.sh
{ . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && declare -F ps_parse_payload >/dev/null; } || {
  # A library this gate cannot load is not a message with nothing to check (claude-config#1900,
  # L10): with it missing nothing here can tell a pull request or a commit from any other command,
  # so a command naming one is refused, naming the file, and any other passes as it would have.
  case "$payload" in *SKIP_CLOSING_CHECK=1*) exit 0 ;; esac
  # The group word pr alone, not only the word create: `gh pr new` is gh pr create, and no list of
  # gh's aliases is kept here (claude-config#2424). Too broad, never too narrow.
  case "$payload" in *"pr create"*|*"pr edit"*|*"pr "*|*"git commit"*) ;; *) exit 0 ;; esac
  echo "BLOCKED: check-closing-keyword.sh could not load $HOOK_DIR/lib/push-scope.sh, which reads whether this command writes a pull request body or a commit message, so this command could not be checked. A library this gate cannot load is not a message with nothing to check. Reinstall the hooks with claude-sync pull. For this one command: SKIP_CLOSING_CHECK=1 <the same command>" >&2
  exit 2
}

# THE DETECTOR'S OWN READER, asked before anything is measured (claude-config#486, L490).
#
# The detector, lib/closing-keyword.py (inline here until claude-config#1550), is python3, and
# nothing here asked whether python3 was installed.
# Without it the findings came back empty, the emptiness test passed, and this gate exited 0 on
# exactly the phrasing it exists to stop, with nothing said. A detector that cannot run finds
# nothing, and finding nothing is exactly what a clean run looks like (L42, L98).
#
# Asked above the payload read, because python3 is also one of the two tools ps_parse_payload
# reads with: with neither jq nor python3 the parse below exits 0 first and this question would
# never be reached (L135, L667).
#
# Narrowed, on the raw payload, to git commit and any command naming `pr ` (which covers pr create
# and pr edit, the two that can link an issue, and also catches harmless ones such as gh pr view),
# so the refusal stays near the commands this hook is about (L36, L54). A substring rather than
# the leading token test used below, because with no reader there are no tokens: it can only ever
# be too broad here, never too narrow. The override is read the same way (L109).
if ps_reader_missing python3; then
  case "$payload" in
    *SKIP_CLOSING_CHECK=1*) exit 0 ;;
    *"pr create"*|*"pr edit"*|*"pr "*|*"git commit"*)
      echo "BLOCKED: $(ps_detector_absent_why "python3 is not on PATH" \
        "check-closing-keyword.sh reads this text with it (lib/closing-keyword.py), looking for a closing keyword beside an issue the text says it is not closing, so with python3 absent nothing here reads the text at all." \
        "python3")" >&2
      echo "A sentence like \"does not close #897\" closes the issue on merge regardless of the negation, which is why this is a gate rather than a note." >&2
      echo "OVERRIDE, this one command: SKIP_CLOSING_CHECK=1 <your original command>" >&2
      exit 2 ;;
  esac
  exit 0
fi

# Taken raw above, before the library that cleans it loaded, and cleaned here before anything parses
# it: a lone surrogate escape made jq read nothing (claude-config#1944). A payload still unreadable
# is judged by its words, as a missing library is above (#1922).
payload="$(ps_clean_payload "$payload")"
parsed="$(ps_parse_payload "$payload" raw)" \
  || ps_unparsed_refuse "$payload" check-closing-keyword.sh SKIP_CLOSING_CHECK "a pull request body or a commit message" '*pr create*' '*pr edit*' '*pr *' '*git commit*'
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

# The repository a gh command names with -R or --repo, from the words gh itself reads as the
# subcommand's (PS_RUN_ARGS, set by ps_runs_gh), never the string: a body quoting "--repo x/y" names
# nothing. HOST/OWNER/REPO keeps its last two parts.
cc_repo_flag() {
  local w next=0 v=""
  for w in ${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"}; do
    if [ "$next" = 1 ]; then v="$w"; break; fi
    case "$w" in
      -R|--repo) next=1 ;;
      --repo=*) v="${w#--repo=}"; break ;;
      -R?*) v="${w#-R}"; break ;;
    esac
  done
  case "$v" in */*/*) v="${v#*/}" ;; esac
  printf '%s' "$v"
}
gh_repo=""

# Only the commands that can actually link an issue: a PR body/title, or a commit message.
#
# Asked of each command the shell would RUN, never of the string. That is the whole difference
# between a command and a command PAYLOAD, and getting it wrong was not theoretical: the first draft
# of this hook blocked its own issue-closing comment, because that comment QUOTED a PR-creation
# command as the example of what it catches. An issue comment cannot close anything, and neither can
# a comment that merely talks about a PR.
#
# Read by lib/push-scope.sh, the one reading of a command every gate shares: ps_runs_gh finds the gh
# subcommand as gh itself does, so `gh -R o/x pr create` and `gh pr -R o/x edit 3` are the creation
# and the edit they are (claude-config#1188; this hook read the first three words before, and a flag
# in front walked a negated keyword past it), and ps_is_git_commit, the push gates' own question,
# sees `git -C <dir> commit`, which the first three words did not. With nothing able to read the
# command (no lib/shell-words.py), the crude cut and ps_runs_gh's crude reading, which can only see
# more creations than are there.
is_target=0
# Read once, in this shell, so every question below is answered from the one reading.
ps__read "$cmd" || :
if ps_is_git_commit "$cmd"; then
  is_target=1
else
  segs="$(ps__shell_segments "$cmd")"
  [ "$?" -eq 1 ] && segs="$(ps__crude_cut "$cmd" | tr '\n' '\036')"
  while IFS= read -r -d $'\x1e' seg; do
    if ps_runs_gh "$seg" pr create || ps_runs_gh "$seg" pr edit; then
      is_target=1
      gh_repo="$(cc_repo_flag)"
      break
    fi
  done <<LOOP_INPUT
$segs
LOOP_INPUT
fi
[ "$is_target" -eq 1 ] || exit 0

if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])SKIP_CLOSING_CHECK=1([[:space:]]|$)'; then
  exit 0
fi

# The rule is lib/closing-keyword.py's, the one reading of a closing keyword against its sentence,
# which check-closing-merge.sh asks too about the body GitHub holds at merge (claude-config#1550), so
# a sentence is judged the same where it is written and where it takes effect (L263, L370). It lived
# inline here until then. `text` mode counts every issue a keyword is followed by as closing, and
# finds the keyword in a negated, conditional, "which" or partial sentence, or an issue the same text
# also calls "Part of" or says stays open.
#
# A detector file that is not there finds nothing, and nothing is what a clean message looks like, so
# its absence is refused as python3's is above (L98), and so is a detector that ran and failed: a
# crash prints no finding either. CLOSING_KEYWORD_LIB points it at another file, for the tests.
DETECTOR="${CLOSING_KEYWORD_LIB:-$HOOK_DIR/lib/closing-keyword.py}"
if [ ! -f "$DETECTOR" ]; then
  echo "BLOCKED: $DETECTOR is missing, and it is the rule this hook applies, so nothing here can read this text for a closing keyword that says the opposite of what it does. Restore it with claude-sync pull." >&2
  echo "OVERRIDE, this one command: SKIP_CLOSING_CHECK=1 <your original command>" >&2
  exit 2
fi
# The repository a bare #N is looked up in (claude-config#2464): the one the gh command names, else
# the origin of the directory the command runs in, read as mt_remote_slug in lib/merge-target.sh reads
# it. Anything that is not owner/name leaves the detector no repository, and a bare #N then refuses.
slug="$gh_repo"
if [ -z "$slug" ] && [ -n "$cwd" ]; then
  slug="$(git -C "$cwd" config --get remote.origin.url 2>/dev/null \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
fi
findings="$(printf '%s' "$cmd" | python3 "$DETECTOR" text "$slug" 2>/dev/null)"; det_rc=$?
if [ "$det_rc" -ne 0 ]; then
  echo "BLOCKED: $DETECTOR failed (exit $det_rc) reading this text, so whether it puts a closing keyword in front of an issue it says it is not closing is unknown. That is the detector failing, not the text passing." >&2
  echo "OVERRIDE, this one command: SKIP_CLOSING_CHECK=1 <your original command>" >&2
  exit 2
fi

[ -n "$findings" ] || exit 0

cat >&2 <<EOF
BLOCKED: a closing keyword in front of a number this text should not close, or one that could
not be checked.

$findings

GitHub will CLOSE whatever a closing word sits in front of on merge, issue or pull request,
whatever the sentence around it says. Its linked-issue parser matches the keyword plus the
reference and reads nothing else: a "not", a "would have", a "which" or a "Part of" elsewhere
is invisible to it. "It does not close #897" closed Overture #897 on a PR that said it did
not, and "the p0 fix #2451", in passing, closed pull request #2451 unmerged.

Reword each phrase quoted above so the closing word is never in front of the number:
  "Part of #897, which stays open."
  "#897 stays open: this fixes only the ratchet."
  "the p0 change in #2451", or "Supersedes #2451" for a pull request this replaces.
An issue this change does finish goes on a line of its own: "Closes #897".

Override (a doc that must quote the broken phrasing): SKIP_CLOSING_CHECK=1 <command>
EOF
exit 2
