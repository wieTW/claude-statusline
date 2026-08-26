## MODIFIED Requirements

### Requirement: Burn-rate slope estimation from persisted samples

The statusline SHALL estimate the rate of change of a reset window's used-percentage by computing a smoothed positive slope (used% per hour) over the recent persisted samples of that window, and a two-point estimate using the oldest and newest in-range samples SHALL be an acceptable smoothing.

The sampled quantity SHALL be the cross-session reconciled "newest-session authority" adopted used% (the value the reconciliation writes into `five_h` / `seven_d`), so the slope reflects the truest known usage rather than a frozen session's stale snapshot.

Each sample SHALL be a `(timestamp, adopted_used%)` pair persisted as a bounded series piggybacked on the existing rate-limit cache (`~/.claude/sl-ratelimit-cache`), keyed by the reconciled EFFECTIVE five-hour window key — the adopted class authority's `resets_at`, which equals the frame's own `five_reset` whenever that snapshot is live — written under the same per-pid temp + atomic `mv` discipline as the existing cache so concurrent sessions do not corrupt it. Keying by the effective window key means a frame whose own snapshot window has rolled still samples (and projects) against the live window it adopted, instead of producing no samples at all. When fewer than two in-range samples exist for a window, the slope SHALL be treated as undefined and no alarm SHALL be produced for that window.

#### Scenario: Two-point slope over recent samples

- **WHEN** a window has at least two persisted samples whose timestamps fall within the recent sampling horizon, the oldest being `(t0, p0)` and the newest `(t1, p1)` with `t1 > t0`
- **THEN** the statusline SHALL compute `slope = (p1 - p0) / ((t1 - t0) / 3600)` in used% per hour and SHALL use that slope for projection

##### Example: Two-point slope computation

- GIVEN samples `(t=0s, used=10%)` and `(t=1800s, used=20%)`
- WHEN the slope is computed
- THEN `slope = (20 - 10) / (1800/3600) = 10 / 0.5 = 20`%/h

#### Scenario: Insufficient samples yield no slope

- **WHEN** a window has zero or exactly one in-range persisted sample
- **THEN** the slope for that window SHALL be undefined and the burn alarm for that window SHALL NOT be shown

##### Example: Single in-range sample yields no alarm

- GIVEN a window with exactly one persisted sample `(t=0s, used=40%)` and no other in-range sample
- WHEN the slope is requested for that window
- THEN the slope SHALL be undefined and no burn alarm SHALL be shown for that window

#### Scenario: Sampled quantity is the reconciled authority value

- **WHEN** the reconciliation adopts a fresher session's used% for the five-hour class, mutating `five_h` in place from a frozen `30` to a reconciled `42`
- **THEN** the sample appended for that window SHALL record `42` (the adopted value), NOT the pre-reconciliation `30`

---
### Requirement: Sampling and projection are five-hour-window only

The burn-projection sample series and the slope projection SHALL be confined to the 5-hour window; the 7-day window SHALL NOT be sampled and SHALL NOT produce a burn alarm. Each frame's `_reconcile_core` awk pass SHALL append at most one `P` sample — the pair `(now, adopted used% of the 5-hour class)` — and only when a reconciled five-hour class authority exists; the sample SHALL be keyed by that authority's effective window key. The 7-day class SHALL NOT be sampled, because the slope gate downstream reads only the 5-hour retained samples, so any 7-day series would be persisted but never read. The two-point slope, the positive-slope gate, the before-reset gate, and the emitted `burn_tte` SHALL all be computed from the 5-hour window's retained samples alone, matched against the effective five-hour key.

#### Scenario: Only the five-hour window is sampled

- **WHEN** a writable frame reconciles both the 5-hour and 7-day classes into the authority records
- **THEN** exactly one `P` sample keyed by the effective 5-hour window key SHALL be appended for that frame, and no `P` sample keyed by the 7-day window SHALL ever be appended

#### Scenario: The seven-day window never produces a burn alarm

- **WHEN** the 7-day window's used% is rising across frames
- **THEN** no slope SHALL be projected for it, no `burn_tte` SHALL be derived from it, and no `↘` indicator SHALL be attached to the 7-day quota segment

##### Example: climbing 7d usage stays silent

- GIVEN a 7-day window whose adopted used% climbs from 40% to 70% over several frames while the 5-hour window is flat
- WHEN the burn projection runs
- THEN the 5-hour slope is zero so its alarm is hidden, the 7-day window is never sampled, and no depletion indicator SHALL be shown for either window

---
### Requirement: Bounded persisted sample series on the rate-limit cache

The sample series SHALL be bounded so the cache cannot grow without limit: per window, only the most recent samples needed to compute a smoothed slope over the sampling horizon SHALL be retained, and samples for a window whose `resets_at` is at or before `now` SHALL be pruned on rewrite (mirroring the existing `W5`/`W7` and `S` line pruning). The series SHALL be encoded as an additional cache line type that the existing `awk` reconciliation pass reads and rewrites in the same single pass, and malformed or old-format sample lines SHALL be dropped (not carried forward) exactly as malformed `W5`/`W7`/`S` lines already are. Any failure to write the cache (for example a read-only `$HOME`) SHALL degrade safely, leaving the current frame's values untouched and producing no alarm rather than an error.

#### Scenario: Expired window samples are pruned

- **WHEN** the cache holds samples for a window whose `resets_at` is at or before `now`
- **THEN** those samples SHALL be dropped on the next rewrite and SHALL NOT contribute to any future slope

#### Scenario: Bounded retention caps the series length

- **WHEN** a window accumulates more samples than the retention bound across many frames
- **THEN** only the most recent samples within the sampling horizon SHALL be kept and the cache line count for that window SHALL stay bounded

##### Example: Retention bound caps a window at 5 samples

- GIVEN a per-window retention bound of 5 samples and 9 frames have each appended one in-horizon sample for the same window
- WHEN the cache is rewritten on the 9th frame
- THEN only the 5 most recent in-horizon samples SHALL remain and that window's sample-line count SHALL be 5

#### Scenario: Cache write failure degrades safely

- **WHEN** the cache temp file cannot be created or `mv`-replaced (read-only `$HOME`)
- **THEN** the frame SHALL keep its own reconciled values, SHALL NOT emit a burn alarm, and SHALL NOT print any error to stdout or the terminal
