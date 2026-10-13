#!/usr/bin/env bash
# Tests for feature-issue-review.sh and the instruction it now points at.
#
# The 8,000 character instruction used to live inside this hook as a JSON heredoc.
# It moved to review/issue-review.md (claude-config#243) because a Stop hook's
# `reason` is printed to Dan verbatim, so everything addressed to Claude was landing
# on his screen. The rules did not change; where they live did.
#
# What has to be checked did not change either. The instruction is the ONLY carrier
# of a set of rules that were each got wrong in practice, and a silent drop brings
# the original problem straight back, so each is asserted individually. The JSON
# parse check moved with them: the hook still holds one hand written JSON payload,
# the fallback it emits when the pointer cannot be built, and an unescaped quote
# there makes Claude Code drop the hook with nothing in the transcript to say so.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/feature-issue-review.sh"
INSTRUCTION="$DIR/review/issue-review.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-issue-review.XXXXXX")" || exit 2
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
WORK="$(cd "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT
# The temp directory this suite was STARTED with, kept so the end of the file can prove that
# nothing the hook writes landed there (claude-config#1019).
REAL_TMPDIR="${TMPDIR:-/tmp}"
# Every file the hook under test writes (the findings, each session's stamp, the cooldown and muted
# stamps) goes under $TMPDIR, and this suite left them all in the real one, one set per throwaway
# project per run (claude-config#1019). Pointed at this run's own directory, the way
# test-subagent-issue-harvest.sh already does, so the hook still computes the names it computes in
# production and the trap above reclaims the lot (L2).
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

# Pinned to a throwaway spool, so this suite is structurally unable to write into
# the real one (L2). A sibling suite did exactly that 120 times before it was noticed.
export CLAUDE_ISSUE_SPOOL_DIR="$WORK/spool"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"

