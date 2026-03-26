#!/bin/bash
# ============================================================
# CCDC - User Account & Login Monitor
# Cronjob: */5 * * * * /opt/ccdc/user_monitor.sh
# ============================================================

# --- Configuration ---
STATE_DIR="/var/lib/ccdc"
PASSWD_SNAPSHOT="$STATE_DIR/passwd.snapshot"
SHADOW_SNAPSHOT="$STATE_DIR/shadow.snapshot"
GROUP_SNAPSHOT="$STATE_DIR/group.snapshot"
LOG_FILE="/var/log/ccdc_user_monitor.log"
ALERT_LOG="/var/log/ccdc_alerts.log"

# Optional: set to an email address to receive alerts (requires mailutils/sendmail)
ALERT_EMAIL=""

# Minimum UID to track (ignore system accounts below this)
MIN_UID=1000

# --- Setup ---
mkdir -p "$STATE_DIR"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

alert() {
    echo "[$TIMESTAMP] [ALERT] $1" | tee -a "$LOG_FILE" | tee -a "$ALERT_LOG"
    if [ -n "$ALERT_EMAIL" ]; then
        echo "$1" | mail -s "[CCDC ALERT] User Monitor: $1" "$ALERT_EMAIL" 2>/dev/null
    fi
}

# ============================================================
# SECTION 1: Initialize snapshots if they don't exist
# ============================================================
if [ ! -f "$PASSWD_SNAPSHOT" ]; then
    log "Initializing passwd snapshot."
    cp /etc/passwd "$PASSWD_SNAPSHOT"
fi

if [ ! -f "$SHADOW_SNAPSHOT" ]; then
    log "Initializing shadow snapshot."
    cp /etc/shadow "$SHADOW_SNAPSHOT"
fi

if [ ! -f "$GROUP_SNAPSHOT" ]; then
    log "Initializing group snapshot."
    cp /etc/group "$GROUP_SNAPSHOT"
fi

# ============================================================
# SECTION 2: Check for new or deleted user accounts (/etc/passwd)
# ============================================================
log "--- Checking /etc/passwd for changes ---"

NEW_USERS=$(diff "$PASSWD_SNAPSHOT" /etc/passwd | grep "^>" | cut -d: -f1 | sed 's/^> //')
DEL_USERS=$(diff "$PASSWD_SNAPSHOT" /etc/passwd | grep "^<" | cut -d: -f1 | sed 's/^< //')

if [ -n "$NEW_USERS" ]; then
    while IFS= read -r line; do
        USERNAME=$(echo "$line" | cut -d: -f1)
        UID_VAL=$(echo "$line" | cut -d: -f3)
        SHELL=$(echo "$line" | cut -d: -f7)
        alert "NEW USER ADDED: username='$USERNAME' uid=$UID_VAL shell=$SHELL"
    done < <(diff "$PASSWD_SNAPSHOT" /etc/passwd | grep "^>" | sed 's/^> //')
fi

if [ -n "$DEL_USERS" ]; then
    while IFS= read -r line; do
        USERNAME=$(echo "$line" | cut -d: -f1)
        alert "USER DELETED: username='$USERNAME'"
    done < <(diff "$PASSWD_SNAPSHOT" /etc/passwd | grep "^<" | sed 's/^< //')
fi

# Check for UID 0 (root-equivalent) accounts
ROOT_EQUIV=$(awk -F: '($3 == 0) {print $1}' /etc/passwd | grep -v "^root$")
if [ -n "$ROOT_EQUIV" ]; then
    alert "ROOT-EQUIVALENT UID=0 ACCOUNT DETECTED: $ROOT_EQUIV"
fi

# Update snapshot
cp /etc/passwd "$PASSWD_SNAPSHOT"

# ============================================================
# SECTION 3: Check for password changes (/etc/shadow)
# ============================================================
log "--- Checking /etc/shadow for changes ---"

SHADOW_DIFF=$(diff "$SHADOW_SNAPSHOT" /etc/shadow)
if [ -n "$SHADOW_DIFF" ]; then
    CHANGED_USERS=$(diff "$SHADOW_SNAPSHOT" /etc/shadow | grep "^[<>]" | awk -F: '{print $1}' | sed 's/^[<>] //' | sort -u)
    while IFS= read -r user; do
        alert "PASSWORD CHANGED for user: $user"
    done <<< "$CHANGED_USERS"
    cp /etc/shadow "$SHADOW_SNAPSHOT"
fi

# ============================================================
# SECTION 4: Check for group changes (/etc/group)
# ============================================================
log "--- Checking /etc/group for changes ---"

