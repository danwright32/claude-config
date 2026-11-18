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
#   - the size bound;
#   - a standard library module the gate's reading of a Python script asks (lib/py-aliases.py, #3102):
#     where Python finds it and what its file holds are recorded, and a kept judgement is not used
#     once either has changed.
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
                elif a.name in jc.MODULE_USES and a.asname:
                    found.append("%s:%d imports %s under another name, around the names it may use" % (short, node.lineno, a.name))
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
             "return __builtins__" "return os.environ.get('NEW_GATE_SETTING')" "return shutil.which('git')" "import shutil as sh"; do
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
# importlib.util.module_from_spec is where a compiled extension's file is loaded from the disk, by
# the system's loader, with no open and no event the audit hook reads (claude-config#3151): passed
# through as pure, a judgement that made one could be kept with that file nowhere in its record.
# Measured here by an audit hook of the test's own: the call raises import with the file's path.
import importlib.machinery
ext = next((s for s in (importlib.util.find_spec(n) for n in ("_lsprof", "_multibytecodec", "_statistics",
            "_queue", "_dbm", "_posixshmem", "_uuid", "cmath", "audioop")) if s is not None
            and isinstance(s.loader, importlib.machinery.ExtensionFileLoader) and s.name not in sys.modules), None)
if ext is None:
    # The count is the two expect calls in the branch below, which this machine cannot run
    # (claude-config#3191): they are named here, never folded into this script's one pass.
    print("SUITE-PART-UNMEASURED 2 checks of a compiled extension made through the stand ins (its file loaded from the disk, and what it holds in the record), because none of the ones tried is there unloaded")
else:
    loaded = []
    sys.addaudithook(lambda event, args: loaded.append(args[1]) if event == "import" and args[1] == ext.origin else None)
    rec5 = jc.Recorder()
    jc.install(rec5, [vars(gate)])
    made = gate.importlib.util.module_from_spec(gate.importlib.util.spec_from_file_location(ext.name, ext.origin))
    expect("the control: making %s from its spec loaded %s from the disk" % (ext.name, ext.origin),
           loaded == [ext.origin] and getattr(made, "__file__", None) == ext.origin)
    big = os.path.getsize(ext.origin) > jc.MAX_READ
    expect("what the compiled extension's file holds is in the record, or the record is marked for its size: %r, %r"
           % (rec5.tainted, sorted(k for k in rec5.reads if k[0] == "read")),
           (rec5.tainted and "larger" in rec5.tainted) if big
           else (rec5.tainted is None and rec5.reads.get(("read", ext.origin), [None])[0] == "ok"))
# A module written in Python is made empty, with nothing read: it passes through unmarked. A
# loader the recorder does not know may read anything while it makes its module. Neither needs a
# compiled extension, so both run on every machine, outside the branch above (claude-config#3191).
rec6 = jc.Recorder()
jc.install(rec6, [vars(gate)])
plain = gate.importlib.util.module_from_spec(gate.importlib.util.spec_from_file_location("jc_plain", os.path.join(work, "src.py")))
expect("a module written in Python made from its spec leaves the record whole and empty: %r, %r"
       % (rec6.tainted, rec6.reads), plain.__name__ == "jc_plain" and rec6.tainted is None and not rec6.reads)
class OwnLoader:
    def create_module(self, spec):
        return None
    def exec_module(self, module):
        pass
gate.importlib.util.module_from_spec(importlib.machinery.ModuleSpec("jc_own", OwnLoader()))
expect("a loader the recorder does not know marks the record: %r" % rec6.tainted,
       rec6.tainted and "OwnLoader" in rec6.tainted)

# Fail closed on the way in and on the way out.
cache = os.path.join(work, "cache")
trace = os.path.join(work, "trace")
os.environ["SLACK_GATE_CACHE_TRACE"] = trace
def traced():
    return open(trace).read() if os.path.exists(trace) else ""
