---
name: update-context-docs
description: Review captured friction events, apply them to context docs, and open a pull request
allowed-tools:
  - Bash(find *)
  - Bash(rm -rf .claude/friction/)
  - Bash(git add *)
  - Bash(git branch *)
  - Bash(git checkout *)
  - Bash(git fetch *)
  - Bash(git rev-parse *)
  - Bash(git commit *)
  - Bash(git push *)
  - Bash(gh pr create)
  - Edit
  - Read
---

# Instructions

## Phase 1: Read friction events

Read all `*.md` files from `.claude/friction/` recursively (each session has its own subfolder: `.claude/friction/{session-id}/{slug}.md`). If none exist, report "No friction events to process." and stop.

For each file, extract the YAML frontmatter fields (`type`, `doc_gap`, `date`) and the body paragraph. Group events by `doc_gap` — the named file is the edit target.

## Phase 2: User exclusion

Print a numbered list of all events:
```
Events to be processed:
  1. one-sentence summary of what friction it captured
  2. ...
```

Then use `AskUserQuestion` with a single question: "Enter the numbers of any events to exclude (comma-separated), or proceed with all." Provide one option — "Proceed with all" — and rely on the "Other" free-text input for exclusions.

Events the user excludes are tracked as "Skipped by user" and must not result in any doc edits.

## Phase 3: Create branch

Detect the default branch with:

```bash
git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|^origin/||'
```

If that returns empty (origin/HEAD not configured, common in manually-cloned repos), fall back to:

```bash
git remote show origin 2>/dev/null | awk '/HEAD branch:/ {print $NF}'
```

If both fail, default to `main`. Then check whether `friction/update-context-docs-YYYY-MM-DD` already exists with `git branch --list` (increment a numeric suffix until the name is unique, e.g. `-2`, `-3`). Then run:

```bash
git fetch origin
git checkout -b friction/update-context-docs-YYYY-MM-DD origin/<default-branch>
```

## Phase 4: Apply edits

For each non-excluded event:
- Only edit files that exist
- Read the target file
- Assess severity based on the event description, the target file's existing content, and event count for that file:
  - **low**: edge case or minor clarification — add one targeted rule or example, no restructuring
  - **medium**: recurring pattern or missing convention — add a rule with an example
  - **high**: fundamental gap affecting core behavior — broader edit, may touch related sections
- Add a rule, example, or clarification that prevents the friction from recurring
- Follow the file's existing formatting conventions
- Do not reorganize existing content
- Do not push a file past 200 lines — consolidate instead of appending

## Phase 5: Propose eval cases (optional)

If a `promptfoo.yaml` or similar eval config exists, propose a new test case for each friction event backed by multiple events whose expected behavior can be verified with a `contains`/`not-contains` assertion rather than LLM judgment. Each case needs: `description`, `vars.task`, and at least one `contains`/`not-contains` or `llm-rubric` assertion.

## Phase 6: Clean up

Delete only the individual friction files that were **processed** (not excluded by the user) in Phase 2. After deleting individual files, also delete any session subdirectories under `.claude/friction/` that are now empty. Do not delete session subdirectories that still contain excluded files — those should appear in the next run of `/togi:update-context-docs`.

## Phase 7: Commit and open a PR

Stage only the files that were actually edited in Phase 4 — do not use `git add -A`.
List each modified file explicitly:

```bash
git add <file1> <file2> ...
```

Commit with message `docs: improve context docs from friction capture`, push, and open a PR. The PR body must contain:
- One line per friction event in the format `YYYY-MM-DD — <what the friction was> → <what changed>`
- A metrics section:

```
## Friction Metrics

### Events
| Type | Count |
|---|---|
| Corrections | N |
| Clarifications | N |
| Denials | N |
| Mistakes | N |
| **Total** | **N** |

### Outcomes
| Result | Count |
|---|---|
| Docs improved | N |
| Eval cases added | N |
| Skipped by user | N |

**Docs improved:** `file1.md`, `file2.md`
```

- The standard `Generated with Claude Code` footer
