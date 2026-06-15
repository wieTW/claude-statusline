<!-- SPECTRA:START v1.0.2 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra-*` skills when:

- A discussion needs structure before coding → `/spectra-discuss`
- User wants to plan, propose, or design a change → `/spectra-propose`
- Tasks are ready to implement → `/spectra-apply`
- There's an in-progress change to continue → `/spectra-ingest`
- User asks about specs or how something works → `/spectra-ask`
- Implementation is done → `/spectra-archive`
- Commit only files related to a specific change → `/spectra-commit`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra-apply` and `/spectra-ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-line Claude Code statusline. Claude Code invokes `statusline-command.sh`,
piping a status JSON on **stdin**; the script prints **one colored line** on stdout.
It is not auto-installed — wire it up by pointing the `statusLine.command` setting (in
`~/.claude/settings.json`) at the script's absolute path. Reference guide:
`github.com/Raymondhou0917/claude-code-resources` starter-kit `06-statusline.md`.

The line has two halves: a **left** part (path · model · effort · thinking · ctx bar ·
token usage · rate-limit countdowns · last-message time) and a **right** part (git ·
worktree · session name), right-aligned to the terminal edge with a `│` junction that
appears only when the two halves nearly touch.

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

`tests/run-tests.sh` is one monolithic suite — each check prints a labeled section (`A`,
`A2`, `B`…`U`, plus `G` perf at the end; `T` = rate-sync rule matrix, `U` = last-msg age);
a failure prints `★ FAIL` and the script exits 1. There is **no
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
start_tokens_job                    # fire-and-forget detached token re-sum for the NEXT frame (never blocks this one)
collect_status                      # git×3 + effort scan, concurrent, blocks on the slowest
read_theme / read_width             # jobs already done → zero wait
reconcile_rates                     # cross-session rate-limit sync (newest-session authority; see RL_SYNC)
read_tokens                         # read this session's cached token totals (tiny file; heavy sum runs only in the bg job)
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

### Cross-session rate-limit sync (`reconcile_rates`)

CC freezes `rate_limits` at each session's **start snapshot** (upstream limitation): an old
session keeps showing a stale used%, only the countdown moves. `reconcile_rates` (in
`lib/collect.sh`, gated by `RL_SYNC`) fixes this via a shared cache at
`~/.claude/sl-ratelimit-cache` — an `awk` pass over two line types: `S <session_id>
<first_seen>` (a registry of each session's first render time) and `W <resets_at> <used>
<auth_first_seen>` (per reset-window authority value). **Rule: the newest session is the
authority** — a window's used% is overwritten only by a report whose session's `first_seen`
is newer-or-equal, so a frozen old session can't override a fresher one in either direction
(adopt a climb, honour a genuine cap-raise drop). `RL_REG_TTL` prunes registry records older
than the longest reset window. Test section `T` covers the full rule matrix.

### Token usage (`start_tokens_job` / `read_tokens` / `tokens_update`)

Cumulative **input+output** tokens (cache tokens deliberately EXCLUDED, so the number is
stable across prompt-cache churn) for this session and its subagents, shown left between
the ctx bar and the rate windows. Summing ~6–23MB of transcript JSONL is too slow for the
hot path, so the foreground only ever **reads** a tiny one-line-per-session cache at
`~/.claude/sl-tokens-cache` (`read_tokens`); a **detached** background job
(`start_tokens_job` → `tokens_update`) re-sums and rewrites the cache for the *next* frame,
gated on the transcript's size/mtime so it only recomputes when sources changed. So this
frame shows the previous result (first-ever frame: nothing). Cache line:
`T <sid> <session_tokens> <subagent_tokens> <main_size> <main_mtime> <sub_size> <sub_mtime>`;
subagent transcripts are summed from `<transcript without extension>/subagents/**/agent-*.jsonl`.
**`_sum_inout` dedups by `.message.id`** — CC writes one JSONL row per content block, each
repeating the same message-level usage, so a naive per-row sum over-counts (~10x on real
logs). The rewrite is single-flighted by an `mkdir` lock (stale-stolen after 30s) and prunes
`T`-lines whose `main_mtime` is older than `RL_REG_TTL` so the file can't grow unbounded.
Test sections `W` (display) / `X` (dedup) / `X2` (prune) cover it.

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
truncates the right edge again), `JGAP` (min gap before a `│` junction is inserted),
`RL_SYNC` (cross-session rate-limit sync on/off; see above), `RL_REG_TTL` (session-registry
retention in sec, default 7d), and the last-message age tiers `LASTMSG_WARN` (Δ ≥ this →
yellow, default 300s = 5-min cache idle-cold) / `LASTMSG_STALE` (Δ ≥ this → red, default
3600s = extended cache gone). The age colours track Anthropic's two prompt-cache TTLs (5 min
/ 1 h); the timestamp is shown as honest elapsed text, only Δ carries the cache read.
