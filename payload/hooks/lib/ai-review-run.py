#!/usr/bin/env python3
"""The detached half of the advisory AI review (claude-config#433).

ai-review-on-push.sh starts this in the background the moment a `git push` has succeeded and
returns at once, so the push waits for nothing. This process then asks `claude` to review the
diff and writes the answer where ai-review-nudge.sh will find it on a later prompt.

    ai-review-run.py --state-dir D --key K --sha S --repo-label L --branch B --repo-dir R
                     --model M --prompt-file P --lessons-dir D --diff-file F --deadline SECONDS
                     --started EPOCH

It runs EXACTLY `env -u CLAUDECODE CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p <prompt> --model
<model> --settings {"disableAllHooks":true} --strict-mcp-config --disallowedTools ReportFindings` with
the diff on stdin (the last three are explained where the command is built).
The `env -u` is load bearing: a nested claude refuses to start while CLAUDECODE is set, and every
hook inherits that variable from the session that fired it. Removing it here rather than in the
shell keeps the whole command in one place the test can read back from the fake claude's recorded
environment.

The prompt is the text of ai-review-prompt.txt, verbatim, with one context line in front of it
naming the framework read from package.json (or saying there was none), and the lessons index in
between. The file is the prompt the test compares against, so the hook never holds wording of its
own (L41).

THE LESSONS, on purpose, and nothing else of the global config (claude-config#539). The review used
to inherit the whole global CLAUDE.md by accident, because a headless claude loads it unless told
not to. It is now told not to, and every LESSONS-INDEX-*.md in --lessons-dir (the config root
beside the hooks) is read HERE, at run time, into the prompt, so it is always the current index and
never a copy that drifts (L41). A review that found no index files still runs, and its answer says
so on its first line, because running on without them silently would read as a review that applied
the lessons and found nothing to cite.

WHAT IT WRITES, and the one rule about the order. The hook has already written
<key>-<sha>.txt.pending carrying the start time. On any exit at all this process writes
<key>-<sha>.txt (the finished file, atomically, via a temporary name and rename), THEN removes the
pending file, THEN removes the diff. The finished file lands first so there is never a moment with
neither: a nudge that saw nothing would read it as no review having been started (L98). A review
that ran out of time, a claude that exited non-zero, one that printed nothing, and a crash inside
this script all still produce a finished file, each saying which it was in its own words (L11,
L514). The deadline is enforced here with subprocess's own timeout because macOS has no `timeout`
command, and the whole process group is killed on expiry so a stuck child cannot outlive it.

The finished file's first lines are `name=value` metadata (repo, branch, sha, started, finished,
status, model), then a blank line, then the review. The nudge reads only that shape.

TWO KINDS, one reviewer (claude-config#560). `--kind push` (the default) is the advisory review of
one push. `--kind pr` is the lessons review of a WHOLE branch that lib/pr-review.sh starts when a
pull request is opened, and that the merge gate waits for. A pr review also records `kind`, `base`
and `findings` (the count of finding lines, 0 for "No issues found.") in its metadata, and its
`--scope-file` is sent in front of the shared prompt, so the one prompt file serves both (L41).

THE CITATION LEDGER. Every finished review with findings appends one line to citations.tsv in the
state directory: finish time, kind, repository, sha, findings, and the lesson numbers its findings
cite. The review files themselves are swept after 14 days; the ledger is not, because the monthly
re-rank of the lessons core (#563, #566) needs which lessons reviews actually cite, over months.
"""
import argparse
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time


