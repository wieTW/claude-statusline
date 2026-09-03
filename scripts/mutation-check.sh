#!/usr/bin/env bash
# mutation-check.sh — ask whether a test is actually testing anything.
#
# Apply one literal mutation to a source file, run the test suite, say whether the suite noticed, and
# ALWAYS put the file back from a pristine copy taken before the edit (verified by hash, even when the
# suite crashes or you interrupt it).
#
# A mutation the suite does NOT turn red is a hole in the tests, never a property of the code. Two shapes
# of hole show up over and over, and neither is visible by reading the tests:
#
#   1. A fixture missing several fields at once. It gets rejected by whichever guard happens to run first,
#      so every LATER guard is never executed — yet the fixture reads as if it covers all of them. Delete
#      one of those guards and the suite stays green.
#   2. An assertion that only checks a negative ("this id must NOT appear"). It cannot tell "the guard
#      correctly rejected the row" from "the whole script emitted nothing". Blank the output entirely and
#      the suite stays green.
#
# Shape 2 is what the three blanket mutations below are for; run them first, because any assertion they
# fail to catch is a negative-only assertion that needs a positive control row added next to it.
#
# Usage:
#   scripts/mutation-check.sh <file> <old-literal> <new-literal>
#   scripts/mutation-check.sh <file> @old.txt @new.txt     # a literal beginning with @ is read from that
#                                                          # file — use it for anchors containing quotes
# Exit: 0 = suite went red (the rule is guarded) · 1 = suite stayed green (GAP: add a fixture) · 2 = error
#
# Worked example — prove the model guard in subagent-status-line.sh is actually tested:
#   scripts/mutation-check.sh subagent-status-line.sh \
#     '[ -n "$sa_id" ] && [ -n "$sa_model" ] || continue' '[ -n "$sa_id" ] || continue'
#
# The three blanket mutations worth running against any new section (each must turn the suite red):
#   emit nothing        : the loop body's first guard line   -> 'continue'
#   blank every content : the line appending content         -> append '""'
#   blank every id      : the line appending the id          -> append '""'
export LC_ALL=C

SL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SUITE=${MUTATION_SUITE:-tests/run-tests.sh}   # override to point at a different suite

if [ "$#" -ne 3 ]; then
    printf 'usage: %s <file> <old-literal|@file> <new-literal|@file>\n' "$0" >&2
    exit 2
fi

target=$1; old=$2; new=$3
case "$target" in /*) ;; *) target="$SL/$target" ;; esac
[ -f "$target" ] || { printf 'mutation-check: no such file: %s\n' "$target" >&2; exit 2; }
case "$old" in @*) old=$(cat "${old#@}") || exit 2 ;; esac
case "$new" in @*) new=$(cat "${new#@}") || exit 2 ;; esac

# The pristine copy is the whole safety story: it is taken BEFORE the edit and restored unconditionally,
# so an interrupted or crashing run cannot leave a mutated source behind.
pristine=$(mktemp "${TMPDIR:-/tmp}/mutation-check.XXXXXX") || exit 2
cp "$target" "$pristine" || exit 2
restore() {
    cp "$pristine" "$target"
    if cmp -s "$pristine" "$target"; then :; else
        printf 'mutation-check: RESTORE FAILED — %s differs from %s\n' "$target" "$pristine" >&2
        exit 3
    fi
    rm -f "$pristine"
}
trap 'restore; exit 3' INT TERM

# Exactly one occurrence, or we are not mutating what the caller thinks we are.
python3 - "$target" "$old" "$new" <<'PY'
import io, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(path, encoding='utf-8').read()
n = s.count(old)
if n != 1:
    sys.stderr.write("mutation-check: anchor matched %d times, need exactly 1\n" % n)
    sys.exit(2)
io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PY
rc=$?
if [ "$rc" -ne 0 ]; then restore; exit 2; fi

out=$(cd "$SL" && bash "$SUITE" 2>&1); suite_rc=$?
printf '%s\n' "$out" | grep '★ FAIL'
restore
trap - INT TERM

if [ "$suite_rc" -ne 0 ]; then
    printf 'GUARDED — the suite went red (rc=%s). Source restored.\n' "$suite_rc"
    exit 0
fi
printf 'GAP — the suite stayed GREEN with this mutation applied. Nothing tests this rule.\n'
printf '      Add a fixture that isolates it, and give the fixture a positive control row\n'
printf '      (a complete row that MUST be emitted) so it cannot pass on a blank output.\n'
printf '      Source restored.\n'
exit 1
