# shellcheck shell=bash
# shellcheck disable=SC2034  # globals written here are consumed by the sibling render.sh (see WRITES header); lint via: shellcheck -x statusline-command.sh
# collect.sh — input collection: stdin JSON parsing + theme / width / git / effort collected concurrently in the background
#
# READS : stdin (statusline JSON), $HOME/.claude.json, $HOME/.claude/settings.json, transcript
# WRITES: cwd project_dir model session_name used_pct worktree_name effort thinking
#         five_h seven_d five_reset seven_reset session_id transcript_path exceeds_200k dur_ms api_ms now act_epoch
#         git_branch git_dirty git_ins git_del effort_mode _theme term_cols
#         ctx_in_tok ctx_cc_tok ctx_cr_tok ctx_out_tok ctx_win_size
#         session_tokens subagent_tokens burn_tte
#         quota_label quota_pct quota_sev quota_at
#
# Sync model: background jobs run via process substitution opening an FD; a read blocks until that job hits EOF, which is the
# sync point — no wait / temp file needed. Jobs are independent and run in parallel, so wall-clock = the slowest one, not the sum.
# Hard rule: every background job gets </dev/null (a job inherits the stdin JSON pipe; only parse_input's jq is allowed to read it).


# t=0: start the theme background job first; it doesn't depend on stdin and fully overlaps parse_input's jq parsing
start_theme_job() {
    exec 3< <(resolve_theme </dev/null)
}

# Theme follows /theme: written to ~/.claude.json (settings.json as fallback); always emits one line.
# ~/.claude.json may be mid-rewrite by Claude Code (torn read) → on jq parse failure fall through the fallback chain, affecting only one frame.
resolve_theme() {
    local t
    t=$(jq -r '.theme // empty' "$HOME/.claude.json" 2>/dev/null)
    [ -n "$t" ] || t=$(jq -r '.theme // "dark"' "$HOME/.claude/settings.json" 2>/dev/null)
    printf '%s\n' "$t"
}

read_theme() {
    _theme=""
    IFS= read -r _theme <&3 || :
    exec 3<&-
}


# t=0: at the same time start the terminal-width background job (for the right-align gap); doesn't depend on stdin, fully overlaps theme/jq
start_width_job() {
    $RIGHT_ALIGN || return 0
    exec 8< <(resolve_width </dev/null)
}

# Width source: prefer stty's live value (a terminal resize is reflected on the next frame), trust COLUMNS only on failure
# (it may be a startup snapshot, and COLUMNS=0 environments have been observed). Always emits one line; empty if unavailable, render falls back on its own.
# Note: 2>/dev/null MUST come before </dev/tty: redirects apply left-to-right, so this is the order that swallows the
# error from /dev/tty failing to open (no controlling terminal) — already hit: reversed, the error message leaks onto the display.
resolve_width() {
    local size
    size=$(stty size 2>/dev/null </dev/tty)
    size=${size##* }   # "rows cols" — take the last field
    case "$size" in ''|*[!0-9]*|0) size="" ;; esac
    if [ -z "$size" ]; then
        case "$COLUMNS" in ''|*[!0-9]*|0) ;; *) size=$COLUMNS ;; esac
    fi
    printf '%s\n' "$size"
}

read_width() {
    term_cols=""
    $RIGHT_ALIGN || return 0
    IFS= read -r term_cols <&8 || :
    exec 8<&-
}


