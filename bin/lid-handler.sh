#!/bin/bash

# Lid close handler for Omarchy es.power plugin
# Called by Hyprland when switch:on:Lid Switch triggers

set -euo pipefail

CONFIG_FILE="$HOME/.config/omarchy/power-management.json"
STAY_AWAKE_FILE="$HOME/.local/state/omarchy/indicators/stay-awake"

# 1. Verify the lid is actually closed
if type omarchy-hw-laptop-closed >/dev/null 2>&1; then
  if ! omarchy-hw-laptop-closed; then
    exit 0
  fi
fi

# 2. Check for connected external displays (clamshell mode)
if type omarchy-hw-external-monitors >/dev/null 2>&1; then
  if omarchy-hw-external-monitors; then
    # Clamshell mode: keep external display running, turn off internal
    omarchy-hyprland-monitor-clamshell >/dev/null 2>&1 || true
    exit 0
  fi
fi

# 3. Check if Stay Awake is active
if [[ -f "$STAY_AWAKE_FILE" ]]; then
  # Inhibit sleep: adjust displays only
  omarchy-hyprland-monitor-clamshell >/dev/null 2>&1 || true
  exit 0
fi

# 4. Determine AC vs Battery power
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

# 5. Read configured lid actions
lid_action="suspend"
separate_ac="false"
lid_action_ac="lock"

if [[ -f "$CONFIG_FILE" ]]; then
  lid_action=$(jq -r '.lidAction // "suspend"' "$CONFIG_FILE" 2>/dev/null || echo "suspend")
  separate_ac=$(jq -r '.separateAcAction // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
  lid_action_ac=$(jq -r '.lidActionAc // "lock"' "$CONFIG_FILE" 2>/dev/null || echo "lock")
fi

target_action="$lid_action"
if [[ "$on_battery" == "false" && "$separate_ac" == "true" ]]; then
  target_action="$lid_action_ac"
fi

# 6. Execute the target action
case "$target_action" in
  suspend)
    omarchy-system-lock >/dev/null 2>&1 || true
    omarchy-hyprland-monitor-clamshell >/dev/null 2>&1 || true
    systemctl suspend
    ;;
  lock)
    omarchy-system-lock >/dev/null 2>&1 || true
    omarchy-hyprland-monitor-clamshell >/dev/null 2>&1 || true
    ;;
  display-off)
    omarchy-system-lock >/dev/null 2>&1 || true
    hyprctl dispatch dpms off >/dev/null 2>&1 || true
    ;;
  ignore)
    omarchy-hyprland-monitor-clamshell >/dev/null 2>&1 || true
    ;;
  *)
    # Fallback to standard Omarchy behavior
    omarchy-system-lock >/dev/null 2>&1 || true
    omarchy-hyprland-monitor-clamshell >/dev/null 2>&1 || true
    ;;
esac
