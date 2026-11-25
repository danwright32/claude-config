#!/usr/bin/env bash
# Tests for the builder agent type and the script that renders it (claude-config#3389).
#
# Dan decided on 2026-11-25 ("Servers and rule files (Recommended)") that builders run as one agent
# type that lists no connected servers and does not load the rule files, carrying instead, in its
# own prompt, the lessons core and the rules a builder must still follow from the global CLAUDE.md.
# That prompt is a COPY of rules whose home is elsewhere, so it is never kept by hand (L244):
# render-builder-type.py writes it from CLAUDE.md, the files CLAUDE.md imports,
# builder-type-head.md and builder-type-rules.tsv, and its --check says when a written copy has
# gone stale. No rendered copy is committed (L554): CLAUDE.md and the lessons core files changed in
# 103 commits in the 30 days to 2026-11-25, 76 of them made by the sync on one Mac or the other
# with no pull request, and a committed rendering would be stale after each one.
#
# What this holds the files to:
#   1. the renderer, on a fixture: imports written out in place, left out sections and items gone,
#      kept items present, and anything the table does not name CARRIED and said, never dropped;
#   2. its failures: a missing source renders nothing and leaves an earlier copy alone;
#   3. --check passes on a fresh copy and fails, naming the line, once a source has moved;
#   4. the real payload: every section of CLAUDE.md has a recorded choice, every entry of the table
#      still matches, the tool list names no connected server, no model is set, and the rendered
#      prompt is inside its size budget.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$DIR/render-builder-type.py"
# The checkout, found by the one shared test, lib/checkout-root.sh (claude-config#1567, #1663).
# Empty for an installed copy in ~/.claude/skills, and then the checks that read the payload say
# they were not measured rather than judging other files.
REPO="$(bash "$DIR/../../hooks/lib/checkout-root.sh" "$DIR/../.." 2>/dev/null || true)"
PAYLOAD=""
[ -n "$REPO" ] && PAYLOAD="$REPO/payload"

