#!/usr/bin/env bash
# Tests for lib/install-hook-libs.py, the one way a suite installs Python, shell and JavaScript
# (#2298) hook helpers into a
# scratch home or any folder standing in for hooks/lib (claude-config#2138), and for
# lib/hand-written-lib-list.py, the scan that fails a suite copying one by hand instead (#2147).
# A hand written list misses the module a helper starts importing, and the copy then fails only on
# a Mac whose real install is not there to hide the gap (#2118 made sleep-report.py import
# repo_slug, and each list had to learn repo_slug.py by hand).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$DIR/lib/install-hook-libs.py"
SCAN="$DIR/lib/hand-written-lib-list.py"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/hand-written-lib-list.XXXXXXXX")" || TMPROOT=""
[ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] || { echo "FAIL: could not make a scratch folder"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
check_eq() { if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }
says() { if [[ "$2" == *"$1"* ]]; then echo yes; else echo "no: $2"; fi; }   # $1 = text  $2 = output

# ---- the install ----
# Naming sleep-report.py alone installs the repo_slug it imports (#2138).
said="$(python3 "$INSTALL" "$DIR/lib" "$TMPROOT/lib" sleep-report.py 2>&1)"; rc=$?
check_eq "#2138 the install brings the modules a named helper imports" "0 repo_slug.py sleep-report.py " \
  "$rc $(ls "$TMPROOT/lib" | tr '\n' ' ')${said:+ said: $said}"
# A helper importing a module nobody has stops the install with that module named.
mkdir -p "$TMPROOT/src"
printf 'import no_such_hook_module_2138\n' > "$TMPROOT/src/needs-missing.py"
said="$(python3 "$INSTALL" "$TMPROOT/src" "$TMPROOT/lib2" needs-missing.py 2>&1)"; rc=$?
check_eq "#2138 the install refuses a helper that imports a module nobody has, naming it" \
  "1 yes" "$rc $(says "needs-missing.py imports no_such_hook_module_2138" "$said")"
# A helper loaded by its path, never imported, stays out unless it is named, so a suite can still
# build a folder missing one on purpose: shell_code_lines.py loads shell-words.py that way.
said="$(python3 "$INSTALL" "$DIR/lib" "$TMPROOT/noreader" hand-written-lib-list.py 2>&1)"; rc=$?
check_eq "#2147 the install follows imports, source lines and requires only, so a helper loaded by its path is left out" \
  "0 hand-written-lib-list.py shell_code_lines.py " "$rc $(ls "$TMPROOT/noreader" | tr '\n' ' ')${said:+ said: $said}"

# ---- the install follows what a shell helper sources (#2204) ----
# A shell helper sourcing another beside it brings it, through each way the helpers name their own
# folder, and on through what that one sources. A `.` in a comment, a heredoc, or jq text in quotes
# is not a source line and brings nothing.
mkdir -p "$TMPROOT/shsrc"
cat > "$TMPROOT/shsrc/top.sh" <<'TOP'
#!/usr/bin/env bash
_T_LIB="${BASH_SOURCE[0]%/*}"; [ "$_T_LIB" != "${BASH_SOURCE[0]}" ] || _T_LIB=.
_T_LIB="$(cd "${_T_LIB:-/}" && pwd)"
. "$_T_LIB/by-var.sh" 2>/dev/null || { echo "top: by-var.sh is missing" >&2; return 1; }
. "${BASH_SOURCE[0]%/*}/by-strip.sh"
declare -F x >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/by-dirname.sh"
f() {
  local _a="" _reader="$_T_LIB/by-reader.sh"
  if [ -f "$_reader" ] && . "$_reader" 2>/dev/null; then :; fi
  st="$( . "$_T_LIB/in-subst.sh" 2>/dev/null && echo ok )"
  if . "$_T_LIB/after-if.sh" 2>/dev/null; then :; fi
  _a=. ; n="$(grep -c . "$_reader")"
}
# . "$_T_LIB/in-comment.sh" is what this used to say
jq -r 'if . == 1 then . else "x" end' </dev/null
cat > "$HOME/stand-in.sh" <<'IN'
. "$_T_LIB/in-heredoc.sh"
IN
TOP
printf '#!/usr/bin/env bash\n_C="${BASH_SOURCE[0]%%/*}"\n. "$_C/chained.sh"\n' > "$TMPROOT/shsrc/by-var.sh"
for f in by-strip by-dirname by-reader in-subst after-if chained in-comment in-heredoc unrelated; do
  printf '#!/usr/bin/env bash\n: %s\n' "$f" > "$TMPROOT/shsrc/$f.sh"
done
said="$(python3 "$INSTALL" "$TMPROOT/shsrc" "$TMPROOT/shdest" top.sh 2>&1)"; rc=$?
check_eq "#2204 the install brings every helper a shell helper sources beside it, and what those source, and nothing named only in a comment, a heredoc, a quoted string, a value of . or a grep pattern" \
  "0 after-if.sh by-dirname.sh by-reader.sh by-strip.sh by-var.sh chained.sh in-subst.sh top.sh " \
  "$rc $(ls "$TMPROOT/shdest" | tr '\n' ' ')${said:+ said: $said}"
# A source line whose path cannot be resolved to a file beside the helper stops the install, naming
# the helper, its line and the path, never skipped in silence.
mkdir -p "$TMPROOT/shbad"
printf '#!/usr/bin/env bash\n. "$HOME/.somewhere/else.sh"\n' > "$TMPROOT/shbad/elsewhere.sh"
said="$(python3 "$INSTALL" "$TMPROOT/shbad" "$TMPROOT/shbaddest" elsewhere.sh 2>&1)"; rc=$?
check_eq "#2204 the install refuses a source line it cannot resolve, naming the helper, the line and the path" \
  "1 yes" "$rc $(says 'elsewhere.sh line 2 sources "$HOME/.somewhere/else.sh", which could not be resolved to a file beside it' "$said")"
# A source line naming a file beside the helper that the source folder does not have stops it too.
printf '#!/usr/bin/env bash\n. "${BASH_SOURCE[0]%%/*}/no-such-2204.sh"\n' > "$TMPROOT/shbad/needs-gone.sh"
said="$(python3 "$INSTALL" "$TMPROOT/shbad" "$TMPROOT/shbaddest2" needs-gone.sh 2>&1)"; rc=$?
check_eq "#2204 the install refuses a helper sourcing a file its folder does not have, naming it" \
  "1 yes" "$rc $(says "needs-gone.sh line 2 sources no-such-2204.sh, which $TMPROOT/shbad does not have" "$said")"
# The real helpers: merge-target.sh sources six others, directly or through them, and every one arrives with it.
# this-mac.sh joined them with claude-config#2561, when the ledger's Mac name moved to that one helper.
said="$(python3 "$INSTALL" "$DIR/lib" "$TMPROOT/mt" merge-target.sh 2>&1)"; rc=$?
check_eq "#2204 #2561 installing merge-target.sh brings the six helpers it sources" \
  "0 ai-review-common.sh gh-poll.sh hook-notice.sh merge-target.sh push-scope.sh this-mac.sh whole-number.sh " \
  "$rc $(ls "$TMPROOT/mt" | tr '\n' ' ')${said:+ said: $said}"
# Every shell helper in lib/ installs on its own: each source line in every one resolves.
every_sh="$(cd "$DIR/lib" && ls -- *.sh)"
said="$(cd "$DIR/lib" && python3 "$INSTALL" "$DIR/lib" "$TMPROOT/allsh" $every_sh 2>&1)"; rc=$?
check_eq "#2204 every source line in every shell helper in lib/ resolves" "0|" "$rc|$said"

# ---- the install follows what a JavaScript helper requires (#2298) ----
# A require naming a file beside the helper brings it, in each spelling a helper uses (a relative
# path with or without .js, path.join(__dirname, ...), __dirname + "/..."), and on through what that
# one requires. A built in or package name, and a require in a comment or inside a quoted string,
# brings nothing.
mkdir -p "$TMPROOT/jssrc"
cat > "$TMPROOT/jssrc/top.js" <<'TOP'
const fs = require('fs');
const path = require("path");
const a = require('./by-relative');
const b = require("./by-relative-ext.js");
const c = require(path.join(__dirname, 'by-join.js'));
const d = require(__dirname + "/by-concat.js");
// const old = require('./in-line-comment.js');
/* const older = require('./in-block-comment.js');
   still the comment */
const s = "require('./in-string.js')";
const t = `require('./in-template.js')`;
const re = /it's "quoted"/; const g = require('./after-regex.js');
const half = d.length / 2; const h = require('./after-division.js');
TOP
printf "module.exports = require('./chained.js');\n" > "$TMPROOT/jssrc/by-relative.js"
for f in by-relative-ext by-join by-concat after-regex after-division chained in-line-comment in-block-comment in-string in-template unrelated; do
  printf 'module.exports = "%s";\n' "$f" > "$TMPROOT/jssrc/$f.js"
done
said="$(python3 "$INSTALL" "$TMPROOT/jssrc" "$TMPROOT/jsdest" top.js 2>&1)"; rc=$?
check_eq "#2298 the install brings every helper a JavaScript helper requires beside it (after a regular expression holding quotes, and after a division), and what those require, and nothing named only by a built in, a comment or a quoted string" \
  "0 after-division.js after-regex.js by-concat.js by-join.js by-relative-ext.js by-relative.js chained.js top.js " \
  "$rc $(ls "$TMPROOT/jsdest" | tr '\n' ' ')${said:+ said: $said}"
# A relative require naming a file the source folder does not have stops the install, naming it.
mkdir -p "$TMPROOT/jsbad"
printf "const x = require('./no-such-2298');\n" > "$TMPROOT/jsbad/needs-gone.js"
said="$(python3 "$INSTALL" "$TMPROOT/jsbad" "$TMPROOT/jsbaddest" needs-gone.js 2>&1)"; rc=$?
check_eq "#2298 the install refuses a helper requiring a file its folder does not have, naming it" \
  "1 yes" "$rc $(says "needs-gone.js line 1 requires ./no-such-2298, which $TMPROOT/jsbad does not have" "$said")"
# A require whose path is not written out, or reaches outside the folder, cannot be followed, so it
# stops the install with its line, never skipped in silence.
printf "const m = require(process.env.SOME_MODULE);\n" > "$TMPROOT/jsbad/dynamic.js"
said="$(python3 "$INSTALL" "$TMPROOT/jsbad" "$TMPROOT/jsbaddest2" dynamic.js 2>&1)"; rc=$?
check_eq "#2298 the install refuses a require whose path it cannot read, naming the helper and the line" \
  "1 yes" "$rc $(says "dynamic.js line 1 requires process.env.SOME_MODULE, which could not be resolved to a file beside it" "$said")"
printf "const m = require('../elsewhere.js');\n" > "$TMPROOT/jsbad/outside.js"
said="$(python3 "$INSTALL" "$TMPROOT/jsbad" "$TMPROOT/jsbaddest3" outside.js 2>&1)"; rc=$?
check_eq "#2298 the install refuses a require reaching outside the helper's folder, naming it" \
  "1 yes" "$rc $(says "outside.js line 1 requires ../elsewhere.js, which could not be resolved to a file beside it" "$said")"
# The real helpers: changelog-entry.test.js requires changelog-entry.js through path.join(__dirname).
said="$(python3 "$INSTALL" "$DIR/lib" "$TMPROOT/ce" changelog-entry.test.js 2>&1)"; rc=$?
check_eq "#2298 installing changelog-entry.test.js brings the changelog-entry.js it requires" \
  "0 changelog-entry.js changelog-entry.test.js " \
  "$rc $(ls "$TMPROOT/ce" | tr '\n' ' ')${said:+ said: $said}"
# Every JavaScript helper in lib/ installs on its own: each require in every one resolves.
every_js="$(cd "$DIR/lib" && ls -- *.js)"
said="$(cd "$DIR/lib" && python3 "$INSTALL" "$DIR/lib" "$TMPROOT/alljs" $every_js 2>&1)"; rc=$?
check_eq "#2298 every require in every JavaScript helper in lib/ resolves" "0|" "$rc|$said"

# ---- the scan refuses when it cannot read the suites ----
# Without lib/shell-words.py no line can be told from a heredoc's body, so nothing is judged, which
# is said, and never reported as a tree with no hand written list.
out="$(printf 'payload/hooks/test-x.sh\n' | python3 "$TMPROOT/noreader/hand-written-lib-list.py" --root "$TMPROOT" 2>&1)"; rc=$?
check_eq "#2147 without lib/shell-words.py the scan refuses, naming it" "2 yes" \
  "$rc $(says "lib/shell-words.py could not be loaded" "$out")"

# ---- the scan sees each hand written copy, and nothing else ----
mkdir -p "$TMPROOT/scan/payload/hooks"
cat > "$TMPROOT/scan/payload/hooks/test-probe.sh" <<'PROBE'
#!/usr/bin/env bash
cp "$DIR/lib/sleep-report.py" "$H/lib/"
PY="$DIR/lib/repo_slug.py"
cp "$PY" "$H/lib/repo_slug.py"
mkdir -p "$H/lib"; cp -p "$(dirname "$PY")/session_registry.py" "$H/lib/"
cp "$(dirname "$SCRIPT")/payload/hooks/lib/work-names.py" "$1/payload/hooks/lib/work-names.py"
cp "$DIR/lib/push-scope.sh" "$H/lib/"
SD="$DIR/lib/suite-deadline.sh"; cp "$SD" "$DIR/lib/kill-tree.sh" "$H/lib/"
cp -R "$DIR/lib" "$H/lib"
cp "$DIR/sleep-report.py" "$H/"
cp "$WORK/stand-in.py" "$H/lib/sleep-report.py"
# cp "$DIR/lib/sleep-report.py" "$H/lib/" is what this used to say
printf 'cp "$DIR/lib/sleep-report.py" x\n' > "$H/fixture.sh"
cat > "$H/stand-in.sh" <<'IN'
cp "$DIR/lib/sleep-report.py" "$H/lib/"
IN
X="a fixture spanning lines:
cp "$DIR/lib/sleep-report.py" "$H/lib/"
"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$H/lib" sleep-report.py
PROBE
cp "$TMPROOT/scan/payload/hooks/test-probe.sh" "$TMPROOT/scan/payload/hooks/probe-helper.sh"
probe="$(printf 'payload/hooks/test-probe.sh\npayload/hooks/probe-helper.sh\n' | python3 "$SCAN" --root "$TMPROOT/scan" 2>&1)"; probe_rc=$?
probe_lines="$(printf '%s\n' "$probe" | awk -F': ' 'NF { split($1, p, ":"); printf "%s=%s ", p[2], $2 }')"
check_eq "#2147 #2204 the scan sees each hand written copy of a Python or shell helper (by path, through a variable, through dirname, from a checkout), and not a whole lib folder, a hook, a stand in written under a helper's name, a comment, a printf fixture, a heredoc, a quoted string, the install, or a file that is not a suite" \
  "1 2=sleep-report.py 4=repo_slug.py 5=session_registry.py 6=work-names.py 7=push-scope.sh 8=suite-deadline.sh kill-tree.sh " "$probe_rc $probe_lines"
printf '#!/usr/bin/env bash\npython3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$H/lib" sleep-report.py\n' > "$TMPROOT/scan/payload/hooks/test-clean.sh"
clean="$(printf 'payload/hooks/test-clean.sh\n' | python3 "$SCAN" --root "$TMPROOT/scan" 2>&1)"; clean_rc=$?
check_eq "#2147 control: a suite installing through lib/install-hook-libs.py passes in silence" "0|" "$clean_rc|$clean"
# A JavaScript helper copied by hand is a list too (#2298): workflow-syntax.js and
# dev-update-registry.js are installed beside the shell and Python ones, and a list naming them goes
# stale the first time one requires another. A copy of a .js file outside lib/ is not a helper.
cat > "$TMPROOT/scan/payload/hooks/test-probe-js.sh" <<'PROBE'
#!/usr/bin/env bash
cp "$DIR/lib/workflow-syntax.js" "$H/lib/"
READER="$ROOT/payload/hooks/lib/dev-update-registry.js"
cp "$READER" "$H/lib/dev-update-registry.js"
cp "$(dirname "$READER")/changelog-entry.js" "$H/lib/"
cp "$ROOT/tools/typescript/package.json" "$H/"
cp "$WORK/stand-in.js" "$H/lib/workflow-syntax.js"
PROBE
probe="$(printf 'payload/hooks/test-probe-js.sh\n' | python3 "$SCAN" --root "$TMPROOT/scan" 2>&1)"; probe_rc=$?
probe_lines="$(printf '%s\n' "$probe" | awk -F': ' 'NF { split($1, p, ":"); printf "%s=%s ", p[2], $2 }')"
check_eq "#2298 the scan sees each hand written copy of a JavaScript helper (by path, through a variable, through dirname), and not a file outside lib/ or a stand in written under a helper's name" \
  "1 2=workflow-syntax.js 4=dev-update-registry.js 5=changelog-entry.js " "$probe_rc $probe_lines"
unr="$(printf 'payload/hooks/test-clean.sh\npayload/hooks/test-missing.sh\n' | python3 "$SCAN" --root "$TMPROOT/scan" 2>&1)"; unr_rc=$?
case "$unr" in *"payload/hooks/test-missing.sh could not be read"*) unr_named=named ;; *) unr_named="unnamed: $unr" ;; esac
check_eq "#2147 a listed suite that cannot be read stops the scan with exit 2 and is named, never skipped" "2 named" "$unr_rc $unr_named"

# ---- and no suite anywhere copies a Python, shell or JavaScript helper by hand ----
# Every suite in the repository, read from the files git ships rather than a list of names (L96).
SELF_TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
FILES="$(bash "$DIR/lib/repo-files.sh" "$SELF_TOP" 2>/dev/null || true)"
if [ -n "$SELF_TOP" ] && [ -f "$SELF_TOP/claude-sync" ] && [ -n "$FILES" ]; then
  found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$SELF_TOP" 2>&1)"; found_rc=$?
  check_eq "#2147 #2204 #2298 no suite copies a Python, shell or JavaScript hook helper by hand; each installs through lib/install-hook-libs.py" \
    "0" "$found_rc${found:+
$found}"
else
  echo "SUITE-PART-UNMEASURED this copy is not in a claude-config checkout, so its suites were not scanned for a hand written helper list"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
