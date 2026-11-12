"""What a write to a path the Slack drafts gate cannot work out can name (claude-config#2785).

The gate notes every file a command writes, so that a script written and then run in the same command
is judged by what was written (claude-config#2525, #2721). Where the written path cannot be worked out,
#2721 read it as possibly any file at all unless its last part was plain text, so `> $S/f-$m.txt` or
`>> $L` refused every script the command ran after it, /bin/sleep included: 17 refusals in the #2642
replay of real sessions, every one false. The word is now read for what it does show:

  * An unknown part of it (a variable the command never sets, a substitution, a function's argument,
    a glob) can hold anything, a / and .. included, so all that is certain after one is the literal
    text following the last: `$S/f-$m.txt` with $m unknown ends in .txt.
  * A variable the command does set is read as each value the command gives it (NAME=value, export
    NAME=value, for NAME in words), worked out the same way, and as what the environment holds, which
    is what the shell uses where that assignment is skipped (`cd x && L=...; ... > $L`). One the
    command may set in any other way (read, printf -v, ${L:=x}, let, a nameref, eval, source) is
    unknown, and so is one it never sets: #2721 decided a path from the environment alone cannot be
    read, and a test holds it.
  * Where an unknown part is unquoted in a word the shell splits (any word but a redirection's target,
    where more than one word is an error), the words it becomes can end anywhere, so that write can be
    any file.
  * A copier's word can be a folder that files are copied into, so what is under it counts as written
    too. Before #2785 `cp post.sh "$X/tools"` noted only `*/tools`, and tools/post.sh then ran unread.

So a write still counts against the script a command runs whenever it could plausibly be that script:
the same literal ending, a variable whose value names it, or a variable set from it.

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base. The
methods use the Judge's own resolver (sh_param, sh_subst, sh_close, sh_cwd, sh_source_var, sh_word_end,
sh_tokens) and the text being read (shell), so a value is worked out here exactly as it is there.
"""
import os
import re

ANY = object()  # a part of a word whose text is not known
MAX_SHAPES = 64  # alternatives past this are read as any word at all


def glob_escape(s):
    return re.sub(r"([*?\[])", r"[\1]", s)


