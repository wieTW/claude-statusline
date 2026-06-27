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

The line has two halves: a **left** part (path · model · effort · thinking · ctx bar +
200k cliff marker · token usage · rate-limit countdowns + burn-projection alarm ·
session duration + last-message cache-age delta) and a **right** part (git · worktree · session name),
right-aligned to the terminal edge with a `│` junction that appears only when the two halves
nearly touch. When the terminal is too narrow, the line degrades through a fixed 14-step
sacrifice order (shrink before drop; path + ctx% never dropped) so it never wraps.

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
`A2`, `B`… through the alphabet, plus `G` perf at the very end). Key feature sections:
`T`/`T2` = rate-sync rule matrix + concurrency, `U` = last-msg age (incl. cross-day),
`V` = parse_input positional sentinel, `W`/`X`/`X2` = token display/dedup/prune,
`CTX` = budget-aware context meter + 200k cliff, `Y` = burn projection, `Z`/`Z1`–`Z5` =
adaptive-layout 14-step degrade. A failure prints `★ FAIL` and the script exits 1. There is **no
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
reconcile_start                     # cross-session rate-limit sync as a background FD job — overlaps the git stage below (see RL_SYNC)
collect_status                      # git×3 + effort scan, concurrent, blocks on the slowest
read_theme / read_width             # jobs already done → zero wait
reconcile_read                      # reap the reconcile FD: adopt the freshest used% any session saw + the burn-projection time-to-exhaust
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

### Right-align / adaptive-layout width algorithm (`render_line` + `degrade_layout`)

Goal: the line **never exceeds the drawable width** (`term_cols - EDGE_PAD`) and so never
gets hard-cut/wrapped by the terminal. `render_line` is tiered from roomiest to tightest:
plain-whitespace gap (no `│`) → insert `│` junction → … . When even the junction tier
overflows, it walks **`degrade_layout` over a fixed 14-step sacrifice order** — applying
each step only when the prior step still overflows (earliest sufficient step), so a wide
terminal never enters the ladder and renders unchanged.

The principle is **shrink/truncate before drop; the core (path + ctx%) is never dropped**.
The 14 steps, widest→narrowest: 1 gap→junction (the junction tier) · 2 drop git diffstat ·
3 drop worktree · 4 ctx bar→plain `N%` · 5 drop git branch · 6 drop last-msg · 7 drop 7d ·
8 drop token (session+subagent as one unit) · 9 model→first-word compact · 10 drop model ·
11 truncate session with `…` (the right-truncation tier, keeps git) · 12 drop session ·
13 5h→remaining-% compact (**keeps any burn alarm**, drops only the reset countdown) ·
14 core only = path + ctx%, head-truncating the **path** (not the %) so the percentage
survives a 1–2 column terminal. Segments with two forms shrink at their step before any
later drop (4 ctx, 9 model, 11 session, 13 5h). `vis_width` computes visible columns by
folding the narrow multibyte glyphs we emit (`│ · … ⊂ ↘ ⚑`) to 1 byte then estimating cells
(byte-count overestimate, safe direction — only shrinks the gap); `trunc_head` uses perl for
correct wide-char truncation with a pure-bash degraded fallback when perl is absent.
Sections `Z`/`Z1`–`Z5` cover the invariant, the per-segment compact forms, the monotone order,
shrink-before-drop, and core survival at pathological widths.

### Cross-session rate-limit sync (`reconcile_start` / `reconcile_read` / `_reconcile_core`)

CC freezes `rate_limits` at each session's **start snapshot** (upstream limitation): an old
session keeps showing a stale used%, only the countdown moves. Reconcile (in `lib/collect.sh`,
gated by `RL_SYNC`) fixes this via a shared cache at `~/.claude/sl-ratelimit-cache` — an `awk`
pass over three line types: `S <session_id> <first_seen>` (a registry of each session's first
render time), `W <resets_at> <used> <auth_first_seen>` (per reset-window authority value), and
`P <resets_at> <timestamp> <used>` (bounded burn-projection sample series; see below).
**Rule: the newest session is the authority** — a window's used% is overwritten only by a
report whose session's `first_seen` is newer-or-equal, so a frozen old session can't override
a fresher one in either direction (adopt a climb, honour a genuine cap-raise drop). `RL_REG_TTL`
prunes registry records older than the longest reset window. Test section `T` covers the full
rule matrix.

