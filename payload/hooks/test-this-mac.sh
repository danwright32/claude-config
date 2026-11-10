#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/
# Tests for lib/this-mac.sh, the one reading of which Mac a hook is on (claude-config#2561), and for
# lib/hand-rolled-hostname.py, the scan that fails on the next hook working it out by hand (L613).
#
# Four hooks read `hostname` themselves and did not agree: two cut at the first dot and two only a
# trailing .local, so a name with several dots, as a network can hand out, was one Mac to one hook
# and another to the next.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/lib/this-mac.sh"
SCAN="$DIR/lib/hand-rolled-hostname.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
check_eq() { if [[ "$3" == "$2" ]]; then check "$1" ok; else check "$1" "expected '$2', got '$3'"; fi; }

for f in "$HELPER" "$SCAN"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: test-this-mac: ${f#"$DIR"/} is missing beside this suite"
    printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" 1
    exit 1
  fi
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/this-mac.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-this-mac: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A stand in for hostname, answering whatever STUB_HOST says, or failing when STUB_FAIL is set.
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/hostname" <<'EOF'
#!/bin/bash
if [ -n "${STUB_FAIL:-}" ]; then echo "hostname: cannot read" >&2; exit 1; fi
printf '%s\n' "${STUB_HOST-}"
EOF
chmod +x "$TMPROOT/bin/hostname"

name() { # name <stub hostname> [argument...]: what this_mac_name prints, then its exit
  local h="$1"; shift
  STUB_HOST="$h" PATH="$TMPROOT/bin:$PATH" bash -c '. "$1"; shift; out="$(this_mac_name "$@")"; printf "%s %s" "$?" "$out"' _ "$HELPER" "$@"
}

echo "lib/this-mac.sh: one short name, however hostname answers"
check_eq "a plain name is itself" "0 Dans-MacBook-Pro" "$(name Dans-MacBook-Pro)"
check_eq "a .local name drops the .local" "0 Dans-MacBook-Pro" "$(name Dans-MacBook-Pro.local)"
check_eq "a name with several dots keeps what is before the first" "0 Dans-MacBook-Pro" "$(name Dans-MacBook-Pro.lan.example.com)"
check_eq "an empty answer is no name, exit 1" "1 " "$(name '')"
check_eq "a name that is only a domain is no name, exit 1" "1 " "$(name .local)"
out="$(STUB_FAIL=1 PATH="$TMPROOT/bin:$PATH" bash -c '. "$1"; out="$(this_mac_name)"; printf "%s %s" "$?" "$out"' _ "$HELPER")"
check_eq "a hostname that fails is no name, exit 1" "1 " "$out"
check_eq "a name passed in is judged instead of this Mac's" "0 Daniels-MacBook-Pro-2" "$(name Dans-MacBook-Pro Daniels-MacBook-Pro-2.local)"
check_eq "an empty name passed in stands for a Mac whose name cannot be read" "1 " "$(name Dans-MacBook-Pro '')"

echo "every hook that works out which Mac it is on asks lib/this-mac.sh"
# The callers, judged as one Mac named with several dots: each must reach the same short name.
judge() { STUB_HOST="Dans-MacBook-Pro.lan.example.com" PATH="$TMPROOT/bin:$PATH" "$@"; }
out="$(AGENT_CAP_HOST= judge bash "$DIR/agent-cap.sh" 2>&1)"
case "$out" in *"name could not be read"*) check "agent-cap.sh: an empty AGENT_CAP_HOST still stands for an unreadable name" ok ;; *) check "agent-cap.sh: an empty AGENT_CAP_HOST still stands for an unreadable name" "$out" ;; esac
out="$(judge bash "$DIR/agent-cap.sh" --number 2>&1)"
check_eq "agent-cap.sh reads a several dot name as the work MacBook" "$(bash "$DIR/agent-cap.sh" --table | awk '$1 == "Dans-MacBook-Pro" { print $2 }')" "$out"
out="$(judge bash -c '. "$1"; ar_host' _ "$DIR/lib/ai-review-common.sh" 2>&1)"
check_eq "ai-review-common.sh's ar_host reads a several dot name as the work MacBook" "Dans-MacBook-Pro" "$out"
out="$(AI_REVIEW_HOST=Daniels-MacBook-Pro-2.local judge bash -c '. "$1"; ar_host' _ "$DIR/lib/ai-review-common.sh" 2>&1)"
check_eq "ar_host still judges as AI_REVIEW_HOST names" "Daniels-MacBook-Pro-2" "$out"
# push-changes.sh sourced by a bare name, from its own folder: BASH_SOURCE holds no slash, so cutting
# at the last one leaves the file name, and the helper must still be found beside it.
out="$(cd "$DIR/lib" && judge bash -c '. push-changes.sh; out="$(this_mac_name)"; printf "%s %s" "$?" "$out"' 2>&1)"
check_eq "push-changes.sh sourced by a bare file name still finds lib/this-mac.sh" "0 Dans-MacBook-Pro" "$out"

# The helper missing beside a hook is said, never read as a Mac with no name (L11).
mkdir -p "$TMPROOT/nolib/lib"
cp "$DIR/agent-cap.sh" "$DIR/check-project-list.sh" "$TMPROOT/nolib/"
said="$(python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$TMPROOT/nolib/lib" project-list.sh 2>&1)"; rc=$?
check_eq "project-list.sh installs beside the hooks that lack lib/this-mac.sh, without bringing it" \
  "0 absent" "$rc $([ -e "$TMPROOT/nolib/lib/this-mac.sh" ] && echo present || echo absent)${said:+ said: $said}"
