#!/usr/bin/env bash
#
# stop-hook-python-notice.sh: say ONCE when the end of turn hooks cannot run without python3
# (claude-config#490).
#
# All three Stop hooks decide whether the turn did real work by running python3: two of them call
# turn-worked.py, and checkpoint-save.sh is a python3 heredoc from top to bottom. With no python3
# the answer comes back EMPTY, the comparison against "yes" fails, and the hook exits 0. So on a
# machine with no python3 there is no reflection, no issue review and no memory write, ever, and
# quiet is indistinguishable from having nothing to say (L98, L11). session-reflection.sh even
# carries a static fallback payload further down that can never be reached, because the hook has
# already exited by the time it would matter.
#
# This is a DIFFERENT fault from the one claude-config#486 fixed, and it is why these three were
# left out of that change. Those hooks stand between an action and its effect, so going silent
# opens a gate. A Stop hook refuses nothing: its turn's work is already done and its
# decision:block is a continuation instruction. Losing one is a lost nudge, which is smaller, and
# needs a message that says so.
#
# ONE notice, not one per hook. The cause is a single missing interpreter and all three lose their
# work to it, so three blocks in one turn would be exactly the noise that gets a hook switched off
# (L36). The marker is therefore SHARED, and whichever hook notices first speaks for all of them,
# which is why the wording has to name the other two: a reader told about one lost nudge would
# silently lose three (L11, L679 is the opposite trap and is avoided here by naming the hooks
# rather than enumerating what each one does).
#
# IT BLOCKS ONLY WHEN IT COULD RECORD THAT IT HAD. A decision:block causes a continuation, which
# arrives as another Stop, which would block again: a Stop hook that cannot deduplicate its own
# block does not speak twice, it never stops. So where the marker cannot be written this stays
# silent. That is a real loss and it is the deliberate one of the two (L93): a notice missed on an
# unwritable temporary directory against a session that can never end.
#
# The marker lives in TMPDIR, so it lasts as long as the machine's temporary space does and the
# notice comes back if python3 is still missing after a restart. That is the same shape and the
# same reasoning as deferral-edit-check.sh and teammate-challenge-gate.sh use for #486.
#
# Environment:
#   STOP_HOOK_NOTICE_DIR   where the marker is kept (default TMPDIR), so a suite can drive both
#                          the first notice and the silence after it.

# Returns 0 when python3 is there and the caller should carry on. Otherwise it speaks at most once
# and EXITS the calling hook, because there is nothing for that hook to do without python3.
stop_hook_python3_notice() {   # $1 = the calling hook's file name, for the message
  command -v python3 >/dev/null 2>&1 && return 0

  local who="${1:-a Stop hook}" dir marker reason
  dir="${STOP_HOOK_NOTICE_DIR:-${TMPDIR:-/tmp}}"
  mkdir -p "$dir" 2>/dev/null || exit 0
  marker="$dir/stop-hooks-no-python3"
  [ -e "$marker" ] && exit 0
  # Written BEFORE the notice is printed, so a notice cannot repeat itself if anything below
  # fails, and checked afterwards rather than trusted: a redirection into an unwritable directory
  # reports failure through its status and this is the one place that status decides whether it is
  # safe to block at all.
  # In a SUBSHELL with stderr closed off. A redirection that fails is reported by the shell itself
  # before a `2>/dev/null` on the same simple command takes effect, so the plain form leaks
  # "Permission denied" out of a hook whose whole contract here is to say nothing (L11 cuts both
  # ways: a hook that has decided to stay silent must actually be silent).
  ( : > "$marker" ) 2>/dev/null || exit 0
  [ -f "$marker" ] || exit 0

  # One line, and deliberately free of quotes, backslashes and newlines: it is interpolated into a
  # JSON string by printf, with no interpreter available to encode it properly. The three names are
  # a fact about the code rather than a claim about which of them this machine has registered, so
  # the sentence stays true either way (L11).
  reason="END OF TURN HOOKS DID NOT RUN: python3 is not on PATH, and $who decides whether the turn did real work by running python3. Nothing reflected on this turn, nothing reviewed it for issues worth filing, and nothing was written to memory. All three end of turn hooks (session-reflection.sh, feature-issue-review.sh, checkpoint-save.sh) are silent for the same reason, and none of them refuses anything, so nothing has been blocked or lost beyond those three nudges. This is said ONCE per machine rather than on every turn. Tell the user that python3 is missing from PATH and that those hooks are inert until it is installed, then end the turn without acting further on this."
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  exit 0
}
