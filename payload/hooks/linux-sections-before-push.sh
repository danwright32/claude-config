#!/usr/bin/env bash
#
# linux-sections-before-push.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: before a `git push`, run the test sections the change touches on LINUX, in a container, and
# block the push if one of them fails there (claude-config#339).
#
# It exists because two defects shipped on 2026-09-07 that were green on every machine anybody
# looks at and red only on the CI runner: a tab escape in a grep pattern that BSD grep honours and
# GNU grep does not, and a git call with no identity, which works wherever git can find one. The
# shared repo stayed red for seven hours. Each attempt to understand either one cost a push and a
# five minute wait, and one of them could not be reproduced on a Mac at all.
#
# It is repo-agnostic by construction: a repository with no tests/run-on-linux.sh is not this one,
# and the hook does nothing at all there rather than guessing what to run.
#
# Fails OPEN in every direction it cannot see: no docker, no base to diff against, a parse error, a
# repository this does not apply to. Of the Linux run it blocks on one thing only, something that
# actually ran on Linux and failed: a changed section's own checks, or the prelude they run after,
# each named as what it is (claude-config#625). A machine that cannot ask the question must not stop
# a push over it, and the audit says UNMEASURED so that a run nobody made is never mistaken for a
# clean one.
#
# Separately, it refuses a push straight to the default branch of the shared claude-config repository
# (claude-config#596), because the Linux run here cannot be relied on to happen and a pull request's
# CI can. The reasons, with the measurements, are beside that rule below. That rule judges where the
# push GOES, the URL of the remote it reaches from the directory it runs in, never the checkout's
# shape (claude-config#892), and it fails CLOSED: a push to main whose directory cannot be resolved is
# refused rather than judged in the session's place.
#
# Overrides, each for one push, explained to the user first and never silently:
#   SKIP_LINUX_CHECK=1 git push ...        do not run the changed sections on Linux
#   ALLOW_DIRECT_MAIN_PUSH=1 git push ...  push straight to the default branch

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0

# The repository the push runs in: a `git -C`, a `cd` in the same command, or the session's directory
# (claude-config#892). Empty when none of those resolves to a work tree, which the default branch
# rule below treats as a target it cannot see, never as somewhere else, and never as the session's
# directory in its place. Nothing below calls git while it is empty: the hook's own directory is not
# the push's.
repo_dir="$(ps_repo_dir "$cmd" "$cwd" 2>/dev/null)" || repo_dir=""
if [ -n "$repo_dir" ]; then cd "$repo_dir" 2>/dev/null || repo_dir=""; fi

_ls_state_dir="${LINUX_SECTIONS_STATE_DIR:-$HOME/.claude/state/linux-sections}"
_ls_key(){   # -> this repository's record file, keyed on the origin remote
  local remote key
  remote="$(git remote get-url origin 2>/dev/null)"
  [ -n "$remote" ] || remote="$(pwd -P)"
  key="$(printf '%s' "$remote" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  [ -n "$key" ] || return 1
  printf '%s/%s.txt' "$_ls_state_dir" "$key"
}

