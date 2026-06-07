---
name: update-context-docs
description: Review captured friction events, apply them to context docs, and open a pull request
allowedTools:
  - Bash(bash *)
  - Bash(find *)
  - Bash(git add *)
  - Bash(git branch *)
  - Bash(git checkout *)
  - Bash(git fetch *)
  - Bash(git rev-parse *)
  - Edit
  - Read
---

# Instructions

## Phase 1: Binary version check

Run:

```bash
.claude/bin/togi install --check
```

- Exit code 0: binary is up to date. Continue to Phase 2.
- Exit code 2: a newer version is available. The output shows the installed and latest
  versions. Use `AskUserQuestion` to inform the user:

  > A newer version of togi is available (see above).
  >
  > The binary handles friction capture and security validation. Updating will:
  > 1. Download the new binary from the GitHub release
  > 2. Verify its build attestation (`gh attestation verify`)
  > 3. Verify its SHA-256 checksum
  > 4. Replace `.claude/bin/togi` with the new version
  >
  > Update now?

  Options: **Update now (recommended)** / **Continue without updating**

  If the user selects **Continue without updating**, proceed to Phase 2.

  If the user selects **Update now**, run:

  ```bash
  .claude/bin/togi install
  ```

  Show the full output to the user. If the command fails, stop and report the error.
  Otherwise continue to Phase 2.

- If the binary does not exist or the command fails for any other reason, skip this phase
  and continue to Phase 2.

## Phase 2: Read friction events

Read all `*.md` files from `.claude/friction/` recursively (each session has its own subfolder: `.claude/friction/{session-id}/{slug}.md`). If none exist, report "No friction events to process." and stop.

For each file, extract the YAML frontmatter fields (`type`, `doc_gap`, `date`) and the body paragraph. Group events by `doc_gap` — the named file is the edit target.

## Phase 3: User exclusion

Print a numbered list of all events:
```
Events to be processed:
  1. one-sentence summary of what friction it captured
  2. ...
```

Then use `AskUserQuestion` with a single question: "Enter the numbers of any events to exclude (comma-separated), or proceed with all." Provide one option — "Proceed with all" — and rely on the "Other" free-text input for exclusions.

Events the user excludes are tracked as "Skipped by user" and must not result in any doc edits.

## Phase 4: Create branch

Detect the default branch with `git rev-parse --abbrev-ref origin/HEAD` and check whether `friction/update-context-docs-YYYY-MM-DD` already exists with `git branch --list` (increment a numeric suffix until the name is unique, e.g. `-2`, `-3`). Then run:

```bash
git fetch origin
git checkout -b friction/update-context-docs-YYYY-MM-DD origin/<default-branch>
```

## Phase 5: Apply edits

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

## Phase 6: Propose eval cases (optional)

If a `promptfoo.yaml` or similar eval config exists, propose a new test case for each friction event backed by multiple events whose expected behavior can be verified with a `contains`/`not-contains` assertion rather than LLM judgment. Each case needs: `description`, `vars.task`, and at least one `contains`/`not-contains` or `llm-rubric` assertion.

## Phase 7: Clean up

Delete the session subfolders for all processed friction events from `.claude/friction/`. Each subfolder is named after the session ID; deleting it removes all friction files for that session at once.

## Phase 8: Commit and open a PR

Stage only the files that were actually edited in Phase 5 — do not use `git add -A`.
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
