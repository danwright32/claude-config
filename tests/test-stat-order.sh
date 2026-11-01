#!/usr/bin/env bash
# Every shell file in the repository asks GNU stat before BSD stat (claude-config#2003).
#
# GNU stat (the Ubuntu CI runner) reads -f as "report on the FILE SYSTEM": handed a BSD format it
# prints a block about the filesystem instead of failing cleanly, so a read that asks BSD's -f first
# is right on the Mac and quietly wrong on Linux, and nothing on the Mac can see it. The rule, and
# the two GNU first forms it accepts, live in payload/hooks/lib/stat-order.sh.
#
# The guard used to read only the disk cleaning skill's files (#1874), so the same slip anywhere else
# was caught by nothing until a Linux run failed, and three such reads were sitting outside it
# (run-all-tests.sh, test-claude-sync.sh and bug-bash/egress-setup.sh), with two more in
# claude-sync. Fix the class (L30): this reads every shell file the repository holds, derived
# through the shared lister, never listed (L96).
#
# The one part of the tree it leaves alone is the disk cleaning skill's own territory, which that
# skill's suite guards by the same rule and where it names, with its reason, the one BSD only read
# allowed on purpose (dcs_dataless). The territory is derived here exactly as that suite derives it,
# so the two split the tree without a gap, and the split is checked to have a guard on the other
# side (L129). Nothing in this suite allows a form by name.
#
# The readers that were fixed are also RUN, under stand ins shaped like each stat, because a Mac
# never runs the GNU half and the runner never runs the BSD half (L143). Each stand in is first
# shown to behave as the stat it imitates, and the GNU one to catch the old BSD first read.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() {
  echo ""
  echo "passed: $pass, failed: $fail"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo "'$2' not in: $1"; }
eq() { [ "$1" = "$2" ] && echo ok || echo "expected [$2], got [$1]"; }

. "$ROOT/payload/hooks/lib/stat-order.sh" || { check "the shared stat order rule loads" "payload/hooks/lib/stat-order.sh did not load"; finish; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stat-order.XXXXXXXX")" || { check "a scratch directory" "mktemp failed"; finish; }
case "${TMP%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}") echo "test-stat-order: refusing to run: scratch came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

# BSD's flag, spelled so this file holds no literal BSD first stat for the guard to read in itself.
BSD="stat -""f"

# ================================================================================================
# 1. The control on a real file: the guard is only real once seen to fail (L1). The rule's own
#    fixtures, every form refused and accepted, are in payload/hooks/test-stat-order-rule.sh.
# ================================================================================================
# One of the three reads #2003 named, put back the way it was: a copy of run-all-tests.sh with its
# GNU first mtime read swapped to ask BSD first. The guard has to refuse the copy.
RAT="$ROOT/payload/hooks/run-all-tests.sh"
mkdir -p "$TMP/swapped"
sed "s/stat -c %Y \"\$1\" 2>\/dev\/null || $BSD %m \"\$1\"/$BSD %m \"\$1\" 2>\/dev\/null || stat -c %Y \"\$1\"/" \
  "$RAT" > "$TMP/swapped/run-all-tests.sh"
check "the copy of run-all-tests.sh really was swapped back to BSD first" "$(cmp -s "$RAT" "$TMP/swapped/run-all-tests.sh" && echo "sed changed nothing" || echo ok)"
check "the guard refuses run-all-tests.sh with its mtime read asked BSD first" \
  "$(has "$(stat_order_scan "$TMP/swapped/run-all-tests.sh")" "run-all-tests.sh:")"

# ================================================================================================
# 2. The files it reads: every shell file in the repository, derived
# ================================================================================================
# The disk cleaning skill's territory, derived as that skill's stat order suite derives it: every
# shell file in the skill, and every one under hooks/ whose name or text names it or its removal
# tool. Relative to the root, as the lister prints.
territory() {
  { find "$ROOT/payload/skills/disk-clean" -type f -name '*.sh'
    grep -r -l --include='*.sh' -e 'disk-clean' -e 'disk-remove' "$ROOT/payload/hooks"
  } 2>/dev/null | sed "s|^$ROOT/||" | sort -u
}
TERR="$(territory)"
listed="$(bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" 'claude-sync' '*.sh')"; lrc=$?
check "the shared lister names the repository's shell files" "$([ "$lrc" -eq 0 ] && [ -n "$listed" ] && echo ok || echo "exit $lrc")"
files=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qxF -- "$f" <<< "$TERR" && continue
  files+=("$ROOT/$f")
