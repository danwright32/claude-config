#!/usr/bin/env bash
# The shared test harness every disk-clean suite uses (claude-config#1804), proved before any code
# that deletes anything exists.
#
# The disk-clean milestone builds a tool whose whole job is removing files from a real Mac, so the
# first thing built is the place its tests run, and it is proved here on its own: a PATH of stubs
# plus a short list of core tools and nothing else, a HOME inside a throwaway directory the harness
# made itself (refused otherwise), writing tools that refuse any path outside that directory, and a
# static check that lists every command the disk-clean scripts call and fails on any that is
# neither stubbed nor a core tool. Every guard is first shown to refuse (L1), then shown to let the
# legitimate case through, so a guard that refuses everything cannot pass either.
#
# Two tests run the REAL tools the plan depends on, on files this suite creates in its own
# throwaway directory, because their behaviour is a platform fact a stub would only restate:
#   /usr/bin/trash   measured 2026-10-27: it moves into the REAL ~/.Trash whatever HOME says, so no
#                    disk-clean test may ever run it except this one, and this one removes its own
#                    probe from the Trash by inode afterwards. Absent before macOS 15, which is
#                    reported as SUITE-PART-UNMEASURED, never as a pass (L411).
#   lsof             exits 1 for a file nobody has open, a missing file and a permission denied
#                    alike; only stderr tells the last two apart from "not open" (L42).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$DIR/lib/disk-clean-harness.sh"
# The two files the harness runs, named so a check can say which one is missing.
GUARD="$DIR/lib/disk-clean-guard.sh"
SCANNER="$DIR/lib/disk-clean-commands.py"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
finish() {
  echo ""
  echo "passed: $pass, failed: $fail"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

if ! . "$HARNESS"; then
  check "the harness is there to source" "could not source $HARNESS"
  finish
fi
check "the write guard and the command scanner are beside it" \
  "$([ -f "$GUARD" ] && [ -f "$SCANNER" ] && echo ok || echo "missing: $([ -f "$GUARD" ] || echo "$GUARD") $([ -f "$SCANNER" ] || echo "$SCANNER")")"
# The predicates live in ONE file the harness, the guard and disk-remove.sh all source (#1805, L261):
# disk-remove's test mode refusal must read the very rule dc_run enforces, never a copy of it.
PREDICATES="$DIR/lib/disk-clean-predicates.sh"
pred_defs="$(grep -l -E '^(dc_home_isolated|dc_root_valid|dc_inside|dc_resolve)\(\)' "$DIR"/*.sh "$DIR"/lib/*.sh 2>/dev/null | tr '\n' ' ')"
check "the predicates are defined in disk-clean-predicates.sh and nowhere else" \
  "$([ "$pred_defs" = "$PREDICATES " ] && echo ok || echo "defined in: $pred_defs")"
check "and disk-remove.sh sources that file for its test mode refusal" \
  "$(grep -qF '. "$LIB/disk-clean-predicates.sh"' "$DIR/lib/disk-remove.sh" && grep -qF 'dc_home_isolated "${HOME:-}" "$TEST_ROOT"' "$DIR/lib/disk-remove.sh" && echo ok || echo "disk-remove.sh does not source it, or does not ask dc_home_isolated")"

# A second throwaway directory OUTSIDE the harness's own, standing in for the real Mac. Every
# refusal below is aimed at a sentinel in here, never at anything real, so a guard that fails to
# refuse destroys only this (L5).
OUT="$(mktemp -d "${TMPDIR:-/tmp}/disk-clean-harness-outside.XXXXXXXX")" || OUT=""
case "${OUT%/}" in
  ''|/|"${HOME%/}") echo "test-disk-clean-harness: refusing to run: the outside directory came back as '$OUT'." >&2; exit 2 ;;
esac
OUT="$(cd -P "$OUT" && pwd -P)"
printf 'sentinel\n' > "$OUT/sentinel"

if ! dc_setup; then
  rm -rf "$OUT"
  check "dc_setup builds the harness" "dc_setup failed"
  finish
fi
trap 'dc_cleanup; chmod -R u+rwx "$OUT" 2>/dev/null; rm -rf "$OUT"' EXIT

# ================================================================================================
# 1. The harness's own directory, PATH and HOME
# ================================================================================================
# dc_setup sets its own EXIT trap only when the suite has none, and never replaces one. Asked of a
# second shell, so this suite's own trap is not the one at stake.
kept="$(bash -c 'trap "echo suite-trap" EXIT; . "$1" || exit 9; dc_setup >/dev/null 2>&1 || exit 8; r="$DC_ROOT"; trap -p EXIT; dc_cleanup; [ -d "$r" ] && echo "root left"' _ "$HARNESS" 2>&1)"
check "dc_setup leaves an EXIT trap the suite already set in place" \
  "$(grep -qF 'echo suite-trap' <<< "$kept" && ! grep -qF 'dc_cleanup' <<< "$kept" && ! grep -qF 'root left' <<< "$kept" && echo ok || echo "said: $kept")"
