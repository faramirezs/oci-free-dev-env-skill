#!/usr/bin/env bash
# devhost preflight — make this machine able to provision an instance:
#   OCI CLI (installs it when missing), Ansible + collections, an SSH key,
#   and a working OCI authentication.
#
# Idempotent, non-interactive, safe to re-run. Never edits ~/.oci/config.
#
# Exit codes:
#   0  ready to provision
#   2  action required by the human (OCI authentication)
#   1  a prerequisite could not be satisfied
#
# Environment (read from .env when present):
#   OCI_REGION       expected home region (informational cross-check)
#   SSH_KEY_PATH     private key to use / create (default ~/.ssh/id_ed25519)
#   PKG_INSTALL=0    skip installing anything, only report what is missing
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

PKG_INSTALL="${PKG_INSTALL:-1}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
OCI_REGION="${OCI_REGION:-}"
OCI_CLI_ARGS="${OCI_CLI_ARGS:-}"

green="\033[0;32m"; red="\033[0;31m"; yellow="\033[0;33m"; blue="\033[0;34m"; reset="\033[0m"
ok()   { printf "${green}ok${reset}   %s\n" "$1"; }
warn() { printf "${yellow}warn${reset} %s\n" "$1"; }
die()  { printf "${red}fail${reset} %s\n" "$1"; exit 1; }
step() { printf "\n${blue}==>${reset} %s\n" "$1"; }

ACTION_REQUIRED=0

# --- 1. Platform ----------------------------------------------------------
step "Platform"
os="$(uname -s)"; arch="$(uname -m)"
case "$os" in
    Linux)  ok "Linux ($arch)" ;;
    Darwin) ok "macOS ($arch)" ;;
    *)      warn "$os is not tested; the scripts need bash, curl, python3, ssh" ;;
esac
command -v python3 >/dev/null 2>&1 || die "python3 is required (the OCI CLI itself is a Python program)"
command -v curl >/dev/null 2>&1 || die "curl is required"
ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"

# --- 2. OCI CLI -----------------------------------------------------------
step "OCI CLI"
OCI=""
find_oci() {
    local c
    for c in oci "$HOME/bin/oci" "$HOME/.local/bin/oci" /usr/local/bin/oci /opt/homebrew/bin/oci; do
        if [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; then
            printf '%s' "$(command -v "$c" 2>/dev/null || printf '%s' "$c")"
            return 0
        fi
    done
    return 1
}

if OCI="$(find_oci)"; then
    ok "oci $("$OCI" --version 2>/dev/null || echo '(version unknown)') at $OCI"
elif [ "$PKG_INSTALL" = "0" ]; then
    die "the OCI CLI is missing and PKG_INSTALL=0 forbids installing it"
else
    warn "OCI CLI not found — installing it"
    case "$os" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install oci-cli || die "brew install oci-cli failed"
            else
                die "Homebrew is missing. Install it (https://brew.sh), then re-run. Or install the CLI manually: https://docs.oracle.com/iaas/Content/API/SDKDocs/climanualinst.htm"
            fi
            ;;
        *)
            installer="$(mktemp)"
            curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o "$installer" \
                || die "could not download the OCI CLI installer"
            bash "$installer" --accept-all-defaults || die "OCI CLI installer failed"
            rm -f "$installer"
            hash -r
            ;;
    esac
    if OCI="$(find_oci)"; then
        ok "installed oci at $OCI"
        case ":$PATH:" in
            *":$(dirname "$OCI"):"*) ;;
            *) warn "add $(dirname "$OCI") to PATH in your shell profile to use 'oci' directly" ;;
        esac
    else
        die "the OCI CLI was installed but not found. Look for ~/bin/oci or ~/.local/bin/oci"
    fi
fi

# --- 3. Ansible -----------------------------------------------------------
step "Ansible"
install_ansible() {
    if command -v pipx >/dev/null 2>&1; then
        pipx install --force ansible-core
    elif python3 -m pip --version >/dev/null 2>&1; then
        python3 -m pip install --user --upgrade ansible-core
    else
        return 1
    fi
    hash -r
}

# ansible-playbook --version prints "ansible-playbook [core 2.17.14] ...", so the
# second field is "[core" — the version is inside the brackets.
ansible_core_version() {
    ansible-playbook --version 2>/dev/null | sed -n 's/.*\[core \([0-9][0-9.]*\).*/\1/p' | head -1
}

if command -v ansible-playbook >/dev/null 2>&1; then
    core_version="$(ansible_core_version)"
    if [ -z "$core_version" ]; then
        # A shim on PATH whose Python cannot import ansible is a broken install:
        # say so instead of failing later inside ansible-galaxy.
        die "ansible-playbook is on PATH but does not run (its Python cannot import ansible). Fix that install, then re-run. A clean replacement is: pipx install --force ansible-core"
    fi
    ok "ansible-playbook $core_version"
    # community.general (the ufw module lives there) needs a recent core; an
    # older core only produces compatibility warnings, so upgrade rather than
    # fail later with a confusing error.
    core_short="${core_version%.*}"
    if [ -n "$core_short" ] && [ "$(printf '%s\n2.18\n' "$core_short" | sort -V | head -1)" != "2.18" ]; then
        if [ "$PKG_INSTALL" = "0" ]; then
            warn "ansible-core $core_version is older than 2.18; PKG_INSTALL=0 leaves it alone"
        else
            warn "ansible-core $core_version is older than 2.18 — upgrading for the ufw module"
            install_ansible || warn "upgrade failed; continuing with $core_version"
        fi
    fi
