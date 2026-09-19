#!/usr/bin/env bash
# Tests for check-public-assets.sh and its detector lib/public-assets.py (claude-config#429).
#
# Drives the REAL hook with a payload on stdin against fixture repositories built here, so the rule is
# exercised where it lives rather than re-implemented (L52). Every case is a push of one commit on
# top of a base that has already reached the fixture's origin, which is the ordinary shape of a push.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-public-assets.sh"
SCANNER="$DIR/lib/public-assets.py"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.publicassets.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

# ---- fixtures -------------------------------------------------------------------------------
# A repo whose BASE holds src/page.tsx referencing /brand/logo.svg, public/brand/logo.svg, and
# public/old-dead.svg which nothing references (the pre-existing dead asset every real repo has).
# The base is pushed to a bare origin so the hook's merge-base is real. $1 = fixture name. Each
# fixture gets its own directory from mktemp: a counter would not survive the subshell these run in,
# and two fixtures sharing a directory re-init the second on top of the first's history.
mk_repo(){
  local root
  root="$(mktemp -d "$WORK/$1.XXXXXX")"
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.name t; git config user.email t@t
    mkdir -p src public/brand
    printf 'export default function Page() {\n  return <img src="/brand/logo.svg" alt="" />;\n}\n' > src/page.tsx
    printf '<svg/>\n' > public/brand/logo.svg
    printf '<svg/>\n' > public/old-dead.svg
    echo baseline > README.md
    git add -A; git commit -qm base
    git remote add origin "$root/origin.git"
    git push -qu origin main
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
# A repo with NO asset directory at all.
mk_bare_repo(){
  local root
  root="$(mktemp -d "$WORK/noassets.XXXXXX")"
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.name t; git config user.email t@t
    echo baseline > README.md
    git add -A; git commit -qm base
    git remote add origin "$root/origin.git"
    git push -qu origin main
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
commit_all(){ ( cd "$1" && git add -A && git commit -qm change ) >/dev/null 2>&1; }
# A file of exactly $2 bytes that starts like a PNG.
write_png(){ python3 -c 'import sys; p, size = sys.argv[1], int(sys.argv[2]); open(p, "wb").write(b"\x89PNG\r\n\x1a\n" + b"\0" * (size - 8))' "$1" "$2"; }

# ---- driving the hook -----------------------------------------------------------------------
CODE=0; ERR=""; OUT=""
run_hook(){  # $1 = cwd for the payload, $2 = command
  local p
  p="$(HK_CMD="$2" HK_CWD="$1" python3 -c 'import json, os, sys
sys.stdout.write(json.dumps({"tool_input": {"command": os.environ["HK_CMD"]}, "cwd": os.environ["HK_CWD"]}))')"
  ERR="$(printf '%s' "$p" | bash "$HOOK" 2>&1 >"$WORK/stdout")"; CODE=$?
  OUT="$(cat "$WORK/stdout")"
}
want_code(){ if [ "$CODE" = "$1" ]; then ok; else bad "$2: expected exit $1, got $CODE; stderr: $ERR; stdout: $OUT"; fi; }
says(){ case "$ERR$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_says(){ if says "$1"; then ok; else bad "$2: expected to read [$1], got stderr: $ERR stdout: $OUT"; fi; }
want_silent_on(){ if says "$1"; then bad "$2: wrongly said [$1]"; else ok; fi; }

ELSEWHERE="$WORK/elsewhere"; mkdir -p "$ELSEWHERE"

# ============================================================================================
# Positive controls (L1): the two defects the guard exists for, each seen to fail.
# ============================================================================================

W="$(mk_repo dead)"
printf '<svg/>\n' > "$W/public/dead.svg"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "positive control: an unreferenced asset added by the push blocks it"
want_says "public/dead.svg: added in this push" "the refusal names the file and says it was added"
want_says 'not by path "dead.svg"' "the refusal says what it looked for"
want_says "SKIP_ASSET_CHECK=1" "the refusal names the override"
want_says "explain to the user" "the refusal says to explain first"
want_says "hygiene-allow.txt" "the refusal names the allowlist"
want_silent_on "over the 250 KB cap" "a dead asset alone does not claim an oversized image"
want_silent_on "public/old-dead.svg" "the pre-existing dead asset is not blamed on this push"

W="$(mk_repo big)"
write_png "$W/public/brand/hero.png" 300000
printf 'export const hero = "/brand/hero.png";\n' > "$W/src/hero.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "positive control: a 300 KB png added by the push blocks it"
want_says "public/brand/hero.png: 300 KB, over the 250 KB cap" "the refusal names the image, its size and the cap"
want_says "re-encode" "the refusal says what to do about the image"
want_silent_on "nothing in the repo references" "an oversized referenced image does not claim it is unreferenced"

# Both at once: the headline says both, because each was measured (L11).
W="$(mk_repo both)"
printf '<svg/>\n' > "$W/public/dead.svg"
write_png "$W/public/brand/hero.png" 300000
printf 'export const hero = "/brand/hero.png";\n' > "$W/src/hero.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "both defects block"
want_says "nothing references, and carries an" "the headline names both kinds of finding"

# ============================================================================================
# The skip line, the escape hatch, and not-a-push.
# ============================================================================================

W="$(mk_bare_repo)"
echo more >> "$W/README.md"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "a repo with no asset directory is allowed"
want_says "ASSET CHECK SKIPPED" "and says out loud that it skipped"
want_says "no assets to judge" "and why"

W="$(mk_repo skip)"
printf '<svg/>\n' > "$W/public/dead.svg"; commit_all "$W"
run_hook "$W" "SKIP_ASSET_CHECK=1 git push"
want_code 0 "the escape hatch allows the push"

W="$(mk_repo notpush)"
printf '<svg/>\n' > "$W/public/dead.svg"; commit_all "$W"
run_hook "$W" "git status"
want_code 0 "a command that is not a push is not judged"
if [ -z "$ERR$OUT" ]; then ok; else bad "not a push: expected silence, got: $ERR$OUT"; fi

# A session rooted elsewhere reaching the repo through the command is still judged.
W="$(mk_repo cdpush)"
printf '<svg/>\n' > "$W/public/dead.svg"; commit_all "$W"
run_hook "$ELSEWHERE" "cd $W && git push"
want_code 2 "cd-then-push from a non-repo cwd is judged"
run_hook "$ELSEWHERE" "git -C $W push"
want_code 2 "git -C push from a non-repo cwd is judged"

# ============================================================================================
# What counts as a reference.
# ============================================================================================

W="$(mk_repo refpath)"
printf '<svg/>\n' > "$W/public/brand/hero.svg"
printf 'export const hero = "/brand/hero.svg";\n' > "$W/src/hero.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "an asset referenced by its served path passes"
want_says "Checked 3 assets under public/" "and the clean run says what it scanned"
want_says "1 already unreferenced before this push and left alone" "and counts the pre-existing dead asset"

W="$(mk_repo refname)"
printf '<svg/>\n' > "$W/public/brand/mark.svg"
printf 'export const icon = "mark.svg";\n' > "$W/src/icon.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "an asset referenced by its bare basename passes"

# A longer name that merely ENDS with the asset's name is not a reference to it.
W="$(mk_repo suffix)"
printf '<svg/>\n' > "$W/public/brand/mark.svg"
printf 'export const icon = "checkmark.svg";\n' > "$W/src/icon.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "a name that only ends with the asset's name does not count"

# A reference from a doc counts, as the issue asks (source, docs, scripts or config).
W="$(mk_repo docref)"
printf '<svg/>\n' > "$W/public/brand/diagram.svg"
mkdir -p "$W/docs"; printf 'See /brand/diagram.svg for the flow.\n' > "$W/docs/flow.md"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "a reference from a doc counts"

# A mention inside .claude/ does not count: a plan that says to copy a file is not a load. This is
# the exclusion that decides the Slate case (see the detector's docstring).
W="$(mk_repo claude)"
printf '<svg/>\n' > "$W/public/brand/plan.svg"
mkdir -p "$W/.claude"; printf 'Copy plan.svg into public/brand/plan.svg.\n' > "$W/.claude/notes.md"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "a mention only inside .claude/ is not a reference"

# A mention from another file INSIDE the asset directory does not count either.
W="$(mk_repo inside)"
printf '<svg/>\n' > "$W/public/brand/inner.svg"
printf '<html><img src="/brand/inner.svg"></html>\n' > "$W/public/demo.html"
printf 'export const demo = "/demo.html";\n' > "$W/src/demo.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "a reference from another file inside the asset directory does not count"
want_says "public/brand/inner.svg" "and it is the inner asset that is named"

# Names a browser fetches on its own need no reference.
W="$(mk_repo wellknown)"
printf 'ico\n' > "$W/public/favicon.ico"
printf 'User-agent: *\n' > "$W/public/robots.txt"
mkdir -p "$W/public/.well-known"; printf '{}\n' > "$W/public/.well-known/assetlinks.json"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "favicon.ico, robots.txt and .well-known/ pass with no reference"

# static/ and assets/ are asset directories too.
W="$(mk_bare_repo)"
mkdir -p "$W/static"; printf '<svg/>\n' > "$W/static/dead.svg"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "static/ is judged like public/"
W="$(mk_bare_repo)"
mkdir -p "$W/assets"; printf '<svg/>\n' > "$W/assets/dead.svg"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "assets/ is judged like public/"

# ============================================================================================
# The merge-base comparison: fail on what THIS push did, never on what was already there.
# ============================================================================================

W="$(mk_repo existing)"
echo more >> "$W/README.md"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "a pre-existing dead asset never fails an unrelated push"
want_says "1 already unreferenced before this push and left alone" "and the summary counts it"

W="$(mk_repo lastref)"
printf 'export default function Page() {\n  return null;\n}\n' > "$W/src/page.tsx"; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "removing the last reference to an asset blocks the push"
want_says "public/brand/logo.svg: nothing references it now" "the refusal names the orphaned asset"
want_says "before this push it was referenced by src/page.tsx:2" "and names the file and line that used to reference it"

W="$(mk_repo delboth)"
rm "$W/public/brand/logo.svg"
printf 'export default function Page() {\n  return null;\n}\n' > "$W/src/page.tsx"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "deleting the asset along with its reference is clean"

W="$(mk_repo deldead)"
rm "$W/public/old-dead.svg"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "deleting a dead asset is clean"
want_silent_on "already unreferenced" "and there is nothing left to count"

# An asset moved to a name nothing references is a new dead asset.
W="$(mk_repo rename)"
git -C "$W" mv public/brand/logo.svg public/brand/logo-old.svg >/dev/null 2>&1; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "renaming an asset away from its references blocks"
want_says "public/brand/logo-old.svg: added in this push" "and names the new name"

# ============================================================================================
# Images: only added or changed ones, only under the asset directories, only over the cap.
# ============================================================================================

W="$(mk_repo small)"
write_png "$W/public/brand/hero.png" 100000
printf 'export const hero = "/brand/hero.png";\n' > "$W/src/hero.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "a 100 KB png passes"
want_says "1 raster images added or changed" "and the summary counts it"

W="$(mk_repo exact)"
write_png "$W/public/brand/hero.png" 250000
printf 'export const hero = "/brand/hero.png";\n' > "$W/src/hero.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "exactly 250 KB is not over the cap"

# Over the cap but already at the base: not this push's doing.
W="$(mk_repo oldbig)"
write_png "$W/public/brand/hero.png" 300000
printf 'export const hero = "/brand/hero.png";\n' > "$W/src/hero.ts"; commit_all "$W"
( cd "$W" && git push -q origin main ) >/dev/null 2>&1
echo more >> "$W/README.md"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "an oversized image already at the base does not fail an unrelated push"

# Modified from under to over the cap: this push's doing.
W="$(mk_repo grew)"
write_png "$W/public/brand/hero.png" 100000
printf 'export const hero = "/brand/hero.png";\n' > "$W/src/hero.ts"; commit_all "$W"
( cd "$W" && git push -q origin main ) >/dev/null 2>&1
write_png "$W/public/brand/hero.png" 300000; commit_all "$W"
run_hook "$W" "git push"
want_code 2 "an image grown over the cap by this push blocks"

# A large raster OUTSIDE the asset directories is not served and not judged.
W="$(mk_repo outside)"
mkdir -p "$W/design"; write_png "$W/design/master.png" 1200000; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "a large image outside the asset directories is not judged"

# An SVG is not a raster, so its size is not capped.
W="$(mk_repo bigsvg)"
python3 -c 'open(__import__("sys").argv[1], "w").write("<svg>" + "a" * 400000 + "</svg>\n")' "$W/public/brand/big.svg"
printf 'export const big = "/brand/big.svg";\n' > "$W/src/big.ts"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "a large SVG is not capped"

# ============================================================================================
# The allowlist.
# ============================================================================================

W="$(mk_repo allow)"
printf '<svg/>\n' > "$W/public/widget.svg"
mkdir -p "$W/.claude"; printf 'public/widget.svg # loaded by partner pages, never referenced here\n' > "$W/.claude/hygiene-allow.txt"
commit_all "$W"
run_hook "$W" "git push"
want_code 0 "an allowlisted asset with a reason passes"

W="$(mk_repo allowimg)"
write_png "$W/public/brand/hero.png" 300000
printf 'export const hero = "/brand/hero.png";\n' > "$W/src/hero.ts"
mkdir -p "$W/.claude"; printf 'public/brand/*.png # photography, sized for the retina hero\n' > "$W/.claude/hygiene-allow.txt"
commit_all "$W"
run_hook "$W" "git push"
want_code 0 "an allowlist glob with a reason exempts an oversized image"

W="$(mk_repo noreason)"
printf '<svg/>\n' > "$W/public/widget.svg"
mkdir -p "$W/.claude"; printf 'public/widget.svg\n' > "$W/.claude/hygiene-allow.txt"
commit_all "$W"
run_hook "$W" "git push"
want_code 2 "an allowlist line with no reason does not exempt"
want_says "has no reason after a #" "and the refusal says so"

# An allowlist line does not turn a reference INTO one: the file is not a reference source.
W="$(mk_repo allowother)"
printf '<svg/>\n' > "$W/public/dead.svg"
mkdir -p "$W/.claude"; printf 'public/other.svg # some other guard entry\n' > "$W/.claude/hygiene-allow.txt"
commit_all "$W"
run_hook "$W" "git push"
want_code 2 "an allowlist entry for a different path exempts nothing"

# ============================================================================================
# The detector on its own: the outcomes the hook cannot reach through a real push.
# ============================================================================================

W="$(mk_repo direct)"
python3 "$SCANNER" --repo "$W" --head no-such-rev >"$WORK/direct" 2>&1; rc=$?
if [ "$rc" = 3 ]; then ok; else bad "detector: an unreadable tree exits 3, got $rc"; fi
case "$(cat "$WORK/direct")" in *"Could not measure"*) ok ;; *) bad "detector: an unreadable tree says it could not measure, said: $(cat "$WORK/direct")" ;; esac

# With no base at all, every asset counts as added and the summary says so.
python3 "$SCANNER" --repo "$W" --base "" >"$WORK/direct" 2>&1; rc=$?
if [ "$rc" = 1 ]; then ok; else bad "detector: no base names the existing dead asset, exit $rc"; fi
case "$(cat "$WORK/direct")" in *"public/old-dead.svg: nothing in the repo references it"*"no base commit, so every asset counts as added"*) ok ;; *) bad "detector: no base wording, got: $(cat "$WORK/direct")" ;; esac

