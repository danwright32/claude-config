#!/usr/bin/env python3
"""agent-overrides.py: what a command does to get past the checks, and what a report says it did
(claude-config#1587). The one reading behind no-verify-gate.sh, monitor-action-gate.sh and
handback-claims-gate.sh, so the gate that refuses a skip and the check that compares a report with
the commands cannot come to disagree about what a skip is (L263, L370).

    agent-overrides.py skips                 stdin: one command line
        one line per git hook skip it runs, exit 0 when there is one, 10 when there is none.

    EXIT CODES. No mode answers "nothing found" with 1, which is what Python exits on an uncaught
    exception: a crash must never read as clean (claude-config#1856, #1869, L1033). Each answers it
    with 10, and every caller reads any code it does not expect as could not read.
    agent-overrides.py stdin-device          stdin: one command line
        one line per git command reading a file from standard input's device path (/dev/stdin,
        /dev/fd/0), exit 0 when there is one, 10 when there is none, never 1, which is what Python
        exits on a crash (claude-config#1765, #1869).
    agent-overrides.py stdin-device-refusal <agent>    stdin: one command line
        exit 0 printing what agent <agent> is told for such a command, 10 printing nothing when there
        is none, never 1, which is what Python exits on a crash (#1869). The one wording, said by
        no-verify-gate.sh before the call and by the job watcher mod at Claude Code's permission
        prompt, which comes first (claude-config#1765).
    agent-overrides.py rewrite-refusal <agent>    stdin: one command line
        exit 0 printing what agent <agent> is told for a git command that rewrites a commit already
        made (commit --amend, push --force, -f, --force-with-lease, a +refspec), 10 printing nothing
        when there is none, never 1, which is what Python exits on a crash. Said by
        amend-force-push-gate.sh (claude-config#1856).
    agent-overrides.py runs-script <name>    stdin: one command line
        exit 0 when a command in it runs the script <name> (by name or path, directly or through a
        shell), 10 when none does.
    agent-overrides.py check-report <transcript>    stdin: the report
        exit 0 printing what contradicts what when the report says no hook was skipped or no override
        was used and the agent's own commands in <transcript> did; 10 when nothing contradicts; 2
        when the transcript cannot be read.

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

# Loading shell-words.py would otherwise leave a __pycache__ in lib/, which is the synced payload
# (test-push-scope.sh holds lib/ to none, #1017).
sys.dont_write_bytecode = True
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


# The device paths that name standard input as a file (claude-config#1765).
STDIN_DEVICES = ("/dev/stdin", "/dev/fd/0")


def _names_stdin_device(w):
    """Whether one word of a git command's arguments hands git standard input's device path as a file:
    the word itself, an option's value after =, or a short option's value glued on (-F/dev/stdin,
    -qF/dev/stdin). A message's value is not one: -m/dev/stdin is its text."""
    for dev in STDIN_DEVICES:
        if w == dev:
            return True
        if w.startswith("--") and w.endswith("=" + dev):
            return not w.startswith(("--message=",))
        if w.startswith("-") and not w.startswith("--") and w.endswith(dev) and len(w) > len(dev) + 1:
            return "m" not in w[1:len(w) - len(dev)]
    return False


def stdin_device_reads(s):
    """Every git command s runs that reads a message or file from standard input's device path
    (`git commit -F /dev/stdin`), as short descriptions. `-F -` reads the same input and is not one:
    measured on 2026-10-26, a worktree subagent's commit naming the device path waited on a Claude Code
    permission prompt nobody could answer (2 of 2, for 1,241 and 10,469 seconds), while 418 commits
    through `-F -` never did (claude-config#1765)."""
    found = []
    for text, _pairs, words in _commands(s):
        reading = sw.git_read(words)
        if reading is None:
            continue
        sub, _front, after = reading
        i = 0
        while i < len(after):
            w = after[i]
            if w == "--":
                i += 1
                continue
            # A message's value is its text, so `-m /dev/stdin` names nothing git opens.
            if w in ("-m", "--message") or (w.startswith("-") and not w.startswith("--") and len(w) > 2
                                            and w.endswith("m") and "/" not in w):
                i += 2
                continue
            if _names_stdin_device(w):
                found.append("git %s reading %s: %s" % (sub or "", w, text.strip().split("\n")[0]))
                break
            i += 1
    return found