pass=0
fail=0
check() { # check <description> <ok|why-not>
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

# --- the instruction file has to exist, or the review points at nothing ---
[ -f "$INSTRUCTION" ] \
  && check "the instruction file exists" ok \
  || check "the instruction file exists" "nothing at $INSTRUCTION"

instruction="$(cat "$INSTRUCTION" 2>/dev/null)"

# --- the rules the instruction is the only carrier of ---
# Each of these exists because it was got wrong in practice.
needs=(
  "MILESTONE AND PRIORITY"          # both axes required on every issue
  "priority-p0"                     # the scale is spelled out, not assumed
  "priority-p2"
  "priority-p4"
  "[p2, tech-debt, NEW Backlog grouping, moves #241 #242]"  # a new milestone is SHOWN as new, with what it moves
  "Ungrouped"                       # the catch-all is still offered
  "milestone-candidates.sh"         # the backlog is READ before a milestone is chosen
  "READ THE TITLES"                 # the score ranks the shortlist, the reader decides (#265)
  "DUPLICATE-RISK"                  # an idea that already exists is not filed again
  "CLOSE-MATCH"                     # and one whose title shares nothing still has to be read
  "CHECK THOSE BEFORE FILING"       # which only works if the lines are actually read
  "2 OR MORE issues would go into it at once"  # the bar for opening a new milestone
  "--create-approved"               # which only happens after Dan selects it
  "--for-issues <n>"                # and the cluster size is stated, because the script now enforces it
  "gh issue edit"                   # and the siblings actually get moved
  "plan-council"                    # planning a feature still belongs there
  "ensure-priority-labels.sh"       # how to make the labels exist
  "severity:*"                      # the retired scale is named as retired
  "NAMING.md"                       # points at the shared rule
  "AskUserQuestion"                 # the picker, not prose
  "claude-suggested"                # the forbidden attribution label
  "EVERY area label that genuinely applies"  # labels are many per issue, not one
  "STARTING POINT, not a closed set"         # the vocabulary is guidance, not a cage
  "gh label list"                            # read the repo's own labels first
  "data-integrity"                           # the area vocabulary is actually listed
  "ISSUE REVIEW"                             # the banner it has to open with
  "SECOND PASS"                              # the reflection folds in here
  "TO FILE THESE"                            # the clear command the render wrote (#287)
  "Run that line, verbatim"                  # and it is run as it stands, not reconstructed
  "do NOT drop any of its arguments"         # its last one is the stamp of what was read (#381)
  "THESE cannot be filed from this review"   # a render with no stamp has nothing to run (#381)
  "harvested after the review was rendered"  # and a clear that left late arrivals needs nothing (#381)
)
# --- and the wording it must NOT carry any more ---------------------------
# The rule that ad hoc filing may never open a milestone was REVERSED on 2026-09-02,
# after Dan opened his list and found Ungrouped holding 98 issues in this repo, 157
# in bidspoke and 102 in new-agent-onboarding, with obvious clusters inside them. The
# assertion that used to guard the old rule is deleted rather than adjusted: its whole
# content was the decision being reversed, so keeping it in any form would leave a
# test defending the behaviour that was removed (L252).
#
# These two are the wording that CAUSED the pile-up. The ban itself, and the sentence
# that primed every idea toward the holding pen before it had even been looked at.
#
# The third is the clear command as a FIXED line (claude-config#287). It passed no session
# transcript, so it keyed on the git common dir while the render that produced the findings keyed
# on the transcript's directory, and the two agreed only when those roots coincided. The render now
# writes the command it means, so any fixed form here is a second derivation of the same key and
# the exact failure over again (L70, L285). Matched on the whole invocation rather than on the
# words, so the prose explaining why it is gone does not answer for it (L135).
forbidden=(
  "NEVER create a new milestone"
  "Most of these ideas are standalone fixes"
  "there is no third option"
  "issue-spool.sh clear \"\$PWD\""
)
for gone in "${forbidden[@]}"; do
  if [[ "$instruction" != *"$gone"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: the instruction should no longer carry '$gone'"
  fi
done

for want in "${needs[@]}"; do
  if [[ "$instruction" == *"$want"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: the instruction should still carry '$want'"
  fi
done

# --- the instruction must obey the writing rule it enforces ---
# It tells Claude never to use dashes as punctuation, and it once used 17 em dashes
# doing so. A rule contradicted by the prose around it loses to the demonstration
# (L270). The characters are BUILT rather than written, because a file holding one
# literally is what the pre push style hook blocks, and it cannot tell a line banning
# the character from a line using it.
emdash="$(printf '\xe2\x80\x94')"
endash="$(printf '\xe2\x80\x93')"
if [[ "$instruction" != *"$emdash"* && "$instruction" != *"$endash"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: the instruction contains an em or en dash, which the style rule forbids"
fi

# --- the hook's fallback payload has to be valid JSON ---
# It is the one hand written JSON left in the hook. An unescaped quote there is
# invisible: Claude Code drops the hook and the review simply stops happening.
result="$(python3 - "$HOOK" <<'PY'
import json, re, sys

src = open(sys.argv[1]).read()
blocks = re.findall(r"cat <<'JSON'\n(.*?)\nJSON", src, re.S)
if not blocks:
    print("no JSON heredoc found, so the fallback payload is missing")
    sys.exit(0)
for block in blocks:
    try:
        payload = json.loads(block)
    except Exception as exc:
        print("JSON does not parse: %s" % exc)
        sys.exit(0)
    if payload.get("decision") != "block":
        print("decision should be 'block', got %r" % payload.get("decision"))
        sys.exit(0)
    if not (payload.get("reason") or "").strip():
        print("reason is empty")
        sys.exit(0)
print("ok")
PY
)"
check "the hook's fallback payload is valid JSON with a block decision and a reason" "$result"

# ---------------------------------------------------------------------------
# The spool wiring: what the review does with findings that are waiting.
# ---------------------------------------------------------------------------
TRANSCRIPT="$WORK/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"t1","input":{}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
} > "$TRANSCRIPT"

# Every project a review ran for, so the end of the file can look for their files. A FILE, because
# run_review is called inside $(...), and a subshell's additions to an array never reach this one.
REVIEWED="$WORK/reviewed-projects.list"; : > "$REVIEWED"
run_review() { # run_review <project dir>
  printf '%s\n' "$1" >> "$REVIEWED"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TRANSCRIPT" | \
    CLAUDE_PROJECT_DIR="$1" bash "$HOOK"
}
# The findings file a review's reason points at.
named_in() {
  printf '%s' "$1" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
'
}
# The command on the line after TO FILE THESE in a findings file, exactly as written.
clear_line_of() { awk 'f { sub(/^  /, ""); print; exit } /^TO FILE THESE/ { f = 1 }' "$1" 2>/dev/null; }
# Whether <text> holds <needle>, and whether it holds <line> as a whole line. Matched in the shell
# rather than through `producer | grep -q`, which leaves on its first match and kills the producer, so
# under pipefail a match can report as a failure (test-pipefail-shortcircuit.sh).
holds() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
has_line() { case "
$1
" in *"
$2
"*) return 0 ;; esac; return 1; }
reason_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("NO PAYLOAD AT ALL")
    sys.exit(0)
try:
    print(json.loads(raw).get("reason") or "")
except Exception as exc:
    print("PAYLOAD DOES NOT PARSE: %s" % exc)
'
}

# An EMPTY spool must not produce a findings pointer. A reason that always names a
# file leaves Claude opening a stale one, and a stale findings file reads exactly
# like findings that are still waiting.
EMPTY_PROJ="$(mktemp -d "$WORK/empty.XXXXXX")"
reason="$(reason_of "$(run_review "$EMPTY_PROJ")")"
[[ "$reason" != *"SUBAGENT FINDINGS"* ]] \
  && check "an empty spool produces no findings pointer" ok \
  || check "an empty spool produces no findings pointer" "[$reason]"

# A spool holding a finding must produce a pointer at a file that HOLDS that
# finding. Checked by reading the file the reason names, not by trusting that one
# was written: a pointer at an empty or missing file is the failure worth catching.
FIND_PROJ="$(mktemp -d "$WORK/withfindings.XXXXXX")"
MARKER="the widget cache is never invalidated on rename"
bash "$DIR/lib/issue-spool.sh" note "$FIND_PROJ" "$MARKER" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason="$(reason_of "$(run_review "$FIND_PROJ")")"

[[ "$reason" == *"SUBAGENT FINDINGS"* ]] \
  && check "a pending finding produces a findings pointer" ok \
  || check "a pending finding produces a findings pointer" "[$reason]"

[[ "$reason" == *"1 finding"* ]] \
  && check "the pointer counts the one pending finding" ok \
  || check "the pointer counts the one pending finding" "[$reason]"

named="$(printf '%s' "$reason" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
[ -s "$named" ] \
  && check "the findings file the pointer names exists and is not empty" ok \
  || check "the findings file the pointer names exists and is not empty" "nothing at [$named]"

grep -qF "$MARKER" "$named" 2>/dev/null \
  && check "the findings file holds the finding that was spooled" ok \
  || check "the findings file holds the finding that was spooled" "[$named] does not contain it"

# The finding must SURVIVE the review. Reading does not consume the spool: a review
# that is read and then interrupted has to leave the finding for the next one, and
# only `clear` (after the picker is answered) files it away.
bash "$DIR/lib/issue-spool.sh" has-findings "$FIND_PROJ" "$TRANSCRIPT" >/dev/null 2>&1 \
  && check "the finding is still pending after the review carried it" ok \
  || check "the finding is still pending after the review carried it" "the spool no longer holds it"

# ---------------------------------------------------------------------------
# A finding an open issue already covers arrives WITH the issue number (claude-config#256).
# ---------------------------------------------------------------------------
# On 2026-09-01 eight read only agents audited every open issue in one repo. The harvest spooled
# their observations, another session's review offered them as fresh findings, and four were filed:
# each a twin of the issue the agent had been READING, closed as a duplicate within the hour. The
# harvest cannot know a problem is already tracked; the review can look.
MATCH_PROJ="$(mktemp -d "$WORK/matching.XXXXXX")"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers the one question the matcher asks, and records that it was asked.
printf '%s\n' "$*" >> "$GH_CALLS"
cat "$GH_ISSUES"
STUB
chmod +x "$WORK/bin/gh"
export GH_CALLS="$WORK/gh-calls.log"; : > "$GH_CALLS"
export GH_ISSUES="$WORK/issues.json"
cat > "$GH_ISSUES" <<'JSON'
[{"number": 412, "title": "The widget cache is never invalidated in widget/cache.py",
  "body": "widget/cache.py keeps a stale entry after a rename."},
 {"number": 998, "title": "Something else entirely",
  "body": "About other/thing.py and nothing to do with the above."}]
JSON
bash "$DIR/lib/issue-spool.sh" note "$MATCH_PROJ" \
  "widget/cache.py keeps a stale cache entry when a widget is renamed" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason="$(PATH="$WORK/bin:$PATH" reason_of "$(PATH="$WORK/bin:$PATH" run_review "$MATCH_PROJ")")"
named="$(printf '%s' "$reason" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
# The stub really was asked, or everything below is satisfied by a matcher that never ran (L100).
grep -q "issue list" "$GH_CALLS" 2>/dev/null \
  && check "#256 the review asks for the open issues" ok \
  || check "#256 the review asks for the open issues" "gh was never called: $(cat "$GH_CALLS" 2>/dev/null)"
grep -q "already #412" "$named" 2>/dev/null \
  && check "#256 a finding an open issue already covers carries that issue's number" ok \
  || check "#256 a finding an open issue already covers carries that issue's number" "file=$(awk 'NR <= 3' "$named" 2>/dev/null)"
grep -q "already #998" "$named" 2>/dev/null \
  && check "#256 and an unrelated open issue is not attached to it" "it named #998 as well" \
  || check "#256 and an unrelated open issue is not attached to it" ok

# A finding naming a file NO open issue mentions gets nothing, or the annotation says nothing and
# would talk somebody out of filing a real finding (L159).
NOMATCH_PROJ="$(mktemp -d "$WORK/nomatch.XXXXXX")"
bash "$DIR/lib/issue-spool.sh" note "$NOMATCH_PROJ" \
  "unrelated/module.py drops its error on the floor" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason_nm="$(PATH="$WORK/bin:$PATH" reason_of "$(PATH="$WORK/bin:$PATH" run_review "$NOMATCH_PROJ")")"
named_nm="$(printf '%s' "$reason_nm" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
# Asked of the LINE, not of the file. Every note here shares one transcript, so they share one
# spool key and one pending list: a file-wide grep is answered by the annotated finding above and
# says nothing about this one (L135, and it did exactly that).
_nm_line="$(grep 'unrelated/module.py' "$named_nm" 2>/dev/null || true)"
case "$_nm_line" in
  "") check "#256 a finding no open issue covers is left alone" "the finding is not in the file at all" ;;
  *"already #"*) check "#256 a finding no open issue covers is left alone" "it was annotated: $_nm_line" ;;
  *) check "#256 a finding no open issue covers is left alone" ok ;;
esac

# And it FAILS OPEN. This is a convenience on a review, and losing it must never cost the review.
FAILOPEN_PROJ="$(mktemp -d "$WORK/failopen.XXXXXX")"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: not logged in" >&2
exit 1
STUB
chmod +x "$WORK/bin/gh"
FAILMARK="widget/cache.py still drops the rename"
bash "$DIR/lib/issue-spool.sh" note "$FAILOPEN_PROJ" "$FAILMARK" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason_fo="$(PATH="$WORK/bin:$PATH" reason_of "$(PATH="$WORK/bin:$PATH" run_review "$FAILOPEN_PROJ")")"
named_fo="$(printf '%s' "$reason_fo" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
grep -qF "$FAILMARK" "$named_fo" 2>/dev/null \
  && check "#256 a gh that refuses leaves the findings going out unannotated" ok \
  || check "#256 a gh that refuses leaves the findings going out unannotated" "file=[$named_fo] $(awk 'NR <= 2' "$named_fo" 2>/dev/null)"
# And SAYS it could not look. Failing open is right; failing open in silence makes an unannotated
# list indistinguishable from a list with no duplicates in it (L10, L11).
grep -q "OPEN ISSUES NOT READ" "$named_fo" 2>/dev/null \
  && check "#256 and says the open issues could not be read" ok \
  || check "#256 and says the open issues could not be read" "file=[$named_fo]"
# The control: a run that COULD read them says nothing of the kind.
grep -q "OPEN ISSUES NOT READ" "$named" 2>/dev/null \
  && check "#256 and a run that read them says nothing about it" "it claimed it could not read them" \
  || check "#256 and a run that read them says nothing about it" ok

# The matcher on its own, by name. Driving it only through the review would leave its own refusals
# untested, and the coverage ratchet is right that a file no suite names is a file nobody checks.
MATCHER="$DIR/lib/match-open-issues.py"
matcher_out() { # matcher_out <findings text>   -> the annotated text
  printf '%s\n' "$1" | PATH="$WORK/bin:$PATH" python3 "$MATCHER" "$WORK" 2>/dev/null
}
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
cat "$GH_ISSUES"
STUB
chmod +x "$WORK/bin/gh"
mo="$(matcher_out 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename')"
case "$mo" in
  *"already #412"*) check "#256 the matcher on its own attaches the issue that names the same file" ok ;;
  *) check "#256 the matcher on its own attaches the issue that names the same file" "out=$mo" ;;
