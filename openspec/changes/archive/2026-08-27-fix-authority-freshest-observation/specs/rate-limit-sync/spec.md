## ADDED Requirements

### Requirement: Freshest-observation authority survives concurrent renders

The cross-session rate-limit reconciliation SHALL maintain exactly one authority record per window CLASS (five-hour and seven-day), persisted as `W5 <resets_at> <used> <auth_observed_at>` and `W7 <resets_at> <used> <auth_observed_at>` lines, where `<auth_observed_at>` is the wall-clock second (epoch seconds) at which the contributing session observed that value; it occupies the field the prior schema used for the authority's first-seen, so legacy lines compare without a migration step. Authority SHALL be held by the freshest OBSERVATION and SHALL NOT be held by the newest session start. A report SHALL override the stored class record, replacing key, value and observation time together, when its own observation time is at or after the stored record's (`report_observed_at >= auth_observed_at`), its own window key is live and sane, and its used% is numeric; otherwise the stored cache line SHALL be kept unchanged. The report's `first_seen` SHALL NOT enter this test, so a session with a smaller `first_seen` that has just observed a change SHALL override the value an idle newer session left behind. Adoption SHALL be direction-agnostic: a used% climbing normally, a used% dropping after the cap was raised, and a report carrying a new `resets_at` after a window roll are all adopted on the same test, so a cap raise SHALL NOT leave the display stuck on the obsolete higher value. Equal observation times SHALL resolve in favour of the later writer (the comparison is `>=`), which the serialization lock makes deterministic. The reconciliation SHALL preserve this rule under concurrent renders (no lost update), SHALL NOT TTL-prune the persisted authority, and SHALL keep the authority record after the contributing session has ended. When loading a cache that (abnormally) holds several live lines for one class, the loader SHALL keep the record with the newest `auth_observed_at` and drop the rest. The registry-retention TTL floor SHALL remain load-bearing under this rule: pruning a still-alive session's registry row erases its recorded pairs, so its next report would count as a first observation and could seize the authority with a stale value.

#### Scenario: An active older session overrides an idle newer session's stale authority

- **WHEN** the session holding a class record has gone idle (its reported pair is unchanged frame after frame) and a session with a smaller `first_seen` reports a pair that differs from the pair recorded in its own registry row
- **THEN** the older session's report SHALL replace the class record (key, value and observation time together) and the frames SHALL display the newly adopted value

##### Example: idle newest session stuck at 19 while an active older session observes 15

- GIVEN `now = 2000` and the cache holds `W7 900000 19 1500` plus `S idle 1800 - - - 900000 19 1500`
- AND session ACTIVE has `first_seen = 100`, its registry row records the seven-day pair `900000 19` observed at `1200`, and this frame it reports `used% = 15` for `resets_at = 900000`
- WHEN ACTIVE reconciles as a writable frame
- THEN ACTIVE's observation time SHALL be `2000` (its pair changed), the persisted line SHALL be `W7 900000 15 2000`, and the frames SHALL display `15`, never `19`

#### Scenario: A used% dropping after a cap raise is adopted

- **WHEN** a session reports a used% lower than the stored class record for a live window key, so the pair differs from the pair recorded in its own registry row
- **THEN** the lower value SHALL be adopted as the new class record with observation time `now`, and the previous higher value SHALL NOT be kept

##### Example: 47 recomputed down to 31 after a cap raise

- GIVEN `now = 1000` and the cache holds `W5 5000 47 800`
- AND session A's registry row records the five-hour pair `5000 47` observed at `800`, and this frame it reports `used% = 31` for the same key `5000`
- WHEN A reconciles as a writable frame
- THEN the persisted line SHALL be `W5 5000 31 1000` and the frame SHALL display `31`

#### Scenario: A window roll observed by any session is adopted

- **WHEN** any session reports a `resets_at` for a class that differs from the one recorded in its own registry row (the window rolled) and that key is live and sane
- **THEN** the report SHALL replace the class record entirely (new key, new used%, observation time `now`) whatever the reporting session's `first_seen` is, and the rolled window's record SHALL NOT survive alongside it

#### Scenario: An idle session cannot re-take authority with an unchanged pair

- **WHEN** a session whose reported pair is identical to the pair recorded in its own registry row reconciles against a class record whose `auth_observed_at` is newer than that session's carried-over observation time
- **THEN** its report SHALL NOT override the class record, even when its `first_seen` is the largest in the registry, and the stored cache line SHALL be kept unchanged

