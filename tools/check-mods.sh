#!/bin/bash
# check-mods.sh <mods dir>: hold every mod in a folder to what Claude Code itself accepts
# (claude-config#606). A mod is a folder holding .claude-plugin/plugin.json. Each one is run through
# `claude plugin validate`, and through `claude plugin test` when it carries any *.test.ts or
# *.test.tsx of its own. Both commands' exit codes were measured on 2.1.288 before this relied on
# them (2026-10-03): validate exits 1 on a bad event name and on a missing module, test exits 1 on
# a failing test.
#
# Exit codes, each distinct so a caller can never read one as another (L11, L53):
#   0  every mod passed (the count is printed, so zero mods is visibly zero, L98)
#   1  at least one mod failed, each named with the engine's reason
#   2  the mods folder does not exist
#   3  UNMEASURED: mods are present but there is no claude command to ask (L411, L490)
#   4  UNMEASURED: claude answered that hooks modules are switched off in this process (its cached
#      rollout switch, cachedGrowthBookFeatures.tengu_plugin_hooks_modules in the user's
#      .claude.json, or a setting such as disableAllHooks), which no test can set; the engine's
#      words are printed (#740). A definite failure of another mod outranks it, as it outranks 3.
#
# CLAUDE_BIN names the claude command; left unset it is found on PATH, then at ~/.local/bin/claude.
# TSC_BIN names a TypeScript compiler for the strict type check; left unset it is the compiler pinned
# in tools/typescript (installed with `npm ci --prefix tools/typescript`, #803), else tsc on PATH.
# CHECK_MODS_TS_DIR moves where the pin, the pinned Claude Code types (claude-code-types/) and the
# record of known type errors are read from, for tests. Nothing is read from an installed copy of a
# mod (#953), so the same tree gives the same verdict on any machine and in CI.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mods: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
dir="${dir%/}"

mods=()
for d in "$dir"/*/; do
  [ -f "$d.claude-plugin/plugin.json" ] && mods+=("${d%/}")
done
n=${#mods[@]}
if [ "$n" -eq 0 ]; then
  echo "check-mods: 0 mods checked in $dir"
  exit 0
fi

# Every mod ships its own tsconfig.json (Dan, 2026-10-04, after #638). Without one, Claude Code
# generates it in the installed copy, and the sync sends that up to main as a local edit. This needs
# only the filesystem, so it is checked before the claude lookup and holds on a machine with none.
failed=0
for d in "${mods[@]}"; do
  if [ ! -f "$d/tsconfig.json" ]; then
    echo "check-mods: $(basename "$d") has no tsconfig.json; every mod ships its own, or the copy Claude Code generates is sent up as a local edit"
    failed=1
  fi
done

# No mod hooks an event Claude Code's built-in security default sends past the user tier every mod
# loads in (#875). Seated outermost for a Team or Enterprise organization, it routes each of these
# straight to the tier beneath, so a mod's hook on one never runs, and nothing says so but a debug log
# line. Its own code in 2.1.292: e("classic.*",(n,o,t)=>t.to(o,"append")), and the same for each name
# below. Both Macs keep it out of first place with a managed settings file (#876), so these hooks run
# there, but only while that file is in place: each is listed by mod and event in BYPASS_KNOWN with
# the issue deciding it, so depending on the file is a decision, never an accident. Filesystem only, so it holds on CI's runner too; where a claude binary is found,
# the list is compared with that build's own routes below.
BYPASSED_ROUTES="attribution.text
classic.*
prompt.compose
prompt.context
prompt.section
settings.read
skill.prompt"
BYPASS_KNOWN="${CHECK_MODS_BYPASS_KNOWN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sec-default-bypassed-hooks.tsv}"
is_bypassed(){   # $1 = event name
  local r
  # Read line by line, never word split, where classic.* would be expanded as a file pattern.
  while IFS= read -r r; do
    # Unquoted on purpose: classic.* is a pattern, and a dot in the others is a dot.
    # shellcheck disable=SC2254
    case "$1" in $r) return 0 ;; esac
  done <<< "$BYPASSED_ROUTES"
  return 1
}
# Every event a mod's own hook files register, one per line: on('<event>' in command position, in
# hooks/ outside its tests, with whole comment lines taken out first so a comment naming one is not
# one. Only a line that IS a comment is taken out: a // later in a line may be inside a string (a
# URL), and cutting there would hide a hook after it (lessons review of #879). A trailing comment
# naming an event is read as a hook, which fails loudly rather than passing a dead one.
events_of(){   # $1 = mod dir
  perl -MFile::Find -e '
    my @f;
    find(sub { push @f, $File::Find::name if -f $_ && /\.tsx?$/ && !/\.test\.tsx?$/ }, $ARGV[0]) if -d $ARGV[0];
    for my $f (sort @f) {
      open(my $h, "<", $f) or die "cannot read $f: $!\n";
      local $/; my $s = <$h>; close $h;
      $s =~ s{^[ \t]*//[^\n]*}{}mg;
      while ($s =~ /(?<![\w.\$])on\(\s*[\x27"]([A-Za-z][\w.*]*)[\x27"]/g) { print "$1\n" }
    }' "$1/hooks"
}
known_bypass=""
if [ -f "$BYPASS_KNOWN" ]; then
  # Each line: mod, event, and why it stays, which begins with the issue deciding it (L675, L129).
  bad_known="$(awk -F'\t' '!/^#/ && NF > 0 && (NF < 3 || $3 !~ /^#[0-9]+:? [A-Za-z]/) { print NR }' "$BYPASS_KNOWN" | paste -sd, -)"
  if [ -n "$bad_known" ]; then
    echo "check-mods: $BYPASS_KNOWN line(s) $bad_known need a mod, an event and a reason that begins with the issue deciding it (#123: why)"
    failed=1
  fi
  known_bypass="$(awk -F'\t' '!/^#/ && NF >= 2 { print $1 "\t" $2 }' "$BYPASS_KNOWN")"
