#!/usr/bin/env bash
# rtk's excluded commands travel with the shared config (claude-config#1427).
#
# rtk reads `[hooks] exclude_commands` from its own machine local config, which the sync did not
# carry. On 2026-10-20 the personal MacBook listed grep, rg, egrep, fgrep, cat, head and tail there
# and the work MacBook evidently listed none, so the two Macs rewrote different commands and nothing
# recorded or checked it (found by the #1419 builder, PR #1423). The list now lives in
# payload/rtk-exclude-commands.txt, a pull writes it into rtk's config on each Mac without touching
# any other key, and status and verify say when a Mac's installed list differs.
#
# Every case runs against a fixture: CLAUDE_HOME is a throwaway directory and rtk is a stub whose
# `config` answers with a throwaway config path, so nothing here can reach the real
# ~/Library/Application Support/rtk. Where the real rtk is installed, block 11 runs it against
# a throwaway HOME to prove rtk itself reads what the pull wrote.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-sync"
. "$HERE/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2.. = a command that succeeds when the check holds
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has(){ grep -qF -- "$2" <<< "$1"; }       # $1 = text  $2 = a literal it must contain
lacks(){ ! grep -qF -- "$2" <<< "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rtk-exclusions.XXXXXX")"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# status reads the machine as well as the fixture: the process table (suites left running, listed
# by command line) and the scratch under the system temp directory. A fixture run must judge an
# empty table and its own scratch, or what else is running decides the answer (claude-config#1445,
# L463). Case 3c2 sets a table on purpose.
export SYNC_PS_FIXTURE="$WORK/ps-none"; : > "$SYNC_PS_FIXTURE"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"

# Whether output says anything about the shared list, judged by what only the list's own code
# prints: the status section's header, the list file every refusal and drift sentence names, the
# pull's applied line, and its backup line. A bare "rtk" also matches a suite's file name in the
# process table or another clone's hook suite record, which is the routine output of a busy Mac,
# not a statement about the list (claude-config#1445).
says_rtk_list(){
  has "$1" "--- rtk's excluded commands ---" || has "$1" "rtk-exclude-commands.txt" \
    || has "$1" "rtk config (" || has "$1" "rtk's config"
}
quiet_about_rtk_list(){ ! says_rtk_list "$1"; }

WANT_FILE_TEXT='# Commands rtk leaves alone on every Mac (claude-config#1427).
grep
rg
cat
'
# The list as rtk's config holds it after a pull, in the payload's own order.
WANT_LINE='exclude_commands = ["grep", "rg", "cat"]'

# A repo whose payload carries the list (or not, with an empty second argument).
mkrepo(){   # $1 = repo dir  $2 = the list file's text, or empty for no file
  mkdir -p "$1/payload"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$1/payload/rtk-exclude-commands.txt"
  return 0
}
# A stub rtk: `config` prints the line the real one prints and exits with whatever $dir/rc holds,
# so a case can play rtk failing to parse its file. Anything else it is asked exits 0 silently.
mkstub(){   # $1 = dir for the stub  $2 = the config path it reports
  mkdir -p "$1"
  cat > "$1/rtk" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = config ]; then
  echo "Config: $2"
  rc="\$(cat '$1/rc' 2>/dev/null || echo 0)"
  [ "\$rc" = 0 ] || echo "Error: TOML parse error at line 1, column 6" >&2
  exit "\$rc"
