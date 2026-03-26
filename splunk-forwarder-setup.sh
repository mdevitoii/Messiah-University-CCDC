#!/bin/bash
# =============================================================================
# Splunk Universal Forwarder - Automated Setup Script
# Supported OS: Ubuntu 24.04, Fedora 42
# =============================================================================

set -euo pipefail

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

# --- Constants ---------------------------------------------------------------
SPLUNK_HOME="/opt/splunkforwarder"
SPLUNK_BIN="$SPLUNK_HOME/bin/splunk"
SPLUNK_SERVICE="SplunkForwarder"
SPLUNK_USER="splunk"
INPUTS_CONF="$SPLUNK_HOME/etc/system/local/inputs.conf"
LOG_FILE="/var/log/splunk_forwarder_setup.log"

# --- Logging -----------------------------------------------------------------
log()    { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
header() { echo -e "\n${CYAN}==> $*${NC}" | tee -a "$LOG_FILE"; }

# --- Root check --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
fi

# =============================================================================
# OS SELECTION
# =============================================================================
# The user selects their OS manually. This determines which package manager
# to use (dpkg vs rpm), which log group to add the splunk user to
# (adm vs systemd-journal), and which log files to monitor (Ubuntu and Fedora
# use different filenames for the same logs).
# =============================================================================
header "Operating System Selection"
echo ""
echo "  Which OS is this script running on?"
echo "  1) Ubuntu 24.04"
echo "  2) Fedora 42"
echo ""

while true; do
    read -rp "Enter selection [1 or 2]: " OS_CHOICE
    case "$OS_CHOICE" in
        1)
            ID="ubuntu"
            OS_FAMILY="debian"
            PKG_EXTENSION=".deb"
            # adm group grants read access to /var/log on Ubuntu/Debian
            LOG_GROUP="adm"
            # Ubuntu log file paths
            SYSLOG_PATH="/var/log/syslog"
            AUTHLOG_PATH="/var/log/auth.log"
            KERNLOG_PATH="/var/log/kern.log"
            log "OS selected: Ubuntu 24.04"
            break
            ;;
        2)
            ID="fedora"
            OS_FAMILY="rhel"
            PKG_EXTENSION=".rpm"
            # systemd-journal group grants read access to /var/log/journal on Fedora/RHEL.
            # The adm group does not exist by default on Fedora.
            LOG_GROUP="systemd-journal"
            # Fedora log file paths (Fedora uses 'messages' instead of 'syslog',
            # and 'secure' instead of 'auth.log')
            SYSLOG_PATH="/var/log/messages"
            AUTHLOG_PATH="/var/log/secure"
            KERNLOG_PATH="/var/log/kern.log"
            log "OS selected: Fedora 42"
            break
            ;;
        *)
            warn "Invalid selection. Please enter 1 for Ubuntu or 2 for Fedora."
            ;;
    esac
done

log "OS family: $OS_FAMILY | Package type: $PKG_EXTENSION | Log group: $LOG_GROUP"

# =============================================================================
# STEP 0: Collect inputs
# =============================================================================
header "Splunk Universal Forwarder Setup"
echo ""

read -rp "Enter Splunk Indexer IP address: " INDEXER_IP
[[ -z "$INDEXER_IP" ]] && error "Indexer IP cannot be empty."

read -rp "Enter Splunk Indexer receiving port [default: 9997]: " INDEXER_PORT
INDEXER_PORT="${INDEXER_PORT:-9997}"

# Prompt for the package path and validate it matches the expected extension
# for the detected OS (.deb for Ubuntu, .rpm for Fedora)
while true; do
    read -rp "Enter full path to the Splunk forwarder ${PKG_EXTENSION} package: " SPLUNK_PKG_PATH
    if [[ -z "$SPLUNK_PKG_PATH" ]]; then
        warn "Package path cannot be empty."
    elif [[ ! -f "$SPLUNK_PKG_PATH" ]]; then
        warn "File not found: $SPLUNK_PKG_PATH — please check the path and try again."
    elif [[ "$SPLUNK_PKG_PATH" != *"$PKG_EXTENSION" ]]; then
        warn "File does not appear to be a ${PKG_EXTENSION} package: $SPLUNK_PKG_PATH"
    else
        log "Package found: $SPLUNK_PKG_PATH"
        break
    fi
done

while true; do
    read -rsp "Set Splunk admin password for this forwarder: " ADMIN_PASSWORD
    echo ""
    read -rsp "Confirm password: " ADMIN_PASSWORD_CONFIRM
    echo ""
    if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
        break
    else
        warn "Passwords do not match. Please try again."
    fi
done