# Single jq pass parsing every field; the order must match the reads below one-for-one.
# Newlines/carriage-returns inside values are first escaped to literal \n \r so each value stays on one line and fields don't misalign;
# all other control characters are stripped: C0 (incl. ESC, tab), DEL, AND the C1 block U+0080-U+009F (8-bit CSI/OSC/DCS — U+009B = "ESC [" on a UTF-8 terminal honoring C1, same injection class as a raw ESC; select keeps only `. >= 32 and (. < 127 or . > 159)`) — JSON's \u001b escape is legal input, and a raw ESC leaking out
# gets parsed by the terminal as CSI (injection risk), plus vis_width's width accounting wouldn't match the terminal and would push the single line into a wrap
# (reproduced in review: a session name containing ESC[1Zm renders as 121 cols at COLUMNS=120 → wraps).
# This is the only entry point for external strings, so after stripping, downstream can assume the string holds only our own SGR codes.
# Stripping uses explode/implode for codepoint filtering, not regex — jq's Oniguruma doesn't honor regex-layer backslash-u escapes,
# and a control-character range is treated as a literal character class (where the 0-u range strips almost all ASCII — already hit).
# jq inside the process substitution inherits the script's stdin (the statusline JSON).
# The last field (now|floor) also grabs the current Unix seconds for ttl, saving a date +%s fork.
# Each value is also capped to 256 codepoints (| .[0:256]): vis_width's ASCII-strip in render.sh is O(n^2) under bash 3.2, so an
# unbounded multi-KB field (e.g. a crafted session_name) would stall every frame (10KB → ~5s); 256 is far above any terminal's visible width, so render's "…" truncation still governs what shows.
parse_input() {
    {
        IFS= read -r cwd               # 01 cwd
        IFS= read -r project_dir       # 02 project_dir
        IFS= read -r model             # 03 model
        IFS= read -r session_name      # 04 session_name
        IFS= read -r used_pct          # 05 used_pct
        IFS= read -r worktree_name     # 06 worktree_name
        IFS= read -r effort            # 07 effort
        IFS= read -r thinking          # 08 thinking
        IFS= read -r five_h            # 09 five_h
        IFS= read -r seven_d           # 10 seven_d
        IFS= read -r five_reset        # 11 five_reset
        IFS= read -r seven_reset       # 12 seven_reset
        IFS= read -r session_id        # 13 session_id
        IFS= read -r transcript_path   # 14 transcript_path
        IFS= read -r exceeds_200k      # 15 exceeds_200k (upstream over-200k cost/cache cliff indicator)
        IFS= read -r dur_ms            # 16 dur_ms (cost.total_duration_ms — session wall-clock since start, ms)
        IFS= read -r api_ms            # 17 api_ms (cost.total_api_duration_ms — cumulative API-wait/"thinking" time, ms; excl. idle + local tools)
        IFS= read -r now               # 18 now
        IFS= read -r ctx_in_tok        # 19 ctx_in_tok   (context_window.current_usage.input_tokens)
        IFS= read -r ctx_cc_tok        # 20 ctx_cc_tok   (context_window.current_usage.cache_creation_input_tokens)
        IFS= read -r ctx_cr_tok        # 21 ctx_cr_tok   (context_window.current_usage.cache_read_input_tokens)
        IFS= read -r ctx_out_tok       # 22 ctx_out_tok  (context_window.current_usage.output_tokens)
        IFS= read -r ctx_win_size      # 23 ctx_win_size (context_window.context_window_size)
        # NOTE: this read order is positional one-for-one with the jq array below. Each line carries a "# NN field"
        # number that MUST match the same-numbered jq element. Inserting/removing a field means editing BOTH lists at
        # the same position. Section V (sentinel test) in tests/run-tests.sh asserts every field lands in its own global.
    } < <(jq -r '
        [ .workspace.current_dir // .cwd // "",                              # 01 cwd
          .workspace.project_dir // "",                                      # 02 project_dir
          .model.display_name // "",                                         # 03 model
          .session_name // "",                                               # 04 session_name
          .context_window.used_percentage // "",                            # 05 used_pct
          .worktree.name // "",                                              # 06 worktree_name
          .effort.level // "",                                               # 07 effort
          (if .thinking.enabled == null then "" else .thinking.enabled end), # 08 thinking
          .rate_limits.five_hour.used_percentage // "",                     # 09 five_h
          .rate_limits.seven_day.used_percentage // "",                     # 10 seven_d
          .rate_limits.five_hour.resets_at // "",                            # 11 five_reset
          .rate_limits.seven_day.resets_at // "",                            # 12 seven_reset
          .session_id // "",                                                 # 13 session_id
          .transcript_path // "",                                            # 14 transcript_path
          (if .context_window.exceeds_200k_tokens == null then ""            # 15 exceeds_200k (over-200k cost/cache cliff flag; "" when absent)
             else .context_window.exceeds_200k_tokens end),
          .cost.total_duration_ms // "",                                     # 16 dur_ms (session wall-clock since start, ms)
          .cost.total_api_duration_ms // "",                                 # 17 api_ms (cumulative API-wait/"thinking" ms; excl. idle + local tools)
          (now | floor),                                                     # 18 now
          # 19-23: the raw usage counters behind the "Context low (N% remaining)" warning CC prints for itself. They feed
          # ctx_aligned_pct in render.sh (T = 19+20+21+22, P = 23 - CTX_RESERVE); absent on older CC builds → "" → fallback.
          .context_window.current_usage.input_tokens // "",                  # 19 ctx_in_tok
          .context_window.current_usage.cache_creation_input_tokens // "",   # 20 ctx_cc_tok
          .context_window.current_usage.cache_read_input_tokens // "",       # 21 ctx_cr_tok
          .context_window.current_usage.output_tokens // "",                 # 22 ctx_out_tok
          .context_window.context_window_size // ""                          # 23 ctx_win_size
        ] | map(tostring | gsub("\n"; "\\n") | gsub("\r"; "\\r")
            | explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode | .[0:256])[]
    ' 2>/dev/null)
    # Post-jq hardening for the fields interpolated into file paths / awk -v / space-delimited cache records (jq guards JSON structure,
    # not these downstream uses). session_id → last-msg path, awk sid, cache fields: allow only [A-Za-z0-9_-] so a crafted value can't
    # inject awk C-escapes (needs \), corrupt space-delimited records (needs whitespace), or traverse paths (needs / or ..); real CC
    # session IDs (UUIDs) are a subset. transcript_path → tail/find reads: reject path-traversal. Both blank-on-violation; every
    # downstream reader already treats empty as a graceful no-op.
    case "$session_id" in ''|*[!0-9A-Za-z_-]*) session_id="" ;; esac
    case "$transcript_path" in *..*) transcript_path="" ;; esac
    # act_epoch: the turn's last-activity time = the transcript file's mtime. The transcript is appended on every
    # request during a turn and frozen while idle, so its mtime tracks the last request (≈ turn end ≈ the last
    # prompt-cache refresh). render.sh's build_left anchors the (Δ) idle delta on this; empty when the transcript is
    # unavailable → render falls back to lm_epoch (prompt submit), preserving pre-change behavior. BSD stat (macOS).
    act_epoch=""
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        act_epoch=$(stat -f %m "$transcript_path" 2>/dev/null)
        case "$act_epoch" in ''|*[!0-9]*) act_epoch="" ;; esac
    fi
}