# ============================================================================================
# The hook's own arms for a detector that could not measure or crashed: one NON-BLOCKING line
# (exit 1, so the first stderr line surfaces), never a pass and never a refusal it did not measure.
# Reached through a stub detector, because a real repository the shared helpers accept as a work
# tree gives the real detector nothing it cannot read (L151: every enumerated outcome gets a case
# that produces it).
# ============================================================================================
STUB="$WORK/stub-detector.py"
W="$(mk_repo stubbed)"
echo more >> "$W/README.md"; commit_all "$W"

printf 'import sys\nprint("Could not measure: git ls-tree failed: bad object")\nsys.exit(3)\n' > "$STUB"
run_stub(){ ERR="$(printf '%s' "$1" | PUBLIC_ASSETS_SCANNER="$STUB" bash "$HOOK" 2>&1 >"$WORK/stdout")"; CODE=$?; OUT="$(cat "$WORK/stdout")"; }
PAYLOAD="$(HK_CWD="$W" python3 -c 'import json, os, sys
sys.stdout.write(json.dumps({"tool_input": {"command": "git push"}, "cwd": os.environ["HK_CWD"]}))')"
run_stub "$PAYLOAD"
want_code 1 "a detector that could not measure lets the push through as a non-blocking error"
want_says "ASSET CHECK DID NOT RUN (Could not measure: git ls-tree failed: bad object)" "and the one line carries the detector's reason"
want_silent_on "PUSH BLOCKED" "and it is not a refusal"