# The most bytes the rendered prompt may hold. On 2026-11-25 the payload rendered to 88,281 (two
# readings), once the two UI sections were left out (93,942 before, one reading): 55,485 are the
# 355 lessons of the core with its table of contents, 26,357 the carried rules, and the rest the
# head and the tool notes. The budget leaves room for about 23 more core lessons at their present
# average of 156, or 3,700 characters of new rules. Past it somebody decides what a builder stops
# carrying, because every byte here is read again on every request a builder makes: at the 2.85
# characters a token that claude-config#3389's trial measured for this text (58,216 characters
# removed for 20,398 tokens, three runs), 3,700 is about 1,300 tokens.
BUDGET="${BUILDER_TYPE_BUDGET:-92000}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo ok || echo "'$2' is not in $(basename "$1")"; }
# A file that is not there lacks everything, so absence is only judged in one that was rendered.
lacks() {
  [ -s "$1" ] || { echo "$(basename "$1") is missing or empty, so nothing was judged"; return 0; }
  grep -qF -- "$2" "$1" 2>/dev/null && echo "'$2' is in $(basename "$1")" || echo ok
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/builder-type.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

render() { python3 -I "$RENDER" "$@"; }

check "the renderer is beside this suite" "$([ -f "$RENDER" ] && echo ok || echo "there is no $RENDER")"

# ---- the fixture: a small rules folder, head and table ----
FX="$WORK/rules"
mkdir -p "$FX"
printf '# Tool notes\n\n## A heading inside an imported file\n\nimported tool text\n' > "$FX/RTK.md"
printf '# Lessons core: A (generated, do not edit)\n\n- L1. first lesson line\n- L2. second lesson line\n' > "$FX/LESSONS-CORE-a.md"
cat > "$FX/CLAUDE.md" <<'RULES'
@RTK.md
<!-- lessons index: generated from LESSONS.md, do not edit between these markers -->
@LESSONS-CORE-a.md
<!-- end lessons index -->
The files above are lessons. This sentence names @notes.local.txt inside a line.

## Alpha

Alpha opening words.

- **First rule.** alpha keeps this
- **Second rule.** alpha drops this
  and this second line of it

      an indented block under the second rule, after a blank line
- **Third rule.** alpha keeps this too

## Beta

Beta opening words.

- **Beta one.** nothing of beta is carried

## Gamma

Gamma words to keep.

- gamma path one
- gamma path two

## Delta

- **Delta rule.** no row of the table names this section
RULES
HEAD="$WORK/head.md"
printf -- '---\nname: builder\ndescription: fixture\ntools: Bash, Read\nomitClaudeMd: true\n---\n\nFixture opening words.\n' > "$HEAD"
TABLE="$WORK/rules.tsv"
{
  printf '# kind\tsection\twords the item starts with, or the reason\treason\n'
  printf 'carry\tAlpha\tneeded\n'
  printf 'drop\tAlpha\tSecond rule.\tnot for a builder\n'
  printf 'leave\tBeta\tnot for a builder\n'
  printf 'leave\tGamma\ta list a brief supplies\n'
  printf 'keep\tGamma\tGamma words to keep.\ta writing rule\n'
} > "$TABLE"

OUT="$WORK/builder.md"
render --rules "$FX" --head "$HEAD" --table "$TABLE" --out "$OUT" 2> "$WORK/err.txt"
rc=$?
check "a render of the fixture exits 0" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: $(head -3 "$WORK/err.txt")")"
check "the head opens the file, so the frontmatter is its first line" \
  "$([ "$(head -1 "$OUT" 2>/dev/null)" = "---" ] && [ "$(sed -n 2p "$OUT" 2>/dev/null)" = "name: builder" ] && echo ok || echo "it opens with '$(head -2 "$OUT" 2>/dev/null | tr '\n' '|')'")"
check "an imported lessons file is written out in place" "$(has "$OUT" "- L2. second lesson line")"
check "the other imported file is written out too" "$(has "$OUT" "imported tool text")"
check "no import line is left for a reader that cannot follow one" "$(lacks "$OUT" "@LESSONS-CORE-a.md")"
# The payload's CLAUDE.md wraps its lessons imports in two marker comments, which the sync writes
# (ensure_lesson_index_imports). They are the sync's own bookkeeping and say nothing to a builder.
# The first fixture here had no markers, and the renderer it passed left every lessons import of
# the real file unread, as a bare line, in a prompt that rendered without complaint (L48).
check "the sync's marker comments around the imports are not carried" "$(lacks "$OUT" "lessons index")"
check "an import named inside a sentence is left as the sentence had it" "$(has "$OUT" "names @notes.local.txt inside a line")"
check "a heading inside an imported file is not read as a section of the rules" "$(has "$OUT" "## A heading inside an imported file")"
check "a carried section keeps its heading" "$(has "$OUT" "## Alpha")"
check "a carried section keeps its opening words" "$(has "$OUT" "Alpha opening words.")"
check "a carried section keeps an item no row drops" "$(has "$OUT" "**First rule.** alpha keeps this")"
check "a dropped item is gone" "$(lacks "$OUT" "alpha drops this")"
check "a dropped item's second line goes with it" "$(lacks "$OUT" "and this second line of it")"
# What is indented under a bullet is part of it across a blank line too (a command, a sub list),
# or dropping the bullet would leave its example behind for a builder to follow.
check "a dropped item's indented block after a blank line goes with it" "$(lacks "$OUT" "an indented block under the second rule")"
check "the item after a dropped one is still carried" "$(has "$OUT" "**Third rule.** alpha keeps this too")"
check "a left out section's heading is gone" "$(lacks "$OUT" "## Beta")"
check "a left out section's items are gone" "$(lacks "$OUT" "nothing of beta is carried")"
check "a kept item of a left out section is carried, under its heading" \
  "$([ "$(has "$OUT" "## Gamma")" = ok ] && [ "$(has "$OUT" "Gamma words to keep.")" = ok ] && echo ok || echo "the heading or the kept words are missing")"
check "the rest of that section is left out" "$(lacks "$OUT" "gamma path one")"
# The failure path of the table itself: a section nobody decided about must reach the builder.
check "a section no row names is CARRIED, never dropped by omission" "$(has "$OUT" "no row of the table names this section")"
check "and the render says which section had no row" "$(has "$WORK/err.txt" "Delta")"
check "the render says it is generated, below the head" "$(has "$OUT" "generated, do not edit")"

# Byte identical run to run, and nothing in it that two clean edits could collide over (L554).
render --rules "$FX" --head "$HEAD" --table "$TABLE" > "$WORK/again.md" 2>/dev/null
check "two renders of the same sources are byte identical" "$([ -s "$WORK/again.md" ] && cmp -s "$OUT" "$WORK/again.md" && echo ok || echo "they differ, or nothing was rendered")"
aggregate="$(grep -nE '20[0-9]{2}-[0-9]{2}-[0-9]{2}|sha256|[0-9]+ (lessons|rules|sections|characters)' "$OUT" 2>/dev/null)"
check "the render carries no date, count or hash of its sources" "$([ -s "$OUT" ] && [ -z "$aggregate" ] && echo ok || echo "it holds one, or nothing was rendered: $aggregate")"

# ---- strict: what a pull request is held to ----
render --strict --rules "$FX" --head "$HEAD" --table "$TABLE" > /dev/null 2> "$WORK/strict.txt"
rc=$?
check "a strict render refuses a section with no row" "$([ "$rc" -eq 2 ] && [ "$(has "$WORK/strict.txt" "Delta")" = ok ] && echo ok || echo "exit $rc: $(head -2 "$WORK/strict.txt")")"
printf 'carry\tDelta\tneeded\n' >> "$TABLE"
render --strict --rules "$FX" --head "$HEAD" --table "$TABLE" > /dev/null 2> "$WORK/strict.txt"
rc=$?
check "a strict render passes once every section has a row" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: $(head -2 "$WORK/strict.txt")")"

# A row that matches nothing would otherwise read as a choice still in force (L100).
T2="$WORK/rules-stale-drop.tsv"
{ cat "$TABLE"; printf 'drop\tAlpha\tA rule that was reworded.\tnot for a builder\n'; } > "$T2"
render --strict --rules "$FX" --head "$HEAD" --table "$T2" > /dev/null 2> "$WORK/strict.txt"
rc=$?
check "a strict render refuses a drop row that matches no item" \
  "$([ "$rc" -eq 2 ] && [ "$(has "$WORK/strict.txt" "A rule that was reworded.")" = ok ] && echo ok || echo "exit $rc: $(head -2 "$WORK/strict.txt")")"
T3="$WORK/rules-stale-keep.tsv"
sed 's/Gamma words to keep\./Gamma words that moved./' "$TABLE" > "$T3"
render --rules "$FX" --head "$HEAD" --table "$T3" > "$WORK/keep.md" 2> "$WORK/keep.txt"
rc=$?
check "a keep row that matches nothing carries the WHOLE section, the harmless side" \
  "$([ "$rc" -eq 0 ] && [ "$(has "$WORK/keep.md" "gamma path one")" = ok ] && [ "$(has "$WORK/keep.md" "Gamma words to keep.")" = ok ] && echo ok || echo "exit $rc, or part of Gamma is missing")"
check "and says which row matched nothing" "$(has "$WORK/keep.txt" "Gamma words that moved.")"
T4="$WORK/rules-gone-section.tsv"
{ cat "$TABLE"; printf 'leave\tEpsilon\tnot for a builder\n'; } > "$T4"
render --strict --rules "$FX" --head "$HEAD" --table "$T4" > /dev/null 2> "$WORK/strict.txt"
rc=$?
check "a strict render refuses a row for a section the rules no longer have" \
  "$([ "$rc" -eq 2 ] && [ "$(has "$WORK/strict.txt" "Epsilon")" = ok ] && echo ok || echo "exit $rc: $(head -2 "$WORK/strict.txt")")"

# ---- failures: nothing half rendered, and an earlier copy is never replaced by a worse one ----
cp "$OUT" "$WORK/before.md" 2>/dev/null
mv "$FX/LESSONS-CORE-a.md" "$WORK/set-aside.md"
render --rules "$FX" --head "$HEAD" --table "$TABLE" --out "$OUT" 2> "$WORK/missing.txt"
rc=$?
check "a missing imported file is a failure, not a prompt without its lessons" "$([ "$rc" -eq 2 ] && echo ok || echo "exit $rc")"
check "the failure names the missing file" "$(has "$WORK/missing.txt" "LESSONS-CORE-a.md")"
check "and the copy written earlier is left exactly as it was" "$([ -s "$OUT" ] && cmp -s "$OUT" "$WORK/before.md" && echo ok || echo "it was changed, or there was none")"
render --rules "$FX" --head "$HEAD" --table "$TABLE" > "$WORK/stdout.md" 2>/dev/null
rc=$?
check "a failed render prints nothing a caller could mistake for a prompt" "$([ "$rc" -eq 2 ] && [ ! -s "$WORK/stdout.md" ] && echo ok || echo "exit $rc, having printed $(wc -c < "$WORK/stdout.md" | tr -d ' ') characters")"
mv "$WORK/set-aside.md" "$FX/LESSONS-CORE-a.md"
render --rules "$FX" --head "$WORK/no-such-head.md" --table "$TABLE" > /dev/null 2> "$WORK/missing.txt"
check "a missing head is a failure" "$([ $? -eq 2 ] && echo ok || echo "it did not exit 2")"
printf 'name: builder\n\nno frontmatter fence\n' > "$WORK/bad-head.md"
render --rules "$FX" --head "$WORK/bad-head.md" --table "$TABLE" > /dev/null 2> "$WORK/missing.txt"
check "a head that does not open with frontmatter is a failure" "$([ $? -eq 2 ] && echo ok || echo "it did not exit 2")"
# Exit 1 means a stale copy and nothing else, so a source that is not text must not reach it by
# way of an uncaught error.
printf -- '---\nname: builder\n---\n\nbytes that are not text: \377\376\n' > "$WORK/not-text-head.md"
render --rules "$FX" --head "$WORK/not-text-head.md" --table "$TABLE" > "$WORK/stdout.md" 2> "$WORK/missing.txt"
rc=$?
check "a source that is not readable text is a failure that says so, exit 2" \
  "$([ "$rc" -eq 2 ] && [ ! -s "$WORK/stdout.md" ] && [ "$(has "$WORK/missing.txt" "nothing was rendered")" = ok ] && echo ok || echo "exit $rc: $(tail -1 "$WORK/missing.txt" | cut -c1-200)")"
# An import below the first section is one Claude Code would follow and this cannot place.
mkdir -p "$WORK/late"
cp "$FX/RTK.md" "$FX/LESSONS-CORE-a.md" "$WORK/late/"
{ cat "$FX/CLAUDE.md"; printf '\n@MORE-RULES.md\n'; } > "$WORK/late/CLAUDE.md"
render --rules "$WORK/late" --head "$HEAD" --table "$TABLE" > "$WORK/stdout.md" 2> "$WORK/missing.txt"
rc=$?
check "an import inside a section is a failure, never a bare line a builder cannot follow" \
  "$([ "$rc" -eq 2 ] && [ ! -s "$WORK/stdout.md" ] && [ "$(has "$WORK/missing.txt" "@MORE-RULES.md")" = ok ] && echo ok || echo "exit $rc: $(head -2 "$WORK/missing.txt")")"

# ---- --check: the copy on disk against its sources ----
render --rules "$FX" --head "$HEAD" --table "$TABLE" --check "$OUT" > "$WORK/check.txt" 2>&1
rc=$?
check "--check passes on a copy just rendered" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: $(head -2 "$WORK/check.txt")")"
printf -- '- **Fourth rule.** added after the copy was rendered\n' >> "$FX/CLAUDE.md"
render --rules "$FX" --head "$HEAD" --table "$TABLE" --check "$OUT" > "$WORK/check.txt" 2>&1
rc=$?
check "--check fails once a rule was added to the source" "$([ "$rc" -eq 1 ] && echo ok || echo "exit $rc")"
check "and names the line the copy lacks" "$(has "$WORK/check.txt" "Fourth rule.")"
check "--check never rewrites the copy it judges" "$([ -s "$OUT" ] && cmp -s "$OUT" "$WORK/before.md" && echo ok || echo "it was changed, or there was none")"
printf -- '- L3. a lesson added to the core\n' >> "$FX/LESSONS-CORE-a.md"
render --rules "$FX" --head "$HEAD" --table "$TABLE" --out "$OUT" 2>/dev/null
check "a new render carries a lesson added to the core" "$(has "$OUT" "- L3. a lesson added to the core")"
render --rules "$FX" --head "$HEAD" --table "$TABLE" --check "$WORK/no-such-copy.md" > "$WORK/check.txt" 2>&1
check "--check fails on a copy that is not there" "$([ $? -eq 1 ] && echo ok || echo "it did not exit 1")"

# ---- how a session comes to use the type: the orchestrate skill and the agent rules ----
SKILL="${BUILDER_TYPE_SKILL:-$DIR/SKILL.md}"
AGENT_RULES="${BUILDER_TYPE_AGENT_RULES:-$DIR/agent-rules.md}"
TYPE_HOME="### Which agent type a builder runs as"
homes="$(grep -c -x -F -- "$TYPE_HOME" "$SKILL" 2>/dev/null || true)"
check "the orchestrate skill says which agent type a builder runs as, once" "$([ "${homes:-0}" -eq 1 ] && echo ok || echo "'$TYPE_HOME' is a heading ${homes:-0} times in $(basename "$SKILL")")"
section="$(awk -v h="$TYPE_HOME" '$0 == h { on = 1; next } on && /^#/ { exit } on { print }' "$SKILL" 2>/dev/null)"
printf '%s\n' "$section" > "$WORK/section.txt"
in_section() { grep -qF -- "$1" "$WORK/section.txt" && echo ok || echo "the section does not say '$1'"; }
check "it names the type as the Agent call takes it" "$(in_section 'subagent_type: "builder"')"
# A type the session's list lacks fails the Agent call, and the type is on a Mac only once that
# Mac has rendered it, so the instruction has to turn on what the session can see.
check "it turns on the Agent tool listing the type, and says what to do where it does not" \
  "$([ "$(in_section "list of agent types names \`builder\`")" = ok ] && [ "$(in_section "leave the type out")" = ok ] && echo ok || echo "the condition or the fallback is missing")"
check "it keeps read only items off the type, which has no connected server" "$(in_section 'A `check` or `investigate` item')"
check "it says the model rule holds and the type sets no model" "$([ "$(in_section "The model rule above holds")" = ok ] && [ "$(in_section "sets no model")" = ok ] && echo ok || echo "one of the two is missing")"
check "it says the brief names any memory file, since the type loads no memory index" "$(in_section "names any memory file")"
check "it says the type reads the project's own instructions itself" "$(in_section "told to read that file first")"
# Dan, 2026-11-25 ("Cut the UI sections first"): the type no longer carries the two UI sections, so
# the brief for an item that works on a screen sends the builder to them. A brief that does not say
# so leaves a screen built without its rules and nothing in the type to say they were missing.
check "it says a brief for an item on a screen names the two UI sections the type leaves out" \
  "$([ "$(in_section "anything a person sees on a screen")" = ok ] && [ "$(in_section '"Progress & Feedback (UI)"')" = ok ] && [ "$(in_section '"Building UI"')" = ok ] && echo ok || echo "the condition or one of the two section names is missing")"
# The agent rules send every agent to the global rules for the no verdict rule, "which you already
# have loaded". A builder of this type has not loaded them: the rule is in its prompt.
check "the agent rules say where a builder typed agent finds the no verdict rule" "$(has "$AGENT_RULES" "written out in your own prompt")"
dashes="$(grep -n -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' "$DIR/builder-type-head.md" "$DIR/builder-type-rules.tsv" "$DIR/render-builder-type.py" 2>/dev/null)"
check "the type's head, table and renderer hold no em or en dash" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

# ---- the real payload ----
if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD/CLAUDE.md" ]; then
  echo "test-builder-type: not in a checkout of the config, so the payload's own rules were not rendered here."
  printf 'SUITE-UNMEASURED %s\n' "the payload checks need a checkout holding payload/CLAUDE.md"
else
  REAL="$WORK/real.md"
  render --strict --out "$REAL" 2> "$WORK/real-err.txt"
  rc=$?
  # One check carries the three ways the table can fall behind CLAUDE.md: a section with no row, a
  # row whose section is gone, a drop or keep row that matches no item. The message is the
  # renderer's own, which names each one.
  check "every section of the payload's CLAUDE.md has a recorded choice and every row still matches" \
    "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: $(tr '\n' ' ' < "$WORK/real-err.txt" | cut -c1-600)")"
  front_of() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on { print }' "$1" 2>/dev/null; }
  tools_of() { front_of "$1" | sed -n 's/^tools: *//p' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'; }
  # The model rule (claude-config#1961) sets a builder's model on each dispatch. A model written
  # in the type would answer for a dispatch that named none, behind the gate's back.
  sets_model() { front_of "$1" > "$WORK/front-model.txt"; grep -q '^model:' "$WORK/front-model.txt"; }
  # A connected server is told from a mod by where it comes from, never by a list kept here (L96):
  # a server this repository ships as a mod that registers a tool is the session's own, as is
  # Claude Code's browser extension. Anything else is a connector, and so is a wildcard, which
  # would take every server a Mac has connected.
  strangers_of() {   # $1 = a rendered type -> the entries of its tool list that are not its own
    local t server out=""
    while IFS= read -r t; do
      case "$t" in
        '*'|'mcp__*') out="$out $t"; continue ;;
        mcp__*) ;;
        *) continue ;;
      esac
      server="${t#mcp__}"; server="${server%%__*}"
      [ "$server" = "claude-in-chrome" ] && continue
      if [ -d "$PAYLOAD/mods/$server" ] && grep -rqs 'tool\.register' "$PAYLOAD/mods/$server/hooks"; then continue; fi
      out="$out $t"
    done <<TOOLS
