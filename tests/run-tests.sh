#!/usr/bin/env bash
# statusline single-line integration tests: fake HOME + controlled COLUMNS run the real script, asserting alignment / fallback / content.
# All run in-process via direct calls — no export/bash -c (a prior version's exported-function env passing blew up).
# Self-locating: SL = the statusline project root (this script lives in <root>/tests/). Survives directory renames.
# Work dir is a fresh mktemp (NOT /tmp/sl-test — that hardcoded path is exactly why the old harness vanished on tmp-clear).
set -u
SL=$(cd "$(dirname "$0")/.." && pwd)
SLDIR=$(basename "$SL")   # project-dir basename, shown as the path segment; derived (not hardcoded) so the order check survives a repo rename
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
TP="$WORK/transcript.jsonl"
mkdir -p "$FAKE_HOME/.claude/last-msg"
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"
printf '{"type":"user","content":"<local-command-stdout>Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration</local-command-stdout>"}\n' > "$TP"
# Hermetic git repo for width-sensitive git-segment fixtures: a clean, commit-less repo yields a deterministic
# "branch only, no dirty, no diffstat" segment. Using the live repo ($SL) would make the segment width track this
# checkout's uncommitted diff, flaking name-budget asserts (e.g. J) whenever the working tree is dirty.
GREPO="$WORK/grepo"; git init -q "$GREPO" >/dev/null 2>&1 || mkdir -p "$GREPO"

# Pull EDGE_PAD / JGAP from the script so the asserts track the real config instead of hardcoding 3 / 2.
EDGE_PAD=$(sed -n 's/^EDGE_PAD=\([0-9][0-9]*\).*/\1/p' "$SL/statusline-command.sh"); EDGE_PAD=${EDGE_PAD:-3}
JGAP=$(sed -n 's/^JGAP=\([0-9][0-9]*\).*/\1/p' "$SL/statusline-command.sh"); JGAP=${JGAP:-2}

mkjson() {  # $1=cwd $2=project_dir $3=session_name → one-line statusline JSON on stdout
  jq -cn --arg cwd "$1" --arg proj "$2" --arg sn "$3" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj},
    model:{display_name:"Opus 4.8 (1M context)"},
    session_name:$sn,
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest",
    transcript_path:$tp,
    effort:{level:"xhigh"},
    thinking:{enabled:true} }'
}

run() { printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh"; }

check() {  # stdin=output, $1=exact|max|min $2=expected width → assert single line + display width (CJK=2 cells)
  # Must run via -c, NOT heredoc: a heredoc steals stdin so the data side reads nothing (already hit).
  python3 -c '
import sys, re, unicodedata
mode, want = sys.argv[1], int(sys.argv[2])
lines = sys.stdin.buffer.read().decode("utf-8").rstrip("\n").split("\n")
assert len(lines) == 1, f"FAIL expected 1 line, got {len(lines)}: {lines!r}"
plain = re.sub(r"\x1b\[[0-9;]*m", "", lines[0])
w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in plain)
ok = {"exact": w == want, "max": w <= want, "min": w >= want}[mode]
assert ok, f"FAIL width {w} not {mode} {want}: [{plain}]"
print(f"  width={w} [{plain[:110]}]")' "$@"
}

vw() {  # display width (strip ANSI, CJK=2 cells)
  python3 -c 'import sys,re,unicodedata
p=re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read().rstrip("\n"))
print(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in p))'
}

J=$(mkjson "$SL" "$SL" "Consolidate statusline from two rows to one")
JCJK=$(mkjson "$SL" "$SL" "把狀態列整成一行測試")
JNOGIT=$(mkjson /private/tmp /private/tmp "")
# JLONG: hermetic GREPO (branch-only git, no dirty/diffstat) + a long session name. Defined here (not in J's section) so the earlier
# K / adaptive-layout sections can also use it — git + a wide session name keep the right half populated across squeezed widths.
JLONG=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:3},
    rate_limits:{ five_hour:{used_percentage:40, resets_at:(now+500|floor)},
                  seven_day:{used_percentage:86, resets_at:(now+108000|floor)} },
    effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"Consolidate statusline from two rows to one" }')
# JXLONG: GREPO git + an extra-long session name so the right half can't fit with a >=JGAP gap at mid widths — this forces the junction
# tier (│ placed, session head-truncated with …), exercising the "shrink (truncate) before drop" path that the fixed sacrifice order needs.
JXLONG=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:3},
    rate_limits:{ five_hour:{used_percentage:40, resets_at:(now+500|floor)},
                  seven_day:{used_percentage:86, resets_at:(now+108000|floor)} },
    effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"a very very very very very very very very very very long session name that forces right truncation" }')

fail=0
chk() { if "$@"; then :; else echo "  ★ FAIL"; fail=1; fi; }

# Baseline: content width W in the separated (no-width) fallback. Boundary cases derive from W dynamically.
W=$(run 0 "$J" | vw)
echo "baseline content width W=$W (separated mode; lw+rw=$((W-EDGE_PAD)))"

echo "── A. roomy align COLUMNS=$((W+20)): single line, width exactly $((W+20-EDGE_PAD)) (right edge = COLUMNS-EDGE_PAD)"
chk check exact $((W+20-EDGE_PAD)) < <(run $((W+20)) "$J")

echo "── A2. content order dir→model→ultra→ctx→quota→time→git→session"
plain=$(run $((W+20)) "$J" | python3 -c 'import sys,re;sys.stdout.write(re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()))')
case "$plain" in
  "$SLDIR"*"Opus 4.8 (1M)"*ultra*"6%"*"77%"*"16%"*"06-07 19:38"*main*"Consolidate statusline from two rows to one") echo "  order OK" ;;
  *) echo "  ★ FAIL order mismatch: [$plain]"; fail=1 ;;
esac

echo "── B. CJK session name: aligned width exactly $((140-EDGE_PAD)) (CJK=2 cells folds correctly)"
chk check exact $((140-EDGE_PAD)) < <(run 140 "$JCJK")

echo "── B2. boundary COLUMNS=W+JGAP → gap exactly JGAP, plain whitespace no │, right-aligned, width=W-(EDGE_PAD-JGAP)"
chk check exact $((W+JGAP-EDGE_PAD)) < <(run $((W+JGAP)) "$J")

echo "── B3. boundary COLUMNS=W+1 → gap<JGAP, junction │ placed, name truncated right (width=COLUMNS-EDGE_PAD, no overflow)"
chk check exact $((W+1-EDGE_PAD)) < <(run $((W+1)) "$J")

echo "── C. COLUMNS=0 (invalid width, unmeasurable) → cannot bound, fall back to │-join (width=W)"
chk check exact "$W" < <(run 0 "$J")

echo "── D. COLUMNS=50 (full set far wider than drawable) → degrade by the fixed sacrifice order, single line ≤ drawable, core (path+ctx%) kept"
# Post-adaptive-layout: instead of char-truncating the whole left blob to exactly fill the width (old behaviour), the renderer now
# drops/compacts segments in the fixed sacrifice order until the line fits — so it may sit BELOW the drawable width (≤, not ==), and the
# path basename + ctx% (the core) always survive. Width-bounded + single-line is the invariant (the J/P/M method); exact-fill no longer is.
out_d=$(run 50 "$J")
chk check max $((50-EDGE_PAD)) <<<"$out_d"
out_dp=$(printf '%s' "$out_d" | sed 's/\x1b\[[0-9;]*m//g')
case "$out_dp" in "$SLDIR"*"6%"*) echo "  core path + ctx% retained OK" ;; *) echo "  ★ FAIL core path/ctx% lost: [$out_dp]"; fail=1 ;; esac
[ "$(printf '%s' "$out_d" | grep -c '')" -eq 1 ] || { echo "  ★ FAIL D not single line"; fail=1; }

echo "── E. non-git + no session → right part empty, print left only, single line"
out_e=$(run 140 "$JNOGIT")
chk check max $((140-1)) <<<"$out_e"
case "$out_e" in *main*) echo "  ★ FAIL should have no git segment"; fail=1 ;; *) echo "  no git segment OK" ;; esac

echo "── K. junction │ only when 'merged': roomy(gap>=JGAP) plain whitespace gap, squeezed (right-truncated) keeps the │ junction, │-join fallback has │"
# Post-adaptive-layout the left/right junction is reached only when the right half (git + a wide session name) can't fit with a >=JGAP gap
# even after the in-order left drops — so the squeezed case uses JXLONG (extra-long name) and asserts the junction │ rides next to the
# … -truncated session, exercising step 11 (truncate before drop). roomy / fallback use JLONG. The roomy gap before the session is plain
# whitespace (no │); the in-segment │ separators inside each half are unaffected — the marker is the gap immediately before the right half.
kbad=0
ka=$(run 200 "$JLONG" | sed 's/\x1b\[[0-9;]*m//g')   # very wide: roomy, plain whitespace gap before the right half (git), no junction
# The right half starts with the git segment "main"; the gap before it is the left/right junction region. Roomy ⇒ only spaces there
# (the │ between main and the session is the right half's INTERNAL separator, not the junction — so we test the gap before "main").
case "$ka" in *"  main"*) echo "  roomy plain-whitespace gap (no junction) OK" ;; *"│ main"*) echo "  ★ FAIL roomy placed a junction │ before the right half: [$ka]"; kbad=1 ;; *) echo "  ★ FAIL roomy unexpected layout: [$ka]"; kbad=1 ;; esac
kt=$(run 120 "$JXLONG" | sed 's/\x1b\[[0-9;]*m//g')  # squeezed: junction │ placed, session head-truncated with …
case "$kt" in *"│ a very"*) ktj=1 ;; *) ktj=0 ;; esac
case "$kt" in *"…"*) ktt=1 ;; *) ktt=0 ;; esac
if [ "$ktj" -eq 1 ] && [ "$ktt" -eq 1 ]; then echo "  squeezed: junction │ + … -truncated session (shrink before drop) OK"; else echo "  ★ FAIL squeezed missing junction/… (junc=$ktj trunc=$ktt): [$kt]"; kbad=1; fi
kc=$(run 0 "$JLONG" | sed 's/\x1b\[[0-9;]*m//g')     # width unmeasurable → │-join fallback
case "$kc" in *"│"*) echo "  │-join fallback has │ OK" ;; *) echo "  ★ FAIL │-join fallback missing │"; kbad=1 ;; esac
[ "$kbad" -eq 0 ] || fail=1

