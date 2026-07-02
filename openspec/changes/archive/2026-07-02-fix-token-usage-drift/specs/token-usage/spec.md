## MODIFIED Requirements

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