##### Example: the newest session idles while another session observed later

- GIVEN `now = 3000` and the cache holds `W5 5000 20 2500` plus `S idle 2400 5000 14 2400 - - -`
- AND session IDLE (`first_seen = 2400`, the largest in the registry) reports `used% = 14` for key `5000` again, unchanged
- WHEN IDLE reconciles as a writable frame
- THEN IDLE's carried-over observation time SHALL stay `2400`, the test `2400 >= 2500` SHALL fail, the persisted line SHALL remain `W5 5000 20 2500`, and IDLE's frame SHALL display `20`, never `14`

#### Scenario: Two sessions render concurrently on different classes

- **WHEN** session A and session B render at the same time, A contributing the seven-day class authority and B contributing the five-hour class authority
- **THEN** after both renders complete the shared cache SHALL contain both the `W5` and the `W7` record, and neither contribution SHALL be dropped

#### Scenario: A staler observation SHALL NOT clobber a fresher one during a concurrent write

- **WHEN** a session whose observation time is older renders concurrently with a session that has already (or simultaneously) written a fresher observation for the same window class
- **THEN** the final persisted class record SHALL be the fresher observation's, and the staler concurrent write SHALL NOT replace it with the outdated value

##### Example: a carried-over observation loses to one stamped this second

- GIVEN `now = 1000`, session STALE reports `used% = 12` for key `5000` with a carried-over observation time of `200`, and session FRESH reports `used% = 47` for the same key with its pair changed this frame (observation time `1000`)
- WHEN both frames reconcile against the shared cache, FRESH taking the lock first
- THEN the persisted line SHALL be `W5 5000 47 1000`, STALE's write SHALL leave it unchanged (`200 >= 1000` fails), and both frames SHALL display `47`

#### Scenario: The authority persists after the contributing session ends

- **WHEN** the session that contributed the current class record has ended and its registry row has been dropped by the retention TTL
- **THEN** the class record SHALL remain in the cache with its value and `auth_observed_at` intact, and SHALL keep being displayed until a fresher observation replaces it or its window rolls

---
### Requirement: Session registry rows carry each session's last reported pair per class

The session registry line SHALL persist, for each session, the last `(resets_at, used%)` pair it reported for each window class together with the wall-clock second at which that pair was first observed: `S <session_id> <first_seen> <r5> <u5> <o5> <r7> <u7> <o7>`, nine whitespace-separated fields on a single line. A class the session has never reported SHALL carry the placeholder `-` in all three of its fields. On each writable frame the reconciliation SHALL compare this frame's report for a class against the pair recorded in that session's own row: when the pair differs, the row SHALL be rewritten with the new pair and `observed_at = now`; when the pair is identical, the recorded `observed_at` SHALL be carried over unchanged, so re-rendering alone SHALL NOT refresh an observation; when no previous pair is recorded (a session rendering for the first time, or a legacy three-field row being upgraded) the observation time of that first report SHALL be the session's `first_seen`, so upgrading an old row SHALL NOT hand it the authority. A legacy three-field `S` row SHALL be accepted, treated as having no previous pair for either class, and rewritten in the nine-field form on the same rewrite. Only a writable frame (serialization lock held and a non-empty `session_id`) SHALL record observation state; a read-only frame SHALL leave every existing registry row intact and SHALL record nothing of its own. Registry rows SHALL remain subject to the `RL_REG_TTL` retention floor, and SHALL stay single-line, whitespace-separated, and parseable by `awk` under `LC_ALL=C` on bash 3.2.

#### Scenario: A changed pair stamps the row with the current second

- **WHEN** a writable frame reports a pair for a class that differs from the pair recorded in its own registry row
- **THEN** the rewritten row SHALL carry the new `(resets_at, used%)` for that class with `observed_at = now`

##### Example: the five-hour pair moves from 14 to 20

- GIVEN `now = 3000` and the cache holds `S sessA 1000 5000 14 2400 - - -`
- WHEN sessA reports `used% = 20` for key `5000` on a writable frame
- THEN the rewritten row SHALL be `S sessA 1000 5000 20 3000 - - -`

#### Scenario: An unchanged pair carries the recorded observation time over

