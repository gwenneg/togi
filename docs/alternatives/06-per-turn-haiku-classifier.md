# 6. Per-turn Haiku classifier in a Stop hook

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** A `Stop` hook calls a cheap model (Haiku) at every turn end to classify whether the turn contained friction — semantic detection, no keyword blind spot, no UI noise.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| High | Invisible, +latency every turn end | Medium | Yes, per turn | Medium |

## What it is

Where the keyword approaches ([3](03-conditional-stop-hook.md), [4](04-userpromptsubmit-injection.md)) miss cue-less corrections, this judges each turn semantically. At every turn end the `Stop` hook sends the latest turn to a small, cheap model with a classification prompt; a positive verdict writes a friction event. No blocking, no visible prompt.

## Why it wasn't chosen

- **Adds latency to every turn end** and **N API calls per session** (one per turn), where the chosen sweep makes one call per session.
- **Breaks the privacy claim N times instead of once** — each turn's content is shipped to a classifier call, rather than a single resume of the user's own session.

It buys semantic recall without UI noise, but the per-turn cost and the repeated out-of-session calls are worse on both axes than one cached, full-session sweep.

## Implementation plan

1. **Register a `Stop` hook**; read the last turn from the tail of the transcript.
2. **Call `claude -p`** (Haiku, or a small model) with a classify prompt → structured verdict (`is_friction`, `type`, `body`).
3. **On positive** → write a friction event file.
4. **Detach the call** (background, fire-and-forget) so it doesn't add latency to the user's turn end; protect it from `HUP` like the current sweep does.
5. Reuse the existing counter and `/togi:update-context-docs`.

## Risks & open questions

- **Cost and latency scale with turn count** — a chatty session means many calls.
- **Privacy** — each turn is sent to a separate model call.
- **Detached-call reliability** — N fragile background processes per session instead of one.
- Classifier precision on single turns (no full-session context) may be lower than a retrospective sweep.
