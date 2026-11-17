"""The Slack drafts gate's cache of the calls it allowed (claude-config#2918).

Judging `bash tests/test-claude-sync.sh` takes the gate about four seconds of its eleven, and a
session runs the same line many times a day. The gate keeps, across its runs, the judgement of a
whole Bash call it allowed, so judging it again with nothing changed costs a lookup. Dan chose this
on 2026-11-14 knowing it does nothing for a cold run (a CI runner starts with no cache).

WHAT A KEPT JUDGEMENT IS KEYED ON (key()): the gate's own code and every library it ran, as the bytes
it ran them from; the Python (version, executable, platform, sys.path); the tool, the command, the
directory the payload gives and the directory the gate process runs in (which abspath and realpath
read); and every environment variable the gate reads by name (KEY_ENV). The directory is certain at
the top of a call, which is the only place a judgement is kept, so the key records it as certain.

WHAT IT RECORDS AND CHECKS AGAIN (Recorder): everything else the judgement read. Every disk read the
gate and its libraries make goes through one place, the stand ins install() puts in each one's
namespace under the names os, glob, importlib, ast and open, so a new direct call such as os.path.isfile
is recorded without anybody remembering to (L621). Each question is recorded with its answer: the
bytes of each file read (as a hash), each file test (isfile, isdir, exists, lexists, islink), each
realpath, size, access test, directory listing and walk, each glob, each import lookup, each
environment variable read by a name only known at run time, and the home of each ~user expanded (from
the password database, which the key does not hold). Before a kept judgement is used,
lookup() asks every one of them again and uses it only if every answer is the same.

FAIL CLOSED. A judgement is kept only when it is an allow and the recording is whole: anything the
stand ins do not know (an os attribute not classified here), any disk event Python raises outside
them (an audit hook sees open, listdir, scandir, subprocesses and the rest, from any route), a file
larger than MAX_READ, or a question answered two ways within one judgement marks it not keepable.
Any doubt on the way back (an entry that cannot be read, is not an entry, is not signed with this
cache's key, names an operation not listed here, or finds one answer changed) is a miss, and the call
is judged afresh. A refusal is never kept, so the cache can only skip the work of an allow, never
turn a refusal into one.

SIGNED (claude-config#2965). Each entry carries an HMAC of its body under a 32 byte key in
<cache folder>.key, beside the folder and never in it, made on the first store with mode 600. A key
that is missing (on a lookup), unreadable, a link, not this user's, or open to anyone else means no
cache: nothing is used or kept, and nothing unsigned ever is. So a process that can write entries
but not read that key cannot forge a kept allow. The key's bytes are never printed or traced.

ORDERED (claude-config#2965). Python iterates a set of strings in an order salted afresh in each
process, so a verdict resting on that order could differ between a kept judgement and a fresh one.
Nothing is kept or used unless string hashing is fixed (order_fixed()); the gate's wrapper runs it
with PYTHONHASHSEED=0, so the order is the same on every run.

WHERE: $HOME/.claude/state/slack-gate-cache (the sync never carries ~/.claude/state), or
SLACK_GATE_CACHE_DIR, with the key beside it. Under a test run (HOOK_TESTS_RUNNING=1) it is off unless a directory is named,
so no suite reads or writes this Mac's. At most MAX_ENTRIES entries and MAX_TOTAL bytes, the least
recently used removed first; one file per key, written to a temporary name and renamed into place.
SLACK_GATE_CACHE_TRACE names a file each run appends what the cache did to (a suite's view of it).
"""
import ast as _ast
import builtins
import glob as _glob
import hashlib
import hmac
import importlib.machinery as _machinery
import importlib.util as _util
import io
import json
import os as _os
import re
import secrets
import stat as _stat
import sys
import tempfile
import time

FORMAT = 2  # 2: signed with the cache's key rather than checksummed (claude-config#2965)
MAX_ENTRIES = 200
MAX_ENTRY = 4 * 1024 * 1024  # bytes of one entry; a larger judgement is not kept
MAX_TOTAL = 64 * 1024 * 1024  # bytes of all entries
MAX_READ = 8 * 1024 * 1024  # a file larger than this is read as it always was, and nothing is kept

# The environment variables the gate and its libraries read by name. test-judgement-cache.sh fails
# when a name read in their source is missing here. A variable read by a name worked out at run time
# is recorded and checked again instead (Recorder.env).
KEY_ENV = ("CARGO_TARGET_DIR", "CDPATH", "CURL_HOME", "DATA_GUARDED_RE", "GATE_DIR", "HOME", "HOOK_TESTS_RUNNING",
           "PATH", "PYTHONPATH", "SLACK_GATE_CACHE_DIR", "SLACK_GATE_CACHE_TRACE", "SLACK_GATE_TICK_BUDGET",
           "SLACK_GATE_UNWORKED_PATHS", "VIRTUAL_ENV", "XDG_CONFIG_HOME")