esac
# A finding naming NO file is left alone whatever words it shares. Title words alone produced false
# siblings twice in the milestone helper, always claiming a cluster that was not there (#265).
mo_nofile="$(matcher_out 'FINDING (a, b): the widget cache is never invalidated on rename')"
case "$mo_nofile" in
  *"already #"*) check "#256 a finding naming no file is never matched on words alone" "out=$mo_nofile" ;;
  *) check "#256 a finding naming no file is never matched on words alone" ok ;;
esac
# A shared file and no shared word is two findings that mention one file, not one subject.
mo_pathonly="$(matcher_out 'FINDING (a, b): widget/cache.py should log its eviction reason')"
case "$mo_pathonly" in
  *"already #412"*) check "#256 a shared path with no shared subject word is not a match" "out=$mo_pathonly" ;;
  *) check "#256 a shared path with no shared subject word is not a match" ok ;;
esac
# The PROJECT DIRECTORY IS NOT ALWAYS THE CHECKOUT (claude-config#344). In PET the workspace root
# is one level above the repo, so `gh issue list` run there refused with "not a git repository" and
# the matcher fell back to its honest OPEN ISSUES NOT READ line. Failing open was right, but the
# effect was that the duplicate check had never once run in that project: every review there judged
# duplicates with no sight of the backlog, which is the condition #265 was written about, and the
# notice reads as a footnote rather than as "this whole review was blind".
#
# This gh REFUSES outside a checkout, the way the real one does, so a matcher that did not resolve
# the repo cannot pass. It gets its own bin directory rather than overwriting the stub above, which
# the cases before this one still depend on.
mkdir -p "$WORK/bin-pet"
cat > "$WORK/bin-pet/gh" <<'STUB'
#!/usr/bin/env bash
if [ ! -e .git ]; then
  echo "fatal: not a git repository (or any of the parent directories): .git" >&2
  exit 1
