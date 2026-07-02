## ADDED Requirements

### Requirement: Burn-projection sample series persists as a third cache line type

The shared rate-limit cache (`~/.claude/sl-ratelimit-cache`) SHALL support a third line type `P <resets_at> <timestamp> <used>` alongside the `S` (session registry) and `W` (window authority) lines. Each `P` line records one burn-projection sample: the adopted used% (`<used>`) observed at wall-clock second `<timestamp>` for the reset window keyed by `<resets_at>`. On each writable rewrite the reconciliation (`_reconcile_core`) SHALL append one fresh `P` sample for the five-hour window using the ADOPTED authority value (the reconciled `W` value, never the frame's frozen start-snapshot report) and SHALL retain at most `MAXSAMP` (5) samples per reset window, keeping the newest by timestamp in chronological order and dropping the oldest when a window exceeds five samples. A `P` line whose `<timestamp>` is at or older than the sampling horizon (`HORIZON` = 10800 seconds, ~3 hours) — i.e. `timestamp <= now - HORIZON` — SHALL be dropped on the next rewrite. The `P` series SHALL be maintained only when `RL_SYNC` is true, since the entire reconcile is gated on that toggle. A read-only frame — one that skips the cache rewrite because of lock contention or an empty `session_id` — SHALL leave every existing `P` line on disk intact (it appends its sample only to a discarded per-pid temp, never to the persisted cache).

#### Scenario: Writable frame appends a 5h sample and bounds the series to MAXSAMP

- **WHEN** a writable frame (lock held, non-empty `session_id`, `RL_SYNC` true) reconciles a five-hour window whose adopted authority is present, and the cache already holds `MAXSAMP` (5) in-horizon `P` samples for that window
- **THEN** the rewrite SHALL append one new `P <resets_at> <now> <adopted-used%>` line, drop the single oldest sample for that window, and persist exactly five `P` lines for that window (the newest five by timestamp, in chronological order)

##### Example: sixth sample evicts the oldest

- GIVEN `RL_SYNC=true`, `now = 1000`, five-hour window `resets_at = 5000` (unexpired), and the cache holds `W 5000 40 900` plus `P 5000 100 30`, `P 5000 200 32`, `P 5000 300 35`, `P 5000 400 38`, `P 5000 500 40` (five samples, all inside the 10800s horizon)
- AND this writable frame adopts `used% = 42` for window `5000`
- WHEN it rewrites the cache
- THEN it SHALL append `P 5000 1000 42`, drop the oldest `P 5000 100 30`, and the persisted `P 5000` lines SHALL be exactly the five samples at timestamps `200, 300, 400, 500, 1000`

#### Scenario: Read-only frame leaves existing P lines intact

- **WHEN** a frame is read-only for the rate-limit cache — either its `session_id` is empty, or it fails to acquire the serialization lock within its bounded attempt — while the cache already holds one or more `P` lines
- **THEN** the frame SHALL NOT rewrite the cache, and every existing `P` line SHALL remain on disk byte-for-byte unchanged (the freshly computed sample is written only to a per-pid temp that is removed, never moved over the cache)

##### Example: empty session id does not disturb the P series

- GIVEN the cache holds `S sessA 900`, `W 5000 47 900`, and `P 5000 500 47`, with `now = 1000`
- AND a frame arrives with `session_id = ""` reporting `used% = 80` for window `5000`
- WHEN the frame reconciles read-only
- THEN the on-disk cache SHALL still contain `P 5000 500 47` unchanged (and `S sessA 900`, `W 5000 47 900` unchanged), and no new `P` line SHALL be persisted

---
### Requirement: RL_SYNC master toggle gates the entire reconciliation

The `RL_SYNC` configuration knob SHALL act as a master switch for the cross-session rate-limit reconciliation. When `RL_SYNC` is true (the default), the frame SHALL run `reconcile_start` / `reconcile_read`, share and adopt the cross-session authority through the cache, and maintain the burn-projection `P` series. When `RL_SYNC` is false, the frame SHALL skip the entire reconciliation: `reconcile_start` SHALL NOT launch the background reconcile job, `reconcile_read` SHALL NOT read or adopt any cached value, no read or write of `~/.claude/sl-ratelimit-cache` (or its lock) SHALL occur, and the frame SHALL display its own `parse_input`-derived used% — which can be a frozen start-snapshot value — for both the five-hour and seven-day windows. With `RL_SYNC` false the burn-projection alarm SHALL be silent (`burn_tte` empty), because no reconciled sample series is maintained to project from.

#### Scenario: Sync disabled trusts the frame's own frozen value

- **WHEN** `RL_SYNC` is false
- **THEN** the frame SHALL NOT open the rate-limit cache, SHALL keep its own parsed `five_h` / `seven_d` used% unchanged, and SHALL emit no burn-projection alarm

##### Example: frozen used% is shown verbatim with sync off

- GIVEN `RL_SYNC=false`, this frame's `parse_input` `five_h = 12` (a frozen start-snapshot value), and a cache on disk that holds `W 5000 47 900`
- WHEN the frame renders
- THEN `reconcile_start` SHALL return early (no background job), `reconcile_read` SHALL return early, the cache file SHALL NOT be opened, `five_h` SHALL remain `12` (never adopting the cached `47`), and `burn_tte` SHALL be empty

#### Scenario: Sync enabled runs the full reconcile

- **WHEN** `RL_SYNC` is true and a rankable non-empty `session_id` is present
- **THEN** the frame SHALL launch the background reconcile, read the cache, adopt the newest-session authority, and maintain the `P` sample series per the cross-session rules

---
### Requirement: A stale reconcile lock is stolen and re-acquired

The serialization lock — `~/.claude/sl-ratelimit-cache.lock`, an `mkdir`-created directory — SHALL be steal-able when its holder has died mid-frame. During bounded lock acquisition inside `_reconcile_core`, when a `mkdir` attempt fails and the existing lock directory's modification time is strictly older than `RL_LOCK_STALE` seconds (`now - lock_mtime > RL_LOCK_STALE`), the reconciliation SHALL remove the stale lock directory with `rmdir` and immediately re-attempt `mkdir` to acquire it. A lock directory younger than or exactly `RL_LOCK_STALE` seconds SHALL NOT be stolen; the frame SHALL instead back off `RL_LOCK_WAIT` seconds and retry, up to `RL_LOCK_TRIES` total attempts, before degrading to a read-only (skip-write) frame that still adopts and displays the authority it read. The steal path SHALL NOT invoke `set -e` and SHALL tolerate a losing race (another frame's `rmdir`/`mkdir` won the steal) by continuing its bounded retry without erroring.

