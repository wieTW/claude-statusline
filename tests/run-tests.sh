#!/usr/bin/env bash
# statusline single-line integration tests: fake HOME + controlled COLUMNS run the real script, asserting alignment / fallback / content.
# All run in-process via direct calls — no export/bash -c (a prior version's exported-function env passing blew up).
# Self-locating: SL = the statusline project root (this script lives in <root>/tests/). Survives directory renames.
# Work dir is a fresh mktemp (NOT /tmp/sl-test — that hardcoded path is exactly why the old harness vanished on tmp-clear).
set -u
SL=$(cd "$(dirname "$0")/.." && pwd)
SLDIR=$(basename "$SL")   # project-dir basename, shown as the path segment; derived (not hardcoded) so the order check survives a repo rename
SLBR=$(git -C "$SL" branch --show-current 2>/dev/null); SLBR=${SLBR:-main}  # current worktree branch; the order check must not assume main
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Wall-clock second this run began. Only T4(b) uses it: that block audits the user's REAL shared cache, and it must be able to
# tell a row THIS run could have stamped (timestamp >= HARNESS_T0) from one that was already on disk when the run started.
# Taken here, before the first frame renders, so no write by any section of this harness can predate it.
HARNESS_T0=$(date +%s)
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
  "$SLDIR"*"Opus 4.8(1M)"*ultra*"6%"*"77%"*"16%"*"06-07 19:38"*"$SLBR"*"Consolidate statusline from two rows to one") echo "  order OK" ;;
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