# Bash-side twin of parse_input's jq sanitizer for the two fields that bypass jq: git_branch (from git, in collect_status) and
# last_msg (read from a file, in render.sh build_left). Strips C0+DEL (single bytes) + 2-byte UTF-8 C1 U+0080-U+009F (incl. U+009B
# CSI) and caps to 256 bytes — the bash mirror of select(. >= 32 and (. < 127 or . > 159)) | .[0:256]. Sets global REPLY (no
# command-substitution fork on the hot path; bash 3.2 has no namerefs). Keep in sync with parse_input and the render.sh call site.
_sanitize_field() {
    REPLY=${1//[$'\001'-$'\037'$'\177']/}
    REPLY=${REPLY//$'\302'[$'\200'-$'\237']/}
    REPLY=${REPLY:0:256}
}


# effort mode detection: the JSON only gives the resolved level (ultracode→xhigh, auto→resolved value),
# the mode itself is only recorded in the transcript's /effort stdout (<local-command-stdout> tag); grab the last one.
# The old 5-process pipe (tail|grep|grep|tail|sed) is shrunk to 3 (tail|grep|sed), taking the last match via bash string expansion.
# Word extraction must stay with sed: the anchor needs the full "effort level (set to|to)" token —
# a pure-bash trim anchored on "fort level" would wrongly catch suffixes like comfort/discomfort level (already hit).
effort_scan() {   # $1=transcript_path → one line of mode text on stdout (empty line if none)
    local m
    m=$(tail -n 2000 "$1" 2>/dev/null \
        | grep -oE '<local-command-stdout>[^<]*[Ee]ffort level (set to|to) [a-zA-Z]+[^<]*</local-command-stdout>' \
        | sed -E 's/.*[Ee]ffort level (set to|to) ([a-zA-Z]+).*/\2/')
    printf '%s\n' "${m##*$'\n'}"   # take the last match if there are several
}

# Concurrent collection of git×3 + effort: each opens its own FD in the procsub subshell, reaped in order; always emits a fixed 4 lines
collect_all() {   # $1=cwd $2=transcript_path $3=effort_level → branch / shortstat / untracked / effort_mode
    local b="" s="" u="" m=""
    if [ -n "$1" ]; then
        # branch: spends only 1 git process on a branch; falls back to a short sha only on detached HEAD
        # (4/5/6 no longer need </dev/null: collect_all itself is launched with </dev/null, and the child jobs inherit it)
        exec 4< <(git --no-optional-locks -C "$1" symbolic-ref --short -q HEAD 2>/dev/null \
                  || git --no-optional-locks -C "$1" rev-parse --short HEAD 2>/dev/null) \
             5< <(git --no-optional-locks -C "$1" diff --shortstat HEAD 2>/dev/null) \
             6< <(git --no-optional-locks -C "$1" ls-files --others --exclude-standard 2>/dev/null | head -1)
    fi
    if [ -n "$3" ] && [ -f "$2" ]; then
        exec 7< <(effort_scan "$2" </dev/null)
    fi
    if [ -n "$1" ]; then
        IFS= read -r b <&4 || :
        IFS= read -r s <&5 || :
        IFS= read -r u <&6 || :
    fi
    if [ -n "$3" ] && [ -f "$2" ]; then
        IFS= read -r m <&7 || :
    fi
    printf '%s\n%s\n%s\n%s\n' "$b" "$s" "$u" "$m"
}

collect_status() {
    local git_stat git_untracked   # intermediate values don't leave the function; git_branch/effort_mode are globals for render
    git_branch=""; git_stat=""; git_untracked=""; effort_mode=""
    {
        IFS= read -r git_branch
        IFS= read -r git_stat
        IFS= read -r git_untracked
        IFS= read -r effort_mode
    } < <(collect_all "$cwd" "$transcript_path" "$effort" </dev/null)
    _sanitize_field "$git_branch"; git_branch=$REPLY   # git_branch bypasses parse_input's jq (it comes from git) → strip C1/control + cap; else a hostile branch name injects SGR to stdout and desyncs vis_width

    # dirty flag + changed-line counts merged (precedence and behavior bit-for-bit identical to the old version):
    # non-empty shortstat = tracked files have changes (staged+unstaged) → dirty, also extract +N/-N;
    # otherwise an untracked new file also counts as dirty. +N/-N excludes untracked new-file lines (diff HEAD can't see them).
    # In a non-git directory all three jobs are empty; an empty git_branch silences the whole segment.
    git_dirty=""; git_ins=""; git_del=""
    if [ -n "$git_branch" ]; then
        if [ -n "$git_stat" ]; then
            git_dirty="*"
            if [[ $git_stat =~ ([0-9]+)\ insertion ]]; then git_ins="${BASH_REMATCH[1]}"; fi
            if [[ $git_stat =~ ([0-9]+)\ deletion ]]; then git_del="${BASH_REMATCH[1]}"; fi
        elif [ -n "$git_untracked" ]; then
            git_dirty="*"   # no tracked changes, but there is an untracked new file
        fi
    fi
}


# Cross-session rate-limit sync. Claude Code refreshes a session's rate_limits after each API round trip, but an idle session keeps
# reporting the last value it received. This shares the freshest observation across sessions so an idle frame adopts current usage.
#
# Rule — "the freshest observation is the authority", per window CLASS: the cache persists ONE record per class (W5 = five-hour,
# W7 = seven-day), each carrying (resets_at, used%, auth_observed_at). Every session also remembers its last reported pair per class:
# when that pair changes, observed_at becomes now; when it is unchanged, observed_at is carried over. A report replaces the stored
# class record — key, value and observation time together — only when observed_at >= auth_observed_at and its window key is live.
# This works in both directions: normal usage climbs and cap-raise drops are adopted alike. A changed resets_at re-keys the whole class
# after a window roll. Class-isolated: 5h never adopts a W7 record and vice versa; with no live class authority the frame keeps its own
# reported values. The authority is persisted and is not pruned when a session ends; only its live/sane window bounds its lifetime.
#
# Cache lines, four kinds (malformed / old-format lines — including the legacy untagged `W` schema — are simply not carried forward):
#   S  <session_id> <first_seen> <r5> <u5> <o5> <r7> <u7> <o7>  per-session last pair + observation time (`- - -` if absent)
#   W5 <resets_at>  <used> <auth_observed_at> five-hour class authority (single record; key+value+time replaced together)
#   W7 <resets_at>  <used> <auth_observed_at> seven-day class authority (same shape)
#   P  <resets_at>  <timestamp> <used>        burn-projection sample: (when, adopted used%) for a window, bounded series
# Pruning on rewrite: W5/W7/P lines with resets_at <= now (window rolled) OR resets_at >= now+691200 (8d sanity bound = the longest
# 7d window + 1d skew margin; an absurd far-future key — the real cache once carried W 9999999999 — must never become immortal),
# and S lines older than RL_REG_TTL (past the longest window), are dropped; P samples older than the sampling horizon, or beyond
# the per-window retention bound, are also dropped (keep the newest few).
# One awk pass reads all four kinds, applies this frame's report per the rule, rewrites survivors to a per-pid temp (atomic mv tolerates
# concurrent sessions), and emits "<five>|<eff5>|<seven>|<eff7>|<burn_tte>" (adopted value + adopted effective window key per class).
# Mutates five_h / seven_d / five_reset / seven_reset in place; build_rate renders them unchanged.
# Degrades safely: any awk/mv failure (e.g. read-only HOME) leaves out empty → the guards below keep this frame's own values and no alarm.
# An empty session_id contributes no observation state but still adopts an existing authority.
#
# Burn projection (5h window only): each frame appends a P sample (now, the ADOPTED used% of the 5h class — never a stale report)
# under the EFFECTIVE 5h key (the adopted authority's resets_at, = this frame's r5 whenever its snapshot window is live), keeps a
# bounded recent series, and computes a two-point slope (oldest→newest in-horizon sample) against that same key. When the
# slope is positive AND extrapolating it would hit 100% used strictly before resets_at, it emits burn_tte = seconds-to-exhaust (= remaining
# × Δt / Δused). Both gates are mandatory and live here (they need now/resets_at); the sensitivity ceiling + colour live in render's
# build_burn. <2 in-horizon samples → no slope → empty. Sampling the reconciled authority (not a stale session value) is what makes the
# slope reflect the true cross-session climb instead of a stuck value.
#
# Concurrency / serialization (the read-modify-write must NOT lose updates): the whole read+awk+mv is guarded by an mkdir spin-lock at
# "<cache>.lock" (stock macOS has no flock; mkdir is the POSIX-atomic create-a-dir primitive). Acquisition is bounded-retry with a
# staleness steal (a lock dir older than RL_LOCK_STALE means a holder died mid-frame). Two safe-degradation rules, both per the spec:
#   • lock NOT acquired (another writer holds it within our bounded attempt) → SKIP the mv (leave the on-disk cache untouched by this
#     frame) but STILL run the awk read-only so this frame DISPLAYS the correct adopted authority it read — never a stale/empty number.
#   • empty session_id (cannot record an observation → contributes nothing) → SKIP the mv (no destructive rewrite, every S/W/P line
#     left intact) but STILL adopt the existing authority read-only. No lock is taken on this path (we never write).
# The awk ALWAYS writes survivors to a per-pid temp and emits "<five>|<eff5>|<seven>|<eff7>|<burn_tte>"; only the mv is conditional. So the emitted
# (adopted) values are computed identically on every path; whether we persist them is the only difference. reconcile_start launches this
# as a background FD job overlapping the git stage (</dev/null per the stdin hard rule — reconcile reads/writes only the cache file, never
# the stdin JSON); reconcile_read reaps the FD and applies the numeric adoption guards. Degrades safely: any awk/mv/lock failure leaves
# the emitted fields empty → the guards in reconcile_read keep this frame's own parse_input values and raise no alarm (never set -e).
RL_LOCK_STALE=10    # steal the reconcile lock dir if it is older than this many seconds (a holder that died mid-frame)
RL_LOCK_TRIES=50    # bounded acquisition attempts before giving up and degrading to a read-only (skip-write) frame
RL_LOCK_WAIT=0.01   # backoff (sec) between failed attempts: the critical section is a few-ms read+awk+mv, so a short wait lets a
                    # genuine concurrent writer take its turn (no busy-spin starving a peer) while keeping the bounded total wait small.
                    # This runs in the background reconcile job overlapping the ~20ms git stage, so the wait is hidden from the frame.

# Background FD job: kick off the cross-session reconcile so it overlaps the git stage. </dev/null is mandatory (hard rule): the job must
# not consume the stdin JSON pipe it would otherwise inherit. The FD read in reconcile_read is the sync point (no wait / temp signalling).
reconcile_start() {
    burn_tte=""                                    # always defined (sync-off path never reaches the awk that would set it)
    $RL_SYNC || return 0
    exec 9< <(_reconcile_core </dev/null)
}

# Reap the reconcile FD job and adopt its result. Per-field numeric guards gate adoption: an empty/non-numeric reconciled field
# (awk/mv/lock failure, read-only HOME, torn cache, no live class authority) leaves this frame's own parse_input value for that
# field unchanged — and never errors out. eff5/eff7 are the adopted effective window keys: overwriting five_reset/seven_reset with
# them is what makes a post-roll frame's countdown track the LIVE window instead of a permanent 0m.
reconcile_read() {
    $RL_SYNC || return 0
    local out rest new5 eff5 new7 eff7
    IFS= read -r out <&9 || :                      # EOF with no trailing newline returns rc=1 as a normal path (never set -e)
    exec 9<&-
    new5=${out%%|*}; rest=${out#*|}                # _reconcile_core emits exactly four "|"; robust to newline stripping
    eff5=${rest%%|*}; rest=${rest#*|}
    new7=${rest%%|*}; rest=${rest#*|}
    eff7=${rest%%|*}; burn_tte=${rest#*|}
    case "$new5" in ''|*[!0-9.]*|*.*.*) ;; *) five_h="$new5" ;; esac          # adopt only a clean numeric (digits + ≤1 dot; *.*.* rejects ≥2 dots)
    case "$eff5" in ''|*[!0-9]*) ;; *) five_reset="$eff5" ;; esac              # all-digits epoch only; countdown follows the adopted window
    case "$new7" in ''|*[!0-9.]*|*.*.*) ;; *) seven_d="$new7" ;; esac
    case "$eff7" in ''|*[!0-9]*) ;; *) seven_reset="$eff7" ;; esac
    case "$burn_tte" in ''|*[!0-9]*) burn_tte="" ;; esac                     # non-numeric / empty → no alarm
}

