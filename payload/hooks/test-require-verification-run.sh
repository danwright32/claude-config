#!/usr/bin/env bash
#
# test-require-verification-run.sh: the merge check that requires a passing verification run per
# touched area (claude-config#1529), and verification-tally-notice.sh, the main session hook that
# asks Dan to switch a repository to block once its warn tally reaches its count.
#
# Every case runs the REAL hook with a fake `gh` first on PATH, so what is tested is the hook's own
# reading of GitHub's answers and its own words, not a rewrite of its logic here (L52). The judgment
# itself (merge_check.py) has its own cases in skills/verification-guides/scripts/test_merge_check.py;
# this suite proves every refusal reaches a person through the hook, and the hook's own: GitHub
# unreadable, the read budget running out, a missing interpreter, the override, and the no op on a
# repository whose base branch holds no areas.json, which is every repository today.
#
# The merge command is assembled from $MERGE rather than written out, because writing it literally
# makes this file trip the merge gates on the way in.

set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/require-verification-run.sh"
NOTICE="$HOOK_DIR/verification-tally-notice.sh"
SCRIPTS="$HOOK_DIR/../skills/verification-guides/scripts"
MERGE="gh pr me""rge"
# The override is the hook's own, and a test that inherited it from the shell would pass every case
# for the wrong reason.
unset ALLOW_UNVERIFIED_MERGE
# A sleep record that does not exist, so the notice hook is never silenced by this Mac really being
# asleep while the suite runs (lib/sleep.sh).
export CLAUDE_SLEEP_RECORD="/nonexistent/sleep-record.json"
unset CLAUDE_DETACHED_RUN

passed=0
failed=0
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }
denied() { local re='"permissionDecision": *"deny"'; [[ "$1" =~ $re ]]; }
says() {  # $1 = the hook output, $2 = a LITERAL needle
  [[ "$1" == *"$2"* ]]
}
expect_deny() {  # $1 = what, $2 = output, $3.. = needles
  local what="$1" out="$2" n; shift 2
  if ! denied "$out"; then fail "$what: not refused: ${out:0:400}"; return; fi
  for n in "$@"; do
    says "$out" "$n" || { fail "$what: the refusal does not say [$n]: ${out:0:600}"; return; }
  done
  pass
}
expect_allow() {  # $1 = what, $2 = output
  if [ -z "$2" ]; then pass; else fail "$1: wanted a silent allow, got: ${2:0:400}"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-vrun.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
HEAD="1111111111111111111111111111111111111111"
OLD="2222222222222222222222222222222222222222"
BASE="3333333333333333333333333333333333333333"

# The fake gh. Each answer is a file in $FAKE; a <name>.fail file makes that read fail with its text
# on stderr, and a <name>.flaky file fails it once with its text and then answers.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/log"
answer(){  # $1 = name
  if [ -f "$FAKE/$1.flaky" ]; then cat "$FAKE/$1.flaky" >&2; rm -f "$FAKE/$1.flaky"; exit 1; fi
  if [ -f "$FAKE/$1.fail" ]; then cat "$FAKE/$1.fail" >&2; exit 1; fi
  if [ -f "$FAKE/$1" ]; then cat "$FAKE/$1"; exit 0; fi
  echo 'gh: Not Found (HTTP 404)' >&2; exit 1
}
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*) answer view.json ;;
  *"contents/.claude/verification/areas.json"*) answer areas.json ;;
  *"contents/.claude/verification/guides/invoices.md"*) answer guide-invoices.md ;;
  *"contents/.claude/verification/guides/clients.md"*) answer guide-clients.md ;;
  *"/files"*) answer files.json ;;
  *"/comments"*) answer comments.json ;;
  *"/compare/"*) answer compare.json ;;
  *) echo "fake gh: no answer for: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$WORK/bin/gh"

# The fixtures are written by Python through verification.py's own constants, so a record or a
# receipt here has the shape the real writers give it.
cat > "$WORK/fixture.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SCRIPTS"])
import verification as v
fake, home, spec = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
HEAD, OLD, BASE = "1" * 40, "2" * 40, "3" * 40
GUIDE = ("# Invoices\n\n## Roles\nOwner.\n\n## Reach\n/invoices\n\n## State setup\nDemo.\n\n## Checks\n"
         "- [C1] The list shows every sent invoice.\n- [C2] Opening an invoice shows its total.\n"
         "- [C3] A draft can be sent.\n\n## Known traps\nNone.\n")
CHECKS = [("C1", "The list shows every sent invoice."), ("C2", "Opening an invoice shows its total."),
          ("C3", "A draft can be sent.")]
