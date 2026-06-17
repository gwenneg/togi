# 8. SessionEnd digest → sweep at next SessionStart

> Considered for togi's friction capture, not chosen. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up against the others. This file explains the approach and sketches how to build it if revisited.

**One-liner:** `SessionEnd` writes a lightweight digest of the session (no API call); the next `SessionStart` runs the friction sweep over that digest — preserving "no out-of-session API calls."

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| Medium-high | Work at top of next session | Low | No | Medium |

## What it is

Capture is split across two session boundaries. At `SessionEnd`, a hook records a digest (a queued pointer to the transcript, or a trimmed summary) — cheap, no model call. At the next `SessionStart`, before the user begins, a hook runs the sweep over the queued digest and writes friction events. The key property: **no model call ever runs outside an interactive session**, which sidesteps the consent/billing surface of out-of-session calls.

## Why it wasn't chosen

It is the only high-recall option that preserves "no out-of-session API calls," and it is **kept as the documented fallback** if the consent change for the chosen sweep proves unpopular. Its costs:

- **Latency at the top of the next session** — the user waits while the previous session is swept.
- **Sweeps a digest rather than the live context** — lower fidelity than resuming the actual session.
- **Never runs if there is no next session** — the last session before a long gap is dropped.

## Implementation plan

1. **`SessionEnd` hook** — enqueue a digest entry (transcript path + metadata, or a trimmed summary) into a pending-sweep queue under `.togi/`.
2. **`SessionStart` hook** — check the queue; for each pending entry, run the sweep (in-session via a skill, or headless) over the digest, write friction event files, and clear the entry.
3. **Bound the work** — cap how many queued sessions are swept per start to keep startup latency acceptable.
4. Reuse the existing counter and `/togi:update-context-docs`.

## Risks & open questions

- **Top-of-next-session latency** — the user feels the cost of the previous session.
- **Digest fidelity** — a summary loses detail a live resume keeps.
- **Orphaned final sessions** — no next session means no sweep; consider a periodic flush.
- **Queue management** — growth, ordering, and clearing under concurrent sessions.
