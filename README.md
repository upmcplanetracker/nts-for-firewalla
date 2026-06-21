Firewalla NTS: Encrypted Time & Transparent Intercept
=====================================================

Secure your network time with authenticated **NTS (Network Time Security)** and force all devices on your LAN to use it via Firewalla’s NTP Intercept feature – **without sacrificing security or stability**.

* * *

⚠️ BIG DISCLAIMER (READ THIS FIRST)
-----------------------------------

> **I AM NOT AFFILIATED WITH FIREWALLA.** This is a **community contribution** and is **NOT supported** by Firewalla Inc.
> 
> **USE AT YOUR OWN RISK.** Modifying your router always carries risks. I am not responsible if your device malfunctions. Know how to **reflash** your Firewalla and have a recovery drive ready **before** proceeding.
> 
> **NEVER RUN `APT UPGRADE`.** This script only installs `chrony` – it does **not** upgrade system packages. Firewalla uses a custom OS kernel; upgrading generic Ubuntu packages will **destabilize or brick** your box.
> 
> **TESTED ON FIREWALLA GOLD PLUS** running **Ubuntu 22.04** (fresh image from Firewalla). Should work on other modern models, but **not guaranteed** on older OS versions (18.04, 20.04).
> 
> **PLEASE READ THIS ENTIRE README** to understand what you’re getting into – **and how to revert** if needed.
> 
> **NTP INTERCEPT STILL APPLIES.** Clients on your network must still use **plain NTP** (not NTS) because Firewalla only intercepts NTP. If you have devices with Chrony/NTS (e.g., Ubuntu 25.10+), they will fail to sync unless you either:
> 
> *   Reconfigure them to use NTP, **or**
> *   Turn off NTP Intercept for that network (so their NTS requests reach the internet directly).

**⚠️ Important:** Because this script applies its own firewall rules (`iptables`) at every boot, the **"NTP Intercept" slider in the Firewalla App may no longer reflect reality**.  
Even if you turn the slider **OFF**, the script will **re‑enable interception** on reboot – by design, to keep your network secure and transparently intercepted.

* * *

❓ Why Replace the Default NTP?
------------------------------

Default NTP sends time data in **unencrypted plain text**. Anyone on the path – hacker, ISP, government – can inspect or spoof your time requests (Man‑in‑the‑Middle).

This project replaces the default time service with **Chrony**, configured to use **NTS (Network Time Security)**.

### ✅ The Benefits

*   **Encryption & Authentication** – Chrony uses **TLS** to verify the time server’s identity and ensure the time has not been altered.
*   **The "Force Field" (Intercept)** – Many IoT devices have hardcoded, insecure NTP servers. This script transparently intercepts **all** NTP traffic on your LAN and redirects it to your secure Chrony instance – devices never know.
*   **Robustness** – The script installs itself into Firewalla’s persistence folder (`post_main.d`) and automatically **repairs** itself after reboots (though firmware updates may overwrite it – the cron job handles that).

* * *

🚀 Installation
---------------

### Step 1: Prepare the Environment

Firewalla aliases `apt` to prevent accidental breakage. **Unalias** it for your session:

    unalias apt
    unalias apt-get

_(You’ll need to repeat this if you log out and back in.)_

### Step 2: Install the Script

SSH into your Firewalla and create the script file:

    sudo mkdir -p /home/pi/.firewalla/config/post_main.d
    sudo nano /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh

Paste the **full script** from this repository (the one provided above).  
Then save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

### Step 3: Make It Executable & Run

    sudo chmod +x /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh
    sudo /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh

The script will:

*   **Auto‑discover** all your LAN interfaces (bridges and physical, excluding WAN).
*   **Auto‑detect** the precise subnets (CIDR) and add them to `chrony.conf` (e.g., `allow 192.168.1.0/24`).
*   **Install** `chrony` if missing.
*   **Mask** competing NTP services (`ntp`, `ntpdate`, `systemd-timesyncd`) – without removing packages.
*   **Add** a daily cron job at **4:00 AM** to re‑apply the configuration after Firewalla updates.
*   **Append** NTS server IPs to `/etc/hosts` so Chrony can resolve hostnames even when DNS is slow.
*   **Apply** iptables rules to redirect NTP traffic on all LAN interfaces.

* * *

✅ How to Verify
---------------

### 1\. Check Time Sources

Run:

    chronyc sources -v

You should see:

*   `^*` – the **primary** server (likely Cloudflare)
*   `^+` – **backup** servers (TimeNL / PTB)
*   `^?` – temporarily unreachable (normal during startup)

### 2\. Verify NTS Encryption

Run:

    sudo chronyc authdata

Look at the **Cookies** column. A value **\> 0** (e.g., `8`) means NTS is **active**.  
If it’s **0**, the handshake failed – but the script will retry.

### 3\. Confirm Firewall Rules

    sudo iptables -t nat -L PREROUTING

You should see a `REDIRECT` rule for NTP (port 123) on your LAN interfaces.

