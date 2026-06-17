# 7. SessionEnd → headless sweep over the transcript (fresh context)

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** At `SessionEnd`, run a headless `claude -p` that reads the *serialized transcript* as fresh input and extracts friction — same high recall and invisibility as the chosen sweep, but without resuming the session.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| High | Invisible | Medium (full re-read, no cache) | Yes, per session | Medium |

## What it is

A `SessionEnd` hook spawns a one-shot headless model call. Instead of `--resume --fork-session` (which replays the live session at warm-cache prices), it feeds the transcript content as a plain prompt and asks the model to find friction events. Detached and invisible, like the chosen approach.

## Why it wasn't chosen

- **Pays full input price** — a fresh context re-reads the entire transcript with no cache reuse, ~10× the cost of the warm-cache resume.
- **Reads a serialized transcript instead of inhabiting the conversation** — a less faithful view than resuming the actual session state.

It is **strictly dominated by the chosen resume sweep** once `--fork-session` was verified to carry full context at ~0.1× input price. Worth revisiting only if session resume/fork is unavailable (e.g. a port to a tool without it).

## Implementation plan

1. **Register a `SessionEnd` hook**; read `transcript_path`.
2. **Build the prompt** — serialize the transcript (or a trimmed form) and append the friction-extraction instruction.
3. **Run `claude -p`** detached (nohup + disown, `HUP` trap), parse the output into friction event files.
4. **Apply the same guards** as the current sweep: opt-in gate, recursion guard, skip non-final end reasons, validate the session id.
5. Reuse the existing counter and `/togi:update-context-docs`.

## Risks & open questions

- **Cost** — full input price every session; large sessions get expensive.
- **Fidelity** — a serialized transcript may lose nuance the live session held.
- **Detached-process fragility** — same as the chosen sweep.
- Primarily a **fallback for environments lacking session resume/fork**.
