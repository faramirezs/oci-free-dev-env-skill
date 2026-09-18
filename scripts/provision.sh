#!/usr/bin/env bash
# devhost provision — create the Oracle Cloud infrastructure and instance for a
# free remote development host.
#
# Creates, or reuses by display name (idempotent):
#   VCN + internet gateway + default route table route + dedicated security list
#   + network security group + public subnet
#   VM.Standard.A1.Flex instance (Always Free) with the SSH key injected at launch
#
# Writes state/devhost.env, which scripts/configure.sh, verify.sh and destroy.sh
# read. Re-running is a no-op that refreshes that file.
#
# Requires: scripts/preflight.sh has succeeded (OCI CLI installed + authenticated).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/state/devhost.env"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

DEVHOST_NAME="${DEVHOST_NAME:-devhost-1}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-100}"
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"
VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.0.0/24}"
BOOTSTRAP_SSH_CIDR="${BOOTSTRAP_SSH_CIDR:-}"
EXPOSE_PUBLIC_HTTP="${EXPOSE_PUBLIC_HTTP:-false}"
EXPOSE_PUBLIC_HTTPS="${EXPOSE_PUBLIC_HTTPS:-false}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-24}"
ATTEMPT_SLEEP="${ATTEMPT_SLEEP:-60}"
OCI_CLI_ARGS="${OCI_CLI_ARGS:-}"
OCI_REGION="${OCI_REGION:-}"
OCID_COMPARTMENT="${OCID_COMPARTMENT:-}"
OCI_AVAILABILITY_DOMAIN="${OCI_AVAILABILITY_DOMAIN:-}"
TAG_VALUE="oci-free-dev-env"

green="\033[0;32m"; red="\033[0;31m"; yellow="\033[0;33m"; blue="\033[0;34m"; reset="\033[0m"
ok()   { printf "${green}ok${reset}   %s\n" "$1"; }
warn() { printf "${yellow}warn${reset} %s\n" "$1"; }
die()  { printf "${red}fail${reset} %s\n" "$1"; exit 1; }
step() { printf "\n${blue}==>${reset} %s\n" "$1"; }

# --- OCI plumbing ---------------------------------------------------------
OCI_BIN="${OCI_BIN:-$(command -v oci || true)}"
[ -n "$OCI_BIN" ] || die "the OCI CLI is not on PATH — run scripts/preflight.sh"
[ -x "$SSH_KEY_PATH.pub" ] || [ -f "$SSH_KEY_PATH.pub" ] || die "$SSH_KEY_PATH.pub not found — run scripts/preflight.sh"

# shellcheck disable=SC2086
oapi() { "$OCI_BIN" ${OCI_CLI_ARGS} "$@"; }

pyget() {  # pyget <json> <python-expression over `d`>  -> prints, empty on failure
    local expr="$1" payload="${2:-}"
    printf '%s' "$payload" | EXPR="$expr" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
safe = {"len": len, "str": str, "int": int, "float": float, "next": next,
        "sorted": sorted, "any": any, "all": all, "min": min, "max": max}
try:
    v = eval(os.environ["EXPR"], {"__builtins__": {}}, dict(safe, d=d))
except Exception:
    sys.exit(0)
print("" if v is None else v)
'
}

jq_items() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

tag_json() {
    python3 -c 'import json,sys; print(json.dumps({"managed-by": sys.argv[1], "devhost": sys.argv[2]}))' "$TAG_VALUE" "$DEVHOST_NAME"
}

echo "devhost provision — $DEVHOST_NAME"

# --- 0. Preconditions ----------------------------------------------------
step "Checking authentication"
if ! region_data="$(oapi iam region-subscription list 2>&1)"; then
    printf '%s\n' "$region_data" | sed 's/^/     /'
    die "OCI is not authenticated — run scripts/preflight.sh (it prints the auth guide)"
fi
HOME_REGION="$(pyget 'next((r["region-name"] for r in d["data"] if r.get("is-home-region")), "")' "$region_data")"
TENANCY_ID="$(pyget 'next((r["tenancy-id"] for r in d["data"]), "")' "$region_data")"
[ -n "$TENANCY_ID" ] || die "could not read the tenancy OCID from the CLI"

REGION="${OCI_REGION:-$HOME_REGION}"
[ -n "$REGION" ] || die "could not determine the region; set OCI_REGION in .env"
COMPARTMENT="${OCID_COMPARTMENT:-$TENANCY_ID}"
if [ "$REGION" != "$HOME_REGION" ]; then
    warn "OCI_REGION=$REGION but the tenancy home region is $HOME_REGION"
    warn "Always Free resources (compute, block storage) exist only in the home region."
    warn "Continuing because OCI_REGION was set explicitly."
