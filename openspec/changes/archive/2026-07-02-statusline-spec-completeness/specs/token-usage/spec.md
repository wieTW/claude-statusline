## ADDED Requirements

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