def stdin_device_refusal(agent, found):
    """What an agent whose git command reads standard input's device path is told, after its caller's
    own `REFUSED (<who>): `. One wording for both places that refuse it, the PreToolUse gate and the
    job watcher mod's answer to the permission prompt, so the two cannot drift (L263, L370)."""
    return ("agent %s ran a git command that reads a file from standard input's device path:\n  %s\n"
            "From a subagent in a worktree, Claude Code turns that path into a permission prompt nobody "
            "can answer, and the call waits until the agent is stopped (claude-config#1765: 2 of 2 hung, "
            "for 20 minutes and almost 3 hours). Write the message to a file with the Write tool and pass "
            "-F <file>, or keep the heredoc and use -F - instead of the device path."
            % (agent, "\n  ".join(found)))


# The one sentence a dispatched builder is told about rewriting a commit it already made: in the global
# CLAUDE.md's worktree agent rule, and in amend-force-push-gate.sh's refusal (claude-config#1856).
REWRITE_RULE = "Never amend a commit or force push: add a new commit and push normally."
# git push's options that take the next word as their value, so that word is not a refspec or a flag.
PUSH_LONG_VALUED = {"--repo", "--receive-pack", "--exec", "--push-option"}
PUSH_SHORT_VALUED = set("o")


def _commit_amends(after):
    """Whether a git commit's words (after the subcommand) amend: --amend, or a prefix git reads as it
    (--am is the shortest, since no other commit option starts so), unless a later --no-amend turns
    it off. The value of a valued option (-m "--amend") is not an option."""
    on = False
    i = 0
    while i < len(after):
        w = after[i]
        if w == "--":
            break
        if len(w) >= 4 and "--amend".startswith(w):
            on = True
        elif w == "--no-amend":
            on = False
        elif w.startswith("--"):
            if "=" not in w and w in COMMIT_LONG_VALUED:
                i += 1
        elif w.startswith("-") and len(w) > 1:
            letters = w[1:]
            for k, ch in enumerate(letters):
                if ch in COMMIT_SHORT_VALUED:
                    if k == len(letters) - 1:
                        i += 1
                    break
        i += 1
    return on


# The long options that force a push. The same list, and the same reading of a prefix, as the
# scope-modes mod's overnight refusal (mods/scope-modes/hooks/overnight.ts FORCES and spells), so the
# two cannot come to disagree about what a force push is (L263).
PUSH_FORCES = ("--force", "--force-with-lease", "--force-if-includes", "--mirror")


def _spells_force(name):
    """Whether a long option's name could be read by git as one of PUSH_FORCES: git takes any
    unambiguous prefix of a long option (`--forc`), so the whole name or a prefix of four characters
    or more counts, failing closed where git would call it ambiguous."""
    return any(o == name or (len(name) >= 4 and o.startswith(name)) for o in PUSH_FORCES)


def _push_forces(after):
    """What forces a git push's words (after the subcommand): --force, -f (alone or clustered),
    --force-with-lease (with or without a value), --force-if-includes, --mirror, a prefix git would
    read as one of them, or a refspec with a + leading either side. The last of a force and its
    --no- form wins, as in git."""
    why = []
    forced = {}
    i = 0
    opts_done = False
    while i < len(after):
        w = after[i]
        if not opts_done and w == "--":
            opts_done = True
        elif not opts_done and w.startswith("--"):
            name = w.split("=", 1)[0]
            if name.startswith("--no-") and _spells_force("--" + name[5:]):
                forced.pop("--" + name[5:], None)
                if name == "--no-force":
                    forced.pop("-f", None)
            elif _spells_force(name):
                forced[name] = w
            elif "=" not in w and name in PUSH_LONG_VALUED:
                i += 1
        elif not opts_done and w.startswith("-") and len(w) > 1:
            letters = w[1:]
            for k, ch in enumerate(letters):
                if ch == "f":
                    forced["-f"] = "-f"
                if ch in PUSH_SHORT_VALUED:
                    if k == len(letters) - 1:
                        i += 1
                    break
        elif any(side.startswith("+") for side in w.split(":")):
            why.append("refspec " + w)
        i += 1
    return list(forced.values()) + why