fi
cat "$GH_ISSUES"
STUB
chmod +x "$WORK/bin-pet/gh"
PET_ROOT="$(mktemp -d "$WORK/pet.XXXXXX")"
mkdir -p "$PET_ROOT/pet/.git"
mo_pet="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$PET_ROOT" 2>/dev/null)"
case "$mo_pet" in
  *"already #412"*) check "#344 a project whose checkout is one level down is still matched" ok ;;
  *) check "#344 a project whose checkout is one level down is still matched" "out=$mo_pet" ;;
esac
case "$mo_pet" in
  *"OPEN ISSUES NOT READ"*) check "#344 and it does not report itself blind" "out=$mo_pet" ;;
  *) check "#344 and it does not report itself blind" ok ;;
esac
# TWO checkouts under one project directory: it must not pick one (claude-config#346). Reading
# another repository's open issues would put THAT repository's issue numbers beside these findings,
# and a wrong "already #N" is the one outcome this whole matcher is built to avoid, because it
# would talk somebody out of filing a real finding.
AMBIG_ROOT="$(mktemp -d "$WORK/ambig.XXXXXX")"
mkdir -p "$AMBIG_ROOT/alpha/.git" "$AMBIG_ROOT/beta/.git"
mo_ambig="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$AMBIG_ROOT" 2>/dev/null)"
case "$mo_ambig" in
  *"already #"*) check "#346 a project directory holding two checkouts is never matched" "out=$mo_ambig" ;;
  *) check "#346 a project directory holding two checkouts is never matched" ok ;;
esac
# And it says WHY, naming the ambiguity rather than reporting gh's complaint about a directory
# that is not a repository, which is true and is a different fault with a different remedy (L11).
case "$mo_ambig" in
  *"more than one checkout"*) check "#346 and says which fault stopped it looking" ok ;;
  *) check "#346 and says which fault stopped it looking" "out=$mo_ambig" ;;
esac
# The same two children under a project that IS a checkout, as a git WORKTREE, where `.git` is a
# file (claude-config#402). The helper's rule is that the directory itself wins whatever its children
# look like, and it tests for `.git` with `-e`. The matcher re-checked with a DIRECTORY test, so a
# worktree read as no checkout at all and was refused as ambiguous, the two halves of one rule
# disagreeing about the case agents work in by default (L263).
WTP_ROOT="$(mktemp -d "$WORK/worktree.XXXXXX")"
mkdir -p "$WTP_ROOT/alpha/.git" "$WTP_ROOT/beta/.git"
printf 'gitdir: /somewhere/else/.git/worktrees/x\n' > "$WTP_ROOT/.git"
mo_wtp="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$WTP_ROOT" 2>/dev/null)"
case "$mo_wtp" in
  *"already #412"*) check "#402 a project that is itself a worktree is matched, not refused as ambiguous" ok ;;
  *) check "#402 a project that is itself a worktree is matched, not refused as ambiguous" "out=$mo_wtp" ;;
esac

# The control. Resolving must find a checkout, never invent one: a directory with no repo anywhere
# still fails open and still SAYS so, or the case above would be satisfied by a matcher that had
# simply stopped reporting when it could not look (L11, L159).
BARE_ROOT="$(mktemp -d "$WORK/bare.XXXXXX")"
mo_bare="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$BARE_ROOT" 2>/dev/null)"
case "$mo_bare" in
  *"OPEN ISSUES NOT READ"*) check "#344 a directory with no checkout anywhere still says it could not look" ok ;;
  *) check "#344 a directory with no checkout anywhere still says it could not look" "out=$mo_bare" ;;
esac

# Text with no findings in it comes back untouched, so the matcher can never eat a report.
mo_plain="$(matcher_out 'HARVEST FAILED: one agent could not be read')"
case "$mo_plain" in
  *"HARVEST FAILED: one agent could not be read"*) check "#256 text holding no finding is passed through" ok ;;
  *) check "#256 text holding no finding is passed through" "out=$mo_plain" ;;
esac

