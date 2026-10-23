#!/usr/bin/env python3
"""local-allow-rules.py: judge, and on Dan's answer tidy, a project's local allow rules (claude-config#1582).

Answering a permission prompt with "Yes, don't ask again" saves that exact command as an allow rule
in the project's .claude/settings.local.json, which is out of git and read by nothing we own. They
pile up: on 2026-10-21 to 23 Slate, Bidspoke and PET each opened every session with Claude Code's
"allows any option at its *" warnings for one off grep, rg, ls and curl rules, and Bidspoke's rules
held a live Cloudflare and Supabase token in plain text. Dan chose "Sweep and report" on 2026-10-23:
flag, say once, and remove only what he picks.

  sweep   --file F --project P     run by local-allow-sweep.sh at session start. Prints what to tell
                                   Dan and the picker to offer, or nothing. Never changes the file.
  remove  --project P --rules R    run on Dan's picker answer. R is "pos:fingerprint,..." exactly as
                                   the sweep printed it.

WHAT IS FLAGGED, per rule:
  holds a key or token   the one redactor, lib/review-redact.sed through ar_redact in
                         ai-review-common.sh, would change it. That is the detector the lessons review
                         already trusts with exactly this case (a Supabase key inside a curl rule,
                         Bidspoke 2026-09-24), so there is no second list of secret shapes (L370,
                         L655). claude-sync's scan_secrets is not used: it lives outside the payload,
                         so no installed hook can read it, and it has no rule for a bearer header.
  one off                a * inside a Bash command (anything but a trailing prefix wildcard), a path
                         into dist/ or a temp folder (tmp, var/folders, TMPDIR, a scratchpad, an agent
                         worktree), or an exact Bash rule with literal arguments (a quoted string, a
                         path argument, a number of three or more digits such as a process id, an env
                         assignment, a pipe or chain, or more than four words). A prefix rule
                         (cmd:* or "cmd *") is one off only when its prefix holds a quoted string.
                         Calibrated 2026-10-23 against the four local settings files on the personal
                         MacBook, by counts only (1011 rules): the numbers are in DESIGN.md.

WHAT IS NEVER PRINTED: the text of any rule. A rule is named by its position, its tool and the first
word of its command, and its kinds. Not only the secret ones: since claude-config#1585 the redactor
also has a shape for a token after a flag named for one (--token, --api-key, --auth, a secret or a
password, then a space) and for a bare Cloudflare token, but a key in a shape it still lacks (after a
flag named otherwise, or in a format it has never seen) would otherwise be printed beside a rule
flagged only as one off, so the rule that nothing is printed is structural rather than resting on
the detector being complete (L27).

ONCE PER SET. The fingerprints (a 12 character sha256 prefix of each flagged rule) last said are kept
in ~/.claude/state/local-allow-sweep/<key>, which holds hashes only. It speaks again only when a rule
is flagged that was not in the set last said, so a removal of some of them, or Dan keeping them, is
not said again on every session. When nothing is flagged the record is not even read: the one file
read is the settings file.

REMOVAL (L5, L9). In order, and each step refuses before the next: parse the file; find every picked
rule by its fingerprint at its position (a file changed since the sweep refuses, never guesses, L237);
copy the file to a backup OUTSIDE ~/.claude (the sync keeps out only names ending exactly in
.local.json, and its repository is public) and read the copy back; cut the picked strings out of the
raw text, so every byte outside the allow list is untouched; check the result parses to the same
document minus exactly those rules; write it to a temporary file beside the original and rename it
over, so a failed write leaves the original as it was.

Environment (seams for tests):
  LOCAL_ALLOW_STATE_DIR      where the said sets are kept (default ~/.claude/state/local-allow-sweep)
  LOCAL_ALLOW_BACKUP_DIR     where backups go (default ~/.claude-allow-rule-backups)
  LOCAL_ALLOW_REVIEW_COMMON  the ai-review-common.sh whose ar_redact is the detector
"""

import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from json.decoder import scanstring

