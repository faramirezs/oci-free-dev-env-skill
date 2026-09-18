#!/usr/bin/env bash
# devhost verify — syntax-check the playbook, apply it, then run the on-host
# verification suite over SSH.
#
# Usage:
#   scripts/verify.sh                 # syntax check + playbook + remote suite
#   scripts/verify.sh --remote-only   # skip the playbook, just run the suite
#   scripts/verify.sh --syntax-only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/state/devhost.env"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
[ -f "$STATE" ] || { echo "state/devhost.env not found — run scripts/provision.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"

SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SSH_USER="${SSH_USER:-ubuntu}"
REMOTE_ONLY=0
SYNTAX_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --remote-only) REMOTE_ONLY=1; shift ;;
        --syntax-only) SYNTAX_ONLY=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

green="\033[0;32m"; red="\033[0;31m"; blue="\033[0;34m"; reset="\033[0m"
ok()   { printf "${green}ok${reset} %s\n" "$1"; }
die()  { printf "${red}fail${reset} %s\n" "$1"; exit 1; }
step() { printf "\n${blue}==>${reset} %s\n" "$1"; }

# Prefer the tailnet name: it keeps working after the host goes Tailscale-only.
tailnet_name="$(tailscale status --json 2>/dev/null | DEVHOST_NAME="$DEVHOST_NAME" python3 -c '
import json, os, sys
want = os.environ["DEVHOST_NAME"].lower()
try:
    peers = json.load(sys.stdin).get("Peer") or {}
except Exception:
    sys.exit(0)
for peer in peers.values():
    if (peer.get("HostName") or "").lower() == want and (peer.get("Online") or False):
        print((peer.get("DNSName") or "").rstrip("."))
        break
' 2>/dev/null || true)"
host="${tailnet_name:-$PUBLIC_IP}"
[ -n "$host" ] || die "no tailnet node and no recorded public IP"

ssh_cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
         -i "$SSH_KEY_PATH" "$SSH_USER@$host")

if [ "$REMOTE_ONLY" = "0" ]; then
    step "Ansible syntax check"
    (cd "$ROOT/ansible" && ansible-playbook site.yml --syntax-check)
    ok "playbook parses"
fi

if [ "$SYNTAX_ONLY" = "1" ]; then
    exit 0
fi

if [ "$REMOTE_ONLY" = "0" ]; then
    step "Applying the playbook to $host (idempotent)"
    (cd "$ROOT/ansible" && ansible-playbook -i inventory.ini site.yml)
    ok "playbook applied"
fi

step "On-host verification suite (as seen from $host)"
"${ssh_cmd[@]}" 'bash ~/.devhost-verify/verify.sh'
ok "verification finished"