# The serialized worker. Emits "<five>|<eff5>|<seven>|<eff7>|<burn_tte>" on stdout. Acquires the mkdir lock (bounded retry + stale steal) around the
# read+awk+mv; on lock failure OR empty session_id it still runs the awk read-only and emits the adopted value but skips the mv.
_reconcile_core() {
    umask 077                                      # cache/tmp/lock created private (600/700): they hold session IDs + usage — no cross-user read on a shared machine. Subshell-scoped (only ever run via procsub in reconcile_start).
    local cache="$HOME/.claude/sl-ratelimit-cache" lock="$HOME/.claude/sl-ratelimit-cache.lock"
    local src tmpfile have_lock=0 tries lmt
    tmpfile="$cache.$$"                            # $$ is unique per session process → no temp collision across sessions
    # Only contend for the lock when we actually intend to write (a non-empty sid). An empty sid is read-only (skip mv), so it needs no
    # lock — taking one would only add a contention source for a frame that can never be the authority.
    if [ -n "$session_id" ]; then
        tries=0
        while [ "$tries" -lt "${RL_LOCK_TRIES:-50}" ]; do
            if mkdir "$lock" 2>/dev/null; then have_lock=1; break; fi
            lmt=$(stat -f '%m' "$lock" 2>/dev/null)   # steal a stale lock (holder died) older than RL_LOCK_STALE, else back off and retry
            if [ -n "$lmt" ] && [ "$(( now - lmt ))" -gt "${RL_LOCK_STALE:-10}" ]; then
                rmdir "$lock" 2>/dev/null
                if mkdir "$lock" 2>/dev/null; then have_lock=1; break; fi
            fi
            sleep "${RL_LOCK_WAIT:-0.01}" 2>/dev/null   # yield the CPU so a concurrent holder can finish its read+awk+mv (no busy-spin)
            tries=$(( tries + 1 ))
        done
    fi
    # The cache-existence probe MUST happen AFTER lock acquisition so the read reflects the cache state at lock-hold time: probing it
    # before the lock would freeze src=/dev/null for a writer that then waits behind a peer who creates/updates the cache, making this
    # writer's awk read NOTHING and its mv clobber the peer's authority (the exact lost-update the lock exists to prevent).
    src="$cache"; [ -f "$src" ] || src=/dev/null   # first run / read-only: no cache yet → read nothing, just seed/adopt from this frame
    : > "$tmpfile" 2>/dev/null || { [ "$have_lock" = 1 ] && rmdir "$lock" 2>/dev/null; printf '%s|%s|%s|%s|%s\n' '' '' '' '' ''; return 0; }
    # writable = this frame will persist (lock held AND a non-empty sid). A read-only frame (lock-contention or empty-sid) must
    # adopt the EXISTING authority it read and NOT fold in its own (possibly stale) report — the spec is explicit that a contention frame
    # displays the value it READ (e.g. 47), never its own (e.g. 12). So `writable` gates whether the awk applies this frame's report.
    local writable=0; [ "$have_lock" = 1 ] && [ -n "$session_id" ] && writable=1
    local out
    out=$(awk -v now="$now" -v sid="$session_id" -v r5="$five_reset" -v u5="$five_h" \
              -v r7="$seven_reset" -v u7="$seven_d" -v regttl="$RL_REG_TTL" -v tmp="$tmpfile" -v writable="$writable" '
        function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?$/) }
        # sane live window key: strictly in the future AND below the 8d bound (longest 7d window 604800 + 1d skew margin) —
        # an absurd far-future key (the real cache once carried W 9999999999) would otherwise survive pruning forever
        function sane(k){ return (isnum(k) && k+0 > now+0 && k+0 < now+0 + MAXWIN) }
        function tripleok(r, u, o) {
            return ((r=="-" && u=="-" && o=="-") || (isnum(r) && isnum(u) && isnum(o)))
        }
        # Apply this frame report to class c: the freshest observation wins the WHOLE record (key+value+time).
        # A changed reset key re-keys the class after a roll; expired/insane/non-numeric reports are ignored.
        function applycls(c, r, u, o) {
            if (!sane(r) || !isnum(u) || !isnum(o)) return
            if (!(c in Rv) || o+0 >= Rf[c]+0) { Rk[c]=r; Rv[c]=u+0; Rf[c]=o }
        }
        # Record the latest pair for this session. First reports inherit first_seen; only a changed pair is observed now.
        function observe(c, r, u, o) {
            if (!isnum(r) || !isnum(u)) return
            if (!(c in Mr) || Mr[c]=="-") o=myfs
            else if (Mr[c]""==r"" && Mu[c]+0==u+0) o=Mo[c]
            else o=now
            Mr[c]=r; Mu[c]=u+0; Mo[c]=o
            applycls(c, r, u, o)
        }
        BEGIN { MAXSAMP=5; HORIZON=10800; MAXWIN=691200 }              # ≤5 samples/window over ~3h; window keys sane below now+8d
        $1=="S" && NF==9 && isnum($3) && tripleok($4,$5,$6) && tripleok($7,$8,$9) {
            if ($2==sid || $3+0 > now+0-regttl) {
                Sf[$2]=$3; S5r[$2]=$4; S5u[$2]=$5; S5o[$2]=$6; S7r[$2]=$7; S7u[$2]=$8; S7o[$2]=$9
                if ($2==sid) {
                    myfs=$3
                    Mr[5]=$4; Mu[5]=$5; Mo[5]=$6; Mr[7]=$7; Mu[7]=$8; Mo[7]=$9
                }
            }
            next
        }
        $1=="S" && NF==3 && isnum($3) {                                 # legacy registry row: no previous pair for either class
            if ($2==sid || $3+0 > now+0-regttl) {
                Sf[$2]=$3; S5r[$2]="-"; S5u[$2]="-"; S5o[$2]="-"; S7r[$2]="-"; S7u[$2]="-"; S7o[$2]="-"
                if ($2==sid) { myfs=$3; Mr[5]="-"; Mr[7]="-" }
            }
            next
        }
        # Per-class authority (W5=five-hour, W7=seven-day): keep the freshest observation per class. Keys stay STRINGS end-to-end
        # (a numeric round-trip would CONVFMT-mangle a non-integral epoch); legacy untagged W lines fall through and are dropped
        ($1=="W5" || $1=="W7") && NF==4 && isnum($3) && isnum($4) && sane($2) {
            c = ($1=="W5") ? 5 : 7
            if (!(c in Rv) || $4+0 >= Rf[c]+0) { Rk[c]=$2; Rv[c]=$3+0; Rf[c]=$4 }
            next
        }
        # burn sample for a sane still-live window, still inside the horizon — load in file (chronological) order; others dropped (pruned)
        $1=="P" && NF==4 && isnum($3) && isnum($4) && sane($2) && $3+0 > now+0 - HORIZON {
            np++; Pk[np]=$2; Pt[np]=$3+0; Pu[np]=$4+0; next
        }
        # any other / malformed / old-format line (incl. the legacy untagged `W <key> <used> <fs>` schema): dropped (not written to tmp)
        END{
            # Only a WRITABLE frame (lock held + rankable non-empty sid) folds its own report into the authority and registers itself.
            # A read-only frame (lock-contention or empty-sid) leaves the class records exactly as read from cache, so it adopts/displays
            # the value it READ (never its own possibly-stale report) and contributes no S/W mutation — matching the spec safe-degradation rules.
            if (writable+0 == 1 && sid != "") {
                if (myfs=="" || !isnum(myfs)) myfs=now                  # new session → first seen is now
                Sf[sid]=myfs
                if (!(5 in Mr)) Mr[5]="-"
                if (!(7 in Mr)) Mr[7]="-"
                observe(5, r5, u5); observe(7, r7, u7)
                S5r[sid]=Mr[5]; S5u[sid]=((5 in Mu) ? Mu[5] : "-"); S5o[sid]=((5 in Mo) ? Mo[5] : "-")
                S7r[sid]=Mr[7]; S7u[sid]=((7 in Mu) ? Mu[7] : "-"); S7o[sid]=((7 in Mo) ? Mo[7] : "-")
            }
            # append this frame’s sample (now, adopted used%) under the EFFECTIVE 5h key — the adopted authority’s resets_at, which
            # equals r5 whenever this frame’s snapshot window is live. 7d is never sampled (nothing downstream reads such a series).
            # The isnum(r5) gate keeps a frame that reports no 5h data at all from sampling another session’s quota.
            if (isnum(r5) && (5 in Rv)) { np++; Pk[np]=Rk[5]; Pt[np]=now+0; Pu[np]=Rv[5] }
            for (s in Sf) if (isnum(Sf[s]) && Sf[s]+0 > now+0-regttl)
                printf "S %s %s %s %s %s %s %s %s\n", s, Sf[s], S5r[s], S5u[s], S5o[s], S7r[s], S7u[s], S7o[s] >> tmp
            if (5 in Rv) printf "W5 %s %s %s\n", Rk[5], Rv[5], Rf[5] >> tmp
            if (7 in Rv) printf "W7 %s %s %s\n", Rk[7], Rv[7], Rf[7] >> tmp
            # rewrite samples bounded to the newest MAXSAMP per window (chronological); track 5h oldest/newest for the slope
            for (i=1;i<=np;i++) cnt[Pk[i]]++
            for (i=1;i<=np;i++) {
                k=Pk[i]; seen[k]++
                if (seen[k] > cnt[k]-MAXSAMP) {                         # this sample is within the newest MAXSAMP for its window
                    printf "P %s %s %s\n", k, Pt[i], Pu[i] >> tmp
                    if ((5 in Rv) && k""==Rk[5]"") {
                        rc++
                        if (rc==1) { pt0=Pt[i]; pu0=Pu[i] }             # oldest retained 5h sample
                        pt1=Pt[i]; pu1=Pu[i]                            # newest retained 5h sample (this frame)
                    }
                }
            }
            tte=""                                                     # 5h burn projection — both mandatory gates applied here
            if ((5 in Rv) && rc>=2 && pt1>pt0) {
                dp=pu1-pu0; dt=pt1-pt0
                if (dp>0 && dt>=60) {                                   # slope-positive gate + min-Δt gate: a sub-minute render burst (dt 1-2s) with a used% jump would otherwise project a false imminent alarm; 60 is inclusive & load-bearing (Y4 row 6 is a legit dt≈60 red)
                    rem=100-pu1; if (rem<0) rem=0
                    x=rem*dt/dp                                         # seconds-to-exhaust = remaining ÷ (slope per second)
                    if (now+0+x < Rk[5]+0) tte=sprintf("%d", x)        # before-reset gate: must run dry before the (effective) window rolls
                }
            }
            # 5 fields: adopted value + adopted effective key per class. The isnum(rX) gates keep a frame that reports NO rate-limit
            # data for a class (API-key auth, older CC) on its own silent segment instead of surfacing another session’s quota.
            printf "%s|%s|%s|%s|%s\n", \
                ((isnum(r5) && (5 in Rv)) ? Rv[5]"" : ""), ((isnum(r5) && (5 in Rv)) ? Rk[5] : ""), \
                ((isnum(r7) && (7 in Rv)) ? Rv[7]"" : ""), ((isnum(r7) && (7 in Rv)) ? Rk[7] : ""), tte
        }
    ' "$src" 2>/dev/null)
    # Persist ONLY when this frame both holds the lock AND has a rankable (non-empty) sid; otherwise this is a read-only frame:
    # skip the mv (leave the on-disk cache untouched), drop the temp, but still emit the adopted value computed above. This is the
    # safe-degradation path for both lock-contention and empty-sid, and it never errors out (no set -e).
    if [ "$have_lock" = 1 ] && [ -n "$session_id" ]; then
        # Overwrite ONLY when the awk produced a non-empty temp (success). An awk failure leaves an empty/half temp; mv-ing it would
        # wipe the cross-session authority other sessions persisted. rm cleans up the skip case (mv consumes the temp on success);
        # the lock is released on BOTH paths so an awk-failure frame never leaks the lock dir.
        [ -s "$tmpfile" ] && mv -f "$tmpfile" "$cache" 2>/dev/null
        rm -f "$tmpfile" 2>/dev/null
        rmdir "$lock" 2>/dev/null
    else
        rm -f "$tmpfile" 2>/dev/null
    fi
    printf '%s\n' "$out"
}