# A PUSH STRAIGHT TO THE DEFAULT BRANCH IS REFUSED HERE (claude-config#596). CI on a pull request
# is the only place this repository is reliably judged on Linux before main is, and the section
# gate below cannot stand in for it. Measured rather than assumed:
#   * on Daniels-MacBook-Pro-2 the record this hook keeps (claude-config#529) read "judged: 0,
#     with_sections: 15" on 2026-10-05: Docker's daemon was not running on any push that had a
#     section to judge, so Linux judged none of them;
#   * it only ever judges sections of tests/test-claude-sync.sh, so a defect in any other suite
#     (the 2026-09-02 red stretch was payload/hooks/test-run-all-tests.sh) is outside it entirely;
#   * the September 2026 CI review found 51 of main's 60 red runs came from direct pushes, against
#     2 of 100 pull request merges, and the direct push failures sampled since were whole repo
#     checks (a pipefail scan, a comment rule, a project list check) that the full suite on a pull
#     request runs and a section audit never does.
# The automatic "sync from <host>" commits are pushed by claude-sync itself, not through a session's
# Bash call, so this never sees them. Its own override, never SKIP_LINUX_CHECK: a second rule put
# behind an existing override widens every use of it (L448).
_ls_cur_branch(){ git symbolic-ref --quiet --short HEAD 2>/dev/null; }
_ls_unquote(){ local t="$1"; t="${t#[\"\']}"; t="${t%[\"\']}"; printf '%s' "$t"; }
# The shared repository, judged by the URL a push goes to (claude-config#892). Its SHAPE (a Linux
# runner beside an audit) said "this repository" for any copy of it, so a scratch clone whose origin
# was a local bare repository had its push to main refused. GitHub reads owner and name without case.
_ls_is_shared_url(){   # $1 = a remote URL
  local u
  u="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  # Anchored at BOTH ends: a URL that merely contains the path (a mirror's) is somewhere else.
  [[ "$u" =~ ^((https?|ssh|git)://([^/@]+@)?|[^/@:]+@)?github\.com[:/]+danwright32/claude-config(\.git)?/*$ ]]
}
# Whether a remote word names a URL or a path rather than a configured remote's name.
_ls_is_location(){ case "$1" in */*|*:*|.*|'~'*) return 0 ;; esac; return 1; }
# The remote a push with no remote word goes to, as git chooses it.
_ls_default_remote(){
  local b r
  b="$(_ls_cur_branch)"
  [ -n "$b" ] && r="$(git config --get "branch.$b.pushRemote" 2>/dev/null)"
  [ -n "$r" ] || r="$(git config --get remote.pushDefault 2>/dev/null)"
  [ -n "$r" ] || { [ -n "$b" ] && r="$(git config --get "branch.$b.remote" 2>/dev/null)"; }
  printf '%s' "${r:-origin}"
}
# What a push command updates, one line per destination: "<remote as written><US><branch>" (a unit separator,
# never a tab: read splits on whitespace by collapsing it, so an empty remote vanished), the
# branch being ALL for --all, --mirror, --branches and a pattern refspec. Read from the push
# segment's own words: explicit refspecs first, then where a bare `git push` goes (@{push}), then the
# current branch. $2 = words: read the words alone and call no git at all, for a push whose
# repository could not be resolved, where a destination only git could answer (a bare push, HEAD)
# is printed as ? because it may be the default branch.
_ls_push_dests(){   # $1 = command  $2 = repo | words
  local segs seg mode="${2:-repo}"
  segs="$(ps__shell_segments "$1")" || segs="$(printf '%s' "$1" | sed -E 's/(&&|\|\||;|\|)/\n/g' | tr '\n' '\036')"
  while IFS= read -r -d $'\x1e' seg; do
    ps__segment_is_push "$seg" || continue
    local -a tok
    read -r -a tok <<< "$seg"
    # The refspecs are kept in an ARRAY and walked quoted: a glob refspec like refs/heads/*:refs/
    # heads/* expanded unquoted is matched against files in the working directory (claude-config#776
    # review). A tag only push (--tags with no refspec) updates no branch, so it names none.
    local -a specs=()
    local i=0 n=${#tok[@]} seen=0 remote="" skip=0 tags=0 all=0 t d
    while [ "$i" -lt "$n" ]; do
      t="${tok[$i]}"; i=$((i + 1))
      if [ "$seen" -eq 0 ]; then
        case "$t" in push|push\)*|push\}*) seen=1 ;; esac
        continue
      fi
      t="${t%%)*}"; t="${t%%\}*}"; t="$(_ls_unquote "$t")"
      [ -n "$t" ] || continue
      if [ "$skip" -eq 1 ]; then skip=0; continue; fi
      case "$t" in
        --all|--mirror|--branches) all=1 ;;
        --tags) tags=1 ;;
        -o|--push-option|--repo|--receive-pack|--exec) skip=1 ;;
        -*) ;;
        *) if [ -z "$remote" ]; then remote="$t"; else specs+=("$t"); fi ;;
      esac
    done
    [ "$all" -eq 1 ] && printf '%s\037ALL\n' "$remote"
    if [ "${#specs[@]}" -gt 0 ]; then
      for t in "${specs[@]}"; do
        t="${t#+}"
        case "$t" in *:*) d="${t#*:}" ;; *) d="$t" ;; esac
        if [ -z "$d" ] || [ "$d" = "HEAD" ]; then
          if [ "$mode" = words ]; then printf '%s\037?\n' "$remote"; continue; fi
          d="$(_ls_cur_branch)"
        fi
        d="${d#refs/heads/}"
        # A pattern refspec reaches every branch it matches, the default one included.
        case "$d" in *'*'*) d="ALL" ;; esac
        printf '%s\037%s\n' "$remote" "$d"
      done
    elif [ "$tags" -eq 1 ] || [ "$all" -eq 1 ]; then
      :
    elif [ "$mode" = words ]; then
      printf '%s\037?\n' "$remote"
    else
      d="$(git rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null)"
      if [ -n "$d" ]; then d="${d#*/}"; else d="$(_ls_cur_branch)"; fi
      [ -n "$d" ] && printf '%s\037%s\n' "$remote" "$d"
    fi
  done < <(printf '%s' "$segs")
}
if ! ps_has_override "$cmd" ALLOW_DIRECT_MAIN_PUSH; then
  _ls_hit=""; _ls_blind=""
  if [ -n "$repo_dir" ]; then
    # Resolved: the push is judged by where it actually goes. Only a destination on the shared
    # repository counts, whatever the remote is called, and whatever this checkout looks like.
    _ls_def="$(ps__default_ref 2>/dev/null)"; _ls_def="${_ls_def#*/}"; _ls_def="${_ls_def:-main}"
    while IFS=$'\x1f' read -r _ls_r _ls_d; do
      [ -n "$_ls_d" ] || continue
      case "$_ls_d" in ALL|"$_ls_def") ;; *) continue ;; esac
      [ -n "$_ls_r" ] || _ls_r="$(_ls_default_remote)"
      # Where the push GOES: a configured remote's push URL (pushurl and pushInsteadOf applied),
      # which can differ from the one it fetches from; otherwise the word as git expands it.
      if git config --get "remote.$_ls_r.url" >/dev/null 2>&1; then
        _ls_url="$(git remote get-url --push "$_ls_r" 2>/dev/null)"
      else
        _ls_url="$(git ls-remote --get-url "$_ls_r" 2>/dev/null)"
      fi
      _ls_is_shared_url "${_ls_url:-$_ls_r}" && _ls_hit=1
    done <<DESTS