echo "── F. RIGHT_ALIGN=false → output byte-for-byte identical to the 'no width' fallback"
mkdir -p "$WORK/noalign/lib" && cp "$SL"/lib/*.sh "$WORK/noalign/lib/"
sed 's/^RIGHT_ALIGN=true/RIGHT_ALIGN=false/' "$SL/statusline-command.sh" > "$WORK/noalign/statusline-command.sh"
# The two runs are independent processes that each read their own wall-clock `now`, so the rate-limit countdown token (e.g. 1H6m → 1H5m
# across a minute tick) can legitimately differ by one unit between them — that is a clock boundary, NOT a right-align divergence. Canonicalise
# every ttl token (runs of <digits><D|H|m>) before comparing so the assertion targets the right-align/fallback structure it actually tests.
ttlnorm() { sed -E 's/[0-9]+[DHm]/_/g'; }
out_f=$(printf '%s' "$J" | env COLUMNS=140 HOME="$FAKE_HOME" bash "$WORK/noalign/statusline-command.sh" | ttlnorm)
out_c=$(run 0 "$J" | ttlnorm)
if [ "$out_f" = "$out_c" ]; then echo "  identical OK"; else echo "  ★ FAIL the two fallbacks differ"; fail=1; fi

echo "── H. ESC injection: session_name with \\u001b[1Zm → control chars stripped, exact align no wrap"
JESC=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    session_name:"[1Zmhello", session_id:"sl-selftest", transcript_path:$tp, effort:{level:"xhigh"} }')
out_h=$(run 120 "$JESC")
case "$out_h" in *$'\033'"[1Z"*) echo "  ★ FAIL raw ESC leaked"; fail=1 ;; *) echo "  ESC stripped OK" ;; esac
chk check exact $((120-EDGE_PAD)) <<<"$out_h"

echo "── L. SEC-01: last_msg file ANSI injection stripped + session_id path traversal blocked"
# L1: a raw ESC written into the last-msg file must NOT reach the output (it bypasses parse_input).
printf '06-07 19:38\033[31mINJECT\033[0m\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"
out_l1=$(run 160 "$J")
case "$out_l1" in
  *$'\033'"[31mINJECT"*) echo "  ★ FAIL raw ESC from last-msg leaked"; fail=1 ;;
  *INJECT*) echo "  last-msg ESC stripped (inert text kept) OK" ;;
  *) echo "  ★ FAIL last-msg content unexpectedly dropped: [$(printf '%s' "$out_l1" | sed 's/\x1b\[[0-9;]*m//g')]"; fail=1 ;;
esac
chk check exact $((160-EDGE_PAD)) <<<"$out_l1"   # width still exact → vis_width did not desync into a wrap
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # restore
# L2: a session_id shaped like a traversal must make the read be skipped, so the planted secret never appears.
printf 'SECRET-TRAVERSAL-LEAK\n' > "$FAKE_HOME/secret"
JTRAV=$(echo "$J" | jq -c '.session_id="../../secret"')
out_l2=$(run 160 "$JTRAV" | sed 's/\x1b\[[0-9;]*m//g')
case "$out_l2" in *SECRET-TRAVERSAL-LEAK*) echo "  ★ FAIL path traversal: arbitrary file leaked"; fail=1 ;; *) echo "  session_id traversal blocked OK" ;; esac

echo "── M. ROB-01: perl absent on the narrow-truncation path → still single line, no overflow/wrap"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 127\n' > "$WORK/bin/perl"; chmod +x "$WORK/bin/perl"   # shadow perl with a failing stub
JLONGM=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:3}, effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"a deliberately long session name to force the narrow-terminal truncation path" }')
mbad=0
for cols in 70 90 110 130; do
  o=$(printf '%s' "$JLONGM" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh")
  nl=$(printf '%s' "$o" | grep -c '')
  w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]            || { echo "  ★ FAIL perl-absent C=$cols not single line: $nl"; mbad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL perl-absent C=$cols overflow: width=$w > $((cols-EDGE_PAD))"; mbad=1; }
done
[ "$mbad" -eq 0 ] && echo "  perl-absent 70..130: single line, never overflows OK" || fail=1

echo "── I. half-width katakana (known limitation): only shrinks, never blows up — single line, width ≤120"
JKANA=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    session_name:"ｾｯｼｮﾝ", session_id:"sl-selftest", transcript_path:$tp, effort:{level:"xhigh"} }')
chk check max 120 < <(run 120 "$JKANA")

echo "── J. long name + narrow terminal (original bug scenario): sweep 80..150, never overflow, name segment always present"
jbad=0
for cols in 80 100 110 120 125 130 135 140 145 150; do
  o=$(run "$cols" "$JLONG")
  w=$(printf '%s' "$o" | vw)
  nl=$(printf '%s' "$o" | grep -c '')
  [ "$w" -le "$cols" ]       || { echo "  ★ FAIL C=$cols overflow: width=$w"; jbad=1; }
  [ "$nl" -eq 1 ]            || { echo "  ★ FAIL C=$cols not single line: $nl"; jbad=1; }
  [ "$w" -eq $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL C=$cols width $w != edge $((cols-EDGE_PAD))"; jbad=1; }
  if [ "$cols" -ge 120 ]; then
    case "$o" in *Conso*) : ;; *) echo "  ★ FAIL C=$cols name segment vanished"; jbad=1 ;; esac
  fi
done
[ "$jbad" -eq 0 ] && echo "  80..150: single line, no overflow, width=edge; >=120 name present OK" || fail=1

echo "── N. SEC-02: C1 controls U+0080-U+009F (8-bit CSI/OSC) stripped from session_name AND last-msg"
# U+009B == "ESC [" on a UTF-8 terminal that honors C1; it survived the old C0/DEL-only strip and could inject.
noc1() { python3 -c 'import sys; sys.exit(1 if b"\xc2\x9b" in sys.stdin.buffer.read() else 0)'; }   # exit 0 = clean
JC1=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    session_name:(([155]|implode)+"2J"), session_id:"sl-selftest", transcript_path:$tp, effort:{level:"xhigh"} }')
if run 160 "$JC1" | noc1; then echo "  session_name C1 stripped OK"; else echo "  ★ FAIL C1 byte leaked from session_name"; fail=1; fi
chk check exact $((160-EDGE_PAD)) < <(run 160 "$JC1")   # width still exact → no vis_width desync/wrap
printf '06-07 \302\2332J\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # raw U+009B in the last-msg file (bypasses parse_input)
if run 160 "$J" | noc1; then echo "  last-msg C1 stripped OK"; else echo "  ★ FAIL C1 byte leaked from last-msg"; fail=1; fi
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # restore

echo "── O. PERF-01: a multi-KB session_name can't stall the frame (vis_width's ASCII strip is O(n^2); input capped at 256)"
OBIG=$(printf 'x%.0s' $(seq 1 8000))
JOBIG=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg sn "$OBIG" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus"}, session_name:$sn,
    session_id:"sl-selftest", transcript_path:$tp }')
SECONDS=0; run 120 "$JOBIG" >/dev/null
if [ "$SECONDS" -lt 3 ]; then echo "  8KB name frame ${SECONDS}s (uncapped this was ~4-5s, 20KB ~33s) OK"; else echo "  ★ FAIL 8KB name frame ${SECONDS}s — quadratic not bounded"; fail=1; fi

echo "── P. left-only line (no git/worktree/session) is width-bounded — a long left on a narrow terminal never overflows"
printf 'a fairly long recent-activity note that pads the left part well past a narrow terminal width\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"
JLEFT=$(jq -cn --arg cwd /private/tmp/not-a-git-repo --arg tp "$TP" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"}, effort:{level:"high"},
    context_window:{used_percentage:90}, session_id:"sl-selftest", transcript_path:$tp }')   # no project_dir/session_name, fake cwd → git empty → right part empty
pbad=0
for cols in 60 80 100 120; do
  o=$(run "$cols" "$JLEFT"); w=$(printf '%s' "$o" | vw); l=$(printf '%s' "$o" | grep -c '')
  [ "$l" -eq 1 ]                  || { echo "  ★ FAIL C=$cols not single line: $l"; pbad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL C=$cols left-only overflow: width=$w > $((cols-EDGE_PAD))"; pbad=1; }
done
[ "$pbad" -eq 0 ] && echo "  left-only 60..120: single line, never overflows COLUMNS-EDGE_PAD OK" || fail=1
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # restore

echo "── Q. ROB-02: perl-absent truncation of a CJK name never emits invalid UTF-8 (no mid-char byte cut)"
# reuses the failing perl stub planted by test M at $WORK/bin/perl
JQCJK=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus"},
    session_name:"把狀態列整成一行測試把狀態列整成一行", session_id:"sl-selftest", transcript_path:$tp }')
qbad=0
for cols in 90 95 100 105 110 115; do
  o=$(printf '%s' "$JQCJK" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh")
  printf '%s' "$o" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || { echo "  ★ FAIL C=$cols invalid UTF-8 (mid-char cut)"; qbad=1; }
done
[ "$qbad" -eq 0 ] && echo "  perl-absent CJK trunc 90..115: always valid UTF-8 OK" || fail=1

echo "── R. trunc_head negative cap (COLUMNS 1-2): no perl 'Unrecognized switch' on stderr, still single line"
rbad=0
for cols in 1 2; do
  err=$(run "$cols" "$J" 2>&1 >/dev/null)
  [ -z "$err" ]                          || { echo "  ★ FAIL C=$cols stderr noise: [$err]"; rbad=1; }
  [ "$(run "$cols" "$J" | grep -c '')" -eq 1 ] || { echo "  ★ FAIL C=$cols not single line"; rbad=1; }
done
[ "$rbad" -eq 0 ] && echo "  COLUMNS 1-2: stderr clean, single line OK" || fail=1

echo "── S. rate-limit used_percentage>100 clamps 'remaining' to 0% (never a negative number)"
JS=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus"},
    rate_limits:{five_hour:{used_percentage:120, resets_at:(now+100|floor)}},
    session_id:"sl-selftest", transcript_path:$tp }')
sout=$(run 200 "$JS" | sed 's/\x1b\[[0-9;]*m//g')
case "$sout" in *-[0-9]*%*) echo "  ★ FAIL negative remaining %: [$sout]"; fail=1 ;; *) echo "  no negative % OK" ;; esac

echo "── T. RATE-SYNC: per-window authority = the NEWEST session's value (older sessions can't override) — climb / cap-raise drop / anti-reversal / persistence / keying / toggle / prune / legacy"
SLC="$FAKE_HOME/.claude/sl-ratelimit-cache"
nocol() { sed 's/\x1b\[[0-9;]*m//g'; }
rsj() {  # $1=used% $2=resets_at $3=session_id → minimal five_hour-only json (ctx pinned 5% so the only other "%" token is the rate)
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "${3:-sl-selftest}" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{five_hour:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
# Scenarios are set up by PRE-SEEDING the cache with controlled first_seen epochs (render-time alone is sub-second so can't order sessions in-test).
NOW=$(jq -n 'now|floor'); RT=$((NOW + 9000))   # active window key (~2.5h to reset)
OLD=$((NOW - 5000)); RECENT=$((NOW - 100))     # an old vs a recent session's first_seen
# T1 climb: authority is an OLD session at 40; a NEW session (first_seen=now > OLD) reports higher 75 → adopt → remaining 25%
printf 'S sessOld %s\nW %s 40 %s\n' "$OLD" "$RT" "$OLD" > "$SLC"
t1=$(run 120 "$(rsj 75 "$RT" sessNew)" | nocol)
case "$t1" in *" 25%"*) echo "  T1 newer session raises (climb) → 25% OK" ;; *) echo "  ★ FAIL T1 expected 25% remaining: [$t1]"; fail=1 ;; esac
# T2 cap-raise (THE incident): authority OLD at 70; a NEW session reports LOWER 38 → adopt → remaining 62%, not the stale 30%
printf 'S sessOld %s\nW %s 70 %s\n' "$OLD" "$RT" "$OLD" > "$SLC"
t2=$(run 120 "$(rsj 38 "$RT" sessNew)" | nocol)
case "$t2" in *" 62%"*) echo "  T2 newer session lowers (cap raised) → 62%, not stale 30% OK" ;; *" 30%"*) echo "  ★ FAIL T2 stuck on stale high 70 (showed 30%): [$t2]"; fail=1 ;; *) echo "  ★ FAIL T2 expected 62%: [$t2]"; fail=1 ;; esac
# T3 older can't override + persistence: authority set by a RECENT session at 75; an OLD frozen-low session reports 40 → ignored → stays 25% (setter need not be rendering)
printf 'S sessRecent %s\nS sessOldFrozen %s\nW %s 75 %s\n' "$RECENT" "$OLD" "$RT" "$RECENT" > "$SLC"
t3=$(run 120 "$(rsj 40 "$RT" sessOldFrozen)" | nocol)
case "$t3" in *" 25%"*) echo "  T3 older session can't lower authority (no under-report) → 25% OK" ;; *" 60%"*) echo "  ★ FAIL T3 old frozen-low session overrode authority (showed 60%): [$t3]"; fail=1 ;; *) echo "  ★ FAIL T3 expected 25%: [$t3]"; fail=1 ;; esac
# T4 anti-reversal: after a newer session lowers 70→38, the OLD frozen-HIGH session rendering again must NOT bounce it back to 30%
printf 'S sessOld %s\nW %s 70 %s\n' "$OLD" "$RT" "$OLD" > "$SLC"
run 120 "$(rsj 38 "$RT" sessNew)" >/dev/null     # newer session lowers to 38 (becomes authority @ now)
t4=$(run 120 "$(rsj 70 "$RT" sessOld)" | nocol)  # the old session reports its stale 70 again
case "$t4" in *" 62%"*) echo "  T4 stale-high old session can't undo the cap-raise → still 62% OK" ;; *" 30%"*) echo "  ★ FAIL T4 reverted to stale 70 (showed 30%): [$t4]"; fail=1 ;; *) echo "  ★ FAIL T4 expected 62%: [$t4]"; fail=1 ;; esac
# T5 keying: a DIFFERENT window (different resets_at) must NOT inherit RT's authority
printf 'S sessOld %s\nW %s 40 %s\n' "$OLD" "$RT" "$OLD" > "$SLC"
t5=$(run 120 "$(rsj 0 "$((NOW + 22000))" sessOther)" | nocol)
case "$t5" in *" 100%"*) echo "  T5 separate window not polluted → 100% OK" ;; *) echo "  ★ FAIL T5 window polluted: [$t5]"; fail=1 ;; esac
# T6 toggle: RL_SYNC=false must ignore the cache entirely → a frozen used=0 shows the raw 100% (cache still holds the RT authority)
printf 'S sessOld %s\nW %s 70 %s\n' "$OLD" "$RT" "$OLD" > "$SLC"
mkdir -p "$WORK/nosync/lib" && cp "$SL"/lib/*.sh "$WORK/nosync/lib/"
sed 's/^RL_SYNC=true/RL_SYNC=false/' "$SL/statusline-command.sh" > "$WORK/nosync/statusline-command.sh"
t6=$(printf '%s' "$(rsj 0 "$RT" sessOld)" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$WORK/nosync/statusline-command.sh" | nocol)
case "$t6" in *" 100%"*) echo "  T6 RL_SYNC=false ignores cache (100%) OK" ;; *) echo "  ★ FAIL T6 false-path consulted cache: [$t6]"; fail=1 ;; esac
# T7 prune: a frame whose window already expired (resets_at<=now) must NOT be persisted as a W line
rm -f "$SLC"; RTpast=$((NOW - 100))
run 120 "$(rsj 90 "$RTpast" sessX)" >/dev/null
if grep -q "^W $RTpast " "$SLC" 2>/dev/null; then echo "  ★ FAIL T7 expired window persisted to cache"; fail=1; else echo "  T7 expired window pruned from cache OK"; fi
# T8 legacy: an old-format "<resets_at> <used>" line is ignored (dropped), not read as an authority
printf '%s 99\n' "$RT" > "$SLC"
t8=$(run 120 "$(rsj 10 "$RT" sessZ)" | nocol)
case "$t8" in *" 90%"*) echo "  T8 legacy 2-col line ignored → own 90% OK" ;; *" 1%"*) echo "  ★ FAIL T8 legacy line treated as authority (showed 1%): [$t8]"; fail=1 ;; *) echo "  ★ FAIL T8 expected 90%: [$t8]"; fail=1 ;; esac
rm -f "$SLC"

echo "── T2. RATE-SYNC CONCURRENCY: mkdir-lock serialises read+awk+mv (no lost-update), lock-contention safe-skip, empty-sid read-only, torn-cache survives"
LOCK="$SLC.lock"
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
# T2.0 spec Example (5.1): now≈now, window unexpired, OLD first_seen far back reports frozen-low 12, NEW first_seen recent reports 47 →
# the persisted W must be NEW's (47, NEW first_seen); the OLD frame must DISPLAY 47 (adopt), never its own 12. (relative first_seen mirrors the now=1000 example)
RTc=$((NOW + 9000)); OLDc=$((NOW - 5000)); NEWc=$((NOW - 100))
printf 'S sNew %s\nW %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" > "$SLC"     # NEW already wrote authority 47
t20=$(run 120 "$(rsj 12 "$RTc" sOldLow)" | nocol)                    # OLD frozen-low (first render → first_seen=now>OLDc? no: not seeded, defaults to now) reports 12
# sOldLow has no S line → its first_seen defaults to `now` (this render), which is NEWER than NEW's NEWc → by the rule it WOULD become authority.
# To honour the spec example (OLD must be the older one), pre-seed sOldLow as the genuinely-older session:
printf 'S sNew %s\nS sOldLow %s\nW %s 47 %s\n' "$NEWc" "$OLDc" "$RTc" "$NEWc" > "$SLC"
t20=$(run 120 "$(rsj 12 "$RTc" sOldLow)" | nocol)
case "$t20" in *" 53%"*) echo "  T2.0 old frozen-low adopts newer authority 47 → remaining 53% OK" ;;
  *" 88%"*) echo "  ★ FAIL T2.0 old session used its own frozen 12 (showed 88%): [$t20]"; fail=1 ;;
  *) echo "  ★ FAIL T2.0 expected 53% remaining: [$t20]"; fail=1 ;; esac
wline=$(grep "^W $RTc " "$SLC")
case "$wline" in "W $RTc 47 $NEWc") echo "  T2.0 persisted W = newer session's value+first_seen (47 $NEWc), old frame didn't clobber OK" ;;
  *) echo "  ★ FAIL T2.0 W line clobbered by older session: [$wline]"; fail=1 ;; esac

# T2.1 (5.1) Two sessions render CONCURRENTLY with DISTINCT windows → both W authority lines survive (no lost-update from racing rewrites)
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
WA=$((NOW + 9000)); WB=$((NOW + 18000))                              # two distinct unexpired 5h-style windows
N=16
for i in $(seq 1 $N); do
  run 120 "$(rsj 30 "$WA" sConcA)" >/dev/null 2>&1 &
  run 120 "$(rsj 55 "$WB" sConcB)" >/dev/null 2>&1 &
done
wait
ca=$(grep -c "^W $WA " "$SLC" 2>/dev/null); ca=${ca:-0}
cb=$(grep -c "^W $WB " "$SLC" 2>/dev/null); cb=${cb:-0}
if [ "$ca" -ge 1 ] && [ "$cb" -ge 1 ]; then echo "  T2.1 concurrent distinct-window renders: both authority lines survive (no lost-update) OK"
else echo "  ★ FAIL T2.1 lost-update under concurrency: WA-lines=$ca WB-lines=$cb"; fail=1; fi
rm -rf "$LOCK" 2>/dev/null

# T2.2 (5.1) Lock CONTENTION: a held (fresh) lock makes the frame SKIP the write, but it STILL displays the adopted authority value.
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
printf 'S sNew %s\nW %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" > "$SLC"     # cache holds authority 47
mkdir "$LOCK" 2>/dev/null                                           # another writer "holds" the lock (fresh mtime → not stealable)
szbefore=$(wc -c < "$SLC"); szbefore=${szbefore// /}; mtbefore=$(stat -f '%m' "$SLC")
t22=$(run 120 "$(rsj 12 "$RTc" sContend)" | nocol)                  # this frame can't get the lock → must read-only adopt 47
case "$t22" in *" 53%"*) echo "  T2.2 lock-contention frame still adopts authority 47 -> 53% OK" ;;
  *" 88%"*) echo "  ★ FAIL T2.2 contention frame fell back to its own 12 (showed 88%): [$t22]"; fail=1 ;;
  *) echo "  ★ FAIL T2.2 expected 53%: [$t22]"; fail=1 ;; esac
szafter=$(wc -c < "$SLC"); szafter=${szafter// /}; mtafter=$(stat -f '%m' "$SLC")
if [ "$szbefore" = "$szafter" ] && [ "$mtbefore" = "$mtafter" ]; then echo "  T2.2 contention frame did NOT rewrite the cache (skipped write) OK"
else echo "  ★ FAIL T2.2 contention frame rewrote the cache (size $szbefore-$szafter mtime $mtbefore-$mtafter)"; fail=1; fi
rm -rf "$LOCK" 2>/dev/null

# T2.3 (5.1) STALE lock (older than the steal horizon) is stolen → the frame proceeds with its write
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
printf 'S sNew %s\nW %s 47 %s\n' "$OLDc" "$RTc" "$OLDc" > "$SLC"    # authority owned by an OLD session
mkdir "$LOCK" 2>/dev/null
touch -t 200001010000 "$LOCK" 2>/dev/null                          # make the lock ancient → stealable
t23=$(run 120 "$(rsj 60 "$RTc" sFresh)" | nocol)                   # a fresh session reports 60 → after stealing the lock it becomes authority
case "$t23" in *" 40%"*) echo "  T2.3 stale lock stolen → fresh session writes authority 60 → 40% OK" ;;
  *) echo "  ★ FAIL T2.3 stale lock not stolen / wrong value: [$t23]"; fail=1 ;; esac
[ -d "$LOCK" ] && { echo "  ★ FAIL T2.3 lock dir leaked after a successful write"; fail=1; } || echo "  T2.3 lock released after the serialized write OK"

# T2.4 (5.2) EMPTY session_id: read-only adopt — must display the authority but NOT rewrite the cache (inode/size/mtime unchanged)
# Built inline (NOT via rsj, whose ${3:-default} would turn an empty sid into a real one) so session_id is genuinely "".
rsjempty() {  # $1=used% $2=resets_at → five_hour-only json with an EMPTY session_id
  jq -cn --arg cwd "$SL" --arg tp "$TP" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{five_hour:{used_percentage:$u, resets_at:$r}}, session_id:"", transcript_path:$tp }'; }
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
printf 'S sessA %s\nW %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" > "$SLC"
inob=$(stat -f '%i' "$SLC"); szb=$(wc -c < "$SLC"); szb=${szb// /}; mtb=$(stat -f '%m' "$SLC")
t24=$(run 120 "$(rsjempty 80 "$RTc")" | nocol)                     # empty sid reporting a HIGHER 80 — must be ignored, 47 adopted
case "$t24" in *" 53%"*) echo "  T2.4 empty-sid frame adopts authority 47 (ignores its own 80) -> 53% OK" ;;
  *" 20%"*) echo "  ★ FAIL T2.4 empty-sid overrode authority with its own 80 (showed 20%): [$t24]"; fail=1 ;;
  *) echo "  ★ FAIL T2.4 expected 53%: [$t24]"; fail=1 ;; esac
inoa=$(stat -f '%i' "$SLC"); sza=$(wc -c < "$SLC"); sza=${sza// /}; mta=$(stat -f '%m' "$SLC")
cafter=$(cat "$SLC")
if [ "$inob" = "$inoa" ] && [ "$szb" = "$sza" ] && [ "$mtb" = "$mta" ]; then echo "  T2.4 empty-sid did NOT rewrite the cache (inode/size/mtime unchanged) OK"
else echo "  ★ FAIL T2.4 empty-sid rewrote the cache (inode $inob-$inoa size $szb-$sza mtime $mtb-$mta)"; fail=1; fi
case "$cafter" in "S sessA $NEWc"*"W $RTc 47 $NEWc"*) echo "  T2.4 empty-sid left S and W lines intact OK" ;;
  *) echo "  ★ FAIL T2.4 empty-sid mutated cache contents: [$cafter]"; fail=1 ;; esac

# T2.5 (5.3) TORN / BINARY cache fixture: reconcile must not crash, frame stays single-line with a valid %, stderr clean
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
{ printf 'S sNew %s\nW %s 47 %s\n' "$NEWc" "$RTc" "$NEWc"; printf 'W garbage notnum xx\n'; head -c 64 /dev/urandom; printf '\nP %s notime nope\n' "$RTc"; } > "$SLC"
t25o=$(run 120 "$(rsj 33 "$RTc" sTorn)" 2>/dev/null)
t25e=$(run 120 "$(rsj 33 "$RTc" sTorn)" 2>&1 >/dev/null)
t25nl=$(printf '%s' "$t25o" | grep -c ''); t25p=$(printf '%s' "$t25o" | nocol)
t25bad=0
[ "$t25nl" -eq 1 ] || { echo "  ★ FAIL T2.5 torn cache → not single line ($t25nl)"; t25bad=1; }
[ -z "$t25e" ]     || { echo "  ★ FAIL T2.5 torn cache → stderr noise: [$t25e]"; t25bad=1; }
case "$t25p" in *%*) ;; *) echo "  ★ FAIL T2.5 torn cache → no valid % rendered: [$t25p]"; t25bad=1 ;; esac
[ "$t25bad" -eq 0 ] && echo "  T2.5 torn/binary cache survives: single line, valid %, clean stderr OK" || fail=1

# T2.6 (5.4) reconcile is BACKGROUNDED (overlapped with git): a function named reconcile_start must open an FD job and reconcile_read must reap it,
# both honouring the </dev/null hard rule (the bg job must NOT read the stdin JSON pipe). Behaviour-equivalent to the old sync path (T section above stays green).
T2C=$(grep -c 'reconcile_start\|reconcile_read' "$SL/lib/collect.sh")
[ "$T2C" -ge 2 ] && echo "  T2.6 reconcile split into start/read FD-job pair OK" || { echo "  ★ FAIL T2.6 reconcile not backgrounded (reconcile_start/reconcile_read absent)"; fail=1; }
# the bg reconcile job must redirect stdin from /dev/null (hard rule) — assert a reconcile procsub job carries </dev/null
grep -q 'exec [0-9]*< <(_reconcile.*</dev/null)' "$SL/lib/collect.sh" && echo "  T2.6 reconcile bg job has </dev/null (stdin hard rule) OK" || { echo "  ★ FAIL T2.6 reconcile bg job missing </dev/null"; fail=1; }
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null

echo "── U. LAST-MSG: 'HH:MM (Δ)' cache-age delta — <1m hides Δ, 5m/1h colour tiers, old format verbatim, cross-day date prefix"
NOWS=$(jq -n 'now|floor')
LMF="$FAKE_HOME/.claude/last-msg/sl-selftest"
lmrun() { printf '09:30 %s\n' "$(( NOWS - $1 ))" > "$LMF"; run 200 "$J"; }      # $1=age sec → render with that last-msg age
pcode() { sed -E 's/.*\x1b\[([0-9;]*)m\(.*/\1/'; }    # SGR code right before the LAST "(" (the Δ segment)
strip()  { sed 's/\x1b\[[0-9;]*m//g'; }
# U1 Δ<1min suppressed → clock time only (no "(" after the time)
u1=$(lmrun 30 | strip)
case "$u1" in *"09:30 ("*) echo "  ★ FAIL U1 <1min should hide Δ: [$u1]"; fail=1 ;; *"09:30"*) echo "  U1 <1min: time only OK" ;; *) echo "  ★ FAIL U1 time missing"; fail=1 ;; esac
# U2 ~10min → minutes Δ (5m–1h yellow tier)
u2raw=$(lmrun 600); u2=$(printf '%s' "$u2raw" | strip)
case "$u2" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  U2 10min: (10m) Δ OK" ;; *) echo "  ★ FAIL U2 expected (10m): [$u2]"; fail=1 ;; esac
# U3 ~2h → H/m Δ (≥1h red tier)
u3raw=$(lmrun 7200); u3=$(printf '%s' "$u3raw" | strip)
case "$u3" in *"09:30 (2H0m)"*|*"09:30 (1H59m)"*) echo "  U3 2h: (2H0m) Δ OK" ;; *) echo "  ★ FAIL U3 expected (2H0m): [$u3]"; fail=1 ;; esac
# U4 the three TTL tiers (warm <5m / 5m–1h / ≥1h) must be coloured differently
cw=$(lmrun 120 | pcode); cm=$(printf '%s' "$u2raw" | pcode); cc=$(printf '%s' "$u3raw" | pcode)
if [ -n "$cw" ] && [ -n "$cm" ] && [ -n "$cc" ] && [ "$cw" != "$cm" ] && [ "$cm" != "$cc" ] && [ "$cw" != "$cc" ]; then
  echo "  U4 three cache-TTL colour tiers distinct OK"
