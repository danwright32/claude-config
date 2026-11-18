#!/usr/bin/env bash
# Tests for check-duplication.sh and its detector lib/duplication.py (claude-config#428).
#
# Two layers, because the two questions are different. The detector is driven directly over fixture
# trees, with the review's real Slate lines as positive controls (L1: a guard that has never been
# seen to fail is not a guard). The hook is driven end to end with a payload on stdin against
# fixture git repos, so the base is a real merge base and the pushed side is a real HEAD or a real
# working tree, never a re-implementation of either rule inside this file.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-duplication.sh"
DETECTOR="$DIR/lib/duplication.py"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.dupcheck-test.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

pass=0
fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
want_eq(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
want_has(){ case "$3" in *"$2"*) ok ;; *) bad "$1: expected to contain [$2], got: $3" ;; esac; }
# want_notice <desc> <ERE> <stdout>: what a push let through says is one JSON systemMessage. The
# hooks documentation says a PreToolUse hook's plain stdout on exit 0 goes to the debug log, not the
# transcript, so a line printed plain was read by nobody (claude-config#1906).
. "$DIR/lib/hook-notice.sh"
want_notice(){ local why; why="$(hook_notice_verdict "$3" "$2")"; if [ -z "$why" ]; then ok; else bad "#1906 $1: $why"; fi; }
want_lacks(){ case "$3" in *"$2"*) bad "$1: must not contain [$2], got: $3" ;; *) ok ;; esac; }

# ---------------------------------------------------------------------------------------------
# The review's real lines, lifted from Slate main fc7397d7. Each is long enough on its own to clear
# the detector's single line floor (100 characters, a value the code sets, not measured); the block
# fixture clears the two line window floor (160 characters, likewise set).
# ---------------------------------------------------------------------------------------------
BOOKER_A='className={`inline-flex min-h-12 items-center justify-center rounded-lg border px-5 text-sm font-semibold disabled:opacity-60 ${c.toggleBorder} ${c.body} ${c.navHover}`}'
# The same class string with a DIFFERENT variable appended: the blanked interpolation is what
# groups these, and without it the review saw eleven different lines.
BOOKER_B='className={`inline-flex min-h-12 items-center justify-center rounded-lg border px-5 text-sm font-semibold disabled:opacity-60 ${other.toggleBorder} ${other.body} ${other.navHover}`}'
SVG_1='<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true" className="shrink-0 text-fg-muted">'
SVG_2='<path d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" strokeLinecap="round" strokeLinejoin="round" className="text-fg" />'
LONG_LINE='const message = err instanceof Error ? err.message : String(err); // one long line, written once here, and copied nowhere'

# A fixture tree: $1 = root dir; then pairs of <relative path> <content>
mk_tree(){
  local root="$1"; shift
  while [ $# -ge 2 ]; do
    mkdir -p "$root/$(dirname "$1")"
    printf '%s\n' "$2" > "$root/$1"
    shift 2
  done
}
scan(){ python3 "$DETECTOR" scan "$1" 2>&1; }
compare(){ python3 "$DETECTOR" compare "$1" "$2" 2>&1; }
group_count(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["groups"]))' <<< "$1"; }

# --- positive control: the Booker class string, three copies, once interpolations are blanked ---
T="$WORKDIR/booker"
# Each className sits on a line of its own, as the formatter leaves them in Slate; that is the
# shape the review saw and the shape the line rule judges.
mk_tree "$T" \
  src/components/Booker.tsx "$(printf 'export function Booker() {\n  return (\n    <button\n      type="button"\n      %s\n    >\n      go\n    </button>\n  );\n}\nfunction Other() {\n  return (\n    <a\n      href="/x"\n      %s\n    >\n      x\n    </a>\n  );\n}\n' "$BOOKER_A" "$BOOKER_B")" \
  src/components/Manage.tsx "$(printf 'export function Manage() {\n  return (\n    <button\n      type="submit"\n      %s\n    >\n      ok\n    </button>\n  );\n}\n' "$BOOKER_A")"
out="$(scan "$T")"
want_eq "the review's Booker class string is one group" 1 "$(group_count "$out")"
want_has "and it has three copies" '"copies": 3' "$out"
want_has "and the variable appended at the end was blanked" '${} ${} ${}' "$out"
want_has "and it names the file that holds two of them" 'src/components/Booker.tsx' "$out"

# --- positive control: a two line JSX block written into two components (the block shape) ---
T="$WORKDIR/block"
mk_tree "$T" \
  src/components/A.tsx "$(printf 'export function A() {\n  return (\n    %s\n      %s\n    </svg>\n  );\n}\n' "$SVG_1" "$SVG_2")" \
  src/components/B.tsx "$(printf 'export function B() {\n  return (\n    <span>\n    %s\n      %s\n    </svg>\n    </span>\n  );\n}\n' "$SVG_1" "$SVG_2")"
