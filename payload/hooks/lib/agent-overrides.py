#!/usr/bin/env python3
"""agent-overrides.py: what a command does to get past the checks, and what a report says it did
(claude-config#1587). The one reading behind no-verify-gate.sh, monitor-action-gate.sh and
handback-claims-gate.sh, so the gate that refuses a skip and the check that compares a report with
the commands cannot come to disagree about what a skip is (L263, L370).

    agent-overrides.py skips                 stdin: one command line
        one line per git hook skip it runs, exit 0 when there is one, 1 when there is none.
    agent-overrides.py runs-script <name>    stdin: one command line
        exit 0 when a command in it runs the script <name> (by name or path, directly or through a
        shell), 1 when none does.
    agent-overrides.py check-report <transcript>    stdin: the report
        exit 0 printing what contradicts what when the report says no hook was skipped or no override
        was used and the agent's own commands in <transcript> did; 1 when nothing contradicts; 2 when
        the transcript cannot be read.

WHY. On 2026-10-23 a Bidspoke builder agent committed twice with `git commit --no-verify` because the
repository's pre-commit typecheck and lint were slow under load, and handed back "no `--no-verify`, no
overrides". CI ran every check and they passed, so nothing broken shipped, but nothing refused the
skip and the report the main session acted on was untrue.

A SKIP is anything that stops the repository's OWN git hooks running for a git command: --no-verify
on any git subcommand, commit's -n (only commit's: push -n and merge -n mean other things), a
core.hooksPath set on the command with -c, and the hook managers' own switches (HUSKY=0,
HUSKY_SKIP_HOOKS=1, LEFTHOOK=0, SKIP_SIMPLE_GIT_HOOKS=1) set in front of git or exported. A rebase's
--exec command is read as a command of its own, since `git rebase --exec "git commit --amend
--no-verify"` is a skip on every commit it rewrites (seen on this Mac, claude-config 2026-10).

AN OVERRIDE is a gate's documented escape, a SKIP_<NAME> or ALLOW_<NAME> setting given a value other
than empty or 0, in front of a command, through env, or exported. Only settings the shell would
apply count: the words of an echo, a grep pattern or a commit message are not one.

Commands are read by lib/shell-words.py, the one reading every gate uses, so a skip behind rtk, env,
sudo, an if or a `bash -c` string is seen exactly where a push or a merge is (claude-config#1188,
#1478).
"""
import importlib.util
import json
import os
import re
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("shell_words", os.path.join(_here, "shell-words.py"))
sw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sw)

# The hook managers' own switches, by the value that switches hooks off.
HOOK_SWITCHES = {"HUSKY": "0", "HUSKY_SKIP_HOOKS": "1", "LEFTHOOK": "0", "SKIP_SIMPLE_GIT_HOOKS": "1"}
OVERRIDE_NAME = re.compile(r"^(SKIP|ALLOW)_[A-Z0-9_]+$")
DECLARERS = {"export", "declare", "typeset", "local", "readonly"}
# git commit's options that take a value, short (the rest of the word, or the next word) and long (the
# next word unless written with =). Their values are not options, so a message reading "-n" is not -n.
COMMIT_SHORT_VALUED = set("mFCct")
COMMIT_LONG_VALUED = {"--message", "--file", "--reuse-message", "--reedit-message", "--template", "--author",
                      "--date", "--cleanup", "--trailer", "--fixup", "--squash", "--pathspec-from-file"}
# Every other git subcommand: a word that is a value of one of these is not --no-verify.
VALUED_ELSEWHERE = {"-m", "--message", "-F", "--file", "-o", "--push-option", "-X", "--strategy-option",
                    "-s", "--strategy", "--onto"}


def _assignment(word):
    m = sw.ASSIGNMENT.match(word)
    if not m:
        return None
    return word[:m.end() - 1], word[m.end():]


def _commands(s):
    """(text, assignments as [(name, value)], words from the command's own name on) for every command
    s runs, a wrapper's commands included."""
    try:
        records = sw._records(s, "", 0)[0]
    except Exception:
        records = [("", t, "", t, "", "", 0) for t in re.split(r"[;&|\n]+", s)]
    out = []
    for _d, text, _wrap, rest, assigns, _field, _depth in records:
        pairs = []
        for a in (assigns or "").split("\n"):
            p = _assignment(a.strip())
            if p:
                pairs.append(p)
        words = sw.command_words(rest)
        if words and words[0] in DECLARERS:
            for w in words[1:]:
                p = _assignment(w)
                if p:
                    pairs.append(p)
        out.append((text, pairs, words))
    return out


