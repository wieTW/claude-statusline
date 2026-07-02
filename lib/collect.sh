# shellcheck shell=bash
# shellcheck disable=SC2034  # globals written here are consumed by the sibling render.sh (see WRITES header); lint via: shellcheck -x statusline-command.sh
# collect.sh — input collection: stdin JSON parsing + theme / width / git / effort collected concurrently in the background
#
# READS : stdin (statusline JSON), $HOME/.claude.json, $HOME/.claude/settings.json, transcript
# WRITES: cwd project_dir model session_name used_pct worktree_name effort thinking
#         five_h seven_d five_reset seven_reset session_id transcript_path exceeds_200k dur_ms api_ms now
#         git_branch git_dirty git_ins git_del effort_mode _theme term_cols
#         session_tokens subagent_tokens burn_tte
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
          (now | floor)                                                      # 18 now
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


# Cross-session rate-limit sync. Claude Code freezes rate_limits at a session's START snapshot (upstream limitation): a long-lived
# session keeps reporting its stale used% while only the countdown moves; a freshly-started session reports the true current value.
# This shares the truest value across sessions through a tiny cache so a frozen session adopts it.
#
# Rule — "the newest session is the authority": per reset-window we persist (value, authority_first_seen) = the used% reported by the
# session with the LATEST first-seen time. A report overrides the stored value only if its session is newer-or-equal (first_seen >=
# the authority's); an OLDER session can never overwrite it. This is correct in BOTH directions, unlike a plain max:
#   • used% climbs (normal): a newer session reports higher → adopt it; a stale older session reporting lower is ignored.
#   • used% drops (Anthropic raised the cap → % recomputed down): a newer session reports lower → adopt it; the obsolete high is dropped.
# The authority is PERSISTED — not pruned when a session ends. used% is cumulative, so a past high is still real until the window rolls;
# only a *newer* session may lower it. That is exactly why freshness is keyed on session AGE, not on "is the session still alive": TTL-
# pruning the authority would let an old frozen-LOW session re-take over and UNDER-report usage (you'd think you have budget and hit the
# wall — the one direction this display must never get wrong). first_seen is the first render time we saw a session_id (a seconds-grained
# proxy for session start; the error is sub-second-of-usage, negligible).
#
# Cache lines, three kinds (malformed / old-format lines are simply not carried forward on the next write):
#   S <session_id> <first_seen>             registry of each session's first-seen epoch (used to rank freshness)
#   W <resets_at>  <used> <auth_first_seen> per-window authority value + the first_seen of the session that set it
#   P <resets_at>  <timestamp> <used>       burn-projection sample: (when, adopted used%) for a window, bounded series
# Pruning on rewrite: W/P lines with resets_at <= now (window rolled) and S lines older than RL_REG_TTL (past the longest window) are
# dropped; P samples older than the sampling horizon, or beyond the per-window retention bound, are also dropped (keep the newest few).
# One awk pass reads all three kinds, applies this frame's report per the rule, rewrites survivors to a per-pid temp (atomic mv tolerates
# concurrent sessions), and emits "<five>|<seven>|<burn_tte>". Mutates five_h / seven_d in place; add_rate renders them unchanged.
# Degrades safely: any awk/mv failure (e.g. read-only HOME) leaves out empty → the guards below keep this frame's own values and no alarm.
# An empty session_id contributes nothing (cannot be ranked) but still adopts an existing authority.
#
# Burn projection (5h window only): each frame appends a P sample (now, the ADOPTED used% — Wval, not the frozen report) for each live
# window, keeps a bounded recent series, and computes a two-point slope (oldest→newest in-horizon sample) for the 5h window. When the
# slope is positive AND extrapolating it would hit 100% used strictly before resets_at, it emits burn_tte = seconds-to-exhaust (= remaining
# × Δt / Δused). Both gates are mandatory and live here (they need now/resets_at); the sensitivity ceiling + colour live in render's
# build_burn. <2 in-horizon samples → no slope → empty. Sampling the reconciled authority (not the frozen snapshot) is what makes the
# slope reflect the true cross-session climb instead of a stuck value.
#
# Concurrency / serialization (the read-modify-write must NOT lose updates): the whole read+awk+mv is guarded by an mkdir spin-lock at
# "<cache>.lock" (stock macOS has no flock; mkdir is the POSIX-atomic create-a-dir primitive). Acquisition is bounded-retry with a
# staleness steal (a lock dir older than RL_LOCK_STALE means a holder died mid-frame). Two safe-degradation rules, both per the spec:
#   • lock NOT acquired (another writer holds it within our bounded attempt) → SKIP the mv (leave the on-disk cache untouched by this
#     frame) but STILL run the awk read-only so this frame DISPLAYS the correct adopted authority it read — never a stale/empty number.
#   • empty session_id (cannot be ranked for freshness → contributes nothing) → SKIP the mv (no destructive rewrite, every S/W/P line
#     left intact) but STILL adopt the existing authority read-only. No lock is taken on this path (we never write).
# The awk ALWAYS writes survivors to a per-pid temp and emits "<five>|<seven>|<burn_tte>"; only the mv is conditional. So the emitted
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

