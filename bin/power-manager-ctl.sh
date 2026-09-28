#!/bin/bash

# Power management CLI controller for Omarchy es.power plugin
# Handles battery telemetry, lid actions, and stay-awake toggling

set -euo pipefail

CONFIG_FILE="$HOME/.config/omarchy/power-management.json"
STATE_DIR="$HOME/.local/state/omarchy/indicators"
STAY_AWAKE_FILE="$STATE_DIR/stay-awake"
POWER_SUPPLY_PATH="${OMARCHY_POWER_SUPPLY_PATH:-/sys/class/power_supply}"

ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat <<'EOF' > "$CONFIG_FILE"
{
  "lidAction": "suspend",
  "separateAcAction": false,
  "lidActionAc": "lock",
  "stayAwake": false
}
EOF
  fi
}

get_config_value() {
  local key="$1"
  local fallback="${2:-}"
  ensure_config
  local val
  val=$(jq -r --arg k "$key" '.[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true)
  if [[ -z "$val" ]]; then
    echo "$fallback"
  else
    echo "$val"
  fi
}

set_config_value() {
  local key="$1"
  local value="$2"
  local is_bool="${3:-false}"
  ensure_config
  local tmp
  tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
  if [[ "$is_bool" == "true" ]]; then
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$CONFIG_FILE" > "$tmp"
  else
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$CONFIG_FILE" > "$tmp"
  fi
  mv "$tmp" "$CONFIG_FILE"
}

is_stay_awake() {
  [[ -f "$STAY_AWAKE_FILE" ]]
}

action_label() {
  case "$1" in
    suspend) echo "Sleep (Suspend)" ;;
    lock) echo "Lock Screen" ;;
    display-off) echo "Turn Off Screen" ;;
    ignore) echo "Do Nothing / Clamshell" ;;
    *) echo "$1" ;;
  esac
}

