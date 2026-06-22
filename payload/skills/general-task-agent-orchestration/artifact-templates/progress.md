# PROGRESS.md Template

Use this template when creating the progress tracker (Phase 12). This file enables session continuity - any new session reads it to know where things stand.

---

```markdown
# <Project Name> - Execution Progress

**Target**: <Date or milestone>
**Current Phase**: <Phase N: Name> (Task N.M in progress)

---

## Phase Overview

| Phase | Status | Tasks Done | Total | Notes |
|-------|--------|------------|-------|-------|
| 1: <Name> | pending | 0 | <N> | |
| 2: <Name> | pending | 0 | <N> | |
| ... | | | | |
| N: Verification | pending | 0 | <N> | |
| **Total** | | **0** | **<Total>** | |

---

## Task Progress

### Phase 1: <Name>

| Task | Title | Surface(s) | Status | Date | Verification | Notes |
|------|-------|-----------|--------|------|--------------|-------|
| 1.1 | <Title> | <Surface tags> | pending | | | |
| 1.2 | <Title> | <Surface tags> | pending | | | |
| ... | | | | | | |
| 1.V | Phase 1 Verification Sweep | All | pending | | | |

### Phase 2: <Name>

| Task | Title | Surface(s) | Status | Date | Verification | Notes |
|------|-------|-----------|--------|------|--------------|-------|
| 2.1 | <Title> | <Surface tags> | pending | | | |
| ... | | | | | | |

### Phase N: Verification

| Task | Title | Surface(s) | Status | Date | Verification | Notes |
|------|-------|-----------|--------|------|--------------|-------|
| N.1 | <Title> | <Surface tags> | pending | | | |
| ... | | | | | | |

---

## Verification Sweep Results

### Phase 1 Verification Sweep
- Status: pending
- Results: <TBD>
- Evidence:
  - [browser] <Snapshot/screenshot reference>
  - [native] <Peekaboo capture reference>
  - [file] <File read confirmation>
  - [api] <API response reference>

### Phase 2 Verification Sweep
- Status: pending
- Results: <TBD>

---

## Surface Setup Status

| Tool/Surface | Type | Status | Notes |
|-------------|------|--------|-------|
| Playwright MCP | MCP | <verified/pending> | |
| Peekaboo CLI | CLI | <verified/pending> | |
| <Tool> | <Type> | pending | <Setup required> |
| ... | | | |

---

## Blockers

| Blocker | Type | Surfaces Affected | Status | Resolution |
|---------|------|-------------------|--------|------------|
| <None> | | | | |
```

---

## Guidelines for PROGRESS.md

- **This is the source of truth** for what's done, what's in progress, and what's next
- **Update after every task** - status, date, verification result, and notes
- **Status values**: `pending`, `in-progress`, `done`, `blocked`, `failed`
- **Surface column** - shows which surfaces each task touches, enabling surface-specific debugging
- **Verification column** - records pass/fail per verification check, not just overall status
- **Evidence in notes** - include snapshot excerpts, screenshot paths, API responses as verification evidence
- **Verification sweep results** - detailed pass/fail per surface, not just "passed"
- **Session continuity** - a new session reads this file first to understand current state
- **Keep it current** - stale PROGRESS.md leads to duplicate work or missed tasks
