---
name: oci-free-dev-env
description: Create a free remote development host on Oracle Cloud (Always Free) end to end — install and authenticate the OCI CLI, provision VCN/subnet/NSG/instance with capacity retries, then apply a hardened Ubuntu 22.04 Ansible stack (Tailscale-only SSH, ufw, fail2ban, mosh, persistent tmux, Caddy tailnet web previews, on-host verification suite) and tear it down again. Use when the user says "free remote dev environment", "Oracle Cloud free tier dev box", "OCI Always Free VPS", "give me a cloud dev machine for free", "provision a dev host on Oracle", or asks to move a Tailscale-only dev host setup to Oracle Cloud. Covers OCI CLI bootstrap, the Tailscale cutover, verification, costs, and teardown.
---

# OCI Always Free remote dev host

**Deliverable:** a reachable, hardened development host that costs nothing, plus a repo of scripts and an Ansible playbook that recreates it. This skill is the genericized, distribution-ready version of the author's private dev-host playbook.

## Layout

```
scripts/preflight.sh   installs OCI CLI + Ansible + collections, checks auth   (idempotent)
scripts/provision.sh   VCN, IGW, security list, NSG, subnet, A1 instance       (idempotent)
scripts/configure.sh   renders inventory/vars, runs the playbook over SSH
scripts/verify.sh      syntax check + playbook + on-host verification suite
scripts/destroy.sh     terminates the instance, optionally the whole network
ansible/               the playbook (site.yml, roles/, group_vars/)
```

## Hard rules

- **Never open tcp/22 to `0.0.0.0/0`.** `provision.sh` allows only the operator's detected public IP `/32`, and `configure.sh --tailscale-only` removes even that. The host is meant to be reachable over Tailscale only.
- **Run the phases in order, never skip preflight.** `provision.sh` refuses to run without a working OCI authentication.
- **Two human gates.** (1) Uploading the OCI API public key in the Console. (2) Opening the Tailscale login URL when no auth key is configured. Everything else is unattended. Do not fabricate either one — stop and ask.
- **`destroy.sh` is destructive.** Run it only on an explicit user order; it deletes the boot volume by default.
- **Always Free, not free trial.** Resources must live in the tenancy's *home region*; check the current allowance before raising `OCPUS`/`MEMORY_GB` (see Costs below).
- Never put real OCIDs, IPs, tailnet names or secrets into the repo or into a commit.

## 0. Resolve the skill directory

```bash
SKILL_DIR=<directory containing this SKILL.md>   # e.g. ~/.omp/agent/skills/oci-free-dev-env
cd "$SKILL_DIR"
[ -f .env ] || cp .env.example .env              # then set the values the user chose
```

Ask the user only for what you cannot decide: home region if the tenancy has several, desired host name, and whether to use a Tailscale auth key now. Everything else has a working default. Ask for confirmation of Always Free assumptions when the tenancy is not new.

## 1. Preflight — OCI CLI, Ansible, authentication

```bash
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
scripts/preflight.sh
```

