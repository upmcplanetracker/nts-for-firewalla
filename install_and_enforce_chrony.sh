#!/bin/bash
# ==============================================================================
# Firewalla NTS-Secured Chrony Installer & Enforcer
# ------------------------------------------------------------------------------
# DISCLAIMER: This script is NOT associated with Firewalla Inc.
# USE AT YOUR OWN RISK. I am not responsible for bricked devices.
# ------------------------------------------------------------------------------
#
# FEATURES:
# 1. Installs Chrony (modern, secure NTP) without breaking Firewalla core.
# 2. Configures NTS (Network Time Security) with the "Holy Trinity" of servers.
# 3. Fixes DNS/Permission issues via /etc/hosts injection.
# 4. Forces all LAN traffic (IPv4 & IPv6) on Port 123 to use this secure stream.
# 5. Persists across reboots via the post_main.d folder.
#
# INSTRUCTIONS:
# Place this file in: /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh
# Make it executable: chmod +x /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh
# Run it once manually: sudo /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh
# ==============================================================================

# --- PART 1: SAFETY CHECKS & INSTALL ---
# Check if Chrony is installed. If not, install ONLY chrony (NO UPGRADES).
if ! command -v chronyd &> /dev/null; then
    echo "Installing Chrony..."
    apt-get update
    # CRITICAL: We only install chrony. NEVER run 'apt upgrade' on Firewalla!
    apt-get install -y chrony
fi

# Stop and disable conflict services (systemd-timesyncd and legacy ntp)
systemctl stop systemd-timesyncd
systemctl disable systemd-timesyncd
if systemctl is-active --quiet ntp; then
    systemctl stop ntp
    systemctl disable ntp
fi

# --- PART 2: APPLY SECCOMP FIX ---
# Firewalla's kernel restricts system calls. We must relax Chrony's sandbox filter
# or it will fail to resolve DNS and crash.
sed -i 's/DAEMON_OPTS="-F 1"/DAEMON_OPTS="-F -1"/g' /etc/default/chrony

# --- PART 3: THE "CAVEMAN" HOSTS FIX ---
# NTS requires DNS, but the _chrony user is often blocked from reading DNS on Firewalla.
# We hardcode the "Holy Trinity" of stable, government-grade NTS servers into /etc/hosts.
# WARNING: If these IP addresses change, time sync will fail until updated.

# 1. Cloudflare (Global Anycast) - Primary
if ! grep -q "time.cloudflare.com" /etc/hosts; then
    echo "162.159.200.123  time.cloudflare.com" >> /etc/hosts
fi
# 2. TimeNL (Netherlands Government) - Backup 1
if ! grep -q "ntppool1.time.nl" /etc/hosts; then
    echo "94.198.159.15    ntppool1.time.nl" >> /etc/hosts
fi
# 3. PTB (German National Metrology Institute) - Backup 2 (The Tank)
if ! grep -q "ptbtime1.ptb.de" /etc/hosts; then
    echo "192.53.103.108   ptbtime1.ptb.de" >> /etc/hosts
fi

# --- PART 4: CREATE CONFIGURATION ---
# We overwrite the config to ensure strict NTS usage and allow LAN clients.
cat > /etc/chrony/chrony.conf <<EOF
# --- SERVERS ---
# 1. Cloudflare (Fastest)
server time.cloudflare.com iburst nts

# 2. TimeNL (Highly Trusted Backup)
server ntppool1.time.nl iburst nts

# 3. PTB Germany (The "Nuclear Option" for stability)
server ptbtime1.ptb.de iburst nts

# --- SETTINGS ---
# Allow drift monitoring
driftfile /var/lib/chrony/chrony.drift

# Allow local networks to query us (Interception targets)
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12

# Sync the Real Time Clock (RTC)
rtcsync

# Jump the clock if offset is larger than 1 second (Fast recovery)
makestep 1 3
EOF

# Fix permissions and Restart Service
chown root:root /etc/chrony/chrony.conf
chmod 644 /etc/chrony/chrony.conf
systemctl unmask chrony
systemctl enable chrony
systemctl restart chrony

# --- PART 5: FORCE NTP INTERCEPT (The "Force Field") ---
# Redirects all Port 123 traffic from LAN devices back to Chrony.
# Devices "think" they are talking to Google/Apple, but Chrony answers securely.

echo "Waiting for network..."
sleep 5

# IPv4 Redirect
iptables -t nat -D PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
iptables -t nat -A PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123

# IPv6 Redirect
ip6tables -t nat -D PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
ip6tables -t nat -A PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123

echo "Chrony NTS Setup Complete. Run 'chronyc sources -v' to verify."