HERE = os.path.dirname(os.path.abspath(__file__))
ISSUE = "claude-config#1582"
SECRET = "holds a key or token"
WILD = "a * inside the command"
TEMP = "a path into dist or a temp folder"
LITERAL = "literal arguments"
FP_LEN = 12


def home():
    return os.path.expanduser("~")


def claude_home():
    return os.environ.get("CLAUDE_HOME") or os.path.join(home(), ".claude")


def fingerprint(rule):
    return hashlib.sha256(rule.encode("utf-8")).hexdigest()[:FP_LEN]


# ---- reading the file ------------------------------------------------------------------------

class Unjudgeable(Exception):
    """The file could not be read or is not the shape a settings file has. Its text is the reason."""


class DetectorBroken(Unjudgeable):
    """The redactor could not run: our install is broken, not Dan's file, so it is never recorded."""


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        raise Unjudgeable("could not be read (%s)" % (e.strerror or e.__class__.__name__))


_WS = " \t\n\r"
_NUM = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
_TARGET = ("permissions", "allow")


def _skip(s, i):
    while i < len(s) and s[i] in _WS:
        i += 1
    return i


def _value(s, i, path, out):
    """Parse one JSON value at s[i:]; return (value, end). Records where permissions.allow and each
    of its elements sit in the raw text, which json.loads cannot say."""
    i = _skip(s, i)
    c = s[i:i + 1]
    if c == "{":
        obj = {}
        i = _skip(s, i + 1)
        if s[i:i + 1] == "}":
            return obj, i + 1
        while True:
            i = _skip(s, i)
            if s[i:i + 1] != '"':
                raise ValueError("expected a key at character %d" % i)
            key, i = scanstring(s, i + 1)
            i = _skip(s, i)
            if s[i:i + 1] != ":":
                raise ValueError("expected ':' at character %d" % i)
            obj[key], i = _value(s, i + 1, path + (key,), out)
            i = _skip(s, i)
            if s[i:i + 1] == ",":
                i += 1
                continue
            if s[i:i + 1] == "}":
                return obj, i + 1
            raise ValueError("expected ',' or '}' at character %d" % i)
    if c == "[":
        start = i
        arr, elems = [], []
        i = _skip(s, i + 1)
        if s[i:i + 1] != "]":
            while True:
                i = _skip(s, i)
                es = i
                v, i = _value(s, i, path + (len(arr),), out)
                arr.append(v)
                elems.append((es, i))
                i = _skip(s, i)
                if s[i:i + 1] == ",":
                    i += 1
                    continue
                if s[i:i + 1] == "]":
                    break
                raise ValueError("expected ',' or ']' at character %d" % i)
        if path == _TARGET:
            out["array"] = (start, i + 1)
            out["elems"] = elems
        return arr, i + 1
    if c == '"':
        return scanstring(s, i + 1)
    for word, v in (("true", True), ("false", False), ("null", None)):
        if s.startswith(word, i):
            return v, i + len(word)
    m = _NUM.match(s, i)
    if m and m.group(0):
        t = m.group(0)
        return (float(t) if any(ch in t for ch in ".eE") else int(t)), m.end()
    raise ValueError("unexpected character at %d" % i)


