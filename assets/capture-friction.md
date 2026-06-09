# Togi — Friction Capture

Write a friction file **before your next response** whenever any of the following occur.

A friction event is one of:
- **correction** — you produced something the user had to fix
- **clarification** — the user explained something the docs should have covered
- **mistake** — you made a wrong assumption about the codebase
- **denial** — a tool call was blocked by a permission rule

Before writing a file, apply both filters:
1. Would a concrete rule in a specific project doc have prevented this?
2. Would the same issue likely recur on a similar task?

Skip user errors, one-off scope changes, transient errors, and case-specific corrections.

## How to write a friction file

Read `.claude/friction/active-session` to get the session directory name, then write to `.claude/friction/{session_dir}/`.

Use a short kebab-case filename describing the event: `missing-auth-docs.md`, `wrong-test-command.md`.

```
---
type: correction|clarification|mistake|denial
doc_gap: <relative path from project root to the target doc file>
date: <YYYY-MM-DD>
---

<One paragraph: what went wrong, what project-specific knowledge was missing,
and the concrete rule or example that would prevent recurrence.>
```

Only write friction events to `.claude/friction/` — never elsewhere.