added="$(bash -c '. "$1" || exit 9; dc_setup >/dev/null 2>&1 || exit 8; trap -p EXIT; dc_cleanup' _ "$HARNESS" 2>&1)"
check "and sets one running dc_cleanup when there was none" \
  "$(grep -qF 'dc_cleanup' <<< "$added" && echo ok || echo "said: $added")"

check "the throwaway root is named by the harness's template" \
  "$(case "${DC_ROOT##*/}" in (disk-clean-harness.?*) echo ok ;; (*) echo "root is $DC_ROOT" ;; esac)"
check "HOME lives inside the throwaway root" \
  "$(case "$DC_HOME" in ("$DC_ROOT"/*) [ -d "$DC_HOME" ] && echo ok || echo "$DC_HOME is not a directory" ;; (*) echo "DC_HOME is $DC_HOME" ;; esac)"

seen_path="$(dc_run bash -c 'printf %s "$PATH"' 2>&1)"
check "a command run by dc_run sees a PATH of the stubs then the core tools, and nothing else" \
  "$([ "$seen_path" = "$DC_STUBS:$DC_CORE" ] && echo ok || echo "saw: $seen_path")"
seen_home="$(dc_run bash -c 'printf "%s|%s|%s" "$HOME" "$(pwd -P)" "$TMPDIR"' 2>&1)"
check "and HOME, its working directory and TMPDIR all inside the throwaway root" \
  "$([ "$seen_home" = "$DC_HOME|$DC_HOME|$DC_TMPDIR" ] && echo ok || echo "saw: $seen_home")"

# The premise of the next check, measured rather than assumed: python3 IS reachable from this
# suite's own PATH, so its absence under dc_run is the harness's doing (L248).
if command -v python3 >/dev/null 2>&1; then
  check "a tool that is neither stubbed nor core (python3) cannot be reached under dc_run" \
    "$(dc_run bash -c 'command -v python3' >/dev/null 2>&1 && echo "python3 was reachable" || echo ok)"
else
  echo "SUITE-PART-UNMEASURED whether dc_run hides a tool outside the core list: python3 is not on this suite's own PATH either, so its absence proves nothing"
fi

# Core tools come from the system's own folders only, never Homebrew or a version manager, so a
# suite measures the same binaries on both Macs and on CI.
bad_core=""
guarded_count=0
for entry in "$DC_CORE"/*; do
  name="${entry##*/}"
  if [ -L "$entry" ]; then
    target="$(readlink "$entry")"
    case "$target" in /bin/*|/usr/bin/*) ;; *) bad_core="$bad_core $name->$target" ;; esac
  elif grep -qF "${GUARD##*/}" "$entry" 2>/dev/null; then
    guarded_count=$((guarded_count + 1))
  else
    bad_core="$bad_core $name(neither a system link nor a guard)"
  fi
done
check "every core entry is a link into /bin or /usr/bin, or a writing tool wrapped by the guard" \
  "$([ -z "$bad_core" ] && echo ok || echo "$bad_core")"
check "and every writing tool on the guarded list is one of the wrapped ones" \
  "$([ "$guarded_count" -eq "$(printf '%s\n' $DC_GUARDED_TOOLS | wc -l)" ] && echo ok || echo "$guarded_count wrapped")"
for tool in $DC_CORE_TOOLS; do [ -e "$DC_CORE/$tool" ] || bad_core="$bad_core missing:$tool"; done
check "and every tool on the core list is there" "$([ -z "$bad_core" ] && echo ok || echo "$bad_core")"

overlap=""
for s in $DC_STUB_NAMES; do case " $DC_CORE_TOOLS " in *" $s "*) overlap="$overlap $s" ;; esac; done
check "no tool is both stubbed and core, so which one runs is never a question of PATH order" \
  "$([ -z "$overlap" ] && echo ok || echo "both:$overlap")"
missing_stub=""
for s in $DC_STUB_NAMES; do [ -x "$DC_STUBS/$s" ] || missing_stub="$missing_stub $s"; done
check "every name on the stub list has a stub from the start" \
  "$([ -z "$missing_stub" ] && echo ok || echo "no stub for:$missing_stub")"

# A stub nobody gave a behaviour refuses loudly rather than answering success with nothing (L98).
out="$(dc_run docker image ls 2>&1)"; rc=$?
check "a stub with no behaviour exits 98 and says the test gave it none" \
  "$([ "$rc" -eq 98 ] && grep -qF 'gave it no behaviour' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
check "and the call is recorded with its arguments" \
  "$(grep -qx "docker image ls" <<< "$(dc_calls docker)" && echo ok || echo "calls: $(dc_calls)")"
dc_stub du 'printf "%s\t%s\n" 42 "$1"'
out="$(dc_run du -sk "a b" 2>&1)"; rc=$?
check "dc_stub gives a stub its behaviour, with the arguments it was called with" \
  "$([ "$rc" -eq 0 ] && [ "$out" = "42	-sk" ] && echo ok || echo "exit $rc, said: $out")"
check "and an argument holding a space is recorded so it can be read back as one" \
  "$(grep -qxF "du -sk a\\ b" <<< "$(dc_calls du)" && echo ok || echo "calls: $(dc_calls du)")"
