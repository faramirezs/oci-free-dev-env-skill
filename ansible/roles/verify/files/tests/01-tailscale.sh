#!/usr/bin/env bash
# Tailscale: daemon up, node authenticated, own MagicDNS name resolving.
set -u

if ! command -v tailscale >/dev/null 2>&1; then
    echo "tailscale is not installed"
    exit 1
fi

status_json="$(tailscale status --json 2>/dev/null || true)"
if [ -z "$status_json" ]; then
    echo "tailscale status returned nothing — daemon not running?"
    exit 1
fi

state="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || echo unknown)"
if [ "$state" != "Running" ]; then
    echo "BackendState=$state — the node is not authenticated yet"
    echo "Join with: sudo tailscale up --hostname=$(hostname) --ssh --accept-dns=true"
    echo "then open the https://login.tailscale.com/... URL that is printed."
    exit 2
fi

ts_ip="$(printf '%s' "$status_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("Self") or {}).get("TailscaleIPs") or [""])[0])' 2>/dev/null || echo "")"
if [ -z "$ts_ip" ]; then
    echo "no tailnet address assigned"
    exit 1
fi
echo "tailnet address: $ts_ip"

dns_name="$(printf '%s' "$status_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("Self") or {}).get("DNSName","")).rstrip("."))' 2>/dev/null || echo "")"
short="${dns_name%%.*}"
if [ -n "$dns_name" ] && { getent hosts "$dns_name" >/dev/null 2>&1 || getent hosts "$short" >/dev/null 2>&1; }; then
    echo "MagicDNS resolves $dns_name"
else
    echo "MagicDNS does not resolve '$dns_name' (needs accept-dns=true on the host)"
    exit 1
fi

echo "tailscale OK"