def untraced():
    """Empty the trace, so the next check's line can only come from what follows."""
    open(trace, "w").close()
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
whole = dict(e)
# Each of these is signed with the cache's own key, so it is the named fault that makes it a miss.
e["reads"][0][0] = "remove"
e["sig"] = jc._signature(jc.signing_key(cache, False), e)
json.dump(e, open(entry, "w"))
expect("an entry naming a question the cache does not ask is a miss", not jc.lookup(cache, "k3"))
e["reads"][0][0] = "read"
e["verdict"] = "refuse"
e["sig"] = jc._signature(jc.signing_key(cache, False), e)
json.dump(e, open(entry, "w"))
expect("an entry that is not an allow is never used", not jc.lookup(cache, "k3"))
json.dump(whole, open(entry, "w"))
expect("put back as it was kept, the entry is found again", jc.lookup(cache, "k3"))

# Signed (claude-config#2965): an entry is used only when it carries the signature of a key that only
# this user can read, kept beside the cache folder and never in it. No key value is ever printed.
keyfile = os.path.normpath(cache) + ".key"  # as the cache spells it: $TMPDIR can end in a slash
expect("the key is where the cache looks for it", jc.key_path(cache) == keyfile)
st = os.lstat(keyfile) if os.path.lexists(keyfile) else None
expect("keeping a judgement made the key beside the cache folder, not in it",
       st is not None and os.path.dirname(keyfile) != cache and not os.path.exists(os.path.join(cache, ".key")))
expect("the key is a regular file of this user's that nobody else can read or write: %s"
       % (oct(st.st_mode) if st else None),
       st is not None and (st.st_mode & 0o777) == 0o600 and st.st_uid == os.getuid() and os.path.isfile(keyfile))
secret = open(keyfile, "rb").read()
expect("the key holds 32 random bytes (%d)" % len(secret), len(secret) == 32)
expect("no trace line carries the key", secret.hex() not in traced() and secret.hex().upper() not in traced())
expect("an entry carries no key", secret.hex() not in open(entry).read())
# A forged entry: an allow for a key nobody judged, sealed the way an unsigned cache would seal it.
forged = {"format": jc.FORMAT, "key": "k5", "verdict": "allow", "reads": []}
forged["sig"] = forged["sum"] = __import__("hashlib").sha256(json.dumps(forged, sort_keys=True).encode()).hexdigest()
json.dump(forged, open(os.path.join(cache, "k5.json"), "w"))
untraced()
expect("an entry not signed with this cache's key is a miss", not jc.lookup(cache, "k5")
       and "miss: the entry is not a whole allow" in traced())
# The same entry signed with another key.
forged["sig"] = jc._signature(b"x" * 32, forged)
json.dump(forged, open(os.path.join(cache, "k5.json"), "w"))
expect("an entry signed with another key is a miss", not jc.lookup(cache, "k5"))
def kept_now(name):
    r = jc.Recorder()
    jc.install(r, [vars(gate)])
    gate.open(src).read()
    jc.store(cache, name, r)
    return os.path.exists(os.path.join(cache, name + ".json"))
# A key anyone else can read is no key: nothing is used and nothing is kept.
os.chmod(keyfile, 0o644)
untraced()
expect("with a key others can read, a kept entry is a miss", not jc.lookup(cache, "k3") and "miss: no signing key" in traced())
untraced()
expect("and nothing is kept", not kept_now("k6") and "not stored: no signing key" in traced())
os.chmod(keyfile, 0o600)
expect("with the key put right, the entry is found again", jc.lookup(cache, "k3"))
# Changed between the check of its name and its open: what is opened must pass every test again.
class _NamedAsItWas:
    """os, but lstat answers as it did before the key was changed (a change in that gap)."""
    def __init__(self, before):
        self.before = before
    def __getattr__(self, name):
        return getattr(os, name)
    def lstat(self, path):
        return self.before if path == keyfile else os.lstat(path)
before = os.lstat(keyfile)
for change, why in ((lambda: os.chmod(keyfile, 0o644), "readable by others"),
                    (lambda: open(keyfile, "ab").write(b"x"), "a byte longer")):
    change()
    real_os, jc._os = jc._os, _NamedAsItWas(before)
    try:
        expect("a key made %s after its name was checked is no key" % why, jc.signing_key(cache, False) is None)
    finally:
        jc._os = real_os
    os.chmod(keyfile, 0o600)
open(keyfile, "r+b").truncate(32)
expect("with the key as it was, the entry is found again", os.lstat(keyfile).st_size == 32 and jc.lookup(cache, "k3"))
# A key that cannot be read is no key.
os.chmod(keyfile, 0)
if os.access(keyfile, os.R_OK):
    print("SUITE-PART-UNMEASURED a key the cache cannot read, because this user reads a file with no permissions")
