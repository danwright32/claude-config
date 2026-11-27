#!/usr/bin/env bash
# The pennie-dev-update skill's first appearance of a product (claude-config#588).
#
# On 2026-09-28 the skill asked Dan for a starting date for Sonar's first run and was about to list
# its merged PRs one by one. Dan answered: "sonar shouldn't announce specific updates. this would
# be the announcement of sonar in general." So a repo with no lastEnd is introduced in general, and
# its window then starts after its newest merge, so later runs report changes only. The skill is
# prose Claude follows, so what is held here is that the prose says so, and that the paragraphs
# contradicting Dan's decision (no launch mode, ask for a starting date) are gone (L252: a reversed
# decision deletes the text defending it).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SKILL="$DIR/../payload/skills/pennie-dev-update/SKILL.md"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
if [ ! -f "$SKILL" ]; then
  echo "FAIL: the skill is not at $SKILL, so nothing was checked."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
# The claims are held to the "### First appearance" section of the skill, never anywhere in the
# file, and each one as the exact sentence that makes it, case and all, inside ONE paragraph of that
# section with its whitespace collapsed (so rewrapping cannot hide it, L278). #790 found the first
# version matched loose words case insensitively anywhere in a paragraph, so a rewording that
# dropped the claim, or unrelated text holding the words, passed (L178, L135). A rewording now
# fails here and the sentence below is updated with it: the wording is the behaviour Claude follows.
section="$(awk '/^### First appearance$/ { f = 1; next } f && /^(#|---)/ { exit } f' "$SKILL")"
paras="$(printf '%s\n' "$section" | awk 'BEGIN { RS = ""; ORS = "\n" } { gsub(/[[:space:]]+/, " "); print }')"
claim(){   # $1 = what it holds  $2 = the exact sentence, inside one paragraph of the section
  if [ -z "$section" ]; then check "$1" "the skill has no '### First appearance' section"; return; fi
  # Matched with `case`, one paragraph at a time, never a producer piped into a quiet grep (L183).
  local p
  while IFS= read -r p; do
    case "$p" in *"$2"*) check "$1" ok; return ;; esac
  done <<< "$paras"
  check "$1" "the section does not say: $2"
}
gone(){   # $1 = what it holds  $2 = a phrase that must appear nowhere in the skill, in any case
  if grep -q -i -F -- "$2" "$SKILL"; then check "$1" "the skill still says: $2"; else check "$1" ok; fi
}

gone "the no launch mode paragraph is gone" "no launch mode"
gone "a first run no longer asks for a starting date" "ask for a starting date"
claim "a repo with no lastEnd is introduced in general" \
  'A repo with no `lastEnd` at all is a product appearing for the first time, and it is introduced in general.'
claim "the introduction never lists the product's merged PRs one by one" \
  "the product's merged PRs are never listed one by one."
claim "Dan's decision is quoted with its date" \
  "Dan decided this on 2026-09-28, when the skill asked him for a starting date for Sonar: \"sonar shouldn't announce specific updates. this would be the announcement of sonar in general.\""
claim "the introduction covers what it is, who uses it, when to open it, what it checks and how to share a result" \
  "what it is, who uses it, when to open it, what it checks, and how to share a result"
claim "the window then starts after the newest merge in production, so later runs report changes only" \
  'set that repo'"'"'s `lastEnd` to the `merged_at` of its newest merged PR that reached production (section 4), so the next run reports changes only'

# The checks above can fail: the same claims against a section that does not make them.
section_real="$section"; paras_real="$paras"
section="An unrelated paragraph mentioning lastEnd, newest, merged_at and changes only, in general, never one by one."
paras="$section"
before_fail=$fail
claim "(control) a section without the claim" 'A repo with no `lastEnd` at all is a product appearing for the first time, and it is introduced in general.' >/dev/null
if [ "$fail" -eq $((before_fail + 1)) ]; then fail=$before_fail; check "the claim check fails on loose words that make no claim" ok
else check "the claim check fails on loose words that make no claim" "it passed text that makes no claim"; fi
section="$section_real"; paras="$paras_real"

# ---- claude-config#679: the defects the October 2026 skills audit found.

