#!/usr/bin/env bash
# Tests for slack-drafts-only-gate.sh and its rule, slack_drafts_only_gate.py, the gate that leaves
# sessions only able to save Slack drafts (claude-config#2302): a natively compiled tool is read as
# its sources, a module a script writes by a path it cannot work out and then imports, the everyday
# tools read whole with the sources refusal on, a file a shell script is handed read as what it is,
# the judgement cache used only while what it read is unchanged, harmless commands it once misread,
# a binary file and a NUL byte, curl's default config and perl -i, and a type only import.
#
# test-slack-drafts-only-gate.sh held every check of the gate, 2,633 of them, until on 2026-11-24 it
# ran past run-all-tests.sh's 1,200 second wall limit on GitHub's runners in three runs of four,
# each time stopping the config sync between the two Macs: one piece held against a fixed deadline
# had grown to most of it (L315). Its sections are now six suites, each a run of them in their
# order, dealt by their own measured cost (claude-config#3575): -scripts, -written-files,
# -file-arguments, test-slack-drafts-only-gate.sh itself (the gate as a whole: /nudge, a payload it
# cannot read, its time budget, a crash, its wiring and its cost), -runners and -tools-cache. Every
# check is as it was, and a comment saying "above" or "below" means in whichever of the six holds it.
#
# The world they all run in (the gate under test, the throwaway folder and its judgement cache, the
# result line, and the fixtures one section makes and a section in another suite reads) is
# lib/slack-drafts-gate-harness.sh, the one place each of them takes it from. The helper functions
# are the one thing each holds a copy of, below, because the gate reads functions only where they
# are called.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/slack-drafts-gate-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/slack-drafts-gate-harness.sh is missing, so there is no gate to run and no world to run it in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

# The helpers every case is driven through, copied as they are into each of the six suites: the
# gate knows a shell function only where the text calling it defines it (lib/unknown-program.py,
# #3304), so with these in a sourced file it would read `run_bash "<a command that posts>"` as an
# unknown program running that command, and refuse a plain run of this suite.
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_tool() { run_raw "$(payload "$1" "$2")"; }
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }

# Helpers a section in an earlier suite defines, copied as they are for the same reason.
PY3="$(command -v python3)"
sv_env() { # sv_env <folder> [package]
  mkdir -p "$1/bin" "$1/lib/python3.12/site-packages"
  printf '%s\n' 'home = /usr/bin' > "$1/pyvenv.cfg"
  ln -sf "$PY3" "$1/bin/python"
  if [ -n "${2:-}" ]; then
    mkdir -p "$1/lib/python3.12/site-packages/$2/_app"
    : > "$1/lib/python3.12/site-packages/$2/__init__.py"
    : > "$1/lib/python3.12/site-packages/$2/_app/__init__.py"
    printf '%s\n' 'def main():' '    print("select 1")' > "$1/lib/python3.12/site-packages/$2/_app/__main__.py"
  fi
}
sv_tool() { # sv_tool <file> <first line> [module]: an entry point script, as pip writes one
  printf '%s\n' "$2" 'import sys' "from ${3:-fakecli._app.__main__} import main" 'sys.exit(main())' > "$1"
  chmod +x "$1"
}
lacks() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:400}" ;; *) check "$1" ok ;; esac; }
read_refused() {
  refused "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}

echo "slack drafts only: a natively compiled tool is read as its sources, and a build in a script is followed (claude-config#2869, #2852)"

# #2869: on 2026-11-12 `[ -x "$T" ] || swiftc -O tools/facecolor2.swift -o "$T"; printf ... | "$T" |
# python3 -I -c '...'` was refused, as a file swiftc may write in a way the gate does not follow. A
# native compiler's output is now read as the sources it is built from (and then as it is on disk,
# which runs where the build is skipped), so a quiet tool passes and one whose source names an
# endpoint is refused. Measured through this wrapper on main at 6ce6746, 2026-11-12: every allowed
# shape below was refused or every refused one with no -o passed (the output was read on disk only).
N="$T/n2869"
mkdir -p "$N/tools" "$N/inc" "$N/sys" "$N/gq" "$N/gp/net" "$N/rq" "$N/rp" "$N/cq/src" "$N/cp/src" "$N/esrc" "$N/tsrc" "$N/dist"
URL2869='https://hooks.slack.com/services/T0/B0/x'
printf '%s\n' 'print("{}")' > "$N/tools/quiet.swift"
printf '%s\n' "let u = URL(string: \"$URL2869\")!" > "$N/tools/post.swift"
printf '%s\n' 'int main(void) { return 0; }' > "$N/quiet.c"
printf '%s\n' "const char *u = \"$URL2869\";" 'int main(void) { return 0; }' > "$N/post.c"
printf '%s\n' '#include "post.h"' 'int main(void) { return 0; }' > "$N/inc/hdr.c"
printf '%s\n' "#define U \"$URL2869\"" > "$N/inc/post.h"
printf '%s\n' '#include "quiet.h"' 'int main(void) { return 0; }' > "$N/inc/qhdr.c"
printf '%s\n' '#define U "x"' > "$N/inc/quiet.h"
printf '%s\n' '#include <spost.h>' 'int main(void) { return 0; }' > "$N/angle.c"
printf '%s\n' "#define U \"$URL2869\"" > "$N/sys/spost.h"
printf '%s\n' 'module example.com/gq' > "$N/gq/go.mod"
printf '%s\n' 'package main' 'func main() {}' > "$N/gq/main.go"
printf '%s\n' 'module example.com/gp' > "$N/gp/go.mod"
printf '%s\n' 'package main' 'import "example.com/gp/net"' 'func main() { net.Send() }' > "$N/gp/main.go"
printf '%s\n' 'package net' "func Send() { _ = \"$URL2869\" }" > "$N/gp/net/net.go"
printf '%s\n' 'fn main() {}' > "$N/rq/main.rs"
printf '%s\n' 'mod net;' 'fn main() { net::send(); }' > "$N/rp/main.rs"
printf '%s\n' "pub fn send() { let _ = \"$URL2869\"; }" > "$N/rp/net.rs"
printf '%s\n' '[package]' 'name = "cq"' > "$N/cq/Cargo.toml"
printf '%s\n' 'fn main() {}' > "$N/cq/src/main.rs"
printf '%s\n' '[package]' 'name = "cp"' > "$N/cp/Cargo.toml"
printf '%s\n' 'mod net;' 'fn main() { net::send(); }' > "$N/cp/src/main.rs"
printf '%s\n' "pub fn send() { let _ = \"$URL2869\"; }" > "$N/cp/src/net.rs"
# Stand ins for tools built before, on disk and quiet: what runs where the build is skipped.
for f in tool app a.out gtool rtool; do printf 'binary\n' > "$N/$f"; chmod +x "$N/$f"; done
run_n() { run_raw "$(payload Bash "$(bash_input "$1")" "$N")"; }

for runs in "swiftc -O tools/post.swift -o tool && ./tool" \
  "[ -x tool ] || swiftc -O tools/post.swift -o tool; printf '%s\\n' a | ./tool | python3 -I -c 'import sys; print(sys.stdin.read())'" \
  "swiftc tools/post.swift && ./post" "clang post.c -o app && ./app" "clang post.c && ./a.out" "gcc -oapp post.c && ./app" \
  "clang++ post.c -o app && ./app" "cc -c post.c && cc post.o -o app && ./app" "clang inc/hdr.c -o app && ./app" \
  "clang -Isys angle.c -o app && ./app" "go build -o gtool ./gp && ./gtool" "cd gp && go build && ./gp" \
  "rustc rp/main.rs -o rtool && ./rtool" "rustc rp/main.rs && ./main" \
  "cargo build --manifest-path cp/Cargo.toml && ./cp/target/debug/cp" "cd cp && cargo build --release && ./target/release/cp"; do
  run_n "$runs"
  read_refused "a tool a native compiler builds from a source that names an endpoint is read as that source: $runs"
done
run_n "swiftc -O tools/post.swift -o tool && ./tool"
says "the refusal names the source the compiler builds from" "which swiftc builds from tools/post.swift"
for runs in "swiftc -O tools/quiet.swift -o tool && ./tool" \
  "[ -x tool ] || swiftc -O tools/quiet.swift -o tool; printf '%s\\n' a | ./tool | python3 -I -c 'import sys; print(sys.stdin.read())'" \
  "swiftc tools/quiet.swift && ./quiet" "clang quiet.c -o app && ./app" "clang quiet.c && ./a.out" "gcc -oapp quiet.c && ./app" \
  "clang++ quiet.c -o app && ./app" "cc -c quiet.c && cc quiet.o -o app && ./app" "clang inc/qhdr.c -o app && ./app" \
  "go build -o gtool ./gq && ./gtool" "cd gq && go build && ./gq" "rustc rq/main.rs -o rtool && ./rtool" \
  "cargo build --manifest-path cq/Cargo.toml && ./cq/target/debug/cq"; do
  run_n "$runs"
  allowed "a tool a native compiler builds from quiet sources passes: $runs"
done
# cargo b is build's short form, and the word after -p is a package name, even one called build:
# the options are read from after the subcommand word, not from after the first word spelled build.
# Measured at 9c25864c6f: reading from after "-p build" lost --manifest-path, the package was not
# found, and the tool built from a source naming an endpoint passed.
run_n "cargo b --manifest-path cq/Cargo.toml -p build && ./cq/target/debug/cq"
allowed "cargo b with a package named build reads its options from after the subcommand"
run_n "cargo b --manifest-path cp/Cargo.toml -p build && ./cp/target/debug/cp"
read_refused "cargo b with a package named build still reads the sources it builds from"
# The reported command's shape, its tool named through variables the command sets.
run_n "W=$N; T=\"\$W/tool\"; [ -x \"\$T\" ] || swiftc -O \"\$W/tools/quiet.swift\" -o \"\$T\"; printf '%s\\n' a | \"\$T\" 2>/dev/null | python3 -I -c 'import json,sys
for l in sys.stdin: print(json.loads(l))'"
allowed "#2869 the reported swiftc command, its tool built from a quiet source, passes"
run_n "W=$N; T=\"\$W/tool\"; [ -x \"\$T\" ] || swiftc -O \"\$W/tools/post.swift\" -o \"\$T\"; printf '%s\\n' a | \"\$T\" 2>/dev/null | python3 -I -c 'import json,sys
for l in sys.stdin: print(json.loads(l))'"
read_refused "#2869 the reported swiftc command, its tool built from a source naming an endpoint, is refused"
# What cannot be read is still refused: a source downloaded earlier in the command, and a compile
# with a word that cannot be worked out, whose output is then not followed and keeps its mark.
for runs in "curl -s -o new.c https://example.com/x.c; clang new.c -o app; ./app" \
  "curl -s -o new.c https://example.com/x.c; clang new.c; ./a.out" \
  "curl -s -o new.ts https://example.com/x.ts; esbuild new.ts --outfile=o.js; node o.js" \
  "swiftc tools/quiet.swift \$EXTRA -o tool && ./tool"; do
  run_n "$runs"
  read_refused "a compiled tool whose source or build cannot be read is still refused: $runs"
done

# #2869: the python3 -c code refused as unparseable was a real syntax error: a backslash inside an
# f-string's braces, which no Python accepts (python3.14 reads `f"{m[\"w\"]}"` as a line
# continuation). Code that cannot be parsed counts as able to act on what it is handed, and it was
# handed what a tool printed, so it is still refused, and the refusal now says what Python found, so
# the code is fixed rather than moved into a file. The same code written correctly passes.
cat > "$N/pybad.cmd" <<'CMD'
./tool 2>/dev/null > measure.jsonl; python3 -I -c '
import json,sys
for l in open(sys.argv[1]):
    m=json.loads(l)
    print(f"{m[\"w\"]}x{m[\"h\"]}")' measure.jsonl
CMD
run_n "$(cat "$N/pybad.cmd")"
read_refused "#2869 python3 -c code that does not parse is still refused"
# The wording is the running python3's own: 3.12 and later say "unexpected character after line
# continuation character", 3.11 and earlier "f-string expression part cannot include a backslash"
# (measured 2026-11-14 with 3.14.4, 3.11 and 3.9.6), and the gate runs the same python3 (#2915).
said2869="$(python3 -c '
import sys
code = open(sys.argv[1]).read().split("-c \x27", 1)[1].rsplit("\x27 measure.jsonl", 1)[0]
try:
    compile(code, "<code>", "exec")
except SyntaxError as e:
    print(e.msg)' "$N/pybad.cmd")"
if [ -n "$said2869" ]; then
  says "the refusal names the syntax error Python reports" "$said2869"
else
  check "the bad code fails to parse on this python3, so the refusal can name its error" "python3 compiled it"
fi
# Written so every python3 parses it: a quote nested in an f-string's braces parses only on 3.12 and
# later (PEP 701), so the earlier `f"{m["w"]}..."` was refused on an older python3 (#2915).
cat > "$N/pygood.cmd" <<'CMD'
./tool 2>/dev/null > measure.jsonl; python3 -I -c '
import json,sys
for l in open(sys.argv[1]):
    m=json.loads(l)
    w, h = m["w"], m["h"]
    print(f"{w}x{h}")' measure.jsonl
CMD
run_n "$(cat "$N/pygood.cmd")"
allowed "#2869 the same code written so it parses, handed what a tool on disk printed, passes"

# #2852: a build run inside a script on disk or a package script was not followed, so `npm run build
# && node out.js` read out.js as it was on disk before the build. It is now read as its source.
printf '%s\n' "fetch('$URL2869');" > "$N/esrc/post.ts"
printf '%s\n' "console.log('hi');" > "$N/esrc/quiet.ts"
printf '%s\n' "console.log('old');" > "$N/out.js"
printf '%s\n' "fetch('$URL2869');" > "$N/tsrc/x.ts"
printf '%s\n' "console.log('old');" > "$N/dist/x.js"
printf '%s\n' '{ "compilerOptions": { "outDir": "dist", "rootDir": "tsrc" }, "include": ["tsrc"] }' > "$N/tsconfig.json"
printf '%s\n' '#!/bin/sh' 'esbuild esrc/post.ts --outfile=out.js' > "$N/build-post.sh"
printf '%s\n' '#!/bin/sh' 'esbuild esrc/quiet.ts --outfile=out.js' > "$N/build-quiet.sh"
printf '%s\n' '#!/bin/sh' 'clang post.c -o app' > "$N/mk-post.sh"
printf '%s\n' '#!/bin/sh' 'clang quiet.c -o app' > "$N/mk-quiet.sh"
printf '%s\n' '{ "scripts": { "build": "esbuild esrc/post.ts --outfile=out.js", "buildq": "esbuild esrc/quiet.ts --outfile=out.js", "tsbuild": "tsc" } }' > "$N/package.json"
for runs in "bash build-post.sh && node out.js" "sh mk-post.sh && ./app" "npm run build && node out.js" \
  "pnpm run build && node out.js" "npm run tsbuild && node dist/x.js"; do
  run_n "$runs"
  read_refused "#2852 a build a script or package script runs is read as its source, which names an endpoint: $runs"
done
for runs in "bash build-quiet.sh && node out.js" "sh mk-quiet.sh && ./app" "npm run buildq && node out.js"; do
  run_n "$runs"
  allowed "#2852 a build a script or package script runs, from a quiet source, passes: $runs"
done

echo "slack drafts only: a module a script on disk writes by a path it cannot work out, then imports (claude-config#2854)"

# test-lib-bytecode-importers.sh writes `printf 'X = 1\n' > "$TMPROOT/fault/lib/fault_probe.py"` and
# imports it with sys.path.insert(0, sys.argv[1]) and "$TMPROOT/fault/lib", TMPROOT from mktemp, so the
# gate placed the import nowhere and refused the suite run alone. A literal write in the same script,
# by the same words, certain to have run, with nothing between it and the import that can change those
# words or write that file, is now read as the module.
F="$T/f2854"
mkdir -p "$F"
f2854() { # f2854 <name> <the write> [<between the write and the import>]: a script in the suite's shape
  {
    printf '%s\n' '#!/usr/bin/env bash' 'TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/f2854.XXXXXXXX")"' 'mkdir -p "$TMPROOT/fault/lib"'
    printf '%s\n' "$2"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf '%s\n' "python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fault_probe' \"\$TMPROOT/fault/lib\""
    printf '%s\n' 'on="$(find "$TMPROOT/fault/lib" -name "*.pyc" | wc -l)"' 'rm -rf "$TMPROOT/fault/lib/__pycache__"'
    # Written again before the second import, as the suite does: the first import is a python run
    # handed the folder, which the gate cannot see writes nothing there (raw_unchanged).
    [ "$1" = twice ] || printf '%s\n' "printf 'X = 1\\n' > \"\$TMPROOT/fault/lib/fault_probe.py\""
    printf '%s\n' "python3 -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import fault_probe' \"\${TMPROOT}/fault/lib\""
  } > "$F/$1.sh"
}
WRITE2854="printf 'X = 1\\n' > \"\$TMPROOT/fault/lib/fault_probe.py\""
f2854 ok "$WRITE2854"
f2854 heredoc "cat > \"\$TMPROOT/fault/lib/fault_probe.py\" <<'PY'
X = 1
PY"
f2854 posts "printf 'import urllib.request\\nurllib.request.urlopen(\"https://hooks.slack.com/services/T0/B0/x\")\\n' > \"\$TMPROOT/fault/lib/fault_probe.py\""
f2854 posts-nested "printf 'import os, sys\\nsys.path.insert(0, os.path.dirname(__file__))\\nimport helper_2854\\n' > \"\$TMPROOT/fault/lib/fault_probe.py\""
f2854 curl "curl -s -o \"\$TMPROOT/fault/lib/fault_probe.py\" https://example.com/x.py"
f2854 unreadable "some_tool > \"\$TMPROOT/fault/lib/fault_probe.py\""
f2854 rebound "$WRITE2854" 'TMPROOT="$(mktemp -d)"'
f2854 cond "if [ -n \"\$X\" ]; then $WRITE2854; fi"
f2854 chained "[ -n \"\$X\" ] && $WRITE2854"
f2854 append "printf 'X = 1\\n' >> \"\$TMPROOT/fault/lib/fault_probe.py\""
f2854 copied "$WRITE2854" 'cp /tmp/elsewhere.py "$TMPROOT/fault/lib/fault_probe.py"'
f2854 unpacked "$WRITE2854" 'tar -xf /tmp/elsewhere.tar -C "$TMPROOT/fault/lib"'
f2854 sourced "$WRITE2854" 'source "$TMPROOT/env.sh"'
# Lessons review of PR #2876: a program the gate does not know to write nothing, handed the module's
# folder, a parent of it or a word it cannot work out, may rewrite the module between the write and
# the import, so the import is no longer read as the text written (raw_unchanged).
f2854 gen-folder "$WRITE2854" 'gen_tool "$TMPROOT/fault/lib"'
f2854 gen-slash "$WRITE2854" 'gen_tool "$TMPROOT/fault/lib/"'
f2854 gen-parent "$WRITE2854" 'gen_tool "$TMPROOT/fault"'
f2854 gen-root "$WRITE2854" 'gen_tool --out="$TMPROOT"'
f2854 gen-var "$WRITE2854" 'OUT="$TMPROOT/fault/lib"
gen_tool "$OUT"'
f2854 gen-subst "$WRITE2854" 'made="$(gen_tool "$TMPROOT/fault/lib")"'
f2854 gen-unknown "$WRITE2854" 'gen_tool "$(pick_dir)"'
f2854 gen-literal "$WRITE2854" 'gen_tool ../somewhere'
f2854 gen-cond "$WRITE2854" 'if gen_tool "$TMPROOT/fault/lib"; then :; fi'
f2854 gen-wrapped "$WRITE2854" 'timeout 5 gen_tool "$TMPROOT/fault/lib"'
f2854 gen-piped "$WRITE2854" 'ls "$TMPROOT" | gen_tool'
f2854 prog-var "$WRITE2854" '"$TOOL" "$TMPROOT/fault/lib"'
f2854 removed "$WRITE2854" 'rm -rf "$TMPROOT/fault"'
f2854 redirect-var "$WRITE2854" 'echo "X = 2" > "$TMPROOT/fault/lib/$NAME"'
f2854 twice "$WRITE2854"
# A program known to write nothing (NON_WRITERS) handed the folder, and a redirect to a file that is
# not the module, leave it as written.
f2854 ls-folder "$WRITE2854" 'ls -la "$TMPROOT/fault/lib"'
f2854 wc-file "$WRITE2854" 'n="$(wc -l < "$TMPROOT/fault/lib/notes.txt")"'
f2854 listing "$WRITE2854" 'ls "$TMPROOT/fault/lib" > "$TMPROOT/listing.txt"'
run_f() { run_raw "$(payload Bash "$(bash_input "$1")" "$F")"; }
for s in ok heredoc ls-folder wc-file listing; do
  run_f "bash $s.sh"
  allowed "#2854 a module a script writes by a path it cannot work out, then imports from that folder, is read: $s"
done
run_f "bash posts.sh"
read_refused "#2854 that module is read as what was written, and refused where it names an endpoint"
says "the refusal names the module the script wrote" "fault_probe"
run_f "bash posts-nested.sh"
read_refused "#2854 that module's own imports are followed: one placed beside it, which cannot be read, is refused"
for s in curl unreadable rebound cond chained append copied unpacked sourced; do
  run_f "bash $s.sh"
  read_refused "#2854 a module whose text the script does not certainly write, by those words, is still refused: $s"
done
for s in gen-folder gen-slash gen-parent gen-root gen-var gen-subst gen-unknown gen-literal gen-cond gen-wrapped \
    gen-piped prog-var removed redirect-var twice; do
  run_f "bash $s.sh"
  read_refused "#2876 review: a module a program not known to write nothing may change after the write is not read as written: $s"
done
# The suite itself now runs alone, from the checkout this suite is in (lib/checkout-root.sh, #1663).
REPO2854="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$REPO2854" ]; then
  run_raw "$(payload Bash "$(bash_input "bash payload/hooks/test-lib-bytecode-importers.sh")" "$REPO2854")"
  allowed "#2854 test-lib-bytecode-importers.sh is allowed run on its own"