elif [ "$PKG_INSTALL" = "0" ]; then
    die "ansible-playbook is missing and PKG_INSTALL=0 forbids installing it"
else
    warn "Ansible not found — installing ansible-core"
    install_ansible || die "could not install ansible-core. Install it manually: https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html"
    command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook still not on PATH (check ~/.local/bin)"
    ok "installed ansible-playbook $(ansible_core_version)"
fi

# The ufw module lives in community.general.
galaxy_ok=1
ansible-galaxy --version >/dev/null 2>&1 || galaxy_ok=0
if [ "$galaxy_ok" = "0" ]; then
    die "ansible-galaxy does not run (same broken install as ansible-playbook). Fix it with: pipx install --force ansible-core"
elif ansible-galaxy collection list 2>/dev/null | grep -q '^community\.general'; then
    ok "collection community.general present"
elif [ "$PKG_INSTALL" = "0" ]; then
    die "collection community.general is missing and PKG_INSTALL=0 forbids installing it"
else
    warn "installing collection community.general"
    ansible-galaxy collection install community.general || die "ansible-galaxy install failed"
    ok "collection community.general installed"
fi

# --- 4. SSH key -----------------------------------------------------------
step "SSH key"
if [ -f "$SSH_KEY_PATH" ]; then
    ok "private key $SSH_KEY_PATH"
elif [ "$PKG_INSTALL" = "0" ]; then
    die "$SSH_KEY_PATH is missing and PKG_INSTALL=0 forbids creating it"
else
    warn "$SSH_KEY_PATH not found — generating an ed25519 key without a passphrase"
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    ssh-keygen -t ed25519 -N "" -C "$(whoami)@$(hostname)-devhost" -f "$SSH_KEY_PATH" >/dev/null \
        || die "ssh-keygen failed"
    ok "created $SSH_KEY_PATH"
fi
if [ -f "$SSH_KEY_PATH.pub" ]; then
    ok "public key $(cat "$SSH_KEY_PATH.pub" | awk '{print $1, substr($2, 1, 12) "…"}')"
else
    die "$SSH_KEY_PATH.pub is missing (expected next to the private key)"
fi

# --- 5. OCI authentication ------------------------------------------------
step "OCI authentication"
# shellcheck disable=SC2086
auth_check() { "$OCI" ${OCI_CLI_ARGS} iam region-subscription list --output json 2>&1; }

if auth_out="$(auth_check)"; then
    home="$(printf '%s' "$auth_out" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)["data"]
except Exception:
    print("")
else:
    print(next((r.get("region-name","") for r in d if r.get("is-home-region")), ""))' 2>/dev/null)"
    tenancy="$(printf '%s' "$auth_out" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)["data"]
except Exception:
    print("")
else:
    print(next((r.get("tenancy-id","") for r in d), ""))' 2>/dev/null)"
    ok "authenticated"
    [ -n "$tenancy" ] && ok "tenancy $tenancy"
    if [ -n "$home" ]; then
        ok "home region $home"
        if [ -n "$OCI_REGION" ] && [ "$OCI_REGION" != "$home" ]; then
            warn "OCI_REGION=$OCI_REGION but the tenancy home region is $home."
            warn "Always Free resources exist only in the home region — set OCI_REGION=$home."
        fi
    fi
else
    ACTION_REQUIRED=1
    printf '%s\n' "$auth_out" | sed 's/^/     /'
fi

if [ "$ACTION_REQUIRED" = "1" ]; then
    cat <<'GUIDE'

  The OCI CLI is installed but not authenticated. One-time setup:

  1. Run the guided setup. It asks for your user OCID, tenancy OCID and region
     (both OCIDs: Console -> Profile menu -> My profile / Tenancy details), then
     writes ~/.oci/config and generates a key pair:

         oci setup config

     Leave the key passphrase empty for a non-interactive CLI. If you set one,
     export OCI_CLI_KEY_PASSPHRASE before running the scripts.

  2. Give the public key to your OCI user. Print it:

         cat ~/.oci/oci_api_key_public.pem

     Console -> Profile menu -> My profile -> API keys -> Add API key ->
     "Paste a public key" -> paste the whole line -> Add.
     Direct link: https://cloud.oracle.com/identity/domains/my-profile/api-keys

  3. Lock down the config file and re-run this script:

         oci setup repair-file-permissions --file ~/.oci/config
         scripts/preflight.sh

  Alternative if you cannot use the Console: OCI Cloud Shell
  (https://cloud.oracle.com -> Developer tools -> Cloud Shell) is already
  authenticated, but your local SSH key still has to come from this machine.

  Alternative for a browser-based login without API keys:

         oci session authenticate --region <your-home-region>

     then run the scripts with
         OCI_CLI_ARGS="--auth security_token --profile <profile-name>"

GUIDE
    exit 2
fi

step "Ready"
ok "provision with: scripts/provision.sh"
exit 0
