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
# repository this does not apply to. It blocks on ONE thing only, a section that actually ran on
# Linux and failed. A machine that cannot ask the question must not stop a push over it, and the
# audit says UNMEASURED so that a run nobody made is never mistaken for a clean one.
#
# Override: SKIP_LINUX_CHECK=1 git push ...   Explain why to the user first, never silently.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0
ps_has_override "$cmd" SKIP_LINUX_CHECK && exit 0

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# Not this repository, so there is nothing here to run and nothing to say about it.
[ -x tests/run-on-linux.sh ] || exit 0
[ -x tests/audit-changed-sections.sh ] || exit 0

base="$(ps_base_ref)" || exit 0
git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || exit 0

out="$(AUDIT_ON_LINUX=1 bash tests/audit-changed-sections.sh "$base" 2>&1)"; rc=$?

# 0 is a pass or an honest nothing-to-do, and 2 is the audit refusing to answer, which is its own
# problem and not evidence about this push. Only 1 means a section ran on Linux and failed.
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
_ls_state_dir="${LINUX_SECTIONS_STATE_DIR:-$HOME/.claude/state/linux-sections}"
_ls_record(){        # $1 = judged | stood-down  -> prints "<judged> of the <total>"
  local remote key file judged total
  remote="$(git remote get-url origin 2>/dev/null)"
  [ -n "$remote" ] || remote="$(pwd -P)"
  key="$(printf '%s' "$remote" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  [ -n "$key" ] || return 1
  file="$_ls_state_dir/$key.txt"
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