fi
exit 0
STUB
  chmod +x "$1/rtk"
}
pull(){   # $1 = home  $2 = repo  $3 = rtk binary (SYNC_RTK_BIN) -> output in OUT, exit status in PULL_RC
  OUT="$(CLAUDE_HOME="$1" SYNC_REPO="$2" SYNC_NO_GIT=1 SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_RTK_BIN="$3" bash "$SCRIPT" pull 2>&1)"
  PULL_RC=$?
}
status(){   # $1 = home  $2 = repo  $3 = rtk binary
  CLAUDE_HOME="$1" SYNC_REPO="$2" SYNC_NO_GIT=1 SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_NO_NOTIFY=1 SYNC_RTK_BIN="$3" bash "$SCRIPT" status 2>&1
}
# GNU stat first: on Linux `stat -f` reads the FILE SYSTEM and prints its own lines before failing on
# the format, so trying the BSD form first and falling back mixes both answers. macOS refuses `-c`
# outright with nothing on stdout, so the order is safe there.
mtime_of(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
cfg_dir(){ printf '%s/%s/Library/Application Support/rtk' "$WORK" "$1"; }

# ---- 1. A FRESH MAC: rtk installed, no config file yet. The pull writes one holding the list. ----
R1="$WORK/r1"; mkrepo "$R1" "$WANT_FILE_TEXT"
H1="$WORK/h1"; mkdir -p "$H1"
C1="$(cfg_dir m1)/config.toml"; mkstub "$WORK/stub1" "$C1"
pull "$H1" "$R1" "$WORK/stub1/rtk"; out1="$OUT"
check "fresh Mac: the pull succeeds" [ "$PULL_RC" -eq 0 ]
check "fresh Mac: rtk's config file is created" [ -f "$C1" ]
check "fresh Mac: it holds the list under [hooks]" grep -qxF '[hooks]' "$C1"
check "fresh Mac: with the payload's commands" grep -qxF "$WANT_LINE" "$C1"
check "fresh Mac: the pull says it wrote rtk's config" has "$out1" "rtk config ("
check "fresh Mac: and names the commands" has "$out1" "grep, rg, cat"
check "fresh Mac: no backup is made when there was no file to back up" [ ! -e "$C1.before-claude-sync" ]
check "fresh Mac: nothing about rtk lands inside the Claude config" [ -z "$(find "$H1" -name '*rtk*' -o -name '*before-claude-sync*' | grep -v '/hooks/')" ]

# A second pull with nothing new leaves the file and its mtime alone.
touch -t 202001010000 "$C1"; sum1="$(cksum < "$C1")"
pull "$H1" "$R1" "$WORK/stub1/rtk"; out1b="$OUT"
check "fresh Mac, second pull: the file is byte for byte" [ "$(cksum < "$C1")" = "$sum1" ]
check "fresh Mac, second pull: and not rewritten" [ "$(mtime_of "$C1")" -lt 1600000000 ]
check "fresh Mac, second pull: claims to have written nothing to rtk" lacks "$out1b" "rtk config"

# ---- 2. AN EXISTING CONFIG holding other keys and a different list: only the list changes. ----
R2="$R1"
H2="$WORK/h2"; mkdir -p "$H2"
D2="$(cfg_dir m2)"; C2="$D2/config.toml"; mkdir -p "$D2"; mkstub "$WORK/stub2" "$C2"
cat > "$C2" <<'TOML'
[tracking]
enabled = true
history_days = 90

[filters]
ignore_dirs = [
    ".git",
    "node_modules",
]

[hooks]
# kept by hand
exclude_commands = [
    "grep",
    "tail",
]
other_hook_key = "kept"

[limits]
grep_max_results = 200
TOML
cp "$C2" "$WORK/c2-original"
status2="$(status "$H2" "$R2" "$WORK/stub2/rtk")"
check "drift: status names rtk's excluded commands" has "$status2" "--- rtk's excluded commands ---"
check "drift: status names what this Mac holds" has "$status2" "grep, tail"
check "drift: status names what the shared list holds" has "$status2" "grep, rg, cat"
check "drift: status names the remedy" has "$status2" "claude-sync pull"
pull "$H2" "$R2" "$WORK/stub2/rtk"; out2="$OUT"
check "existing config: the pull succeeds" [ "$PULL_RC" -eq 0 ]
check "existing config: the list is now the payload's" grep -qxF "$WANT_LINE" "$C2"
check "existing config: the old multi line list is gone entirely" [ -z "$(grep -n '"tail"' "$C2")" ]
# Every other line is exactly as it was: drop the list (one line now, five before) from both and compare.
strip_list(){ awk '/^exclude_commands = \[/ { inlist = ($0 !~ /\]/); next } inlist { if ($0 ~ /\]/) inlist = 0; next } { print }' "$1"; }
check "existing config: every other key, comment and blank line is untouched" [ "$(strip_list "$C2")" = "$(strip_list "$WORK/c2-original")" ]
check "existing config: the original is kept beside rtk's config, outside the Claude config" cmp -s "$C2.before-claude-sync" "$WORK/c2-original"
check "existing config: the pull names the backup" has "$out2" "$C2.before-claude-sync"
status2b="$(status "$H2" "$R2" "$WORK/stub2/rtk")"
check "repaired: status says nothing about rtk once the lists agree" quiet_about_rtk_list "$status2b"

# A later difference is repaired too, and the FIRST backup is never overwritten: it is the original.
sed -i.tmp 's/^exclude_commands = .*/exclude_commands = ["head"]/' "$C2"; rm -f "$C2.tmp"
pull "$H2" "$R2" "$WORK/stub2/rtk"
check "drifted again: the next pull puts the list back" grep -qxF "$WANT_LINE" "$C2"
check "drifted again: the first backup still holds the original" cmp -s "$C2.before-claude-sync" "$WORK/c2-original"

# ---- 3. A CONFIG WITH NO [hooks] TABLE: the table is added, nothing else moves. ----
H3="$WORK/h3"; mkdir -p "$H3"
D3="$(cfg_dir m3)"; C3="$D3/config.toml"; mkdir -p "$D3"; mkstub "$WORK/stub3" "$C3"
printf '[tracking]\nenabled = true\n\n[limits]\ngrep_max_results = 200\n' > "$C3"
cp "$C3" "$WORK/c3-original"
pull "$H3" "$R1" "$WORK/stub3/rtk"
check "no [hooks] table: the list is written" grep -qxF "$WANT_LINE" "$C3"
check "no [hooks] table: under a [hooks] header" [ "$(awk '/^\[hooks\]$/ { h = 1; next } /^\[/ { h = 0 } h && /^exclude_commands/ { print "yes" }' "$C3")" = yes ]
check "no [hooks] table: the original lines are all still first, unchanged" [ "$(head -n "$(wc -l < "$WORK/c3-original")" "$C3")" = "$(cat "$WORK/c3-original")" ]

# ---- 3b. [hooks] WITHOUT THE KEY: the key goes under the header, the table's other keys stay. ----
H3B="$WORK/h3b"; mkdir -p "$H3B"
D3B="$(cfg_dir m3b)"; C3B="$D3B/config.toml"; mkdir -p "$D3B"; mkstub "$WORK/stub3b" "$C3B"
printf '[hooks]\nother_hook_key = "kept"\n\n[limits]\ngrep_max_results = 200\n' > "$C3B"
pull "$H3B" "$R1" "$WORK/stub3b/rtk"
check "[hooks] without the key: the key is added right under the header" [ "$(sed -n 2p "$C3B")" = "$WANT_LINE" ]
check "[hooks] without the key: the other lines are unchanged" [ "$(sed 2d "$C3B")" = "$(printf '[hooks]\nother_hook_key = "kept"\n\n[limits]\ngrep_max_results = 200')" ]

# ---- 3c. AN EMPTY SHARED LIST is a real list: rtk then leaves nothing alone. ----
R3C="$WORK/r3c"; mkrepo "$R3C" '# nothing excluded
'
H3C="$WORK/h3c"; mkdir -p "$H3C"
D3C="$(cfg_dir m3c)"; C3C="$D3C/config.toml"; mkdir -p "$D3C"; mkstub "$WORK/stub3c" "$C3C"
printf '[hooks]\nexclude_commands = ["tail"]\n' > "$C3C"
pull "$H3C" "$R3C" "$WORK/stub3c/rtk"
check "empty shared list: the installed list is emptied" grep -qxF 'exclude_commands = []' "$C3C"
check "empty shared list: and then reads as agreeing" quiet_about_rtk_list "$(status "$H3C" "$R3C" "$WORK/stub3c/rtk")"

# ---- 3c2. OTHER SECTIONS OF status MAY NAME rtk; only the list's own section is about the list. ----
# claude-config#1445: in a full run at load 166 two "says nothing about rtk" checks failed because
# status also lists this repo's suites left running, by command line, and a pile of them included
# tests/test-rtk-exclusions.sh. A process table holding nine such roots (more than the eight a pile
# starts at) is that machine, set rather than waited for.
{
  for p in 101 102 103 104 105 106 107 108 109; do
    printf '%s 1 00:13 bash /x/claude-config/tests/test-rtk-exclusions.sh\n' "$p"
  done
} > "$WORK/ps-rtk-pile"
pile2="$(SYNC_PS_FIXTURE="$WORK/ps-rtk-pile" CLAUDE_HOME="$H2" SYNC_REPO="$R2" SYNC_NO_GIT=1 SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_NO_NOTIFY=1 SYNC_RTK_BIN="$WORK/stub2/rtk" bash "$SCRIPT" status 2>&1)"
check "rtk suites piled up, control: status does list them by command line" has "$pile2" "tests/test-rtk-exclusions.sh"
check "rtk suites piled up: the agreeing list is still not reported" quiet_about_rtk_list "$pile2"

# ---- 3d. hooks SET AS A DOTTED KEY is not rewritten: a second definition would break rtk. ----
H3D="$WORK/h3d"; mkdir -p "$H3D"
D3D="$(cfg_dir m3d)"; C3D="$D3D/config.toml"; mkdir -p "$D3D"; mkstub "$WORK/stub3d" "$C3D"
printf 'hooks.exclude_commands = ["tail"]\n' > "$C3D"; sum3d="$(cksum < "$C3D")"
pull "$H3D" "$R1" "$WORK/stub3d/rtk"; out3d="$OUT"
check "dotted hooks key: left byte for byte" [ "$(cksum < "$C3D")" = "$sum3d" ]
check "dotted hooks key: said, naming the form" has "$out3d" "dotted key"

# ---- 3e. A WRITE rtk CANNOT READ BACK is undone: the original goes back, byte for byte. ----
# The stub parses the file the first time it is asked and refuses it every time after, which is what
# a write that produced a file rtk rejects looks like from here.
H3E="$WORK/h3e"; mkdir -p "$H3E"
D3E="$(cfg_dir m3e)"; C3E="$D3E/config.toml"; mkdir -p "$D3E"; mkstub "$WORK/stub3e" "$C3E"
cat > "$WORK/stub3e/rtk" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = config ]; then
  echo "Config: $C3E"
  n="\$(cat '$WORK/stub3e/count' 2>/dev/null || echo 0)"; echo "\$((n + 1))" > '$WORK/stub3e/count'
  [ "\$n" = 0 ] && exit 0
  echo "Error: TOML parse error at line 3" >&2; exit 1
