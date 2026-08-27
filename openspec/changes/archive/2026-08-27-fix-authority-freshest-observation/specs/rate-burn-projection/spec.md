## MODIFIED Requirements

### Requirement: Burn-rate slope estimation from persisted samples

The statusline SHALL estimate the rate of change of a reset window's used-percentage by computing a smoothed positive slope (used% per hour) over the recent persisted samples of that window, and a two-point estimate using the oldest and newest in-range samples SHALL be an acceptable smoothing.

The sampled quantity SHALL be the cross-session reconciled freshest-observation authority adopted used% (the value the reconciliation writes into `five_h` / `seven_d`), so the slope reflects the truest known usage rather than the stale value an idle session keeps reporting.

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