fi
for d in "${mods[@]}"; do
  name="$(basename "$d")"
  if ! evs="$(events_of "$d")"; then
    echo "check-mods: $name: could not read its hook files to see which events they register (the reason is above), so it was stopped"
    failed=1
    continue
  fi
  # Read line by line, never word split: classic.* would be expanded as a file pattern.
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    is_bypassed "$ev" || continue
    if printf '%s\n' "$known_bypass" | grep -qxF "$name	$ev"; then continue; fi
    echo "check-mods: $name hooks $ev, which Claude Code's built-in security default sends past the user tier mods load in wherever it sits first (#875), so it runs only while /Library/Application Support/ClaudeCode/managed-settings.json keeps it out of first place (#876). Move it to an event that reaches a mod (tool.check for a PreToolUse check, turn.complete, command.run, session.end), or list it in $BYPASS_KNOWN with the issue deciding it."
    failed=1
  done <<< "$(printf '%s\n' "$evs" | LC_ALL=C sort -u)"
  # A listed hook this mod no longer registers: the line comes down, or it would excuse the next one.
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    if ! printf '%s\n' "$evs" | grep -qxF "$ev"; then
      echo "check-mods: $name no longer hooks $ev, so its line in $BYPASS_KNOWN must come down."
      failed=1
    fi
  done <<< "$(printf '%s\n' "$known_bypass" | awk -F'\t' -v m="$name" '$1 == m { print $2 }')"
done

