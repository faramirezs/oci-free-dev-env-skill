#!/usr/bin/env bash
# Firewall: ufw active and default-deny, no world-open SSH, fail2ban jailing sshd.
set -u

if ! sudo -n true 2>/dev/null; then
    echo "passwordless sudo is required to read the firewall state"
    exit 2
fi

status="$(sudo -n ufw status verbose 2>/dev/null || true)"
if ! printf '%s' "$status" | head -1 | grep -q "Status: active"; then
    echo "ufw is not active"
    exit 1
fi
echo "ufw active"

if printf '%s' "$status" | grep -q "Default: deny (incoming)"; then
    echo "default deny incoming"
else
    echo "default incoming policy is not deny"
    exit 1
fi

# A bootstrap rule scoped to one address is expected until
# `scripts/configure.sh --tailscale-only` removes it. A rule open to the whole
# internet is not.
world_open="$(sudo -n ufw status 2>/dev/null | awk '$1 ~ /^22\/tcp/ && /ALLOW/ && $NF == "Anywhere" {c++} END {print c+0}')"
if [ "$world_open" -gt 0 ]; then
    echo "tcp/22 is open to the world:"
    sudo -n ufw status | grep "22/tcp" || true
    exit 1
fi
bootstrap="$(sudo -n ufw status 2>/dev/null | awk '$1 ~ /^22\/tcp/ && /ALLOW/ {print $3}' | paste -sd, -)"
if [ -n "$bootstrap" ]; then
    echo "bootstrap SSH rule present for: $bootstrap"
    echo "(run scripts/configure.sh --tailscale-only once the tailnet works)"
else
    echo "no WAN SSH rule — Tailscale-only"
fi

if systemctl is-active --quiet fail2ban; then
    echo "fail2ban active"
else
    echo "fail2ban is not active"
    exit 1
fi

if sudo -n fail2ban-client status sshd >/dev/null 2>&1; then
    echo "sshd jail active"
else
    echo "sshd jail is not active"
    exit 1
fi

if grep -q "100.64.0.0/10" /etc/fail2ban/jail.d/devhost.local 2>/dev/null; then
    echo "tailnet range exempt from banning"
else
    echo "tailnet range 100.64.0.0/10 is not in fail2ban ignoreip"
    exit 1
fi

echo "firewall OK"