def _commit_skips(after):
    on = False
    i = 0
    while i < len(after):
        w = after[i]
        if w == "--":
            break
        if w == "--no-verify":
            on = True
        elif w == "--verify":
            on = False
        elif w.startswith("--"):
            if "=" not in w and w in COMMIT_LONG_VALUED:
                i += 1
        elif w.startswith("-") and len(w) > 1:
            letters = w[1:]
            for k, ch in enumerate(letters):
                if ch == "n":
                    on = True
                if ch in COMMIT_SHORT_VALUED:
                    if k == len(letters) - 1:
                        i += 1
                    break
        i += 1
    return on


def _other_skips(after):
    i = 0
    while i < len(after):
        w = after[i]
        if w == "--":
            return False
        if w == "--no-verify":
            return True
        if w in VALUED_ELSEWHERE:
            i += 1
        i += 1
    return False


def _exec_values(sub, after):
    """The command strings a rebase runs for each commit (-x, --exec)."""
    if sub != "rebase":
        return []
    vals, i = [], 0
    while i < len(after):
        w = after[i]
        if w in ("-x", "--exec") and i + 1 < len(after):
            vals.append(after[i + 1])
            i += 2
            continue
        if w.startswith("--exec="):
            vals.append(w[len("--exec="):])
        elif w.startswith("-x") and len(w) > 2:
            vals.append(w[2:])
        i += 1
    return vals


def skips(s, depth=0):
    """Every git hook skip s runs, as short descriptions."""
    found = []
    exported = []
    for text, pairs, words in _commands(s):
        switched = [n + "=" + v for n, v in pairs if HOOK_SWITCHES.get(n) == v]
        if words and words[0] in DECLARERS:
            exported.extend(switched)
            continue
        reading = sw.git_read(words)
        if reading is None:
            continue
        sub, front, after = reading
        why = []
        j = 0
        while j < len(front):
            w = front[j]
            val = None
            if w == "-c" and j + 1 < len(front):
                val = front[j + 1]
                j += 1
            elif w.startswith("-c") and len(w) > 2:
                val = w[2:]
            if val is not None and val.split("=", 1)[0].lower() == "core.hookspath":
                why.append("-c " + val)
            j += 1
        if switched or exported:
            why.extend(switched + exported)
        if sub == "commit" and _commit_skips(after):
            why.append("--no-verify")
        elif sub != "commit" and _other_skips(after):
            why.append("--no-verify")
        if why and sub:
            found.append("git %s with %s: %s" % (sub, ", ".join(dict.fromkeys(why)), text.strip()))
        if depth < 3:
            for inner in _exec_values(sub, after):
                found.extend(skips(inner, depth + 1))
    return found


def overrides(s):
    """Every gate override s sets, as NAME=value: in front of a command, through env, or exported."""
    found = []
    for _text, pairs, _words in _commands(s):
        for n, v in pairs:
            if OVERRIDE_NAME.match(n) and v not in ("", "0") and n not in HOOK_SWITCHES:
                found.append(n + "=" + v)
    return list(dict.fromkeys(found))


def runs_script(s, name):
    for _text, _pairs, words in _commands(s):
        if not words:
            continue
        first = words[0].lstrip("({").split("/")[-1]
        if first == name:
            return True
        if first in ("bash", "sh", "zsh", "source", "."):
            for w in words[1:]:
                if w.startswith("-"):
                    continue
                return w.split("/")[-1] == name
    return False


# ---- what a report claims ---------------------------------------------------------------------
NV = r"(?:--)?no-verify"
NV_DENIALS = [
    r"\bno\s+" + NV + r"\b",
    r"\bwithout\s+(?:using\s+|any\s+|a\s+)?" + NV + r"\b",
    r"(?:\bnever|\bnot|n't|\bnor)\b[^,;]{0,40}?" + NV + r"\b",
    NV + r"\s*(?::|was|were|is)?\s*(?:none|never|not used|unused|no)\b",
    r"\bno\s+(?:git\s+|pre-commit\s+|pre-push\s+|commit\s+)?hooks?\s+(?:were\s+|was\s+)?(?:skipped|bypassed)",
    r"\b(?:did\s+not|didn't|never)\s+(?:skip|bypass)\s+(?:any\s+|the\s+)?(?:git\s+|pre-commit\s+|pre-push\s+|commit\s+)?hooks?",
]
GENERAL_DENIALS = [
    r"\bno\s+(?:gate\s+|skip\s+)?(?:overrides?|bypass(?:es)?|skip_\w*|allow_\w*)\b",
    r"\bwithout\s+(?:any\s+)?(?:overrides?|bypass(?:es|ing)?|skipping\s+anything)",
    r"(?:\bnever|\bnot|n't)\s+(?:use|used|using|set|pass|passed|apply|applied)\s+(?:any\s+|an\s+)?(?:overrides?|bypass|skip_\w*|allow_\w*)",
    r"\bnothing\s+(?:was\s+)?(?:skipped|bypassed|overridden)",
    r"\b(?:skipped|bypassed|overrode)\s+nothing\b",
    r"\bno\s+(?:gates?|checks?)\s+(?:were\s+|was\s+)?(?:skipped|bypassed|overridden)",
    r"\b(?:did\s+not|didn't|never)\s+(?:skip|bypass|override)\s+(?:any(?:thing)?|a\s+gate|the\s+gates?|gates?|checks?)\b",
]
# A clause that qualifies itself ("no OTHER overrides", "none except the two above") is not a denial.
QUALIFIED = re.compile(r"\b(?:other|others|except|besides|apart\s+from|aside\s+from|beyond|but|only)\b")