# Token usage: cumulative input+output tokens (cache tokens EXCLUDED) for this session and its subagents, shown left.
# The foreground only reads a tiny one-line cache (never blocks the frame); a DETACHED background job recomputes the heavy
# JSONL sums (~60ms over ~6MB) only when the source files' size/mtime changed (gate), single-flighted by an mkdir lock.
# So a re-sum happens at most once per turn, off the hot path; this frame shows the previous result (first-ever frame: nothing).
# in+out is deliberately cache-free so the number is stable across prompt-cache expiry/rewrite (that churn lands in cache_creation).
# Cache (one line per session):  T <sid> <session_tokens> <subagent_tokens> <main_size> <main_mtime> <sub_size> <sub_mtime>
# On rewrite, stale lines (main_mtime older than RL_REG_TTL) are pruned so the file can't grow without bound across sessions.
# subagent transcripts live alongside the main one: <transcript_path without extension>/subagents/**/agent-*.jsonl
TOKENS_CACHE="$HOME/.claude/sl-tokens-cache"

# in+out (cache excluded) summed over a stream of transcript JSONL on stdin; streamed (reduce inputs), not slurped.
# Dedup by .message.id: CC writes one JSONL row per assistant content block (text/thinking/tool_use), each repeating the
# SAME message-level usage, so a naive per-row sum multiplies every message by its block count (measured ~10x on real logs).
# A streamed seen-set keyed on message.id counts each message once; a row with no id (none in practice) falls through and counts.
_sum_inout() { jq -n 'reduce inputs as $l ({s:0,seen:{}};
    ($l.message.usage) as $u
    | if $u == null then .
      else ($l.message.id) as $id
        | if ($id != null) and (.seen[$id] == true) then .
          else (if $id != null then .seen[$id] = true else . end)
               | .s += (($u.input_tokens // 0) + ($u.output_tokens // 0))
          end
      end) | .s' 2>/dev/null; }

# Foreground: read this session's cached totals (fast, tiny file). Empty when no clean sid or no cache line yet.
read_tokens() {
    session_tokens=""; subagent_tokens=""
    case "$session_id" in ''|*/*|*..*) return 0 ;; esac   # need a clean sid to key the line (same posture as last-msg)
    [ -f "$TOKENS_CACHE" ] || return 0
    local tag s st sat rest
    while IFS=' ' read -r tag s st sat rest; do
        [ "$tag" = "T" ] && [ "$s" = "$session_id" ] || continue
        case "$st"  in ''|*[!0-9]*) ;; *) session_tokens="$st"  ;; esac
        case "$sat" in ''|*[!0-9]*) ;; *) subagent_tokens="$sat" ;; esac
        break
    done < "$TOKENS_CACHE"
}

# Foreground: the alternate-billing quota field, off unless configured.
#
# Some sessions do not bill the personal subscription at all -- ANTHROPIC_BASE_URL
# can point at a company or team gateway with its own daily allowance. When that
# happens the two rate-limit percentages above describe an account this session is
# not spending, so showing them is worse than showing nothing.
#
# Three variables turn this on, and all three come from the environment so that
# nothing about a particular gateway lives in this repository:
#
#   SL_QUOTA_MATCH   substring to look for in ANTHROPIC_BASE_URL; unset = off
#   SL_QUOTA_LABEL   what to call it on screen (default QUOTA)
#   SL_QUOTA_DIR     where the pre-rendered per-model text lives
#
# The percentage is NOT computed here. Whatever fetches it writes the finished
# string per model, because a ~26ms frame has no room to parse anything, and
# because every session must render the identical number.
read_quota_field() {
    quota_label=""; quota_pct=""; quota_sev=""; quota_at=""
    [ -n "${SL_QUOTA_MATCH:-}" ] || return 0
    case "${ANTHROPIC_BASE_URL:-}" in
        *"$SL_QUOTA_MATCH"*) quota_label="${SL_QUOTA_LABEL:-QUOTA}" ;;
        *) return 0 ;;
    esac

    # display_name -> the id the provider uses. Spelled out as a case rather than
    # lowercased, because macOS ships bash 3.2 (no ${var,,}) and because an
    # unknown family should fall through to "label with no number" instead of
    # silently reading some other model's file.
    local m fam ver dir
    m="${model%% (*}"                       # "Sonnet 5 (1M context)" -> "Sonnet 5"
    case "$m" in
        Sonnet*) fam=sonnet ;;
        Opus*)   fam=opus   ;;
        Haiku*)  fam=haiku  ;;
        Fable*)  fam=fable  ;;
        *) return 0 ;;
    esac
    ver="${m#* }"                           # "Sonnet 5" -> "5"
    [ "$ver" != "$m" ] || return 0          # no space at all: not a versioned name
    ver="${ver//./-}"                       # "4.5" -> "4-5"

    dir="${SL_QUOTA_DIR:-$HOME/.claude/state/statusline-quota}"
    [ -f "$dir/claude-$fam-$ver" ] || return 0
    IFS=' ' read -r quota_pct quota_sev quota_at < "$dir/claude-$fam-$ver" 2>/dev/null
}

# Kick off the detached recompute (gated). Fire-and-forget: the frame never waits on it. </dev/null per the stdin hard rule
# (it must not consume the stdin JSON pipe inherited by &); stdout/stderr to /dev/null so nothing interleaves with the line.
start_tokens_job() {
    case "$session_id" in ''|*/*|*..*) return 0 ;; esac
    [ -n "$transcript_path" ] && [ -f "$transcript_path" ] || return 0
    tokens_update "$transcript_path" "$session_id" "$now" >/dev/null 2>&1 </dev/null &
}

# Publish "this pane's working directory" so something OUTSIDE Claude Code can resolve it (PATH_CLICK).
# Why this exists: CC re-renders the statusline through its own style model, which drops OSC 8 hyperlinks, so the
# path segment cannot carry a clickable link itself (verified: zero OSC 8 bytes reach the terminal, with and without
# FORCE_HYPERLINK). The workable route is for the terminal to do the opening, and the only identity the terminal has
# is the tty. CC's children get NO controlling terminal (`ps -o tty=` is `??`, /dev/tty is unopenable), so the tty
# cannot be read here — but `$PPID` of the statusline command IS the claude process, and THAT process does own the
# pane's tty. So we key the record by claude's pid and let the opener go tty -> pid -> directory.
# One file per pid instead of one shared file: no lock, no read-modify-write, so concurrent panes cannot clobber
# each other (the token/rate caches need a lock precisely because they share a file). Dead pids are reaped on write.
CWD_MAP_DIR="$HOME/.claude/sl-cwd"
start_cwdmap_job() {   # $1=claude pid (the caller passes $PPID from the main shell — a subshell's $PPID is not it)
    [ -n "$cwd" ] || return 0
    case "$1" in ''|*[!0-9]*) return 0 ;; esac
    cwdmap_update "$cwd" "$1" >/dev/null 2>&1 </dev/null &
}

