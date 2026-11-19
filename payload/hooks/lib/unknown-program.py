#!/usr/bin/env python3
"""The words written after a program the Slack drafts gate does not know, judged as a command
(claude-config#3277).

The gate reads a command by its program's name: a shell, an interpreter, a launcher, a package
manager, a sender, and past the runners the shared reader knows (env, time, nice, xargs and the
rest of its RUNNERS). A program it has no rule for was a command that runs nothing, so the words
after it were never read: asked on 2026-11-18, the installed gate refused `node --test
test/notify.test.js`, a test file whose imports reach code able to post, and allowed the same
words after `op run --`, after `dotenv --` and after `sandbox-exec -f <profile>` by bare name and
by its /usr/bin path. The first two load secrets into the environment and then run the file. A
request sent by curl to the posting endpoint passed the same way.

THE RULE (Judge.judge_behind_unknown), one more reading of a command after the ones there were, so
it can refuse a command those let through and never the reverse:

  * The command's program, past any runner the reader reads past, is one the gate does not read by
    its name and does not know to be unable to run the words it is handed. That second question is
    the one a shell script's own commands are already asked (Judge.sh_command_acts), and it is
    asked here through that same code, never a second list (L96, L370): echo, grep, cat and the
    rest of SH_INERT by bare name or from a system folder, a git subcommand that only reads, find
    with no -exec, awk whose program runs nothing, and a script the gate reads and sees unable to
    act on what it is handed are known. Every other program is not: op, dotenv, sandbox-exec,
    docker, a program named by a variable, a script that runs its arguments. No list of programs
    that run their words is kept, because a program missing from one would pass.
  * A function the text being read defines is that text's own code, as that same question has
    it: the gate reads its body where it stands. Read as commands, the words this repository's
    gate suite hands its own functions as plain labels (`run_slow python`, `f2854 curl "<a
    write>"`) refused that suite (measured 2026-11-19). A body that runs its arguments ("$@")
    is the program named by a variable that claude-config#2683 left as it was, and stays open.
  * A word after it is the name of a program the gate reads by its name (judged_by_name), or of a
    runner the reader reads past, bare, by a path or in quotes. From that word on, the words are
    judged as the command they would be if the program ran them (Judge.judge, and a string a
    shell among them is handed as a command line of its own), fed what feeds the command they
    are written in, since a program the unknown one runs reads the input that one was given
    (`cat post.py | op run -- python3`). A word that names a file is not such a start: read
    that way, `git add scripts/post.sh` and `sed -n 1,5p scripts/post.sh` would each be a run
    of the script. That leaves `op run -- ./post.sh` open.
  * Where a redirection is glued to one of those words (`node --test test/notify.test.js>out.txt`)
    the words are judged again with a space each side of it, as judge_unglued does for a glued
    name: the shared reader splits words on white space alone, so the file was a word naming no
    file. That reading is the reader's to correct (claude-config#3252); this closes it for the
    words read here.
  * The reader's wrappers (a shell's -c, eval, find -exec, watch, script, parallel) hand their
    command to the walk already, so a command that is one is left to that reading.

WHAT IT COSTS. A program that does not run its words and is not known to be unable to (git add,
sed, docker ps) is refused when the words after it happen to spell a command the gate refuses
(`sed -n /x/p node post.js` reads as node run on post.js). Only the words as a command decide it:
where they are no refused command nothing changes. Of the 43,432 distinct commands sessions ran on
the personal MacBook in the 30 days to 2026-11-19, 403 hold such a word as typed, by a count of
their text alone: after ps (`-o command`), which (`which node`) and top in all but about 70, none
of which spells a refused command. The gate's own verdict on each was not taken: the installed
gate refused the script that asks it (the pull request says what was and was not measured).

More than MAX_STARTS words that could each start a command are not all read: a typed command is
refused as unread there, and a script on disk is left alone, as an unread feed is.
"""
import os
import re

# How many words of one command are each read as the start of a command, and how many of these
# readings may stand inside one another (a runner in front of a second unknown program).
MAX_STARTS = 6
MAX_NESTED = 3
# A pattern nothing matches: no word of a typed command is "what the script was handed".
NOTHING = re.compile(r"(?!)")