else:
    expect("with a key that cannot be read, a kept entry is a miss", not jc.lookup(cache, "k3"))
    expect("and nothing is kept, and the key is not replaced", not kept_now("k6b") and (os.lstat(keyfile).st_mode & 0o777) == 0)
os.chmod(keyfile, 0o600)
# A key that is a link is no key, wherever it points.
os.rename(keyfile, keyfile + ".was")
os.symlink(keyfile + ".was", keyfile)
expect("with a key that is a link, a kept entry is a miss", not jc.lookup(cache, "k3"))
os.unlink(keyfile)
os.rename(keyfile + ".was", keyfile)
# A missing key: a lookup never makes one, and every entry signed with the old one is a miss.
os.rename(keyfile, keyfile + ".was")
untraced()
expect("with no key, a kept entry is a miss", not jc.lookup(cache, "k3") and "miss: no signing key" in traced())
expect("and a lookup does not make one", not os.path.lexists(keyfile))
expect("keeping a judgement makes a new one", kept_now("k7") and os.path.isfile(keyfile))
expect("and an entry signed with the key it replaced is a miss", not jc.lookup(cache, "k3") and jc.lookup(cache, "k7"))
os.unlink(keyfile + ".was")
# A key that cannot be made is no cache, never an unsigned one.
nokey = os.path.join(work, "locked")
os.makedirs(nokey)
os.chmod(nokey, 0o500)
if os.access(nokey, os.W_OK):
    print("SUITE-PART-UNMEASURED a key that cannot be made, because this user writes a folder with no write permission")
else:
    untraced()  # before the recorder is in place, where emptying the trace would be a write it saw
    r = jc.Recorder()
    jc.install(r, [vars(gate)])
    gate.open(src).read()
    jc.store(os.path.join(nokey, "cache"), "k8", r)
    expect("where no key can be made nothing is kept", not os.path.exists(os.path.join(nokey, "cache", "k8.json"))
           and "not stored: no signing key" in traced())
os.chmod(nokey, 0o700)

# Kept only where the order the gate iterates a set in is fixed (claude-config#2965). This process
# runs with PYTHONHASHSEED=0, as the gate's wrapper runs the gate; order.py is run without it.
expect("this suite runs the units with string hashing fixed", sys.flags.hash_randomization == 0)
expect("so a judgement is kept", kept_now("k9"))

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
out="$(env -u SLACK_GATE_CACHE_DIR PYTHONHASHSEED=0 python3 -B "$T/units.py" "$DIR/slack_drafts_only_gate.py" "$T/work" 2>&1)"
while [[ "$out" == SUITE-PART-UNMEASURED* ]]; do echo "${out%%$'\n'*}"; out="${out#*$'\n'}"; done
check "the stand ins, failing closed, signing, and the size bound" "$out"

echo
echo "judgement cache: a judgement whose set iteration order is random is never kept or used (#2965)"
# Python orders a set of strings by their hashes, which are salted afresh in each process unless
# PYTHONHASHSEED fixes them, so where a verdict depends on that order a kept one could differ from a
# fresh one. Units.py kept k9 with hashing fixed; here, with it random, k9 is not used and nothing is.
cat > "$T/order.py" <<'PY'
import importlib.util, os, sys
gate_path, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
jc = gate._cache
cache, trace = os.path.join(work, "cache"), os.path.join(work, "trace")
os.environ["SLACK_GATE_CACHE_TRACE"] = trace
bad = []
if sys.flags.hash_randomization != 1:
    bad.append("order.py ran with string hashing fixed, so it measures nothing")
if not os.path.exists(os.path.join(cache, "k9.json")):
    bad.append("units.py kept no k9 to look up")
if jc.lookup(cache, "k9"):
    bad.append("an entry was used by a process whose set order is random")
r = jc.Recorder()
jc.install(r, [vars(gate)])
gate.open(os.path.join(work, "src.sh")).read()
jc.store(cache, "k10", r)
if os.path.exists(os.path.join(cache, "k10.json")):
    bad.append("a judgement made with set order random was kept")
