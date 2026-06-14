#!/bin/bash

# --- STAGE 1: ROOT & INITIAL SETTLE ---
if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

echo "Waiting 30 seconds for Firewalla baseline boot to settle..."
sleep 30

echo "Checking for internet connectivity..."
for i in {1..30}; do
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo "Internet is UP."
        break
    fi
    echo "Still waiting... ($i/30)"
    sleep 2
done

# --- STAGE 2: FORCE UNLOCK & INSTALL CHRONY ---
if ! command -v chronyd &> /dev/null; then
    echo "Attempting to install chrony..."
    
    # Wait out or clear stale apt/dpkg locks that run on boot
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock &>/dev/null; do
        echo "Apt is being used by another process. Waiting 5s..."
        sleep 5
    done

    until /usr/bin/apt-get update && /usr/bin/apt-get install -y chrony; do
        echo "Apt execution failed. Retrying in 10s..."
        sleep 10
    done
fi

# --- STAGE 3: KILL COMPETITORS ---
systemctl stop systemd-timesyncd 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true
systemctl stop ntp 2>/dev/null || true
systemctl disable ntp 2>/dev/null || true
systemctl mask ntp 2>/dev/null || true

# --- STAGE 4: APPLY CONFIG ---
# Remove severe rate-limiting constraint if present
sed -i 's/DAEMON_OPTS="-F 1"/DAEMON_OPTS="-F -1"/g' /etc/default/chrony 2>/dev/null || true

# Populate /etc/hosts so Chrony can bootstrap NTS keys even if local DNS is starting up
for host in "162.159.200.123 time.cloudflare.com" "94.198.159.15 ntppool1.time.nl" "192.53.103.108 ptbtime1.ptb.de"; do
    IP=$(echo $host | cut -d' ' -f1)
    NAME=$(echo $host | cut -d' ' -f2)
    if ! grep -q "$NAME" /etc/hosts; then
        echo "$IP $NAME" >> /etc/hosts
    fi
done

cat > /etc/chrony/chrony.conf <<EOF
server time.cloudflare.com iburst nts
server ntppool1.time.nl iburst nts
server ptbtime1.ptb.de iburst nts
driftfile /var/lib/chrony/chrony.drift
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
rtcsync
makestep 1 3
EOF

# --- STAGE 5: START UP ---
chown root:root /etc/chrony/chrony.conf
chmod 644 /etc/chrony/chrony.conf

# Unmask and restart both potential systemd alias variations safely
systemctl unmask chrony chronyd 2>/dev/null || true
systemctl enable chrony
systemctl restart chrony

# --- STAGE 6: NETWORK INTERCEPT ---
sleep 5
# Purge and re-apply IPv4 redirect for local bridge interfaces
iptables -t nat -D PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
iptables -t nat -A PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123

# Purge and re-apply IPv6 redirect (Firewalla often handles native v6)
ip6tables -t nat -D PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
ip6tables -t nat -A PREROUTING -i br0 -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true

echo "Chrony NTS Setup Complete."