# The window starts strictly after lastEnd. The skill said so in section 2 and then filtered on
# `merged_at >= start` in section 3, so the newest change of the last post was listed again. Held
# as a class: no line that talks about a merge may compare with >= at all.
ge_lines="$(grep -n 'merged' "$SKILL" | grep -F '>=' || true)"
if [ -z "$ge_lines" ]; then check "no merge comparison includes the boundary itself (>=)" ok
else check "no merge comparison includes the boundary itself (>=)" "$ge_lines"; fi

# The repo paths were typed by hand as they stood before the work MacBook's Documents move on
# 2026-10-02, and pointed at nothing after it (L153). Nothing the skill does needs a local checkout
# once the deploy check asks GitHub, so no entry carries a path at all and no step runs git there.
# The registry is each Mac's own file since claude-config#1526, which no suite in the repository can
# read, so gather.js refuses an entry carrying a path where the file IS read (its own suite,
# test-pennie-dev-update-scripts.sh, holds that), and the prose is held here.
gone "no step runs git in a local checkout" "git -C"
gone "no step reads a configured path" 'configured `path`'

# The 2026-09-28 edit removed the "backend only" line and the "Update for" opener, while the
# structure rules and the worked example still demanded both (L562: the example wins).
gone "the structure no longer asks for a backend only line" "noting some items are backend only"
gone "the example no longer carries the backend only line" "because they are backend only"
old_opener="$(grep -n 'Update for ' "$SKILL" || true)"
if [ -z "$old_opener" ]; then check "no opener still reads Update for" ok
else check "no opener still reads Update for" "$old_opener"; fi
bad_opener="$(grep -n '^Updates for ' "$SKILL" | grep -v ' :thread:$' || true)"
if [ -z "$bad_opener" ]; then check "every example opener ends with :thread:" ok
else check "every example opener ends with :thread:" "$bad_opener"; fi
openers="$(grep -c '^Updates for .* :thread:$' "$SKILL" || true)"
if [ "${openers:-0}" -ge 2 ]; then check "the post example and the quiet period example both open the current way" ok
else check "the post example and the quiet period example both open the current way" "found ${openers:-0} such openers"; fi

# "Three cases" headed a four row table. The number word is checked against the rows it counts.
counted="$(awk '
  /^## 4\./ { s = 1; next }
  s && /^## / { exit }
  s && /must stay distinct/ { split("one two three four five six seven eight", w, " "); for (i in w) if (tolower($0) ~ ("(^|[^a-z])" w[i] "([^a-z]|$)")) word = i }
  s && /^\|/ { rows++ }
  END { print (word ? word : "none") " " (rows > 2 ? rows - 2 : 0) }
' "$SKILL")"
if [ "${counted%% *}" = "${counted##* }" ]; then check "the deploy table's count word matches its rows" ok
else check "the deploy table's count word matches its rows" "word says ${counted%% *}, table has ${counted##* } rows"; fi

# BBEdit's helper opens the file in the background without --front-window, reports success, and
# Dan sees nothing (global CLAUDE.md, 2026-09-09).
no_front="$(grep -n 'bbedit_tool' "$SKILL" | grep -v -e '--front-window' || true)"
if [ -z "$no_front" ]; then check "every BBEdit open brings its window to the front" ok
else check "every BBEdit open brings its window to the front" "$no_front"; fi

# ---- claude-config#680: the window, gathering and post rules moved into scripts. The prose now
# tells Claude to run them, so every script it names must exist beside it (L3: built is not wired),
# and the sequence must run each one.
SKILL_DIR="$(dirname "$SKILL")"
named="$(grep -o -E '(~/\.claude|__CLAUDE_HOME__)/skills/pennie-dev-update/[A-Za-z0-9_.-]*' "$SKILL" | sort -u)"
if [ -z "$named" ]; then check "the skill runs its scripts by path" "it names no script under ~/.claude/skills/pennie-dev-update/"
else
  while IFS= read -r ref; do
    f="${ref##*/}"
    [ -z "$f" ] && continue
    if [ -f "$SKILL_DIR/$f" ]; then check "the skill names $f, which exists beside it" ok
    else check "the skill names $f, which exists beside it" "no $f in $SKILL_DIR"; fi
  done <<< "$named"