def parse(raw):
    """-> (text, document, spans). spans has 'array' and 'elems' when permissions.allow is a list."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Unjudgeable("could not be read as JSON (it is not UTF-8 text)")
    try:
        doc = json.loads(text)
    except ValueError as e:
        raise Unjudgeable("could not be read as JSON (%s)" % e)
    spans = {}
    try:
        mine, end = _value(text, 0, (), spans)
        if _skip(text, end) != len(text):
            raise ValueError("text after the document")
    except (ValueError, IndexError) as e:
        raise Unjudgeable("could not be read as JSON here, though Python's reader took it (%s)" % e)
    if mine != doc:
        raise Unjudgeable("could not be read as JSON consistently (two readers disagree, likely a repeated key)")
    if not isinstance(doc, dict):
        raise Unjudgeable("is not a JSON object")
    perms = doc.get("permissions")
    if perms is None:
        return text, doc, {}
    if not isinstance(perms, dict):
        raise Unjudgeable("has a permissions value that is not an object")
    allow = perms.get("allow")
    if allow is None:
        return text, doc, {}
    if not isinstance(allow, list):
        raise Unjudgeable("has a permissions.allow that is not a list")
    if not all(isinstance(r, str) for r in allow):
        raise Unjudgeable("has a permissions.allow holding something other than text")
    return text, doc, spans


def allow_rules(doc):
    return list(((doc.get("permissions") or {}).get("allow")) or [])


# ---- judging a rule ------------------------------------------------------------------------------

_BASH = re.compile(r"^Bash\((.*)\)$", re.S)
_TOOL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)")
_TEMP = re.compile(
    r"(?<![A-Za-z0-9_.-])dist/"
    r"|(?<![A-Za-z0-9_.-])(?:/private)?/tmp(?![A-Za-z0-9_.-])"
    r"|/var/folders/"
    r"|\$\{?TMPDIR"
    r"|/scratchpad(?![A-Za-z0-9_.-])"
    r"|/\.claude/worktrees/"
)
_CHAIN = re.compile(r"[|;<>`]|&&|\$\(")
_PLAIN_WORD = re.compile(r"^[A-Za-z0-9._+-]{1,30}$")
_NUMBER_ARG = re.compile(r"^[0-9]{3,}$")


def _prefix_part(cmd):
    """The command with a trailing prefix wildcard taken off, and whether there was one."""
    for tail in (":*", " *", "*"):
        if cmd.endswith(tail):
            return cmd[: -len(tail)], True
    return cmd, False


def _command_word(cmd):
    """The first word that is not an env assignment, if it is a plain word; else None."""
    for w in cmd.split():
        if "=" in w:
            continue
        base = w.rsplit("/", 1)[-1]
        return base if _PLAIN_WORD.match(base) else None
    return None


def label(rule):
    """The tool and the command's first word: never anything from its arguments."""
    m = _BASH.match(rule)
    if m:
        word = _command_word(m.group(1))
        return "Bash %s" % word if word else "Bash"
    t = _TOOL.match(rule)
    return t.group(1) if t else "rule"


def one_off_reasons(rule):
    reasons = []
    m = _BASH.match(rule)
    if m:
        body, prefixed = _prefix_part(m.group(1))
        if "*" in body:
            reasons.append(WILD)
    if _TEMP.search(rule):
        reasons.append(TEMP)
    if m and WILD not in reasons:
        body, prefixed = _prefix_part(m.group(1))
        words = body.split()
        literal = False
        if prefixed:
            literal = '"' in body or "'" in body
        else:
            args = words[1:]
            first_real = next((k for k, w in enumerate(words) if "=" not in w), None)
            literal = (
                '"' in body or "'" in body or "\n" in body
                or bool(_CHAIN.search(body))
                or (first_real is not None and first_real > 0)  # an env assignment before it
                or any(("/" in a or a.startswith("~")) for a in args)
                or any(_NUMBER_ARG.match(a) for a in args)  # a process id: kill 48213
                or len(words) > 4
            )
        if literal:
            reasons.append(LITERAL)
    return reasons