echo "── T. RATE-SYNC: per-CLASS (W5/W7) authority = the freshest observation — climb / cap-raise drop / anti-reversal / persistence / re-key / toggle / prune / legacy / roll-adoption / class-isolation / sanity-bound"
SLC="$FAKE_HOME/.claude/sl-ratelimit-cache"
nocol() { sed 's/\x1b\[[0-9;]*m//g'; }
# Fixture session ids MUST be UUID-shaped. lib/collect.sh's sid_persistable gate only lets a real Claude Code session id
# (8-4-4-4-12 lowercase hex) persist an observation into the shared cache; a readable label like "sessOld" takes the
# read-only degradation path instead, so every write scenario below would silently pass for the wrong reason. sidof()
# maps a label to a stable UUID-shaped id so the call sites keep their names; seeds and asserts call it for the same label.
sidof() {  # $1=fixture label → its stable UUID-shaped session id
  local h; h=$(printf 'sl-fixture-%s' "$1" | md5 -q)
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}
rsj() {  # $1=used% $2=resets_at $3=session_id → minimal five_hour-only json (ctx pinned 5% so the only other "%" token is the rate)
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$(sidof "${3:-sl-selftest}")" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{five_hour:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
# Scenarios pre-seed controlled observation epochs; the one legacy fixture also checks first_seen-based upgrade behavior.
NOW=$(jq -n 'now|floor'); RT=$((NOW + 9000))   # active window key (~2.5h to reset)
OLD=$((NOW - 5000)); RECENT=$((NOW - 100))     # an old vs a recent session's first_seen
# T1 climb: authority is an OLD session at 40; a NEW session (first_seen=now > OLD) reports higher 75 → adopt → remaining 25%
printf "S $(sidof sessOld) %s %s 40 %s - - -\nW5 %s 40 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
t1=$(run 120 "$(rsj 75 "$RT" sessNew)" | nocol)
case "$t1" in *" 25%"*) echo "  T1 newer session raises (climb) → 25% OK" ;; *) echo "  ★ FAIL T1 expected 25% remaining: [$t1]"; fail=1 ;; esac
# T2 cap-raise (THE incident): authority OLD at 70; a NEW session reports LOWER 38 → adopt → remaining 62%, not the stale 30%
printf "S $(sidof sessOld) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
t2=$(run 120 "$(rsj 38 "$RT" sessNew)" | nocol)
case "$t2" in *" 62%"*) echo "  T2 newer session lowers (cap raised) → 62%, not stale 30% OK" ;; *" 30%"*) echo "  ★ FAIL T2 stuck on stale high 70 (showed 30%): [$t2]"; fail=1 ;; *) echo "  ★ FAIL T2 expected 62%: [$t2]"; fail=1 ;; esac
# T3 older can't override + persistence: authority set by a RECENT session at 75; an OLD frozen-low session reports 40 → ignored → stays 25% (setter need not be rendering)
printf "S $(sidof sessRecent) %s %s 75 %s - - -\nS $(sidof sessOldFrozen) %s %s 40 %s - - -\nW5 %s 75 %s\n" "$RECENT" "$RT" "$RECENT" "$OLD" "$RT" "$OLD" "$RT" "$RECENT" > "$SLC"
t3=$(run 120 "$(rsj 40 "$RT" sessOldFrozen)" | nocol)
case "$t3" in *" 25%"*) echo "  T3 older session can't lower authority (no under-report) → 25% OK" ;; *" 60%"*) echo "  ★ FAIL T3 old frozen-low session overrode authority (showed 60%): [$t3]"; fail=1 ;; *) echo "  ★ FAIL T3 expected 25%: [$t3]"; fail=1 ;; esac
# T4 anti-reversal: after a newer session lowers 70→38, the OLD frozen-HIGH session rendering again must NOT bounce it back to 30%
printf "S $(sidof sessOld) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
run 120 "$(rsj 38 "$RT" sessNew)" >/dev/null     # newer session lowers to 38 (becomes authority @ now)
t4=$(run 120 "$(rsj 70 "$RT" sessOld)" | nocol)  # the old session reports its stale 70 again
case "$t4" in *" 62%"*) echo "  T4 stale-high old session can't undo the cap-raise → still 62% OK" ;; *" 30%"*) echo "  ★ FAIL T4 reverted to stale 70 (showed 30%): [$t4]"; fail=1 ;; *) echo "  ★ FAIL T4 expected 62%: [$t4]"; fail=1 ;; esac
# T5 keying: a session reporting a NEWER window re-keys the class to its own report — it must NOT inherit the old window's value
printf "S $(sidof sessOld) %s %s 40 %s - - -\nW5 %s 40 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
t5=$(run 120 "$(rsj 0 "$((NOW + 22000))" sessOther)" | nocol)
case "$t5" in *" 100%"*) echo "  T5 separate window not polluted → 100% OK" ;; *) echo "  ★ FAIL T5 window polluted: [$t5]"; fail=1 ;; esac
# T6 toggle: RL_SYNC=false must ignore the cache entirely → a frozen used=0 shows the raw 100% (cache still holds the RT authority)
printf "S $(sidof sessOld) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
mkdir -p "$WORK/nosync/lib" && cp "$SL"/lib/*.sh "$WORK/nosync/lib/"
sed 's/^RL_SYNC=true/RL_SYNC=false/' "$SL/statusline-command.sh" > "$WORK/nosync/statusline-command.sh"
t6=$(printf '%s' "$(rsj 0 "$RT" sessOld)" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$WORK/nosync/statusline-command.sh" | nocol)
case "$t6" in *" 100%"*) echo "  T6 RL_SYNC=false ignores cache (100%) OK" ;; *) echo "  ★ FAIL T6 false-path consulted cache: [$t6]"; fail=1 ;; esac
# T7 prune: a frame whose window already expired (resets_at<=now) must NOT be persisted as a W line
rm -f "$SLC"; RTpast=$((NOW - 100))
run 120 "$(rsj 90 "$RTpast" sessX)" >/dev/null
if grep -q "^W5 $RTpast " "$SLC" 2>/dev/null; then echo "  ★ FAIL T7 expired window persisted to cache"; fail=1; else echo "  T7 expired window pruned from cache OK"; fi
# T8 legacy: an old-format "<resets_at> <used>" line is ignored (dropped), not read as an authority
printf '%s 99\n' "$RT" > "$SLC"
t8=$(run 120 "$(rsj 10 "$RT" sessZ)" | nocol)
case "$t8" in *" 90%"*) echo "  T8 legacy 2-col line ignored → own 90% OK" ;; *" 1%"*) echo "  ★ FAIL T8 legacy line treated as authority (showed 1%): [$t8]"; fail=1 ;; *) echo "  ★ FAIL T8 expected 90%: [$t8]"; fail=1 ;; esac
# T9 (1.3) RL_REG_TTL clamp: an undersized OR non-numeric RL_REG_TTL must be raised to the 604800 floor, so a still-alive old session's
# registry (S) line is NOT pruned — pruning it makes that session re-rank as NEW next frame and seize authority with its frozen used%.
t9bad=0; OLDF=$((NOW-18000))   # first_seen 5h ago, still well within the 7d window
for ttl in 3600 abc; do
  mkdir -p "$WORK/ttl$ttl/lib" && cp "$SL"/lib/*.sh "$WORK/ttl$ttl/lib/"
  sed "s/^RL_REG_TTL=604800/RL_REG_TTL=$ttl/" "$SL/statusline-command.sh" > "$WORK/ttl$ttl/statusline-command.sh"
  printf "S $(sidof sOldLive) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLDF" "$RT" "$OLDF" "$RT" "$OLDF" > "$SLC"
  printf '%s' "$(rsj 70 "$RT" sOldLive)" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$WORK/ttl$ttl/statusline-command.sh" >/dev/null 2>&1
  grep -q "^S $(sidof sOldLive) " "$SLC" 2>/dev/null || { echo "  ★ FAIL T9 RL_REG_TTL=$ttl pruned a live session's registry (clamp missing)"; t9bad=1; }
done
[ "$t9bad" -eq 0 ] && echo "  T9 undersized/non-numeric RL_REG_TTL clamped to 604800 floor (live registry kept) OK" || fail=1
# T10 window-roll adoption (regression: frozen sessions went permanently stale after a roll — showed the pre-roll used% and a
# perpetual 0m countdown): a frame whose OWN resets_at expired must adopt the live per-class authority — value AND resets_at
# (countdown) — for both classes, and must sample the P series under the adopted (effective) live key.
rsj2() {  # $1=used5 $2=reset5 $3=used7 $4=reset7 $5=session_id → five_hour+seven_day json
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$(sidof "${5:-sl-selftest}")" --argjson u5 "$1" --argjson r5 "$2" --argjson u7 "$3" --argjson r7 "$4" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{five_hour:{used_percentage:$u5, resets_at:$r5}, seven_day:{used_percentage:$u7, resets_at:$r7}},
    session_id:$sid, transcript_path:$tp }'; }
RT7=$((NOW + 300000))
printf "S $(sidof sFrozen) %s %s 87 %s %s 79 %s\nS $(sidof sFresh) %s %s 3 %s %s 24 %s\nW5 %s 3 %s\nW7 %s 24 %s\n" \
  "$OLD" "$((NOW-2000))" "$OLD" "$((NOW-1000))" "$OLD" \
  "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" > "$SLC"
t10=$(run 200 "$(rsj2 87 $((NOW-2000)) 79 $((NOW-1000)) sFrozen)" | nocol)
t10bad=0
case "$t10" in *"2H"*" 97%"*) ;; *) echo "  ★ FAIL T10 5h did not adopt live authority value+countdown: [$t10]"; t10bad=1 ;; esac
case "$t10" in *" 76%"*) ;; *) echo "  ★ FAIL T10 7d did not adopt live authority: [$t10]"; t10bad=1 ;; esac
case "$t10" in *" 13%"*|*" 21%"*) echo "  ★ FAIL T10 frozen pre-roll used% leaked into the display: [$t10]"; t10bad=1 ;; esac
grep -q "^P $RT " "$SLC" 2>/dev/null || { echo "  ★ FAIL T10 frozen frame did not sample under the effective live key"; t10bad=1; }
[ "$t10bad" -eq 0 ] && echo "  T10 post-roll frame adopts live W5+W7 authority (value + countdown + effective-key sample) OK" || fail=1
# T11 class isolation: with only a live W7 authority, an expired 5h window must NOT cross-adopt it — the 5h segment keeps the
# frozen fallback (own value + 0m countdown, the documented no-authority residual), while 7d adopts its own class authority.
printf "S $(sidof sFrozen) %s %s 87 %s %s 79 %s\nS $(sidof sFresh) %s - - - %s 24 %s\nW7 %s 24 %s\n" \
  "$OLD" "$((NOW-2000))" "$OLD" "$((NOW-1000))" "$OLD" "$RECENT" "$RT7" "$RECENT" "$RT7" "$RECENT" > "$SLC"
t11=$(run 200 "$(rsj2 87 $((NOW-2000)) 79 $((NOW-1000)) sFrozen)" | nocol)
t11bad=0
case "$t11" in *"0m 13%"*) ;; *) echo "  ★ FAIL T11 expected frozen 5h fallback (0m 13%): [$t11]"; t11bad=1 ;; esac
case "$t11" in *" 76%"*) ;; *) echo "  ★ FAIL T11 7d did not adopt its class authority: [$t11]"; t11bad=1 ;; esac
if grep -q "^W5 " "$SLC" 2>/dev/null; then echo "  ★ FAIL T11 an expired 5h report was persisted as authority"; t11bad=1; fi
[ "$t11bad" -eq 0 ] && echo "  T11 class isolation: 5h keeps frozen fallback, 7d adopts W7 OK" || fail=1
# T12 window-key sanity bound: an absurd far-future key (>= now+691200, 8d) must be refused on load AND on report — it can never
# become an immortal authority (the real user cache carried a W 9999999999 line for over a month before this guard).
printf "S $(sidof sFroz) %s %s 10 %s - - -\nW5 9999999999 28 %s\n" "$OLD" "$RT" "$OLD" "$RECENT" > "$SLC"
t12=$(run 200 "$(rsj 10 "$RT" sFroz)" | nocol)
t12bad=0
case "$t12" in *" 90%"*) ;; *) echo "  ★ FAIL T12 absurd stored key won authority (expected own 90%): [$t12]"; t12bad=1 ;; esac
if grep -q "^W[57] 9999999999 " "$SLC" 2>/dev/null; then echo "  ★ FAIL T12 absurd authority key survived the rewrite"; t12bad=1; fi
run 200 "$(rsj 10 9999999999 sAbsRep)" >/dev/null
if grep -q "^W[57] 9999999999 " "$SLC" 2>/dev/null; then echo "  ★ FAIL T12 absurd reported key became authority"; t12bad=1; fi
[ "$t12bad" -eq 0 ] && echo "  T12 far-future keys refused on load and report (no immortal authority) OK" || fail=1
# T13 legacy/malformed migration: the one retained 3-field S fixture upgrades in place, valid 9-field S survives,
# wrong-arity S and untagged W are dropped, and the legacy session seeds W5 because no valid authority exists.
printf "S $(sidof sOld2) %s\nS sNine %s %s 20 %s - - -\nS sBroken %s %s 20\nW %s 40 %s\n" \
  "$OLD" "$RECENT" "$RT" "$RECENT" "$OLD" "$RT" "$RT" "$RECENT" > "$SLC"
t13=$(run 200 "$(rsj 75 "$RT" sOld2)" | nocol)
t13bad=0
case "$t13" in *" 25%"*) ;; *"60%"*) echo "  ★ FAIL T13 legacy W line adopted as authority (showed 60%): [$t13]"; t13bad=1 ;; *) echo "  ★ FAIL T13 expected 25%: [$t13]"; t13bad=1 ;; esac
if grep -q "^W $RT " "$SLC" 2>/dev/null; then echo "  ★ FAIL T13 legacy W line carried forward"; t13bad=1; fi
grep -q "^W5 $RT 75 " "$SLC" 2>/dev/null || { echo "  ★ FAIL T13 own report did not seed the class authority"; t13bad=1; }
awk -v r="$RT" -v fs="$OLD" -v sid="$(sidof sOld2)" '$1=="S"&&NF==9&&$2==sid&&$3==fs&&$4==r&&$5==75&&$6==fs&&$7=="-"&&$8=="-"&&$9=="-"{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T13 legacy S row was not upgraded to 9 fields with first_seen observation"; t13bad=1; }
grep -q "^S sNine $RECENT $RT 20 $RECENT - - -$" "$SLC" || { echo "  ★ FAIL T13 valid 9-field S row did not survive"; t13bad=1; }
grep -q '^S sBroken ' "$SLC" && { echo "  ★ FAIL T13 wrong-arity S row survived"; t13bad=1; }
[ "$t13bad" -eq 0 ] && echo "  T13 legacy S upgraded; valid 9-field S kept; malformed S and untagged W dropped OK" || fail=1

# T14 older active session overrides an idle newer session when its reported pair changes.
printf "S $(sidof sActive) %s %s 40 %s %s 24 %s\nS $(sidof sIdle) %s %s 70 %s %s 24 %s\nW5 %s 70 %s\nW7 %s 24 %s\n" \
  "$OLD" "$RT" "$OLD" "$RT7" "$OLD" "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" > "$SLC"
t14=$(run 200 "$(rsj2 75 "$RT" 24 "$RT7" sActive)" | nocol); t14bad=0
case "$t14" in *" 25%"*) ;; *) echo "  ★ FAIL T14 older active session did not replace idle authority: [$t14]"; t14bad=1 ;; esac
if ! awk -v r="$RT" -v min="$RECENT" '$1=="W5"&&NF==4&&$2==r&&$3==75&&$4>min{ok=1} END{exit !ok}' "$SLC"; then echo "  ★ FAIL T14 W5 did not persist the changed pair with fresh observed_at"; t14bad=1; fi
if ! awk -v r="$RT" -v min="$RECENT" -v sid="$(sidof sActive)" '$1=="S"&&NF==9&&$2==sid&&$4==r&&$5==75&&$6>min{ok=1} END{exit !ok}' "$SLC"; then echo "  ★ FAIL T14 active S row did not record the changed pair"; t14bad=1; fi
[ "$t14bad" -eq 0 ] && echo "  T14 older active session overrides idle newer session with freshest observation OK" || fail=1

# T17 follows T14: the idle session reports its unchanged stale pair and must not take authority back.
wbefore=$(grep "^W5 $RT " "$SLC")
t17=$(run 200 "$(rsj2 70 "$RT" 24 "$RT7" sIdle)" | nocol); t17bad=0
case "$t17" in *" 25%"*) ;; *) echo "  ★ FAIL T17 idle unchanged session re-took authority: [$t17]"; t17bad=1 ;; esac
wafter=$(grep "^W5 $RT " "$SLC")
[ "$wbefore" = "$wafter" ] || { echo "  ★ FAIL T17 W5 changed: before=[$wbefore] after=[$wafter]"; t17bad=1; }
awk -v r="$RT" -v o="$RECENT" -v sid="$(sidof sIdle)" '$1=="S"&&NF==9&&$2==sid&&$4==r&&$5==70&&$6==o{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T17 idle S row refreshed its carried observation"; t17bad=1; }
[ "$t17bad" -eq 0 ] && echo "  T17 idle unchanged session cannot re-take authority OK" || fail=1

# T15 a cap increase can lower used%; the changed lower pair is still the freshest observation.
printf "S $(sidof sActive) %s %s 70 %s - - -\nS $(sidof sIdle) %s %s 70 %s - - -\nW5 %s 70 %s\n" \
  "$OLD" "$RT" "$OLD" "$RECENT" "$RT" "$RECENT" "$RT" "$RECENT" > "$SLC"
t15=$(run 200 "$(rsj 38 "$RT" sActive)" | nocol); t15bad=0
case "$t15" in *" 62%"*) ;; *) echo "  ★ FAIL T15 cap-raise drop was not adopted: [$t15]"; t15bad=1 ;; esac
awk -v r="$RT" -v min="$RECENT" '$1=="W5"&&NF==4&&$2==r&&$3==38&&$4>min{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T15 lower W5 value/observation not persisted"; t15bad=1; }
awk -v r="$RT" -v min="$RECENT" -v sid="$(sidof sActive)" '$1=="S"&&NF==9&&$2==sid&&$4==r&&$5==38&&$6>min{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T15 active S row did not record the lowered pair"; t15bad=1; }
[ "$t15bad" -eq 0 ] && echo "  T15 cap-raise drop adopted by freshest observation OK" || fail=1

# T16 a changed reset key is a fresh observation and re-keys the whole class without retaining the old W5.
RTOLD=$((NOW+120)); RTNEW=$((NOW+9000))
printf "S $(sidof sActive) %s %s 87 %s - - -\nS $(sidof sIdle) %s %s 87 %s - - -\nW5 %s 87 %s\n" \
  "$OLD" "$RTOLD" "$OLD" "$RECENT" "$RTOLD" "$RECENT" "$RTOLD" "$RECENT" > "$SLC"
t16=$(run 200 "$(rsj 3 "$RTNEW" sActive)" | nocol); t16bad=0
case "$t16" in *" 97%"*) ;; *) echo "  ★ FAIL T16 rolled window was not adopted: [$t16]"; t16bad=1 ;; esac
awk -v r="$RTNEW" -v min="$RECENT" '$1=="W5"&&NF==4&&$2==r&&$3==3&&$4>min{n++} END{exit !(n==1)}' "$SLC" || { echo "  ★ FAIL T16 new W5 key/value/observation not persisted exactly once"; t16bad=1; }
awk -v r="$RTNEW" -v min="$RECENT" -v sid="$(sidof sActive)" '$1=="S"&&NF==9&&$2==sid&&$4==r&&$5==3&&$6>min{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T16 active S row did not record the rolled pair"; t16bad=1; }
grep -q "^W5 $RTOLD " "$SLC" && { echo "  ★ FAIL T16 old W5 key survived window re-key"; t16bad=1; }
[ "$t16bad" -eq 0 ] && echo "  T16 window roll adopts new key and drops old class record OK" || fail=1
rm -f "$SLC"

echo "── T2. RATE-SYNC CONCURRENCY: mkdir-lock serialises read+awk+mv (no lost-update), lock-contention safe-skip, empty-sid read-only, torn-cache survives"
LOCK="$SLC.lock"
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
# T2.0 stale carried observation loses to a fresher authority for the same live window.
RTc=$((NOW + 9000)); OLDc=$((NOW - 5000)); NEWc=$((NOW - 100))
printf "S sNew %s %s 47 %s - - -\nS $(sidof sOldLow) %s %s 12 %s - - -\nW5 %s 47 %s\n" \
  "$NEWc" "$RTc" "$NEWc" "$OLDc" "$RTc" "$OLDc" "$RTc" "$NEWc" > "$SLC"
t20=$(run 120 "$(rsj 12 "$RTc" sOldLow)" | nocol)
case "$t20" in *" 53%"*) echo "  T2.0 old frozen-low adopts newer authority 47 → remaining 53% OK" ;;
  *" 88%"*) echo "  ★ FAIL T2.0 old session used its own frozen 12 (showed 88%): [$t20]"; fail=1 ;;
  *) echo "  ★ FAIL T2.0 expected 53% remaining: [$t20]"; fail=1 ;; esac
wline=$(grep "^W5 $RTc " "$SLC")
case "$wline" in "W5 $RTc 47 $NEWc") echo "  T2.0 persisted W5 = freshest value+auth_observed_at (47 $NEWc), stale frame didn't clobber OK" ;;
  *) echo "  ★ FAIL T2.0 W line clobbered by older session: [$wline]"; fail=1 ;; esac

# T2.1 (5.1) Two sessions render CONCURRENTLY on DIFFERENT classes (one 5h, one 7d) → both class authority lines survive
# (no lost-update from racing rewrites; same-class distinct keys converge to the newest by design, so the race is cross-class)
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
rsj7() {  # $1=used% $2=resets_at $3=session_id → seven_day-only json (mirror of rsj for the other class)
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$(sidof "${3:-sl-selftest}")" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{seven_day:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
WA=$((NOW + 9000)); WB=$((NOW + 300000))                             # a live 5h window and a live 7d window
N=16
for i in $(seq 1 $N); do
  run 120 "$(rsj 30 "$WA" sConcA)" >/dev/null 2>&1 &
  run 120 "$(rsj7 55 "$WB" sConcB)" >/dev/null 2>&1 &
done
wait
ca=$(grep -c "^W5 $WA " "$SLC" 2>/dev/null); ca=${ca:-0}
cb=$(grep -c "^W7 $WB " "$SLC" 2>/dev/null); cb=${cb:-0}
if [ "$ca" -ge 1 ] && [ "$cb" -ge 1 ]; then echo "  T2.1 concurrent cross-class renders: both class authorities survive (no lost-update) OK"
else echo "  ★ FAIL T2.1 lost-update under concurrency: W5-lines=$ca W7-lines=$cb"; fail=1; fi
rm -rf "$LOCK" 2>/dev/null

# T2.2 (5.1) Lock CONTENTION: a held (fresh) lock makes the frame SKIP the write, but it STILL displays the adopted authority value.
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
printf 'S sNew %s %s 47 %s - - -\nW5 %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" "$RTc" "$NEWc" > "$SLC"    # cache holds authority 47
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
printf 'S sNew %s %s 47 %s - - -\nW5 %s 47 %s\n' "$OLDc" "$RTc" "$OLDc" "$RTc" "$OLDc" > "$SLC"   # authority carries an old observation
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
printf 'S sessA %s %s 47 %s - - -\nW5 %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" "$RTc" "$NEWc" > "$SLC"
inob=$(stat -f '%i' "$SLC"); szb=$(wc -c < "$SLC"); szb=${szb// /}; mtb=$(stat -f '%m' "$SLC")
t24=$(run 120 "$(rsjempty 80 "$RTc")" | nocol)                     # empty sid reporting a HIGHER 80 — must be ignored, 47 adopted
case "$t24" in *" 53%"*) echo "  T2.4 empty-sid frame adopts authority 47 (ignores its own 80) -> 53% OK" ;;
  *" 20%"*) echo "  ★ FAIL T2.4 empty-sid overrode authority with its own 80 (showed 20%): [$t24]"; fail=1 ;;
  *) echo "  ★ FAIL T2.4 expected 53%: [$t24]"; fail=1 ;; esac
inoa=$(stat -f '%i' "$SLC"); sza=$(wc -c < "$SLC"); sza=${sza// /}; mta=$(stat -f '%m' "$SLC")
cafter=$(cat "$SLC")
if [ "$inob" = "$inoa" ] && [ "$szb" = "$sza" ] && [ "$mtb" = "$mta" ]; then echo "  T2.4 empty-sid did NOT rewrite the cache (inode/size/mtime unchanged) OK"
else echo "  ★ FAIL T2.4 empty-sid rewrote the cache (inode $inob-$inoa size $szb-$sza mtime $mtb-$mta)"; fail=1; fi
case "$cafter" in "S sessA $NEWc $RTc 47 $NEWc - - -"*"W5 $RTc 47 $NEWc"*) echo "  T2.4 empty-sid left S and W lines intact OK" ;;
  *) echo "  ★ FAIL T2.4 empty-sid mutated cache contents: [$cafter]"; fail=1 ;; esac

# T2.5 (5.3) TORN / BINARY cache fixture: reconcile must not crash, frame stays single-line with a valid %, stderr clean
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
{ printf 'S sNew %s %s 47 %s - - -\nW5 %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" "$RTc" "$NEWc"; printf 'W5 garbage notnum xx\nW garbage notnum xx\n'; head -c 64 /dev/urandom; printf '\nP %s notime nope\n' "$RTc"; } > "$SLC"
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
# T2.7 (1.1) mv guard: an awk-FAILURE frame (empty tmpfile) must NOT clobber the shared authority cache — a failing awk (here a PATH-shim
# awk that exits 0 producing nothing) leaves an empty per-pid temp; the unconditional mv would wipe what prior sessions persisted.
mkdir -p "$WORK/awkfail"; printf '#!/bin/sh\nexit 0\n' > "$WORK/awkfail/awk"; chmod +x "$WORK/awkfail/awk"
printf "S $(sidof sKeep) %s %s 47 %s - - -\nW5 %s 47 %s\n" "$RECENT" "$RT" "$RECENT" "$RT" "$RECENT" > "$SLC"; t27seed=$(cat "$SLC")
printf '%s' "$(rsj 80 "$RT" sKeep)" | env PATH="$WORK/awkfail:$PATH" COLUMNS=120 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >/dev/null 2>&1
t27after=$(cat "$SLC" 2>/dev/null)
[ "$t27seed" = "$t27after" ] && echo "  T2.7 awk-failure frame preserved the authority cache (mv guarded on empty tmpfile) OK" || { echo "  ★ FAIL T2.7 empty tmpfile clobbered the cache: before=[$t27seed] after=[$t27after]"; fail=1; }
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null

echo "── T3. SYNTHETIC-SID GATE (2026-08-31 incident): only a real UUID session id may persist into the shared cache"
# The incident: a demo frame rendered against the real $HOME with the made-up id `sl-sepdemo` became the freshest observation
# and won the W7 authority election, flipping every live session's 7d segment from "84% left / 6D15H" to a red "16% left / 1D7H".
# lib/collect.sh's sid_persistable now refuses to persist any session id that is not UUID-shaped (8-4-4-4-12 lowercase hex);
# such a frame takes the same read-only path as an empty sid — it adopts what it reads and writes nothing at all.
rsjraw() {  # $1=used7% $2=resets_at $3=RAW session_id (deliberately NOT run through sidof) → seven_day-only json
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$3" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{seven_day:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
RT7g=$((NOW + 500000)); AUTHOBS=$((NOW - 200))
# What a real session established: 7d used 16% → the line shows 84% remaining. A synthetic frame reporting 84% used (16% remaining,
# the incident's red number) is NEWER, so without the gate it would take authority and every session would show 16%.
printf "S %s %s - - - %s 16 %s\nW7 %s 16 %s\n" "$(sidof sReal7)" "$AUTHOBS" "$RT7g" "$AUTHOBS" "$RT7g" "$AUTHOBS" > "$SLC"
t3seed=$(cat "$SLC"); t3bad=0
for badsid in sl-sepdemo sl-live-check sl-probe sl sl-selftest E3C7E9B8-EE85-4237-B9EF-F42F666D8C91; do
  t3out=$(printf '%s' "$(rsjraw 84 "$RT7g" "$badsid")" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" | nocol)
  grep -q "^S $badsid " "$SLC" 2>/dev/null && { echo "  ★ FAIL T3 synthetic sid [$badsid] wrote its own S row into the shared cache"; t3bad=1; }
  [ "$t3seed" = "$(cat "$SLC")" ] || { echo "  ★ FAIL T3 synthetic sid [$badsid] rewrote the shared cache: [$(cat "$SLC")]"; t3bad=1; }
  case "$t3out" in *" 84%"*) ;;
    *" 16%"*) echo "  ★ FAIL T3 synthetic sid [$badsid] seized the authority — the 2026-08-31 incident reproduced (showed 16%): [$t3out]"; t3bad=1 ;;
    *) echo "  ★ FAIL T3 synthetic sid [$badsid] did not read-only-adopt the authority (expected 84% remaining): [$t3out]"; t3bad=1 ;; esac
done
# Positive control: the gate rejects by SHAPE, it does not switch syncing off — a real UUID session id must still take authority.
t3real=$(sidof sRealWriter)
t3rout=$(printf '%s' "$(rsjraw 90 "$RT7g" "$t3real")" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" | nocol)
grep -q "^S $t3real " "$SLC" 2>/dev/null || { echo "  ★ FAIL T3 a real UUID session id failed to persist (gate rejects too much)"; t3bad=1; }
case "$t3rout" in *" 10%"*) ;; *) echo "  ★ FAIL T3 real UUID session id did not take authority (expected 10% remaining): [$t3rout]"; t3bad=1 ;; esac
[ "$t3bad" -eq 0 ] && echo "  T3 synthetic session ids cannot touch the shared authority; real UUIDs still sync OK" || fail=1
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null

echo "── T4. SANDBOX DISCIPLINE: nothing here may render the statusline against the real \$HOME"
t4bad=0
# (a) Self-audit: every invocation of the real command in THIS harness must carry a HOME override (or go through sandbox-run.sh).
#     Backslash-continued lines are joined first, so an `env … HOME=… \` + `bash …statusline-command.sh` pair reads as one command.
t4esc=$(python3 - "$SL/tests/run-tests.sh" <<'PYAUDIT'
import sys, re
joined = re.sub(r'\\\n\s*', ' ', open(sys.argv[1]).read())
bad = [l.strip() for l in joined.split('\n')
       if re.search(r'bash\s+"\$(SL|WORK)[^"]*/statusline-command\.sh"', l)
       and 'HOME=' not in l and 'sandbox-run.sh' not in l]