# ---------------------------------------------------------------------------
# A project folder with a curly apostrophe in its name (claude-config#1020).
# ---------------------------------------------------------------------------
# The work MacBook keeps its projects under `Documents - Dan<U+2019>s MacBook Pro`. The clear line was
# written with printf %q, which under the bash macOS ships (3.2) renders that apostrophe as one raw
# byte followed by octal escapes: a reader sees a replacement character, and a line retyped from
# what was shown names a different directory and so reads different keys. The character is BUILT,
# so this file holds no byte a reader could mistake for a plain apostrophe.
CURLY="$(printf '\xe2\x80\x99')"
APOS_PROJ="$WORK/Documents - Dan${CURLY}s MacBook Pro/proj"
mkdir -p "$APOS_PROJ"
APOS_MARK="r1020 a finding from the folder with a curly apostrophe"
bash "$DIR/lib/issue-spool.sh" note "$APOS_PROJ" "$APOS_MARK" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
apos_file="$(named_in "$(reason_of "$(run_review "$APOS_PROJ")")")"
apos_line="$(clear_line_of "$apos_file")"
[ -n "$apos_line" ] \
  && check "#1020 the review writes a clear line for a project under a curly apostrophe" ok \
  || check "#1020 the review writes a clear line for a project under a curly apostrophe" "file=[$apos_file]"
case "$apos_line" in
  *"$APOS_PROJ"*) check "#1020 the line carries the project path exactly as it is spelled" ok ;;
  *) check "#1020 the line carries the project path exactly as it is spelled" "line=$apos_line" ;;
esac
case "$apos_line" in
  *"\$'"*|*\\[0-7][0-7][0-7]*) check "#1020 and holds no octal escapes" "line=$apos_line" ;;
  *) check "#1020 and holds no octal escapes" ok ;;
esac
printf '%s' "$apos_line" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
  && check "#1020 and is valid UTF-8, so nobody is shown a replacement character" ok \
  || check "#1020 and is valid UTF-8, so nobody is shown a replacement character" "line=$apos_line"
# And it still WORKS when run as it stands, which is the one use the line has.
apos_said="$(eval "$apos_line" 2>&1)"
holds "$(bash "$DIR/lib/issue-spool.sh" archive "$APOS_PROJ" "$TRANSCRIPT" 2>/dev/null)" "$APOS_MARK" \
  && check "#1020 and run verbatim it files the finding" ok \
  || check "#1020 and run verbatim it files the finding" "said=${apos_said:0:400}"

# A plain ASCII apostrophe is the one character single quoting has to escape.
SQ_PROJ="$WORK/Dan's proj"
mkdir -p "$SQ_PROJ"
SQ_MARK="r1020 a finding from a folder with a plain apostrophe"
bash "$DIR/lib/issue-spool.sh" note "$SQ_PROJ" "$SQ_MARK" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
sq_line="$(clear_line_of "$(named_in "$(reason_of "$(run_review "$SQ_PROJ")")")")"
sq_said="$(eval "$sq_line" 2>&1)"
holds "$(bash "$DIR/lib/issue-spool.sh" archive "$SQ_PROJ" "$TRANSCRIPT" 2>/dev/null)" "$SQ_MARK" \
  && check "#1020 a folder with a plain apostrophe still gets a line that runs" ok \
  || check "#1020 a folder with a plain apostrophe still gets a line that runs" "line=$sq_line said=${sq_said:0:300}"

# A record written before records carried their project key is attributed by its `cwd`, which the
# writer stores as JSON, so the curly apostrophe is on disk as a six character JSON escape (backslash,
# u, then its code point in hex), never as the character itself. Pulled out
# with sed, that escape was never decoded, the path hashed as written, and the file belonged to no
# project. The fixture is written by the same json.dumps the writers use, with no project key, and
# under a key the project's own directory does not produce, which is the shape such a record has.
KW_DIR="$WORK/Documents - Dan${CURLY}s MacBook Pro/keyed"
mkdir -p "$KW_DIR"
KW_KEY="0123456789ab"
python3 -c '
import json, sys
print(json.dumps({"ts": "2026-10-09T00:00:00Z", "status": "found", "agent": "tester",
                  "cwd": sys.argv[1], "findings": ["r1020 a record keyed only by its cwd"]}))
' "$KW_DIR" > "$CLAUDE_ISSUE_SPOOL_DIR/$KW_KEY.jsonl"
# Escaped, not raw: the character is absent from the bytes and the record still decodes to the path.
kw_raw="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$KW_KEY.jsonl")"
case "$kw_raw" in *"$CURLY"*) false ;; *) true ;; esac \
  && python3 -c 'import json, sys; sys.exit(json.loads(sys.argv[1])["cwd"] != sys.argv[2])' "$kw_raw" "$KW_DIR" \
  && check "#1020 the fixture holds the apostrophe as a JSON escape, as the writers store it" ok \
  || check "#1020 the fixture holds the apostrophe as a JSON escape, as the writers store it" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$KW_KEY.jsonl")"
has_line "$(bash "$DIR/lib/issue-spool.sh" read-keys "$KW_DIR" 2>/dev/null)" "$KW_KEY" \
  && check "#1020 a record's escaped cwd is decoded, so the project reads that record's key" ok \
  || check "#1020 a record's escaped cwd is decoded, so the project reads that record's key" "keys=$(bash "$DIR/lib/issue-spool.sh" read-keys "$KW_DIR" 2>&1 | tr '\n' ' ')"
# A line cut off part way (a crash mid write) does not parse, and still names the directory it came
# from: its cwd is read by pattern and decoded the same way.
KW_CUT="0123456789ac"
python3 -c '
import sys
line = open(sys.argv[1]).read()
sys.stdout.write(line[: line.index(", \"findings\"")] + ", \"findi")
' "$CLAUDE_ISSUE_SPOOL_DIR/$KW_KEY.jsonl" > "$CLAUDE_ISSUE_SPOOL_DIR/$KW_CUT.jsonl"
python3 -c 'import json, sys; json.loads(open(sys.argv[1]).read())' "$CLAUDE_ISSUE_SPOOL_DIR/$KW_CUT.jsonl" 2>/dev/null \
  && check "#1020 the cut off fixture really does not parse" "it parsed" \
  || check "#1020 the cut off fixture really does not parse" ok
