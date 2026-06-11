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
- `--allowedTools` is a variadic flag: it consumes the next positional argument as a second tool name. A prompt passed as a positional after `--allowedTools` is silently swallowed, leaving `--resume` with no prompt, which falls into the "continue a deferred tool" code path and fails with "No deferred tool marker found". Deliver the prompt via stdin (`printf '%s' "$PROMPT" | claude …`) to avoid this.
- Prompt cache TTL is 5 minutes from last use (refreshed every turn — an hour-long active session sweeps warm; only idle-then-quit goes cold) and model-scoped (a Haiku sweep can never read an Opus/Fable cache).
- Blocking Stop-hook `reason` text is always user-visible.

## Sweep tool lockdown (verified 2026-06-11)

- Headless `claude -p` INHERITS permission allow rules from user/project/local settings: in a project whose settings allow `Bash(echo *)`, a plain `-p` session executed Bash without prompting. A prompt injection in swept session content could therefore run any pre-allowed command, unsupervised. The sweep needs zero tools, so all action-capable tools are denied.
- `--disallowedTools "Bash,Edit,Write,..."` (comma-separated, single arg) denies the listed tools even when settings allow rules match — deny overrides allow. It acts at the permission layer only, so the tool definitions in the API request are unchanged and the warm prompt cache is preserved.
- `--disallowedTools "*"` is a silent no-op: bare `*` matches no tool name (Bash still executed). Never use it.
- `--disallowedTools` is variadic like `--allowedTools` — same positional-prompt swallow hazard. Prompt stays on stdin; pass the deny list as one comma-separated argument.
- `--bare` is unsuitable: per CLI help it restricts auth to `ANTHROPIC_API_KEY`/`apiKeyHelper` (OAuth and keychain never read), which breaks subscription users; and settings files are not in its documented skip list, so it is not shown to bypass inherited allow rules anyway.
- `--tools ""` would remove tool definitions from the request — tool definitions are part of the cached prefix, so every sweep would run cold, breaking the cost model.
- Known gap: the deny list covers built-in tools only. MCP tools auto-allowed by project settings (e.g. `enableAllProjectMcpServers`) are not covered — a bare `mcp__*` deny pattern is unverified, and `--strict-mcp-config` would drop MCP tool definitions from the request (cold cache for MCP-using sessions). Revisit if a verified blanket deny becomes available.

Re-verify these when CLI behavior changes.

## Distribution pinning (2026-06-11)

- The plugin `source` in `.claude-plugin/marketplace.json` is pinned to a full commit `sha`: `{"source": "github", "repo": "gwenneg/togi", "sha": "83fd179..."}`. A relative `"./."` source tracks whatever ref the marketplace catalog was fetched at (effectively `main`); the explicit `github` + `sha` source decouples the plugin code users run from `main`, so WIP on `main` does not reach users. A `sha` is chosen over a `ref` tag because it is immutable — a tag can be force-moved, a commit hash cannot. The matching tag (`v0.4.6`) is kept as a human-readable marker only; the pin resolves the sha.
- Auto-update is removed everywhere (marketplace.json, the setup skill's `extraKnownMarketplaces` write, README). With auto-update off, third-party marketplaces update only when the user explicitly updates the plugin — the deliberate-release boundary on the consumer side.
- Residual risk: the pin lives on `main`, so an attacker who controls `main` can rewrite the sha. Pinning buys deliberate releases + verifiability (git content-addressing fixes the bytes once the sha is set), not protection against branch/account compromise — that needs account and branch hardening.
- Unverified here: that the installed CLI resolves a pinned `sha` plugin source as documented. This came from the plugin-marketplace docs, not a local test. Verify with `/plugin install` before depending on it, and record the result here.