done <<< "$listed"
check "it reads the repository's shell files (${#files[@]})" "$([ "${#files[@]}" -ge 300 ] && echo ok || echo "too few to be the real tree")"
# Held in a variable and read from a here string, never piped into `grep -q`, which leaves on its
# first match and fails the writer under pipefail (L183).
FILELIST="$(printf '%s\n' "${files[@]+"${files[@]}"}")"
for want in claude-sync payload/hooks/run-all-tests.sh tests/test-claude-sync.sh \
  payload/skills/bug-bash/egress-setup.sh payload/hooks/lib/stat-order.sh tests/test-stat-order.sh; do
  check "it reads $want" "$(grep -qxF "$ROOT/$want" <<< "$FILELIST" && echo ok || echo "not in its files")"
done
for want in payload/skills/disk-clean/scan-lib.sh payload/hooks/lib/disk-remove.sh; do
  check "it leaves $want to the disk cleaning skill's own guard" "$(grep -qxF "$want" <<< "$TERR" && echo ok || echo "not in that territory")"
done
# The other side of the split has to be guarded, or the territory is simply unread (L129): some
# suite inside it must carry a check that its stats ask GNU's -c before BSD's -f.
terr_guard="$(cd "$ROOT" && grep -l -E "check \"[^\"]*GNU's -c before BSD's -f" $(grep -E '(^|/)test-[^/]*\.sh$' <<< "$TERR") 2>/dev/null)"
terr_guard="${terr_guard%%$'\n'*}"
check "a suite in the disk cleaning territory guards its stat order (${terr_guard:-none})" "$([ -n "$terr_guard" ] && echo ok || echo "no suite there checks it, so those files are read by nothing")"

# ================================================================================================
# 3. The real files
# ================================================================================================
real="unscanned"; [ "${#files[@]}" -gt 0 ] && real="$(stat_order_scan "${files[@]}")"
check "every stat in every shell file outside the disk cleaning skill asks GNU's -c before BSD's -f" \
  "$([ -z "$real" ] && echo ok || printf '%s\n' "$real" | sed "s|^$ROOT/||; s/^/BSD first: /")"

# ================================================================================================
# 4. The fixed readers, run under each stat
# ================================================================================================
# One perl reader stands behind both stand ins, so they answer from the same file the expected
# value comes from. lstat, as both stats do without -L.
cat > "$TMP/fields.pl" <<'PL'
my ($flavour, $fmt, $p) = @ARGV;
my @s = lstat($p);
unless (@s) { print STDERR "stat: cannot stat '$p': No such file or directory\n"; exit 1 }
my $user = getpwuid($s[4]); $user = $s[4] unless defined $user;
my (%v, $re);
if ($flavour eq 'gnu') {
  %v = ('%Y' => $s[9], '%n' => $p, '%U' => $user, '%a' => sprintf('%o', $s[2] & 07777), '%s' => $s[7], '%%' => '%');
  $re = qr/%[YnUas%]/;
} else {
  %v = ('%m' => $s[9], '%N' => $p, '%Su' => $user, '%Lp' => sprintf('%o', $s[2] & 0777), '%z' => $s[7], '%t' => "\t", '%%' => '%');
  $re = qr/%(?:Su|Lp|[mNzt%])/;
}
(my $o = $fmt) =~ s/($re)/$v{$1}/g;
print "$o\n";
PL
GNUBIN="$TMP/gnu-bin"; BSDBIN="$TMP/bsd-bin"; mkdir -p "$GNUBIN" "$BSDBIN"
# GNU's stat: -c takes the format; -f is file system status, printing a block for each path that
# exists and failing on the rest, which is how a BSD format handed to it is read.
cat > "$GNUBIN/stat" <<'GNU'
#!/usr/bin/env bash
[ -n "${STAT_CALLS:-}" ] && printf '%s\n' "$*" >> "$STAT_CALLS"
fields="$(dirname "$0")/../fields.pl"
case "${1:-}" in
  -c)
    fmt="${2:-}"; shift 2 || exit 1; rc=0
    for p in "$@"; do perl "$fields" gnu "$fmt" "$p" || rc=1; done
    exit "$rc" ;;
  -f)
    shift; rc=0
    for p in "$@"; do
      if [ -e "$p" ]; then printf '  File: "%s"\n    ID: 9a1f2b0000000000 Namelen: 255     Type: ext2/ext3\n' "$p"
      else echo "stat: cannot read file system information for '$p': No such file or directory" >&2; rc=1; fi
    done
    exit "$rc" ;;
esac
echo "stat: missing operand" >&2
exit 1
GNU
# BSD's stat: -f takes the format; anything else, -c included, is an illegal option, said on
# stderr only.
cat > "$BSDBIN/stat" <<'BSDSTAT'
#!/usr/bin/env bash
[ -n "${STAT_CALLS:-}" ] && printf '%s\n' "$*" >> "$STAT_CALLS"
fields="$(dirname "$0")/../fields.pl"
case "${1:-}" in
  -f)
    fmt="${2:-}"; shift 2 || exit 1; rc=0
    for p in "$@"; do perl "$fields" bsd "$fmt" "$p" || rc=1; done
    exit "$rc" ;;
