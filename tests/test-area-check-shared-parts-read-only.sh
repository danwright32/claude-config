#!/bin/bash
# The area check lets `bash tools/check-mod-shared-parts.sh <mods folder>` run without judging the
# folder, by name (payload/mods/area-check/hooks/named.ts SHARED_PARTS, claude-config#3082, signed off
# by Dan, 2026-11-16). The script's own commands are read as writing nothing. What kept the hold on
# every run is the python program it runs through a variable, tools/lib/ts_source.py, which really
# writes: each mod's hooks with the comments taken out, into a folder the script makes under the
# temporary folder and removes as it ends. No reader places a write whose path python builds from
# its arguments, so that the folder it is handed is only read is a claim about the script and that
# program, and this suite holds it there, against the real ones (L96, L58):
#   - SHARED_PARTS.texts is the script and exactly the program files it runs, and it sources none,
#     so a program or library added to the script turns red here. The program imports python's own
#     os, re and sys and nothing else, and no file beside it stands in for one of them.
#   - The real script, run from a throwaway checkout over two of this repository's own mods (mod-kit
#     and the area check), leaves the checkout as it found it: every path byte for byte, no new one,
#     an ignored one included, and git status the same. It is seen to do its work (L98, L288): it
#     counts both mods, and its one run of strip-hooks is handed a folder under the temporary
#     folder, outside the checkout.
#   - The same over a checkout where it FINDS something. The lines it prints then name a cp that
#     brings a copy back, which was first taken for the write (#3082); the cp is printed, never run.
#   - Each of those checks is seen to fail (L1): a copy of the script changed to append to a tracked
#     file, to add a new file, or to plant an ignored one is caught, and so is a copy of the program
#     changed to write its copies into the folder it reads.
#   - Why the rule judges a command that sets a value: with TMPDIR set to the folder, the script's
#     copies are made inside it.
#   - The rule itself, run on mod-kit's REAL reader of a command and real git
#     (tests/area-check-named-rule.mjs), lets through only that script at its path from the root of a
#     checkout of its repository, handed one folder, in a command that sets no value and runs the
#     script once, with nothing but a change of folder before it and readers its output is piped into
#     after it, with its texts as the checkout left the default branch with them. Every other shape,
#     a changed text, a copy elsewhere, another repository, and everything chained with the run, the
#     other script let through by name included, is still judged.
#   - The guard on this suite's own temporary folder (tests/area-check-named-reader.sh named_tmp): a
#     mktemp that fails stops the suite, and the folder it ran from is still there.
# What it cannot prove, said so it is never claimed (L460): what a python3 other than this machine's
# does, and a file left beside the program under the name of a module it imports (tools/lib/re.py),
# which python would load in its place. Git compares the texts it is asked about, and a file it does
# not track is not one of them; this suite is red while this checkout holds such a file.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
finish(){
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the area check's list could not be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
REAL_PY="$(command -v python3 2>/dev/null)"
if [ -z "$REAL_PY" ]; then
  echo "FAIL: python3 is not installed, so the script reads no mod (it exits 3) and nothing here was run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

. "$DIR/area-check-named-reader.sh" || {
  echo "FAIL: $(basename "$0"): tests/area-check-named-reader.sh is missing, so nothing was run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
named_tmp test-area-check-shared-parts

# ---- The guard on the temporary folder ----
# A mktemp that fails, in a shell of its own started from a folder holding a file: the suite stops
# there, and the folder is not what its EXIT trap removes.
mkdir -p "$TMP/ran-from" && : > "$TMP/ran-from/kept"
guard="$(cd "$TMP/ran-from" && (mktemp(){ return 1; }; named_tmp guarded; echo "went on with $TMP") 2>&1)"; guard_code=$?
case "$guard" in *"went on"*) went=yes ;; *) went=no ;; esac
[ "$guard_code" -eq 1 ] && [ "$went" = no ] && printf '%s\n' "$guard" | grep -q 'no temporary folder could be made' && printf '%s\n' "$guard" | grep -q '^SUITE-RESULT passed=0 failed=1$' \
  && check "a mktemp that fails stops the suite before anything runs, as one failure" ok \
  || check "a mktemp that fails stops the suite before anything runs, as one failure" "exit=$guard_code out=$guard"
[ -f "$TMP/ran-from/kept" ] && check "and the folder it ran from is still there" ok || check "and the folder it ran from is still there" "$TMP/ran-from/kept is gone"

