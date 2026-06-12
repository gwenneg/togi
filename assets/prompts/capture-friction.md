Review this entire session for friction events — corrections you were asked to make, clarifications the user gave that the docs should have covered, mistakes you made about the codebase, or tool calls that were denied.

Apply both filters before including an event:
1. Would a concrete rule in a specific project doc have prevented this?
2. Would the same issue likely recur on a similar task?

Skip user errors, one-off scope changes, transient errors, and case-specific corrections.

Output a JSON array — `[]` if nothing qualifies. Each qualifying event is an object with these fields (all required except where noted):

- `type`: one of `correction`, `clarification`, `mistake`, `denial`
- `slug`: a short kebab-case description (e.g. `no-test-command-in-claude-md`)
- `captured_by`: your exact model ID as stated in your environment context
- `body`: one paragraph — what went wrong, what project-specific knowledge was missing, and the concrete rule or example that would prevent recurrence. Name the topic precisely (the subsystem, workflow, or convention involved): this paragraph is the only signal a later step has when deciding which doc the rule belongs in
- `misleading_doc`: include this field only when a doc that was loaded into this session's context contained wrong, outdated, or misleading guidance that contributed to the event — set it to that doc's path relative to the project root. Omit the field otherwise. Do not guess where missing knowledge *should* be documented: you cannot see the repo's doc tree, and the target doc is chosen later with full repo access

Output only the JSON array, nothing else. Do not wrap it in a code block.