$(tools_of "$1")
TOOLS
    printf '%s' "${out# }"
  }
  # Each list goes to a file that grep reads, never down a pipe to a grep that stops at its first
  # match: under pipefail that can report a failure that never happened (test-pipefail-shortcircuit.sh).
  front_of "$REAL" > "$WORK/front.txt"
  check "the type is named builder" "$(grep -qx 'name: builder' "$WORK/front.txt" && echo ok || echo "its frontmatter opens: $(sed -n 1,3p "$WORK/front.txt" | tr '\n' '|')")"
  check "the type does not load the rule files" "$(grep -qx 'omitClaudeMd: true' "$WORK/front.txt" && echo ok || echo "omitClaudeMd: true is not in its frontmatter")"
  check "the type sets no model of its own" "$([ -s "$WORK/front.txt" ] && ! sets_model "$REAL" && echo ok || echo "its frontmatter sets one, or there is none")"
  tools="$(tools_of "$REAL")"
  printf '%s\n' "$tools" > "$WORK/tools.txt"
  check "the type has a tool list, so it does not inherit every connected server" \
    "$([ -n "$tools" ] && echo ok || echo "its frontmatter has no tools line")"
  for want in Bash Read Edit Write Skill SubagentHandback mcp__area-check mcp__job-watcher; do
    check "the tool list keeps $want" "$(grep -qx -- "$want" "$WORK/tools.txt" && echo ok || echo "it is not listed")"
  done
  strangers="$(strangers_of "$REAL")"
  check "the tool list names no connected server" "$([ -n "$tools" ] && [ -z "$strangers" ] && echo ok || echo "it names: $strangers, or there is no list")"
  # The same three questions asked of a head that gets each one wrong, so they are seen to fail
  # (L1): a connector by name, every server at once, a mod this repository does not ship, a model.
  BADHEAD="$WORK/bad-tools-head.md"
  sed 's/^tools: \(.*\)$/tools: \1, mcp__claude_ai_Slack, mcp__*, mcp__not-a-mod-here__thing/' "$DIR/builder-type-head.md" \
    | awk '{ print } $0 == "omitClaudeMd: true" { print "model: sonnet" }' > "$BADHEAD"
  BAD="$WORK/bad-tools.md"
  render --head "$BADHEAD" --out "$BAD" 2>/dev/null
  bad_strangers="$(strangers_of "$BAD")"
  # Whole entries, one a line, matched as fixed text: the entry for every server holds a `*`.
  printf '%s\n' "$bad_strangers" | tr ' ' '\n' > "$WORK/bad-strangers.txt"
  caught() { grep -qxF -- "$1" "$WORK/bad-strangers.txt" && echo ok || echo "caught only: $bad_strangers"; }
  check "a connector named in the tool list is caught" "$(caught 'mcp__claude_ai_Slack')"
  check "a tool list that takes every server at once is caught" "$(caught 'mcp__*')"
  check "a server that is no mod of this repository is caught" "$(caught 'mcp__not-a-mod-here__thing')"
  check "the mods a builder keeps are not caught with them" \
    "$(grep -q -e area-check -e job-watcher -e claude-in-chrome "$WORK/bad-strangers.txt" && echo "caught: $bad_strangers" || echo ok)"
  check "a model written into the type is caught" "$(sets_model "$BAD" && echo ok || echo "a head with a model line passed")"
  check "the payload's lessons reach the rendered prompt" "$(has "$REAL" "- L1. A test or guard is only real once it has been seen to fail.")"
  check "the shell rules reach it" "$(has "$REAL" "## Shell Commands")"
  check "the git rules reach it" "$(has "$REAL" "Never credit Claude as the author of anything")"
  check "the writing rules reach it" "$(has "$REAL" "No dashes as punctuation")"
  check "the test first rule reaches it" "$(has "$REAL" "**Test first, in the same commit:**")"
  check "the no verdict rule, whose one home is the global rules, reaches it" "$(has "$REAL" "**One unchanged resend after no verdict**")"
  check "the rule against weakening a security control reaches it" "$(has "$REAL" "Never weaken a security control")"
  # The two UI sections are left out (Dan, 2026-11-25, "Cut the UI sections first"), and the head
  # sends a builder whose item works on a screen to them, by name, in the file that holds them.
  check "the Progress & Feedback (UI) section is not carried" "$(lacks "$REAL" "## Progress & Feedback (UI)")"
  check "the Building UI section is not carried" "$(lacks "$REAL" "## Building UI")"
  check "the head tells a builder working on a screen to read the two UI sections first" \
    "$([ "$(has "$REAL" "anything a person sees on a screen")" = ok ] && [ "$(has "$REAL" '"Progress & Feedback (UI)" and "Building UI"')" = ok ] && [ "$(has "$REAL" 'the global rules file, `~/.claude/CLAUDE.md`')" = ok ] && echo ok || echo "the condition, a section name or the file is missing from the head")"
  size="$(wc -c < "$REAL" 2>/dev/null | tr -d ' ')"
  check "the rendered prompt is inside its budget of $BUDGET bytes" \
    "$([ "${size:-0}" -gt 0 ] && [ "$size" -le "$BUDGET" ] && echo ok || echo "it is ${size:-0} bytes")"
  # The decisions table a person reads before a merge, from the same parse.
  render --decisions > "$WORK/decisions.md" 2>/dev/null
  sections="$(grep -c '^## ' "$PAYLOAD/CLAUDE.md")"
  rows="$(grep -c '^| ' "$WORK/decisions.md")"
  check "the decisions table has a row for the top of the file and one for each of the $sections sections" \
    "$([ "$rows" -eq $((sections + 3)) ] && echo ok || echo "$rows lines against $sections sections plus the header, its rule and the top of the file")"
fi

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
