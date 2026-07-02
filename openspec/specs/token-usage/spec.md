# token-usage Specification

## Purpose

The token-usage capability defines the cumulative input-plus-output token counter (cache tokens excluded, so the number is stable across prompt-cache churn) for the session and its subagents. It owns the human-formatted display and its placement, the per-message deduplicated summation over the transcripts, and the change-gated, detached background recompute that keeps the per-frame latency budget while refreshing a cache for subsequent frames.

## Requirements

### Requirement: Cumulative Session Token Display

The statusline SHALL render a left-part segment showing the current session's cumulative input plus output token count, computed as the sum of `input_tokens + output_tokens` over every assistant turn recorded in the session transcript, and this sum SHALL exclude `cache_read` and `cache_creation` token counts.

The displayed number SHALL be human-formatted: values below 1000 SHALL render as the raw integer, values from 1000 up to (but excluding) 1,000,000 SHALL render as a "k" abbreviation, and values of 1,000,000 and above SHALL render as an "M" abbreviation. The "k" form SHALL be an integer count of thousands; the "M" form SHALL carry one decimal place.

The token-usage segment SHALL appear in the left part, positioned immediately after the context meter and before the rate-limit quota segments (the five-hour and seven-day windows), so the left part reads context, tokens, five-hour, seven-day, last-message. It SHALL NOT be positioned after the seven-day quota.

#### Scenario: Session-only total with no subagents

- **WHEN** the session transcript records assistant turns whose summed `input_tokens + output_tokens` (excluding cache_read and cache_creation) is greater than zero AND the subagent cumulative total is zero
- **THEN** the segment SHALL render the session total alone, human-formatted, with no "⊂" marker present anywhere in the segment

##### Example: Session-only rendering

- GIVEN the cached session total is 562000 tokens and the cached subagent total is 0
- WHEN `build_left` assembles the token-usage segment
- THEN the segment text SHALL be `562k` with no `⊂` marker

##### Example: Cache tokens excluded from the sum

- GIVEN three assistant turns with `(input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens)` of `(100, 50, 9000, 4000)`, `(200, 80, 12000, 0)`, and `(40, 30, 0, 0)`
- WHEN the summation job computes the session total
- THEN the session total SHALL be `500` (the sum of input+output only: 150 + 280 + 70), and the cache_read and cache_creation columns SHALL contribute nothing

#### Scenario: Segment placed between context and the rate-limit windows

- **WHEN** the context meter, the token-usage segment, and the five-hour and seven-day rate-limit segments are all present in a frame
- **THEN** the left-part order SHALL be context, then tokens, then the five-hour window, then the seven-day window (tokens before the rate-limit windows, not after the seven-day window)

##### Example: token index precedes the rate-limit indices

- GIVEN a frame whose left part contains a context segment, a token segment `128k`, a five-hour segment `2H10m 37%`, and a seven-day segment `5D6H 72%`
- WHEN `build_left` appends the segments in order
- THEN the token segment's position in the left part SHALL be after the context segment and before the five-hour segment (so its index is lower than both rate-limit segments' indices)

---
### Requirement: Subagent Token Display

The token-usage segment SHALL additionally show the subagents' cumulative `input_tokens + output_tokens` total (excluding cache_read and cache_creation) prefixed with the marker "⊂" WHEN that subagent cumulative total is greater than zero. WHEN the subagent cumulative total is zero, the segment SHALL show ONLY the session number and SHALL NOT emit the "⊂" marker or any subagent number.

#### Scenario: Subagent total appended

- **WHEN** the cached subagent cumulative `input_tokens + output_tokens` total is greater than zero
- **THEN** the segment SHALL render the session total followed by the subagent total prefixed with "⊂", both human-formatted

##### Example: With-subagents rendering

- GIVEN the cached session total is 562000 tokens and the cached subagent total is 1100000 tokens
- WHEN `build_left` assembles the token-usage segment
- THEN the segment text SHALL contain `562k` and `⊂1.1M`

#### Scenario: No subagent marker when subagent total is zero