out="$(judge bash "$TMPROOT/nolib/agent-cap.sh" 2>&1)"
case "$out" in *"lib/this-mac.sh is missing"*"default applies"*) check "agent-cap.sh without lib/this-mac.sh says it is missing and takes the default" ok ;; *) check "agent-cap.sh without lib/this-mac.sh says it is missing and takes the default" "$out" ;; esac
printf '## Projects\n\nOn Dans-MacBook-Pro:\n- `~/x`\n' > "$TMPROOT/nolib/CLAUDE.md"
out="$(PROJECT_LIST_FILE="$TMPROOT/nolib/CLAUDE.md" judge bash "$TMPROOT/nolib/check-project-list.sh" 2>&1)"; rc=$?
case "$rc $out" in "2 "*"this-mac.sh is missing"*) check "check-project-list.sh without lib/this-mac.sh refuses, naming it" ok ;; *) check "check-project-list.sh without lib/this-mac.sh refuses, naming it" "exit $rc: $out" ;; esac

echo "lib/hand-rolled-hostname.py: the next hook reading hostname by hand fails"
T="$TMPROOT/tree"
mkdir -p "$T/payload/hooks/lib" "$T/tools"
# The shapes the hooks used, one per file, each a copy.
printf '#!/usr/bin/env bash\nHOST="${X:-$(hostname 2>/dev/null)}"\n' > "$T/payload/hooks/own-sub.sh"
printf '#!/usr/bin/env bash\nh="${HOSTNAME:-x}"\n' > "$T/payload/hooks/own-var.sh"
printf '#!/usr/bin/env bash\nf() { local h; h=`hostname -s`; }\n' > "$T/payload/hooks/lib/own-tick.sh"
printf '#!/usr/bin/env bash\nn="$(scutil --get LocalHostName)"\n' > "$T/payload/hooks/own-scutil.sh"
printf '#!/bin/bash\nhostname | cut -d. -f1\n' > "$T/payload/hooks/own-noext"
# What is not a copy: a comment, a sentence naming hostname, gh's --hostname, Python's
# gethostname (another language), a suite, the helper itself, and a file outside the hooks.
printf '#!/usr/bin/env bash\n# reads `hostname` by hand\necho "no readable hostname, so"\ngh auth token --hostname github.com\n' > "$T/payload/hooks/clean.sh"
printf '#!/usr/bin/env bash\nh="$(hostname)"\n' > "$T/payload/hooks/test-clean.sh"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$T/payload/hooks/lib" this-mac.sh >/dev/null \
  || check "lib/this-mac.sh installs into the scan's tree" "install-hook-libs.py refused it"
printf '#!/usr/bin/env bash\nh="$(hostname -s)"\n' > "$T/tools/clean.sh"
LIST="payload/hooks/own-sub.sh
payload/hooks/own-var.sh
payload/hooks/lib/own-tick.sh
payload/hooks/own-scutil.sh
payload/hooks/own-noext
payload/hooks/clean.sh
payload/hooks/test-clean.sh
payload/hooks/lib/this-mac.sh
tools/clean.sh"
out="$(printf '%s\n' "$LIST" | python3 "$SCAN" --root "$T" 2>"$TMPROOT/err")"; rc=$?
check_eq "a tree holding a hand rolled reading fails the scan" "1" "$rc"
for f in payload/hooks/own-sub.sh:2 payload/hooks/own-var.sh:2 payload/hooks/lib/own-tick.sh:2 payload/hooks/own-scutil.sh:2 payload/hooks/own-noext:2; do
  case "$out" in *"$f: "*) check "and names $f" ok ;; *) check "and names $f" "$out" ;; esac
done
for f in payload/hooks/clean.sh payload/hooks/test-clean.sh payload/hooks/lib/this-mac.sh tools/clean.sh; do
  case "$out" in *"$f:"*) check "and does not name $f" "$out" ;; *) check "and does not name $f" ok ;; esac
done
grep -q 'lib/this-mac.sh' "$TMPROOT/err" && check "and says to ask lib/this-mac.sh" ok \
  || check "and says to ask lib/this-mac.sh" "$(cat "$TMPROOT/err")"
# A list naming nothing it reads is not a clean tree (L98).
out="$(printf 'tools/clean.sh\n' | python3 "$SCAN" --root "$T" 2>&1)"; rc=$?
check_eq "a list naming no hook it reads is refused, not passed" "2" "$rc"
out="$(printf 'payload/hooks/clean.sh\n' | python3 "$SCAN" --root "$T" 2>&1)"; rc=$?
check_eq "a tree with no copy passes" "0" "$rc"

# The whole tree, when this suite sits in a checkout (lib/checkout-root.sh, claude-config#1567).
ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
  FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
  [ -n "$FILES" ] && check "the files to judge were listed" ok \
    || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
  found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$ROOT" 2>&1)"; found_rc=$?
  check_eq "no hook in this repository works out which Mac it is on by hand" "0" "$found_rc${found:+
$found}"
else
  echo "SUITE-PART-UNMEASURED this copy is not in a claude-config checkout, so its hooks were not scanned for a hand rolled hostname"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
