#!/usr/bin/env bash
# Tests for rtk-rewrite.sh, which rewrites a command before Claude Code runs it
# (claude-config#124).
#
# This is the hook with the least room for error in the whole set: whatever it emits is what
# actually EXECUTES. It had no test. The rewrite logic itself lives in the rtk binary and is not
# this repo's to check; what IS this repo's is the refusal, the pass through, and the JSON, and
# every one of those is checked here against a stubbed rtk so nothing depends on which version
# happens to be installed (L52 is the risk being accepted here, and it is accepted knowingly: the
# stub encodes the CONTRACT this hook relies on, and the contract is one line, "print the rewrite
# or exit 1").
#
# The refusal matters most. `rtk read` strips comment lines and renumbers what remains, so every
# line number taken from it is wrong AND plausible, which is worse than mangled output. Three
# planning passes cited wrong file:line pairs before anyone suspected the instrument
# (downbeat#254). The hook refuses by DESTINATION rather than by source command, and that
# distinction is what the checks below pin.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/rtk-rewrite.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v jq >/dev/null 2>&1 || { echo "test-rtk-rewrite: jq is not on PATH, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.rtk.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-rtk-rewrite: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
# A stub rtk whose whole behaviour is read from a file, so each scenario sets what the real binary
# would have said and nothing here depends on the version installed on this Mac.
cat > "$BIN/rtk" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) cat "$RTK_STUB_DIR/version" 2>/dev/null || echo "rtk 0.31.0" ;;
  rewrite)
    if [ -s "$RTK_STUB_DIR/rewrite" ]; then cat "$RTK_STUB_DIR/rewrite"; exit 0; fi
    exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/rtk"
export RTK_STUB_DIR="$TMPROOT"
: > "$TMPROOT/rewrite"

# The payload is written to a FILE and fed in with a redirect, never through a pipe. The hook
# exits before reading stdin in several of the cases below (no jq, no rtk, too old), and a python
# producer whose stdout closes underneath it fails to flush at exit and returns 120, which under
# `pipefail` becomes the exit code the check reads. The hook's own exit is what these are about.
payload() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1],"description":"d"}}))' "$1" > "$TMPROOT/payload.json"; }
hook() { # hook <command>  -> the hook's stdout, with the stub ahead of anything real on PATH
  payload "$1"
  PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null
}
rewritten_to() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("hookSpecificOutput") or {}).get("updatedInput") or {}).get("command",""))' 2>/dev/null; }

# ---------------------------------------------------------------------------
# The ordinary rewrite, which is the thing the hook is for.
# ---------------------------------------------------------------------------
printf 'rtk git status\n' > "$TMPROOT/rewrite"
out="$(hook 'git status')"
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "a rewrite comes back as valid JSON" ok \
  || check "a rewrite comes back as valid JSON" "out=$out"
[ "$(printf '%s' "$out" | rewritten_to)" = "rtk git status" ] \
  && check "and carries the rewritten command" ok \
  || check "and carries the rewritten command" "out=$out"
printf '%s' "$out" | grep -q '"permissionDecision": *"allow"' \
  && check "and allows it, or the rewrite would just prompt" ok \
  || check "and allows it, or the rewrite would just prompt" "out=$out"
# The rest of the tool input has to survive: the hook replaces ONE field of it, and a rewrite that
# dropped the others would silently discard whatever else the caller set.
printf '%s' "$out" | grep -q '"description"' \
  && check "and keeps the rest of the tool input rather than replacing it" ok \
  || check "and keeps the rest of the tool input rather than replacing it" "out=$out"

# ---------------------------------------------------------------------------
# The refusal. Judged by DESTINATION, so it must hold whatever command produced it.
# ---------------------------------------------------------------------------
printf 'rtk read /repo/Thing.swift\n' > "$TMPROOT/rewrite"
for src in "cat /repo/Thing.swift" "head -50 /repo/Thing.swift" "tail -20 /repo/Thing.swift" "sed -n 1,5p /repo/Thing.swift"; do
  [ -z "$(hook "$src")" ] \
    && check "a rewrite into 'rtk read' is refused, whatever produced it: $src" ok \
    || check "a rewrite into 'rtk read' is refused, whatever produced it: $src" "it rewrote anyway"
