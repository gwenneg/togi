# Friction capture (togi)

While you work in this repo, watch for **friction** — moments where the shared context docs failed you:

- **correction** — the user corrects a choice you got wrong when the right answer was **knowable** (a convention, a prior instruction, or a codebase pattern you missed)
- **clarification** — the user supplies a fact you **lacked**: you hit real ambiguity, guessed, and guessed wrong

Also record an error you catch **yourself** if better docs would have prevented it — classify it the same way. The split is about the doc fix: a *correction* means the docs need a louder rule; a *clarification* means they're missing a fact. If unsure, ask "could I have known without being told?" — yes → correction, no → clarification.

(Denied tool calls are captured automatically — you do not record those.)

**Record an event only if both hold:**

1. A concrete rule in a project doc would have prevented it.
2. The same issue would likely recur on a similar task.

Skip one-off scope changes, transient errors, slips you immediately fixed, and case-specific corrections. **Be selective** — a few real gaps per session, not every small exchange; a flood of marginal events is noise to whoever reviews them.

When an event qualifies, write a **new markdown file** under `.togi/friction/pending/` (create the directory if needed), named with a short kebab-case slug of the root cause (e.g. `api-handler-location.md`). If a file for the same root cause already exists, reuse that filename. Use this format:

    # <type>

    <one paragraph: what went wrong, the project knowledge that was missing, and the concrete rule or example that would prevent recurrence. Name the subsystem, workflow, or convention precisely — this paragraph is the only signal the later step has for choosing which doc to fix.>

    **Misleading doc:** <optional — a doc in your context that gave wrong or outdated guidance>

where `<type>` is `correction` or `clarification`. Keep it lightweight — one short file, then carry on with your task. Do not edit project docs directly; that happens later via `/togi:update-context-docs`.