def secret_flags(rules, common):
    """-> list of bools, one per rule: would the one redactor change it. Raises Unjudgeable when the
    redactor cannot run, which is never the same answer as finding nothing."""
    if not rules:
        return []
    lines = [r.replace("\r", " ").replace("\n", " ") for r in rules]
    if not os.path.isfile(common):
        raise DetectorBroken("could not check its rules for keys or tokens: %s is missing" % common)
    try:
        p = subprocess.run(
            ["bash", "-c", '. "$1" && ar_redact', "_", common],
            # Five seconds, inside the hook's own ten, so a hung redactor is reported here rather
            # than the whole hook being killed with nothing said.
            input="\n".join(lines) + "\n", capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as e:
        raise DetectorBroken("could not check its rules for keys or tokens: the redactor did not run (%s)" % e.__class__.__name__)
    out = p.stdout.split("\n")
    if p.returncode != 0 or len(out) < len(lines):
        raise DetectorBroken("could not check its rules for keys or tokens: the redactor (lib/review-redact.sed through ar_redact) did not run (exit %d)" % p.returncode)
    return [out[k] != lines[k] for k in range(len(lines))]


def judge(rules, common):
    """-> list of (position, rule, label, kinds) for every flagged rule, position counted from 1."""
    secrets = secret_flags(rules, common)
    flagged = []
    for k, rule in enumerate(rules):
        kinds = []
        if secrets[k]:
            kinds.append(SECRET)
        reasons = one_off_reasons(rule)
        if reasons:
            kinds.append("one off: " + ", ".join(reasons))
        if kinds:
            flagged.append((k + 1, rule, label(rule), kinds))
    return flagged


# ---- the once per set record -------------------------------------------------------------------

def state_path(settings_file):
    d = os.environ.get("LOCAL_ALLOW_STATE_DIR") or os.path.join(claude_home(), "state", "local-allow-sweep")
    key = hashlib.sha256(os.path.realpath(settings_file).encode("utf-8")).hexdigest()[:16]
    return d, os.path.join(d, key)


def read_said(settings_file):
    _, p = state_path(settings_file)
    try:
        with open(p) as f:
            return set(line.strip() for line in f if line.strip())
    except OSError:
        return set()


def write_said(settings_file, keys):
    """Written before anything is said, so a failed write is said rather than repeated silently."""
    d, p = state_path(settings_file)
    try:
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".said.")
        with os.fdopen(fd, "w") as f:
            f.write("".join(k + "\n" for k in sorted(keys)))
        os.replace(tmp, p)
        return None
    except OSError as e:
        return "(This could not be recorded as said, %s, so it may be said again next session.)" % (e.strerror or e)


# ---- sweep ---------------------------------------------------------------------------------------

def lib_command(project, rules_arg):
    return "python3 %s remove --project %s --rules %s" % (
        shlex.quote(os.path.join(HERE, "local-allow-rules.py")), shlex.quote(project), rules_arg)


