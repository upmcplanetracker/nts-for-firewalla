Firewalla NTS: Encrypted Time & Transparent Intercept
=====================================================

**Secure your network time with authenticated NTS (Network Time Security) and force all devices on the network to use it via Firewalla's NTP Intercept feature.**

* * *

⚠️ BIG DISCLAIMER (READ THIS FIRST)
-----------------------------------

*   **I AM NOT AFFLIATED WITH FIREWALLA.** This project is a community contribution and is NOT supported by Firewalla Inc.
*   **USE AT YOUR OWN RISK.** Modifying your router always carries risks. I am not responsible if your device malfunctions. Know how to reflash it and have a reflash drive ready before proceeding.
*   **NEVER RUN "APT UPGRADE".** When installing, this script only installs `chrony`. Do not attempt to upgrade the full system packages, as Firewalla uses a custom OS kernel. Upgrading generic Ubuntu packages over it will destabilize or brick your box.
*   **I TESTED THIS ON A FIREWALLA GOLD PLUS.** I assume it should work on every other modern Firewalla router, but I do not know that for sure.  Addtionally I updated the Firewalla software to Ubuntu 22.04 using the newest image for my box on the Firewalla website, so while it probably will work on older versions (18.04, 20.04), I am not 100% certain.
*   **PLEASE READ THIS WHOLE README FILE TO KNOW WHAT YOU ARE GETTING INTO.** And how to get out of it if needed.
*   **THIS DOESN'T CHANGE THE FACT THAT FIREWALLA ONLY SUPPORTS NTP INTERCEPT.** All your network devices will need to still use NTP, not NTS, to stay in sync. This is important if you install Ubuntu 25.10 or newer as it defaults to Chrony/NTS, which will fail in syncing to the Firewalla if NTP intercept is on for that network. You will need to uninstall Chrony and install another NTP APT package to keep your Ubhntu device in sync, or turn off NTP intercept for the network that device is on so that your device's NTS request can reach the Internet.
*   **THIS CURRENTLY MAY ONLY WORK ON A NETWORK WITH 1 LAN ACTIVATED.** I haven't tested it in a multi-lan setup (yet).  

* * *

⚠️ Important Note on "NTP Intercept"
------------------------------------

Because this script applies its own manual firewall rules (`iptables`) every time the device boots, **the "NTP Intercept" slider in the Firewalla App may no longer reflect reality.**

Even if you turn the slider "OFF" in the app, this script will re-enable the interception rules the next time the device reboots. This is intentional design to ensure your network remains secure and transparently intercepted at all times.

* * *

Why replace the default NTP?
----------------------------

By default, standard NTP (Network Time Protocol) sends time data in **unencrypted plain text**. Any hacker, ISP, or government agency on the path can inspect or spoof these packets (Man-in-the-Middle attacks).

This project replaces the default service with **Chrony**, configured to use encrypted **NTS (Network Time Security)**.

### The Benefits

1.  **Encryption:** Uses TLS to authenticate the time server. Your router cryptographically verifies that the time is coming from a trusted source (Cloudflare, Government Institutes) and has not been altered.
2.  **The "Force Field" (Intercept):** Many IoT devices (cameras, smart plugs, Alexa) have hardcoded, insecure time servers. This script uses built-in Firewalla rules to transparently intercept _all_ NTP traffic on your LAN and force it through your secure Chrony stream. The devices don't know it's happening.
3.  **Robustness:** The script installs itself into Firewalla's persistence folder (`post_main.d`), meaning it will automatically repair and re-install itself after reboots (but probably not with firmware updates).

* * *

🚀 Installation
---------------

### Step 1: Prepare the Environment

Firewalla aliases the `apt` command to prevent accidental breakage. You must unalias it for your current session before you can do anything manually.

    unalias apt
    unalias apt-get

_Note: You will need to type this again if you log out and log back in._

### Step 2: Install the Script

1.  SSH into your Firewalla.
2.  Create the script file: (`vi` is the built in editor, but I use `nano` which I installed via `sudo apt install nano`)

    ```bash
    sudo mkdir -p /home/pi/.firewalla/config/post_main.d
    sudo nano /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh
    
4.  Paste the contents of the script provided in this repo.
5.  Using `ip a` from the Firewalla ssh prompt, find out what interfaces you are using/which networks you want NTS to work with networkwise on the firewalla.  Typically lan1 will be `br0`.  lan2 will be `br1`.
6.  Scroll down to section 5 of the script and change the interfaces to the ones you want to use.
7.  Save and Exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

### Step 3: Permission & Run

    chmod +x /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh
    sudo /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh

* * *

✅ How to Verify
---------------

### 1\. Check Time Sources

Run `chronyc sources -v`. You should see:

*   **`*`** (Asterisk): The Primary server (likely Cloudflare).
*   **`+`** (Plus): The Backup servers (TimeNL/PTB).
*   **`?`** (Question Mark): A server that is unreachable (normal during startup/internet hiccups).

### 2\. Verify Encryption (NTS)

Run `sudo chronyc authdata`.  
Look for the **Cookies** column. If you see a number greater than 0 (e.g., `8`), encryption is **ACTIVE**. If it is 0, the handshake failed.

* * *

🔧 Technical Details & Caveats
------------------------------

### Fix the Hosts File

Due to the secure sandbox Firewalla uses, the `_chrony` service user is often blocked from reading the system DNS settings. To bypass this reliable point of failure, this script **hardcodes** the IP addresses of the NTS servers into `/etc/hosts`.

**Why only 3 servers?** Secure NTS servers are still rare globally. We selected the "Holy Trinity" of stable, static IP providers:

*   **Cloudflare:** US/Global (Anycast)
*   **TimeNL:** Netherlands Government (Static IP)
*   **PTB:** German National Metrology Institute (Static IP)

**Limitation:** If these organizations change their physical IP addresses (rare), your sync will fail with that server until you update the IP addresses in the script.

* * *

❌ Uninstall / Revert to Stock
-----------------------------

If you want to remove Chrony and go back to the default Firewalla time settings, follow these steps exactly.

### Step 1: Delete the Persistence Script

This stops the rules from re-applying on the next boot.

    sudo rm /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh

### Step 2: Clean up /etc/hosts

Remove the hardcoded IP addresses we added.

    sudo sed -i '/time.cloudflare.com/d' /etc/hosts
    sudo sed -i '/ntppool1.time.nl/d' /etc/hosts
    sudo sed -i '/ptbtime1.ptb.de/d' /etc/hosts

### Step 3: Remove Chrony

Uninstall the package and its configurations.

    unalias apt
    unalias apt-get
    sudo apt-get remove --purge -y chrony

### Step 4: Restore Default Time Service

Firewalla uses `systemd-timesyncd` by default. We need to wake it back up.

    sudo apt-get update
    sudo apt install systemd-timesyncd -y
    sudo systemctl unmask systemd-timesyncd
    sudo systemctl enable systemd-timesyncd
    sudo systemctl start systemd-timesyncd

### Step 5: Reboot (Mandatory)

You must reboot to flush the manual `iptables` firewall rules from memory and let Firewalla take control again.