else echo "  ★ FAIL U4 tiers not distinct: warm=[$cw] mid=[$cm] cold=[$cc]"; fail=1; fi
# U5 backward compat — old "MM-DD HH:MM" (no epoch tail) shown verbatim
printf '06-07 19:38\n' > "$LMF"
u5=$(run 200 "$J" | strip)
case "$u5" in *"06-07 19:38"*) echo "  U5 old format verbatim OK" ;; *) echo "  ★ FAIL U5 old format dropped: [$u5]"; fail=1 ;; esac
# U6 cross-day (26h ago): different local calendar day → the timestamp gains a "MM-DD" date prefix (not a bare HH:MM)
U6AGE=$(( 26*3600 )); U6EP=$(( NOWS - U6AGE )); U6MD=$(date -r "$U6EP" '+%m-%d' 2>/dev/null)
u6=$(lmrun "$U6AGE" | strip)
case "$u6" in *"$U6MD 09:30 ("*) echo "  U6 cross-day (26h) date-prefixed $U6MD 09:30 OK" ;;
  *"09:30 ("*) echo "  ★ FAIL U6 cross-day NOT date-prefixed (expected $U6MD): [$u6]"; fail=1 ;;
  *) echo "  ★ FAIL U6 time segment missing: [$u6]"; fail=1 ;; esac