# Every module the gate and its libraries import, and why its disk reads are seen. test-judgement-cache.sh
# fails on an import of a module not listed here, on `from M import` of one that is not "pure", and on a
# proxied one imported inside a function or under another name, where it would bypass install().
#   pure: reads no disk.  proxied: replaced by install()'s stand in.  audited: what it does to the disk
#   raises an audit event (open, os.listdir, subprocess.Popen, ...) that marks the judgement not keepable.
# A module first imported in the middle of a judgement reads its own files to load, which the audit
# hook sees, so that judgement is not kept (the gate's lazy `import tokenize`, for instance).
MODULES = {
    "ast": "proxied", "bisect": "pure", "fnmatch": "pure", "functools": "pure", "json": "pure", "re": "pure",
    "shlex": "pure", "signal": "pure", "sys": "pure", "time": "pure", "warnings": "pure", "zlib": "pure",
    "faulthandler": "pure", "hashlib": "pure", "tomllib": "pure", "atexit": "pure",
    # generate_tokens over text in memory; tokenize.open would read a file, through the builtin open,
    # which the audit hook sees.
    "tokenize": "pure",
    "os": "proxied", "glob": "proxied", "importlib.util": "proxied", "importlib.machinery": "proxied",
    "io": "audited", "lzma": "audited", "tarfile": "audited", "zipfile": "audited", "configparser": "audited",
    "tempfile": "audited", "shutil": "audited", "subprocess": "audited",
    # lib/gate-qos.py's raise of the gate's scheduling priority, before any judgement starts (#2918).
    # Every ctypes call raises an audit event under ctypes., which UNRECORDED_EVENTS taints.
    "ctypes": "audited",
}
# An audited module some of whose functions read the disk with no audit event (shutil.which and its
# stat and access helpers): only the names listed may be used, which test-judgement-cache.sh checks.
MODULE_USES = {"shutil": ("rmtree",)}

# What an audit event outside the stand ins means: a read or an effect nobody recorded.
UNRECORDED_EVENTS = ("open", "os.", "subprocess.", "socket.", "shutil.", "tempfile.", "glob.", "pathlib.",
                     "urllib.", "http.", "ctypes.", "fcntl.", "mmap.", "pty.", "sqlite3.", "webbrowser.",
                     "zipimport.", "pwd.", "grp.")


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _read_hash(path):
    """The hash of a file's bytes, as the gate's read of it finds them, or None past MAX_READ."""
    with builtins.open(path, mode="rb") as f:
        data = f.read(MAX_READ + 1)
    return None if len(data) > MAX_READ else _sha(data)


def _dirsplit(top):
    """One directory as os.walk (topdown, no onerror, links not followed) splits it: [dirs, others].
    Raises OSError where os.walk skips the directory."""
    dirs, others = [], []
    with _os.scandir(top) as entries:
        for entry in entries:
            try:
                is_dir = entry.is_dir()
            except OSError:
                is_dir = False
            (dirs if is_dir else others).append(entry.name)
    return [dirs, others]


def _spec_form(spec):
    return None if spec is None else [spec.name, spec.origin]


# Every question a judgement can ask of the disk or the environment: (how to ask it, the form its
# answer is recorded in). lookup() asks them again the same way. Arguments are strings, or a list of
# strings for pathfinder.
OPS = {
    "isfile": (_os.path.isfile, None), "isdir": (_os.path.isdir, None), "exists": (_os.path.exists, None),
    "lexists": (_os.path.lexists, None), "islink": (_os.path.islink, None),
    "realpath": (_os.path.realpath, None), "getsize": (_os.path.getsize, None),
    "access": (_os.access, None), "listdir": (_os.listdir, None), "getcwd": (_os.getcwd, None),
    "dirsplit": (_dirsplit, None), "glob": (_glob.glob, None),
    "find_spec": (_util.find_spec, _spec_form),
    "pathfinder": (lambda name, dirs: _machinery.PathFinder.find_spec(name, list(dirs)), _spec_form),
    "read": (_read_hash, None), "env": (_os.environ.get, None),
    # A user's home by name, as ~name gives it (os.path.expanduser): read from the password database,
    # which no key holds, so a judgement that reads one is kept only while it is the same.
    "home": (lambda name: _os.path.expanduser("~" + name), None),
}


def _ask(op, args):
    """(the real answer, its recorded form); the form of an exception is ["raise", its type, errno]."""
    fn, form = OPS[op]
    try:
        value = fn(*args)
    except Exception as e:
        return e, ["raise", type(e).__name__, getattr(e, "errno", None)]
    return value, ["ok", form(value) if form else value]


def _normal(x):
    """x as JSON gives it back (tuples as lists), so a recorded and a fresh answer compare alike."""
    return json.loads(json.dumps(x))