out="$(scan "$T")"
want_has "a two line block in two files is a group" '"kind": "block"' "$out"
want_has "and it points at both files" 'src/components/B.tsx' "$out"

# --- and the negative it must not see ---
T="$WORKDIR/clean"
mk_tree "$T" \
  src/a.ts "$(printf 'export function a() {\n  %s\n}\n' "$LONG_LINE")" \
  src/b.ts "$(printf 'export function b() {\n  return 2;\n}\n' )"
out="$(scan "$T")"
want_eq "a long line written once is not a group" 0 "$(group_count "$out")"

# --- what is deliberately not read ---
T="$WORKDIR/skips"
mk_tree "$T" \
  src/a.test.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")" \
  src/__tests__/b.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")" \
  src/fixtures/c.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")" \
  src/types.d.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")" \
  src/node_modules/x/y.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")" \
  src/data.json "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")" \
  scripts/test-thing.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")" \
  docs/notes.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")"
out="$(scan "$T")"
want_eq "tests, fixtures, .d.ts, node_modules, non code and files outside the roots are not read" 0 "$(group_count "$out")"
# The control for the skip list: the same content in a plain source file IS seen, so the zero above
# is the skip list working and not the scan reading nothing (L98).
mk_tree "$T" src/plain.ts "$(printf '%s\n%s\n' "$BOOKER_A" "$BOOKER_A")"
out="$(scan "$T")"
want_eq "the same content in a plain source file is seen" 1 "$(group_count "$out")"

# --- a trivial line between two copied lines does not hide the block ---
T="$WORKDIR/trivial"
mk_tree "$T" \
  src/a.tsx "$(printf '%s\n  );\n  %s\n' "$SVG_1" "$SVG_2")" \
  src/b.tsx "$(printf '%s\n%s\n' "$SVG_1" "$SVG_2")"
out="$(scan "$T")"
want_has "a bracket only line between the two copied lines does not break the window" '"kind": "block"' "$out"

# --- comments are not copies ---
T="$WORKDIR/comments"
mk_tree "$T" \
  src/a.tsx "$(printf '{/* %s\n   %s */}\n' "$SVG_1" "$SVG_2")" \
  src/b.tsx "$(printf '{/* %s\n   %s */}\n' "$SVG_1" "$SVG_2")"
out="$(scan "$T")"
want_eq "the body of a block comment is not a copy" 0 "$(group_count "$out")"

# --- a six line block is ONE finding, not five overlapping windows ---
BASE="$WORKDIR/run-base"; PUSHED="$WORKDIR/run-pushed"
mk_tree "$BASE" src/a.ts 'export const nothing = 1;'
SIX="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$SVG_1" "$SVG_2" "$BOOKER_A" "$LONG_LINE" "$SVG_1" "$BOOKER_B")"
mk_tree "$PUSHED" src/a.ts "$SIX" src/b.ts "$SIX"
out="$(compare "$BASE" "$PUSHED")"
want_has "adjacent new windows with the same copies are merged into one block" 'copies of the same 6 line block' "$out"
want_lacks "and no 2 line fragment of it is reported beside it" 'the same 2 line block' "$out"
want_lacks "and none of its lines is reported again on its own" 'copies of the same line' "$out"
# The control for that: the same long line copied to a site OUTSIDE the block is still its own
# finding, so the silence above is the overlap rule and not the line shape going quiet (L98).
mk_tree "$PUSHED" src/c.ts "$(printf 'export function c() {\n  %s\n}\n' "$LONG_LINE")"
out="$(compare "$BASE" "$PUSHED")"
want_has "a copy outside every block keeps its own line finding" '3 copies of the same line' "$out"
want_has "and it is the outside site that is named" 'src/c.ts:2' "$out"

# --- the verdict is a comparison: existing duplication never fails, growth does ---
BASE="$WORKDIR/cmp-base"; PUSHED="$WORKDIR/cmp-same"; GROWN="$WORKDIR/cmp-grown"
mk_tree "$BASE" src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_A"
mk_tree "$PUSHED" src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_A" src/c.tsx 'export const unrelated = "nothing copied here at all";'
out="$(compare "$BASE" "$PUSHED")"; rc=$?
want_eq "two copies at the base and two in the push is not a finding" 0 "$rc"
want_has "and the summary says how many groups the tree already holds" 'groups=1 new=0' "$out"
mk_tree "$GROWN" src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_A" src/c.tsx "$BOOKER_B"
out="$(compare "$BASE" "$GROWN")"; rc=$?
want_eq "a third copy of a line the base held twice is a finding" 1 "$rc"
want_has "and the message says how many the base had" 'the base had 2' "$out"
want_has "and names the new site" 'src/c.tsx:1' "$out"
# A rename moves both copies and adds none.
MOVED="$WORKDIR/cmp-moved"
mk_tree "$MOVED" src/x/a.tsx "$BOOKER_A" src/x/b.tsx "$BOOKER_A"
out="$(compare "$BASE" "$MOVED")"; rc=$?
want_eq "moving both copies into another directory adds nothing" 0 "$rc"