fi
ok "region $REGION (home: $HOME_REGION)"
ok "compartment $COMPARTMENT"

# --- Bootstrap SSH rule --------------------------------------------------
step "Bootstrap SSH rule"
if [ -z "$BOOTSTRAP_SSH_CIDR" ]; then
    detected="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 10 https://ifconfig.me/ip 2>/dev/null || true)"
    if printf '%s' "$detected" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        BOOTSTRAP_SSH_CIDR="${detected}/32"
        ok "detected this machine's public address: $BOOTSTRAP_SSH_CIDR"
    else
        die "could not detect this machine's public IP. Set BOOTSTRAP_SSH_CIDR in .env (e.g. 203.0.113.10/32)."
    fi
fi
case "$BOOTSTRAP_SSH_CIDR" in
    0.0.0.0/0|::/0) die "BOOTSTRAP_SSH_CIDR=$BOOTSTRAP_SSH_CIDR would open SSH to the internet. Use your own /32." ;;
esac
ok "tcp/22 from $BOOTSTRAP_SSH_CIDR only"

# --- Availability domains ------------------------------------------------
step "Availability domains"
if [ -n "$OCI_AVAILABILITY_DOMAIN" ]; then
    AD_LIST="$OCI_AVAILABILITY_DOMAIN"
    ok "using $AD_LIST (from OCI_AVAILABILITY_DOMAIN)"
else
    ad_data="$(oapi iam availability-domain list --compartment-id "$COMPARTMENT" 2>/dev/null || true)"
    AD_LIST="$(pyget '" ".join(a["name"] for a in d["data"])' "$ad_data")"
    [ -n "$AD_LIST" ] || die "no availability domains returned for $COMPARTMENT"
    ok "candidates: $AD_LIST"
fi
read -r -a ADS <<<"$AD_LIST"

# --- Capacity pre-check --------------------------------------------------
# Limit names are server-side metadata: if the tenancy does not know these ones,
# list what it does know instead of failing silently.
step "Always Free capacity"
if [ -n "${ADS[0]:-}" ]; then
    for limit_name in standard-a1-core-count standard-a1-memory-count; do
        avail="$(oapi limits resource-availability get --service-name compute --limit-name "$limit_name" \
                    --compartment-id "$COMPARTMENT" --availability-domain "${ADS[0]}" \
                    --query 'data.available' --raw-output 2>/dev/null || true)"
        if [ -n "$avail" ]; then
            ok "$limit_name available in ${ADS[0]}: $avail"
            if [ "$limit_name" = "standard-a1-core-count" ] && [ "$avail" = "0" ]; then
                warn "no A1 OCPUs free in ${ADS[0]} right now — the launch will retry across domains"
            fi
        else
            defs="$(oapi limits definition list --compartment-id "$COMPARTMENT" --service-name compute \
                        --query "data[?starts_with(name, 'standard-a1')].name" --raw-output 2>/dev/null || true)"
            warn "$limit_name is not a limit name in this tenancy"
            [ -n "$defs" ] && warn "A1 limits this tenancy does define: $(printf '%s' "$defs" | tr '\n' ' ')"
        fi
    done
fi

# --- Network -------------------------------------------------------------
vcn_name="$DEVHOST_NAME-vcn"; igw_name="$DEVHOST_NAME-igw"
sl_name="$DEVHOST_NAME-sl"; nsg_name="$DEVHOST_NAME-nsg"; subnet_name="$DEVHOST_NAME-subnet"

step "VCN"
vcn_data="$(oapi network vcn list --compartment-id "$COMPARTMENT" --display-name "$vcn_name" 2>/dev/null || echo '{}')"
VCN_ID="$(pyget 'next((v["id"] for v in d.get("data", [])), "")' "$vcn_data")"
if [ -n "$VCN_ID" ]; then
    ok "reusing $vcn_name ($VCN_ID)"
