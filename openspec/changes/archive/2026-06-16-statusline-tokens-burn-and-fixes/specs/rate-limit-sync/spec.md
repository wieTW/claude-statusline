## ADDED Requirements

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