cwdmap_update() {   # $1=cwd $2=claude pid — detached worker: publish, then reap records of panes that are gone
    umask 077                                            # holds directory paths: keep it private (600/700), subshell-scoped
    mkdir -p "$CWD_MAP_DIR" 2>/dev/null || return 0
    printf '%s\n' "$1" > "$CWD_MAP_DIR/$2" 2>/dev/null
    local f p alive
    # One ps for the whole sweep, and `ps` rather than `kill -0`: kill -0 fails with EPERM on a process this user does
    # not own, which is indistinguishable from "gone" and would delete a live pane's record.
    alive=" $(/bin/ps -A -o pid= 2>/dev/null | tr -s ' \n' '  ') "
    for f in "$CWD_MAP_DIR"/*; do
        p=${f##*/}
        case $p in ''|*[!0-9]*) continue ;; esac          # skip the literal glob when the dir is empty, and any stray file
        case $alive in *" $p "*) ;; *) rm -f "$f" 2>/dev/null ;; esac
    done
}

tokens_update() {   # $1=transcript_path $2=sid $3=now — detached worker: gate on size/mtime, recompute + rewrite this sid's line
    umask 077                                            # token cache/tmp/lock created private (600/700): holds session IDs + token counts. Subshell-scoped (detached bg job / test subshell).
    local tp=$1 sid=$2 nowsec=$3 cache="$TOKENS_CACHE" lock="$TOKENS_CACHE.lock"
    local _b=${1##*/} subdir                              # strip the extension from the BASENAME only — NOT the last dot
    subdir="${1%/*}/${_b%.*}/subagents"                   # anywhere in the path, so a dotted parent dir can't misdirect find
    if ! mkdir "$lock" 2>/dev/null; then            # single-flight: at most one recompute in flight
        local lmt
        lmt=$(stat -f '%m' "$lock" 2>/dev/null)     # steal a stale lock (writer died) older than 30s, else skip this frame
        if [ -n "$lmt" ] && [ "$(( nowsec - lmt ))" -gt 30 ]; then
            rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
        else
            return 0
        fi
    fi
    local msig mz mt sig sz st
    msig=$(stat -f '%z %m' "$tp" 2>/dev/null); mz=${msig%% *}; mt=${msig##* }; mz=${mz:-0}; mt=${mt:-0}
    sig=$(find "$subdir" -type f -name 'agent-*.jsonl' -exec stat -f '%z %m' {} + 2>/dev/null \
          | awk '{s+=$1; if ($2+0>m+0) m=$2} END{printf "%d %d", s+0, m+0}')   # subagent aggregate: total bytes + latest mtime
    sz=${sig%% *}; st=${sig##* }; sz=${sz:-0}; st=${st:-0}
    local ctag csid cstok csat cmz cmt csz cst
    IFS=' ' read -r ctag csid cstok csat cmz cmt csz cst < <(awk -v s="$sid" '$1=="T" && $2==s {print; exit}' "$cache" 2>/dev/null)
    if [ "$ctag" = "T" ] && [ "$cmz" = "$mz" ] && [ "$cmt" = "$mt" ] && [ "$csz" = "$sz" ] && [ "$cst" = "$st" ]; then
        rmdir "$lock" 2>/dev/null; return 0          # sources unchanged → keep the cached totals (gate hit)
    fi
    local stok satok=0
    stok=$(_sum_inout < "$tp"); case "$stok" in ''|*[!0-9]*) stok=0 ;; esac
    if [ -d "$subdir" ]; then
        satok=$(find "$subdir" -type f -name 'agent-*.jsonl' -exec cat {} + 2>/dev/null | _sum_inout)
        case "$satok" in ''|*[!0-9]*) satok=0 ;; esac
    fi
    # Rewrite: drop this sid's old line AND prune any session whose main_mtime (field 6) is older than RL_REG_TTL (a dead
    # session — its transcript hasn't been touched in that long), then append the fresh line. awk's $2==sid is an exact
    # compare (no regex), so unlike the old grep -v it can't over-delete on an odd sid. Atomic mv tolerates concurrent sessions.
    local tmp="$TOKENS_CACHE.$$" cut=$(( nowsec - ${RL_REG_TTL:-604800} ))
    { awk -v sid="$sid" -v cut="$cut" '
          $1=="T" && $2==sid { next }
          $1=="T" && NF==8 && $6 ~ /^[0-9]+$/ && ($6+0) < cut { next }
          { print }
      ' "$cache" 2>/dev/null
      printf 'T %s %s %s %s %s %s %s\n' "$sid" "$stok" "$satok" "$mz" "$mt" "$sz" "$st"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
    rmdir "$lock" 2>/dev/null
}
