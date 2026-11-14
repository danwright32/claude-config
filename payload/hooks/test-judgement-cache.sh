#!/usr/bin/env bash
# Tests for lib/judgement-cache.py, the Slack drafts gate's cache of the calls it allowed
# (claude-config#2918). The judgements themselves (a changed sourced file, a changed disk answer and a
# corrupt entry each judged afresh) are in test-slack-drafts-only-gate.sh; this suite checks the
# cache's own parts:
#   - the one route to the disk: every module the gate and its libraries import is classified, none
#     is reached around install()'s stand ins, and every environment variable read by name is in the
#     key (L621: a new direct disk call fails here, not in a review);
#   - the stand ins: recorded reads give the caller what the real call gives, and anything they do not
#     know (an unclassified os attribute, an open from another route) marks the record not whole;
#   - fail closed: a tainted record, a read that changed while judging, and an unreadable entry are
#     never a kept allow;
#   - the size bound.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/judgement-cache.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

echo "judgement cache: the one route to the disk (L621)"

# scan.py <gate> [extra line to put in a copy of the gate]: every finding, one per line, or "ok".
cat > "$T/scan.py" <<'PY'
import ast, importlib.util, os, re, sys
gate = sys.argv[1]
here = os.path.dirname(gate)
spec = importlib.util.spec_from_file_location("jc", os.path.join(here, "lib", "judgement-cache.py"))
jc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jc)
gate_src = open(gate).read()
if len(sys.argv) > 2:  # a copy of the gate with one more line inside its first function
    gate_src = gate_src.replace("\ndef ", "\ndef _probe():\n    " + sys.argv[2] + "\n\n\ndef ", 1)
files = {gate: gate_src}
libs = re.findall(r'load_lib\("\w+", "([\w.-]+\.py)"\)', gate_src)
for name in libs:
    if name != "judgement-cache.py":
        p = os.path.join(here, "lib", name)
        files[p] = open(p).read()
found = []
if len(libs) < 4:
    found.append("only %d libraries found loaded by the gate" % len(libs))
env_names = set()
for path, src in files.items():
    short = os.path.basename(path)
    tree = ast.parse(src)
    top = {id(n) for n in tree.body}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                kind = jc.MODULES.get(a.name)
                if kind is None:
                    found.append("%s:%d imports %s, which judgement-cache.py has not classified" % (short, node.lineno, a.name))
                elif kind == "proxied" and (id(node) not in top or a.asname):
                    found.append("%s:%d imports %s inside a function or under another name, around install()" % (short, node.lineno, a.name))
        elif isinstance(node, ast.ImportFrom):
            if jc.MODULES.get(node.module) != "pure":
                found.append("%s:%d imports names from %s, which binds them around install()" % (short, node.lineno, node.module))
        elif isinstance(node, ast.Name) and node.id in ("__builtins__", "__import__", "builtins"):
            found.append("%s:%d names %s, a way to the builtin open around install()" % (short, node.lineno, node.id))
        elif isinstance(node, ast.Attribute) and node.attr in ("import_module", "__import__"):
            found.append("%s:%d calls %s, an import around install()" % (short, node.lineno, node.attr))
        elif isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                and node.value.id in jc.MODULE_USES and node.attr not in jc.MODULE_USES[node.value.id]:
            found.append("%s:%d uses %s.%s, which can read the disk with no audit event" % (short, node.lineno, node.value.id, node.attr))
        elif isinstance(node, ast.Call) and node.args and isinstance(node.args[0], ast.Constant) \
                and isinstance(node.args[0].value, str) and ast.unparse(node.func) in ("os.environ.get", "os.getenv"):
            env_names.add(node.args[0].value)
        elif isinstance(node, ast.Subscript) and ast.unparse(node.value) == "os.environ" \
                and isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str):
            env_names.add(node.slice.value)
for name in sorted(env_names - set(jc.KEY_ENV)):
    found.append("the environment variable %s is read by name but is not in KEY_ENV" % name)
if len(env_names) < 8:
    found.append("only %d environment variables found read by name" % len(env_names))
