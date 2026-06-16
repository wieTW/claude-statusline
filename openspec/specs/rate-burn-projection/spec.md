# rate-burn-projection Specification

## Purpose

TBD - created by archiving change 'statusline-tokens-burn-and-fixes'. Update Purpose after archive.

## Requirements

### Requirement: Burn-rate slope estimation from persisted samples

The statusline SHALL estimate the rate of change of a reset window's used-percentage by computing a smoothed positive slope (used% per hour) over the recent persisted samples of that window, and a two-point estimate using the oldest and newest in-range samples SHALL be an acceptable smoothing.

The sampled quantity SHALL be the cross-session reconciled "newest-session authority" adopted used% (the value `reconcile_rates` writes into `five_h` / `seven_d`), so the slope reflects the truest known usage rather than a frozen session's stale snapshot.

Each sample SHALL be a `(timestamp, adopted_used%)` pair persisted as a bounded series piggybacked on the existing rate-limit cache (`~/.claude/sl-ratelimit-cache`), keyed by the window's `resets_at`, written under the same per-pid temp + atomic `mv` discipline as the existing cache so concurrent sessions do not corrupt it. When fewer than two in-range samples exist for a window, the slope SHALL be treated as undefined and no alarm SHALL be produced for that window.

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

- **WHEN** `reconcile_rates` adopts a fresher session's used% for a window, mutating `five_h` in place from a frozen `30` to a reconciled `42`
- **THEN** the sample appended for that window SHALL record `42` (the adopted value), NOT the pre-reconciliation `30`


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
### Requirement: Conditional display of the burn alarm

The burn alarm SHALL be displayed adjacent to the 5-hour quota segment ONLY WHEN BOTH conditions hold: (a) the smoothed slope is strictly greater than zero (used% is increasing), AND (b) the projected exhaust time (the wall-clock time at which used% reaches 100%) is strictly before the window's `resets_at`. When either condition fails, the alarm SHALL NOT be shown and the quota segment SHALL render exactly as it does today (hidden by default).

#### Scenario: Slow usage that does not exhaust before reset is hidden

- **WHEN** used% is increasing but the projected exhaust time is at or after `resets_at` (the window rolls over before the budget runs out)
- **THEN** the alarm SHALL NOT be shown

#### Scenario: Idle session is hidden

- **WHEN** the smoothed slope is zero or negative (used% is flat or the remaining budget is rising)
- **THEN** the alarm SHALL NOT be shown

##### Example: Flat usage hides the alarm

- GIVEN samples `(t=0s, used=58%)` and `(t=600s, used=58%)` giving slope = 0%/h
- WHEN the display gates are evaluated
- THEN the slope-positive gate fails and the alarm SHALL NOT be shown

#### Scenario: Window resets before projected exhaust is hidden

- **WHEN** the slope is positive but `projected_exhaust >= resets_at`
- **THEN** the alarm SHALL NOT be shown

##### Example: Projected exhaust derivation and the two gates

- GIVEN remaining = 40% (used 60%), slope = 20%/h, time-to-reset = 3h
- WHEN the projection is computed
- THEN `time_to_exhaust = remaining / slope = 40 / 20 = 2.0h`, so `projected_exhaust = now + 2h`; since `2.0h < 3h` (before reset) AND slope > 0, BOTH gates pass and the alarm SHALL be shown
- GIVEN the same remaining = 40% and slope = 20%/h but time-to-reset = 1h
- THEN `time_to_exhaust = 2.0h >= 1h`, gate (b) fails, and the alarm SHALL NOT be shown


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
### Requirement: Burn alarm indicator content and color thresholds

The alarm SHALL show only the depletion-direction glyph `↘` immediately followed by the projected time-to-exhaust formatted in the same compact duration style as the existing `ttl` helper (e.g. `↘33m`, `↘1H40m`). The alarm color SHALL be yellow when the projected time-to-exhaust is strictly greater than 30 minutes and red when the projected time-to-exhaust is 30 minutes or less. The indicator SHALL be subject to the same control-char-safe, width-bounded rendering as every other left-part segment and SHALL NOT widen the line past the drawable width.

#### Scenario: Comfortable approach renders yellow

- **WHEN** both display gates pass and the projected time-to-exhaust is greater than 30 minutes
- **THEN** the alarm SHALL render `↘<ttl>` in the yellow palette role

#### Scenario: Imminent exhaust renders red

- **WHEN** both display gates pass and the projected time-to-exhaust is 30 minutes or less
- **THEN** the alarm SHALL render `↘<ttl>` in the red palette role

##### Example: Color threshold boundary

- GIVEN projected time-to-exhaust = 31m
- THEN color SHALL be yellow and the text SHALL be `↘31m`
- GIVEN projected time-to-exhaust = 30m
- THEN color SHALL be red and the text SHALL be `↘30m`
- GIVEN projected time-to-exhaust = 20m
- THEN color SHALL be red and the text SHALL be `↘20m`


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
### Requirement: Depletion-only direction

Only the depletion direction (`↘`) SHALL ever be emitted by this capability. A condition in which the remaining budget is rising (used% decreasing, slope < 0) SHALL NOT produce any indicator, glyph, or arrow of any kind.

#### Scenario: Rising remaining emits nothing