class Recorder:
    """The record of one judgement: every question asked, with its answer, and the first reason the
    record is not whole (tainted)."""

    def __init__(self):
        self.reads = {}  # (op, args...) -> recorded answer
        self.tainted = None
        self.inside = 0  # >0 while a stand in is asking, so the audit hook knows the event is recorded
        self.closed = False

    def taint(self, why):
        if self.tainted is None:
            self.tainted = why

    def asked(self, op, *args):
        """Ask op of the disk, record the answer, and give the caller exactly what the real call gives."""
        self.inside += 1
        try:
            value, answer = _ask(op, args)
        finally:
            self.inside -= 1
        k = (op,) + args
        if k in self.reads:
            if self.reads[k] != answer:
                self.taint(f"{op} {args!r} answered two ways in one judgement")
        else:
            self.reads[k] = _normal(answer) if isinstance(value, list) else answer
        if isinstance(value, Exception):
            raise value
        return list(value) if isinstance(value, list) else value

    def path_asked(self, op, name):
        """A stand in for a one path question: recorded for a string path, passed through and marking
        the record not whole for anything else (bytes, a path object, a descriptor)."""
        def call(path, *rest, **kw):
            if rest or kw or not isinstance(path, str):
                self.taint(f"{name} called as ({path!r}, {rest!r}, {kw!r})")
                return OPS[op][0](path, *rest, **kw)
            return self.asked(op, path)
        call.__name__ = name
        return call

    def audit(self, event, args):
        if self.inside or self.closed or self.tainted:
            return
        if event.startswith(UNRECORDED_EVENTS):
            # Where it came from, by file and line (read from the frames, not the files), so a trace
            # says which code reached the disk around the stand ins.
            where, f = [], sys._getframe(1)
            while f is not None and len(where) < 6:
                where.append(f"{_os.path.basename(f.f_code.co_filename)}:{f.f_lineno}")
                f = f.f_back
            self.taint(f"the audit event {event} {str(args)[:120]} outside the recorder, from {' < '.join(where)}")

    # The stand ins for open, os.walk, glob.glob, the import lookups and the environment.

    def open(self, file, mode="r", buffering=-1, encoding=None, errors=None, newline=None, closefd=True,
             opener=None):
        if (not isinstance(file, str) or set(mode) - set("rbt") or buffering != -1 or not closefd
                or opener is not None):
            self.taint(f"open({file!r}, {mode!r}) is not a plain read")
            return builtins.open(file, mode, buffering, encoding=encoding, errors=errors, newline=newline, closefd=closefd, opener=opener)
        self.inside += 1
        try:
            try:
                with builtins.open(file, mode="rb") as f:
                    data = f.read(MAX_READ + 1)
            except Exception as e:
                answer = ["raise", type(e).__name__, getattr(e, "errno", None)]
                self.reads.setdefault(("read", file), answer)
                if self.reads[("read", file)] != answer:
                    self.taint(f"read {file!r} answered two ways in one judgement")
                raise
            if len(data) > MAX_READ:
                self.taint(f"{file} is larger than {MAX_READ} bytes")
                return builtins.open(file, mode, buffering, encoding=encoding, errors=errors, newline=newline)
        finally:
            self.inside -= 1
        answer = ["ok", _sha(data)]
        if self.reads.setdefault(("read", file), answer) != answer:
            self.taint(f"read {file!r} answered two ways in one judgement")
        # The bytes recorded are the bytes the caller reads, so nothing can change between the two.
        if "b" in mode:
            return io.BytesIO(data)
        return io.TextIOWrapper(io.BytesIO(data), encoding=encoding, errors=errors, newline=newline)

    def walk(self, top, topdown=True, onerror=None, followlinks=False):
        """os.walk as Python 3.14 does it with its defaults, each directory split by the recorded
        dirsplit and each link test recorded, so a caller pruning dirs walks the same tree."""
        if topdown is not True or onerror is not None or followlinks is not False or not isinstance(top, str):
            self.taint(f"os.walk({top!r}, {topdown!r}, {onerror!r}, {followlinks!r})")
            yield from _os.walk(top, topdown, onerror, followlinks)
            return
        stack = [top]
        while stack:
            top = stack.pop()
            try:
                dirs, others = self.asked("dirsplit", top)
            except OSError:
                continue
            dirs, others = list(dirs), list(others)
            yield top, dirs, others
            for name in reversed(dirs):
                new_path = _os.path.join(top, name)
                if not self.asked("islink", new_path):
                    stack.append(new_path)

    def glob(self, pathname, **kw):
        if kw or not isinstance(pathname, str):
            self.taint(f"glob.glob({pathname!r}, {kw!r})")
            return _glob.glob(pathname, **kw)
        return self.asked("glob", pathname)

    def find_spec(self, name, package=None):
        if package is not None or not isinstance(name, str):
            self.taint(f"importlib.util.find_spec({name!r}, {package!r})")
            return _util.find_spec(name, package)
        self.inside += 1
        try:
            try:
                spec = _util.find_spec(name)
            except Exception as e:
                self._note("find_spec", (name,), ["raise", type(e).__name__, getattr(e, "errno", None)])
                raise
        finally:
            self.inside -= 1
        self._note("find_spec", (name,), ["ok", _spec_form(spec)])
        return spec

    def pathfinder(self, name, path=None, target=None):
        if target is not None or not isinstance(name, str) or not isinstance(path, (list, tuple)) \
                or not all(isinstance(p, str) for p in path):
            self.taint(f"PathFinder.find_spec({name!r}, {path!r})")
            return _machinery.PathFinder.find_spec(name, path, target)
        self.inside += 1
        try:
            try:
                spec = _machinery.PathFinder.find_spec(name, list(path))
            except Exception as e:
                self._note("pathfinder", (name, tuple(path)), ["raise", type(e).__name__, getattr(e, "errno", None)])
                raise
        finally:
            self.inside -= 1
        self._note("pathfinder", (name, tuple(path)), ["ok", _spec_form(spec)])
        return spec

    def parse(self, source, filename="<unknown>", *rest, **kw):
        """ast.parse. On a syntax error CPython opens the file it was told the source came from (by
        default "<unknown>", relative to the process's directory) to quote the line, so that attempt
        is recorded as a read of it, and the open itself is the recorder's."""
        self.inside += 1
        try:
            return _ast.parse(source, filename, *rest, **kw)
        except SyntaxError:
            if isinstance(filename, str):
                self._note("read", (filename,), _ask("read", (filename,))[1])
            else:
                self.taint(f"ast.parse given the file name {filename!r}")
            raise
        finally:
            self.inside -= 1

    def _note(self, op, args, answer):
        answer = _normal(answer)
        if self.reads.setdefault((op,) + args, answer) != answer:
            self.taint(f"{op} {args!r} answered two ways in one judgement")

    def env(self, name):
        if not isinstance(name, str):
            self.taint(f"the environment read by {name!r}")
            return _os.environ.get(name)
        return self.asked("env", name)


