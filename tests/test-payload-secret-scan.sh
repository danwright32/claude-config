#!/usr/bin/env bash
# The payload this repository ships passes claude-sync's own secret scan.
#
# A send runs scan_secrets over everything it is about to publish and refuses outright on a hit,
# so one token SHAPED placeholder blocks every sync from every Mac until somebody notices. That
# happened when claude-config#675 shipped `"token": "REPLACE_BY_RUNNING_tracker.sh_new-token"` in
# skills/tracker/config.example.json: a key named token, then 24 or more identifier characters,
# which is exactly what the scan's assignment pattern looks for. Nothing ran the scan before
# merge; it first ran on the next send.
#
# So this runs the REAL function, cut out of claude-sync by name, never a copy of its patterns,
# which would drift from the scan it stands for (L41). It reads the repository's real
# .secret-allowlist, as the send does, over every file git would carry under payload/ (tracked,
# plus untracked files that are not ignored, so the file just written is judged too, L456).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SCRIPT="$ROOT/claude-sync"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-secretscan-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-payload-secret-scan: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The function and the helper it calls, cut from claude-sync by name. die is replaced so a refusal
# is reported here instead of ending this suite (and without the notification the real one posts).
SCAN_SRC="$(sed -n '/^scan_secrets(){/,/^}/p' "$SCRIPT")"
BLANK_SRC="$(sed -n '/^is_blank(){/p' "$SCRIPT")"
case "$SCAN_SRC" in
  *'apat='*'grep -rIoE'*'die '*) check "scan_secrets was cut from claude-sync whole" ok ;;
  *) check "scan_secrets was cut from claude-sync whole" "the extraction found no scan_secrets body, so nothing below would mean anything" ;;
esac
[ -n "$BLANK_SRC" ] && check "is_blank was cut from claude-sync" ok \
  || check "is_blank was cut from claude-sync" "not found"

# run_scan <payload dir> <repo dir holding .secret-allowlist>; prints what the scan said, and
# "SCAN-RC=<n>" last. Run in a subshell with the override switched off explicitly: a
# SYNC_SKIP_SECRET_SCAN inherited from whoever started this suite would pass everything (L439).
run_scan(){
  # Locals, which scan_secrets sees through bash's dynamic scope and which go when this returns.
  local PAYLOAD="$1" SYNC_REPO="$2"
  (
    unset SYNC_SKIP_SECRET_SCAN
    die(){ printf 'REFUSED: %s\n' "$*"; exit 1; }
    eval "$BLANK_SRC"
    eval "$SCAN_SRC"
    scan_secrets
  ) 2>&1
  printf 'SCAN-RC=%s\n' "$?"
}

# --- the shipped payload ---------------------------------------------------------
# A copy holding exactly the files git would carry, so an ignored local file (a skill's
# config.local.json, which the sync also leaves out) neither fails nor passes this.
SHIPPED="$TMPROOT/shipped/payload"
mkdir -p "$SHIPPED"
listed="$(bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" payload)" || listed=""
n=0
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$ROOT/$f" ] || continue
  mkdir -p "$TMPROOT/shipped/$(dirname "$f")"
  cp "$ROOT/$f" "$TMPROOT/shipped/$f"
  n=$((n+1))
done <<< "$listed"
[ "$n" -ge 100 ] && check "the scan reads the shipped payload ($n files)" ok \
  || check "the scan reads the shipped payload ($n files)" "too few to be the real payload"
[ -f "$SHIPPED/skills/tracker/config.example.json" ] && check "and the tracker's example config is among them" ok \
  || check "and the tracker's example config is among them" "missing, so the case that blocked sync is not being judged"

out="$(run_scan "$SHIPPED" "$ROOT")"
case "$out" in
  *'SCAN-RC=0') check "the shipped payload passes claude-sync's secret scan" ok ;;
  *) check "the shipped payload passes claude-sync's secret scan" "a send would refuse: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# --- the controls (L1) -----------------------------------------------------------
