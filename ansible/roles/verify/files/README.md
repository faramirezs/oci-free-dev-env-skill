# devhost verify suite

Runs on the host, checks the live system rather than the configuration files.

```bash
bash ~/.devhost-verify/verify.sh              # everything
bash ~/.devhost-verify/verify.sh tailscale    # one test (substring match)
bash ~/.devhost-verify/verify.sh 03 06        # several
```

| Test | Asserts |
|---|---|
| 01-tailscale | daemon running, node authenticated, own MagicDNS name resolves (SKIP if not authenticated) |
| 02-mosh | mosh client + server present, session timeout configured, a server actually starts and listens |
| 03-caddy | service active, health endpoint returns 200 with the security headers (SKIP without a tailnet address) |
| 04-tmux | config present, auto-attach wired into `.bashrc`, lingering enabled, a real session survives a command round-trip |
| 05-sshd | effective `sshd -T` config: no password auth, no keyboard-interactive, root login restricted, pubkeys required |
| 06-firewall | ufw active with default-deny incoming, no world-open tcp/22, fail2ban running with the sshd jail |
| 07-storage | root filesystem usage under 80% and the partition spans the whole boot volume |

Exit codes: `0` pass, `2` skip (not ready, e.g. Tailscale), anything else fail — per test. The
harness itself exits `0` when no test failed and `1` otherwise, so a skipped test does not fail the
run; read the `passed: … skipped: … failed: …` summary line.
Logs land in `/var/log/devhost-verify/<test>.<timestamp>.log`.

Add a test by dropping `tests/08-mycheck.sh` that exits 0 / 2 / non-zero; the
harness picks up every `tests/*.sh`.
