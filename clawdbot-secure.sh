#!/usr/bin/env bash
set -euo pipefail

# Purpose: Hardening script to prepare a host for running the "clawdbot" service
# Contract:
# - Inputs: none (expects to be run as root on a Debian/Ubuntu-like system)
# - Outputs: system packages updated, SSH and kernel hardening applied, Docker installed and configured,
#   a restricted docker-compose file placed in /opt/clawdbot
# - Error modes: script exits on any error (set -e). Some operations may require manual rollback.
# - Success: script completes without error and writes configuration to /etc and /opt.
#
# Assumptions & notes:
# - You have network access to download package updates and Docker install script.
# - You are running this as root and accept the changes to system configuration.
# - Each numbered step below includes a short "What will change" and "Consequences/Risks" note.

echo "== ClawDBot Secure Host + Docker Setup =="

### VARIABLES ###
BOT_NAME="clawdbot"
BOT_DIR="/opt/clawdbot"
SSH_PORT=22

### 1. SYSTEM UPDATE ###
# What will change: Runs `apt update` and `apt upgrade -y` to refresh package lists and install available upgrades.
# Consequences/Risks: Packages may be upgraded to newer versions which can change behavior or require a reboot.
# - Benefit: fixes known bugs and security issues.
# - Risk: if a service has specific version requirements, the upgrade could introduce incompatibilities.
# Recommendation: run on a maintenance window or snapshot the VM before running in production.
echo "[1/9] Updating system..."
apt update && apt upgrade -y

### 2. SSH HARDENING ###
# What will change: Modifies `/etc/ssh/sshd_config` to:
# - disable password authentication
# - forbid root login
# - change SSH port to the value of $SSH_PORT
# Consequences/Risks:
# - Benefit: reduces attack surface from brute-force and credential theft.
# - Risk: if you don't already have key-based access configured, you may lock yourself out.
# - Changing the port requires corresponding firewall rules; the script enables the SSH port later.
# Recommendation: ensure at least one working key-based login before running this step.
echo "[2/9] Hardening SSH..."
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i "s/#Port 22/Port ${SSH_PORT}/" /etc/ssh/sshd_config
systemctl restart sshd

### 3. FIREWALL ###
# What will change: Installs `ufw`, sets default policies (deny incoming, allow outgoing) and allows the configured SSH port.
# Consequences/Risks:
# - Benefit: simple host-level filtering to block unsolicited inbound traffic.
# - Risk: enabling the firewall could block services you expect to be reachable if not explicitly allowed.
# Recommendation: review required service ports and add `ufw allow` rules for them before enabling.
echo "[3/9] Configuring firewall..."
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp
ufw --force enable

### 4. KERNEL HARDENING ###
# What will change: Writes a sysctl config at `/etc/sysctl.d/99-clawdbot.conf` enabling several kernel-level protections
# (e.g. restricted kernel pointers, protected symlinks/hardlinks, TCP syncookies, rp_filter).
# Consequences/Risks:
# - Benefit: improves kernel-level protections against certain classes of attacks and information disclosure.
# - Risk: some network configurations or low-level features may be affected (e.g. custom networking or containers needing specific flags).
# Recommendation: test on a staging host and review `dmesg`/`sysctl` for unexpected errors after applying.
echo "[4/9] Applying kernel hardening..."
cat <<EOF >/etc/sysctl.d/99-clawdbot.conf
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.unprivileged_bpf_disabled=1
fs.protected_symlinks=1
fs.protected_hardlinks=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.tcp_syncookies=1
EOF
sysctl --system

### 5. INSTALL DOCKER ###
# What will change: Installs Docker using the official convenience script from get.docker.com and starts/enables the service.
# Consequences/Risks:
# - Benefit: quick, standard Docker install and systemd service enabled.
# - Risk: running a remote install script has supply-chain risks; review the script or pin an installation method if required.
# - The script will add Docker's packages and may pull in newer dependency versions.
# Recommendation: audit the download or use the distro package repository if you need stricter controls.
echo "[5/9] Installing Docker..."
apt install ca-certificates curl gnupg docker -y
systemctl enable docker
systemctl start docker

### 6. DOCKER SECURITY DEFAULTS ###
# What will change: Creates `/etc/docker/daemon.json` with conservative defaults:
# - disables inter-container communication (icc: false)
# - enables user namespace remapping (userns-remap: default)
# - sets `no-new-privileges` and enables `live-restore`.
# Consequences/Risks:
# - Benefit: reduces attack surface and isolates containers from the host more strongly.
# - Risk: userns-remap may change UID/GID expectations for bind mounts; some containers may break if they expect root ownership on volumes.
# Recommendation: validate container filesystem permissions after applying; be prepared to adjust volume ownership or user mapping.
echo "[6/9] Hardening Docker daemon..."
mkdir -p /etc/docker
cat <<EOF >/etc/docker/daemon.json
{
  "icc": false,
  "userns-remap": "default",
  "no-new-privileges": true,
  "live-restore": true
}
EOF
systemctl restart docker

### 7. BOT DIRECTORY ###
# What will change: Creates the bot directory structure at ${BOT_DIR} with `data` and `logs` subdirectories, sets permissions to 750
# and changes ownership to `root:docker`.
# Consequences/Risks:
# - Benefit: limits access to the bot files to root and members of the docker group.
# - Risk: if the `docker` group does not exist, `chown` will fail; containers may need specific uid/gid access.
# Recommendation: ensure the `docker` group exists (`getent group docker`) and that any host users needing access are added intentionally.
echo "[7/9] Creating bot directory..."
mkdir -p ${BOT_DIR}/{data,logs}
chmod 750 ${BOT_DIR}
chown root:docker ${BOT_DIR}

### 8. DOCKER COMPOSE ###
# What will change: Writes a `docker-compose.yml` into ${BOT_DIR} describing a hardened container configuration:
# - runs image `clawdbot:latest` as user 1000:1000
# - mounts only ./data and ./logs and marks container filesystem read-only
# - drops all capabilities, sets `no-new-privileges`, limits pids/memory/cpu and configures JSON file logging rotation
# Consequences/Risks:
# - Benefit: strong runtime constraints, least-privilege approach and resource caps reduce blast radius.
# - Risk: `read_only: true` means the container only can write to explicitly mounted volumes; the application must not expect to write elsewhere.
# - `cap_drop: - ALL` may remove capabilities the app needs (e.g., NET_BIND_SERVICE). Resource limits may need tuning for performance.
# - Mapping `user: "1000:1000"` assumes the container's app user matches that UID/GID; otherwise adjust to the container's internal user.
# Recommendation: inspect the container's expected filesystem layout and required capabilities before deploying; adapt volumes and user config accordingly.
echo "[8/9] Creating docker-compose.yml..."
cat <<EOF >${BOT_DIR}/docker-compose.yml
version: "3.9"

services:
  clawdbot:
    image: clawdbot:latest
    container_name: clawdbot
    user: "1000:1000"
    read_only: true
    restart: unless-stopped

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    pids_limit: 100
    mem_limit: 512m
    cpus: "1.0"

    volumes:
      - ./data:/app/data:rw
      - ./logs:/app/logs:rw

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

### 9. FINAL NOTES ###
# What will change: None (informational). Prints reminders and start instructions.
# Consequences/Risks:
# - Benefit: gives quick checklist and safe reminders (verify image source, avoid mounting host root/home, etc.).
# - Risk: none directly; but operators should heed the reminders.
echo "[9/9] DONE ✅"

echo ""
echo "SECURITY REMINDERS:"
echo "- Verify image source (checksum, signature)"
echo "- NEVER mount / or /home"
echo "- Do not expose ports unless required"
echo "- Rotate credentials regularly"
echo ""
echo "To start:"
echo "cd ${BOT_DIR} && docker compose up -d"