**Backgrounded + serialized.** `reconcile_start` launches `_reconcile_core` as a background FD
job (`exec 9< <(… </dev/null)`) overlapping the git stage; `reconcile_read` reaps the FD and
applies numeric adoption guards. The whole read+awk+mv is serialized by an **`mkdir` spin-lock**
(`<cache>.lock` — stock macOS has no `flock`; `mkdir` is the POSIX-atomic primitive) with
bounded retry + stale-steal (`RL_LOCK_TRIES`/`RL_LOCK_WAIT`/`RL_LOCK_STALE`, defined in
collect.sh), so concurrent renders don't lose updates. Two safe-degradation paths, both still
**adopting the value they READ** (never their own frozen report): lock not acquired → skip the
`mv`, run awk read-only; **empty `session_id`** → skip the lock and `mv` entirely (an anonymous
frame can't be ranked, so it never does a destructive rewrite). Any awk/mv/lock failure leaves
the emitted fields empty → `reconcile_read`'s guards keep this frame's own parse_input values
(never `set -e`). Section `T2` covers the concurrency, lock-contention safe-skip, and empty-sid path.

### Rate-limit burn-projection alarm (`_reconcile_core` awk → `build_burn`)

The 5h window samples its **adopted** used% (the reconciled authority, not the frozen
snapshot) into the `P` series each frame, keeping ≤5 samples over a ~3h horizon. The awk
computes a **two-point slope** (oldest→newest in-horizon sample) and emits `burn_tte` =
seconds-to-exhaust only when **both mandatory gates** pass: the slope is positive (used% is
climbing) AND extrapolating it hits 100% strictly **before** `resets_at`. (Falling used%
→ empty `burn_tte` → nothing shown; only the depletion glyph `↘` is ever emitted.) `build_burn`
in render.sh then applies the `BURN_SENS` sensitivity ceiling and the colour threshold,
rendering `↘<time-to-exhaust>` next to the 5h quota — yellow `>30m`, red `≤30m`. Otherwise the
segment stays silent (the statusline's "show only when abnormal" rule). The alarm rides inside
the 5h segment and is **retained** when that segment collapses to its compact form (degrade
step 13). Section `Y` covers the result matrix, thresholds, the depletion-only direction,
the gates, the bounded sample retention, and the sensitivity knob.

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

### Context meter (`build_left`, ctx segment)

The ctx% turns red only near the model's context limit, on a **budget-aware** threshold —
NOT a fixed 80%. A 1M-context model (display name carries the `1M context` / `(1M)` marker,
the same signal the model-name compaction keys on) has ~5x the budget, so 80% there is still
huge headroom and would falsely flag red; the threshold is **80% for 200k-class models, 92%
for 1M-context models** (keeps the spec's worked 85% example normal-coloured while still
warning as the 1M window nears full). Separately, a **200k cost/cache cliff marker** `⚑` is
appended iff the upstream `exceeds_200k_tokens` flag is true. The marker is **decoupled** from
the percentage colour — driven solely by the flag, independent of used% or which budget the
colour threshold picked (a normal-coloured 1M frame can still show the cliff). Section `CTX`
covers the budget-aware threshold and the decoupled marker.

### Session duration + last-message age (`build_left`, time segment)

The time segment's **primary** text is the **session duration**: `cost.total_duration_ms`
(upstream wall-clock since session start, idle included) divided to seconds and run through
`fmt_dur` (`1H15m` / `40m` / `2D3H`), shown dim. It **replaces** the absolute last-prompt
clock. A parenthesized delta `(Δ)` — how long since the last user prompt — is appended once
that age is ≥60s, and the **delta's colour** signals prompt-cache freshness via the two idle
tiers (dim < `LASTMSG_WARN` ≤ yellow < `LASTMSG_STALE` ≤ red). A sub-minute age hides the
delta. Both texts are honest elapsed time; only the Δ colour asserts the cache read (the
script can't see CC's real cache TTL). Negative ages (clock skew) clamp to 0.

**Clock fallback (backward compatible):** when `cost.total_duration_ms` is absent (older CC,
or a non-numeric value), the primary text falls back to the legacy `HH:MM` clock with the same
`(Δ)`. This is the no-`cost` path that every test frame without a `cost` field takes, so the
whole `U` section's clock behaviour is preserved unchanged. **Cross-day correctness applies to
that clock fallback only:** `lm_epoch` is UTC but the stored `HH:MM` label is LOCAL, so a
prior-day prompt would read as today. When `lm_epoch` and `now` fall on **different LOCAL
calendar days** the clock is prefixed with the date (`MM-DD HH:MM`). The test is a calendar-day
difference, **not a fixed 24h age** — a `23:50` prompt rendered at `00:10` next day is cross-day
at Δ=20m and still gets the prefix (the spec's normative "cross-midnight under one hour"
scenario; this supersedes design.md/tasks.md 6.5's stale "Δ≥1h gate" wording — spec.md is the
authority). The date is resolved with `date -r <epoch>` (BSD/macOS, DST-correct, no manual
offset) and the fork is **gated behind the Δ≥60s + clock-fallback branch** so the common path
(duration primary, or a sub-minute prompt) stays fork-free. The session-duration primary needs
no cross-day fix — it is an elapsed span, not a wall clock. A legacy file with no numeric epoch
tail is shown verbatim when it is the fallback (backward compatible). Section `U` covers the
clock-fallback tiers, sub-minute hide, legacy format, and cross-day prefix; section `DUR`
covers the duration primary, clock replacement, `fmt_dur` boundaries, the no-last-msg case, and
the no-`cost` fallback.

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
retention in sec, default 7d), `BURN_SENS` (rate-limit burn-projection alarm sensitivity —
`conservative` alarms only ≤30m to exhaust / `balanced` default ~90m+ / `sensitive` alarms
whenever exhaust is projected before reset; needs `RL_SYNC=true` since it samples the
reconciled authority; all levels still require a positive slope AND projected exhaust before
reset), and the last-message age tiers `LASTMSG_WARN` (Δ ≥ this → yellow, default 300s = 5-min
cache idle-cold) / `LASTMSG_STALE` (Δ ≥ this → red, default 3600s = extended cache gone). The
age colours track Anthropic's two prompt-cache TTLs (5 min / 1 h); the timestamp is shown as
honest elapsed text, only Δ carries the cache read. (The reconcile `mkdir`-lock knobs
`RL_LOCK_STALE` / `RL_LOCK_TRIES` / `RL_LOCK_WAIT` live at the top of `lib/collect.sh`, not the
entry point — they tune the serialization spin-lock, not appearance.)

The token segment shows **cumulative input+output only — cache tokens are excluded**, so the
number is stable across prompt-cache churn and is NOT a measure of real spend (cache-write
cost is deliberately not counted; see the Token usage section).
