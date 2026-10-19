#!/usr/bin/env python3
"""Score the pre merge lessons review on a fixed set of judged cases (claude-config#1355).

    review-score.py run      [--cases DIR] [--results-dir DIR] [--all | --sample N | --only ID,ID]
                             [--repeat N] [--model M] [--window N] [--jobs N] [--deadline S]
                             [--hooks-lib DIR] [--lessons-dir DIR] [--save-baseline]
    review-score.py rescore  RUN.json [--cases DIR] [--results-dir DIR] [--window N]
    review-score.py baseline RUN.json [--cases DIR] [--results-dir DIR]
    review-score.py check    [--cases DIR]

Run it BY HAND when the review's prompt, its runner or its model changes, never per pull request.
It reports two numbers: CATCH RATE, the real defects in the cases that the review found, and WRONG
FINDING RATE, the review's findings that match one already judged wrong. A change is kept only if
neither gets worse than the saved baseline.

WHERE THE CASES LIVE. --cases, else $REVIEW_SCORE_CASES, else ~/.claude-review-cases. The real
judged set quotes private code from other repositories and this repository is public, so it lives
on the Mac, outside this repository and outside ~/.claude: nothing the config sync ever carries can
reach it. ~/.claude/state is not mirrored today either (MIRROR_DIRS in claude-sync names hooks,
agents, commands, audits and mods, and .gitignore drops state/), but a folder outside ~/.claude
cannot start being carried by a later change to the sync. tools/review-score-sample is a small
INVENTED set, public on purpose, that proves the scorer works. A case set that is not there is
reported as UNMEASURED and exits 2, never as a zero score (L411, L90).

A CASE is one directory: input.diff, exactly what the reviewer reads on standard input (the
"===== FILES THIS PUSH CHANGED" block, then the diff), and case.json, whose "items" are the judged
points in that diff, each {id, verdict, file, line, quote, keywords, claim}. The verdict is real (a
defect the review should catch), trivial (true but minor), wrong (a finding judged wrong, to watch
for) or unsure. An optional "package_json" object stands in for the repository's package.json,
which the runner reads to name the framework.

MATCHING a finding (`path:line: text`) to an item: the same file, and EITHER the cited line within
--window lines of the item's (default 20: the 2026-10-19 sample found 44 of 60 findings citing the
wrong line, nearly all within about 20 lines, #1357) OR the finding quoting the item's line text,
AND, when the item lists keywords, at least one of them in the finding's text, so a finding near a
defect that makes some other claim does not count as catching it. A finding takes the closest
matching item. A real item matched by any finding is caught, once however many findings hit it.
A finding matching no item is UNJUDGED: it counts in the denominator of the wrong rate but is not
wrong, and its text is kept in the results file for a person to judge and add to the case.

WHAT A RUN COSTS. Each case is one review by the real runner (payload/hooks/lib/ai-review-run.py,
the prompt and scope beside it, the lessons index under payload/), so one review per case per
repeat. The cost is MEASURED, not estimated: a shim put first on PATH runs the real claude with
--output-format json and hands the runner the review text, keeping the cost and token counts it
reports. With no selection a run reviews an evenly spread sample of 3 cases; --all reviews every
case. Each review costs about what one lessons review of that diff costs.

RESULTS go to --results-dir (default <cases>/results): run-<UTC time>.json per run, holding every
review's raw findings, and baseline.json. A comparison re-matches BOTH runs against the case set as
it is now, over only the cases both measured, so a judgement added after the baseline was taken
applies to both sides, and a subset run is compared like for like. The terminal shows ids and
counts only, never a finding's text, which can quote private code (L222).

EXIT: 0 compared and not worse, 1 worse than the baseline, 2 unmeasured (no case set, no claude,
or no case could be reviewed), 3 scored with no baseline covering these cases.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_HOOKS_LIB = os.path.join(REPO, "payload", "hooks", "lib")
DEFAULT_LESSONS_DIR = os.path.join(REPO, "payload")
DEFAULT_SAMPLE = 3
DEFAULT_WINDOW = 20
VERDICTS = ("real", "trivial", "wrong", "unsure")

EXIT_OK, EXIT_WORSE, EXIT_UNMEASURED, EXIT_NO_BASELINE = 0, 1, 2, 3


class Unmeasured(Exception):
    """Nothing could be measured; the message says why."""


# ---------------------------------------------------------------------------------------------
# The case set

def cases_dir(arg):
    if arg:
        return os.path.abspath(os.path.expanduser(arg))
    env = os.environ.get("REVIEW_SCORE_CASES", "")
    if env:
        return os.path.abspath(os.path.expanduser(env))
    return os.path.join(os.path.expanduser("~"), ".claude-review-cases")


def require_cases(path):
    if not os.path.isdir(path):
        raise Unmeasured(
            f"no case set at {path}. Point at one with --cases DIR or REVIEW_SCORE_CASES=DIR; "
            "the public invented sample is tools/review-score-sample.")
    ids = sorted(d for d in os.listdir(path)
                 if os.path.isfile(os.path.join(path, d, "case.json")))
    if not ids:
        raise Unmeasured(f"{path} holds no case (a directory with a case.json).")
    return ids


def diff_files(diff_text):
    """The paths the diff changes, from its +++ lines and its file list."""
    files = set()
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            p = line[4:].strip()
            if p != "/dev/null":
                files.add(norm(p))
        elif line.startswith("diff --git "):
            parts = line.split()
            if len(parts) >= 4:
                files.add(norm(parts[3]))
    return files


def load_case(root, cid):
    """(case dict, list of problems). A case with problems is not scored."""
    d = os.path.join(root, cid)
    problems = []
    try:
        with open(os.path.join(d, "case.json"), encoding="utf-8") as f:
            case = json.load(f)
    except (OSError, ValueError) as e:
        return None, [f"case.json does not read: {e}"]
    diff_path = os.path.join(d, "input.diff")
    try:
        with open(diff_path, encoding="utf-8", errors="replace") as f:
            diff = f.read()
    except OSError:
        diff = ""
    if not diff.strip():
        problems.append("input.diff is missing or empty")
    changed = diff_files(diff)
    items = case.get("items")
    if not isinstance(items, list):
        return None, problems + ["case.json has no items list"]
    seen = set()
    for i, it in enumerate(items):
        if not isinstance(it, dict):
            problems.append(f"item {i + 1} is not an object")
            continue
        iid = it.get("id") or f"#{i + 1}"
        if iid in seen:
            problems.append(f"item id {iid} is used twice")
        seen.add(iid)
        if it.get("verdict") not in VERDICTS:
            problems.append(f"item {iid} has verdict {it.get('verdict')!r}, not one of {', '.join(VERDICTS)}")
        if not isinstance(it.get("line"), int):
            problems.append(f"item {iid} has no whole number line")
        f = it.get("file")
        if not isinstance(f, str) or not f:
            problems.append(f"item {iid} names no file")
        elif changed and not any(same_file(f, c) for c in changed):
            problems.append(f"item {iid} names {f}, which the diff does not change, so no review can find it there")
    case["diff_path"] = diff_path
    case["id"] = cid
    return case, problems


# ---------------------------------------------------------------------------------------------
# Matching

def _runner_module(hooks_lib):
    """The runner itself, so a finding line is recognised by the same pattern the gate counts."""
    path = os.path.join(hooks_lib, "ai-review-run.py")
    spec = importlib.util.spec_from_file_location("ai_review_run", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FINDING_PARTS = re.compile(r"^(\S+):(\d+): (.*)$")


def norm(p):
    p = p.strip().strip("`")
    for pre in ("a/", "b/", "./"):
        if p.startswith(pre):
            p = p[len(pre):]
    return p


def same_file(a, b):
    a, b = norm(a), norm(b)
    return a == b or a.endswith("/" + b) or b.endswith("/" + a)


def parse_findings(lines):
    out = []
    for line in lines:
        m = FINDING_PARTS.match(line)
        if m:
            out.append({"file": m.group(1), "line": int(m.group(2)), "text": m.group(3)})
    return out


def match_item(finding, items, window):
    """The item this finding is about, or None."""
    text = finding["text"].lower()
    best, best_dist = None, None
    for it in items:
        if not same_file(finding["file"], it.get("file", "")):
            continue
        quote = (it.get("quote") or "").strip()
        dist = abs(finding["line"] - it.get("line", 0))
        if quote and quote.lower() in text:
            dist = 0
        elif dist > window:
            continue
        kws = [k.lower() for k in it.get("keywords") or [] if k]
        if kws and not any(k in text for k in kws):
            continue
        if best is None or dist < best_dist:
            best, best_dist = it, dist
    return best


def score_case(case, reviews, window):
    """Counts for one case over its measured reviews."""
    items = case["items"]
    real = [it for it in items if it.get("verdict") == "real"]
    s = {"reviews": 0, "real": 0, "caught": 0, "findings": 0,
         "real_findings": 0, "trivial": 0, "wrong": 0, "unsure": 0, "unjudged": 0,
         "missed": [], "unjudged_text": []}
    for rv in reviews:
        if rv.get("status") != "ok":
            continue
        s["reviews"] += 1
        s["real"] += len(real)
        hit = set()
        for f in parse_findings(rv.get("findings", [])):
            s["findings"] += 1
            it = match_item(f, items, window)
            if it is None:
                s["unjudged"] += 1
                s["unjudged_text"].append(f"{f['file']}:{f['line']}: {f['text']}")
                continue
            v = it["verdict"]
            if v == "real":
                s["real_findings"] += 1
                hit.add(it["id"])
            else:
                s[v] += 1
        s["caught"] += len(hit)
        for it in real:
            if it["id"] not in hit and it["id"] not in s["missed"]:
                s["missed"].append(it["id"])
    return s


def totals(per_case):
    keys = ("reviews", "real", "caught", "findings", "real_findings", "trivial", "wrong", "unsure", "unjudged")
    t = {k: 0 for k in keys}
    for s in per_case.values():
        for k in keys:
            t[k] += s[k]
    return t


def pct(n, d):
    return round(100.0 * n / d) if d else None


def rates(t):
    return {"catch": (t["caught"] / t["real"]) if t["real"] else None,
            "wrong": (t["wrong"] / t["findings"]) if t["findings"] else None}


def score_run(run, cases, window):
    """{case id: counts} for the measured cases of a stored run, judged by the cases as they are now."""
    per = {}
    for cid, entry in run["cases"].items():
        case = cases.get(cid)
        if case is None:
            continue
        s = score_case(case, entry.get("reviews", []), window)
        if s["reviews"]:
            per[cid] = s
    return per


# ---------------------------------------------------------------------------------------------
# Reviewing

SHIM = r'''#!/usr/bin/env python3
# The real claude, asked for JSON, so the scorer can read what each review cost. The runner sees
# only the review text, as it would from the real claude, and the same exit status.
import json, os, subprocess, sys
real = os.environ["REVIEW_SCORE_REAL_CLAUDE"]
p = subprocess.run([real] + sys.argv[1:] + ["--output-format", "json"], stdin=sys.stdin,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
sys.stderr.write(p.stderr.decode("utf-8", "replace"))
raw = p.stdout.decode("utf-8", "replace")
try:
    d = json.loads(raw)
    text = d.get("result") or ""
    usage = {"cost_usd": d.get("total_cost_usd"), "usage": d.get("usage") or {}}
except ValueError:
    text, usage = raw, None
if usage is not None:
    with open(os.environ["REVIEW_SCORE_USAGE_FILE"], "w", encoding="utf-8") as f:
        json.dump(usage, f)
sys.stdout.write(text)
sys.exit(p.returncode)
'''


def review_once(case, cfg, real_claude):
    """One review of one case by the real runner. Never raises: a failure is a status."""
    started = time.time()
    tmp = tempfile.mkdtemp(prefix="review-score-")
    try:
        state = os.path.join(tmp, "state"); os.mkdir(state)
        repo = os.path.join(tmp, "repo"); os.mkdir(repo)
        bindir = os.path.join(tmp, "bin"); os.mkdir(bindir)
        shim = os.path.join(bindir, "claude")
        with open(shim, "w", encoding="utf-8") as f:
            f.write(SHIM)
        os.chmod(shim, os.stat(shim).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        if isinstance(case.get("package_json"), dict):
            with open(os.path.join(repo, "package.json"), "w", encoding="utf-8") as f:
                json.dump(case["package_json"], f)
        diff = os.path.join(tmp, "input.diff")
        shutil.copyfile(case["diff_path"], diff)  # the runner deletes the diff it was given
        usage_file = os.path.join(tmp, "usage.json")
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ.get("PATH", ""),
                   REVIEW_SCORE_REAL_CLAUDE=real_claude, REVIEW_SCORE_USAGE_FILE=usage_file,
                   AI_REVIEW_STATE_DIR=state)
        lib = cfg["hooks_lib"]
        cmd = [sys.executable, os.path.join(lib, "ai-review-run.py"),
               "--state-dir", state, "--key", "score", "--sha", case["id"], "--name", "review",
               "--kind", "pr", "--base", "score", "--repo-label", case["id"], "--branch", "score",
               "--repo-dir", repo, "--model", cfg["model"],
               "--prompt-file", os.path.join(lib, "ai-review-prompt.txt"),
               "--scope-file", os.path.join(lib, "ai-review-pr-scope.txt"),
               "--lessons-dir", cfg["lessons_dir"], "--diff-file", diff,
               "--deadline", str(cfg["deadline"]), "--started", str(int(started))]
        try:
            subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=cfg["deadline"] + 60, check=False)
        except subprocess.TimeoutExpired:
            return {"status": "timeout", "note": "the runner itself did not return", "findings": [],
                    "seconds": round(time.time() - started)}
        out = os.path.join(state, "review.txt")
        try:
            with open(out, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            return {"status": "error", "note": "the runner left no finished review", "findings": [],
                    "seconds": round(time.time() - started)}
        head, _, body = text.partition("\n\n")
        meta = dict(l.split("=", 1) for l in head.splitlines() if "=" in l)
        status = meta.get("status", "error")
        lines = body.splitlines()
        rv = {"status": status, "findings": [l for l in lines if cfg["finding_re"].match(l)],
              "seconds": round(time.time() - started)}
        if status != "ok":
            rv["note"] = (lines[0] if lines else "")[:200]
        try:
            with open(usage_file, encoding="utf-8") as f:
                u = json.load(f)
            rv["cost_usd"] = u.get("cost_usd")
            rv["usage"] = u.get("usage") or {}
        except (OSError, ValueError):
            pass
        return rv
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def pick(ids, args):
    if args.only:
        want = [x.strip() for x in args.only.split(",") if x.strip()]
        unknown = [x for x in want if x not in ids]
        if unknown:
            raise Unmeasured(f"no case named {', '.join(unknown)} in the case set.")
        return want, f"{len(want)} named case{'s' if len(want) != 1 else ''}"
    if args.all:
        return ids, f"all {len(ids)} cases"
    n = args.sample if args.sample is not None else DEFAULT_SAMPLE
    if n <= 0:
        raise Unmeasured("--sample must be at least 1.")
    if n >= len(ids):
        return ids, f"all {len(ids)} cases"
    chosen = [ids[(i * len(ids)) // n] for i in range(n)]
    return chosen, f"sample of {n} of {len(ids)} cases"


def default_model(hooks_lib):
    """The model the lessons review uses, read from pr-review.sh so the two cannot drift."""
    with open(os.path.join(hooks_lib, "pr-review.sh"), encoding="utf-8") as f:
        m = re.search(r"AI_REVIEW_MODEL:-([A-Za-z0-9._-]+)", f.read())
    if not m:
        raise Unmeasured("could not read the lessons review's default model from pr-review.sh; pass --model.")
    return os.environ.get("AI_REVIEW_MODEL") or m.group(1)


def file_hash(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:12]
    except OSError:
        return ""


# ---------------------------------------------------------------------------------------------
# Reporting

def fmt_rate(n, d):
    p = pct(n, d)
    return "unmeasured" if p is None else f"{p}%"


def print_scores(t, per, unmeasured, cost):
    print(f"  catch rate: {t['caught']} of {t['real']} real defects caught ({fmt_rate(t['caught'], t['real'])})"
          if t["real"] else "  catch rate: unmeasured (these cases hold no real defect)")
    print(f"  wrong findings: {t['wrong']} of {t['findings']} findings judged wrong ({fmt_rate(t['wrong'], t['findings'])})"
          if t["findings"] else "  wrong findings: none, the review raised no finding")
    print(f"  also: trivial {t['trivial']}, unsure {t['unsure']}, unjudged {t['unjudged']}")
    missed = [f"{cid} {m}" for cid in sorted(per) for m in per[cid]["missed"]]
    print(f"  missed: {', '.join(missed) if missed else 'none'}")
    print(f"  unmeasured: {', '.join(unmeasured) if unmeasured else 'none'}")
    print(cost)


def cost_line(run):
    usd, tin, tout, n, gaps = 0.0, 0, 0, 0, 0
    for entry in run["cases"].values():
        for rv in entry.get("reviews", []):
            if rv.get("status") != "ok" and "cost_usd" not in rv:
                continue  # a review that failed before claude answered cost nothing to report
            if rv.get("cost_usd") is None:
                gaps += 1
                continue
            n += 1
            usd += float(rv["cost_usd"])
            u = rv.get("usage") or {}
            tin += sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            tout += int(u.get("output_tokens") or 0)
    if not n:
        return "  cost: unmeasured (no review reported its cost)"
    gap = f", {gaps} review{'s' if gaps != 1 else ''} did not report one" if gaps else ""
    return (f"  cost: ${usd:.2f} measured over {n} review{'s' if n != 1 else ''} "
            f"({tin:,} input tokens, {tout:,} output tokens, about ${usd / n:.2f} a review){gap}")


def compare(run, base, cases, window):
    """(exit code, lines). Both runs judged by the cases as they are now, over the cases both measured."""
    now = score_run(run, cases, window)
    then = score_run(base, cases, window)
    common = sorted(set(now) & set(then))
    if not common:
        return EXIT_NO_BASELINE, ["Baseline: none of these cases was measured in the baseline, so nothing is compared."]
    tn = totals({c: now[c] for c in common})
    tb = totals({c: then[c] for c in common})
    rn, rb = rates(tn), rates(tb)
    lines = [f"Baseline {base.get('name', '')} (model {base.get('model', '?')}), same {len(common)} case{'s' if len(common) != 1 else ''}: "
             f"catch {tb['caught']} of {tb['real']} ({fmt_rate(tb['caught'], tb['real'])}), "
             f"wrong {tb['wrong']} of {tb['findings']} ({fmt_rate(tb['wrong'], tb['findings'])})"]
    worse = []
    if rn["catch"] is not None and rb["catch"] is not None and rn["catch"] < rb["catch"]:
        worse.append(f"catch rate fell from {fmt_rate(tb['caught'], tb['real'])} to {fmt_rate(tn['caught'], tn['real'])}")
    if rn["wrong"] is not None and rb["wrong"] is not None and rn["wrong"] > rb["wrong"]:
        worse.append(f"wrong finding rate rose from {fmt_rate(tb['wrong'], tb['findings'])} to {fmt_rate(tn['wrong'], tn['findings'])}")
    elif rn["wrong"] is not None and rb["wrong"] is None and tn["wrong"]:
        worse.append(f"wrong finding rate rose from none to {fmt_rate(tn['wrong'], tn['findings'])}")
    if worse:
        lines.append("REGRESSION: " + "; ".join(worse) + ". Keep the change only if this holds up on a second run.")
        return EXIT_WORSE, lines
    lines.append(f"NOT WORSE: catch {fmt_rate(tb['caught'], tb['real'])} then, {fmt_rate(tn['caught'], tn['real'])} now; "
                 f"wrong {fmt_rate(tb['wrong'], tb['findings'])} then, {fmt_rate(tn['wrong'], tn['findings'])} now.")
    return EXIT_OK, lines


def failed_reviews(run):
    """One line per case of a run with a failed review, for both a run and a rescore: a case whose
    reviews all failed is left out of the score, and one where only some failed is scored on fewer
    reviews, and neither may happen without being said."""
    out = []
    for cid in sorted(run["cases"]):
        statuses = [rv.get("status", "error") for rv in run["cases"][cid].get("reviews", [])]
        failed = sorted({s for s in statuses if s != "ok"})
        if failed and "ok" not in statuses:
            out.append(f"{cid} ({', '.join(failed)})")
        elif failed:
            n_bad = sum(1 for s in statuses if s != "ok")
            out.append(f"{cid} ({n_bad} of {len(statuses)} reviews failed: {', '.join(failed)})")
    return out


def load_all_cases(root, ids):
    cases, bad = {}, {}
    for cid in ids:
        case, problems = load_case(root, cid)
        if case is None or problems:
            bad[cid] = problems
        else:
            cases[cid] = case
    return cases, bad


def report(run, cases, window, results_dir, unmeasured):
    per = score_run(run, cases, window)
    if not per:
        print("UNMEASURED: no case was reviewed successfully, so there is no score."
              + (f" Unmeasured: {', '.join(unmeasured)}." if unmeasured else ""))
        return EXIT_UNMEASURED
    t = totals(per)
    print(f"Lessons review score: {run.get('selection', '')}, model {run.get('model', '?')}, "
          f"{run.get('repeat', 1)} review{'s' if run.get('repeat', 1) != 1 else ''} each")
    print_scores(t, per, unmeasured, cost_line(run))
    base_path = os.path.join(results_dir, "baseline.json")
    if not os.path.isfile(base_path):
        print(f"Baseline: no baseline yet in {results_dir}. Save this run as one with: "
              f"review-score.py baseline {run.get('path', 'RUN.json')} --results-dir {results_dir}")
        return EXIT_NO_BASELINE
    with open(base_path, encoding="utf-8") as f:
        base = json.load(f)
    code, lines = compare(run, base, cases, window)
    for line in lines:
        print(line)
    return code


# ---------------------------------------------------------------------------------------------
# Commands

def cmd_check(args):
    root = cases_dir(args.cases)
    ids = require_cases(root)
    counts = {v: 0 for v in VERDICTS}
    n_items, bad = 0, 0
    for cid in ids:
        case, problems = load_case(root, cid)
        for p in problems:
            print(f"{cid}: {p}")
        if problems:
            bad += 1
        for it in (case or {}).get("items", []):
            if isinstance(it, dict) and it.get("verdict") in counts:
                counts[it["verdict"]] += 1
            n_items += 1
    print(f"{len(ids)} case{'s' if len(ids) != 1 else ''}, {n_items} items: "
          + ", ".join(f"{counts[v]} {v}" for v in VERDICTS))
    if bad:
        print(f"{bad} case{'s' if bad != 1 else ''} with problems: a run would leave them unmeasured.")
        return 1
    return 0


def cmd_run(args):
    root = cases_dir(args.cases)
    ids = require_cases(root)
    chosen, selection = pick(ids, args)
    if args.repeat < 1:
        raise Unmeasured("--repeat must be at least 1.")
    real_claude = shutil.which("claude")
    if not real_claude:
        raise Unmeasured("claude is not on PATH, so no review can run.")
    hooks_lib = os.path.abspath(args.hooks_lib)
    cfg = {"hooks_lib": hooks_lib, "lessons_dir": os.path.abspath(args.lessons_dir),
           "model": args.model or default_model(hooks_lib), "deadline": args.deadline,
           "finding_re": _runner_module(hooks_lib).FINDING}
    cases, bad = load_all_cases(root, chosen)
    results_dir = os.path.abspath(args.results_dir or os.path.join(root, "results"))
    os.makedirs(results_dir, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(results_dir, f"run-{stamp}.json")
    n = 1
    while os.path.exists(path):
        n += 1
        path = os.path.join(results_dir, f"run-{stamp}-{n}.json")
    run = {"version": 1, "name": os.path.basename(path), "path": path, "started": int(time.time()),
           "model": cfg["model"], "repeat": args.repeat, "window": args.window, "selection": selection,
           "cases_dir": root,
           "hashes": {"prompt": file_hash(os.path.join(hooks_lib, "ai-review-prompt.txt")),
                      "scope": file_hash(os.path.join(hooks_lib, "ai-review-pr-scope.txt")),
                      "runner": file_hash(os.path.join(hooks_lib, "ai-review-run.py"))},
           "cases": {}}
    unmeasured = [f"{cid} ({'; '.join(p)})" for cid, p in sorted(bad.items())]
    jobs = [(cid, r) for cid in chosen if cid in cases for r in range(args.repeat)]
    print(f"Reviewing {len(jobs)} time{'s' if len(jobs) != 1 else ''} ({selection}, {args.repeat} each) "
          f"with {cfg['model']}, {args.jobs} at once; each review takes about as long as a lessons review.",
          flush=True)
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futs = {pool.submit(review_once, cases[cid], cfg, real_claude): cid for cid, _ in jobs}
        for fut in concurrent.futures.as_completed(futs):
            cid = futs[fut]
            rv = fut.result()
            run["cases"].setdefault(cid, {"reviews": []})["reviews"].append(rv)
            done += 1
            print(f"  [{done}/{len(jobs)}] {cid}: {rv['status']}, {len(rv['findings'])} finding"
                  f"{'s' if len(rv['findings']) != 1 else ''}, {rv['seconds']}s", flush=True)
    unmeasured += failed_reviews(run)
    run["finished"] = int(time.time())
    per = score_run(run, cases, args.window)
    run["scored"] = per
    with open(path, "w", encoding="utf-8") as f:
        json.dump(run, f, indent=2)
    print(f"Results: {path}")
    code = report(run, cases, args.window, results_dir, unmeasured)
    if args.save_baseline:
        save_baseline_if_safe(run, path, code, results_dir)
    return code


def save_baseline_if_safe(run, path, code, results_dir):
    """Replace the baseline only with a run that is not worse AND measured every case the baseline
    did, or when there is none yet. A regressed run saved would make the next comparison measure
    against the regression, and a subset run saved would drop every other case from all later
    comparisons (L5). Accepting either on purpose is the baseline command, named in the refusal."""
    base_path = os.path.join(results_dir, "baseline.json")
    accept = f"To accept it anyway: review-score.py baseline {path} --results-dir {results_dir}"
    if code == EXIT_UNMEASURED:
        print("Nothing was measured, so it was not saved as the baseline.")
        return
    if not os.path.isfile(base_path):
        shutil.copyfile(path, base_path)
        print(f"Saved as the baseline in {results_dir}.")
        return
    if code == EXIT_WORSE:
        print(f"This run is worse than the baseline, so it was not saved as the baseline. {accept}")
        return
    with open(base_path, encoding="utf-8") as f:
        base = json.load(f)

    def measured(r):
        return {cid for cid, e in r.get("cases", {}).items()
                if any(rv.get("status") == "ok" for rv in e.get("reviews", []))}

    left_out = sorted(measured(base) - measured(run))
    if left_out:
        print(f"This run covers only some of the baseline's cases ({len(left_out)} of the baseline's "
              f"{len(measured(base))} not measured here), so it was not saved as the baseline. {accept}")
        return
    shutil.copyfile(path, base_path)
    print(f"Saved as the baseline in {results_dir}.")


def read_run(path):
    try:
        with open(path, encoding="utf-8") as f:
            run = json.load(f)
    except (OSError, ValueError) as e:
        raise Unmeasured(f"cannot read the run {path}: {e}")
    if not isinstance(run.get("cases"), dict):
        raise Unmeasured(f"{path} is not a run written by review-score.py.")
    return run


def cmd_rescore(args):
    run = read_run(args.run)
    root = cases_dir(args.cases or run.get("cases_dir"))
    ids = require_cases(root)
    cases, bad = load_all_cases(root, [c for c in run["cases"] if c in ids])
    results_dir = os.path.abspath(args.results_dir or os.path.join(root, "results"))
    unmeasured = sorted([f"{cid} ({'; '.join(p)})" for cid, p in bad.items()]
                        + [f"{cid} (no longer in the case set)" for cid in run["cases"] if cid not in ids]
                        + failed_reviews(run))
    print(f"Rescoring {os.path.basename(args.run)} against the case set as it is now (no review is run).")
    return report(run, cases, args.window, results_dir, unmeasured)


def cmd_baseline(args):
    run = read_run(args.run)
    root = cases_dir(args.cases or run.get("cases_dir"))
    results_dir = os.path.abspath(args.results_dir or os.path.join(root, "results"))
    os.makedirs(results_dir, exist_ok=True)
    shutil.copyfile(args.run, os.path.join(results_dir, "baseline.json"))
    print(f"Saved {os.path.basename(args.run)} (model {run.get('model', '?')}, {run.get('selection', '')}) "
          f"as the baseline in {results_dir}.")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="Score the pre merge lessons review on a judged case set.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--cases", default=None)
        p.add_argument("--results-dir", default=None)

    r = sub.add_parser("run"); common(r)
    sel = r.add_mutually_exclusive_group()
    sel.add_argument("--all", action="store_true")
    sel.add_argument("--sample", type=int, default=None)
    sel.add_argument("--only", default="")
    r.add_argument("--repeat", type=int, default=1)
    r.add_argument("--model", default="")
    r.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    r.add_argument("--jobs", type=int, default=3)
    r.add_argument("--deadline", type=int, default=600)
    r.add_argument("--hooks-lib", default=DEFAULT_HOOKS_LIB)
    r.add_argument("--lessons-dir", default=DEFAULT_LESSONS_DIR)
    r.add_argument("--save-baseline", action="store_true")

    rs = sub.add_parser("rescore"); rs.add_argument("run"); common(rs)
    rs.add_argument("--window", type=int, default=DEFAULT_WINDOW)

    b = sub.add_parser("baseline"); b.add_argument("run"); common(b)

    c = sub.add_parser("check"); c.add_argument("--cases", default=None)

    args = ap.parse_args(argv)
    try:
        return {"run": cmd_run, "rescore": cmd_rescore, "baseline": cmd_baseline, "check": cmd_check}[args.cmd](args)
    except Unmeasured as e:
        print(f"UNMEASURED: {e}")
        return EXIT_UNMEASURED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