t = open(trace).read()
if t.count("string hashing is random") < 2:
    bad.append("the trace does not say why: " + t[-200:])
print("; ".join(bad) or "ok")
PY
out="$(env -u SLACK_GATE_CACHE_DIR -u PYTHONHASHSEED python3 -B "$T/order.py" "$DIR/slack_drafts_only_gate.py" "$T/work" 2>&1)"
check "with set order random, a kept judgement is not used and a new one is not kept" "$out"

# The gate's wrapper fixes the order, so the cache still answers a call the second time it is judged.
mkdir -p "$T/wrap/w"
printf '%s\n' 'echo hi' > "$T/wrap/run.sh"
wrap_payload="$(python3 -c 'import json, sys; print(json.dumps({"session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": "bash " + sys.argv[1], "description": "d"}}))' "$T/wrap/run.sh" "$T/wrap/w")"
for i in 1 2; do
  : > "$T/wrap/trace"
  printf '%s' "$wrap_payload" | env -u PYTHONHASHSEED SLACK_GATE_CACHE_DIR="$T/wrap/cache" SLACK_GATE_CACHE_TRACE="$T/wrap/trace" bash "$DIR/slack-drafts-only-gate.sh" >/dev/null 2>&1
  got[$i]="$(tr '\n' '|' < "$T/wrap/trace")"
done
case "${got[1]}" in *"|stored|"*|stored\|*) check "run through its wrapper, the gate keeps an allowed call" ok ;;
  *) check "run through its wrapper, the gate keeps an allowed call" "the cache traced: ${got[1]}" ;; esac
case "${got[2]}" in hit\|*|*"|hit|"*) check "and answers it from the cache the second time" ok ;;
  *) check "and answers it from the cache the second time" "the cache traced: ${got[2]}" ;; esac

echo
echo "judgement cache: the reader's parses of large texts, kept between runs (#2918)"
# Dan's decision of 2026-11-15: for heavy load, a parse of a large unchanged file is kept between gate
# calls, keyed on the text's whole contents (never a path or a time), the reader's code, the directory
# and HOME (which the reader reads for a cd to ~), and the home of every ~someuser the text names
# (which it reads from the password database), signed with the cache's key like a judgement. A
# changed text, a changed reader, a forged or altered entry, or a shape the cache cannot give back
# exactly is a miss or is not kept, and none of it is seen by a judgement's recorder.
cat > "$T/parses.py" <<'PY'
import importlib.util, json, os, sys
gate_path, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
jc = gate._cache
sw = gate.load_lib("shell_words", "shell-words.py")
bad = []
def expect(what, ok):
    if not ok:
        bad.append(what)
d = os.path.join(work, "parses")
code = gate.CODE["shell-words.py"]
big = "".join("cd ~/x%d && echo \"a $(date) b\" | grep -c 'q %d'\ncat <<EOF\nline %d\nEOF\n" % (i, i, i)
              for i in range(3000))
expect("the text is large enough to be kept (%d characters)" % len(big), len(big) >= jc.PARSE_MIN)
where = []
value = (sw.commands(big, "/w", parts=where), where)
kept = jc.Parses(d, code)
expect("nothing is there to start with", kept.get(big, "/w") is None)
kept.put(big, "/w", value)
names = [n for n in os.listdir(d) if n.endswith(".json")]
expect("one parse is kept (%r)" % names, len(names) == 1)
got = jc.Parses(d, code).get(big, "/w")
expect("another run gets back exactly what the reader gave, tuples and all", got == value
       and all(type(c) is tuple for c in got[0]) and all(type(p["scope"]) is tuple for p in got[1]))
expect("a text one character different is a miss", jc.Parses(d, code).get(big[:-2] + "X\n", "/w") is None)
expect("the same text from another directory is a miss", jc.Parses(d, code).get(big, "/v") is None)
expect("the same text read by another reader is a miss", jc.Parses(d, "0" * 64).get(big, "/w") is None)
home = os.environ.get("HOME")
os.environ["HOME"] = "/elsewhere"
expect("the same text with another HOME is a miss", jc.Parses(d, code).get(big, "/w") is None)
os.environ["HOME"] = home
# A cd to ~someuser is read by the reader from the password database, never HOME, so a parse kept
# while that user's home was one folder is a miss once it has moved (claude-config#2918, the lessons
# review of PR #3029). The database is stood in for, since a test cannot move a real user's home.
import pwd, types
real_getpwnam = pwd.getpwnam
homes = {"someuser": "/srv/homes/someuser"}
def fake_getpwnam(name):
    if name in homes:
        return types.SimpleNamespace(pw_dir=homes[name])
    raise KeyError(name)