# U7 same-day (10 min ago, already U2): the timestamp stays a BARE HH:MM — no date prefix
u7=$(lmrun 600 | strip)
case "$u7" in *[0-9][0-9]-[0-9][0-9]" 09:30 ("*) echo "  ★ FAIL U7 same-day wrongly date-prefixed: [$u7]"; fail=1 ;;
  *"09:30 ("*) echo "  U7 same-day bare HH:MM (no date prefix) OK" ;;
  *) echo "  ★ FAIL U7 time segment missing: [$u7]"; fail=1 ;; esac
# U8 cross-day prefix does NOT alter the delta colour tier: 26h ≥ LASTMSG_STALE → still the red (≥1h) tier, same as a bare-time ≥1h delta
u8cross=$(lmrun "$U6AGE" | pcode); u8bare=$(printf '%s' "$u3raw" | pcode)
if [ -n "$u8cross" ] && [ "$u8cross" = "$u8bare" ]; then echo "  U8 date prefix keeps the same Δ colour tier (red) OK";
else echo "  ★ FAIL U8 date prefix changed the Δ colour tier (cross=[$u8cross] bare=[$u8bare])"; fail=1; fi
printf '06-07 19:38\n' > "$LMF"   # restore baseline

echo "── W. TOKENS: cumulative in+out, subagent ⊂ only when >0, foreground reads cache (never blocks)"
# Seed the token cache with the transcript's REAL size/mtime so the detached bg job hits its gate (sources unchanged →
# no recompute) and the seeded token VALUES are preserved; this makes the assertions deterministic despite the bg job.
TKC="$FAKE_HOME/.claude/sl-tokens-cache"
TSZ=$(stat -f '%z' "$TP" 2>/dev/null); TMT=$(stat -f '%m' "$TP" 2>/dev/null)
printf 'T sl-selftest 562000 0 %s %s 0 0\n' "$TSZ" "$TMT" > "$TKC"      # W1: session-only → 562k, no ⊂
w1=$(run 200 "$J" | nocol)
case "$w1" in *"⊂"*) echo "  ★ FAIL W1 ⊂ shown with zero subagent: [$w1]"; fail=1 ;;
  *"562k"*) echo "  W1 session-only 562k, no ⊂ OK" ;; *) echo "  ★ FAIL W1 expected 562k: [$w1]"; fail=1 ;; esac