out="$(dc_stub curl 'exit 0' 2>&1)"; rc=$?
check "dc_stub refuses a name that is not on the stub list, which the command check reads" \
  "$([ "$rc" -ne 0 ] && [ ! -e "$DC_STUBS/curl" ] && echo ok || echo "exit $rc, said: $out")"
check "a seam variable points at its stub under dc_run" \
  "$([ "$(dc_run bash -c 'printf %s "$DISK_CLEAN_TRASH"' 2>&1)" = "$DC_STUBS/trash" ] && echo ok || echo "the seam was not set")"

# ================================================================================================
# 2. HOME must be inside a throwaway directory the harness made, or nothing runs
# ================================================================================================
REAL_HOME="$(dc_real_home)"
check "the real home is read from the user database, not from HOME" \
  "$([ -n "$REAL_HOME" ] && [ -d "$REAL_HOME" ] && echo ok || echo "read '$REAL_HOME'")"
check "the predicate accepts the harness's own HOME and root (the positive control)" \
  "$(dc_home_isolated "$DC_HOME" "$DC_ROOT" && echo ok || echo "refused its own HOME")"
check "it refuses the real home as HOME" \
  "$(dc_home_isolated "$REAL_HOME" "$DC_ROOT" && echo "accepted $REAL_HOME" || echo ok)"
check "it refuses a HOME outside the root, even in a temp directory" \
  "$(dc_home_isolated "$OUT" "$DC_ROOT" && echo "accepted $OUT" || echo ok)"
check "it refuses HOME equal to the root itself" \
  "$(dc_home_isolated "$DC_ROOT" "$DC_ROOT" && echo "accepted the root" || echo ok)"
ln -s "$OUT" "$DC_ROOT/escape-home"
check "it refuses a HOME inside the root that is a link to somewhere outside" \
  "$(dc_home_isolated "$DC_ROOT/escape-home" "$DC_ROOT" && echo "accepted a link out" || echo ok)"
check "it refuses a root the harness's template did not name" \
  "$(mkdir -p "$OUT/home" && dc_home_isolated "$OUT/home" "$OUT" && echo "accepted $OUT" || echo ok)"
rmdir "$OUT/home"
check "it refuses / as the root" \
  "$(dc_root_valid / && echo "accepted /" || echo ok)"
check "it refuses an empty root" \
  "$(dc_home_isolated "$DC_HOME" "" && echo "accepted an empty root" || echo ok)"
# The rules about the real home and the temp folders are asked of the inner predicate with a
# stand in for each, because building a root inside the real home to prove it is refused would be
# the very write this harness exists to prevent.
mkdir -p "$OUT/disk-clean-harness.inner/user" "$OUT/disk-clean-harness.inner2"
check "the inner predicate accepts a template root under a temp folder, away from the home (the positive control)" \
  "$(_dc_root_valid_against "$OUT/disk-clean-harness.inner2" "$DC_HOME" "$DC_TEMP_PARENTS" && echo ok || echo "refused")"
check "it refuses a root that holds the real home" \
  "$(_dc_root_valid_against "$OUT/disk-clean-harness.inner" "$OUT/disk-clean-harness.inner/user" "$DC_TEMP_PARENTS" && echo "accepted" || echo ok)"
check "it refuses a root inside the real home, even one named by the template" \
  "$(_dc_root_valid_against "$OUT/disk-clean-harness.inner2" "$OUT" "$DC_TEMP_PARENTS" && echo "accepted" || echo ok)"
check "it refuses a root outside every temp folder" \
  "$(_dc_root_valid_against "$OUT/disk-clean-harness.inner2" "$DC_HOME" "/nonexistent-temp-parent" && echo "accepted" || echo ok)"
rm -rf "$OUT/disk-clean-harness.inner" "$OUT/disk-clean-harness.inner2"

# dc_run itself refuses, and runs nothing, once HOME would not be isolated.
saved_home="$DC_HOME"
DC_HOME="$REAL_HOME"
out="$(dc_run touch "$DC_ROOT/ran-with-real-home" 2>&1)"; rc=$?
DC_HOME="$saved_home"
check "dc_run refuses to run anything when HOME would be the real home" \
  "$([ "$rc" -eq 97 ] && [ ! -e "$DC_ROOT/ran-with-real-home" ] && echo ok || echo "exit $rc, ran: $([ -e "$DC_ROOT/ran-with-real-home" ] && echo yes || echo no), said: $out")"
check "and says why" "$(grep -qF 'not inside' <<< "$out" && echo ok || echo "said: $out")"
saved_root="$DC_ROOT"
DC_ROOT=""
out="$(dc_run true 2>&1)"; rc=$?
DC_ROOT="$saved_root"
check "dc_run refuses when the harness was never set up" \
  "$([ "$rc" -eq 97 ] && echo ok || echo "exit $rc, said: $out")"