has_line "$(bash "$DIR/lib/issue-spool.sh" read-keys "$KW_DIR" 2>/dev/null)" "$KW_CUT" \
  && check "#1020 a damaged line's escaped cwd is decoded too" ok \
  || check "#1020 a damaged line's escaped cwd is decoded too" "keys=$(bash "$DIR/lib/issue-spool.sh" read-keys "$KW_DIR" 2>&1 | tr '\n' ' ') line=$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$KW_CUT.jsonl")"
rm -f "$CLAUDE_ISSUE_SPOOL_DIR/$KW_CUT.jsonl"
# The control: a different folder beside it does not claim that key (L159).
mkdir -p "$WORK/Documents - Dan${CURLY}s MacBook Pro/other"
has_line "$(bash "$DIR/lib/issue-spool.sh" read-keys "$WORK/Documents - Dan${CURLY}s MacBook Pro/other" 2>/dev/null)" "$KW_KEY" \
  && check "#1020 and another folder does not read it" "it claimed $KW_KEY" \
  || check "#1020 and another folder does not read it" ok
rm -f "$CLAUDE_ISSUE_SPOOL_DIR/$KW_KEY.jsonl"

# ---------------------------------------------------------------------------
# The review's per session bookkeeping is removed once it is spent (claude-config#1019).
# ---------------------------------------------------------------------------
# Every render that shows findings writes a stamp named per SESSION, and a clear that cannot rewrite
# the spool writes a seen ledger beside it. Nothing removed either, so one Slate project held 26
# stamps on 2026-10-09. Both are spent once the ownership window has passed: a mark in a ledger stops
# counting the moment its record is old enough for anybody to claim, which is that window, and a
# stamp that old names a render that has been superseded. Ages are SET with touch, never waited for.
SW="${TMPDIR:-/tmp}"; SW="${SW%/}"
sw_old_manifest="$SW/claude-issue-findings-aaaaaaaaaaaa.oldsession.manifest"
sw_old_seen="$SW/claude-issue-findings-aaaaaaaaaaaa.oldsession.seen"
sw_old_txt="$SW/claude-issue-findings-aaaaaaaaaaaa.txt"
sw_recent_seen="$SW/claude-issue-findings-bbbbbbbbbbbb.recentsession.seen"
sw_unrelated="$SW/claude-unrelated-file.manifest"
sw_dir="$SW/claude-issue-findings-cccccccccccc.adirectory.manifest"
for f in "$sw_old_manifest" "$sw_old_seen" "$sw_old_txt" "$sw_recent_seen" "$sw_unrelated"; do
  printf 'x\n' > "$f"
done
mkdir -p "$sw_dir"
touch -t 202001010000 "$sw_old_manifest" "$sw_old_seen" "$sw_old_txt" "$sw_unrelated" "$sw_dir"
# One day old: inside the default seven day window, so it must survive (the window is a window, not
# "anything older than now").
python3 -c 'import os, sys, time; t = time.time() - 86400; os.utime(sys.argv[1], (t, t))' "$sw_recent_seen"
SW_PROJ="$(mktemp -d "$WORK/sweep.XXXXXX")"
bash "$DIR/lib/issue-spool.sh" note "$SW_PROJ" "r1019 a finding whose review sweeps" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
sw_file="$(named_in "$(reason_of "$(run_review "$SW_PROJ")")")"
sw_gone=0
for f in "$sw_old_manifest" "$sw_old_seen" "$sw_old_txt"; do [ -e "$f" ] || sw_gone=$((sw_gone + 1)); done
[ "$sw_gone" -eq 3 ] \
  && check "#1019 a render removes stamps, ledgers and findings files older than the window" ok \
  || check "#1019 a render removes stamps, ledgers and findings files older than the window" "$sw_gone of 3 removed"
[ -e "$sw_recent_seen" ] \
  && check "#1019 and keeps a ledger still inside the window" ok \
  || check "#1019 and keeps a ledger still inside the window" "it was removed"
[ -e "$sw_unrelated" ] \
  && check "#1019 and leaves a file that is not the review's alone" ok \
  || check "#1019 and leaves a file that is not the review's alone" "it was removed"
[ -d "$sw_dir" ] \
  && check "#1019 and removes nothing that is not a plain file" ok \
  || check "#1019 and removes nothing that is not a plain file" "the directory was removed"
sw_stamp="$(clear_line_of "$sw_file" | awk '{print $NF}')"
[ -n "$sw_stamp" ] && [ -f "$sw_stamp" ] \
  && check "#1019 and keeps the stamp it has just written" ok \
  || check "#1019 and keeps the stamp it has just written" "stamp=[$sw_stamp]"
grep -q "removed 3 " "$sw_file" 2>/dev/null \
  && check "#1019 and says how many it removed" ok \
  || check "#1019 and says how many it removed" "file=$(tail -3 "$sw_file" 2>/dev/null)"
# Said ABOVE the clear line: review/issue-review.md tells the reader the file ends with it.
[ -n "$sw_stamp" ] && [ "$(awk 'NF { last = $0 } END { sub(/^  /, "", last); print last }' "$sw_file")" = "$(clear_line_of "$sw_file")" ] \
  && check "#1019 and the findings file still ends with the clear line" ok \
  || check "#1019 and the findings file still ends with the clear line" "file ends: $(tail -2 "$sw_file" 2>/dev/null)"
rm -rf "$sw_recent_seen" "$sw_unrelated" "$sw_dir"

