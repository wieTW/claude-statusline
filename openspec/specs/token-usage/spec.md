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
