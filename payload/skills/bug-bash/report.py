#!/usr/bin/env python3
"""report.py: build the bug bash report Dan reads from a run's findings file (claude-config#719).

    python3 ~/.claude/skills/bug-bash/report.py <findings.json>

The findings file is what the verify step writes. Its shape:

    {
      "target": "http://127.0.0.1:4173/",
      "mode": "local" | "read-only",
      "cost": {"model_calls": 23},
      "findings": [
        {"id": "f3", "area": "Invoices", "persona": "numbers and copy", "title": "...",
         "status": "confirmed",
         "test": "e2e/bug-bash/invoice-total.spec.ts",
         "failure": "the failing assertion, quoted from the test run",
         "reason_match": "why that failure is the explorer's reason and not another"},
        {"id": "f4", ..., "status": "unverified", "why_unverified": "..."},
        {"id": "f1", ..., "status": "rejected", "reject_reason": "explorer-artifact", "note": "..."}
      ]
    }

A finding reaches the confirmed section only with all three pieces of evidence: the test that
reproduces it, the failure that test printed, and why that failure is the reason the explorer gave.
Anything short of that is refused, naming the finding, rather than reported as a bug. Rejections take
one reason from a fixed list so they can be grouped and counted.

The report runs: confirmed bugs, then risks that could not be verified locally, then rejected
findings grouped by reason, then what the run cost. Exit 0 with the report on stdout, or 2 with the
reason on stderr and nothing on stdout.
"""

import json
import sys

REJECT_REASONS = {
    "not-reproduced": "Not reproduced: the verifying test passed",
    "failed-for-other-reason": "The test failed, but not for the reason the explorer gave",
    "local-setup": "Explained by the local setup or seed data",
    "explorer-artifact": "An artefact of how the explorer looked (a new tab, a slow first load, a missed wait)",
    "works-as-designed": "Works as designed",
    "duplicate": "Duplicate of another finding",
}
STATUSES = ("confirmed", "unverified", "rejected")


class Refusal(Exception):
    pass


def text(f, key):
    value = f.get(key)
    return value.strip() if isinstance(value, str) else ""


def validate(data):
    if not isinstance(data, dict):
        raise Refusal("the findings file must be a JSON object")
    cost = data.get("cost")
    calls = cost.get("model_calls") if isinstance(cost, dict) else None
    if not isinstance(calls, int) or isinstance(calls, bool) or calls < 0:
        raise Refusal(
            "cost.model_calls must be the number of model calls the run made: "
            "a bug bash is paid per run, so the report always says what it cost"
        )
    if data.get("mode") not in ("local", "read-only"):
        raise Refusal('mode must be "local" or "read-only"')
    findings = data.get("findings")
    if not isinstance(findings, list):
        raise Refusal("findings must be a list (an empty one when nothing was found)")
    seen = set()
    for f in findings:
        if not isinstance(f, dict):
            raise Refusal("every finding must be an object")
        fid = text(f, "id")
        if not fid:
            raise Refusal("every finding needs an id")
        if fid in seen:
            raise Refusal(f"finding {fid} appears twice: give each finding its own id")
        seen.add(fid)
        if not text(f, "title"):
            raise Refusal(f"finding {fid} has no title")
        status = f.get("status")
        if status not in STATUSES:
            raise Refusal(f"finding {fid} has status {status!r}; it must be one of {', '.join(STATUSES)}")
        if status == "confirmed":
            missing = [k for k, what in (
                ("test", "the test that reproduces it"),
                ("failure", "the failing output that test printed"),
                ("reason_match", "why that failure is the reason the explorer gave"),
            ) if not text(f, k)]
            if missing:
                raise Refusal(
                    f"finding {fid} is marked confirmed without {', '.join(missing)}: a finding counts "
                    "as confirmed only once its test fails for the explorer's reason. Verify it, or mark "
                    "it unverified or rejected"
                )
        elif status == "unverified" and not text(f, "why_unverified"):
            raise Refusal(f"finding {fid} is unverified with no why_unverified saying what stopped a local test")
        elif status == "rejected" and f.get("reject_reason") not in REJECT_REASONS:
            raise Refusal(
                f"finding {fid} has reject_reason {f.get('reject_reason')!r}; it must be one of "
                + ", ".join(REJECT_REASONS)
            )
    return findings, calls


def where(f):
    parts = [p for p in (text(f, "area"), text(f, "persona")) if p]
    return f" ({', '.join(parts)})" if parts else ""


def render(data, findings, calls):
    by = {s: [f for f in findings if f["status"] == s] for s in STATUSES}
    out = [f"# Bug bash: {data.get('target', '')}".rstrip()]
    if data["mode"] == "read-only":
        out.append("")
        out.append("Read only run against a deployment: nothing was changed there, and nothing could be "
                   "reproduced with a test, so every finding is a risk to verify locally.")
    if not findings:
        out.append("")
        out.append("No findings: every explorer finished and reported nothing.")

    out += ["", f"## Confirmed bugs ({len(by['confirmed'])})"]
    if not by["confirmed"]:
        out.append("None: no finding was reproduced by a failing test.")
    for f in by["confirmed"]:
        out.append(f"- **{text(f, 'title')}**{where(f)}")
        out.append(f"  - Failing test: `{text(f, 'test')}`")
        out.append(f"  - Failure: {text(f, 'failure')}")
        out.append(f"  - Why this is the reported bug: {text(f, 'reason_match')}")

    out += ["", f"## Risks not verifiable locally ({len(by['unverified'])})"]
    if not by["unverified"]:
        out.append("None.")
    for f in by["unverified"]:
        out.append(f"- **{text(f, 'title')}**{where(f)}: {text(f, 'why_unverified')}")

    out += ["", f"## Rejected ({len(by['rejected'])})"]
    if not by["rejected"]:
        out.append("None.")
    for reason, label in REJECT_REASONS.items():
        group = [f for f in by["rejected"] if f["reject_reason"] == reason]
        if not group:
            continue
        out.append(f"### {label} ({len(group)})")
        for f in group:
            note = text(f, "note")
            out.append(f"- {text(f, 'title')}{where(f)}" + (f": {note}" if note else ""))

    out += ["", "## Cost", f"{calls} model calls."]
    return "\n".join(out) + "\n"


def main(argv):
    if len(argv) != 2:
        print("Usage: report.py <findings.json>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print(f"report.py: no findings file at {argv[1]}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"report.py: the findings file is not valid JSON: {exc}", file=sys.stderr)
        return 2
    try:
        findings, calls = validate(data)
    except Refusal as exc:
        print(f"report.py: {exc}", file=sys.stderr)
        return 2
    sys.stdout.write(render(data, findings, calls))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