fi
sequence="$(awk '/^## 10\./ { f = 1; next } f' "$SKILL")"
for step in 'gather.js gather' 'gather.js commit-state' 'lint-post.js'; do
  case "$sequence" in *"$step"*) check "the sequence runs $step" ok ;; *) check "the sequence runs $step" "section 10 never says $step" ;; esac
done

# ---- claude-config#3503: on 2026-11-23 a gathered pull request body named a Slack posting method,
# and from then on the Slack drafts gate refused the skill's own local commands that are handed the
# gathered file: a node one liner printing counts from it, and gather.js commit-state. Neither needs
# the network, so both run under the no network wrapper, which the gate lets through only when the
# wrapper's path is the call's first word, written out absolute, and no word after it is a tilde.
# __CLAUDE_HOME__ is what the sync turns into this Mac's absolute path. The gather itself reads
# GitHub, so it must NOT be put under the wrapper. Each claim is held to the code line that makes it.
WRAP_RUN='__CLAUDE_HOME__/hooks/no-network-run.sh '
if [ -f "$DIR/../payload/hooks/no-network-run.sh" ]; then check "the wrapper the skill names exists in the payload" ok
else check "the wrapper the skill names exists in the payload" "no payload/hooks/no-network-run.sh"; fi
commit_line="$(awk 'index($0, "gather.js commit-state ") { print; exit }' <<< "$sequence")"
case "${commit_line#"${commit_line%%[![:space:]]*}"}" in
  "${WRAP_RUN}node __CLAUDE_HOME__/skills/pennie-dev-update/gather.js commit-state "*) check "the sequence runs commit-state under the no network wrapper" ok ;;
  *) check "the sequence runs commit-state under the no network wrapper" "its line is: ${commit_line:-none}" ;; esac
case "$commit_line" in
  *'~'*) check "the commit-state line holds no tilde, which takes it off the wrapper's route" "$commit_line" ;;
  *) check "the commit-state line holds no tilde, which takes it off the wrapper's route" ok ;; esac
read_line="$(awk -v w="${WRAP_RUN}node -e " 'index($0, w) && index($0, "gathered.json") { print; exit }' <<< "$sequence")"
if [ -n "$read_line" ]; then check "the sequence reads the gathered file's counts under the no network wrapper" ok
else check "the sequence reads the gathered file's counts under the no network wrapper" "section 10 has no '${WRAP_RUN}node -e' line reading gathered.json"; fi
gather_line="$(awk 'index($0, "gather.js gather ") { print; exit }' <<< "$sequence")"
case "$gather_line" in
  *no-network-run*) check "the gather, which reads GitHub, is not put under the wrapper" "$gather_line" ;;
  '') check "the gather, which reads GitHub, is not put under the wrapper" "section 10 has no gather line" ;;
  *) check "the gather, which reads GitHub, is not put under the wrapper" ok ;; esac
window_section="$(awk '/^## 2\./ { f = 1; next } f && /^## / { exit } f' "$SKILL")"
case "$window_section" in *"${WRAP_RUN}"*) check "section 2 says commit-state runs under the wrapper" ok ;;
  *) check "section 2 says commit-state runs under the wrapper" "section 2 never names ${WRAP_RUN% }" ;; esac

# ---- claude-config#1182: a bare gh command runs as whichever account gh has active, which on the
# personal MacBook is danwright32, and GitHub answers it 404 for the work organisation's private repos. So
# every gh command the skill shows runs through `gather.js gh`, which runs it as the account
# the registry names for the repo. The bare form is a code block line that STARTS with gh, or an
# inline command in backticks that starts with gh and names its repo with --repo (every command
# the skill gives does, section 1). A prose mention such as "never `gh pr list`" names no repo.
bare_gh="$(grep -n -E '^[[:space:]]*gh (issue|label|api|pr|search|repo|run|workflow) ' "$SKILL" || true)"
bare_gh="$bare_gh$(grep -n -E '`gh [a-z]+ [^`]*--repo' "$SKILL" || true)"
if [ -z "$bare_gh" ]; then check "every gh command in the skill runs as the repo's account, through gather.js gh" ok
else check "every gh command in the skill runs as the repo's account, through gather.js gh" "$bare_gh"; fi
case "$sequence" in *'gather.js gh'*) check "the sequence runs the issue check through gather.js gh" ok ;;
  *) check "the sequence runs the issue check through gather.js gh" "section 10 never says gather.js gh" ;; esac