# The same run refuses a planted credential, so its silence above is a verdict.
mkdir -p "$TMPROOT/planted/payload/skills/x" "$TMPROOT/planted/repo"
# The planted token is a hash made here, never pieces of one written into this file (#1125).
printf '{ "token": "%s" }\n' "$(printf 'payload scan planted control' | shasum -a 256 | cut -c1-40)" > "$TMPROOT/planted/payload/skills/x/c.json"
out="$(run_scan "$TMPROOT/planted/payload" "$TMPROOT/planted/repo")"
case "$out" in
  *'possible secret found in: skills/x/c.json'*'SCAN-RC=1') check "control: the same scan refuses a planted token and names its file" ok ;;
  *) check "control: the same scan refuses a planted token and names its file" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# And it refuses the placeholder that blocked sync, so this suite would have caught it.
mkdir -p "$TMPROOT/old/payload/skills/tracker" "$TMPROOT/old/repo"
printf '{\n  "url": "x",\n  "token": "REPLACE_BY_RUNNING_tracker.sh_new-token"\n}\n' > "$TMPROOT/old/payload/skills/tracker/config.example.json"
out="$(run_scan "$TMPROOT/old/payload" "$TMPROOT/old/repo")"
case "$out" in
  *'possible secret found in: skills/tracker/config.example.json'*'SCAN-RC=1') check "control: the scan refuses the token shaped placeholder that blocked sync after #675" ok ;;
  *) check "control: the scan refuses the token shaped placeholder that blocked sync after #675" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# Every path that ends a scan WITHOUT refusing clears the record of the last refusal
# (claude-config#947), or a later pull blames a refusal that no longer applies. The early returns
# are the paths a test of the whole tool cannot easily reach, so they are driven here.
run_scan_recorded(){   # $1 = payload dir  $2 = repo dir  $3 = SYNC_SKIP_SECRET_SCAN value
  local PAYLOAD="$1" SYNC_REPO="$2" SEND_REFUSED_FILE="$2/.send-refused" SYNC_SKIP_SECRET_SCAN="$3"
  printf '1\tskills/x/c.json\n' > "$SEND_REFUSED_FILE"
  (
    die(){ printf 'REFUSED: %s\n' "$*"; exit 1; }
    eval "$BLANK_SRC"
    eval "$SCAN_SRC"
    scan_secrets
  ) >/dev/null 2>&1
  [ -e "$SEND_REFUSED_FILE" ] && printf 'still there' || printf 'cleared'
}
mkdir -p "$TMPROOT/rec/repo" "$TMPROOT/rec/clean/payload"
printf 'nothing secret\n' > "$TMPROOT/rec/clean/payload/f.txt"
r="$(run_scan_recorded "$TMPROOT/rec/clean/payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = cleared ] && check "#947 a scan that passes clears the record of the last refusal" ok \
  || check "#947 a scan that passes clears the record of the last refusal" "$r"
r="$(run_scan_recorded "$TMPROOT/rec/no-such-payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = cleared ] && check "#947 so does a scan with no payload to read" ok \
  || check "#947 so does a scan with no payload to read" "$r"
r="$(run_scan_recorded "$TMPROOT/planted/payload" "$TMPROOT/rec/repo" 1)"
[ "$r" = cleared ] && check "#947 so does a send let past the scan with SYNC_SKIP_SECRET_SCAN=1" ok \
  || check "#947 so does a send let past the scan with SYNC_SKIP_SECRET_SCAN=1" "$r"
r="$(run_scan_recorded "$TMPROOT/planted/payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = 'still there' ] && check "#947 control: a scan that refuses keeps it" ok \
  || check "#947 control: a scan that refuses keeps it" "$r"