print('\n'.join(bad))
PYAUDIT
)
[ -z "$t4esc" ] || { printf '  ★ FAIL T4 harness renders the statusline with no HOME override:\n%s\n' "$t4esc"; t4bad=1; }
# (b) MACHINE-STATE AUDIT — the ONE check in this file that is not a hermetic code test. Everything else here renders against
#     $FAKE_HOME and asserts a property of the CODE; this block opens the user's REAL shared cache and asserts a property of the
#     MACHINE, so its verdict depends on state no test fixture controls. It is kept deliberately: it is the standing detector for
#     the 2026-08-31 incident, the only place that would notice if a frame ever again stamped a synthetic session row into the
#     file every live session reads. The judge is the production gate itself (sid_persistable, sourced in a subshell) so the
#     audit can never drift from the shipped rule. It is read-only — it never writes the real cache.
#     Being machine-state, it has two failure modes an ordinary assert does not, and both are handled explicitly:
#       * FALSE GREEN — no cache file (a fresh machine, a CI box, a different user) used to fall through this whole branch in
#         silence while the section still printed its OK line. It now prints a SKIP and the section summary says, in words, that
#         the audit did not run. A skip is never reported as a pass.
#       * FALSE RED — the delta spec is explicit that a refused id's row is never deleted or rewritten, so a LEGAL leftover row
#         written before the gate shipped may sit in this file forever. Failing on it would keep the suite red for a machine
#         state this change never claimed to repair. Attribution is therefore BY TIME: a synthetic row fails only when the newest
#         numeric stamp on it (first_seen / o5 / o7, i.e. fields 3, 6 and 9 of "S <sid> <first_seen> <r5> <u5> <o5> <r7> <u7>
#         <o7>") is at or after HARNESS_T0, the second this run started — only then could this run have written it. Anything
#         older is reported as pre-existing residue and does not fail. Conservative edge: a synthetic row written by a CONCURRENT
#         third party mid-run is indistinguishable from one of ours and does fail — that is still a true pollution report.
#     SL_AUDIT_CACHE overrides the file inspected, so this audit is itself auditable: point it at a fixture to exercise the
#     absent-file and the old-residue branches without ever touching the real cache. Read-only; defaults to the real path.
echo "  ── T4(b) MACHINE-STATE AUDIT (not a hermetic test: reads the real shared cache, judges this machine)"
t4cache=${SL_AUDIT_CACHE:-$HOME/.claude/sl-ratelimit-cache}
t4audited=no
if ! ( . "$SL/lib/collect.sh" 2>/dev/null; type sid_persistable >/dev/null 2>&1 ); then
  echo "  ★ FAIL T4 lib/collect.sh defines no sid_persistable — the synthetic-sid write gate is gone"; t4bad=1
elif [ ! -f "$t4cache" ]; then
  echo "  SKIP T4(b) no shared cache at [$t4cache] — there is no machine state to audit here; this check did NOT run and is NOT a pass"
else
  t4audited=yes
  # Emits one "NEW:<sid>" or "OLD:<sid>" token per synthetic row: NEW = stampable by this run (fails), OLD = pre-existing (reported only).
  t4synth=$( . "$SL/lib/collect.sh" 2>/dev/null
             while read -r t4tag t4sid t4fs t4r5 t4u5 t4o5 t4r7 t4u7 t4o7; do
               [ "$t4tag" = "S" ] || continue
               sid_persistable "$t4sid" && continue
               t4newest=0
               for t4ts in "$t4fs" "$t4o5" "$t4o7"; do
                 case "$t4ts" in (''|*[!0-9]*) continue ;; esac      # "-" placeholders and junk carry no attribution. The
                 # leading "(" is load-bearing: bash 3.2 (macOS /bin/bash) cannot parse a bare case pattern inside $( ).
                 [ "$t4ts" -gt "$t4newest" ] && t4newest=$t4ts
               done
               if [ "$t4newest" -ge "$HARNESS_T0" ]; then printf 'NEW:%s ' "$t4sid"; else printf 'OLD:%s ' "$t4sid"; fi
             done < "$t4cache" )
  t4new=""; t4old=""
  for t4tok in $t4synth; do
    case "$t4tok" in NEW:*) t4new="$t4new ${t4tok#NEW:}" ;; OLD:*) t4old="$t4old ${t4tok#OLD:}" ;; esac
  done
  [ -z "$t4new" ] || { echo "  ★ FAIL T4(b) a synthetic session row was stamped into the REAL shared cache DURING this run — the 2026-08-31 incident is live again:$t4new"; t4bad=1; }
  [ -z "$t4old" ] || echo "  NOTE T4(b) pre-existing synthetic rows predate this run; the gate leaves them alone by design (spec: refused ids are never deleted or rewritten), so this is not a failure:$t4old"
  [ -n "$t4new$t4old" ] || echo "  T4(b) real shared cache [$t4cache]: every S row is a real session id"
fi
# (c) scripts/sandbox-run.sh must FAIL CLOSED when the sandbox HOME would land inside a real user home ($SL is under /Users).
t4sb=$(printf '{}' | env TMPDIR="$SL/tests" bash "$SL/scripts/sandbox-run.sh" --columns 80 2>&1); t4sbrc=$?
rm -rf "$SL"/tests/sl-sandbox.* 2>/dev/null
[ "$t4sbrc" = 2 ] || { echo "  ★ FAIL T4 sandbox-run.sh did not refuse a /Users sandbox HOME (rc=$t4sbrc): [$t4sb]"; t4bad=1; }
case "$t4sb" in *"refusing to run"*) ;; *) echo "  ★ FAIL T4 sandbox-run.sh guard message missing: [$t4sb]"; t4bad=1 ;; esac
# (d) …and must still render a normal frame from its own throwaway HOME.
t4line=$(printf '%s' "$(rsj 20 "$RT" sSandbox)" | bash "$SL/scripts/sandbox-run.sh" --columns 120); t4nl=$(printf '%s' "$t4line" | grep -c '')
[ "$t4nl" -eq 1 ] || { echo "  ★ FAIL T4 sandbox-run.sh did not emit a single line ($t4nl): [$t4line]"; t4bad=1; }
case "$(printf '%s' "$t4line" | nocol)" in *%*) ;; *) echo "  ★ FAIL T4 sandbox-run.sh rendered no percentage: [$t4line]"; t4bad=1 ;; esac
# The summary must state whether (b) actually ran: "OK" with the machine-state audit skipped would be the very false green above.
if [ "$t4bad" -ne 0 ]; then fail=1
elif [ "$t4audited" = yes ]; then echo "  T4 harness is HOME-isolated, real-cache audit ran and found no row this run could have written, sandbox-run.sh fails closed and renders OK"
else echo "  T4 harness is HOME-isolated, sandbox-run.sh fails closed and renders OK — machine-state audit (b) SKIPPED, not passed"; fi

echo "── U. LAST-MSG: 'HH:MM (Δ)' cache-age delta — <1m hides Δ, 5m/1h colour tiers, old format verbatim, cross-day date prefix"
NOWS=$(jq -n 'now|floor')
LMF="$FAKE_HOME/.claude/last-msg/sl-selftest"
# lmset <clock> <epoch>: write the per-session last-msg file AND set the transcript mtime to the same epoch.
# The (Δ) idle delta anchors on the transcript mtime (last activity ≈ turn end); lm_epoch still drives the clock
# label + cross-day prefix. Setting both to <epoch> keeps the delta reading as (now-epoch), so these fixtures
# assert the same outputs after the anchor moved from prompt time to last activity.
lmset() { printf '%s %s\n' "$1" "$2" > "$LMF"; touch -t "$(date -r "$2" '+%Y%m%d%H%M.%S')" "$TP" 2>/dev/null; }
lmrun() { lmset 09:30 "$(( NOWS - $1 ))"; run 200 "$J"; }                        # $1=idle sec → render with that last-activity age
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
# U7 10 min ago (already U2): normally same LOCAL day → BARE HH:MM, no date prefix. But within
# 10 min after local midnight, now-600 lands on YESTERDAY — the spec's normative cross-midnight-
# under-one-hour case — so the prefix is then REQUIRED. Derive the expectation from the fixture
# epoch's own calendar day instead of assuming wall-clock (the suite was flaky 00:00–00:10).
U7EP=$(( NOWS - 600 )); U7MD=$(date -r "$U7EP" '+%m-%d' 2>/dev/null)
u7=$(lmrun 600 | strip)
if [ "$U7MD" = "$(date -r "$NOWS" '+%m-%d' 2>/dev/null)" ]; then
  case "$u7" in *[0-9][0-9]-[0-9][0-9]" 09:30 ("*) echo "  ★ FAIL U7 same-day wrongly date-prefixed: [$u7]"; fail=1 ;;
    *"09:30 ("*) echo "  U7 same-day bare HH:MM (no date prefix) OK" ;;
    *) echo "  ★ FAIL U7 time segment missing: [$u7]"; fail=1 ;; esac
else
  case "$u7" in *"$U7MD 09:30 ("*) echo "  U7 cross-midnight (<1h) date-prefixed $U7MD OK" ;;
    *"09:30 ("*) echo "  ★ FAIL U7 cross-midnight NOT date-prefixed (expected $U7MD): [$u7]"; fail=1 ;;
    *) echo "  ★ FAIL U7 time segment missing: [$u7]"; fail=1 ;; esac
fi
# U8 cross-day prefix does NOT alter the delta colour tier: 26h ≥ LASTMSG_STALE → still the red (≥1h) tier, same as a bare-time ≥1h delta
u8cross=$(lmrun "$U6AGE" | pcode); u8bare=$(printf '%s' "$u3raw" | pcode)
if [ -n "$u8cross" ] && [ "$u8cross" = "$u8bare" ]; then echo "  U8 date prefix keeps the same Δ colour tier (red) OK";
else echo "  ★ FAIL U8 date prefix changed the Δ colour tier (cross=[$u8cross] bare=[$u8bare])"; fail=1; fi
# U9 REGRESSION: (Δ) anchors on the turn's last activity (transcript mtime), NOT the prompt time (lm_epoch).
# A prompt submitted 2h10m ago whose turn last wrote 90s ago must read as a warm ~(1m) idle, never a red (2H10m).
# Falsifiable: revert the render change (delta back on lm_epoch) and this asserts (2H10m) → FAIL.
printf '09:30 %s\n' "$(( NOWS - 7800 ))" > "$LMF"                 # prompt 2h10m ago (drives the clock label only)
touch -t "$(date -r "$(( NOWS - 90 ))" '+%Y%m%d%H%M.%S')" "$TP"  # last activity 90s ago (drives the idle delta)
u9=$(run 200 "$J" | strip)
case "$u9" in
  *"09:30 (1m)"*|*"09:30 (2m)"*) echo "  U9 idle anchored on transcript mtime (warm ~1m, not 2H10m) OK" ;;
  *"(1H"*|*"(2H"*) echo "  ★ FAIL U9 delta anchored on prompt time, not last activity: [$u9]"; fail=1 ;;
  *) echo "  ★ FAIL U9 expected 09:30 (1m): [$u9]"; fail=1 ;;
esac
# U10 FALLBACK: transcript_path points at a missing file → act_epoch empty → (Δ) falls back to lm_epoch (prompt
# time), reproducing pre-change behavior for hosts/renders without a usable transcript.
printf '09:30 %s\n' "$(( NOWS - 600 ))" > "$LMF"
JNOTP=$(jq -cn --arg cwd "$SL" '
  { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest", transcript_path:"/nonexistent/sl-missing.jsonl" }')
u10=$(run 200 "$JNOTP" | strip)
case "$u10" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  U10 transcript-missing falls back to lm_epoch (10m) OK" ;; *) echo "  ★ FAIL U10 fallback expected 09:30 (10m): [$u10]"; fail=1 ;; esac
printf '06-07 19:38\n' > "$LMF"   # restore baseline

echo "── DUR. SESSION DURATION drives the time segment: cost.total_duration_ms → '<dur> (Δ)', replaces clock, keeps Δ, format boundaries"
# mkdur: a standard roomy frame WITH cost.total_duration_ms ($1 = ms). Same session_id so the U-section last-msg file applies.
mkdur() { jq -cn --arg cwd "$SL" --arg tp "$TP" --argjson d "$1" '
  { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest", transcript_path:$tp, cost:{total_duration_ms:$d} }'; }
# DUR1: duration is the PRIMARY text, the absolute clock 09:30 is REPLACED, the Δ-since-last-prompt is kept → "1H15m (10m)"
lmset 09:30 "$(( NOWS - 600 ))"
d1=$(run 200 "$(mkdur 4521000)" | strip)
case "$d1" in *"1H15m (10m)"*|*"1H15m (11m)"*) echo "  DUR1 duration primary + Δ kept (1H15m (10m)) OK" ;; *) echo "  ★ FAIL DUR1 expected 1H15m (10m): [$d1]"; fail=1 ;; esac
case "$d1" in *"09:30"*) echo "  ★ FAIL DUR1 absolute clock 09:30 not replaced by duration: [$d1]"; fail=1 ;; esac
# DUR2: last prompt <1min → Δ hidden, duration alone (clock still replaced)
lmset 09:30 "$(( NOWS - 30 ))"
d2=$(run 200 "$(mkdur 4521000)" | strip)
case "$d2" in *"1H15m ("*) echo "  ★ FAIL DUR2 <1min should hide Δ: [$d2]"; fail=1 ;; *"1H15m"*) echo "  DUR2 <1min: duration only, no Δ OK" ;; *) echo "  ★ FAIL DUR2 duration missing: [$d2]"; fail=1 ;; esac
# DUR3: no last-msg file at all → duration still shows (the segment is duration-driven, not last-msg-driven)
rm -f "$LMF"
d3=$(run 200 "$(mkdur 4521000)" | strip)
case "$d3" in *"1H15m"*) echo "  DUR3 duration shows with no last-msg file OK" ;; *) echo "  ★ FAIL DUR3 duration missing with no last-msg: [$d3]"; fail=1 ;; esac
# DUR4: fmt_dur boundaries — <1h has no H (40m); >=1 day uses D/H (2D3H)
d4a=$(run 200 "$(mkdur 2400000)" | strip)     # 2,400,000 ms = 40 m
case "$d4a" in *"40m"*) echo "  DUR4a <1h → 40m OK" ;; *) echo "  ★ FAIL DUR4a expected 40m: [$d4a]"; fail=1 ;; esac
d4b=$(run 200 "$(mkdur 183600000)" | strip)   # 183,600,000 ms = 2 d 3 h
case "$d4b" in *"2D3H"*) echo "  DUR4b >=1day → 2D3H OK" ;; *) echo "  ★ FAIL DUR4b expected 2D3H: [$d4b]"; fail=1 ;; esac
# DUR5: no cost field → legacy clock fallback unchanged (the absolute clock still renders with its Δ)
lmset 09:30 "$(( NOWS - 600 ))"
d5=$(run 200 "$J" | strip)
case "$d5" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  DUR5 no-cost → legacy clock fallback (09:30) OK" ;; *) echo "  ★ FAIL DUR5 expected clock fallback 09:30 (10m): [$d5]"; fail=1 ;; esac
printf '06-07 19:38\n' > "$LMF"   # restore baseline

