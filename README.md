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