- **WHEN** the cached subagent cumulative total is exactly zero
- **THEN** the rendered segment SHALL NOT contain the character "⊂" and SHALL NOT contain any subagent number


<!-- @trace
source: statusline-tokens-burn-and-fixes
updated: 2026-06-16
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: Token Data Sources

The summation SHALL derive its inputs only from data Claude Code already provides; no new field from Claude Code is required. The session total SHALL come from the main transcript file at the `transcript_path` provided on stdin. The subagent total SHALL come from subagent transcripts located in the sibling subagents directory, defined as the `transcript_path` with its file extension removed, followed by `/subagents/`, and SHALL recursively match files named according to the `agent-*.jsonl` pattern within that directory tree.

The subagents directory path SHALL be subject to the same path-traversal safety posture as other interpolated paths: WHEN `transcript_path` is empty or does not resolve to a regular file, the session total summation SHALL be skipped; WHEN the derived subagents directory does not exist, the subagent total SHALL be treated as zero.

#### Scenario: Subagents directory derived from transcript path

- **WHEN** `transcript_path` is `/Users/x/.claude/projects/p/session-abc.jsonl`
- **THEN** the subagent transcripts SHALL be sought under `/Users/x/.claude/projects/p/session-abc/subagents/` matching `agent-*.jsonl` recursively

#### Scenario: Missing transcript yields no session total

- **WHEN** `transcript_path` is empty OR points to a path that is not a regular file
- **THEN** the session-total summation SHALL be skipped AND the segment SHALL render whatever total was last cached (an absent cache yields no token-usage segment)

#### Scenario: Absent subagents directory yields zero subagent total

- **WHEN** the derived subagents directory does not exist on disk
- **THEN** the subagent cumulative total SHALL be treated as zero AND the "⊂" marker SHALL NOT be rendered


<!-- @trace
source: statusline-tokens-burn-and-fixes
updated: 2026-06-16
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: Non-Blocking Background Summation

Token summation SHALL run as a detached, fire-and-forget background job — backgrounded with `&`, redirecting its stdin from `/dev/null` so it never consumes the stdin status JSON, and redirecting its stdout and stderr to `/dev/null` so nothing interleaves with the rendered line — and that job SHALL recompute and rewrite a cache for a SUBSEQUENT frame rather than being read within the current frame through a dedicated file descriptor. The foreground frame SHALL read the small cached total and SHALL NOT block on summation, preserving the per-frame latency budget. The summation job SHALL never invoke `set -e`, and a failed or unavailable summation (for example a read-only HOME or absent cache) SHALL degrade to rendering the last cached total, or to omitting the segment when no cache exists, without aborting the frame.

#### Scenario: Foreground reads cache and never blocks

- **WHEN** a frame is rendered
- **THEN** the foreground SHALL read the previously cached session and subagent totals to build the segment AND SHALL NOT wait for the current frame's summation job to finish before printing the line

##### Example: First-ever frame with no cache

- GIVEN no token cache file exists yet
- WHEN the frame renders
- THEN the token-usage segment SHALL be omitted for this frame AND a detached background summation SHALL be started so a subsequent frame can display the total

#### Scenario: Summation is detached, not read in-frame

- **WHEN** the summation job is launched for a frame
- **THEN** it SHALL be a detached background job that rewrites the cache for a later frame AND the current frame SHALL NOT read that job's output through a file descriptor before printing its line

##### Example: launch shape is fire-and-forget

- GIVEN a frame with a valid `transcript_path` and `session_id`
- WHEN the token summation is launched
- THEN it SHALL be started as `tokens_update … >/dev/null 2>&1 </dev/null &` (backgrounded, stdout/stderr and stdin all detached) AND the frame SHALL print its line using only the previously cached totals read by `read_tokens`, never awaiting this job

---
### Requirement: Change-Gated Recompute

A full recompute of the token totals SHALL happen only in the background and SHALL be skipped when the source files are unchanged, determined by a size and mtime check across the main transcript and the subagent transcript files. WHEN that size/mtime signature is unchanged since the last successful summation, the background job SHALL NOT re-scan the transcripts and the cached totals SHALL be reused. WHEN any source file's size or mtime has changed, a full recompute SHALL run in the background and SHALL refresh the cache.

