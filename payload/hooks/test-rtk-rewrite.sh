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
  --help|help) cat "$RTK_STUB_DIR/help" 2>/dev/null || true ;;
  rewrite)
    if [ -s "$RTK_STUB_DIR/rewrite" ]; then cat "$RTK_STUB_DIR/rewrite"; exit 0; fi
    exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/rtk"
export RTK_STUB_DIR="$TMPROOT"
: > "$TMPROOT/rewrite"
# rtk's own subcommand list, which is where the set of test summarisers is derived from.
rtk_help_fixture() {
  cat > "$TMPROOT/help" <<'HELP'
Commands:
  git            Git commands with compact output
  test           Run tests and show only failures
  playwright     Playwright E2E tests with compact output
  pytest         Pytest test runner with compact output
  vitest         Vitest commands with compact output
  cargo          Cargo commands with compact output
  newrunner      Brand new test harness with compact output
  read           Read file with intelligent filtering
HELP
}
rtk_help_fixture

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
grep -q '"permissionDecision": *"allow"' <<< "$out" \
  && check "and allows it, or the rewrite would just prompt" ok \
  || check "and allows it, or the rewrite would just prompt" "out=$out"
# The rest of the tool input has to survive: the hook replaces ONE field of it, and a rewrite that
# dropped the others would silently discard whatever else the caller set.
grep -q '"description"' <<< "$out" \
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

# ---------------------------------------------------------------------------
# A TEST RUN is never rewritten into an rtk summariser (claude-config#259).
#
# Twice on 2026-09-01 a full Playwright run came back as exactly 18 bytes, `PASS (0) FAIL (3)`,
# and nothing else. Both commands EXITED 0 and the true results were 4356 and 4359 passed with
# nothing failed. Two properties compound: it invented three failures that did not exist, and it
# discarded the entire underlying output, so there was nothing left to cross-check against. The
# same parser failing the other way round reports PASS on a red suite, by the same mechanism, with
# no output left to contradict it.
#
# A summary that can disagree with the exit code, while being the only thing printed, is not a
# summary a reader can rely on, and a test verdict is the one output where being wrong is
# indistinguishable from being right. So test runs pass through unfiltered and everything else
# keeps saving tokens, which is the same shape as the `rtk read` refusal above: by DESTINATION,
# because whatever produced it is what corrupts the output.
refused_to_rewrite() { # refused_to_rewrite <destination>  -> "ok" when the hook passed through
  printf '%s\n' "$1" > "$TMPROOT/rewrite"
  local o; o="$(hook 'some command')"
  if [ -z "$o" ]; then echo ok; else echo "it rewrote to: $(printf '%s' "$o" | rewritten_to)"; fi
}
check "#259 a playwright run is not condensed into a verdict" \
  "$(refused_to_rewrite 'rtk playwright test --config playwright.node.config.js --reporter=dot')"
check "#259 nor a pytest run" "$(refused_to_rewrite 'rtk pytest -q')"
check "#259 nor a vitest run" "$(refused_to_rewrite 'rtk vitest run')"
check "#259 nor the generic test summariser" "$(refused_to_rewrite 'rtk test')"
# The test-ness of these lives in the ARGUMENT, not the subcommand: rtk's help calls `cargo` and
# `go` compact output for those tools generally, and only the `test` verb makes it a verdict.
check "#259 nor cargo test, where the verb is the argument" "$(refused_to_rewrite 'rtk cargo test')"
check "#259 nor go test" "$(refused_to_rewrite 'rtk go test ./...')"
# Derived, not listed: a summariser this hook has never heard of is refused because rtk's own help
# says it runs tests. A hand-written list checks only what it lists (L96).
check "#259 and a test summariser nobody hardcoded is refused too" "$(refused_to_rewrite 'rtk newrunner --all')"