# ================================================================================================
# 3. Writing tools refuse any path outside the throwaway root
# ================================================================================================
sentinel_ok() { [ "$(cat "$OUT/sentinel" 2>/dev/null)" = "sentinel" ]; }
refusal_count() { dc_refusals | grep -c 'refused' || true; }
refused() { # refused <description> <command...>: the command exits 97, logs it, the sentinel is untouched
  local desc="$1" out rc before after; shift
  before="$(refusal_count)"
  out="$(dc_run "$@" </dev/null 2>&1)"; rc=$?
  after="$(refusal_count)"
  check "$desc" "$([ "$rc" -eq 97 ] && [ "$after" -gt "$before" ] && sentinel_ok && echo ok || echo "exit $rc, refusals $before then $after, sentinel intact: $(sentinel_ok && echo yes || echo no), said: $out")"
}
refused_inside() { # as refused, for a tool run BY another tool, whose own exit code it reports instead
  local desc="$1" out rc before after; shift
  before="$(refusal_count)"
  out="$(dc_run "$@" </dev/null 2>&1)"; rc=$?
  after="$(refusal_count)"
  check "$desc" "$([ "$after" -gt "$before" ] && sentinel_ok && echo ok || echo "exit $rc, refusals $before then $after, sentinel intact: $(sentinel_ok && echo yes || echo no), said: $out")"
}
printf 'x\n' > "$DC_HOME/inside.txt"
out="$(dc_run rm "$DC_HOME/inside.txt" 2>&1)"; rc=$?
check "rm of a file inside the root works (the positive control)" \
  "$([ "$rc" -eq 0 ] && [ ! -e "$DC_HOME/inside.txt" ] && echo ok || echo "exit $rc, said: $out")"
out="$(dc_run mkdir -p "$DC_HOME/a/b" 2>&1)"; rc=$?
check "mkdir -p of a new path inside the root works" \
  "$([ "$rc" -eq 0 ] && [ -d "$DC_HOME/a/b" ] && echo ok || echo "exit $rc, said: $out")"
out="$(dc_run touch -t 202601011200 "$DC_HOME/a/b/t" 2>&1)"; rc=$?
check "touch with an option that takes a value works inside the root" \
  "$([ "$rc" -eq 0 ] && [ -f "$DC_HOME/a/b/t" ] && echo ok || echo "exit $rc, said: $out")"
out="$(dc_run sed -n 1p "$OUT/sentinel" 2>&1)"; rc=$?
check "sed that only reads a file outside the root is not refused" \
  "$([ "$rc" -eq 0 ] && [ "$out" = sentinel ] && echo ok || echo "exit $rc, said: $out")"
# A guarded tool's calls are recorded as a stub's are, so a suite can count them: the scan's one walk
# of the home folder is a find, and only the count of its calls can show it ran once (#1851).
dc_run find "$DC_HOME/a" -maxdepth 0 > /dev/null 2>&1
check "a guarded tool's call is recorded in the call log with its arguments, as a stub's is" \
  "$(grep -qxF "find $(printf '%q' "$DC_HOME/a") -maxdepth 0" <<< "$(dc_calls find)" && echo ok || echo "calls: $(dc_calls find)")"

refused "rm of a file outside the root is refused" rm "$OUT/sentinel"
refused "rm -rf of the outside folder is refused" rm -rf "$OUT"
refused "a relative path climbing out with .. is refused" rm "../../${OUT##*/}/sentinel"
ln -s "$OUT" "$DC_HOME/link-out"
refused "a path inside the root that passes through a link to outside is refused" rm "$DC_HOME/link-out/sentinel"
ln -s "$OUT/sentinel" "$DC_HOME/file-link-out"
refused "writing through a link to a file outside is refused" tee "$DC_HOME/file-link-out"
refused "mv of a file outside into the root is refused" mv "$OUT/sentinel" "$DC_HOME/moved"
refused "cp onto a file outside is refused" cp "$DC_HOME/a/b/t" "$OUT/sentinel"
refused "touch outside is refused" touch "$OUT/new"
refused "mkdir outside is refused" mkdir -p "$OUT/new-dir"
refused "ln into outside is refused" ln -s "$DC_HOME/a" "$OUT/new-link"
refused "chmod outside is refused" chmod 000 "$OUT/sentinel"
refused "sed -i outside is refused" sed -i.bak 's/sentinel/changed/' "$OUT/sentinel"
refused "find -delete outside is refused" find "$OUT" -name sentinel -delete
refused_inside "rm reached through xargs is refused, because xargs finds rm on the same PATH" \
  bash -c 'printf "%s\n" "$1" | xargs rm' _ "$OUT/sentinel"
refused_inside "rm reached through find -exec is refused" find "$OUT" -name sentinel -exec rm {} ';'
check "nothing outside the root changed" \
  "$([ -z "$(ls -A "$OUT" | grep -vx sentinel)" ] && sentinel_ok && echo ok || echo "outside now holds: $(ls -A "$OUT" | tr '\n' ' ')")"
check "every refusal is in the refusal log" \
  "$(n="$(dc_refusals | grep -c 'refused')"; [ "${n:-0}" -ge 15 ] && echo ok || echo "only ${n:-0} refusals logged")"
