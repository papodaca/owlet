#!/bin/sh
# owlet-signal — send a signal to the running Owlet instance.
#
# Usage:
#   owlet-signal toggle     # SIGUSR1 — toggle dictation (record + stream
#                                   # into the focused window; stop +
#                                   # type the final text)
#   owlet-signal stop       # SIGUSR2 — stop recording (finalizes + types
#                                   # the final text if dictating)
#   owlet-signal insert     # SIGRTMIN+1 — copy + type the transcript into
#                                   # the focused window (refused while
#                                   # dictation is active)
#
# Bind in GNOME: Settings → Keyboard → View and Customize Shortcuts →
# Custom Shortcuts →
#   Name:    Owlet Toggle Recording
#   Command: owlet-signal toggle
#   Shortcut: (press your combo)
#
# This is the fallback path for environments without the
# org.freedesktop.portal.GlobalShortcuts portal (see Preferences →
# Shortcuts → "Install helper script"). The running Owlet writes its PID
# to $XDG_RUNTIME_DIR/owlet.pid (or /tmp/owlet.pid) at startup.
set -eu

PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/owlet.pid"

notify() {
    # notify-send is optional; degrade silently when absent.
    command -v notify-send >/dev/null 2>&1 \
        && notify-send -a owlet -i im.apodaca.owlet "$1" "$2" || true
}

if [ "$#" -lt 1 ]; then
    echo "usage: owlet-signal <toggle|stop|insert>" >&2
    exit 2
fi

if [ ! -r "$PIDFILE" ]; then
    echo "owlet not running (no $PIDFILE)" >&2
    notify "Owlet is not running" "Start Owlet first."
    exit 1
fi

PID="$(cat "$PIDFILE")"
# Reject non-numeric, empty, zero, or negative "pids" before touching
# kill — `kill -USR1 -1` would signal every process the caller owns
# (default action: terminate), and `kill -USR1 0` the caller's process
# group. A world-writable fallback /tmp/owlet.pid makes this plantable.
case "$PID" in
    ''|*[!0-9]*)
        echo "owlet-signal: invalid pid in $PIDFILE" >&2
        notify "Owlet pidfile is corrupt" "Start Owlet again."
        exit 1
        ;;
esac
[ "$PID" -gt 0 ] 2>/dev/null || {
    echo "owlet-signal: invalid pid in $PIDFILE" >&2
    notify "Owlet pidfile is corrupt" "Start Owlet again."
    exit 1
}

if ! kill -0 "$PID" 2>/dev/null; then
    echo "owlet not running (stale pid $PID in $PIDFILE)" >&2
    notify "Owlet is not running" "Start Owlet first."
    exit 1
fi

# Stale pidfile + PID reuse: kill -0 only proves *some* process owns the
# PID. SIGUSR1/USR2/RTMIN+1 default to termination, so signalling a
# reused PID would kill an unrelated process. Confirm the target is
# actually Owlet. /proc is Linux-only (Owlet targets GNOME/Linux); if it
# is unavailable we fall through to the kill -0 check above.
if [ -r "/proc/$PID/comm" ]; then
    comm="$(cat "/proc/$PID/comm")"
    if [ "$comm" != "owlet" ]; then
        echo "owlet-signal: pid $PID is not owlet (stale $PIDFILE, comm=$comm)" >&2
        notify "Owlet is not running" "pid $PID is not owlet (stale pidfile)"
        exit 1
    fi
fi

case "$1" in
    toggle) kill -USR1 "$PID" ;;
    stop)   kill -USR2 "$PID" ;;
    insert) kill -RTMIN+1 "$PID" ;;
    *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac
