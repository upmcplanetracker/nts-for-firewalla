#!/bin/bash

# --- STAGE 1: ROOT & INITIAL SETTLE ---
if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

# --- CONFIGURATION ---
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
CONFIG_FILE="/etc/chrony-interface.conf"
HEALTH_CHECK_INTERVAL=300          # 5 minutes
MAX_CHRONY_RESTARTS=3
RESTART_COUNTER_FILE="/tmp/chrony_restart_counter"
LAST_HEALTH_CHECK="/tmp/chrony_last_health"
CRON_TAG="# Chrony NTS Service"
CRON_JOB="0 4 * * * $SCRIPT_PATH &>/dev/null"
CRON_FILE="/etc/crontab"

# --- Bypass Firewalla aliases (use full paths) ---
APT_GET="/usr/bin/apt-get"
DPKG="/usr/bin/dpkg"
SYSTEMCTL="/usr/bin/systemctl"
IPTABLES="/sbin/iptables"
IP6TABLES="/sbin/ip6tables"
IP="/sbin/ip"
SED="/bin/sed"
GREP="/bin/grep"
CAT="/bin/cat"
ECHO="/bin/echo"
DATE="/bin/date"
SLEEP="/bin/sleep"
RM="/bin/rm"
FUSER="/usr/bin/fuser"
CHOWN="/bin/chown"
CHMOD="/bin/chmod"
REALPATH="/usr/bin/realpath"

unalias -a 2>/dev/null || true

FROM_CRON=0
if [ -z "$TERM" ] && [ -t 0 ] 2>/dev/null; then
    FROM_CRON=1
fi

# --- FUNCTIONS ---
log() {
    $ECHO "[$($DATE '+%Y-%m-%d %H:%M:%S')] $1"
}

manage_crontab() {
    local action="$1"
    case "$action" in
        "check")
            $GREP -q "$CRON_TAG" "$CRON_FILE" 2>/dev/null
            return $?
            ;;
        "update")
            $SED -i "/$CRON_TAG/d" "$CRON_FILE" 2>/dev/null || true
            $ECHO "$CRON_TAG" >> "$CRON_FILE"
            $ECHO "$CRON_JOB" >> "$CRON_FILE"
            log "✅ Updated crontab with: $CRON_JOB"
            ;;
        "show")
            $GREP -A1 "$CRON_TAG" "$CRON_FILE" 2>/dev/null || $ECHO "No cron entry found"
            ;;
    esac
}

get_lan_interfaces() {
    local interfaces=""
    for iface in $($IP link show type bridge 2>/dev/null | $GREP -E '^[0-9]+:' | awk -F': ' '{print $2}'); do
        if $IP addr show "$iface" | $GREP -q "inet "; then
            interfaces="$interfaces $iface"
        fi
    done
    if [ -z "$interfaces" ]; then
        for iface in $($IP link show | $GREP -E '^[0-9]+: (eth|en|wl)' | awk -F': ' '{print $2}' | cut -d'@' -f1); do
            if $IP addr show "$iface" | $GREP -q "inet " && [[ ! "$iface" =~ (wan|ppp|tun|wg|vpn) ]]; then
                interfaces="$interfaces $iface"
            fi
        done
    fi
    if [ -z "$interfaces" ]; then
        $ECHO "br0"
        return
    fi
    $ECHO "$interfaces" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

get_lan_subnets() {
    local subnets=""
    local interfaces=$(get_lan_interfaces)
    for iface in $interfaces; do
        $IP -4 addr show "$iface" | $GREP 'inet ' | while read line; do
            cidr=$(echo "$line" | awk '{print $2}')
            ip=$(echo "$cidr" | cut -d'/' -f1)
            if [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^10\. ]] || \
               [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
               [[ "$ip" =~ ^169\.254\. ]]; then
                echo "$cidr"
            fi
        done
    done | sort -u | tr '\n' ' '
}

apply_iptables_rules() {
    local interfaces=$(get_lan_interfaces)
    for iface in $interfaces; do
        $IPTABLES -t nat -D PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
        $IP6TABLES -t nat -D PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
    done
    for iface in $interfaces; do
        log "Adding redirect rule for interface: $iface"
        $IPTABLES -t nat -A PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123
        if $IP -6 addr show "$iface" | $GREP -q "inet6"; then
            $IP6TABLES -t nat -A PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
        fi
    done
}

is_chrony_healthy() {
    if ! $SYSTEMCTL is-active --quiet chrony && ! $SYSTEMCTL is-active --quiet chronyd; then
        return 1
    fi
    local sources=$(chronyc sources -v 2>/dev/null | $GREP -c "^\^" || true)
    [ "$sources" -ge 1 ]
}

should_check_health() {
    [ ! -f "$LAST_HEALTH_CHECK" ] && return 0
    local last_check=$($CAT "$LAST_HEALTH_CHECK")
    local current_time=$($DATE +%s)
    [ $((current_time - last_check)) -ge $HEALTH_CHECK_INTERVAL ]
}

manage_restart_counter() {
    case "$1" in
        "increment")
            local count=1
            [ -f "$RESTART_COUNTER_FILE" ] && count=$($CAT "$RESTART_COUNTER_FILE")
            count=$((count + 1))
            $ECHO "$count" > "$RESTART_COUNTER_FILE"
            ;;
        "reset") $RM -f "$RESTART_COUNTER_FILE" ;;
        "get")
            if [ -f "$RESTART_COUNTER_FILE" ]; then
                $CAT "$RESTART_COUNTER_FILE"
            else
                $ECHO "0"
            fi
            ;;
    esac
}

