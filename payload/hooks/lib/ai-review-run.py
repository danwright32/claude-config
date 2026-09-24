#!/usr/bin/env python3
"""The detached half of the advisory AI review (claude-config#433).

ai-review-on-push.sh starts this in the background the moment a `git push` has succeeded and
returns at once, so the push waits for nothing. This process then asks `claude` to review the
diff and writes the answer where ai-review-nudge.sh will find it on a later prompt.

    ai-review-run.py --state-dir D --key K --sha S --repo-label L --branch B --repo-dir R
                     --model M --prompt-file P --lessons-dir D --diff-file F --deadline SECONDS
                     --started EPOCH

It runs EXACTLY `env -u CLAUDECODE CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p <prompt> --model
<model>` with the diff on stdin.
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
"""
import argparse
import glob
import json
import os
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


def main(argv):
    ap = argparse.ArgumentParser()
    for opt in ("--state-dir", "--key", "--sha", "--repo-label", "--branch", "--repo-dir",
                "--model", "--prompt-file", "--lessons-dir", "--diff-file"):
        ap.add_argument(opt, required=True)
    ap.add_argument("--deadline", type=int, required=True)
    ap.add_argument("--started", type=int, required=True)
    a = ap.parse_args(argv)

    name = f"{a.key}-{a.sha}"
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

    status, body = "error", ""
    lessons_note = ""
    try:
        with open(a.prompt_file, encoding="utf-8") as f:
            prompt_text = f.read()
        lessons, lessons_note = lessons_block(a.lessons_dir)
        prompt = framework_line(a.repo_dir) + "\n\n" + (lessons + "\n\n" if lessons else "") + prompt_text

        cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt,
               "--model", a.model]
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
                tail = "\n".join(errtext.splitlines()[-5:]) if errtext else "(claude printed nothing on stderr)"
                body = f"claude exited {proc.returncode} and no review was read back. Its last lines:\n{tail}"
            elif not text:
                status = "empty"
                body = "claude exited 0 and printed nothing, so there is no review to show."
            else:
                status = "ok"
                body = text
    except Exception as e:  # noqa: BLE001  a crash here must still leave a finished file (L514)
        status = "error"
        body = f"The review runner failed before it could read an answer: {type(e).__name__}: {e}"

    if lessons_note:
        body = lessons_note + "\n\n" + body
    meta["finished"] = int(time.time())
    meta["status"] = status
    try:
        write_finished(a.state_dir, name, meta, body)
    finally:
        try:
            os.remove(a.diff_file)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