echo "── API. API THINKING TIME is the top-priority primary: cost.total_api_duration_ms → fmt_dur_s '<dur> (Δ)', overrides duration+clock, 3-level fallback"
# mkapi: a standard roomy frame whose cost object ($1 = whole JSON cost object) drives the time segment. Same session_id → the last-msg file applies.
mkapi() { jq -cn --arg cwd "$SL" --arg tp "$TP" --argjson c "$1" '
  { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest", transcript_path:$tp, cost:$c }'; }
# API1: api time is the PRIMARY (overrides BOTH the duration 1H15m and the clock 09:30); the Δ-since-last-prompt is kept → "3m45s (10m)"
lmset 09:30 "$(( NOWS - 600 ))"
a1=$(run 200 "$(mkapi '{"total_duration_ms":4521000,"total_api_duration_ms":225000}')" | strip)
case "$a1" in *"3m45s (10m)"*|*"3m45s (11m)"*) echo "  API1 api primary + Δ kept (3m45s (10m)) OK" ;; *) echo "  ★ FAIL API1 expected 3m45s (10m): [$a1]"; fail=1 ;; esac
case "$a1" in *"1H15m"*) echo "  ★ FAIL API1 duration form 1H15m leaked (api must replace it): [$a1]"; fail=1 ;; esac
case "$a1" in *"09:30"*) echo "  ★ FAIL API1 absolute clock 09:30 not replaced by api time: [$a1]"; fail=1 ;; esac
# API2: fmt_dur_s boundary table (remove last-msg so only the bare primary shows, no Δ noise). Delegates to fmt_dur at >=1h.
rm -f "$LMF"
for pair in "500:0s" "45000:45s" "60000:1m0s" "3599000:59m59s" "4500000:1H15m" "97200000:1D3H"; do
  ms=${pair%%:*}; want=${pair##*:}
  a2=$(run 200 "$(mkapi "{\"total_api_duration_ms\":$ms}")" | strip)
  case "$a2" in *"$want"*) : ;; *) echo "  ★ FAIL API2 api=${ms}ms expected $want: [$a2]"; fail=1 ;; esac
done
echo "  API2 fmt_dur_s boundaries (0s/45s/1m0s/59m59s/1H15m/1D3H) OK"   # 500ms row pins the sub-second s=0 branch (spec table row 1)
a2p=$(run 200 "$(mkapi '{"total_api_duration_ms":45000}')" | strip)   # pin: sub-minute value carries NO minute prefix
case "$a2p" in *"m45s"*) echo "  ★ FAIL API2 45s carries a spurious minute prefix: [$a2p]"; fail=1 ;; *"45s"*) echo "  API2 45s has no minute prefix OK" ;; *) echo "  ★ FAIL API2 45s missing: [$a2p]"; fail=1 ;; esac
a2z=$(run 200 "$(mkapi '{"total_api_duration_ms":500}')" | strip)     # pin: sub-second (spec table row 1, s=0) is EXACTLY "0s", never "0m0s" — a plain *"0s"* substring would wrongly match "0m0s"
case "$a2z" in *"m0s"*) echo "  ★ FAIL API2 sub-second carries a minute prefix (0m0s): [$a2z]"; fail=1 ;; *"0s"*) echo "  API2 sub-second → 0s (no minute prefix) OK" ;; *) echo "  ★ FAIL API2 0s missing: [$a2z]"; fail=1 ;; esac
# API3: api time present, NO duration field → api is still the primary → "3m45s"
a3=$(run 200 "$(mkapi '{"total_api_duration_ms":225000}')" | strip)
case "$a3" in *"3m45s"*) echo "  API3 api primary with no duration field OK" ;; *) echo "  ★ FAIL API3 expected 3m45s: [$a3]"; fail=1 ;; esac
# API4: invalid api time (0 / non-numeric / negative) falls back to the session-duration 1H15m (never a spurious 0s).
# Build the frame JSON into a variable first: an inline $(run … "$(mkapi "…\":$bad")") triple-nests command subs and bash mangles the escaped quotes → empty frame.
a4ok=1
for bad in '0' '"abc"' '-5000'; do
  j4=$(mkapi "{\"total_duration_ms\":4521000,\"total_api_duration_ms\":$bad}")
  a4=$(run 200 "$j4" | strip)
  case "$a4" in *"1H15m"*) : ;; *) echo "  ★ FAIL API4 api=$bad should fall back to 1H15m: [$a4]"; fail=1; a4ok=0 ;; esac
  case "$a4" in *"0s"*) echo "  ★ FAIL API4 api=$bad rendered as 0s instead of falling back: [$a4]"; fail=1; a4ok=0 ;; esac
done
[ "$a4ok" = 1 ] && echo "  API4 invalid api (0/\"abc\"/-5000) falls back to duration 1H15m OK"
# API5: cost object present but NEITHER field usable → clock fallback with its Δ → "09:30 (10m)"
lmset 09:30 "$(( NOWS - 600 ))"
a5=$(run 200 "$(mkapi '{"total_duration_ms":0,"total_api_duration_ms":0}')" | strip)
case "$a5" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  API5 both cost fields unusable → clock fallback 09:30 (10m) OK" ;; *) echo "  ★ FAIL API5 expected clock fallback 09:30 (10m): [$a5]"; fail=1 ;; esac
# API6: last prompt <1min → Δ hidden, api primary alone → "3m45s" with no "("
lmset 14:05 "$(( NOWS - 30 ))"
a6=$(run 200 "$(mkapi '{"total_api_duration_ms":225000}')" | strip)
case "$a6" in *"3m45s ("*) echo "  ★ FAIL API6 sub-minute prompt should hide Δ: [$a6]"; fail=1 ;; *"3m45s"*) echo "  API6 <1min prompt → api primary only, no Δ OK" ;; *) echo "  ★ FAIL API6 api primary missing: [$a6]"; fail=1 ;; esac
# API7: cross-day prompt (26h ago → prior local calendar day) with an API primary → the elapsed-span primary is NEVER date-prefixed
# (spec normative "An elapsed-span primary is never date-prefixed"); the date "MM-DD" prefix is a clock-fallback-only concern. The Δ still shows.
lmset 12:00 "$(( NOWS - 93600 ))"
a7=$(run 200 "$(mkapi '{"total_api_duration_ms":225000}')" | strip)
case "$a7" in
  *[0-9][0-9]-[0-9][0-9]\ 3m45s*) echo "  ★ FAIL API7 elapsed-span primary got a date prefix: [$a7]"; fail=1 ;;
  *"3m45s (1D2H)"*|*"3m45s (1D3H)"*) echo "  API7 cross-day api primary: no date prefix, elapsed Δ kept OK" ;;
  *) echo "  ★ FAIL API7 expected bare 3m45s with (1D2H) Δ: [$a7]"; fail=1 ;;
esac
# API8-API10 string-typed cost fields. CC sends numbers, but jq's tostring erases the type, so a string-typed value
# reaches the arithmetic verbatim and a leading zero would be read as octal: "0900000" aborts the expression and spills
# "value too great for base" onto the statusline (its output IS the screen), while a legal octal like "04521000" is
# worse, formatting a wrong duration with no symptom. Each case asserts exit 0, empty stderr, and the DECIMAL reading.
runapi() {   # $1=cost object → stdout in $WORK/api.out, stderr in $WORK/api.err, exit code in ARC
  printf '%s' "$(mkapi "$1")" | env COLUMNS=200 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >"$WORK/api.out" 2>"$WORK/api.err"; ARC=$?
}
chkapi() {   # $1=label $2=expected substring in the rendered line
  local out errb; out=$(strip < "$WORK/api.out"); errb=$(wc -c < "$WORK/api.err" | tr -d ' ')
  if   [ "$ARC" -ne 0 ];   then echo "  ★ FAIL $1 exited $ARC (expected 0)"; fail=1
  elif [ "$errb" != "0" ]; then echo "  ★ FAIL $1 wrote $errb bytes to stderr: [$(cat "$WORK/api.err")]"; fail=1
  else case "$out" in *"$2"*) echo "  $1 OK" ;; *) echo "  ★ FAIL $1 expected [$2]: [$out]"; fail=1 ;; esac; fi
}
rm -f "$LMF"                                                   # bare primary, no Δ noise
# API8 api time as a leading-zero string → decimal 900000ms = 900s → 15m0s (octal would abort the expression)
runapi '{"total_api_duration_ms":"0900000"}'; chkapi API8 "15m0s"
# API9 junk api time → falls through to the session-duration primary, still silently
runapi '{"total_duration_ms":4521000,"total_api_duration_ms":"12a"}'; chkapi API9 "1H15m"
# API10 the level-2 field carries the leading zero → decimal 4521000ms = 1H15m (octal 04521000 would render 20m)
runapi '{"total_duration_ms":"04521000"}'; chkapi API10 "1H15m"
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
  context_window:{used_percentage:"S_used", exceeds_200k_tokens:true, context_window_size:"S_win",
                  current_usage:{input_tokens:"S_in", cache_creation_input_tokens:"S_cc",
                                 cache_read_input_tokens:"S_cr", output_tokens:"S_out"}}, worktree:{name:"S_wt"},
  effort:{level:"S_effort"}, thinking:{enabled:false},
  rate_limits:{ five_hour:{used_percentage:"S_5h", resets_at:"S_5r"},
                seven_day:{used_percentage:"S_7d", resets_at:"S_7r"} },
  session_id:"S_sid", transcript_path:"S_tp", cost:{total_duration_ms:4521000, total_api_duration_ms:987654} }')
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
   chkv exceeds_200k "$exceeds_200k" true; chkv dur_ms "$dur_ms" 4521000
   chkv api_ms "$api_ms" 987654
   chkv ctx_in_tok "$ctx_in_tok" S_in;    chkv ctx_cc_tok "$ctx_cc_tok" S_cc
   chkv ctx_cr_tok "$ctx_cr_tok" S_cr;    chkv ctx_out_tok "$ctx_out_tok" S_out
   chkv ctx_win_size "$ctx_win_size" S_win
   case "$now" in ''|*[!0-9]*) echo "  ★ FAIL now not numeric: [$now]"; rc=1 ;; esac
   exit $rc ); then echo "  all 23 fields land in their own global OK"; else fail=1; fi

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

echo "── M1-M7. 1M detection follows context_window_size, with display-name fallback and unchanged compact form"
# mk1m: one-line statusline JSON with independently controlled model and reported window. The window is deliberately
# string-typed so the render gate sees the same hostile shapes jq's tostring preserves; "omit" leaves the field absent.
# Existing mkctx/mkctxa signatures remain unchanged because their CTX fixtures exercise separate contracts.
mk1m() {  # $1=model display_name $2=context_window_size (or omit) $3=used_percentage
  jq -cn --arg m "$1" --arg win "$2" --arg up "$3" '
    { workspace:{current_dir:"/private/tmp"}, model:{display_name:$m},
      context_window: ({used_percentage:($up|tonumber)}
        + (if $win == "omit" then {} else {context_window_size:$win} end)) }'
}

m1=$(run 200 "$(mk1m 'Opus 5' 1000000 85)" | nocol)
case "$m1" in
  *"Opus 5(1M)"*) case "$m1" in *"Opus 5 (1M)"*) echo "  ★ FAIL M1 appended marker has a separating space: [$m1]"; fail=1 ;;
                     *) echo "  M1 reported 1000000 appends Opus 5(1M) with no space OK" ;; esac ;;
  *) echo "  ★ FAIL M1 missing appended marker: [$m1]"; fail=1 ;;
esac
m2=$(run 200 "$(mk1m 'Sonnet 5' 200000 85)" | nocol)
case "$m2" in *"Sonnet 5"*) case "$m2" in *"(1M)"*) echo "  ★ FAIL M2 standard window gained marker: [$m2]"; fail=1 ;;
                                      *) echo "  M2 reported 200000 leaves Sonnet 5 unmarked OK" ;; esac ;;
  *) echo "  ★ FAIL M2 model missing: [$m2]"; fail=1 ;;
esac
m3=$(run 200 "$(mk1m 'Opus 4.8 (1M context)' 1000000 85)" | nocol)
case "$m3" in *"Opus 4.8(1M)"*) case "$m3" in *"(1M)(1M)"*) echo "  ★ FAIL M3 duplicate marker: [$m3]"; fail=1 ;;
                                             *) echo "  M3 announced + reported extended window yields one marker OK" ;; esac ;;
  *) echo "  ★ FAIL M3 legacy rewrite missing: [$m3]"; fail=1 ;;
esac
m4=$(run 200 "$(mk1m 'Opus 4.8 (1M context)' omit 85)" | nocol)
case "$m4" in *"Opus 4.8(1M)"*) echo "  M4 absent size falls back to announced 1M name OK" ;;
  *) echo "  ★ FAIL M4 display-name fallback missing: [$m4]"; fail=1 ;;
esac
m5=$(run 200 "$(mk1m 'Sonnet 5' omit 85)" | nocol)
case "$m5" in *"Sonnet 5"*) case "$m5" in *"(1M)"*) echo "  ★ FAIL M5 absent size invented marker: [$m5]"; fail=1 ;;
                                      *) echo "  M5 absent size + silent name remains unmarked OK" ;; esac ;;
  *) echo "  ★ FAIL M5 model missing: [$m5]"; fail=1 ;;
esac
m6=$(run 22 "$(mk1m 'Opus 5' 1000000 85)" | nocol)
case "$m6" in *"Opus"*) case "$m6" in *"Opus 5(1M)"*) echo "  ★ FAIL M6 full model survived compact tier: [$m6]"; fail=1 ;;
                                  *) echo "  M6 compact form stays the raw leading word Opus OK" ;; esac ;;
  *) echo "  ★ FAIL M6 compact model missing: [$m6]"; fail=1 ;;
esac
m7e=$(run 200 "$(mk1m 'Opus 5' 1000000 85)" | ctxpcode)
m7s=$(run 200 "$(mk1m 'Sonnet 5' 200000 85)" | ctxpcode)
if [ "$m7e" = "$NMCODE" ] && [ "$m7s" = "$RDCODE" ] && [ "$m7e" != "$m7s" ]; then
  echo "  M7 reported window drives 92/80 threshold at identical 85% OK"
else
  echo "  ★ FAIL M7 threshold did not follow size (1M=[$m7e] normal=[$NMCODE] 200k=[$m7s] red=[$RDCODE])"; fail=1
fi

# Predicate robustness: every unusable size falls back without arithmetic diagnostics; a leading-zero decimal remains usable.
m8bad=0
for spec in 'nonnumeric|abc|Opus 4.8 (1M context)|Opus 4.8(1M)' 'leading-zero|01000000|Opus 5|Opus 5(1M)' '40-digit|9999999999999999999999999999999999999999|Sonnet 5|Sonnet 5'; do
  label=${spec%%|*}; rest=${spec#*|}; win=${rest%%|*}; rest=${rest#*|}; m8model=${rest%%|*}; want=${rest#*|}
  printf '%s' "$(mk1m "$m8model" "$win" 85)" | env COLUMNS=200 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >"$WORK/m8.out" 2>"$WORK/m8.err"; m8rc=$?
  m8plain=$(nocol < "$WORK/m8.out"); m8lines=$(grep -c '' "$WORK/m8.out"); m8err=$(wc -c < "$WORK/m8.err" | tr -d ' ')
  [ "$m8rc" -eq 0 ] || { echo "  ★ FAIL M8 $label exited $m8rc"; m8bad=1; }
  [ "$m8lines" -eq 1 ] || { echo "  ★ FAIL M8 $label emitted $m8lines lines"; m8bad=1; }
  [ "$m8err" = 0 ] || { echo "  ★ FAIL M8 $label wrote $m8err stderr bytes: [$(cat "$WORK/m8.err")]"; m8bad=1; }
  case "$m8plain" in *"$want"*) ;; *) echo "  ★ FAIL M8 $label fallback/decimal result missing [$want]: [$m8plain]"; m8bad=1 ;; esac
done
[ "$m8bad" -eq 0 ] && echo "  M8 nonnumeric/leading-zero/40-digit frames: one line, stderr clean, correct fallback OK" || fail=1

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

# CTX8-CTX14: warning-aligned percentage source. The displayed % is computed locally on Claude Code's
# "Context low (N% remaining)" basis instead of echoing the upstream used_percentage: T = the four current_usage token
# counts summed, P = context_window_size - CTX_RESERVE, R = round-half-up(100*(P-T)/P) with (P-T) clamped at 0, and the
# displayed N = 100 - R. So the statusline number and the warning's remaining number always add up to 100.
mkctxa() {  # $1=model $2=input $3=cache_creation $4=cache_read $5=output $6=context_window_size $7=used% ("omit") $8=exceeds ("omit")
  jq -cn --arg cwd "$SL" --arg m "$1" --argjson i "$2" --argjson cc "$3" --argjson cr "$4" --argjson o "$5" \
     --arg win "$6" --arg up "$7" --arg ex "$8" --arg tp "$TP" '
    { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:$m},
      context_window: ( {current_usage:{input_tokens:$i, cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr, output_tokens:$o}}
        + (if $win == "omit" then {} else {context_window_size:($win|tonumber)} end)
        + (if $up  == "omit" then {} else {used_percentage:($up|tonumber)} end)
        + (if $ex  == "omit" then {} else {exceeds_200k_tokens:($ex == "true")} end) ),
      session_id:"sl-selftest", transcript_path:$tp }'
}
# ctxpct: the percentage NUMBER the ctx segment displays (last "\e[<code>m[ctx:]NN%" match — these frames carry no rate
# segment, so the only percentage on the line is the ctx one). Empty when the segment is suppressed.
ctxpct() { perl -ne 'while(/\x1b\[[0-9;]*m(?:ctx:)?([0-9]+)%/g){$p=$1} END{print $p}'; }
# CTX8 aligned basis, the design's anchor frame: T=960400, window=1000000 → P=980000, R=round(100*19600/980000)=2 → 98
p8=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 1000000 omit omit)" | ctxpct)
case "$p8" in 98) echo "  CTX8 aligned basis (T=960400, win=1M) → 98% OK" ;; *) echo "  ★ FAIL CTX8 expected 98 got [$p8]"; fail=1 ;; esac
# CTX9 priority: the same frame ALSO carrying used_percentage 96 still shows 98 — the aligned value beats the upstream one
p9=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 1000000 96 omit)" | ctxpct)
case "$p9" in 98) echo "  CTX9 aligned value wins over upstream used_percentage 96 OK" ;; *) echo "  ★ FAIL CTX9 expected 98 got [$p9]"; fail=1 ;; esac
# CTX10 saturation: T=985000 exceeds P=980000 → (P-T) clamps to 0, R=0 → 100 (never a negative remaining)
p10=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 500000 85000 400000 0 1000000 omit omit)" | ctxpct)
case "$p10" in 100) echo "  CTX10 usage past the reserve boundary clamps to 100% OK" ;; *) echo "  ★ FAIL CTX10 expected 100 got [$p10]"; fail=1 ;; esac
# CTX11 window not ABOVE the reserve (exactly 20000) → the aligned computation must not run; used_percentage 96 shows through
p11=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 20000 96 omit)" | ctxpct)
case "$p11" in 96) echo "  CTX11 window not above the reserve falls back to used_percentage 96 OK" ;; *) echo "  ★ FAIL CTX11 expected 96 got [$p11]"; fail=1 ;; esac
# CTX14 half-up boundary: T=955500 → exact remaining 100*24500/980000 = 2.5 → R rounds up to 3 → N=97. An independently
# rounded used% (97.5 → 98) would break the complement, which is why N is defined as 100 - R.
p14=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 500000 55000 400000 500 1000000 omit omit)" | ctxpct)
case "$p14" in 97) echo "  CTX14 .5 remaining rounds half-up (R=3 → 97%) OK" ;; *) echo "  ★ FAIL CTX14 expected 97 got [$p14]"; fail=1 ;; esac
# CTX12 legacy frame (used_percentage only, no current_usage): the ctx segment must stay byte-identical to the pre-change
# output. CTX12_EXPECT was CAPTURED from the real pre-change script, not hand-written:
#   printf '{"workspace":{"current_dir":"'"$PWD"'"},"model":{"display_name":"Opus 4.8 (1M context)"},
#            "context_window":{"used_percentage":96},"session_id":"sl-selftest"}' | COLUMNS=200 bash statusline-command.sh
# (captured 2026-08-14 with the default STYLE=tokyo-night-claude; re-capture with that command if the default palette changes).
# ctxseg: the COMPLETE ctx segment, from the bar/percentage start up to the segment boundary (the " │ " separator, a
# >=2-space gap, or end of line). It deliberately does NOT stop at the % or the ⚑: anything trailing inside the segment
# (a duplicated marker, an unreset SGR, stray bytes) lands INSIDE the compared string instead of being cropped away.
ctxseg() { perl -0777 -ne 'chomp; print $1 if /(((?:\x1b\[48;2;[0-9;]+m )+\x1b\[0m )?\x1b\[[0-9;]+m(?:ctx:)?\d+%.*?)(?:\x1b\[[0-9;]+m │ \x1b\[0m|  |$)/s'; }
CTX12_EXPECT=$'\033[48;2;158;206;106m \033[48;2;158;206;106m \033[48;2;158;206;106m \033[48;2;224;175;104m \033[48;2;224;175;104m \033[48;2;224;175;104m \033[48;2;255;158;100m \033[48;2;255;158;100m \033[48;2;255;158;100m \033[48;2;247;118;142m \033[48;2;247;118;142m \033[48;2;41;46;66m \033[0m \033[38;2;247;118;142m96%\033[0m'
s12=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 96 omit)" | ctxseg)
if [ "$s12" = "$CTX12_EXPECT" ]; then echo "  CTX12 legacy used_percentage-only frame byte-identical to the pre-change capture (full segment, suffix included) OK"
else echo "  ★ FAIL CTX12 ctx segment differs from the pre-change capture: [$(printf '%s' "$s12" | cat -v)]"; fail=1; fi
# CTX13 neither source numeric → the WHOLE segment is suppressed, cliff marker included. exceeds_200k is true here on
# purpose: the ⚑ has no percentage to ride on, so it must not be emitted either.
c13out=$(run 200 "$(jq -cn --arg cwd "$SL" --arg tp "$TP" \
  '{workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{exceeds_200k_tokens:true}, session_id:"sl-selftest", transcript_path:$tp}')")
p13=$(printf '%s' "$c13out" | ctxpct)
case "$c13out" in
  *"⚑"*) echo "  ★ FAIL CTX13 ⚑ emitted with no numeric percentage to host it"; fail=1 ;;
  *) case "$p13" in '') echo "  CTX13 neither source numeric → whole ctx segment (and ⚑) suppressed OK" ;;
       *) echo "  ★ FAIL CTX13 percentage [$p13] rendered with no numeric source"; fail=1 ;; esac ;;