# ---- claude-config#2564: the post can be saved as a Slack draft, and only ever a draft (global
# CLAUDE.md, "Slack: drafts only", 2026-11-05). The tool names are built from parts so this file
# holds none of them literally: the Slack drafts gate reads the scripts a command runs.
DRAFT_TOOL="slack_send""_message_draft"
SENDS='slack_(send|post)''_message([^_]|$)|slack_schedule''_message|slack_reply''_to_thread|chat[._]post''(message|ephemeral)|chat[._]schedule''message|hooks[.]slack[.]com'
names_send(){ grep -n -i -E -- "$SENDS" "$1" || true; }
if grep -q -F -- "$DRAFT_TOOL" "$SKILL"; then check "the skill saves the post with the Slack draft tool" ok
else check "the skill saves the post with the Slack draft tool" "it never names $DRAFT_TOOL"; fi
sends="$(names_send "$SKILL")"
if [ -z "$sends" ]; then check "the skill names no Slack send or schedule tool or endpoint" ok
else check "the skill names no Slack send or schedule tool or endpoint" "$sends"; fi
# Seen failing: the same scan over text naming a send tool.
probe="$(mktemp "${TMPDIR:-/tmp}/dev-update-skill.XXXXXX")"
printf 'Then post it with slack_send''_message to the channel.\n' > "$probe"
if [ -n "$(names_send "$probe")" ]; then check "the send scan fires on text naming a send tool" ok
else check "the send scan fires on text naming a send tool" "it passed text naming one"; fi
printf 'Save it with %s.\n' "$DRAFT_TOOL" > "$probe"
if [ -z "$(names_send "$probe")" ]; then check "the send scan passes the draft tool itself" ok
else check "the send scan passes the draft tool itself" "it flagged the draft tool"; fi
rm -f "$probe"
# The sequence saves the draft, reads its channel from the registry's one reader, runs /no-ai-tells
# BEFORE the draft is saved, and tells Dan nothing was sent.
case "$sequence" in *"$DRAFT_TOOL"*) check "the sequence has the Slack draft step" ok ;;
  *) check "the sequence has the Slack draft step" "section 10 never names $DRAFT_TOOL" ;; esac
case "$sequence" in *'dev-update-registry.js channel'*) check "the draft's channel comes from the registry reader" ok ;;
  *) check "the draft's channel comes from the registry reader" "section 10 never runs dev-update-registry.js channel" ;; esac
before_draft="${sequence%%"$DRAFT_TOOL"*}"
case "$before_draft" in *'/no-ai-tells'*) check "/no-ai-tells runs before the draft is saved" ok ;;
  *) check "/no-ai-tells runs before the draft is saved" "section 10 does not run /no-ai-tells before $DRAFT_TOOL" ;; esac
seq_flat="$(printf '%s\n' "$sequence" | tr -s '[:space:]' ' ')"
for said in 'no channel, say so and skip the draft' 'nothing was sent' 'belongs in the thread' 'the whole post as one draft'; do
  case "$seq_flat" in *"$said"*) check "the draft step says: $said" ok ;;
    *) check "the draft step says: $said" "section 10 does not say: $said" ;; esac
done

# ---- claude-config#3502: on 2026-11-23 the sequence opened the draft in BBEdit at step 5, then ran
# the issue check and the state commit, and Dan took the open window to mean the run was finished
# and edited the draft while it was still going ("You shouldn't open bbedit until it's ready to
# post"). So BBEdit is first named in section 10 only after the issue check (the step running
# `gather.js gh`) and the state commit, and the Slack draft, which is saved from the file Dan may
# have edited there, comes after the editor opens. Line numbers within section 10, first mention.
seq_line(){ awk -v s="$1" 'index($0, s) { print NR; exit }' <<< "$sequence"; }
open_at="$(seq_line 'BBEdit')"; issue_at="$(seq_line 'gather.js gh')"
commit_at="$(seq_line 'gather.js commit-state')"; draft_at="$(seq_line "$DRAFT_TOOL")"
if [ -z "$open_at" ] || [ -z "$issue_at" ] || [ -z "$commit_at" ] || [ -z "$draft_at" ]; then
  check "section 10 names the editor, the issue check, the state commit and the draft" "open=${open_at:-none} issue=${issue_at:-none} commit=${commit_at:-none} draft=${draft_at:-none}"
