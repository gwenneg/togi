# 5. Layered capture — denials + keyword fast path + once-per-session sweep

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** Combine three cheap mechanisms — a `PermissionDenied` hook for denials, a keyword fast path for obvious corrections, and one transcript sweep per session for the rest — to reach high recall without any extra API call.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| High | One visible block/session | Low | No | High |

## What it is

Each friction type is captured at its cheapest reliable level:

- **Denials** — a `PermissionDenied` hook records them directly as typed events (free, no model).
- **Obvious corrections** — a conditional keyword path (approach [3](03-conditional-stop-hook.md) or [4](04-userpromptsubmit-injection.md)) catches the cue-bearing ones.
- **Everything else** — a single per-session pass over the transcript (local/heuristic, or deferred to next start) sweeps up what the first two missed.

Results from all three are deduplicated into one friction store.

## Why it wasn't chosen

- **Three mechanisms to maintain** — and the dedup logic across them.
- **Still one visible block per session** from the sweep/keyword layer.

It reaches the best recall achievable without an extra API call, but the complexity wasn't buying enough over the chosen resume sweep (which gets high recall from one cached call).

## Implementation plan

1. **`PermissionDenied` hook** → write a denial event file per denied tool call (record tool + input factually).
2. **Conditional keyword path** (`Stop` or `UserPromptSubmit`) → capture cue-bearing corrections.
3. **Once-per-session pass** — at `SessionEnd` or next `SessionStart`, a heuristic/local sweep over the transcript for the remainder.
4. **Dedup** — merge the three sources, collapsing overlaps (e.g. a denial caught by both the hook and the sweep).
5. Reuse the existing counter and `/togi:update-context-docs`.

## Risks & open questions

- **Maintenance surface** — three capture paths plus dedup.
- **Dedup correctness** — overlapping captures must merge cleanly.
- **Still a visible block** from the sweep/keyword layer.
- The non-model "sweep" layer has bounded recall vs a true model pass.
