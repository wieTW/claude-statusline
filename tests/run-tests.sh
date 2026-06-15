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

echo "── D. COLUMNS=50 (left part wider than drawable) → head-truncate left, no overflow (width=$((50-EDGE_PAD)))"
out_d=$(run 50 "$J")
chk check exact $((50-EDGE_PAD)) <<<"$out_d"
case "$out_d" in *"…"*) echo "  left has … truncation marker OK" ;; *) echo "  ★ FAIL expected … marker"; fail=1 ;; esac

echo "── E. non-git + no session → right part empty, print left only, single line"
out_e=$(run 140 "$JNOGIT")
chk check max $((140-1)) <<<"$out_e"
case "$out_e" in *main*) echo "  ★ FAIL should have no git segment"; fail=1 ;; *) echo "  no git segment OK" ;; esac

echo "── K. junction │ only when 'merged': roomy(gap>=JGAP) no │, squeezed/truncated has │, │-join fallback has │"
kbad=0
mid() { sed 's/\x1b\[[0-9;]*m//g' | grep -oE '19:38.*main' | sed -E 's/^19:38(.*)main$/\1/'; }  # extract between time and main
ka=$(run $((W+30)) "$J" | mid)
case "$ka" in *"│"*) echo "  ★ FAIL roomy should not have junction │: mid=[$ka]"; kbad=1 ;; *) echo "  roomy no │ OK" ;; esac
kt=$(run 125 "$J" | mid)
case "$kt" in *"│"*) echo "  squeezed/truncated has │ OK" ;; *) echo "  ★ FAIL truncated path missing junction │: mid=[$kt]"; kbad=1 ;; esac
kc=$(run 0 "$J" | mid)
case "$kc" in *"│"*) echo "  │-join fallback has │ OK" ;; *) echo "  ★ FAIL │-join fallback missing │"; kbad=1 ;; esac
[ "$kbad" -eq 0 ] || fail=1

echo "── F. RIGHT_ALIGN=false → output byte-for-byte identical to the 'no width' fallback"
mkdir -p "$WORK/noalign/lib" && cp "$SL"/lib/*.sh "$WORK/noalign/lib/"
sed 's/^RIGHT_ALIGN=true/RIGHT_ALIGN=false/' "$SL/statusline-command.sh" > "$WORK/noalign/statusline-command.sh"
out_f=$(printf '%s' "$J" | env COLUMNS=140 HOME="$FAKE_HOME" bash "$WORK/noalign/statusline-command.sh")
out_c=$(run 0 "$J")
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
JLONG=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:3},
    rate_limits:{ five_hour:{used_percentage:40, resets_at:(now+500|floor)},
                  seven_day:{used_percentage:86, resets_at:(now+108000|floor)} },
    effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"Consolidate statusline from two rows to one" }')
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

echo "── U. LAST-MSG: 'HH:MM (Δ)' cache-age delta — <1m hides Δ, 5m/1h colour tiers, old format shown verbatim"
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
  context_window:{used_percentage:"S_used"}, worktree:{name:"S_wt"},
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
   case "$now" in ''|*[!0-9]*) echo "  ★ FAIL now not numeric: [$now]"; rc=1 ;; esac
   exit $rc ); then echo "  all 15 fields land in their own global OK"; else fail=1; fi

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

echo "── G. perf: 10 frames"
time (for _ in 1 2 3 4 5 6 7 8 9 10; do run 140 "$J" >/dev/null; done)

if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME FAILED"; exit 1; fi
