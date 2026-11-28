#!/usr/bin/env python3
"""Say whether a model check can run on this Mac (claude-config#3471).

    model_tools.py check

A model check needs two things: a Java runtime that starts, and the TLA+ tools jar, whose bytes
match the checksum its publisher gave. This reads both and installs nothing: installing is a step
the skill asks Dan for first (SKILL.md, "Model check guides").

  java    VERIFICATION_JAVA, else the `java` found on PATH. It must run `java -version` and exit 0;
          macOS ships a `java` that only says no runtime is installed, and that is reported as
          broken, never as present.
  jar     VERIFICATION_TLA_JAR, else <VERIFICATION_HOME>/tools/tla2tools.jar (default
          ~/.claude-verification, outside ~/.claude so the sync never carries a jar to the public
          repository).
  sha256  <jar>.sha256 beside the jar: the checksum the install step copied from the place the jar
          was published, as 64 hex characters. The jar's own SHA-256 must equal it.

Prints {"ready": true, "java", "jar", "sha256"} and exits 0 only when all three hold. Otherwise
prints {"ready": false, "problems": [...]} and one `verification: <kind>: the model check could not
run: ...` line per problem on stderr, every problem at once:

  3  model-tools-missing     no java, no jar, or no recorded checksum
  4  model-tools-broken      a java that does not start, or a jar that cannot be read
     model-tools-unverified  a checksum record that cannot be read or is not 64 hex characters
     model-tools-mismatch    a jar whose bytes differ from its recorded checksum
  2  usage

A check that could not run is never a pass (L98): no caller may read exit 3 or 4 as ready.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
sys.path.insert(0, HERE)

import verification as v  # noqa: E402

SHA256_RE = re.compile(r"^[0-9a-f]{64}\Z")
EXIT = {"model-tools-missing": 3}
JAVA_TIMEOUT_S = 30


def _problem(kind, message):
    return (kind, "the model check could not run: " + message)


def jar_path():
    return os.environ.get("VERIFICATION_TLA_JAR") or os.path.join(v.verification_home(), "tools", "tla2tools.jar")


def check_tools():
    problems, out = [], {}
    java = os.environ.get("VERIFICATION_JAVA") or shutil.which("java")
    if not java or not os.path.isfile(java):
        problems.append(_problem("model-tools-missing", "no java on PATH (or at VERIFICATION_JAVA): a Java runtime is needed"))
    else:
        out["java"] = java
        try:
            r = subprocess.run([java, "-version"], capture_output=True, text=True, timeout=JAVA_TIMEOUT_S)
            if r.returncode != 0:
                first = v.first_line((r.stderr or "") + (r.stdout or "")) or "(it printed nothing)"
                problems.append(_problem("model-tools-broken", "%s -version exited %d: %s" % (java, r.returncode, first)))
        except subprocess.TimeoutExpired:
            problems.append(_problem("model-tools-broken", "%s -version did not finish in %d seconds" % (java, JAVA_TIMEOUT_S)))
        except OSError as e:
            problems.append(_problem("model-tools-broken", "%s could not be started: %s" % (java, e)))
    jar = jar_path()
    out["jar"] = jar
    if not os.path.isfile(jar):
        problems.append(_problem("model-tools-missing", "%s is not there: the TLA+ tools jar is needed" % jar))
    else:
        record = jar + ".sha256"
        expected = None
        try:
            with open(record, encoding="ascii", errors="strict") as f:
                expected = f.read().strip().lower()
        except FileNotFoundError:
            problems.append(_problem("model-tools-missing", "no published checksum is recorded at %s, so the jar"
                                     " cannot be trusted" % record))
        except (OSError, UnicodeDecodeError) as e:
            problems.append(_problem("model-tools-unverified", "%s could not be read as a checksum: %s" % (record, e)))
        if expected is not None:
            if not SHA256_RE.match(expected):
                problems.append(_problem("model-tools-unverified", "%s does not hold a SHA-256 (64 hex characters)" % record))
            else:
                h = hashlib.sha256()
                try:
                    with open(jar, "rb") as f:
                        for chunk in iter(lambda: f.read(1 << 20), b""):
                            h.update(chunk)
                    out["sha256"] = h.hexdigest()
                except OSError as e:
                    problems.append(_problem("model-tools-broken", "%s could not be read: %s" % (jar, e)))
                if "sha256" in out and out["sha256"] != expected:
                    problems.append(_problem("model-tools-mismatch", "%s has SHA-256 %s, not the published %s"
                                             % (jar, out["sha256"], expected)))
    return out, problems


def main(argv):
    if argv != ["check"]:
        print("verification: usage: model_tools.py check (see the docstring at the top of %s)" % os.path.abspath(__file__),
              file=sys.stderr)
        return 2
    out, problems = check_tools()
    if problems:
        print(json.dumps({"ready": False, "problems": [{"kind": k, "message": m} for k, m in problems]}, indent=2))
        for k, m in problems:
            print("verification: %s: %s" % (k, m), file=sys.stderr)
        # 3 when every problem is something absent, else 4: a broken or mismatched tool outranks it.
        return max(EXIT.get(k, 4) for k, _ in problems)
    print(json.dumps(dict({"ready": True}, **out), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
