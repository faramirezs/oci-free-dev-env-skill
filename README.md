# oci-free-dev-env

After some weeks using a **free remote development host on Oracle Cloud** I can tell how happy I am. Now my agents have a place to code without my local machine being a bottleneck. 

This skill automates the whole process of provision a **free remote development host on Oracle Cloud** and configure it end to end: OCI CLI bootstrap, VCN/subnet/NSG/instance, then a hardened Ubuntu 22.04 Ansible stack — Tailscale-only SSH, ufw, fail2ban, mosh, persistent tmux, Caddy tailnet web previews, and an on-host verification suite.

It is packaged as an **agent skill** (`SKILL.md`) so an AI coding agent can run the whole flow, including the two steps only a human can do (uploading the OCI API key, approving the Tailscale login).


```
local machine                          Oracle Cloud (Always Free)                 tailnet
┌──────────────────┐                   ┌──────────────────────────────┐          ┌─────────┐
│ preflight.sh     │  oci CLI          │ VCN 10.0.0.0/16              │          │ laptop  │
│ provision.sh     │ ────────────────► │  subnet 10.0.0.0/24          │          │ phone   │
│ configure.sh     │                   │  NSG: tcp/22 from your /32   │  ssh /   │ tablet  │
│ verify.sh        │  ansible over ssh │       udp/41641 (Tailscale)  │◄──mosh──►│         │
│ destroy.sh       │ ────────────────► │  instance: A1.Flex 2c/12GB   │  http:// │         │
└──────────────────┘                   │   ufw · fail2ban · tmux      │  :9000-09│         │
                                       │   caddy · mosh · tailscaled  │          └─────────┘
                                       └──────────────────────────────┘
```

## Requirements

- An Oracle Cloud account. Sign-up requires a card for identity verification; Always Free resources are not charged. Use *Always Free*, not a paid upgrade.
- A Tailscale account (free tier is enough) and the Tailscale client on your laptop.
- Locally: `bash`, `curl`, `python3`, `ssh`. The scripts install the OCI CLI and Ansible themselves.

## Quickstart

For agents:

```bash
# Oh My Pi
git clone https://github.com/faramirezs/oci-free-dev-env-skill ~/.omp/agent/skills/oci-free-dev-env
# Claude Code style layouts
git clone https://github.com/faramirezs/oci-free-dev-env-skill ~/.claude/skills/oci-free-dev-env
```

Then ask the agent for a "free remote dev environment on Oracle Cloud"


For humans:
```bash
git clone https://github.com/faramirezs/oci-free-dev-env-skill
cd oci-free-dev-env-skill
cp .env.example .env                  # optional: host name, region, shape, Tailscale key

scripts/preflight.sh                  # installs OCI CLI + Ansible, verifies authentication
scripts/provision.sh                  # VCN, subnet, NSG, instance (retries on capacity)
scripts/configure.sh                  # Ansible stack + client SSH config
scripts/configure.sh --tailscale-only # drop the bootstrap SSH rule
scripts/verify.sh                     # playbook + on-host verification suite
```

Two human steps, both flagged by the scripts:

1. **OCI API key.** On first run `preflight.sh` exits 2 and prints the guide: run `oci setup config`, then paste `cat ~/.oci/oci_api_key_public.pem` into Console → Profile → My profile → API keys → *Add API key* → *Paste a public key* (<https://cloud.oracle.com/identity/domains/my-profile/api-keys>), then re-run.
2. **Tailscale login.** Without a `TAILSCALE_AUTH_KEY` in `.env`, the playbook prints a `https://login.tailscale.com/...` URL; open it once and the host joins the tailnet.


## What the Ansible setup covers

`ansible/site.yml` runs the roles below in dependency order. Every guarantee has a test in the on-host verify suite (`ansible/roles/verify/files/tests/`).

| Role | What it does | Test |
|---|---|---|
| `common` | apt cache + base toolchain (git, build-essential, tmux, fzf, ripgrep, python3-venv, jq, rsync, htop, strace …), persistent journald, unattended **security** upgrades only, timezone, per-user `.ssh` hygiene (0700/0600, never overwrites an existing client config) | — |
| `storage` | grows the root partition/filesystem when the boot volume is larger than the partition (cloud-init normally already did it; this covers a volume enlarged later) | `07-storage` |
| `tailscale` | installs tailscaled, joins the tailnet with an auth key **or prints a login URL**, `--accept-dns` (MagicDNS), optional Tailscale SSH, operator rights for the login user; its tailnet address becomes the bind address the `caddy` role uses. Idempotent: parses `tailscale status --json` instead of string-matching it | `01-tailscale` |
| `sshd` | drop-in `99-devhost-hardening.conf`: root login restricted, password and keyboard-interactive auth off, pubkeys required, `MaxAuthTries 4`, idle disconnects. Validated with `sshd -t` before reload and asserted against the **effective** `sshd -T` | `05-sshd` |
| `fail2ban` | sshd jail, systemd backend, 5 tries / 1 h ban, tailnet range `100.64.0.0/10` exempt so a stale key can never lock you out of the only path in | `06-firewall` |
| `firewall` | ufw: default deny incoming/routed, allow outgoing; allow rules are installed **before** ufw is enabled (lockout-safe ordering); only the bootstrap `/32` on tcp/22, plus 80/443 when public sites are configured | `06-firewall` |
| `mosh` | installs mosh, sets a week-long server-side session timeout; nothing is opened to the WAN — the mosh client's default `--bind-server=ssh` makes the server reply from the address the SSH connection arrived on (the tailnet address) | `02-mosh` |
| `caddy` | installs Caddy, binds the tailnet address, serves a health endpoint with security headers, and reverse-proxies ports **9000-9009** from `127.0.0.1` so a dev server on loopback is reachable from any tailnet device (widen `caddy_reverse_routes` in `ansible/group_vars/all/main.yml` for more). systemd drop-ins: file limits + wait for tailscaled before binding. Optional public HTTPS sites with automatic ACME | `03-caddy` |
| `tmux` | hardened config (prefix `C-a`, 100k history, mouse, vi copy, OSC 52 clipboard), auto-attach on interactive SSH login, `tz` helper for per-directory sessions, systemd lingering so sessions survive logout | `04-tmux` |
| `verify` | deploys this test suite to `~/.devhost-verify` | — |

Deliberately **not** included: any server-side editor daemon. Zed and VS Code Remote-SSH both use plain OpenSSH on the host; install the client locally and point it at `Host <name>` from your SSH config.

## Access model

```bash
ssh <name>            # MagicDNS name, tmux session `main` attaches automatically
mosh <name>           # roaming-safe; works over the tailnet
tz ls                 # per-directory tmux sessions
```

Web previews: start a dev server on `127.0.0.1:9000-9009` inside the host, then open `http://<tailnet-ip>:<port>` from any device on the tailnet. HTTP is deliberate — the tailnet link is already WireGuard-encrypted, and Caddy cannot bind HTTP and HTTPS on the same port.

There is no HTTPS listener on the tailnet address, so there is no certificate to trust. Public sites configured through `caddy_public_sites` get real ACME certificates for their own domains.

## Security model

- **No public SSH.** The NSG allows tcp/22 only from the operator's public IP, and `configure.sh` deletes that ufw rule as soon as the host is reachable over the tailnet (`--tailscale-only` forces it, and any later run over the tailnet does it automatically). Afterwards the only path in is Tailscale. The NSG rule is left in place — ufw denies the port — and can be deleted in the Console.
- **The OCI default security list is not used.** It allows inbound tcp/22 from `0.0.0.0/0`; `provision.sh` creates a dedicated egress-only security list instead.
- **nftables/iptables order.** `tailscaled` installs its own `ts-input` chain ahead of the ufw chains and accepts everything arriving on `tailscale0`. So ufw governs **WAN** traffic only, and within the tailnet reachability is decided by **Tailscale ACLs**, not by ufw. Both facts are easy to get wrong; the playbook documents them rather than adding rules that do nothing.
- **No WAN UDP range for mosh.** Only `udp/41641` (Tailscale direct connections, avoiding the DERP relay) is opened.
- **Key-only login.** The instance is launched with your public key; password and keyboard-interactive auth are off, `sshd -t` validates every config change before reload, and fail2ban rate-limits the bootstrap window.
- **Secrets never committed.** `.env`, `state/`, `ansible/inventory.ini`, `ansible/host_vars/`, `group_vars/all/secrets.yml` are gitignored; the two generated var files are written with mode 0600.

## Always Free: limits and traps

| Resource | Allowance (current docs) |
|---|---|
| Ampere A1 (`VM.Standard.A1.Flex`) | 1,500 OCPU-h + 9,000 GB-h per month = **2 OCPU / 12 GB** continuously |
| AMD micro (`VM.Standard.E2.1.Micro`) | 2 instances, 1/8 OCPU, 1 GB each |
| Block storage | **200 GB total**, boot + block volumes combined; 5 volume backups |
| Outbound data transfer | 10 TB per month |

- **Home region only.** Always Free compute and block storage exist solely in the tenancy's home region. `preflight.sh` warns when `OCI_REGION` disagrees.
- **The A1 allowance was halved on 2026-06-15** (4 OCPU / 24 GB → 2 OCPU / 12 GB). Tenancies created earlier may still show 4/24 in *Governance & Administration → Limits, Quotas and Usage*; instances above the current allowance can be disabled. Check before raising `OCPUS`/`MEMORY_GB`.
- **"Out of host capacity" is routine** for A1 shapes in busy regions. `provision.sh` rotates availability domains and retries (`MAX_ATTEMPTS`, `ATTEMPT_SLEEP`).
- **Idle instances can be reclaimed.** Oracle may reclaim an Always Free instance that stays below 20% CPU *and* network *and* memory (95th percentile) for 7 days. Keep it in real use.
- **Boot volume sizing.** The volume is created at `BOOT_VOLUME_GB` (default 100) and counts against the 200 GB total. 47 GB is the minimum; leave headroom if you want a second instance or a block volume.
- **Free vs pay-as-you-go.** A free tenancy is refused rather than billed when it exceeds an allowance. If the account was upgraded, keep to the numbers above or you pay the difference.

## Configuration

`.env` (copied from `.env.example`) drives everything; `configure.sh` renders it into Ansible variables.

| Variable | Default | Notes |
|---|---|---|
| `OCI_REGION` | empty → home region | Always Free requires the home region |
| `OCID_COMPARTMENT` | empty → tenancy root | provisioning target |
| `DEVHOST_NAME` | `devhost-1` | instance name, hostname label, Tailscale node name |
| `SSH_USER` / `SSH_KEY_PATH` | `ubuntu` / `~/.ssh/id_ed25519` | login user and key |
| `SHAPE`, `OCPUS`, `MEMORY_GB` | `VM.Standard.A1.Flex`, `2`, `12` | the Always Free allowance |
| `BOOT_VOLUME_GB` | `100` | against the 200 GB block-storage total |
| `UBUNTU_VERSION` | `22.04` | the playbook asserts this version |
| `VCN_CIDR` / `SUBNET_CIDR` | `10.0.0.0/16` / `10.0.0.0/24` | |
| `BOOTSTRAP_SSH_CIDR` | auto-detected `/32` | never `0.0.0.0/0` |
| `TAILSCALE_AUTH_KEY` | empty → interactive login | reusable + pre-approved, not ephemeral |
| `EXPOSE_PUBLIC_HTTP/HTTPS`, `CADDY_PUBLIC_SITES` | `false`/`false`/`[]` | only for real DNS + public sites |
| `MAX_ATTEMPTS` / `ATTEMPT_SLEEP` | `24` / `60` | capacity retry budget (`0` = forever) |
| `OCI_CLI_ARGS` | empty | e.g. `--auth security_token --profile x` |
| `PKG_INSTALL` | `1` | `0` = report missing tools instead of installing |

Frequently changed Ansible variables live in `ansible/group_vars/all/main.yml` (tmux session name and idle timeout, Caddy preview ports, public sites, timezone, unattended upgrades, `ssh_permit_root_login`, extras).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `preflight.sh` exits 2, `NotAuthenticated` | API key not uploaded, or wrong user/tenancy OCID | follow the printed guide, then re-run |
| `oci` not found after install | `~/bin` or `~/.local/bin` not on `PATH` | add it to your shell profile |
| Launch fails with `OutOfHostCapacity` | A1 capacity scarce | leave the retry loop running; try another AD; lower `OCPUS` |
| Launch fails with `LimitExceeded` | allowance smaller than requested | lower `OCPUS`/`MEMORY_GB`; check the Limits page |
| `configure.sh` never reaches SSH | instance still booting, or the NSG no longer matches your IP | wait; if your ISP changed your IP, set `BOOTSTRAP_SSH_CIDR` and re-run `provision.sh` |
| Host unreachable after `--tailscale-only` | client not on the tailnet, or `ssh` still pointing at the old public IP | `tailscale up` on the client; check the `Host` block in `~/.ssh/config` |
| `Could not resolve hostname <name>` | MagicDNS not enabled on the client | `tailscale set --accept-dns=true` (client) |
| mosh connects then stalls, "broken pipe" | sessions relayed via DERP | confirm the NSG `udp/41641` rule (added by `provision.sh`) and that the client has direct connectivity |
| Preview port returns 502 | nothing listening on that port on the host | start the dev server on `127.0.0.1:<port>`; check `caddy_reverse_routes` in `ansible/group_vars/all/main.yml` holds that port |
| `sudo` asks for a password | image user without NOPASSWD | `ansible-playbook … --ask-become-pass`, or add `ansible_become_password` |
| `community.general` missing | collections not installed | `ansible-galaxy collection install community.general` (preflight does this) |
| Root filesystem smaller than the volume | cloud-init growpart skipped | re-run `scripts/configure.sh`; the `storage` role grows it |

## Teardown

```bash
scripts/destroy.sh          # terminate the instance and delete the boot volume
scripts/destroy.sh --all    # also delete subnet, NSG, security list, internet gateway, VCN
scripts/destroy.sh --keep-boot-volume
```

Check Block Volumes and Instances in the Console afterwards: whatever is left keeps consuming the Always Free allowance.

## Layout

```
SKILL.md               agent-facing workflow (phases, gates, hard rules)
README.md              this file
.env.example           every knob, with defaults
scripts/               preflight · provision · configure · verify · destroy
ansible/
  site.yml             role order + platform asserts
  ansible.cfg          pipelining, accept-new host keys, connection sharing
  group_vars/all/      main.yml (defaults) · secrets.yml.example
  host_vars/<name>.yml   generated by configure.sh: operator values for this host
  roles/               common · storage · tailscale · sshd · fail2ban · firewall · mosh · caddy · tmux · verify
  files/ssh_config     client snippet appended by configure.sh
state/devhost.env      generated: instance OCID, IPs, NSG/subnet ids (gitignored)
```