def rewrites(s, depth=0):
    """Every git command s runs that rewrites a commit already made: `git commit --amend`, and a
    `git push` forced by --force, -f, --force-with-lease or a +refspec, as short descriptions, behind
    rtk, env, a cd, an if or a `bash -c` string alike, and inside a rebase's --exec. Words that only
    mention one (a commit message, an echo, a grep) are not one (claude-config#1856)."""
    found = []
    for text, _pairs, words in _commands(s):
        reading = sw.git_read(words)
        if reading is None:
            continue
        sub, _front, after = reading
        first = text.strip().split("\n")[0]
        if sub == "commit" and _commit_amends(after):
            found.append("git commit with --amend: %s" % first)
        elif sub == "push":
            why = _push_forces(after)
            if why:
                found.append("git push with %s: %s" % (", ".join(dict.fromkeys(why)), first))
        if depth < 3:
            for inner in _exec_values(sub, after):
                found.extend(rewrites(inner, depth + 1))
    return found


def rewrite_refusal(agent, found):
    """What an agent whose git command amends or force pushes is told, after the gate's own
    `REFUSED (<who>): `. It ends on REWRITE_RULE, the sentence the global CLAUDE.md says."""
    return ("agent %s ran a git command that rewrites a commit already made:\n  %s\n"
            "A dispatched builder that amended after a push review finding pushed its commit without the "
            "fix, and force pushes were refused by the auto mode classifier the same night "
            "(claude-config#1856). %s"
            % (agent, "\n  ".join(found), REWRITE_RULE))


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


# A denial the report WITHDRAWS or QUOTES is not a claim (claude-config#1702). In the #1674 probe on
# 2026-10-24 an agent corrected its report exactly as the refusal asks, and was refused twice more:
# once for "so the earlier claim that no overrides were used is withdrawn", once for pasting the
# refusal, whose own words are It says "Probe report: no overrides were used.". Both readings are kept
# narrow, so a denial merely NEAR either shape is still read:
#   RETRACTED: "<the> claim/statement that <denial> is/was withdrawn, retracted, false, wrong, untrue or
#     incorrect", or "I withdraw/retract the <earlier> claim that <denial>". Only the withdrawn span is
#     removed (in the second shape, up to the end of the first denial after "that"), so a fresh denial
#     after it in the same clause is still read; the word "withdrawn" anywhere else ("the withdrawn
#     branch") retracts nothing. In the first shape the retraction must come STRAIGHT after the denial,
#     nothing between: the denial ("no overrides"), at most its own passive verb ("were used"), then
#     is/was/are/has been/have been, an optional "now", and the retraction word. So "the claim that no
#     overrides were used stands as the count was wrong" still denies; a word list of what may sit
#     between was patched twice by the lessons review of #1702 and was still incomplete.
#   QUOTED: a span in double quotes (straight or curly) straight after a reporting verb (says, said,
#     reads, quoted, quotes, stated, claimed, wrote, contains) whose speaker is somebody else: the
#     refusal ('It says "..."'), another agent or another report ('The builder's report said "..."').
#     A quote is the report's OWN words, and so still a claim, when its speaker is I or we, a first
#     person possessive ('My report says', 'Our status says', 'My earlier hand-back said'), or the
#     report itself ('The report says', 'This summary reads', 'The final summary says', 'This hand back
#     says'). Dan, signing off #1716: a report must not hide its denial behind its own name. A denial
#     in quotes nothing attributes ('Done. "No overrides."') and quotes around one word in a denial
#     are still read too.
CLAIM_THAT = re.compile(r"\b(?:claim|statement)s?\s+that\b")
# Matched exactly at a denial's end. The only words allowed before the predicate are the denial's own
# passive verb, which the denial patterns stop short of ("no overrides" | "were used"); nothing else.
RETRACTED_BY = re.compile(
    r"(?:\s+(?:was|were)\s+(?:used|set|passed|applied|run|needed|taken))?"
    r"\s+(?:is|was|are|has\s+been|have\s+been)\s+(?:now\s+)?(?:withdrawn|retracted|false|wrong|untrue|incorrect)\b")
WITHDRAWING = re.compile(
    r"\b(?:withdraw|withdrawing|withdrew|retract|retracting)\s+(?:the|my|that)\s+"
    r"(?:earlier\s+|previous\s+|original\s+|first\s+)?(?:claim|statement)s?\s+that\b")
QUOTED = re.compile(
    r"\b(says|said|reads|quoted|quotes|stated|claimed|wrote|contains)(\s*:?\s*)"
    "[\"\u201c][^\"\u201c\u201d\\n]*[\"\u201d]", re.I)