printf 'T sl-selftest 562000 1100000 %s %s 0 0\n' "$TSZ" "$TMT" > "$TKC"  # W2: subagent>0 → 562k ⊂1.1M
w2=$(run 200 "$J" | nocol)
case "$w2" in *"562k"*"⊂1.1M"*) echo "  W2 session 562k + subagent ⊂1.1M OK" ;; *) echo "  ★ FAIL W2 expected 562k ⊂1.1M: [$w2]"; fail=1 ;; esac
printf 'T sl-selftest 950 0 %s %s 0 0\n' "$TSZ" "$TMT" > "$TKC"           # W3: fmt_tok sub-1000 raw
w3=$(run 200 "$J" | nocol)
case "$w3" in *"950"*) echo "  W3 sub-1000 raw count OK" ;; *) echo "  ★ FAIL W3 expected raw 950: [$w3]"; fail=1 ;; esac
rm -f "$TKC"                                                              # W4: no cache → token segment omitted, frame still one line
chk check max $((200-1)) < <(run 200 "$J")
rm -f "$TKC" "$TKC".* 2>/dev/null; rm -rf "$TKC".lock 2>/dev/null

echo "── V. parse_input positional contract: each field lands in its own global (sentinel)"
# Source collect.sh and feed a JSON where every field carries a distinct value; assert each global got its own.
# A jq-array / read-block misalignment (the codebase's most fragile spot) makes one field's value land in another → caught here.
VFEED=$(jq -cn '{
  workspace:{current_dir:"S_cwd", project_dir:"S_proj"},
  model:{display_name:"S_model"}, session_name:"S_sname",
  context_window:{used_percentage:"S_used", exceeds_200k_tokens:true}, worktree:{name:"S_wt"},
  effort:{level:"S_effort"}, thinking:{enabled:false},
  rate_limits:{ five_hour:{used_percentage:"S_5h", resets_at:"S_5r"},
                seven_day:{used_percentage:"S_7d", resets_at:"S_7r"} },
  session_id:"S_sid", transcript_path:"S_tp" }')
if printf '%s' "$VFEED" | ( . "$SL/lib/collect.sh"; parse_input
   rc=0
   chkv() { [ "$2" = "$3" ] || { echo "  ★ FAIL $1=[$2] expected [$3]"; rc=1; }; }
   chkv cwd "$cwd" S_cwd;                 chkv project_dir "$project_dir" S_proj
   chkv model "$model" S_model;           chkv session_name "$session_name" S_sname
   chkv used_pct "$used_pct" S_used;      chkv worktree_name "$worktree_name" S_wt
   chkv effort "$effort" S_effort;        chkv thinking "$thinking" false
   chkv five_h "$five_h" S_5h;            chkv seven_d "$seven_d" S_7d
   chkv five_reset "$five_reset" S_5r;    chkv seven_reset "$seven_reset" S_7r
   chkv session_id "$session_id" S_sid;   chkv transcript_path "$transcript_path" S_tp
   chkv exceeds_200k "$exceeds_200k" true
   case "$now" in ''|*[!0-9]*) echo "  ★ FAIL now not numeric: [$now]"; rc=1 ;; esac
   exit $rc ); then echo "  all 16 fields land in their own global OK"; else fail=1; fi

echo "── CTX. CONTEXT-METER: budget-aware red threshold (1M model not red at 85%, 200k model is) + decoupled 200k cliff marker ⚑"
# mkctx: build a statusline JSON with controllable model / used% / exceeds_200k. Width is roomy (no degrade) so the ctx% renders full.
# ctxpcode extracts the SGR colour code on the segment IMMEDIATELY preceding "N%" — that is ctx_color, so we can assert red-or-not
# without hardcoding the theme's exact red triple. RD (tokyo-night-claude) = 38;2;247;118;142 ; WH = 38;2;222;214;202.
mkctx() {  # $1=model display_name $2=used% $3=exceeds(true|false|omit)
  if [ "$3" = "omit" ]; then
    jq -cn --arg cwd "$SL" --arg m "$1" --argjson up "$2" --arg tp "$TP" \
      '{workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:$m}, context_window:{used_percentage:$up}, session_id:"sl-selftest", transcript_path:$tp}'
  else
    jq -cn --arg cwd "$SL" --arg m "$1" --argjson up "$2" --argjson ex "$3" --arg tp "$TP" \
      '{workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:$m}, context_window:{used_percentage:$up, exceeds_200k_tokens:$ex}, session_id:"sl-selftest", transcript_path:$tp}'
  fi
}
# ctxpcode: the SGR code that colours the "N%" token — grab the code from the last "\e[<code>mNN%" match. That is ctx_color.
ctxpcode() { perl -ne 'while(/\x1b\[([0-9;]*)m([0-9]+)%/g){$c=$1} END{print $c}'; }
# Derive the palette's red/normal ctx codes EMPIRICALLY (theme-agnostic): a 200k model far over threshold is guaranteed red,
# a 1M model far under threshold is guaranteed normal. No colour triple is hardcoded — the asserts track the live palette.
RDCODE=$(run 200 "$(mkctx 'Sonnet 4.6' 99 omit)" | ctxpcode)             # guaranteed-red reference (200k @99%)
NMCODE=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 10 omit)" | ctxpcode)  # guaranteed-normal reference (1M @10%)
if [ -n "$RDCODE" ] && [ -n "$NMCODE" ] && [ "$RDCODE" != "$NMCODE" ]; then echo "  CTX0 red/normal ctx colours derived OK"
else echo "  ★ FAIL CTX0 could not derive distinct red/normal colours (red=[$RDCODE] normal=[$NMCODE])"; fail=1; fi
# CTX1 1M model at 85% → NOT red (the spec worked example)
c1=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 85 omit)" | ctxpcode)
if [ "$c1" != "$RDCODE" ]; then echo "  CTX1 1M @85% ctx% NOT red OK"; else echo "  ★ FAIL CTX1 1M @85% wrongly red ([$c1] == RD)"; fail=1; fi
# CTX2 200k model (no 1M marker) at 85% → red
c2=$(run 200 "$(mkctx 'Sonnet 4.6' 85 omit)" | ctxpcode)
if [ "$c2" = "$RDCODE" ]; then echo "  CTX2 200k @85% ctx% red OK"; else echo "  ★ FAIL CTX2 200k @85% not red ([$c2] != RD [$RDCODE])"; fail=1; fi
# CTX3 threshold is budget-driven, not a constant: identical 85% differs in colour only by the 1M marker (CTX1 vs CTX2)
if [ "$c1" != "$c2" ]; then echo "  CTX3 budget-driven threshold (1M≠200k at same 85%) OK"; else echo "  ★ FAIL CTX3 1M and 200k coloured identically at 85% ([$c1]=[$c2])"; fail=1; fi
# CTX4 over-200k indicator TRUE at 70% on a 1M model → cliff ⚑ present, % still normal (decoupled)
c4out=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 70 true)"); c4=$(printf '%s' "$c4out" | ctxpcode)
case "$c4out" in *"⚑"*) if [ "$c4" != "$RDCODE" ]; then echo "  CTX4 ⚑ shown + % normal (decoupled) OK"; else echo "  ★ FAIL CTX4 % unexpectedly red"; fail=1; fi ;;
  *) echo "  ★ FAIL CTX4 ⚑ cliff marker missing when exceeds_200k=true"; fail=1 ;; esac