# Reap the reconcile FD job and adopt its result. Numeric guards (digits + at most one dot) gate adoption: an empty/non-numeric reconciled
# value (awk/mv/lock failure, read-only HOME, torn cache) leaves this frame's own parse_input value unchanged — and never errors out.
reconcile_read() {
    $RL_SYNC || return 0
    local out rest new5 new7
    IFS= read -r out <&9 || :                      # EOF with no trailing newline returns rc=1 as a normal path (never set -e)
    exec 9<&-
    new5=${out%%|*}; rest=${out#*|}; new7=${rest%%|*}; burn_tte=${rest#*|}   # _reconcile_core emits exactly two "|"; robust to newline stripping
    case "$new5" in ''|*[!0-9.]*|*.*.*) ;; *) five_h="$new5" ;; esac          # adopt only a clean numeric (digits + ≤1 dot; *.*.* rejects ≥2 dots)
    case "$new7" in ''|*[!0-9.]*|*.*.*) ;; *) seven_d="$new7" ;; esac
    case "$burn_tte" in ''|*[!0-9]*) burn_tte="" ;; esac                     # non-numeric / empty → no alarm
}

# The serialized worker. Emits "<five>|<seven>|<burn_tte>" on stdout. Acquires the mkdir lock (bounded retry + stale steal) around the
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
    : > "$tmpfile" 2>/dev/null || { [ "$have_lock" = 1 ] && rmdir "$lock" 2>/dev/null; printf '%s|%s|%s\n' '' '' ''; return 0; }
    # writable = this frame will persist (lock held AND a rankable non-empty sid). A read-only frame (lock-contention or empty-sid) must
    # adopt the EXISTING authority it read and NOT fold in its own (possibly frozen) report — the spec is explicit that a contention frame
    # displays the value it READ (e.g. 47), never its own (e.g. 12). So `writable` gates whether the awk applies this frame's report.
    local writable=0; [ "$have_lock" = 1 ] && [ -n "$session_id" ] && writable=1
    local out
    out=$(awk -v now="$now" -v sid="$session_id" -v r5="$five_reset" -v u5="$five_h" \
              -v r7="$seven_reset" -v u7="$seven_d" -v regttl="$RL_REG_TTL" -v tmp="$tmpfile" -v writable="$writable" '
        function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?$/) }
        # apply this frame report (window r, used u): newest-or-equal session wins, older is ignored; expired/non-numeric skipped
        function applywin(r, u) {
            if (!isnum(r) || !isnum(u) || r+0 <= now+0) return
            if (!(r in Wval) || myfs+0 >= Wfs[r]+0) { Wval[r]=u+0; Wfs[r]=myfs }
        }
        BEGIN { MAXSAMP=5; HORIZON=10800 }                             # keep ≤5 samples/window over a ~3h horizon
        $1=="S" && NF==3 {                                              # session registry line
            if ($2==sid) myfs=$3                                        #   my own first_seen — preserved across renders
            else if (isnum($3) && $3+0 > now+0 - regttl) Sf[$2]=$3      #   keep other not-too-old sessions
            next
        }
        $1=="W" && NF==4 && isnum($2) && $2+0 > now+0 {                 # unexpired per-window authority
            Wval[$2]=$3+0; Wfs[$2]=$4; next
        }
        # burn sample for a still-live window, still inside the horizon — load in file (chronological) order; others dropped (pruned)
        $1=="P" && NF==4 && isnum($2) && isnum($3) && isnum($4) && $2+0 > now+0 && $3+0 > now+0 - HORIZON {
            np++; Pk[np]=$2+0; Pt[np]=$3+0; Pu[np]=$4+0; next
        }
        # any other / malformed / old-format line: dropped (not written to tmp)
        END{
            # Only a WRITABLE frame (lock held + rankable non-empty sid) folds its own report into the authority and registers itself.
            # A read-only frame (lock-contention or empty-sid) leaves Wval exactly as read from cache, so it adopts/displays the value it
            # READ (never its own possibly-frozen report) and contributes no S/W mutation — matching the spec safe-degradation rules.
            if (writable+0 == 1 && sid != "") {
                if (myfs=="" || !isnum(myfs)) myfs=now                  # new session → first seen is now
                Sf[sid]=myfs
                applywin(r5, u5); applywin(r7, u7)
            }
            # append this frame’s sample (now, adopted used%) for the 5h window only — it is the sole window the alarm projects,
            # so sampling 7d would persist bounded series that nothing downstream ever reads (the slope gate below is r5-only).
            if (isnum(r5) && (r5 in Wval)) { np++; Pk[np]=r5+0; Pt[np]=now+0; Pu[np]=Wval[r5] }
            for (s in Sf) if (isnum(Sf[s]) && Sf[s]+0 > now+0 - regttl) printf "S %s %s\n", s, Sf[s] >> tmp
            for (k in Wval) if (isnum(k) && k+0 > now+0) printf "W %s %s %s\n", k, Wval[k], Wfs[k] >> tmp
            # rewrite samples bounded to the newest MAXSAMP per window (chronological); track 5h oldest/newest for the slope
            for (i=1;i<=np;i++) cnt[Pk[i]]++
            for (i=1;i<=np;i++) {
                k=Pk[i]; seen[k]++
                if (seen[k] > cnt[k]-MAXSAMP) {                         # this sample is within the newest MAXSAMP for its window
                    printf "P %s %s %s\n", k, Pt[i], Pu[i] >> tmp
                    if (isnum(r5) && k==r5+0) {
                        rc++
                        if (rc==1) { pt0=Pt[i]; pu0=Pu[i] }             # oldest retained 5h sample
                        pt1=Pt[i]; pu1=Pu[i]                            # newest retained 5h sample (this frame)
                    }
                }
            }
            tte=""                                                     # 5h burn projection — both mandatory gates applied here
            if (isnum(r5) && rc>=2 && pt1>pt0) {
                dp=pu1-pu0; dt=pt1-pt0
                if (dp>0 && dt>=60) {                                   # slope-positive gate + min-Δt gate: a sub-minute render burst (dt 1-2s) with a used% jump would otherwise project a false imminent alarm; 60 is inclusive & load-bearing (Y4 row 6 is a legit dt≈60 red)
                    rem=100-pu1; if (rem<0) rem=0
                    x=rem*dt/dp                                         # seconds-to-exhaust = remaining ÷ (slope per second)
                    if (now+0+x < r5+0) tte=sprintf("%d", x)           # before-reset gate: must run dry before the window rolls
                }
            }
            printf "%s|%s|%s\n", ((isnum(r5) && (r5 in Wval)) ? Wval[r5]"" : ""), ((isnum(r7) && (r7 in Wval)) ? Wval[r7]"" : ""), tte
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

# Kick off the detached recompute (gated). Fire-and-forget: the frame never waits on it. </dev/null per the stdin hard rule
# (it must not consume the stdin JSON pipe inherited by &); stdout/stderr to /dev/null so nothing interleaves with the line.
start_tokens_job() {
    case "$session_id" in ''|*/*|*..*) return 0 ;; esac
    [ -n "$transcript_path" ] && [ -f "$transcript_path" ] || return 0
    tokens_update "$transcript_path" "$session_id" "$now" >/dev/null 2>&1 </dev/null &
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
