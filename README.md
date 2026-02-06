Firewalla NTS: Encrypted Time & Transparent Intercept
=====================================================

**Secure your network time with authenticated NTS (Network Time Security) and force all IoT devices to use it.**

* * *

⚠️ BIG DISCLAIMER (READ THIS FIRST)
-----------------------------------

*   **I DO NOT WORK FOR FIREWALLA.** This project is a community contribution and is NOT supported by Firewalla Inc.
*   **USE AT YOUR OWN RISK.** Modifying your router always carries risks. I am not responsible if your device malfunctions.
*   **NEVER RUN "APT UPGRADE".** When installing, this script only installs `chrony`. Do not attempt to upgrade the full system packages, as Firewalla uses a custom OS kernel. Upgrading generic Ubuntu packages over it will destabilize or brick your box.

* * *

🤔 Why replace the default NTP?
-------------------------------

By default, standard NTP (Network Time Protocol) sends time data in **unencrypted plain text**. Any hacker, ISP, or government agency on the path can inspect or spoof these packets (Man-in-the-Middle attacks).

This project replaces the default service with **Chrony**, configured to use **NTS (Network Time Security)**.

### The Benefits

1.  **Encryption:** Uses TLS to authenticate the time server. Your router cryptographically verifies that the time is coming from a trusted source (Cloudflare, Government Institutes) and has not been altered.
2.  **The "Force Field" (Intercept):** Many IoT devices (cameras, smart plugs, Alexa) have hardcoded, insecure time servers. This script uses firewall rules to transparently intercept _all_ NTP traffic on your LAN and force it through your secure Chrony stream. The devices don't know it's happening.
3.  **Robustness:** The script installs itself into Firewalla's persistence folder (`post_main.d`), meaning it will automatically repair and re-install itself after reboots or firmware updates.

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
2.  Create the script file:
    
        sudo nano /home/pi/.firewalla/config/post_main.d/install_and_enforce_chrony.sh
    
3.  Paste the contents of the script provided in this repo.
4.  Save and Exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

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

### The "Caveman Fix" (Hosts File)

Due to the secure sandbox Firewalla uses, the `_chrony` service user is often blocked from reading the system DNS settings. To bypass this reliable point of failure, this script **hardcodes** the IP addresses of the NTS servers into `/etc/hosts`.

**Why only 3 servers?** Secure NTS servers are still rare globally. We selected the "Holy Trinity" of stable, static IP providers:

*   **Cloudflare:** US/Global (Anycast)
*   **TimeNL:** Netherlands Government (Static IP)
*   **PTB:** German National Metrology Institute (Static IP)

**Limitation:** If these organizations change their physical IP addresses (rare), your sync will fail until you update the IP addresses in the script.