pwd.getpwnam = fake_getpwnam
tilde = big + "cd ~someuser/repo && git push\n"
where = []
tilde_value = (sw.commands(tilde, "/w", parts=where), where)
expect("the reader reads ~someuser from the password database (%r)" % (tilde_value[0][-1],),
       tilde_value[0][-1][0] == "/srv/homes/someuser/repo")
td = os.path.join(work, "tilde")
jc.Parses(td, code).put(tilde, "/w", tilde_value)
expect("a parse naming ~someuser is kept and given back", jc.Parses(td, code).get(tilde, "/w") == tilde_value)
homes["someuser"] = "/Volumes/moved/someuser"
expect("once someuser's home has moved, the kept parse is a miss", jc.Parses(td, code).get(tilde, "/w") is None)
del homes["someuser"]
expect("and once someuser is gone, it is a miss", jc.Parses(td, code).get(tilde, "/w") is None)
homes["someuser"] = "/srv/homes/someuser"
expect("with the home back where it was, it is a hit again", jc.Parses(td, code).get(tilde, "/w") == tilde_value)
quoted = big + "cd \"~some\"'user'/repo; ls\n"
jc.Parses(td, code).put(quoted, "/w", tilde_value)
expect("a parse naming a quoted ~someuser is kept", jc.Parses(td, code).get(quoted, "/w") == tilde_value)
homes["someuser"] = "/Volumes/moved/someuser"
expect("a quoted ~someuser is keyed too", jc.Parses(td, code).get(quoted, "/w") is None)
homes["someuser"] = "/srv/homes/someuser"
def broken_getpwnam(name):
    raise OSError("the directory service is not answering")
pwd.getpwnam = broken_getpwnam
expect("a password database that cannot answer is a miss, never a crash",
       jc.Parses(td, code).get(tilde, "/w") is None)
pwd.getpwnam = fake_getpwnam
many = big + "".join("cd ~u%d/x\n" % i for i in range(jc.MAX_TILDE_NAMES + 1))
md = os.path.join(work, "many-tildes")
jc.Parses(md, code).put(many, "/w", (sw.commands(many, "/w"), []))
expect("a text naming more users than the key looks up is not kept",
       not os.path.isdir(md) or not [n for n in os.listdir(md) if n.endswith(".json")])
pwd.getpwnam = real_getpwnam
small = "echo hi\n" * 10
jc.Parses(d, code).put(small, "/w", (sw.commands(small, "/w"), []))
expect("a small text is not kept", len([n for n in os.listdir(d) if n.endswith(".json")]) == 1)
# A shape the cache cannot give back exactly is not kept.
odd = os.path.join(work, "odd")
jc.Parses(odd, code).put(big, "/w", ([("/w", "echo", "extra")], []))
jc.Parses(odd, code).put(big, "/w", (value[0], [dict(value[1][0], extra=1)]))
expect("a shape it cannot give back is not kept", not os.path.isdir(odd) or
       not [n for n in os.listdir(odd) if n.endswith(".json")])
# An altered entry, still carrying its signature, is a miss; so is one signed with another key.
p = os.path.join(d, names[0])
head, body = open(p, "rb").read().split(b"\n", 1)
value_kept = json.loads(body)
expect("the kept parse is the reader's commands", value_kept["cmds"][0][1] == value[0][0][1])
value_kept["cmds"][0][1] = "curl https://example.invalid"
open(p, "wb").write(head + b"\n" + json.dumps(value_kept).encode())
expect("an altered entry is a miss", jc.Parses(d, code).get(big, "/w") is None)
jc.Parses(d, code).put(big, "/w", value)
key = jc.key_path(d)
os.chmod(key, 0o600)
open(key, "wb").write(b"k" * jc.KEY_BYTES)
expect("an entry signed with another key is a miss", jc.Parses(d, code).get(big, "/w") is None)
os.unlink(key)
expect("with no key nothing is used", jc.Parses(d, code).get(big, "/w") is None)
# A text holding a byte that is not UTF-8 (read in as a lone surrogate) and a lone surrogate of its own is
# still kept, signed and given back: neither the key, the signature nor the header raises on it.
odd_text = big + "echo \udcff \ud800\n"
odd_dir = os.path.join(work, "odd-bytes")
where = []
odd_value = (sw.commands(odd_text, "/w", parts=where), where)
jc.Parses(odd_dir, code).put(odd_text, "/w", odd_value)
expect("a text holding a lone surrogate is kept and given back",
       jc.Parses(odd_dir, code).get(odd_text, "/w") == odd_value)