out="$(env -u DISK_CLEAN_TEST_ROOT bash "$DC_CORE/rm" "$DC_HOME/a/b/t" 2>&1)"; rc=$?
check "a writing tool with no throwaway root named refuses everything, even inside" \
  "$([ "$rc" -eq 97 ] && [ -f "$DC_HOME/a/b/t" ] && echo ok || echo "exit $rc, said: $out")"

# ================================================================================================
# 4. The command check
# ================================================================================================
FX="$DC_ROOT/fixtures"
mkdir -p "$FX"
cmd_check() { dc_check_commands "$@" 2>&1; }
fail_lines() { # the line numbers the check failed for in one file, for one command name
  awk -F '\t' -v f="$2" -v n="$3" '$1 == "fail" && $2 == n { split($3, a, ":"); if (a[1] == f) print a[2] }' <<< "$1" | sort -n | uniq | tr '\n' ' '
}

# 4a. Every way a script can call a command, each line marked FINDS must be reported and no other.
cat > "$FX/constructs.sh" <<'EOF'
#!/usr/bin/env bash
# curl in a comment is not a call
helper() { printf '%s\n' "$1"; }
echo "curl in a string is not a call"
printf 'curl %s\n' x
cat <<'BODY'
curl in a heredoc body is not a call
BODY
case "$1" in
  curl) helper one ;;
  wget|curl) helper two ;;
esac
for w in curl wget; do helper "$w"; done
[[ "$1" == curl ]] && helper three
x="$(curl a)"   # FINDS
y=`curl b`   # FINDS
cat <(curl c)   # FINDS
printf '%s\n' a | xargs -n 1 curl   # FINDS
find . -name z -exec curl {} \;   # FINDS
env FOO=1 curl d   # FINDS
bash -c 'curl e'   # FINDS
trap 'curl f' EXIT   # FINDS
eval "curl g"   # FINDS
printf x | curl h   # FINDS
true && curl i   # FINDS
( curl j )   # FINDS
case "$1" in a) curl k ;; esac   # FINDS
f2() {
  curl l   # FINDS
}
if curl m; then :; fi   # FINDS
while curl n; do break; done   # FINDS
command curl o   # FINDS
echo "$(printf '%s' "$(curl p)")"   # FINDS
arr=(one "$(curl q)")   # FINDS
time curl r   # FINDS
! curl s   # FINDS
FOO=bar curl t   # FINDS
curl u >/dev/null 2>&1   # FINDS
{ curl v; }   # FINDS
nohup curl w &   # FINDS
g() { if true; then curl x; fi }   # FINDS
while true; do if true; then curl y; fi done   # FINDS
EOF
expected="$(grep -n '# FINDS' "$FX/constructs.sh" | cut -d: -f1 | tr '\n' ' ')"
out="$(cmd_check "$FX/constructs.sh")"; rc=$?
got="$(fail_lines "$out" "$FX/constructs.sh" curl)"
check "the check reports curl on exactly the lines that call it, and on none that only mention it" \
  "$([ "$got" = "$expected" ] && echo ok || echo "expected lines $expected got $got")"
check "and the check fails" "$([ "$rc" -eq 1 ] && echo ok || echo "exit $rc")"
syntax_as_cmd="$(awk -F '\t' '$1 == "fail" && ($2 == "}" || $2 == "fi" || $2 == "done" || $2 == "esac" || $2 == "then" || $2 == "do" || $2 == "{") { print $2 " at " $3 }' <<< "$out")"
check "no piece of bash syntax, such as a } straight after fi, is reported as a command" \
  "$([ -z "$syntax_as_cmd" ] && echo ok || echo "$syntax_as_cmd")"
check "a function the script defines is listed as a function, not a failure" \
  "$([ -n "$(awk -F '\t' '$1 == "function" && $2 == "helper"' <<< "$out")" ] && echo ok || echo "helper not listed as a function")"
check "and a function defined with a body over several lines is too" \
  "$([ -n "$(awk -F '\t' '$1 == "fail" && $2 == "f2"' <<< "$out")" ] && echo "f2 failed" || echo ok)"

# 4b. A clean script, every kind of command it may use, passes, and the listing names each kind.
cat > "$FX/clean-helper.sh" <<'EOF'
#!/usr/bin/env bash
count_lines() { wc -l < "$1"; }
EOF
cat > "$FX/clean.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/clean-helper.sh"
for f in "$@"; do
  size="$(du -sk "$f" | awk '{print $1}')"
  count_lines "$f" | grep -c 0 >/dev/null || printf '%s %s\n' "$f" "$size"
  "${DISK_CLEAN_TRASH:-/usr/bin/trash}" -s "$f"
done
EOF
out="$(cmd_check "$FX/clean.sh")"; rc=$?
check "a script calling only core tools, builtins, functions, stubs and seams passes" \
  "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: $(grep '^fail' <<< "$out")")"
for kind_name in "core awk" "core grep" "stub du" "builtin printf" "function count_lines" "seam DISK_CLEAN_TRASH" "follow clean-helper.sh" "core wc"; do
  check "and lists $kind_name" \
    "$([ -n "$(awk -F '\t' -v k="${kind_name% *}" -v n="${kind_name#* }" '$1 == k && $2 == n' <<< "$out")" ] && echo ok || echo "not listed")"