fi
exit 0
STUB
printf '[hooks]\nexclude_commands = ["tail"]\n' > "$C3E"; sum3e="$(cksum < "$C3E")"
pull "$H3E" "$R1" "$WORK/stub3e/rtk"; out3e="$OUT"
check "unreadable after the write: the pull still succeeds" [ "$PULL_RC" -eq 0 ]
check "unreadable after the write: the original is back byte for byte" [ "$(cksum < "$C3E")" = "$sum3e" ]
check "unreadable after the write: said, with rtk's error" has "$out3e" "put back exactly as it was"
check "unreadable after the write: and claims no write in the summary" lacks "$out3e" "rtk config ("

# ---- 4. RTK NOT INSTALLED: said, and the pull is not failed by it. ----
H4="$WORK/h4"; mkdir -p "$H4"
pull "$H4" "$R1" "$WORK/no-rtk-here/rtk"; out4="$OUT"
check "no rtk: the pull still succeeds" [ "$PULL_RC" -eq 0 ]
check "no rtk: it says rtk is not installed" has "$out4" "rtk is not installed"
check "no rtk: status says the same rather than nothing" has "$(status "$H4" "$R1" "$WORK/no-rtk-here/rtk")" "rtk is not installed"

# ---- 5. A CONFIG RTK CANNOT PARSE: refused, reported, left byte for byte. ----
H5="$WORK/h5"; mkdir -p "$H5"
D5="$(cfg_dir m5)"; C5="$D5/config.toml"; mkdir -p "$D5"; mkstub "$WORK/stub5" "$C5"
printf 'this is [[ not toml\n' > "$C5"; echo 1 > "$WORK/stub5/rc"
sum5="$(cksum < "$C5")"
pull "$H5" "$R1" "$WORK/stub5/rtk"; out5="$OUT"
check "malformed: the pull still succeeds" [ "$PULL_RC" -eq 0 ]
check "malformed: the file is left byte for byte" [ "$(cksum < "$C5")" = "$sum5" ]
check "malformed: no backup is written either" [ ! -e "$C5.before-claude-sync" ]
check "malformed: the pull says rtk cannot read it" has "$out5" "rtk cannot read"
check "malformed: and names the file" has "$out5" "$C5"
check "malformed: and passes on rtk's own error" has "$out5" "TOML parse error"
check "malformed: status reports it too" has "$(status "$H5" "$R1" "$WORK/stub5/rtk")" "rtk cannot read"

