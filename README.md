# claude-statusline

A single-line status bar for [Claude Code](https://claude.ai/code) that keeps the things you
actually glance at — where you are, how much context is left, and whether you're about to hit a
rate limit — on one tidy, colored line. Pure bash, no build step, no dependencies to speak of.

```
claude-statusline │ Opus 4.8 │ ██████░░░░ 42% │ 128k │ 2H10m 37% │ 5D6H 72% │ 1H15m (7m)          main* +68/-14
└─ project ────────┴─ model ──┴─ context ─────┴ tokens ┴─ 5h quota ┴ 7d quota ┴─ session (Δ) ──┘   └─ git ──┘
```

The left half tracks your session and resources; the right half (git, worktree, session name) is
pinned to the terminal's right edge. When the window gets narrow, the line shrinks and drops the
least-important pieces instead of wrapping — so it always stays one line.

## What it shows

| Segment | What it tells you |
|---------|-------------------|
| **Path** | The project and sub-path you're working in |
| **Model** | The active model, e.g. `Opus 4.8` |
| **Effort / thinking** | Reasoning effort level; a red `no-think` only shows up as a warning when thinking is *off* |
| **Context** `██████ 42%` | How full the context window is before auto-compact. Turns red near the limit, and a `⚑` marks the 200k token cost/cache cliff |
| **Tokens** `128k` | Cumulative input+output tokens this session; a `⊂` figure is added for subagent usage |
| **5h quota** `2H10m 37%` | Time until your 5-hour rate limit resets, and the % you have left. A `↘` alarm appears when you're on track to run dry *before* the reset |
| **7d quota** `5D6H 72%` | The same, for the weekly limit |
| **Session** `1H15m (7m)` | How long this session has run, and how long since your last prompt. The `(Δ)` turns yellow→red as your prompt cache likely goes cold (5 min / 1 h) |
| **Git** `main* +68/-14` | Branch, an `*` if there are uncommitted changes, and the diffstat |
| **Worktree / name** | The git worktree and session name, when set |

Colors follow a **only-shout-when-it-matters** rule: quotas fade green→yellow→red as they
deplete, the context meter stays calm until you're actually close to the limit, and the warning
markers (`⚑`, `↘`, `no-think`) appear only when the condition is real.

## Install

```bash
git clone https://github.com/wieTW/claude-statusline.git
cd claude-statusline
./install.sh
```

`install.sh` wires the statusline into `~/.claude/settings.json` for you. It **merges** into your
existing settings (permissions, hooks, model, everything else is left alone), **backs the file up**
first, and is safe to run again any time. Then **restart your Claude Code session**.

```bash
./install.sh 30                 # refresh every 30s instead of the default 60
REFRESH_INTERVAL=0 ./install.sh # don't set a refresh timer (update only on activity)
```

### Keeping it live while idle

By default the installer adds `"refreshInterval": 60`, which re-renders the line every 60 seconds
even when you're not typing. Without it, Claude Code only redraws the statusline on activity — so
the clocks freeze and the cache-freshness color stops updating the moment you step away. 60s fits
this line (everything is minute-grained) and is safe; going below ~15s can disable the rate-limit
burn alarm, so ~30s is the lowest you'd want without other changes.

Prefer to wire it up by hand? Add this to `~/.claude/settings.json` (use the script's absolute
path):

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
- **`jq`** — required (parses the status JSON Claude Code sends). macOS: `brew install jq`
- **`git`, `perl`, `stty`** — optional; each degrades gracefully if missing (no git segment,
  a pure-bash text-truncation fallback, a simpler layout, respectively)
- Built for **macOS** (uses BSD `stat`/`date` flags) and runs on the system bash 3.2 — no upgrade needed

## Configure

The line looks good out of the box. To tweak it, edit the settings at the top of
`statusline-command.sh`:

| Setting | Default | What it does |
|---------|---------|--------------|
| `STYLE` | `tokyo-night-claude` | Color theme: `claude`, `tokyo-night`, `tokyo-night-claude`, `catppuccin`, or `rose-pine` |
| `CTX_BAR` | `true` | Show context as a gradient bar; `false` for plain `ctx:42%` text |
| `NORM_THINKING` | `true` | Assume thinking is normally on, and warn only when it's off |
| `RIGHT_ALIGN` | `true` | Pin the git/session half to the right edge |
| `RL_SYNC` | `true` | Share the true rate-limit % across your open sessions (a stale session otherwise shows a frozen number) |
| `BURN_SENS` | `balanced` | How eager the `↘` burn alarm is: `conservative`, `balanced`, or `sensitive` |
| `LASTMSG_WARN` / `LASTMSG_STALE` | `300` / `3600` | Seconds of idle before the `(Δ)` turns yellow / red |

## Contributing

Handy for development:

```bash
# Render one frame by hand — the fastest way to see a change (COLUMNS sets the width)
printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"used_percentage":42}}' "$PWD" \
  | COLUMNS=140 bash statusline-command.sh

# Full check before committing
bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh   # syntax
shellcheck -x statusline-command.sh                                               # lint
bash tests/run-tests.sh                                                           # tests → "ALL CHECKS PASSED"
```

Architecture, the concurrency model, and the hard rules (targets bash 3.2, never `set -e`, input
sanitization) live in [`CLAUDE.md`](CLAUDE.md).
