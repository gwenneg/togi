# Friction capture (togi)

While you work in this repo, watch for **friction** — moments where the shared context docs failed you:

- **correction** — the user corrects a choice you got wrong when the right answer was **knowable** (a convention, a prior instruction, or a codebase pattern you missed) — so the docs need a louder rule
- **clarification** — the user supplies a fact you **lacked**: you hit real ambiguity, guessed, and guessed wrong — so the docs are missing that fact

**Record an event only if both hold:**

1. You can name the **specific, generalizable rule** a doc should state — an actual convention, location, or fact, not "I should have read more carefully."
2. The same gap would likely trip up you or another agent on a future task in this repo — i.e., fixing the doc has lasting value beyond the current task.

Skip one-off scope changes, transient errors, typos or slips with no underlying knowledge gap, and case-specific corrections. **Be selective** — a few real gaps per session, not every small exchange; a flood of marginal events is noise to whoever reviews them.

Also record an error you catch **yourself** if better docs would have prevented it — apply the same gate and classify it the same way. (Fixing something immediately does not disqualify a self-catch — the question is whether the knowledge gap would recur, not whether you recovered.)

(Denied tool calls are captured automatically — you do not record those.)

When an event qualifies, check `.togi/friction/pending/` (use that exact relative path, not an absolute one) for an existing file covering the same root cause (even under a different slug) — if so, reuse it; otherwise write a **new markdown file** there named with a short kebab-case slug of the root cause (e.g. `api-handler-location.md`). Use this format:

    # <type>

    <one paragraph: what went wrong, the project knowledge that was missing, and the concrete rule or example that would prevent recurrence. Name the subsystem, workflow, or convention precisely — this paragraph is the only signal the later step has for choosing which doc to fix.>

    **Misleading doc:** <optional — a doc in your context that gave wrong or outdated guidance>

where `<type>` is `correction` or `clarification`. Keep it lightweight — one short file, then carry on with your task. Do not edit project docs directly. After writing the file, output exactly one line: "Friction captured." — nothing more. If nothing qualifies, say nothing about friction.
