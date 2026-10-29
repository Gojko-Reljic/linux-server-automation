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

## User notes

`create_users.sh` makes the accounts and their sudo role match `config/users.conf`, and is safe to run again:

- **The config is the source of truth.** Each line is `username:role`, where the role is `sudo` or `user`. A `user` account that is in the `sudo` group is removed from it on the next run, so a membership added by hand does not survive.
- **Validated before anything changes.** The whole file is checked first (username pattern, no `root`, no duplicates, known roles, existing `sudo` group), so a mistake on a late line cannot leave earlier accounts half provisioned. Comments, blank lines, indentation and CRLF line endings are accepted.
- **Trusted config only.** The file must be a regular file owned by root and not writable by group or others. Symlinks are refused.
- **Managed accounts only.** An existing account with a UID below 1000, a home other than `/home/<name>` or a shell other than `/bin/bash` is refused instead of modified.
- **SSH directory.** `.ssh` is created with mode 700 and the right owner, or repaired if it exists. A symlink is refused. `authorized_keys` is not managed.
- **New accounts are locked.** An administrator installs a public key before anyone logs in. An account with the `sudo` role also needs a password (`sudo passwd <name>`) before `sudo` works, because the default Ubuntu rule asks for one. No `NOPASSWD` rule is added, and re-running the script does not lock the account again.
- **Known limits.** There is no rollback: the checks on existing accounts run per account inside the loop, so a failure there leaves the accounts handled before it. An open session could swap `.ssh` for a symlink between the check and the `chown`. Both are planned for V2.

Test evidence is in `docs/test-results/create_users-run-*.txt`. The tests ran on Ubuntu 22.04 in a container.

## Docker notes

`install_docker.sh` installs Docker CE from Docker's official APT repository and stops when it cannot verify what it is about to trust:

- **Checks before changes.** It requires root, a supported OS (Ubuntu or Debian with a `VERSION_CODENAME`), systemd, and the `CAP_NET_ADMIN` and `CAP_SYS_ADMIN` capabilities. It stops if a conflicting package from the Ubuntu or Debian archive is installed (`docker.io`, `containerd`, `runc` and others) and removes nothing itself: in a test, installing `runc` silently removed `docker-ce` and `containerd.io`.
- **The signing key is verified.** The key is downloaded to a private temporary directory and installed only if the file contains exactly one primary key and its fingerprint matches the one in the script. Otherwise nothing is written under `/etc`. If Docker rotates its key, the script fails instead of trusting the new one.
- **An existing repository file is never overwritten.** If `/etc/apt/sources.list.d/docker.list` exists with different content, the script stops.
- **Idempotent install.** It uses `--no-upgrade`, so running it again does not upgrade or restart a working Docker. APT waits up to 120 seconds for the dpkg lock and retries failed downloads.
- **Version pin.** `DOCKER_VERSION` (for example `5:29.9.1-1~ubuntu.26.04~resolute`) pins `docker-ce` and `docker-ce-cli`, and the script checks both after the install. A different installed version stops the script; it never upgrades or downgrades. `containerd.io`, Buildx, Compose and the dependency `docker-ce-rootless-extras` follow the repository.
- **UFW needs an explicit acknowledgement.** Ports published by Docker can bypass UFW. While UFW is active the script stops unless `ALLOW_DOCKER_WITH_UFW=true` is set. The variable is a declaration only; the `DOCKER-USER` chain is not checked.
- **No test image.** The check asks the local daemon for its version, so nothing is pulled from a registry.
- **No terminal on stdin.** With a terminal on stdin and piped output, `apt-get` stopped mid-install in early test runs and the script hung. The script now reads stdin from `/dev/null`. The cause of the stop was not fully established.
- **No users are added to the `docker` group.** Membership is equivalent to root, so it stays an explicit decision.
- **Known limits.** `gpg` leaves `/root/.gnupg` behind. There is no rollback: if a later step fails, the key, repository file and packages stay. The lock wait is shorter than a long unattended-upgrades run, which the script reports with APT's own message. Rootless mode and user namespace remapping are not configured. Rollback, full version pinning and these two options are planned for V2.

Test evidence is in `docs/test-results/install_docker-run-*.txt`. The tests ran on Ubuntu 26.04 in a KVM virtual machine.

## Requirements

- Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13 (releases that still get free security updates). End-to-end testing was done on Ubuntu 26.04 only.
- Root access (sudo), systemd and apt
- At least 512 MB of usable RAM (the container limit, if there is one) and 5 GB free on each of /, /var and /home

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
