## ADDED Requirements

### Requirement: Burn alarm disabled outright when cross-session sync is off

When the `RL_SYNC` config knob is false, the burn-projection alarm SHALL be disabled outright and no depletion indicator SHALL ever be emitted. Because the sample series lives only on the shared rate-limit cache that `_reconcile_core` maintains, disabling `RL_SYNC` removes the only source of persisted `(timestamp, adopted used%)` samples, so there is nothing to project a slope from. `reconcile_start` SHALL set the `burn_tte` global to empty and return before launching the `_reconcile_core` background job, and `reconcile_read` SHALL return early without reading any FD or mutating `burn_tte`, leaving it empty. `build_burn` SHALL then treat the empty `burn_tte` as "no alarm" and produce empty output. The `BURN_SENS` sensitivity knob SHALL have no effect while `RL_SYNC` is false, because it tunes only the ceiling applied to a `burn_tte` that is never produced.

#### Scenario: RL_SYNC false suppresses the alarm and skips all sampling

- **WHEN** `RL_SYNC` is false
- **THEN** `reconcile_start` SHALL set `burn_tte` empty and return without launching `_reconcile_core`, `reconcile_read` SHALL return early leaving `burn_tte` empty, no `P` sample SHALL be appended to the cache, and `build_burn` SHALL emit nothing

##### Example: sync-off frame shows no depletion glyph regardless of usage

- GIVEN `RL_SYNC=false` and a 5-hour window whose used% is climbing steeply toward exhaustion before reset
- WHEN a frame renders
- THEN `burn_tte` is empty, `build_burn` returns empty, and the statusline SHALL show no `↘` indicator and no time-to-exhaust text

##### Example: BURN_SENS is inert while sync is off

- GIVEN `RL_SYNC=false` and `BURN_SENS=sensitive`
- WHEN a frame renders
- THEN the sensitive level SHALL change nothing because `burn_tte` is empty, and no alarm SHALL be shown

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - lib/collect.sh
  - lib/render.sh
  - statusline-command.sh
-->

---
### Requirement: Sampling and projection are five-hour-window only

The burn-projection sample series and the slope projection SHALL be confined to the 5-hour window; the 7-day window SHALL NOT be sampled and SHALL NOT produce a burn alarm. Each frame's `_reconcile_core` awk pass SHALL append at most one `P` sample — the pair `(now, adopted used% of the 5-hour window)` — and only when the 5-hour `resets_at` (`r5`) is numeric and present in the reconciled authority map. The 7-day `resets_at` (`r7`) SHALL NOT be sampled, because the slope gate downstream reads only the 5-hour retained samples, so any 7-day series would be persisted but never read. The two-point slope, the positive-slope gate, the before-reset gate, and the emitted `burn_tte` SHALL all be computed from the 5-hour window's retained samples alone.

#### Scenario: Only the five-hour window is sampled

- **WHEN** a writable frame reconciles both the 5-hour and 7-day windows into the authority map
- **THEN** exactly one `P` sample keyed by the 5-hour `resets_at` SHALL be appended for that frame, and no `P` sample keyed by the 7-day `resets_at` SHALL ever be appended

#### Scenario: The seven-day window never produces a burn alarm

- **WHEN** the 7-day window's used% is rising across frames
- **THEN** no slope SHALL be projected for it, no `burn_tte` SHALL be derived from it, and no `↘` indicator SHALL be attached to the 7-day quota segment

##### Example: climbing 7d usage stays silent

- GIVEN a 7-day window whose adopted used% climbs from 40% to 70% over several frames while the 5-hour window is flat
- WHEN the burn projection runs
- THEN the 5-hour slope is zero so its alarm is hidden, the 7-day window is never sampled, and no depletion indicator SHALL be shown for either window

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - lib/collect.sh
  - lib/render.sh
  - statusline-command.sh
-->

## MODIFIED Requirements

### Requirement: Configurable sensitivity knob

Sensitivity SHALL be controlled by a single config knob at the top of `statusline-command.sh` offering exactly three levels. `conservative` SHALL show the alarm only when the projected time-to-exhaust is 1800 seconds (30 minutes) or less. `balanced` SHALL be the default and SHALL show the alarm when the projected time-to-exhaust is 6300 seconds (105 minutes) or less. `sensitive` SHALL show the alarm whenever the projected exhaust is before reset (subject to the slope-positive gate). All three levels SHALL remain subordinate to the two mandatory display gates: the alarm SHALL NOT be shown unless the slope is positive AND the projected exhaust is before reset, regardless of level.

#### Scenario: Conservative suppresses a 60-minute projection

- **WHEN** the level is `conservative` and the projected time-to-exhaust is 60 minutes (before reset, slope positive)
- **THEN** the alarm SHALL NOT be shown because 60m is greater than the 30-minute conservative ceiling

#### Scenario: Balanced default shows a 60-minute projection

- **WHEN** the level is `balanced` and the projected time-to-exhaust is 60 minutes (before reset, slope positive)
- **THEN** the alarm SHALL be shown in yellow because 60m is within the 6300-second (105-minute) balanced ceiling and greater than 30m

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
### Requirement: Burn projection end-to-end result matrix

For the 5-hour quota, the displayed result SHALL be exactly hidden, yellow, or red according to the combination of remaining%, burn rate, time-to-reset, and projected exhaust, applying the slope-positive gate, the before-reset gate, the default `balanced` sensitivity ceiling of 6300 seconds (105 minutes), and the 30-minute red threshold.

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
- GIVEN 42% remaining at 25%/h: `time_to_exhaust = 42/25 ≈ 1H40m`; `1H40m < 2H10m` (before reset) and `100m <= 6300s (105m)` is within the balanced ceiling and `> 30m` → yellow
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

