#!/usr/bin/env bash
# Open the working directory of the Claude Code pane that was clicked, in Finder.
#
# Why this script exists at all: the statusline cannot make its own path segment clickable. Claude Code re-renders the
# statusline through its own style model, which drops OSC 8 hyperlinks — measured on a real session, zero OSC 8 bytes
# reach the terminal, and FORCE_HYPERLINK does not change it. So the terminal has to do the opening, and the only handle
# the terminal has on a pane is its tty. Claude Code's own children get NO controlling terminal, so the statusline
# cannot record the tty itself; what it CAN see is `$PPID`, which is the claude process, and that process does own the
# tty. Hence the two halves: the statusline publishes `claude pid -> cwd`, this script resolves `tty -> claude pid`.
#
# Wiring (iTerm2): Settings > Profiles > Advanced > Smart Selection > Edit, add a rule whose action runs
#   <this script> \(session.tty)
# A cmd-click on text matching the rule invokes that action. The tty argument is optional: with no argument the script
# asks iTerm2 for the frontmost session's tty, which is the pane that was just clicked.
#
# Exit codes: 0 opened, 1 could not resolve a directory (a desktop notification says why, since a Smart Selection
# action's stdout/stderr is not visible anywhere).
LC_ALL=C
MAP_DIR="$HOME/.claude/sl-cwd"

fail() {   # a Smart Selection action's stdout/stderr goes nowhere, so a desktop notification is the only user-visible
           # channel. SL_OPEN_NOTIFY=0 suppresses it (the test suite exercises these paths and must stay silent).
    printf 'open-pane-dir: %s\n' "$1" >&2
    [ "${SL_OPEN_NOTIFY:-1}" = "0" ] || \
        /usr/bin/osascript -e "display notification \"$1\" with title \"claude-statusline\"" >/dev/null 2>&1
    exit 1
}

tty_arg=$1
if [ -z "$tty_arg" ]; then
    # No tty passed (legacy \0-style parameters carry no session variables) — ask iTerm2 which pane is frontmost.
    # The click focuses the pane first, so the frontmost session IS the clicked one.
    tty_arg=$(/usr/bin/osascript -e 'tell application "iTerm2" to tell current session of current window to get tty' 2>/dev/null)
fi
[ -n "$tty_arg" ] || fail "could not determine which pane was clicked"

tty_short=${tty_arg#/dev/}
case $tty_short in ''|*[!a-zA-Z0-9]*) fail "unexpected tty: $tty_arg" ;; esac   # only ever ttysNNN / consNN

# Every claude process on that tty. Nested sessions put more than one there, so prefer the most recently published
# record: that is the pane's live session (an outer, idle claude has a staler file).
best="" best_mt=0
for pid in $(/bin/ps -t "$tty_short" -o pid=,comm= 2>/dev/null | /usr/bin/awk '$2 ~ /claude/ {print $1}'); do
    f="$MAP_DIR/$pid"
    [ -f "$f" ] || continue
    mt=$(/usr/bin/stat -f %m "$f" 2>/dev/null) || continue
    [ "$mt" -gt "$best_mt" ] 2>/dev/null && { best_mt=$mt; best=$f; }
done
[ -n "$best" ] || fail "no directory published for tty $tty_short (is PATH_CLICK on, and has the statusline rendered once?)"

IFS= read -r dir < "$best" || fail "could not read the published directory"
[ -n "$dir" ] && [ -d "$dir" ] || fail "published directory is gone: $dir"

/usr/bin/open "$dir" || fail "open failed for $dir"
