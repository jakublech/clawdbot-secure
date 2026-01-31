# ClawDBot Secure Host Setup

Purpose
-------
This repository contains a single hardening script (`clawdbot-secure`) that prepares a Debian/Ubuntu-like host to run the ClawDBot service inside Docker with conservative, security-minded defaults.

Important notes
---------------
- The script is intended to be run as root. It makes system-level changes (package upgrades, SSH and kernel configuration, firewall rules, Docker installation, and writes files under `/etc` and `/opt`).
- IMPORTANT: This script is intended to run on localhost (a personal workstation or local machine). It is NOT designed for remote VPS or dedicated servers. Running it on remote or provider-managed servers may disrupt access, violate provider policies, or interfere with network configurations managed outside the machine.
- WARNING: The script modifies SSH, firewall, and kernel networking settings — it will affect ports and communication on your host. Be sure you have an alternate access method (local console or provider serial/management console) before running.
- Review the changes and ensure you have console or alternative access (e.g., cloud provider serial console) before running on a production host.
- Test on a staging machine or snapshot the VM before running.

Quick start
-----------
1. Inspect the script:

   cat ./clawdbot-secure

2. Run as root (recommended on a test VM first):

   sudo bash ./clawdbot-secure.sh

3. To start the bot after the script completes:

   cd /opt/clawdbot && docker compose up -d

If you prefer to review changes before they are applied, open the script and follow the step descriptions (each numbered step includes a "What will change" and "Consequences/Risks").

What the script modifies (detailed)
----------------------------------
Below is a concise summary of each automated step and the expected consequences or risks. This duplicates the in-script documentation so you can review offline.

1) System update
- What will change: Runs `apt update` and `apt upgrade -y` to refresh package indices and install available upgrades.
- Consequences / Risks: Packages may update to newer versions; services may change behavior or require a reboot. Run during a maintenance window and snapshot the machine first.

2) SSH hardening
- What will change: Edits `/etc/ssh/sshd_config` to disable password authentication, disallow root login, and set the configured SSH port.
- Consequences / Risks: If you don't have key-based access configured, you may be locked out. Ensure at least one working key-based login or alternate console access before running.

3) Firewall (ufw)
- What will change: Installs `ufw`, sets default deny incoming/allow outgoing and allows the SSH port.
- Consequences / Risks: Other services may be blocked if not allowed explicitly. Review required ports beforehand.

4) Kernel hardening
- What will change: Writes `/etc/sysctl.d/99-clawdbot.conf` with conservative kernel settings (e.g., restrict kernel pointers, protect symlinks/hardlinks, enable TCP syncookies and rp_filter).
- Consequences / Risks: Some advanced networking or kernel features may be impacted. Validate on staging.

5) Install Docker
- What will change: Installs Docker using the upstream convenience installer (`get.docker.com`) and enables the Docker systemd service.
- Consequences / Risks: Running remote install scripts carries supply-chain risk. Consider using distro packages or pinning versions if required.

6) Docker daemon defaults
- What will change: Writes `/etc/docker/daemon.json` with conservative defaults (disable inter-container comms, enable user namespace remap, enable `no-new-privileges`, enable `live-restore`).
- Consequences / Risks: `userns-remap` can alter UID/GID mappings for volumes and may require adjusting ownership or image expectations.

7) Bot directory
- What will change: Creates `/opt/clawdbot` with `data` and `logs` subdirectories, sets `chmod 750 /opt/clawdbot` and `chown root:docker /opt/clawdbot`.
- Consequences / Risks: If the `docker` group is missing this `chown` may fail. Ensure the `docker` group exists or adjust as needed.

8) Docker Compose file
- What will change: Writes a `docker-compose.yml` to `/opt/clawdbot` describing a hardened runtime for the `clawdbot` container (read-only root filesystem, dropped capabilities, resource limits, limited volumes, JSON log rotation).
- Consequences / Risks: `read_only: true` and dropped capabilities can break applications that expect to write to container filesystem or require capabilities. The `user: "1000:1000"` mapping assumes the application user; adjust as required.

9) Final notes
- What will change: Prints reminders; no further changes.

Recommendations & rollback hints
--------------------------------
- Backup: Snapshot or backup the VM before running.
- SSH lockout: Before disabling password auth or root login, ensure at least one working SSH key is installed under the account(s) you will use. If you are locked out, use your cloud provider's serial console / recovery ISO / out-of-band management to regain access and revert `/etc/ssh/sshd_config`.
- Docker namespace issues: If containers fail due to `userns-remap`, you can revert by adjusting `/etc/docker/daemon.json` and restarting Docker:

   sudo mv /etc/docker/daemon.json /etc/docker/daemon.json.disabled
   sudo systemctl restart docker

- Firewall: If you get locked out by `ufw`, use the provider console to run `ufw disable` or connect locally and run `ufw disable`.

Extending or customizing
------------------------
- Dry-run / prompts: You might add interactive confirmations before steps that can lock you out (SSH hardening, firewall enable) or implement a `--noop`/`--dry-run` mode to print planned changes without applying them.
- Ansible: For repeatable deployments, consider converting the script into an Ansible playbook for idempotence and better auditing.

Safety & audit
--------------
- The script favors conservative defaults but is not a substitute for a formal security review. Review the helm/image provenance, secrets handling, and runtime behavior of the `clawdbot` image before production use.

License
-------
This repository contains utility scripting provided as-is. No explicit license is included—add one if you plan to share publicly.

Contact / Next steps
--------------------
If you'd like, I can:
- Add a `--check`/`--dry-run` mode to the script.
- Add an interactive confirmation step before risky changes.
- Convert this script into an idempotent Ansible playbook and add tests.

Choose one and I'll implement it next.
