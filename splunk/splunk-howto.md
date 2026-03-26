# Splunk Universal Forwarder Setup Script

Automated setup script for installing and configuring a Splunk Universal Forwarder on **Ubuntu 24.04** or **Fedora 42**.

---

## Prerequisites

- A Splunk Universal Forwarder `.deb` (Ubuntu) or `.rpm` (Fedora) package downloaded to the server
  - Download from: https://www.splunk.com/en_us/download/universal-forwarder.html
- A running Splunk indexer with receiving enabled on port 9997
- Root/sudo access on the target machine

---

## Usage

```bash
chmod +x splunk_forwarder_setup.sh
sudo ./splunk_forwarder_setup.sh
```

The script will prompt you for:

1. **OS selection** — Ubuntu 24.04 or Fedora 42
2. **Indexer IP** — IP address of your Splunk indexer
3. **Indexer port** — defaults to 9997
4. **Package path** — full path to the `.deb` or `.rpm` file on this machine
5. **Admin password** — password for Splunk's internal admin account (min. 8 characters)

---

## What the Script Does

1. Removes any existing Splunk forwarder installation
2. Installs the forwarder from the package you provide
3. Creates a dedicated `splunk` system user
4. Initializes the Splunk admin account with the password you set
5. Enables the forwarder as a systemd service (auto-starts on reboot)
6. Configures forwarding to your indexer
7. Sets up monitors for system, auth, and kernel logs
8. Verifies the connection to the indexer

---

## Log Files Monitored

| Log | Ubuntu | Fedora |
|-----|--------|--------|
| System | `/var/log/syslog` | `/var/log/messages` |
| Auth | `/var/log/auth.log` | `/var/log/secure` |
| Kernel | `/var/log/kern.log` | `/var/log/kern.log` |

---

## Verifying It Works

After the script completes, log into your Splunk web UI and search:

```
index=main host=<this-machine-hostname>
```

You should see events arriving within a minute or two.

---

## Troubleshooting

| Command | Purpose |
|---------|---------|
| `systemctl status SplunkForwarder` | Check if the service is running |
| `ss -tnp \| grep 9997` | Verify TCP connection to indexer |
| `sudo tail -f /opt/splunkforwarder/var/log/splunk/splunkd.log` | View Splunk logs |
| `sudo cat /var/log/splunk_forwarder_setup.log` | View setup log |
