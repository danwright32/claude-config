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
# CHECK_MODS_TS_DIR moves where the pin and its record of known type errors are read from, and
# CHECK_MODS_TYPES_HOME where a mod's laid types are borrowed from (default ~/.claude), for tests.
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
# loads in (#875). Seated outermost for a Team or Enterprise organization (both Macs), it routes each
# of these straight to the tier beneath, so a mod's hook on one never runs, and nothing says so but a
# debug log line. Its own code in 2.1.292: e("classic.*",(n,o,t)=>t.to(o,"append")), and the same for
# each name below. A hook that cannot move yet is listed by mod and event in BYPASS_KNOWN with the
# issue deciding it. Filesystem only, so it holds on CI's runner too; where a claude binary is found,
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
    echo "check-mods: $name hooks $ev, which Claude Code's built-in security default sends past the user tier mods load in, so it never runs (#875). Move it to an event that reaches a mod (tool.check for a PreToolUse check, turn.complete, command.run, session.end), or list it in $BYPASS_KNOWN with the issue deciding it."
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

bin="${CLAUDE_BIN:-}"
if [ -z "$bin" ]; then
  bin="$(command -v claude 2>/dev/null || true)"
  [ -n "$bin" ] || { [ -x "$HOME/.local/bin/claude" ] && bin="$HOME/.local/bin/claude"; }
fi
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  # CI's runner is always here, so the type check it never reaches is named too (#833).
  echo "check-mods: UNMEASURED: $n mod(s) in $dir, and no claude command to check them with (looked for ${bin:-claude on PATH}). That is not a pass. The strict type check is UNMEASURED too: it checks against the types Claude Code lays, and there is no Claude Code here to lay them." >&2
  # A missing tsconfig.json is a definite failure, which outranks the unmeasured rest.
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

# The TypeScript compiler for the strict type check (#758): TSC_BIN, else the pinned one in
# tools/typescript (#803), else tsc on PATH. None is not a failure, since nothing was measured: each
# mod's line says its types were not checked, and the run ends with one UNMEASURED line counting
# them and naming the install command (L411).
TS_DIR="${CHECK_MODS_TS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/typescript}"
tsc="${TSC_BIN:-}"
[ -n "$tsc" ] || { [ -x "$TS_DIR/node_modules/.bin/tsc" ] && tsc="$TS_DIR/node_modules/.bin/tsc"; }
[ -n "$tsc" ] || tsc="$(command -v tsc 2>/dev/null || true)"
[ -n "$tsc" ] && [ -x "$tsc" ] || tsc=""
# Claude Code lays a mod's types only in the copy it loads, ~/.claude/mods/<mod>, and the mirror
# never carries them (README "Mods"), so a mod checked where none are laid borrows that copy's.
TYPES_HOME="${CHECK_MODS_TYPES_HOME:-$HOME/.claude}"
# Type errors already found and recorded (#803), one line per mod, file and error code: the mod, the
# file and code ("hooks/register.tsx TS2345"), how many, and the issue fixing them. Kept by where and
# what rather than one count a mod, so fixing one error does not make room for a new one (L367). An
# error beyond its line fails; a line with fewer left passes and says the record can come down. A
# mod with no lines must have no errors.
KNOWN="$TS_DIR/known-type-errors.tsv"
known_of(){ [ -f "$KNOWN" ] && awk -F'\t' -v m="$1" '$1 == m { print $2 "\t" $3 "\t" $4 }' "$KNOWN"; }
# Which Claude Code build the record was measured on (#833). The laid types describe the build that
# laid them, which is the installed one, so the record is only comparable on that build: on another,
# a new error may be the newer types rather than a change in the mod. A run names the build its types
# came from against the recorded one, and on a mismatch every type failure names both. It still
# fails, because a real regression on the other build looks exactly the same (L42).
CC_RECORD="$TS_DIR/claude-code-version"
cc_now="$("$bin" --version 2>/dev/null | head -n 1 | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
cc_rec=""; [ -f "$CC_RECORD" ] && cc_rec="$(head -n 1 "$CC_RECORD" | tr -d '[:space:]')"
cc_note=""
if [ -n "$cc_now" ] && [ -n "$cc_rec" ] && [ "$cc_now" != "$cc_rec" ]; then
  cc_note=" [types from Claude Code $cc_now; the record was measured on $cc_rec, so this may be the newer types rather than a change in the mod]"
