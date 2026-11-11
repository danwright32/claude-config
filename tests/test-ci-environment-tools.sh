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
#
# The quoted arguments of a call to a JUDGING helper are blanked the same way (#2700). A function
# the scanned file defines is a judging helper when every route its arguments take leaves them as
# data (printed, tested, assigned and followed, handed to another judging helper, or read by a
# single quoted inline program naming no way to run a command), so `run_bash "cd x && bun test"`
# hands bun to a gate as text and is not a call. The set is worked out from each function's body,
# never from a list; an unquoted call beside a judged one, and a substitution inside its argument,
# are still read.
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
        my $q = pos($l); my $c = substr($l, $q, 1);
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
    # --- judging helpers (#2700): which functions this file defines never run their arguments.
    # The length of the positional parameter, or tainted variable, reference at $k, or 0.
    sub param_at { my ($s, $k, $tv) = @_; my $r = substr($s, $k + 1);
      return 2 if $r =~ /^[1-9@*]/;
      return 1 + length($1) if $r =~ /^(\{#?[1-9@*][^}]*\})/;
      return 1 + length($1) if $r =~ /^(\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\})/ && $tv->{$2};
      return 1 + length($1) if $r =~ /^([A-Za-z_][A-Za-z0-9_]*)/ && $tv->{$1};
      return 0 }
    # The simple commands of shell text from $k to $stop (")" or a backtick, or the end), each a
    # list of words with whether the data reaches it: a word holding a positional parameter, a
    # tainted variable or the output of a command given one, or a stdin piped from such a command.
    # Returns (index after, any command tainted, bad, commands); bad is a positional parameter
    # outside double quotes, a heredoc or a process substitution, or text this cannot follow.
    sub walk { my ($s, $k, $stop, $tv) = @_;
      my (@cmds, @w); my ($cur, $ct, $csq, $have, $pin, $taint, $bad, $depth) = ("", 0, 1, 0, 0, 0, 0, 0);
      my $end_word = sub { push @w, { t => $cur, taint => $ct, sq => $csq } if $have; ($cur, $ct, $csq, $have) = ("", 0, 1, 0) };
      my $end_cmd = sub { my ($pipe) = @_; $end_word->(); my $any = (grep { $_->{taint} } @w) || $pin;
        push @cmds, { w => [@w], pin => $pin } if @w; $taint ||= $any; @w = (); $pin = $pipe && $any ? 1 : 0 };
      my $inner = sub { my ($at, $close) = @_; my ($e, $t, $b, @sc) = walk($s, $at, $close, $tv);
        return undef unless defined $e; push @cmds, @sc; $ct ||= $t; $bad ||= $b; ($csq, $have) = (0, 1); return $e };
      while ($k < length $s) { my $c = substr($s, $k, 1);
        if (defined $stop && $c eq $stop && ($stop ne ")" || $depth == 0)) { $end_cmd->(0); return ($k + 1, $taint, $bad, @cmds) }
        if ($c eq "\\") { $cur .= substr($s, $k + 1, 1); ($csq, $have) = (0, 1); $k += 2; next }
        if ($c eq "#" && !$have) { my $e = index($s, "\n", $k); $k = $e < 0 ? length $s : $e; next }
        if ($c eq "\x27") { my $e = index($s, "\x27", $k + 1); return undef if $e < 0;
          $cur .= substr($s, $k + 1, $e - $k - 1); $have = 1; $k = $e + 1; next }
        if ($c eq "\"") { ($csq, $have) = (0, 1); $k++; my $closed = 0;
          while ($k < length $s) { my $d = substr($s, $k, 1);
            if ($d eq "\\") { $cur .= substr($s, $k, 2); $k += 2; next }
            if ($d eq "\"") { $k++; $closed = 1; last }
            if (substr($s, $k, 2) eq "\$(") { $k = $inner->($k + 2, ")"); return undef unless defined $k; next }
            if ($d eq "`") { $k = $inner->($k + 1, "`"); return undef unless defined $k; next }
            if ($d eq "\$" && (my $n = param_at($s, $k, $tv))) { $ct = 1; $cur .= substr($s, $k, $n); $k += $n; next }
            $cur .= $d; $k++ }
          return undef unless $closed; next }
        if (substr($s, $k, 2) eq "\$(") { $k = $inner->($k + 2, ")"); return undef unless defined $k; next }
        if ($c eq "`") { $k = $inner->($k + 1, "`"); return undef unless defined $k; next }
        if ($c eq "\$" && (my $n = param_at($s, $k, $tv))) { ($bad, $ct, $csq, $have) = (1, 1, 0, 1); $cur .= substr($s, $k, $n); $k += $n; next }
        if (substr($s, $k, 2) =~ /^(?:<<|<\(|>\()$/) { $bad = 1; $k += 2; next }
        if ($c eq " " || $c eq "\t") { $end_word->(); $k++; next }
        if ($c eq "\n" || $c eq ";") { $end_cmd->(0); $k++; next }
        if ($c eq "&") { $end_cmd->(0); $k += substr($s, $k, 2) eq "&&" ? 2 : 1; next }
        if ($c eq "|") { my $two = substr($s, $k, 2); $end_cmd->($two eq "||" ? 0 : 1); $k += ($two eq "||" || $two eq "|&") ? 2 : 1; next }
        if ($c eq "(") { $depth++ if defined $stop && $stop eq ")"; $end_cmd->(0); $k++; next }
        if ($c eq ")") { $depth-- if $depth; $end_cmd->(0); $k++; next }
        $cur .= $c; ($csq, $have) = (0, 1); $k++ }
      return undef if defined $stop;
      $end_cmd->(0); return ($k, $taint, $bad, @cmds) }
    # Whether a command the data reaches leaves it as data. A route that runs it, or one this does
    # not know, says no, so the helper is not judged and its call sites are read as before.
    sub route_ok { my ($cmd, $J, $tv) = @_; my @w = @{ $cmd->{w} };
      shift @w while @w && $w[0]{t} =~ /^(?:if|then|do|else|elif|while|until|!|\{|\}|time)$/ && !$w[0]{taint};
      shift @w while @w && $w[0]{t} =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
      return 1 unless @w;
      my $name = $w[0]{t}; return 0 if $w[0]{taint};
      my @args = @w[1 .. $#w];
      if ($cmd->{pin}) {
        return 0 unless $name =~ /^(?:bash|sh|zsh|dash|ksh)$/ && @args && $args[0]{t} !~ /^-/ && !grep { $_->{taint} } @args;
        return 1 }
      return 1 if $J->{$name} || $name =~ /^(?:printf|echo|\[|\[\[|test|case|local|declare|typeset|readonly|export)$/;
      if ($name =~ /^(?:perl|python|python3|node|ruby)$/) { my $i = 0;
        $i++ while $i < @args && $args[$i]{t} =~ /^-/ && $args[$i]{t} !~ /^-[ceE]$/ && !$args[$i]{taint};
        return 0 unless $i + 1 < @args && $args[$i]{t} =~ /^-[ceE]$/;
        my $prog = $args[$i + 1];
        return 0 if $prog->{taint} || !$prog->{sq} || $prog->{t} =~ /system|exec|popen|spawn|subprocess|child_process|eval|`|qx|open\s*\(/;
        return !grep { $_->{taint} } @args[0 .. $i + 1] }
      return 0 }
    # The judged set of one file: each function it defines once, whose body every route of the data
    # leaves as data. Built up from nothing, so a cycle or a call to an unjudged helper is unjudged.
    sub judged { my @L = @_; my (%body, %count);
      for my $i (0 .. $#L) {
        next unless $L[$i] =~ /^(\s*)(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{(.*)$/;
        my ($ind, $n, $rest) = ($1, $2, $3); $count{$n}++;
        if ($rest =~ /^(.*[;&])\s*\}\s*$/) { $body{$n} = $1; next }
        my ($b, $closed) = ($rest, 0);
        for my $j ($i + 1 .. $#L) { if ($L[$j] =~ /^\Q$ind\E\}\s*$/) { $closed = 1; last } $b .= "\n" . $L[$j] }
        $body{$n} = $closed ? $b : undef }
      my (%J, %parsed);
      for my $n (keys %body) { next if $count{$n} > 1 || !defined $body{$n};
        my %tv; my @r;
        for (1 .. 5) { @r = walk($body{$n} . "\n", 0, undef, \%tv); last unless defined $r[0];
          my $grew = 0;
          for my $c (@r[3 .. $#r]) { for my $x (@{ $c->{w} }) {
            next unless $x->{taint} && $x->{t} =~ /^([A-Za-z_][A-Za-z0-9_]*)=/ && !$tv{$1}; $tv{$1} = 1; $grew = 1 } }
          last unless $grew }
        next unless defined $r[0] && !$r[2];
        $parsed{$n} = [ grep { $_->{pin} || grep { $_->{taint} } @{ $_->{w} } } @r[3 .. $#r] ] }
      my $grew = 1;
      while ($grew) { $grew = 0;
        for my $n (keys %parsed) { next if $J{$n};
          next if grep { !route_ok($_, \%J) } @{ $parsed{$n} };
          $J{$n} = 1; $grew = 1 } }
      return \%J }
    # The line with the literal text of every quoted argument of each judged call turned to spaces.
    # A substitution inside one still runs at the call and is kept; an argument whose closing quote
    # is not on its line leaves the line as it was.
    sub blank_judged { my ($l, $J) = @_; return $l unless %$J; my $out = $l;
      my $names = join "|", map { quotemeta } sort keys %$J;
      while ($l =~ /(?:^|[;&|({!]|\b(?:then|do|else|elif|if|while|until)\b)\s*(?:$names)(?=[ \t])/g) {
        my $k = pos($l); my (@lit, $ok); $ok = 1;
        while ($k < length $l) { my $c = substr($l, $k, 1);
          last if $c =~ /[;&|)\n]/;
          if ($c eq "\\") { $k += 2; next }
          if ($c eq "#" && substr($l, $k - 1, 1) =~ /\s/) { last }
          if ($c eq "\x27") { my $e = index($l, "\x27", $k + 1); if ($e < 0) { $ok = 0; last }
            push @lit, $k + 1 .. $e - 1; $k = $e + 1; next }
          if ($c eq "\"") { $k++; my $closed = 0;
            while ($k < length $l) { my $ch = substr($l, $k, 1);
              if ($ch eq "\\") { push @lit, $k, $k + 1; $k += 2; next }
              if ($ch eq "\"") { $closed = 1; $k++; last }
              if (substr($l, $k, 2) eq "\$(") { $k = past_sub($l, $k + 2); last unless defined $k; next }
              if ($ch eq "`") { my $e = index($l, "`", $k + 1); last if $e < 0; $k = $e + 1; next }
              push @lit, $k; $k++ }
            unless ($closed && defined $k) { $ok = 0; last } next }
          if (substr($l, $k, 2) eq "\$(") { $k = past_sub($l, $k + 2); unless (defined $k) { $ok = 0; last } next }
          if ($c eq "`") { my $e = index($l, "`", $k + 1); if ($e < 0) { $ok = 0; last } $k = $e + 1; next }
          $k++ }
        substr($out, $_, 1) = " " for $ok ? @lit : ();
        pos($l) = $k if $k > pos($l) }
      return $out }
    my %seen;
    for my $f (@ARGV) {
      open(my $fh, "<", $f) or next;
      my @L = <$fh>; close $fh;
      my $J = judged(@L);
      for my $i (0 .. $#L) { my $raw = $L[$i];
        next if $raw =~ /^\s*#/;
        my $l = blank_judged(blank_messages($raw), $J);
        for my $t (@t) {
          next if $seen{$t};
          if ($l =~ /(?:^\s*|[;&|(`]\s*|\$\(\s*|\b[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\x27[^\x27]*\x27|[^\s"\x27]*)\s+)\Q$t\E\s+(?!=)/) {
            $seen{$t} = "$f:" . ($i + 1);
          }
        }
      }
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

# --- a command handed as text to a judging helper is not a call (#2700). The Slack drafts gate
#     suite judges `run_bash "cd <checkout> && bun test ..."`: the text goes through JSON to the
#     hook on its stdin and is never run, and the `&& bun` inside it refused a correct push. The
#     fixture calls name python3, which the fixture step stopped probing above and the real step
#     probes, because the real tree scan below reads this file too (bun there would fail it); the
#     helpers use perl, so a python3 sighting can only come from a call site. The helpers are the
#     gate suite's own shape, a chain that only ever hands its argument on as data.
cat > "$FX/judged-python.sh" <<'SH'
#!/usr/bin/env bash
bash_input() { perl -MJSON::PP -e 'print encode_json({command => $ARGV[0]})' "$1"; }
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp)"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
}
run_bash() { run_raw "$(bash_input "$1")"; }
run_bash "cd $T && python3 tools/area-check-replay.py"
[ -d "$T" ] && run_bash 'cd x || python3 a.py'
SH
o="$(unprobed "$FX" "$FX/judged-python.sh")"
case "$o" in *python3*) check "a tool named inside a quoted argument to a judging helper is not a call" "got: [$o]" ;;
  *) check "a tool named inside a quoted argument to a judging helper is not a call" ok ;; esac
# A real call still counts wherever it sits: unquoted after && beside a judged call, and inside a
# substitution, which runs at the call even inside a judged argument.
printf '%s\n' '#!/usr/bin/env bash' 'run_bash() { printf "%s" "$1" | bash "$HOOK"; }' \
  'run_bash "cd x && perl a.pl"; cd "$T" && python3 x.py' > "$FX/after-judged-python.sh"
o="$(unprobed "$FX" "$FX/after-judged-python.sh")"
case "$o" in *python3*after-judged-python.sh:3*) check "an unquoted call after && beside a judged call is still found" ok ;;
  *) check "an unquoted call after && beside a judged call is still found" "got: [$o]" ;; esac
printf '%s\n' '#!/usr/bin/env bash' 'run_bash() { printf "%s" "$1" | bash "$HOOK"; }' \
  'run_bash "cd x && $(python3 --version)"' > "$FX/subst-judged-python.sh"
o="$(unprobed "$FX" "$FX/subst-judged-python.sh")"
case "$o" in python3*subst-judged-python.sh:3*) check "a call in a substitution inside a judged argument is still found" ok ;;
  *) check "a call in a substitution inside a judged argument is still found" "got: [$o]" ;; esac
