# Messiah-University-CCDC
A repository holding scripts utilized within the Mid-Atlantic Collegate Cyber Defense Competition

---
## Commands:

`wget https://raw.githubusercontent.com/mdevitoii/Messiah-University-CCDC/refs/heads/main/splunk-forwarder-setup.sh`

# CCDC Monitoring Scripts

Two cronjob scripts to help detect red team activity during competition.

---

## Scripts

| Script | Purpose |
|---|---|
| `user_monitor.sh` | Detects new/deleted accounts, password changes, and logins |
| `integrity_check.sh` | Detects modifications to critical config files |

---

## Setup

```bash
# Copy scripts to a permanent location
sudo mkdir -p /opt/ccdc
sudo cp user_monitor.sh integrity_check.sh /opt/ccdc/
sudo chmod +x /opt/ccdc/*.sh

# Create log directory
sudo mkdir -p /var/lib/ccdc /var/log

# Add both scripts to root's crontab (runs every 5 minutes)
sudo crontab -e
```

Add these lines to the crontab:

```
*/5 * * * * /opt/ccdc/user_monitor.sh
*/5 * * * * /opt/ccdc/integrity_check.sh
```

---

## integrity_check.sh

Hashes important config files and alerts if any of them change.

**First run** — automatically creates a hash baseline. No action needed.

**After hardening** — once you've finished locking down the system, reset the baseline so your secure state is the new normal:

```bash
sudo /opt/ccdc/integrity_check.sh --reset
```

You'll be prompted to confirm. The old baseline is automatically backed up.

**See which files are being monitored:**

```bash
sudo /opt/ccdc/integrity_check.sh --list
```

Files marked `[ABSENT]` don't exist on this system and are safely ignored.

---

## user_monitor.sh

Monitors `/etc/passwd`, `/etc/shadow`, `/etc/group`, and `/etc/sudoers` for changes. Also logs active sessions and recent logins.

**No setup needed** — snapshots are created automatically on first run.

---

## Viewing Alerts

All alerts from both scripts are written to:

```
/var/log/ccdc_alerts.log
```

Watch it live during the competition:

```bash
sudo tail -f /var/log/ccdc_alerts.log
```

Full logs (including OK checks) are at:

```
/var/log/ccdc_user_monitor.log
/var/log/ccdc_integrity.log
```

---

## What Gets Alerted

**user_monitor.sh**
- New user account created
- User account deleted
- Password changed
- Any account with UID 0 (root-equivalent) that isn't `root`
- `/etc/sudoers` modified
- Successful SSH logins
- Brute force attempts (10+ failed logins)

**integrity_check.sh**
- Config file modified (shows old and new hash)
- Config file deleted
