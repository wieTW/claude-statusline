## MODIFIED Requirements

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
- THEN `time_to_exhaust = remaining / slope = 40 / 20 = 2.0h` (120m), so `projected_exhaust = now + 2h`; since `2.0h < 3h` (before reset) AND slope > 0, BOTH MANDATORY gates pass and a `burn_tte` IS emitted — but the final DISPLAY additionally depends on the `BURN_SENS` ceiling (see the "Configurable sensitivity knob" requirement): under the default `balanced` level the 120m projection exceeds the 105-minute (6300s) ceiling, so `build_burn` returns nothing and the alarm stays hidden
- GIVEN the same remaining = 40% and slope = 20%/h but time-to-reset = 1h
- THEN `time_to_exhaust = 2.0h >= 1h`, gate (b) fails, and the alarm SHALL NOT be shown