def sweep(settings_file, project, common):
    shown = settings_file
    raw = b""
    try:
        raw = read_bytes(settings_file)
        _, doc, _ = parse(raw)
        rules = allow_rules(doc)
        flagged = judge(rules, common)
    except Unjudgeable as e:
        reason = str(e)
        if isinstance(e, DetectorBroken):
            # Our own tooling is broken: said every session until it is fixed, never recorded.
            print("Local allow rules (%s): %s %s, so they were not checked. Nothing was changed. Tell Dan." % (ISSUE, shown, reason))
            return 0
        # Keyed on the reason and the bytes, so the same broken file is said once, and an edit to it
        # (which may break it differently) is said again. Added to what was said, never replacing
        # it, so a file broken for a moment and mended does not make its flagged rules new again.
        raw_key = "unjudgeable:" + hashlib.sha256((reason + "\0").encode("utf-8") + raw).hexdigest()[:FP_LEN]
        said = read_said(settings_file)
        if raw_key in said:
            return 0
        note = write_said(settings_file, said | {raw_key})
        print("Local allow rules (%s): %s %s, so its allow rules were not checked, and nothing was changed. "
              "Claude Code may be ignoring that file too. Tell Dan once, in plain words.%s"
              % (ISSUE, shown, reason, (" " + note) if note else ""))
        return 0
    if not flagged:
        return 0
    keys = set(fingerprint(r) for _, r, _, _ in flagged)
    said = read_said(settings_file)
    if keys <= said:
        return 0
    # The rules said become exactly the set said now (a rule removed and later re-added is new
    # again); what was said about the file being unjudgeable is kept.
    note = write_said(settings_file, keys | set(k for k in said if k.startswith("unjudgeable:")))

    n_secret = sum(1 for f in flagged if SECRET in f[3])
    lines = [
        "Local allow rules to tidy (%s). Tell Dan once, in plain words, what is below, then ask him with ONE "
        "AskUserQuestion picker using exactly these options. Remove nothing he does not pick; run the command "
        "for his answer and tell him what it printed. Never print or read out a rule's text." % ISSUE,
        "",
        "%s has %d allow rules; %d are flagged:" % (shown, len(rules), len(flagged)),
    ]
    for pos, rule, lab, kinds in flagged:
        lines.append("  rule %d (%s): %s" % (pos, lab, "; ".join(kinds)))
    lines.append("")
    arg = lambda group: ",".join("%d:%s" % (p, fingerprint(r)) for p, r, _, _ in group)
    if len(flagged) <= 3:
        lines.append("Picker, multiSelect, one option per rule plus a keep option. For the rules he picks, run one "
                     "command with all their --rules values joined by commas:")
        for pos, rule, lab, kinds in flagged:
            lines.append('  "Remove rule %d" (%s): --rules %s' % (pos, kinds[0], arg([(pos, rule, lab, kinds)])))
        lines.append('  "Keep them all": run nothing.')
        lines.append("  Command: %s" % lib_command(project, "<the picked values>"))
    else:
        secret_group = [f for f in flagged if SECRET in f[3]]
        other_group = [f for f in flagged if SECRET not in f[3]]
        lines.append("Picker, single select:")
        lines.append('  "Remove all %d flagged": %s' % (len(flagged), lib_command(project, arg(flagged))))
        if secret_group and other_group:
            lines.append('  "Remove the %d holding a key or token": %s' % (len(secret_group), lib_command(project, arg(secret_group))))
            lines.append('  "Remove the %d one off ones": %s' % (len(other_group), lib_command(project, arg(other_group))))
        lines.append('  "Keep them all": run nothing.')
    lines.append("")
    lines.append("A removal first takes a backup outside ~/.claude and says where it is.")
    if n_secret:
        lines.append("A key or token has been sitting in plain text in that file; taking the rule out does not revoke it.")
    if note:
        lines.append(note)
    print("\n".join(lines))
    return 0


# ---- remove --------------------------------------------------------------------------------------

def _inside(path, folder):
    path, folder = os.path.realpath(path), os.path.realpath(folder)
    return path == folder or path.startswith(folder.rstrip(os.sep) + os.sep)


def _cut(text, spans, k):
    """The text with element k of the allow list cut out, with the comma and spacing that went with it."""
    a_start, a_end = spans["array"]
    elems = spans["elems"]
    if len(elems) == 1:
        return text[: a_start + 1] + text[a_end - 1:]
    if k < len(elems) - 1:
        return text[: elems[k][0]] + text[elems[k + 1][0]:]
    return text[: elems[k - 1][1]] + text[elems[k][1]:]