- **WHEN** a writable frame reports a pair identical to the one recorded in its own registry row
- **THEN** the rewritten row SHALL keep that class's recorded `observed_at` unchanged, and this carried-over value SHALL be the observation time used in the authority comparison

#### Scenario: A legacy three-field row is upgraded without granting authority

- **WHEN** a writable frame's own registry row is a legacy `S <session_id> <first_seen>` line
- **THEN** its first report SHALL be stamped with that session's `first_seen` rather than `now`, the row SHALL be rewritten in the nine-field form, and a class record whose `auth_observed_at` is newer SHALL NOT be overridden by that first report

##### Example: an upgraded old row keeps the fresher record

- GIVEN `now = 3000` and the cache holds `S old 100` plus `W5 5000 20 2500`
- WHEN session `old` reports `used% = 14` for key `5000` on a writable frame
- THEN its first observation SHALL be stamped `100`, the test `100 >= 2500` SHALL fail, the persisted authority SHALL remain `W5 5000 20 2500`, and the rewritten registry row SHALL be `S old 100 5000 14 100 - - -`

## MODIFIED Requirements

### Requirement: Serialized read-modify-write with safe degradation on lock failure

The read-modify-write of the shared rate-limit cache SHALL be serialized so that concurrent writers do not clobber each other's authority updates. When the serialization lock cannot be acquired for the current frame, the frame SHALL degrade safely by skipping the cache write entirely, and SHALL STILL display the correct adopted authority value computed from the cache contents it read for the current frame. The reconciliation SHALL NEVER invoke `set -e`, SHALL run each helper background job with stdin redirected from `/dev/null`, SHALL keep `LC_ALL=C` pinned, and SHALL target bash 3.2 (no bash-4+ features).

#### Scenario: Lock acquired — serialized write proceeds

- **WHEN** a frame acquires the serialization lock before its read-modify-write of the cache
- **THEN** the frame SHALL read the current cache, apply this frame's report per the freshest-observation rule, write the survivors atomically, release the lock, and display the adopted value

##### Example: uncontended write persists this frame's authority

- GIVEN the cache holds `W5 5000 30 100` (its value observed at second `100`) and this frame's session reports `used% = 47` for the five-hour window `5000`, a pair that differs from the one recorded in its own registry row, so its observation time is `now = 900`
- WHEN the frame acquires the lock and performs its read-modify-write
- THEN the persisted line becomes `W5 5000 47 900`, the lock is released, and the frame displays `47`

#### Scenario: Lock contention — safe skip with correct display

- **WHEN** a frame cannot acquire the serialization lock (another writer holds it) within the frame's bounded attempt
- **THEN** the frame SHALL NOT write the cache (it SHALL skip the write for this frame, leaving the on-disk cache untouched by this frame)
- **AND** the frame SHALL STILL display the correct adopted authority value derived from the cache state it read, never a stale or empty value caused by the skipped write
- **AND** the frame SHALL complete normally without erroring out (no `set -e` abort, no partial line)

##### Example: contention degrades to read-only display, not a wrong number

- GIVEN the cache already holds `W5 5000 47 900` and this frame's session reports `used% = 12` for the five-hour window `5000`
- WHEN this frame fails to acquire the lock
- THEN this frame SHALL NOT rewrite the cache (the `W5 5000 47 900` line is preserved by whoever holds the lock)
- AND this frame SHALL display `47` (the adopted authority value it read), not `12` and not empty

---
### Requirement: Empty session id adopts read-only without destructive rewrite

When the session id is empty, the frame SHALL NOT perform a destructive rewrite of the shared rate-limit cache: an empty-session-id frame cannot be ranked for freshness and so SHALL contribute nothing to the authority, SHALL adopt the existing authority read-only for display — the value, and (per the window-roll adoption requirement) the authority's `resets_at` when the frame's own window key has rolled — and SHALL NOT write the cache back. The empty-session-id path SHALL leave every existing `S` (session registry) and `W5`/`W7` (class authority) line intact, and SHALL record no observation state of its own (no reported pair, no observation time).

#### Scenario: Empty session id — no cache write, value still adopted

- **WHEN** a frame is reconciled with an empty `session_id` while the cache already contains a class authority for the frame's window
- **THEN** the frame SHALL adopt and display that authority value for the window
- **AND** the frame SHALL NOT write the cache (no line is added, modified, removed, or rewritten)