else
    VCN_ID="$(oapi network vcn create --compartment-id "$COMPARTMENT" --cidr-blocks "[\"$VCN_CIDR\"]" \
                --display-name "$vcn_name" --dns-label "${DEVHOST_NAME%-*}-vcn" --freeform-tags "$(tag_json)" \
                --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
    ok "created $vcn_name ($VCN_ID)"
fi
DEFAULT_RT_ID="$(oapi network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)"

step "Internet gateway"
igw_data="$(oapi network internet-gateway list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --display-name "$igw_name" 2>/dev/null || echo '{}')"
IGW_ID="$(pyget 'next((g["id"] for g in d.get("data", [])), "")' "$igw_data")"
if [ -n "$IGW_ID" ]; then
    ok "reusing $igw_name ($IGW_ID)"
else
    IGW_ID="$(oapi network internet-gateway create --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" \
                --is-enabled true --display-name "$igw_name" --freeform-tags "$(tag_json)" \
                --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
    ok "created $igw_name ($IGW_ID)"
fi

step "Default route table"
route_rules="$(IGW_ID="$IGW_ID" python3 -c '
import json, os
print(json.dumps([{"cidrBlock": "0.0.0.0/0", "networkEntityId": os.environ["IGW_ID"], "description": "internet via IGW"}]))')"
existing_routes="$(oapi network route-table get --rt-id "$DEFAULT_RT_ID" --query 'data."route-rules"' 2>/dev/null || echo '[]')"
routes_match="$(DESIRED="$route_rules" EXISTING="$existing_routes" python3 -c '
import json, os
def key(rule):
    return (rule.get("cidrBlock") or rule.get("destination"), rule.get("networkEntityId"))
try:
    desired = json.loads(os.environ["DESIRED"])
    existing = json.loads(os.environ["EXISTING"]) or []
except Exception:
    print("no")
else:
    print("yes" if {key(r) for r in desired} <= {key(r) for r in existing} else "no")')"
if [ "$routes_match" = "yes" ]; then
    ok "0.0.0.0/0 -> $igw_name (already present)"
else
    # --force skips the interactive confirmation for updating a route table.
    oapi network route-table update --rt-id "$DEFAULT_RT_ID" --route-rules "$route_rules" --force >/dev/null
    ok "0.0.0.0/0 -> $igw_name"
fi

# A dedicated security list, NOT the VCN default one: the default list allows
# inbound tcp/22 from 0.0.0.0/0, which is exactly what this host must not have.
step "Security list"
sl_data="$(oapi network security-list list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --display-name "$sl_name" 2>/dev/null || echo '{}')"
SL_ID="$(pyget 'next((s["id"] for s in d.get("data", [])), "")' "$sl_data")"
egress_rules="$(python3 -c '
import json
print(json.dumps([{"destination": "0.0.0.0/0", "protocol": "all", "isStateless": False,
                   "description": "all outbound (package installs, Tailscale, git)"}]))')"
if [ -n "$SL_ID" ]; then
    ok "reusing $sl_name ($SL_ID)"
else
    SL_ID="$(oapi network security-list create --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" \
                --display-name "$sl_name" --egress-security-rules "$egress_rules" \
                --ingress-security-rules '[]' --freeform-tags "$(tag_json)" \
                --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
    ok "created $sl_name (egress only, no ingress)"
fi

step "Network security group"
nsg_data="$(oapi network nsg list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --display-name "$nsg_name" 2>/dev/null || echo '{}')"
NSG_ID="$(pyget 'next((n["id"] for n in d.get("data", [])), "")' "$nsg_data")"
if [ -n "$NSG_ID" ]; then
    ok "reusing $nsg_name ($NSG_ID)"
else
    NSG_ID="$(oapi network nsg create --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" \
                --display-name "$nsg_name" --freeform-tags "$(tag_json)" --query 'data.id' --raw-output)"
    ok "created $nsg_name ($NSG_ID)"
fi

# Desired ingress, then only the missing rules are added: re-running must not
# pile up duplicates.
desired_rules="$(BOOTSTRAP_CIDR="$BOOTSTRAP_SSH_CIDR" HTTP="$EXPOSE_PUBLIC_HTTP" HTTPS="$EXPOSE_PUBLIC_HTTPS" python3 -c '
import json, os
rules = [
    {"direction": "INGRESS", "protocol": "6", "source": os.environ["BOOTSTRAP_CIDR"],
     "sourceType": "CIDR_BLOCK", "isStateless": False,
     "tcpOptions": {"destinationPortRange": {"min": 22, "max": 22}},
     "description": "bootstrap SSH (removed by configure.sh --tailscale-only)"},
    # Tailscale direct (non-DERP) peer connections. Without it tailscaled UDP is
    # dropped at the cloud edge and every session is relayed via DERP, which
    # shows up as frequent broken pipes.
    {"direction": "INGRESS", "protocol": "17", "source": "0.0.0.0/0",
     "sourceType": "CIDR_BLOCK", "isStateless": False,
     "udpOptions": {"destinationPortRange": {"min": 41641, "max": 41641}},
     "description": "Tailscale direct endpoint"},
]
if os.environ["HTTP"].lower() == "true":
    rules.append({"direction": "INGRESS", "protocol": "6", "source": "0.0.0.0/0",
                  "sourceType": "CIDR_BLOCK", "isStateless": False,
                  "tcpOptions": {"destinationPortRange": {"min": 80, "max": 80}},
                  "description": "public HTTP for Caddy"})