block_ntp_services() {
    log "Blocking competing NTP services (mask only – no holds)..."
    $CAT > /etc/apt/preferences.d/block-ntp <<EOF
Package: ntp ntpdate systemd-timesyncd
Pin: origin *
Pin-Priority: -1
EOF
    for svc in ntp ntpdate systemd-timesyncd ntp-systemd-netif; do
        $SYSTEMCTL mask "$svc.service" 2>/dev/null || true
    done
    log "✅ NTP services masked (installations blocked via apt preferences)."
}

enforce_chrony_dominance() {
    log "Ensuring chrony is the only active time service..."
    for svc in ntp ntpdate systemd-timesyncd; do
        if $SYSTEMCTL is-active --quiet "$svc" 2>/dev/null; then
            log "⚠️  $svc is running – stopping and masking"
            $SYSTEMCTL stop "$svc" 2>/dev/null || true
            $SYSTEMCTL disable "$svc" 2>/dev/null || true
            $SYSTEMCTL mask "$svc" 2>/dev/null || true
        fi
    done
    if ! $SYSTEMCTL is-active --quiet chrony; then
        log "Chrony not running – restarting..."
        $SYSTEMCTL restart chrony
    fi
}

# --- STAGE 2: CRONTAB MANAGEMENT (only manual runs) ---
if [ $FROM_CRON -eq 0 ]; then
    log "Checking crontab..."
    if manage_crontab "check"; then
        if ! $GREP -A1 "$CRON_TAG" "$CRON_FILE" | $GREP -q "$SCRIPT_PATH"; then
            log "Updating cron entry (path changed)..."
            manage_crontab "update"
        else
            log "✅ Cron entry OK."
        fi
    else
        log "Adding cron entry..."
        manage_crontab "update"
    fi
fi

# --- STAGE 3: BLOCK COMPETING SERVICES ---
block_ntp_services

# --- STAGE 4: DISCOVER NETWORK ---
log "Discovering LAN interfaces..."
LAN_INTERFACES=$(get_lan_interfaces)
log "Found: $LAN_INTERFACES"
LAN_SUBNETS=$(get_lan_subnets)
log "Detected subnets: $LAN_SUBNETS"

$CAT > "$CONFIG_FILE" <<EOF
# Chrony Interface Config – $($DATE)
LAN_INTERFACES="$LAN_INTERFACES"
LAN_SUBNETS="$LAN_SUBNETS"
SCRIPT_PATH="$SCRIPT_PATH"
CRON_JOB="$CRON_JOB"
EOF

# --- STAGE 5: BOOT SETTLE (only manual runs) ---
if [ $FROM_CRON -eq 0 ]; then
    log "Waiting 30s for system settle..."
    $SLEEP 30
fi

# --- STAGE 6: QUICK CHECK – exit if already healthy ---
if $SYSTEMCTL is-active --quiet chrony && \
   $IPTABLES -t nat -L PREROUTING -v -n 2>/dev/null | $GREP -q "dpt:123.*REDIRECT"; then
    log "Chrony already configured and running."
    enforce_chrony_dominance
    if should_check_health; then
        log "Performing periodic health check..."
        $ECHO "$($DATE +%s)" > "$LAST_HEALTH_CHECK"
        if ! is_chrony_healthy; then
            log "WARNING: Chrony unhealthy – restarting once..."
            $SYSTEMCTL restart chrony
            $SLEEP 10
            if is_chrony_healthy; then
                log "Chrony recovered."
                manage_restart_counter "reset"
            else
                log "ERROR: Chrony still unhealthy."
                local rc=$(manage_restart_counter "get")
                if [ "$rc" -ge "$MAX_CHRONY_RESTARTS" ]; then
                    log "CRITICAL: Chrony repeatedly failing – manual intervention needed."
                fi
            fi
        else
            log "Health check passed."
            manage_restart_counter "reset"
        fi
    fi
    exit 0
fi