#### Scenario: Empty session id contributes no registry or authority line

- **WHEN** a frame with an empty `session_id` reports a used% for an unexpired reset window
- **THEN** no registry line SHALL be created for the empty id, in either the legacy three-field `S <id> <first_seen>` form or the current nine-field form
- **AND** the reported used% SHALL NOT overwrite the existing class authority, even if the reported value is higher

##### Example: empty session id is read-only

- GIVEN the cache holds `S sessA 900` and `W5 5000 47 900`, `now = 1000`
- AND a frame arrives with `session_id = ""` reporting `used% = 80` for the five-hour window `5000`
- WHEN the frame reconciles
- THEN the on-disk cache SHALL remain exactly `S sessA 900` and `W5 5000 47 900` (unchanged)
- AND the frame SHALL display `47` for that window, never `80`

---
### Requirement: Registry retention TTL is clamped to a hard floor

The `RL_REG_TTL` configuration knob (session-registry retention, in seconds) SHALL be clamped at load time so it is never less than the longest reset window (604800 seconds, 7 days). A non-numeric or empty value SHALL be normalized to 604800. This prevents an under-sized retention from pruning the registry record of a session that is still alive within a reset window, which would otherwise erase that session's recorded per-class pairs together with its first-seen, so its next render would count as a first observation stamped `now` and could overwrite the window authority with a stale (typically lower) used%, under-reporting usage. The clamp SHALL be a floor only: a value larger than 604800 SHALL be preserved unchanged so longer future windows remain configurable.

#### Scenario: An undersized RL_REG_TTL is raised to the floor

- **WHEN** `RL_REG_TTL` is configured to a value below 604800 (for example 3600), or to a non-numeric value
- **THEN** the effective retention SHALL be 604800, and a still-alive session whose first-seen is older than the configured value SHALL retain its registry record and SHALL NOT be re-ranked as a new session

##### Example: a 5-hour-old live session must not be re-ranked as new

- GIVEN `RL_REG_TTL` is configured to 3600 (one hour)
- AND session OLD has `first_seen = now - 18000` (5 hours ago) and is still rendering
- WHEN OLD reconciles after the clamp is applied
- THEN the effective TTL SHALL be 604800, OLD's registry record SHALL survive (because `now - 18000 > now - 604800`) with its recorded pairs and observation times intact, and OLD SHALL NOT acquire a fresh `first_seen = now` that would stamp its next report as a first observation at `now` and let a stale value seize window authority

#### Scenario: A larger RL_REG_TTL is preserved

- **WHEN** `RL_REG_TTL` is configured to a value greater than 604800
- **THEN** the effective retention SHALL remain that larger value unchanged

---
### Requirement: Malformed and old-format cache lines are silently dropped

The reconciliation's single `awk` pass SHALL recognize a cache line only when its leading tag is `S`, `W5`, `W7`, or `P`, its field count is exactly 9 for a current-format `S`, exactly 3 for a legacy `S`, or exactly 4 for `W5`/`W7`/`P`, and its window-key field is numeric (and, for `P`, its timestamp and used fields are numeric as well). In a nine-field `S` row each class triple SHALL be either three `-` placeholders or a numeric `<resets_at> <used> <observed_at>` triple; a row mixing a placeholder with numbers inside one class triple SHALL be dropped like any other malformed line. Any other line — a blank line, a line whose first field is not a recognized tag (including the legacy untagged `W` authority lines from the prior cache schema), a recognized tag with the wrong field count, or a line carrying a non-numeric value where a number is required — SHALL be silently dropped and SHALL NOT be carried forward to the rewritten cache. Dropping a malformed line SHALL NOT raise an error or abort the frame (no `set -e`); the line is simply omitted from the survivors written to the per-pid temp file.

#### Scenario: Old-format and wrong-arity lines are not carried forward

