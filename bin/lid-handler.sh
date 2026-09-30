#!/bin/bash

# Lid close handler for Omarchy es.power plugin
# Called by Hyprland when switch:on:Lid Switch triggers

set -euo pipefail

LOG_FILE="/tmp/omarchy-lid-handler.log"
CONFIG_FILE="$HOME/.config/omarchy/power-management.json"
STATE_DIR="$HOME/.local/state/omarchy/indicators"
STAY_AWAKE_FILE="$STATE_DIR/stay-awake"

log() {
  local msg="$1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $msg" >> "$LOG_FILE"
  logger -t omarchy-lid-handler "$msg"
}

log "=== Lid close event received (PID: $$) ==="

# 1. Verify the lid is actually closed (with slight debounce for ACPI status propagation)
if type omarchy-hw-laptop-closed >/dev/null 2>&1; then
  closed=false
  for i in {1..3}; do
    if omarchy-hw-laptop-closed; then
      closed=true
      break
    fi
    sleep 0.1
  done
  if [[ "$closed" == "false" ]]; then
    log "Lid switch reported closed, but ACPI / hardware reports lid is open. Ignoring event."
    exit 0
  fi
fi

# 2. Check for connected external displays (clamshell mode)
if type omarchy-hw-external-monitors >/dev/null 2>&1; then
  if omarchy-hw-external-monitors; then
    log "External display detected: applying Clamshell mode (disabling internal panel)."
    omarchy-hyprland-monitor-clamshell >/dev/null 2>&1 || true
    exit 0
  fi
fi

# 3. Determine AC vs Battery power
on_battery=false
if [[ -r /sys/class/power_supply/ADP1/online && "$(<"/sys/class/power_supply/ADP1/online")" == "1" ]]; then
  on_battery=false
elif [[ -r /sys/class/power_supply/ACAD/online && "$(<"/sys/class/power_supply/ACAD/online")" == "1" ]]; then
  on_battery=false
elif upower -d 2>/dev/null | grep -q 'on-battery:[[:space:]]*yes'; then
  on_battery=true
else
  on_battery=true
  for supply in /sys/class/power_supply/*; do
    if [[ -r "$supply/type" && "$(<"$supply/type")" == "Mains" && -r "$supply/online" && "$(<"$supply/online")" == "1" ]]; then
      on_battery=false
      break
    fi
  done
fi

log "Power source: on_battery=$on_battery"

# 4. Read configured lid actions & stay-awake
lid_action="suspend"
separate_ac="false"
lid_action_ac="lock"
stay_awake=false

if [[ -f "$CONFIG_FILE" ]]; then
  lid_action=$(jq -r '.lidAction // "suspend"' "$CONFIG_FILE" 2>/dev/null || echo "suspend")
  separate_ac=$(jq -r '.separateAcAction // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
  lid_action_ac=$(jq -r '.lidActionAc // "lock"' "$CONFIG_FILE" 2>/dev/null || echo "lock")
  stay_awake=$(jq -r '.stayAwake // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
fi

if [[ -f "$STAY_AWAKE_FILE" ]]; then
  stay_awake=true
fi

target_action="$lid_action"
if [[ "$on_battery" == "false" && "$separate_ac" == "true" ]]; then
  target_action="$lid_action_ac"
fi

log "Configured action: target_action=$target_action (on_battery=$on_battery, separate_ac=$separate_ac, stay_awake=$stay_awake)"

# Helper functions for display & lock
turn_display_off() {
  log "Turning display off via omarchy-brightness-display off"
  omarchy-brightness-display off >/dev/null 2>&1 || true
}

lock_screen() {
  log "Locking screen via omarchy-system-lock"
  omarchy-system-lock >/dev/null 2>&1 || true
}

# 5. Execute action based on target_action and stay_awake
if [[ "$stay_awake" == "true" ]]; then
  case "$target_action" in
    suspend)
      log "Stay Awake is active: inhibiting system suspend. Screen will lock and turn off."
      lock_screen
      turn_display_off
      ;;
    lock)
      lock_screen
      turn_display_off
      ;;
    display-off)
      lock_screen
      turn_display_off
      ;;
    ignore)
      log "Stay Awake is active with action=ignore: turning display off."
      turn_display_off
      ;;
    *)
      lock_screen
      turn_display_off
      ;;
  esac
  log "Handler completed (Stay Awake path)."
  exit 0
fi

case "$target_action" in
  suspend)
    log "Executing action: suspend"
    lock_screen
    turn_display_off
    log "Invoking systemctl suspend..."
    systemctl suspend
    ;;
  lock)
    log "Executing action: lock"
    lock_screen
    turn_display_off
    ;;
  display-off)
    log "Executing action: display-off"
    lock_screen
    turn_display_off
    ;;
  ignore)
    log "Executing action: ignore (keeping awake & unlocked, turning display off)"
    turn_display_off
    ;;
  *)
    log "Executing fallback action: suspend"
    lock_screen
    turn_display_off
    systemctl suspend
    ;;
esac

log "Handler completed successfully."