# --- no test assembles a token this scan would refuse (claude-config#1125) --------
# A fixture that gets past the scan by HOW it is written, never by what it is, is an exception to
# the scan that nobody reviewed, and it shows the next real token a way through: a key in one place
# and its value in a variable, or a value printed from two halves. The scan reads text, so it sees
# neither. This reads every test file the way the shell would put it together, and runs the SAME
# scan over that: each variable given one literal value in its file replaced by it, escaped quotes
# unescaped, adjacent quoted pieces and Python's "a" + "b" joined, and printf's %s filled from its
# quoted arguments. A line is an assembly when the scan refuses the joined form and refuses none of
# its pieces (the raw line, and each value put into it). So a value written whole and visible to the
# scan, like the AWS example key the sync tests plant, is not one, because the scan already sees it.
#
# A fixture the scan accepts BY ITS OWN RULES is the way to stay clear of this: a placeholder with
# spaces or angle brackets (README "Secret scan"), or a value shorter than a pattern's minimum. A
# control that must be token shaped is derived at run time (a hash), so no token exists in the file
# to be split. Reading Python assignments and here documents is out of reach of this check.
#
# assembled_lines <root> <file holding the relative paths to read>: prints path:line per assembly,
# then "READ files=<n> joined=<m>" last, so a run that read nothing cannot pass as clean (L98).
assembled_lines(){
  local root="$1" list="$2" work raw joined listing
  work="$(mktemp -d "$TMPROOT/assembly.XXXXXX")" || { echo "READ failed: no scratch directory"; return 1; }
  raw="$work/raw"; joined="$work/joined"; mkdir -p "$raw" "$joined"
  if python3 - "$root" "$list" "$raw" "$joined" > "$work/listing" 2>&1 <<'PY'
import itertools, os, re, sys
root, listfile, out_raw, out_joined = sys.argv[1:5]
assign = re.compile(r"""^\s*(?:(?:local|export|readonly|declare(?:\s+-\w+)?)\s+)?([A-Za-z_]\w*)=(?:"([^"$`\\]*)"|'([^']*)'|([^\s"'$`;|&<>()\\]+))(?=\s|;|$)""")
ref = re.compile(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)")
glue = re.compile(r"""(?<=[A-Za-z0-9_+/.-])(?:"\s*\+\s*"|'\s*\+\s*'|""|''|"'|'")(?=[A-Za-z0-9_+/.-])""")
printf = re.compile(r"""printf\s+(?:-v\s+\w+\s+)?(?:--\s+)?(['"])((?:(?!\1).)*)\1((?:\s+(?:"(?:[^"\\]|\\.)*"|'[^']*'|[^\s'"<>|;&]+))*)""")
arg = re.compile(r"""\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|([^\s'"<>|;&]+))""")

def fill(m):
    args = [next(g for g in a if g) if any(a) else "" for a in arg.findall(m.group(3))]
    it = iter(args)
    body = re.sub(r"%%|%[sb]", lambda c: "%" if c.group(0) == "%%" else next(it, ""), m.group(2))
    return "printf " + m.group(1) + body + m.group(1) + "".join(" '%s'" % a for a in it)

files = n = 0
for rel in open(listfile).read().splitlines():
    try:
        lines = open(os.path.join(root, rel), errors="ignore").read().splitlines()
    except OSError:
        continue
    files += 1
    values = {}
    for l in lines:
        m = assign.match(glue.sub("", l))
        if m:
            values.setdefault(m.group(1), set()).add(next((g for g in m.groups()[1:] if g is not None), ""))
    for i, l in enumerate(lines, 1):
        names = sorted({a or b for a, b in ref.findall(l)} & set(values))
        used, forms = [], []
        for combo in itertools.islice(itertools.product(*[sorted(values[k]) for k in names]), 16):
            sub = dict(zip(names, combo))
            used += combo
            e = ref.sub(lambda r: sub.get(r.group(1) or r.group(2), r.group(0)), l)
            forms.append(printf.sub(fill, glue.sub("", e.replace('\\"', '"'))))
        if not names:
            forms = [printf.sub(fill, glue.sub("", l.replace('\\"', '"')))]
        if forms == [l]:
            continue
        name = rel.replace("/", "%") + "__L%d" % i
        open(os.path.join(out_raw, name), "w").write("\n".join([l] + used) + "\n")
        open(os.path.join(out_joined, name), "w").write("\n".join(forms) + "\n")
        n += 1
print("READ files=%d joined=%d" % (files, n))
PY
  then listing="$(cat "$work/listing")"
  else echo "READ failed: the reader stopped: $(cat "$work/listing")"; return 1; fi
  refused_in(){ run_scan "$1" "$work/repo" | sed -n 's/^REFUSED: possible secret found in: \(.*\)\. Remove it.*/\1/p' | tr ' ' '\n' | sed '/^$/d' | sort -u; }
  mkdir -p "$work/repo"
  comm -13 <(refused_in "$raw") <(refused_in "$joined") | sed -e 's/%/\//g' -e 's/__L\([0-9]*\)$/:\1/'
  printf '%s\n' "$listing"
}

