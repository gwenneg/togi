# 10. Directive delivery via a CLAUDE.md-family import

> A **delivery-channel** decision (not a capture mechanism like 1–9): how the inline-capture directive reaches the model. Considered and briefly implemented, then rejected in favor of **`SessionStart`-hook injection**. See [§1](../internals.md#1-architecture--lifecycle) for the chosen delivery.

**One-liner:** Deliver the capture directive by `@`-importing a committed `.togi/togi-friction.md` from a CLAUDE.md-family file — committed `./CLAUDE.md`, personal `./CLAUDE.local.md`, or user `~/.claude/CLAUDE.md` — with `/togi:enable` adding the import and `/togi:disable` removing it.

## What it was

The directive is a file; a CLAUDE.md-family file imports it. togi's first cut of the inline-capture pivot used this: a committed, inert `.togi/togi-friction.md`, activated per developer by an import line that `/togi:enable` added to `CLAUDE.local.md` (repo scope) or `~/.claude/CLAUDE.md` (all-repos scope).

The three possible import locations:

| Location | Committed? | Scope | Fatal flaw |
|---|---|---|---|
| `./CLAUDE.md` | yes | repo, **everyone** | activates capture for devs who never installed or consented to togi |
| `./CLAUDE.local.md` | no | repo, you | per-worktree; gate is the import's presence, not `TOGI_ENABLED` |
| `~/.claude/CLAUDE.md` | no | all repos, you | captures in repos that never adopted togi (blast radius) |

## Why it was rejected

The decisive problem: **the gate cannot live in the prompt.** The directive is plain context — the model cannot read `TOGI_ENABLED` (custom env vars are not surfaced into context, and CLAUDE.md is not a templating engine, so there is no `{env:…}` conditional). So an import can only be gated by its **presence**, which is a *different axis* from the hooks' `TOGI_ENABLED` gate. The two drift: the directive can be active while the hooks are off, or vice versa.

That drift is worst for the **committed `./CLAUDE.md`** variant: the import is identical for everyone with the repo, so the directive activates for teammates who never installed the plugin or opted in. Their model writes friction notes with no hooks, no reminder, and no consent. (`.gitignore` keeps those notes out of git, so it is not a leak — but it is capture without opt-in, which togi is architected to avoid.)

The **personal** variants (`CLAUDE.local.md`, `~/.claude/CLAUDE.md`) restore per-developer control but bring their own costs — per-worktree fragility for the former, capture in unrelated repos for the latter — and still gate on import-presence rather than on `TOGI_ENABLED` itself.

Two more reasons hook delivery wins:

- **Compaction control.** A static import survives `/compact` only for root `CLAUDE.md` (re-read from disk — unverified for `@`-imported files) and gives no control over reinjecting the *full* directive. Hook delivery lets the `Stop` hook reinject the full directive when it detects the post-compaction context-size drop. (`PostCompact` cannot inject context — verified — so the `Stop`-detected drop is the only reinjection path either way.)
- **One gate, in the right place.** A shell hook reads `TOGI_ENABLED` natively, so the directive exists *exactly* when capture is enabled. Non-togi devs run no hook → no directive → no capture, with **zero committed footprint** and no reliance on the model honoring a "don't capture" instruction.

## Implementation plan (to revive)

1. Commit an inert `.togi/togi-friction.md` (the directive).
2. `/togi:enable`: append `@.togi/togi-friction.md` to `CLAUDE.local.md` (repo) or copy the directive to `~/.togi/` and append `@~/.togi/togi-friction.md` to `~/.claude/CLAUDE.md` (all); also gitignore `CLAUDE.local.md`.
3. `/togi:disable`: remove the import line.

This is exactly what togi implemented in the inline-capture pivot's first cut (see git history).

## Risks & open questions

- **Gate drift** — import-presence vs `TOGI_ENABLED` are independent and can disagree.
- **Committed variant captures without consent** for non-togi teammates.
- **Personal variants** are per-worktree (`CLAUDE.local.md`) or capture in non-adopted repos (`~/.claude/CLAUDE.md`).
- **No control over compaction reinjection** of the full directive.