# The nouns a report calls itself by. "The <noun>" or "this <noun>", with up to two plain words between
# ("the final summary") and never a possessive ("the probe's report" is somebody else's).
_SELF_NOUN = (r"report|summary|hand[\s-]?back|message|status|update|reply|response|result|results|"
              r"note|notes|write[\s-]?up|answer")
_AUX = r"(?:\s+(?:has|had|have|also|already|just|once|earlier|previously|now|still|clearly|plainly|explicitly))*"
SELF_SPEAKER = re.compile(
    r"(?:\b(?:i|we)|\b(?:my|our)(?:\s+[a-z-]+){1,3}|\b(?:this|the)(?:\s+(?![a-z-]*'s\b)[a-z-]+){0,2}?\s+(?:"
    + _SELF_NOUN + r"))" + _AUX + r"\s*$", re.I)


def _unquote(report):
    """The report with every quotation of SOMEBODY ELSE's words removed, its own kept."""
    def repl(m):
        before = report[max(0, m.start() - 120):m.start()].replace(chr(0x2019), "'")
        before = re.split(r"[.!?\n]\s", before)[-1]
        return m.group(0) if SELF_SPEAKER.search(before) else m.group(1) + m.group(2)
    return QUOTED.sub(repl, report)


def _denial_end(text):
    """Where the first denial in text ends, or None when it holds none."""
    ends = [d.end() for d in (re.search(p, text) for p in NV_DENIALS + GENERAL_DENIALS) if d]
    return min(ends) if ends else None


def _unretracted(low):
    """The clause with every denial it withdraws removed."""
    pos = 0
    while True:
        m = CLAIM_THAT.search(low, pos)
        if not m:
            break
        rest = low[m.end():]
        ends = sorted({d.end() for d in (re.search(p, rest) for p in NV_DENIALS + GENERAL_DENIALS) if d})
        r = next((x for x in (RETRACTED_BY.match(rest, e) for e in ends) if x), None)
        if r:
            low = low[:m.start()] + " " + low[m.end() + r.end():]
            pos = m.start() + 1
        else:
            pos = m.end()
    while True:
        m = WITHDRAWING.search(low)
        if not m:
            return low
        e = _denial_end(low[m.end():])
        # A withdrawal naming no denial withdraws nothing this check reads; drop only its own words.
        cut = m.end() + (e or 0)
        low = low[:m.start()] + " " + low[cut:]


def claims(report):
    """(no-verify denials, general denials): the first a list of clauses, the second of (clause, the
    override names it is about, or None for every override)."""
    nv, gen = [], []
    for c in _clauses(_unquote(report)):
        low = _unretracted(c.lower())
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
        # Not 1: Python exits 1 on an uncaught exception, and a crash must never read as clean (#1869).
        return 0 if found else 10
    if mode == "stdin-device":
        found = stdin_device_reads(data)
        for f in found:
            print(f)
        # Not 1: Python exits 1 on an uncaught exception, and a crash must never read as clean (#1869).
        return 0 if found else 10
    if mode == "stdin-device-refusal" and len(argv) > 2 and argv[2]:
        found = stdin_device_reads(data)
        if not found:
            # Not 1, for the same reason: both callers read any code but 0 and 10 as unread (#1869).
            return 10
        print(stdin_device_refusal(argv[2], found))
        return 0
    if mode == "rewrite-refusal" and len(argv) > 2 and argv[2]:
        found = rewrites(data)
        if not found:
            # Not 1: Python exits 1 on an uncaught exception, and a crash must never read as clean.
            return 10
        print(rewrite_refusal(argv[2], found))
        return 0
    if mode == "runs-script" and len(argv) > 2:
        return 0 if runs_script(data, argv[2]) else 10
    if mode == "check-report" and len(argv) > 2:
        try:
            lines = check_report(data, argv[2])
        except OSError as e:
            sys.stderr.write("cannot read %s: %s\n" % (argv[2], e.strerror or e))
            return 2
        for line in lines:
            print(line)
        return 0 if lines else 10
    sys.stderr.write("usage: agent-overrides.py skips | stdin-device | stdin-device-refusal <agent> | rewrite-refusal <agent> | runs-script <name> | check-report <transcript>  (input on stdin)\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
