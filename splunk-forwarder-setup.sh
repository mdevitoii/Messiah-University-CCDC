#!/bin/bash
# =============================================================================
# Splunk Universal Forwarder - Automated Setup Script
# Target OS: Ubuntu 24.04
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
# STEP 0: Collect inputs
# =============================================================================
header "Splunk Universal Forwarder Setup"
echo ""

read -rp "Enter Splunk Indexer IP address: " INDEXER_IP
[[ -z "$INDEXER_IP" ]] && error "Indexer IP cannot be empty."

read -rp "Enter Splunk Indexer receiving port [default: 9997]: " INDEXER_PORT
INDEXER_PORT="${INDEXER_PORT:-9997}"

while true; do
    read -rp "Enter full path to the Splunk forwarder .deb package: " SPLUNK_DEB_PATH
    if [[ -z "$SPLUNK_DEB_PATH" ]]; then
        warn "Package path cannot be empty."
    elif [[ ! -f "$SPLUNK_DEB_PATH" ]]; then
        warn "File not found: $SPLUNK_DEB_PATH — please check the path and try again."
    elif [[ "$SPLUNK_DEB_PATH" != *.deb ]]; then
        warn "File does not appear to be a .deb package: $SPLUNK_DEB_PATH"
    else
        log "Package found: $SPLUNK_DEB_PATH"
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
header "Checking for existing Splunk installation..."

if dpkg -l splunkforwarder &>/dev/null || [[ -d "$SPLUNK_HOME" ]]; then
    warn "Existing Splunk installation detected. Reinstalling from scratch..."

    # Stop service if running
    if systemctl is-active --quiet "$SPLUNK_SERVICE" 2>/dev/null; then
        log "Stopping $SPLUNK_SERVICE..."
        systemctl stop "$SPLUNK_SERVICE" || true
    fi

    if systemctl is-enabled --quiet "$SPLUNK_SERVICE" 2>/dev/null; then
        log "Disabling $SPLUNK_SERVICE..."
        systemctl disable "$SPLUNK_SERVICE" || true
    fi

    # Remove systemd unit file if present
    rm -f /etc/systemd/system/SplunkForwarder.service
    systemctl daemon-reload

    # Purge the package
    if dpkg -l splunkforwarder &>/dev/null; then
        log "Purging splunkforwarder package..."
        dpkg --purge splunkforwarder || true
    fi

    # Remove leftover directory
    if [[ -d "$SPLUNK_HOME" ]]; then
        log "Removing $SPLUNK_HOME..."
        rm -rf "$SPLUNK_HOME"
    fi

    log "Existing installation removed."
else
    log "No existing installation found. Proceeding with fresh install."
fi

# =============================================================================
# STEP 2: Install package
# =============================================================================
header "Installing Splunk Universal Forwarder from: ${SPLUNK_DEB_PATH}..."

dpkg -i "$SPLUNK_DEB_PATH" || error "dpkg installation failed. Verify the package is a valid Splunk Universal Forwarder .deb for amd64."
log "Package installed successfully."

# =============================================================================
# STEP 3: Create splunk system user and fix ownership
# =============================================================================
header "Configuring splunk user..."

if ! id "$SPLUNK_USER" &>/dev/null; then
    log "Creating system user '$SPLUNK_USER'..."
    useradd -m -r "$SPLUNK_USER"
else
    log "User '$SPLUNK_USER' already exists."
fi

# Add splunk user to adm group so it can read /var/log files
if getent group adm &>/dev/null; then
    usermod -aG adm "$SPLUNK_USER"
    log "Added '$SPLUNK_USER' to adm group (required for /var/log access)."
fi

chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"
log "Ownership of $SPLUNK_HOME set to $SPLUNK_USER."

# =============================================================================
# STEP 4: Seed admin credentials via user-seed.conf
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
# STEP 5: Initial start to trigger user creation
# =============================================================================
header "Starting Splunk to initialize admin user..."

sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" start --accept-license --answer-yes --no-prompt \
    || error "Splunk failed to start during initialization."

sleep 5

# =============================================================================
# STEP 6: Validate admin user was created correctly
# =============================================================================
header "Validating admin user creation..."

PASSWD_FILE="$SPLUNK_HOME/etc/passwd"

if [[ ! -f "$PASSWD_FILE" ]]; then
    error "Splunk passwd file not found at $PASSWD_FILE.\nUser initialization failed. Check $SPLUNK_HOME/var/log/splunk/splunkd.log for details."
fi

# Splunk sometimes writes a leading colon in the passwd file (e.g. ":admin:...")
# so we strip it before checking
if ! grep -q "^:*admin:" "$PASSWD_FILE"; then
    error "Admin user entry not found in $PASSWD_FILE.\nUser creation failed. Check $SPLUNK_HOME/var/log/splunk/splunkd.log for details."
fi

log "Admin user entry found in passwd file."

# If user-seed.conf was not picked up (Splunk falls back to default 'changeme'),
# force-set the password now using the add user command
log "Forcing admin password to configured value..."
sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" add user admin -password "${ADMIN_PASSWORD}" -role admin -force-change-pass false 2>&1 | tee -a "$LOG_FILE" || \
sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" edit user admin -password "${ADMIN_PASSWORD}" -role admin -auth "admin:changeme" 2>&1 | tee -a "$LOG_FILE" || \
    error "Failed to set admin password. Check $SPLUNK_HOME/var/log/splunk/splunkd.log for details."

# Verify authentication works with the configured password
AUTH_TEST=$(sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" status -auth "admin:${ADMIN_PASSWORD}" 2>&1) || true
if echo "$AUTH_TEST" | grep -qi "failed\|invalid\|Login failed"; then
    error "Authentication test failed after password set.\nOutput: $AUTH_TEST"
fi

log "Admin user validated and password confirmed successfully."

# =============================================================================
# STEP 7: Stop Splunk before enabling boot-start
# =============================================================================
sudo -u "$SPLUNK_USER" "$SPLUNK_BIN" stop || true
sleep 3

# =============================================================================
# STEP 8: Enable systemd boot-start
# =============================================================================
header "Enabling systemd boot-start..."

"$SPLUNK_BIN" enable boot-start -systemd-managed 1 -user "$SPLUNK_USER" \
    || error "Failed to enable boot-start."

systemctl daemon-reload
systemctl enable "$SPLUNK_SERVICE" || error "Failed to enable $SPLUNK_SERVICE in systemd."
log "Boot-start enabled."

# =============================================================================
# STEP 9: Configure forward server (outputs.conf)
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
log "outputs.conf written."

# =============================================================================
# STEP 10: Configure log monitors (inputs.conf)
# =============================================================================
header "Configuring log monitors..."

cat > "$INPUTS_CONF" <<EOF
[monitor:///var/log/syslog]
index = main
sourcetype = syslog

[monitor:///var/log/auth.log]
index = main
sourcetype = linux_secure

[monitor:///var/log/kern.log]
index = main
sourcetype = linux_kern
EOF

chown "$SPLUNK_USER:$SPLUNK_USER" "$INPUTS_CONF"
log "inputs.conf written with syslog, auth.log, and kern.log monitors."

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
echo -e "  Indexer:       ${CYAN}${INDEXER_IP}:${INDEXER_PORT}${NC}"
echo -e "  Monitors:      ${CYAN}/var/log/syslog, auth.log, kern.log${NC}"
echo -e "  Service:       ${CYAN}systemctl status $SPLUNK_SERVICE${NC}"
echo -e "  Splunk logs:   ${CYAN}$SPLUNK_HOME/var/log/splunk/splunkd.log${NC}"
echo -e "  Setup log:     ${CYAN}$LOG_FILE${NC}"
echo ""
echo -e "  Verify data on indexer with:"
echo -e "  ${CYAN}index=main host=$(hostname)${NC}"
echo ""