def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)
mode = spec.get("mode", "block")
areas = {"schema": "verification-areas/1", "mode": mode, "url": "http://127.0.0.1:4173",
         "commands": {"serve": "x", "ready": "true", "stop": "true", "drive": "x"},
         "areas": [{"name": "invoices", "guide": ".claude/verification/guides/invoices.md", "owns": ["src/invoices/**"]},
                   {"name": "clients", "guide": ".claude/verification/guides/clients.md", "owns": ["src/clients/**"]}],
         "exempt": [{"glob": "docs/**", "why": "documentation only"}]}
if spec.get("areas") != "absent":
    w(os.path.join(fake, "areas.json"), spec.get("areas_text") or json.dumps(areas))
w(os.path.join(fake, "guide-invoices.md"), GUIDE)
pr = spec.get("pr", 7)
w(os.path.join(fake, "view.json"), json.dumps({
    "number": pr, "url": "https://github.com/acme/widget/pull/%d" % pr, "headRefOid": HEAD, "baseRefOid": BASE,
    "baseRefName": "main", "body": "Fixes it.", "changedFiles": len(spec.get("files", ["src/invoices/list.ts"]))}))
w(os.path.join(fake, "files.json"), json.dumps([{"filename": f} for f in spec.get("files", ["src/invoices/list.ts"])]))
sha = OLD if spec.get("older") else HEAD
rid = "20261022T230000Z-%s-a1b2c3" % sha[:7]
rec = {"schema": "verification-run/1", "area": "invoices", "head_sha": sha, "receipt_id": rid,
       "machine": spec.get("record_machine") or v.machine_name(), "runner_agent_id": "agent-abc123",
       "checks": [dict({"id": c, "text": t, "result": "fail" if c in spec.get("fail", []) else "pass", "note": "seen"},
                       **({"blame": "code"} if c in spec.get("fail", []) else {})) for c, t in CHECKS],
       "done_when": [], "screenshots": [], "guide_edits": []}
body = "## Verification run\n```verification-run\n%s\n```\n" % json.dumps(rec, indent=2)
w(os.path.join(fake, "comments.json"), json.dumps([{"body": "LGTM"}] + ([] if spec.get("no_record") else [{"body": body}])))
w(os.path.join(fake, "compare.json"), json.dumps({"status": "ahead", "files": [{"filename": f} for f in spec.get("since", [])]}))
if not spec.get("no_receipt"):
    egress = {"verdict": "unmeasured", "why": "no egress monitor exists"} if spec.get("unmeasured") else {"verdict": "clean", "why": "measured"}
    w(os.path.join(home, "receipts", rid, "receipt.json"), json.dumps({
        "schema": "verification-receipt/1", "receipt_id": rid, "machine": v.machine_name(), "head_sha": sha,
        "checkout_sha": sha, "areas": ["invoices"], "stopped_at": "2026-10-22T23:10:00Z", "stopped_by": "stop",
        "build_stamp": sha, "build_stamp_source": "stamp-command", "egress": egress}))
    w(os.path.join(home, "receipts", rid, "drives.jsonl"), json.dumps({"area": "invoices", "exit": 0}) + "\n")
PY

