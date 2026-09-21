#!/usr/bin/env bash
#
# check-bundle-budget.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: block a `git push` whose client bundle has grown past a recorded budget, so a dependency
# joining the customer facing hot path is caught on the day it lands rather than by an outside
# reviewer (claude-config#432). Slate shipped Luxon in the embed bundle and nobody knew until
# Try-Pennie/slate#2566 said so: no project measured what its client bundle weighed, so the
# addition passed every green check.
#
# WHAT IT MEASURES. The summed gzipped size of the client chunks the build left behind, in exactly
# two shapes: Next.js (`.next/static/chunks/**/*.js`, or the OpenNext copy under
# `.open-next/assets/_next/static/chunks/`) and Vite (`dist/assets/*.js`). Any other build output
# is refused by NAME and not judged, so a wrong directory can never produce a confident number. The
# measurer is lib/bundle-budget.py (python3, gzip from the stdlib); the rule lives there, once, and
# the test drives it through this hook.
#
# IT ONLY MEANS SOMETHING AFTER A BUILD. A build tree has two verdicts, before and after a build
# (L461). The newest chunk's mtime is compared with HEAD's commit time (`git log -1 --format=%ct`):
# a build older than the commit being pushed is reported as stale and nothing is judged, and no
# build output at all is one skip line. Both exit 0, in their own words, so neither can be read as
# a pass (L98, L11). When the command commits before it pushes, HEAD is still the previous commit,
# so the build is judged against that: fresh enough to be about this tree, not this exact commit.
#
# THE RECORD (a stored baseline, which this guard cannot avoid: there is no merge-base to diff a
# build against). One file per repository at
#     $HOME/.claude/state/bundle-budget/<sha256 of the origin remote URL>.txt
# holding the last accepted total and the date, in the shared ratchet's `<path>: <count>` shape
# (lib/ratchet.py reads it). The first measurement records and passes, saying so. The record only
# ever goes DOWN on its own (a smaller total replaces it) or is raised by the acceptance hatch
# below, so growth inside the margin never ratchets the budget upward one small step at a time.
# BUNDLE_BUDGET_STATE_DIR overrides the directory, which is how the test keeps its records out of
# the real home.
#
# THE MARGINS, measured 2026-09-18 on the Slate checkout's build of 2026-09-06 (34 chunks in
# .next/static/chunks, and the identical 34 in .open-next, which is why only the newer set is
# read): total 387,996 bytes gzipped (1,249,036 raw); median chunk 6,533 gzipped, p90 34,642; the
# five largest 73,110 / 61,751 / 39,373 / 34,642 / 22,886. The fifth is the Luxon chunk the review
# found (2uo7pjh3fqjgn.js: 72,902 raw, holds `Invalid DateTime` and `fromISO`; luxon.min.js alone
# gzips to 24,238). Without it the total is 365,110, so Luxon joining the bundle is a growth of
# 22,886 bytes, +6.3%.
#   Growth blocks when it exceeds BOTH 3% AND 10,240 bytes (10 KB) gzipped.
#   At Slate's size 3% is 10,953 bytes, so the Luxon addition is caught with about 2x headroom, and
#   stays caught until the bundle passes 763 KB. The brief's starting point of 5% (18,256 bytes at
#   Slate's size) would also catch it today, but with only 1.25x headroom and it would stop catching
#   it once the bundle reached 458 KB, which is not far off; the percentage is there for large
#   bundles where 10 KB is noise, not to let the finding this guard exists for slip under it (L172).
#   A median chunk (6.5 KB, an ordinary new page) passes both; a p90 chunk (34 KB) fails and is worth
#   an explicit acceptance. Only ONE build was available to measure, so how often ordinary work
#   crosses the margin is not known yet (L147); revisit the numbers once the record has seen a few
#   weeks of pushes. The Slate main copy handed to this work had no build output, so the numbers
#   come from the main checkout's build of 2026-09-06 rather than from HEAD.
#
# THE POSITIVE CONTROL (claude-config#526). Three days after this shipped, the state directory did
# not exist on this Mac: the guard had never recorded a total for any repository, and every push
# printed one of the skip lines above. Driven on 2026-09-21 against NurseDex, a non-Slate Next.js
# repository here, with a fresh `next build`: the stale-build branch was what had been firing (its
# .next was from 2026-09-04 against a HEAD of 2026-09-20), and after the build the hook recorded
# 1,317,537 bytes gzipped from 87 chunks in .next/static/chunks. So the measurer, the freshness
# test, the remote keying and the record all work end to end on a real repository.
#
# That second reading also puts the margins above in perspective: NurseDex is 3.4x Slate's 387,996
# bytes, so 3% there is 39,526 bytes and a p90 chunk would pass. The margins are unchanged, since
# two builds are still not a distribution (L147) and this is the second of the two; recalibrating
# them against several measured builds is claude-config#528.
#
# Overrides, each good for ONE push and to be explained to the user first, never silently:
#   ACCEPT_BUNDLE_GROWTH=1 git push ...      the growth is intended; record the new total and pass
#   SKIP_BUNDLE_BUDGET_CHECK=1 git push ...  do not judge this push at all, and record nothing
#
# Fails OPEN on anything it cannot read (no repo, no origin remote, no HEAD, the measurer refusing
# its arguments), and says so in one line.
#
# ONE exception, and it is a refusal: python3 not being installed at all (claude-config#486). Every
# other stand down above is a property of THIS push, which the next one can differ on. A missing
# interpreter is a property of the machine, so it silences this gate on every push until somebody
# installs one, and nothing records that a push went unweighed. So it is refused by name (L490).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat)"

