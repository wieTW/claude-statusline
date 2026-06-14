# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-line Claude Code statusline. Claude Code invokes `statusline-command.sh`,
piping a status JSON on **stdin**; the script prints **one colored line** on stdout.
It is wired up by pointing the `statusLine.command` setting at `statusline-command.sh`
(it is not auto-installed by this repo's `setup.sh`). Reference guide:
`github.com/Raymondhou0917/claude-code-resources` starter-kit `06-statusline.md`.

The line has two halves: a **left** part (path · model · effort · thinking · ctx bar ·
rate-limit countdowns · last-message time) and a **right** part (git · worktree ·
session name), right-aligned to the terminal edge with a `│` junction that appears only
when the two halves nearly touch.

## Commands

```bash
# Full check (this is the verify.json gate — all three must exit 0)
bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh   # syntax
shellcheck -x statusline-command.sh                                               # lint (follows the . sources)
bash tests/run-tests.sh                                                           # suite → prints "ALL CHECKS PASSED"

# Render one frame by hand (the fastest dev loop) — COLUMNS drives the right-align width
printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"used_percentage":6.2}}' "$PWD" \
  | COLUMNS=140 bash statusline-command.sh
```

`tests/run-tests.sh` is one monolithic suite — each check prints a labeled line (`A`,
`A2`, `B`…`S`); a failure prints `★ FAIL` and the script exits 1. There is **no
per-test flag**; to isolate a case, read its labeled output or temporarily edit the
script. The harness is self-locating (`SL=$(cd "$(dirname "$0")/.." …)`) and uses a
fresh `mktemp` work dir + fake `$HOME`, so it survives directory renames and tmp clears.

After editing any `.sh` file, write `.claude/verify.json` before stopping (per the global
review-loop convention) — the three commands above are the standard gate.

## Architecture

**Entry point** `statusline-command.sh` holds only config + the main flow; it sources two
modules. The flow is ordered to overlap I/O:

```
start_theme_job → start_width_job   # background jobs kicked off first (don't touch stdin)
parse_input                         # main shell blocks parsing the stdin JSON (the ONLY stdin reader)
collect_status                      # git×3 + effort scan, concurrent, blocks on the slowest
read_theme / read_width             # jobs already done → zero wait
load_palette → build_left → build_right → render_line
```

- **`lib/collect.sh`** — all input collection. Parses the stdin JSON in a single `jq`
  pass and runs theme / terminal-width / git / effort-mode lookups as **concurrent
  background jobs**. It `WRITES` a set of globals (listed in its header comment).
- **`lib/render.sh`** — palette + line assembly. `READS` those globals + the config knobs
  and `WRITES` the final line to stdout.

The collect→render boundary is a **global-variable contract**: collect.sh's `WRITES:`
header and render.sh's `READS:` header are the source of truth. Shellcheck disables for
SC2034/SC2154 are intentional (cross-module globals); always lint via `shellcheck -x` on
the entry point so it follows the `. ` sources.

### Concurrency model (the core idea)

Every slow external command (jq, git, stty, the transcript tail) runs as a background job
opened through **process substitution onto a dedicated file descriptor** (`exec 3< <(…)`).
A `read <&3` blocks until that job hits EOF — **the read IS the sync point**, no `wait` /
temp files. Jobs are independent, so wall-clock ≈ the single slowest job (~20ms), not the
sum. Adding a new collected field = add a job + its FD read, keeping read order aligned.

### Right-align / width algorithm (`render_line`)

Tiered, from roomiest to tightest: plain-whitespace gap (no `│`) → insert `│` junction →
head-truncate the **right** part (keep git, cut the session-name tail with `…`) → drop the
right part and truncate the **left**. Goal: the line **never exceeds the drawable width**
(`term_cols - EDGE_PAD`) and gets hard-cut/wrapped by the terminal. `vis_width` computes
visible columns by stripping SGR codes then estimating cells; `trunc_head` uses perl for
correct wide-char truncation with a pure-bash degraded fallback when perl is absent.

## Hard rules — violating these reintroduces fixed bugs

- **Never `set -e`, anywhere.** A `read` hitting EOF with no trailing newline returns
  rc=1 as a normal path; `-e` would kill the script mid-frame.
- **Every background job gets `</dev/null`.** Jobs inherit the stdin JSON pipe; only
  `parse_input`'s jq is allowed to consume stdin. A stray reader steals the JSON.
- **`LC_ALL=C` is pinned** (top of the entry point). It fixes the `%.0f` decimal format
  *and* makes `${#x}` count bytes — `vis_width`'s cell math depends on byte counting.
- **`parse_input` is the only sanitization entry for external strings.** It escapes
  `\n`/`\r`, strips C0 + DEL **and the C1 block U+0080–U+009F** (`select(. >= 32 and (. <
  127 or . > 159))`), and caps every field to 256 codepoints. Downstream code may then
  assume "only our own SGR codes reach the terminal." The **one exception** is the
  last-message file (read in `build_left`), which bypasses jq and so **re-strips the same
  control set** via glob — keep these two filters in sync.
- **The 256-cap is load-bearing, not cosmetic.** `vis_width`'s ASCII strip is O(n²) under
  macOS's bash 3.2; an uncapped multi-KB field stalls every frame (20KB ≈ 33s). Test `O`
  guards this.
- **jq control-char filtering uses `explode`/`implode`, not regex** — jq's Oniguruma
  doesn't honor `\u` escapes and treats a control range as a literal class.
- **`parse_input`'s `read` order must match the jq array order one-for-one.** They are
  positional.
- **Target bash 3.2** (macOS system bash). No bash-4+ features.

## Security model

Defense-in-depth, all regression-tested (cases `H`, `L`, `N`, `P`, `Q`, `R`, `S`):
ANSI/escape **injection** is neutralized by the control-char strip above (a raw ESC would
both inject into the terminal and desync `vis_width` into a line wrap); `session_id` is
**path-traversal-checked** (`''|*/*|*..*` → skip) before being interpolated into the
last-msg file path; width bounding guarantees **no overflow/wrap** even on 1–2 column
terminals or with perl absent; rate-limit "remaining" is clamped to ≥0%.

## Config knobs

Top of `statusline-command.sh`: `CTX_BAR` (gradient ctx bar vs plain text), `NORM_THINKING`
(whether thinking-on is the norm), `STYLE` (`claude` / `tokyo-night` /
`tokyo-night-claude` / `catppuccin` / `rose-pine`; light themes always use a fixed light
palette), `RIGHT_ALIGN`, `EDGE_PAD` (drawable-width correction; bump if a CC build
truncates the right edge again), `JGAP` (min gap before a `│` junction is inserted).
