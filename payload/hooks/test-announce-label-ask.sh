#!/usr/bin/env bash
# announce-label-ask.sh: a session's ordinary command to put the changelog/announce label on a pull
# request is refused until Dan has approved the wording (claude-config#3666, R10), and the record of
# what he approved is not a session's to write.
#
# The hook is a wrapper around announce_label_gate.py, which holds the rule, the commands it reads and
# its messages, so every case here drives that file through the wrapper, as Claude Code does.
#
# Every case runs the REAL hook with a fake gh first on PATH, in a repository of its own with a
# GitHub remote, and with the record in a folder of the suite's own (ANNOUNCE_APPROVALS_DIR), never
# this Mac's real one. Every repository here is invented.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/announce-label-ask.sh"
ENTRY="$DIR/lib/changelog-entry.js"
LABEL="changelog/announce"
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (${2:0:700})"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no announce-label-ask.sh beside this suite at $DIR, so nothing refuses the announce label on wording Dan has not approved"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$DIR/lib/announce-approval-fixture.sh" 2>/dev/null && declare -F aaf_talk >/dev/null || {
  echo "FAIL: lib/announce-approval-fixture.sh is missing beside this suite, so no session could be built"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
REAL_STORE="${CLAUDE_HOME:-$HOME/.claude}/state/announce-approvals"
real_before="$(ls -la "$REAL_STORE" 2>/dev/null | cksum)"
# Named as the real one is, so a shell command naming the record names it here too.
STORE="$WORK/state/announce-approvals"
REPO="$WORK/repo"
mkdir -p "$REPO" "$WORK/bin"
( cd "$REPO" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
POST='@here
**Handing a call back**

You can now hand a call back to the queue.

- Press Hand back
- Pick a reason'
BODY="Why.

## Changelog
Agents can now hand a call back to the queue.

## Announcement
$POST

## Testing
ran it"
printf '%s\n' "$BODY" > "$REPO/body.md"
# What GitHub holds for pull request 7, which the fake gh answers with: FAKE_BODY names the file.
printf '%s\n' "$BODY" > "$WORK/github-body.md"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account someone (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    [ -z "${FAKE_SLOW:-}" ] || sleep "$FAKE_SLOW"
    [ -n "${FAKE_BODY:-}" ] || { printf 'no pull requests found\n' >&2; exit 1; }
    python3 -c 'import json, sys; print(json.dumps({"number": 7, "url": "https://github.com/acme/widget/pull/7", "body": open(sys.argv[1]).read()}))' "$FAKE_BODY" ;;
  *) printf 'the fake gh was asked something this suite never answers: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$WORK/bin/gh"

hash_text() { printf '%s' "$1" | node "$ENTRY" announcement-hash | python3 -c 'import json, sys; print(json.load(sys.stdin)["hash"])'; }
H="$(hash_text "$POST")"
# approve [repo]: Dan's approval of POST for that repository, as a line on the suite's record.
approve() { mkdir -p "$STORE"; printf '{"kind": "approved", "repo": "%s", "hash": "%s"}\n' "${1:-acme/widget}" "$H" >> "$STORE/record.jsonl"; }
forget() { rm -rf "$STORE"; }
# call <tool> <tool input json> [cwd]: the hook's answer, as "<decision> rc=<exit>|<reason>|<notice>".
# TALK names a session transcript to carry (session s1); AGENT=1 makes the call a subagent's.
call() {
  local body rc
  body="$(python3 -c 'import json, os, sys
d = {"hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2]), "cwd": sys.argv[3], "session_id": "s1",
     "transcript_path": os.environ.get("TALK") or (sys.argv[3] + "/no-transcript.jsonl")}
if os.environ.get("AGENT") == "1":
    d["agent_id"] = "a9bba4c0ffee"
print(json.dumps(d))' "$1" "$2" "${3:-$REPO}" \
    | ( cd "${3:-$REPO}" && PATH="$WORK/bin:$PATH" FAKE_BODY="${FAKE_BODY-$WORK/github-body.md}" ANNOUNCE_APPROVALS_DIR="$STORE" bash "$HOOK" 2>"$WORK/stderr" ))"; rc=$?
  printf '%s' "$body" | python3 -c '
import json, sys
t = sys.stdin.read().strip()
try:
    d = json.loads(t) if t else {}
except Exception:
    print("badjson rc=" + sys.argv[1] + "|" + t[:300] + "|", end=""); sys.exit()
h = d.get("hookSpecificOutput") or {}
print(h.get("permissionDecision", "none") + " rc=" + sys.argv[1] + "|" + h.get("permissionDecisionReason", "") + "|" + d.get("systemMessage", ""), end="")' "$rc"
}
# run <command> [cwd]: the hook's answer before that Bash call runs.
run() { call Bash "$(python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1")" "${2:-}"; }
refused() { [[ "$1" == "deny rc=0|"* ]]; }
passed() { [[ "$1" == "none rc=0||" ]]; }
# asks_dan <answer>: a refusal that tells the session to ask him with the picker, and is no question.
asks_dan() { refused "$1" && [[ "$1" == *"AskUserQuestion"* && "$1" == *"Approve the wording"* && "$1" == *"--front-window"* ]]; }

echo "the label goes on only wording Dan approved (R10)"

EDIT="gh pr edit 7 --add-label $LABEL"
r="$(run "$EDIT")"
check "R10 the label added to a pull request whose wording Dan has not approved is refused" "$(asks_dan "$r" && echo ok || echo "$r")"
check "the refusal names the repository and that he has not approved this wording" "$([[ "$r" == *"Dan has not approved this wording for acme/widget"* ]] && echo ok || echo "$r")"
check "it is a refusal, never a question a permission prompt could answer" "$([[ "$r" != ask* ]] && echo ok || echo "$r")"
approve
r="$(run "$EDIT")"
check "R10 still possible: the same command goes through once he has approved the wording" "$(passed "$r" && echo ok || echo "$r")"
# The wording on GitHub edited since: other wording, refused again.
printf '%s\n' "${BODY/Pick a reason/Pick any reason}" > "$WORK/edited-body.md"
r="$(FAKE_BODY="$WORK/edited-body.md" run "$EDIT")"
check "R10 the label on wording edited since he approved is refused" "$(asks_dan "$r" && echo ok || echo "$r")"
# A description with no Announcement block has no wording to approve.
printf 'Why.\n\n## Changelog\nA sentence.\n' > "$WORK/no-block.md"
r="$(FAKE_BODY="$WORK/no-block.md" run "$EDIT")"
check "the label on a description with no Announcement block is refused, saying so" "$(refused "$r" && [[ "$r" == *"no \`## Announcement\` block"* ]] && echo ok || echo "$r")"
# GitHub gives no answer: the wording it would leave cannot be read.
r="$(FAKE_BODY="" run "$EDIT")"
check "the label where the description cannot be read from GitHub is refused, saying so" "$(refused "$r" && [[ "$r" == *"could not be read from GitHub"* && "$r" == *"--body-file"* ]] && echo ok || echo "$r")"
# A GitHub that does not answer is refused in the hook's own words at its own bound (shortened here
# so no case waits on a clock), and the gh left running does not hold the hook open.
began=$SECONDS
r="$(FAKE_SLOW=30 ANNOUNCE_LABEL_GITHUB_SECONDS=1 run "$EDIT")"
check "a GitHub that does not answer is refused at the hook's own bound, saying so" "$(refused "$r" && [[ "$r" == *"did not answer in 1 seconds"* && "$r" == *"--body-file"* ]] && echo ok || echo "$r")"
check "and the hook does not wait on the gh it left behind" "$([ $((SECONDS - began)) -lt 12 ] && echo ok || echo "took $((SECONDS - began)) seconds")"
forget

# Every ordinary spelling of the same thing.
for cmd in "gh pr edit 7 --add-label=$LABEL" "gh pr edit 7 --add-label bug,$LABEL" "gh pr edit 7 --add-label Changelog/Announce" \
           "gh pr edit --add-label $LABEL" "gh pr edit https://github.com/acme/widget/pull/7 --add-label $LABEL" \
           "gh pr edit 7 -R acme/widget --add-label $LABEL" "gh issue edit 7 --add-label $LABEL" \
           "cd $REPO && gh pr edit 7 --add-label $LABEL" "bash -c 'gh pr edit 7 --add-label $LABEL'" \
           "gh api repos/acme/widget/issues/7/labels -f 'labels[]=$LABEL'" "gh api --method POST /repos/{owner}/{repo}/issues/7/labels -f labels[]=$LABEL" \
           "gh api repos/acme/widget/issues/7/labels --input - <<< '{\"labels\": [\"$LABEL\"]}'"; do
  r="$(run "$cmd")"
  check "R10 refused until he approves: $cmd" "$(asks_dan "$r" && echo ok || echo "$r")"
  approve
  r="$(run "$cmd")"
  check "R10 still possible once he has: $cmd" "$(passed "$r" && echo ok || echo "$r")"
  forget
done

echo "the wording a create or an edit would leave is read from the command"
CREATE="gh pr create --title T --label $LABEL"
for cmd in "$CREATE --body-file body.md" "$CREATE --body-file $REPO/body.md" "$CREATE -F body.md" "gh pr new -t T -l $LABEL -F body.md" \
           "gh pr create -t T -dl $LABEL -F body.md" \
           "gh pr edit 7 --add-label $LABEL --body-file body.md"; do
  r="$(FAKE_BODY="$WORK/edited-body.md" run "$cmd")"
  check "R10 refused until he approves: $cmd" "$(asks_dan "$r" && echo ok || echo "$r")"
  approve
  r="$(FAKE_BODY="$WORK/edited-body.md" run "$cmd")"
  check "R10 still possible once he has, read from the file and not from GitHub: $cmd" "$(passed "$r" && echo ok || echo "$r")"
  forget
done
approve
# The description in single quotes, its lines as they are: a shell reads no \n inside any quotes.
r="$(run "$CREATE --body '$BODY'")"
check "still possible: a description given with --body whose wording he approved" "$(passed "$r" && echo ok || echo "$r")"
r="$(run "$CREATE --body '${BODY/Pick a reason/Pick any reason}'")"
check "R10 a description given with --body whose wording he has not approved is refused" "$(asks_dan "$r" && [[ "$r" == *"Dan has not approved this wording for acme/widget"* ]] && echo ok || echo "$r")"
# A form the wording cannot be read from is refused with the form to use, approved or not.
for cmd in "$CREATE --fill" "$CREATE" "$CREATE --body-file -" "cat body.md | $CREATE -F -" "$CREATE --template bug.md" \
           "printf 'x' > body.md && $CREATE --body-file body.md" "$CREATE --body-file \$BODY_FILE_NOBODY_SET" \
           "gh pr edit 7 8 --add-label $LABEL"; do
  r="$(run "$cmd")"
  check "a form the wording cannot be read from is refused with the form to use: $cmd" "$(refused "$r" && [[ "$r" == *"--body-file <file>"* || "$r" == *"one pull request"* ]] && echo ok || echo "$r")"
done
# An edit whose own description cannot be read (empty, or opening with a dash, which reads as a flag)
# is never judged by what GitHub holds now, since the command replaces that.
for cmd in "gh pr edit 7 --add-label $LABEL --body-file=" \
           "gh pr edit 7 --add-label $LABEL --body ''" "gh pr edit 7 --add-label $LABEL --body '- one
## Announcement
other wording'" "gh pr edit 7 --add-label $LABEL -b ''" "gh pr edit 7 --add-label $LABEL --body-file ''"; do
  r="$(run "$cmd")"
  check "an edit whose own description cannot be read is refused, approved wording on GitHub or not: ${cmd:0:60}" "$(refused "$r" && [[ "$r" == *"--body-file <file>"* && "$r" != *"has no \`## Announcement\`"* ]] && echo ok || echo "$r")"
done
# An empty description glued to its flag (--body=, -b=) IS read: the command would leave an empty
# description, so the refusal says what is true of it, that it leaves no Announcement block, and the
# approved wording GitHub holds now does not carry it through.
for cmd in "gh pr edit 7 --add-label $LABEL --body=" "gh pr edit 7 --add-label $LABEL -b="; do
  r="$(run "$cmd")"
  check "an edit that empties the description is refused, saying it leaves no Announcement block, approved wording on GitHub or not: $cmd" "$(refused "$r" && [[ "$r" == *"the description it would leave has no \`## Announcement\` block"* ]] && echo ok || echo "$r")"
done
# The label added after another write in the same call: what GitHub holds now is not what it would sit on.
for cmd in "gh pr edit 7 --body-file body.md && gh pr edit 7 --add-label $LABEL" "gh api -X PATCH repos/acme/widget/pulls/7 -f body=x; gh pr edit 7 --add-label $LABEL" \
           "gh pr edit 7 --add-label $LABEL && gh issue edit 7 --body other"; do
  r="$(run "$cmd")"
  check "the label added beside another GitHub write in one call is refused, saying to give it a command of its own: $cmd" "$(refused "$r" && [[ "$r" == *"a command of its own"* ]] && echo ok || echo "$r")"
done
# Each command putting the label on is judged by reads of its own, so one call holds one of them:
# the hook's time is then bounded whatever the call holds.
for cmd in "$CREATE --body-file body.md && gh pr create --title U --label $LABEL --body-file body.md" \
           "$CREATE --body-file body.md; gh pr edit 7 --add-label $LABEL --body-file body.md" \
           "gh api repos/acme/widget/issues/7/labels -f 'labels[]=$LABEL' && gh api repos/acme/widget/issues/8/labels -f 'labels[]=$LABEL'"; do
  r="$(run "$cmd")"
  check "a call putting the label on in more than one command is refused, saying one per command: ${cmd:0:70}" "$(refused "$r" && [[ "$r" == *"in more than one command"* && "$r" == *"gh pr edit <number> --add-label $LABEL"* ]] && echo ok || echo "$r")"
done
r="$(run "gh pr view 7 --json labels && gh pr edit 7 --add-label $LABEL")"
check "still possible: the label added after a command that only reads" "$(passed "$r" && echo ok || echo "$r")"
# A repository that cannot be told is no place to look an approval up for.
mkdir -p "$WORK/norepo"; cp "$REPO/body.md" "$WORK/norepo/body.md"
r="$(run "$CREATE --body-file body.md" "$WORK/norepo")"
check "a create whose repository cannot be told is refused, saying to name it" "$(refused "$r" && [[ "$r" == *"--repo owner/name"* ]] && echo ok || echo "$r")"
r="$(run "$CREATE --body-file body.md --repo acme/widget" "$WORK/norepo")"
check "and goes through, approved, once it names the repository" "$(passed "$r" && echo ok || echo "$r")"
# His approval for one repository puts the label on nothing in another.
r="$(run "$CREATE --body-file body.md --repo acme/other" "$WORK/norepo")"
check "R10 his approval for one repository approves no label in another" "$(asks_dan "$r" && echo ok || echo "$r")"
forget

echo "his answer in this session's picker counts, and is kept"
F="$(aaf_shown "$WORK/wording" "$WORK/talk.jsonl" "$POST")"
r="$(TALK="$WORK/talk.jsonl" run "$EDIT")"
check "R10 wording opened in front of him and not yet approved is refused" "$(asks_dan "$r" && echo ok || echo "$r")"
aaf_talk "$WORK/talk.jsonl" ask acme/widget "$F"
r="$(TALK="$WORK/talk.jsonl" AGENT=1 run "$EDIT")"
check "a subagent's command counts his picker for that call" "$(passed "$r" && echo ok || echo "$r")"
check "and writes nothing to the record" "$([ ! -e "$STORE/record.jsonl" ] && echo ok || cat "$STORE/record.jsonl")"
r="$(TALK="$WORK/talk.jsonl" run "$EDIT")"
check "R10 still possible: the command goes through on his picker in this session" "$(passed "$r" && echo ok || echo "$r")"
check "and his approval is written to the record" "$(grep -q "\"hash\": \"$H\"" "$STORE/record.jsonl" 2>/dev/null && echo ok || echo "no line")"
r="$(run "$EDIT")"
check "so a later session's command goes through on the record" "$(passed "$r" && echo ok || echo "$r")"
forget
# The picker's question must tell him to save the file (#3742 item 7): an edit he left unsaved in
# the window is not in the wording that is hashed, so his Approve in a picker that does not say so
# puts the label on nothing.
F="$(aaf_shown "$WORK/nosave" "$WORK/nosave.jsonl" "$POST")"
aaf_talk "$WORK/nosave.jsonl" ask acme/widget "$F" "" nosave
r="$(TALK="$WORK/nosave.jsonl" run "$EDIT")"
check "R10 his Approve in a picker whose question does not tell him to save the file puts no label on" "$(asks_dan "$r" && [[ "$r" == *"did not tell him to save the file"* ]] && echo ok || echo "$r")"
check "and nothing is written to the record for it" "$(! grep -q '"kind": "approved"' "$STORE/record.jsonl" 2>/dev/null && echo ok || cat "$STORE/record.jsonl")"
aaf_talk "$WORK/nosave.jsonl" bash "$AAF_BBEDIT --front-window $F"
aaf_talk "$WORK/nosave.jsonl" ask acme/widget "$F"
r="$(TALK="$WORK/nosave.jsonl" run "$EDIT")"
check "R10 still possible: asked again with the sentence, the command goes through" "$(passed "$r" && echo ok || echo "$r")"
forget
# An Approve with words typed beside it approves nothing (#3742 low 20; Dan, 2026-11-26): what he
# typed is a change he wants, so the label goes on nothing and the refusal gives his words.
F="$(aaf_shown "$WORK/typed" "$WORK/typed.jsonl" "$POST")"
aaf_talk "$WORK/typed.jsonl" ask acme/widget "$F" "" "typed:approve, but fix line 2"
r="$(TALK="$WORK/typed.jsonl" run "$EDIT")"
check "R10 his Approve with words typed beside it puts no label on, and the refusal gives his words" "$(asks_dan "$r" && [[ "$r" == *"approve, but fix line 2"* && "$r" == *"approves nothing"* ]] && echo ok || echo "$r")"
check "and no approval is written to the record for it" "$(! grep -q '"kind": "approved"' "$STORE/record.jsonl" 2>/dev/null && echo ok || cat "$STORE/record.jsonl")"
aaf_talk "$WORK/typed.jsonl" bash "$AAF_BBEDIT --front-window $F"
aaf_talk "$WORK/typed.jsonl" ask acme/widget "$F"
r="$(TALK="$WORK/typed.jsonl" run "$EDIT")"
check "R10 still possible: asked again and approved with nothing typed, the command goes through" "$(passed "$r" && echo ok || echo "$r")"
forget

echo "one approval covers one pull request (Dan, 2026-11-25: \"One approval, one pull request\")"
# Pull request 7 merged on his one approval of this wording: the merge gate recorded it as the one
# that used it. The label still goes on pull request 7, however the command names it, and on no
# other pull request, nor on one not yet made, until he approves the wording again.
approve
printf '{"kind": "used", "repo": "acme/widget", "hash": "%s", "pr": 7, "claim": true, "closes": null}\n' "$H" >> "$STORE/record.jsonl"
for cmd in "gh pr edit 7 --add-label $LABEL" "gh pr edit --add-label $LABEL" "gh pr edit 7 --add-label $LABEL --body-file body.md" \
           "gh pr edit https://github.com/acme/widget/pull/7 --add-label $LABEL --body-file body.md" \
           "gh issue edit 7 --add-label $LABEL --body-file body.md" "gh api repos/acme/widget/issues/7/labels -f 'labels[]=$LABEL'"; do
  r="$(run "$cmd")"
  check "still possible: the label goes on the pull request that used his approval: $cmd" "$(passed "$r" && echo ok || echo "$r")"
done
for cmd in "$CREATE --body-file body.md" "gh pr edit 8 --add-label $LABEL --body-file body.md" \
           "gh pr edit https://github.com/acme/widget/pull/8 --add-label $LABEL --body-file body.md" \
           "gh pr edit some-branch --add-label $LABEL --body-file body.md"; do
  r="$(run "$cmd")"
  check "R10 the label on another pull request with the same wording is refused, and asks him again: $cmd" "$(asks_dan "$r" && [[ "$r" == *"pull request 7 used that approval"* && "$r" == *"one approval covers one pull request"* && "$r" != *"Dan has not approved"* ]] && echo ok || echo "$r")"
done
r="$(run "$CREATE --body-file body.md")"
check "a command naming no pull request by number is told so" "$([[ "$r" == *"names no pull request by number"* ]] && echo ok || echo "$r")"
# Approved a second time, the same wording goes on a second pull request.
printf '{"kind": "approved", "repo": "acme/widget", "hash": "%s", "session": "s0", "picker": "toolu_second"}\n' "$H" >> "$STORE/record.jsonl"
for cmd in "$CREATE --body-file body.md" "gh pr edit 8 --add-label $LABEL --body-file body.md"; do
  r="$(run "$cmd")"
  check "still possible: approved a second time, the wording goes on a second pull request: $cmd" "$(passed "$r" && echo ok || echo "$r")"
done
# The label hook only asks: the use of an approval is recorded at the merge, never here.
check "the label hook records no use of an approval" "$([ "$(grep -c '"kind": "used"' "$STORE/record.jsonl")" = 1 ] && [ "$(wc -l < "$STORE/record.jsonl" | tr -d ' ')" = 3 ] && echo ok || cat "$STORE/record.jsonl")"
forget

echo "commands that put the label on no pull request"
for cmd in "gh pr edit 7 --remove-label $LABEL" "gh pr view 7 --json labels | grep $LABEL" "gh pr list --label $LABEL" \
           "git commit -m 'explain $LABEL'" "grep -rn $LABEL payload/" "gh pr edit 7 --body 'relabel to $LABEL later'" \
           "gh label edit $LABEL --color ff0000" "gh api repos/acme/widget/labels/$LABEL" \
           "gh api -X DELETE repos/acme/widget/issues/7/labels/$LABEL" "gh pr edit 7 --add-label changelog/visible --remove-label $LABEL" \
           "gh pr create --help | grep $LABEL" "echo 'gh pr edit 7 --add-label $LABEL'"; do
  r="$(run "$cmd")"
  check "not refused, since it puts the label on nothing: $cmd" "$(passed "$r" && echo ok || echo "$r")"
done

echo "the label itself"
# Making the label in a repository puts it on no pull request, so there is no wording to read and
# nothing to approve: it always goes through (Dan, 2026-11-25: "Always allow it"). The merge gate
# still holds that an announcement merges only on wording he approved.
for cmd in "gh label create $LABEL --color 82D0FF" "gh label create $LABEL -R acme/widget" "gh api repos/acme/widget/labels -f name=$LABEL -f color=82D0FF" \
           "gh label clone acme/other --repo acme/widget # brings $LABEL" "gh api repos/acme/widget/labels --input - <<< '{\"name\": \"$LABEL\"}'" \
           "gh label create $LABEL && gh label create changelog/visible"; do
  r="$(run "$cmd")"
  check "making the label needs no approval: $cmd" "$(passed "$r" && echo ok || echo "$r")"
done
# Renaming another label onto it puts it on every pull request carrying that one, with no wording
# read for any of them, so it is refused whatever is approved. So is a write this hook cannot place.
approve
for cmd in "gh label edit changelog/visible --name $LABEL" "gh api -X PATCH repos/acme/widget/labels/changelog/visible -f new_name=$LABEL" \
           "gh api -X PATCH repos/acme/widget/issues/7 -f 'labels[]=$LABEL'" \
           "gh api graphql -f query='mutation { addLabelsToLabelable(input: {labelableId: \"PR_x\", labelIds: [\"$LABEL\"]}) { clientMutationId } }'"; do
  r="$(run "$cmd")"
  check "refused with the form to use, whatever is approved: $cmd" "$(refused "$r" && [[ "$r" == *"gh pr edit <number> --add-label $LABEL"* ]] && echo ok || echo "$r")"
done
forget

echo "a command this hook cannot read"
r="$(run "gh pr edit 7 --add-label $LABEL --title 'unclosed")"
check "a command it cannot read that names the label and a gh write is refused" "$(refused "$r" && [[ "$r" == *"could not read this command"* ]] && echo ok || echo "$r")"
r="$(run "echo 'unclosed $LABEL")"
check "a command it cannot read that runs no gh write passes" "$(passed "$r" && echo ok || echo "$r")"
# Making the label needs no approval, so a command it cannot read that only makes it passes too,
# and one that may rename another label onto it is still refused.
for cmd in "gh label create $LABEL --description 'unclosed" "gh label clone acme/other --repo acme/widget # $LABEL 'unclosed"; do
  r="$(run "$cmd")"
  check "a command it cannot read that only makes the label passes: $cmd" "$(passed "$r" && echo ok || echo "$r")"
done
r="$(run "gh label edit bug --name $LABEL --description 'unclosed")"
check "a command it cannot read that may rename a label onto it is refused" "$(refused "$r" && [[ "$r" == *"could not read this command"* ]] && echo ok || echo "$r")"
# A payload that is not a call: refused when it names the label, naming the payload, and passed otherwise.
cut_payload() { printf '%s' "$1" | ( cd "$REPO" && PATH="$WORK/bin:$PATH" ANNOUNCE_APPROVALS_DIR="$STORE" bash "$HOOK" 2>&1 ); printf ' rc=%s' "$?"; }
r="$(cut_payload '{"tool_name": "Bash", "tool_input": {"command": "gh pr edit 7 --add-label changelog/announce"}')"
check "a payload it cannot parse that names the label is refused, naming the payload" "$([[ "$r" == *"payload"*" rc=2" ]] && echo ok || echo "$r")"
# GitHub reads a label's name in any letter case, so the words of such a payload are read so too.
r="$(cut_payload '{"tool_name": "Bash", "tool_input": {"command": "gh pr edit 7 --add-label CHANGELOG/ANNOUNCE"}')"
check "a payload it cannot parse that names the label in capitals is refused, naming the payload" "$([[ "$r" == *"payload"*" rc=2" ]] && echo ok || echo "$r")"
check "and that refusal names the label as a person writes it, never as the pattern that matched it" "$([[ "$r" == *"rc=2" && "$r" != *"[Cc]"* && "$r" != *"[Aa]"* ]] && echo ok || echo "$r")"
r="$(cut_payload '{"tool_name": "Bash", "tool_input": {"command": "gh pr edit 7 --add-label changelog\/announce"}')"
check "a payload it cannot parse that names the label with the slash JSON escaped is refused, naming the payload" "$([[ "$r" == *"payload"*" rc=2" ]] && echo ok || echo "$r")"
r="$(cut_payload '{"tool_name": "Write", "tool_input": {"file_path": "/tmp/x/state/announce-approvals/record.jsonl"')"
check "a payload it cannot parse that names the record is refused, naming the payload" "$([[ "$r" == *"payload"*" rc=2" ]] && echo ok || echo "$r")"
r="$(cut_payload '{"tool_name": "Write", "tool_input": {"file_path": "/tmp/x/STATE/Announce-Approvals/record.jsonl"')"
check "a payload it cannot parse that names the record in other capitals is refused, naming the payload" "$([[ "$r" == *"payload"*" rc=2" ]] && echo ok || echo "$r")"
r="$(cut_payload '{"tool_name": "Bash", "tool_input": {"command": "ls -la"}')"
check "a payload it cannot parse that names nothing it judges passes" "$([[ "$r" == " rc=0" ]] && echo ok || echo "$r")"

# The wrapper with its rule file gone: a gate that did not run is not one that found nothing (L98).
mkdir -p "$WORK/broken"
cp "$HOOK" "$WORK/broken/announce-label-ask.sh"
ln -s "$DIR/lib" "$WORK/broken/lib"
broken() { python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2], "session_id": "s1"}))' "$1" "$REPO" \
  | ( cd "$REPO" && PATH="$WORK/bin:$PATH" ANNOUNCE_APPROVALS_DIR="$STORE" bash "$WORK/broken/announce-label-ask.sh" 2>&1 ); printf ' rc=%s' "$?"; }
r="$(broken "$EDIT")"
check "with its rule file gone, a command naming the label is refused, saying the gate did not run" "$([[ "$r" == *"announce-label-ask.sh failed"*"could not be checked"*" rc=2" ]] && echo ok || echo "$r")"
r="$(broken "ls -la")"
check "and a command naming neither the label nor the record still passes" "$([[ "$r" == " rc=0" ]] && echo ok || echo "$r")"
# The first test knows the library that writes the record by its file name (claude-config#3703): a
# command running it names neither the label nor the record's folder, and left at the first test.
r="$(broken "python3 $DIR/lib/announce-approval.py used --repo acme/widget --hash $H --pr 7")"
check "R2 with its rule file gone, a command running the library that writes the record is judged, so refused" "$([[ "$r" == *"announce-label-ask.sh failed"*"could not be checked"*" rc=2" ]] && echo ok || echo "$r")"
r="$(cut_payload '{"tool_name": "Bash", "tool_input": {"command": "python3 lib/Announce-Approval.py used --repo acme/widget"}')"
check "R2 a payload it cannot parse that names the library is refused, naming the payload" "$([[ "$r" == *"payload"*" rc=2" ]] && echo ok || echo "$r")"

# The hook's first test matches in any letter case, and that setting is the test's alone: a library
# it loads afterwards must find the shell matching as it always does. The stand in library here
# writes down what it found and then fails to load, which the hook refuses by name.
mkdir -p "$WORK/leak/lib"
cp "$HOOK" "$WORK/leak/announce-label-ask.sh"
printf 'shopt -q nocasematch && printf on > "$LEAK_SEEN"\nprintf loaded >> "$LEAK_SEEN.ran"\nreturn 1\n' > "$WORK/leak/lib/push-scope.sh"
r="$(printf '%s' '{"tool_name": "Bash", "tool_input": {"command": "gh pr edit 7 --add-label Changelog/Announce"}}' | LEAK_SEEN="$WORK/leak/seen" bash "$WORK/leak/announce-label-ask.sh" 2>&1; printf ' rc=%s' "$?")"
check "a library that will not load is refused by name" "$([[ "$r" == *"could not load"*"push-scope.sh"*" rc=2" ]] && [ -e "$WORK/leak/seen.ran" ] && echo ok || echo "$r")"
check "the first test's match in any letter case is not left on for the libraries the hook loads" "$([ ! -e "$WORK/leak/seen" ] && echo ok || echo "nocasematch was still on when lib/push-scope.sh was loaded")"

echo "the record of what he approved is not a session's to write"
mkdir -p "$STORE"; printf '' > "$STORE/record.jsonl"
for tool in Write Edit MultiEdit; do
  r="$(call "$tool" "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1], "content": "x", "old_string": "a", "new_string": "b", "edits": []}))' "$STORE/record.jsonl")")"
  check "R2 a $tool of the record is refused" "$(refused "$r" && [[ "$r" == *"only his own answer in the picker adds to it"* ]] && echo ok || echo "$r")"
done
r="$(call Write "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1], "content": "x"}))' "$STORE/another.jsonl")")"
check "R2 a Write of a new file under the record's folder is refused" "$(refused "$r" && echo ok || echo "$r")"
# A Mac's disk reads a path in any letter case, so the record's folder spelled in other capitals is
# the same folder there. The guard compares without case on every disk: on one that does tell the
# two apart it refuses a folder that is not the record, which costs a rename and risks nothing.
other_case="$(dirname "$(dirname "$STORE")")/$(basename "$(dirname "$STORE")" | tr '[:lower:]' '[:upper:]')/$(basename "$STORE" | tr '[:lower:]' '[:upper:]')/record.jsonl"
for tool in Write Edit; do
  r="$(call "$tool" "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1], "content": "x", "old_string": "a", "new_string": "b"}))' "$other_case")")"
  check "R2 a $tool of the record named in other capitals is refused" "$([ "$other_case" != "$STORE/record.jsonl" ] && refused "$r" && [[ "$r" == *"only his own answer in the picker adds to it"* ]] && echo ok || echo "$other_case: $r")"
done
r="$(call Write "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1], "content": "the record is at state/announce-approvals"}))' "$WORK/notes.md")")"
check "a Write elsewhere that only mentions the record passes" "$(passed "$r" && echo ok || echo "$r")"
for cmd in "printf '{\"kind\": \"approved\"}' >> $STORE/record.jsonl" "cd $WORK/state && cp /dev/null announce-approvals/record.jsonl" \
           "python3 -c 'open(\"$STORE/record.jsonl\", \"a\").write(\"x\")'" "rm -rf $STORE" "tee $STORE/record.jsonl < /dev/null"; do
  r="$(run "$cmd")"
  check "R2 a shell command naming the record that is not one only reading it is refused: $cmd" "$(refused "$r" && [[ "$r" == *"is not one that only reads it"* ]] && echo ok || echo "$r")"
done
for cmd in "cat $STORE/record.jsonl" "ls -la $STORE" "grep -rn announce-approvals payload/" "rg -n announce-approvals payload/" "git grep -n announce-approvals"; do
  r="$(run "$cmd")"
  check "a command only reading the record, or its name, passes: $cmd" "$(passed "$r" && echo ok || echo "$r")"
done

echo "the library that writes the record is not a session's to run to write (#3703)"
# The review's first finding: a session wrote a file shaped like a transcript, holding a picker
# nobody was shown, and ran the library's own command line with a payload naming it. The library
# wrote his approval to the record. That command names neither the label nor the record's folder,
# so this hook never judged it. It now refuses a Bash command that runs the library in any form but
# the two that only read: `list`, and `check` without --claim.
LIBRARY="$DIR/lib/announce-approval.py"
mkdir -p "$WORK/forged"
printf '%s\n' "$POST" > "$WORK/forged/post.md"
aaf_new "$WORK/forged/talk.jsonl"
aaf_talk "$WORK/forged/talk.jsonl" bash "$AAF_BBEDIT --front-window $WORK/forged/post.md"
aaf_talk "$WORK/forged/talk.jsonl" ask acme/widget "$WORK/forged/post.md"
FORGED="printf '{\"session_id\":\"s1\",\"transcript_path\":\"$WORK/forged/talk.jsonl\"}'"
forget
for cmd in "$FORGED | python3 $LIBRARY check --repo acme/widget --hash $H --pr 7 --claim" \
           "$FORGED | python3 -B ~/.claude/hooks/lib/announce-approval.py check --claim --repo acme/widget --hash $H" \
           "python3 $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "printf '{}' | python3 $LIBRARY answered" \
           "cd $DIR && /usr/bin/python3 -B -I lib/announce-approval.py used --repo acme/widget --hash $H --pr 7 --unread x" \
           "env ANNOUNCE_APPROVALS_DIR=/tmp/other python3 $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "$FORGED | xargs -0 python3 $LIBRARY check --claim" \
           "find $WORK/forged -name post.md -exec python3 $LIBRARY used --repo acme/widget --hash $H --pr 7 \\;" \
           "nice -n 5 caffeinate -i python3 $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "sudo -u root python3 $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "env -u ANNOUNCE_APPROVALS_DIR python3 $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "echo acme/widget | xargs -I {} python3 $LIBRARY used --repo {} --hash $H --pr 7" \
           "env -u ANNOUNCE_APPROVALS_DIR $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "nohup $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "python3 -BX utf8 $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "python3 -Ic 'import runpy, sys; sys.dont_write_bytecode = True; runpy.run_path(\"$LIBRARY\", run_name=\"__main__\")'" \
           "python3 -B -c\"import runpy; runpy.run_path('$LIBRARY', run_name='__main__')\"" \
           "python3 -Bm runpy $LIBRARY used" \
           "python3 -B --check-hash-based-pycs default $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "echo python3 $LIBRARY used --repo acme/widget --hash $H --pr 7 | sudo -u root sh" \
           "bash -c 'python3 $LIBRARY used --repo acme/widget --hash $H --pr 7'" \
           "chmod +x $LIBRARY && $LIBRARY used --repo acme/widget --hash $H --pr 7" \
           "python3 $LIBRARY \"\$VERB\" --repo acme/widget --hash $H" \
           "python3 $LIBRARY" \
           "python3 -B -c 'import runpy, sys; sys.argv = [\"x\", \"used\"]; runpy.run_path(\"$LIBRARY\", run_name=\"__main__\")'" \
           "python3 -m runpy $LIBRARY used"; do
  r="$(run "$cmd")"
  check "R2 a command that runs the library to write, or in a form that cannot be told from one, is refused: ${cmd:0:150}" "$(refused "$r" && [[ "$r" == *"runs lib/announce-approval.py"* ]] && echo ok || echo "$r")"
done
check "R2 and none of them wrote the record" "$([ ! -e "$STORE/record.jsonl" ] && echo ok || cat "$STORE/record.jsonl")"
r="$(run "$FORGED | python3 $LIBRARY check --repo acme/widget --hash $H --pr 7 --claim")"
check "the refusal says only a hook writes his approval, the forms that read, and how to ask him" "$([[ "$r" == *"only a hook writes"*"announce-approval.py list"*"without --claim"*"AskUserQuestion"* ]] && echo ok || echo "$r")"
# A program on standard input that names the library is not a command this hook can read.
r="$(run "python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location('a', '$LIBRARY')
PY")"
check "R2 a program on standard input that names the library is refused, saying where it is named" "$(refused "$r" && [[ "$r" == *"a heredoc body"* ]] && echo ok || echo "$r")"
# Still possible: the two forms that only read, and every command that names the file without
# running it.
for cmd in "python3 ~/.claude/hooks/lib/announce-approval.py list" \
           "python3 -B $LIBRARY check --repo acme/widget --hash $H" \
           "sudo -u root python3 -BX utf8 $LIBRARY list" \
           "python3 -Bm py_compile $LIBRARY" \
           "python3 $LIBRARY check --repo acme/widget --hash $H --pr 7 | python3 -m json.tool" \
           "git add payload/hooks/lib/announce-approval.py" \
           "git diff HEAD -- payload/hooks/lib/announce-approval.py" \
           "grep -n 'def check' $LIBRARY" \
           "grep -n python3 $LIBRARY" \
           "rg -n python3 payload/hooks/lib/announce-approval.py payload/hooks/require-changelog-tag.sh" \
           "wc -l $LIBRARY && sed -n 1,20p $LIBRARY" \
           "python3 -m py_compile $LIBRARY" \
           "bash $DIR/test-announce-approval.sh" \
           "gh issue comment 12 --body 'lib/announce-approval.py check no longer writes'" \
           "cp $LIBRARY $WORK/copy.py"; do
  r="$(run "$cmd")"
  check "still possible: a command that reads through the library, or names its file without running it, passes: ${cmd:0:110}" "$(passed "$r" && echo ok || echo "$r")"
done

echo "an ordinary call costs nothing and says nothing"
r="$(run "ls -la")"
check "a command naming neither the label nor the record passes" "$(passed "$r" && echo ok || echo "$r")"
r="$(call Write "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1], "content": "x"}))' "$WORK/plain.md")")"
check "a Write naming neither passes" "$(passed "$r" && echo ok || echo "$r")"

echo "his answer about announcing a feature is read into the record before the milestone helper runs (#3669)"
# The helper reads the record only, so the hook that sees the call running it reads his picker in.
HELPER_CALL="bash ~/.claude/skills/milestone/create-milestone.sh acme/widget /tmp/plan.json"
decided_lines() { local n; n="$(grep -c '"kind": "decided"' "$STORE/record.jsonl" 2>/dev/null)"; printf '%s' "${n:-0}"; }
forget
D="$WORK/deciding.jsonl"; aaf_new "$D"
aaf_talk "$D" decide acme/widget "Hand back"
r="$(TALK="$D" run "ls -la")"
check "a call that does not run the helper reads nothing in" "$(passed "$r" && [ "$(decided_lines)" = 0 ] && echo ok || echo "$r $(decided_lines) lines")"
r="$(TALK="$D" AGENT=1 run "$HELPER_CALL")"
check "a subagent's call running the helper passes and writes nothing" "$(passed "$r" && [ "$(decided_lines)" = 0 ] && echo ok || echo "$r $(decided_lines) lines")"
r="$(TALK="$D" run "$HELPER_CALL")"
check "a call running the helper passes, with nothing said" "$(passed "$r" && echo ok || echo "$r")"
check "and his answer in this session's picker is on the record before it runs" "$([ "$(decided_lines)" = 1 ] && grep -q '"answer": "yes"' "$STORE/record.jsonl" && echo ok || cat "$STORE/record.jsonl" 2>/dev/null)"
r="$(TALK="$D" run "$HELPER_CALL")"
check "run again, it writes no second line" "$(passed "$r" && [ "$(decided_lines)" = 1 ] && echo ok || echo "$r $(decided_lines) lines")"
# What stands between his answer and the record is said beside the call, which still runs.
aaf_talk "$D" decide acme/widget "Hand over" "Not announcing" prefilled
r="$(TALK="$D" run "$HELPER_CALL")"
check "a picker that was never put to him is said beside the call, to Dan and the session" "$([[ "$r" == "none rc=0||"*"Hand over"*"already filled in"* ]] && echo ok || echo "$r")"
# One job per call: a call that also names the label is judged for the label alone, inside the time
# the hook is registered with, and reads no answer in.
forget
r="$(TALK="$D" run "$HELPER_CALL; echo $LABEL")"
check "a call running the helper that also names the label reads nothing in" "$([ "$(decided_lines)" = 0 ] && echo ok || echo "$r $(decided_lines) lines")"
r="$(broken "$HELPER_CALL")"
check "with its rule file gone, a call running the helper is refused, saying the hook did not run" "$([[ "$r" == *"announce-label-ask.sh failed"*" rc=2" ]] && echo ok || echo "$r")"

echo "the record is this suite's own"
check "no case wrote to this Mac's real record" "$([ "$(ls -la "$REAL_STORE" 2>/dev/null | cksum)" = "$real_before" ] && echo ok || echo "$REAL_STORE changed during the run")"

echo "  $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