print("\n".join(found) or "ok")
PY
out="$(python3 -B "$T/scan.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
check "every import in the gate and its libraries is classified and reaches the disk only through the stand ins, and every variable read by name is keyed" "$out"
# Seen to fail (L1): each way around the stand ins, put in a copy of the gate, is found.
for probe in "from os.path import isfile" "import pathlib" "import os as real_os" "import glob" \
             "return __builtins__" "return os.environ.get('NEW_GATE_SETTING')" "return shutil.which('git')"; do
  out="$(python3 -B "$T/scan.py" "$DIR/slack_drafts_only_gate.py" "$probe" 2>&1)"
  if [ "$out" != ok ] && [ -n "$out" ]; then check "the scan finds: $probe" ok
  else check "the scan finds: $probe" "it said: $out"; fi
done

echo "judgement cache: the stand ins record what the gate reads, and mark what they cannot see"

cat > "$T/units.py" <<'PY'
import builtins, importlib.util, json, os, sys, time
gate_path, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
jc = gate._cache
bad = []
def expect(what, ok):
    if not ok:
        bad.append(what)

# The tree the stand ins read, made before they are in place (making it is no read of the gate's).
os.makedirs(os.path.join(work, "t", "a", "deep"))
os.makedirs(os.path.join(work, "t", ".hidden"))
open(os.path.join(work, "t", "a", "f.txt"), "w").write("hello\n")
os.symlink(os.path.join(work, "t", "a"), os.path.join(work, "t", "link"))
def pruned(walk):
    out = []
    for cur, dirs, names in walk(os.path.join(work, "t")):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        out.append((cur, sorted(dirs), sorted(names)))
    return out
real_walk = pruned(os.walk)

# Stand ins in every namespace the gate loads.
rec = jc.Recorder()
spaces = [vars(gate)] + [vars(m) for m in gate.LIBS if m is not jc]
proxies = jc.install(rec, spaces)
for ns in spaces:
    for name in ("os", "glob", "importlib", "ast"):
        if name in ns:
            expect("%s's %s is the stand in" % (ns.get("__name__"), name), ns[name] is proxies[name])
    expect("%s's open is the stand in" % ns.get("__name__"), ns.get("open") is proxies["open"])
expect("every library the gate loaded is covered (%d)" % len(spaces), len(spaces) >= 4)

# Recorded reads answer as the real calls do.
g = gate.os
expect("isfile", g.path.isfile(os.path.join(work, "t", "a", "f.txt")) is True)
expect("realpath", g.path.realpath(os.path.join(work, "t", "link")) == os.path.realpath(os.path.join(work, "t", "a")))
try:
    g.listdir(os.path.join(work, "nothing"))
    expect("listdir of a missing folder raises", False)
except FileNotFoundError:
    pass
expect("os.walk with pruning walks what the real one does", pruned(g.walk) == real_walk and len(real_walk) == 3)
with gate.open(os.path.join(work, "t", "a", "f.txt"), "rb") as f:
    expect("open in bytes gives the bytes", f.read(3) == b"hel")
with gate.open(os.path.join(work, "t", "a", "f.txt"), encoding="utf-8", errors="replace") as f:
    expect("open in text gives the text", f.read() == "hello\n")
expect("an environment variable read by a name worked out at run time is recorded",
       g.environ.get("JC_" + "RUNTIME_NAME") is None and ("env", "JC_RUNTIME_NAME") in rec.reads)
# Text that does not parse: CPython tries to open the file the source is said to come from, which
# the ast stand in records as a read rather than leaving to the audit hook.
try:
    gate.ast.parse("x = (")
    expect("a syntax error still raises through the stand in", False)
except SyntaxError:
    pass
expect("and the attempted read of its file is recorded", ("read", "<unknown>") in rec.reads)
expect("none of that marks the record: %r" % rec.tainted, rec.tainted is None)
expect("each read is recorded", ("read", os.path.join(work, "t", "a", "f.txt")) in rec.reads
       and ("dirsplit", os.path.join(work, "t")) in rec.reads)

# A disk call the stand ins do not know marks the record not whole, from any route.
g.stat(work)
expect("an os attribute the recorder does not know marks the record: %r" % rec.tainted,
       rec.tainted and "os.stat" in rec.tainted)
rec2 = jc.Recorder()
jc.install(rec2, [vars(gate)])
builtins.open(os.path.join(work, "t", "a", "f.txt")).close()
expect("an open from around the stand ins marks the record: %r" % rec2.tainted,
       rec2.tainted and "open" in rec2.tainted)
