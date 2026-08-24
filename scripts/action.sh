#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
action=${1:-}

shell_quote() {
  printf "'%s'" "${1//\'/\'\"\'\"\'}"
}

run_in_terminal() {
  local command=$1 focus_uuid focus_title quoted_title terminal_command
  local launcher_pid launcher_status=0 client='' address='' active_address='' focus_deadline

  if [[ -z ${WAYLAND_DISPLAY:-} || -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    exec omarchy-launch-floating-terminal-with-presentation "$command"
  fi

  focus_uuid=$(uuidgen 2>/dev/null || true)
  [[ $focus_uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    exec omarchy-launch-floating-terminal-with-presentation "$command"
  focus_title="studio-omarchy-$focus_uuid"
  quoted_title=$(shell_quote "$focus_title")
  terminal_command="printf '\\033]2;%s\\007' $quoted_title; sleep 1; $command; action_status=\$?; printf '\\033]2;Omarchy\\007'; (exit \$action_status)"

  omarchy-launch-floating-terminal-with-presentation "$terminal_command" &
  launcher_pid=$!
  focus_deadline=$((SECONDS + 5))
  while ((SECONDS < focus_deadline)); do
    client=$(timeout 1 hyprctl -j clients 2>/dev/null | jq -ce --arg title "$focus_title" '
      [.[]
        | select(.mapped == true
          and .class == "org.omarchy.terminal"
          and .initialClass == "org.omarchy.terminal"
          and .title == $title)]
      | if length == 1 then .[0] else empty end' 2>/dev/null) || client=''
    address=$(jq -r '.address // empty' <<<"$client" 2>/dev/null || true)
    if [[ $address =~ ^0x[0-9a-fA-F]+$ ]]; then
      active_address=$(timeout 1 hyprctl -j activewindow 2>/dev/null | jq -r '.address // empty' 2>/dev/null || true)
      if [[ $active_address == "$address" ]]; then
        break
      fi
      timeout 1 hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })" >/dev/null 2>&1 ||
        timeout 1 hyprctl dispatch focuswindow "address:$address" >/dev/null 2>&1 || true
      active_address=$(timeout 1 hyprctl -j activewindow 2>/dev/null | jq -r '.address // empty' 2>/dev/null || true)
      [[ $active_address == "$address" ]] && break
    fi
    sleep 0.1
  done
  wait "$launcher_pid" || launcher_status=$?
  return "$launcher_status"
}

case $action in
  update)
    updater=$(shell_quote "$repo_root/packaging/arch/studio-omarchy-update")
    run_in_terminal "$updater"
    ;;
  launch)
    exec uwsm-app -- /usr/bin/studio
    ;;
  remove)
    remover=$(shell_quote "$repo_root/scripts/remove.sh")
    run_in_terminal "$remover"
    ;;
  *)
    echo 'Usage: action.sh update|launch|remove' >&2
    exit 2
    ;;
esac
