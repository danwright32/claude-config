#!/usr/bin/env bash
# Every interpreter the tool and the suites invoke is named in CI's environment step
# (claude-config#624).
#
# The workflow's "Record the environment the suite is judged in" step is the list
# tests/run-on-linux.sh builds its container from, and the #337 check ties each tool on that list to
# a package the container installs. Nothing tied the list to what the code actually RUNS. Since #413
# the send runs `python3 hooks/lib/hook-registration.py`, the step did not name python3, the
# container had none, and four prelude checks failed on unchanged main while CI passed (fixed by
# hand in #622). So this reads what claude-sync and every shell file in the repository invoke, for a
# named set of tools that are not part of a bare image, and fails on one the step does not probe.
#
# THE SET is a list, deliberately, and it is the part of this a reader should distrust (L96): a tool
# outside it is not checked. It holds the interpreters and the non-coreutils tools the suites are
# known to shell out to. A tool called through a variable ("$PY" -c) is not seen either; the scan
# reads command position only, because reading every mention would flag prose.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
RUNNER="$DIR/run-on-linux.sh"

CHECKED_TOOLS="python3 python perl node ruby php deno bun jq rsync pgrep"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-citools-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-ci-environment-tools: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# Which of CHECKED_TOOLS the given files invoke in COMMAND POSITION: at the start of a line, after a
# separator, inside $( or a backtick, or after leading VAR=value assignments. Comment lines are
# skipped. A word followed by `=` is an assignment in some embedded language, not a call.
#
# The quoted first argument of a message command (MESSAGE_COMMANDS: echo and the check, bad, fail,
# die, say style helpers the suites define, whose first argument is always the text shown) is
# blanked before matching, so "FAIL: (python missing)" names python without calling it (#2129).
# Only the literal text goes: a $( ) or backtick substitution inside the message still runs and is
# still read, and later arguments are left alone, because a check's second argument is often code
# it evaluates. A message whose closing quote is not on its line is read unchanged, so a sighting
# there is reported rather than hidden: a wrong report is a loud failure, a hidden call is #413.
# A message helper missing from the list is read as before, which errs the same loud way.
# Prints "<tool>\t<file>:<line>" for the first sighting of each tool.
MESSAGE_COMMANDS="echo check bad fail die say warn note section hook_allow_notice"
invoked_tools(){   # $@ = files
  TOOLS="$CHECKED_TOOLS" MSGS="$MESSAGE_COMMANDS" perl -e '
    my @t = split / /, $ENV{TOOLS};
    my $msgs = join "|", map { quotemeta } split / /, $ENV{MSGS};
    # The index just past a $( ) that opens at $k (just after its parenthesis), or undef.
    sub past_sub { my ($s, $k) = @_; my $d = 1;
      while ($k < length $s) { my $c = substr($s, $k, 1);
        if ($c eq "\\") { $k += 2; next }
        if ($c eq "\x27") { my $e = index($s, "\x27", $k + 1); return undef if $e < 0; $k = $e + 1; next }
        if ($c eq "\"") { $k = past_dq($s, $k + 1); return undef unless defined $k; next }
        if ($c eq "`") { my $e = index($s, "`", $k + 1); return undef if $e < 0; $k = $e + 1; next }
        if ($c eq "(") { $d++ } elsif ($c eq ")") { return $k + 1 if --$d == 0 }
        $k++ }
      return undef }
    # The index just past a double quoted string whose text starts at $k, or undef.
    sub past_dq { my ($s, $k) = @_;
      while ($k < length $s) { my $c = substr($s, $k, 1);
        if ($c eq "\\") { $k += 2; next }
        return $k + 1 if $c eq "\"";
        if (substr($s, $k, 2) eq "\$(") { $k = past_sub($s, $k + 2); return undef unless defined $k; next }
        if ($c eq "`") { my $e = index($s, "`", $k + 1); return undef if $e < 0; $k = $e + 1; next }
        $k++ }
      return undef }
    # The line with the literal text of each message command quoted first argument turned to spaces.
    sub blank_messages { my ($l) = @_; my $out = $l;
      while ($l =~ /(?:^|[;&|({]|\b(?:then|do|else)\b)\s*(?:$msgs)\s+(?:-[A-Za-z]+\s+)*(?=["\x27])/g) {
        my $q = pos($l); my $c = substr($l, $q, 1); my @keep;
        if ($c eq "\x27") { my $e = index($l, "\x27", $q + 1); next if $e < 0;
          substr($out, $q + 1, $e - $q - 1) = " " x ($e - $q - 1); pos($l) = $e + 1; next }
        my ($k, $ok) = ($q + 1, 0); my @lit;
        while ($k < length $l) { my $ch = substr($l, $k, 1);
          if ($ch eq "\\") { push @lit, $k, $k + 1; $k += 2; next }
          if ($ch eq "\"") { $ok = 1; last }
          if (substr($l, $k, 2) eq "\$(") { $k = past_sub($l, $k + 2); last unless defined $k; next }
          if ($ch eq "`") { my $e = index($l, "`", $k + 1); last if $e < 0; $k = $e + 1; next }
          push @lit, $k; $k++ }
        next unless $ok && defined $k;
        substr($out, $_, 1) = " " for grep { $_ < $k } @lit;
        pos($l) = $k + 1 }
      return $out }
    my %seen;
    for my $f (@ARGV) {
      open(my $fh, "<", $f) or next;
      while (my $raw = <$fh>) {
        next if $raw =~ /^\s*#/;
        my $l = blank_messages($raw);
        for my $t (@t) {
          next if $seen{$t};
          if ($l =~ /(?:^\s*|[;&|(`]\s*|\$\(\s*|\b[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\x27[^\x27]*\x27|[^\s"\x27]*)\s+)\Q$t\E\s+(?!=)/) {
            $seen{$t} = "$f:$.";
          }
        }
      }
      close $fh;
    }
    print "$_\t$seen{$_}\n" for sort keys %seen;
  ' -- "$@"
}

# The tools a workflow's environment step probes, through the runner's own plan, which is the one
# place that list is derived (L41).
probed_tools(){   # $1 = the root of a checkout holding tests/run-on-linux.sh and the workflow
  SYNC_LINUX_PRINT_PLAN=1 bash "$1/tests/run-on-linux.sh" 2>/dev/null | sed -n 's/^probed: //p'
}

# Invoked but not probed, one "<tool>\t<where>" per line.
unprobed(){   # $1 = checkout root  $2.. = files to scan
  local root="$1" probed line tool; shift
  probed=" $(probed_tools "$root") "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tool="${line%%$'\t'*}"
    case "$probed" in *" $tool "*) ;; *) printf '%s\n' "$line" ;; esac
  done <<INVOKED
$(invoked_tools "$@")
INVOKED
}

# --- the scan itself, against a fixture built to hold the answer, before it is trusted on the real
#     tree (L1). A checkout whose step probes python3 only, and whose code calls node.
FX="$TMPROOT/fixture"
mkdir -p "$FX/tests" "$FX/.github/workflows"
cp "$RUNNER" "$FX/tests/run-on-linux.sh"
cat > "$FX/.github/workflows/tests.yml" <<'WF'
jobs:
  suite:
    runs-on: ubuntu-latest
    steps:
      - run: |
          python3 --version
          # node --version   (a commented out probe names nothing)
WF
cat > "$FX/calls-node.sh" <<'SH'
#!/usr/bin/env bash
verdict=$(printf '%s' "$x" | HOOK_DIR="$HOOK_DIR" node -e 'console.log(1)')
SH
cat > "$FX/mentions-node.sh" <<'SH'
#!/usr/bin/env bash
# node is mentioned here in a comment
printf 'absolute: node "%s"\n' "/x"
python3 - <<'PY'
node = stack.pop()
PY
command -v node >/dev/null || echo "no node"
SH
cat > "$FX/calls-python.sh" <<'SH'
#!/usr/bin/env bash
out="$(python3 hooks/lib/hook-registration.py)"
SH

o="$(unprobed "$FX" "$FX/calls-node.sh")"
case "$o" in node*calls-node.sh:2*) check "a call to an unprobed interpreter is found, with where it is" ok ;;
  *) check "a call to an unprobed interpreter is found, with where it is" "got: [$o]" ;; esac
o="$(unprobed "$FX" "$FX/mentions-node.sh")"
[ -z "$o" ] && check "a comment, a quoted mention, an embedded assignment and a command -v probe are not calls" ok \
  || check "a comment, a quoted mention, an embedded assignment and a command -v probe are not calls" "got: [$o]"
o="$(unprobed "$FX" "$FX/calls-python.sh")"
[ -z "$o" ] && check "a call to a probed interpreter passes" ok \
  || check "a call to a probed interpreter passes" "got: [$o]"
# The python3 case is the one that actually happened (#413, #622): with the probe gone from the
# step, the same call is found.
sed -i.bak 's/python3 --version/true/' "$FX/.github/workflows/tests.yml"
o="$(unprobed "$FX" "$FX/calls-python.sh")"
case "$o" in python3*) check "the #413 shape, python3 called and not probed, is caught" ok ;;
  *) check "the #413 shape, python3 called and not probed, is caught" "got: [$o]" ;; esac

# --- a failure message that names a tool is not a call to it (#2129). The fixture step probes
#     neither python nor ruby, so any sighting below is reported. A parenthesis in prose put the
#     word just after a separator, which is how these were read as calls.
cat > "$FX/message-names-python.sh" <<'SH'
#!/usr/bin/env bash
check "#2055 (python alone, C locale) the byte is written as U+FFFD" ok
check "the step (python missing) could not run" "got: [$o]"
  || bad '(python is not on the path) so the probe was skipped'
echo "FAIL: (python missing; ruby too)"
[ -n "$x" ] && say -n "(ruby missing)"
SH
o="$(unprobed "$FX" "$FX/message-names-python.sh")"
[ -z "$o" ] && check "a tool named inside a quoted message is not a call" ok \
  || check "a tool named inside a quoted message is not a call" "got: [$o]"
# The same messages with a real call inside or beside them still count: a substitution inside the
# message runs, the second argument of an evaluating check runs, a call after the message runs, and
# a message left open at the end of its line is read as it always was rather than guessed at. These
# call python3, which the fixture step stopped probing above and the real step probes, because the
# real tree scan below reads this file too.
cat > "$FX/message-runs-python.sh" <<'SH'
#!/usr/bin/env bash
bad "the adapters' tests (python $(python3 --version) exited 1)"
SH
o="$(unprobed "$FX" "$FX/message-runs-python.sh")"
case "$o" in python3*message-runs-python.sh:2*) check "a call inside a message's substitution is still found" ok ;;
  *) check "a call inside a message's substitution is still found" "got: [$o]" ;; esac
cat > "$FX/check-evals-python.sh" <<'SH'
#!/usr/bin/env bash
check "the probe answers (no tool here)" "[ \"\$(python3 -c 'print(1)')\" = 1 ]"
SH
o="$(unprobed "$FX" "$FX/check-evals-python.sh")"
case "$o" in python3*check-evals-python.sh:2*) check "a call in an evaluated check's code argument is still found" ok ;;
  *) check "a call in an evaluated check's code argument is still found" "got: [$o]" ;; esac
cat > "$FX/after-message-python.sh" <<'SH'
#!/usr/bin/env bash
echo "(python missing)"; python3 hooks/lib/x.py
SH
o="$(unprobed "$FX" "$FX/after-message-python.sh")"
case "$o" in python3*after-message-python.sh:2*) check "a call after a message on the same line is still found" ok ;;
  *) check "a call after a message on the same line is still found" "got: [$o]" ;; esac
cat > "$FX/open-message-python.sh" <<'SH'
#!/usr/bin/env bash
echo "a message running onto the next line (python3
missing)"
SH
o="$(unprobed "$FX" "$FX/open-message-python.sh")"
case "$o" in python3*open-message-python.sh:2*) check "a message left open at the end of its line is read unchanged" ok ;;
  *) check "a message left open at the end of its line is read unchanged" "got: [$o]" ;; esac

# --- the real tree. claude-sync and every shell file, uncommitted ones included, through the shared
#     lister, so a file being written is judged before it is committed.
files=()
while IFS= read -r f; do
  [ -f "$ROOT/$f" ] && files+=("$ROOT/$f")
done <<FILES
$(bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" 'claude-sync' '*.sh' 2>/dev/null)
FILES
[ "${#files[@]}" -ge 50 ] && check "the scan reads the repository's shell files (${#files[@]})" ok \
  || check "the scan reads the repository's shell files (${#files[@]})" "too few to be the real tree"
probed_now="$(probed_tools "$ROOT")"
case " $probed_now " in *" python3 "*) check "the real workflow's probes are read ($probed_now)" ok ;;
  *) check "the real workflow's probes are read ($probed_now)" "python3 missing, so the derivation read nothing" ;; esac
# Length checked first: macOS bash 3.2 errors on expanding an empty array under set -u (L486).
o="unscanned"; [ "${#files[@]}" -gt 0 ] && o="$(unprobed "$ROOT" "${files[@]}")"
[ -z "$o" ] && check "every checked tool the repository invokes is probed by CI's environment step" ok \
  || check "every checked tool the repository invokes is probed by CI's environment step" "add a '<tool> --version' line to the step and a package in tests/run-on-linux.sh for: $(printf '%s' "$o" | tr '\n' ';')"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