# The controls, and they are the point: everything that is not a test verdict still saves tokens.
printf 'rtk git status\n' > "$TMPROOT/rewrite"
out_259a="$(hook 'git status')"
[ "$(printf '%s' "$out_259a" | rewritten_to)" = "rtk git status" ] \
  && check "#259 an ordinary command is still rewritten" ok \
  || check "#259 an ordinary command is still rewritten" "out=$out_259a"
printf 'rtk cargo build\n' > "$TMPROOT/rewrite"
out_259b="$(hook 'cargo build')"
[ "$(printf '%s' "$out_259b" | rewritten_to)" = "rtk cargo build" ] \
  && check "#259 and a cargo BUILD is not caught by the cargo test rule" ok \
  || check "#259 and a cargo BUILD is not caught by the cargo test rule" "out=$out_259b"

# Fail closed. If rtk stops answering with a subcommand list the derivation finds nothing, and a
# refusal that quietly stopped refusing would be the defect back with a green test beside it (L98).
: > "$TMPROOT/help"
check "#259 a floor destination is still refused when the derivation reads nothing" \
  "$(refused_to_rewrite 'rtk playwright test')"
rtk_help_fixture

# ---- rtk's integrity baseline still describes the hook beside it (claude-config#259 follow-up) ----
# rtk keeps a sha256 of this hook in .rtk-hook.sha256 and REFUSES TO RUN AT ALL when the two
# disagree: no rewriting, no token saving, and a tamper banner on every command. #259 edited the
# hook deliberately, to stop test runs being routed through a summariser that reported
# "PASS (0) FAIL (3)" for a run with 4356 passes, and the baseline was left describing the version
# before that edit. Nothing here noticed; the first sign was the banner.
#
# So the pair is checked HERE, on every run, rather than only when rtk happens to be invoked. That
# is what makes re-baselining safe: the baseline is not a thing somebody remembers to update, it
# is a thing that goes red in the same suite as the hook it describes (L225: the invariant between
# two stored values is checked by something that reads the VALUES).
RTK_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rtk-rewrite.sh"
RTK_BASELINE="$(dirname "$RTK_HOOK")/.rtk-hook.sha256"
if [ ! -f "$RTK_BASELINE" ]; then
  # Absent is its own answer, not agreement. Without a baseline rtk warns and establishes one, so
  # this is a state worth naming rather than passing over (L98).
  check "the rtk integrity baseline is present" "no .rtk-hook.sha256 beside the hook, so nothing records what rtk expects"
else
  rtk_recorded="$(awk 'NR==1{print $1}' "$RTK_BASELINE" 2>/dev/null)"
  rtk_actual="$(shasum -a 256 "$RTK_HOOK" 2>/dev/null | awk '{print $1}')"
  # Both halves read, and both required to be non-empty: two empty strings agree perfectly, and a
  # comparison that passes by reading nothing is the failure this exists to catch (L98, L178).
  if [ -z "$rtk_recorded" ] || [ -z "$rtk_actual" ]; then
    check "the rtk integrity baseline and the hook can both be read" \
      "recorded=[$rtk_recorded] actual=[$rtk_actual]"
  elif [ "$rtk_recorded" = "$rtk_actual" ]; then
    check "the rtk integrity baseline matches the hook beside it" ok
  else
    check "the rtk integrity baseline matches the hook beside it" \
      "recorded $rtk_recorded but the hook hashes to $rtk_actual, so rtk will refuse to run at all and print a tampering banner on every command. If the hook change was deliberate, re-record it: shasum -a 256 rtk-rewrite.sh | sed 's| .*| rtk-rewrite.sh|' > .rtk-hook.sha256"
  fi
fi
# The comparison is watched saying NO before it is believed, against a hash built here, or a check
# that has only ever agreed is not yet a check (L1).
rtk_probe_bad="0000000000000000000000000000000000000000000000000000000000000000"
[ "$rtk_probe_bad" = "${rtk_actual:-x}" ] \
  && check "the baseline comparison would notice a hash that does not match" "it read a deliberately wrong hash as matching" \
  || check "the baseline comparison would notice a hash that does not match" ok

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
