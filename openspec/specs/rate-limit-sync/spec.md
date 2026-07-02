# rate-limit-sync Specification

## Purpose

The rate-limit-sync capability defines how the true rate-limit usage percentage is shared across concurrent sessions through a lock-serialized cache, correcting Claude Code's frozen per-session start snapshot. It owns the "newest session is the authority" rule, the mkdir spin-lock with stale-steal, the empty-session-id read-only path, and the registry-retention TTL floor that keeps a still-alive session from being re-ranked as new.

## Requirements

### Requirement: Newest-session authority survives concurrent renders

The cross-session rate-limit reconciliation SHALL preserve the "newest session is the authority" rule under concurrent renders: for each reset window, the persisted `(used%, authority_first_seen)` pair MUST reflect the contribution of the session with the latest first-seen time, and a concurrent render by another session MUST NOT cause a legitimate authority update to be lost (no lost-update). A report SHALL override the stored window value only when its session is newer-or-equal (`first_seen >= authority_first_seen`); an older session SHALL NOT overwrite it. The reconciliation SHALL remain correct in both directions (used% climbing and used% dropping after a cap raise) and SHALL NOT TTL-prune the persisted authority value.

#### Scenario: Two sessions render concurrently with distinct windows

- **WHEN** session A (older first-seen) and session B (newer first-seen) render at the same time, A contributing an authority value for its five-hour window and B contributing an authority value for a different five-hour window (distinct `resets_at` keys)
- **THEN** after both renders complete the shared cache SHALL contain both window authority lines, neither contribution SHALL be dropped, and each window SHALL retain the value set by the session that owns it

#### Scenario: Older session SHALL NOT clobber a newer authority during a concurrent write

- **WHEN** an older frozen session renders concurrently with a newer session that has already (or simultaneously) written a higher-or-different authority for the same reset window
- **THEN** the final persisted window value SHALL be the newer session's value, and the older session's concurrent write SHALL NOT replace it with the stale value

##### Example: old frozen-low session racing a newer higher-value session