# A file the sweep cannot remove is NAMED, with the reason, and the sweep fails; a sweep that removed
# nothing and said nothing would read exactly like one with nothing to remove (L98, L11).
SWF="$WORK/sweep-fail"; mkdir -p "$SWF"
printf 'x\n' > "$SWF/claude-issue-findings-dddddddddddd.s.manifest"
touch -t 202001010000 "$SWF/claude-issue-findings-dddddddddddd.s.manifest"
chmod a-w "$SWF"
if ( : > "$SWF/.probe" ) 2>/dev/null; then
  rm -f "$SWF/.probe"; chmod u+w "$SWF"
  echo "UNMEASURED: #1019 a directory the sweep cannot write cannot be made here (chmod does not restrict this user)"
else
  swf_said="$(bash "$DIR/lib/issue-spool.sh" sweep-stamps "$SWF" "claude-issue-findings-" 2>&1)"
  swf_rc=$?
  chmod u+w "$SWF"
  [ "$swf_rc" -ne 0 ] \
    && check "#1019 a sweep that cannot remove a spent file fails" ok \
    || check "#1019 a sweep that cannot remove a spent file fails" "exit 0, said=${swf_said:0:300}"
  case "$swf_said" in
    *"could not remove 1 "*"dddddddddddd.s.manifest"*) check "#1019 and names the file it could not remove" ok ;;
    *) check "#1019 and names the file it could not remove" "said=${swf_said:0:300}" ;;
  esac
  [ -f "$SWF/claude-issue-findings-dddddddddddd.s.manifest" ] \
    && check "#1019 and the file is still there" ok \
    || check "#1019 and the file is still there" "it is gone"
fi

# ---------------------------------------------------------------------------
# Seen ledgers are KEPT beside the spool, past the temp cleaner (#1019 follow-up).
# ---------------------------------------------------------------------------
# keep-ledgers copies, never moves: a clear may be appending to the temp ledger at that moment, and a
# mark it adds afterwards is copied next time, where a move would have lost it.
SPOOL_LIB="$DIR/lib/issue-spool.sh"
KL_TMP="$WORK/keep-tmp"; mkdir -p "$KL_TMP"
kl_stamp="$KL_TMP/claude-issue-findings-eeeeeeeeeeee.sess-k.manifest"
kl_temp="$(bash "$SPOOL_LIB" seen-ledger "$kl_stamp")"
kl_kept="$(bash "$SPOOL_LIB" kept-ledger "$kl_stamp")"
case "$kl_kept" in
  "$CLAUDE_ISSUE_SPOOL_DIR/seen/"*) check "#1019 the kept ledger lives under the spool's own root" ok ;;
  *) check "#1019 the kept ledger lives under the spool's own root" "kept=$kl_kept" ;;
esac
printf 'issue-spool seen v1\nsess-k aaaa1111\nsess-k bbbb2222\n' > "$kl_temp"
kl_said="$(bash "$SPOOL_LIB" keep-ledgers "$KL_TMP" "claude-issue-findings-" 2>&1)"; kl_rc=$?
[ "$kl_rc" -eq 0 ] && [ -z "$kl_said" ] \
  && check "#1019 keeping a ledger succeeds quietly" ok \
  || check "#1019 keeping a ledger succeeds quietly" "exit $kl_rc said=${kl_said:0:300}"
[ "$(grep -c 'sess-k' "$kl_kept" 2>/dev/null)" = 2 ] && [ -f "$kl_temp" ] \
  && check "#1019 the kept copy holds both marks and the temp ledger is left in place" ok \
  || check "#1019 the kept copy holds both marks and the temp ledger is left in place" "kept=$(cat "$kl_kept" 2>/dev/null) temp present=$([ -f "$kl_temp" ] && echo yes || echo no)"
# A mark added later is copied in, and one already held is not copied twice.
printf 'sess-k cccc3333\n' >> "$kl_temp"
bash "$SPOOL_LIB" keep-ledgers "$KL_TMP" "claude-issue-findings-" >/dev/null 2>&1
bash "$SPOOL_LIB" keep-ledgers "$KL_TMP" "claude-issue-findings-" >/dev/null 2>&1
[ "$(grep -c 'sess-k' "$kl_kept" 2>/dev/null)" = 3 ] \
  && check "#1019 a later mark is kept, and none twice" ok \
  || check "#1019 a later mark is kept, and none twice" "kept=$(cat "$kl_kept" 2>/dev/null)"
# That the render reads the kept copy once the temp one is gone is driven end to end through the real
# hook in test-subagent-issue-harvest.sh, beside the #1011 case that writes the ledger.
rm -f "$kl_temp"
# A kept ledger past the window is swept like the rest.
touch -t 202001010000 "$kl_kept"
kl_sweep="$(bash "$SPOOL_LIB" sweep-stamps "$KL_TMP" "claude-issue-findings-" 2>&1)"
[ ! -e "$kl_kept" ] && holds "$kl_sweep" "$CLAUDE_ISSUE_SPOOL_DIR/seen" \
  && check "#1019 a kept ledger past the window is swept, and the sweep names where" ok \
  || check "#1019 a kept ledger past the window is swept, and the sweep names where" "said=${kl_sweep:0:300}"
# A ledger that cannot be kept is NAMED and the command fails; its marks are still read from the temp
# copy, so nothing reappears, but the clock on it is the temp cleaner's and that has to be said.
printf 'issue-spool seen v1\nsess-k dddd4444\n' > "$kl_temp"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR/seen"; chmod a-w "$CLAUDE_ISSUE_SPOOL_DIR/seen"
if ( : > "$CLAUDE_ISSUE_SPOOL_DIR/seen/.probe" ) 2>/dev/null; then
  rm -f "$CLAUDE_ISSUE_SPOOL_DIR/seen/.probe"; chmod u+w "$CLAUDE_ISSUE_SPOOL_DIR/seen"
  echo "UNMEASURED: #1019 an unwritable kept ledger directory cannot be made here (chmod does not restrict this user)"
