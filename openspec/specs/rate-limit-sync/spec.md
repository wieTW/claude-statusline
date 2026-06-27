# rate-limit-sync Specification

## Purpose

TBD - created by archiving change 'statusline-tokens-burn-and-fixes'. Update Purpose after archive.

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