done

# 4c. The ways around a stub are each refused, by line.
cat > "$FX/around.sh" <<'EOF'
#!/usr/bin/env bash
/usr/bin/trash -s x
"$TOOL" y
PATH=/usr/bin:$PATH
export PATH="/usr/bin"
env PATH=/bin rm x
command -p rm x
env -i rm x
bash -s < x
printf x | sh
mapfile -t a < x
bash "$UNKNOWN_SCRIPT"
. "$DIR/nowhere-at-all.sh"
EOF
out="$(cmd_check "$FX/around.sh")"; rc=$?
for want in "2 called by its path" "3 through a variable" "4 sets PATH" "5 sets PATH" "6 sets PATH" "7 command -p" "8 env -i" \
  "9 from standard input" "10 from standard input" "11 mapfile" "12 cannot find" "13 cannot find"; do
  line="${want%% *}"; words="${want#* }"
  check "line $line of the ways around a stub is refused ($words)" \
    "$(grep -qF "$words" <<< "$(awk -F '\t' -v l="$FX/around.sh:$line" '$1 == "fail" && $3 == l' <<< "$out")" && echo ok || echo "not reported: $(grep -F "around.sh:$line	" <<< "$out")")"
done

# 4d. A file the script sources or runs is followed, and its own calls are reported against it.
cat > "$FX/runs-others.sh" <<'EOF'
#!/usr/bin/env bash
. "$DIR/sourced-helper.sh"
bash "$DIR/run-helper.sh" --flag
EOF
printf '#!/usr/bin/env bash\n\ncurl x\n' > "$FX/sourced-helper.sh"
printf '#!/usr/bin/env bash\nwget y\n' > "$FX/run-helper.sh"
out="$(cmd_check "$FX/runs-others.sh")"; rc=$?
check "a command in a sourced file is reported at that file's own line" \
  "$([ -n "$(awk -F '\t' -v l="$FX/sourced-helper.sh:3" '$1 == "fail" && $2 == "curl" && $3 == l' <<< "$out")" ] && echo ok || echo "said: $out")"
check "and one in a script run with bash is too" \
  "$([ -n "$(awk -F '\t' -v l="$FX/run-helper.sh:2" '$1 == "fail" && $2 == "wget" && $3 == l' <<< "$out")" ] && echo ok || echo "said: $out")"

# 4e. What the check cannot read is a failure, never a pass.
printf '#!/usr/bin/env bash\necho "never closed\n' > "$FX/unterminated.sh"
printf '#!/usr/bin/env bash\nx=$(echo a\n' > "$FX/unclosed.sh"
printf '#!/usr/bin/env python3\nimport os\nos.remove("x")\n' > "$FX/scan.py"
printf 'import os\n' > "$FX/no-shebang.py"
for f in unterminated.sh unclosed.sh scan.py no-shebang.py; do
  out="$(cmd_check "$FX/$f")"; rc=$?
  check "a file the check cannot read ($f) fails it" \
    "$([ "$rc" -eq 1 ] && [ -n "$(awk -F '\t' '$1 == "fail"' <<< "$out")" ] && echo ok || echo "exit $rc, said: $out")"
done

# 4f. The default scope is whatever disk-clean scripts are present, read from disk (L132).
REPO_FX="$DC_ROOT/repo"
mkdir -p "$REPO_FX/payload/skills/disk-clean/categories" "$REPO_FX/payload/skills/disk-clean/tests" "$REPO_FX/payload/hooks/lib"
printf '#!/usr/bin/env bash\necho scan\n' > "$REPO_FX/payload/skills/disk-clean/scan.sh"
printf '#!/usr/bin/env bash\necho caches\n' > "$REPO_FX/payload/skills/disk-clean/categories/caches.sh"
printf '#!/usr/bin/env bash\ncurl x\n' > "$REPO_FX/payload/skills/disk-clean/tests/fixture.sh"
printf '#!/usr/bin/env bash\ncurl x\n' > "$REPO_FX/payload/skills/disk-clean/test-scan.sh"
printf '# Disk clean\n' > "$REPO_FX/payload/skills/disk-clean/SKILL.md"
printf '#!/usr/bin/env bash\necho remove\n' > "$REPO_FX/payload/hooks/lib/disk-remove.sh"
printf '#!/usr/bin/env bash\ncurl x\n' > "$REPO_FX/payload/hooks/lib/other.sh"
scope="$(DC_REPO="$REPO_FX" dc_scope_files | sed "s|^$REPO_FX/||" | sort | tr '\n' ' ')"
check "the default scope is the skill's scripts and disk-remove.sh, never its suites or fixtures" \
  "$([ "$scope" = "payload/hooks/lib/disk-remove.sh payload/skills/disk-clean/categories/caches.sh payload/skills/disk-clean/scan.sh " ] && echo ok || echo "scope: $scope")"
out="$(DC_REPO="$REPO_FX" dc_check_commands 2>&1)"; rc=$?
check "and the check passes on that scope with no file named" \
  "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: $out")"