def framework_line(repo_dir):
    """One sentence about what kind of code base this is, read from the files that say so."""
    pj = os.path.join(repo_dir, "package.json")
    if os.path.isfile(pj):
        try:
            with open(pj, encoding="utf-8", errors="replace") as f:
                d = json.load(f)
            deps = {}
            for section in ("dependencies", "devDependencies", "peerDependencies"):
                v = d.get(section)
                if isinstance(v, dict):
                    deps.update(v)
        except (OSError, ValueError, AttributeError):
            deps = {}
        known = (
            ("next", "a Next.js/React application"),
            ("react", "a React application"),
            ("vue", "a Vue application"),
            ("svelte", "a Svelte application"),
            ("express", "an Express (Node.js) service"),
            ("fastify", "a Fastify (Node.js) service"),
        )
        for key, name in known:
            if key in deps:
                return f"Context: this repository is {name} (read from its package.json)."
        return "Context: this repository is a JavaScript or TypeScript project (it has a package.json naming no framework this review knows)."
    for marker in ("pyproject.toml", "requirements.txt", "setup.py"):
        if os.path.isfile(os.path.join(repo_dir, marker)):
            return f"Context: this repository is a Python project (it has a {marker})."
    return "Context: this repository has no package.json, so treat it as a general code base and apply framework rules only where the code makes the framework obvious."


def lessons_block(lessons_dir):
    """(text for the prompt, note for the answer). The note is empty when the lessons were read."""
    files = sorted(glob.glob(os.path.join(lessons_dir, "LESSONS-INDEX-*.md")))
    if not files:
        return "", (f"Note: this review ran without the lessons index: no LESSONS-INDEX-*.md in "
                    f"{os.path.abspath(lessons_dir)}, so no recorded lesson could be cited.")
    parts = []
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            parts.append(f.read().strip())
    return "===== LESSONS\n\n" + "\n\n".join(parts), ""


# A finding that says a file was NOT changed (claude-config#533). The phrasings are the ones such a
# claim takes, anchored on the diff or the push so an ordinary "does not change the return type" is
# not caught; the path must also be one the complete list names, so a true absence is left alone.
ABSENCE = re.compile(
    r"(no changes? to|contains no change|not (?:been )?(?:changed|modified|updated|touched)|"
    r"(?:absent|missing) from (?:the|this) (?:diff|push)|not in (?:the|this) (?:diff|push)|"
    r"(?:diff|push) (?:does not|doesn't) (?:change|modify|touch|include))",
    re.IGNORECASE)