# THE MEASURER'S OWN READER, asked before anything is measured (claude-config#486, L490).
#
# lib/bundle-budget.py runs under python3, and with no python3 the call came back with the shell's
# own "command not found" and exit 127, which landed in the catch all branch: one line on stdout
# and exit 0. The bundle was never weighed and nothing was recorded, on every push, on that
# machine, and a push that was never judged looked exactly like one that passed (L42, L98).
#
# Asked above the payload read, because python3 is also one of the two tools ps_parse_payload
# reads with: with neither jq nor python3 the parse below exits 0 first and this question would
# never be reached (L135, L667). Narrowed by a cheap substring on the raw payload, since nothing
# here can tell a push from an `ls` when the payload is unreadable (L36, L54), and the override is
# read the same way so the refusal is never a dead end (L109).
if ps_reader_missing python3; then
  case "$payload" in
    *SKIP_BUNDLE_BUDGET_CHECK=1*) exit 0 ;;
    *push*)
      echo "PUSH BLOCKED: $(ps_detector_absent_why "python3 is not on PATH" \
        "check-bundle-budget.sh runs its measurer, lib/bundle-budget.py, under it to weigh this repository's built client bundle against its recorded total, so with python3 absent nothing here weighs anything." \
        "python3")" >&2
      echo "OVERRIDE, this one push, recording nothing: SKIP_BUNDLE_BUDGET_CHECK=1 <your original git push command>" >&2
      exit 2 ;;
  esac
  exit 0
fi

parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0
ps_has_override "$cmd" SKIP_BUNDLE_BUDGET_CHECK && exit 0

# A flag word rather than an array: the Mac's bash 3.2 rejects an empty array expansion under
# `set -u`, and a hook that dies there would fail open with no line saying so.
accept=""
ps_has_override "$cmd" ACCEPT_BUNDLE_GROWTH && accept="--accept"

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# The record is keyed by the remote, never by the path: a worktree and its checkout are one
# repository with one bundle, and a repository that moves keeps its budget.
remote="$(git remote get-url origin 2>/dev/null)"
if [ -z "$remote" ]; then
  echo "bundle-budget: this repository has no origin remote to key a budget on, so the bundle weight was not judged.$(BUNDLE_BUDGET_STATE_DIR="${BUNDLE_BUDGET_STATE_DIR:-}" state_dir="${BUNDLE_BUDGET_STATE_DIR:-$HOME/.claude/state/bundle-budget}"; lifetime_note)"
  exit 0
fi

head_time="$(git log -1 --format=%ct 2>/dev/null)"
case "$head_time" in
  ''|*[!0-9]*)
    echo "bundle-budget: could not read HEAD's commit time, so whether the build is fresh is unknown and the bundle was not judged."
    exit 0 ;;
esac

state_dir="${BUNDLE_BUDGET_STATE_DIR:-$HOME/.claude/state/bundle-budget}"

# HOW MANY REPOSITORIES THIS GUARD HAS EVER WEIGHED, said on every push it does NOT weigh
# (claude-config#526). It shipped on 2026-09-18 and for three days the state directory did not
# exist on this Mac at all: every push had found no build, found a stale one, or never reached the
# measurer, and each of those printed a skip line indistinguishable from a working guard. A guard
# that has never once reached a verdict is measuring nothing while reading as installed (L557), and
# the count is the only thing that makes the zero visible.
#
# Not printed when the bundle WAS weighed: that line already says a verdict was reached, and a
# count repeated on every push is the noise a reader learns to skip (L36).
lifetime_note(){
  local n
  n="$(find "$state_dir" -name '*.txt' -type f 2>/dev/null | grep -c . || true)"
  case "${n:-0}" in
    0) printf ' This guard has never weighed any repository, so nothing here has ever been judged.' ;;
    1) printf ' This guard has weighed 1 repository ever.' ;;
    *) printf ' This guard has weighed %s repositories ever.' "$n" ;;
  esac
}

out="$(python3 "$HOOK_DIR/lib/bundle-budget.py" --repo "$repo_dir" --head-time "$head_time" \
  --remote "$remote" --state-dir "$state_dir" $accept 2>&1)"; rc=$?

case "$rc" in
  0)
    # A verdict was reached: a pass, a first record, an accepted or a recorded smaller total. One
    # line, on stdout, where a reader looking at the transcript finds it, and the push goes ahead.
    [ -n "$out" ] && printf '%s\n' "$out"
    exit 0 ;;
  4)
    # Nothing was weighed: no build output, a stale one, or a record that could not be read. The
    # push goes ahead, and the line carries how many repositories have ever been weighed.
    printf '%s%s\n' "${out:-bundle-budget: the bundle was not weighed.}" "$(lifetime_note)"
    exit 0 ;;
  2)
    {
      printf '%s\n' "$out"
      echo ""
      echo "Find what joined the client bundle (a dependency imported from a client component or"
      echo "the embed is the usual cause) and keep it off the hot path, then rebuild and push again."
      echo "OVERRIDE: if the growth is intended, record the new total and push with:"
      echo "    ACCEPT_BUNDLE_GROWTH=1 <your original git push command>"
      echo "To push without judging the bundle at all this once (nothing is recorded):"
      echo "    SKIP_BUNDLE_BUDGET_CHECK=1 <your original git push command>"
      echo "BEFORE overriding you MUST explain to the user, in plain non-technical language, WHY"
      echo "the growth is acceptable here, so they can judge whether it makes sense. Never"
      echo "override silently."
    } >&2
    exit 2 ;;
  *)
    echo "bundle-budget: the measurer could not run (exit $rc), so the bundle was not judged. It said: ${out:-nothing}$(lifetime_note)"
    exit 0 ;;
esac
