# 1. CLAUDE.md import — per-message friction instructions

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** A standing instruction, loaded via `CLAUDE.md` (or an `@import`), tells the working model to detect friction and write the event itself, in-session, as it happens — no hook, no extra process.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| Low, unmeasurable | Invisible, but per-message attention tax | ~free | No | Minimal |

## What it is

A markdown directive describing the friction types (correction, clarification, denial) and instructing Claude, whenever one occurs during normal work, to append a friction-event file to togi's store. Detection and capture both happen inside the working session, by the working model, with no separate sweep or classifier. This is the version togi shipped first.

## Why it wasn't chosen

- **Detection rests on the model voluntarily interrupting its own task** every message — a secondary concern competing with the actual work for attention.
- **Standing instructions habituate**: as the session grows and the directive is buried near the top of context, adherence decays.
- **Recall is unknown and unmeasurable** — there's no way to know what it missed.
- **Capture interrupts the response** to the very correction that triggered it.

Its virtues — zero cost, zero API calls, dead simple — are why it shipped first.

## Implementation plan

1. **Author the directive** — a short markdown file naming the four friction types and instructing the model to write one event file per friction to `.togi/friction/pending/` (one short file, named by a root-cause slug, so the model needs no session id or clock).
2. **Deliver it** — `@import` the directive into `CLAUDE.md` (committed, team-wide) or into a per-developer `CLAUDE.local.md` (gitignored) for opt-in consistency.
3. **Reuse the existing pipeline** — the `SessionStart` counter (count files in `pending/`) fires the threshold reminder; `/togi:update-context-docs` processes them. No `SessionEnd`, no sweep.
4. **Gate opt-in** — presence of the per-developer import (and/or `TOGI_ENABLED`) controls activation.
5. **Optionally** make the writes promptless with a `permissions.allow Write(.togi/friction/**)` rule (works because `.togi/` is not a protected path).

## Risks & open questions

- **Compliance is not guaranteed** — `CLAUDE.md` is "context, not enforced."
- **Habituation** within a long session lowers recall over time.
- **Unmeasurable recall** — you cannot audit what was missed.
- Each capture is a **visible `Write` tool call** in the session.