else
  kl_fail="$(bash "$SPOOL_LIB" keep-ledgers "$KL_TMP" "claude-issue-findings-" 2>&1)"; kl_frc=$?
  chmod u+w "$CLAUDE_ISSUE_SPOOL_DIR/seen"
  [ "$kl_frc" -ne 0 ] && holds "$kl_fail" "could not keep 1 " && holds "$kl_fail" "$(basename "$kl_temp")" \
    && check "#1019 a ledger that cannot be kept is named and the command fails" ok \
    || check "#1019 a ledger that cannot be kept is named and the command fails" "exit $kl_frc said=${kl_fail:0:300}"
fi
rm -rf "$KL_TMP" "$CLAUDE_ISSUE_SPOOL_DIR/seen"

# A kept ledger directory the sweep cannot look in is said, and what the temp directory's pass removed
# is still reported: the first version exited at the listing failure, after removing files, saying
# nothing about them.
SU_TMP="$WORK/sweep-unlisted"; mkdir -p "$SU_TMP" "$CLAUDE_ISSUE_SPOOL_DIR/seen"
printf 'x\n' > "$SU_TMP/claude-issue-findings-ffffffffffff.s.manifest"
touch -t 202001010000 "$SU_TMP/claude-issue-findings-ffffffffffff.s.manifest"
chmod a-r "$CLAUDE_ISSUE_SPOOL_DIR/seen"
if ls "$CLAUDE_ISSUE_SPOOL_DIR/seen" >/dev/null 2>&1; then
  chmod u+r "$CLAUDE_ISSUE_SPOOL_DIR/seen"
  echo "UNMEASURED: #1019 an unlistable kept ledger directory cannot be made here (chmod does not restrict this user)"
else
  su_said="$(bash "$SPOOL_LIB" sweep-stamps "$SU_TMP" "claude-issue-findings-" 2>&1)"; su_rc=$?
  chmod u+r "$CLAUDE_ISSUE_SPOOL_DIR/seen"
  [ "$su_rc" -ne 0 ] && holds "$su_said" "could not look in" && holds "$su_said" "removed 1 " \
    && [ ! -e "$SU_TMP/claude-issue-findings-ffffffffffff.s.manifest" ] \
    && check "#1019 a sweep that cannot look in one place still reports what it removed in the other" ok \
    || check "#1019 a sweep that cannot look in one place still reports what it removed in the other" "exit $su_rc said=${su_said:0:300}"
fi
rm -rf "$SU_TMP" "$CLAUDE_ISSUE_SPOOL_DIR/seen"

# And a ledger the review could not keep is said in the REASON, whether or not there are findings,
# since a review with none writes no findings file.
KR_PROJ="$(mktemp -d "$WORK/keepreason.XXXXXX")"
printf 'issue-spool seen v1\nsess-r 9999aaaa\n' > "${TMPDIR%/}/claude-issue-findings-0000000000aa.sess-r.seen"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR/seen"; chmod a-w "$CLAUDE_ISSUE_SPOOL_DIR/seen"
if ( : > "$CLAUDE_ISSUE_SPOOL_DIR/seen/.probe" ) 2>/dev/null; then
  rm -f "$CLAUDE_ISSUE_SPOOL_DIR/seen/.probe"; chmod u+w "$CLAUDE_ISSUE_SPOOL_DIR/seen"
  echo "UNMEASURED: #1019 an unwritable kept ledger directory cannot be made here (chmod does not restrict this user)"
else
  kr_reason="$(reason_of "$(run_review "$KR_PROJ")")"
  chmod u+w "$CLAUDE_ISSUE_SPOOL_DIR/seen"
  holds "$kr_reason" "could not keep 1 " \
    && check "#1019 a ledger the review could not keep is said in its reason" ok \
    || check "#1019 a ledger the review could not keep is said in its reason" "reason=${kr_reason:0:300}"
fi
rm -rf "${TMPDIR%/}/claude-issue-findings-0000000000aa.sess-r.seen" "$CLAUDE_ISSUE_SPOOL_DIR/seen"

# --- the hook stays quiet when nothing happened ---
# It fires on Stop, so a chat-only turn must not trigger a review. An absent
# transcript is the cheapest stand-in for "nothing to review".
out="$(printf '{"transcript_path":"/nonexistent/path.jsonl"}' | bash "$HOOK" 2>/dev/null)"
if [[ -z "$out" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a missing transcript should produce no output, got: $out"
fi

# --- the hook is syntactically valid shell ---
if bash -n "$HOOK" 2>/dev/null; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: the hook is not valid bash"
fi

# --- and nothing the hook wrote landed in the temp directory this suite was started with ---
# Every review above writes a findings file, a stamp and a cooldown stamp under $TMPDIR. Before
# claude-config#1019 this suite did not point TMPDIR at its own directory, so each run left them in
# the real one (52 stamps from throwaway projects on the personal MacBook on 2026-10-09). Asked of
# the files themselves, by each reviewed project's hash, rather than of the export (L322).
leaked="$(python3 - "$REAL_TMPDIR" "$REVIEWED" <<'PY'
import hashlib, os, sys
real = sys.argv[1]
with open(sys.argv[2], encoding="utf-8", errors="surrogateescape") as fh:
    projects = [ln.rstrip("\n") for ln in fh if ln.strip()]
hashes = {hashlib.sha1(p.encode("utf-8", "surrogateescape")).hexdigest()[:12] for p in projects}
try:
    names = os.listdir(real)
except OSError:
    names = []
print(" ".join(sorted(n for n in names if n.startswith("claude-") and any(h in n for h in hashes))))
PY
)"
reviews_run="$(grep -c . "$REVIEWED" 2>/dev/null || true)"
[ "${reviews_run:-0}" -gt 0 ] && [ -z "$leaked" ] \
  && check "#1019 the suite leaves nothing in the temp directory it was started with" ok \
  || check "#1019 the suite leaves nothing in the temp directory it was started with" "reviews=${reviews_run:-0} leaked: ${leaked:0:400}"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