else
  printf 'SUITE-PART-UNMEASURED %s\n' "#2854 the bytecode suite run alone: this suite is not in a claude-config checkout"
fi

echo "slack drafts only: with the sources refusal on, the everyday tools are read whole and let through (claude-config#2538)"
# Switched on, a file sourced by a path the gate cannot work out is refused, so a tool every session
# runs has to set each path it sources plainly. Before #2538's rewrite run-all-tests.sh took its issue
# spool library from HOOK_SPOOL_LIB and was refused, and with it plan-council's healthcheck.
for f in run-all-tests.sh lib/merge-when-ready.sh lib/issue-spool.sh lib/suite-deadline.sh lib/push-scope.sh; do
  run_bash "bash $DIR/$f"
  allowed "#2538 the sources refusal is on, and hooks/$f is allowed"
done
if [ -n "$REPO2854" ]; then
  for f in claude-sync tools/load-window.sh tests/test-claude-sync.sh; do
    run_bash "bash $REPO2854/$f"
    allowed "#2538 the sources refusal is on, and $f is allowed"
  done
else
  printf 'SUITE-PART-UNMEASURED %s\n' "#2538 claude-sync, load-window and the claude-sync suite: this suite is not in a claude-config checkout"
fi

echo
echo "slack drafts only: a TypeScript, JavaScript or Python file a shell script is handed is read as what it is, not as commands (claude-config#2792)"

# On 2026-11-11 a test run was refused on the work MacBook: vitest, run by the launcher pnpm writes
# into node_modules/.bin (a shell script that execs node on the package), handed one test file. The
# launcher's being a shell script made the gate read the file it was handed as shell commands, so
# `return b => // a comment` read as a command writing a file named //, and the next comment line as
# a run of that file, which nothing could read: "the script // is written earlier in this command by
# return". The same reading reached any shell script handing its arguments on (a test wrapper). A
# file that says what it is, by its extension or its #!, is now read as that when it is handed to a
# script, as it already was when the launcher is a node script (npm's own node_modules/.bin).
V="$T/v2792"
mkdir -p "$V/node_modules/.bin" "$V/node_modules/vitest/dist" "$V/src" "$V/scripts"
# pnpm's launcher, as it writes one (measured from a real one, 2026-11-13, its paths renamed).
cat > "$V/node_modules/.bin/vitest" <<'SHIM'
#!/bin/sh
basedir=$(dirname "$(echo "$0" | sed -e 's,\\,/,g')")
basedir_win="$basedir"
exe=""

case `uname -a` in
  *CYGWIN*|*MINGW*|*MSYS*)
    if command -v cygpath > /dev/null 2>&1; then
      basedir_win=`cygpath -w "$basedir"`
    fi
    exe=".exe"
  ;;
esac

if [ -z "$NODE_PATH" ]; then
  export NODE_PATH="/w/app/node_modules/.pnpm/vitest@3.2.4/node_modules/vitest/node_modules:/w/app/node_modules/.pnpm/node_modules"
else
  export NODE_PATH="/w/app/node_modules/.pnpm/vitest@3.2.4/node_modules/vitest/node_modules:/w/app/node_modules/.pnpm/node_modules:$NODE_PATH"
fi
if [ -n "$exe" ] && [ -x "$basedir/node.exe" ]; then
  exec "$basedir/node.exe"  "$basedir_win/../vitest/vitest.mjs" "$@"
elif [ -x "$basedir/node" ]; then
  exec "$basedir/node"  "$basedir/../vitest/vitest.mjs" "$@"
else
  exec node  "$basedir/../vitest/vitest.mjs" "$@"
fi
SHIM
chmod +x "$V/node_modules/.bin/vitest"
printf '%s\n' '#!/usr/bin/env node' "import './dist/cli.js'" > "$V/node_modules/vitest/vitest.mjs"
# The runner starts workers, so it counts as able to run what it is handed, as the real one does.
printf '%s\n' "import { fork } from 'node:child_process'" 'for (const f of process.argv.slice(3)) fork(f)' > "$V/node_modules/vitest/dist/cli.js"
printf '%s\n' '#!/bin/sh' 'exec node node_modules/vitest/vitest.mjs run "$@"' > "$V/scripts/test.sh"
chmod +x "$V/scripts/test.sh"
# The test file: an arrow function before a comment, inside a function that returns it, then a
# comment line of its own.
printf '%s\n' "import { expect, it } from 'vitest'" '' 'const adder = (a: number) => {' '  return b => // b is added to a' '    a + b' '}' '' \
  '// Adding is the same in either order.' "it('adds', () => {" '  expect(adder(1)(2)).toBe(3)' '})' > "$V/src/adder.test.ts"
printf '%s\n' 'import { it } from "vitest"' '// posts for real' 'it("posts", () => fetch("https://slack.com/api/chat.postMessage"))' > "$V/src/posts.test.ts"
printf '%s\n' 'export const post = (text: string) => fetch("https://hooks.slack.com/services/T0/B0/x", { method: "POST", body: text })' > "$V/src/poster.ts"
printf '%s\n' 'import { it } from "vitest"' 'import { post } from "./poster"' '// sends through the poster' 'it("posts", () => post("hi"))' > "$V/src/imports-poster.test.ts"
printf '%s\n' '#!/bin/sh' 'curl -d hi https://hooks.slack.com/services/T0/B0/x' > "$V/scripts/poster.sh"
# Shell commands in a file with no extension and no #!, in one whose #! names a shell whatever its
# extension, and in one named as TypeScript with no #!.
printf '%s\n' 'sh scripts/poster.sh' > "$V/scripts/plain"
printf '%s\n' '#!/bin/sh' 'sh scripts/poster.sh' > "$V/scripts/shebang.ts"
printf '%s\n' 'sh scripts/poster.sh' > "$V/scripts/named.ts"
run_v() { run_raw "$(payload Bash "$(bash_input "$1")" "$V")"; }

