# 3. Conditional Stop hook (keyword grep on transcript)

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** A `Stop` hook greps the just-finished turn for correction cues, and only acts (block or inject) when a cue matches — turning the always-on wall of approach [2](02-unconditional-blocking-stop-hook.md) into an occasional, targeted prompt.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| Medium, keyword-blind | Occasional visible block | Low | No | Medium |

## What it is

The `Stop` hook reads the session transcript, extracts the latest user turn, and matches it against a list of correction/clarification cue patterns ("no,", "actually", "that's wrong", "don't", file reverts, …). Only on a match does it surface a capture instruction. Most turns pass silently.

## Why it wasn't chosen

- **Keyword filters have a systematic blind spot**: corrections that don't use correction words are invisible — forever. The misses are not random noise; an entire phrasing style stays uncaught.

It trades the every-turn cost/noise of approach 2 for a fixed, structural recall gap.

## Implementation plan

1. **Register a `Stop` hook**; read `transcript_path` from the payload.
2. **Extract the last user turn** — read from the tail of the JSONL, do not slurp the whole file (keep the hook fast so it shows no spinner).
3. **Match cue patterns** — a maintained list of correction markers; optionally also detect file reverts (the user re-editing a file the agent just edited).
4. **On match** — inject a capture instruction via `additionalContext` (silent) or block with a `reason` (visible) to record the friction.
5. **On no match** — exit 0 silently.
6. Reuse the existing counter and `/togi:update-context-docs`.

## Risks & open questions

- **Recall gap** — cue-less corrections are never caught; this is intrinsic.
- **Cue-list maintenance** — phrasing drift requires updates.
- **Per-turn transcript parse** — must stay fast (tail-read) to avoid a visible spinner.
- A blocking variant still shows a `reason` on matched turns.
