#!/usr/bin/env bash
#
# check-deferrals.sh
# Claude Code PreToolUse(Bash) hook.
#
# Refuse a `git push` whose ADDED lines write a deferral down with no issue number beside it
# (claude-config#430). Two of the ten confirmed findings in the 2026-09-18 Slate review were
# already known and written in the tree: the content security policy deferred in a code comment
# ("a full content CSP is a separate effort", src/lib/security-headers.ts) and a gap named in
# docs/pii.md. Neither had an issue, so no picker offered them, no milestone held them and nothing
# scheduled them (slate#2564, slate#2565). L65 says a deliberately temporary state needs its issue
# filed in the same change; this is the enforcement.
#
# THE RULE lives in ONE detector, lib/deferrals.py, shared with deferral-edit-check.sh, which asks
# the same question of every Edit and Write the moment it happens. This hook is the backstop for
# a deferral that slipped past the edit hook (a heredoc, a python one liner, a file written by a
# tool). The phrase list is lib/deferral-phrases.txt, one line per phrase with a reason.
#
# A finding is a line in a COMMENT (or any line of a markdown or text file) that carries one of the
# phrases and has no `#NNNN` or GitHub issue URL on the line or within two lines either side. The
# remedy is to file the issue and put its number beside the line, which the issue gate makes cheap.
#
# MEASURED before it was turned on (L147, L172), on 2026-09-18, against the whole of Slate's main
# checkout (src/, scripts/, docs/, AGENTS.md, CLAUDE.md: 1,681 files, every comment and every doc
# line, the two lines either side rule applied). With the sixteen phrases the issue proposed:
#
#   later 362, deferred 41, not yet 32, eventually 25, for now 7, follow-up 4,
#   separate effort 3, follow up 2, XXX 1; TODO, FIXME, defer this, future work, someday,
#   when we have time, punt: 0 each (Slate holds no TODO or FIXME at all).
#
# DROPPED, because they fired on true sentences rather than deferrals:
#   later        362 hits, every sampled one a statement about time ("a later statement", "nine
#                days later", "a variant added later is covered by construction"); at most two of
#                the 362 ("a later pass") were deferrals.
#   not yet      32 hits, all describing state ("not yet stale", "callers not yet migrated").
#   eventually   25 hits, "eventually consistent" and "what eventually notices is the alarm".
#   XXX          1 hit, the `BOOKING_API_KEY=xxx` placeholder in a usage comment.
#   deferred     41 hits, 33 of them Slate's own term for `after()` work ("deferred send",
#                "deferred job", `deferred=0`). NARROWED to "deferred to", "deferred until" and
#                "deferred pending", which is how the genuine ones were worded ("deferred to
#                Task 6", "deferred pending a 200 agent soak") and which keep 5 of the 8.
#
# KEPT, with the final list: 21 findings on the whole tree, 13 of them genuine deferrals, 8 noise
# (the noise: "a follow-up commit", "a follow-up PR", "THE FOLLOW UP SENTENCE" in alert copy, "the
# rest deferred to next tick", and two grammatical accidents of "for now": "no builder for now
# throws", "the state the action asked for now"). The real case IS caught:
# src/lib/security-headers.ts:13 "content CSP is a separate effort", whose nearest issue number
# sits four lines away. The docs/pii.md sentence ("That is the single largest gap in this map")
# is NOT detectable by phrase: it contains no deferral wording, and it has #1041 two lines below
# it anyway. Saying so here rather than stretching the list to "gap", which is an ordinary word.
#
# A push judges only the lines it ADDS, so the whole tree rate above (21 in 1,681 files) is the
# ceiling, not the expectation; a typical push adds a handful of comment lines.
#
# Reads the COMMITTED range (merge-base to HEAD) and, when the same command commits before it
# pushes, the PENDING content that commit would carry: the index, plus what the `git add` names,
# plus every tracked change when the commit stages for itself with -a. Untracked files are read
# only when the add takes them, because an untracked file nobody staged cannot be pushed
# (claude-config#350). Removed lines are never judged and cannot clear a finding.
#
# Override: SKIP_DEFERRAL_CHECK=1 git push ...   one push only. Explain to Dan first, in plain
# language, why the line is not a deferral or why it genuinely cannot carry an issue yet; never
# skip silently.
#
# Fails OPEN on anything it cannot read (no repo, no detector, no phrase list), and SAYS SO in
# one line on stderr, because a silent skip is indistinguishable from a pass (L98).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0
DETECTOR="$HOOK_DIR/lib/deferrals.py"

