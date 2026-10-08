# Linux Server Automation

> Status: 🚧 In development

Automated provisioning script for fresh Linux servers (Ubuntu/Debian).
One command prepares a server for production use: system checks, user
setup, SSH hardening, firewall configuration, Nginx, Docker, logging,
backups, and a final health check.

## Why this project exists

Manually provisioning a server is slow and error-prone - it's easy to
forget a step (e.g. closing an unnecessary port), and every server ends
up slightly different. This project solves that: the same, repeatable,
tested process for every server.

## Implementation status

- [x] `system_check.sh` - OS detection and requirement validation
- [x] `update_system.sh`
- [x] `create_users.sh`
- [x] `configure_ssh.sh`
- [x] `configure_firewall.sh`
- [x] `install_nginx.sh`
- [x] `install_docker.sh`
- [ ] `configure_logging.sh`
- [ ] `backup.sh`
- [ ] `health_check.sh`
- [ ] `deploy.sh` (orchestrator)

## Usage

```bash
sudo ./deploy.sh
```

*(Detailed usage instructions will be added once `deploy.sh` is complete.)*

## Firewall notes

`configure_firewall.sh` is designed to fail closed:

- **Management access first.** `firewall.conf` must contain the management rule (`22/tcp` by default, override with `FIREWALL_MANAGEMENT_RULE`). The script refuses to run without it, applies it first, and sets `default deny incoming` only after every `allow` rule is in place, so an already-active firewall never has a window in which SSH is blocked.
- **Strict rule format.** Every line must be `PORT/tcp`, `PORT/udp` or `START:END/proto` (ports 1-65535). Anything else is rejected before the firewall is touched.
- **IPv6 is secure by default.** The script stops unless `IPV6=yes` is set in `/etc/default/ufw`, instead of reporting success while IPv6 traffic is unfiltered. Hosts without IPv6 can opt out explicitly with `FIREWALL_ALLOW_IPV6_DISABLED=true`, which only logs a warning.
- **Existing rules are preserved.** Rules added by hand are not removed. The script warns and leaves the audit to `ufw status numbered`.

Test evidence is in `docs/test-results/configure_firewall-run-*.txt`.

## Nginx notes

`install_nginx.sh` is designed to stop before it changes anything it cannot verify:

- **Checks before changes.** It requires root, a supported OS (Ubuntu or Debian), systemd and curl, and it refuses to start if another process already owns port 80. Nginx itself is allowed, so re-running the script on a working server is safe.
- **Idempotent install.** It always runs `apt-get install`, so an existing installation is updated and a missing one is installed. APT waits up to 120 seconds for the dpkg lock and retries failed downloads.
- **Version pin.** `NGINX_PACKAGE_VERSION` pins `nginx` and `nginx-common` to the same version, because they depend on each other. APT refuses a downgrade under `-y`. The pin was tested with the Ubuntu archive packages.
- **Configuration is validated first.** `nginx -t` runs before `systemctl enable --now`, so a broken configuration stops the script without touching the running service.
- **The health check proves it is Nginx.** One request to `http://127.0.0.1/` (no proxy, with timeouts) must return HTTP 200 and a `Server: nginx` header.
- **UFW is only warned about.** If UFW is active without a rule for port 80, the script warns, because the local check cannot see the firewall. It does not change firewall rules.
- **Known limits.** The lock wait is shorter than a long unattended-upgrades run, and a broken configuration is reported with Nginx's own message only.

Test evidence is in `docs/test-results/install_nginx-run-*.txt`.

## Requirements

- Ubuntu 20.04+ or Debian 11+
- Root access (sudo)
- Minimum 512MB RAM, 5GB free disk space

## Project structure

```
linux-server-automation/
├── deploy.sh               # Main orchestrator - calls all other scripts
├── scripts/                # Individual, self-contained scripts
├── config/                 # Configuration files (users, firewall, backup)
├── systemd/                # systemd service/timer definitions for backups
├── tests/                  # Tests for individual scripts
└── docs/                   # Detailed documentation
```

## License

MIT