# --- STAGE 7: INTERNET CHECK (manual runs only) ---
if [ $FROM_CRON -eq 0 ]; then
    log "Checking internet connectivity..."
    INTERNET_UP=0
    for i in {1..30}; do
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log "Internet is UP."
            INTERNET_UP=1
            break
        fi
        log "Still waiting... ($i/30)"
        $SLEEP 2
    done
    if [ $INTERNET_UP -eq 0 ]; then
        log "WARNING: No internet – will still configure chrony for LAN."
    fi
fi

# --- STAGE 8: INSTALL CHRONY (if missing) ---
if ! command -v chronyd &>/dev/null; then
    log "Installing chrony..."
    local lock_wait=0
    while $FUSER /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock &>/dev/null; do
        if [ $lock_wait -ge 120 ]; then
            log "ERROR: Apt locked >2 min – exiting."
            exit 1
        fi
        log "Apt busy – waiting 5s ($lock_wait/120s)"
        $SLEEP 5
        lock_wait=$((lock_wait + 5))
    done
    for attempt in {1..3}; do
        log "Install attempt $attempt/3..."
        if $APT_GET update && $APT_GET install -y chrony; then
            log "Chrony installed."
            break
        fi
        if [ $attempt -lt 3 ]; then
            log "Retrying in 10s..."
            $SLEEP 10
        else
            log "ERROR: Failed to install chrony."
            exit 1
        fi
    done
fi

# --- STAGE 9: STOP & MASK COMPETITORS (do not remove packages) ---
log "Disabling other time services..."
for svc in systemd-timesyncd ntp ntpdate; do
    $SYSTEMCTL stop "$svc" 2>/dev/null || true
    $SYSTEMCTL disable "$svc" 2>/dev/null || true
    $SYSTEMCTL mask "$svc" 2>/dev/null || true
done

# --- STAGE 10: WRITE CHRONY CONFIG ---
log "Applying chrony configuration..."
$SED -i 's/DAEMON_OPTS="-F 1"/DAEMON_OPTS="-F -1"/g' /etc/default/chrony 2>/dev/null || true

# Append NTS server IPs to /etc/hosts for reliable boot‑time DNS
$CAT >> /etc/hosts <<EOF
162.159.200.123 time.cloudflare.com
94.198.159.15 ntppool1.time.nl
192.53.103.108 ptbtime1.ptb.de
EOF

# Build chrony.conf – using hostnames (for NTS certificate validation)
$CAT > /etc/chrony/chrony.conf <<EOF
# Chrony NTS Configuration – $($DATE)
# Using hostnames; IPs are in /etc/hosts for bootstrap.

server time.cloudflare.com iburst nts
server ntppool1.time.nl iburst nts
server ptbtime1.ptb.de iburst nts

driftfile /var/lib/chrony/chrony.drift

# Allowed subnets (precise CIDRs from active interfaces)
$(for subnet in $LAN_SUBNETS; do $ECHO "allow $subnet"; done)

local stratum 10
rtcsync
makestep 1 3

logdir /var/log/chrony
log measurements statistics tracking
EOF

$CHOWN root:root /etc/chrony/chrony.conf
$CHMOD 644 /etc/chrony/chrony.conf

# --- STAGE 11: START CHRONY ---
log "Starting chrony..."
$SYSTEMCTL unmask chrony chronyd 2>/dev/null || true
$SYSTEMCTL enable chrony
$SYSTEMCTL restart chrony
$SLEEP 10

# --- STAGE 12: IPTABLES RULES ---
log "Applying iptables redirection..."
apply_iptables_rules

# --- STAGE 13: ENFORCE DOMINANCE AGAIN ---
enforce_chrony_dominance

# --- STAGE 14: HEALTH CHECK ---
log "Initial health check..."
if is_chrony_healthy; then
    log "✅ Chrony is healthy!"
    $ECHO "$($DATE +%s)" > "$LAST_HEALTH_CHECK"
    manage_restart_counter "reset"
else
    log "⚠️  Chrony started but not yet synchronized (normal for first start)."
    log "   It will sync in a few minutes."
fi

# --- STAGE 15: FINAL STATUS ---
log "=== Chrony Status ==="
chronyc tracking 2>/dev/null || log "Unable to fetch tracking info"
log "======================"
log "LAN interfaces: $LAN_INTERFACES"
log "Allowed subnets: $LAN_SUBNETS"
log "Config saved to: $CONFIG_FILE"
log "Cron job: $CRON_JOB"

if manage_crontab "check"; then
    log "✅ Cron entry:"
    manage_crontab "show"
else
    log "⚠️  Cron not configured – run manually to add."
fi

log "=== NTP Protection ==="
log "Masked services:"
$SYSTEMCTL list-unit-files | $GREP -E "(ntp|timesyncd)" | $GREP mask || log "  (none found)"
log "Apt preferences: /etc/apt/preferences.d/block-ntp"
log "======================"

exit 0
