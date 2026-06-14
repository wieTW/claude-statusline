# claude-statusline

A single-line [Claude Code](https://claude.ai/code) statusline. Claude Code invokes
`statusline-command.sh` with a status JSON on **stdin**; the script prints **one
colored line** on stdout.

## Install

It is not auto-installed — point the `statusLine.command` setting (in `~/.claude/settings.json`)
at the script's absolute path:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/will/Downloads/macOS/claude-statusline/statusline-command.sh"
  }
}
```

## The line

Two halves, right-aligned to the terminal edge with a `│` junction that appears only when
they nearly touch:

- **left** — path · model · effort · thinking · context bar · rate-limit countdowns ·
  last-message time as `HH:MM (Δ)`, where Δ is colored as a prompt-cache-freshness signal
- **right** — git · worktree · session name

When space runs out it degrades gracefully (drop the junction → truncate the session name →
drop the right half), so the line never overflows the terminal width.

## Develop

```bash
# Full check (the verify.json gate — all must exit 0)
bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh   # syntax
shellcheck -x statusline-command.sh                                               # lint
bash tests/run-tests.sh                                                           # suite → "ALL CHECKS PASSED"

# Render one frame by hand (fastest dev loop); COLUMNS drives the right-align width
printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"used_percentage":6.2}}' "$PWD" \
  | COLUMNS=140 bash statusline-command.sh
```

See [`CLAUDE.md`](CLAUDE.md) for the architecture, the concurrency model, and the hard
rules (target bash 3.2, never `set -e`, input sanitization, etc.).
