"""Three shapes the Slack drafts gate's walk of a script's variables (Judge.sh_walk) could not follow,
for the gate (claude-config#2912).

Since #2911 a file sourced by a path the walk cannot work out is refused unread, and these three
shapes were refused that way however quiet the files they named:

  * A for loop over words written out, sourcing a path built from its name
    (`for f in a.sh b.sh; do . "$LIB/$f"; done`, tools/load-window.sh before #2911). The walk took
    the loop's name as unknown. Each value is now tried in turn (sh_for_loops, sh_source_each): the
    walk reads every file the loop sources, and the gate judges each of them. A word that is not
    written out (a glob, a variable, a substitution), a body that binds the name itself, or a sourced
    file that binds it leaves the path unknown, and it is refused as before.
  * NAME="$NAME" cmd inside a function, which sets NAME for that one command, was read as the
    function binding NAME, so a call to the function left NAME unknown (sh_one_command_sets, the
    count the walk already used for such assignments outside function bodies).
  * A call of a function of the script that evaluates its argument (`ev() { eval "$1"; }`) ended the
    walk, so every variable past it was unknown: a sourced path was then refused, and a file RUN by
    such a path (behind the #2683 switch, off) passed unread, a file that posts included. The
    function is now read as lib/hang-wait.sh's hang_wait is (sh_evaluator): a call whose argument is
    written out (in double quotes too, with every $, ` and " escaped) is followed as though written
    in its place, and what it evaluates is judged as a command line, so `ev "bash post.sh"` is
    refused as the post it is, through hang_wait too, where before it passed (sh_eval_text_reason).
    A call whose argument the gate cannot read still ends the walk: a sourced path past it is
    refused, and a file run past it stays behind the #2683 switch, which the gate suite pins for
    exactly this shape (Dan, 2026-11-10: "measure first").

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, as
it does lib/code-loaders.py's, so the methods use the Judge's own readers (rest_of, words_of,
raw_words, sh_tokens, sh_literal_word, sh_strip_openers, sh_binds, sh_source_word,
sh_source_target, sh_source_var, sh_cwd, sh_ctx_known, sh_eval_call, line, shell, unfollow).

Since claude-config#3020 it also reads text handed to eval, to a shell's -c or to a function that
evaluates its argument through a variable or a substitution (handed_text_reason, with the comment
above it), using the Judge's sh_value, sh_word_end, pieces_of and pieces_reason as well.
"""
import os
import re

# The most paths one source command is worked out to, across the values of the loops around it: past
# it the path is taken as unknown, and refused, rather than read once for each.
MAX_CHOICES = 64
# A word that is one substitution printing one file's text (text_of_file): $(cat F) or $(< F), or
# either in backquotes, the whole of the word, in double quotes or not. F is read as one shell word.
FILE_TEXT = re.compile(r'("?)(?:\$\(\s*(?:cat\s+|<\s*)([^()`]+?)\s*\)|`\s*(?:cat\s+|<\s*)([^()`]+?)\s*`)\1')
# A word that is one variable or positional parameter and nothing else, in double quotes or not.
LONE_NAME = re.compile(r'"?\$\{?([A-Za-z_]\w*|[0-9])\}?"?')