esac
# CTX15-CTX17 CTX_BAR knob on the aligned percentage: one fixed frame (aligned 98%, over-200k true) rendered by both builds.
# The knob selects between the two FULL forms only — it must not touch the bare compact form or the cliff marker.
mkdir -p "$WORK/nobar/lib" && cp "$SL"/lib/*.sh "$WORK/nobar/lib/"
sed 's/^CTX_BAR=true/CTX_BAR=false/' "$SL/statusline-command.sh" > "$WORK/nobar/statusline-command.sh"
runnobar() { printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" bash "$WORK/nobar/statusline-command.sh"; }
barcells() { perl -0777 -ne '$n=()=/\x1b\[48;2;[0-9;]+m /g; print $n'; }   # count of background-painted bar cells
KNOBF=$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 1000000 omit true)
k15=$(run 200 "$KNOBF" | ctxseg); n15=$(printf '%s' "$k15" | barcells)
case "$n15:$(printf '%s' "$k15" | ctxpct):$k15" in
  12:98:*"⚑"*) echo "  CTX15 CTX_BAR=true full form = 12-cell bar + aligned 98% + ⚑ OK" ;;
  *) echo "  ★ FAIL CTX15 expected 12 cells/98%/⚑, got cells=[$n15] pct=[$(printf '%s' "$k15" | ctxpct)]"; fail=1 ;; esac
k16=$(runnobar 200 "$KNOBF" | ctxseg); n16=$(printf '%s' "$k16" | barcells)
case "$k16" in
  *"ctx:98%"*"⚑"*) case "$n16" in 0) echo "  CTX16 CTX_BAR=false full form = ctx:98% text, no bar, ⚑ kept OK" ;;
                     *) echo "  ★ FAIL CTX16 bar cells present with CTX_BAR=false: [$n16]"; fail=1 ;; esac ;;
  *) echo "  ★ FAIL CTX16 expected ctx:98% + ⚑, got [$(printf '%s' "$k16" | cat -v)]"; fail=1 ;; esac
# CTX17 compact form: at a width that forces degrade step 4 the bare N% is byte-identical under both knob settings, ⚑ included
k17a=$(run 45 "$KNOBF" | ctxseg); k17b=$(runnobar 45 "$KNOBF" | ctxseg); n17=$(printf '%s' "$k17a" | barcells)
if [ "$k17a" = "$k17b" ]; then
  case "$k17a" in *"ctx:"*) echo "  ★ FAIL CTX17 compact form carries the ctx: label"; fail=1 ;;
    *"98%"*"⚑"*) case "$n17" in 0) echo "  CTX17 bare 98%+⚑ compact form identical under both CTX_BAR settings, no bar cells OK" ;;
                   *) echo "  ★ FAIL CTX17 compact form still paints $n17 bar cells"; fail=1 ;; esac ;;
    *) echo "  ★ FAIL CTX17 compact form is not the bare 98%+⚑: [$(printf '%s' "$k17a" | cat -v)]"; fail=1 ;; esac
else echo "  ★ FAIL CTX17 compact form differs by knob: [$(printf '%s' "$k17a" | cat -v)] vs [$(printf '%s' "$k17b" | cat -v)]"; fail=1; fi

# CTX18-CTX22 hostile counter values. jq's tostring erases the JSON type, so a STRING-typed counter reaches the
# arithmetic verbatim — these frames send exactly that shape. Every case must exit 0 and keep stderr empty, because the
# statusline's output IS the screen: an arithmetic error message there is itself the bug.
mkctxh() {  # $1..$4 = the four current_usage counters, $5 = context_window_size (all JSON strings), $6 = used% ("omit")
  jq -cn --arg cwd "$SL" --arg i "$1" --arg cc "$2" --arg cr "$3" --arg o "$4" --arg win "$5" --arg up "$6" --arg tp "$TP" '
    { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
      context_window: ( {current_usage:{input_tokens:$i, cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr, output_tokens:$o},
                         context_window_size:$win}
        + (if $up == "omit" then {} else {used_percentage:($up|tonumber)} end) ),
      session_id:"sl-selftest", transcript_path:$tp }'
}
runh() {   # $1=COLUMNS $2=json → stdout in $WORK/h.out, stderr in $WORK/h.err, exit code in HRC
  printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >"$WORK/h.out" 2>"$WORK/h.err"; HRC=$?
}
chkh() {   # $1=label $2=expected displayed % → assert exit 0 + empty stderr + that percentage
  local got errb; got=$(ctxpct < "$WORK/h.out"); errb=$(wc -c < "$WORK/h.err" | tr -d ' ')
  if   [ "$HRC" -ne 0 ];    then echo "  ★ FAIL $1 exited $HRC (expected 0)"; fail=1
  elif [ "$errb" != "0" ];  then echo "  ★ FAIL $1 wrote $errb bytes to stderr: [$(cat "$WORK/h.err")]"; fail=1
  elif [ "$got" != "$2" ];  then echo "  ★ FAIL $1 expected $2% got [$got]"; fail=1
  else echo "  $1 OK"; fi
}
# CTX18 leading zero "08": bash reads a leading zero as octal, and "08" is not even a legal octal literal — unguarded it
# aborts the expression and spills "value too great for base" onto the statusline. It must count as decimal 8:
# T = 8+60000+500000+400 = 560408, P = 980000 → R = round(100*419592/980000) = 43 → 57.
runh 200 "$(mkctxh 08 60000 500000 400 1000000 omit)"; chkh CTX18 57
# CTX19 leading zero "040000": a legal octal literal, so an unguarded read is SILENT — 16384 instead of 40000 (which
# would show 53% instead of 55%). T = 40000+0+500000+0 = 540000 → R = round(100*440000/980000) = 45 → 55.
runh 200 "$(mkctxh 040000 0 500000 0 1000000 omit)"; chkh CTX19 55
# CTX20 negative counter → ineligible → the used_percentage fallback (96), not a nonsense percentage
runh 200 "$(mkctxh -5 60000 500000 400 1000000 96)"; chkh CTX20 96
# CTX21 16-digit counter (past the 15-digit cap that keeps 200*(P-T) inside 64-bit) → fallback, no wrap-around
runh 200 "$(mkctxh 1234567890123456 0 0 0 1000000 96)"; chkh CTX21 96
# CTX22 mixed alphanumeric "12a" → fallback
runh 200 "$(mkctxh 12a 60000 500000 400 1000000 96)"; chkh CTX22 96
# CTX23-CTX26 walk the leading zero across the REMAINING four operands, one per case, so that dropping the decimal
# prefix on any single one of the five is caught: CTX18/19 cover input_tokens, these cover the other three counters and
# the window. The counter cases use "08" (illegal as octal → the expression aborts and stderr is no longer empty); the
# window uses "01000000", a legal octal literal that would silently read as 262144 and show 100% instead of 98%.
runh 200 "$(mkctxh 400000 08 500000 400 1000000 omit)"; chkh CTX23 92   # cache_creation: T=900408 → R=8
runh 200 "$(mkctxh 400000 60000 08 400 1000000 omit)"; chkh CTX24 47    # cache_read:     T=460408 → R=53
runh 200 "$(mkctxh 400000 60000 500000 08 1000000 omit)"; chkh CTX25 98 # output_tokens:  T=960008 → R=2
runh 200 "$(mkctxh 400000 60000 500000 400 01000000 omit)"; chkh CTX26 98 # window: P=980000 as decimal, 242144 as octal

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

# Y10 sampled quantity is the freshest-observation authority, not the stale session report (task 3.1)
RA=$((NOWB+9000)); OLDA=$((NOWB-5000)); RECA=$((NOWB-100))
printf "S sRec %s %s 75 %s - - -\nS $(sidof sOldF) %s %s 40 %s - - -\nW5 %s 75 %s\n" "$RECA" "$RA" "$RECA" "$OLDA" "$RA" "$OLDA" "$RA" "$RECA" > "$SLC"
run 200 "$(rsj 40 "$RA" sOldF)" >/dev/null   # a stale carried observation reports 40 but adopts 75, so the sample records 75
case "$(grep "^P $RA " "$SLC")" in
  *" 75") echo "  Y10 sample records reconciled authority (75), not frozen report (40) OK" ;;
  *" 40") echo "  ★ FAIL Y10 sample recorded the stale report 40"; fail=1 ;;
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

# Y12 minimum-Δt gate (dt>=60, inclusive): a sub-minute render burst with a used% jump must NOT project a false alarm; a genuine
# 60s interval still alarms. brun's appended sample is at ~now, so dt = now - old_ts. (Y4 row 6's dt≈60 red alarm pins the inclusive boundary.)
y12bad=0
y12a=$(brun $((NOWB+9000)) $((NOWB-2))  40 70 sBurst | hasarrow)   # dt≈2s burst, used 40→70 — without the gate this falsely projects ↘
[ "$y12a" = no ]  || { echo "  ★ FAIL Y12 sub-minute burst (dt<60) emitted a false alarm"; y12bad=1; }
y12b=$(brun $((NOWB+9000)) $((NOWB-60)) 50 80 sEx60 | hasarrow)    # dt≈60s genuine interval, exhaust before reset → still shown (inclusive 60)
[ "$y12b" = yes ] || { echo "  ★ FAIL Y12 dt=60 genuine interval wrongly suppressed"; y12bad=1; }
[ "$y12bad" -eq 0 ] && echo "  Y12 dt>=60 gate: sub-minute burst hidden, genuine 60s shown OK" || fail=1
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

# Z2 (task 4.2) Per-segment forms: model compacts "Opus 4.8(1M)"→"Opus", ctx bar collapses to plain N%, 5h collapses to remaining% only.
echo "── Z2. per-segment compact forms: model→Opus, ctx bar→plain N%, 5h→remaining% (compact preferred over drop)"
z2bad=0
z2full=$(run 200 "$JZ"); z2fp=$(printf '%s' "$z2full" | nocol)
[ "$(printf '%s' "$z2full" | barcells)" -eq 12 ] || { echo "  ★ FAIL Z2 wide: ctx bar (12 cells) absent"; z2bad=1; }
case "$z2fp" in *"Opus 4.8(1M)"*) ;; *) echo "  ★ FAIL Z2 wide: full model name absent"; z2bad=1 ;; esac
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

# CLK (PATH_CLICK) The statusline cannot make its own path clickable — CC re-renders the line through its own style model
# and drops OSC 8 hyperlinks (measured: zero OSC 8 bytes reach the terminal, FORCE_HYPERLINK included). So the terminal
# does the opening and the statusline only publishes what the terminal cannot see: this pane's working directory, keyed by
# the claude pid (CC's children have no controlling terminal, so the tty is unknowable on this side; $PPID is claude).
echo "── CLK. PATH_CLICK: publish claude-pid → cwd for the terminal-side opener, reap dead panes, opener guards"
cbad=0
CWDMAP="$FAKE_HOME/.claude/sl-cwd"
OPENER="$SL/scripts/open-pane-dir.sh"
rm -rf "$CWDMAP"
run 140 "$J" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -d "$CWDMAP" ] && [ -n "$(ls -A "$CWDMAP" 2>/dev/null)" ] && break; sleep 0.2; done   # detached job
pub=$(ls -A "$CWDMAP" 2>/dev/null | head -1)
if [ -z "$pub" ]; then echo "  ★ FAIL CLK nothing published"; cbad=1; else
  case $pub in ''|*[!0-9]*) echo "  ★ FAIL CLK record not keyed by pid: [$pub]"; cbad=1 ;; esac
  [ "$(cat "$CWDMAP/$pub" 2>/dev/null)" = "$SL" ] || { echo "  ★ FAIL CLK published dir [$(cat "$CWDMAP/$pub" 2>/dev/null)] != [$SL]"; cbad=1; }
  # the map leaks directory paths of every open pane → must not be world-readable
  perm=$(stat -f '%Lp' "$CWDMAP" 2>/dev/null); [ "$perm" = "700" ] || { echo "  ★ FAIL CLK dir mode $perm != 700"; cbad=1; }
  perm=$(stat -f '%Lp' "$CWDMAP/$pub" 2>/dev/null); [ "$perm" = "600" ] || { echo "  ★ FAIL CLK file mode $perm != 600"; cbad=1; }
fi
# a pane that is gone must not leave its directory behind forever (pid 1 is alive and must survive; a free high pid must not)
deadpid=$(( 99000 + RANDOM % 900 )); while kill -0 "$deadpid" 2>/dev/null; do deadpid=$((deadpid+1)); done
echo /tmp > "$CWDMAP/$deadpid"; echo /tmp > "$CWDMAP/1"; echo /tmp > "$CWDMAP/not-a-pid"
run 140 "$J" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$CWDMAP/$deadpid" ] || break; sleep 0.2; done
[ -f "$CWDMAP/$deadpid" ] && { echo "  ★ FAIL CLK dead pane record not reaped"; cbad=1; }
[ -f "$CWDMAP/1" ]       || { echo "  ★ FAIL CLK live pid record wrongly reaped"; cbad=1; }
[ -f "$CWDMAP/not-a-pid" ] || { echo "  ★ FAIL CLK non-pid file wrongly removed"; cbad=1; }
# PATH_CLICK=false publishes nothing at all
mkdir -p "$WORK/noclick/lib" && cp "$SL"/lib/*.sh "$WORK/noclick/lib/"
sed 's/^PATH_CLICK=true/PATH_CLICK=false/' "$SL/statusline-command.sh" > "$WORK/noclick/statusline-command.sh"
rm -rf "$CWDMAP"
printf '%s' "$J" | env COLUMNS=140 HOME="$FAKE_HOME" bash "$WORK/noclick/statusline-command.sh" >/dev/null
sleep 0.6
[ -d "$CWDMAP" ] && { echo "  ★ FAIL CLK PATH_CLICK=false still published"; cbad=1; }
# opener guards: a tty string that is not a plain device name must be rejected before it reaches ps, and an unknown
# pane must fail cleanly rather than open something arbitrary. SL_OPEN_NOTIFY=0 keeps these paths silent.
out=$(SL_OPEN_NOTIFY=0 HOME="$FAKE_HOME" bash "$OPENER" '/dev/../etc/passwd' 2>&1); rc=$?
[ "$rc" -eq 1 ] && case "$out" in *"unexpected tty"*) ;; *) echo "  ★ FAIL CLK traversal tty not rejected: [$out]"; cbad=1 ;; esac
[ "$rc" -eq 1 ] || { echo "  ★ FAIL CLK traversal tty exit=$rc"; cbad=1; }
out=$(SL_OPEN_NOTIFY=0 HOME="$FAKE_HOME" bash "$OPENER" /dev/ttys999 2>&1); rc=$?
[ "$rc" -eq 1 ] || { echo "  ★ FAIL CLK unknown pane should fail, exit=$rc"; cbad=1; }
[ "$cbad" -eq 0 ] && echo "  CLK publish + reap + private perms + disable + opener guards OK" || fail=1

echo "── Q. alternate-billing quota field"
# A session billing somewhere other than the personal subscription must not show
# the personal rate limits: those percentages belong to an account it is not
# spending, which is worse than showing nothing.
qbad=0
qdir="$WORK/quota"
mkdir -p "$qdir"
qrun() {  # $1=cols $2=json ; same as run() plus a configured gateway
  printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" \
    ANTHROPIC_BASE_URL="https://gw.example.invalid/v1" \
    SL_QUOTA_MATCH="gw.example.invalid" SL_QUOTA_LABEL="TEAM" SL_QUOTA_DIR="$qdir" \
    bash "$SL/statusline-command.sh"
}
qrun_stale() {  # $1=stale seconds $2=cols $3=json
  printf '%s' "$3" | env COLUMNS="$2" HOME="$FAKE_HOME" SL_QUOTA_STALE="$1" \
    ANTHROPIC_BASE_URL="https://gw.example.invalid/v1" \
    SL_QUOTA_MATCH="gw.example.invalid" SL_QUOTA_LABEL="TEAM" SL_QUOTA_DIR="$qdir" \
    bash "$SL/statusline-command.sh"
}
# Extract the SGR code immediately before the quota value or label. References
# are derived from the live palette in one frame, so no colour triple is fixed.
qvaluecode() { perl -ne 'while(/\x1b\[([0-9;]*)m63%\*/g){$c=$1} END{print $c}'; }
qlabelcode() { perl -ne 'while(/\x1b\[([0-9;]*)mTEAM/g){$c=$1} END{print $c}'; }

# QS0: derive distinct severity and DM role codes from the current palette.
printf '63%%* red\n' > "$qdir/claude-opus-4-8"
qsref=$(qrun 200 "$J"); qs_sev=$(printf '%s' "$qsref" | qvaluecode); qs_dm=$(printf '%s' "$qsref" | qlabelcode)
if [ -n "$qs_sev" ] && [ -n "$qs_dm" ] && [ "$qs_sev" != "$qs_dm" ]; then
  echo "  QS0 quota severity/DM colours derived OK"
else
  echo "  ★ FAIL QS0 could not derive distinct quota colours (severity=[$qs_sev] DM=[$qs_dm])"; qbad=1
fi

qnow=$(date +%s)
# QS1: a timestamp 60 seconds ago remains in its severity role.
printf '63%%* red %s\n' "$((qnow-60))" > "$qdir/claude-opus-4-8"
qs1=$(qrun 200 "$J"); qs1code=$(printf '%s' "$qs1" | qvaluecode); qs1plain=$(printf '%s' "$qs1" | nocol)
[ "$qs1code" = "$qs_sev" ] || { echo "  ★ FAIL QS1 fresh value not in severity role (got=[$qs1code] want=[$qs_sev])"; qbad=1; }
case "$qs1plain" in *"63%*"*) ;; *) echo "  ★ FAIL QS1 value text changed: [$qs1plain]"; qbad=1 ;; esac
case "$qs1plain" in *"$((qnow-60))"*) echo "  ★ FAIL QS1 timestamp reached screen: [$qs1plain]"; qbad=1 ;; esac

# QS2: 901 seconds is strictly outside the default window, so only the value
# role changes to DM; the stripped frame stays byte-identical to QS1.
printf '63%%* red %s\n' "$((qnow-901))" > "$qdir/claude-opus-4-8"
qs2=$(qrun 200 "$J"); qs2code=$(printf '%s' "$qs2" | qvaluecode); qs2dm=$(printf '%s' "$qs2" | qlabelcode); qs2plain=$(printf '%s' "$qs2" | nocol)
[ "$qs2code" = "$qs2dm" ] || { echo "  ★ FAIL QS2 stale value not in DM role (value=[$qs2code] DM=[$qs2dm])"; qbad=1; }
[ "$qs2code" != "$qs_sev" ] || { echo "  ★ FAIL QS2 stale value retained severity role"; qbad=1; }
[ "$qs2plain" = "$qs1plain" ] || { echo "  ★ FAIL QS2 dimming changed stripped frame"; qbad=1; }

# QS3/QS4: old two-field files and unusable third fields keep severity colour;
# neither the timestamp nor any trailing content may reach the screen.
for qline in '63%* red' '63%* red abc' '63%* red 1756300000 extra'; do
  printf '%s\n' "$qline" > "$qdir/claude-opus-4-8"
  qso=$(qrun 200 "$J"); qscode=$(printf '%s' "$qso" | qvaluecode); qsplain=$(printf '%s' "$qso" | nocol)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS3/QS4 unusable timestamp changed severity for [$qline]"; qbad=1; }
  case "$qsplain" in *abc*|*1756300000*|*extra*) echo "  ★ FAIL QS3/QS4 third field reached screen: [$qsplain]"; qbad=1 ;; esac
done

# QS5: an environment override of 60 seconds dims age 61, while the same file
# remains fresh under the default 900-second window.
printf '63%%* red %s\n' "$((qnow-61))" > "$qdir/claude-opus-4-8"
qs5=$(qrun_stale 60 200 "$J"); qs5code=$(printf '%s' "$qs5" | qvaluecode); qs5dm=$(printf '%s' "$qs5" | qlabelcode)
[ "$qs5code" = "$qs5dm" ] || { echo "  ★ FAIL QS5 override did not dim age 61 (value=[$qs5code] DM=[$qs5dm])"; qbad=1; }
qs5default=$(qrun 200 "$J" | qvaluecode)
[ "$qs5default" = "$qs_sev" ] || { echo "  ★ FAIL QS5 default window dimmed age 61"; qbad=1; }

# QS6: unusable windows fall back to 900, and a leading zero is decimal. Ages
# 61 and 600 bind the fresh side (including against a bogus fallback of 100),
# while age 1200 binds the stale side of the same default.
for qwindow in '' sixty 1234567890123456789012345678901234567890 00900; do
  printf '63%%* red %s\n' "$((qnow-61))" > "$qdir/claude-opus-4-8"
  qscode=$(qrun_stale "$qwindow" 200 "$J" | qvaluecode)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS6 window [$qwindow] dimmed age 61"; qbad=1; }
  printf '63%%* red %s\n' "$((qnow-600))" > "$qdir/claude-opus-4-8"
  qscode=$(qrun_stale "$qwindow" 200 "$J" | qvaluecode)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS6 window [$qwindow] did not retain default/decimal 900"; qbad=1; }
  printf '63%%* red %s\n' "$((qnow-1200))" > "$qdir/claude-opus-4-8"
  qso=$(qrun_stale "$qwindow" 200 "$J"); qscode=$(printf '%s' "$qso" | qvaluecode); qsdm=$(printf '%s' "$qso" | qlabelcode)
  [ "$qscode" = "$qsdm" ] || { echo "  ★ FAIL QS6 window [$qwindow] did not use decimal/default 900"; qbad=1; }
done

# QS7: future/millisecond/oversized timestamps are never stale; a usable
# leading-zero timestamp is read in base 10 and remains fresh here.
for qat in "$((qnow+3600))" 1756300000000 1234567890123456789012345678901234567890 "0$((qnow-60))"; do
  printf '63%%* red %s\n' "$qat" > "$qdir/claude-opus-4-8"
  qscode=$(qrun 200 "$J" | qvaluecode)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS7 timestamp [$qat] was incorrectly dimmed"; qbad=1; }
done

# A colon is not a digit. It must fail closed to severity without entering
# arithmetic, printing diagnostics, or terminating the frame.
printf '63%%* red 123:456\n' > "$qdir/claude-opus-4-8"
qs7err="$WORK/qs7-colon.err"
qs7colon=$(qrun 200 "$J" 2>"$qs7err"); qs7rc=$?
qs7code=$(printf '%s' "$qs7colon" | qvaluecode); qs7lines=$(printf '%s' "$qs7colon" | grep -c '')
[ "$qs7rc" -eq 0 ] || { echo "  ★ FAIL QS7 colon timestamp terminated frame (exit=$qs7rc)"; qbad=1; }
[ ! -s "$qs7err" ] || { echo "  ★ FAIL QS7 colon timestamp wrote stderr"; qbad=1; }
[ "$qs7lines" -eq 1 ] || { echo "  ★ FAIL QS7 colon timestamp output lines=$qs7lines"; qbad=1; }
[ "$qs7code" = "$qs_sev" ] || { echo "  ★ FAIL QS7 colon timestamp changed severity"; qbad=1; }

