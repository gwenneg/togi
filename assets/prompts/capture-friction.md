Review this entire session for friction events — corrections you were asked to make, clarifications the user gave that the docs should have covered, mistakes you made about the codebase, or tool calls that were denied.

Apply both filters before writing:
1. Would a concrete rule in a specific project doc have prevented this?
2. Would the same issue likely recur on a similar task?

Skip user errors, one-off scope changes, transient errors, and case-specific corrections.

For each qualifying event, write a file to `.claude/friction/` named `{{TIMESTAMP}}-<short-kebab-description>.md`:

```
---
type: correction|clarification|mistake|denial
doc_gap: <relative path from project root to the target doc file>
date: {{DATE}}
session: {{SESSION_ID}}
captured_by: <set this to the exact model id stated in your environment context>
cache: {{CACHE}}
---

<One paragraph: what went wrong, what project-specific knowledge was missing, and the concrete rule or example that would prevent recurrence.>
```

If no event qualifies, stop without writing anything. Your final output is not shown to anyone — write the friction files and output nothing else.