# Every test in this repository: tracked or not yet, under tests/ or named test-* anywhere.
bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" | grep -E '(^|/)test-[^/]*$|^tests/' > "$TMPROOT/test-files" || true
out="$(assembled_lines "$ROOT" "$TMPROOT/test-files")"
read_files="$(printf '%s\n' "$out" | sed -n 's/^READ files=\([0-9]*\).*/\1/p')"
[ "${read_files:-0}" -ge 100 ] && check "#1125 the assembly check reads every test file ($read_files)" ok \
  || check "#1125 the assembly check reads every test file (${read_files:-none})" "too few to be this repository's tests: $out"
found="$(printf '%s\n' "$out" | grep -v '^READ ' || true)"
[ -z "$found" ] && check "#1125 no test assembles a token the secret scan would refuse" ok \
  || check "#1125 no test assembles a token the secret scan would refuse" "write the fixture so the scan accepts it as written (see the comment above this check): $(printf '%s' "$found" | tr '\n' ' ')"

# The controls, both ways (L1, L497). The token shaped values are a hash, made here, so this file
# holds none of them; each fixture is a file of its own, read the same way as the tests above.
FX="$TMPROOT/assembly-fixtures"; mkdir -p "$FX/tests"
fxv="$(printf 'claude-config#1125 control' | shasum -a 256 | cut -c1-40)"
printf 'FXV="%s"\nprintf '"'"'{"token":"%%s"}'"'"' "$FXV"\n' "$fxv" > "$FX/tests/test-key-apart.sh"
printf 'write "{\\"token\\":\\"$FXV\\"}"\nFXV="%s"\n' "$fxv" > "$FX/tests/test-escaped.sh"
printf "printf '{ \"token\": \"%%s%%s\" }' \"%s\" \"%s\"\n" "${fxv:0:16}" "${fxv:16}" > "$FX/tests/test-halves.sh"
printf 'FXV="%s"\nprintf "AKI""A%%s" "$FXV"\n' "$(printf '%s' "$fxv" | tr 'a-f' 'A-F' | cut -c1-16)" > "$FX/tests/test-glued.sh"
printf 'FXG="%s""%s"\necho "api_key=$FXG"\n' "${fxv:0:8}" "${fxv:8}" > "$FX/tests/test-glued-value.sh"
cat > "$FX/tests/test-placeholder.sh" <<'EOF'
FXP="kept token, invented for this test"
write "{\"token\":\"$FXP\"}"
EOF
cat > "$FX/tests/test-visible.sh" <<'EOF'
FXS='AKIAIOSFODNN7EXAMPLE'
printf 'export AWS_KEY=%s\n' "$FXS"
EOF
(cd "$FX" && ls tests) | sed 's|^|tests/|' > "$FX/list"
out="$(assembled_lines "$FX" "$FX/list")"
for want in tests/test-key-apart.sh:2 tests/test-escaped.sh:1 tests/test-halves.sh:1 tests/test-glued.sh:2 tests/test-glued-value.sh:2; do
  case "$out" in
    *"$want"*) check "#1125 control: the check finds the assembly at $want" ok ;;
    *) check "#1125 control: the check finds the assembly at $want" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
done
case "$out" in
  *test-placeholder*) check "#1125 control: a placeholder the scan accepts by its own rules is not an assembly" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  *) check "#1125 control: a placeholder the scan accepts by its own rules is not an assembly" ok ;;
esac
case "$out" in
  *test-visible*) check "#1125 control: a value the scan already sees whole is not an assembly" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  *) check "#1125 control: a value the scan already sees whole is not an assembly" ok ;;
esac
# And the real fixture this issue was filed against, when the history holding it is here.
if git -C "$ROOT" cat-file -e a323443b:payload/skills/tracker/test-scan-flow.sh 2>/dev/null; then
  mkdir -p "$FX/old/payload/skills/tracker"
  git -C "$ROOT" show a323443b:payload/skills/tracker/test-scan-flow.sh > "$FX/old/payload/skills/tracker/test-scan-flow.sh"
  printf 'payload/skills/tracker/test-scan-flow.sh\n' > "$FX/old/list"
  case "$(assembled_lines "$FX/old" "$FX/old/list")" in
    *'test-scan-flow.sh:161'*) check "#1125 control: the check finds the tracker scan test's token as #1112 shipped it" ok ;;
    *) check "#1125 control: the check finds the tracker scan test's token as #1112 shipped it" "not found" ;;
  esac
else
  echo "UNMEASURED: #1125 control on the fixture #1112 shipped: commit a323443b is not in this clone's history"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