payload="$(cat)"

parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0

if ps_has_override "$cmd" SKIP_DEFERRAL_CHECK; then
  exit 0
fi

skip() {  # $1 = what could not be measured; allows the push and says so
  echo "check-deferrals: skipped, $1" >&2
  exit 0
}

[ -f "$DETECTOR" ] || skip "the detector lib/deferrals.py is not beside this hook, so nothing was judged."

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || skip "no git work tree was named by the command or the session directory, so nothing was judged."
[ -n "$repo_dir" ] || skip "no git work tree was named by the command or the session directory, so nothing was judged."
cd "$repo_dir" 2>/dev/null || skip "could not enter $repo_dir, so nothing was judged."

base="$(ps_base_ref || true)"
commit_in_chain=0
ps_commit_in_chain "$cmd" && commit_in_chain=1
# Where the committed range starts, from the shared contract (claude-config#441). A command that
# commits before it pushes has its own entry point: the pending commit is the change, so on a branch
# already level with its upstream the range starts at HEAD, where the plain push answer (HEAD~1)
# blamed this push for the last commit already on the remote.
if [ "$commit_in_chain" -eq 1 ]; then
  mb="$(ps_pending_base "$base")"
else
  mb="$(ps_merge_base "$base")"
fi

# Two lines of context is what the detector's window needs; three is git's default and is kept.
CTX=(-U3)
EXCLUDES=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.snap'
  ':(exclude)*.min.js' ':(exclude)*.min.css' ':(exclude)*.svg'
  ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif'
  ':(exclude)*.pdf' ':(exclude)*.woff' ':(exclude)*.woff2')

# No merge base (one commit, nothing upstream) means no COMMITTED range to read; the pending
# reading below still runs, because a first commit made by the same command is exactly what
# such a repository pushes. The skip for having read nothing at all is decided after both.
committed_diff=""
[ -n "$mb" ] && committed_diff="$(git diff "${CTX[@]}" "$mb" HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"

# The PENDING content, when this command commits before it pushes. What the commit would ACTUALLY
# carry: the index, plus what the `git add` in this chain names, plus every tracked change when
# the commit stages for itself with -a. Never the whole working tree, which held another
# session's untracked documents the day check-style-guide.sh read it (claude-config#350).
pending_diff=""
scope_unknown=0
untracked_block() {  # $1 = an untracked path; a real unified diff against nothing
  [ -f "$1" ] || return 0
  case "$1" in
    *.lock|*-lock.json|*.snap|*.min.js|*.min.css|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.pdf|*.woff|*.woff2) return 0 ;;
  esac
  # awk rather than head, so the producer is read to its end: a consumer that leaves early kills
  # the producer under pipefail and the pipeline reads as failed (L183).
  git diff --no-index "${CTX[@]}" /dev/null "$1" 2>/dev/null | awk 'NR <= 4000'
  printf '\n'
}
if [ "$commit_in_chain" -eq 1 ]; then
  pending_diff="$(git diff --cached "${CTX[@]}" -- . "${EXCLUDES[@]}" 2>/dev/null)"
  # What the commit will take beyond the index, from the one parser every push hook shares
  # (claude-config#442). This hook held a second copy of check-style-guide.sh's, and two copies of
  # one rule drift silently, one gate reading pending work one way and its sibling another (L370).
  add_scope="$(ps_add_scope "$cmd")"
  add_kind="${add_scope%%$'\n'*}"
  case "$add_kind" in
    INDEX) : ;;
    TRACKED)
      pending_diff="${pending_diff}
$(git diff "${CTX[@]}" HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)" ;;
    ALL|UNKNOWN)
      [ "$add_kind" = "UNKNOWN" ] && scope_unknown=1
      pending_diff="${pending_diff}