if os.environ["HTTPS"].lower() == "true":
    rules.append({"direction": "INGRESS", "protocol": "6", "source": "0.0.0.0/0",
                  "sourceType": "CIDR_BLOCK", "isStateless": False,
                  "tcpOptions": {"destinationPortRange": {"min": 443, "max": 443}},
                  "description": "public HTTPS for Caddy"})
print(json.dumps(rules))')"

existing_rules="$(oapi network nsg rules list --nsg-id "$NSG_ID" --query 'data' 2>/dev/null || echo '[]')"
missing_rules="$(DESIRED="$desired_rules" EXISTING="$existing_rules" python3 -c '
import json, os

def key(rule):
    opts = rule.get("tcpOptions") or rule.get("udpOptions") or {}
    ports = opts.get("destinationPortRange") or {}
    return (rule.get("direction"), str(rule.get("protocol")), rule.get("source"),
            ports.get("min"), ports.get("max"))

desired = json.loads(os.environ["DESIRED"])
try:
    existing = json.loads(os.environ["EXISTING"]) or []
except Exception:
    existing = []
have = {key(r) for r in existing}
print(json.dumps([r for r in desired if key(r) not in have]))')"

if [ "$(pyget 'len(d)' "$missing_rules")" = "0" ]; then
    ok "all ingress rules already present"
else
    oapi network nsg rules add --nsg-id "$NSG_ID" --security-rules "$missing_rules" >/dev/null
    ok "added $(pyget 'len(d)' "$missing_rules") ingress rule(s)"
fi

step "Public subnet"
subnet_data="$(oapi network subnet list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --display-name "$subnet_name" 2>/dev/null || echo '{}')"
SUBNET_ID="$(pyget 'next((s["id"] for s in d.get("data", [])), "")' "$subnet_data")"
if [ -n "$SUBNET_ID" ]; then
    ok "reusing $subnet_name ($SUBNET_ID)"
else
    SUBNET_ID="$(oapi network subnet create --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" \
                    --cidr-block "$SUBNET_CIDR" --display-name "$subnet_name" \
                    --dns-label "${DEVHOST_NAME%-*}-sub" --security-list-ids "[\"$SL_ID\"]" \
                    --freeform-tags "$(tag_json)" --wait-for-state AVAILABLE \
                    --query 'data.id' --raw-output)"
    ok "created $subnet_name ($SUBNET_ID)"
fi

# --- Instance ------------------------------------------------------------
step "Instance"
instance_data="$(oapi compute instance list --compartment-id "$COMPARTMENT" --display-name "$DEVHOST_NAME" 2>/dev/null || echo '{}')"
INSTANCE_ID="$(pyget 'next((i["id"] for i in d.get("data", []) if i.get("lifecycle-state") != "TERMINATED"), "")' "$instance_data")"

if [ -n "$INSTANCE_ID" ]; then
    INSTANCE_STATE="$(oapi compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
    ok "reusing $DEVHOST_NAME ($INSTANCE_STATE)"
    if [ "$INSTANCE_STATE" = "STOPPED" ]; then
        warn "instance is stopped — starting it"
        oapi compute instance action --instance-id "$INSTANCE_ID" --action START >/dev/null
    fi
    AD_OF_INSTANCE="$(oapi compute instance get --instance-id "$INSTANCE_ID" --query 'data."availability-domain"' --raw-output)"
else
    step "Resolving the Ubuntu $UBUNTU_VERSION image for $SHAPE"
    IMAGE_ID="$(oapi compute image list --compartment-id "$COMPARTMENT" \
                    --operating-system "Canonical Ubuntu" --operating-system-version "$UBUNTU_VERSION" \
                    --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
                    --query 'data[0].id' --raw-output 2>/dev/null || true)"
    [ -n "$IMAGE_ID" ] && [ "$IMAGE_ID" != "None" ] || die "no Canonical Ubuntu $UBUNTU_VERSION image for $SHAPE in $REGION. Check UBUNTU_VERSION in .env."
    ok "image $IMAGE_ID"

    ssh_pubkey="$(cat "$SSH_KEY_PATH.pub")"
    metadata="$(SSH_PUBKEY="$ssh_pubkey" python3 -c '