$(_ls_push_dests "$cmd" repo)
DESTS
  else
    # Unresolved: the command moves somewhere this cannot see (a variable, a directory the same
    # command creates). The words still say main; only a remote written as a location that is
    # plainly not the shared repository lets the push through (L75: an unidentified target is
    # refused, never replaced by a nearby one).
    _ls_def="main"
    while IFS=$'\x1f' read -r _ls_r _ls_d; do
      case "$_ls_d" in ALL|main|master|'?') ;; *) continue ;; esac
      if _ls_is_location "$_ls_r"; then _ls_is_shared_url "$_ls_r" && _ls_hit=1
      else _ls_hit=1; _ls_blind=1; fi
    done <<DESTS
$(_ls_push_dests "$cmd" words)
DESTS
  fi
  if [ -n "$_ls_hit" ] && [ -n "$_ls_blind" ]; then
    {
      echo "PUSH BLOCKED: this may push to $_ls_def, and the hook could not tell which repository it pushes from."
      echo ""
      echo "The command runs the push somewhere that is not a git work tree yet, or names it through"
      echo "a variable, so it cannot be checked against the shared claude-config repository, where a"
      echo "change reaches $_ls_def only through a pull request. Unknown is refused, not assumed elsewhere."
      echo ""
      echo "Instead, run the push as its own command once the directory exists, with the path written"
      echo "out (git -C <path> push ...), and it is judged by the repository it actually reaches."
      echo ""
      echo "OVERRIDE, this one push: ALLOW_DIRECT_MAIN_PUSH=1 <your original git push command>"
      echo "BEFORE overriding you MUST explain to the user, in plain non-technical language, why"
      echo "this push is safe. Never override silently."
    } >&2
    exit 2
  fi
  if [ -n "$_ls_hit" ]; then
    _ls_file=""
    [ -n "$repo_dir" ] && _ls_file="$(_ls_key 2>/dev/null)"
    _ls_j="$(awk -F': ' '/^judged:/ { print $2 }' "$_ls_file" 2>/dev/null)"
    _ls_t="$(awk -F': ' '/^with_sections:/ { print $2 }' "$_ls_file" 2>/dev/null)"
    case "$_ls_j:$_ls_t" in
      :*|*:|*[!0-9:]*) _ls_seen="it has no record of judging any push here" ;;
      *) _ls_seen="it has judged $_ls_j of the $_ls_t pushes here that had a section to check" ;;
    esac
    {
      echo "PUSH BLOCKED: this pushes straight to $_ls_def. In this repository a change reaches $_ls_def through a pull request."
      echo ""
      echo "A pull request is the only place this repository is reliably judged on Linux before"
      echo "$_ls_def is. Pushed directly, a defect that only shows on the CI runner turns $_ls_def red,"
      echo "and while it is red neither Mac receives config. The Linux check run before a push"
      echo "cannot stand in for it: $_ls_seen, and it only ever looks at"
      echo "sections of tests/test-claude-sync.sh."
      echo ""
      echo "Instead, push a branch and open a pull request:"
      echo "    git push -u origin HEAD:<branch-name>"
      echo "    gh pr create --base $_ls_def"
      echo ""
      echo "OVERRIDE, this one push: ALLOW_DIRECT_MAIN_PUSH=1 <your original git push command>"
      echo "BEFORE overriding you MUST explain to the user, in plain non-technical language, why"
      echo "this change cannot wait for a pull request. Never override silently."
    } >&2
    exit 2
  fi