done
# The control: with the destination changed and NOTHING else changed, the same source commands are
# rewritten. Without this, every refusal above is satisfied by a hook that rewrites nothing (L159).
printf 'rtk cat /repo/Thing.swift\n' > "$TMPROOT/rewrite"
[ -n "$(hook 'cat /repo/Thing.swift')" ] \
  && check "the control: the same command IS rewritten when the destination is not rtk read" ok \
  || check "the control: the same command IS rewritten when the destination is not rtk read" "it refused that too"

# ---------------------------------------------------------------------------
# Everything that must pass through untouched, saying nothing.
# ---------------------------------------------------------------------------
: > "$TMPROOT/rewrite"       # the stub now exits 1, which is rtk saying "no rewrite"
[ -z "$(hook 'git status')" ] \
  && check "no rewrite available means the command passes through silently" ok \
  || check "no rewrite available means the command passes through silently" "it said something"
printf 'git status\n' > "$TMPROOT/rewrite"
[ -z "$(hook 'git status')" ] \
  && check "a rewrite identical to the command passes through silently" ok \
  || check "a rewrite identical to the command passes through silently" "it emitted a no-op rewrite"
printf 'rtk git status\n' > "$TMPROOT/rewrite"
payload ''
[ -z "$(PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null)" ] \
  && check "a payload with an empty command passes through silently" ok \
  || check "a payload with an empty command passes through silently" "it rewrote nothing into something"
printf 'not json' > "$TMPROOT/payload.json"
[ -z "$(PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null)" ] \
  && check "a payload that does not parse passes through silently" ok \
  || check "a payload that does not parse passes through silently" "it emitted something"

# ---------------------------------------------------------------------------
# A version of rtk too old to have `rewrite` at all. It must WARN and pass through, never rewrite
# and never fail the command: an unusable tool has to be visible, and the person's command still
# has to run (L11).
# ---------------------------------------------------------------------------
printf 'rtk 0.22.0\n' > "$TMPROOT/version"
printf 'rtk git status\n' > "$TMPROOT/rewrite"
payload 'git status'
out_old="$(PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>"$TMPROOT/olderr")"; code_old=$?
[ -z "$out_old" ] && [ "$code_old" -eq 0 ] \
  && check "an rtk too old to rewrite passes the command through and exits cleanly" ok \
  || check "an rtk too old to rewrite passes the command through and exits cleanly" "out=$out_old exit=$code_old"
grep -qi 'too old' "$TMPROOT/olderr" \
  && check "and says so rather than going quiet" ok \
  || check "and says so rather than going quiet" "stderr=$(cat "$TMPROOT/olderr")"
printf 'rtk 0.31.0\n' > "$TMPROOT/version"

# ---------------------------------------------------------------------------
# rtk absent altogether. PATH here holds neither the stub nor anything else, so this is the state
# of a machine where rtk was never installed.
# ---------------------------------------------------------------------------
# The system directories only. rtk installs into ~/.local/bin or a package manager's directory,
# never into /usr/bin, so this is a PATH that has every tool the hook needs and no rtk. Asserted
# rather than assumed, because a PATH that happened to still hold rtk would make the checks below
# pass while testing the ordinary case again.
SYSPATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$SYSPATH" command -v rtk >/dev/null 2>&1 \
  && check "the fixture PATH really has no rtk on it" "rtk is at $(PATH="$SYSPATH" command -v rtk)" \
  || check "the fixture PATH really has no rtk on it" ok
PATH="$SYSPATH" command -v jq >/dev/null 2>&1 \
  && check "and does have jq, so the hook gets past its first guard" ok \
  || check "and does have jq, so the hook gets past its first guard" "no jq on $SYSPATH"
payload 'git status'
out_none="$(PATH="$SYSPATH" bash "$H" < "$TMPROOT/payload.json" 2>"$TMPROOT/noneerr")"; code_none=$?
[ -z "$out_none" ] && [ "$code_none" -eq 0 ] \
  && check "with rtk not installed the command passes through and exits cleanly" ok \
  || check "with rtk not installed the command passes through and exits cleanly" "out=$out_none exit=$code_none"
grep -qi 'not installed' "$TMPROOT/noneerr" \
  && check "and says which tool is missing" ok \
  || check "and says which tool is missing" "stderr=$(cat "$TMPROOT/noneerr")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
