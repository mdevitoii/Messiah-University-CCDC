#!/bin/bash
# ============================================================
# CCDC - Config File Integrity Checker
# Cronjob:  */5 * * * * /opt/ccdc/integrity_check.sh
# Reset:    /opt/ccdc/integrity_check.sh --reset
# ============================================================

# --- Configuration ---
STATE_DIR="/var/lib/ccdc"
HASH_DB="$STATE_DIR/integrity_hashes.db"
LOG_FILE="/var/log/ccdc_integrity.log"
ALERT_LOG="/var/log/ccdc_alerts.log"

# Optional: set to an email address to receive alerts (requires mailutils/sendmail)
ALERT_EMAIL=""

# --- Files to monitor ---
# Add or remove paths as needed for your environment
MONITORED_FILES=(
    # Core system auth
    "/etc/passwd"
    "/etc/shadow"
    "/etc/group"
    "/etc/gshadow"
    "/etc/sudoers"
    "/etc/sudoers.d"

    # SSH
    "/etc/ssh/sshd_config"
    "/root/.ssh/authorized_keys"

    # Network
    "/etc/hosts"
    "/etc/resolv.conf"
    "/etc/hosts.allow"
    "/etc/hosts.deny"
    "/etc/network/interfaces"
    "/etc/sysconfig/network-scripts"

    # Firewall
    "/etc/iptables/rules.v4"
    "/etc/iptables/rules.v6"
    "/etc/nftables.conf"
    "/etc/firewalld/firewalld.conf"

    # Web servers
    "/etc/apache2/apache2.conf"
    "/etc/apache2/sites-enabled"
    "/etc/nginx/nginx.conf"
    "/etc/nginx/sites-enabled"

    # DNS
    "/etc/named.conf"
    "/var/named"
    "/etc/bind/named.conf"

    # Mail
    "/etc/postfix/main.cf"
    "/etc/postfix/master.cf"

    # FTP
    "/etc/vsftpd.conf"
    "/etc/vsftpd/vsftpd.conf"

    # PAM (authentication stack)
    "/etc/pam.d/sshd"
    "/etc/pam.d/login"
    "/etc/pam.d/su"
    "/etc/pam.d/sudo"

    # System startup / services
    "/etc/rc.local"
    "/etc/crontab"
    "/etc/cron.d"
    "/var/spool/cron"

    # Sysctl / kernel params
    "/etc/sysctl.conf"
    "/etc/sysctl.d"
)

# ============================================================
# Helper functions
# ============================================================
mkdir -p "$STATE_DIR"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

alert() {
    echo "[$TIMESTAMP] [ALERT] $1" | tee -a "$LOG_FILE" | tee -a "$ALERT_LOG"
    if [ -n "$ALERT_EMAIL" ]; then
        echo "$1" | mail -s "[CCDC ALERT] Integrity Check: $1" "$ALERT_EMAIL" 2>/dev/null
    fi
}

# Hash a file or directory recursively
compute_hash() {
    local target="$1"
    if [ -d "$target" ]; then
        # For directories, hash all files within recursively
        find "$target" -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
    elif [ -f "$target" ]; then
        sha256sum "$target" 2>/dev/null | awk '{print $1}'
    else
        echo "NOT_FOUND"
    fi
}

# Sanitize a path to use as a key in the hash DB
path_to_key() {
    echo "$1" | sed 's|/|_|g'
}