# CTX5 over-200k indicator FALSE at 95% → NO ⚑ even at high %
c5out=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 95 false)")
case "$c5out" in *"⚑"*) echo "  ★ FAIL CTX5 ⚑ shown when exceeds_200k=false: present"; fail=1 ;; *) echo "  CTX5 no ⚑ when exceeds_200k=false OK" ;; esac
# CTX6 absent indicator → no ⚑ (default off)
c6out=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 95 omit)")
case "$c6out" in *"⚑"*) echo "  ★ FAIL CTX6 ⚑ shown when indicator absent"; fail=1 ;; *) echo "  CTX6 no ⚑ when indicator absent OK" ;; esac
# CTX7 decoupled matrix: 200k @85% true → BOTH red % AND ⚑ (coloring and marker independent)
c7out=$(run 200 "$(mkctx 'Sonnet 4.6' 85 true)"); c7=$(printf '%s' "$c7out" | ctxpcode)
if [ "$c7" = "$RDCODE" ]; then case "$c7out" in *"⚑"*) echo "  CTX7 200k @85% true → red % + ⚑ (both independent) OK" ;;
  *) echo "  ★ FAIL CTX7 ⚑ missing"; fail=1 ;; esac
else echo "  ★ FAIL CTX7 % not red ([$c7])"; fail=1; fi

echo "── X. _sum_inout dedups by message.id (CC logs one row per content block, each repeating the same message usage)"
# m1 appears 3× with the same usage (10+5), m2 once (100+20); a naive per-row sum = 165, the correct dedup = 135.
# A user row (no .message.usage) must be ignored. _sum_inout reads stdin only, so HOME is irrelevant here.
xdedup=$(printf '%s\n' \
  '{"message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}' \
  '{"message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}' \
  '{"message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}' \
  '{"message":{"id":"m2","usage":{"input_tokens":100,"output_tokens":20}}}' \
  '{"type":"user","message":{"role":"user"}}' \
  | ( . "$SL/lib/collect.sh"; _sum_inout ))
case "$xdedup" in 135) echo "  X dedup by message.id → 135 (not 165) OK" ;; *) echo "  ★ FAIL X expected 135 got [$xdedup]"; fail=1 ;; esac

echo "── X2. tokens_update prunes T-lines whose main_mtime is older than RL_REG_TTL, exact-matches sid (no regex over-delete)"
# HOME=FAKE_HOME so TOKENS_CACHE resolves into the sandbox, NOT the real ~/.claude cache. 'ancient' mtime=1 → pruned;
# 'fresh' mtime=now → kept; 'xupd' has no seeded line → gate misses → the rewrite path (the code under test) runs.
NOWX=$(date +%s)
printf 'T ancient 100 0 10 1 0 0\nT fresh 200 0 10 %s 0 0\n' "$NOWX" > "$TKC"
( export HOME="$FAKE_HOME"; . "$SL/lib/collect.sh"; tokens_update "$TP" xupd "$NOWX" )
xp=$(cat "$TKC" 2>/dev/null); xok=1
case "$xp" in *"T ancient"*) echo "  ★ FAIL X2 stale 'ancient' line not pruned: [$xp]"; fail=1; xok=0 ;; esac
case "$xp" in *"T fresh "*) ;; *) echo "  ★ FAIL X2 'fresh' line wrongly dropped: [$xp]"; fail=1; xok=0 ;; esac
case "$xp" in *"T xupd "*) ;; *) echo "  ★ FAIL X2 own line not written: [$xp]"; fail=1; xok=0 ;; esac
[ "$xok" = 1 ] && echo "  X2 prune stale + keep fresh + write own line OK"
rm -f "$TKC" "$TKC".* 2>/dev/null; rm -rf "$TKC".lock 2>/dev/null