esac
echo "stat: illegal option -- ${1#-}" >&2
echo "usage: stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]" >&2
exit 1
BSDSTAT
chmod +x "$GNUBIN/stat" "$BSDBIN/stat"

mkdir -p "$TMP/files" "$TMP/owned"
printf 'a\n' > "$TMP/files/plain"
printf 'b\n' > "$TMP/files/with space"
chmod 755 "$TMP/owned"
mtime_of() { perl -e 'print ((lstat($ARGV[0]))[9])' "$1"; }
WANT_PLAIN="$(mtime_of "$TMP/files/plain")"
WANT_SPACE="$(mtime_of "$TMP/files/with space")"
WANT_OWNED="$(perl -e 'my @s = lstat($ARGV[0]); my $u = getpwuid($s[4]); $u = $s[4] unless defined $u; printf "%s %o\n", $u, $s[2] & 0777' "$TMP/owned")"
check "the expected answers were read" "$([ -n "$WANT_PLAIN" ] && [ -n "$WANT_SPACE" ] && [ -n "$WANT_OWNED" ] && echo ok || echo "perl read nothing")"

# The stand ins, shown to be what they claim before anything is judged through them (L404).
g_f="$(PATH="$GNUBIN:$PATH" $BSD %m "$TMP/files/plain" 2>/dev/null)"; g_frc=$?
found_stat="$(PATH="$GNUBIN:$PATH" command -v stat)"
check "the GNU stand in is the stat found on its PATH" "$(eq "$found_stat" "$GNUBIN/stat")"
check "the GNU stand in reads -f as file system status, printing a block and failing" \
  "$([ "$g_frc" -ne 0 ] && grep -q '^  File: ' <<< "$g_f" && echo ok || echo "exit $g_frc, said: $g_f")"
check "and answers -c with the format" "$(eq "$(PATH="$GNUBIN:$PATH" stat -c %Y "$TMP/files/plain")" "$WANT_PLAIN")"
b_c="$(PATH="$BSDBIN:$PATH" stat -c %Y "$TMP/files/plain" 2>/dev/null)"; b_crc=$?
check "the BSD stand in refuses -c with nothing on stdout" "$([ "$b_crc" -ne 0 ] && [ -z "$b_c" ] && echo ok || echo "exit $b_crc, said: $b_c")"
check "and answers -f with the format" "$(eq "$(PATH="$BSDBIN:$PATH" $BSD %m "$TMP/files/plain")" "$WANT_PLAIN")"

# The readers, lifted out of the files that hold them, so it is the shipped code that runs.
SYNC="$ROOT/claude-sync"; CST="$ROOT/tests/test-claude-sync.sh"; EGRESS="$ROOT/payload/skills/bug-bash/egress-setup.sh"
sed -n '/^_file_mtime(){/,/^}/p' "$RAT" > "$TMP/rat.sh"
sed -n '/^file_mtime(){/,/^}/p;/^file_mtimes(){/,/^}/p' "$SYNC" > "$TMP/sync.sh"
sed -n '/^_suite_mtime(){/,/^}/p' "$CST" > "$TMP/cst.sh"
egress_line="$(grep -m1 'read -r owner mode <<<' "$EGRESS")"
{ printf '%s\n' 'egress_owner_mode() {' '  local d="$1" owner="" mode=""'
  printf '%s\n' "$egress_line"
  printf '%s\n' '  printf "%s %s\n" "$owner" "$mode"' '}'
} > "$TMP/egress.sh"
check "run-all-tests.sh's mtime reader was found" "$(grep -q '^_file_mtime(){' "$TMP/rat.sh" && echo ok || echo "not found")"
check "claude-sync's two mtime readers were found" "$(grep -q '^file_mtime(){' "$TMP/sync.sh" && grep -q '^file_mtimes(){' "$TMP/sync.sh" && echo ok || echo "not found")"
check "test-claude-sync.sh's own mtime reader was found" "$(grep -q '^_suite_mtime(){' "$TMP/cst.sh" && echo ok || echo "not found")"
check "egress-setup.sh's owner and mode read was found" "$([ -n "$egress_line" ] && echo ok || echo "not found")"