#### Scenario: Recompute skipped when sources unchanged

- **WHEN** the size/mtime signature of the main transcript and all matched subagent transcripts is identical to the signature stored with the cache
- **THEN** the background job SHALL skip re-scanning AND the cached session and subagent totals SHALL be reused unchanged

##### Example: unchanged signature reuses the cache

- GIVEN the stored signature records the main transcript at size 48211 / mtime 1718400000 and the cached totals are session 562k / subagent 1.1M
- WHEN a frame observes the main transcript and every matched subagent transcript at the identical size and mtime
- THEN the background job SHALL NOT re-scan and the segment SHALL reuse the cached `562k ⊂1.1M`

#### Scenario: Recompute runs when a source file changes

- **WHEN** the main transcript or any matched subagent transcript has a different size or mtime than the stored signature
- **THEN** a full recompute SHALL run in the background AND the cache (totals plus the new signature) SHALL be refreshed for subsequent frames

##### Example: Signature gate decision

- GIVEN the stored signature records the main transcript at size 48211 / mtime 1718400000 and the cached session total is 562k
- WHEN a frame observes the main transcript now at size 48990 / mtime 1718400305
- THEN the size/mtime differs, so a background recompute SHALL run and refresh both the totals and the stored signature; the foreground SHALL still render the prior cached `562k` for this frame


<!-- @trace
source: statusline-tokens-burn-and-fixes
updated: 2026-06-16
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: Token Display Respects Statusline Hard Rules

The token-usage feature SHALL conform to the statusline hard rules without exception. The implementation SHALL target bash 3.2, SHALL NOT use `set -e`, SHALL keep `LC_ALL=C` pinned for its integer and `%.0f`/decimal formatting, and SHALL NOT introduce any foreground stdin reader other than `parse_input`. Because no new Claude Code stdin field is added, `parse_input`'s positional jq-array-to-read order SHALL remain unchanged. Any externally sourced string used by the feature SHALL pass through the same control-character sanitization posture already enforced (the 256-codepoint cap and control-strip), preserving the invariant that only the script's own SGR codes reach the terminal.

#### Scenario: No new stdin field and no parse_input reorder

- **WHEN** the feature is implemented
- **THEN** `parse_input`'s jq array and its one-for-one `read` order SHALL be unchanged AND no foreground reader other than `parse_input` SHALL consume the stdin JSON

#### Scenario: Background job isolates stdin and avoids set -e

- **WHEN** the summation background job is launched
- **THEN** the job SHALL redirect its stdin from `/dev/null` AND neither the job nor the entry flow SHALL enable `set -e`

#### Scenario: Verify gate passes

- **WHEN** the acceptance gate runs
- **THEN** `bash -n statusline-command.sh`, `bash -n lib/collect.sh`, and `bash -n lib/render.sh` SHALL each exit 0, `shellcheck -x statusline-command.sh` SHALL pass, AND `bash tests/run-tests.sh` SHALL print `ALL CHECKS PASSED`

<!-- @trace
source: statusline-tokens-burn-and-fixes
updated: 2026-06-16
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: Per-Message Deduplicated Summation

The token summation (`_sum_inout` in `lib/collect.sh`) SHALL count each assistant message's usage exactly once, keyed on `.message.id`, because Claude Code writes one transcript JSONL row per content block (text, thinking, tool_use) and every such row repeats the SAME message-level `usage` object; a naive per-row sum therefore multiplies each message by its content-block count (measured at roughly 10x on real transcripts) and SHALL NOT be used. The summation SHALL maintain a streamed seen-set of already-counted message ids and, for each row, SHALL add `input_tokens + output_tokens` (each defaulting to 0 when absent, cache columns excluded) to the running total only when that message id has not already been counted. A row whose `.message.usage` is absent SHALL contribute nothing. A row that carries usage but has no `.message.id` SHALL fall through and count (it cannot be deduplicated), matching that this case does not occur in practice.