for runs in "./node_modules/.bin/vitest run src/adder.test.ts" "node_modules/.bin/vitest run src/adder.test.ts" \
  "$V/node_modules/.bin/vitest run src/adder.test.ts" "bash scripts/test.sh src/adder.test.ts" "./scripts/test.sh src/adder.test.ts"; do
  run_v "$runs"
  allowed "a test file whose comments follow an arrow, handed to a shell launcher, is read as TypeScript: ${runs#"$V"/}"
done
# What the file is read for is unchanged: the endpoint it names, and now the modules it imports, as
# when a node script is handed it.
run_v "./node_modules/.bin/vitest run src/posts.test.ts"
read_refused "a test file naming an endpoint, handed to a shell launcher, is still refused"
says "the refusal names the endpoint in the test file" "src/posts.test.ts posts to Slack (it names chat.postMessage)"
run_v "./node_modules/.bin/vitest run src/imports-poster.test.ts"
read_refused "a test file importing a module that posts, handed to a shell launcher, is refused as TypeScript is"
says "the refusal follows the import to the module that posts" "poster"
run_v "node node_modules/vitest/vitest.mjs run src/imports-poster.test.ts"
read_refused "the same test file handed to the node script itself is refused the same way (the control)"
# A file that does not say what it is, or says it is a shell script, is still read as commands.
run_v "./node_modules/.bin/vitest run scripts/plain"
read_refused "a file with no extension and no #!, handed to a shell launcher, is still read as commands"
says "the refusal follows the command in it" "scripts/poster.sh runs a command that posts"
run_v "./node_modules/.bin/vitest run scripts/shebang.ts"
read_refused "a file whose #! names a shell is read as commands whatever its extension"
# A shell run on the file itself reads it as commands, as the shell would: only a file handed to a
# script is read by its own name.
run_v "bash scripts/named.ts"
read_refused "a shell run on a file named as TypeScript still reads it as commands"
# The one thing that passed through no longer followed: shell commands in a file named as
# TypeScript with no #!, handed to a shell script as an argument. Read as TypeScript it imports
# nothing and names no endpoint. Recorded here so the change is a decision, not a surprise.
run_v "./node_modules/.bin/vitest run scripts/named.ts"
allowed "shell commands in a file named as TypeScript, handed to a shell launcher, are read as TypeScript (no longer followed)"

echo "slack drafts only: a judgement kept in the cache is used only while everything it read is unchanged (#2918)"
# The gate keeps an allowed call's judgement, keyed on what it was given, with every file it read and
# every disk test it answered recorded and checked again before the kept answer is used. A refusal is
# never kept. The cache's own checks (the one route to the disk, the size bound) are in
# test-judgement-cache.sh; these are the judgements themselves.
JC="$T/jc"; mkdir -p "$JC/w"
export SLACK_GATE_CACHE_DIR="$T/jc-cache" SLACK_GATE_CACHE_TRACE="$T/jc-trace"
jc_run() { : > "$SLACK_GATE_CACHE_TRACE"; run_raw "$(payload Bash "$(bash_input "$1")" "$JC/w")"; }
# traced <what> <start> [<also>]: a trace line starts with <start> (so "stored" is never "not stored")
# and, where given, holds <also>.
traced() { if awk -v p="$2" -v q="${3:-}" 'index($0, p) == 1 && (q == "" || index($0, q)) { f = 1 } END { exit !f }' "$SLACK_GATE_CACHE_TRACE"
           then check "$1" ok; else check "$1" "the cache traced: $(tr '\n' '|' < "$SLACK_GATE_CACHE_TRACE")"; fi; }