echo "── Y. BURN: rate-limit burn-projection alarm — two-point slope from persisted P samples, ↘<ttl>, yellow>30m/red≤30m, sensitivity, gates, retention"
SLC="$FAKE_HOME/.claude/sl-ratelimit-cache"
NOWB=$(jq -n 'now|floor')
# brun: seed exactly ONE old sample, then report cur_used → render (raw, colours kept). rsj pins ctx=5% + five_hour-only.
brun() {  # $1=reset_epoch $2=old_ts $3=old_used $4=cur_used $5=sid → rendered line
  printf 'P %s %s %s\n' "$1" "$2" "$3" > "$SLC"
  run 200 "$(rsj "$4" "$1" "${5:-sBurn}")"
}
brunV() { # $1=variant-dir $2=reset $3=old_ts $4=old_used $5=cur_used $6=sid → render under a BURN_SENS-overridden copy
  local vd=$1; shift
  printf 'P %s %s %s\n' "$1" "$2" "$3" > "$SLC"
  printf '%s' "$(rsj "$4" "$1" "${5:-sBurnV}")" | env COLUMNS=200 HOME="$FAKE_HOME" bash "$WORK/$vd/statusline-command.sh"
}
hasarrow() { python3 -c 'import sys; print("yes" if "↘" in sys.stdin.buffer.read().decode("utf-8","replace") else "no")'; }
bcode() { python3 -c 'import sys,re
m=re.search("\x1b\\[([0-9;]*)m↘", sys.stdin.buffer.read().decode("utf-8","replace")); print(m.group(1) if m else "")'; }
rcode() { python3 -c 'import sys,re
ms=re.findall("\x1b\\[([0-9;]*)m[0-9]+%", sys.stdin.buffer.read().decode("utf-8","replace")); print(ms[-1] if ms else "")'; }
# BURN_SENS variant scripts (mirror the F/T6 copy-and-sed pattern)
mkdir -p "$WORK/bcons/lib" && cp "$SL"/lib/*.sh "$WORK/bcons/lib/"
sed 's/^BURN_SENS="balanced"/BURN_SENS="conservative"/' "$SL/statusline-command.sh" > "$WORK/bcons/statusline-command.sh"
mkdir -p "$WORK/bsens/lib" && cp "$SL"/lib/*.sh "$WORK/bsens/lib/"
sed 's/^BURN_SENS="balanced"/BURN_SENS="sensitive"/' "$SL/statusline-command.sh" > "$WORK/bsens/statusline-command.sh"

# Y1 two-point slope → seconds-to-exhaust: used 33→58 over 1h ⇒ slope 25%/h, remaining 42% ⇒ tte=42·3600/25=6048s=1H40m (task 3.2)
y1=$(brun $((NOWB+9000)) $((NOWB-3600)) 33 58 sTTE | strip)
case "$y1" in *"↘1H40m"*|*"↘1H39m"*|*"↘1H41m"*) echo "  Y1 two-point slope → ↘1H40m (tte = remaining·Δt/Δused) OK" ;;
  *) echo "  ★ FAIL Y1 expected ↘1H40m: [$y1]"; fail=1 ;; esac

# Y2 colour thresholds + capture YREF/RREF: align the rate colour to the burn colour so we pin yellow/red without theme constants (task 3.4)
yref=$(brun $((NOWB+9000)) $((NOWB-600)) 30 40 sYel)   # cur40→rate remaining60=YELLOW; tte=60·600/10=3600s=60m (>30m)=YELLOW
rref=$(brun $((NOWB+9000)) $((NOWB-600)) 70 80 sRed)   # cur80→rate remaining20=RED;    tte=20·600/10=1200s=20m (≤30m)=RED
YREF=$(printf '%s' "$yref" | bcode); RATEY=$(printf '%s' "$yref" | rcode)
RREF=$(printf '%s' "$rref" | bcode); RATER=$(printf '%s' "$rref" | rcode)
ybad=0
[ "$(printf '%s' "$yref" | hasarrow)" = yes ] || { echo "  ★ FAIL Y2 >30m scenario hid the alarm"; ybad=1; }
[ "$(printf '%s' "$rref" | hasarrow)" = yes ] || { echo "  ★ FAIL Y2 ≤30m scenario hid the alarm"; ybad=1; }
{ [ -n "$YREF" ] && [ "$YREF" = "$RATEY" ]; } || { echo "  ★ FAIL Y2 >30m burn not yellow (burn=$YREF rate=$RATEY)"; ybad=1; }
{ [ -n "$RREF" ] && [ "$RREF" = "$RATER" ]; } || { echo "  ★ FAIL Y2 ≤30m burn not red (burn=$RREF rate=$RATER)"; ybad=1; }
[ "$YREF" != "$RREF" ] || { echo "  ★ FAIL Y2 yellow/red colour identical ($YREF)"; ybad=1; }
[ "$ybad" -eq 0 ] && echo "  Y2 >30m yellow / ≤30m red (burn colour = same-tier rate colour) OK" || fail=1

# Y3 exact 30m/31m boundary (spec example): dp large + Δt large so %d truncation absorbs ≤2s clock skew (task 3.4)
y3a=$(brun $((NOWB+9000)) $((NOWB-4200)) 0 70 s30)    # rem30, tte=30·4200/70=1800s=30m → red, text ↘30m
y3b=$(brun $((NOWB+9000)) $((NOWB-4140)) 0 69 s31)    # rem31, tte=31·4140/69=1860s=31m → yellow, text ↘31m
y3bad=0
case "$(printf '%s' "$y3a" | strip)" in *"↘30m"*) ;; *) echo "  ★ FAIL Y3 expected ↘30m: [$(printf '%s' "$y3a" | strip)]"; y3bad=1 ;; esac
case "$(printf '%s' "$y3b" | strip)" in *"↘31m"*) ;; *) echo "  ★ FAIL Y3 expected ↘31m: [$(printf '%s' "$y3b" | strip)]"; y3bad=1 ;; esac
[ "$(printf '%s' "$y3a" | bcode)" = "$RREF" ] || { echo "  ★ FAIL Y3 30m not red"; y3bad=1; }
[ "$(printf '%s' "$y3b" | bcode)" = "$YREF" ] || { echo "  ★ FAIL Y3 31m not yellow"; y3bad=1; }
[ "$y3bad" -eq 0 ] && echo "  Y3 boundary ↘30m red / ↘31m yellow OK" || fail=1

# Y4 end-to-end result matrix (balanced default), 6 rows → hidden / yellow / red (task 3.7)
mbad=0
mrow() { # $1=label $2=reset $3=old_ts $4=old_u $5=cur_u $6=want(hidden|yellow|red)
  local o a; o=$(brun "$2" "$3" "$4" "$5" "mx$1"); a=$(printf '%s' "$o" | hasarrow)
  if [ "$6" = hidden ]; then
    [ "$a" = no ] || { echo "  ★ FAIL Y4[$1] expected hidden, got [$(printf '%s' "$o" | strip)]"; mbad=1; }
  else
    [ "$a" = yes ] || { echo "  ★ FAIL Y4[$1] expected $6 shown, got hidden"; mbad=1; return; }
    local c; c=$(printf '%s' "$o" | bcode)
    if [ "$6" = yellow ]; then [ "$c" = "$YREF" ] || { echo "  ★ FAIL Y4[$1] not yellow (code=$c)"; mbad=1; }
    else [ "$c" = "$RREF" ] || { echo "  ★ FAIL Y4[$1] not red (code=$c)"; mbad=1; }; fi
  fi
}
mrow 1 $((NOWB+7800)) $((NOWB-3600))  8 10 hidden   # 90% rem, slow burn, exhaust ~45h ≫ 2H10m reset → before-reset gate fails
mrow 2 $((NOWB+1800)) $((NOWB-3600)) 40 50 hidden   # 50% rem, tte 5h ≫ 30m reset → hidden
mrow 3 $((NOWB+7200)) $((NOWB-3600)) 70 70 hidden   # flat (slope 0) → slope gate fails
mrow 4 $((NOWB+7800)) $((NOWB-3600)) 33 58 yellow   # 42% rem, tte 1H40m < reset, within balanced ceiling, >30m → yellow
mrow 5 $((NOWB+7200)) $((NOWB-600))  70 80 red      # 20% rem, tte 20m ≤30m → red
mrow 6 $((NOWB+7200)) $((NOWB-60))    6 10 red      # 90% rem but bursting, tte ~22m ≤30m → red
[ "$mbad" -eq 0 ] && echo "  Y4 end-to-end matrix (hidden×3 / yellow / red×2) OK" || fail=1

# Y5 configurable sensitivity knob: same projection, three levels differ (task 3.6)
sbad=0
c60=$(brunV bcons $((NOWB+9000))  $((NOWB-600))  30 40 | hasarrow)   # 60m: conservative (≤30m) → hidden
b60=$(brun        $((NOWB+9000))  $((NOWB-600))  30 40 | hasarrow)   # 60m: balanced default → shown
s60=$(brunV bsens $((NOWB+9000))  $((NOWB-600))  30 40 | hasarrow)   # 60m: sensitive → shown
b120=$(brun        $((NOWB+14400)) $((NOWB-1200)) 30 40 | hasarrow)  # 120m: balanced (>~90m+) → hidden
s120=$(brunV bsens $((NOWB+14400)) $((NOWB-1200)) 30 40 | hasarrow)  # 120m: sensitive (before reset) → shown
c25=$(brunV bcons $((NOWB+9000))  $((NOWB-750))  70 80 | hasarrow)   # 25m: conservative (≤30m) → shown
[ "$c60" = no ]  || { echo "  ★ FAIL Y5 conservative 60m should hide"; sbad=1; }
[ "$b60" = yes ] || { echo "  ★ FAIL Y5 balanced 60m should show"; sbad=1; }
[ "$s60" = yes ] || { echo "  ★ FAIL Y5 sensitive 60m should show"; sbad=1; }
[ "$b120" = no ] || { echo "  ★ FAIL Y5 balanced 120m should hide"; sbad=1; }
[ "$s120" = yes ] || { echo "  ★ FAIL Y5 sensitive 120m should show"; sbad=1; }
[ "$c25" = yes ] || { echo "  ★ FAIL Y5 conservative 25m should show"; sbad=1; }
[ "$sbad" -eq 0 ] && echo "  Y5 conservative/balanced/sensitive gate the same projection differently OK" || fail=1

# Y6 depletion-only direction: a rising remaining budget (slope<0) emits no glyph at all (task 3.5)
case "$(brun $((NOWB+9000)) $((NOWB-1800)) 50 40 sDep | strip)" in
  *↘*|*↗*) echo "  ★ FAIL Y6 falling/rising emitted an indicator"; fail=1 ;;
  *) echo "  Y6 rising remaining (slope<0) → no ↘/↗ glyph OK" ;;
esac

# Y7 insufficient samples: only the current frame's own sample (no seed) → <2 in-horizon → no slope, no alarm (task 3.2)
rm -f "$SLC"
case "$(run 200 "$(rsj 58 "$((NOWB+9000))" sOne)" | strip)" in
  *↘*) echo "  ★ FAIL Y7 single sample produced an alarm"; fail=1 ;;
  *) echo "  Y7 <2 in-horizon samples → no alarm OK" ;; esac

# Y8 bounded retention: 9 frames each append one sample → window capped at 5 P-lines (task 3.1)
rm -f "$SLC"; RB=$((NOWB+9000))
for i in 1 2 3 4 5 6 7 8 9; do run 200 "$(rsj $((10+i)) "$RB" sRet)" >/dev/null; done
pc=$(grep -c "^P $RB " "$SLC" 2>/dev/null); pc=${pc:-0}
[ "$pc" -eq 5 ] && echo "  Y8 9 frames → series bounded to 5 samples/window OK" || { echo "  ★ FAIL Y8 expected 5 P-lines, got $pc"; fail=1; }

# Y9 expired-window pruning: a sample whose resets_at ≤ now is dropped on rewrite; the live window's sample survives (task 3.1)
PASTR=$((NOWB-100)); RL=$((NOWB+9000))
printf 'P %s %s 50\nP %s %s 60\n' "$PASTR" "$((NOWB-200))" "$RL" "$((NOWB-50))" > "$SLC"
run 200 "$(rsj 30 "$RL" sPrune)" >/dev/null
c9=$(cat "$SLC" 2>/dev/null); y9bad=0
case "$c9" in *"P $PASTR "*) echo "  ★ FAIL Y9 expired-window sample not pruned: [$c9]"; y9bad=1 ;; esac
case "$c9" in *"P $RL "*) ;; *) echo "  ★ FAIL Y9 live-window sample wrongly dropped: [$c9]"; y9bad=1 ;; esac
[ "$y9bad" -eq 0 ] && echo "  Y9 expired-window samples pruned, live kept OK" || fail=1

# Y10 sampled quantity is the reconciled authority, not the frozen report (task 3.1)
RA=$((NOWB+9000)); OLDA=$((NOWB-5000)); RECA=$((NOWB-100))
printf 'S sRec %s\nS sOldF %s\nW %s 75 %s\n' "$RECA" "$OLDA" "$RA" "$RECA" > "$SLC"   # authority 75 set by a RECENT session
run 200 "$(rsj 40 "$RA" sOldF)" >/dev/null   # an OLDER frozen session reports 40 but must adopt 75 → the sample records 75
case "$(grep "^P $RA " "$SLC")" in
  *" 75") echo "  Y10 sample records reconciled authority (75), not frozen report (40) OK" ;;
  *" 40") echo "  ★ FAIL Y10 sample recorded the frozen 40"; fail=1 ;;
  *) echo "  ★ FAIL Y10 no/odd P sample: [$(grep "^P $RA " "$SLC")]"; fail=1 ;; esac

# Y11 the alarm is width-bounded like every other left segment — burn-active frame stays single-line, never overflows (task 3.3)
printf 'P %s %s 33\n' "$((NOWB+9000))" "$((NOWB-3600))" > "$SLC"
JBW=$(rsj 58 "$((NOWB+9000))" sBW); wbad=0
for cols in 60 90 120 160; do
  o=$(printf '%s' "$JBW" | env COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh")
  nl=$(printf '%s' "$o" | grep -c ''); w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]                 || { echo "  ★ FAIL Y11 C=$cols not single line: $nl"; wbad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL Y11 C=$cols overflow width=$w > $((cols-EDGE_PAD))"; wbad=1; }
done
[ "$wbad" -eq 0 ] && echo "  Y11 burn-active frame single-line + width-bounded 60..160 OK" || fail=1
rm -f "$SLC" "$TKC" "$TKC".* 2>/dev/null; rm -rf "$TKC".lock 2>/dev/null

echo "── Z. ADAPTIVE-LAYOUT: fixed 14-step sacrifice order — width invariant, segment forms/priority, monotonic drop order, shrink-before-drop, core always remains"
# Full-set fixture on the hermetic GREPO (deterministic git segment: branch "grepo"/basename, no dirty/diffstat) so the degrade widths
# don't flake on this checkout's working tree. ctx=42% (bar present), worktree, both quotas, last-msg, long session name all populated.
JZ=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:42}, worktree:{name:"wt1"},
    rate_limits:{ five_hour:{used_percentage:40, resets_at:(now+9000|floor)},
                  seven_day:{used_percentage:86, resets_at:(now+108000|floor)} },
    effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"Consolidate statusline from two rows to one" }')
barcells() { python3 -c 'import sys; print(sys.stdin.buffer.read().decode("utf-8","replace").count("48;2"))'; }   # ctx bar = 12 bg cells

# Z1 (task 4.1) Drawable-width invariant + width-tiered: sweep many COLUMNS (incl. 1-2 col pathological) → always single line, width ≤ edge.
echo "── Z1. drawable-width invariant: every width emits ONE line ≤ term_cols-EDGE_PAD, no wrap (J/P/M method over the full degrade range)"
# Sweep down to cols=EDGE_PAD+1 (drawable width 1), the smallest POSITIVE drawable width — the strict width≤edge invariant. The
# pathological cols≤EDGE_PAD case (drawable width ≤0, where any glyph overflows) is the degraded "as far as drawable allows" fallback,
# asserted no-crash/single-line in Z5 and test R, not against an impossible ≤0 width bound.
z1bad=0
for cols in 200 160 140 130 120 110 100 90 80 70 60 50 40 30 24 20 17 10 5 $((EDGE_PAD+1)); do
  o=$(run "$cols" "$JZ"); nl=$(printf '%s' "$o" | grep -c ''); w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]                 || { echo "  ★ FAIL Z1 C=$cols not single line: $nl"; z1bad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL Z1 C=$cols overflow width=$w > $((cols-EDGE_PAD))"; z1bad=1; }
done
[ "$z1bad" -eq 0 ] && echo "  Z1 200..$((EDGE_PAD+1)) cols: single line, never exceeds drawable width OK" || fail=1

# Z2 (task 4.2) Per-segment forms: model compacts "Opus 4.8 (1M)"→"Opus", ctx bar collapses to plain N%, 5h collapses to remaining% only.
echo "── Z2. per-segment compact forms: model→Opus, ctx bar→plain N%, 5h→remaining% (compact preferred over drop)"
z2bad=0
z2full=$(run 200 "$JZ"); z2fp=$(printf '%s' "$z2full" | nocol)
[ "$(printf '%s' "$z2full" | barcells)" -eq 12 ] || { echo "  ★ FAIL Z2 wide: ctx bar (12 cells) absent"; z2bad=1; }
case "$z2fp" in *"Opus 4.8 (1M)"*) ;; *) echo "  ★ FAIL Z2 wide: full model name absent"; z2bad=1 ;; esac
z2c=$(run 130 "$JZ"); z2cp=$(printf '%s' "$z2c" | nocol)
[ "$(printf '%s' "$z2c" | barcells)" -eq 0 ] || { echo "  ★ FAIL Z2 mid: ctx bar not collapsed to plain N%"; z2bad=1; }
case "$z2cp" in *"42%"*) ;; *) echo "  ★ FAIL Z2 mid: ctx % lost"; z2bad=1 ;; esac
z2m=$(run 90 "$JZ" | nocol)
case "$z2m" in *"grepo │ Opus │"*) ;; *) echo "  ★ FAIL Z2 model not compacted to 'Opus': [$z2m]"; z2bad=1 ;; esac
case "$z2m" in *"Opus 4.8"*) echo "  ★ FAIL Z2 model still in full form at C=90: [$z2m]"; z2bad=1 ;; esac
z2q=$(run 30 "$JZ" | nocol)   # 5h collapsed to remaining% only (countdown "2H..m" dropped), session gone
case "$z2q" in *"2H"*m*) echo "  ★ FAIL Z2 5h countdown not dropped at C=30: [$z2q]"; z2bad=1 ;; esac
case "$z2q" in *"60%"*) ;; *) echo "  ★ FAIL Z2 5h remaining% lost at C=30: [$z2q]"; z2bad=1 ;; esac
[ "$z2bad" -eq 0 ] && echo "  Z2 model/ctx/5h compact forms render at their tiers OK" || fail=1

# Z3 (task 4.3) Fixed sacrifice order: as width decreases, segments disappear/compact in the exact 14-step order; the visible set is monotonic.
echo "── Z3. fixed sacrifice order: diffstat→worktree→ctx→git→last-msg→7d→model→session-trunc→session-drop→5h-compact, monotonic"
z3bad=0
has() { case "$1" in *"$2"*) echo y ;; *) echo n ;; esac; }   # $1=plain line $2=needle → y/n
p200=$(run 200 "$JZ" | nocol); p130=$(run 130 "$JZ" | nocol); p120=$(run 120 "$JZ" | nocol)
p110=$(run 110 "$JZ" | nocol); p95=$(run 95 "$JZ" | nocol);  p80=$(run 80 "$JZ" | nocol)
# step 2/3: diffstat present full, gone by 130; worktree present full, gone by 130
[ "$(has "$p200" "[wt:wt1]")" = y ] || { echo "  ★ FAIL Z3 worktree absent at full width"; z3bad=1; }
[ "$(has "$p130" "[wt:wt1]")" = n ] || { echo "  ★ FAIL Z3 worktree not dropped by C=130 (step 3)"; z3bad=1; }
# step 4: ctx bar present full, collapsed by 130 (checked in Z2); step 5: git "grepo │"-as-right gone by 120 but last-msg still there
[ "$(has "$p130" " main")" = y ] || { echo "  ★ FAIL Z3 git not present at C=130"; z3bad=1; }
[ "$(has "$p120" " main")" = n ] || { echo "  ★ FAIL Z3 git not dropped by C=120 (step 5)"; z3bad=1; }
[ "$(has "$p120" "19:38")" = y ] || { echo "  ★ FAIL Z3 last-msg dropped too early (before git): order violated at C=120"; z3bad=1; }
# step 6: last-msg gone by 110; step 7: 7d "1D" gone by 95
[ "$(has "$p110" "19:38")" = n ] || { echo "  ★ FAIL Z3 last-msg not dropped by C=110 (step 6)"; z3bad=1; }
[ "$(has "$p110" "1D")" = y ]    || { echo "  ★ FAIL Z3 7d dropped before last-msg: order violated at C=110"; z3bad=1; }
[ "$(has "$p95"  "1D")" = n ]    || { echo "  ★ FAIL Z3 7d quota not dropped by C=95 (step 7)"; z3bad=1; }
# step 10: model fully gone by 80 (compact step 9 verified in Z2)
[ "$(has "$p80" "Opus")" = n ]   || { echo "  ★ FAIL Z3 model not dropped by C=80 (step 10)"; z3bad=1; }
[ "$z3bad" -eq 0 ] && echo "  Z3 segments vanish/compact in the fixed 14-step order, monotonically OK" || fail=1

# Z4 (task 4.4) Shrink-before-drop: at a mid width the session is head-truncated with … (not dropped); JXLONG forces the right-truncation tier.
echo "── Z4. shrink before drop: mid-width session is … -truncated (not vanished), junction │ retained"
z4=$(run 120 "$JXLONG" | nocol); z4bad=0
case "$z4" in *"a very"*) ;; *) echo "  ★ FAIL Z4 session vanished instead of truncating: [$z4]"; z4bad=1 ;; esac
case "$z4" in *"…"*) ;; *) echo "  ★ FAIL Z4 no … truncation marker on the session: [$z4]"; z4bad=1 ;; esac
case "$z4" in *"truncation"*) echo "  ★ FAIL Z4 session shown whole (not truncated) at C=120: [$z4]"; z4bad=1 ;; esac
[ "$z4bad" -eq 0 ] && echo "  Z4 session truncates with … before being dropped OK" || fail=1

# Z5 (task 4.5) Core always remains: at the narrowest widths (incl. 1-2 col, perl present and absent) path basename + ctx% survive, single line.
echo "── Z5. core always remains: path basename + ctx% kept at the narrowest widths (1-2 col pathological), single line, no crash"
z5bad=0
for cols in 20 17 10; do   # core "grepo 42%" tier: both the path (head-truncated as needed) and the ctx% must be present
  o=$(run "$cols" "$JZ"); pl=$(printf '%s' "$o" | nocol); nl=$(printf '%s' "$o" | grep -c ''); w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]                 || { echo "  ★ FAIL Z5 C=$cols not single line"; z5bad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL Z5 C=$cols overflow width=$w"; z5bad=1; }
  case "$pl" in *"42%"*) ;; *) echo "  ★ FAIL Z5 C=$cols ctx% removed from core: [$pl]"; z5bad=1 ;; esac
  case "$pl" in g*) ;; *) echo "  ★ FAIL Z5 C=$cols path basename head not retained: [$pl]"; z5bad=1 ;; esac   # path basename head ("g…")
done
# 1-2 col pathological + perl absent (reuse the failing perl stub at $WORK/bin/perl planted by test M): no crash, single line, clean stderr
for cols in 1 2; do
  err=$(printf '%s' "$JZ" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" 2>&1 >/dev/null)
  o=$(printf '%s' "$JZ" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" 2>/dev/null)
  [ -z "$err" ]                              || { echo "  ★ FAIL Z5 C=$cols (perl absent) stderr noise: [$err]"; z5bad=1; }
  [ "$(printf '%s' "$o" | grep -c '')" -eq 1 ] || { echo "  ★ FAIL Z5 C=$cols (perl absent) not single line"; z5bad=1; }
done
[ "$z5bad" -eq 0 ] && echo "  Z5 core (path basename + ctx%) survives 20..1 cols, perl present/absent, single line OK" || fail=1

echo "── G. perf: 10 frames"
time (for _ in 1 2 3 4 5 6 7 8 9 10; do run 140 "$J" >/dev/null; done)

if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME FAILED"; exit 1; fi