#### Scenario: Repeated per-block usage counts the message once

- **WHEN** a single assistant message is recorded across multiple JSONL rows (one per content block) that each repeat the identical `.message.id` and the identical `.message.usage`
- **THEN** the summation SHALL add that message's `input_tokens + output_tokens` exactly once, not once per row

##### Example: Ten content-block rows do not decuple the total

- GIVEN one message with `.message.id` `msg_abc` and `usage.input_tokens = 100`, `usage.output_tokens = 50`, emitted across 10 JSONL rows that all repeat that same id and usage
- WHEN `_sum_inout` streams those 10 rows
- THEN the contributed total SHALL be `150`, NOT `1500`

#### Scenario: Row without usage contributes nothing

- **WHEN** a transcript row has no `.message.usage` object
- **THEN** the summation SHALL skip that row and add zero, without altering the seen-set

---
### Requirement: On-Disk Token Cache Schema And Atomic Rewrite

The token totals SHALL be persisted in a single-line-per-session cache file at `$HOME/.claude/sl-tokens-cache` (`TOKENS_CACHE`), where each session's line SHALL have exactly the eight space-separated fields `T <sid> <session_tokens> <subagent_tokens> <main_size> <main_mtime> <sub_size> <sub_mtime>`: the literal tag `T`, the session id, the cumulative session and subagent in-plus-out token totals, and the size/mtime signature of the main transcript and of the aggregated subagent transcripts. The foreground reader (`read_tokens`) SHALL locate this session's line by an exact match on the tag `T` and the session id and SHALL adopt `session_tokens` and `subagent_tokens` only when each is a non-empty all-digits value, leaving them empty otherwise. Every rewrite (`tokens_update`) SHALL be performed atomically by writing a temporary file (`$TOKENS_CACHE.$$`) and renaming it over the cache with `mv -f`, so a concurrent reader never observes a partially written file; the cache, its temporary file, and its lock SHALL be created private via `umask 077` because the file holds session ids and token counts. When the temporary-file write fails, the `mv` SHALL NOT run and the previous cache SHALL be left intact.

#### Scenario: Cache line has the eight-field token schema

- **WHEN** `tokens_update` rewrites the cache for a session
- **THEN** this session's line SHALL be `T <sid> <session_tokens> <subagent_tokens> <main_size> <main_mtime> <sub_size> <sub_mtime>` with exactly those eight space-separated fields in that order

##### Example: A freshly written token line

- GIVEN session id `sess-1` with session total `562000`, subagent total `1100000`, main transcript size `48211` / mtime `1718400000`, and aggregated subagent size `9002` / mtime `1718399000`
- WHEN `tokens_update` appends this session's line
- THEN the line SHALL be `T sess-1 562000 1100000 48211 1718400000 9002 1718399000`

#### Scenario: Rewrite is atomic via temp plus rename

- **WHEN** the cache is rewritten
- **THEN** the new content SHALL be written to a temporary file first AND SHALL be moved over the cache with `mv -f` only after the write succeeds, so no reader observes a truncated line

---
### Requirement: Single-Flight Background Recompute

The background recompute (`tokens_update`) SHALL be serialized so at most one recompute is in flight at a time, guarded by an `mkdir` lock directory at `$TOKENS_CACHE.lock` (the POSIX-atomic primitive; stock macOS has no `flock`). WHEN the lock cannot be acquired, the job SHALL steal the lock only when the existing lock directory's mtime is older than 30 seconds (a writer that died mid-recompute), otherwise it SHALL return without recomputing so it does not contend. WHEN the size/mtime gate shows the sources are unchanged, the job SHALL release the lock (`rmdir`) and return without re-scanning. The lock SHALL be released after a successful rewrite. The lock SHALL NOT be held across the foreground frame — it exists only inside the detached worker.

#### Scenario: Second concurrent recompute skips while a fresh lock is held

- **WHEN** a recompute is already in flight and its lock directory exists with an mtime newer than 30 seconds
- **THEN** a second recompute SHALL return without re-scanning and without stealing the lock

#### Scenario: Stale lock is stolen after thirty seconds