import json, os
print(json.dumps({"ssh_authorized_keys": os.environ["SSH_PUBKEY"]}))')"
    shape_config="$(OCPUS="$OCPUS" MEMORY_GB="$MEMORY_GB" python3 -c '
import json, os
print(json.dumps({"ocpus": float(os.environ["OCPUS"]), "memoryInGBs": float(os.environ["MEMORY_GB"])}))')"

    attempt=0
    INSTANCE_ID=""
    while : ; do
        attempt=$((attempt + 1))
        if [ "$MAX_ATTEMPTS" != "0" ] && [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
            die "gave up after $MAX_ATTEMPTS attempts. Free A1 capacity is scarce: re-run later, or try another OCI region (Always Free compute must be in the home region)."
        fi
        ad="${ADS[$(((attempt - 1) % ${#ADS[@]}))]}"
        printf '     attempt %s in %s ... ' "$attempt" "$ad"

        if launch_out="$(oapi compute instance launch \
                --compartment-id "$COMPARTMENT" \
                --availability-domain "$ad" \
                --shape "$SHAPE" \
                --shape-config "$shape_config" \
                --image-id "$IMAGE_ID" \
                --subnet-id "$SUBNET_ID" \
                --nsg-ids "[\"$NSG_ID\"]" \
                --assign-public-ip true \
                --display-name "$DEVHOST_NAME" \
                --hostname-label "${DEVHOST_NAME:0:15}" \
                --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
                --metadata "$metadata" \
                --freeform-tags "$(tag_json)" \
                --wait-for-state RUNNING --wait-interval-seconds 10 2>&1)"; then
            INSTANCE_ID="$(pyget 'd["data"]["id"]' "$launch_out")"
            echo "ok"
            ok "launched $DEVHOST_NAME in $ad"
            AD_OF_INSTANCE="$ad"
            break
        fi
        echo "failed"
        if printf '%s' "$launch_out" | grep -q "OutOfHostCapacity\|Out of host capacity\|InternalError"; then
            warn "no free A1 capacity in $ad; retrying in ${ATTEMPT_SLEEP}s"
        elif printf '%s' "$launch_out" | grep -q "LimitExceeded"; then
            printf '%s\n' "$launch_out" | sed 's/^/     /'
            die "the tenancy limit was exceeded. Check Governance & Administration -> Limits, Quotas and Usage: on tenancies created before 2026-06-15 the Always Free A1 allowance may be 4 OCPU / 24 GB, but the current allowance is 2 OCPU / 12 GB. Lower OCPUS/MEMORY_GB in .env."
        else
            printf '%s\n' "$launch_out" | sed 's/^/     /'
            die "instance launch failed (not a capacity error)"
        fi
        sleep "$ATTEMPT_SLEEP"
    done
fi

# --- State ---------------------------------------------------------------
step "Recording state"
vnic_data="$(oapi compute instance list-vnics --instance-id "$INSTANCE_ID" 2>/dev/null || echo '{}')"
PUBLIC_IP="$(pyget 'next((v.get("public-ip") for v in d.get("data", []) if v.get("public-ip")), "")' "$vnic_data")"
PRIVATE_IP="$(pyget 'next((v.get("private-ip") for v in d.get("data", [])), "")' "$vnic_data")"
[ -n "$PUBLIC_IP" ] || warn "no public IP on the VNIC yet — it may still be assigning"

mkdir -p "$ROOT/state"
umask 077
cat > "$STATE" <<EOF
# Generated by scripts/provision.sh — do not commit (gitignored).
DEVHOST_NAME=$DEVHOST_NAME
SSH_USER=$SSH_USER
SSH_KEY_PATH=$SSH_KEY_PATH
REGION=$REGION
HOME_REGION=$HOME_REGION
COMPARTMENT=$COMPARTMENT
TENANCY=$TENANCY_ID
AVAILABILITY_DOMAIN=${AD_OF_INSTANCE:-}
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
PRIVATE_IP=$PRIVATE_IP
VCN_ID=$VCN_ID
SUBNET_ID=$SUBNET_ID
NSG_ID=$NSG_ID
SECURITY_LIST_ID=$SL_ID
IGW_ID=$IGW_ID
ROUTE_TABLE_ID=$DEFAULT_RT_ID
BOOTSTRAP_SSH_CIDR=$BOOTSTRAP_SSH_CIDR
PROVISIONED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
ok "state/devhost.env"

step "Done"
ok "instance: $DEVHOST_NAME ($INSTANCE_ID)"
ok "public IP: ${PUBLIC_IP:-pending}"
ok "next:     scripts/configure.sh"
ok "teardown: scripts/destroy.sh   (stops all charges and removes everything)"
