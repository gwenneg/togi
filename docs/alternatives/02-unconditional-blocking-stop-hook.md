# 2. Unconditional blocking Stop hook

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** A `Stop` hook fires at every turn end and *blocks* the stop, forcing the model to review the just-finished turn for friction before it is allowed to finish.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| Medium | **Prompt wall every turn** | ~$1+ (extra inference/turn) | No | Low |

## What it is

Where approach [1](01-claude-md-import.md) relies on the model remembering a standing instruction, this enforces capture just-in-time: a `Stop` hook returns a block decision every turn, with the friction-capture instruction in the hook's `reason`. The model cannot end the turn until it has processed the instruction (and recorded any friction).

## Why it wasn't chosen

- **A blocking `Stop` hook's `reason` is user-visible by design** — a ~22-line prompt rendered every single turn. There is no silent form of a block.
- **Most expensive option** — one extra model inference per turn (the model re-runs to satisfy the block), plus the `reason` text accumulating in context turn after turn.

The just-in-time enforcement fixes the attention/habituation problem of approach 1, but the cost and the every-turn prompt wall make it unusable as a default.

## Implementation plan

1. **Register a `Stop` hook** (no matcher; fires on every turn completion).
2. **Return a block** — exit code 2, or JSON `decision: "block"` — with a `reason` that instructs the model to capture any friction from this turn (write an event file) before stopping.
3. **Guard against loops** — track per-turn state (e.g. a marker keyed by the last assistant message id) so the hook blocks at most once per turn and lets the model stop on the second pass.
4. Reuse the existing `SessionStart` counter and `/togi:update-context-docs`.

## Risks & open questions

- **Visible `reason` every turn** — unavoidable; this is the dealbreaker.
- **Cost** — an extra inference per turn is the most expensive of all options.
- **Loop risk** — without a solid per-turn guard, the block can repeat indefinitely.
- Context bloat from the accumulating `reason`.