class _StandIn:
    """A module as the gate sees it once install() has run: the attributes classified here are set on
    it, the pure ones as the real module's own and the ones that read the disk as the recorder's. Any
    other attribute is the real module's, and asking for it marks the record not whole."""

    def __init__(self, real, recorder, label, pure=(), asked=None):
        self.__dict__["_real"], self.__dict__["_recorder"], self.__dict__["_label"] = real, recorder, label
        for name in pure:
            if hasattr(real, name):
                self.__dict__[name] = getattr(real, name)
        self.__dict__.update(asked or {})

    def __getattr__(self, name):
        self._recorder.taint(f"{self._label}.{name}, which the recorder does not know")
        return getattr(self._real, name)


class _Environ:
    """os.environ as the gate sees it: each read by name recorded; anything else (items, iteration)
    marks the record not whole."""

    def __init__(self, recorder):
        self._recorder = recorder

    def get(self, name, default=None):
        value = self._recorder.env(name)
        return default if value is None else value

    def __getitem__(self, name):
        value = self._recorder.env(name)
        if value is None:
            raise KeyError(name)
        return value

    def __contains__(self, name):
        return self._recorder.env(name) is not None

    def __iter__(self):
        self._recorder.taint("os.environ iterated")
        return iter(_os.environ)

    def __len__(self):
        self._recorder.taint("os.environ counted")
        return len(_os.environ)

    def __getattr__(self, name):
        self._recorder.taint(f"os.environ.{name}")
        return getattr(_os.environ, name)


PATH_PURE = ("join", "dirname", "basename", "normpath", "isabs", "splitext", "split", "commonpath",
             "commonprefix", "normcase", "abspath", "relpath", "splitdrive", "splitroot", "sep",
             "pathsep", "curdir", "pardir", "extsep", "altsep", "devnull", "defpath")
PATH_ASKED = ("isfile", "isdir", "exists", "lexists", "islink", "realpath", "getsize")
OS_PURE = ("sep", "pathsep", "curdir", "pardir", "extsep", "altsep", "linesep", "devnull", "name", "fspath",
           "fsencode", "fsdecode", "F_OK", "R_OK", "W_OK", "X_OK")


def stand_ins(recorder):
    """{name: the stand in} for every name install() replaces."""
    def expanduser(p):
        # ~ and ~/ are HOME's, which the key holds. ~name is the password database's, which it does
        # not: the home is asked as a recorded question, so a kept judgement that read one is a miss
        # once that user's home has moved (claude-config#2918, the lessons review of PR #3029). The
        # rest is posixpath.expanduser's own arithmetic on that home.
        if not isinstance(p, str):
            recorder.taint(f"os.path.expanduser({p!r})")
            return _os.path.expanduser(p)
        if not p.startswith("~") or p == "~" or p.startswith("~/"):
            return _os.path.expanduser(p)
        cut = p.find("/", 1)
        cut = len(p) if cut < 0 else cut
        home = recorder.asked("home", p[1:cut])
        if home == p[:cut]:
            return p  # no such user
        return (home.rstrip("/") + p[cut:]) or "/"

    asked = {n: recorder.path_asked(n, "os.path." + n) for n in PATH_ASKED}
    asked["expanduser"] = expanduser
    path = _StandIn(_os.path, recorder, "os.path", PATH_PURE, asked)
    environ = _Environ(recorder)

    def access(p, mode, **kw):
        if kw or not isinstance(p, str) or not isinstance(mode, int):
            recorder.taint(f"os.access({p!r}, {mode!r}, {kw!r})")
            return _os.access(p, mode, **kw)
        return recorder.asked("access", p, mode)

    def listdir(p="."):
        if not isinstance(p, str):
            recorder.taint(f"os.listdir({p!r})")
            return _os.listdir(p)
        return recorder.asked("listdir", p)

    os_ = _StandIn(_os, recorder, "os", OS_PURE, {
        "path": path, "environ": environ, "getenv": environ.get, "getcwd": lambda: recorder.asked("getcwd"),
        "access": access, "listdir": listdir, "walk": recorder.walk})
    glob_ = _StandIn(_glob, recorder, "glob", ("escape", "has_magic"), {"glob": recorder.glob})
    util = _StandIn(_util, recorder, "importlib.util", ("spec_from_file_location", "module_from_spec"),
                    {"find_spec": recorder.find_spec})
    finder = _StandIn(_machinery.PathFinder, recorder, "importlib.machinery.PathFinder", (),
                      {"find_spec": recorder.pathfinder})
    machinery = _StandIn(_machinery, recorder, "importlib.machinery", (), {"PathFinder": finder})
    importlib_ = _StandIn(sys.modules["importlib"], recorder, "importlib", (), {"util": util, "machinery": machinery})
    # ast is pure but for parse (Recorder.parse), so the stand in carries every name the module has.
    ast_ = _StandIn(_ast, recorder, "ast", [n for n in vars(_ast) if not n.startswith("__")],
                    {"parse": recorder.parse})
    return {"os": os_, "glob": glob_, "importlib": importlib_, "ast": ast_, "open": recorder.open}


def install(recorder, namespaces):
    """Put the stand ins in each namespace (the gate's globals, each library's), and the audit hook in
    the process, so every disk read a judgement makes from here on is recorded or marks it not whole.
    open is set in every namespace, where it shadows the builtin; the others where the name is bound."""
    proxies = stand_ins(recorder)
    for ns in namespaces:
        for name, proxy in proxies.items():
            if name == "open" or name in ns:
                ns[name] = proxy
    sys.addaudithook(recorder.audit)
    _RECORDERS.append(recorder)
    return proxies


