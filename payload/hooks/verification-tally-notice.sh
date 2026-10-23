#!/usr/bin/env bash
#
# verification-tally-notice.sh
# Claude Code PostToolUse(Bash) hook (claude-config#1529): once a repository's warn tally has grown by
# verification.py's TALLY_ASK_EVERY pull requests since Dan was last asked, ask the MAIN session to
# put the switch to block question to him as a picker, with what the tally saw.
#
# require-verification-run.sh allows every merge in a repository whose areas.json says `mode: warn`,
# and appends its verdict to that repository's tally, keyed by pull request. Warn mode exists to
# watch real merges before anything blocks (L56), and a tally nobody reads is the counter that is not
# a detector (L357), so this is what reads it. Keyed on the STATE reached (the tally's count against
# the count last asked at), never on a merge having just happened, so a count reached in a subagent
# or through merge-when-ready.sh is still asked about here (L247).
#
# Guards:
#   agent_id in the payload     a subagent has nobody to ask; the main session's payload carries none
#   CLAUDE_DETACHED_RUN set     a headless run has nobody to ask
#   asleep (sleep mode)         nobody is there; it is asked after wake, with nothing marked
#   no tally folder             no repository has been judged in warn mode: leaves before python
# Each question is marked asked by verification.py at the count it was asked at, so it comes again
# only after that many more pull requests, never on every tool call.
#
# Fails QUIET: anything it cannot read exits 0 with no output, since a notice that cannot be read
# costs one late question, and this hook runs after every Bash call in every session.
#
# Seams: VERIFICATION_HOME (verification.py), VR_SCRIPTS (the skill's scripts folder), CLAUDE_SLEEP_RECORD
# (lib/sleep.sh).

set -uo pipefail

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0
payload="$(cat 2>/dev/null || true)"
case "$payload" in *'"agent_id"'*) exit 0 ;; esac

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALLY_DIR="${VERIFICATION_HOME:-$HOME/.claude-verification}/merge-tally"
[ -d "$TALLY_DIR" ] || exit 0

if . "$HOOK_DIR/lib/sleep.sh" 2>/dev/null && sleep_active; then
  exit 0
fi

command -v python3 >/dev/null 2>&1 || exit 0
SCRIPTS="${VR_SCRIPTS:-$HOOK_DIR/../skills/verification-guides/scripts}"
[ -f "$SCRIPTS/verification.py" ] || exit 0

# Read without marking: the question is marked asked only once it has been handed over below, so a
# failure building it costs a repeat, never a lost question.
due="$(python3 "$SCRIPTS/verification.py" tally due 2>/dev/null)" || exit 0
[ -n "$due" ] || exit 0

reason="$(printf '%s' "$due" | python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import verification as v
due = json.load(sys.stdin)
if not due:
    sys.exit(0)
parts = []
for d in due:
    kinds = ", ".join("%s %d" % (k, n) for k, n in sorted(d["kinds"].items(), key=lambda kv: -kv[1])) or "none"
    if d["refused"] == 0:
        rec = "Recommended: Switch to block, since every one of them would have passed."
    elif d["kinds"].get("egress-unmeasured"):
        rec = ("Recommended: Keep warn, since %d of them carried egress-unmeasured, which nothing can clear until an"
               " egress monitor exists, so block mode would refuse every merge." % d["kinds"]["egress-unmeasured"])
    else:
        rec = "Recommended: Keep warn, since %d of them would have been refused." % d["refused"]
    parts.append(
        "%s: %d pull requests judged in warn mode, %d would have passed and %d would have been refused (by reason: %s). %s"
        % (d["repo"], d["prs"], d["passed"], d["refused"], kinds, rec))
print("The verification merge check has watched enough merges to ask about block mode. " + " ".join(parts) +
      " Ask Dan now with one AskUserQuestion picker per repository, before anything else, with the recommended option"
      " first and marked: \"Switch to block\" (merges in that repository are then refused until every area they"
      " touch has a passing verification run at the merge head; the switch is setting \"mode\" to \"block\" in"
      " .claude/verification/areas.json through a pull request in that repository) and \"Keep warn\" (asked again"
      " after %d more pull requests). Put the numbers above in the question. Make no change for Keep warn."
      % v.TALLY_ASK_EVERY)
' "$SCRIPTS" 2>/dev/null)" || exit 0
[ -n "$reason" ] || exit 0

out="$(python3 -c 'import json, sys; print(json.dumps({"decision": "block", "reason": sys.argv[1]}))' "$reason" 2>/dev/null)" || exit 0
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
python3 "$SCRIPTS/verification.py" tally due --mark >/dev/null 2>&1 || true
exit 0