# ============================================================
# MODE: --reset  (rebuild the hash database)
# ============================================================
if [[ "$1" == "--reset" ]]; then
    echo "============================================"
    echo " CCDC Integrity Check - RESET MODE"
    echo "============================================"
    echo ""
    echo "This will re-hash all monitored files and"
    echo "treat the CURRENT state as the new baseline."
    echo ""
    read -rp "Are you sure you want to reset all hashes? [yes/N]: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Reset cancelled."
        exit 0
    fi

    # Backup the old DB if it exists
    if [ -f "$HASH_DB" ]; then
        BACKUP="$HASH_DB.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$HASH_DB" "$BACKUP"
        echo "Old hash DB backed up to: $BACKUP"
    fi

    # Wipe and rebuild
    > "$HASH_DB"
    echo ""
    echo "Re-hashing monitored files..."
    SKIPPED=0
    HASHED=0
    for target in "${MONITORED_FILES[@]}"; do
        KEY=$(path_to_key "$target")
        HASH=$(compute_hash "$target")
        if [ "$HASH" == "NOT_FOUND" ]; then
            echo "  [SKIP]   $target (not found on this system)"
            ((SKIPPED++))
        else
            echo "  [HASHED] $target"
            echo "$KEY=$HASH" >> "$HASH_DB"
            ((HASHED++))
        fi
    done

    echo ""
    echo "Done. $HASHED files hashed, $SKIPPED skipped."
    echo "New baseline saved to: $HASH_DB"
    log "Hash database RESET by user. $HASHED files hashed."
    exit 0
fi

# ============================================================
# MODE: --list  (show all monitored files and current status)
# ============================================================
if [[ "$1" == "--list" ]]; then
    echo "============================================"
    echo " CCDC Integrity Check - Monitored Files"
    echo "============================================"
    for target in "${MONITORED_FILES[@]}"; do
        if [ -e "$target" ]; then
            echo "  [EXISTS] $target"
        else
            echo "  [ABSENT] $target"
        fi
    done
    exit 0
fi

# ============================================================
# MODE: Normal cronjob check
# ============================================================
log "--- Starting integrity check ---"

# If no hash DB exists yet, create one automatically
if [ ! -f "$HASH_DB" ]; then
    log "No hash database found. Creating initial baseline..."
    for target in "${MONITORED_FILES[@]}"; do
        KEY=$(path_to_key "$target")
        HASH=$(compute_hash "$target")
        if [ "$HASH" != "NOT_FOUND" ]; then
            echo "$KEY=$HASH" >> "$HASH_DB"
        fi
    done
    log "Baseline created with $(wc -l < "$HASH_DB") entries. Run again to start detecting changes."
    exit 0
fi

# --- Check each monitored file against stored hash ---
CHANGES=0
MISSING=0

for target in "${MONITORED_FILES[@]}"; do
    KEY=$(path_to_key "$target")
    STORED_HASH=$(grep "^$KEY=" "$HASH_DB" 2>/dev/null | cut -d'=' -f2-)

    # File wasn't in DB at all (newly added to monitor list)
    if [ -z "$STORED_HASH" ]; then
        CURRENT_HASH=$(compute_hash "$target")
        if [ "$CURRENT_HASH" != "NOT_FOUND" ]; then
            log "NEW ENTRY: $target (adding to DB)"
            echo "$KEY=$CURRENT_HASH" >> "$HASH_DB"
        fi
        continue
    fi

    # File was tracked but now missing
    if [ ! -e "$target" ]; then
        if [ "$STORED_HASH" != "NOT_FOUND" ]; then
            alert "FILE DELETED or MISSING: $target"
            ((MISSING++))
            # Update DB to reflect it's gone now
            sed -i "s|^$KEY=.*|$KEY=NOT_FOUND|" "$HASH_DB"
        fi
        continue
    fi

    # File exists — compare hashes
    CURRENT_HASH=$(compute_hash "$target")
    if [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
        alert "INTEGRITY VIOLATION: $target has been MODIFIED!"
        log "  Stored:  $STORED_HASH"
        log "  Current: $CURRENT_HASH"
        ((CHANGES++))

        # Update DB with new hash so we don't re-alert every run
        # Comment out the line below if you want repeated alerts until manual reset
        sed -i "s|^$KEY=.*|$KEY=$CURRENT_HASH|" "$HASH_DB"
    else
        log "OK: $target"
    fi
done

# ============================================================
# Summary
# ============================================================
if [ "$CHANGES" -gt 0 ] || [ "$MISSING" -gt 0 ]; then
    alert "Integrity check complete: $CHANGES file(s) modified, $MISSING file(s) missing."
else
    log "Integrity check complete: All monitored files OK."
fi

log "--- Integrity check done ---"
