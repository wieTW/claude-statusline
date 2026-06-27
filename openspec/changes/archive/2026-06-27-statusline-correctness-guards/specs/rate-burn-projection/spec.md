## ADDED Requirements

### Requirement: Minimum sampling interval gate for slope projection

The burn-rate projection SHALL NOT extrapolate an exhaustion time from two samples whose real elapsed interval is shorter than 60 seconds. Before projecting, in addition to the existing positive-slope gate and the exhaust-before-reset gate, the projection MUST require that the elapsed seconds between the oldest and newest in-horizon samples is at least 60, compared inclusively at exactly 60. A render burst can persist two samples 1 to 2 seconds apart; without this gate a used% jump across that tiny interval extrapolates to a near-immediate exhaustion and fires a false imminent (red) alarm. The 60-second threshold is load-bearing: a stricter gate (greater than 60, or 120) SHALL NOT be used because it would suppress legitimate alarms whose samples are a genuine 60 seconds apart.

#### Scenario: Sub-minute sample interval produces no alarm

- **WHEN** a window's two in-horizon samples are separated by fewer than 60 seconds of real elapsed time, even if used% rose between them
- **THEN** the slope SHALL NOT be projected, no seconds-to-exhaust value SHALL be emitted, and no burn alarm SHALL be shown for that window

##### Example: a 2-second render burst with a used% jump shows no alarm

- GIVEN two persisted 5-hour-window samples `(t=1000s, used=40%)` and `(t=1002s, used=70%)` from a 2-second render burst
- WHEN the burn projection runs
- THEN the elapsed interval is 2 seconds, which is less than 60, the projection SHALL be skipped, and no depletion alarm SHALL be shown

#### Scenario: A genuine 60-second interval still projects

- **WHEN** a window's two in-horizon samples are separated by at least 60 seconds and the existing positive-slope and exhaust-before-reset gates pass
- **THEN** the projection SHALL proceed and emit the seconds-to-exhaust value as before

##### Example: an interval of exactly 60 seconds still alarms

- GIVEN two samples `(t=0s, used=50%)` and `(t=60s, used=80%)` whose projection exhausts the window before it resets
- WHEN the burn projection runs
- THEN the elapsed interval is 60 seconds, which satisfies the inclusive at-least-60 gate, and the alarm SHALL be produced