# What an engine.create hook returns, the built $ spread with what the mod adds, is never cast
# (#833). A cast to never passes any shape, so a test's stand-in for another mod's noun that lacked a
# member, or took a parameter narrower than the real one, type checked clean: removing all 19 casts on
# 2.1.292 found eight such stand-ins in seven mods. A stand-in is typed with
# the real noun's types instead (import type from ../.claude-plugin/types/<mod>/index.d.ts), and each
# member a test never reaches refuses by name. The returned object is matched with its braces
# balanced, so a cast inside it (a state.set argument) is not one, and the line named is the return's.
# Filesystem only, so it holds on CI's runner too.
casts_of(){   # $1 = mod dir
  perl -MFile::Find -e '
    my @f;
    find({ wanted => sub { push @f, $File::Find::name if -f $_ && /\.tsx?$/ },
           preprocess => sub { grep { $_ ne "node_modules" && $_ ne ".claude-plugin" } @_ } }, $ARGV[0]);
    for my $f (sort @f) {
      open(my $h, "<", $f) or die "cannot read $f: $!\n";
      local $/; my $s = <$h>; close $h;
      while ($s =~ /\breturn\s*(\{\s*\.\.\.built\b(?:[^{}]|(\{(?:[^{}]|(?2))*\}))*\})\s*as\s+(never|unknown|any)\b/g) {
        my $line = 1 + (substr($s, 0, $-[0]) =~ tr/\n//);
        my $rel = substr($f, length($ARGV[0]) + 1);
        print "$rel:$line: as $3\n";
      }
    }' "$1"
}
for d in "${mods[@]}"; do
  name="$(basename "$d")"
  if ! cs="$(casts_of "$d")"; then
    echo "check-mods: $name: could not read its files to see whether an engine.create return is cast (the reason is above), so it was stopped"
    failed=1
    continue
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    echo "check-mods: $name/$c: an engine.create hook casts the object it returns, which passes any shape, so the strict type check cannot see a member it lacks or a parameter the real one refuses (#833). Return it uncast, typed with the real types."
    failed=1
  done <<< "$cs"
done

# A mod test that times its subject sets a time limit of its own (#1016). The test runner's default,
# 5,000 ms, is a fixed number, so a test timing its subject under it is judged by how busy the
# machine is (L224): session-registry's #911 test, which compares a list against a yardstick
# measured in the same run, failed at it three times out of three beside 96 CPU burners with
# nothing broken (measured 2026-10-09, when the runner's own error named the 5,000 ms). Timing is performance.now, process.hrtime, or Date.now arithmetic, in the test
# itself or in a helper it calls, however many helpers deep. A test's limit is the timeoutMs in its
# options, written in place or in the named object it passes; a timeoutMs elsewhere in its body
# (a command's bound) is not its limit. Tests and helpers are found by indentation, as every mod
# here is formatted: one ends at the next line indented no deeper that does not close a bracket.
# Whole comment lines are taken out first, so a comment naming a clock is not timing. Prints
# "<file>:<line><TAB><test name><TAB><what times>" for each test without a limit.
# Filesystem only, so it holds on CI's runner too.
untimed_of(){   # $1 = mod dir
  perl -MFile::Find -e '
    my @f;
    find({ wanted => sub { push @f, $File::Find::name if -f $_ && /\.test\.tsx?$/ },
           preprocess => sub { grep { $_ ne "node_modules" && $_ ne ".claude-plugin" } @_ } }, $ARGV[0]);
    my $clock = qr{\bperformance\.now\s*\(|\bprocess\.hrtime\b|\bDate\.now\s*\(\s*\)\s*-|-\s*Date\.now\s*\(\s*\)};
    for my $f (sort @f) {
      open(my $h, "<", $f) or die "cannot read $f: $!\n";
      my @l = <$h>; close $h;
      chomp @l;
      s{^\s*//.*}{} for @l;
      my $indent = sub { $_[0] =~ /^(\s*)/; length $1 };
      # The text of the statement starting on line $i: to the next line indented no deeper that
      # does not close a bracket.
      my $stmt = sub {
        my $i = shift; my $k = $indent->($l[$i]); my $j = $i + 1;
        $j++ while $j < @l && ($l[$j] !~ /\S/ || $indent->($l[$j]) > $k || $l[$j] =~ /^\s*[\}\)\]]/);
        join("\n", @l[$i .. $j - 1]);
      };
      my %def;
      for my $i (0 .. $#l) {
        next unless $l[$i] =~ /^\s*(?:export\s+)?(?:(?:const|let|var)\s+([A-Za-z_\$][\w\$]*)\s*(?::[^=]*)?=(?!=)|(?:async\s+)?function\s*\*?\s*([A-Za-z_\$][\w\$]*))/;
        my $n = defined $1 ? $1 : $2;
        $def{$n} .= $stmt->($i) . "\n";
      }
      # Helpers that time, directly or through another that does, to a fixed point.
      my %times;
      $times{$_} = "the clock" for grep { $def{$_} =~ $clock } keys %def;
      for (my $grew = 1; $grew; ) {
        $grew = 0;
        for my $n (sort keys %def) {
          next if $times{$n};
          for my $m (sort keys %times) {
            if ($def{$n} =~ /(?<![\w\$.])\Q$m\E\s*\(/) { $times{$n} = $m; $grew = 1; last }
          }
        }
      }
      (my $rel = $f) =~ s{^\Q$ARGV[0]\E/}{};
      for my $i (0 .. $#l) {
        next unless $l[$i] =~ /^\s*(?:test|it)\s*\(\s*([\x27"`])/;
        my $q = $1;
        my $t = $stmt->($i);
        my $via;
        if ($t =~ $clock) { ($via) = $t =~ /(performance\.now|process\.hrtime|Date\.now)/ }
        else {
          for my $m (sort keys %times) {
            if ($t =~ /(?<![\w\$.])\Q$m\E\s*\(/) { $via = $m; last }
          }
        }
        next unless $via;
        $t =~ /^\s*(?:test|it)\s*\(\s*\Q$q\E((?:[^\\\Q$q\E]|\\.)*)\Q$q\E\s*,\s*/s or next;
        my ($name, $rest) = ($1, substr($t, $+[0]));
        my $limited = 0;
        if ($rest =~ /^(\{(?:[^{}]|(?1))*\})/) { $limited = $1 =~ /\btimeoutMs\b/ }
        elsif ($rest =~ /^([A-Za-z_\$][\w\$]*)\s*,/) { $limited = ($def{$1} // "") =~ /\btimeoutMs\b/ }
        print "$rel:", $i + 1, "\t$name\t$via\n" unless $limited;
      }
    }' "$1"
}
for d in "${mods[@]}"; do
  name="$(basename "$d")"
  if ! ut="$(untimed_of "$d")"; then
    echo "check-mods: $name: could not read its tests to see whether one times its subject under the default time limit (the reason is above), so it was stopped"
    failed=1
    continue
  fi
  while IFS=$'\t' read -r where test via; do
    [ -n "$where" ] || continue
    echo "check-mods: $name/$where: test '$test' times its subject (through $via) under the test runner's fixed 5,000 ms limit, which measures how busy the machine is, not the code (#1016, L224). Let a comparison against a yardstick from the same run be the judgement, and give the test a timeoutMs only a hang reaches."
    failed=1
  done <<< "$ut"
done

# The strict type check (#758), against types taken from this repository alone (#953). Claude Code
# lays a mod's types only in the copy it loads, and its MCP part lists whatever tools the session had
# connected when that copy last reloaded, so a check borrowing an installed copy's types gave the
# same tree a different verdict from one hour to the next, and none at all where nothing was
# installed (L461, L398). Each mod is checked instead beside the Claude Code types pinned in
# tools/typescript/claude-code-types (one build's engine API and built-in tools, and an MCP list
# declaring no tool) and its dependencies' contracts as this folder holds them. That needs no Claude
# Code, so it runs before the claude lookup and holds on CI's runner too.
#
# The TypeScript compiler (#758): TSC_BIN, else the pinned one in tools/typescript (#803), else tsc on
# PATH. None is not a failure, since nothing was measured: each mod's line says its types were not
# checked, and the type check ends with one UNMEASURED line counting them and naming the install
# command (L411).
TS_DIR="${CHECK_MODS_TS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/typescript}"
PINNED="$TS_DIR/claude-code-types"
tsc="${TSC_BIN:-}"
[ -n "$tsc" ] || { [ -x "$TS_DIR/node_modules/.bin/tsc" ] && tsc="$TS_DIR/node_modules/.bin/tsc"; }
[ -n "$tsc" ] || tsc="$(command -v tsc 2>/dev/null || true)"
[ -n "$tsc" ] && [ -x "$tsc" ] || tsc=""
pinned_missing=""
for f in claude-code/index.d.ts claude-code-tools/index.d.ts claude-code-mcp/index.d.ts tsconfig.json; do
  [ -f "$PINNED/$f" ] || pinned_missing="${pinned_missing:+$pinned_missing, }$f"
done
# Which build the pinned types describe, from their own first line as the engine writes it.
pinned_build="$(head -n 1 "$PINNED/claude-code/index.d.ts" 2>/dev/null | sed -nE 's#^// Written by Claude Code ([0-9]+\.[0-9]+\.[0-9]+)\.?$#\1#p')"
# Type errors already found and recorded (#803), one line per mod, file and error code: the mod, the
# file and code ("hooks/register.tsx TS2345"), how many, and the issue fixing them. Kept by where and
# what rather than one count a mod, so fixing one error does not make room for a new one (L367). An
# error beyond its line fails; a line with fewer left passes and says the record can come down. A
# mod with no lines must have no errors.
KNOWN="$TS_DIR/known-type-errors.tsv"
known_of(){ [ -f "$KNOWN" ] && awk -F'\t' -v m="$1" '$1 == m { print $2 "\t" $3 "\t" $4 }' "$KNOWN"; }
# A mod's tsconfig and its dependencies' contracts, written into its scratch copy's types folder:
# the pinned tsconfig with each dependency added to "types", and each dependency's contract, the
# file its own plugin.json names as "types", copied from this folder. A dependency naming none adds
# nothing to `$`, so it is left out. Dies with the reason when a dependency is not in this folder,
# names a file that is not there, or a manifest cannot be read.
lay_deps(){   # $1 = mod dir  $2 = the scratch copy's types folder
  perl -MJSON::PP -MFile::Copy -MFile::Path=make_path -e '
    my ($pinned, $mod, $dir, $out) = @ARGV;
    sub load { my $f = shift; open(my $h, "<", $f) or die "cannot read $f: $!\n"; local $/; my $j = eval { JSON::PP->new->decode(<$h>) }; die "$f is not JSON: $@" unless ref $j eq "HASH"; $j }
    my $deps = load("$mod/.claude-plugin/plugin.json")->{dependencies} // [];
    die "its plugin.json lists dependencies as something other than a list\n" unless ref $deps eq "ARRAY";
    my @typed;
    for my $d (sort { $a cmp $b } map { ref $_ eq "HASH" ? $_->{name} // "" : $_ } @$deps) {
      die "it depends on $d, which is not in $dir\n" unless $d ne "" && -f "$dir/$d/.claude-plugin/plugin.json";
      my $t = load("$dir/$d/.claude-plugin/plugin.json")->{types};
      next unless defined $t;
      die "its dependency $d names $t as its types, which is not there\n" unless -f "$dir/$d/$t";
      make_path("$out/$d"); copy("$dir/$d/$t", "$out/$d/index.d.ts") or die "could not copy $d types: $!\n";
      push @typed, $d;
    }
    my $cfg = load("$pinned/tsconfig.json");
    push @{ $cfg->{compilerOptions}{types} }, @typed;
    open(my $w, ">", "$out/tsconfig.json") or die "could not write its tsconfig.json: $!\n";
    print $w JSON::PP->new->pretty->canonical->encode($cfg);
    close $w or die "could not write its tsconfig.json: $!\n";
  ' "$PINNED" "$1" "$dir" "$2"
}
typed=0
scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-mods.XXXXXX" 2>/dev/null)" || scratch=""
trap '[ -n "$scratch" ] && rm -rf "$scratch"' EXIT
# The mods whose types went unchecked, by cause, each "cause<TAB>mod" (L629: every cause named).
untyped=0; untyped_why=""
unchecked(){ untyped=$((untyped + 1)); untyped_why="${untyped_why}$1	$2
"; }
# Each mod's type result, by its place in mods: the words its ok line carries, and whether it failed,
# which its own line above already said.
types_of=(); typefail=()
for i in "${!mods[@]}"; do
  d="${mods[$i]}"; name="$(basename "$d")"
  types_of[i]=""; typefail[i]=0
  [ -f "$d/tsconfig.json" ] || continue
  # No compiler is decided first, so it is the cause named whatever else is wrong.
  if [ -z "$tsc" ]; then
    unchecked "no TypeScript compiler" "$name"
    types_of[i]="types not checked: no TypeScript compiler (looked for ${TSC_BIN:-$TS_DIR/node_modules/.bin/tsc, then tsc on PATH})"
    continue
  fi
  if [ -n "$pinned_missing" ]; then
    # This repository's own files: missing, they are a fault in the checkout, never unmeasured (L42).
    echo "check-mods: $name could not be type checked: the pinned Claude Code types in $PINNED lack $pinned_missing. Restore them from git, or pin a build's with: bash tools/refresh-claude-code-types.sh"
    failed=1; typefail[i]=1
    continue
  fi
  # The mod's source in scratch, any types laid in its own folder replaced by the pinned ones, so
  # nothing is written into the folder under check or through a link Claude Code laid there.
  checked="$scratch/$name"; copy_failed=""
  if [ -z "$scratch" ]; then
    copy_failed="no scratch folder could be made"
  elif ! { rm -rf "$checked" && cp -R "$d" "$checked" && rm -rf "$checked/.claude-plugin/types" \
      && mkdir -p "$checked/.claude-plugin/types" \
      && cp -R "$PINNED/claude-code" "$PINNED/claude-code-tools" "$PINNED/claude-code-mcp" "$checked/.claude-plugin/types/"; } 2>/dev/null; then
    copy_failed="the copy failed"
  fi
  if [ -n "$copy_failed" ]; then
    types_of[i]="types not checked: could not copy it to scratch ($copy_failed)"
    unchecked "could not be copied to scratch" "$name"
    continue
  fi
  if ! why="$(lay_deps "$d" "$checked/.claude-plugin/types" 2>&1)"; then
    echo "check-mods: $name could not be type checked: $(printf '%s\n' "$why" | sed '/^ *$/d' | tail -n 2 | paste -sd';' -)"
    failed=1; typefail[i]=1
    continue
  fi
  # Every mod imports its own files as ./x.ts, as the engine loads them, and the tsconfig Claude
  # Code lays does not allow that, so it is allowed here for every mod rather than in each one's
  # own tsconfig.json (lessons review of #797).
  typed=$((typed + 1))
  out="$("$tsc" -p "$checked" --noEmit --allowImportingTsExtensions 2>&1)"; trc=$?
  if [ "$trc" -ne 0 ]; then
    # Each error named from the mod's own folder, never the scratch copy it was checked in.
    errs="$(printf '%s\n' "$out" | grep 'error TS' | sed "s#^[^(]*/$name/#$name/#" || true)"
    if [ -z "$errs" ]; then
      # No error TS line: the compiler itself failed (a crash, a config it could not read), so no
      # type check was measured and none is claimed (L11).
      echo "check-mods: $name could not be type checked: the compiler exited $trc without reporting a type error: $(printf '%s\n' "$out" | sed '/^ *$/d' | tail -n 3 | sed 's/^ *//' | paste -sd';' -)"
      failed=1; typefail[i]=1
      continue
    fi
    count="$(printf '%s\n' "$errs" | grep -c 'error TS' || true)"
    rec="$(known_of "$name")"
    if [ -n "$rec" ]; then
      issue="$(printf '%s\n' "$rec" | head -n 1 | cut -f3)"
      # Each error by its file and code, counted: "hooks/register.tsx TS2345<TAB>3".
      cur="$(printf '%s\n' "$errs" | sed -E "s#^($name/)?([^(]*)\(.*error (TS[0-9]+):.*#\\2 \\3#" | LC_ALL=C sort | uniq -c \
        | awk '{ c = $1; $1 = ""; sub(/^ /, ""); print $0 "\t" c }')"
      over="$(awk -F'\t' 'NR == FNR { lim[$1] = $2; next } { r = ($1 in lim) ? lim[$1] : 0; if ($2 + 0 > r + 0) print $1 " (" $2 " found, " r " recorded)" }' \
        <(printf '%s\n' "$rec") <(printf '%s\n' "$cur") | paste -sd';' -)"
      if [ -n "$over" ]; then
        echo "check-mods: $name has type errors not in the record in $KNOWN ($issue): $over"
        failed=1; typefail[i]=1
        continue
      fi
      types_of[i]="types checked, $count known type errors ($issue)"
      under="$(awk -F'\t' 'NR == FNR { now[$1] = $2; next } { if ($2 + 0 > (($1 in now) ? now[$1] : 0) + 0) n++ } END { print n + 0 }' \
        <(printf '%s\n' "$cur") <(printf '%s\n' "$rec"))"
      [ "$under" -gt 0 ] && types_of[i]="${types_of[i]}, fewer than recorded in $under place(s): lower the record"
      continue
    fi
    echo "check-mods: $name fails a strict type check ($count errors): $(printf '%s\n' "$errs" | sed -n '1,3p' | sed 's/^ *//' | paste -sd';' -)"
    failed=1; typefail[i]=1
    continue
  fi
  types_of[i]="types checked"
  [ -n "$(known_of "$name")" ] && types_of[i]="types checked, none of its recorded errors left: remove its lines from $KNOWN"
done
# Which build every mod was checked against, said only when some mod's types really were checked.
if [ "$typed" -gt 0 ]; then
  echo "check-mods: $typed of $n mods type checked against the Claude Code ${pinned_build:-(build not named on the first line of claude-code/index.d.ts)} types pinned in $PINNED, never an installed copy's."
fi
# Never a silent skip (#803): how many mods' types went unchecked, why, and the one command that
# installs the pinned compiler. Said on stderr, and not a failure, since nothing was measured.
if [ "$untyped" -gt 0 ]; then
  causes="$(printf '%s' "$untyped_why" | awk -F'\t' 'NF == 2 { if (!($1 in n)) order[++k] = $1; n[$1]++; m[$1] = m[$1] ($1 in seen ? ", " : "") $2; seen[$1] = 1 }
    END { for (i = 1; i <= k; i++) printf "%s%d %s: %s", (i > 1 ? "; " : ""), n[order[i]], order[i], m[order[i]] }')"
  fix=""
  case "$untyped_why" in *"no TypeScript compiler	"*) fix=" Install the pinned compiler with: npm ci --prefix tools/typescript" ;; esac
  echo "check-mods: UNMEASURED: $untyped of $n mods' types were not checked ($causes).$fix" >&2
fi

bin="${CLAUDE_BIN:-}"
if [ -z "$bin" ]; then
  bin="$(command -v claude 2>/dev/null || true)"
  [ -n "$bin" ] || { [ -x "$HOME/.local/bin/claude" ] && bin="$HOME/.local/bin/claude"; }
fi
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  # CI's runner is always here. The type check above needs no Claude Code, so it has run (#953).
  echo "check-mods: UNMEASURED: $n mod(s) in $dir, and no claude command to validate or test them with (looked for ${bin:-claude on PATH}). That is not a pass. Their strict type check needs no Claude Code and is reported above." >&2
  # A definite failure (a missing tsconfig.json, a type error) outranks the unmeasured rest.
  [ "$failed" -eq 1 ] && exit 1
  exit 3
fi

# The list of bypassed events above, against the routes this build's security default really has
# (#875, L41): each is the literal e("<event>",(n,o,t)=>t.to(o,"append")) in its code, whatever the
# minifier names its variables. A build that adds one would leave a new dead hook unflagged, and one
# that drops one would flag a hook that now runs, so either difference fails. Read from the file the
# command resolves to; a file holding no route at all (a stub, another build layout) is said, not
# passed.
bin_file="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
routes_now="$(grep -a -o -E '[A-Za-z_$]\("[A-Za-z.*]+",\([A-Za-z_$]+,[A-Za-z_$]+,[A-Za-z_$]+\)=>[A-Za-z_$]+\.to\([A-Za-z_$]+,"append"\)\)' "$bin_file" 2>/dev/null \
  | sed -E 's/^.\("([^"]+)".*/\1/' | LC_ALL=C sort -u || true)"
if [ -z "$routes_now" ]; then
  echo "check-mods: UNMEASURED: no security default route was found in $bin_file, so the list of bypassed events was not compared with this build. The list in tools/check-mods.sh still applies." >&2
else
  routes_list="$(printf '%s\n' "$BYPASSED_ROUTES" | LC_ALL=C sort -u)"
  added="$(LC_ALL=C comm -13 <(printf '%s\n' "$routes_list") <(printf '%s\n' "$routes_now") | paste -sd' ' -)"
  dropped="$(LC_ALL=C comm -23 <(printf '%s\n' "$routes_list") <(printf '%s\n' "$routes_now") | paste -sd' ' -)"
  if [ -n "$added$dropped" ]; then
    echo "check-mods: this Claude Code build's security default routes past the user tier: $(printf '%s\n' "$routes_now" | paste -sd' ' -). The list in tools/check-mods.sh differs${added:+ (not listed: $added)}${dropped:+ (listed, no longer routed: $dropped)}. Update BYPASSED_ROUTES, then check every mod hook on the events that changed."
    failed=1
  fi
fi

# The engine's verdict lines: the item marks and the failure summary, a few at most. When there is
# no such line, the exit code and the last lines of output instead, never an empty reason (#740).
reason(){   # $1 = output  $2 = exit code
  local r
  r="$(printf '%s\n' "$1" | grep -E '[Ff]ail|[Ee]rror|refused|bad' | sed -n '1,3p' | sed 's/^ *//' | paste -sd';' -)"
  [ -n "$r" ] || r="no verdict line; exit $2, last output: $(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 3 | sed 's/^ *//' | paste -sd';' -)"
  printf '%s' "$r"
}
# Claude Code's refusal to run any plugin's code at all (2.1.289: "hooks modules are turned off in
# this process: ..." or "hooks modules are turned off here (disableAllHooks, ...)"). It says nothing
# about the mod, so the mod is unmeasured, never failed (L411).
switched_off(){ printf '%s\n' "$1" | grep -m1 'hooks modules are turned off' | sed 's/^ *//'; }
unmeasured=0; off_reason=""

for i in "${!mods[@]}"; do
  d="${mods[$i]}"; name="$(basename "$d")"
  [ -f "$d/tsconfig.json" ] || continue
  out="$("$bin" plugin validate "$d" 2>&1)"; rc=$?
  off="$(switched_off "$out")"
  if [ -n "$off" ]; then
    echo "check-mods: $name UNMEASURED: claude plugin validate answered: $off"
    unmeasured=1; off_reason="$off"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    echo "check-mods: $name refused by claude plugin validate: $(reason "$out" "$rc")"
    failed=1
    continue
  fi
  # Its own tests only: what the engine generates under .claude-plugin/types/ is not the mod's.
  # Both .test.ts and .test.tsx (UI tests that mount a component, #655).
  if [ -n "$(find "$d" \( -name '*.test.ts' -o -name '*.test.tsx' \) -not -path "$d/.claude-plugin/types/*" 2>/dev/null)" ]; then
    out="$("$bin" plugin test "$d" 2>&1)"; rc=$?
    off="$(switched_off "$out")"
    if [ -n "$off" ]; then
      echo "check-mods: $name UNMEASURED: claude plugin test answered: $off"
      unmeasured=1; off_reason="$off"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      echo "check-mods: $name failed claude plugin test: $(reason "$out" "$rc")"
      failed=1
      continue
    fi
  fi
  # A type failure was said on its own line above, so the mod has no ok line.
  [ "${typefail[i]}" -eq 1 ] && continue
  echo "check-mods: $name ok (${types_of[i]})"
done
echo "check-mods: $n mods checked in $dir"
# A Mac running another build than the pinned one is told so, and nothing else changes: every verdict
# above came from the pinned types, so it is the same on every build (#953).
cc_now="$("$bin" --version 2>/dev/null | head -n 1 | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ -n "$cc_now" ] && [ -n "$pinned_build" ] && [ "$cc_now" != "$pinned_build" ]; then
  echo "check-mods: this Mac runs Claude Code $cc_now, and the types every mod was checked against are pinned at $pinned_build. To check against $cc_now's, run bash tools/refresh-claude-code-types.sh once a mod has loaded on it, then run tests/test-mods.sh and commit the result."
fi
[ "$failed" -eq 1 ] && exit 1
if [ "$unmeasured" -eq 1 ]; then
  echo "check-mods: UNMEASURED: Claude Code has hooks modules switched off in this process, so its mods could not be checked. That is not a pass. It said: $off_reason" >&2
  exit 4
fi
exit 0