# ---------------------------------------------------------------------------------------------
# Generated sections inside a hand written file (claude-config#3187). The shape is the one a work
# repository met: a generator stamps one guard trigger template out once per copied table into a
# SQL file, between an opening comment naming the generator and `-- <<< END GENERATED`, and the
# template itself lives once in a hand written helper. Before this, the check read the stamped
# copies as 18 copies and the template as a copy of its own output.
# ---------------------------------------------------------------------------------------------
GUARD_1='perform guard_copied_table_write(tg_op, tg_table_name, to_jsonb(old), to_jsonb(new), current_setting(sync_source_key, true));'
GUARD_2='raise exception using message = format(copied_table_message_template, tg_table_name), errcode = copied_table_errcode;'
GEN_OPEN='-- >>> GENERATED by scripts/gen-guards.ts from the copied table list. Do not edit by hand.'
GEN_CLOSE='-- <<< END GENERATED'
GEN_SCRIPT='export function main() { return renderGuards(readCopiedTables()); }'
# stamped <n>: n copies of the template, as the generator prints them
stamped(){
  local i
  for i in $(seq 1 "$1"); do
    printf 'create function guard_t%s() returns trigger as $$ begin\n%s\n%s\nend $$ language plpgsql;\n' "$i" "$GUARD_1" "$GUARD_2"
  done
}
HAND_SQL='create table hand_written_settings (id bigint primary key, value text not null, updated_at timestamptz);'
GEN_EMPTY="$WORKDIR/gen-base"; mk_tree "$GEN_EMPTY" src/db/other.sql "$HAND_SQL"

# A repeat inside a marked section is not reported, and the skip is SAID, with where and by what.
T="$WORKDIR/gen-marked"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/db/guards.sql "$(printf '%s\n%s\n%s\n%s\n' "$HAND_SQL" "$GEN_OPEN" "$(stamped 3)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 three stamped copies inside a marked generated section are not a finding" 0 "$rc"
want_has "#3187 and the summary counts the section and its lines" 'generated_sections=1 generated_lines=14' "$out"
want_has "#3187 and a line says which section was not compared, and what writes it" \
  'generated section not compared: src/db/guards.sql:2-15, written by scripts/gen-guards.ts' "$out"
want_has "#3187 and that the marker is new in this push" '(new in this push)' "$out"

# The template paired with its own output: the template is hand written and read, the output is not.
T="$WORKDIR/gen-template"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/lib/guard-template.ts "$(printf 'export const GUARD = `\n%s\n%s\n`;\n' "$GUARD_1" "$GUARD_2")" \
  src/db/guards.sql "$(printf '%s\n%s\n%s\n' "$GEN_OPEN" "$(stamped 1)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 the template is not paired with the section it generates" 0 "$rc"
# The control for both: the same files with the markers taken out ARE refused, so the two zeros
# above are the markers working and not the content falling under a floor (L1).
T="$WORKDIR/gen-unmarked"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/lib/guard-template.ts "$(printf 'export const GUARD = `\n%s\n%s\n`;\n' "$GUARD_1" "$GUARD_2")" \
  src/db/guards.sql "$(printf '%s\n%s\n' "$HAND_SQL" "$(stamped 3)")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 control: the same copies with no markers are a finding" 1 "$rc"
want_has "#3187 control: and the template is named beside them" 'src/lib/guard-template.ts' "$out"

# An unmarked repeat in the same file is still caught, and only it is.
T="$WORKDIR/gen-mixed"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/db/guards.sql "$(printf '%s\n%s\n%s\n%s\n%s\n' "$HAND_SQL" "$GEN_OPEN" "$(stamped 3)" "$GEN_CLOSE" "$HAND_SQL")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 a hand written repeat outside the section in the same file is still refused" 1 "$rc"
want_has "#3187 and it is the only finding" 'new=1' "$out"
want_has "#3187 and it names the copy after the section" 'src/db/guards.sql:16' "$out"

# A marker with no closing marker silences nothing: everything after it is read, and it says why.
T="$WORKDIR/gen-unclosed"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/db/guards.sql "$(printf '%s\n%s\n%s\n' "$GEN_OPEN" "$(stamped 2)" "$HAND_SQL")" \
  src/db/more.sql "$HAND_SQL"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 an opening marker with no closing marker silences nothing" 1 "$rc"
want_has "#3187 so the copies after it are reported" 'src/db/guards.sql:3-4' "$out"
want_has "#3187 and so is a repeat later in the file" 'src/db/guards.sql:10' "$out"
want_has "#3187 and it says the marker was not honoured, and why" \
  'marker not honoured: src/db/guards.sql:1 opens a generated section that is never closed' "$out"