# ---- 6. A CONFIG THAT CANNOT BE READ AT ALL: refused, reported, left alone. ----
H6="$WORK/h6"; mkdir -p "$H6"
D6="$(cfg_dir m6)"; C6="$D6/config.toml"; mkdir -p "$D6"; mkstub "$WORK/stub6" "$C6"
printf '[hooks]\nexclude_commands = ["tail"]\n' > "$C6"; chmod 000 "$C6"
if [ -r "$C6" ]; then
  echo "SUITE-PART-UNMEASURED this run can read a mode 000 file (running as root?), so the unreadable case was not measured"
else
  pull "$H6" "$R1" "$WORK/stub6/rtk"; out6="$OUT"
  check "unreadable: the pull still succeeds" [ "$PULL_RC" -eq 0 ]
  check "unreadable: the pull says it could not be read" has "$out6" "could not be read"
  check "unreadable: and names the file" has "$out6" "$C6"
  chmod 600 "$C6"
  check "unreadable: the file was not replaced" [ "$(cat "$C6")" = "$(printf '[hooks]\nexclude_commands = ["tail"]')" ]
fi

# ---- 7. A SHARED LIST THAT IS NOT A LIST OF COMMAND NAMES is refused whole, by line. ----
R7="$WORK/r7"; mkrepo "$R7" 'grep
rm -rf /
'
H7="$WORK/h7"; mkdir -p "$H7"
C7="$(cfg_dir m7)/config.toml"; mkstub "$WORK/stub7" "$C7"
pull "$H7" "$R7" "$WORK/stub7/rtk"; out7="$OUT"
check "bad shared list: the pull still succeeds" [ "$PULL_RC" -eq 0 ]
check "bad shared list: nothing is written" [ ! -e "$C7" ]
check "bad shared list: it says which line is refused" has "$out7" "rm -rf /"

