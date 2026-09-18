#!/usr/bin/env bash
# Tests for check-duplication.sh and its detector lib/duplication.py (claude-config#428).
#
# Two layers, because the two questions are different. The detector is driven directly over fixture
# trees, with the review's real Slate lines as positive controls (L1: a guard that has never been
# seen to fail is not a guard). The hook is driven end to end with a payload on stdin against
# fixture git repos, so the base is a real merge base and the pushed side is a real HEAD or a real
# working tree, never a re-implementation of either rule inside this file.
set -uo pipefail

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
want_lacks(){ case "$3" in *"$2"*) bad "$1: must not contain [$2], got: $3" ;; *) ok ;; esac; }

# ---------------------------------------------------------------------------------------------
# The review's real lines, lifted from Slate main fc7397d7. Long enough to clear the 100 character
# line floor on their own; the block fixture clears the 160 character window floor.
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

# 4. A repo with none of the source roots skips OUT LOUD.
W="$(mk_repo noroots README.md 'just a readme' docs/a.md "$BOOKER_A")"
run_hook "$W" "git push"
want_eq "a repo with no source roots is allowed" 0 "$HOOK_RC"
want_has "and says it skipped" "duplication check: skipped" "$HOOK_OUT"
want_has "and names the roots it looks for" "src, app, lib, components, worker, scripts" "$HOOK_OUT"

# 5. The escape hatch, and it says so.
W="$(mk_repo hatch src/clean.ts 'export const clean = 1;' src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_B")"
run_hook "$W" "SKIP_DUPLICATION_CHECK=1 git push"
want_eq "the escape hatch allows the push" 0 "$HOOK_RC"
want_has "and prints that it skipped rather than passing silently" "SKIP_DUPLICATION_CHECK=1" "$HOOK_OUT"

# 6. Not a push: silent.
run_hook "$W" "git status"
want_eq "a non push command is ignored" 0 "$HOOK_RC"
want_eq "silently" "" "$HOOK_OUT$HOOK_ERR"
# A command that merely MENTIONS a push is not one (leading tokens, not substrings).
run_hook "$W" "echo 'git push'"
want_eq "a command that only mentions a push is ignored" 0 "$HOOK_RC"

# 7. Commit and push in one command: nothing is in history yet, so the working tree is read, and
#    the refusal says so. A plain push on the same repo judges the commits only.
W="$(mk_repo pending src/clean.ts 'export const clean = 1;')"
( cd "$W" && printf '%s\n' "$BOOKER_A" > src/a.tsx && printf '%s\n' "$BOOKER_B" > src/b.tsx )
run_hook "$W" "git push"
want_eq "a push on its own ignores uncommitted copies" 0 "$HOOK_RC"
run_hook "$W" "cd $W && git add src && git commit -qm copy && git push"
want_eq "commit and push in one command reads the working tree" 2 "$HOOK_RC"
want_has "and says the commit would add it, not the push" "the commit this command is about to make" "$HOOK_ERR"
want_has "and says the reading came from the working tree" "Read from the working tree" "$HOOK_ERR"
want_has "and how to settle it" "two separate commands" "$HOOK_ERR"

# 8. The first push that CREATES the source root has an empty base, so a copy in it is new.
W="$(mk_repo firstroot README.md 'readme first' src/a.tsx "$BOOKER_A" src/b.tsx "$BOOKER_B")"
run_hook "$W" "git push"
want_eq "a duplicate pair in a brand new src/ is blocked" 2 "$HOOK_RC"
want_has "and the base is described as having none" "the base had none" "$HOOK_ERR"

# 9. A test file added with a copy in it is not a finding.
W="$(mk_repo testfile src/clean.ts 'export const clean = 1;' src/a.tsx "$BOOKER_A" src/a.test.tsx "$BOOKER_A")"
run_hook "$W" "git push"
want_eq "a copy inside a test file is not judged" 0 "$HOOK_RC"

# 10. The header carries the registration line the settings check compares against.
grep -q 'Claude Code PreToolUse(Bash) hook' "$HOOK" && ok || bad "the hook header must declare Claude Code PreToolUse(Bash) hook"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