want_has "#3187 and the summary counts no section" 'generated_sections=0' "$out"

# A second opening marker before the first closes: the first is not honoured, the second is.
T="$WORKDIR/gen-reopened"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/db/guards.sql "$(printf '%s\n%s\n%s\n%s\n%s\n' "$GEN_OPEN" "$(stamped 2)" "$GEN_OPEN" "$(stamped 2)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 an opening marker inside an open section leaves the first section's copies read" 1 "$rc"
want_has "#3187 and says the first marker was never closed" 'src/db/guards.sql:1 opens a generated section that is never closed' "$out"
want_has "#3187 and the second section is the one honoured" 'src/db/guards.sql:10-19' "$out"

# A closing marker with no opening one silences nothing either.
T="$WORKDIR/gen-closeonly"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/db/guards.sql "$(printf '%s\n%s\n' "$(stamped 2)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 a closing marker alone silences nothing" 1 "$rc"

# A marker must name a generator that is in the repository, and not the file it sits in.
T="$WORKDIR/gen-nogen"
mk_tree "$T" src/db/guards.sql "$(printf '%s\n%s\n%s\n' "$GEN_OPEN" "$(stamped 2)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 a marker naming a generator the repository does not hold is not honoured" 1 "$rc"
want_has "#3187 and it says the generator is missing" \
  'marker not honoured: src/db/guards.sql:1 names scripts/gen-guards.ts as its generator, which is not in the repository' "$out"
T="$WORKDIR/gen-self"
mk_tree "$T" src/db/guards.sql "$(printf '%s\n%s\n%s\n' '-- GENERATED by src/db/guards.sql. Do not edit by hand.' "$(stamped 2)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 a marker naming its own file as the generator is not honoured" 1 "$rc"
want_has "#3187 and it says so" 'names its own file as its generator' "$out"
T="$WORKDIR/gen-noname"
mk_tree "$T" src/db/guards.sql "$(printf '%s\n%s\n%s\n' '-- GENERATED by hand. Do not edit by hand.' "$(stamped 2)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 a marker whose generator is not a path in the repository is not honoured" 1 "$rc"
want_has "#3187 and it names what it read as the generator" 'names hand as its generator' "$out"
# Without "Do not edit by hand" a GENERATED by comment is not a marker, and it says so.
T="$WORKDIR/gen-nophrase"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/db/guards.sql "$(printf '%s\n%s\n%s\n' '-- >>> GENERATED by scripts/gen-guards.ts' "$(stamped 2)" "$GEN_CLOSE")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 an opening comment without Do not edit by hand is not a marker" 1 "$rc"
want_has "#3187 and it says what the marker lacks" 'does not say Do not edit by hand' "$out"

# A marked section against hand written code outside it, decided: the section is not read at all,
# exactly like a whole .generated. file, so one hand written copy of a generated line is not
# paired with it; two hand written copies are still a finding between themselves.
T="$WORKDIR/gen-outside1"
mk_tree "$T" scripts/gen-guards.ts "$GEN_SCRIPT" \
  src/db/guards.sql "$(printf '%s\n%s\n%s\n' "$GEN_OPEN" "$(stamped 2)" "$GEN_CLOSE")" \
  src/lib/a.ts "$(printf 'const sql = `\n%s\n`;\n' "$GUARD_1")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 one hand written copy of a generated line is not paired with the section" 0 "$rc"
mk_tree "$T" src/lib/b.ts "$(printf 'const sql = `\n%s\n`;\n' "$GUARD_1")"
out="$(compare "$GEN_EMPTY" "$T")"; rc=$?
want_eq "#3187 two hand written copies of it are a finding" 1 "$rc"
want_has "#3187 counted between the two hand written sites only" '2 copies of the same line' "$out"
want_lacks "#3187 and never naming the section" 'src/db/guards.sql:' "$(printf '%s\n' "$out" | grep -v '^generated section')"

# A file list that cannot be read is an error (exit 2), never a quiet fall back to asking the tree,
# which would call a generator outside the source roots missing.
T="$WORKDIR/gen-marked"
out="$(python3 "$DETECTOR" compare "$GEN_EMPTY" "$T" --pushed-files 2>&1)"; rc=$?
want_eq "#3187 --pushed-files with no file after it is an error" 2 "$rc"
want_has "#3187 and says which flag" '--pushed-files needs a file after it' "$out"
out="$(python3 "$DETECTOR" compare "$GEN_EMPTY" "$T" --base-files "$WORKDIR/no-such-list" 2>&1)"; rc=$?
want_eq "#3187 a --base-files list that cannot be opened is an error" 2 "$rc"
want_has "#3187 and says a file list could not be read" 'a file list could not be read' "$out"
out="$(python3 "$DETECTOR" scan "$T" --repo-files "$WORKDIR/no-such-list" 2>&1)"; rc=$?
want_eq "#3187 scan with a --repo-files list that cannot be opened is an error" 2 "$rc"
# And a list that is read is what decides: one that lacks the generator refuses the marker even
# though the file sits in the tree.
printf '%s\n' src/db/guards.sql > "$WORKDIR/list-without-gen"
out="$(python3 "$DETECTOR" compare "$GEN_EMPTY" "$T" --pushed-files "$WORKDIR/list-without-gen" 2>&1)"; rc=$?
want_eq "#3187 the pushed file list, not the tree, says whether the generator is there" 1 "$rc"
want_has "#3187 and the marker is refused for it" 'which is not in the repository' "$out"