# ---- The list, held to the texts ----
named_texts SHARED_PARTS || finish
[ "$SCRIPT" = tools/check-mod-shared-parts.sh ] && [ -f "$ROOT/$SCRIPT" ] && check "the named script is tools/check-mod-shared-parts.sh, and it is there" ok \
  || check "the named script is tools/check-mod-shared-parts.sh, and it is there" "named: $SCRIPT"
# Four runs of the program today: strip-hooks once, then kit-test-takers, real-waits and unscreened
# for each mod. Fewer than that and the reading of them has gone blind, which would pass every check
# below it (L98).
runs="$(named_fact RUNS)"
[ "${runs:-0}" -ge 4 ] && check "the lines that run a program file are found" ok || check "the lines that run a program file are found" "found ${runs:-none}: $listed"
[ "$(named_fact LINES)" = 0 ] && check "and the script sources no file" ok || check "and the script sources no file" "$listed"
problems="$(named_fact PROBLEM)"
[ -z "$problems" ] && check "SHARED_PARTS.texts is the script and exactly the program files it runs" ok \
  || check "SHARED_PARTS.texts is the script and exactly the program files it runs" "$problems"
# The program's own imports, which no shell line names. Exactly these three, each python's own: one
# more is a text the list may need, so it is read here before it is allowed.
PROGRAM=tools/lib/ts_source.py
imports="$(grep -E '^[[:space:]]*(import|from)[[:space:]]' "$ROOT/$PROGRAM" | sed 's/[[:space:]]*$//' | LC_ALL=C sort | paste -sd';' -)"
[ "$imports" = 'import os;import re;import sys' ] && check "the program imports os, re and sys, and nothing else" ok \
  || check "the program imports os, re and sys, and nothing else" "it imports: $imports. A file of this repository among them belongs in SHARED_PARTS.texts"
computed="$(grep -n -E '__import__|importlib|runpy|\bexec\(|\beval\(' "$ROOT/$PROGRAM" | sed -n '1,3p' | paste -sd';' -)"
[ -z "$computed" ] && check "and it loads or runs no code by a name it builds" ok || check "and it loads or runs no code by a name it builds" "$computed"
shadow=""
for m in os re sys; do
  for f in "$ROOT/tools/lib/$m.py" "$ROOT/tools/lib/$m"; do [ -e "$f" ] && shadow="$shadow $f"; done
done
[ -z "$shadow" ] && check "and no file beside it stands in for one of python's own modules" ok || check "and no file beside it stands in for one of python's own modules" "python loads these in place of its own:$shadow"

# ---- The real script over a throwaway checkout ----
# Two of this repository's own mods, every file of theirs that git tracks or would track: mod-kit,
# which the script reads as the one that shares, and the area check, which it reads as every other
# mod and which keeps copies of mod-kit's files. Two, since each run of the script costs a python
# start three times a mod and nothing it does differs from one mod to the next.
MODS_FILES="$(bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" payload/mods/mod-kit payload/mods/area-check)" && [ -n "$MODS_FILES" ] \
  && check "the mods the script reads are listed" ok || check "the mods the script reads are listed" "repo-files.sh gave: $MODS_FILES"
# A checkout holding the real script and program at their paths, the real ignore rules, and the mods.
make_repo(){   # $1 = folder
  local repo="$1"
  mkdir -p "$repo" || return 1
  { printf '%s\n' "$TEXTS"; echo .gitignore; printf '%s\n' "$MODS_FILES"; } > "$TMP/files.list"
  (cd "$ROOT" && tar -cf - -T "$TMP/files.list") | (cd "$repo" && tar -xf -) || return 1
  git -C "$repo" init -q -b main >/dev/null 2>&1 || return 1
  git -C "$repo" add -A >/dev/null 2>&1 || return 1
  git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q -m fixture >/dev/null 2>&1 || return 1
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
}
# python3, standing in only to say what it was handed, and then the real one.
mkdir -p "$TMP/bin" "$TMP/tmp"
PY_CALLS="$TMP/python-calls"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$PY_LOG"\nexec "%s" "$@"\n' "$REAL_PY" > "$TMP/bin/python3"; chmod +x "$TMP/bin/python3"
# The script as the area check lets it through: `bash tools/check-mod-shared-parts.sh payload/mods`
# from the root of the checkout. Only the stand in, and a temporary folder of its own, are set
# around it.
run_scan(){   # $1 = checkout  rest = more of the environment -> sets out and code
  local repo="$1"; shift
  : > "$PY_CALLS"
  out="$(cd "$repo" && env PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmp" PY_LOG="$PY_CALLS" "$@" bash tools/check-mod-shared-parts.sh payload/mods 2>&1)"; code=$?
}
# Where the one run of strip-hooks was told to write its copies.
copies_in(){ sed -n 's/^.*ts_source\.py strip-hooks payload\/mods //p' "$PY_CALLS"; }