printf '%s\n' '#!/bin/bash' 'D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' '. "$D/lib.sh"' 'bash "$D/later.sh"' > "$JC/run.sh"
printf '%s\n' 'greet() { echo hi; }' > "$JC/lib.sh"
POSTS="curl -s https://slack.com/api/chat""\x2epostMessage -d text=hi"
jc_run "bash $JC/run.sh"
allowed "a script sourcing a file that does not post is allowed"
traced "its judgement is kept" "stored"
jc_run "bash $JC/run.sh"
allowed "judged again with nothing changed, it is allowed"
traced "the second judgement is answered from the cache" "hit"
# A changed sourced file: the kept judgement read lib.sh, so it is judged afresh and refused.
cp "$JC/lib.sh" "$JC/lib.sh.was"
printf "$POSTS\n" >> "$JC/lib.sh"
jc_run "bash $JC/run.sh"
refused "once the file it sources posts, the same command is refused"
traced "the kept judgement is not used once a file it read has changed" "miss: read" "answers differently now"
traced "a refusal is never kept" "not stored: refused"
cp "$JC/lib.sh.was" "$JC/lib.sh"
jc_run "bash $JC/run.sh"
allowed "with the sourced file put back as it was, it is allowed"
traced "and answered from the cache, which keys a file on what it holds" "hit"
# A changed disk answer: later.sh was not there, so there was nothing to run. Made, and posting, it is.
printf "$POSTS\n" > "$JC/later.sh"
jc_run "bash $JC/run.sh"
refused "once the script it runs is there and posts, the same command is refused"
traced "the kept judgement is not used once a disk test it answered would answer differently" "miss: " "later.sh'] answers differently now"
rm -f "$JC/later.sh"
# A corrupt entry: unreadable as an entry, it is no judgement, and the call is judged afresh.
for f in "$T/jc-cache"/*.json; do printf 'not an entry' > "$f"; done
jc_run "bash $JC/run.sh"
allowed "with its kept entry corrupt, the command is judged afresh and allowed"
traced "a corrupt entry is not used" "miss: the entry is not an entry"
traced "and the fresh judgement is kept in its place" "stored"
for f in "$T/jc-cache"/*.json; do python3 -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s[: len(s) // 2])' "$f"; done
jc_run "bash $JC/run.sh"
traced "an entry cut short is not used" "miss: the entry is not an entry"
for f in "$T/jc-cache"/*.json; do
  python3 -c 'import json, sys; p = sys.argv[1]; e = json.load(open(p)); e["reads"] = e["reads"][1:]; json.dump(e, open(p, "w"))' "$f"
done
jc_run "bash $JC/run.sh"
traced "an entry with a recorded read taken out is not used" "miss: the entry is not a whole allow"
# A change to anything the key covers is a different entry: an environment variable the gate reads.
CDPATH="$JC" jc_run "bash $JC/run.sh"
traced "a call judged with a different value of a variable the gate reads finds no entry" "miss: no entry"
# Kept parses (#2918, Dan's decision of 2026-11-15): the reader's parse of a large file is kept by
# the file's contents, so another call reading the same file is spared reading it, and a file changed
# by one line is read afresh. The cache's own checks are in test-judgement-cache.sh.
for i in $(seq 1 4000); do printf 'echo "line %d" | tr a b\n' "$i"; done > "$JC/big.sh"
jc_run "bash $JC/big.sh"
allowed "a large script that does not post is allowed"
traced "its parse is kept" "parse stored"
jc_run "bash $JC/big.sh --again"
allowed "another call running the same script is allowed"
traced "and is spared reading it, its parse kept" "parse hit"
printf "$POSTS\n" >> "$JC/big.sh"
jc_run "bash $JC/big.sh --again"
refused "once the large script posts, the same command is refused"
traced "its changed text does not find the kept parse" "parse miss: no entry"
# A script run by its path places its imports where the python its first line names does (#3144), so
# a kept judgement is not used once that environment's package, or the first line, has changed.
JSV="$JC/sv"
sv_env "$JSV/env" fakecli
sv_env "$JSV/bare"
sv_tool "$JSV/env/bin/fake" "#!$JSV/env/bin/python"
jc_run "$JSV/env/bin/fake sql"
allowed "a script whose package is installed where its first line's python finds it is allowed"
traced "its judgement is kept" "stored"
jc_run "$JSV/env/bin/fake sql"
traced "judged again with nothing changed, it is answered from the cache" "hit"
mv "$JSV/env/lib/python3.12/site-packages/fakecli" "$JSV/fakecli.was"
jc_run "$JSV/env/bin/fake sql"
refused "once the package has gone from that environment, the same command is refused"
traced "the kept judgement is not used once the package has gone" "miss: " "answers differently now"
mv "$JSV/fakecli.was" "$JSV/env/lib/python3.12/site-packages/fakecli"
jc_run "$JSV/env/bin/fake sql"
allowed "with the package put back, it is allowed"
sv_tool "$JSV/env/bin/fake" "#!$JSV/bare/bin/python"
jc_run "$JSV/env/bin/fake sql"
refused "once its first line names an environment without the package, it is refused"
traced "the kept judgement is not used once the first line has changed" "miss: " "answers differently now"
# A Python script that names an endpoint in a comment has its comments found with tokenize (#2913).
# The gate imported that module where it used it, in the middle of the judgement, and a module's own
# files read then are a read the cache's record never saw, so no such judgement was kept. The command
# that starts this suite is one: it was judged whole, about 19 units, every time it was asked (#3255).
printf '%s\n' '# chat.postMessage is named here only in a comment.' 'print(1)' > "$JC/prose.py"
jc_run "python3 $JC/prose.py"
allowed "a Python script naming an endpoint only in a comment is allowed"
traced "its judgement is kept, comments and all (#3255)" "stored"
jc_run "python3 $JC/prose.py"
allowed "judged again with nothing changed, it is allowed"
traced "and that second judgement is answered from the cache (#3255)" "hit"
# Kept, it is still only as good as the file it read: once the script can send the name, it is refused.
printf '%s\n' 'URL = "https://slack.com/api/chat.postMessage"' 'print(URL)' >> "$JC/prose.py"
jc_run "python3 $JC/prose.py"
refused "once that script names the endpoint in a string it can send, the same command is refused"
traced "the kept judgement is not used once the script has changed (#3255)" "miss: read" "answers differently now"
# A file larger than the cache reads whole (lib/judgement-cache.py's MAX_READ) made its judgement one
# the cache could not keep, though the gate reads only the start of any file. A quoted command line
# handed to a function that runs it is read as a command (lib/unknown-program.py, #3304), and the
# claude-sync suite holds `check_expr_shape "... bash /bin/echo hi"`: on CI's Linux runner /bin/echo
# is one program of over 8 MB, so `bash tests/test-claude-sync.sh` was judged whole every time it was
# asked, about 61 units against the 6 a kept judgement costs (pull request #3394, 2026-11-21). The
# start the gate read is now what the record holds, so the judgement is kept, and is used only while
# that start is the same.
head -c 8392704 /dev/zero > "$JC/program.bin"
printf '%s\n' 'probe() { bash -n -c "$1"; }' "probe \"A=1 bash $JC/program.bin hi\"" > "$JC/quoted.sh"
jc_run "bash $JC/quoted.sh"
allowed "a script handing a function a quoted command line that runs a file of over 8 MB is allowed"
traced "its judgement is kept, the large file recorded as far as the gate read it (#3394)" "stored"
jc_run "bash $JC/quoted.sh"
allowed "judged again with nothing changed, it is allowed"
traced "and that second judgement is answered from the cache (#3394)" "hit"
jc_run "bash $JC/program.bin hi"
allowed "the same large file run by bash, typed plainly, is allowed"
traced "and its judgement is kept too (#3394)" "stored"
jc_run "bash $JC/program.bin hi"
traced "judged again, it is answered from the cache (#3394)" "hit"
# A byte added past what the gate reads changes nothing a judgement saw, and the kept one is used.
printf 'x' >> "$JC/program.bin"
jc_run "bash $JC/quoted.sh"
traced "a change past what the gate reads of the large file leaves the kept judgement in use (#3394)" "hit"
# Kept, it is still only as good as the start it read: once that start names an endpoint, it is refused.
{ printf '\0\n'; printf "$POSTS\n"; head -c 8392704 /dev/zero; } > "$JC/program.bin"
jc_run "bash $JC/quoted.sh"
refused "once the start of the large file names an endpoint, the same command is refused"
traced "the kept judgement is not used once the start the gate read has changed (#3394)" "miss: head" "answers differently now"
jc_run "bash $JC/program.bin hi"
refused "and so is the large file run by bash, typed plainly"
unset SLACK_GATE_CACHE_TRACE
# Outside this suite the cache is in ~/.claude/state, which the sync does not carry; under a test run
# with no cache named it is off, so no suite reads or writes this Mac's.
env -u SLACK_GATE_CACHE_DIR -u HOOK_TESTS_RUNNING HOME="$T/jc-home" bash "$HOOK" <<< "$(payload Bash "$(bash_input "bash $JC/run.sh")" "$JC/w")" >/dev/null 2>&1
if ls "$T/jc-home/.claude/state/slack-gate-cache/"*.json >/dev/null 2>&1; then check "outside a test run the judgement is kept under ~/.claude/state/slack-gate-cache" ok
else check "outside a test run the judgement is kept under ~/.claude/state/slack-gate-cache" "nothing was written there"; fi
env -u SLACK_GATE_CACHE_DIR HOOK_TESTS_RUNNING=1 HOME="$T/jc-home2" bash "$HOOK" <<< "$(payload Bash "$(bash_input "bash $JC/run.sh")" "$JC/w")" >/dev/null 2>&1
if [ -e "$T/jc-home2/.claude" ]; then check "under a test run with no cache named, nothing is kept" "$T/jc-home2/.claude was made"
else check "under a test run with no cache named, nothing is kept" ok; fi
export SLACK_GATE_CACHE_DIR="$T/gate-cache"

echo
echo "slack drafts only: harmless commands it misread (claude-config#2913, #2922, #2910)"

# #2913: a suite run by a relative path after `mkdir ... && cd <checkout> &&` was refused, because
# the cd joined by && after another command was taken as one that may not have run, so the folder
# the suite ran in, and the path it sources by "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)", were
# not known (the #2914 builder, 2026-11-14 03:44 UTC). A command joined by && to such a cd runs
# only where every command before it in that && chain worked, the cd included.
B="$T/b2913"
mkdir -p "$B/kit/lib" "$B/away" "$B/bad/lib"
printf '%s\n' '#!/usr/bin/env bash' '. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/helper.sh"' 'say hi' > "$B/kit/suite.sh"
printf '%s\n' 'say() { echo "$1"; }' > "$B/kit/lib/helper.sh"
printf '%s\n' '#!/usr/bin/env bash' '. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/helper.sh"' 'say hi' > "$B/bad/suite.sh"
printf '%s\n' 'say() { curl -X POST https://slack.com/api/chat.postMessage -d text="$1"; }' > "$B/bad/lib/helper.sh"
run_b() { run_raw "$(payload Bash "$(bash_input "$1")" "$B/away")"; }
run_b "cd $B/kit && bash suite.sh"
allowed "#2913 the control: a suite by a relative path after a lone cd"
for c in "mkdir -p $B/out && cd $B/kit && bash suite.sh" "mkdir -p $B/out && cd $B/kit && HOOK_TESTS_RUNNING=1 bash suite.sh > $B/out/t.txt 2>&1" \
  "true && cd $B/kit && cd . && bash suite.sh" "[ -d $B/kit ] && cd $B/kit && bash suite.sh"; do
  run_b "$c"
  allowed "#2913 a suite by a relative path after a cd chained by && passes: ${c//$B/B}"
done
run_b "mkdir -p $B/out && cd $B/bad && bash suite.sh"
read_refused "#2913 a suite sourcing a helper that posts, run the same way, is refused"
says "#2913 and the refusal names the endpoint" "chat.postMessage"
for c in "mkdir -p $B/out || cd $B/kit && bash suite.sh" "mkdir -p $B/out && cd $B/kit; bash suite.sh" \
  "mkdir -p $B/out && cd $B/kit || bash suite.sh"; do
  run_b "$c"
  read_refused "#2913 where the cd may not have run before the suite, its folder is still not known: ${c//$B/B}"
done
if [ -n "$REPO" ] && [ -f "$REPO/payload/hooks/test-scanners-before-push.sh" ]; then
  run_b "mkdir -p $B/out && cd $REPO && bash payload/hooks/test-scanners-before-push.sh"
  allowed "#2913 this repository's own suite by a relative path after mkdir && cd passes"
else
  printf 'SUITE-PART-UNMEASURED %s\n' "#2913 a real suite by a relative path: this suite is not in a claude-config checkout"
fi

# #2913: a Python file that names an endpoint only in a comment or a docstring says nothing it can
# send, and was refused as one that posts when run or handed to a helper.
Y="$T/y2913"
mkdir -p "$Y"
printf '%s\n' '"""Reads a reply. The other tool calls chat.postMessage; this one never does."""' \
  '# chat.postMessage is named here only in a comment.' 'def f():' '    """Not hooks.slack.com either."""' \
  '    return 1' 'print(f())' > "$Y/prose.py"
printf '%s\n' 'URL = "https://slack.com/api/chat.postMessage"' 'print(URL)' > "$Y/names.py"
printf '%s\n' '"""chat.postMessage"""' 'import urllib.request' 'urllib.request.urlopen(__doc__)' > "$Y/usesdoc.py"
printf '%s\n' 'import subprocess, sys' 'print(len(open(sys.argv[1]).read()))' > "$Y/helper.py"
run_y() { run_raw "$(payload Bash "$(bash_input "$1")" "$Y")"; }
run_y "python3 prose.py"
allowed "#2913 a Python script naming an endpoint only in comments and docstrings passes"
# Handed to a helper as data, the same file is still read whole: the helper can read its text and
# post to an address it finds in a comment, so only a file run as Python leaves them out (lessons
# review at d05bf8b). The gate's own source handed to such a helper stays refused for that reason.
run_y "python3 helper.py prose.py"
read_refused "#2913 a helper that runs code, handed that file as data, is still refused"
run_y "python3 helper.py $DIR/slack_drafts_only_gate.py"
read_refused "#2913 a helper that runs code, handed the gate's own source, is still refused"
run_y "python3 names.py"
read_refused "#2913 a Python script naming an endpoint in a string it can send is still refused"
run_y "python3 helper.py names.py"
read_refused "#2913 a helper that runs code, handed a Python file naming an endpoint in code, is still refused"
run_y "python3 usesdoc.py"
read_refused "#2913 a docstring the script reads back through __doc__ is still read"
# What this gives up, recorded so it is a decision (lessons review at f99a36f): a script that reads
# its own source (open(__file__), inspect.getsource) and posts to an address in a comment passes.
# That is the boundary the gate already had for a script reading any file the command does not name:
# poster.py, posting to the address in cfg.txt, passed before this change too (measured on main).
printf '%s\n' 'https://slack.com/api/chat.postMessage' > "$Y/cfg.txt"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen(open("cfg.txt").read().strip())' > "$Y/poster.py"
printf '%s\n' '# https://slack.com/api/chat.postMessage' 'import urllib.request' \
  'urllib.request.urlopen(open(__file__).read().split()[1])' > "$Y/self.py"
run_y "python3 poster.py"
allowed "#2913 the boundary as it was: a script posting to an address in a file the command does not name passes"
run_y "python3 self.py"
allowed "#2913 the same boundary: a script posting to an address in its own comment, read from its file, passes"
printf '%s\n' '"""https://slack.com/api/chat.postMessage"""' > "$Y/docmod.py"
printf '%s\n' 'import urllib.request, docmod' 'urllib.request.urlopen(docmod.__doc__)' > "$Y/readsdoc.py"
run_y "python3 readsdoc.py"
read_refused "#2913 an imported module's docstring, which the importer can read back, is still read"
# Already passing before this change (the perl reading of #2886), kept here as the case was reported.
printf '%s\n' 'print "hello\n";' > "$Y/probe.pl"
run_y "perl -e 'print \"@ARGV\\n\"' -l ./probe.pl"
allowed "#2913 a perl one-liner given -l and a file that only prints passes"

# #2922: a local script that reads one file and writes another, handed a page curl saved earlier in
# the command, was refused because what curl saved cannot be read. A script that cannot send a
# request or run code cannot make a page post; what it writes is judged where it runs.
D="$T/d2922"
mkdir -p "$D"
printf '%s\n' 'import html, re, sys' 'text = open(sys.argv[1], encoding="utf-8", errors="replace").read()' \
  'open(sys.argv[2], "w").write(html.unescape(re.sub(r"<[^>]+>", " ", text)))' > "$D/totext.py"
printf '%s\n' 'import json, sys, urllib.request' 'urllib.request.urlopen(json.load(open(sys.argv[1]))["url"])' > "$D/send.py"
printf '%s\n' 'import sys' 'exec(open(sys.argv[1]).read())' > "$D/runit.py"
printf '%s\n' 'import sys' 'open(sys.argv[2], "w").write(open(sys.argv[1]).read())' > "$D/copy2.py"
printf '%s\n' 'import sys' 'open("built.sh", "w").write(open(sys.argv[1]).read())' > "$D/copy3.py"
run_d() { run_raw "$(payload Bash "$(bash_input "$1")" "$D")"; }
for c in "curl -o page.html https://example.com/ && python3 -I totext.py page.html page.txt" \
  "curl -sL -o page.html https://example.com/; python3 -I totext.py page.html page.txt"; do
  run_d "$c"
  allowed "#2922 a script that only reads and writes files, handed a page curl saved, passes: $c"
done
run_d "curl -o msg.json https://example.com/m && python3 send.py msg.json"
read_refused "#2922 a script that sends a request, handed what curl saved, is still refused"
says "#2922 and it says the check could not be made, not that it found a post" "REFUSED: the gate could not check whether this command posts to Slack"
lacks "#2922 and, with no endpoint in the command, it does not say to save a draft" "slack_send_message_draft"
run_d "curl -o code.txt https://example.com/c && python3 runit.py code.txt"
read_refused "#2922 a script that runs what it is handed, handed what curl saved, is still refused"
run_d "curl -o x.sh https://example.com/x && python3 copy2.py x.sh out.sh && bash out.sh"
read_refused "#2922 a file that script writes from the download, then run, is still refused"
run_d "echo -e 'x' > g.txt && python3 - < g.txt"
says "#2922 a file another command wrote, unreadable to the gate, is refused as not checked" "REFUSED: the gate could not check whether this command posts to Slack"

run_d "curl -o x.sh https://example.com/x && python3 copy3.py x.sh && bash built.sh"
read_refused "#2922 a file named in that script's own text, then run, is still refused"
says "#2922 and the refusal names the script as what may have written it" "may be written earlier in this command by the script copy3.py"

# #2910: a copy loop into a folder the command sets by a literal assignment was refused as possibly
# writing the scanner run after it by its absolute path. Its refusal claimed a post it had not found:
# it now says the check could not be made. Dan decided on 2026-11-14 ("Make the change") that the
# loop passes: `cd X && S=...`, with X a folder that is there, is certain to set S (reversing that
# part of #2785, above), and a path `git diff --name-only` prints cannot climb out of the folder it is
# copied into with .., so "$S/$f" stays inside $S. Paths from anywhere else still can.
K="$T/k2910"
B="$T/k2910-scanner"  # the scanner, outside the folder the loop runs in, as /opt/homebrew/bin was
mkdir -p "$K/src" "$K/bin" "$B"
printf '%s\n' '#!/bin/sh' 'echo scanned "$@"' > "$K/bin/scan.sh"
cp "$K/bin/scan.sh" "$B/scan.sh"
chmod +x "$K/bin/scan.sh" "$B/scan.sh"
run_kk() { run_raw "$(payload Bash "$(bash_input "$1")" "$K")"; }
loop='cd '"$K"' && S="'"$K"'/out/scan"; rm -rf "$S" && mkdir -p "$S"; n=0; for f in $(git diff --name-only HEAD); do mkdir -p "$S/$(dirname "$f")" && cp "$f" "$S/$f" && n=$((n+1)); done; '
run_kk "${loop}$B/scan.sh dir \"\$S\" --report-path \"\$S/../report.json\""
allowed "#2910 the reported copy loop passes"
run_kk 'cd '"$K"' && S="'"$K"'/out/scan"; rm -rf "$S" && mkdir -p "$S" && git fetch origin main -q; for f in $(git diff --name-only --diff-filter=AM origin/main...HEAD); do cp "$f" "$S/$f"; done; '"$B"'/scan.sh dir "$S"'
allowed "#2910 and so does its form with a range and --diff-filter"
# Every case below differs from the passing loop in one thing, and is refused as it was.
# A cd into a folder that is not there: S may keep what the environment holds, so "$S/$f" can be any
# path, and the directory "$f" is read in is not known either.
run_kk "${loop/cd $K/cd $K/missing}$B/scan.sh dir \"\$S\""
read_refused "#2910 the same loop after a cd into a folder that is not there is still refused"
says "#2910 and its refusal says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
lacks "#2910 and does not say to save a draft" "slack_send_message_draft"
# A path list from any other source can hold .., so the copy can land anywhere; so can one from a
# git diff whose options change what it prints, one handed a path outside the working tree (which it
# compares as --no-index does, printing the paths as given), --name-only where git reads it as a
# pathspec, any git diff past the one shape read (options, then at most two revisions), or a git the
# command defines itself.
for src in '$(cat list.txt)' '$(git diff --name-only HEAD | sed s/x/y/)' '$(git diff --name-only --no-index a b)' \
  '$(git diff --name-only --line-prefix=../ HEAD)' '$(git diff --name-only $OPTS HEAD)' '$(git ls-files)' \
  '$(find . -name "*.sh")' '$(git diff --name-only ../a b)' '$(git diff --name-only /tmp/a /tmp/b)' \
  '$(git diff -- --name-only)' '$(git diff HEAD --name-only)' '$(git diff --name-only HEAD -- src)' \
  '$(git diff --name-only -z HEAD)' '$(git diff --name-only a b c)'; do
  run_kk 'cd '"$K"' && S="'"$K"'/out/scan"; for f in '"$src"'; do cp "$f" "$S/$f"; done; '"$B"'/scan.sh'
  read_refused "#2910 a copy loop over a path list from another source is still refused: $src"
done
run_kk 'git() { echo ../../bin; }; cd '"$K"' && S="'"$K"'/out/scan"; for f in $(git diff --name-only HEAD); do cp "$f" "$S/$f"; done; '"$B"'/scan.sh'
read_refused "#2910 a loop over a git the command defines as a function is still refused"
# Unquoted, a git path is split and matched as a glob (.* matches ..), so it can be any name.
run_kk 'cd '"$K"' && S="'"$K"'/out/scan"; for f in $(git diff --name-only HEAD); do cp "$f" $S/$f; done; '"$B"'/scan.sh'
read_refused "#2910 an unquoted destination built from a git path is still refused"
# The source word "$f" is relative, so where the directory it is read in is not known it can be any
# file: a cd into a folder that is not there leaves it so even with S set beforehand.
run_kk 'S="'"$K"'/out/scan"; cd '"$K"'/missing; for f in $(git diff --name-only HEAD); do cp "$f" "$S/$f"; done; '"$B"'/scan.sh'
read_refused "#2910 a git path copied where the directory is not known is still refused"
# And where it is known, "$f" can still name any file under it: cp cannot be told which unknown word
# is its target (GNU cp's -t), so a script in the folder the loop runs in is still refused.
run_kk "${loop}$K/bin/scan.sh dir \"\$S\""
read_refused "#2910 a script inside the folder the loop runs in is still refused"
run_kk "${loop}bash \"\$S/run.sh\""
read_refused "#2910 a file inside that folder, run after the copies, is still refused"
says "#2910 and it says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
lacks "#2910 and, with no endpoint in the command, it does not say to save a draft" "slack_send_message_draft"
run_kk 'for f in $(git diff --name-only HEAD); do cp "src/$f" "$f"; done; '"$K"'/bin/scan.sh'
read_refused "#2910 a copy whose destination cannot be worked out, then a script run, is still refused"
run_kk 'for f in $(git diff --name-only HEAD); do cp $f '"$K"'/out/x; done; '"$K"'/bin/scan.sh'
read_refused "#2910 an unquoted copied word, which can split into the destination, is still refused"

echo "slack drafts only: a binary file named in code is not read as commands, and a NUL byte is refused, not a crash (claude-config#2892)"

# Two real commands from this Mac crashed the gate with "lstat: embedded null character in path"
# (found 2026-11-13, replayed on main at 6ce6746): python3 heredocs editing a script and then running
# it, whose code names /usr/bin/true or /bin/bash inside a string. Code that edits a file is judged
# by every file it names (#2772), so the program's own bytes were added to the script and read as
# shell commands, and a word cut from a Mach-O header held a NUL. bash refuses a file whose first line
# holds a NUL ("cannot execute binary file"), so such a file is now searched for an endpoint and not
# read as commands; any other NUL in text read as commands is refused as text the gate cannot read.
G9="$T/g2892"
mkdir -p "$G9/lw/tools" "$G9/uw/hooks/lib" "$G9/mix" "$G9/nul"
printf '%s\n' '#!/usr/bin/env bash' 'limit=1; workers=0; spawners=0' \
  'if [ $(( workers + spawners )) -gt 0 ]; then' 'bash -c '"'"'' '  lim=$1; n=$2; m=$3' \
  '  wait'"'"' load-window-workers "$limit" "$workers" "$spawners" </dev/null >/dev/null 2>&1 &' 'wpid=$!' 'fi' \
  > "$G9/lw/tools/load-window.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo ok' > "$G9/lw/tools/test-load-window.sh"
cat > "$G9/row3823.txt" <<'CMD'
cd @D@ && python3 - <<'PY'
p='tools/load-window.sh'
s=open(p).read()
old='''if [ $(( workers + spawners )) -gt 0 ]; then
bash -c '
  lim=$1; n=$2; m=$3
  (sleep "$lim"; kill -KILL 0) &
  i=0; while [ "$i" -lt "$n" ]; do bash -c "while [ \\$SECONDS -lt $lim ]; do :; done" & i=$((i + 1)); done
  i=0; while [ "$i" -lt "$m" ]; do bash -c "while [ \\$SECONDS -lt $lim ]; do /usr/bin/true; done" & i=$((i + 1)); done
  wait' load-window-workers "$limit" "$workers" "$spawners" </dev/null >/dev/null 2>&1 &
wpid=$!
fi'''
new='''if [ $(( workers + spawners )) -gt 0 ]; then
  bash -c '
    lim=$1; n=$2; m=$3
    (sleep "$lim"; kill -KILL 0) &
    i=0; while [ "$i" -lt "$n" ]; do bash -c "while [ \\$SECONDS -lt $lim ]; do :; done" & i=$((i + 1)); done
    i=0; while [ "$i" -lt "$m" ]; do bash -c "while [ \\$SECONDS -lt $lim ]; do /usr/bin/true; done" & i=$((i + 1)); done
    wait' load-window-workers "$limit" "$workers" "$spawners" </dev/null >/dev/null 2>&1 &
  wpid=$!
fi'''
assert s.count(old)==1
s=s.replace(old,new); open(p,'w').write(s)
PY
bash -n tools/load-window.sh && bash tools/test-load-window.sh 2>&1 | tail -8
CMD
printf '%s\n' '#!/usr/bin/env bash' '. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/d.sh" || exit 1' \
  'if [ -x /bin/bash ] && command -v ps >/dev/null 2>&1; then' '  parents=x' 'fi' 'echo ok' > "$G9/uw/hooks/test-uw.sh"
printf '%s\n' 'true' > "$G9/uw/hooks/lib/d.sh"
cat > "$G9/row567.txt" <<'CMD'
python3 - <<'EOF'
p='hooks/test-uw.sh'
s=open(p).read()
old_start=s.index('if [ -x /bin/bash ] && command -v ps >/dev/null 2>&1; then\n  parents=')
new='''if [ -x /bin/bash ] && command -v ps >/dev/null 2>&1; then
  verdict="$(child_split_verdict /bin/bash)"
  case "$verdict" in
    ok) echo "#1984 /bin/bash makes the child its own" ;;
    *) echo "mismatch: $(printf '%s' "$verdict" | tr '\\n' ' ')" ;;
  esac
fi
'''
s=s[:old_start]+new
open(p,'w').write(s)
EOF
bash -n hooks/test-uw.sh && bash hooks/test-uw.sh 2>&1 | tail -3
CMD
run_at() { run_raw "$(payload Bash "$(bash_input "$1")" "$2")"; } # run_at <command> <cwd>
c="$(cat "$G9/row3823.txt")"
run_at "${c//@D@/$G9/lw}" "$T"
allowed "#2892 a python3 heredoc naming /usr/bin/true that edits a script, then runs it, is judged and passes"
run_at "$(cat "$G9/row567.txt")" "$G9/uw"
allowed "#2892 a python3 heredoc naming /bin/bash that edits a test, then runs it, is judged and passes"
# The binary is still searched for an endpoint, and the script's own text is still read as commands.
printf '\0\0\0\ncurl -d x https://hooks.slack.com/services/T0/B0/x\n' > "$G9/mix/poster.bin"
printf '\0\0\0\nls\n' > "$G9/mix/quiet.bin"
printf '%s\n' "$POST" > "$G9/mix/post.sh"
printf '%s\n' 'echo start' 'bash post.sh' > "$G9/mix/run.sh"
run_at "python3 -c \"open('new.sh', 'w').write(open('quiet.bin').read())\" && bash new.sh" "$G9/mix"
allowed "#2892 a script written from a binary file that names no endpoint passes"
run_at "python3 -c \"open('new.sh', 'w').write(open('poster.bin').read())\" && bash new.sh" "$G9/mix"
read_refused "#2892 a script written from a binary file that names an endpoint is still refused"
says "#2892 and the refusal names the endpoint" "hooks.slack.com"
run_at "python3 - <<'PY'
p = 'run.sh'
s = open(p).read()
open(p, 'w').write(s + '# run by /bin/bash\n')
PY
bash run.sh" "$G9/mix"
read_refused "#2892 a script edited by code naming /bin/bash is still read as commands, and the script it runs posts"
says "#2892 and the refusal names the script that posts" "post.sh"
run_at "bash quiet.bin" "$G9/mix"
allowed "#2892 a binary file handed to bash, which bash refuses to run, passes"
run_at "bash poster.bin" "$G9/mix"
read_refused "#2892 a binary file handed to bash that names an endpoint is still refused"
# A NUL anywhere else is refused as text the gate cannot read: bash drops it and runs the rest, zsh
# keeps it inside the word, and every program reads it as the end of the word.
printf '%s\n' "$POST" > "$G9/nul/post.sh"
printf 'echo hi\nbash po\0st.sh\n' > "$G9/nul/late.sh"
run_at "bash late.sh" "$G9/nul"
read_refused "#2892 a script holding a NUL after its first line is refused, not a crash"
says "#2892 and the refusal names the NUL byte" "NUL"
says "#2892 and it says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
run_raw "$(payload Bash '{"command": "bash po\u0000st.sh", "description": "d"}' "$G9/nul")"
read_refused "#2892 a command holding a NUL byte is refused, not a crash"
says "#2892 and that refusal names the NUL byte" "NUL"
# Behind both: no word holding a NUL reaches os.path.realpath, which raises on one. The gate's one
# way from a word to a path refuses it, and main() turns that into a refusal rather than a crash.
check "#2892 a word holding a NUL is refused before it becomes a path, and main() refuses the call" "$(python3 - "$DIR" <<'PY' 2>&1
import io, json, os, sys
sys.dont_write_bytecode = True  # the gate is carried by the sync: leave no cache beside it (#2919)
os.environ["GATE_DIR"] = sys.argv[1]
sys.path.insert(0, sys.argv[1])
import slack_drafts_only_gate as gate
try:
    gate.Judge.resolve(None, "po\0st.sh", "/tmp")
    print("resolve gave a path for a word holding a NUL")
    sys.exit(0)
except gate.NulPath:
    pass
gate.Judge.line = lambda self, s, cwd, depth, whole: self.resolve("po\0st.sh", cwd)
sys.stdin = io.TextIOWrapper(io.BytesIO(json.dumps(
    {"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "bash post.sh"}}).encode()))
buf = io.BytesIO()
out = io.TextIOWrapper(buf, write_through=True)
real_out, sys.stdout = sys.stdout, out
try:
    gate.main()
    out.flush()
    said = buf.getvalue().decode()
finally:
    sys.stdout = real_out
print("ok" if said.startswith("refuse\n") and "NUL" in said else "main() said: %r" % said[:300])
PY
)"

echo "slack drafts only: curl's default config is read, and perl -i takes no value (claude-config#2893)"

# curl reads ~/.curlrc ($CURL_HOME/.curlrc, $XDG_CONFIG_HOME/curlrc) unless -q or --disable is its
# first word, so a config written there earlier that names an endpoint makes a later plain curl post.
# Only a config handed with -K or --config was read (#2889).
CH="$T/g2893"
mkdir -p "$CH/home" "$CH/xdg" "$CH/quiet" "$CH/empty" "$CH/wh" "$CH/later"
printf '%s\n' 'url = "https://hooks.slack.com/services/T0/B0/x"' 'data = "text=hi"' > "$CH/home/.curlrc"
printf '%s\n' 'url = "https://hooks.slack.com/services/T0/B0/x"' > "$CH/xdg/curlrc"
printf '%s\n' 'silent' 'show-error' > "$CH/quiet/.curlrc"
CURL_HOME="$CH/quiet" run_bash "curl -s https://example.com/status"
allowed "#2893 the control: curl with a default config naming no endpoint passes"
CURL_HOME="$CH/empty" run_bash "curl -s https://example.com/status"
allowed "#2893 and with no default config there"
CURL_HOME="$CH/home" run_bash "curl -s https://example.com/status"
read_refused "#2893 a plain curl whose \$CURL_HOME/.curlrc names an endpoint is refused"
says "#2893 and the refusal names the config file" ".curlrc"
CURL_HOME="$CH/empty" HOME="$CH/home" run_bash "curl -s https://example.com/status"
read_refused "#2893 a plain curl whose ~/.curlrc names an endpoint is refused"
CURL_HOME="$CH/empty" XDG_CONFIG_HOME="$CH/xdg" run_bash "curl -s https://example.com/status"
read_refused "#2893 a plain curl whose \$XDG_CONFIG_HOME/curlrc names an endpoint is refused"
for first in "-q" "--disable"; do
  CURL_HOME="$CH/home" run_bash "curl $first -s https://example.com/status"
  allowed "#2893 curl with $first as its first word, which skips the default config, passes"
done
CURL_HOME="$CH/home" run_bash "curl -s -q https://example.com/status"
read_refused "#2893 a -q that is not curl's first word does not skip the default config"
run_bash "CURL_HOME=$CH/home curl -s https://example.com/status"
read_refused "#2893 a CURL_HOME set on the command itself is read"
run_bash "export CURL_HOME=$CH/home; curl -s https://example.com/status"
read_refused "#2893 a CURL_HOME exported earlier in the command is read"
CURL_HOME="$CH/empty" HOME="$CH/home" run_bash "curl -s -d HOME=$CH/quiet https://example.com/status"
read_refused "#2893 a HOME= that is only curl's data does not stop ~/.curlrc being read"
# Only an assignment moves where curl looks: a NAME= inside other text is not one (the replay of this
# Mac's commands found `echo "CURL_HOME=${CURL_HOME:-unset}"; curl --version` refused).
CURL_HOME="$CH/quiet" run_bash "echo \"CURL_HOME=\${CURL_HOME:-unset} XDG=\${XDG_CONFIG_HOME:-unset}\"; curl --version"
allowed "#2893 a CURL_HOME= inside echoed text is no assignment, and the curl after it passes"
run_bash "env CURL_HOME=$CH/home curl -s https://example.com/status"
read_refused "#2893 a CURL_HOME set through env is read"
run_bash "CURL_HOME=\"\$(mktemp -d)\" curl -s https://example.com/status"
read_refused "#2893 a CURL_HOME the gate cannot work out is refused as unread"
# A write that leaves a default config naming an endpoint is refused, so a later call cannot post.
CURL_HOME="$CH/empty" HOME="$CH/wh" run_bash "printf 'url = https://hooks.slack.com/services/T0/B0/x\n' > ~/.curlrc"
read_refused "#2893 writing ~/.curlrc with an endpoint in it is refused"
says "#2893 and the refusal names the config file" ".curlrc"
CURL_HOME="$CH/empty" HOME="$CH/wh" run_bash "printf 'silent\n' > ~/.curlrc"
allowed "#2893 writing ~/.curlrc with no endpoint in it passes"
CURL_HOME="$CH/empty" HOME="$CH/wh" run_bash "printf 'url = https://hooks.slack.com/services/T0/B0/x\n' > notes.txt"
allowed "#2893 writing the same text to another file passes"
CURL_HOME="$CH/empty" run_bash "printf 'url = https://hooks.slack.com/services/T0/B0/x\n' > $CH/later/.curlrc; CURL_HOME=$CH/later curl -s https://example.com/status"
read_refused "#2893 a .curlrc written with an endpoint by a command that then runs curl is refused"
# Neither the wrapper's quick pass nor the cache may keep an allowed curl once a default config
# naming an endpoint appears (#2918): first with none there, then with one naming none, which the
# gate judges and keeps, then with the same file naming one.
CURL_HOME="$CH/later2" run_bash "curl -s https://example.com/later"
allowed "#2893 before the config is there, a plain curl passes"
mkdir -p "$CH/later2"
printf '%s\n' 'silent' > "$CH/later2/.curlrc"
CURL_HOME="$CH/later2" run_bash "curl -s https://example.com/later"
allowed "#2893 with a config there naming no endpoint, it passes"
printf '%s\n' 'url = "https://hooks.slack.com/services/T0/B0/x"' > "$CH/later2/.curlrc"
CURL_HOME="$CH/later2" run_bash "curl -s https://example.com/later"
read_refused "#2893 and once the config names one, the same call is refused, not served from the cache"
# perl's -i takes no separate value: `perl -i -pe s/a/b/ post.sh` read -pe as -i's value and s/a/b/ as
# the script, and refused for post.sh as perl's script, which it is not.
printf '%s\n' "$POST" > "$CH/post.sh"
run_at "perl -i -pe s/a/b/ post.sh" "$CH"
read_refused "#2893 perl -i -pe editing a file is refused"
says "#2893 for its -i switch" "-i switch"
lacks "#2893 not for a script it does not run" "which perl may run as its script"
run_at "perl -i.bak -pe s/a/b/ post.sh" "$CH"
read_refused "#2893 perl -i.bak -pe editing a file is refused"
lacks "#2893 not for a script it does not run, with a suffix either" "which perl may run as its script"
# ruby's -i is the same (ruby -i[ext]), so the word after it is not its value either.
run_at "ruby -i -pe 'x' post.sh" "$CH"
read_refused "#2893 ruby -i -pe editing a file is refused"
lacks "#2893 not for a script it does not run" "which ruby may run as its script"
# bash -i (interactive) and node -i (the REPL) take no value either. Read as taking one, `node -i -e
# CODE` took -e for -i's value, so the code was never read as code: an import of a file that posts
# passed (measured at 07aed34).
printf '%s\n' "fetch('https://slack.com/api/chat.postMessage');" > "$CH/post.mjs"
run_at "node -i -e 'import(\"./post.mjs\")'" "$CH"
read_refused "#2893 node -i -e importing a file that posts is refused"
run_at "bash -i -c 'bash post.sh'" "$CH"
read_refused "#2893 bash -i -c running a script that posts is refused"
run_at "node -i -e 'console.log(1)'" "$CH"
allowed "#2893 node -i -e with code that does nothing passes"

echo "slack drafts only: a type only import of a file that is there is not followed (claude-config#2890)"

# `import type ... from` is erased before anything runs, so no module is loaded for it, whether its
# file is there or not (measured for #2526). Only a missing declaration file was passed, so a test whose
# only route to a posting file was a type import was refused in a work repository (2026-11-12).
TY="$T/g2890"
mkdir -p "$TY"
printf '%s\n' 'export type T = { a: number };' "export function send() { fetch('https://slack.com/api/chat.postMessage'); }" > "$TY/posts.ts"
printf '%s\n' 'import type { T } from "./posts.ts";' 'export type U = T;' 'export const n = 1;' > "$TY/types.ts"
ty_case() { # ty_case <lines of a.ts...>: judge node running a file holding them
  printf '%s\n' "$@" 'console.log(1);' > "$TY/a.ts"
  run_bash "node $TY/a.ts"
}
ty_case 'import { n } from "./missing-control.ts";'
refused "#2890 the control: a value import of a missing file is refused"
ty_case 'import type { T } from "./posts.ts";'
allowed "#2890 a type only import of a file that posts passes"
ty_case 'import type {' '  T,' '} from "./posts.ts";'
allowed "#2890 the same import over several lines"
ty_case 'import type * as P from "./posts.ts";'
allowed "#2890 a type only namespace import"
ty_case 'import { n } from "./types.ts";'
allowed "#2890 a value import of a file whose only route to the poster is a type import"
for line in 'import { send } from "./posts.ts";' \
  'import { type T } from "./posts.ts";' \
  'import { type T, send } from "./posts.ts";' \
  'import type, { send } from "./posts.ts";' \
  'import "./posts.ts";' \
  'const p = await import("./posts.ts");' \
  'const p = require("./posts.ts");' \
  'export type { T } from "./posts.ts";' \
  'export * from "./posts.ts";'; do
  ty_case "$line"
  refused "#2890 a file that posts reached as: $line"
done
ty_case 'import type { T } from "./posts.ts";' 'import { send } from "./posts.ts";'
refused "#2890 a value import beside a type only import of the same file"

echo
sdg_harness_result