fi

# Nowhere to run the Linux sections from, or not this repository: nothing to run and nothing to say.
[ -n "$repo_dir" ] || exit 0
[ -x tests/run-on-linux.sh ] || exit 0
[ -x tests/audit-changed-sections.sh ] || exit 0

ps_has_override "$cmd" SKIP_LINUX_CHECK && exit 0

base="$(ps_base_ref)" || exit 0
git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || exit 0

out="$(AUDIT_ON_LINUX=1 bash tests/audit-changed-sections.sh "$base" 2>&1)"; rc=$?

# 0 is a pass or an honest nothing-to-do, and 2 is the audit refusing to answer, which is its own
# problem and not evidence about this push. Only 1 means a section ran on Linux and failed, and 4
# that the prelude before it failed while no check of its own failed.
#
# An exit 0 that says UNMEASURED is neither: the runner could not run, so nothing about this push
# was judged on Linux. That must be SAID. Measured on 2026-09-21 while timing what a push waits on
# (claude-config#523): docker is installed on this Mac and its daemon is not running, so this gate
# returned in 1.5 seconds, silently, on every push, and a push nobody had checked on Linux read
# exactly like one that passed (L98, L557). The push is still not blocked on a question this
# machine cannot ask.
# THE RECORD of how often Linux actually judged a push here (claude-config#529). A gate that stands
# down on most pushes is close to not being there, and nothing knew: this one judged nothing at all
# on this Mac between 2026-09-07 and 2026-09-21, because docker was installed and its daemon was
# not running, and every push looked the same (L557).
#
# Counted per repository, keyed on the origin remote so a worktree and its checkout are one
# repository, and only for pushes that HAD a section to judge: a push touching no test section is
# not a stand down, and counting it would make the number say the gate is failing on every push.
# Bookkeeping that cannot be written never blocks a push and never silences the notice itself.
_ls_record(){        # $1 = judged | stood-down  -> prints "<judged> of the <total>"
  local remote file judged total
  remote="$(git remote get-url origin 2>/dev/null)"
  [ -n "$remote" ] || remote="$(pwd -P)"
  file="$(_ls_key)" || return 1
  mkdir -p "$_ls_state_dir" 2>/dev/null || return 1
  judged="$(awk -F': ' '/^judged:/ { print $2 }' "$file" 2>/dev/null)"
  total="$(awk -F': ' '/^with_sections:/ { print $2 }' "$file" 2>/dev/null)"
  case "$judged" in ''|*[!0-9]*) judged=0 ;; esac
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  total=$(( total + 1 ))
  [ "$1" = "judged" ] && judged=$(( judged + 1 ))
  {
    printf '# how often %s was judged on Linux before a push (claude-config#529)\n' "$remote"
    printf 'judged: %s\n' "$judged"
    printf 'with_sections: %s\n' "$total"
    printf 'last: %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"
  } > "$file" 2>/dev/null || return 1
  printf '%s of the %s' "$judged" "$total"
}