REPO="$TMP/repo"
# One of the area check's copies of a file of mod-kit's.
COPY=payload/mods/area-check/tests/mod-kit/tests/core.ts
make_repo "$REPO" && [ -z "$(status "$REPO")" ] && check "the throwaway checkout is made, clean, with the real script and two of this repository's mods in it" ok \
  || check "the throwaway checkout is made, clean, with the real script and two of this repository's mods in it" "status: $(status "$REPO")"
for t in $TEXTS; do
  cmp -s "$ROOT/$t" "$REPO/$t" && check "its $t is the real one, byte for byte" ok || check "its $t is the real one, byte for byte" "the copy differs"
done
mods="$(ls -d "$REPO"/payload/mods/*/.claude-plugin/plugin.json 2>/dev/null | wc -l | tr -d ' ')"
[ "${mods:-0}" -eq 2 ] && [ -f "$REPO/$COPY" ] && check "and it holds both mods, the area check with its copies of mod-kit's files" ok \
  || check "and it holds both mods, the area check with its copies of mod-kit's files" "$mods mods under $REPO/payload/mods"

# 1. Nothing in the checkout changes at all.
whole_before="$(whole "$REPO")"; status_before="$(status "$REPO")"
run_scan "$REPO"
printf '%s\n' "$out" | grep -q "^check-mod-shared-parts: $mods mods checked in payload/mods\$" && [ "$code" -le 1 ] \
  && check "the run did its work: it read both mods" ok \
  || check "the run did its work: it read both mods" "exit=$code out=$(printf '%s\n' "$out" | tail -n 3)"
[ "$(grep -c "^$REPO/tools/lib/ts_source\.py " "$PY_CALLS")" -ge "$((1 + 2 * mods))" ] && [ "$(grep -c -v "^$REPO/tools/lib/ts_source\.py " "$PY_CALLS")" -eq 0 ] \
  && check "by the checkout's own program and no other, once and then at least twice a mod" ok \
  || check "by the checkout's own program and no other, once and then at least twice a mod" "$(grep -c . "$PY_CALLS") runs: $(sed -n '1,3p' "$PY_CALLS")"
case "$(copies_in)" in "$TMP/tmp/check-mod-shared-parts."*) check "its copies were written under the temporary folder, outside the checkout" ok ;;
  *) check "its copies were written under the temporary folder, outside the checkout" "strip-hooks was handed: $(copies_in)" ;; esac
[ -z "$(ls -A "$TMP/tmp")" ] && check "and removed as it ended" ok || check "and removed as it ended" "left: $(ls -A "$TMP/tmp")"
whole_after="$(whole "$REPO")"
[ "$whole_after" = "$whole_before" ] && check "every path in the checkout is byte for byte as it was, and none is new" ok \
  || check "every path in the checkout is byte for byte as it was, and none is new" "$(changed "$whole_before" "$whole_after")"
[ "$(status "$REPO")" = "$status_before" ] && check "and git status is as it was" ok || check "and git status is as it was" "now: $(status "$REPO")"

# 2. Where it finds something: the cp it names is printed, never run.
FOUND="$TMP/found"
cp -R "$REPO" "$FOUND" && printf '// differs\n' >> "$FOUND/$COPY" && git -C "$FOUND" -c user.email=t@example.com -c user.name=t commit -q -a -m differs >/dev/null 2>&1 \
  && check "a checkout is made where a mod's copy of mod-kit's file differs" ok || check "a checkout is made where a mod's copy of mod-kit's file differs" "it could not be made"
