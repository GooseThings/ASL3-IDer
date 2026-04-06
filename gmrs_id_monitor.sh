#!/bin/bash
# =============================================================================
# gmrs_id_monitor.sh
# GMRS FCC-Compliant Station ID Monitor for ASL3
# Node: 643931
#
# FCC 47 CFR § 95.1751 compliance:
#   - ID is transmitted following any transmission or series of transmissions
#   - ID is transmitted at least once every 15 minutes during ongoing activity
#   - No ID is sent during periods of complete inactivity
#
# Logic:
#   - Polls RPT_RXKEYED every 5 seconds via the Asterisk CLI
#   - Sets a flag when RX activity is detected
#   - If activity has occurred and 15 minutes have elapsed since the last ID,
#     plays the ID and resets the timer
#   - If the node goes idle (no RX for IDLE_TIMEOUT seconds), resets state
#     so the ID won't fire again until new activity begins
#
# Usage:
#   sudo bash gmrs_id_monitor.sh
#
# To run as a persistent service, see the systemd unit file comments at
# the bottom of this script.
# =============================================================================

# --- Configuration ---
NODE="643931"
ID_INTERVAL=900          # 15 minutes in seconds (FCC maximum)
POLL_INTERVAL=5          # How often to check RX status (seconds)
IDLE_TIMEOUT=120         # Seconds of silence before resetting activity flag
LOG_FILE="/var/log/gmrs_id_monitor.log"
MAX_LOG_SIZE=1048576     # Rotate log at 1MB

# --- Internal state ---
last_id_time=0           # Epoch time of last ID transmission
last_rx_time=0           # Epoch time of last RX activity detected
activity_since_last_id=0 # 1 = there has been RX activity since the last ID

# =============================================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"

    # Rotate log if too large
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "Log rotated."
    fi
}

play_id() {
    log "ACTION: Transmitting station ID on node $NODE"
    /usr/sbin/asterisk -rx "rpt fun $NODE *721" > /dev/null 2>&1
    last_id_time=$(date +%s)
    activity_since_last_id=0
}

get_rx_keyed() {
    # Query the node variables and extract RPT_RXKEYED value
    # Returns 1 if keyed, 0 if not, 255 on error
    local output
    output=$(/usr/sbin/asterisk -rx "rpt show variables $NODE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "255"
        return
    fi
    # Extract RPT_RXKEYED value from output line like: RPT_RXKEYED=1
    local val
    val=$(echo "$output" | grep -i "RPT_RXKEYED" | grep -oP '=\K[0-9]+' | head -1)
    if [ -z "$val" ]; then
        echo "0"
    else
        echo "$val"
    fi
}

# =============================================================================
# Main
# =============================================================================

log "=============================================="
log "GMRS ID Monitor starting for node $NODE"
log "ID interval: ${ID_INTERVAL}s (15 min)"
log "Poll interval: ${POLL_INTERVAL}s"
log "Idle reset timeout: ${IDLE_TIMEOUT}s"
log "=============================================="

# Initialize last_id_time to now so we don't fire immediately on startup
last_id_time=$(date +%s)

while true; do
    now=$(date +%s)
    rx_keyed=$(get_rx_keyed)

    if [ "$rx_keyed" = "255" ]; then
        log "WARNING: Could not query Asterisk. Is it running? Retrying in ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    # --- Detect RX activity ---
    if [ "$rx_keyed" = "1" ]; then
        last_rx_time=$now
        if [ "$activity_since_last_id" = "0" ]; then
            log "RX activity detected — ID timer is now active."
            activity_since_last_id=1
        fi
    fi

    # --- Check idle timeout: reset if no RX for IDLE_TIMEOUT seconds ---
    if [ "$activity_since_last_id" = "1" ] && [ "$last_rx_time" -gt 0 ]; then
        idle_seconds=$(( now - last_rx_time ))
        if [ "$idle_seconds" -ge "$IDLE_TIMEOUT" ]; then
            log "Node idle for ${idle_seconds}s — resetting activity flag. No ID needed."
            activity_since_last_id=0
            last_rx_time=0
            # Reset the ID timer so the 15-min clock starts fresh on next activity
            last_id_time=$now
        fi
    fi

    # --- Check if ID is due ---
    if [ "$activity_since_last_id" = "1" ]; then
        elapsed=$(( now - last_id_time ))
        if [ "$elapsed" -ge "$ID_INTERVAL" ]; then
            log "15 minutes elapsed since last ID (${elapsed}s). RX activity present."
            play_id
        fi
    fi

    sleep "$POLL_INTERVAL"
done