# A crash is exit 1 too, the same code as findings. Without the summary line a judged run always
# ends with, it must not become a refusal about a finding nobody measured.
printf 'import sys\nraise RuntimeError("boom")\n' > "$STUB"
run_stub "$PAYLOAD"
want_code 1 "a detector that crashed is reported the same way"
want_says "ASSET CHECK DID NOT RUN (detector exited 1 without a summary: RuntimeError: boom)" "and names the crash rather than claiming a finding"
want_silent_on "PUSH BLOCKED" "and a crash is never a refusal"

# Findings the hook does not recognise are not a refusal either.
printf 'import sys\nprint("public/x.svg: something new this hook has never heard of.")\nprint("Checked 1 assets under public/ against 1 files; 0 raster images added or changed in this push.")\nsys.exit(1)\n' > "$STUB"
run_stub "$PAYLOAD"
want_code 1 "a finding of an unknown kind is not turned into a refusal"
want_says "could not read" "and says so"

# The same stub exit codes the real detector uses, so the mapping is pinned in both directions.
printf 'import sys\nprint("No public/, static/ or assets/ directory at the root of this repo, so there were no assets to judge.")\nsys.exit(2)\n' > "$STUB"
run_stub "$PAYLOAD"
want_code 0 "exit 2 from the detector is the skip"
want_says "ASSET CHECK SKIPPED: No public/" "and is said on stdout"

# The real detector on a real repo, driven the same way, still reaches the real arm.
W="$(mk_repo real)"
echo more >> "$W/README.md"; commit_all "$W"
run_hook "$W" "git push"
want_code 0 "control: the real detector through the same hook is clean on a clean push"
want_says "Checked 2 assets" "and reports what it checked"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