# ---- 8. NO SHARED LIST AT ALL: nothing is written and nothing is said. ----
R8="$WORK/r8"; mkrepo "$R8" ''
H8="$WORK/h8"; mkdir -p "$H8"
C8="$(cfg_dir m8)/config.toml"; mkstub "$WORK/stub8" "$C8"
pull "$H8" "$R8" "$WORK/stub8/rtk"; out8="$OUT"
check "no shared list: nothing is written" [ ! -e "$C8" ]
check "no shared list: nothing is said about rtk" quiet_about_rtk_list "$out8"

# ---- 9. A FIXTURE HOME WITH NO rtk NAMED never reaches this Mac's real rtk config. ----
# CLAUDE_HOME is not this user's ~/.claude, so the real rtk (and the real config it would report)
# is out of bounds: the only way in is SYNC_RTK_BIN, named explicitly.
H9="$WORK/h9"; mkdir -p "$H9"
out9="$(CLAUDE_HOME="$H9" SYNC_REPO="$R1" SYNC_NO_GIT=1 SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1)"
check "fixture home: nothing is said about rtk" quiet_about_rtk_list "$out9"

# ---- 10. verify FAILS while this Mac's list differs, naming the remedy, and passes once repaired. ----
VB="$WORK/v-bare.git"; git init -q --bare -b main "$VB"
VA="$WORK/v-repoA"; git clone -q "$VB" "$VA" 2>/dev/null
VBR="$WORK/v-repoB"
VHA="$WORK/v-homeA"; VHB="$WORK/v-homeB"; mkdir -p "$VHA" "$VHB"
echo '{"hooks":{}}' > "$VHA/settings.json"; echo '{"hooks":{}}' > "$VHB/settings.json"
mkdir -p "$VA/payload"; printf '%s' "$WANT_FILE_TEXT" > "$VA/payload/rtk-exclude-commands.txt"
git -C "$VA" add payload >/dev/null 2>&1
git -C "$VA" -c user.email=t@t -c user.name=t commit -qm 'shared rtk list' >/dev/null 2>&1
git -C "$VA" push -q origin HEAD:main >/dev/null 2>&1
git clone -q "$VB" "$VBR" 2>/dev/null
CA="$(cfg_dir va)/config.toml"; mkstub "$WORK/stubva" "$CA"
vsync(){ CLAUDE_HOME="$1" SYNC_REPO="$2" SYNC_HOSTNAME="$3" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_RTK_BIN="$4" bash "$SCRIPT" sync >/dev/null 2>&1; }
vverify(){ CLAUDE_HOME="$VHA" SYNC_REPO="$VA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 SYNC_RTK_BIN="$WORK/stubva/rtk" bash "$SCRIPT" verify 2>&1; }
vsync "$VHA" "$VA" macA "$WORK/stubva/rtk"
vsync "$VHB" "$VBR" macB "$WORK/no-rtk-here/rtk"
vsync "$VHA" "$VA" macA "$WORK/stubva/rtk"
outv1="$(vverify)"; rcv1=$?
check "verify control: the fixture's two Macs agree (output: $outv1)" has "$outv1" "Verified"
check "verify control: and verify passes" [ "$rcv1" -eq 0 ]
sed -i.tmp 's/^exclude_commands = .*/exclude_commands = ["tail"]/' "$CA"; rm -f "$CA.tmp"
outv2="$(vverify)"; rcv2=$?
check "verify: fails while this Mac's rtk list differs" [ "$rcv2" -ne 0 ]
check "verify: names rtk's excluded commands" has "$outv2" "rtk"
check "verify: names what this Mac holds" has "$outv2" "tail"
check "verify: names the remedy" has "$outv2" "claude-sync pull"
check "verify: and does not call the config Verified" lacks "$outv2" "Verified:"

# ---- 11. THE REAL rtk, where installed, reads what a pull wrote (L82, L404). ----
REAL_RTK="$(command -v rtk 2>/dev/null || true)"
if [ -z "$REAL_RTK" ]; then
  echo "SUITE-PART-UNMEASURED rtk is not installed here, so whether rtk itself honours the written list was not measured. Everything above used a stub."
else
  RH="$WORK/real-home"; mkdir -p "$RH"
  mkdir -p "$WORK/realwrap"
  printf '#!/usr/bin/env bash\nHOME=%q exec %q "$@"\n' "$RH" "$REAL_RTK" > "$WORK/realwrap/rtk"; chmod +x "$WORK/realwrap/rtk"
  RC_CFG="$RH/Library/Application Support/rtk/config.toml"
  # Control first: under this empty HOME rtk DOES rewrite a bare grep, so a pass below is the list.
  ctl="$("$WORK/realwrap/rtk" rewrite 'grep x f' 2>/dev/null)"
  check "real rtk control: an empty HOME rewrites a bare grep (got: $ctl)" [ -n "$ctl" ]
  HR="$WORK/hr"; mkdir -p "$HR"
  pull "$HR" "$R1" "$WORK/realwrap/rtk"
  where="$("$WORK/realwrap/rtk" config 2>/dev/null | sed -n 1p)"
  check "real rtk: reports the config the pull wrote" [ "$where" = "Config: $RC_CFG" ]
  check "real rtk: parses it" "$WORK/realwrap/rtk" config >/dev/null 2>&1
  after="$("$WORK/realwrap/rtk" rewrite 'grep x f' 2>/dev/null)"
  check "real rtk: no longer rewrites grep (got: $after)" [ -z "$after" ]
  # And a genuinely malformed file, judged by rtk's own parser rather than the stub.
  printf 'this is [[ not toml\n' > "$RC_CFG"; summ="$(cksum < "$RC_CFG")"
  pull "$HR" "$R1" "$WORK/realwrap/rtk"; outm="$OUT"
  check "real rtk, malformed: left byte for byte" [ "$(cksum < "$RC_CFG")" = "$summ" ]
  check "real rtk, malformed: reported" has "$outm" "rtk cannot read"
fi

# ---- 12. THIS REPOSITORY'S shared list is the one the personal MacBook carried on 2026-10-20. ----
REPO_LIST="$HERE/../payload/rtk-exclude-commands.txt"
check "the repository carries the shared list" [ -f "$REPO_LIST" ]
check "and it holds grep, rg, egrep, fgrep, cat, head and tail" [ "$(grep -vE '^[[:space:]]*(#|$)' "$REPO_LIST" 2>/dev/null | tr '\n' ' ')" = "grep rg egrep fgrep cat head tail " ]

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