def changed_files(diff_path):
    """The paths the push changed, from the list the hook put at the top of the input, or None
    when there is no list or it was truncated, since a partial list cannot prove a file changed
    and must not be read as the whole truth."""
    paths, in_block = [], False
    try:
        with open(diff_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("===== FILES THIS PUSH CHANGED"):
                    in_block = True
                    continue
                if not in_block:
                    return None
                if line.startswith("===== END OF FILE LIST"):
                    return paths
                if line.startswith("TRUNCATED:"):
                    return None
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[1]:
                    paths.append(parts[1])
    except OSError:
        return None
    return None


def mark_false_absences(text, paths):
    """(text, count): each finding claiming a listed file was not changed gets a visible mark.
    Marked rather than deleted, because deleting would destroy the evidence the reviewer ignored
    the list, which is the thing to know about it (L340)."""
    if not paths:
        return text, 0
    out, marked = [], 0
    for line in text.splitlines():
        hit = None
        if ABSENCE.search(line):
            for p in sorted(paths, key=len, reverse=True):
                if p in line:
                    hit = p
                    break
        if hit:
            line += (f" [review harness: {hit} IS in this push, per the complete list of changed files, "
                     "so this finding's premise is false]")
            marked += 1
        out.append(line)
    return "\n".join(out), marked


FINDING = re.compile(r"^\S+:\d+: ")
LESSON = re.compile(r"\(L([0-9]{1,4})\)")


def count_findings(text):
    """The number of lines in the review's own finding shape, `<path>:<line>: ...`."""
    return sum(1 for line in text.splitlines() if FINDING.match(line))


def append_ledger(state_dir, meta, text):
    """One line per review with findings, never swept (see the module docstring)."""
    lessons = sorted({int(m) for m in LESSON.findall(text)})
    line = "\t".join(str(x) for x in (
        meta.get("finished", ""), meta.get("kind", "push"), meta.get("repo", ""), meta.get("sha", ""),
        meta.get("findings", ""), ",".join(f"L{n}" for n in lessons)))
    with open(os.path.join(state_dir, "citations.tsv"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


def write_finished(state_dir, name, meta, body):
    final = os.path.join(state_dir, name + ".txt")
    tmp = final + ".tmp"
    lines = [f"{k}={v}" for k, v in meta.items()]
    text = "\n".join(lines) + "\n\n" + (body.rstrip("\n") + "\n" if body else "")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, final)
    for leftover in (final + ".pending",):
        try:
            os.remove(leftover)
        except OSError:
            pass


def redact(text, stderr=False):
    """Reviewer text made safe to store and print (claude-config#581), through the ONE redactor,
    ar_redact in ai-review-common.sh. Its stderr once carried a live secret key quoted inside a
    permission rule warning, which the merge gate then echoed into the session. A redactor that
    cannot run withholds the text rather than passing it through raw (L42)."""
    common = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai-review-common.sh")
    args = ["bash", "-c", '. "$1" && ar_redact $2', "_", common, "--stderr" if stderr else ""]
    try:
        r = subprocess.run(args, input=text.encode("utf-8", errors="replace"),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "(withheld: the redactor could not run, so this text was not stored)"
    if r.returncode != 0:
        return "(withheld: the redactor failed, so this text was not stored)"
    return r.stdout.decode("utf-8", errors="replace").strip()


def main(argv):
    ap = argparse.ArgumentParser()
    for opt in ("--state-dir", "--key", "--sha", "--repo-label", "--branch", "--repo-dir",
                "--model", "--prompt-file", "--lessons-dir", "--diff-file"):
        ap.add_argument(opt, required=True)
    ap.add_argument("--deadline", type=int, required=True)
    ap.add_argument("--kind", default="push", choices=("push", "pr"))
    ap.add_argument("--base", default="")
    ap.add_argument("--scope-file", default="")
    ap.add_argument("--name", default="")
    ap.add_argument("--started", type=int, required=True)
    a = ap.parse_args(argv)

    name = a.name or f"{a.key}-{a.sha}"
    meta = {
        "repo": a.repo_label,
        "branch": a.branch,
        "sha": a.sha,
        "started": a.started,
        "finished": "",
        "status": "",
        "model": a.model,
        "deadline": a.deadline,
    }
    if a.kind == "pr":
        meta["kind"] = "pr"
        meta["base"] = a.base
        meta["findings"] = ""

    status, body = "error", ""
    lessons_note = ""
    try:
        with open(a.prompt_file, encoding="utf-8") as f:
            prompt_text = f.read()
        lessons, lessons_note = lessons_block(a.lessons_dir)
        scope = ""
        if a.scope_file:
            with open(a.scope_file, encoding="utf-8") as f:
                scope = f.read().strip() + "\n\n"
        prompt = framework_line(a.repo_dir) + "\n\n" + (lessons + "\n\n" if lessons else "") + scope + prompt_text

        # Hooks OFF (claude-config#560). Measured 2026-09-24, the first real whole branch reviews: the
        # headless claude ran Dan's global hooks, the reviewer's own tool use tripped the end of turn
        # issue review, and what came back was that review of the SESSION, not a review of the diff.
        # --bare would skip hooks too but refuses subscription sign in, so the setting is passed.
        # The findings tool OFF (claude-config#804). Claude Code offers every headless run a built
        # in ReportFindings tool whose own description says to report a code review through it and
        # not also print the findings as text, so the reviewer often did exactly that: measured
        # 2026-10-08, 6 of about 10 rounds on one pull request answered "I reported N findings
        # through ReportFindings" with no finding line, the gate correctly refused that as unparsed,
        # and the findings existed only in a tool call nobody reads. Disallowed, the tool is gone
        # from the run's tool list (checked against the run's own init event), so the text this
        # runner parses is the review's only channel. Last on the line because the flag takes a list.
        # MCP servers OFF (claude-config#956). Without it the reviewer started every server Dan has
        # connected (claude.ai connectors, plugin servers, his own), none of which a review of a diff
        # calls: 12 in the run's init event on 2026-10-08, and 0 with --strict-mcp-config and no
        # --mcp-config, which is what the flag means ("only use MCP servers from --mcp-config").
        # The servers cost startup on every review (median 2.39 s to the init event with them, 1.68 s
        # without, five runs each) and one stored answer ended with the reviewer's aside that they
        # needed authorizing, text that is neither a finding nor "No issues found.". So never name
        # an --mcp-config here: one would bring its servers straight back.
        cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt,
               "--model", a.model, "--settings", '{"disableAllHooks":true}', "--strict-mcp-config",
               "--disallowedTools", "ReportFindings"]
        with open(a.diff_file, "rb") as diff:
            # Its own process group, so the deadline can kill everything claude started and not
            # only the one pid subprocess knows about.
            proc = subprocess.Popen(cmd, stdin=diff, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, start_new_session=True)
            try:
                out, err = proc.communicate(timeout=a.deadline)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
                try:
                    proc.communicate(timeout=5)
                except (subprocess.TimeoutExpired, OSError):
                    pass
                status = "timeout"
                body = (f"The review did not finish inside {a.deadline} seconds and was stopped. "
                        "Nothing was read back. Re-run it by pushing again, or raise "
                        "AI_REVIEW_DEADLINE_SECONDS if this repository's pushes are routinely large.")
                out = err = b""
        if status != "timeout":
            text = out.decode("utf-8", errors="replace").strip()
            errtext = err.decode("utf-8", errors="replace").strip()
            if proc.returncode != 0:
                status = "error"
                # Never the raw stderr: settings warnings dropped and credentials redacted first.
                safe = redact(errtext, stderr=True) if errtext else ""
                tail = ("\n".join(safe.splitlines()[-5:]) if safe else
                        "(claude printed nothing on stderr)" if not errtext else
                        "(nothing left to show once settings warnings were dropped)")
                body = f"claude exited {proc.returncode} and no review was read back. Its last lines:\n{tail}"
            elif not text:
                status = "empty"
                body = "claude exited 0 and printed nothing, so there is no review to show."
            elif text != "No issues found." and count_findings(text) == 0:
                # Neither shape the prompt allows. Counting it as zero findings would read an answer
                # that is not a review (the hook hijack above, a refusal, a question back) as a clean
                # one (L98, L340), so it is its own outcome, kept verbatim as the evidence.
                status = "unparsed"
                body = ("The reviewer answered, but not in the review's format: no finding lines and not "
                        "\"No issues found.\", so this is not a review. What it said:\n" + redact(text))
            else:
                status = "ok"
                text, marked = mark_false_absences(text, changed_files(a.diff_file))
                if marked:
                    text = (f"Note: {marked} finding below claims a file this push changed was not changed; "
                            "the complete list of changed files says otherwise, and each is marked.\n\n"
                            if marked == 1 else
                            f"Note: {marked} findings below claim a file this push changed was not changed; "
                            "the complete list of changed files says otherwise, and each is marked.\n\n") + text
                body = text
                if a.kind == "pr":
                    meta["findings"] = count_findings(text)
    except Exception as e:  # noqa: BLE001  a crash here must still leave a finished file (L514)
        status = "error"
        body = f"The review runner failed before it could read an answer: {type(e).__name__}: {e}"

    if lessons_note:
        body = lessons_note + "\n\n" + body
    meta["finished"] = int(time.time())
    meta["status"] = status
    if status == "ok":
        try:
            append_ledger(a.state_dir, meta, body)
        except OSError:
            pass  # the ledger is a record for later; losing one line must not lose the review
    try:
        write_finished(a.state_dir, name, meta, body)
        if a.kind == "pr":
            # The durable outcome ledger, written by the one bash function every finishing path
            # shares (lib/ai-review-common.sh ar_pr_ledger, claude-config#562).
            common = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai-review-common.sh")
            subprocess.run(["bash", "-c", '. "$1" && ar_pr_ledger "$2" "$3"', "_", common,
                            os.path.join(a.state_dir, name + ".txt"), a.repo_dir],
                           env=dict(os.environ, AI_REVIEW_STATE_DIR=a.state_dir),
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30, check=False)
    finally:
        try:
            os.remove(a.diff_file)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