- **WHEN** the lock directory exists but its mtime is older than 30 seconds (the prior writer died)
- **THEN** the new recompute SHALL `rmdir` the stale lock, re-acquire it, and proceed; if re-acquisition still fails it SHALL return without recomputing

##### Example: Lock released on the unchanged-sources gate

- GIVEN the cached size/mtime signature for this session equals the main and subagent transcripts' current size and mtime
- WHEN `tokens_update` acquires the lock and evaluates the gate
- THEN it SHALL `rmdir` the lock and return without re-summing the transcripts

---
### Requirement: Cross-Session Cache Pruning

On every rewrite, `tokens_update` SHALL prune the cache so it cannot grow without bound as sessions accumulate: it SHALL drop this session's own prior line (an exact match on the session id in field 2, not a regex, so an odd session id cannot over-delete) before appending the fresh line, AND it SHALL drop any other `T` line whose `main_mtime` (field 6) is a valid integer older than the retention cutoff `now - RL_REG_TTL` — a session whose transcript has not been touched within the retention window is treated as dead. Lines that do not match the eight-field `T` shape SHALL be preserved verbatim. The retention window SHALL be governed by the `RL_REG_TTL` config knob (default 604800 seconds / 7 days), shared with the rate-limit registry; a non-numeric or below-floor `RL_REG_TTL` SHALL be clamped so retention is never shorter than the longest reset window (604800 seconds).

#### Scenario: Dead session line pruned on rewrite

- **WHEN** the cache contains a `T` line for another session whose `main_mtime` is older than `now - RL_REG_TTL`
- **THEN** that line SHALL be dropped from the rewritten cache

#### Scenario: Live session lines retained

- **WHEN** a `T` line for another session has a `main_mtime` newer than the retention cutoff
- **THEN** that line SHALL be preserved in the rewritten cache

##### Example: Own line replaced, stale peer pruned, live peer kept

- GIVEN `now = 1719000000`, `RL_REG_TTL = 604800` (cutoff `1718395200`), and the cache holds a line for the current session `sess-1`, a peer `sess-old` with `main_mtime = 1718000000`, and a peer `sess-live` with `main_mtime = 1718900000`
- WHEN `tokens_update` rewrites the cache for `sess-1`
- THEN the old `sess-1` line SHALL be removed and replaced by the fresh line, `sess-old` SHALL be pruned, and `sess-live` SHALL be retained

---
### Requirement: Token Segment Colouring

The rendered token-usage segment (`build_left` in `lib/render.sh`) SHALL colour the session total with the primary-text role `WH` (white). WHEN a non-zero subagent total is present, the segment SHALL append the subagent total coloured with the `YL` (yellow) role, immediately preceded by the `⊂` marker (with its leading space) coloured with the `DM` (dim) role, so the marker reads as secondary framing while the subagent number itself carries the yellow accent. Each coloured span SHALL be terminated with the reset sequence so no colour leaks past the segment. WHEN the subagent total is zero or absent, no `⊂` marker, no yellow subagent number, and no dim span SHALL be emitted, leaving only the white session total.

#### Scenario: Session total is white, subagent total is yellow with a dim marker

- **WHEN** the token segment renders a non-zero session total and a non-zero subagent total
- **THEN** the session number SHALL use the `WH` role, the `⊂` marker (and its leading space) SHALL use the `DM` role, and the subagent number SHALL use the `YL` role

##### Example: Composed colour spans for session plus subagent

- GIVEN the cached session total is 562000 and the cached subagent total is 1100000
- WHEN `build_left` assembles the token segment
- THEN the segment SHALL render `562k` in `WH`, then ` ⊂` in `DM`, then `1.1M` in `YL`, each span reset-terminated

#### Scenario: No dim marker or yellow span when subagent total is zero

- **WHEN** the subagent total is zero or absent
- **THEN** the segment SHALL emit only the `WH` session total AND SHALL NOT emit any `DM` marker span or `YL` subagent span

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - lib/collect.sh
  - lib/render.sh
  - statusline-command.sh
-->