- **WHEN** a writable frame rewrites a cache that contains, alongside valid lines, a legacy `W <resets_at> <used> <fs>` line from the prior schema and a recognized-tag line with the wrong field count
- **THEN** only the well-formed `S`/`W5`/`W7`/`P` lines (plus this frame's own valid contributions) SHALL appear in the rewritten cache, and every malformed or old-format line SHALL be absent

##### Example: a legacy untagged W line and a wrong-arity line are dropped

- GIVEN `now = 1000`, and the cache holds a valid `W5 5000 47 900`, a legacy `W 5000 47 900` (untagged old schema), and a malformed `W5 5000 47` (three fields, not four)
- WHEN a writable frame rewrites the cache
- THEN the survivors SHALL retain `W5 5000 47 900`, and SHALL NOT contain the legacy `W 5000 47 900` or the three-field `W5 5000 47` line

#### Scenario: A nine-field S row survives while a wrong-arity S row is dropped

- **WHEN** a writable frame rewrites a cache holding a well-formed nine-field `S` row, a legacy three-field `S` row, and an `S` row with some other field count
- **THEN** the nine-field row SHALL survive with its recorded pairs and observation times, the legacy row SHALL survive as an upgraded nine-field row, and the wrong-arity row SHALL be absent from the rewritten cache

##### Example: five-field S row is dropped, three-field and nine-field rows survive

- GIVEN `now = 3000`, and the cache holds `S nine 1000 5000 20 2500 - - -`, `S three 1200`, and `S broken 1300 5000 20`
- WHEN a writable frame rewrites the cache
- THEN the survivors SHALL contain `S nine 1000 5000 20 2500 - - -` and a nine-field row for `three` carrying `first_seen = 1200`, and SHALL NOT contain any row for `broken`

---
### Requirement: Burn-projection sample series persists as a third cache line type

The shared rate-limit cache (`~/.claude/sl-ratelimit-cache`) SHALL support a third line type `P <resets_at> <timestamp> <used>` alongside the `S` (session registry) and `W5`/`W7` (per-class window authority) lines. Each `P` line records one burn-projection sample: the adopted used% (`<used>`) observed at wall-clock second `<timestamp>` for the reset window keyed by `<resets_at>`. On each writable rewrite the reconciliation (`_reconcile_core`) SHALL append one fresh `P` sample for the five-hour class using the ADOPTED authority value and the ADOPTED (effective) five-hour window key — the reconciled class record's `resets_at`, which equals the frame's own `five_reset` whenever that snapshot is live — never the frame's own reported value, which lags behind while the session idles. The rewrite SHALL retain at most `MAXSAMP` (5) samples per reset window, keeping the newest by timestamp in chronological order and dropping the oldest when a window exceeds five samples. A `P` line whose `<timestamp>` is at or older than the sampling horizon (`HORIZON` = 10800 seconds, ~3 hours) — i.e. `timestamp <= now - HORIZON` — SHALL be dropped on the next rewrite. The `P` series SHALL be maintained only when `RL_SYNC` is true. A read-only frame — one that skips the cache rewrite because of lock contention or an empty `session_id` — SHALL leave every existing `P` line on disk intact.

#### Scenario: Writable frame appends a 5h sample and bounds the series to MAXSAMP

- **WHEN** a writable frame (lock held, non-empty `session_id`, `RL_SYNC` true) reconciles a five-hour class whose adopted authority is present, and the cache already holds `MAXSAMP` (5) in-horizon `P` samples for that window key
- **THEN** the rewrite SHALL append one new `P <effective_resets_at> <now> <adopted-used%>` line, drop the single oldest sample for that window, and persist exactly five `P` lines for that window (the newest five by timestamp, in chronological order)

##### Example: sixth sample evicts the oldest

- GIVEN `RL_SYNC=true`, `now = 1000`, live five-hour key `resets_at = 5000`, and the cache holds `W5 5000 40 900` plus `P 5000 100 30`, `P 5000 200 32`, `P 5000 300 35`, `P 5000 400 38`, `P 5000 500 40` (five samples, all inside the 10800s horizon)
- AND this writable frame adopts `used% = 42` for the five-hour class
- WHEN it rewrites the cache
- THEN it SHALL append `P 5000 1000 42`, drop the oldest `P 5000 100 30`, and the persisted `P 5000` lines SHALL be exactly the five samples at timestamps `200, 300, 400, 500, 1000`

#### Scenario: A frozen frame samples under the effective key

- **WHEN** a writable frame whose own five-hour `resets_at` is expired adopts the live five-hour class authority
- **THEN** its appended `P` sample SHALL be keyed by the adopted authority's `resets_at`, not by the frame's own expired key

#### Scenario: Read-only frame leaves existing P lines intact

- **WHEN** a frame is read-only for the rate-limit cache — either its `session_id` is empty, or it fails to acquire the serialization lock within its bounded attempt — while the cache already holds one or more `P` lines
- **THEN** the frame SHALL NOT rewrite the cache, and every existing `P` line SHALL remain on disk byte-for-byte unchanged

##### Example: empty session id does not disturb the P series

- GIVEN the cache holds `S sessA 900`, `W5 5000 47 900`, and `P 5000 500 47`, with `now = 1000`
- AND a frame arrives with `session_id = ""` reporting `used% = 80` for key `5000`
- WHEN the frame reconciles read-only
- THEN the on-disk cache SHALL still contain `P 5000 500 47` unchanged (and `S sessA 900`, `W5 5000 47 900` unchanged), and no new `P` line SHALL be persisted

---
### Requirement: RL_SYNC master toggle gates the entire reconciliation

The `RL_SYNC` configuration knob SHALL act as a master switch for the cross-session rate-limit reconciliation. When `RL_SYNC` is true (the default), the frame SHALL run `reconcile_start` / `reconcile_read`, share and adopt the cross-session authority through the cache, and maintain the burn-projection `P` series. When `RL_SYNC` is false, the frame SHALL skip the entire reconciliation: `reconcile_start` SHALL NOT launch the background reconcile job, `reconcile_read` SHALL NOT read or adopt any cached value, no read or write of `~/.claude/sl-ratelimit-cache` (or its lock) SHALL occur, and the frame SHALL display its own `parse_input`-derived used% — the last value this session observed, which goes stale while the session idles — for both the five-hour and seven-day windows. With `RL_SYNC` false the burn-projection alarm SHALL be silent (`burn_tte` empty), because no reconciled sample series is maintained to project from.

#### Scenario: Sync disabled trusts the frame's own frozen value

- **WHEN** `RL_SYNC` is false
- **THEN** the frame SHALL NOT open the rate-limit cache, SHALL keep its own parsed `five_h` / `seven_d` used% unchanged, and SHALL emit no burn-projection alarm

##### Example: frozen used% is shown verbatim with sync off

- GIVEN `RL_SYNC=false`, this frame's `parse_input` `five_h = 12` (the last value this session observed, now stale), and a cache on disk that holds `W 5000 47 900`
- WHEN the frame renders
- THEN `reconcile_start` SHALL return early (no background job), `reconcile_read` SHALL return early, the cache file SHALL NOT be opened, `five_h` SHALL remain `12` (never adopting the cached `47`), and `burn_tte` SHALL be empty

#### Scenario: Sync enabled runs the full reconcile

- **WHEN** `RL_SYNC` is true and a rankable non-empty `session_id` is present
- **THEN** the frame SHALL launch the background reconcile, read the cache, adopt the freshest-observation authority, and maintain the `P` sample series per the cross-session rules

## REMOVED Requirements

### Requirement: Newest-session authority survives concurrent renders

**Reason**: The rule ranked authority by session start (`first_seen >= auth_first_seen`), on the premise that Claude Code freezes `rate_limits` at session start so the newest session must hold the truest value. End-to-end reproduction on 2026-08-27 refuted that premise: within one 44-minute session the cache's five-hour value moved 14 to 20 and the seven-day value moved 85 to 86 while that session stayed the authority, so Claude Code refreshes a session's `rate_limits` on each API round trip. Session age therefore no longer tracks truth: once the newest-started session goes idle it freezes the display on its last value, while older sessions that are actively used observe the true value and are blocked from writing it (observed as `4D14H 19%` on the statusline against `4D14H 15%` in `/usage`).

**Migration**: Replaced by `Requirement: Freshest-observation authority survives concurrent renders`, which ranks a report by when its `(resets_at, used%)` pair was last observed to change instead of by the reporting session's start. The persisted authority line keeps its shape; only the meaning of its fourth field changes from `auth_first_seen` to `auth_observed_at` (both epoch seconds), so existing cache lines compare correctly and transition on the first reconcile without a migration step. Every other guarantee of the removed requirement (one record per class, no lost update under concurrent renders, adoption in both directions, no TTL-pruning of the authority, newest record wins when several live lines exist for one class) is carried over by the replacement.

#### Scenario: The retired session-age ranking is no longer applied

- **WHEN** a report is compared against a stored class record after this change ships
- **THEN** the comparison SHALL use the observation times, and the reporting session's `first_seen` SHALL NOT decide the outcome
