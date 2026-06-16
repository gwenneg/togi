# 4. UserPromptSubmit silent additionalContext

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-why-a-session-end-sweep-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** A `UserPromptSubmit` hook silently injects the friction-capture instruction (via `additionalContext`) the moment the user submits a prompt, so the directive is fresh as the model handles that turn.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| Low (advisory only) | Invisible | ~free | No | Low |

## What it is

Instead of relying on a buried `CLAUDE.md` directive (approach [1](01-claude-md-import.md)), this re-delivers the instruction on every user turn through a hook. `UserPromptSubmit`'s `additionalContext` is silent — the injected text is wrapped in a system reminder Claude sees but the user does not — and it lands *before* the model processes the prompt, giving maximal recency.

## Why it wasn't chosen

- **Advisory only** — like approach 1, it just asks the model to capture; nothing enforces it.
- **Fires at the moment of least hindsight** — before the model has even responded, so it cannot reflect on a turn that hasn't happened yet.

Effectively approach 1 with better recency: it defeats habituation (fresh every turn) but keeps the low, unmeasurable recall of a purely advisory instruction.

## Implementation plan

1. **Register a `UserPromptSubmit` hook.**
2. **Emit `additionalContext`** carrying the friction directive (or a short salience nudge pointing at a fuller directive). Keep it terse — it is injected every user turn, so it is a recurring token cost.
3. **Optionally make it conditional** — grep the submitted `prompt` for correction cues and only inject when one appears, cutting the per-turn cost (at the recall cost of approach [3](03-conditional-stop-hook.md)).
4. Reuse the existing counter and `/togi:update-context-docs`.

## Risks & open questions

- **No enforcement** — capture remains the model's choice.
- **Least-hindsight timing** — better suited to *priming* than to *reflecting*; pairing with a `Stop`-side reflection could help.
- **Recurring context tax** — every-turn injection adds tokens; throttle or make conditional.
- Recall remains low and unmeasurable.