def remove(project, rules_arg):
    settings_file = os.path.join(project, ".claude", "settings.local.json")
    shown = settings_file

    def refuse(msg):
        print("Nothing was removed: %s" % msg)
        return 1

    picks = []
    for part in (rules_arg or "").split(","):
        m = re.match(r"^\s*([0-9]+):([0-9a-f]{%d})\s*$" % FP_LEN, part)
        if not m:
            return refuse("'%s' is not a rule as the sweep names them (position:fingerprint)." % part.strip())
        picks.append((int(m.group(1)), m.group(2)))

    try:
        raw = read_bytes(settings_file)
        text, doc, spans = parse(raw)
    except Unjudgeable as e:
        return refuse("%s %s, and the file was not changed." % (shown, e))
    rules = allow_rules(doc)
    for pos, fp in picks:
        if not (1 <= pos <= len(rules)) or fingerprint(rules[pos - 1]) != fp:
            return refuse("rule %d in %s is not the rule the sweep named, so the file has changed since it was "
                          "swept. Start a new session to sweep it again; the file was not changed." % (pos, shown))
    remove_idx = sorted(set(pos - 1 for pos, _ in picks))

    # The backup, outside ~/.claude and outside the project, read back before anything changes.
    bdir_root = os.environ.get("LOCAL_ALLOW_BACKUP_DIR") or os.path.join(home(), ".claude-allow-rule-backups")
    for forbidden, what in ((claude_home(), "~/.claude"), (project, "the project")):
        if _inside(bdir_root, forbidden):
            return refuse("the backup folder %s is inside %s, where a copy of this file must never go (the "
                          "sync and git keep out only the exact name), so no backup was taken and the file was "
                          "not changed." % (bdir_root, what))
    key = hashlib.sha256(os.path.realpath(settings_file).encode("utf-8")).hexdigest()[:8]
    bdir = os.path.join(bdir_root, "%s-%s" % (re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(os.path.realpath(project))) or "project", key))
    backup = os.path.join(bdir, "settings.local.json.%s.%d" % (time.strftime("%Y%m%dT%H%M%S"), os.getpid()))
    try:
        os.makedirs(bdir_root, mode=0o700, exist_ok=True)
        os.makedirs(bdir, mode=0o700, exist_ok=True)
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        with open(backup, "rb") as f:
            if f.read() != raw:
                raise OSError(0, "the copy read back differs from the original")
    except OSError as e:
        return refuse("no backup could be written to %s (%s), so the file was not changed." % (bdir, e.strerror or e))

    # Cut the picked strings out of the raw text, last first, re-reading the spans after each cut.
    new = text
    for k in sorted(remove_idx, reverse=True):
        _, _, sp = parse(new.encode("utf-8"))
        new = _cut(new, sp, k)
    expect = json.loads(text)
    expect["permissions"]["allow"] = [r for k, r in enumerate(rules) if k not in set(remove_idx)]
    try:
        _, got, got_spans = parse(new.encode("utf-8"))
    except Unjudgeable as e:
        return refuse("the edited text did not parse (%s), so the file was not changed. Backup: %s" % (e, backup))
    if got != expect or new[: spans["array"][0]] != text[: spans["array"][0]] \
            or new[got_spans["array"][1]:] != text[spans["array"][1]:]:
        return refuse("the edit would have changed more than the picked rules, so the file was not changed. Backup: %s" % backup)

    # Write beside the original and rename over it, so a write that fails leaves it untouched. A
    # settings file that is a symlink is written where it points, so the link stays a link and the
    # file it shares gets the removal.
    if raw != read_bytes(settings_file):
        return refuse("%s changed while this ran, so it was not changed. Backup of what was read: %s" % (shown, backup))
    target = os.path.realpath(settings_file)
    tmp = None
    try:
        mode = os.stat(target).st_mode & 0o7777
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".settings.local.json.")
        with os.fdopen(fd, "wb") as f:
            f.write(new.encode("utf-8"))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, target)
        tmp = None
    except OSError as e:
        return refuse("%s could not be written (%s), so it was not changed. Backup: %s" % (shown, e.strerror or e, backup))
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    if read_bytes(settings_file) != new.encode("utf-8"):
        print("The rules were written but the file does not read back as written. Put it back with: cp %s %s"
              % (shlex.quote(backup), shlex.quote(settings_file)))
        return 1
    removed = ", ".join(str(k + 1) for k in remove_idx)
    print("Removed rules %s from %s; %d allow rules remain and every other setting is unchanged. "
          "The backup, which still holds the removed rules, is %s. To put it back: cp %s %s"
          % (removed, shown, len(rules) - len(remove_idx), backup, shlex.quote(backup), shlex.quote(settings_file)))
    return 0


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="local-allow-rules.py")
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("sweep")
    s.add_argument("--file", required=True)
    s.add_argument("--project", required=True)
    r = sub.add_parser("remove")
    r.add_argument("--project", required=True)
    r.add_argument("--rules", required=True)
    a = ap.parse_args(argv)
    common = os.environ.get("LOCAL_ALLOW_REVIEW_COMMON") or os.path.join(HERE, "ai-review-common.sh")
    if a.cmd == "sweep":
        return sweep(a.file, a.project, common)
    if a.cmd == "remove":
        return remove(a.project, a.rules)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