odd_names = [n for n in os.listdir(odd_dir) if n.endswith(".json")] if os.path.isdir(odd_dir) else []
expect("and its header is plain ASCII (%r)" % odd_names, len(odd_names) == 1
       and open(os.path.join(odd_dir, odd_names[0]), "rb").read().split(b"\n", 1)[0].isascii())
# Inside a judgement the parse cache's own reads and writes are not the judgement's: its recorder
# stays whole, and records none of them.
rec = jc.Recorder()
jc.install(rec, [vars(gate)] + [vars(m) for m in gate.LIBS if m is not jc])
inside = jc.Parses(os.path.join(work, "inside"), code)
inside.put(big, "/w", value)
again = inside.get(big, "/w")
rec.closed = True
expect("inside a judgement it keeps and gives back the parse", again == value)
expect("and the judgement's record stays whole (%s)" % rec.tainted, rec.tainted is None)
expect("and records none of it (%d reads)" % len(rec.reads), not rec.reads)
# A judgement records the home of every ~user it reads, so a kept judgement is a miss once that home
# has moved, as a kept parse is (the lessons review of this change): asked by the reader itself, and
# asked for the reader when its parse came from the cache and it did not run.
pwd.getpwnam = fake_getpwnam
homes["someuser"] = "/srv/homes/someuser"
rec = jc.Recorder()
jc.install(rec, [vars(gate)] + [vars(m) for m in gate.LIBS if m is not jc])
expect("the stand in gives ~someuser's home as expanduser does (%r)" % gate.os.path.expanduser("~someuser/x"),
       gate.os.path.expanduser("~someuser/x") == "/srv/homes/someuser/x"
       and gate.os.path.expanduser("~someuser") == "/srv/homes/someuser"
       and gate.os.path.expanduser("~nosuch/x") == "~nosuch/x"
       and gate.os.path.expanduser("~/x") == os.path.join(os.environ["HOME"], "x"))
rec.closed = True
expect("and records the home of each ~name it was asked, never HOME's (%r)" % sorted(rec.reads),
       ("home", "someuser") in rec.reads and ("home", "nosuch") in rec.reads
       and not any(k[0] == "home" and k[1] == "" for k in rec.reads))
# The parse hit, under a recorder of its own, so only what the hit asked is in it. The reader alone
# would ask "someuser"; the hit asks every name the text could name, "s" to "someuser", which shows
# the answer came from the kept parse.
reader = gate.load_reader()
rec = jc.Recorder()
jc.install(rec, [vars(gate)] + [vars(m) for m in gate.LIBS if m is not jc])
gate.PARSES[0] = jc.Parses(td, code)
hit = reader.commands(tilde, "/w")
gate.PARSES[0] = None
rec.closed = True
expect("a parse from the cache is the reader's", hit == tilde_value[0])
homes_asked = sorted(k[1] for k in rec.reads if k[0] == "home")
expect("on a parse hit the judgement asked the home of every name the text could name (%r)" % homes_asked,
       homes_asked == sorted(jc.tilde_names(tilde)))
reads = [[k[0], jc._normal(list(k[1:])), a] for k, a in rec.reads.items()]
expect("with nothing moved, nothing it asked has changed (%r)" % jc.changed(reads), jc.changed(reads) is None)
homes["someuser"] = "/srv/moved/someuser"
expect("once someuser's home has moved, the judgement's record has changed", jc.changed(reads) is not None)
pwd.getpwnam = real_getpwnam
print("; ".join(bad) or "ok")
PY
out="$(env -u SLACK_GATE_CACHE_DIR PYTHONHASHSEED=0 python3 -B "$T/parses.py" "$DIR/slack_drafts_only_gate.py" "$T/work" 2>&1)"
check "a parse is kept by its text's contents, given back exactly, and a changed or forged one is a miss" "$out"