# Every recorder install() put in place, so the kept parses' own disk work (Parses) is never taken
# for the judgement's.
_RECORDERS = []


class _Quiet:
    """While inside, the audit hook of every recorder in place ignores what this module does itself."""

    def __enter__(self):
        for r in _RECORDERS:
            r.inside += 1

    def __exit__(self, *exc):
        for r in _RECORDERS:
            r.inside -= 1


# The cache itself.

def trace(line):
    where = _os.environ.get("SLACK_GATE_CACHE_TRACE")
    if where:
        try:
            with builtins.open(where, "a", encoding="utf-8", errors="replace") as f:
                f.write(line + "\n")
        except OSError:
            pass


def where():
    """The cache's directory, or (None, why it is off)."""
    named = _os.environ.get("SLACK_GATE_CACHE_DIR")
    if named:
        return named, None
    if _os.environ.get("HOOK_TESTS_RUNNING") == "1":
        return None, "a test run names no cache directory"
    home = _os.environ.get("HOME")
    if not home:
        return None, "HOME is not set"
    return _os.path.join(home, ".claude", "state", "slack-gate-cache"), None


class Call:
    """One Bash call as the cache sees it: its directory and key."""

    def __init__(self, dirpath, k):
        self.dirpath, self.key = dirpath, k

    def hit(self):
        """Whether a kept allow answers this call. A fault in the lookup is a miss: the call is judged."""
        try:
            return lookup(self.dirpath, self.key)
        except Exception as e:
            trace(f"miss: the lookup raised {type(e).__name__}")
            return False

    def record(self, namespaces):
        recorder = Recorder()
        install(recorder, namespaces)
        return recorder

    def keep(self, recorder):
        """Keep the allow just judged. A fault here only means nothing is kept: the call was judged, and
        what it was judged to be is unchanged, so it is traced and the allow goes out as judged."""
        try:
            store(self.dirpath, self.key, recorder)
        except Exception as e:
            trace(f"not stored: storing it raised {type(e).__name__}")


def call(command, cwd, code, here, gate_file, as_itself):
    """The Call for a Bash call, or None where the cache is off or the key cannot be worked out (the
    call is then judged afresh and nothing is kept). code is {library: hash} for what the gate ran;
    the gate's own file, its wrapper and the folder it runs from are added here. as_itself is whether
    the gate is the program Python was asked to run: imported by another (a suite's shim that replaces
    one of its functions), the code that judges is more than the gate's, and the key cannot cover it."""
    if not as_itself:
        trace("off: the gate was not run as itself")
        return None
    dirpath, why = where()
    if not dirpath:
        trace("off: " + why)
        return None
    try:
        # Code Python runs before any script, from site-packages, is part of what judges too.
        site = {n: file_hash(sys.modules[n].__file__) for n in ("sitecustomize", "usercustomize")
                if getattr(sys.modules.get(n), "__file__", None)}
        code = dict(code, here=here, gate=file_hash(_os.path.abspath(gate_file)), site=site,
                    modules=sorted(sys.modules),
                    wrapper=file_hash(_os.path.join(here, "slack-drafts-only-gate.sh")))
        return Call(dirpath, key(command, cwd, code))
    except Exception as e:
        trace(f"off: {type(e).__name__} working out the key")
        return None


def file_hash(path):
    with builtins.open(path, mode="rb") as f:
        return _sha(f.read())


def key(command, cwd, code):
    """The key of a Bash call: code is {name: hash} for the gate, its wrapper and each library it ran."""
    parts = {
        "format": FORMAT, "code": code, "tool": "Bash", "command": command, "cwd": cwd, "cwd_known": True,
        "process_cwd": _os.getcwd(),
        "python": [sys.version, sys.executable, sys.platform, list(sys.path), list(sys.flags)],
        "env": {n: _os.environ.get(n) for n in KEY_ENV},
    }
    return _sha(json.dumps(parts, sort_keys=True).encode("utf-8", errors="surrogatepass"))


ORDER_RANDOM = ("string hashing is random in this process (the gate was not run with PYTHONHASHSEED=0), "
                "so the order it iterates a set in, and any verdict resting on that order, can differ "
                "from one run to the next")


def order_fixed():
    """Whether the order this process iterates a set in is the same in every run given the same
    inputs. Python orders a set of strings by their hashes, salted afresh in each process unless
    hashing is fixed. The gate's sets hold strings and tuples of them, and its sets of id() values
    (which differ between runs) are only asked whether they hold one, never iterated (read on
    2026-11-14). So with hashing fixed (the interpreter's own flag, which PYTHONHASHSEED=0
    clears and -E, -I or -R set again) a judgement is as deterministic as its recorded inputs, and
    sys.flags in the key keeps one made otherwise apart. Without it nothing is kept or used: a kept
    verdict would be one ordering's, where a fresh one could take another (claude-config#2965)."""
    return sys.flags.hash_randomization == 0


KEY_BYTES = 32


def key_path(dirpath):
    """Where the signing key for the cache in dirpath lives: beside the folder, never in it, so
    nothing that writes or evicts entries touches it."""
    return _os.path.normpath(dirpath) + ".key"