rec3 = jc.Recorder()
jc.install(rec3, [vars(gate)])
os.listdir(work)
expect("a listing from around the stand ins marks the record: %r" % rec3.tainted,
       rec3.tainted and "os.listdir" in rec3.tainted)
rec4 = jc.Recorder()
jc.install(rec4, [vars(gate)])
was, jc.MAX_READ = jc.MAX_READ, 3
with gate.open(os.path.join(work, "t", "a", "f.txt"), "rb") as f:
    expect("a file past MAX_READ is still read whole", f.read() == b"hello\n")
jc.MAX_READ = was
expect("a file past MAX_READ marks the record: %r" % rec4.tainted, rec4.tainted and "larger" in rec4.tainted)

# Fail closed on the way in and on the way out.
cache = os.path.join(work, "cache")
trace = os.path.join(work, "trace")
os.environ["SLACK_GATE_CACHE_TRACE"] = trace
def traced():
    return open(trace).read() if os.path.exists(trace) else ""
src = os.path.join(work, "src.sh")
open(src, "w").write("echo one\n")
r = jc.Recorder()
jc.install(r, [vars(gate)])
gate.open(src).read()
r.taint("a test's reason")
jc.store(cache, "k1", r)
expect("a record not whole is not kept", not os.path.exists(os.path.join(cache, "k1.json")) and "not stored: a test's reason" in traced())
r = jc.Recorder()
jc.install(r, [vars(gate)])
gate.open(src).read()
# Changed after it was read, before it was kept. The write is this test's, not the judgement's, so the
# record is closed first: otherwise the audit hook would see the write and the case would pass on that.
r.closed = True
open(src, "w").write("echo two\n")
jc.store(cache, "k2", r)
expect("a judgement whose input changed while it was judged is not kept, for that reason: %r" % traced()[-160:],
       r.tainted is None and not os.path.exists(os.path.join(cache, "k2.json"))
       and "not stored: something changed while it was judged: read" in traced())
r = jc.Recorder()
jc.install(r, [vars(gate)])
gate.open(src).read()
jc.store(cache, "k3", r)
expect("a whole record is kept", os.path.exists(os.path.join(cache, "k3.json")))
expect("and found again", jc.lookup(cache, "k3"))
expect("but not under another key", not jc.lookup(cache, "k4"))
entry = os.path.join(cache, "k3.json")
os.chmod(entry, 0)
if os.access(entry, os.R_OK):
    print("SUITE-PART-UNMEASURED an entry the cache cannot read, because this user reads a file with no permissions, so one cannot be made")
else:
    expect("an entry that cannot be read is a miss", not jc.lookup(cache, "k3") and "could not be read" in traced())
os.chmod(entry, 0o600)
e = json.load(open(entry))
e["reads"][0][0] = "remove"
e["sum"] = jc._checksum(e)
json.dump(e, open(entry, "w"))
expect("an entry naming a question the cache does not ask is a miss", not jc.lookup(cache, "k3"))
e["reads"][0][0] = "read"
e["verdict"] = "refuse"
e["sum"] = jc._checksum(e)
json.dump(e, open(entry, "w"))
expect("an entry that is not an allow is never used", not jc.lookup(cache, "k3"))

# Bounded: the least recently used go first, by count and by bytes.
bound = os.path.join(work, "bound")
os.makedirs(bound)
now = time.time()
for i in range(205):
    p = os.path.join(bound, "e%03d.json" % i)
    open(p, "w").write("x" * 100)
    os.utime(p, (now - 1000 + i, now - 1000 + i))
jc.evict(bound)
left = sorted(os.listdir(bound))
expect("at most MAX_ENTRIES are kept, the oldest removed: %d left, first %s" % (len(left), left[:1]),
       len(left) == jc.MAX_ENTRIES and left[0] == "e005.json")
jc.evict(bound, max_total=1000)
expect("past the byte bound the oldest go too", len(os.listdir(bound)) == 10)
print("; ".join(bad) or "ok")
PY
out="$(env -u SLACK_GATE_CACHE_DIR python3 -B "$T/units.py" "$DIR/slack_drafts_only_gate.py" "$T/work" 2>&1)"
case "$out" in
  SUITE-PART-UNMEASURED*) echo "${out%%$'\n'*}"; out="${out#*$'\n'}" ;;
esac
check "the stand ins, failing closed, and the size bound" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