* * *

🔄 What About Updates & Persistence?
------------------------------------

*   **Boot persistence:** The script is placed in `post_main.d` – it runs **every boot**.
*   **Daily cron job:** The script **automatically** adds a cron entry (`0 4 * * * root /path/to/script.sh`) to the **system crontab** (`/etc/crontab`). This means it runs **as root** and has full permissions to restart services and apply firewall rules.
*   **Health checks:** Every script run (boot, cron, manual) performs a **lightweight health check** – it verifies that Chrony is running and has at least one source. If Chrony is missing or dead, it restarts it (up to 3 times).

* * *

🛠️ Technical Details & Caveats
-------------------------------

### Hosts File Fix

Firewalla’s sandbox often blocks the `_chrony` user from reading system DNS. To bypass this, the script **hardcodes** the NTS server IPs into `/etc/hosts`.  
After running, your `/etc/hosts` will include:

    162.159.200.1    time.cloudflare.com
    94.198.159.15    ntppool1.time.nl
    192.53.103.108   ptbtime1.ptb.de
    3.134.129.152    ohio.time.system76.com
    52.203.218.175   virginia.time.system76.com

### Why 5 Servers?

We moved beyond the original "Holy Trinity" to a 5-server quorum to ensure better geographic diversity and failover reliability. Most NTS experts recommend at least 4 servers but no more than 10.As this protocol is less well adopted than NTP, the server ecosystem isn't as mature as NTP. The five I picked are:

*   Cloudflare – Global Anycast
*   TimeNL & PTB – European government-backed stability
*   System76 (Ohio & Virginia) – Low-latency US regional redundancy

**Limitation:** If these IPs change (rare), you’ll need to update them in the script and `/etc/hosts` manually.

### Auto‑Detection of Interfaces & Subnets

The script automatically discovers:

*   All **bridge** interfaces (`br0`, `br1`, …)
*   Physical interfaces (if no bridges) – excluding WAN (`wan`, `ppp`, `tun`, `wg`, `vpn`)
*   For each interface, it extracts the **precise CIDR** (e.g., `192.168.1.0/24`) and adds `allow` lines in `chrony.conf`.

This means **you don’t need to manually edit any interface or subnet settings** – it Just Works.

### 🛠 Customizing Your Time Servers

If you want to use different NTS servers (e.g., to prioritize servers closer to your specific geography), you only need to update two places in the script:

1.  **`chrony.conf`**: Update the `server` lines.
2.  **`/etc/hosts`**: Update the corresponding IP address mappings so the script can resolve them during the boot-up bootstrap phase.

**Tip:** You can find a list of reliable NTS-capable servers at [this Github repo](https://github.com/jauderho/nts-servers).

### Cron & Permissions

The script adds the cron job to `/etc/crontab` with the **user field explicitly set to `root`** – so the command runs with full privileges. You do **not** need to prepend `sudo` inside the cron job.

* * *

❌ Uninstall / Revert to Stock
-----------------------------

If you want to remove Chrony and go back to Firewalla’s default time service, follow these steps **exactly**.

### Step 1: Remove the Persistence Script

    sudo rm /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh

### Step 2: Delete the Cron Entry

    sudo sed -i '/# Chrony NTS Service/d' /etc/crontab
    sudo sed -i '/install_and_enforce_chrony.sh/d' /etc/crontab

### Step 3: Clean Up `/etc/hosts`

    sudo sed -i '/time.cloudflare.com/d' /etc/hosts
    sudo sed -i '/ntppool1.time.nl/d' /etc/hosts
    sudo sed -i '/ptbtime1.ptb.de/d' /etc/hosts
    sudo sed -i '/time.system76.com/d' /etc/hosts

### Step 4: Remove Chrony

    unalias apt
    unalias apt-get
    sudo apt-get remove --purge -y chrony

### Step 5: Restore Default Time Service

Firewalla uses `systemd-timesyncd` by default:

    sudo apt-get update
    sudo apt install systemd-timesyncd -y
    sudo systemctl unmask systemd-timesyncd
    sudo systemctl enable systemd-timesyncd
    sudo systemctl start systemd-timesyncd

### Step 6: Reboot (Mandatory)

    sudo reboot

A reboot is required to flush the manual `iptables` rules and let Firewalla regain full control.

* * *

🧪 Final Notes
--------------

*   The script is designed to be **low‑risk** and **revertible** – it never removes packages, never holds them, and only masks services.
*   It uses **full command paths** (e.g., `/usr/bin/apt-get`) to bypass Firewalla aliases – no surprises.
*   The cron job runs daily at **4 AM** – well after Firewalla’s typical update window, so any changes are quickly corrected.

* * *

🙏 Credits & Community
----------------------

This project was built with input from the Firewalla community. If you have improvements or find issues, please open an issue or pull request – contributions are welcome!

**Stay secure, stay synced.** 🚀

_Last updated: June 2026_