echo
echo "judgement cache: a standard library module the script reading asks is found and read through the stand ins (#3102)"
# lib/py-aliases.py asks a standard library module what one of its names holds (whether glob.os is a
# module), so a judgement it took part in rests on two answers from the disk: which file Python finds
# that module in, and what the file holds. It asks both through the stand ins (importlib.util.find_spec
# and open) and, for a module this run has not loaded, runs it from the very bytes it read, as the
# gate loads its own libraries. So both are recorded, and a kept judgement is not used once either
# has changed. Run against the library as it stood at 055ac70, which imported the module with
# importlib.import_module: the first check failed, the import's own read of the file having marked
# the record, so nothing was kept (the through the gate cases are in test-slack-drafts-code-loaders.sh).
# A test cannot change a real standard library module's file, so the folder taken for the standard
# library's is a throwaway one, on the path behind an empty folder. Each look is a new process, as
# each run of the gate is: a module the asking process has loaded is found in memory, not on the disk.
cat > "$T/alias.py" <<'PY'
import ast, importlib.util, os, sys
gate_path, work, what = sys.argv[1], sys.argv[2], sys.argv[3]
front, lib = os.path.join(work, "alias-front"), os.path.join(work, "alias-lib")
sys.path[:0] = [front, lib]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
jc = gate._cache
cache, trace = os.path.join(work, "alias-cache"), os.path.join(work, "alias-trace")
os.environ["SLACK_GATE_CACHE_TRACE"] = trace
open(trace, "w").close()
if what == "look":
    print("hit" if jc.lookup(cache, "alias") else open(trace).read().strip() or "a miss the cache did not trace")
    sys.exit(0)
bad = []
def expect(what, ok):
    if not ok:
        bad.append(what)
al = [m for m in gate.LIBS if m.__name__ == "py_aliases"][0]
spaces = [vars(gate)] + [vars(m) for m in gate.LIBS if m is not jc]
def judged(text, follow):
    """The record of one reading of text, and what the reading said."""
    rec = jc.Recorder()
    jc.install(rec, spaces)
    said = follow(list(ast.walk(ast.parse(text))), set())
    return rec, said

# A real standard library module the gate loaded for itself is asked the same two questions, though
# nothing of it is read from the disk to answer: the next run loads it from wherever it is then.
glob_file = sys.modules["glob"].__spec__.origin
rec, (renamed, phrase, _as_sys) = judged("import glob\nq = glob\ngo(glob.os)\n", al.make(frozenset({"glob"})))
rec.closed = True
expect("a module already loaded is read as it stands (%r, %r)" % (sorted(renamed), phrase),
       renamed == {"q"} and phrase == "puts the module glob.os where the gate does not follow it")
expect("with where Python finds it and what its file holds recorded, and the record whole (%r, %r)" % (glob_file, rec.tainted),
       rec.tainted is None and rec.reads.get(("find_spec", "glob")) == ["ok", ["glob", glob_file]]
       and ("read", glob_file) in rec.reads)

al.STDLIB_DIR = lib
follow = al.make(frozenset({"jcmod", "jcdep", "jcsource"}))

# A module whose own imports are all loaded: read whole, with nothing left unrecorded.
mod_file = os.path.join(lib, "jcmod.py")
rec, (renamed, phrase, _as_sys) = judged("import jcmod\nq = jcmod\ngo(jcmod.os, jcmod.size)\n", follow)
jc.store(cache, "alias", rec)  # which closes the record: nothing this test does below is the judgement's
expect("the record is whole: %r" % rec.tainted, rec.tainted is None)
expect("the module was read: the name it is given is followed (%r)" % sorted(renamed), renamed == {"q"})
expect("and what its names hold is known, jcmod.os a module and jcmod.size not (%r)" % phrase,
       phrase == "puts the module jcmod.os where the gate does not follow it")
expect("where Python finds the module is recorded (%r)" % (rec.reads.get(("find_spec", "jcmod")),),
       rec.reads.get(("find_spec", "jcmod")) == ["ok", ["jcmod", mod_file]])