# The base honours the same markers, so a marked section already there is not new in this push.
T="$WORKDIR/gen-marked"
out="$(compare "$T" "$T")"; rc=$?
want_eq "#3187 an unchanged marked section is not a finding" 0 "$rc"
want_lacks "#3187 and is not called new" '(new in this push)' "$out"

# ---------------------------------------------------------------------------------------------
# The hook, end to end.
# ---------------------------------------------------------------------------------------------
G=(git -c user.name=t -c user.email=t@t)

# A repo with a clean base pushed to an origin, then whatever files $@ names committed on top.
#   mk_repo <name> <base file> <base content> [<file> <content>]...
mk_repo(){
  local name="$1"; shift
  local root="$WORKDIR/repo-$name"
  mkdir -p "$root"
  "${G[@]}" init -q --bare "$root/origin.git"
  "${G[@]}" init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; shift 2
    "${G[@]}" add -A; "${G[@]}" commit -qm base
    "${G[@]}" remote add origin "$root/origin.git"
    "${G[@]}" push -qu origin main
    if [ $# -ge 2 ]; then
      while [ $# -ge 2 ]; do mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; shift 2; done
      "${G[@]}" add -A; "${G[@]}" commit -qm change
    fi
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
run_hook(){  # $1 cwd, $2 command -> HOOK_RC, HOOK_ERR (stderr), HOOK_OUT (stdout)
  local p
  p="$(HK_CMD="$2" HK_CWD="$1" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  HOOK_ERR="$(printf '%s' "$p" | bash "$HOOK" 2>&1 >"$WORKDIR/hook-out")"; HOOK_RC=$?
  HOOK_OUT="$(cat "$WORKDIR/hook-out")"
}

# 1. The canary: a push that adds a duplicate pair is refused, and the refusal names file and line.
W="$(mk_repo canary src/clean.ts 'export const clean = 1;' src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_B")"
run_hook "$W" "git push"
want_eq "a push adding a duplicate pair is blocked" 2 "$HOOK_RC"
want_has "and says the push adds it" "this push adds duplicated code" "$HOOK_ERR"
want_has "and names the first site" "src/a.tsx:1" "$HOOK_ERR"
want_has "and the second" "src/b.tsx:1" "$HOOK_ERR"
want_has "and shows the copied text" "inline-flex min-h-12" "$HOOK_ERR"
want_has "and says what to do" "one shared function, component or constant" "$HOOK_ERR"
want_has "and how to override" "SKIP_DUPLICATION_CHECK=1" "$HOOK_ERR"
want_has "and that an override is explained first" "explain to the user" "$HOOK_ERR"
want_has "and says what it compared against" "Compared against" "$HOOK_ERR"
want_lacks "and does not claim a working tree reading it did not take" "working tree" "$HOOK_ERR"

# 2. The same push from a session rooted elsewhere, reaching the repo through the command.
run_hook "$WORKDIR" "cd $W && git push"
want_eq "cd-then-push from a non-repo cwd is still judged" 2 "$HOOK_RC"
run_hook "$WORKDIR" "git -C $W push"
want_eq "git -C push from a non-repo cwd is still judged" 2 "$HOOK_RC"

# 3. Existing duplication never fails a push: the base already holds the pair, the push adds a
#    file that copies nothing. Built by hand because mk_repo's base takes one file.
W="$WORKDIR/repo-existing"
mkdir -p "$W"; "${G[@]}" init -q --bare "$W/origin.git"; "${G[@]}" init -q -b main "$W/work"
(
  cd "$W/work" || exit 1
  mkdir -p src; printf '%s\n' "$BOOKER_A" > src/a.tsx; printf '%s\n' "$BOOKER_B" > src/b.tsx
  "${G[@]}" add -A; "${G[@]}" commit -qm base
  "${G[@]}" remote add origin "$W/origin.git"; "${G[@]}" push -qu origin main
  printf '%s\n' 'export const c = "a new file that copies nothing at all, however long this line is made to be";' > src/c.ts
  "${G[@]}" add -A; "${G[@]}" commit -qm change
) >/dev/null 2>&1
run_hook "$W/work" "git push"
want_eq "duplication already at the base does not block a push" 0 "$HOOK_RC"
want_has "and the pass says what it measured" "no new duplicate groups" "$HOOK_OUT"
want_has "and how many groups the tree already holds" "groups=1" "$HOOK_OUT"
want_notice "and says it where the person sees it" "no new duplicate groups" "$HOOK_OUT"

# 4. A repo with none of the source roots skips OUT LOUD.
W="$(mk_repo noroots README.md 'just a readme' docs/a.md "$BOOKER_A")"
run_hook "$W" "git push"
want_eq "a repo with no source roots is allowed" 0 "$HOOK_RC"
want_has "and says it skipped" "duplication check: skipped" "$HOOK_OUT"
want_has "and names the roots it looks for" "src, app, lib, components, worker, scripts" "$HOOK_OUT"
want_notice "and says it where the person sees it" "duplication check: skipped" "$HOOK_OUT"

# 5. The escape hatch, and it says so.
W="$(mk_repo hatch src/clean.ts 'export const clean = 1;' src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_B")"
run_hook "$W" "SKIP_DUPLICATION_CHECK=1 git push"
want_eq "the escape hatch allows the push" 0 "$HOOK_RC"
want_has "and prints that it skipped rather than passing silently" "SKIP_DUPLICATION_CHECK=1" "$HOOK_OUT"
want_notice "and says it where the person sees it" "skipped because the command carries SKIP_DUPLICATION_CHECK=1" "$HOOK_OUT"

# 6. Not a push: silent.
run_hook "$W" "git status"
want_eq "a non push command is ignored" 0 "$HOOK_RC"
want_eq "silently" "" "$HOOK_OUT$HOOK_ERR"
# A command that merely MENTIONS a push is not one (leading tokens, not substrings).
run_hook "$W" "echo 'git push'"
want_eq "a command that only mentions a push is ignored" 0 "$HOOK_RC"

# 7. Commit and push in one command: nothing is in history yet, so what the commit will carry is
#    read (the index, plus what the add names), and the refusal says so. A plain push on the same
#    repo judges the commits only.
W="$(mk_repo pending src/clean.ts 'export const clean = 1;')"
( cd "$W" && printf '%s\n' "$BOOKER_A" > src/a.tsx && printf '%s\n' "$BOOKER_B" > src/b.tsx )
run_hook "$W" "git push"
want_eq "a push on its own ignores uncommitted copies" 0 "$HOOK_RC"
run_hook "$W" "cd $W && git add src && git commit -qm copy && git push"
want_eq "commit and push in one command reads what the commit will carry" 2 "$HOOK_RC"
want_has "and says the commit would add it, not the push" "the commit this command is about to make" "$HOOK_ERR"
want_has "and says what the reading came from" "what the commit will carry" "$HOOK_ERR"
want_lacks "and does not claim a working tree reading it did not take" "Read from the working tree" "$HOOK_ERR"

# 7a. Only what the commit will carry (claude-config#457 item 5). This hook read the WHOLE working
#     tree of its source roots for every commit then push, so a copy sitting in files the add never
#     named, another session's untracked work included, was blamed on this commit (#350).
W="$(mk_repo stranger src/clean.ts 'export const clean = 1;')"
( cd "$W" && printf '%s\n' "$BOOKER_A" > src/a.tsx && printf '%s\n' "$BOOKER_B" > src/b.tsx \
    && printf '%s\n' 'export const mine = 2;' > src/mine.ts )
run_hook "$W" "cd $W && git add src/mine.ts && git commit -qm mine && git push"
want_eq "untracked copies the add does not name are not this commit's" 0 "$HOOK_RC"
#     Reading the pending files says nothing of its own: #1984 put a `local` at the script's top
#     level here, and bash printed "local: can only be used in a function" on every such push.
want_lacks "#1984 reading the pending files prints no shell error" "can only be used in a function" "$HOOK_ERR"
#     The control in the same repository: an add naming both copies carries the pair.
run_hook "$W" "cd $W && git add src/a.tsx src/b.tsx && git commit -qm pair && git push"
want_eq "and naming both copies is judged" 2 "$HOOK_RC"
#     A tracked file edited into a copy but not named stays behind the same way.
W="$(mk_repo trackedleft src/a.tsx "$BOOKER_A" src/clean.ts 'export const clean = 1;')"
( cd "$W" && "${G[@]}" push -q origin main && printf '%s\n' "$BOOKER_B" > src/clean.ts \
    && printf '%s\n' 'export const mine = 2;' > src/mine.ts ) >/dev/null 2>&1
run_hook "$W" "cd $W && git add src/mine.ts && git commit -qm mine && git push"
want_eq "a tracked edit the add does not name is not this commit's" 0 "$HOOK_RC"
run_hook "$W" "cd $W && git commit -qam all && git push"
want_eq "and a commit -a, which takes it, is judged" 2 "$HOOK_RC"

# 7c. An add nobody can read widens to the whole working tree, and the refusal says so.
W="$(mk_repo widened src/clean.ts 'export const clean = 1;')"
( cd "$W" && printf '%s\n' "$BOOKER_A" > src/a.tsx && printf '%s\n' "$BOOKER_B" > src/b.tsx )
run_hook "$W" "cd $W && git add \"src/a.tsx && git commit -qm x && git push"
want_eq "an add that cannot be read is judged on the whole working tree" 2 "$HOOK_RC"
want_has "and says the add could not be read" "could not be read" "$HOOK_ERR"
want_has "and how to settle it" "two separate commands" "$HOOK_ERR"

# 7b. Commit and push in one command on a branch with NO remote ref at all (claude-config#441). The
#     base falls to the local main, which is the branch itself, so a merge base at HEAD says nothing
#     about what the remote holds: the last commit has never been pushed and is part of this push.
#     This hook read HEAD as the base there, so a copy that commit added was never compared.
W="$WORKDIR/repo-localbase"
mkdir -p "$W"
(
  cd "$W" && "${G[@]}" init -q -b main . && mkdir -p src
  printf '%s\n' 'export const clean = 1;' > src/clean.ts
  "${G[@]}" add -A && "${G[@]}" commit -qm base
  printf '%s\n' "$BOOKER_A" > src/a.tsx && printf '%s\n' "$BOOKER_B" > src/b.tsx
  "${G[@]}" add -A && "${G[@]}" commit -qm copy
  printf '%s\n' 'export const other = 2;' > src/c.ts
) >/dev/null 2>&1
run_hook "$W" "cd $W && git add src/c.ts && git commit -qm c && git push -u origin main"
want_eq "commit and push with no remote ref still compares the unpushed last commit" 2 "$HOOK_RC"

# 8. The first push that CREATES the source root has an empty base, so a copy in it is new.
W="$(mk_repo firstroot README.md 'readme first' src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_B")"
run_hook "$W" "git push"
want_eq "a duplicate pair in a brand new src/ is blocked" 2 "$HOOK_RC"
want_has "and the base is described as having none" "the base had none" "$HOOK_ERR"