def make(sh_special, sh_param, runs_refused=lambda: False, unknown_dir=None):
    """The base class for the gate's Judge (module docstring). sh_special is its SH_SPECIAL, the
    builtins an assignment in front of lasts past, and sh_param its SH_PARAM; runs_refused says
    whether its #2683 switch is on, and unknown_dir is its SH_UNKNOWN_DIR."""

    class ShWalkShapes:
        def sh_one_command_sets(self, heads, funcs):
            """{NAME: how many times NAME=value stands in front of a command in heads}, counting only a
            command that is not a special builtin nor a function of the text (funcs), which run with
            it set: for any other it is set for that command alone, so it binds nothing that lasts.
            heads are the commands with the keywords that open a block taken off, so the first
            command of a function's body (`run() { LIB="$LIB" env`) is read as the command it is."""
            temp = {}
            for t in heads:
                rest_t, assigns = self.rest_of(t)
                words = self.words_of(rest_t)
                if words and words[0] not in sh_special and words[0] not in funcs:
                    for a in assigns.split("\n"):
                        n = a.split("=", 1)[0]
                        if a.strip() and re.fullmatch(r"[A-Za-z_]\w*", n):
                            temp[n] = temp.get(n, 0) + 1
            return temp

        def sh_for_loops(self, s, items, blocks):
            """Each loop of blocks written `for NAME in WORD...`, every word written out whole (quoted
            or plain, no glob, brace, tilde or expansion), whose body never binds NAME: (open, close,
            NAME, the words' values, where the loop starts, where it ends). The body is everything
            after the header to the done."""
            out = []
            for blk in blocks or ():
                if blk["kind"] != "loop" or blk["close"] is None:
                    continue
                o, c = blk["open"], blk["close"]
                head = self.sh_strip_openers(items[o][0][1])
                m = re.match(r"for\s+([A-Za-z_]\w*)\s+in(?=\s|$)", head)
                if not m:
                    continue
                toks = self.sh_tokens(head[m.end():])
                if toks and toks[-1] == ("op", ";"):
                    toks = toks[:-1]
                values = [self.sh_literal_word(raw) if kind == "word" else None for kind, raw in toks]
                if any(v is None for v in values):
                    continue
                body = s[items[o][1]["end"]:items[c][1]["end"]]
                if self.sh_binds(m.group(1), body):
                    continue
                out.append((o, c, m.group(1), values, items[o][1]["start"], items[c][1]["end"]))
            return out

        def sh_source_each(self, text, wd, var, script, loops, at):
            """The paths a source or . command reads, worked out once for each value of every loop of
            loops (sh_for_loops) around offset at whose name the path uses: a list of words, empty for
            a loop over no words, or None where any of them cannot be worked out, or there are more
            than MAX_CHOICES. var gives every other name's value, as sh_source_word takes it."""
            raw = self.sh_source_target(text) or ""
            used = {(a or b).split(":", 1)[0].split("%", 1)[0].split("#", 1)[0] for a, b in sh_param.findall(raw)}
            around = {}
            for o, c, name, values, start, end in loops:
                if start <= at < end and name in used:
                    around[name] = values  # an inner loop over the same name is the one that holds
            if not around:
                return None
            names = sorted(around)
            total = 1
            for n in names:
                total *= len(around[n])
            if total > MAX_CHOICES:
                return None
            # Every pick of one value per name, built by hand: an import of itertools would be one more
            # module the judgement cache must classify (test-judgement-cache.sh).
            picks = [{}]
            for n in names:
                picks = [{**p, n: v} for p in picks for v in around[n]]
            out = []
            for pick in picks:
                v, bad = self.sh_source_word(text, wd, lambda n, pick=pick: pick[n] if n in pick else var(n), script)
                if bad or v is None:
                    return None
                out.append(v)
            return out

        def sh_source_choices(self, text, d):
            """For the source or . command being judged: [(path, False)] for each file it reads, worked
            out from the script's variables, and from each value of a for loop around it that the
            walk of its variables followed (sh_walk's "each"); else [(None, True)] where its path
            cannot be worked out, or [(None, False)] for no path at all."""
            wd, script = self.sh_cwd(d), self.shell["script"]
            v, bad = self.sh_source_word(text, wd, self.sh_source_var, script)
            at = self.shell["at"]
            if not bad or at is None:
                return [(v, bad)]
            got = self.sh_source_each(text, wd, self.sh_source_var, script,
                                      self.sh_ctx_known().get("each", ()), at)
            return [(None, True)] if got is None else [(w, False) for w in got]

        def sh_eval_text_reason(self, text, d, depth):
            """The reason a call of a function that evaluates its argument in the caller's shell posts,
            judging each argument it evaluates, written out, as a command line; or None. The functions
            are the ones the walk of the text's variables found (its own, and those of the files it
            sources), each with the positions of the arguments it evaluates."""
            evals = self.shell["known"].get("evals") if self.shell.get("known") else None
            # Asked of every command: one that holds none of the names calls none of them, and is
            # passed over before its openers are cut (#2918).
            if not evals or not any(f in text for f in evals):
                return None
            head = self.sh_strip_openers(text)
            lits = self.sh_eval_call(head, evals)
            if lits is False:
                # A plain call with an argument that is not written out: read where the gate can read
                # it, and refused where it cannot (handed_text_reason, claude-config#3020).
                for raw in self.sh_eval_call(head, evals, raw=True) or ():
                    reason = self.handed_text_reason("a function that evaluates its argument", [raw], d, depth)
                    if reason:
                        return reason
                return None
            for lit in lits or ():
                try:
                    inner = self.line(lit, d, depth + 1, lit)
                except self.sw.Unreadable:
                    inner = self.unfollow(f"it evaluates {lit!r}, which the gate cannot read")
                if inner:
                    return f"{text.strip()[:120]} evaluates {lit!r} in this shell, and that posts: {inner}"
            return None

        # ---- Text handed to eval, a shell's -c or an evaluating function (claude-config#3020) --------
        # `X="$(cat cmd.txt)"; eval "$X"` ran a file's text with the file never read, and so did
        # `eval "$(cat cmd.txt)"`, `bash -c "$(cat cmd.txt)"` and a call of a function that evaluates
        # its argument, where the same text fed to a shell's input (`bash <<< "$(cat cmd.txt)"`,
        # claude-config#2887) was read. One reading now serves all of them (text_of_file, which the
        # here string reading uses too). Text handed through a variable or a substitution is:
        #   * judged as a command line where every word of it has a value the gate works out
        #     (`X='bash post.sh'; eval "$X"` passed);
        #   * read as the file it is where it is one file's text: $(cat F), $(< F) or the same in
        #     backquotes, straight or through a variable the text sets once from it, F worked out as
        #     any path is, and what an earlier command made F from counted (pieces_of);
        #   * and otherwise text the gate cannot read: a program's output, a variable set nowhere,
        #     a file whose path cannot be worked out. In the command itself that is refused, as input
        #     a shell reads that cannot be read is (fed_reason). Inside a script on disk it stays
        #     behind the #2683 switch, as a file run by a path the gate cannot work out does: 9 of
        #     this repository's scripts evaluate a variable their caller sets (lib/issue-spool.sh's
        #     test seam among them), and refusing them is the measurement Dan asked for first.
        # A positional parameter is what a function or a script was handed: judged at each call of a
        # function the walk found to evaluate it (sh_eval_text_reason), and for a script on disk
        # where the script is handed something (the gate's acts reading).

        def text_of_file(self, raw, d):
            """For a raw word that is one substitution printing one file's text ($(cat F), $(< F), or
            either in backquotes, in double quotes or not): what the file holds, as pieces (pieces_of),
            or an unreadable piece where F cannot be worked out. None for any other word."""
            m = FILE_TEXT.fullmatch(raw or "")
            if not m:
                return None
            toks = self.sh_tokens((m.group(2) if m.group(2) is not None else m.group(3)).strip())
            if len(toks) != 1 or toks[0][0] != "word":
                return None
            path = self.sh_value(toks[0][1], d)
            if path is None or (not os.path.isabs(path) and self.sh_cwd(d) == unknown_dir):
                return [("unknown", None, f"the file {toks[0][1]}, whose path the gate cannot work out")]
            return self.pieces_of(path, d)

        def sh_set_from(self, name):
            """The value the text being read gives NAME, as written, where it sets it exactly once
            before the command being judged, by a plain NAME=value, and binds it no other way before
            then; else None."""
            at, text = self.shell.get("at"), self.shell.get("text") or ""
            if at is None:
                return None
            before = text[:at]
            found = list(re.finditer(r"(?:^|(?<=[\s;&|({]))" + re.escape(name) + r"=", before))
            if len(found) != 1 or self.sh_binds(name, before, 1):
                return None
            start = found[0].end()
            return before[start:self.sh_word_end(before, start)]

        def handed_text_reason(self, name, raws, d, depth):
            """The reason the text name (eval, a shell's -c, a function that evaluates its argument)
            is handed posts, or cannot be read, or None (the comment above). raws are the words of
            the text as written."""
            raws = raws[1:] if raws[:1] == ["--"] else raws
            if not any(re.search(r"[$`]", r) for r in raws):
                return None  # written out: its commands are read where they are
            values = [self.sh_value(r, d) for r in raws]
            pieces = None
            if all(v is not None for v in values):
                pieces = [("text", " ".join(values) + "\n", "")]
            elif len(raws) == 1:
                lone = LONE_NAME.fullmatch(raws[0])
                if lone and lone.group(1).isdigit():
                    evals = self.sh_ctx_known().get("evals") or {}
                    if self.shell.get("on_disk") or any(int(lone.group(1)) in ns for ns in evals.values()):
                        return None  # what it was handed, judged where it is handed (the comment above)
                pieces = self.text_of_file((self.sh_set_from(lone.group(1)) or "") if lone else raws[0], d)
            shown = " ".join(raws)[:120]
            unread = (f"{name} is handed {shown}, text the gate cannot read before the command runs%s, so "
                      "whether it posts cannot be checked. Write the commands out, or put them in a script "
                      "and run that")
            if pieces is None:
                if self.shell.get("on_disk") and not runs_refused():
                    return None
                return self.unfollow(unread % "")
            return self.pieces_reason(name, pieces, d, depth, True, None, "runs the text it is handed",
                                      "runs commands from the text it is handed", unread)


    return ShWalkShapes