[[ ${#ADMIN_PASSWORD} -lt 8 ]] && error "Password must be at least 8 characters."

log "Configuration collected. Starting setup..."
log "Indexer target: ${INDEXER_IP}:${INDEXER_PORT}"

# =============================================================================
# STEP 1: Uninstall existing Splunk forwarder if present
# =============================================================================
# Checks for an existing installation using the appropriate package manager
# for the detected OS, then removes it cleanly before reinstalling.
# =============================================================================
header "Checking for existing Splunk installation..."

EXISTING_INSTALL=false
if [[ "$OS_FAMILY" == "debian" ]] && dpkg -l splunkforwarder &>/dev/null; then
    EXISTING_INSTALL=true
elif [[ "$OS_FAMILY" == "rhel" ]] && rpm -q splunkforwarder &>/dev/null; then
    EXISTING_INSTALL=true
elif [[ -d "$SPLUNK_HOME" ]]; then
    EXISTING_INSTALL=true
fi

if [[ "$EXISTING_INSTALL" == true ]]; then
    warn "Existing Splunk installation detected. Reinstalling from scratch..."

    if systemctl is-active --quiet "$SPLUNK_SERVICE" 2>/dev/null; then
        log "Stopping $SPLUNK_SERVICE..."
        systemctl stop "$SPLUNK_SERVICE" || true
    fi

    if systemctl is-enabled --quiet "$SPLUNK_SERVICE" 2>/dev/null; then
        log "Disabling $SPLUNK_SERVICE..."
        systemctl disable "$SPLUNK_SERVICE" || true
    fi

    rm -f /etc/systemd/system/SplunkForwarder.service
    systemctl daemon-reload

    if [[ "$OS_FAMILY" == "debian" ]] && dpkg -l splunkforwarder &>/dev/null; then
        log "Purging splunkforwarder package via dpkg..."
        dpkg --purge splunkforwarder || true
    elif [[ "$OS_FAMILY" == "rhel" ]] && rpm -q splunkforwarder &>/dev/null; then
        log "Removing splunkforwarder package via rpm..."
        rpm -e splunkforwarder || true
    fi

    if [[ -d "$SPLUNK_HOME" ]]; then
        log "Removing leftover directory $SPLUNK_HOME..."
        rm -rf "$SPLUNK_HOME"
    fi

    log "Existing installation removed."
else
    log "No existing installation found. Proceeding with fresh install."
fi

# =============================================================================
# STEP 2: Install package
# =============================================================================
# Installs the Splunk forwarder package using the appropriate package manager.
# dpkg is used on Ubuntu/Debian; rpm is used on Fedora/RHEL.
# =============================================================================
header "Installing Splunk Universal Forwarder from: ${SPLUNK_PKG_PATH}..."

if [[ "$OS_FAMILY" == "debian" ]]; then
    dpkg -i "$SPLUNK_PKG_PATH" \
        || error "dpkg installation failed. Verify the package is a valid Splunk Universal Forwarder .deb for amd64."
elif [[ "$OS_FAMILY" == "rhel" ]]; then
    rpm -ivh "$SPLUNK_PKG_PATH" \
        || error "rpm installation failed. Verify the package is a valid Splunk Universal Forwarder .rpm for x86_64."
fi

log "Package installed successfully."

# =============================================================================
# STEP 3: Create splunk system user and fix ownership
# =============================================================================
# Creates a dedicated low-privilege 'splunk' system user to run the forwarder.
# Running Splunk as root is a security risk and is not recommended.
#
# The splunk user is also added to the log-reading group for the detected OS:
#   - Ubuntu: 'adm' group           — grants read access to /var/log files
#   - Fedora: 'systemd-journal' group — grants read access to journald logs
# Without this, Splunk cannot read the log files we configure it to monitor.
# =============================================================================
header "Configuring splunk user..."

if ! id "$SPLUNK_USER" &>/dev/null; then
    log "Creating system user '$SPLUNK_USER'..."
    useradd -m -r "$SPLUNK_USER"
else
    log "User '$SPLUNK_USER' already exists."
fi

if getent group "$LOG_GROUP" &>/dev/null; then
    usermod -aG "$LOG_GROUP" "$SPLUNK_USER"
    log "Added '$SPLUNK_USER' to '$LOG_GROUP' group (required for /var/log read access on $ID)."
else
    warn "Group '$LOG_GROUP' not found — splunk may not be able to read log files."
fi

chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"
log "Ownership of $SPLUNK_HOME set to $SPLUNK_USER."

# =============================================================================
# STEP 4: Seed admin credentials via user-seed.conf
# =============================================================================
# Splunk reads user-seed.conf on first boot to create the admin user. We write
# this file before starting Splunk so the password is set correctly from the
# start. The file is automatically deleted by Splunk after it is consumed.
# =============================================================================
header "Seeding admin credentials..."

mkdir -p "$SPLUNK_HOME/etc/system/local"

cat > "$SPLUNK_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = admin
PASSWORD = ${ADMIN_PASSWORD}
EOF

chown "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME/etc/system/local/user-seed.conf"
chmod 600 "$SPLUNK_HOME/etc/system/local/user-seed.conf"
log "user-seed.conf written."

# =============================================================================
# STEP 5: First boot - initialize Splunk and create admin user
# =============================================================================
# Splunk requires a first-time start to generate its internal config files,
# certificates, and the passwd file that stores user credentials.
# We pass --seed-passwd here so Splunk sets the admin password during this
# first boot rather than defaulting to 'changeme', which would lock us out
# of the CLI on subsequent steps.
# =============================================================================
header "First boot: initializing Splunk and creating admin user..."
log "Starting Splunk for the first time to generate internal config files and certificates..."
log "This may take up to 30 seconds — please be patient."
log "NOTE: Any 'Splunk username/password' prompts you see below are internal Splunk CLI"
log "      output and do NOT require any input from you. The script handles this automatically."

sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" start --accept-license --answer-yes --no-prompt --seed-passwd "${ADMIN_PASSWORD}" \
    || error "Splunk failed to start during first boot initialization.\nCheck $SPLUNK_HOME/var/log/splunk/splunkd.log for details."

log "First boot complete. Waiting for Splunk to finish initializing..."
log "(Giving Splunk 10 seconds to finish writing its configuration files...)"
sleep 10
log "Initialization wait complete."

# =============================================================================
# STEP 6: Validate admin user was created with the correct password
# =============================================================================
# After first boot, we verify two things:
#   1. The passwd file exists and contains an admin entry — confirming Splunk
#      successfully created the user during initialization.
#   2. We can authenticate with the password you provided — confirming the
#      --seed-passwd flag was picked up correctly. If Splunk ignored it and
#      fell back to 'changeme', this check will catch it and abort cleanly
#      rather than leaving the forwarder running with a default password.
# =============================================================================
header "Validating admin user creation..."
log "Checking that Splunk created its internal 'admin' user account during first boot."
log "NOTE: This is Splunk's own internal admin account — it is separate from any"
log "      Linux system user. It is only used to manage this Splunk forwarder locally."

PASSWD_FILE="$SPLUNK_HOME/etc/passwd"

# Check 1: passwd file must exist
log "Check 1/3: Verifying Splunk passwd file exists at $PASSWD_FILE..."
if [[ ! -f "$PASSWD_FILE" ]]; then
    error "Splunk passwd file not found at $PASSWD_FILE.\nSplunk did not complete initialization. Check $SPLUNK_HOME/var/log/splunk/splunkd.log for details."
fi
log "Check 1/3 passed: passwd file exists."

# Check 2: admin entry must be present
# Note: Splunk sometimes writes a leading colon in the passwd file (e.g. ":admin:...")
# The ^:* pattern handles both ":admin:" and "admin:" formats
log "Check 2/3: Verifying admin user entry exists in passwd file..."
if ! grep -q "^:*admin:" "$PASSWD_FILE"; then
    error "Admin user entry not found in $PASSWD_FILE.\nSplunk started but did not create the admin user. Check $SPLUNK_HOME/var/log/splunk/splunkd.log for details."
fi
log "Check 2/3 passed: admin user entry found in passwd file."

# Check 3: confirm authentication works with the configured password
log "Check 3/3: Testing that the admin account accepts the password you provided..."
log "(This confirms Splunk picked up --seed-passwd correctly during initialization.)"
AUTH_TEST=$(sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" status -auth "admin:${ADMIN_PASSWORD}" 2>&1) || true
if echo "$AUTH_TEST" | grep -qi "failed\|invalid\|Login failed\|disabled"; then
    error "Admin user was created but authentication failed with the configured password.\nThis means --seed-passwd was not picked up during initialization.\nOutput: $AUTH_TEST\nCheck $SPLUNK_HOME/var/log/splunk/splunkd.log for details."
fi
log "Check 3/3 passed: authentication test successful."

log "All validation checks passed. Splunk admin user is correctly configured."

# =============================================================================
# STEP 7: Stop Splunk before enabling boot-start
# =============================================================================
log "Stopping Splunk before registering systemd boot-start service..."
sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" stop || true
sleep 3

# =============================================================================
# STEP 8: Enable systemd boot-start
# =============================================================================
# Registers the Splunk forwarder as a systemd service so it starts
# automatically on reboot. Uses the -systemd-managed 1 flag which is
# required on Ubuntu 24.04 and Fedora 42 since both use systemd natively.
# =============================================================================
header "Enabling systemd boot-start..."

"$SPLUNK_BIN" enable boot-start -systemd-managed 1 -user "$SPLUNK_USER" \
    || error "Failed to enable boot-start."

systemctl daemon-reload
systemctl enable "$SPLUNK_SERVICE" || error "Failed to enable $SPLUNK_SERVICE in systemd."
log "Boot-start enabled. Splunk will now start automatically on reboot."

# =============================================================================
# STEP 9: Configure forward server (outputs.conf)
# =============================================================================
# Tells the forwarder where to send log data. This points to the Splunk
# indexer you specified at the start of this script.
# =============================================================================
header "Configuring forward server: ${INDEXER_IP}:${INDEXER_PORT}..."

mkdir -p "$SPLUNK_HOME/etc/system/local"

cat > "$SPLUNK_HOME/etc/system/local/outputs.conf" <<EOF
[tcpout]
defaultGroup = primary_indexer

[tcpout:primary_indexer]
server = ${INDEXER_IP}:${INDEXER_PORT}
EOF

chown "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME/etc/system/local/outputs.conf"
log "outputs.conf written. Forwarder will send data to ${INDEXER_IP}:${INDEXER_PORT}."

# =============================================================================
# STEP 10: Configure log monitors (inputs.conf)
# =============================================================================
# Tells Splunk which log files to watch and forward to the indexer.
# Log file paths differ between Ubuntu and Fedora:
#   Ubuntu: /var/log/syslog, /var/log/auth.log, /var/log/kern.log
#   Fedora: /var/log/messages, /var/log/secure,  /var/log/kern.log
# The correct paths were set automatically during OS detection at the top
# of this script.
# =============================================================================
header "Configuring log monitors..."
log "OS-specific log paths for $ID:"
log "  System log : $SYSLOG_PATH"
log "  Auth log   : $AUTHLOG_PATH"
log "  Kernel log : $KERNLOG_PATH"

cat > "$INPUTS_CONF" <<EOF
[monitor://${SYSLOG_PATH}]
index = main
sourcetype = syslog

[monitor://${AUTHLOG_PATH}]
index = main
sourcetype = linux_secure

[monitor://${KERNLOG_PATH}]
index = main
sourcetype = linux_kern
EOF

chown "$SPLUNK_USER:$SPLUNK_USER" "$INPUTS_CONF"
log "inputs.conf written."

# =============================================================================
# STEP 11: Start the forwarder service
# =============================================================================
header "Starting SplunkForwarder service..."

systemctl start "$SPLUNK_SERVICE" || error "Failed to start $SPLUNK_SERVICE. Check: journalctl -u $SPLUNK_SERVICE"
sleep 5

if ! systemctl is-active --quiet "$SPLUNK_SERVICE"; then
    error "$SPLUNK_SERVICE failed to stay running. Check: journalctl -u $SPLUNK_SERVICE"
fi

log "SplunkForwarder is running."

# =============================================================================
# STEP 12: Verify TCP connection to indexer
# =============================================================================
header "Verifying TCP connection to indexer..."

sleep 5
CONNECTION=$(ss -tnp | grep ":${INDEXER_PORT}" || true)

if [[ -z "$CONNECTION" ]]; then
    warn "No active TCP connection to ${INDEXER_IP}:${INDEXER_PORT} detected yet."
    warn "This may resolve in a few seconds. To check manually run:"
    warn "  ss -tnp | grep ${INDEXER_PORT}"
    warn "Also verify port ${INDEXER_PORT} is open on the indexer and receiving is enabled."
else
    log "Active connection to indexer confirmed:"
    echo "$CONNECTION" | tee -a "$LOG_FILE"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Splunk Universal Forwarder setup complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  OS detected:   ${CYAN}${ID} ${VERSION_ID}${NC}"
echo -e "  Indexer:       ${CYAN}${INDEXER_IP}:${INDEXER_PORT}${NC}"
echo -e "  Monitors:      ${CYAN}${SYSLOG_PATH}, ${AUTHLOG_PATH}, ${KERNLOG_PATH}${NC}"
echo -e "  Service:       ${CYAN}systemctl status $SPLUNK_SERVICE${NC}"
echo -e "  Splunk logs:   ${CYAN}$SPLUNK_HOME/var/log/splunk/splunkd.log${NC}"
echo -e "  Setup log:     ${CYAN}$LOG_FILE${NC}"
echo ""
echo -e "  Verify data on indexer with:"
echo -e "  ${CYAN}index=main host=$(hostname)${NC}"
echo ""