GROUP_DIFF=$(diff "$GROUP_SNAPSHOT" /etc/group)
if [ -n "$GROUP_DIFF" ]; then
    NEW_GROUPS=$(diff "$GROUP_SNAPSHOT" /etc/group | grep "^>" | sed 's/^> //' | cut -d: -f1)
    DEL_GROUPS=$(diff "$GROUP_SNAPSHOT" /etc/group | grep "^<" | sed 's/^< //' | cut -d: -f1)
    MOD_GROUPS=$(diff "$GROUP_SNAPSHOT" /etc/group | grep "^[<>]" | sed 's/^[<>] //' | cut -d: -f1 | sort | uniq -d)

    [ -n "$NEW_GROUPS" ] && alert "NEW GROUP ADDED: $NEW_GROUPS"
    [ -n "$DEL_GROUPS" ] && alert "GROUP DELETED: $DEL_GROUPS"
    [ -n "$MOD_GROUPS" ] && alert "GROUP MODIFIED (membership change): $MOD_GROUPS"

    cp /etc/group "$GROUP_SNAPSHOT"
fi

# Check for users in the sudo/wheel group
SUDO_USERS=$(getent group sudo wheel 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | sort -u | xargs)
if [ -n "$SUDO_USERS" ]; then
    log "Current sudo/wheel group members: $SUDO_USERS"
fi

# ============================================================
# SECTION 5: Check for sudoers changes
# ============================================================
log "--- Checking sudoers ---"
SUDOERS_HASH_FILE="$STATE_DIR/sudoers.hash"
CURRENT_SUDOERS_HASH=$(md5sum /etc/sudoers 2>/dev/null | awk '{print $1}')

if [ -f "$SUDOERS_HASH_FILE" ]; then
    STORED_HASH=$(cat "$SUDOERS_HASH_FILE")
    if [ "$CURRENT_SUDOERS_HASH" != "$STORED_HASH" ]; then
        alert "/etc/sudoers HAS BEEN MODIFIED!"
    fi
fi
echo "$CURRENT_SUDOERS_HASH" > "$SUDOERS_HASH_FILE"

# ============================================================
# SECTION 6: Check active logins and recent auth activity
# ============================================================
log "--- Active logins ---"
LOGGED_IN=$(who)
if [ -n "$LOGGED_IN" ]; then
    log "Currently logged in users:"
    echo "$LOGGED_IN" | while IFS= read -r line; do
        log "  $line"
    done
else
    log "No users currently logged in."
fi

# ============================================================
# SECTION 7: Check recent logins from auth log
# ============================================================
log "--- Recent successful logins (last 10 minutes) ---"
SINCE=$(date --date='10 minutes ago' '+%b %e %H:%M' 2>/dev/null || date -v-10M '+%b %e %H:%M')

AUTH_LOG=""
for f in /var/log/auth.log /var/log/secure; do
    [ -f "$f" ] && AUTH_LOG="$f" && break
done

if [ -n "$AUTH_LOG" ]; then
    RECENT_LOGINS=$(grep "Accepted" "$AUTH_LOG" | awk -v since="$SINCE" '$0 >= since')
    if [ -n "$RECENT_LOGINS" ]; then
        log "Recent successful logins:"
        while IFS= read -r line; do
            log "  $line"
            # Alert on logins from unusual sources
            SRC_IP=$(echo "$line" | grep -oP 'from \K[\d.]+')
            USER=$(echo "$line" | grep -oP 'for \K\S+')
            alert "SUCCESSFUL LOGIN: user=$USER from=$SRC_IP"
        done <<< "$RECENT_LOGINS"
    fi

    # Check for failed login attempts
    FAILED=$(grep "Failed password\|authentication failure\|FAILED LOGIN" "$AUTH_LOG" | tail -20)
    if [ -n "$FAILED" ]; then
        FAIL_COUNT=$(echo "$FAILED" | wc -l)
        log "Recent failed login attempts (last 20): $FAIL_COUNT"
        # Alert if brute force threshold exceeded
        if [ "$FAIL_COUNT" -ge 10 ]; then
            alert "POSSIBLE BRUTE FORCE: $FAIL_COUNT failed login attempts detected"
        fi
    fi
fi

# ============================================================
# SECTION 8: last logins summary
# ============================================================
log "--- Last 10 logins (from 'last' command) ---"
last -n 10 --time-format iso 2>/dev/null | head -10 | while IFS= read -r line; do
    log "  $line"
done

log "--- User monitor check complete ---"
