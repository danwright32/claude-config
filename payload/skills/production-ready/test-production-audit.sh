#!/usr/bin/env bash
# Tests for the production-ready audit's legal coverage and its agent ceiling (claude-config#1753),
# by RUNNING production-audit.workflow.js with every agent stood in (production-audit.harness.cjs),
# not by grepping its text. The 2026-10-24 audit of a consumer site missed CAN-SPAM entirely: the
# profiler set sendsEmail false because the repo sends no email, so nothing looked at the consumer
# email sent from outside systems, and most legal checks that did land came from a hand written
# focus argument the script did not have. It also ran 19 auditors at once, above the four agent rule.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${PRODUCTION_AUDIT_WORKFLOW:-$DIR/production-audit.workflow.js}"
H="$DIR/production-audit.harness.cjs"
pass=0; fail=0
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is missing, so the audit could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# expect <scenario> <description> <python expression over r (result), calls, logs, mx (most at once)>
expect() {
  local scen="$1" what="$2" expr="$3" out
  out="$(node "$H" "$WF" "$scen" 2>&1)"
  if python3 -c '
import json, sys
d = json.loads(sys.argv[1]); r, calls, logs, mx = d["result"], d["calls"], d["logs"], d["maxInFlight"]
labels = [c["label"] for c in calls]
prompt = lambda lab: next((c["prompt"] for c in calls if c["label"] == lab), "")
audits = [l for l in labels if l.startswith("audit:")]
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$out" "$expr" 2>/dev/null; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: [$scen] $what"; echo "  expr: $expr"; echo "  out: ${out:0:600}"
  fi
}

# The compliance auditor is asked about every law the trypennie report had to add by hand.
for term in "CAN-SPAM" "postal address" "List-Unsubscribe" "10 business days" "TCPA" "proof of" \
  "Global Privacy Control" "COPPA" "auto renewal" "DMCA" "GLBA" "FCRA" "TILA" "UDAAP" "HIPAA"; do
  expect default "the compliance auditor is asked about: $term" "'$term' in prompt('audit:compliance-audit')"
done
# Third party resources and session recording sit with personal data.
for term in "visitor IP" "fonts" "session recording" "CIPA" "consent"; do
  expect default "the personal data auditor is asked about: $term" "'$term'.lower() in prompt('audit:data-isolation-pii').lower()"
done
expect default "accessibility is graded as ADA legal exposure" "'ADA' in prompt('audit:accessibility') and 'WCAG 2.1 AA' in prompt('audit:accessibility')"

# The profiler is asked about consumer messaging sent from OUTSIDE the repo, not only from it.
expect default "the profiler is asked which outside systems email, text or call consumers" "'outside' in prompt('profile') and 'consumerMessaging' in prompt('profile')"
expect default "and told sendsEmail counts email sent from anywhere" "'sendsEmailFromRepo' in prompt('profile')"
expect not-inspected "outside systems the person named reach the profiler" "'Quillfeather Dialer' in prompt('profile')"
expect default "every auditor is told to tag a finding with the law it exposes" "all('law' in prompt(a) for a in audits)"

# Every finding keeps its law into the report.
expect default "a backlog item carries the law it exposes" "[b.get('law') for b in r['report']['backlog']] == ['CAN-SPAM']"
expect default "and nothing is reported lost" "r['report']['lawTagsLost'] == []"
expect law-dropped "a law tag synthesis dropped is reported, never silently lost" "r['report']['lawTagsLost'] == ['CAN-SPAM']"
expect law-dropped "and logged" "any('CAN-SPAM' in l for l in logs)"

# What could not be inspected is reported, including an outside system nobody mentioned.
expect not-inspected "an outside system the auditor could not inspect is reported with its reason" "{'system': 'Larkspur CRM', 'reason': 'templates live in the CRM, not the repo', 'domain': 'compliance-audit'} in r['report']['notInspected']"
expect not-inspected "an outside system no auditor reported on is reported too" "any(n['system'] == 'Quillfeather Dialer' and 'no auditor' in n['reason'] for n in r['report']['notInspected'])"
expect default "an outside system no finding names is reported as uninspected" "any(n['system'] == 'Larkspur CRM' for n in r['report']['notInspected'])"
expect crm-inspected "an outside system a finding's evidence names counts as inspected" "not any(n['system'] == 'Larkspur CRM' for n in r['report']['notInspected'])"

# The legal domains are never dropped from a public site holding personal data.
expect drops-legal "compliance is audited although the profiler excluded it" "'audit:compliance-audit' in labels"
expect drops-legal "personal data is audited although the profiler excluded it" "'audit:data-isolation-pii' in labels"
expect drops-legal "and the override is logged" "any('compliance-audit' in l and 'kept' in l for l in logs)"
expect drops-legal "and neither is listed as not applicable" "not any(n['key'] in ('compliance-audit', 'data-isolation-pii') for n in r['naDomains'])"
expect internal-tool "an internal tool with no public surface may still skip compliance" "'audit:compliance-audit' not in labels"

# A dead auditor is never a clean domain.
expect dead-auditor "a domain whose auditor died is reported unaudited" "r['report']['unauditedDomains'] == ['compliance-audit']"
expect dead-auditor "and the run still finishes the other domains" "len(audits) == len(r['applicable'])"
expect dead-auditor "and the outside CRM is reported as not inspected" "any(n['system'] == 'Larkspur CRM' for n in r['report']['notInspected'])"
expect default "a run where every auditor answered reports none unaudited" "r['report']['unauditedDomains'] == []"

# At most four agents run at once, and every applicable domain is still audited.
expect default "never more than four agents at once" "mx <= 4"
expect default "with more than one at once, so the ceiling is what held it" "mx > 1"
expect default "every applicable domain is audited" "len(audits) == len(r['applicable']) == 19"
expect dead-auditor "a dead agent frees its place, so the ceiling holds and the run finishes" "mx <= 4 and len(audits) == 19"

# focus is a documented argument: it adds emphasis to every auditor, and is absent when not given.
expect focus "a focus reaches every auditor" "all('consumer email sent from the CRM' in prompt(a) for a in audits)"
expect focus "and the profiler" "'consumer email sent from the CRM' in prompt('profile')"
expect default "no focus line when none was given" "not any('extra attention' in prompt(a) for a in audits)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
