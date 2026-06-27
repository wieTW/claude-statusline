## ADDED Requirements

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