$(git diff "${CTX[@]}" HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        pending_diff="${pending_diff}
$(untracked_block "$u")"
      done < <(git ls-files --others --exclude-standard 2>/dev/null) ;;
    PATHS)
      while IFS= read -r pth; do
        [ -n "$pth" ] || continue
        if [ ! -e "$pth" ]; then scope_unknown=1; continue; fi
        pending_diff="${pending_diff}
$(git diff "${CTX[@]}" HEAD -- "$pth" "${EXCLUDES[@]}" 2>/dev/null)"
        while IFS= read -r u; do
          [ -n "$u" ] || continue
          pending_diff="${pending_diff}
$(untracked_block "$u")"
        done < <(git ls-files --others --exclude-standard -- "$pth" 2>/dev/null)
      done < <(printf '%s\n' "$add_scope" | tail -n +2)
      if [ "$scope_unknown" -eq 1 ]; then
        pending_diff="${pending_diff}
$(git diff "${CTX[@]}" HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"
        while IFS= read -r u; do
          [ -n "$u" ] || continue
          pending_diff="${pending_diff}
$(untracked_block "$u")"
        done < <(git ls-files --others --exclude-standard 2>/dev/null)
      fi ;;
  esac
fi

if [ -z "$committed_diff$pending_diff" ]; then
  # Nothing added is an ordinary allowed push. Having had NOTHING to read is a skip, and is said.
  if [ -z "$mb" ] && [ "$commit_in_chain" -eq 0 ]; then
    skip "no commit to compare this push against (a repository with one commit and no upstream), so nothing was judged."
  fi
  exit 0
fi

# The detector's stdout is its findings and its stderr is its refusal, and it never writes both,
# so one capture holds whichever it produced and the exit code says which (L184).
scan() {  # $1 = diff text; prints one finding per line, or the detector's own refusal
  printf '%s\n' "$1" | python3 "$DETECTOR" --diff 2>&1
}
committed_findings="$(scan "$committed_diff")"; rc=$?
if [ "$rc" -ne 0 ]; then
  err="${committed_findings%%$'\n'*}"
  skip "the detector could not run (${err:-exit $rc}), so nothing was judged."
fi
pending_findings=""
if [ -n "$pending_diff" ]; then
  pending_findings="$(scan "$pending_diff")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    err="${pending_findings%%$'\n'*}"
    skip "the detector could not run (${err:-exit $rc}), so nothing was judged."
  fi
fi

[ -n "$committed_findings$pending_findings" ] || exit 0

{
  echo "PUSH BLOCKED: a deferral is written down with no issue number beside it."
  echo ""
  echo "A comment or a doc line that puts work off (\"for now\", \"separate effort\", \"TODO\","
  echo "\"follow up\", \"deferred to\") needs the issue that will pick it up, as #NNNN on that"
  echo "line or within two lines of it. Without one, nothing schedules the work: no picker"
  echo "offers it and no milestone holds it (the 2026-09-18 Slate review found two such lines)."
  if [ -n "$committed_findings" ]; then
    echo ""
    echo "In the commits being pushed:"
    printf '%s\n' "$committed_findings" | awk 'NR <= 25'
  fi
  if [ -n "$pending_findings" ]; then
    echo ""
    echo "In content this command is about to commit (read from what it would stage):"
    printf '%s\n' "$pending_findings" | awk 'NR <= 25'
  fi
  if [ "$scope_unknown" -eq 1 ]; then
    echo ""
    echo "Which paths that commit would take could not be worked out from the command, so the"
    echo "whole working tree was read and a line above may belong to a file this commit will not"
    echo "carry. Run the commit and the push as two separate commands to find out."
  fi
  echo ""
  echo "To fix: file the issue (gh issue create, with its milestone, priority and category) and"
  echo "put its number beside the line, for example \"... is a separate effort (#1234).\" If the"
  echo "line is not a deferral, reword it so it does not read as one."
  echo "OVERRIDE, one push only: SKIP_DEFERRAL_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical language, WHY"
  echo "skipping is legitimate here, so they can judge whether it makes sense. Never override"
  echo "silently."
} >&2
exit 2