def make(judged_by_name, sh_redirect):
    """The Judge's base for the rule. judged_by_name is the gate's own answer to whether it reads a
    program by its name, and sh_redirect its pattern for a redirection's operator."""

    class UnknownProgram:
        behind = 0  # how many of these readings are inside one another
        starts_memo = {}  # {a word: whether it can start a command the gate reads}, one Judge a process
        funcs_memo = {}  # {a text: the names of the functions it defines}

        def starts_command(self, word):
            """Whether a word, as the program gets it, names a program the gate reads by its name
            or a runner the reader reads past: the first word of a command the gate can judge."""
            got = self.starts_memo.get(word)
            if got is None:
                name = os.path.basename(word)
                got = self.starts_memo[word] = bool(name) and (judged_by_name(name) or name in self.sw.RUNNERS)
            return got

        def may_run_its_words(self, words, d, depth):
            """Whether the program of a command is one the gate does not know to be unable to run
            the words it is handed: sh_command_acts's answer for a command handed something in its
            words, which is how a shell script's own commands are asked. A function the text being
            read defines is that text's own code, as it is there: its body's commands are read
            where they stand."""
            text = self.shell.get("text") or ""
            defined = self.funcs_memo.get(text)
            if defined is None:
                if len(self.funcs_memo) > 64:
                    self.funcs_memo.clear()
                defined = self.funcs_memo[text] = frozenset(self.sh_funcs(text))
            cmd = {"words": words, "docs": None, "fed": False, "takes": True, "expands": False, "block": False,
                   "env": lambda: None}
            return bool(self.sh_command_acts(cmd, NOTHING, defined, d, depth))

        def word_value(self, raw):
            """One raw word as the program gets it, quotes removed, or None where it is not one word."""
            try:
                got = self.sw.shell_split(raw)
            except ValueError:
                return None
            return got[0] if len(got) == 1 else None

        def judge_behind_unknown(self, d, text, wrapper, depth, whole, fed_by):
            """The reason a command posts through the words after a program the gate does not
            know, or None (THE RULE above). Asked of every command, so the cheap answers come
            first: most commands hold no word that could start another. fed_by is the command as
            the text being read wrote it, text itself unless text is already such words: a
            program run by the unknown one reads the input that one was given, so what feeds
            the words is looked for under the command they were written in (`run_slow python`,
            a function handed a name in this repository's own suite, is fed nothing, where the
            lone word `python` is written on many of that suite's lines)."""
            if wrapper not in ("", "direct") or self.behind >= MAX_NESTED:
                return None
            rest = self.rest_of(text)[0]
            words = self.words_of(rest)
            if len(words) < 2 or not any(self.starts_command(w) for w in words[1:]):
                return None
            name = os.path.basename(words[0])
            if judged_by_name(name) or not self.may_run_its_words(words, d, depth):
                return None
            joined = self.sw.join_continuations(rest)
            toks = self.sh_tokens(joined)
            places, at, end = [], 0, len(toks)
            for k, (kind, raw) in enumerate(toks):
                if kind == "op" and not sh_redirect.fullmatch(raw):
                    end = k  # one command's words end at an operator that is not a redirection
                    break
                at = joined.find(raw, at)  # only white space stands between one word and the next
                places.append(at)
                at += len(raw)
            starts = [k for k in range(1, end) if toks[k][0] == "word" and toks[k - 1][0] == "word"
                      and self.starts_command(self.word_value(toks[k][1]) or "")]
            if not starts:
                return None
            if len(starts) > MAX_STARTS:
                return self.unread_typed(
                    f"{len(starts)} of the words after {words[0]} could each start a command, more than the "
                    f"{MAX_STARTS} the gate reads, and it does not know {name} to be unable to run them, so "
                    "whether the command posts cannot be checked")
            last = places[end - 1] + len(toks[end - 1][1])
            noted = len(self.unfollowed)
            self.behind += 1
            try:
                for k in starts:
                    written = joined[places[k]:last]
                    spaced = " ".join(raw for _, raw in toks[k:end])
                    for new in (written, spaced) if spaced.split() != written.split() else (written,):
                        inner = self.judge_as_run(d, new, depth, whole, fed_by)
                        if not inner:
                            continue
                        if self.sh_in_script() and any(u in inner for u in self.unfollowed[noted:]):
                            # In a script on disk only a finding that something posts stands, as for
                            # the unread shapes (judge_unread_shapes): these words are read without
                            # the script's own reading of its variables around them.
                            del self.unfollowed[noted:]
                            continue
                        return (f"{words[0]} is not a program the gate knows to be unable to run the words after "
                                f"it, so they are read as a command it runs: {inner}")
            finally:
                self.behind -= 1
            return None

        def judge_as_run(self, d, new, depth, whole, fed_by):
            """The reason the command new posts, or None: judged as any command is (Judge.judge),
            fed what feeds the command it was written in, and a string a shell in it is handed
            read as a command line, since the reader gave that string's commands to nobody (as
            rejudge reads one)."""
            wrapper, string, why = self.sw.wrapped(self.rest_of(new)[0]) or ("", None, "")
            if string is not None and not why:
                inner = self.inner_line(string, d, depth)
                if inner:
                    return f"{wrapper} runs a string, one of whose commands posts: {inner}"
            return self.judge(d, new, wrapper, why, depth, whole, fed_by)

    return UnknownProgram
