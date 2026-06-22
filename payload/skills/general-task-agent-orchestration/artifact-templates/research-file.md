# Research File Template

Use this template for all research output files (Phase 2 first wave and Phase 4 second wave).

---

```markdown
# <Research Domain> - Research

**Wave**: <First | Second>
**Researcher**: <Subagent description>
**Date**: <date>
**Status**: Complete
**Target Surface(s)**: <Browser | Native | Files | Communication | Calendar | APIs | Code | Multiple>

---

## Summary

<2-3 sentence overview of findings>

## Key Findings

### <Finding Category 1>

<Detailed findings with specifics - tool names, platform details, configuration patterns, version numbers>

### <Finding Category 2>

<Detailed findings>

## Recommended Approach

Based on research, the recommended approach for this domain is:

1. <Specific recommendation>
2. <Specific recommendation>

## Alternatives Considered

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| <Option A> | ... | ... | Recommended / Rejected |
| <Option B> | ... | ... | ... |

## Pitfalls and Edge Cases

- <Specific pitfall with mitigation>
- <Edge case to watch for>

## References

- <URL or source>
- <Documentation link>

---

## Second Wave Additions (if applicable)

### Execution Details (filtered by DISCOVERY.md)

<Specific execution guidance aligned with user's decisions>

### Tool and Surface Configuration

| Tool/Service | Surface | Purpose | Setup Required | Agent Can Self-Configure? |
|-------------|---------|---------|----------------|---------------------------|
| <Tool> | <Surface> | <Why needed> | <API key / config> | Yes (Playwright/Peekaboo) / No (user) |

### Verification Strategy

<How to verify this domain's deliverables on their target surface>

- Verification method: <surface-specific check>
- Evidence to capture: <snapshots, screenshots, file reads, API responses>
- Acceptance threshold: <what "pass" looks like>

### Human Actions Required

| Action | Who | How | Status |
|--------|-----|-----|--------|
| <Get API key> | User | <Instructions> | Pending |
| <Configure webhook> | Agent (Playwright) | <Steps> | Pending |
```

---

## Guidelines for Research Files

- **Be specific** - include version numbers, exact configurations, real examples
- **Be thorough** - this research informs all downstream decisions
- **Distinguish facts from opinions** - clearly label recommendations vs findings
- **Second wave focuses on execution** - how to accomplish it, not what to accomplish
- **Include verification angles** - how to confirm deliverables are correct on each surface
- **Flag human-required actions** - what can the agent do via Playwright/Peekaboo vs what truly needs the user
- **Tag target surfaces** - note which execution surfaces this research domain touches
