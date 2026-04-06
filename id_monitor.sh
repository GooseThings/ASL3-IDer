#!/bin/bash
# =============================================================================
# id_monitor.sh
# FCC-Compliant Station ID Monitor for ASL3
#
# FCC 47 CFR § 95.1751 compliance:
#   - ID after the first transmission following a period of inactivity (Initial ID)
#   - ID at least every 15 minutes while the repeater remains active (Pending ID)
#   - No ID during complete inactivity
#
# Logic mirrors the Arcom RC210 repeater controller:
#
#   STATE: IDLE
#     - Repeater has been quiet for at least IDLE_TIMEOUT seconds
#     - Waiting for first keyup
#     - On first unkey -> play Initial ID -> enter ACTIVE state
#
#   STATE: ACTIVE
#     - Repeater has been in use since the last ID
#     - Pending ID timer is running
#     - If PENDING_ID_INTERVAL elapses AND channel is clear -> play Pending ID
#     - If channel is busy when Pending ID is due -> wait for unkey then play
#     - If no activity for IDLE_TIMEOUT seconds -> return to IDLE state
#
# Timers:
#   IDLE_TIMEOUT         How long the repeater must be quiet before it
#                        resets to IDLE state (ready for a fresh Initial ID)
#   POST_TX_DELAY        Seconds to wait after RX unkeys before playing ID
#                        (lets the repeater tail/hang time clear first)
#   PENDING_ID_INTERVAL  How often the Pending ID fires during activity (15 min)
# =============================================================================

# --- Configuration ---
NODE="643931"
IDLE_TIMEOUT=600         # 10 min quiet time before resetting to IDLE state
POST_TX_DELAY=4          # Seconds after unkey before playing ID (clears tail)
PENDING_ID_INTERVAL=900  # 15 minutes — Pending ID interval (FCC max)
POLL_INTERVAL=5          # How often to poll RX status (seconds)
LOG_FILE="/var/log/gmrs_id_monitor.log"
MAX_LOG_SIZE=1048576     # Rotate log at 1MB

# --- States ---
STATE_IDLE=0             # Quiet long enough — next keyup gets Initial ID
STATE_WAIT_UNKEY=1       # First keyup seen, waiting for unkey to play Initial ID
STATE_ACTIVE=2           # Initial ID done, Pending ID timer running
STATE_PENDING_WAIT=3     # Pending ID due but RX is busy — waiting for clear

state=$STATE_IDLE
last_rx_time=0
last_id_time=0
prev_rx_keyed=0
activity_since_last_id=0  # Has there been any RX since the last ID?

# =============================================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$state] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "Log rotated."
    fi
}

play_id() {
    log "ACTION: Playing station ID — reason: $1"
    /usr/sbin/asterisk -rx "rpt fun $NODE *721" > /dev/null 2>&1
    last_id_time=$(date +%s)
    activity_since_last_id=0
}

get_rx_keyed() {
    local output val
    output=$(/usr/sbin/asterisk -rx "rpt show variables $NODE" 2>/dev/null) || { echo "255"; return; }
    val=$(echo "$output" | grep -i "RPT_RXKEYED" | grep -oP '=\K[0-9]+' | head -1)
    echo "${val:-0}"
}

state_name() {
    case $1 in
        0) echo "IDLE" ;;
        1) echo "WAIT_UNKEY" ;;
        2) echo "ACTIVE" ;;
        3) echo "PENDING_WAIT" ;;
    esac
}

set_state() {
    local new=$1
    log "State: $(state_name $state) -> $(state_name $new)"
    state=$new
}

# =============================================================================
# Main
# =============================================================================

log "=============================================="
log "GMRS ID Monitor starting for node $NODE"
log "Idle timeout:    ${IDLE_TIMEOUT}s"
log "Post-TX delay:   ${POST_TX_DELAY}s"
log "Pending ID:      ${PENDING_ID_INTERVAL}s (15 min)"
log "Poll interval:   ${POLL_INTERVAL}s"
log "Starting state:  IDLE"
log "=============================================="

while true; do
    now=$(date +%s)
    rx_keyed=$(get_rx_keyed)

    if [ "$rx_keyed" = "255" ]; then
        log "WARNING: Cannot query Asterisk. Retrying in ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Track last time RX was active
    if [ "$rx_keyed" = "1" ]; then
        last_rx_time=$now
        activity_since_last_id=1
    fi

    # Detect falling edge (unkey)
    rx_just_dropped=0
    if [ "$prev_rx_keyed" = "1" ] && [ "$rx_keyed" = "0" ]; then
        rx_just_dropped=1
    fi

    # -------------------------------------------------------------------------
    case $state in

        # --- IDLE: waiting for first keyup after a long quiet period ---
        $STATE_IDLE)
            if [ "$rx_keyed" = "1" ]; then
                log "First keyup detected after idle period — waiting for unkey to play Initial ID"
                set_state $STATE_WAIT_UNKEY
            fi
            ;;

        # --- WAIT_UNKEY: first TX in progress, wait for them to finish ---
        $STATE_WAIT_UNKEY)
            if [ "$rx_just_dropped" = "1" ]; then
                log "Unkeyed — waiting ${POST_TX_DELAY}s for tail to clear, then playing Initial ID"
                sleep "$POST_TX_DELAY"
                play_id "Initial ID (first keyup after idle)"
                set_state $STATE_ACTIVE
            fi
            ;;

        # --- ACTIVE: repeater in use, Pending ID timer running ---
        $STATE_ACTIVE)
            elapsed=$(( now - last_id_time ))

            # Pending ID is due
            if [ "$elapsed" -ge "$PENDING_ID_INTERVAL" ]; then
                if [ "$activity_since_last_id" = "1" ]; then
                    # There was activity — ID is needed
                    if [ "$rx_keyed" = "0" ]; then
                        # Channel is clear, play now
                        log "Pending ID due (${elapsed}s since last ID), channel clear — playing now"
                        play_id "Pending ID (15-min interval)"
                        # Stay in ACTIVE — reset timer, keep watching
                    else
                        # Channel busy — wait for unkey
                        log "Pending ID due but RX is busy — waiting for channel clear"
                        set_state $STATE_PENDING_WAIT
                    fi
                else
                    # Timer elapsed but no activity since last ID — nothing to ID for
                    log "Pending ID interval elapsed but no activity — resetting timer"
                    last_id_time=$now
                fi
            fi

            # Check idle timeout
            if [ "$last_rx_time" -gt 0 ]; then
                idle_secs=$(( now - last_rx_time ))
                if [ "$idle_secs" -ge "$IDLE_TIMEOUT" ]; then
                    log "No activity for ${idle_secs}s — returning to IDLE state"
                    activity_since_last_id=0
                    last_rx_time=0
                    set_state $STATE_IDLE
                fi
            fi
            ;;

        # --- PENDING_WAIT: Pending ID is overdue, waiting for channel to clear ---
        $STATE_PENDING_WAIT)
            if [ "$rx_keyed" = "0" ]; then
                log "Channel now clear — playing overdue Pending ID"
                sleep "$POST_TX_DELAY"
                play_id "Pending ID (waited for clear channel)"
                set_state $STATE_ACTIVE
            else
                log "Still waiting for channel to clear for Pending ID..."
            fi
            ;;

    esac

    prev_rx_keyed=$rx_keyed
    sleep "$POLL_INTERVAL"
done