whole_before="$(whole "$FOUND")"; status_before="$(status "$FOUND")"
run_scan "$FOUND"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q "area-check's tests/mod-kit/tests/core.ts differs from mod-kit's own.*: cp \"payload/mods/mod-kit/tests/core.ts\" \"payload/mods/area-check/tests/mod-kit/tests/core.ts\"" \
  && check "the run fails, naming the copy and the cp that brings it back" ok \
  || check "the run fails, naming the copy and the cp that brings it back" "exit=$code out=$out"
cmp -s "$FOUND/$COPY" "$FOUND/payload/mods/mod-kit/tests/core.ts" && check "the cp it names was not run: the copy still differs" "the copy now matches mod-kit's" \
  || check "the cp it names was not run: the copy still differs" ok
whole_after="$(whole "$FOUND")"
[ "$whole_after" = "$whole_before" ] && check "and every path in that checkout is byte for byte as it was" ok \
  || check "and every path in that checkout is byte for byte as it was" "$(changed "$whole_before" "$whole_after")"
[ "$(status "$FOUND")" = "$status_before" ] && check "with git status as it was" ok || check "with git status as it was" "now: $(status "$FOUND")"

# 3. The controls (L1): a script, or a program, that writes into the checkout is caught.
control(){   # $1 = name  $2 = the text changed  $3 = sed program  $4 = whole | tracked  $5 = what the difference must name
  local repo="$TMP/control-$1" before after seen
  cp -R "$REPO" "$repo" && sed "$3" "$repo/$2" > "$repo/$2.changed" && ! cmp -s "$repo/$2" "$repo/$2.changed" && cat "$repo/$2.changed" > "$repo/$2" && rm -f "$repo/$2.changed" \
    || { check "control $1: a changed copy of $2 is made" "$2 did not change, or the checkout could not be made"; return; }
  if [ "$4" = whole ]; then before="$(whole "$repo")"; else before="$(tracked "$repo")"; fi
  run_scan "$repo"
  if [ "$4" = whole ]; then after="$(whole "$repo")"; else after="$(tracked "$repo")"; fi
  seen="$(changed "$before" "$after")"
  case "$seen" in *"$5"*) check "control $1 is caught, naming $5" ok ;; *) check "control $1 is caught, naming $5" "the listing showed: ${seen:-no difference}; out=$out" ;; esac
}
AFTER_DIR='/^dir="\${dir%\/}"$/a\'
control "the script appending to a tracked file" "$SCRIPT" "$AFTER_DIR
printf '// x\\\\n' >> \"\$dir/mod-kit/hooks/card.ts\"
" tracked "payload/mods/mod-kit/hooks/card.ts"
control "the script adding a new file" "$SCRIPT" "$AFTER_DIR
: > \"\$dir/mod-kit/hooks/new.ts\"
" tracked "payload/mods/mod-kit/hooks/new.ts"
[ -n "$(status "$TMP/control-the script adding a new file" | grep 'new\.ts')" ] && check "and git status shows it" ok || check "and git status shows it" "git status does not name new.ts"
control "the script planting an ignored file" "$SCRIPT" "$AFTER_DIR
: > \"\$dir/mod-kit/planted.log\"
" whole "payload/mods/mod-kit/planted.log"
git -C "$TMP/control-the script planting an ignored file" check-ignore -q payload/mods/mod-kit/planted.log && check "which the repository's own ignore rules hide from git status" ok \
  || check "which the repository's own ignore rules hide from git status" "payload/mods/mod-kit/planted.log is not ignored there"
# The write the reader could not place, aimed at the folder it reads in place of the script's own.
control "the program writing its copies into the folder it reads" "$PROGRAM" 's/target = os\.path\.join(dest, entry, "hooks"/target = os.path.join(mods, entry, "hooks"/' tracked "payload/mods/area-check/hooks/"

# 4. Why a command that sets a value is judged: TMPDIR set to the folder puts the copies inside it.
run_scan "$REPO" TMPDIR="$REPO/payload/mods"
case "$(copies_in)" in "$REPO/payload/mods/check-mod-shared-parts."*) check "with TMPDIR set to the folder, the script's copies are made inside the folder" ok ;;
  *) check "with TMPDIR set to the folder, the script's copies are made inside the folder" "strip-hooks was handed: $(copies_in); out=$out" ;; esac

# ---- The rule, on the real reader and real git ----
# How many checks must run is set here, not measured: 31 of the run's shape and its text, one for
# the program, and one for the other script let through by name.
named_rule SHARED_PARTS "$REPO" payload/mods/mod-kit/hooks/card.ts 33

finish