# QS8: guarantee the writer timestamp and jq's render time are in the same
# wall-clock second, then bind the strict default boundary: age 900 is fresh.
qs8=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  qs8now=$(date +%s)
  printf '63%%* red %s\n' "$((qs8now-900))" > "$qdir/claude-opus-4-8"
  qs8try=$(qrun 200 "$J")
  [ "$(date +%s)" = "$qs8now" ] || continue
  qs8=$qs8try
  break
done
if [ -n "$qs8" ]; then
  qs8code=$(printf '%s' "$qs8" | qvaluecode)
  [ "$qs8code" = "$qs_sev" ] || { echo "  ★ FAIL QS8 age exactly 900 was dimmed"; qbad=1; }
else
  echo "  ★ FAIL QS8 could not capture a same-second boundary frame"; qbad=1
fi
[ "$qbad" -ne 0 ] || echo "  QS1-QS8 freshness, strict boundary, guards, fallback, and override cases OK"

# QJ: the writer joins two figures into this one slot with its own separator --
# U+00A0 │ U+00A0. The no-break spaces are deliberate: read_quota_field splits
# the file with IFS=' ', so only a space that is not an ASCII space keeps the
# joined text together as field one. That │ is punctuation, not data, so it must
# be drawn in the same neutral SP role as every other │ on the line instead of
# pulsing orange/red/DM with the numbers it divides.
qsep=$(printf '\302\240\342\224\202\302\240')
# SGR immediately before the value's own │, identified by the no-break space in
# front of it -- no other separator on the line is preceded by one.
qsepcode() { perl -ne 'while(/\x1b\[([0-9;]*)m\xc2\xa0\xe2\x94\x82/g){$c=$1} END{print $c}'; }
# SGR of the structural SP role, read off an ordinary " │ " join in the same frame.
qspcode()  { perl -ne 'while(/\x1b\[([0-9;]*)m \xe2\x94\x82/g){$c=$1} END{print $c}'; }
# SGR immediately before an arbitrary literal word.
qjcode()   { QW="$1" perl -ne 'while(/\x1b\[([0-9;]*)m\Q$ENV{QW}\E/g){$c=$1} END{print $c}'; }

qjnow=$(date +%s)
printf '36.9M%s26%% orange %s\n' "$qsep" "$((qjnow-60))" > "$qdir/claude-opus-4-8"
qj1=$(qrun 200 "$J")
qj1sp=$(printf '%s' "$qj1" | qspcode)
qj1sep=$(printf '%s' "$qj1" | qsepcode)
qj1l=$(printf '%s' "$qj1" | qjcode '36.9M')
qj1r=$(printf '%s' "$qj1" | qjcode '26%')
# Preconditions: without a live SP that differs from the severity role, the
# assertions below would pass no matter how the separator were coloured.
if [ -z "$qj1sp" ] || [ -z "$qj1l" ] || [ "$qj1sp" = "$qj1l" ]; then
  echo "  ★ FAIL QJ1 preconditions (SP=[$qj1sp] severity=[$qj1l]) -- assertions would be vacuous"; qbad=1
fi
[ "$qj1l" = "$qj1r" ] || { echo "  ★ FAIL QJ1 figures differ in colour (left=[$qj1l] right=[$qj1r])"; qbad=1; }
[ "$qj1sep" = "$qj1sp" ] || { echo "  ★ FAIL QJ1 separator not in SP role (sep=[$qj1sep] SP=[$qj1sp])"; qbad=1; }
[ "$qj1sep" != "$qj1l" ] || { echo "  ★ FAIL QJ1 separator took the severity colour [$qj1sep]"; qbad=1; }

# QJ4: recolouring must not disturb one character of the display text.
qj1plain=$(printf '%s' "$qj1" | nocol)
case "$qj1plain" in *"36.9M${qsep}26%"*) ;; *) echo "  ★ FAIL QJ4 display text altered: [$qj1plain]"; qbad=1 ;; esac
case "$qj1plain" in *"$((qjnow-60))"*) echo "  ★ FAIL QJ4 timestamp reached screen"; qbad=1 ;; esac

# QJ3: staleness dims the figures; the separator stays structural in both frames.
printf '36.9M%s26%% orange %s\n' "$qsep" "$((qjnow-901))" > "$qdir/claude-opus-4-8"
qj3=$(qrun 200 "$J")
qj3sp=$(printf '%s' "$qj3" | qspcode)
qj3sep=$(printf '%s' "$qj3" | qsepcode)
qj3l=$(printf '%s' "$qj3" | qjcode '36.9M')
qj3r=$(printf '%s' "$qj3" | qjcode '26%')
qj3dm=$(printf '%s' "$qj3" | qlabelcode)
if [ -z "$qj3sp" ] || [ -z "$qj3dm" ] || [ "$qj3sp" = "$qj3dm" ]; then
  echo "  ★ FAIL QJ3 preconditions (SP=[$qj3sp] DM=[$qj3dm]) -- assertions would be vacuous"; qbad=1
fi
[ "$qj3l" = "$qj3dm" ] || { echo "  ★ FAIL QJ3 stale left figure not DM (got=[$qj3l] DM=[$qj3dm])"; qbad=1; }
[ "$qj3r" = "$qj3dm" ] || { echo "  ★ FAIL QJ3 stale right figure not DM (got=[$qj3r] DM=[$qj3dm])"; qbad=1; }
[ "$qj3sep" = "$qj3sp" ] || { echo "  ★ FAIL QJ3 stale separator not in SP role (sep=[$qj3sep] SP=[$qj3sp])"; qbad=1; }
[ "$qj3sep" != "$qj3dm" ] || { echo "  ★ FAIL QJ3 separator was dimmed along with the figures"; qbad=1; }

# QJ2: a value carrying no separator keeps today's shape exactly -- one SGR, the
# whole string, one reset, with none of the splitting machinery in between.
printf 'no-cookie yellow %s\n' "$((qjnow-60))" > "$qdir/claude-opus-4-8"
qj2=$(qrun 200 "$J")
qj2one=$(printf '%s' "$qj2" | perl -ne 'print "y" if /\x1b\[[0-9;]*mno-cookie\x1b\[0m/')
[ "$qj2one" = "y" ] || { echo "  ★ FAIL QJ2 separatorless value no longer one contiguous coloured run"; qbad=1; }
[ -z "$(printf '%s' "$qj2" | qsepcode)" ] || { echo "  ★ FAIL QJ2 separator role appeared inside a value with no separator"; qbad=1; }

# QJ5: the separator sitting at the value's leading or trailing EDGE — the one arrangement QJ1-QJ4 never feed, since they all
# put text on both sides of it. build_quota_value splits the text on the separator and colours each run, so an edge separator
# leaves one run EMPTY: the loop emits a bare "<severity SGR><reset>" pair with no character between them. That pair is
# invisible by construction (vis_width consumes every ESC before it measures) and this case pins that claim down.
# The control fixture "2<sep>6%" is picked to carry exactly the SAME bytes as the two edge fixtures — three ASCII characters,
# two no-break spaces, one │ — so the renderer's width arithmetic sees an identical byte profile and the ONLY difference left
# is where the separator sits. Equal rendered width therefore means the empty run cost zero cells; an unequal one would mean
# it was measured. Roles are read against QJ1's own frame, so the severity and SP references come from the live palette.
qj5frame() {  # $1=quota value text → the raw frame that value renders at COLUMNS=200
  printf '%s orange %s\n' "$1" "$((qjnow-60))" > "$qdir/claude-opus-4-8"
  qrun 200 "$J"
}
qj5vw() {  # stdin=frame → visible width of the quota value alone: the text between the TEAM label and the next structural " │ ".
           # The value's own separator is no-break-space-delimited, so a non-greedy match cannot mistake it for that structural join.
  nocol | python3 -c '
import sys, re, unicodedata
line = sys.stdin.read().rstrip("\n")
m = re.search(u"TEAM \u2502 (.*?) \u2502 ", line)
print(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in m.group(1)) if m else -1)'
}
qj5ctl=$(qj5frame "2${qsep}6%")            # interior separator, same bytes as both edge fixtures
qj5ctlw=$(printf '%s' "$qj5ctl" | vw); qj5ctlvw=$(printf '%s' "$qj5ctl" | qj5vw)
qj5lead=$(qj5frame "${qsep}26%")
qj5trail=$(qj5frame "26%${qsep}")
[ "$qj5ctlvw" -gt 0 ] || { echo "  ★ FAIL QJ5 control value not locatable in the frame — the asserts below would be vacuous"; qbad=1; }
for qj5n in lead trail; do
  case "$qj5n" in
    lead)  qj5v="${qsep}26%";  qj5f=$qj5lead  ;;
    trail) qj5v="26%${qsep}";  qj5f=$qj5trail ;;
  esac
  qj5plain=$(printf '%s' "$qj5f" | nocol)
  # Visible text, bounded on BOTH sides by the structural join, so a stray blank emitted for the empty run cannot hide in a
  # trailing wildcard: the value must be the writer's string exactly, no character more.
  case "$qj5plain" in *"TEAM │ ${qj5v} │ "*) ;; *) echo "  ★ FAIL QJ5/$qj5n visible text is not the value verbatim: [$qj5plain]"; qbad=1 ;; esac
  # Width, two independent ways. The value's own visible width catches a character leaking out of the empty run; the whole
  # frame's width catches the opposite error, the renderer MEASURING the empty run and under-filling the line to pay for it.
  qj5vwn=$(printf '%s' "$qj5f" | qj5vw)
  [ "$qj5vwn" = "$qj5ctlvw" ] || { echo "  ★ FAIL QJ5/$qj5n quota value width $qj5vwn != interior-control $qj5ctlvw — the empty colour run is not empty"; qbad=1; }
  qj5w=$(printf '%s' "$qj5f" | vw)
  [ "$qj5w" = "$qj5ctlw" ] || { echo "  ★ FAIL QJ5/$qj5n frame width $qj5w != interior-control $qj5ctlw — the empty colour run is being measured"; qbad=1; }
  qj5sep=$(printf '%s' "$qj5f" | qsepcode)
  qj5fig=$(printf '%s' "$qj5f" | qjcode '26%')
  [ "$qj5sep" = "$qj1sp" ] || { echo "  ★ FAIL QJ5/$qj5n edge separator left the neutral SP role (sep=[$qj5sep] SP=[$qj1sp])"; qbad=1; }
  [ "$qj5fig" = "$qj1l" ]  || { echo "  ★ FAIL QJ5/$qj5n figure lost the severity role (got=[$qj5fig] want=[$qj1l])"; qbad=1; }
done
rm -f "$qdir/claude-opus-4-8"

[ "$qbad" -ne 0 ] || echo "  QJ1-QJ5 inline separator neutral, figures coloured, stale dims figures only, text intact, edge separator costs no width OK"

# mkjson reports "Opus 4.8 (1M context)", which maps to claude-opus-4-8.
printf '3.3%% green\n' > "$qdir/claude-opus-4-8"
out=$(qrun 200 "$J" | nocol)
case "$out" in *"TEAM"*"3.3%"*) ;; *) echo "  ★ FAIL label+value missing: [$out]"; qbad=1 ;; esac
# 23 and 84 used render as 77% and 16% remaining; neither may survive here.
case "$out" in *"77%"*|*"16%"*) echo "  ★ FAIL personal rate limits leaked: [$out]"; qbad=1 ;; esac

# Unconfigured sessions keep the old behaviour exactly.
out=$(run 200 "$J" | nocol)
case "$out" in *TEAM*) echo "  ★ FAIL quota field shown while unconfigured: [$out]"; qbad=1 ;; esac
case "$out" in *"77%"*) ;; *) echo "  ★ FAIL personal rate limit vanished while unconfigured: [$out]"; qbad=1 ;; esac

# Configured label but a base URL that does not match: still the old behaviour.
out=$(printf '%s' "$J" | env COLUMNS=200 HOME="$FAKE_HOME" \
      ANTHROPIC_BASE_URL="https://api.anthropic.com" \
      SL_QUOTA_MATCH="gw.example.invalid" SL_QUOTA_LABEL="TEAM" SL_QUOTA_DIR="$qdir" \
      bash "$SL/statusline-command.sh" | nocol)
case "$out" in *TEAM*) echo "  ★ FAIL quota field shown for a non-matching base URL: [$out]"; qbad=1 ;; esac

# A marker the writer appends (an unenforced limit, say) must reach the screen
# untouched: without it a comfortable number looks like a line that would stop you.
printf '1.4%%* green\n' > "$qdir/claude-opus-4-8"
out=$(qrun 200 "$J" | nocol)
case "$out" in *"1.4%*"*) ;; *) echo "  ★ FAIL trailing marker dropped: [$out]"; qbad=1 ;; esac

# Nothing cached yet: still say which account this is, just without a number.
rm -f "$qdir/claude-opus-4-8"
out=$(qrun 200 "$J" | nocol)
case "$out" in *TEAM*) ;; *) echo "  ★ FAIL label needs no cached value: [$out]"; qbad=1 ;; esac
case "$out" in *"77%"*|*"16%"*) echo "  ★ FAIL personal limits reappeared with no cache: [$out]"; qbad=1 ;; esac

# An unrecognised model family falls through to the same safe state rather than
# reading some other model's file.
JQ2=$(printf '%s' "$J" | jq -c '.model.display_name="Nimbus 9 (1M context)"')
printf '99.9%% red\n' > "$qdir/claude-opus-4-8"
out=$(qrun 200 "$JQ2" | nocol)
case "$out" in *"99.9%"*) echo "  ★ FAIL unknown family read another model's value: [$out]"; qbad=1 ;; esac
case "$out" in *TEAM*) ;; *) echo "  ★ FAIL label missing for unknown family: [$out]"; qbad=1 ;; esac
rm -f "$qdir/claude-opus-4-8"

# Narrowing drops the value before the label. A percentage with nothing naming
# the account it belongs to is worse than no percentage: the label is the part
# that answers "whose allowance is this".
printf '42%% green\n' > "$qdir/claude-opus-4-8"
wide=$(qrun 200 "$J" | nocol)
case "$wide" in *"TEAM"*"42%"*) ;; *) echo "  ★ FAIL wide line lost label or value: [$wide]"; qbad=1 ;; esac
narrow=$(qrun 70 "$J" | nocol)
case "$narrow" in *"42%"*) echo "  ★ FAIL value survived a width that must drop it: [$narrow]"; qbad=1 ;; esac
case "$narrow" in *TEAM*) ;; *) echo "  ★ FAIL label dropped before the value: [$narrow]"; qbad=1 ;; esac
rm -f "$qdir/claude-opus-4-8"

[ "$qbad" -eq 0 ] && echo "  quota label + value + marker + no-cache + unknown-model + off-by-default + ladder OK" || fail=1

# ── SUBAGENT STATUS LINE (SA1-SA4) ──────────────────────────────────────────────────────────────────
# Second entry point. subagent-status-line.sh reads the subagent status JSON on stdin and prints JSON Lines
# ({"id":…,"content":…}), one record per task row it takes over. A task id it does NOT print keeps Claude
# Code's own default row, and that guaranteed fallback is this script's ONLY error path — so "emitted nothing
# for this id" is a PASS condition in several cases below, never an accident to be papered over.
# HOME is pinned to $FAKE_HOME like every other invocation in this file: the script resolves the user's theme
# from ~/.claude.json, and the real one would make the palette (hence the emitted SGR bytes) machine-dependent.
SASCRIPT="$SL/subagent-status-line.sh"

sarun() {   # $1=payload JSON → JSON Lines on stdout
  printf '%s' "$1" | env HOME="$FAKE_HOME" bash "$SASCRIPT"
}