- **WHEN** the smoothed slope is negative (used% is falling, e.g. after a cap raise recomputes the percentage down)
- **THEN** no alarm and no direction glyph SHALL be emitted; the quota segment SHALL render unchanged

##### Example: Negative slope produces no glyph

- GIVEN samples `(t=0s, used=50%)` and `(t=1800s, used=40%)` giving slope = -20%/h
- THEN the result SHALL be hidden with no `↘` and no upward glyph


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
### Requirement: Configurable sensitivity knob

Sensitivity SHALL be controlled by a single config knob at the top of `statusline-command.sh` offering exactly three levels. `conservative` SHALL show the alarm only when the projected time-to-exhaust is 30 minutes or less. `balanced` SHALL be the default and SHALL show the alarm when the projected time-to-exhaust is approximately 90 minutes or less. `sensitive` SHALL show the alarm whenever the projected exhaust is before reset (subject to the slope-positive gate). All three levels SHALL remain subordinate to the two mandatory display gates: the alarm SHALL NOT be shown unless the slope is positive AND the projected exhaust is before reset, regardless of level.

#### Scenario: Conservative suppresses a 60-minute projection

- **WHEN** the level is `conservative` and the projected time-to-exhaust is 60 minutes (before reset, slope positive)
- **THEN** the alarm SHALL NOT be shown because 60m is greater than the 30-minute conservative ceiling

#### Scenario: Balanced default shows a 60-minute projection

- **WHEN** the level is `balanced` and the projected time-to-exhaust is 60 minutes (before reset, slope positive)
- **THEN** the alarm SHALL be shown in yellow because 60m is within the ~90-minute balanced ceiling and greater than 30m

#### Scenario: Sensitive shows any before-reset projection

- **WHEN** the level is `sensitive`, the slope is positive, and the projected exhaust is before reset, with a projected time-to-exhaust of 2 hours
- **THEN** the alarm SHALL be shown

##### Example: Same projection across the three levels

| level | projected time-to-exhaust | before reset | slope > 0 | result |
| --- | --- | --- | --- | --- |
| conservative | 60m | yes | yes | hidden |
| balanced | 60m | yes | yes | yellow |
| sensitive | 60m | yes | yes | yellow |
| conservative | 25m | yes | yes | red |
| balanced | 120m | yes | yes | hidden |
| sensitive | 120m | yes | yes | yellow |


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
### Requirement: Bounded persisted sample series on the rate-limit cache

The sample series SHALL be bounded so the cache cannot grow without limit: per window, only the most recent samples needed to compute a smoothed slope over the sampling horizon SHALL be retained, and samples for a window whose `resets_at` is at or before `now` SHALL be pruned on rewrite (mirroring the existing `W` and `S` line pruning). The series SHALL be encoded as an additional cache line type that the existing `awk` reconciliation pass reads and rewrites in the same single pass, and malformed or old-format sample lines SHALL be dropped (not carried forward) exactly as malformed `W`/`S` lines already are. Any failure to write the cache (for example a read-only `$HOME`) SHALL degrade safely, leaving the current frame's values untouched and producing no alarm rather than an error.

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
### Requirement: Burn projection end-to-end result matrix

For the 5-hour quota, the displayed result SHALL be exactly hidden, yellow, or red according to the combination of remaining%, burn rate, time-to-reset, and projected exhaust, applying the slope-positive gate, the before-reset gate, the default `balanced` sensitivity ceiling of approximately 90 minutes, and the 30-minute red threshold.

#### Scenario: Canonical result table holds for the balanced default

- **WHEN** the sensitivity level is `balanced` and each row below is evaluated
- **THEN** the displayed result SHALL match the `result` column

##### Example: End-to-end result table (balanced default)

| remaining% | burn rate | time-to-reset | projected exhaust | result |
| --- | --- | --- | --- | --- |
| 90% | 11%/h | 2H10m | ~8h | hidden |
| 50% | 20%/h | 30m | 2.5h | hidden |
| 30% | 0 | 2H | — | hidden |
| 42% | 25%/h | 2H10m | 1H40m | yellow |
| 20% | 60%/h | 2H | 20m | red |
| 90% | 200%/h | 2H | 27m | red |

##### Example: Row-by-row derivation

- GIVEN 90% remaining at 11%/h: `time_to_exhaust = 90/11 ≈ 8.2h`; `8.2h >= 2H10m` so the before-reset gate fails → hidden
- GIVEN 50% remaining at 20%/h: `time_to_exhaust = 50/20 = 2.5h`; `2.5h >= 30m` so the before-reset gate fails → hidden
- GIVEN 30% remaining at 0%/h: slope is not positive so the slope gate fails → hidden
- GIVEN 42% remaining at 25%/h: `time_to_exhaust = 42/25 ≈ 1H40m`; `1H40m < 2H10m` (before reset) and `100m <= ~90m+` is within the balanced ceiling and `> 30m` → yellow
- GIVEN 20% remaining at 60%/h: `time_to_exhaust = 20/60 ≈ 20m`; before reset and `<= 30m` → red
- GIVEN 90% remaining at 200%/h: `time_to_exhaust = 90/200 ≈ 27m`; even with high remaining the burst still exhausts before the 2H reset and `<= 30m` → red

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