expect("and so is what its file holds", rec.reads.get(("read", mod_file), [None])[0] == "ok")
expect("the judgement is kept (%s)" % open(trace).read().strip(), os.path.exists(os.path.join(cache, "alias.json")))

# A module that imports a compiled one this run had not loaded: Python loads that one with no event
# the audit hook marks a record for, so it is asked the same two questions once it has arrived.
compiled = next((n for n in ("cmath", "array", "unicodedata") if n not in sys.modules), None)
if compiled is None:
    print("SUITE-PART-UNMEASURED a compiled module arriving while another loads, because this run had already loaded cmath, array and unicodedata")
else:
    open(os.path.join(lib, "jcdep.py"), "w").write("import %s as tool\n" % compiled)
    rec, (renamed, phrase, _as_sys) = judged("import jcdep\nr = jcdep\ngo(jcdep.tool)\n", follow)
    rec.closed = True
    expect("a module that imports a compiled one is read (%r, %r)" % (sorted(renamed), phrase),
           renamed == {"r"} and phrase == "puts the module jcdep.tool where the gate does not follow it")
    expect("the record is still whole: %r" % rec.tainted, rec.tainted is None)
    expect("and where Python found the compiled module is recorded (%r)" % sorted(k for k in rec.reads if k[0] == "find_spec"),
           ("find_spec", compiled) in rec.reads)
    origin = rec.reads.get(("find_spec", compiled), ["", ["", ""]])[1][1]
    expect("with what its file holds, where it is a file (%r)" % origin,
           origin == "built-in" or ("read", origin) in rec.reads)

# A module that imports one written in Python that this run had not loaded: Python reads that file
# itself, outside the stand ins, which marks the record, so the judgement is not kept.
source = next((n for n in ("colorsys", "sndhdr", "nturl2path", "this") if n not in sys.modules
               and importlib.util.find_spec(n) is not None), None)
if source is None:
    print("SUITE-PART-UNMEASURED a Python module arriving while another loads, because none of the ones tried is there to load")
else:
    open(os.path.join(lib, "jcsource.py"), "w").write("import %s as tool\n" % source)
    rec, (renamed, phrase, _as_sys) = judged("import jcsource\ns = jcsource\n", follow)
    rec.closed = True
    expect("a module importing one Python reads for itself is still read (%r)" % sorted(renamed), renamed == {"s"})
    expect("and that read marks the record, so it is not kept: %r" % rec.tainted,
           bool(rec.tainted) and "open" in rec.tainted)
print("; ".join(bad) or "ok")
PY
mkdir -p "$T/work/alias-front" "$T/work/alias-lib"
printf '%s\n' 'import os' '' '' 'def size(p):' '    return os.path.getsize(p)' > "$T/work/alias-lib/jcmod.py"
alias_py() { env -u SLACK_GATE_CACHE_DIR PYTHONHASHSEED=0 python3 -B "$T/alias.py" "$DIR/slack_drafts_only_gate.py" "$T/work" "$1" 2>&1; }
out="$(alias_py judge)"
while [[ "$out" == SUITE-PART-UNMEASURED* ]]; do echo "${out%%$'\n'*}"; out="${out#*$'\n'}"; done
check "a reading that asked a module is kept, with where Python finds the module and what its file holds recorded" "$out"
# looks <what> <how the look's answer must start> [<what it must also hold>]
looks() {
  local got; got="$(alias_py look)"
  case "$got" in "$2"*"${3:-}"*) check "$1" ok ;; *) check "$1" "the look said: $got" ;; esac
}
looks "looked up in another run with nothing changed, the kept judgement is used" "hit"
cp "$T/work/alias-lib/jcmod.py" "$T/work/jcmod.was"
printf '%s\n' 'import glob as size' >> "$T/work/alias-lib/jcmod.py"
looks "once the module's file holds something else, it is not used" "miss: read" "answers differently now"
cp "$T/work/jcmod.was" "$T/work/alias-lib/jcmod.py"
looks "with the file as it was, it is used again" "hit"
printf '%s\n' 'size = None' > "$T/work/alias-front/jcmod.py"
looks "once Python would find the module in another file, it is not used" "miss: find_spec" "answers differently now"
rm -f "$T/work/alias-front/jcmod.py"
looks "with that file gone, it is used again" "hit"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