def _read_key(path):
    """The key's bytes, or None where there is no usable key: missing, a link, not a regular file, not
    this user's, readable or writable by anyone else, or not KEY_BYTES long."""
    try:
        # Judged before it is opened, so a link or a pipe is never followed or waited on, and again
        # once open: the same file (device and inode), every test passed again on what was opened.
        def usable(st):
            return (_stat.S_ISREG(st.st_mode) and st.st_uid == _os.getuid() and not st.st_mode & 0o077
                    and st.st_size == KEY_BYTES)
        named = _os.lstat(path)
        if not usable(named):
            return None
        with builtins.open(path, mode="rb", buffering=0) as f:
            opened = _os.fstat(f.fileno())
            if not usable(opened) or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
                return None
            data = f.read(KEY_BYTES + 1)
    except OSError:
        return None
    return data if len(data) == KEY_BYTES else None


def signing_key(dirpath, create):
    """The key the entries in dirpath are signed with, or None, which means no cache: nothing is used
    and nothing is kept, never an unsigned entry. Only store() makes one (create=True), mode 600,
    written whole under a temporary name and linked into place, so a reader never sees half of it and
    of two runs making one at once, the first link wins and both use it. A key that is there but
    unusable (unreadable, readable by others, a link) is never replaced: it stays no key until put
    right. The key's bytes are never printed or traced."""
    path = key_path(dirpath)
    found = _read_key(path)
    if found is not None or not create or _os.path.lexists(path):
        return found
    parent = _os.path.dirname(path) or "."
    try:
        _os.makedirs(parent, mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".tmp-key-", suffix=".part")  # made mode 600
        try:
            with _os.fdopen(fd, "wb") as f:
                f.write(secrets.token_bytes(KEY_BYTES))
            try:
                _os.link(tmp, path)
            except FileExistsError:
                pass  # another run linked its key first, and that key is the one
        finally:
            _os.unlink(tmp)
    except OSError:
        return None
    return _read_key(path)


def _signature(secret, entry):
    body = {k: entry[k] for k in ("format", "key", "verdict", "reads")}
    data = json.dumps(body, sort_keys=True).encode("utf-8", errors="surrogatepass")
    return hmac.new(secret, data, hashlib.sha256).hexdigest()


def changed(reads):
    """The first recorded question whose answer is not the same now, as a phrase, or None."""
    for op, args, answer in reads:
        if op not in OPS or not isinstance(args, list):
            return f"{op!r} is not a question this cache asks"
        call = [tuple(a) if isinstance(a, list) else a for a in args]
        if not all(isinstance(a, (str, int, tuple)) for a in call):
            return f"{op} {args!r} is not a question this cache asks"
        _, now = _ask(op, call)
        if _normal(now) != answer:
            return f"{op} {args!r} answers differently now"
    return None


def lookup(dirpath, k):
    """True when the kept judgement for key k is an allow and every question it asked is answered the
    same now. Any doubt is False."""
    if not order_fixed():
        trace("miss: " + ORDER_RANDOM)
        return False
    secret = signing_key(dirpath, False)
    if secret is None:
        trace("miss: no signing key")
        return False
    path = _os.path.join(dirpath, k + ".json")
    try:
        with builtins.open(path, mode="rb") as f:
            raw = f.read(MAX_ENTRY + 1)
    except FileNotFoundError:
        trace("miss: no entry")
        return False
    except OSError as e:
        trace(f"miss: the entry could not be read ({type(e).__name__})")
        return False
    try:
        entry = json.loads(raw)
        ok = (isinstance(entry, dict) and entry.get("format") == FORMAT and entry.get("key") == k
              and entry.get("verdict") == "allow" and isinstance(entry.get("reads"), list)
              and isinstance(entry.get("sig"), str) and len(raw) <= MAX_ENTRY
              and all(isinstance(r, list) and len(r) == 3 for r in entry["reads"])
              and hmac.compare_digest(entry["sig"], _signature(secret, entry)))
    except Exception as e:  # anything at all wrong with it is no judgement
        trace(f"miss: the entry is not an entry ({type(e).__name__})")
        return False
    if not ok:
        trace("miss: the entry is not a whole allow for this key")
        return False
    try:
        why = changed(entry["reads"])
    except Exception as e:
        why = f"checking it raised {type(e).__name__}"
    if why:
        trace("miss: " + why)
        return False
    try:
        _os.utime(path)  # most recently used, for evict()
    except OSError:
        pass
    trace("hit")
    return True


def store(dirpath, k, recorder):
    """Keep an allow whose record is whole and still true now."""
    recorder.closed = True
    if recorder.tainted:
        trace("not stored: " + recorder.tainted)
        return
    reads = [[key_[0], _normal(list(key_[1:])), answer] for key_, answer in recorder.reads.items()]
    why = changed(reads)
    if why:
        trace("not stored: something changed while it was judged: " + why)
        return
    if not order_fixed():
        trace("not stored: " + ORDER_RANDOM)
        return
    secret = signing_key(dirpath, True)
    if secret is None:
        trace("not stored: no signing key")
        return
    entry = {"format": FORMAT, "key": k, "verdict": "allow", "reads": reads}
    entry["sig"] = _signature(secret, entry)
    data = json.dumps(entry).encode("utf-8", errors="surrogatepass")
    if len(data) > MAX_ENTRY:
        trace(f"not stored: the entry would be {len(data)} bytes")
        return
    try:
        _write(dirpath, k + ".json", data)
    except OSError as e:
        trace(f"not stored: {type(e).__name__} writing it")
        return
    trace("stored")
    evict(dirpath)


