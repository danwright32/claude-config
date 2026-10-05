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
# Separately, in a repository it applies to, it refuses a push straight to the default branch
# (claude-config#596), because the Linux run here cannot be relied on to happen and a pull request's
# CI can. The reasons, with the measurements, are beside that rule below.
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

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# Not this repository, so there is nothing here to run and nothing to say about it.
[ -x tests/run-on-linux.sh ] || exit 0
[ -x tests/audit-changed-sections.sh ] || exit 0

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
# The branch names a push command would update on origin, one per line, or ALL for --all, --mirror
# and --branches. Read from the push segment's own words: explicit refspecs first, then where a
# bare `git push` goes (@{push}), then the current branch.
_ls_push_dests(){   # $1 = command
  local segs seg
  segs="$(ps__shell_segments "$1")" || segs="$(printf '%s' "$1" | sed -E 's/(&&|\|\||;|\|)/\n/g' | tr '\n' '\036')"
  while IFS= read -r -d $'\x1e' seg; do
    ps__segment_is_push "$seg" || continue
    local -a tok
    read -r -a tok <<< "$seg"
    local i=0 n=${#tok[@]} seen=0 remote="" specs="" skip=0 t d
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
        --all|--mirror|--branches) printf 'ALL\n' ;;
        -o|--push-option|--repo|--receive-pack|--exec) skip=1 ;;
        -*) ;;
        *) if [ -z "$remote" ]; then remote="$t"; else specs="$specs $t"; fi ;;
      esac
    done
    # A push to another remote does not reach the shared repository's default branch.
    case "$remote" in ''|origin) ;; *) continue ;; esac
    if [ -n "$specs" ]; then
      for t in $specs; do
        t="${t#+}"
        case "$t" in *:*) d="${t#*:}" ;; *) d="$t" ;; esac
        if [ -z "$d" ] || [ "$d" = "HEAD" ]; then d="$(_ls_cur_branch)"; fi
        printf '%s\n' "${d#refs/heads/}"
      done
    else
      d="$(git rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null)"
      if [ -n "$d" ]; then d="${d#*/}"; else d="$(_ls_cur_branch)"; fi
      [ -n "$d" ] && printf '%s\n' "$d"
    fi
  done < <(printf '%s' "$segs")
}
if ! ps_has_override "$cmd" ALLOW_DIRECT_MAIN_PUSH; then
  _ls_def="$(ps__default_ref 2>/dev/null)"; _ls_def="${_ls_def#*/}"; _ls_def="${_ls_def:-main}"
  _ls_hit=""
  while IFS= read -r _ls_d; do
    case "$_ls_d" in ALL|"$_ls_def") _ls_hit=1 ;; esac
  done <<DESTS
$(_ls_push_dests "$cmd")
DESTS
  if [ -n "$_ls_hit" ]; then
    _ls_file="$(_ls_key 2>/dev/null)"
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

ps_has_override "$cmd" SKIP_LINUX_CHECK && exit 0

base="$(ps_base_ref)" || exit 0
git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || exit 0

out="$(AUDIT_ON_LINUX=1 bash tests/audit-changed-sections.sh "$base" 2>&1)"; rc=$?

# 0 is a pass or an honest nothing-to-do, and 2 is the audit refusing to answer, which is its own
# problem and not evidence about this push. Only 1 means a section ran on Linux and failed, and 4
# that the prelude before it failed while its own checks passed.
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
  # The PRELUDE failed and the changed sections' own checks passed (claude-config#625). Still a
  # block, because something this push would run fails on Linux, but worded for what was measured:
  # on 2026-10-03 this said a changed section failed while the suite's own counts read
  # prelude_fail=4 target_fail=0, and a refusal naming the wrong culprit pushes toward an override
  # rather than a fix (L11).
  _ls_record judged >/dev/null || true
  {
    echo "PUSH BLOCKED: the prelude every test section runs first FAILS on Linux."
    echo ""
    echo "The sections this change touches passed their own checks there. What failed is the"
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