saraw() {   # stdin=JSON Lines, $1=task id → that record's content verbatim (empty when the id was not emitted)
  # Must run via -c, NOT heredoc: a heredoc steals stdin so the data side would read nothing (harness-wide rule).
  python3 -c '
import sys, json
want = sys.argv[1]; out = ""
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    o = json.loads(line)
    if o.get("id") == want: out = o.get("content", "")
sys.stdout.write(out)' "$1"
}

sajsonl() {  # stdin=JSON Lines → "OK <n>" when every line is an object with exactly id+content, else the reason
  python3 -c '
import sys, json
n = 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    try: o = json.loads(line)
    except Exception as e: print("bad JSON line: %s" % e); sys.exit(0)
    if not isinstance(o, dict): print("line is not an object"); sys.exit(0)
    if set(o) != {"id", "content"}: print("unexpected keys: %r" % sorted(o)); sys.exit(0)
    n += 1
print("OK %d" % n)'
}

sacolat() {  # stdin=raw content, $1=text to locate, $2=expected SGR prefix → "OK" or the mismatch
  python3 -c '
import sys, re
s = sys.stdin.read(); needle = sys.argv[1]; want = sys.argv[2]
m = re.search(r"(\x1b\[[0-9;]*m)" + re.escape(needle), s)
if not m: print("not found: %r" % needle)
elif m.group(1) != want: print("colour %r, wanted %r" % (m.group(1), want))
else: print("OK")' "$1" "$2"
}

samk() {  # $1=model $2=contextWindowSize $3=description $4=label $5=columns — "" omits that field entirely
  jq -cn --arg m "$1" --arg w "$2" --arg d "$3" --arg l "$4" --arg c "$5" '
    { tasks: [ {id:"tid"}
        + (if $m == "" then {} else {model:$m} end)
        + (if $w == "" then {} else {contextWindowSize:($w|tonumber)} end)
        + (if $d == "" then {} else {description:$d} end)
        + (if $l == "" then {} else {label:$l} end) ] }
    + (if $c == "" then {} else {columns:($c|tonumber)} end)'
}

# The palette the script itself will load: same STYLE source (statusline-command.sh's knob, pulled the way
# EDGE_PAD/JGAP are above) and same empty-theme = dark path. Asserting against the ROLE (MD / YL) rather than
# a hardcoded RGB keeps these checks true under any STYLE. Caveat: rose-pine defines MD and YL as the same
# bytes, so under that style the two colour asserts stop being able to tell the roles apart (they still pass).
SASTYLE=$(sed -n 's/^STYLE="\([^"]*\)".*/\1/p' "$SL/statusline-command.sh")
SAMD=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$MD" )
SAYL=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$YL" )

echo "── SA1. SUBAGENT: Model display name derived by rule, never by lookup table (five derivation cases)"
sa1bad=0
sacase() {  # $1=model identifier $2=expected display name
  local got
  got=$(sarun "$(samk "$1" 1000000 d l 120)" | saraw tid | nocol)
  if [ "$got" = "d │ $2(1M) │ l" ]; then :; else
    echo "  ★ FAIL model [$1] → wanted [d │ $2(1M) │ l], got [$got]"; sa1bad=1
  fi
}
sacase 'claude-sonnet-5'   'Sonnet 5'
sacase 'claude-opus-5[1m]' 'Opus 5'
sacase 'claude-haiku-4-5'  'Haiku 4.5'
sacase 'claude-opus-4-8'   'Opus 4.8'
sacase 'claude-mystery'    'mystery'     # no numeric segment: printed verbatim after prefix strip, never guessed
# The harness's `bash` is whatever PATH resolves first (homebrew bash 5 on this machine), so nothing above
# can prove the project's "target bash 3.2" rule. macOS's system bash IS 3.2.57: render the same frame
# through it and demand byte-identical output, so a bash-4-only construct fails here and not on a user's
# machine. A missing /bin/bash is reported as a skip, never counted as a pass.
if [ -x /bin/bash ]; then
  sa1p=$(samk claude-haiku-4-5 200000 DESCR LABEL 120)
  sa1a=$(printf '%s' "$sa1p" | env HOME="$FAKE_HOME" bash "$SASCRIPT")
  sa1b=$(printf '%s' "$sa1p" | env HOME="$FAKE_HOME" /bin/bash "$SASCRIPT")
  if [ -n "$sa1b" ] && [ "$sa1a" = "$sa1b" ]; then :; else
    echo "  ★ FAIL system bash 3.2 renders differently from PATH bash"; echo "    PATH bash: [$sa1a]"; echo "    bash 3.2 : [$sa1b]"; sa1bad=1
  fi
else
  echo "  NOTE /bin/bash absent — the bash 3.2 cross-check did NOT run and is NOT a pass"
fi
[ "$sa1bad" -eq 0 ] && echo "  sonnet-5 / opus-5[1m] / haiku-4-5 / opus-4-8 / unrecognised + bash 3.2 parity OK" || fail=1

echo "── SA2. SUBAGENT: Absent fields fall back to Claude Code's default row (no model / no description / no label)"
sa2bad=0
# (a) the smoke-test row captured alongside the real frames: id + name only, no model, no window, no description
sa2out=$(sarun '{"tasks":[{"id":"t1","name":"demo"}],"columns":120}'); sa2rc=$?
[ "$sa2rc" -eq 0 ] || { echo "  ★ FAIL exit $sa2rc on a row carrying no model"; sa2bad=1; }
case "$sa2out" in *t1*) echo "  ★ FAIL a row with no model was emitted: [$sa2out]"; sa2bad=1 ;; esac
# (b) description absent, label present → label is promoted to the first segment and NOT repeated as the third
sa2b=$(sarun "$(samk claude-sonnet-5 1000000 '' PROMOTED 120)" | saraw tid | nocol)
[ "$sa2b" = "PROMOTED │ Sonnet 5(1M)" ] || { echo "  ★ FAIL promoted label: wanted [PROMOTED │ Sonnet 5(1M)], got [$sa2b]"; sa2bad=1; }
# (c) label absent → the third segment and the separator before it are both gone
sa2c=$(sarun "$(samk claude-sonnet-5 1000000 DESCR '' 120)" | saraw tid | nocol)
[ "$sa2c" = "DESCR │ Sonnet 5(1M)" ] || { echo "  ★ FAIL missing label: wanted [DESCR │ Sonnet 5(1M)], got [$sa2c]"; sa2bad=1; }
# (d) neither description nor label → the row cannot be attributed to any task, so it keeps its default row
sa2d=$(sarun "$(samk claude-sonnet-5 1000000 '' '' 120)")
case "$sa2d" in *tid*) echo "  ★ FAIL row with no description and no label was emitted: [$sa2d]"; sa2bad=1 ;; esac
[ "$sa2bad" -eq 0 ] && echo "  no-model / promoted-label / dropped-label / unattributable all fall back OK" || fail=1

echo "── SA3. SUBAGENT: Per-task subagent line content + Context-window marker signals a shrunken window"
sa3bad=0
# Real captured frames, embedded verbatim so this section stays hermetic if scratchpad is ever cleared.
SAREAL1='{"session_id":"ceffb128-b1cd-4561-b8a7-0b522a1f582c","cwd":"/Users/will/Downloads/macOS","agent_type":"commander","columns":160,"tasks":[{"id":"ab4c560a44129c990","type":"local_agent","status":"running","description":"實作 wrap-up 感知的 ctx guard","label":"Extracting command-args from wrap-up envelopes","startTime":1788426930573,"model":"claude-opus-5[1m]","contextWindowSize":1000000,"tokenCount":254074,"tokenSamples":[254074],"cwd":"/Users/will/Downloads/macOS"}]}'
SAREAL2='{"columns":160,"tasks":[{"id":"aa0603d3a354ff732","type":"local_agent","status":"running","description":"Remove library-divergence-watch","label":"Reading threshold-watch.sh","startTime":1788427330881,"model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":66562},{"id":"acee8f6f3483fcf1f","type":"local_agent","status":"running","description":"Codex: review relay guard design","label":"Codex: review relay guard design","startTime":1788427376910,"model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":0}]}'
sa3j=$(sarun "$SAREAL1" | sajsonl)
case "$sa3j" in "OK 1") ;; *) echo "  ★ FAIL real 1-task frame is not clean JSON Lines: [$sa3j]"; sa3bad=1 ;; esac
sa3a=$(sarun "$SAREAL1" | saraw ab4c560a44129c990 | nocol)
[ "$sa3a" = "實作 wrap-up 感知的 ctx guard │ Opus 5(1M) │ Extracting command-args from wrap-up envelopes" ] \
  || { echo "  ★ FAIL real frame content: [$sa3a]"; sa3bad=1; }
sa3j2=$(sarun "$SAREAL2" | sajsonl)
case "$sa3j2" in "OK 2") ;; *) echo "  ★ FAIL real 2-task frame did not yield 2 clean records: [$sa3j2]"; sa3bad=1 ;; esac
sa3b=$(sarun "$SAREAL2" | saraw acee8f6f3483fcf1f | nocol)
[ "$sa3b" = "Codex: review relay guard design │ Sonnet 5(1M) │ Codex: review relay guard design" ] \
  || { echo "  ★ FAIL second task of the real 2-task frame: [$sa3b]"; sa3bad=1; }
# 1M window: marker present and drawn in the MODEL role (normal state)
sa3c=$(sarun "$(samk claude-sonnet-5 1000000 d l 120)" | saraw tid | sacolat '(1M)' "$SAMD")
[ "$sa3c" = OK ] || { echo "  ★ FAIL (1M) marker colour: $sa3c"; sa3bad=1; }
# shrunken window: 200K in the WARNING role — the whole point of the marker
sa3d=$(sarun "$(samk claude-sonnet-5 200000 d l 120)" | saraw tid | nocol)
[ "$sa3d" = "d │ Sonnet 5(200K) │ l" ] || { echo "  ★ FAIL 200K marker text: [$sa3d]"; sa3bad=1; }
sa3e=$(sarun "$(samk claude-sonnet-5 200000 d l 120)" | saraw tid | sacolat '(200K)' "$SAYL")
[ "$sa3e" = OK ] || { echo "  ★ FAIL (200K) marker colour: $sa3e"; sa3bad=1; }
# window size absent → the whole bracket is omitted; no "(?)" and no guessed default
sa3f=$(sarun "$(samk claude-sonnet-5 '' d l 120)" | saraw tid | nocol)
[ "$sa3f" = "d │ Sonnet 5 │ l" ] || { echo "  ★ FAIL absent window size: wanted [d │ Sonnet 5 │ l], got [$sa3f]"; sa3bad=1; }
[ "$sa3bad" -eq 0 ] && echo "  real 1-task + 2-task frames, JSON Lines shape, 1M/200K/absent markers OK" || fail=1

echo "── SA4. SUBAGENT: Untrusted input is sanitised + Width is bounded by the reported column count"
sa4bad=0
# (a) a raw ESC in a field never reaches the terminal, and the REST of the field survives (a regex-based
#     control-char filter would strip the lot — jq's Oniguruma does not honour \u escapes in a class)
sa4esc=$(sarun "$(samk claude-sonnet-5 1000000 "$(printf 'A\033[1ZmB')" l 120)" | saraw tid)
case "$sa4esc" in *$'\033''[1Z'*) echo "  ★ FAIL raw ESC survived into content"; sa4bad=1 ;; esac
case "$(printf '%s' "$sa4esc" | nocol)" in *'A[1ZmB'*) ;; *) echo "  ★ FAIL field was gutted instead of stripped: [$(printf '%s' "$sa4esc" | nocol)]"; sa4bad=1 ;; esac
# (b) the 8-bit C1 CSI (U+009B) is the same injection class as a raw ESC and is stripped too
sa4c1=$(sarun '{"columns":120,"tasks":[{"id":"tid","model":"claude-sonnet-5","description":"A\u009b[1ZmB","label":"l"}]}' | saraw tid | nocol)
case "$sa4c1" in *'A[1ZmB'*) ;; *) echo "  ★ FAIL C1 CSI case: [$sa4c1]"; sa4bad=1 ;; esac
case "$sa4c1" in *$'\302\233'*) echo "  ★ FAIL U+009B survived into content"; sa4bad=1 ;; esac
# (c) structural surprises yield zero records and a clean exit — one bad task must not abort every task's line
for sa4in in '{"tasks":"not-an-array","columns":120}' '["not","an","object"]' '{"tasks":["not-an-object"],"columns":120}' '' 'not json at all'; do
  sa4o=$(sarun "$sa4in"); sa4rc=$?
  [ "$sa4rc" -eq 0 ] || { echo "  ★ FAIL exit $sa4rc on structurally invalid input [$sa4in]"; sa4bad=1; }
  [ -z "$sa4o" ]     || { echo "  ★ FAIL output on structurally invalid input [$sa4in]: [$sa4o]"; sa4bad=1; }
done
# (d) an 8KB description is capped, so vis_width's quadratic ASCII strip cannot stall the frame
SABIG=$(printf 'x%.0s' $(seq 1 8000))
SECONDS=0
sa4big=$(sarun "$(samk claude-sonnet-5 1000000 "$SABIG" l '')" | saraw tid | vw)
# The lower bound matters as much as the upper one: without it an empty output (script gone, script broken)
# would sail through this check as "nicely bounded". 256 capped description + " | " + model + " | " + "l" = 275.
if [ "$SECONDS" -lt 3 ] && [ "$sa4big" -le 300 ] && [ "$sa4big" -ge 260 ]; then echo "  8KB description → width $sa4big in ${SECONDS}s OK"
else echo "  ★ FAIL 8KB description: width $sa4big in ${SECONDS}s (want 260..300 — the 256-codepoint cap plus the other segments)"; sa4bad=1; fi
# (e) too narrow → the activity label is sacrificed FIRST; description and model segment stay whole
sa4n=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that cannot possibly fit' 40)" | saraw tid | nocol)
sa4w=$(printf '%s' "$sa4n" | vw)
[ "$sa4w" -le 40 ]      || { echo "  ★ FAIL narrow width $sa4w > 40: [$sa4n]"; sa4bad=1; }
case "$sa4n" in *'Sonnet 5(1M)'*) ;; *) echo "  ★ FAIL model segment truncated at width 40: [$sa4n]"; sa4bad=1 ;; esac
case "$sa4n" in *DESCRIPTION*)     ;; *) echo "  ★ FAIL description sacrificed before the label: [$sa4n]"; sa4bad=1 ;; esac
case "$sa4n" in *…*)               ;; *) echo "  ★ FAIL label dropped instead of truncated: [$sa4n]"; sa4bad=1 ;; esac
# (f) narrower still → label goes entirely, description is truncated, model segment SURVIVES INTACT
sa4t=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that cannot possibly fit' 20)" | saraw tid | nocol)
sa4tw=$(printf '%s' "$sa4t" | vw)
[ "$sa4tw" -le 20 ]     || { echo "  ★ FAIL narrowest width $sa4tw > 20: [$sa4t]"; sa4bad=1; }
case "$sa4t" in *'Sonnet 5(1M)'*) ;; *) echo "  ★ FAIL model segment lost at width 20: [$sa4t]"; sa4bad=1 ;; esac
# (g) no usable column count → no bounding at all, all three segments intact
sa4u=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that cannot possibly fit' '')" | saraw tid | nocol)
[ "$sa4u" = "DESCRIPTION │ Sonnet 5(1M) │ a very long activity label that cannot possibly fit" ] \
  || { echo "  ★ FAIL unbounded render: [$sa4u]"; sa4bad=1; }
[ "$sa4bad" -eq 0 ] && echo "  ESC/C1 stripped, structural surprises inert, 256-cap, label-then-description sacrifice OK" || fail=1

echo "── G. perf: 10 frames"
time (for _ in 1 2 3 4 5 6 7 8 9 10; do run 140 "$J" >/dev/null; done)

if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME FAILED"; exit 1; fi