battery_status() {
  local shell_output=false
  if [[ "${1:-}" == "--shell" ]]; then
    shell_output=true
  fi

  # Find battery device: check upower with regex for battery_ or BAT, or fallback to sysfs
  local battery=""
  battery=$(upower -e 2>/dev/null | grep -E '/battery_|[bB][aA][tT]' | head -n 1 || true)

  local battery_path=""
  local percentage=0
  local capacity=0
  local time_remaining="—"
  local power_rate="0"
  local state="unknown"
  local threshold_start=""
  local threshold_end=""
  local cycles=""

  if [[ -n "$battery" ]]; then
    local battery_info
    battery_info=$(upower -i "$battery" 2>/dev/null || true)

    percentage=$(awk '/percentage/ { print int($2); exit }' <<<"$battery_info")
    capacity=$(awk '/energy-full:/ { printf "%d", $2; exit }' <<<"$battery_info")
    time_remaining=$(awk '/time to (empty|full)/ {
      value = $4
      unit = $5
      if (unit ~ /^minute/) {
        printf "%dm", int(value)
      } else {
        hours = int(value)
        minutes = int((value - hours) * 60)
        if (minutes > 0) {
          printf "%dh %dm", hours, minutes
        } else {
          printf "%dh", hours
        }
      }
      exit
    }' <<<"$battery_info")
    [[ -z "$time_remaining" ]] && time_remaining="—"
    
    local power_rate_raw
    power_rate_raw=$(awk '/energy-rate/ { print $2; exit }' <<<"$battery_info")
    local native_path
    native_path=$(awk '/native-path/ { print $2; exit }' <<<"$battery_info")
    battery_path="$POWER_SUPPLY_PATH/$native_path"

    if [[ -r "$battery_path/power_now" ]]; then
      power_rate_raw=$(awk -v microwatts="$(<"$battery_path/power_now")" 'BEGIN { print microwatts / 1000000 }')
    elif [[ -r "$battery_path/current_now" && -r "$battery_path/voltage_now" ]]; then
      power_rate_raw=$(awk \
        -v microamps="$(<"$battery_path/current_now")" \
        -v microvolts="$(<"$battery_path/voltage_now")" \
        'BEGIN { print microamps * microvolts / 1000000000000 }')
    fi

    power_rate=$(awk -v rate="${power_rate_raw:-0}" 'BEGIN {
      rounded = sprintf("%.1f", rate)
      sub(/\.0$/, "", rounded)
      print rounded
    }')

    state=$(awk '/state/ { print $2; exit }' <<<"$battery_info")
    threshold_start=$(awk '/charge-start-threshold:/ { gsub(/%/, "", $2); print int($2); exit }' <<<"$battery_info")
    threshold_end=$(awk '/charge-end-threshold:/ { gsub(/%/, "", $2); print int($2); exit }' <<<"$battery_info")
  fi

  # Fallback to sysfs search if upower battery path empty
  if [[ -z "$battery_path" || ! -d "$battery_path" ]]; then
    for b in "$POWER_SUPPLY_PATH"/*; do
      [[ -r "$b/type" ]] || continue
      if [[ "$(<"$b/type")" == "Battery" ]]; then
        battery_path="$b"
        break
      fi
    done
  fi

  if [[ -d "$battery_path" ]]; then
    [[ -z "$threshold_end" ]] && threshold_end=$(cat "$battery_path"/charge_control_end_threshold 2>/dev/null || true)
    [[ -z "$threshold_start" ]] && threshold_start=$(cat "$battery_path"/charge_control_start_threshold 2>/dev/null || true)
    cycles=$(cat "$battery_path"/cycle_count 2>/dev/null || true)
    if (( percentage == 0 )) && [[ -r "$battery_path/capacity" ]]; then
      percentage=$(cat "$battery_path/capacity" 2>/dev/null || echo 0)
    fi
  fi

  local ac_online=false
  for supply in "$POWER_SUPPLY_PATH"/*; do
    [[ -r "$supply/type" ]] || continue
    [[ "$(<"$supply/type")" == "Mains" ]] || continue
    [[ -r "$supply/online" ]] || continue
    if [[ "$(<"$supply/online")" == "1" ]]; then
      ac_online=true
      break
    fi
  done

  local charge_idle=false
  if awk -v rate="${power_rate:-0}" 'BEGIN { exit !(rate <= 0.2) }'; then
    charge_idle=true
  fi

  local charge_holding=false
  if [[ "$ac_online" == "true" && -n "$threshold_end" ]]; then
    if [[ "$state" == "pending-charge" ]]; then
      charge_holding=true
    elif [[ "$state" == "fully-charged" ]] && (( percentage < 99 )); then
      charge_holding=true
    elif [[ "$state" == "charging" && "$charge_idle" == "true" ]] && (( threshold_end < 99 && percentage >= threshold_end )); then
      charge_holding=true
    fi
  fi

  if [[ "$shell_output" == "true" ]]; then
    printf 'percentage\t%s\n' "${percentage}%"
    if [[ "$charge_holding" == "true" ]]; then
      printf 'state\tholding\n'
    else
      printf 'state\t%s\n' "$state"
    fi
    printf 'rate\t%s\n' "${power_rate}W"
    printf 'size\t%s\n' "${capacity}Wh"
    printf 'time\t%s\n' "$time_remaining"
    [[ -n "$cycles" ]] && printf 'cycles\t%s\n' "$cycles"
    if [[ -n "$threshold_end" ]]; then
      if [[ -n "$threshold_start" && "$threshold_start" != "$threshold_end" ]]; then
        printf 'threshold\t%s-%s%%\n' "$threshold_start" "$threshold_end"
      else
        printf 'threshold\t%s%%\n' "$threshold_end"
      fi
    fi
  else
    if [[ "$charge_holding" == "true" ]]; then
      echo "Battery ${percentage}%  ·  Holding  ·  ${power_rate}W / ${capacity}Wh"
    elif [[ "$state" == "charging" ]]; then
      echo "Battery ${percentage}%  ·  ${time_remaining} to full  ·   ${power_rate}W / ${capacity}Wh"
    else
      echo "Battery ${percentage}%  ·  ${time_remaining} left  ·   ${power_rate}W / ${capacity}Wh"
    fi
  fi
}

cmd="${1:-status}"
shift || true

case "$cmd" in
  battery-status)
    battery_status "$@"
    ;;
  get-config)
    ensure_config
    # Refresh stayAwake from actual indicator file
    stay_val=$(is_stay_awake && echo "true" || echo "false")
    jq --argjson sa "$stay_val" '.stayAwake = $sa' "$CONFIG_FILE"
    ;;
  get-lid-action)
    target="${1:-battery}"
    if [[ "$target" == "ac" ]]; then
      get_config_value "lidActionAc" "lock"
    else
      get_config_value "lidAction" "suspend"
    fi
    ;;
  set-lid-action)
    action="${1:-suspend}"
    target="${2:-battery}"
    case "$action" in
      suspend|lock|display-off|ignore) ;;
      *) echo "Invalid action: $action" >&2; exit 1 ;;
    esac

    lbl=$(action_label "$action")
    if [[ "$target" == "ac" ]]; then
      set_config_value "lidActionAc" "$action"
      omarchy-notification-send -g 󰒲 "Lid Action (Plugged In)" "Set to $lbl" >/dev/null 2>&1 || true
    else
      set_config_value "lidAction" "$action"
      omarchy-notification-send -g 󰒲 "Lid Action (On Battery)" "Set to $lbl" >/dev/null 2>&1 || true
    fi
    echo "ok"
    ;;
  toggle-separate-ac)
    current=$(get_config_value "separateAcAction" "false")
    if [[ "$current" == "true" ]]; then
      next="false"
      set_config_value "separateAcAction" false true
      omarchy-notification-send -g 󰒲 "Lid Action Settings" "Using unified lid action for Battery & AC" >/dev/null 2>&1 || true
    else
      next="true"
      set_config_value "separateAcAction" true true
      omarchy-notification-send -g 󰒲 "Lid Action Settings" "Separate AC power action enabled" >/dev/null 2>&1 || true
    fi
    echo "$next"
    ;;
  get-stay-awake)
    if is_stay_awake; then
      echo "true"
    else
      echo "false"
    fi
    ;;
  toggle-stay-awake)
    mkdir -p "$STATE_DIR"
    if is_stay_awake; then
      rm -f "$STAY_AWAKE_FILE"
      set_config_value "stayAwake" false true
      omarchy-notification-send -g 󰅶 "Stay Awake Disabled" "System sleep & idle timers resumed" >/dev/null 2>&1 || true
      echo "false"
    else
      touch "$STAY_AWAKE_FILE"
      set_config_value "stayAwake" true true
      omarchy-notification-send -g 󰅶 "Stay Awake Enabled" "Sleep & idle locking are now inhibited" >/dev/null 2>&1 || true
      echo "true"
    fi
    ;;
  *)
    cat <<EOF
Usage: power-manager-ctl.sh <command> [args]
Commands:
  battery-status [--shell]
  get-config
  get-lid-action [battery|ac]
  set-lid-action <suspend|lock|display-off|ignore> [battery|ac]
  toggle-separate-ac
  get-stay-awake
  toggle-stay-awake
EOF
    exit 1
    ;;
esac
