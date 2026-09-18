#!/usr/bin/env bash
# devhost destroy — tear down everything scripts/provision.sh created.
#
# Usage:
#   scripts/destroy.sh                 # terminate the instance, keep the network
#   scripts/destroy.sh --all           # also delete subnet, NSG, security list,
#                                      # internet gateway and VCN
#   scripts/destroy.sh --yes           # no confirmation prompt
#
# By default the boot volume is DELETED with the instance: a preserved boot
# volume keeps consuming the 200 GB Always Free block-storage allowance and is
# easy to forget. Pass --keep-boot-volume to preserve it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/state/devhost.env"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
[ -f "$STATE" ] || { echo "state/devhost.env not found — nothing recorded to destroy" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"

OCI_CLI_ARGS="${OCI_CLI_ARGS:-}"
DELETE_NETWORK=0
ASSUME_YES=0
KEEP_BOOT_VOLUME=0

while [ $# -gt 0 ]; do
    case "$1" in
        --all) DELETE_NETWORK=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --keep-boot-volume) KEEP_BOOT_VOLUME=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

green="\033[0;32m"; red="\033[0;31m"; yellow="\033[0;33m"; blue="\033[0;34m"; reset="\033[0m"
ok()   { printf "${green}ok${reset}   %s\n" "$1"; }
warn() { printf "${yellow}warn${reset} %s\n" "$1"; }
die()  { printf "${red}fail${reset} %s\n" "$1"; exit 1; }
step() { printf "\n${blue}==>${reset} %s\n" "$1"; }

OCI_BIN="${OCI_BIN:-$(command -v oci || true)}"
[ -n "$OCI_BIN" ] || die "the OCI CLI is not on PATH"
# shellcheck disable=SC2086
oapi() { "$OCI_BIN" ${OCI_CLI_ARGS} "$@"; }

echo "devhost destroy — $DEVHOST_NAME"
echo "  instance    : $INSTANCE_ID"
[ "$KEEP_BOOT_VOLUME" = "1" ] && echo "  boot volume : keep (keeps consuming the free block-storage allowance)"
[ "$DELETE_NETWORK" = "1" ] && echo "  network     : delete VCN, subnet, NSG, security list, internet gateway"

if [ "$ASSUME_YES" != "1" ]; then
    printf 'Type the instance name (%s) to confirm: ' "$DEVHOST_NAME"
    read -r reply
    [ "$reply" = "$DEVHOST_NAME" ] || die "confirmation did not match — nothing was deleted"
fi

step "Terminating the instance"
if [ -n "${INSTANCE_ID:-}" ]; then
    state="$(oapi compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo GONE)"
    if [ "$state" = "GONE" ]; then
        ok "instance already gone"
    elif [ "$state" = "TERMINATED" ]; then
        ok "instance already terminated"
    else
        preserve="true"
        [ "$KEEP_BOOT_VOLUME" = "1" ] || preserve="false"
        oapi compute instance terminate --instance-id "$INSTANCE_ID" \
            --preserve-boot-volume "$preserve" --force --wait-for-state SUCCEEDED >/dev/null
        ok "instance terminated (boot volume preserved: $preserve)"
    fi
else
    warn "no instance id in state — skipping"
fi

if [ "$DELETE_NETWORK" = "1" ]; then
    step "Deleting the network"
    [ -n "${SUBNET_ID:-}" ] && { oapi network subnet delete --subnet-id "$SUBNET_ID" --force >/dev/null && ok "subnet deleted"; }
    [ -n "${NSG_ID:-}" ] && { oapi network nsg delete --nsg-id "$NSG_ID" --force >/dev/null && ok "network security group deleted"; }
    [ -n "${SECURITY_LIST_ID:-}" ] && { oapi network security-list delete --security-list-id "$SECURITY_LIST_ID" --force >/dev/null && ok "security list deleted"; }
    [ -n "${IGW_ID:-}" ] && { oapi network internet-gateway delete --ig-id "$IGW_ID" --force >/dev/null && ok "internet gateway deleted"; }
    # The VCN owns its default route table and default security list, so they go
    # with it.
    if [ -n "${VCN_ID:-}" ]; then
        oapi network vcn delete --vcn-id "$VCN_ID" --force >/dev/null && ok "VCN deleted"
    fi
else
    warn "network left in place (VCN, subnet, NSG): run scripts/destroy.sh --all to remove it"
fi

step "Removing local state"
rm -f "$STATE"
ok "state/devhost.env removed"

step "Verify in the Console"
echo "  Instances:   https://cloud.oracle.com/compute/instances?region=$REGION"
echo "  Block volumes: https://cloud.oracle.com/block-storage/volumes?region=$REGION"
echo "  A preserved boot volume, a floating public IP or an idle A1 instance keeps"
echo "  consuming the Always Free allowance."
