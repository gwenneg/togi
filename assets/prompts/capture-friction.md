Review this entire session for friction events — corrections you were asked to make, clarifications the user gave that the docs should have covered, mistakes you made about the codebase, or tool calls that were denied.

Apply both filters before including an event:
1. Would a concrete rule in a specific project doc have prevented this?
2. Would the same issue likely recur on a similar task?

Skip user errors, one-off scope changes, transient errors, and case-specific corrections.

Output a JSON array — `[]` if nothing qualifies. Each qualifying event is an object with these fields:

- `type`: one of `correction`, `clarification`, `mistake`, `denial`
- `slug`: a short kebab-case description (e.g. `no-test-command-in-claude-md`)
- `doc_gap`: relative path from the project root to the target doc file
- `captured_by`: your exact model ID as stated in your environment context
- `body`: one paragraph — what went wrong, what project-specific knowledge was missing, and the concrete rule or example that would prevent recurrence

Output only the JSON array, nothing else. Do not wrap it in a code block.