N=0
setup() {  # $1 = fixture spec JSON ; sets FAKE, HOME_V and REPO for this case
  N=$((N + 1))
  FAKE="$WORK/case$N/fake"; HOME_V="$WORK/case$N/home"; REPO="$WORK/case$N/repo"
  mkdir -p "$FAKE" "$HOME_V" "$REPO"
  ( cd "$REPO" && git init -q && git remote add origin https://github.com/acme/widget.git )
  SCRIPTS="$SCRIPTS" python3 "$WORK/fixture.py" "$FAKE" "$HOME_V" "$1" || echo "  (fixture failed for case $N)"
}

payload() {  # $1 = command, $2 = cwd, $3 = extra JSON fields (with a leading comma) or empty
  python3 -c 'import json,sys; print(json.dumps(dict({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}, **json.loads(sys.argv[3] or "{}"))))' "$1" "$2" "${3:-}"
}

run_hook() {  # $1 = command ; extra env through the environment of the call
  payload "$1" "$REPO" | ( cd "$REPO" && PATH="$WORK/bin:$PATH" FAKE="$FAKE" VERIFICATION_HOME="$HOME_V" \
    VR_SLEEP="${VR_SLEEP:-true}" bash "$HOOK" )
}

echo "require-verification-run: a repository whose base branch holds no areas.json is untouched"
setup '{"areas": "absent"}'
out="$(run_hook "$MERGE 7 --squash")"; rc=$?
expect_allow "no areas.json at the base commit" "$out"
[ "$rc" = 0 ] && pass || fail "the no op exited $rc"
calls="$(grep -c . "$FAKE/log")"
# The whole cost of the no op: the pull request read once and the file looked for once at its base.
if [ "$calls" = 2 ] && grep -q "pr view" "$FAKE/log" && grep -q "areas.json?ref=$BASE" "$FAKE/log"; then pass
else fail "the no op asked gh $calls things, wanted the pull request and areas.json at $BASE: $(cat "$FAKE/log")"; fi

echo "require-verification-run: what is not a merge, and the override"
setup '{}'
out="$(run_hook "git status")"; expect_allow "a command that is not a merge" "$out"
out="$(run_hook "ALLOW_UNVERIFIED_MERGE=1 $MERGE 7 --squash")"; expect_allow "the visible override" "$out"
[ ! -s "$FAKE/log" ] && pass || fail "the override still read GitHub: $(cat "$FAKE/log")"
out="$(run_hook "$MERGE 7 --squash && $MERGE 8 --squash")"
expect_deny "a command merging two pull requests" "$out" "Cannot judge"

echo "require-verification-run: GitHub unreadable"
setup '{}'
printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$FAKE/view.json.fail"
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "the pull request cannot be read" "$out" "HTTP 403" "ALLOW_UNVERIFIED_MERGE=1"
setup '{}'
printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$FAKE/areas.json.fail"
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "areas.json at the base cannot be read" "$out" "areas.json" "HTTP 403"
setup '{}'
printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$FAKE/comments.json.fail"
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "the comments cannot be read, in block mode" "$out" "comments" "HTTP 403"

echo "require-verification-run: the read budget runs out (refuses)"
# The sleep is injected, so no case here waits on a real clock (L524), and the stub records every
# wait it was asked for, which a budget that has run out must never ask for.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/slept"\n' "$WORK" > "$WORK/sleep-stub"; chmod +x "$WORK/sleep-stub"
setup '{}'
printf 'Get "https://api.github.com/x": net/http: TLS handshake timeout\n' > "$FAKE/comments.json.fail"
: > "$WORK/slept"
out="$(VR_READ_BUDGET_SECONDS=0 VR_READ_RETRY_SECONDS=5 VR_SLEEP="$WORK/sleep-stub" run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "a transient failure with no budget left" "$out" "budget"
[ ! -s "$WORK/slept" ] && pass || fail "a retry was waited for past the budget: $(cat "$WORK/slept")"
setup '{}'
printf 'Get "https://api.github.com/x": net/http: TLS handshake timeout\n' > "$FAKE/view.json.fail"
out="$(VR_READ_BUDGET_SECONDS=0 VR_READ_RETRY_SECONDS=5 VR_SLEEP="$WORK/sleep-stub" run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "the pull request read times out with no budget left" "$out" "budget"
[ ! -s "$WORK/slept" ] && pass || fail "a retry was waited for past the budget: $(cat "$WORK/slept")"
setup '{}'
printf 'Get "https://api.github.com/x": net/http: TLS handshake timeout\n' > "$FAKE/comments.json.flaky"
out="$(VR_SLEEP="$WORK/sleep-stub" run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_allow "a read that fails once inside the budget is asked again and answers" "$out"

echo "require-verification-run: every refusal, in block mode"
setup '{}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_allow "a passing run at the head, clean egress, stamp and a drive" "$out"
setup '{"no_record": true}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "no record" "$out" "no verification-run record" "invoices" "ALLOW_UNVERIFIED_MERGE=1"
setup '{"fail": ["C2"]}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "a failing record" "$out" "fails C2"
setup '{"no_receipt": true}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "the receipt missing" "$out" "is not on this machine"
setup '{"record_machine": "Some-Other-Mac"}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "a receipt from another machine" "$out" "was run on Some-Other-Mac"
setup '{"files": ["src/invoices/list.ts", "src/billing/new.ts"]}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "an unowned file" "$out" "src/billing/new.ts is owned by no area"
setup '{"older": true, "since": ["src/invoices/list.ts"]}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "a stale record" "$out" "since then this pull request changed src/invoices/list.ts"
grep -q "compare/$OLD...$HEAD" "$FAKE/log" && pass || fail "the compare was not asked from the record's commit to the head: $(cat "$FAKE/log")"
setup '{"older": true, "files": ["src/invoices/list.ts", "docs/notes.md"], "since": ["docs/notes.md"]}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_allow "a record from an older commit whose later patch leaves the area alone" "$out"
setup '{"unmeasured": true}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "unmeasured egress is never clean" "$out" "egress as unmeasured"
setup '{}'
out="$(run_hook "$MERGE 7 --squash")"
expect_deny "an unpinned merge" "$out" "does not pin" "--match-head-commit $HEAD"
setup '{"areas_text": "{\"schema\": \"verification-areas/1\"}"}'
out="$(run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "a malformed areas.json on the base branch" "$out" "is malformed"

echo "require-verification-run: a missing interpreter is named"
. "$HOOK_DIR/lib/no-python-path.sh"
NOPY="$WORK/nopy"
npp_build_bin "$NOPY" jq
ln -s "$WORK/bin/gh" "$NOPY/gh"
if npp_reaches_python3 "$NOPY"; then fail "the premise: $NOPY still reaches python3"; else pass; fi
setup '{}'
# A repository's own merge tool, read by the shell, so nothing before the judge needs python3.
out="$(payload "./scripts/merge-when-green.sh 7" "$REPO" | ( cd "$REPO" && PATH="$NOPY" FAKE="$FAKE" VERIFICATION_HOME="$HOME_V" "$NOPY/bash" "$HOOK" ))"
expect_deny "no python3" "$out" "python3 is not on PATH"
setup '{}'
out="$(VR_SCRIPTS="$WORK/no-such-scripts" run_hook "$MERGE 7 --squash --match-head-commit $HEAD")"
expect_deny "the judge itself missing" "$out" "$WORK/no-such-scripts/merge_check.py"

echo "require-verification-run: warn mode allows, says the verdict, and tallies it by pull request"
for pr in 1 2 3 4 5; do
  setup "{\"mode\": \"warn\", \"unmeasured\": true, \"pr\": $pr}"
  # One receipt home across the five, as on a real Mac.
  rm -rf "$HOME_V"; HOME_V="$WORK/warn-home"
  SCRIPTS="$SCRIPTS" python3 "$WORK/fixture.py" "$FAKE" "$HOME_V" "{\"mode\": \"warn\", \"unmeasured\": true, \"pr\": $pr}"
  out="$(run_hook "$MERGE $pr --squash --match-head-commit $HEAD")"
  if denied "$out"; then fail "warn mode refused PR $pr: ${out:0:300}"; continue; fi
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
  if says "$ctx" "warn mode" && says "$ctx" "would be refused" && says "$ctx" "egress as unmeasured"; then pass
  else fail "warn mode's verdict for PR $pr did not reach the session: ${out:0:400}"; fi
done
lines="$(cat "$HOME_V/merge-tally/acme/widget.jsonl" 2>/dev/null | grep -c .)"
[ "$lines" = 5 ] && pass || fail "the tally holds $lines lines, wanted 5"
says "$ctx" "5 pull requests judged" && pass || fail "the last verdict does not count the tally: $ctx"

echo "verification-tally-notice: the count reached raises the switch to block picker, in the main session only"
notice() {  # $1 = extra payload JSON or empty
  # A guard that leaves before reading stdin closes the pipe on the writer, which is the hook doing
  # its job, so the writer's broken pipe is not reported.
  payload "ls" "$REPO" "${1:-}" 2>/dev/null | VERIFICATION_HOME="$HOME_V" bash "$NOTICE"
}
out="$(notice '{"agent_id": "abc"}')"
expect_allow "a subagent is never asked to raise a picker" "$out"
out="$(CLAUDE_DETACHED_RUN=1 notice)"
expect_allow "a headless run has nobody to ask" "$out"
out="$(notice)"
reason="$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)"
if [ "$(printf '%s' "$out" | jq -r '.decision // ""' 2>/dev/null)" = block ] && says "$reason" "AskUserQuestion" \
   && says "$reason" "acme/widget" && says "$reason" "Switch to block" && says "$reason" "egress-unmeasured"; then pass
else fail "the notice did not ask for the picker with the tally: ${out:0:500}"; fi
says "$reason" "Recommended: Keep warn" && pass || fail "with every refusal unmeasured egress, keeping warn is not what it recommends: $reason"
out="$(notice)"
expect_allow "asked once, then quiet until five more pull requests" "$out"
rm -rf "$WORK/empty-home"; mkdir -p "$WORK/empty-home"
out="$(payload "ls" "$REPO" "" | VERIFICATION_HOME="$WORK/empty-home" bash "$NOTICE")"
expect_allow "no tally at all" "$out"

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