# Runs <function> <args> from <definitions> with <bin> first on PATH (none for the real stat),
# logging every stat call the stand ins see to $CALLS.
CALLS="$TMP/calls"
run_reader() { # <bin or ""> <definitions> <function> [args...]
  local bin="$1" defs="$2"; shift 2
  : > "$CALLS"
  if [ -n "$bin" ]; then
    STAT_CALLS="$CALLS" PATH="$bin:$PATH" bash -c '. "$1"; shift; "$@"' _ "$defs" "$@"
  else
    bash -c '. "$1"; shift; "$@"' _ "$defs" "$@"
  fi
}
first_call() { head -1 "$CALLS" | cut -c1-2; }
asked_bsd() { grep -q '^-f' "$CALLS" && echo yes || echo no; }

for flavour in gnu bsd real; do
  case "$flavour" in gnu) bin="$GNUBIN" ;; bsd) bin="$BSDBIN" ;; real) bin="" ;; esac
  for r in "rat.sh _file_mtime" "sync.sh file_mtime" "cst.sh _suite_mtime"; do
    defs="${r%% *}"; fn="${r#* }"
    got="$(run_reader "$bin" "$TMP/$defs" "$fn" "$TMP/files/plain")"
    check "$fn ($defs) reads the mtime under the $flavour stat" "$(eq "$got" "$WANT_PLAIN")"
    got="$(run_reader "$bin" "$TMP/$defs" "$fn" "$TMP/files/not-there" 2>/dev/null)"
    check "$fn ($defs) says nothing for a path that is not there, under the $flavour stat" "$(eq "$got" "")"
    case "$flavour" in
      gnu) run_reader "$bin" "$TMP/$defs" "$fn" "$TMP/files/plain" >/dev/null
           check "$fn ($defs) never asks BSD's -f when GNU's -c answers" "$(eq "$(asked_bsd)" no)" ;;
      bsd) run_reader "$bin" "$TMP/$defs" "$fn" "$TMP/files/plain" >/dev/null
           check "$fn ($defs) asks GNU's -c first" "$(eq "$(first_call)" "-c")" ;;
    esac
  done

  # claude-sync's batch reader: one stat for every path, and a name with a space in it kept whole.
  got="$(printf '%s\n%s\n' "$TMP/files/plain" "$TMP/files/with space" | STAT_CALLS="$CALLS" PATH="${bin:+$bin:}$PATH" bash -c ': > "$1"; . "$2"; file_mtimes' _ "$CALLS" "$TMP/sync.sh")"
  check "file_mtimes reads every mtime in one go under the $flavour stat" \
    "$(eq "$got" "$(printf '%s\t%s\n%s\t%s' "$WANT_PLAIN" "$TMP/files/plain" "$WANT_SPACE" "$TMP/files/with space")")"
  case "$flavour" in
    gnu) check "file_mtimes asks GNU's -c and never BSD's -f under the GNU stat" "$(eq "$(asked_bsd)" no)"
         check "and reads both paths in one batch, not one stat each" "$([ "$(grep -c -- "$TMP/files/" "$CALLS")" = 1 ] && echo ok || echo "calls: $(tr '\n' '|' < "$CALLS")")" ;;
    bsd) check "file_mtimes asks GNU's -c first under the BSD stat" "$(eq "$(first_call)" "-c")"
         check "and then reads both paths in one BSD batch, not one stat each" "$([ "$(grep -c -- "$TMP/files/" "$CALLS")" = 1 ] && echo ok || echo "calls: $(tr '\n' '|' < "$CALLS")")" ;;
  esac

  got="$(run_reader "$bin" "$TMP/egress.sh" egress_owner_mode "$TMP/owned" 2>/dev/null)"
  check "egress-setup.sh's owner and mode read answers under the $flavour stat" "$(eq "$got" "$WANT_OWNED")"
done

# The GNU stand in catches the defect it is here for: egress-setup.sh's read as it was before
# #2003, BSD's -f alone, answers with the file system block's first words rather than an owner.
printf '%s\n' 'old_owner_mode() {' '  local d="$1" owner="" mode=""' \
  "  read -r owner mode <<< \"\$($BSD '%Su %Lp' \"\$d\")\"" \
  '  printf "%s %s\n" "$owner" "$mode"' '}' > "$TMP/old-egress.sh"
check "under the BSD stand in the old read answers, so the next check is about GNU" "$(eq "$(run_reader "$BSDBIN" "$TMP/old-egress.sh" old_owner_mode "$TMP/owned")" "$WANT_OWNED")"
old="$(run_reader "$GNUBIN" "$TMP/old-egress.sh" old_owner_mode "$TMP/owned" 2>/dev/null)"
check "under the GNU stand in the old BSD first read answers wrongly, as it would on Linux" \
  "$([ "$old" != "$WANT_OWNED" ] && echo ok || echo "it answered correctly, so the stand in proves nothing")"

finish