- GIVEN `now = 1000`, reset window key `resets_at = 5000` (unexpired, `> now`)
- AND session OLD has `first_seen = 100` and reports `used% = 12` (frozen low at its start snapshot)
- AND session NEW has `first_seen = 900` and reports `used% = 47` (true current value)
- WHEN OLD and NEW both reconcile against the shared cache concurrently
- THEN the persisted `W 5000` line SHALL be `W 5000 47 900` (NEW's value and first_seen win because `900 >= 100`)
- AND OLD's frame SHALL display `47` for that window, never `12`, because OLD adopts the authority it reads rather than its own frozen value


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
### Requirement: Serialized read-modify-write with safe degradation on lock failure

The read-modify-write of the shared rate-limit cache SHALL be serialized so that concurrent writers do not clobber each other's authority updates. When the serialization lock cannot be acquired for the current frame, the frame SHALL degrade safely by skipping the cache write entirely, and SHALL STILL display the correct adopted authority value computed from the cache contents it read for the current frame. The reconciliation SHALL NEVER invoke `set -e`, SHALL run each helper background job with stdin redirected from `/dev/null`, SHALL keep `LC_ALL=C` pinned, and SHALL target bash 3.2 (no bash-4+ features).

#### Scenario: Lock acquired — serialized write proceeds

- **WHEN** a frame acquires the serialization lock before its read-modify-write of the cache
- **THEN** the frame SHALL read the current cache, apply this frame's report per the newest-session rule, write the survivors atomically, release the lock, and display the adopted value

##### Example: uncontended write persists this frame's authority

- GIVEN the cache holds `W 5000 30 100` and this frame's session has `first_seen = 900` reporting `used% = 47` for window `5000`
- WHEN the frame acquires the lock and performs its read-modify-write
- THEN the persisted line becomes `W 5000 47 900`, the lock is released, and the frame displays `47`

#### Scenario: Lock contention — safe skip with correct display

- **WHEN** a frame cannot acquire the serialization lock (another writer holds it) within the frame's bounded attempt
- **THEN** the frame SHALL NOT write the cache (it SHALL skip the write for this frame, leaving the on-disk cache untouched by this frame)
- **AND** the frame SHALL STILL display the correct adopted authority value derived from the cache state it read, never a stale or empty value caused by the skipped write
- **AND** the frame SHALL complete normally without erroring out (no `set -e` abort, no partial line)

##### Example: contention degrades to read-only display, not a wrong number

- GIVEN the cache already holds `W 5000 47 900` and this frame's session reports `used% = 12` for window `5000`
- WHEN this frame fails to acquire the lock
- THEN this frame SHALL NOT rewrite the cache (the `W 5000 47 900` line is preserved by whoever holds the lock)
- AND this frame SHALL display `47` (the adopted authority value it read), not `12` and not empty


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
### Requirement: Empty session id adopts read-only without destructive rewrite

When the session id is empty, the frame SHALL NOT perform a destructive rewrite of the shared rate-limit cache: an empty-session-id frame cannot be ranked for freshness and so SHALL contribute nothing to the authority, SHALL adopt the existing authority value read-only for display, and SHALL NOT write the cache back. The empty-session-id path SHALL leave every existing `S` (session registry) and `W` (window authority) line intact.

#### Scenario: Empty session id — no cache write, value still adopted

- **WHEN** a frame is reconciled with an empty `session_id` while the cache already contains a window authority for the frame's reset window
- **THEN** the frame SHALL adopt and display that authority value for the window
- **AND** the frame SHALL NOT write the cache (no line is added, modified, removed, or rewritten)

#### Scenario: Empty session id contributes no registry or authority line

- **WHEN** a frame with an empty `session_id` reports a used% for an unexpired reset window
- **THEN** no `S <id> <first_seen>` registry line SHALL be created for the empty id
- **AND** the reported used% SHALL NOT overwrite the existing window authority, even if the reported value is higher

##### Example: empty session id is read-only

- GIVEN the cache holds `S sessA 900` and `W 5000 47 900`, `now = 1000`
- AND a frame arrives with `session_id = ""` reporting `used% = 80` for window `5000`
- WHEN the frame reconciles
- THEN the on-disk cache SHALL remain exactly `S sessA 900` and `W 5000 47 900` (unchanged)
- AND the frame SHALL display `47` for window `5000`, never `80`


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
### Requirement: Reconciliation respects the parse_input sanitization and cap contract

The rate-limit sync SHALL consume only the already-sanitized `session_id`, `five_h`, `seven_d`, `five_reset`, and `seven_reset` globals produced by `parse_input`, which is the single input-sanitization entry point whose `read` order is positional one-for-one with the jq array and whose 256-codepoint per-field cap is load-bearing. The reconciliation SHALL NOT introduce a second sanitization path for these fields and SHALL NOT relax the 256-codepoint cap. Adopted values written back to `five_h` / `seven_d` SHALL be validated as numeric (digits and at most one dot) before adoption; a non-numeric or empty reconciled value SHALL leave this frame's own parsed value unchanged.

#### Scenario: Non-numeric reconciled output leaves the frame's own value

- **WHEN** the reconciliation emits an empty or non-numeric value for a window (for example because the awk pass or atomic move failed under a read-only HOME)
- **THEN** the frame SHALL keep its own `parse_input`-derived used% for that window unchanged and SHALL render it without erroring

##### Example: numeric guard on adoption

- GIVEN the reconciliation emits `47.5|` (five-hour `47.5`, seven-day empty)
- WHEN the adoption guard runs
- THEN `five_h` SHALL be set to `47.5` (matches digits-with-one-dot)
- AND `seven_d` SHALL retain its original `parse_input` value (empty reconciled field is rejected, not adopted)

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
### Requirement: Cache overwrite requires a successfully produced temp file

The cross-session rate-limit reconciliation SHALL NOT overwrite the shared cache (`~/.claude/sl-ratelimit-cache`) with an empty or partially-written temp file. Before the atomic `mv` that replaces the cache, the reconciliation MUST confirm the per-pid temp file is non-empty (the awk pass produced its survivor lines). When the awk pass fails or yields an empty temp file, the reconciliation SHALL leave the existing on-disk cache unchanged and SHALL still emit this frame's adopted values, never destroying the cross-session authority that prior sessions persisted. This gate is in addition to the existing lock-held and non-empty-session_id conditions, not a replacement for them.

#### Scenario: awk failure leaves the authority cache intact

- **WHEN** a writable frame holds the reconcile lock and a non-empty session_id, but the awk pass fails or produces an empty temp file
- **THEN** the shared cache file SHALL retain its prior contents (the existing W/S/P lines), the reconciliation SHALL NOT replace it with the empty temp file, and the frame SHALL still display the values it read

##### Example: empty temp file must not clobber a populated cache

- GIVEN the shared cache holds a valid authority line `W 5000 47 900`
- AND a render's awk pass produces an empty temp file (a simulated failure)
- WHEN the reconciliation reaches the overwrite step
- THEN the `mv` SHALL be skipped because the temp file is empty
- AND the cache SHALL still contain `W 5000 47 900` after the frame


<!-- @trace
source: statusline-correctness-guards
updated: 2026-06-27
code:
  - tests/run-tests.sh
  - lib/collect.sh
  - statusline-command.sh
-->

---
### Requirement: Registry retention TTL is clamped to a hard floor

The `RL_REG_TTL` configuration knob (session-registry retention, in seconds) SHALL be clamped at load time so it is never less than the longest reset window (604800 seconds, 7 days). A non-numeric or empty value SHALL be normalized to 604800. This prevents an under-sized retention from pruning the registry record of a session that is still alive within a reset window, which would otherwise cause that session, on its next render, to be ranked as brand-new and overwrite the window authority with its frozen (typically lower) used%, under-reporting usage. The clamp SHALL be a floor only: a value larger than 604800 SHALL be preserved unchanged so longer future windows remain configurable.

#### Scenario: An undersized RL_REG_TTL is raised to the floor

- **WHEN** `RL_REG_TTL` is configured to a value below 604800 (for example 3600), or to a non-numeric value
- **THEN** the effective retention SHALL be 604800, and a still-alive session whose first-seen is older than the configured value SHALL retain its registry record and SHALL NOT be re-ranked as a new session

##### Example: a 5-hour-old live session must not be re-ranked as new

- GIVEN `RL_REG_TTL` is configured to 3600 (one hour)
- AND session OLD has `first_seen = now - 18000` (5 hours ago) and is still rendering
- WHEN OLD reconciles after the clamp is applied
- THEN the effective TTL SHALL be 604800, OLD's registry record SHALL survive (because `now - 18000 > now - 604800`), and OLD SHALL NOT acquire a fresh `first_seen = now` that would let its frozen report seize window authority

#### Scenario: A larger RL_REG_TTL is preserved

- **WHEN** `RL_REG_TTL` is configured to a value greater than 604800
- **THEN** the effective retention SHALL remain that larger value unchanged

<!-- @trace
source: statusline-correctness-guards
updated: 2026-06-27
code:
  - tests/run-tests.sh
  - lib/collect.sh
  - statusline-command.sh
-->

---
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
