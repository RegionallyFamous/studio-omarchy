#!/bin/bash -p

set -euo pipefail

unset BASH_ENV ENV CDPATH

readonly SYSTEM_BIN='/usr/bin'
readonly PROCESS_ENVIRON='/proc/self/environ'
export PATH="$SYSTEM_BIN:/bin"

script_path=${BASH_SOURCE[0]}
[[ $script_path == */* ]] || script_path="./$script_path"
script_dir=$(cd -- "${script_path%/*}" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
action=${1:-}

fail() {
  printf 'WordPress Studio: %s\n' "$1" >&2
  exit 1
}

shell_quote() {
  printf "'%s'" "${1//\'/\'\"\'\"\'}"
}

sanitized_environment=()
sanitize_inherited_environment() {
  local environment_entry environment_name

  if [[ ! -r $PROCESS_ENVIRON || -L $PROCESS_ENVIRON ]]; then
    fail 'cannot inspect the inherited environment safely'
  fi
  sanitized_environment=(
    "$SYSTEM_BIN/env"
    -u BASH_ENV
    -u ENV
    -u CDPATH
    -u SHELLOPTS
    -u BASHOPTS
    -u BASH_XTRACEFD
    -u PS4
  )
  while IFS= read -r -d '' environment_entry; do
    environment_name=${environment_entry%%=*}
    if [[ $environment_entry == *=* && $environment_name == BASH_FUNC_*%% ]]; then
      sanitized_environment+=(-u "$environment_name")
    fi
  done <"$PROCESS_ENVIRON"
}

run_in_terminal() {
  local command=$1 omarchy_root launcher trusted_path quoted_path
  local focus_uuid focus_title quoted_title quoted_sleep terminal_command
  local launcher_pid launcher_status=0 client='' address='' active_address='' focus_deadline
  local -a launcher_environment

  if [[ -z ${OMARCHY_PATH:-} || $OMARCHY_PATH != /* || $OMARCHY_PATH == "/" ||
    $OMARCHY_PATH == *:* || $OMARCHY_PATH == *$'\n'* || $OMARCHY_PATH == *$'\r'* ||
    ! -d $OMARCHY_PATH || -L $OMARCHY_PATH ]]; then
    fail 'refusing an unsafe OMARCHY_PATH for the terminal launcher'
  fi
  omarchy_root=$(cd -- "$OMARCHY_PATH" 2>/dev/null && pwd -P) ||
    fail 'unable to resolve OMARCHY_PATH for the terminal launcher'
  if [[ $omarchy_root != "$OMARCHY_PATH" || ! -d $omarchy_root/bin || -L $omarchy_root/bin ]]; then
    fail 'refusing a non-canonical OMARCHY_PATH for the terminal launcher'
  fi
  launcher="$omarchy_root/bin/omarchy-launch-floating-terminal-with-presentation"
  if [[ ! -f $launcher || -L $launcher || ! -x $launcher ]]; then
    fail 'the fixed Omarchy terminal launcher is unavailable or unsafe'
  fi

  trusted_path="$SYSTEM_BIN:$omarchy_root/bin:/bin"
  export PATH="$trusted_path"
  quoted_path=$(shell_quote "$trusted_path")
  quoted_sleep=$(shell_quote "$SYSTEM_BIN/sleep")

  sanitize_inherited_environment
  launcher_environment=("${sanitized_environment[@]}")
  launcher_environment+=("$launcher")

  if [[ -z ${WAYLAND_DISPLAY:-} || -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    exec "${launcher_environment[@]}" "export PATH=$quoted_path; $command"
  fi

  focus_uuid=$("$SYSTEM_BIN/uuidgen" 2>/dev/null || true)
  [[ $focus_uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    exec "${launcher_environment[@]}" "export PATH=$quoted_path; $command"
  focus_title="studio-omarchy-$focus_uuid"
  quoted_title=$(shell_quote "$focus_title")
  terminal_command="export PATH=$quoted_path; printf '\\033]2;%s\\007' $quoted_title; $quoted_sleep 1; $command; action_status=\$?; printf '\\033]2;Omarchy\\007'; (exit \$action_status)"

  "${launcher_environment[@]}" "$terminal_command" &
  launcher_pid=$!
  focus_deadline=$((SECONDS + 5))
  while ((SECONDS < focus_deadline)); do
    # shellcheck disable=SC2016
    client=$("$SYSTEM_BIN/timeout" 1 "$SYSTEM_BIN/hyprctl" -j clients 2>/dev/null |
      "$SYSTEM_BIN/jq" -ce --arg title "$focus_title" '
      [.[]
        | select(.mapped == true
          and .class == "org.omarchy.terminal"
          and .initialClass == "org.omarchy.terminal"
          and .title == $title)]
      | if length == 1 then .[0] else empty end' 2>/dev/null) || client=''
    address=$("$SYSTEM_BIN/jq" -r '.address // empty' <<<"$client" 2>/dev/null || true)
    if [[ $address =~ ^0x[0-9a-fA-F]+$ ]]; then
      active_address=$("$SYSTEM_BIN/timeout" 1 "$SYSTEM_BIN/hyprctl" -j activewindow 2>/dev/null |
        "$SYSTEM_BIN/jq" -r '.address // empty' 2>/dev/null || true)
      if [[ $active_address == "$address" ]]; then
        break
      fi
      "$SYSTEM_BIN/timeout" 1 "$SYSTEM_BIN/hyprctl" dispatch \
        "hl.dsp.focus({ window = \"address:$address\" })" >/dev/null 2>&1 ||
        "$SYSTEM_BIN/timeout" 1 "$SYSTEM_BIN/hyprctl" dispatch \
          focuswindow "address:$address" >/dev/null 2>&1 || true
      active_address=$("$SYSTEM_BIN/timeout" 1 "$SYSTEM_BIN/hyprctl" -j activewindow 2>/dev/null |
        "$SYSTEM_BIN/jq" -r '.address // empty' 2>/dev/null || true)
      [[ $active_address == "$address" ]] && break
    fi
    "$SYSTEM_BIN/sleep" 0.1
  done
  wait "$launcher_pid" || launcher_status=$?
  return "$launcher_status"
}

case $action in
  update)
    for test_variable in "${!STUDIO_OMARCHY_TEST_@}"; do
      unset "$test_variable"
    done
    unset test_variable STUDIO_OMARCHY_DOWNLOAD_DIR
    updater=$(shell_quote "$repo_root/packaging/arch/studio-omarchy-update")
    updater="for studio_test_variable in \${!STUDIO_OMARCHY_TEST_@}; do unset \"\$studio_test_variable\"; done; unset studio_test_variable STUDIO_OMARCHY_DOWNLOAD_DIR; $updater"
    run_in_terminal "$updater"
    ;;
  launch)
    sanitize_inherited_environment
    exec "${sanitized_environment[@]}" "$SYSTEM_BIN/uwsm-app" -- /usr/bin/studio
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