if [ "$rc" -eq 4 ]; then
  # The PRELUDE failed and no changed section failed a check of its own (claude-config#625). Still a
  # block, because something this push would run fails on Linux, but worded for what was measured:
  # on 2026-10-03 this said a changed section failed while the suite's own counts read
  # prelude_fail=4 target_fail=0, and a refusal naming the wrong culprit pushes toward an override
  # rather than a fix (L11).
  _ls_record judged >/dev/null || true
  {
    echo "PUSH BLOCKED: the prelude every test section runs first FAILS on Linux."
    echo ""
    echo "None of the sections this change touches failed a check of its own there (the audit"
    echo "below says, per section, whether it ran any or was cut short). What failed is the"
    echo "shared setup before them, which is either broken on the base this was cut from, or"
    echo "broken by a change to code it exercises (the tool, a hook, or what the container holds)."
    echo ""
    printf '%s\n' "$out"
    echo ""
    echo "Tell which by running the same section on the unchanged base in a worktree:"
    echo "    git worktree add <dir> $base && cd <dir> && SECTION_ONLY='<the section named above>' tests/run-on-linux.sh tests/test-claude-sync.sh"
    echo "If it fails there too, the base is broken and this change is not the cause."
    echo ""
    echo "OVERRIDE, when the base fails the same way: SKIP_LINUX_CHECK=1 <your original git push command>"
    echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
    echo "language, why skipping is legitimate here. Never override silently."
  } >&2
  exit 2
fi
if [ "$rc" -ne 1 ]; then
  case "$out" in
    *UNMEASURED*)
      _ls_seen="$(_ls_record stood-down || true)"
      {
        echo "linux-sections-before-push: nothing in this push was judged on Linux, and that is not a pass."
        printf '%s\n' "$out"
        if [ -n "$_ls_seen" ]; then
          echo "Linux has judged $_ls_seen push(es) here that had a section to check."
        else
          echo "(How often that has happened could not be recorded, so this is the only place it is said.)"
        fi
        echo "CI will still ask the question. To ask it here, start Docker Desktop and push again."
      } >&2 ;;
    *"ran on their own and passed"*|*"ran on its own and passed"*)
      _ls_record judged >/dev/null || true ;;
  esac
  exit 0
fi
# A section that RAN on Linux and failed is a judged push, whatever the verdict.
_ls_record judged >/dev/null || true

{
  echo "PUSH BLOCKED: a test section this change touches FAILS on Linux."
  echo ""
  echo "It passes here and fails on the machine CI actually uses, which is the"
  echo "shape that kept the shared repo red for seven hours on 2026-09-07. Pushing"
  echo "it turns CI red and stops both Macs receiving config until it is fixed."
  echo ""
  printf '%s\n' "$out"
  echo ""
  echo "Reproduce it as many times as you like, in seconds:"
  echo "    SECTION_ONLY='<the section named above>' tests/run-on-linux.sh tests/test-claude-sync.sh"
  echo ""
  echo "OVERRIDE: if this is genuinely a false positive, re-run with:"
  echo "    SKIP_LINUX_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, why skipping is legitimate here. Never override silently."
} >&2
exit 2
