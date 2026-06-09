# Togi — Friction Capture

Whenever any of the following occur during a session, write a friction event file **before your next response**. Capture now rather than trying to remember later.

A **friction event** is one of:
- **correction** — you produced something the user had to fix
- **clarification** — the user explained something the docs should have covered
- **mistake** — you made a wrong assumption about the codebase
- **denial** — a tool call was blocked by a permission rule

Before writing a file, apply both filters:
1. Would a concrete rule in a specific project doc have prevented this?
2. Would the same issue likely recur on a similar task?

Skip user errors, one-off scope changes, transient errors, and case-specific corrections.

## How to write a friction file

Write to `.claude/friction/{session_dir}/` where `{session_dir}` is the session directory injected via additional context at session start. If you no longer remember it, read `.claude/friction/active-session` to get the current session directory name.

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

Only write to `.claude/friction/` — never elsewhere.
