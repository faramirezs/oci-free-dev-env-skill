#!/usr/bin/env bash
# sshd: the *effective* configuration, not the drop-in file contents.
set -u

if ! sudo -n true 2>/dev/null; then
    echo "passwordless sudo is required to read the effective sshd config"
    exit 2
fi

effective="$(sudo -n sshd -T 2>/dev/null || true)"
if [ -z "$effective" ]; then
    echo "sshd -T produced no output"
    exit 1
fi

check() {
    local key="$1" expected="$2"
    local actual
    actual="$(printf '%s\n' "$effective" | awk -v k="$key" '$1 == k {print $2}' | head -1)"
    if [ "$actual" = "$expected" ]; then
        echo "$key = $actual"
        return 0
    fi
    echo "$key = '${actual:-unset}' (expected '$expected')"
    return 1
}

rc=0
case "$(printf '%s\n' "$effective" | awk '$1 == "permitrootlogin" {print $2}')" in
    no|prohibit-password|forced-commands-only) echo "permitrootlogin restricted" ;;
    *) echo "permitrootlogin is not restricted"; rc=1 ;;
esac
check passwordauthentication no || rc=1
check kbdinteractiveauthentication no || rc=1
check pubkeyauthentication yes || rc=1

if [ ! -f /etc/ssh/sshd_config.d/99-devhost-hardening.conf ]; then
    echo "hardening drop-in /etc/ssh/sshd_config.d/99-devhost-hardening.conf is missing"
    rc=1
fi

[ "$rc" -eq 0 ] || exit 1
echo "sshd OK"