printf '#!/usr/bin/env bash\nrsync -a x y\n' > "$REPO_FX/payload/skills/disk-clean/categories/new.sh"
out="$(DC_REPO="$REPO_FX" dc_check_commands 2>&1)"; rc=$?
check "and fails the moment a new script there calls an unstubbed command, naming it" \
  "$([ "$rc" -eq 1 ] && grep -q 'rsync' <<< "$out" && echo ok || echo "exit $rc: $out")"
mkdir -p "$DC_ROOT/empty-repo/payload/hooks/lib"
out="$(DC_REPO="$DC_ROOT/empty-repo" dc_check_commands 2>&1)"; rc=$?
check "with no disk-clean scripts present it says so with its own exit code, never a pass (L98)" \
  "$([ "$rc" -eq 3 ] && grep -qF 'no disk-clean scripts' <<< "$out" && echo ok || echo "exit $rc: $out")"
stdout_only="$(DC_REPO="$DC_ROOT/empty-repo" dc_check_commands 2>/dev/null)$(DC_REPO="$DC_ROOT/no-such-repo" dc_check_commands 2>/dev/null)"
check "those two answers are said on stderr, so stdout holds only listing lines" \
  "$([ -z "$stdout_only" ] && echo ok || echo "stdout: $stdout_only")"
out="$(DC_REPO="$DC_ROOT/no-such-repo" dc_check_commands 2>&1)"; rc=$?
check "a repository it cannot read is exit 2, could not run, never read as nothing present yet (L11)" \
  "$([ "$rc" -eq 2 ] && grep -qF 'could not' <<< "$out" && echo ok || echo "exit $rc: $out")"

# 4g. The real repository, today. An installed copy (~/.claude/hooks) has no repository above it,
# which is a part not measured there; in a checkout an unreadable repository is a failure.
out="$(dc_check_commands 2>&1)"; rc=$?
case "$rc:$DIR" in
  0:*) check "every command the disk-clean scripts call is stubbed or a core tool" ok ;;
  3:*) echo "SUITE-PART-UNMEASURED the command check of the real disk-clean scripts: none exist yet in this repository (phases #1805 to #1809 add them), so it listed nothing" ;;
  2:*/payload/hooks) check "every command the disk-clean scripts call is stubbed or a core tool" "could not run: $out" ;;
  2:*) echo "SUITE-PART-UNMEASURED the command check of the real disk-clean scripts: this copy at $DIR is not inside a repository checkout, so there are no scripts to read" ;;
  *) check "every command the disk-clean scripts call is stubbed or a core tool" "exit $rc: $(grep '^fail' <<< "$out")" ;;
esac

# ================================================================================================
# 5. The real /usr/bin/trash, on a probe file this suite made
# ================================================================================================
measure_real_trash() { # prints check lines as "desc|result"; returns 3 when it could not measure
  local trash="${DC_REAL_TRASH:-/usr/bin/trash}" probe ino out rc dest real_trash dest_ino
  if [ "$(uname -s)" != Darwin ]; then
    # Another system can have an unrelated trash at the same path (trash-cli on Linux).
    printf 'SUITE-PART-UNMEASURED the real trash test: this is %s, and the tool measured is the one macOS 15 ships\n' "$(uname -s)"
    return 3
  fi
  if [ ! -x "$trash" ]; then
    printf 'SUITE-PART-UNMEASURED the real trash test: %s is not on this machine (it ships with macOS 15 and later), so how the trash method behaves was not measured here\n' "$trash"
    return 3
  fi
  mkdir -p "$DC_ROOT/real-trash"
  out="$("$trash" -s "$DC_ROOT/real-trash/never-created" 2>&1)"; rc=$?
  printf '%s|%s\n' "trash -s exits non zero for a path that does not exist" "$([ "$rc" -ne 0 ] && echo ok || echo "exit $rc")"
  probe="$DC_ROOT/real-trash/disk-clean-harness-probe.$$.$RANDOM.txt"
  printf 'probe\n' > "$probe"
  ino="$(ls -di "$probe" | awk '{print $1}')"
  # HOME pointed at the harness's own, to measure whether trash honours it.
  out="$(HOME="$DC_HOME" "$trash" -v -s "$probe" 2>&1)"; rc=$?
  printf '%s|%s\n' "trash -s exits 0 for a file it moved" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc, said: $out")"
  printf '%s|%s\n' "and the file is gone from where it was" "$([ ! -e "$probe" ] && echo ok || echo "still there")"
  dest="$(sed -n 's/.* to "\(.*\)"$/\1/p' <<< "$out")"
  dest="${dest%%$'\n'*}"
  real_trash="$(dc_real_home)/.Trash"
  printf '%s|%s\n' "and it went to the REAL Trash although HOME was the harness's, so no other test may run it" \
    "$(case "$dest" in ("$real_trash"/*) echo ok ;; (*) echo "went to '$dest'" ;; esac)"
  dest_ino="$(ls -di "$dest" 2>/dev/null | awk '{print $1}')"
  if [ -n "$dest" ] && [ "$dest_ino" = "$ino" ]; then
    rm -f "$dest"
    printf '%s|%s\n' "the probe is removed from the Trash again, by inode" "$([ ! -e "$dest" ] && echo ok || echo "$dest is still in the Trash")"
  else
    printf '%s|%s\n' "the probe is removed from the Trash again, by inode" \
      "could not confirm '$dest' is the probe (inode $dest_ino, expected $ino), so nothing was removed; a file named ${probe##*/} may be left in the Trash"
  fi
  return 0
}
# The skip is itself seen to fire, and never to pass (L1, L411).
skip_out="$(DC_REAL_TRASH=/nonexistent/trash measure_real_trash)"; skip_rc=$?
check "a missing trash tool is reported as SUITE-PART-UNMEASURED, not as a pass" \
  "$([ "$skip_rc" -eq 3 ] && grep -q '^SUITE-PART-UNMEASURED ' <<< "$skip_out" && ! grep -q '|ok$' <<< "$skip_out" && echo ok || echo "exit $skip_rc, said: $skip_out")"