def make(param_re, unknown_dir):
    """The base class for the gate's Judge. param_re is its SH_PARAM, the parameter expansion pattern,
    and unknown_dir its SH_UNKNOWN_DIR, the directory sh_cwd gives where that is not certain."""

    class WrittenPaths:
        def unknown_patterns(self, raw, d, redirect=False, copier=False):
            """fnmatch patterns that every path the raw word can name matches, for a write to it."""
            shapes = self.word_shapes(raw, d, redirect, 0, frozenset())
            pats = []
            for shape in shapes if shapes is not None else [[ANY]]:
                for p in self.shape_patterns(shape, d):
                    for q in ([p, p.rstrip("/") + "/*"] if copier else [p]):
                        if q not in pats:
                            pats.append(q)
            return pats

        def word_shapes(self, raw, d, nosplit, depth, seen):
            """The shapes one raw shell word can take, each a list of literal text and ANY, or None
            where it can be any word at all. nosplit is True where the shell does not split it: a
            redirection's target or a NAME=value's value. seen holds the variables being worked out,
            so one set from itself is not followed round."""
            shapes, i, n, dq = [[]], 0, len(raw), False

            def extend(alts):
                nonlocal shapes
                shapes = [s + a for s in shapes for a in alts]
                return len(shapes) <= MAX_SHAPES

            while i < n:
                c = raw[i]
                if c == '"':
                    dq = not dq
                    i += 1
                    continue
                if c == "'" and not dq:
                    j = raw.find("'", i + 1)
                    if j < 0:
                        return None
                    extend([[raw[i + 1:j]]])
                    i = j + 1
                    continue
                if c == "\\":
                    if i + 1 >= n:
                        return None
                    if dq and raw[i + 1] not in '$`"\\\n':
                        extend([["\\"]])
                        i += 1
                        continue
                    extend([[raw[i + 1]]])
                    i += 2
                    continue
                if c in "`$":
                    alts, i = self.expansion_shapes(raw, i, d, dq, nosplit, depth, seen)
                    if alts is None or not extend(alts):
                        return None
                    continue
                if not dq and c in "*?[":
                    extend([[ANY]])  # a glob: any name it matches
                    i += 1
                    continue
                if not dq and c == "{":
                    j = raw.find("}", i)
                    body = raw[i + 1:j] if j > 0 else ""
                    if j > 0 and "," in body and re.fullmatch(r"[A-Za-z0-9._+%@=:/,-]*", body):
                        if not extend([[a] for a in body.split(",")]):
                            return None
                        i = j + 1
                        continue
                    if j > 0 and re.fullmatch(r"-?\w+\.\.-?\w+(\.\.-?\d+)?", body):
                        extend([[ANY]])  # a sequence, {1..9}
                        i = j + 1
                        continue
                    # Any other list ({"a",b}, {$X,b}, a nested one) becomes words this does not
                    # follow, so the write can be any file (lessons review at 80e51f5).
                    if "," in raw[i:] and "}" in raw[i:]:
                        return None
                if not dq and c == "~" and (i == 0 or raw[i - 1] == ":"):
                    home = os.environ.get("HOME")
                    if re.match(r"~(/|:|$)", raw[i:]) and home:
                        extend([[home]])
                    else:
                        extend([[ANY]])  # ~user, or a HOME not known
                        while i + 1 < n and raw[i + 1] not in "/:":
                            i += 1
                    i += 1
                    continue
                if not dq and (c.isspace() or c in ";&|<>()"):
                    return None
                extend([[c]])
                i += 1
            return None if dq else shapes

        def expansion_shapes(self, raw, i, d, dq, nosplit, depth, seen):
            """(the shapes of the expansion starting at raw[i], a ` or a $, as word_shapes gives them,
            or None where the word can be anything; where the expansion ends)."""
            n, split, cwd = len(raw), not (dq or nosplit), self.sh_cwd(d)
            if raw[i] == "`":
                j = raw.find("`", i + 1)
                if j < 0 or "\\" in raw[i + 1:j]:
                    return None, n
                return (None if split else [[ANY]]), j + 1
            if raw.startswith("$((", i):
                j = raw.find("))", i)
                return (None, n) if j < 0 else ([[ANY]], j + 2)  # a number: it holds no space
            if raw.startswith("$(", i):
                j = self.sh_close(raw, i + 2)
                if j is None:
                    return None, n
                v = self.sh_subst(raw[i + 2:j], cwd, self.sh_source_var, self.shell["script"])
                return self.value_shapes(v, dq, split), j + 1
            m = param_re.match(raw, i)
            if not m:
                return [["$"]], i + 1  # a $ that starts no expansion is itself
            p = m.group(1) if m.group(1) is not None else m.group(2)
            v = self.sh_param(p, cwd, self.sh_source_var, self.shell["script"], dq)
            if v is not None:
                return self.value_shapes(v, dq, split), m.end()
            alts = self.var_shapes(p, d, depth, seen) if re.fullmatch(r"[A-Za-z_]\w*", p) else None
            if alts is None:
                return (None if split else [[ANY]]), m.end()
            if dq:
                return alts, m.end()
            # Unquoted: a value holding a space splits, and one holding a glob is matched to files.
            out = []
            for s in alts:
                lits = [x for x in s if x is not ANY]
                if split and (len(lits) < len(s) or any(re.search(r"\s", x) for x in lits)):
                    return None, n
                out.append([ANY] if any(re.search(r"[\s*?\[]", x) for x in lits) else s)
            return out, m.end()

        @staticmethod
        def value_shapes(v, dq, split):
            """word_shapes's alternatives for an expansion whose value is v (None where not known)."""
            if v is None:
                return None if split else [[ANY]]
            if not dq and split and re.search(r"\s", v):
                return None
            if not dq and re.search(r"[\s*?\[]", v):
                return [[ANY]]
            return [[v]]

        def var_shapes(self, name, d, depth, seen):
            """The shapes the variable name can hold where the command reads it, when the resolver
            could not settle one value: each value the text being read gives it and what the
            environment holds; None where the text never sets it, or may set it some other way."""
            if depth >= 3 or name in seen:
                return None
            text = self.shell.get("text") or ""
            if re.search(r"(?:^|[;&|(){}\n]|\b(?:then|do|else))\s*(?:eval|source|\.|let)\s", text) or \
                    re.search(r"\b(?:declare|typeset|local)\s+(?:-\w+\s+)*-\w*n", text):
                return None
            alts, found, seen = [], False, seen | {name}
            for m in re.finditer(r"(?<![\w$])%s(?!\w)" % re.escape(name), text):
                i, j = m.span()
                prev, nxt = text[i - 1:i], text[j:j + 1]
                if text[max(0, i - 2):i] == "${":
                    if re.match(r":?=", text[j:]):
                        return None  # ${NAME:=x} sets it
                    continue
                if not ((not prev or prev.isspace() or prev in ";&|(){}\"'`")
                        and (not nxt or nxt.isspace() or nxt in ";&|()<>\"'`=[+}")):
                    continue  # part of another word (-L, f-$m, %m): never a name a command sets
                if nxt == "=" and not text.startswith("==", j) and text[max(0, i - 2):i] != "((":
                    val = text[j + 1:self.sh_word_end(text, j + 1)]
                    if val.startswith("("):
                        return None  # an array
                    alts += self.word_shapes(val, d, True, depth + 1, seen) or [[ANY]]
                    found = True
                    continue
                loop = re.match(r"\s+in(?=\s)", text[j:])
                if loop and re.search(r"(?:^|[\s;&|(){}])for\s+$", text[:i]):
                    for kind, t in self.sh_tokens(text[j + loop.end():]):
                        if kind == "op" or t == "do":
                            if kind == "op" and t != ";":
                                return None
                            break
                        alts += self.word_shapes(t, d, False, depth + 1, seen) or [[ANY]]
                    found = True
                    continue
                return None  # read NAME, printf -v NAME, unset NAME and the like
            if not found or len(alts) >= MAX_SHAPES:
                return None
            env = os.environ.get(name)
            alts.append([env if env is not None else ""])
            return alts

        def shape_patterns(self, shape, d):
            """fnmatch patterns for the paths one shape can name: after its last unknown part, only what
            follows, from its last .. on; else the path itself, as written and with links followed."""
            if any(x is ANY for x in shape):
                k = max(i for i, x in enumerate(shape) if x is ANY)
                parts = re.sub(r"/+", "/", "".join(shape[k + 1:])).split("/")
                if ".." in parts:
                    parts = [""] + parts[len(parts) - parts[::-1].index(".."):]
                parts = parts[:1] + [p for p in parts[1:] if p != "."]
                return ["*" + glob_escape("/".join(parts))]
            path = "".join(shape)
            if not path:
                return []  # an empty name: the write fails, and nothing is written
            if not os.path.isabs(path):
                cwd = self.sh_cwd(d)
                if cwd == unknown_dir:
                    return self.shape_patterns([ANY, "/" + path], d)
                path = os.path.join(cwd or os.getcwd(), path)
            if ".." in path.split("/"):
                return self.shape_patterns([ANY, path], d)
            norm = os.path.normpath(path)
            out = [glob_escape(norm)]
            real = glob_escape(os.path.realpath(norm))
            return out if real in out else out + [real]

    return WrittenPaths
