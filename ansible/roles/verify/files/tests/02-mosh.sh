#!/usr/bin/env bash
# Mosh: binaries present, session timeout configured, a server really starts.
set -u

for bin in mosh mosh-server; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "$bin is not installed"
        exit 1
    fi
done
echo "mosh and mosh-server present"

if ! grep -q "^MOSH_SERVER_NETWORK_TMOUT=" /etc/environment 2>/dev/null; then
    echo "MOSH_SERVER_NETWORK_TMOUT is not set in /etc/environment"
    exit 1
fi
echo "session timeout configured"

# Functional check: start a server on a fixed port and confirm it listens.
port=60077
out="$(timeout 15 mosh-server new -c 256 -p "$port" -l LANG=C 2>&1 || true)"
if ! printf '%s' "$out" | grep -q "MOSH CONNECT $port"; then
    echo "mosh-server did not start on port $port:"
    printf '%s\n' "$out"
    exit 1
fi
echo "mosh-server started on $port"

if ss -lun 2>/dev/null | grep -q ":$port "; then
    echo "mosh-server is listening (bound to 0.0.0.0 without an SSH_CONNECTION;"
    echo "a real mosh session binds the address the SSH connection arrived on)"
else
    echo "mosh-server reported a connection but nothing is listening on $port"
    pkill -f "mosh-server new -c 256 -p $port" 2>/dev/null || true
    exit 1
fi

pkill -f "mosh-server new -c 256 -p $port" 2>/dev/null || true
echo "mosh OK"