else
  if [ "$open_at" -gt "$issue_at" ] && [ "$open_at" -gt "$commit_at" ]; then
    check "the editor opens only after the issue check and the state commit" ok
  else
    check "the editor opens only after the issue check and the state commit" "section 10 names BBEdit on its line $open_at, the issue check on $issue_at, the state commit on $commit_at"
  fi
  if [ "$draft_at" -gt "$open_at" ]; then check "the Slack draft is saved only after the editor opens" ok
  else check "the Slack draft is saved only after the editor opens" "section 10 saves the draft on its line $draft_at, before BBEdit on $open_at"; fi
fi
gone "section 8 no longer opens the draft as soon as it is checked" "Then open it"

# ---- claude-config#3668: the announce label (R5, R6). Whether managers notice a change is decided in
# code (gather.js's record.managerVisible), so the label table and section 5 sort by that field and
# never by a label's name, or a fourth label reads as one nobody handles. And the dev update is the
# safety net for an announcement nobody sent, so every one is settled before the run is recorded.
said_in(){   # $1 = what it holds  $2 = the section's text, whitespace collapsed  $3 = the phrase
  case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "it does not say: $3" ;; esac
}
flat(){ printf '%s\n' "$1" | tr -s '[:space:]' ' '; }
gathering="$(flat "$(awk '/^## 3\./ { f = 1; next } f && /^## / { exit } f' "$SKILL")")"
classifying="$(flat "$(awk '/^## 5\./ { f = 1; next } f && /^## / { exit } f' "$SKILL")")"
announcing_raw="$(awk '/^## 11\./ { f = 1; next } f && /^## / { exit } f' "$SKILL")"
announcing=""; [ -n "$announcing_raw" ] && announcing="$(flat "$announcing_raw")"
said_in "the label table has a row for changelog/announce" "$gathering" '| `changelog/announce` |'
said_in "the label table is sorted by record.managerVisible" "$gathering" '`record.managerVisible`'
said_in "section 5 sorts by record.managerVisible" "$classifying" 'decides by `record.managerVisible`'
# Matched against the section with its whitespace collapsed: the old sentence was wrapped across two
# lines, so a line by line grep never saw it, even in the text it was written to catch.
OLD_SORT='`changelog/visible` is manager-visible, `changelog/technical` is behind the scenes'
case "$classifying" in
  *"$OLD_SORT"*) check "section 5 no longer sorts by the label's name" "it still says: $OLD_SORT" ;;
  *) check "section 5 no longer sorts by the label's name" ok ;; esac
if [ -z "$announcing" ]; then check "the skill has a section 11 for announcements for agents" "no '## 11.' section"
else
  check "the skill has a section 11 for announcements for agents" ok
  said_in "section 11 reads the channel with slack_read_channel" "$announcing" 'slack_read_channel'
  said_in "section 11 says found posted at a time and asks nothing" "$announcing" 'found posted at <time>'
  said_in "section 11 asks one picker per announcement otherwise" "$announcing" 'one picker per announcement'
  said_in "section 11 says a failed read as that, never as nothing posted" "$announcing" 'never as "nothing posted"'
  said_in "section 11 says a cut short read as that" "$announcing" 'cut short'
  said_in "section 11 keeps the announcement away from lint-post.js" "$announcing" 'never goes through `lint-post.js`'
  posted_line="$(awk '/^## 11\./ { f = 1; next } f && /^## / { exit } f && index($0, "gather.js posted ") { print; exit }' "$SKILL")"
  case "${posted_line#"${posted_line%%[![:space:]]*}"}" in
    "${WRAP_RUN}node __CLAUDE_HOME__/skills/pennie-dev-update/gather.js posted "*) check "section 11 compares under the no network wrapper" ok ;;
    *) check "section 11 compares under the no network wrapper" "its line is: ${posted_line:-none}" ;; esac
fi
case "$commit_line" in *'--outcomes'*) check "the state commit passes each announcement's outcome" ok ;;
  *) check "the state commit passes each announcement's outcome" "its line is: ${commit_line:-none}" ;; esac

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