def evict(dirpath, max_entries=None, max_total=None):
    """Remove the least recently used entries past max_entries or max_total bytes, and any temporary
    file an interrupted write left more than an hour ago."""
    max_entries = MAX_ENTRIES if max_entries is None else max_entries
    max_total = MAX_TOTAL if max_total is None else max_total
    entries = []
    try:
        names = _os.listdir(dirpath)
    except OSError:
        return
    for name in names:
        p = _os.path.join(dirpath, name)
        try:
            st = _os.stat(p)
        except OSError:
            continue
        if name.endswith(".json"):
            entries.append((st.st_mtime, st.st_size, p))
        elif name.startswith(".tmp-") and st.st_mtime < time.time() - 3600:
            try:
                _os.unlink(p)
            except OSError:
                pass
    entries.sort(reverse=True)  # newest first
    total = 0
    for i, (_, size, p) in enumerate(entries):
        total += size
        if i >= max_entries or total > max_total:
            try:
                _os.unlink(p)
            except OSError:
                pass


# THE READER'S PARSES OF LARGE TEXTS, KEPT BETWEEN RUNS (claude-config#2918, Dan's decision of
# 2026-11-15). A kept judgement answers only the very call it judged with nothing changed; a parse is
# kept for any call that reads the same text. Judging `bash tests/test-claude-sync.sh` reads two texts
# of 64 KB or more, the suite (1.8 MB) and claude-sync (1 MB), and reading them is 0.7 s of the four
# seconds; every other text it reads is smaller, 1,658 of them in 0.05 s (measured 2026-11-15).
#
# KEYED (Parses.key) on the text's whole contents (its hash), never a path or a time; the reader's
# code, as the bytes the gate ran it from; the directory it is read from; HOME, which the reader
# reads for a cd to ~; the home of every user a ~someuser in the text names (Parses.tilde_homes),
# which it reads from the password database; and the Python. A text with any one of these different
# is a miss.
# SIGNED with the judgements' key (signing_key): the entry's body, as the bytes written, under an HMAC
# with its key in a header line, so checking it costs no second serialisation. Anything wrong with an
# entry is a miss and the text is read afresh. GIVEN BACK EXACTLY: a parse is kept only in the shape
# _parse_encode knows (commands as (directory, text) pairs, parts with exactly PART_KEYS), every
# value checked as it is written, so what comes back equals what the reader gave, tuples as tuples.
# NOT THE JUDGEMENT'S: the disk work here is done under _Quiet, so a judgement's recorder neither
# records it nor is marked not whole by it. That is sound because the parse is a function of its key
# alone, the text itself was read, and recorded, by the judgement, and on a hit the gate asks the home
# of every ~user the text could name through the judgement's own os (remember_readings in the gate),
# so the judgement records those too, as it would had the reader run.
# Kept in the judgements' folder, named parse-<key>.json, and bounded and evicted with them.
PARSE_FORMAT = 1
PARSE_MIN = 64 * 1024  # characters: a smaller text is read in a few milliseconds, less than keeping it
MAX_PARSE = 16 * 1024 * 1024  # bytes of one kept parse; the claude-sync suite's is about 4 MB
PART_KEYS = ("start", "end", "scope", "inner", "openers", "how")
_SCALARS = (str, int, bool, type(None))


def _scalars(t):
    if type(t) is not tuple or not all(type(x) in _SCALARS for x in t):
        raise ValueError("not a tuple of plain values")
    return list(t)


def _parse_encode(value):
    """(commands, parts) as JSON can carry them, or ValueError for any shape this cannot give back
    exactly."""
    cmds, parts = value
    if type(cmds) is not list or type(parts) is not list:
        raise ValueError("not lists")
    out_cmds = []
    for c in cmds:
        if len(c) != 2:
            raise ValueError("a command is not a (directory, text) pair")
        out_cmds.append(_scalars(c))
    out_parts = []
    for p in parts:
        if type(p) is not dict or tuple(p) != PART_KEYS:
            raise ValueError("a part does not hold exactly %s" % ", ".join(PART_KEYS))
        if not all(type(p[k]) in _SCALARS for k in ("start", "end", "how")):
            raise ValueError("a part's start, end or how is not a plain value")
        if type(p["inner"]) is not list or type(p["openers"]) is not list:
            raise ValueError("a part's inner or openers is not a list")
        out_parts.append([p["start"], p["end"], _scalars(p["scope"]), [_scalars(x) for x in p["inner"]],
                          [_scalars(x) for x in p["openers"]], p["how"]])
    return {"cmds": out_cmds, "parts": out_parts}


def _parse_decode(enc):
    cmds = [tuple(c) for c in enc["cmds"]]
    parts = [{"start": a, "end": b, "scope": tuple(sc), "inner": [tuple(x) for x in inner],
              "openers": [tuple(x) for x in openers], "how": how}
             for a, b, sc, inner, openers, how in enc["parts"]]
    return cmds, parts


# A cd to ~someuser is read by the reader (os.path.expanduser) from the password database, not HOME,
# so a parse depends on where every user it names has their home (the lessons review of PR #3029).
# The names it can ask are found in the text as written: whatever follows a ~ up to a slash or white
# space, with the quotes and backslashes the reader would take out removed, and every leading part of
# that, since a word can end at any character the shell treats as the end of one (`cd ~bob;`). That
# asks more names than the reader would, each a lookup of a fraction of a millisecond: the claude-sync
# suite and claude-sync between them name 20, about 4 ms in all (the median of seven runs,
# 2026-11-16; the first took 16). A name holding white space is not looked
# for; no macOS account's short name can hold one. A text naming more than MAX_TILDE_NAMES is not kept.
MAX_TILDE_NAMES = 256
MAX_TILDE_NAME = 255  # characters of one name; a longer run after a ~ is looked up to this length
_TILDE_RUN = re.compile(r"~([^/\s]+)")
_TILDE_QUOTING = str.maketrans("", "", "'\"\\")