trash_out="$(measure_real_trash)"
if grep -q '^SUITE-PART-UNMEASURED ' <<< "$trash_out"; then
  printf '%s\n' "$trash_out"
else
  while IFS='|' read -r desc result; do check "$desc" "$result"; done <<< "$trash_out"
fi

# ================================================================================================
# 6. The real lsof, holding a file open, and the three cases it cannot tell apart by exit code
# ================================================================================================
LSOF="${DC_REAL_LSOF:-}"
if [ -z "$LSOF" ]; then for c in /usr/sbin/lsof /usr/bin/lsof; do [ -x "$c" ] && { LSOF="$c"; break; }; done; fi
if [ "$(uname -s)" != Darwin ]; then
  # The disk-clean tools run on macOS only, and what is recorded here is macOS lsof's behaviour.
  # Linux lsof also writes filesystem warnings to stderr, so its "not open" would not read the same.
  echo "SUITE-PART-UNMEASURED the real lsof test: this is $(uname -s), and the fact recorded is about macOS lsof, the only one the disk-clean tools run"
elif [ -z "$LSOF" ] || [ ! -x "$LSOF" ]; then
  echo "SUITE-PART-UNMEASURED the real lsof test: lsof is not in /usr/sbin or /usr/bin on this machine"
else
  L="$DC_ROOT/lsof"
  mkdir -p "$L/locked"
  printf 'x\n' > "$L/file.txt"
  printf 'x\n' > "$L/locked/f.txt"
  lsof_case() { # lsof_case <path> -> sets lrc, lout, lerr
    lout="$("$LSOF" -- "$1" 2>"$L/err")"; lrc=$?
    lerr="$(cat "$L/err")"
  }
  lsof_case "$L/file.txt"; nrc=$lrc
  check "lsof exits 1 for a file nobody has open" "$([ "$lrc" -eq 1 ] && echo ok || echo "exit $lrc")"
  check "and says nothing on stderr" "$([ -z "$lerr" ] && echo ok || echo "stderr: $lerr")"
  lsof_case "$L/missing.txt"; mrc=$lrc
  check "lsof exits 1 for a file that does not exist" "$([ "$lrc" -eq 1 ] && echo ok || echo "exit $lrc")"
  check "and only stderr says so" "$([ -n "$lerr" ] && echo ok || echo "stderr was empty")"
  if [ "$(id -u)" = 0 ]; then
    echo "SUITE-PART-UNMEASURED lsof on a file it may not read: this suite runs as root, which no permission refuses"
    drc=1
  else
    chmod 000 "$L/locked"
    lsof_case "$L/locked/f.txt"; drc=$lrc
    chmod 755 "$L/locked"
    check "lsof exits 1 for a file it is not permitted to look at" "$([ "$lrc" -eq 1 ] && echo ok || echo "exit $lrc")"
    check "and only stderr says so" "$([ -n "$lerr" ] && echo ok || echo "stderr was empty")"
  fi
  check "so not open, missing and permission denied share one exit code, and only stderr separates them" \
    "$([ "$nrc" = "$mrc" ] && [ "$mrc" = "$drc" ] && echo ok || echo "not open $nrc, missing $mrc, denied $drc")"

  # A real holder, waited for by the condition it signals rather than a fixed time (L290).
  mkfifo "$L/ready" "$L/go"
  bash -c 'exec 3<"$1"; echo ready > "$2"; read -r _ < "$3"' _ "$L/file.txt" "$L/ready" "$L/go" &
  holder=$!
  exec 7<>"$L/ready" 8<>"$L/go"
  if read -r -t 30 signal <&7 && [ "$signal" = ready ]; then
    lsof_case "$L/file.txt"
    check "lsof exits 0 for a file a process holds open" "$([ "$lrc" -eq 0 ] && echo ok || echo "exit $lrc, stderr: $lerr")"
    check "and names the process holding it" \
      "$([ -n "$(awk -v p="$holder" 'NR > 1 && $2 == p' <<< "$lout")" ] && echo ok || echo "pid $holder not in: $lout")"
  else
    check "a process holding the file open signalled it was ready" "it never did within 30 seconds"
  fi
  echo go >&8
  wait "$holder" 2>/dev/null
  exec 7<&- 8<&-
fi

finish