# A quoted string that IS run still counts: handed to eval or bash -c directly, to a helper that
# evals it or runs it through bash -c or word splits it unquoted, to a helper whose only route is
# one of those, and to a helper defined nowhere in the file, whose body cannot be read.
evaluated=(
  'eval "cd x && python3 a.py"'
  'bash -c "cd x && python3 a.py"'
  'try_it() { eval "$1"; }@@try_it "cd x && python3 a.py"'
  'in_shell() { bash -c "cd /tmp && $1"; }@@in_shell "cd x && python3 a.py"'
  'split_run() { $1; }@@split_run "cd x && python3 a.py"'
  'try_it() { eval "$1"; }@@outer() { try_it "$1"; }@@outer "cd x && python3 a.py"'
  'piped() { printf "%s" "$1" | bash; }@@piped "cd x && python3 a.py"'
  'kept() { local c="$1"; eval "$c"; }@@kept "cd x && python3 a.py"'
  'inline() { perl -e '"'"'system($ARGV[0])'"'"' "$1"; }@@inline "cd x && python3 a.py"'
  'nowhere_defined "cd x && python3 a.py"'
)
for e in "${evaluated[@]}"; do
  { printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' "${e//@@/$'\n'}"; } > "$FX/evaluated-python.sh"
  o="$(unprobed "$FX" "$FX/evaluated-python.sh")"
  case "$o" in *python3*evaluated-python.sh:*) check "a quoted string that is run is still read: ${e//@@/; }" ok ;;
    *) check "a quoted string that is run is still read: ${e//@@/; }" "got: [$o]" ;; esac
done

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