# 9. A test file added with a copy in it is not a finding.
W="$(mk_repo testfile src/clean.ts 'export const clean = 1;' src/a.tsx "$BOOKER_A" src/a.test.tsx "$BOOKER_A")"
run_hook "$W" "git push"
want_eq "a copy inside a test file is not judged" 0 "$HOOK_RC"

# 10. A merge of main does not make the branch answer for main's copies (claude-config#3054).
#     A branch pushed once merges main in after main gained a duplicated line. From the upstream,
#     the pushed tree held main's pair and the base did not, so the branch was refused for a copy
#     it never wrote. What the merge brought in is set apart by the shared answer every push gate
#     reads (ps_merged_apart, #3015); a copy the conflict resolution adds is still the branch's.
#     The files are Python, a code extension the detector reads, so the fixture writes no screen
#     file (the design round guard held a .tsx one, #3057).
. "$DIR/lib/merged-main-fixture.sh"
DUP_LINE='message = "a long line copied into two places on main, long enough to clear the single line floor of the detector"'
mk_merged(){  # mk_merged <name> <clean|conflict> [line the resolution adds]
  mmf_repo "$WORKDIR/merged-$1" "$2" src/dupe.py "$DUP_LINE
$DUP_LINE
" src/shared.py "${3:-}${3:+
}"
}
W="$(mk_merged mm1 clean)"
if mmf_built "$W" src/dupe.py; then ok; else bad "#3054 the fixture did not build: the branch must track origin/feat and hold main's file through one merge"; fi
run_hook "$W" "git push"
want_eq "#3054 a copy already on main, arriving only through a merge of main, is not this push's" 0 "$HOOK_RC"
want_notice "#3054 and the pass says no new groups" "no new duplicate groups" "$HOOK_OUT"
run_hook "$W" "git commit -q --allow-empty -m more && git push"
want_eq "#3054 the same holds when the command commits before it pushes" 0 "$HOOK_RC"

