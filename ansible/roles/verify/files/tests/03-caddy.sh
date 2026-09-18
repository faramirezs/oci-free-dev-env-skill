#!/usr/bin/env bash
# Caddy: service active, tailnet health endpoint answers with security headers.
set -u

if ! command -v caddy >/dev/null 2>&1; then
    echo "caddy is not installed"
    exit 1
fi

if ! systemctl is-active --quiet caddy; then
    echo "caddy service is not active"
    systemctl status caddy --no-pager -n 20 2>&1 || true
    exit 1
fi
echo "caddy service active"

host="$(tailscale ip -4 2>/dev/null | head -1 || true)"
if [ -z "$host" ]; then
    echo "no tailnet address — tailnet ingress cannot be checked yet"
    exit 2
fi

code="$(curl -fsS -o /dev/null -w '%{http_code}' "http://$host/" --max-time 5 || echo 000)"
if [ "$code" != "200" ]; then
    echo "health check http://$host/ returned $code"
    exit 1
fi
echo "health check: 200"

headers="$(curl -fsSI "http://$host/" --max-time 5 || true)"
for header in Strict-Transport-Security X-Content-Type-Options X-Frame-Options Referrer-Policy; do
    if printf '%s' "$headers" | grep -qi "$header"; then
        echo "header present: $header"
    else
        echo "header missing: $header"
        exit 1
    fi
done

port="${CADDY_PREVIEW_PORT:-9000}"
code="$(curl -fsS -o /dev/null -w '%{http_code}' "http://$host:$port/" --max-time 5 || echo 000)"
if [ "$code" = "502" ] || [ "$code" = "200" ]; then
    echo "preview port $port is proxied by caddy (upstream answered $code)"
else
    echo "preview port $port returned $code (expected 502 with no upstream, 200 with one)"
    exit 1
fi

echo "caddy OK"
