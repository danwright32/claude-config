#!/usr/bin/env bash
# Tests for refresh-claude-code-types.sh, which pins a Claude Code build's types for the mods type
# check (#953). check-mods.sh tells a Mac running another build to run it, so it is run here rather
# than trusted (L406): what it pins, what it leaves out, and that it refuses rather than pinning
# something the push gate or the type check would then trip on.
set -u

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/refresh-claude-code-types.sh"
SCAN="$DIR/../payload/hooks/lib/style-scan.py"

pass=0
fail=0
check() { # check <description> <result>
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
T="$(mktemp -d "${TMPDIR:-/tmp}/test-refresh-cc-types.XXXXXX")"
trap 'rm -rf "$T"' EXIT
EM="$(printf '\342\200\224')"   # an em dash, written as its bytes so this file holds none

# A types folder as Claude Code lays one for a loaded mod, describing build $2.
lay(){
  mkdir -p "$1/claude-code" "$1/claude-code-tools" "$1/claude-code-mcp"
  printf '// Written by Claude Code %s.\n/**\n * The engine %s documented, for now.\n */\n// a line comment\ndeclare module "claude-code" { export type Kept = 1 } // beside code\n' "$2" "$EM" > "$1/claude-code/index.d.ts"
  printf '// The inputs of the built-in tools %s this build has.\ndeclare module "claude-code" {\n  interface BuiltinToolInputs {\n    Bash: {\n      /** The command %s to run */\n      command: string\n    }\n  }\n}\n' "$EM" "$EM" > "$1/claude-code-tools/index.d.ts"
  printf 'declare module "claude-code" { interface McpToolInputs { mcp__session__only: {} } }\n' > "$1/claude-code-mcp/index.d.ts"
  printf '{ "compilerOptions": { "strict": true, "types": ["claude-code", "claude-code-tools", "claude-code-mcp", "mod-kit"] }, "include": ["../../hooks"] }\n' > "$1/tsconfig.json"
}
TS="$T/ts"; P="$TS/claude-code-types"
mkdir -p "$P/claude-code-mcp"; printf 'export {}\n' > "$P/claude-code-mcp/index.d.ts"
run(){ out="$(CHECK_MODS_TS_DIR="$TS" bash "$TOOL" "$@" 2>&1)"; code=$?; }

# 1. A laid folder is pinned: both declaration files and the tsconfig, its build named.
lay "$T/src" 2.1.400
run "$T/src"
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q "pinned Claude Code 2.1.400's types" \
  && check "a laid folder is pinned, naming its build" ok || check "a laid folder is pinned, naming its build" "exit=$code out=$out"
head -n 1 "$P/claude-code/index.d.ts" | grep -qxF '// Written by Claude Code 2.1.400.' \
  && check "the engine's types keep the first line naming their build" ok || check "the engine's types keep the first line naming their build" "$(head -n 1 "$P/claude-code/index.d.ts")"
grep -q 'export type Kept = 1' "$P/claude-code/index.d.ts" && grep -q 'command: string' "$P/claude-code-tools/index.d.ts" \
  && check "every type is kept" ok || check "every type is kept" "$(cat "$P/claude-code/index.d.ts" "$P/claude-code-tools/index.d.ts")"
# Every line that is wholly a comment is left out, block, one line and // alike, dash or not (the
# deferral gate refuses some of their phrases too), and a comment beside code stays.
! grep -q "$EM" "$P/claude-code/index.d.ts" "$P/claude-code-tools/index.d.ts" && ! grep -q 'for now\|a line comment' "$P/claude-code/index.d.ts" \
  && grep -q 'Kept = 1 } // beside code' "$P/claude-code/index.d.ts" \
  && [ "$(wc -l < "$P/claude-code/index.d.ts" | tr -d ' ')" = 2 ] && [ "$(wc -l < "$P/claude-code-tools/index.d.ts" | tr -d ' ')" = 7 ] \
  && check "every line that is wholly a comment is left out, and nothing else" ok \
  || check "every line that is wholly a comment is left out, and nothing else" "$(cat "$P/claude-code/index.d.ts" "$P/claude-code-tools/index.d.ts")"
ok_scan=ok
for f in claude-code/index.d.ts claude-code-tools/index.d.ts tsconfig.json; do
  python3 "$SCAN" --plain < "$P/$f" > /dev/null 2>&1 || ok_scan="$f: $(python3 "$SCAN" --plain < "$P/$f" 2>&1 | head -n 2)"
done
check "so the push gate's own scanner passes every pinned file" "$ok_scan"
[ "$(tr -d ' \n' < "$P/tsconfig.json" | sed -nE 's/.*"types":\[([^]]*)\].*/\1/p')" = '"claude-code","claude-code-tools","claude-code-mcp"' ] \
  && grep -q '"strict": true' "$P/tsconfig.json" \
  && check "the tsconfig keeps its options, with types cut back to Claude Code's three" ok || check "the tsconfig keeps its options, with types cut back to Claude Code's three" "$(cat "$P/tsconfig.json")"
[ "$(cat "$P/claude-code-mcp/index.d.ts")" = 'export {}' ] \
  && check "the session's MCP list is never taken: the pinned one is left as it was" ok \
  || check "the session's MCP list is never taken: the pinned one is left as it was" "$(cat "$P/claude-code-mcp/index.d.ts")"

# 2. A refused character outside a comment would change a type if its line were left out, so the
#    tool refuses, names the line, and pins nothing.
before="$(cksum < "$P/claude-code-tools/index.d.ts")"
lay "$T/src2" 2.1.401
printf 'declare module "claude-code" { export type Mode = "a %s b" }\n' "$EM" >> "$T/src2/claude-code-tools/index.d.ts"
run "$T/src2"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'claude-code-tools/index.d.ts line 10' \
  && check "a refused character in a type refuses the refresh, by line" ok || check "a refused character in a type refuses the refresh, by line" "exit=$code out=$out"
[ "$(cksum < "$P/claude-code-tools/index.d.ts")" = "$before" ] && head -n 1 "$P/claude-code/index.d.ts" | grep -q '2.1.400' \
  && check "and pins nothing" ok || check "and pins nothing" "$(head -n 1 "$P/claude-code/index.d.ts")"

# 3. A folder that is not a laid types folder, or whose engine types do not name their build.
mkdir -p "$T/notlaid"
run "$T/notlaid"
[ "$code" -eq 2 ] && printf '%s\n' "$out" | grep -q 'has no claude-code/index.d.ts' \
  && check "a folder missing a laid file is refused with exit 2, naming the file" ok || check "a folder missing a laid file is refused with exit 2, naming the file" "exit=$code out=$out"
lay "$T/src3" 2.1.402; sed -i.bak '1d' "$T/src3/claude-code/index.d.ts"
run "$T/src3"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'Written by Claude Code' && head -n 1 "$P/claude-code/index.d.ts" | grep -q '2.1.400' \
  && check "engine types that do not name their build are refused, and nothing is pinned" ok \
  || check "engine types that do not name their build are refused, and nothing is pinned" "exit=$code out=$out"

# 3b. A refresh must never leave a pin holding two builds' files, the engine's first line naming one
#     while the tools are another's (lessons review of #970). A pinned tools file and folder that
#     cannot be written stopped the copy that used to go file by file into the pin after the engine's
#     file was already new; the new set is now written whole beside the pin and swapped in, so the
#     same pin is refreshed whole. A user who can write anyway (root) cannot be refused this way.
lay "$T/src5" 2.1.500; printf 'export type B500 = 1\n' >> "$T/src5/claude-code-tools/index.d.ts"
chmod 444 "$P/claude-code-tools/index.d.ts"; chmod 555 "$P/claude-code-tools"
if [ -w "$P/claude-code-tools/index.d.ts" ]; then
  echo "UNMEASURED: this user can write a mode 444 file, so a pin that cannot be written in place cannot be staged here"
else
  run "$T/src5"
  b="$(head -n 1 "$P/claude-code/index.d.ts")"; t="$(grep -c 'B500' "$P/claude-code-tools/index.d.ts")"
  [ "$code" -eq 0 ] && [ "$b" = '// Written by Claude Code 2.1.500.' ] && [ "$t" = 1 ] \
    && check "a pin whose files cannot be written in place is still refreshed whole, engine and tools alike" ok \
    || check "a pin whose files cannot be written in place is still refreshed whole, engine and tools alike" "exit=$code first line: $b, new tools: $t, out=$out"
  [ "$(cat "$P/claude-code-mcp/index.d.ts")" = 'export {}' ] \
    && check "and the hand kept MCP list survives the swap" ok || check "and the hand kept MCP list survives the swap" "$(cat "$P/claude-code-mcp/index.d.ts" 2>&1)"
fi
chmod -R u+w "$TS" 2>/dev/null; rm -rf "$TS"/claude-code-types.old.* 2>/dev/null

# 3c. Where the new set cannot be written at all (here, the folder holding the pin refuses a new
#     folder), the refresh fails, says the pin was left as it was, and it was: every file the same
#     and nothing left beside it.
lay "$T/src6" 2.1.600; printf 'export type B600 = 1\n' >> "$T/src6/claude-code-tools/index.d.ts"
sums(){ cat "$P/claude-code/index.d.ts" "$P/claude-code-tools/index.d.ts" "$P/claude-code-mcp/index.d.ts" "$P/tsconfig.json" | cksum; }
before="$(sums)"
chmod 555 "$TS"
if [ -w "$TS" ]; then
  echo "UNMEASURED: this user can write a mode 555 folder, so a refresh that cannot write its new set cannot be staged here"
else
  run "$T/src6"
  stray="$(find "$TS" -maxdepth 1 -name 'claude-code-types.*' | wc -l | tr -d ' ')"
  [ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'left as it was' && [ "$(sums)" = "$before" ] && [ "$stray" = 0 ] \
    && check "a new set that cannot be written fails the refresh and leaves the pin exactly as it was" ok \
    || check "a new set that cannot be written fails the refresh and leaves the pin exactly as it was" "exit=$code stray=$stray out=$out"
fi
chmod 755 "$TS"

# 4. The pinned types this repository ships (#953): whole, naming their build on the engine's first
#    line, carrying the built-in tools' inputs, declaring no MCP tool, with a tsconfig naming
#    Claude Code's three type roots, and clean under the push gate's own style scanner, which is
#    what lets them be committed at all.
SHIP="$DIR/typescript/claude-code-types"
head -n 1 "$SHIP/claude-code/index.d.ts" 2>/dev/null | grep -qE '^// Written by Claude Code [0-9]+\.[0-9]+\.[0-9]+\.$' \
  && check "the shipped pinned types name the Claude Code build they came from" ok \
  || check "the shipped pinned types name the Claude Code build they came from" "$(head -n 1 "$SHIP/claude-code/index.d.ts" 2>&1)"
grep -q 'interface BuiltinToolInputs' "$SHIP/claude-code-tools/index.d.ts" 2>/dev/null && grep -q 'interface McpToolInputs' "$SHIP/claude-code/index.d.ts" 2>/dev/null \
  && check "and carry the engine's API and the built-in tools' inputs" ok || check "and carry the engine's API and the built-in tools' inputs" "missing"
[ -f "$SHIP/claude-code-mcp/index.d.ts" ] && ! grep -qE '^[[:space:]]*"?mcp__[A-Za-z0-9_-]+"?:' "$SHIP/claude-code-mcp/index.d.ts" && ! grep -q 'McpToolInputs *{' "$SHIP/claude-code-mcp/index.d.ts" \
  && check "and declare no MCP tool, so no session's connected tools enter a verdict" ok \
  || check "and declare no MCP tool, so no session's connected tools enter a verdict" "$(cat "$SHIP/claude-code-mcp/index.d.ts" 2>&1)"
[ "$(tr -d ' \n' < "$SHIP/tsconfig.json" | sed -nE 's/.*"types":\[([^]]*)\].*/\1/p')" = '"claude-code","claude-code-tools","claude-code-mcp"' ] \
  && check "and a tsconfig naming Claude Code's three type roots" ok || check "and a tsconfig naming Claude Code's three type roots" "$(cat "$SHIP/tsconfig.json" 2>&1)"
for f in claude-code/index.d.ts claude-code-tools/index.d.ts claude-code-mcp/index.d.ts tsconfig.json; do
  python3 "$SCAN" --plain < "$SHIP/$f" > /dev/null 2>&1 \
    && check "the shipped $f passes the push gate's style scan" ok || check "the shipped $f passes the push gate's style scan" "$(python3 "$SCAN" --plain < "$SHIP/$f" 2>&1 | head -n 3)"
done

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