W="$(mk_merged mm2 conflict "$DUP_LINE")"
if mmf_built "$W" src/dupe.py && grep -q "as the branch has it" "$W/src/shared.py"; then ok; else bad "#3054 the conflict fixture was not resolved into one merge commit"; fi
run_hook "$W" "git push"
want_eq "#3054 a copy the conflict resolution adds is still the branch's, and refused" 2 "$HOOK_RC"
want_has "#3054 the refusal names the file the resolution added it to" "src/shared.py" "$HOOK_ERR"

W="$(mk_merged mm3 conflict "plain resolution text")"
run_hook "$W" "git push"
want_eq "#3054 control: a conflict resolved with text that copies nothing is allowed" 0 "$HOOK_RC"

# When the merge cannot be set apart (no default branch known), the range is judged whole as
# before, never not at all, and the refusal says part of it came in through the merge (L93).
W="$(mk_merged mm4 clean)"
git -C "$W" update-ref -d refs/remotes/origin/main >/dev/null 2>&1
run_hook "$W" "git push"
want_eq "#3054 with no default branch known the merge is not set apart, so main's copy is judged as before" 2 "$HOOK_RC"
want_has "#3054 and the refusal says why the merge was not set apart" "could not be told from the branch's" "$HOOK_ERR"

# 10b. A marked generated section, end to end (claude-config#3187). The generator sits outside the
#     source roots, where the archived trees cannot show it, so the hook must hand the detector the
#     repository's own file list for the marker to be honoured.
MARKED_SQL="$(printf '%s\n%s\n%s\n' '-- >>> GENERATED by tools/gen_guards.py from the copied table list. Do not edit by hand.' "$(stamped 3)" "$GEN_CLOSE")"
W="$(mk_repo genok src/clean.ts 'export const clean = 1;' tools/gen_guards.py 'print("guards")' src/db/guards.sql "$MARKED_SQL")"
run_hook "$W" "git push"
want_eq "#3187 a push adding a marked generated section is allowed" 0 "$HOOK_RC"
want_notice "#3187 and the pass says which section it did not compare, where the person sees it" \
  "generated section not compared: src/db/guards.sql:1-14, written by tools/gen_guards.py" "$HOOK_OUT"
