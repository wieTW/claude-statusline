# claude-statusline

A one-line statusline for [Claude Code](https://claude.ai/code) that does the math *before*
things go wrong — it warns you before your rate limit hits, not after.

**macOS · stock bash 3.2 · `jq` is the only dependency · ~26 ms a frame**

![A healthy session: project path, model, context bar, token count, both rate-limit countdowns, compute time, and git — one colored line](assets/hero.svg)

Everything follows one display rule: **only shout when it matters**. A healthy session stays
calm and dim; the warning glyphs (`↘`, `⚑`, `no-think`) and red colors appear only when the
condition is real. So when the line does shout, believe it:

![A bad day: red context meter past the ⚑ 200k cliff, thinking off, a ↘23m burn alarm on the 5h quota, and a red idle delta](assets/alerts.svg)

Reading that frame: a red `93%⚑` means the context window is genuinely near its limit *and*
past the 200k cost/cache cliff; `no-think` means extended thinking is off; `↘23m` means at
your current pace the 5h quota runs dry 23 minutes from now — before it resets; and a red
`(1H15m)` means your prompt cache is long gone.

## The three problems it was built to fix

**1. "The rate limit always blindsides me."**
The line samples your real 5-hour-quota usage over time, extrapolates the slope, and shows
**`↘23m`** — the time until you run dry — *only* when the projection says you'll exhaust the
quota **before** it resets. Flat or falling usage shows nothing; there is no alarm to cry
wolf. Yellow above 30 minutes of runway, red at or below; a `BURN_SENS` knob picks how eager
it is.

**2. "My other session lies about quota."**
Claude Code freezes each session's rate-limit numbers at the moment the session starts, so a
long-lived terminal shows a stale used% forever. This statusline shares a small cache across
all your open sessions, with the **newest session as the authority** — every terminal shows
the true current percentage, not its own frozen snapshot.

**3. "Did my prompt cache go cold?"**
The **`(3m)`** delta is the time since your last prompt, colored to track Anthropic's two
real prompt-cache TTLs: **dim** = cache warm, **yellow** past ~5 minutes = the default cache
has gone idle-cold, **red** past ~1 hour = even the extended cache is gone and your next
prompt pays a full cache re-write.

## It never wraps

![The same status at five shrinking terminal widths — segments shrink, then drop, always one line](assets/degrade.svg)

When the window narrows, segments shrink and then drop in a fixed 14-step order — shrink
before drop, least important first. The path and context % survive down to a 2-column
terminal.

## The quieter fixes

- **A token count you can trust** — `128k ⊂23k` is cumulative input+output for the session
  (subagents after the `⊂`). Cache tokens are **excluded**, so the number is stable across
  prompt-cache churn — a work meter, not a spend meter. Transcript rows are deduped by
  message id (naive JSONL summing over-counts ~10x), and the heavy re-sum runs detached in
  the background so rendering never waits on it.
- **A context meter that knows your budget** — red at 80% on 200k-class models but **92% on
  1M-context models**, so a half-empty 1M window is never falsely flagged. The `⚑` cliff
  marker is driven by Claude Code's own `exceeds_200k` flag, independent of the color.
- **Compute time, not wall-clock** — `45m25s` is the time Claude *actually spent producing
  responses* (idle and local tool runs excluded), falling back to session wall-clock, then to
  a plain clock on older Claude Code builds.
- **It won't lag your terminal** — every slow lookup (jq, git ×3, theme, terminal width) runs
  concurrently, so a frame costs ~26 ms.

## What's on the line

| Segment | Example | What it tells you |
|---------|---------|-------------------|
| **Path** | `claude-statusline` | The project and sub-path you're working in |
| **Model** | `Opus 4.8` | The active model; a 1M-context variant compacts to `Opus 4.8(1M)` |
| **Effort / thinking** | `no-think` | Appears only when abnormal: the effort level when set, a red `no-think` when extended thinking is off |
| **Context** | `██████░░ 42%` | Window fill before auto-compact; `⚑` = past the 200k cost/cache cliff |
| **Tokens** | `128k ⊂23k` | Session input+output, subagents after the `⊂`; cache tokens excluded |
| **5h quota** | `2H10m 37%` | Resets in 2h10m, 37% left; `↘23m` appears only when you're projected to run dry before the reset |
| **7d quota** | `5D6H 72%` | The same, for the weekly limit |
| **Time** | `45m25s (3m)` | Claude's actual compute time; `(3m)` = time since your last prompt, colored by cache freshness |
| **Git** | `main* +68/-14` | Branch, `*` if dirty, and the diffstat — pinned to the right edge |
| **Worktree / name** | `auth-refactor` | The git worktree and session name, when set |

## Install

macOS + `jq` is all you need (`brew install jq` — the installer checks for it):

```bash
git clone https://github.com/wieTW/claude-statusline.git
cd claude-statusline
./install.sh
```

`install.sh` **merges** into your existing `~/.claude/settings.json` (permissions, hooks,
model — everything else is left alone), **backs the file up** first, and is idempotent — safe
to re-run any time. Then **restart your Claude Code session** (or run `/statusline`).

```bash
./install.sh 30                 # refresh every 30s instead of the default 60
REFRESH_INTERVAL=0 ./install.sh # no refresh timer (update only on activity)
```

Two things to know on first run: the very first frame can look sparse — the token count is
summed in the background and appears from the next render on — and the quota trend needs a
few renders before the burn alarm has a slope to project. Neither is a broken install.

### Keeping it live while idle

The installer sets `"refreshInterval": 60`, which re-renders the line every 60 seconds even
when you're not typing. Without it, Claude Code only redraws on activity — the countdowns
freeze and the cache-freshness color stops updating the moment you step away. The burn alarm
also samples your quota usage once per render and needs samples spread over minutes to
measure a slope, so ~30s is the lowest interval you'd want; below ~15s the sampling series
degrades and the alarm can go quiet.

Prefer to wire it up by hand? Add this to `~/.claude/settings.json` (use the script's
absolute path — note this path skips the installer's jq check):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/claude-statusline/statusline-command.sh",
    "refreshInterval": 60
  }
}
```

## Requirements

- **Claude Code** — this is a statusline for it
- **`jq`** — the one hard dependency (parses the status JSON Claude Code sends)
- Optional, each degrades gracefully if missing: **`git`** (no git segment), **`perl`**
  (pure-bash wide-char truncation fallback), **`stty`** (simpler non-right-aligned layout)
- **macOS as shipped** — uses BSD `stat`/`date` flags and runs on the stock system
  **bash 3.2**: no bash upgrade, no build step

## Configure

Five themes, picked with `STYLE` at the top of `statusline-command.sh`:

![The five themes — claude, tokyo-night, tokyo-night-claude, catppuccin, rose-pine — rendering the same frame](assets/themes.svg)

| Setting | Default | What it does |
|---------|---------|-------------|
| `STYLE` | `tokyo-night-claude` | `claude` / `tokyo-night` / `tokyo-night-claude` / `catppuccin` / `rose-pine` |
| `CTX_BAR` | `true` | Gradient context bar; `false` for plain `ctx:42%` text |
| `NORM_THINKING` | `true` | Thinking is the norm — warn (red `no-think`) only when it's off |
| `RIGHT_ALIGN` | `true` | Pin the git/session half to the terminal's right edge |
| `RL_SYNC` | `true` | Cross-session rate-limit sync (see problem #2); off = each session keeps its frozen startup snapshot |
| `BURN_SENS` | `balanced` | Burn-alarm eagerness: `conservative` / `balanced` / `sensitive` |
| `LASTMSG_WARN` / `LASTMSG_STALE` | `300` / `3600` | Idle seconds before the `(Δ)` turns yellow / red — matched to Anthropic's 5-minute and 1-hour cache TTLs |

## Contributing

Every screenshot above is real output — `bash assets/generate.sh` re-renders them through the
actual script, so if they look wrong, something *is* wrong.

```bash
# Render one frame by hand — the fastest dev loop (COLUMNS sets the width)
printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"used_percentage":42}}' "$PWD" \
  | COLUMNS=140 bash statusline-command.sh

# Full check before committing
bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh   # syntax
shellcheck -x statusline-command.sh                                               # lint
bash tests/run-tests.sh                                                           # suite → "ALL CHECKS PASSED"
```

Architecture, the concurrency model, and the hard rules (bash 3.2 only, never `set -e`,
input sanitization) live in [`CLAUDE.md`](CLAUDE.md).
