# 9. SessionEnd → resume-and-fork headless sweep

> **togi's original implementation** (through v0.1.x), replaced by in-session inline capture. See the [alternatives comparison](../internals.md#2-friction-capture-alternatives-considered) for how it stacks up. This file preserves the significant design; the exact code lives in git history (`scripts/session-end.sh`, removed in the inline-capture pivot).

**One-liner:** When an opted-in session ends, a detached `SessionEnd` hook forks a headless `claude -p --resume <id> --fork-session` that re-lives the just-ended session, extracts friction events, and writes them to the friction store — invisibly, once per session.

| Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|
| High | Invisible | ~$0.05–0.20 (warm cache) | Yes, per session | Medium |

## What it was

A `SessionEnd` hook (`scripts/session-end.sh`) that, after a session terminated, spawned a **detached** headless Claude process to sweep that session for friction. It resumed the real session by id and **forked** it (`--fork-session`) so the analysis ran with the full original context but left the user's transcript byte-identical. The sweep returned a JSON array of friction events, which the hook validated and wrote as one JSON file per sweep under `.togi/friction/pending/`.

This was the chosen approach for most of togi's life because it delivered **full-session hindsight** (the model that lived the session judging it in retrospect) at the **cheapest** price among high-recall options — the warm prompt cache replays the session at ~0.1× input price — with **zero in-session noise**.

## Why it was replaced

The inline-capture pivot superseded it for reasons that accumulated:

- **Native auto memory** (Claude Code v2.1.59+, default-on) now captures durable facts from corrections for free, making a separate generic sweep largely redundant.
- **The sweep is the expensive, fragile half**: one billed API call per session, warm-cache economics to defend, a detached process that can be lost to crash/SIGKILL, and a consent + cost-disclosure gate.
- **Portability**: a port to OpenCode can't reuse it cleanly — OpenCode bills Anthropic by API key only (subscription/Agent-SDK-credit billing is prohibited there), so the sweep's cost model doesn't survive the move.

Inline capture trades the sweep's measurable, retrospective recall for ~zero cost and far less machinery (accepted; the sweep is preserved here as a revivable option).

## Significant design details (for revival)

- **Resume + fork is mandatory.** `--resume <id>` without `--fork-session` *mutates* the user's session (transcript grows, same id reused). Fork copies history into a new id, leaving the original untouched — verified empirically.
- **All tools denied.** The sweep ran with `--disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Read,Glob,Grep"`. Headless `-p` inherits the project's allow rules, so injected session content could otherwise run a pre-approved command; deny-all is the core injection defense. Prompt passed via **stdin** (the variadic `--disallowedTools` would swallow a positional prompt).
- **Warm/cold cache detection.** If the last transcript turn was older than **290 s** (just under the 5-minute cache TTL), the sweep ran **cold** and fell back to **Haiku** (`--model haiku`) — cold-Haiku costs ~⅕ of cold-Opus. Otherwise it resumed warm on the session's own model at ~0.1× input.
- **Telemetry.** `--output-format json` wrapped the result in an envelope carrying `total_cost_usd` and cache token usage (client-side only, so the warm cache was unaffected). The measured cost was stamped into the friction file as `sweep_cost_usd`.
- **Guards.** Opt-in gate (`TOGI_ENABLED=1`); recursion guard (`TOGI_HEADLESS=1` — the sweep's own session-end would otherwise chain infinitely); skip non-final end reasons (`resume`, `bypass_permissions_disabled` — sweeping them double-bills); session-id validation (interpolated into `--resume` and the filename).
- **Detachment.** The sweep ran in a subshell backgrounded with stdio fully redirected **and** `disown`ed (both load-bearing, else session exit blocks on it), with a `trap '' HUP` so a terminal-close didn't kill the post-`claude` file write.
- **Store.** One JSON file per sweep: an optional `sweep_cost_usd` header plus an `events` array, each event carrying `type`/`body`/`captured_by`/`date` (+ optional `misleading_doc`), schema-gated before writing.

## Cost model (as it was)

**~$0.05–0.20 per session**, billed at standard API rates, drawn from the separate monthly Agent SDK credit. Warm-cache reads at ~0.1× base input were the reason it was cheap; a 150K-token Opus session ≈ $0.08 warm. Cold sessions fell back to Haiku to cap the no-cache case.

## Risks & open questions (why not the default anymore)

- **Per-session billing** and the consent/disclosure surface it requires.
- **Detached-process fragility** — crashed/SIGKILLed sessions aren't swept.
- **Not portable** to tools without session resume/fork or with subscription-billing restrictions.
- Redundant with native auto memory for the durable-facts slice.