want_has "#3187 and counts it in the summary" "generated_sections=1 generated_lines=14" "$HOOK_OUT"

W="$(mk_repo gennone src/clean.ts 'export const clean = 1;' src/db/guards.sql "$MARKED_SQL")"
run_hook "$W" "git push"
want_eq "#3187 a marker whose generator is not in the repository does not let the copies through" 2 "$HOOK_RC"
want_has "#3187 and the refusal says why the section was read" \
  "names tools/gen_guards.py as its generator, which is not in the repository" "$HOOK_ERR"

# The generator arriving in the same commit as the section: the file list is what that commit carries.
W="$(mk_repo genchain src/clean.ts 'export const clean = 1;')"
mkdir -p "$W/tools" "$W/src/db"
printf '%s\n' 'print("guards")' > "$W/tools/gen_guards.py"
printf '%s\n' "$MARKED_SQL" > "$W/src/db/guards.sql"
run_hook "$W" "cd $W && git add tools src && git commit -qm gen && git push"
want_eq "#3187 a generator committed in the same command as its section is found" 0 "$HOOK_RC"
want_notice "#3187 and the section is named as not compared" "generated section not compared: src/db/guards.sql:1-14" "$HOOK_OUT"
run_hook "$W" "cd $W && git add src && git commit -qm gen && git push"
want_eq "#3187 control: when that commit leaves the generator out, the section is read" 2 "$HOOK_RC"

# A file list the hook cannot read skips OUT LOUD rather than judging without it. A git on the PATH
# that fails only the listing call FAIL_LIST names (tree: the whole tree listing, index: the index
# listing), and passes everything else to the real one.
REAL_GIT="$(command -v git)"
mkdir -p "$WORKDIR/failing-git"
cat > "$WORKDIR/failing-git/git" <<SHIM
#!/usr/bin/env bash
[ "\${FAIL_LIST:-}" = tree ] && [ "\$1" = ls-tree ] && [ "\$2" = -r ] && exit 128
[ "\${FAIL_LIST:-}" = index ] && [ "\$1" = -C ] && [ "\$3" = ls-files ] && [ \$# -eq 3 ] && exit 128
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$WORKDIR/failing-git/git"
W="$(mk_repo genlist src/clean.ts 'export const clean = 1;' tools/gen_guards.py 'print("guards")' src/db/guards.sql "$MARKED_SQL")"
FAIL_LIST=tree PATH="$WORKDIR/failing-git:$PATH" run_hook "$W" "git push"
want_eq "#3187 a file list that cannot be read lets the push through" 0 "$HOOK_RC"
want_notice "#3187 and says it skipped and why" "duplication check: skipped, the file list at" "$HOOK_OUT"
W="$(mk_repo genidx src/clean.ts 'export const clean = 1;')"
FAIL_LIST=index PATH="$WORKDIR/failing-git:$PATH" run_hook "$W" "cd $W && git commit -q --allow-empty -m x && git push"
want_eq "#3187 an index file list that cannot be read lets the push through" 0 "$HOOK_RC"
want_notice "#3187 and says it skipped and why" "duplication check: skipped, the index file list could not be read" "$HOOK_OUT"

# 11. The header carries the registration line the settings check compares against.
grep -q 'Claude Code PreToolUse(Bash) hook' "$HOOK" && ok || bad "the hook header must declare Claude Code PreToolUse(Bash) hook"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