def tilde_names(s):
    """Every user name a ~ in s could make the reader look up, or None when there are more than
    MAX_TILDE_NAMES."""
    names = set()
    for m in _TILDE_RUN.finditer(s):
        run = m.group(1)[:MAX_TILDE_NAME].translate(_TILDE_QUOTING)
        names.update(run[:i] for i in range(1, len(run) + 1))
        if len(names) > MAX_TILDE_NAMES:
            return None
    return names


def _write(dirpath, name, data):
    """Write data to dirpath/name whole: under a temporary name, then renamed into place."""
    _os.makedirs(dirpath, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix=".tmp-", suffix=".part")
    try:
        with _os.fdopen(fd, "wb") as f:
            f.write(data)
        _os.replace(tmp, _os.path.join(dirpath, name))
    except BaseException:
        try:
            _os.unlink(tmp)
        except OSError:
            pass
        raise


class Parses:
    """The reader's parses of large texts, kept in dirpath between runs. code is the hash of the
    reader's bytes as the gate ran them."""

    def __init__(self, dirpath, code):
        self.dirpath, self.code = dirpath, code
        self._homes = {}  # user name -> where the reader would take ~name, asked once per run

    def tilde_homes(self, s):
        """{name: home} for every user a ~ in s names who has a home, as the reader would resolve it,
        or None when s names too many to look up. A lookup that raises (a directory service not
        answering) raises out of here, so the caller keeps or uses nothing."""
        names = tilde_names(s)
        if names is None:
            return None
        for name in names - self._homes.keys():
            self._homes[name] = _os.path.expanduser("~" + name)
        return {n: self._homes[n] for n in sorted(names) if self._homes[n] != "~" + n}

    def key(self, s, cwd):
        home = _os.environ.get("HOME")
        if not isinstance(s, str) or not isinstance(cwd, str) or not home:
            return None  # with no HOME the reader would ask the password database, which is not keyed
        users = self.tilde_homes(s)
        if users is None:
            return None
        parts = {"format": PARSE_FORMAT, "kind": "parse", "reader": self.code, "cwd": cwd, "home": home,
                 "users": users, "python": [sys.version, sys.executable], "length": len(s),
                 "text": _sha(s.encode("utf-8", errors="surrogatepass"))}
        return "parse-" + _sha(json.dumps(parts, sort_keys=True).encode("utf-8", errors="surrogatepass"))

    def get(self, s, cwd):
        """The kept parse of s read from cwd, or None. Any doubt is None: the text is read afresh."""
        if len(s) < PARSE_MIN:
            return None
        with _Quiet():
            try:
                return self._get(s, cwd)
            except Exception as e:
                trace(f"parse miss: the lookup raised {type(e).__name__}")
                return None

    def _get(self, s, cwd):
        if not order_fixed():
            trace("parse miss: " + ORDER_RANDOM)
            return None
        k = self.key(s, cwd)
        if k is None:
            trace("parse miss: no key for this text")
            return None
        secret = signing_key(self.dirpath, False)
        if secret is None:
            trace("parse miss: no signing key")
            return None
        path = _os.path.join(self.dirpath, k + ".json")
        try:
            with builtins.open(path, mode="rb") as f:
                raw = f.read(MAX_PARSE + 1024)
        except FileNotFoundError:
            trace("parse miss: no entry")
            return None
        head, _, body = raw.partition(b"\n")
        header = json.loads(head)
        if not (isinstance(header, dict) and header.get("format") == PARSE_FORMAT and header.get("key") == k
                and isinstance(header.get("sig"), str) and len(body) <= MAX_PARSE
                and hmac.compare_digest(header["sig"], hmac.new(secret, k.encode("utf-8", errors="surrogatepass") + b"\n" + body,
                                                                hashlib.sha256).hexdigest())):
            trace("parse miss: the entry is not a whole parse for this key")
            return None
        value = _parse_decode(json.loads(body))
        try:
            _os.utime(path)  # most recently used, for evict()
        except OSError:
            pass
        trace("parse hit")
        return value

    def put(self, s, cwd, value):
        """Keep the parse of s read from cwd. A fault here only means nothing is kept."""
        if len(s) < PARSE_MIN:
            return
        with _Quiet():
            try:
                self._put(s, cwd, value)
            except Exception as e:
                trace(f"parse not stored: {type(e).__name__}: {str(e)[:80]}")

    def _put(self, s, cwd, value):
        if not order_fixed():
            trace("parse not stored: " + ORDER_RANDOM)
            return
        k = self.key(s, cwd)
        if k is None:
            trace("parse not stored: no key for this text")
            return
        body = json.dumps(_parse_encode(value), separators=(",", ":")).encode("utf-8", errors="surrogatepass")
        if len(body) > MAX_PARSE:
            trace(f"parse not stored: it would be {len(body)} bytes")
            return
        secret = signing_key(self.dirpath, True)
        if secret is None:
            trace("parse not stored: no signing key")
            return
        sig = hmac.new(secret, k.encode("utf-8", errors="surrogatepass") + b"\n" + body, hashlib.sha256).hexdigest()
        head = json.dumps({"format": PARSE_FORMAT, "key": k, "sig": sig}).encode("utf-8", errors="surrogatepass")
        _write(self.dirpath, k + ".json", head + b"\n" + body)
        trace("parse stored")
        evict(self.dirpath)