def _clauses(report):
    # Markdown's code and emphasis marks and quotes around a flag are not words.
    text = re.sub(r"[`*\"]", "", report).replace(chr(0x2019), "'")
    for part in re.split(r"(?<=[.!?])\s+|\n+|;|,", text):
        part = part.strip(" -\t")
        if part:
            yield part


# An override named in full ("I never used SKIP_PAYLOAD_WRITE_CHECK") makes the clause a claim about
# that override only. Measured over the 911 hand-backs on this Mac on 2026-10-24: "I never used
# ALLOW_BEHIND_MERGE" read as a claim about every override was contradicted by a SKIP_SCANNERS_CHECK
# push it never denied. A bare prefix ("no SKIP_ overrides") still names none.
NAMED_OVERRIDE = re.compile(r"\b((?:skip|allow)_[a-z0-9_]*[a-z0-9])\b")


def claims(report):
    """(no-verify denials, general denials): the first a list of clauses, the second of (clause, the
    override names it is about, or None for every override)."""
    nv, gen = [], []
    for c in _clauses(report):
        low = c.lower()
        if QUALIFIED.search(low):
            continue
        if any(re.search(p, low) for p in NV_DENIALS):
            nv.append(c)
        elif any(re.search(p, low) for p in GENERAL_DENIALS):
            names = {n.upper() for n in NAMED_OVERRIDE.findall(low)}
            gen.append((c, names or None))
    return nv, gen


def ran_commands(transcript):
    """The Bash and Monitor commands the agent's transcript shows it RAN: a call a hook or the
    platform refused never ran, and its result is an error that does not open with "Exit code"."""
    uses, results = [], {}
    with open(transcript, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            msg = d.get("message") if isinstance(d, dict) else None
            if not isinstance(msg, dict) or not isinstance(msg.get("content"), list):
                continue
            for b in msg["content"]:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("name") in ("Bash", "Monitor"):
                    cmd = (b.get("input") or {}).get("command") if isinstance(b.get("input"), dict) else None
                    if isinstance(cmd, str):
                        uses.append((b.get("id"), cmd))
                elif b.get("type") == "tool_result":
                    c = b.get("content")
                    if isinstance(c, list):
                        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                    results[b.get("tool_use_id")] = (bool(b.get("is_error")), str(c or ""))
    out = []
    for tid, cmd in uses:
        err, text = results.get(tid, (False, ""))
        if err and not text.lstrip().startswith("Exit code"):
            continue
        out.append(cmd)
    return out


def _short(s, n=160):
    s = " ".join(s.split())
    return s if len(s) <= n else s[:n - 3] + "..."


def check_report(report, transcript):
    nv, gen = claims(report)
    if not nv and not gen:
        return []
    skipped, overridden = [], []
    for cmd in ran_commands(transcript):
        for s in skips(cmd):
            skipped.append(s)
        for o in overrides(cmd):
            overridden.append((o.split("=", 1)[0], "%s in: %s" % (o, cmd)))
    lines = []
    if nv and skipped:
        lines.append("It says \"%s\", but these of your own commands skipped the repository's git hooks:" % nv[0])
        lines.extend("  " + _short(s) for s in dict.fromkeys(skipped))
    for clause, names in gen:
        if names is None:
            hits = skipped + [text for _, text in overridden]
        else:
            hits = [text for name, text in overridden if name in names]
        if hits:
            lines.append("It says \"%s\", but these of your own commands skipped a check or set a gate's override:" % clause)
            lines.extend("  " + _short(s) for s in dict.fromkeys(hits))
            break
    return lines


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    data = sys.stdin.read()
    if mode == "skips":
        found = skips(data)
        for f in found:
            print(f)
        return 0 if found else 1
    if mode == "runs-script" and len(argv) > 2:
        return 0 if runs_script(data, argv[2]) else 1
    if mode == "check-report" and len(argv) > 2:
        try:
            lines = check_report(data, argv[2])
        except OSError as e:
            sys.stderr.write("cannot read %s: %s\n" % (argv[2], e.strerror or e))
            return 2
        for line in lines:
            print(line)
        return 0 if lines else 1
    sys.stderr.write("usage: agent-overrides.py skips | runs-script <name> | check-report <transcript>  (input on stdin)\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