- Installs the OCI CLI when missing (Homebrew on macOS, Oracle's installer on Linux), installs `ansible-core` + `community.general`, creates `~/.ssh/id_ed25519` when absent, then verifies authentication with `oci iam region-subscription list`.
- **Exit 2 = the human must act.** Print the guide it emitted and hand these to the user:
  1. `oci setup config` (asks for user OCID, tenancy OCID, region) — this also generates the API key pair.
  2. Console → Profile → **My profile** → **API keys** → *Add API key* → *Paste a public key* → paste `cat ~/.oci/oci_api_key_public.pem`. Direct link: <https://cloud.oracle.com/identity/domains/my-profile/api-keys>
  3. `oci setup repair-file-permissions --file ~/.oci/config`, then re-run `scripts/preflight.sh`.
- Wait for the user to confirm the key was uploaded, then re-run. Do not continue while exit code is 2.
- Browser-login alternative, no API keys: `oci session authenticate --region <home-region>`, then run every script with `OCI_CLI_ARGS="--auth security_token --profile <name>"`.

## 2. Provision — cloud resources

```bash
scripts/provision.sh          # ~2 min when capacity is available, minutes to hours when it is not
```

Creates or reuses by display name: VCN, internet gateway, default-route-table route, a dedicated security list (egress only — deliberately *not* the VCN default list, which allows SSH from anywhere), NSG with `tcp/22` restricted to the operator `/32` plus `udp/41641` for Tailscale direct connections, public subnet, and the `VM.Standard.A1.Flex` instance with the SSH key injected at launch.

- **`OutOfHostCapacity` is normal** for A1 shapes. The script rotates availability domains and retries `MAX_ATTEMPTS` times (default 24 × 60 s). Report progress to the user rather than treating it as an error; a background retry loop is also acceptable (`MAX_ATTEMPTS=0` retries forever).
- `LimitExceeded` is a different problem: the tenancy allowance is smaller than requested. Lower `OCPUS`/`MEMORY_GB` (Always Free is 2 OCPU / 12 GB since 2026-06-15; older tenancies may still hold 4 / 24).
- Result: `state/devhost.env` (instance OCID, public IP, NSG/subnet/VCN ids). Never commit it.

## 3. Configure — the Ansible stack

```bash
scripts/configure.sh
```

Renders `ansible/inventory.ini` plus `group_vars/all/local.yml` and `secrets.yml` (0600) from `.env` and the state file, waits for SSH (300 s budget), then runs `site.yml`. Roles and what they guarantee are listed in `README.md`.

- The bootstrap run reaches the host over the public IP with the `/32` rule. `ssh_wan_allow` therefore contains that `/32` and the playbook writes a `tcp/22` ufw rule for it — that is expected at this stage, not a finding.
- **If no Tailscale auth key was configured**, the playbook prints a `https://login.tailscale.com/...` URL and the host stays unauthenticated. Give the URL to the user, wait for them to open it, then continue. Verify with `ssh <host> tailscale status | head -1` or re-run `scripts/configure.sh`.
- Re-running `configure.sh` is safe and is the right response to any partial failure.

## 4. Cutover — Tailscale only

```bash
scripts/configure.sh --tailscale-only
```

Refuses to run unless the host already reports `BackendState: Running`. It empties `ssh_wan_allow`, names the bootstrap `/32` in `ssh_wan_allow_remove`, and re-applies the playbook, which **deletes** the `tcp/22` ufw rule for that address. Any later `configure.sh` run that reaches the host over the tailnet does the same automatically, so the WAN path closes itself once Tailscale works. The host stays reachable as `ssh <DEVHOST_NAME>` (MagicDNS). The client must be on the tailnet: `tailscale up` (macOS: `brew install --cask tailscale`).

The cloud **NSG** rule for `tcp/22` is not touched by the playbook: ufw already denies the port, and `provision.sh` only re-adds the rule when it is missing. Delete it in the Console (Networking → VCN → NSG → rules) if the cloud edge must be closed too.

## 5. Verify — evidence, not assurances

```bash
scripts/verify.sh
```

`ansible-playbook --syntax-check`, then the playbook, then on-host `~/.devhost-verify/verify.sh` (7 tests: Tailscale, mosh, Caddy headers, tmux persistence, effective `sshd -T` hardening, ufw + fail2ban, storage). Exit 2 means SKIP, and only a skip on `01-tailscale` or `03-caddy` is acceptable before the Tailscale cutover.

Also prove reachability yourself before reporting success:

```bash
ssh <DEVHOST_NAME> 'hostname; tailscale ip -4; sudo ufw status | head -3; tmux ls || true'
```

Report to the user: host name, tailnet address, how to log in (`ssh <name>`, `mosh <name>`), where web previews appear (`http://<tailnet-ip>:9000-9009` → `127.0.0.1:<port>` on the host), and that `scripts/destroy.sh` removes everything.

## 6. Teardown

```bash
scripts/destroy.sh            # instance + boot volume
scripts/destroy.sh --all      # also VCN, subnet, NSG, security list, IGW
```

Confirm with the user first, then pass `--yes` for scripted use. Remind the user to check Block Volumes in the Console for anything left behind — a preserved volume or an idle instance keeps consuming the Always Free allowance.

## Costs, limits, and the traps

| Item | Always Free allowance (current docs) |
|---|---|
| Ampere A1 compute | 1,500 OCPU-h + 9,000 GB-h per month = 2 OCPU / 12 GB continuously |
| AMD micro shapes | 2 × `VM.Standard.E2.1.Micro` (1/8 OCPU, 1 GB) |
| Block storage | 200 GB total, boot + block volumes combined; 5 volume backups |
| Outbound transfer | 10 TB per month |
| VCNs | 2 on free-only tenancies |

- **Region:** Always Free compute and block storage exist only in the tenancy's *home* region.
- **Halving:** on 2026-06-15 Oracle cut the A1 allowance from 4 OCPU / 24 GB to 2 OCPU / 12 GB. Pre-existing larger instances may be disabled. Check *Governance & Administration → Limits, Quotas and Usage* before assuming 4/24.
- **Idle reclamation:** Oracle may reclaim Always Free instances that stay under 20% CPU *and* network *and* memory (95th percentile) for 7 days. A dev host that is genuinely used is safe; a box left idle for a week is not.
- **Charges:** an Always Free account is refused rather than billed. A pay-as-you-go account is billed for anything above the allowance (extra OCPUs, boot volume beyond 200 GB, a second load balancer). If the user upgraded, say so plainly.
