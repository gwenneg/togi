# Togi design — friction capture approach

## Friction capture — alternatives considered

The core problem: detect friction events (corrections, clarifications, mistakes, tool denials) reliably, without taxing the session, at acceptable cost, with an honest privacy story. Each approach trades these off differently.

| # | Approach | Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|---|---|
| 1 | CLAUDE.md import, per-message instructions *(v0.2)* | Low, unmeasurable | Invisible, but per-message attention tax | ~free | No | Minimal |
| 2 | Unconditional blocking Stop hook *(v0.3)* | Medium | **Prompt wall every turn** | ~$1+ (extra inference/turn) | No | Low |
| 3 | Conditional Stop hook (keyword grep on transcript) | Medium, keyword-blind | Occasional visible block | Low | No | Medium |
| 4 | `UserPromptSubmit` silent `additionalContext` | Low (advisory only) | Invisible | ~free | No | Low |
| 5 | Layered: hook-parsed denials + keyword fast path + once-per-session sweep | High | One visible block/session | Low | No | High |
| 6 | Per-turn Haiku classifier in Stop hook | High | Invisible, +latency every turn end | Medium | Yes, per turn | Medium |
| 7 | SessionEnd → headless `claude -p` over transcript (fresh context) | High | Invisible | Medium (full re-read, no cache) | Yes, per session | Medium |
| 8 | SessionEnd digest → sweep at next SessionStart | Medium-high | Work at top of next session | Low | No | Medium |
| 9 | **SessionEnd → `claude -p --resume --fork-session` sweep** *(v0.4, chosen)* | **High** | **Invisible** | **~$0.05–0.20 (warm cache)** | Yes, per session | Medium |

## Why each was rejected

**1. CLAUDE.md import** — detection rests on the model voluntarily interrupting its own task per message; standing instructions habituate, recall is unknown and unmeasurable, and capture interrupts the response to the very correction that triggered it. Its virtues (zero cost, zero API calls, dead simple) are why it shipped first.

**2. Unconditional Stop hook** — fixed the attention problem (just-in-time enforcement) but a blocking Stop hook's `reason` is user-visible by design: a 22-line prompt rendered every turn. Also the most expensive option — one extra inference per turn plus the reason accumulating in context.

**3. Conditional Stop hook** — keyword filters have a systematic blind spot: corrections that don't use correction words. Bounded misses, but a whole phrasing style stays invisible forever.

**4. UserPromptSubmit injection** — silent, but advisory-only at the moment of least hindsight; effectively approach 1 with better recency.

**5. Layered design** — best recall without API calls, but three mechanisms to maintain, and still one visible block per session. The complexity wasn't buying enough over 9.

**6. Per-turn Haiku classifier** — semantic recall with no UI noise, but adds latency to every turn end and N API calls per session; breaks the privacy claim N times instead of once.

**7. Fresh-context transcript analysis** — works, but pays full input price (no cache reuse) and reads a serialized transcript instead of inhabiting the conversation; strictly dominated by 9 once `--fork-session` was verified.

**8. Deferred sweep at next SessionStart** — the only high-recall option preserving "no out-of-session API calls"; kept as the documented fallback if the consent change proves unpopular. Costs: latency at the top of the next session, sweeps a digest rather than the live context, never runs if no next session.

**9. Resume sweep (chosen)** — full-session hindsight from the model that lived the session (verified: fork carries complete context, original transcript untouched), zero session noise, and the cheapest of the high-recall options because the warm prompt cache replays the session at ~0.1× input price. Trades away: one API call per session (consent + cost disclosure required), no sweep on crashed sessions, detached-process fragility.

## Key empirical facts (verified 2026-06-10)

- `claude -p --resume <id> --fork-session` carries full session context, returns a new session id, and leaves the original transcript byte-identical. Without `--fork-session`, the resume mutates the user's session (transcript grew 10 → 19 lines and reused the same session id). Fork is mandatory.
- SessionEnd fires for headless `-p` sessions too (`reason: "other"`) — the sweep child triggers the hook itself, so the recursion guard is load-bearing, not defensive.
- Env vars set on the spawned child (`TOGI_SWEEP=1`) are visible to the child's hooks (verified in both SessionStart and SessionEnd of the child).
- `nohup env … claude -p … &` detaches cleanly; the hook returns immediately.
- Prompt cache TTL is 5 minutes from last use (refreshed every turn — an hour-long active session sweeps warm; only idle-then-quit goes cold) and model-scoped (a Haiku sweep can never read an Opus/Fable cache).
- Blocking Stop-hook `reason` text is always user-visible.

Re-verify these when CLI behavior changes.