fi
typed=0
scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-mods.XXXXXX" 2>/dev/null)" || scratch=""
trap '[ -n "$scratch" ] && rm -rf "$scratch"' EXIT
# The mods whose types went unchecked, by cause, each "cause<TAB>mod" (L629: every cause named).
untyped=0; untyped_why=""
unchecked(){ untyped=$((untyped + 1)); untyped_why="${untyped_why}$1	$2
"; }

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

for d in "${mods[@]}"; do
  name="$(basename "$d")"
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
  # Strict types (#758). Claude Code lays its declarations, and the tsconfig.json every mod's own
  # extends, under .claude-plugin/types once it has loaded the mod; with those and a TypeScript
  # compiler the mod is type checked as its tsconfig.json says (strict, noUncheckedIndexedAccess).
  # Without either it is said on the mod's line, never claimed (L411, L440).
  types="types not checked: no TypeScript compiler (looked for ${TSC_BIN:-$TS_DIR/node_modules/.bin/tsc, then tsc on PATH})"
  checked="$d"
  # No compiler is decided first, so it is the cause named whether or not types could be borrowed.
  if [ -z "$tsc" ]; then
    unchecked "no TypeScript compiler" "$name"
    echo "check-mods: $name ok ($types)"
    continue
  fi
  copy_failed=""
  if [ ! -f "$d/.claude-plugin/types/tsconfig.json" ] && [ -f "$TYPES_HOME/mods/$name/.claude-plugin/types/tsconfig.json" ]; then
    [ -n "$scratch" ] || copy_failed="no scratch folder could be made"
  fi
  if [ -z "$copy_failed" ] && [ ! -f "$d/.claude-plugin/types/tsconfig.json" ] && [ -f "$TYPES_HOME/mods/$name/.claude-plugin/types/tsconfig.json" ]; then
    # This mod's source beside the types laid for the installed copy of it, in scratch, so nothing
    # is written into either.
    checked="$scratch/$name"
    rm -rf "$checked"; cp -R "$d" "$checked" && rm -rf "$checked/.claude-plugin/types" \
      && cp -R "$TYPES_HOME/mods/$name/.claude-plugin/types" "$checked/.claude-plugin/types" || { checked=""; copy_failed="the copy failed"; }
  fi
  if [ -n "$copy_failed" ]; then
    # Types were laid; what failed is the scratch copy, which is the cause said (L11).
    types="types not checked: its laid types are in $TYPES_HOME/mods/$name but it could not copy it to scratch ($copy_failed)"
    unchecked "could not be copied to scratch" "$name"
  elif [ -z "$checked" ] || [ ! -f "$checked/.claude-plugin/types/tsconfig.json" ]; then
    types="types not checked: Claude Code has not laid its types here or in $TYPES_HOME/mods/$name"
    unchecked "no types laid" "$name"
  else
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
        echo "check-mods: $name could not be type checked: the compiler exited $trc without reporting a type error: $(printf '%s\n' "$out" | sed '/^ *$/d' | tail -n 3 | sed 's/^ *//' | paste -sd';' -)$cc_note"
        failed=1
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
          echo "check-mods: $name has type errors not in the record in $KNOWN ($issue): $over$cc_note"
          failed=1
          continue
        fi
        types="types checked, $count known type errors ($issue)"
        under="$(awk -F'\t' 'NR == FNR { now[$1] = $2; next } { if ($2 + 0 > (($1 in now) ? now[$1] : 0) + 0) n++ } END { print n + 0 }' \
          <(printf '%s\n' "$cur") <(printf '%s\n' "$rec"))"
        [ "$under" -gt 0 ] && types="$types, fewer than recorded in $under place(s): lower the record"
        echo "check-mods: $name ok ($types)"
        continue
      fi
      echo "check-mods: $name fails a strict type check ($count errors): $(printf '%s\n' "$errs" | sed -n '1,3p' | sed 's/^ *//' | paste -sd';' -)$cc_note"
      failed=1
      continue
    fi
    types="types checked"
    rec="$(known_of "$name")"
    [ -n "$rec" ] && types="types checked, none of its recorded errors left: remove its lines from $KNOWN"
  fi
  echo "check-mods: $name ok ($types)"
done
echo "check-mods: $n mods checked in $dir"
# The build the checked types came from, against the one the record was measured on (#833). Said
# only when some mod's types were really checked, since otherwise no type result was compared.
if [ "$typed" -gt 0 ]; then
  if [ -z "$cc_rec" ]; then
    echo "check-mods: the record in $TS_DIR names no Claude Code build, so a type result here cannot be told apart from a change in the types: write this build's version (${cc_now:-unknown}) into $CC_RECORD once the record is right."
  elif [ -z "$cc_now" ]; then
    echo "check-mods: could not read which Claude Code build laid these types ('$bin --version' said nothing usable); the record was measured on $cc_rec."
  elif [ "$cc_now" = "$cc_rec" ]; then
    echo "check-mods: types came from Claude Code $cc_now, the build the record was measured on."
  else
    echo "check-mods: types came from Claude Code $cc_now, and the record in $TS_DIR was measured on $cc_rec. A type failure above may be the newer types rather than a change in a mod; once it is fixed or recorded, write $cc_now into $CC_RECORD."
  fi
fi
# Never a silent skip (#803): how many mods' types went unchecked, why, and the one command that
# installs the pinned compiler. Said on stderr, and not a failure, since nothing was measured.
if [ "$untyped" -gt 0 ]; then
  causes="$(printf '%s' "$untyped_why" | awk -F'\t' 'NF == 2 { if (!($1 in n)) order[++k] = $1; n[$1]++; m[$1] = m[$1] ($1 in seen ? ", " : "") $2; seen[$1] = 1 }
    END { for (i = 1; i <= k; i++) printf "%s%d %s: %s", (i > 1 ? "; " : ""), n[order[i]], order[i], m[order[i]] }')"
  echo "check-mods: UNMEASURED: $untyped of $n mods' types were not checked ($causes). Install the pinned compiler with: npm ci --prefix tools/typescript" >&2
fi
[ "$failed" -eq 1 ] && exit 1
if [ "$unmeasured" -eq 1 ]; then
  echo "check-mods: UNMEASURED: Claude Code has hooks modules switched off in this process, so its mods could not be checked. That is not a pass. It said: $off_reason" >&2
  exit 4
fi
exit 0