#### Scenario: Stale lock older than RL_LOCK_STALE is stolen

- **WHEN** a writable frame's initial `mkdir` on the lock fails, and the existing lock directory's mtime is older than `RL_LOCK_STALE` seconds relative to the frame's `now`
- **THEN** the frame SHALL `rmdir` the stale lock and re-`mkdir` it, acquiring the lock and proceeding to the serialized read-modify-write

##### Example: a 20-second-old lock is stolen at the 10-second threshold

- GIVEN `now = 1000`, `RL_LOCK_STALE = 10`, and the lock directory exists with mtime `980` (age `20 > 10`)
- WHEN a writable frame fails its first `mkdir`
- THEN it SHALL `rmdir` the lock and re-`mkdir` it, acquire it, and continue the frame's read-modify-write

#### Scenario: Fresh lock is not stolen

- **WHEN** the existing lock directory's mtime is within `RL_LOCK_STALE` seconds of `now`
- **THEN** the frame SHALL NOT remove it, SHALL back off `RL_LOCK_WAIT` and retry up to `RL_LOCK_TRIES` times, and on exhausting the attempts SHALL degrade to a read-only frame that still displays the adopted authority it read

##### Example: a 5-second-old lock is left alone

- GIVEN `now = 1000`, `RL_LOCK_STALE = 10`, and the lock directory exists with mtime `995` (age `5`, not `> 10`)
- WHEN a writable frame fails its `mkdir`
- THEN it SHALL leave the lock in place, sleep `RL_LOCK_WAIT`, and retry rather than steal

---
### Requirement: Expired reset windows are pruned on rewrite

On each cache rewrite, the reconciliation SHALL drop every `W` and `P` line whose `<resets_at>` is less than or equal to the frame's `now` (the reset window has rolled). An expired window's authority value SHALL NOT be reloaded, re-emitted, or carried forward to the rewritten cache, and this frame's own report for an expired window SHALL NOT be folded into the authority. Only unexpired windows (`resets_at > now`) SHALL survive to the rewritten cache. `S` registry lines are governed instead by the separate `RL_REG_TTL` retention floor and SHALL NOT be pruned by this window-expiry test.

#### Scenario: Expired W and P lines are dropped, unexpired kept

- **WHEN** a writable frame rewrites a cache that holds authority and sample lines for both an already-rolled window (`resets_at <= now`) and a still-live window (`resets_at > now`)
- **THEN** the survivors SHALL contain the live window's `W` and `P` lines and SHALL NOT contain the rolled window's `W` or `P` lines

##### Example: a rolled window is discarded while the live one persists

- GIVEN `now = 1000`, and the cache holds `W 5000 47 900`, `W 300 60 800`, `P 5000 500 47`, and `P 300 400 60`
- WHEN a writable frame rewrites the cache
- THEN window `300` is expired (`300 <= 1000`) so `W 300 60 800` and `P 300 400 60` SHALL be dropped, while window `5000` is unexpired (`5000 > 1000`) so `W 5000 ...` and `P 5000 ...` SHALL survive

---
### Requirement: Malformed and old-format cache lines are silently dropped

The reconciliation's single `awk` pass SHALL recognize a cache line only when its leading tag is `S`, `W`, or `P`, its field count is exactly 3 for `S` or exactly 4 for `W`/`P`, and its window-key field is numeric (and, for `P`, its timestamp and used fields are numeric as well). Any other line — a blank line, a line whose first field is not `S`/`W`/`P`, a recognized tag with the wrong field count, an old-format line left by a prior cache schema, or a line carrying a non-numeric value where a number is required — SHALL be silently dropped and SHALL NOT be carried forward to the rewritten cache. Dropping a malformed line SHALL NOT raise an error or abort the frame (no `set -e`); the line is simply omitted from the survivors written to the per-pid temp file.

#### Scenario: Old-format and wrong-arity lines are not carried forward

- **WHEN** a writable frame rewrites a cache that contains, alongside valid lines, a line from an obsolete schema and a recognized-tag line with the wrong field count
- **THEN** only the well-formed `S`/`W`/`P` lines (plus this frame's own valid contributions) SHALL appear in the rewritten cache, and every malformed or old-format line SHALL be absent

##### Example: a legacy 3-field W line and a bare tag are dropped

- GIVEN `now = 1000`, and the cache holds a valid `W 5000 47 900`, an old-format line `R 5000 47` (unrecognized tag), and a malformed `W 5000 47` (three fields, not four)
- WHEN a writable frame rewrites the cache
- THEN the survivors SHALL retain `W 5000 47 900`, and SHALL NOT contain `R 5000 47` or the three-field `W 5000 47` line

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - lib/collect.sh
  - statusline-command.sh
  - tests/run-tests.sh
-->

