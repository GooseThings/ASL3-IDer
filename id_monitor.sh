#!/bin/bash
# =============================================================================
# gid_monitor.sh
# FCC-Compliant Station ID Monitor for ASL3
# 
#
# FCC 47 CFR § 95.1751 compliance:
#   - ID fires after EVERY single transmission (or series of transmissions)
#   - ID fires at least once every 15 minutes during ongoing activity
#   - No ID is sent during periods of complete inactivity
#
# Logic:
#   - Polls RPT_RXKEYED every POLL_INTERVAL seconds
#   - When RX drops from 1 -> 0 (end of transmission), schedules a post-TX ID
#   - A short delay (POST_TX_DELAY) is waited before playing the ID, to allow
#     the repeater tail/hang time to finish before the CW plays
#   - Separately, if 15 minutes pass with ongoing activity, fires the ID
#   - If the node is idle for IDLE_TIMEOUT seconds, resets state entirely
# =============================================================================

# --- Configuration ---
NODE="643931"
ID_INTERVAL=900          # 15 minutes in seconds (FCC maximum interval)
POST_TX_DELAY=3          # Seconds to wait after RX drop before playing ID
                         # (allows repeater tail/hang time to clear)
POLL_INTERVAL=5          # How often to check RX status (seconds)
IDLE_TIMEOUT=300         # Seconds of silence before resetting state entirely
LOG_FILE="/var/log/gmrs_id_monitor.log"
MAX_LOG_SIZE=1048576     # Rotate log at 1MB

# --- Internal state ---
last_id_time=0           # Epoch time of last ID transmission
last_rx_time=0           # Epoch time of last RX activity
prev_rx_keyed=0          # RX state from previous poll cycle
id_pending=0             # 1 = a post-TX ID is scheduled (waiting POST_TX_DELAY)
id_pending_at=0          # Epoch time when the post-TX ID was scheduled
activity_seen=0          # 1 = there has been at least one TX since last ID

# =============================================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"

    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "Log rotated."
    fi
}

play_id() {
    log "ACTION: Transmitting station ID on node $NODE (reason: $1)"
    /usr/sbin/asterisk -rx "rpt fun $NODE *721" > /dev/null 2>&1
    last_id_time=$(date +%s)
    activity_seen=0
    id_pending=0
    id_pending_at=0
}

get_rx_keyed() {
    local output
    output=$(/usr/sbin/asterisk -rx "rpt show variables $NODE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "255"
        return
    fi
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
log "Post-TX ID delay: ${POST_TX_DELAY}s"
log "15-min interval: ${ID_INTERVAL}s"
log "Poll interval:   ${POLL_INTERVAL}s"
log "Idle reset:      ${IDLE_TIMEOUT}s"
log "=============================================="

last_id_time=$(date +%s)

while true; do
    now=$(date +%s)
    rx_keyed=$(get_rx_keyed)

    if [ "$rx_keyed" = "255" ]; then
        log "WARNING: Could not query Asterisk. Retrying in ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    # --- Detect RX activity ---
    if [ "$rx_keyed" = "1" ]; then
        last_rx_time=$now
        activity_seen=1

        # If a post-TX ID was pending but someone keyed up again, cancel it
        # (we're still in a series of transmissions — ID at 15 min instead)
        if [ "$id_pending" = "1" ]; then
            log "RX keyed again — cancelling pending post-TX ID (series of transmissions in progress)"
            id_pending=0
            id_pending_at=0
        fi
    fi

    # --- Detect falling edge: RX just dropped (1 -> 0) ---
    if [ "$prev_rx_keyed" = "1" ] && [ "$rx_keyed" = "0" ]; then
        log "RX unkeyed — scheduling post-TX ID in ${POST_TX_DELAY}s"
        id_pending=1
        id_pending_at=$now
    fi

    # --- Fire the post-TX ID after the delay ---
    if [ "$id_pending" = "1" ] && [ "$rx_keyed" = "0" ]; then
        pending_elapsed=$(( now - id_pending_at ))
        if [ "$pending_elapsed" -ge "$POST_TX_DELAY" ]; then
            play_id "post-transmission"
        fi
    fi

    # --- Fire the 15-minute ID if activity has been ongoing ---
    if [ "$activity_seen" = "1" ] && [ "$id_pending" = "0" ]; then
        interval_elapsed=$(( now - last_id_time ))
        if [ "$interval_elapsed" -ge "$ID_INTERVAL" ]; then
            log "15-minute interval reached with ongoing activity."
            play_id "15-minute interval"
        fi
    fi

    # --- Idle timeout: reset state if no RX for IDLE_TIMEOUT seconds ---
    if [ "$activity_seen" = "1" ] && [ "$last_rx_time" -gt 0 ]; then
        idle_seconds=$(( now - last_rx_time ))
        if [ "$idle_seconds" -ge "$IDLE_TIMEOUT" ]; then
            log "Node idle for ${idle_seconds}s — resetting state. Next ID on new activity."
            activity_seen=0
            id_pending=0
            id_pending_at=0
            last_rx_time=0
            last_id_time=$now
        fi
    fi

    prev_rx_keyed=$rx_keyed
    sleep "$POLL_INTERVAL"
done
