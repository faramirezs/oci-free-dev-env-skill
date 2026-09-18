#!/usr/bin/env bash
# tmux: config, auto-attach, lingering, and a session that really survives.
set -u

user="$(id -un)"
home_dir="$(getent passwd "$user" | cut -d: -f6)"
session="${DEVHOST_DEFAULT_SESSION:-main}"

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is not installed"
    exit 1
fi

if [ ! -f "$home_dir/.tmux.conf" ]; then
    echo "$home_dir/.tmux.conf is missing"
    exit 1
fi
echo "tmux config present"

if ! grep -q "ANSIBLE MANAGED tmux auto-attach" "$home_dir/.bashrc"; then
    echo "auto-attach block missing from $home_dir/.bashrc"
    exit 1
fi
echo "auto-attach configured"

if loginctl show-user "$user" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
    echo "lingering enabled"
else
    echo "lingering is not enabled for $user (session survives logout only with it)"
    exit 1
fi

# Functional: a detached session must run a command and show its output.
probe="devhost-verify-$$"
tmux kill-session -t "$probe" 2>/dev/null || true
tmux new -d -s "$probe"
sleep 0.5
tmux send-keys -t "$probe" 'echo tmux-persistence-ok' Enter
sleep 1
if tmux capture-pane -t "$probe" -p | grep -q "tmux-persistence-ok"; then
    echo "session persistence works"
else
    echo "session did not execute the probe command"
    tmux kill-session -t "$probe" 2>/dev/null || true
    exit 1
fi
tmux kill-session -t "$probe" 2>/dev/null || true

if tmux has-session -t "$session" 2>/dev/null; then
    echo "default session '$session' exists"
else
    echo "note: default session '$session' does not exist yet (created on first login)"
fi

echo "tmux OK"
