#!/bin/bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
studio_root='/usr/lib/studio'
studio_process_pattern='^/usr/lib/studio/'
bundled_node="$studio_root/resources/bin/node"
bundled_cli="$studio_root/resources/cli/main.mjs"
current_uid=$(id -u)
cli_runtime_root=''
cli_ready_file=''
cli_go_file=''
cli_controller_pid=''
cli_unit=''
cli_control_group=''
cli_verified=false

systemctl_user() {
  timeout --signal=TERM --kill-after=1s 3s systemctl --user "$@"
}

scope_has_runnable_processes() {
  local pid state process_fd process_file="/sys/fs/cgroup$cli_control_group/cgroup.procs"

  [[ -n $cli_control_group && -r $process_file ]] || return 1
  exec {process_fd}<"$process_file" 2>/dev/null || return 1
  while read -r -u "$process_fd" pid; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    if [[ -n $state && $state != Z* ]]; then
      exec {process_fd}<&-
      return 0
    fi
  done
  exec {process_fd}<&-
  return 1
}

signal_verified_scope() {
  local signal=$1

  [[ $cli_verified == true && $cli_unit == studio-remove-*.scope ]] || return 0
  systemctl_user kill --kill-whom=all --signal="$signal" "$cli_unit" >/dev/null 2>&1 || true
}

pid_cmdline_has_token() {
  local pid=$1 expected=$2 token

  [[ -r /proc/$pid/cmdline ]] || return 1
  while IFS= read -r -d '' token; do
    [[ $token == "$expected" ]] && return 0
  done <"/proc/$pid/cmdline"
  return 1
}

cleanup_cli_runtime() {
  if [[ -n $cli_runtime_root && -d $cli_runtime_root ]]; then
    rm -rf -- "$cli_runtime_root"
  fi
  cli_runtime_root=''
  cli_ready_file=''
  cli_go_file=''
}

stop_cli_controller() {
  local deadline

  if [[ $cli_verified == true ]]; then
    signal_verified_scope TERM
    systemctl_user --no-block stop "$cli_unit" >/dev/null 2>&1 || true
    deadline=$((SECONDS + 5))
    while scope_has_runnable_processes; do
      if (( SECONDS >= deadline )); then
        signal_verified_scope KILL
        break
      fi
      sleep 0.1
    done
    deadline=$((SECONDS + 7))
    while scope_has_runnable_processes; do
      signal_verified_scope KILL
      (( SECONDS < deadline )) || break
      sleep 0.05
    done
  fi

  if [[ -n $cli_controller_pid ]] && kill -0 "$cli_controller_pid" 2>/dev/null; then
    kill -TERM "$cli_controller_pid" 2>/dev/null || true
    deadline=$((SECONDS + 1))
    while kill -0 "$cli_controller_pid" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        kill -KILL "$cli_controller_pid" 2>/dev/null || true
        break
      fi
      sleep 0.05
    done
  fi

  if [[ -n $cli_controller_pid ]]; then
    wait "$cli_controller_pid" 2>/dev/null || true
  fi
  cli_controller_pid=''
  if [[ $cli_verified == true && $cli_unit == studio-remove-*.scope ]]; then
    systemctl_user --no-block stop "$cli_unit" >/dev/null 2>&1 || true
  fi
  if [[ $cli_verified == true ]] && scope_has_runnable_processes; then
    echo 'WordPress Studio shutdown cleanup remains active in its bounded systemd scope.' >&2
  else
    cli_unit=''
    cli_control_group=''
    cli_verified=false
  fi
  cleanup_cli_runtime
}

show_failure() {
  trap - ERR HUP INT TERM
  stop_cli_controller
  echo >&2
  echo 'WordPress Studio removal failed. Press any key to close.' >&2
  read -rsn1 || true
  exit 130
}

stop_cli_on_signal() {
  trap - ERR HUP INT TERM
  stop_cli_controller
  exit 130
}

studio_app_running() {
  local pid arg is_child clients client_matches
  local -a app_pids=()

  while read -r pid; do
    [[ -r /proc/$pid/cmdline ]] || continue
    is_child=false
    while IFS= read -r -d '' arg; do
      if [[ $arg == --type=* ]]; then
        is_child=true
        break
      fi
    done <"/proc/$pid/cmdline"
    [[ $is_child == true ]] || app_pids+=("$pid")
  done < <(pgrep -u "$current_uid" -f '^/usr/lib/studio/studio( |$)' || true)

  ((${#app_pids[@]} > 0)) || return 1

  # Choosing Studio's native “Keep site running” quit action closes every
  # compositor window but intentionally keeps the Electron main process alive
  # to supervise the background site. Refuse removal only when one of the exact
  # main-process PIDs still owns a mapped Hyprland window. If compositor state
  # cannot be verified, fail closed and require the user to retry in Omarchy.
  [[ -n ${WAYLAND_DISPLAY:-} && -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 0
  clients=$(timeout --signal=TERM --kill-after=1s 3s hyprctl -j clients 2>/dev/null) || return 0
  jq -e 'type == "array" and all(.[];
    type == "object" and (.mapped | type == "boolean") and (.pid | type == "number"))' \
    <<<"$clients" >/dev/null 2>&1 || return 0
  for pid in "${app_pids[@]}"; do
    client_matches=$(jq -r --argjson pid "$pid" \
      'any(.[]; .mapped == true and .pid == $pid)' <<<"$clients" 2>/dev/null) || return 0
    if [[ $client_matches == "true" ]]; then
      return 0
    elif [[ $client_matches != "false" ]]; then
      return 0
    fi
  done
  return 1
}

studio_pid_is_package_owned() {
  local pid=$1 first_arg process_uid

  [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/status && -r /proc/$pid/cmdline ]] || return 1
  process_uid=$(awk '$1 == "Uid:" { print $2; exit }' "/proc/$pid/status" 2>/dev/null || true)
  IFS= read -r -d '' first_arg <"/proc/$pid/cmdline" 2>/dev/null || return 1
  [[ $process_uid == "$current_uid" && $first_arg == /usr/lib/studio/* ]]
}

studio_processes_present() {
  pgrep -u "$current_uid" -f "$studio_process_pattern" >/dev/null
}

signal_package_owned_studio_processes() {
  local signal=$1 pid

  while read -r pid; do
    studio_pid_is_package_owned "$pid" || continue
    kill -"$signal" "$pid" 2>/dev/null || true
  done < <(pgrep -u "$current_uid" -f "$studio_process_pattern" || true)
}

terminate_hidden_studio_processes() {
  local deadline

  if studio_app_running; then
    echo 'WordPress Studio opened a window again; removal was cancelled.' >&2
    return 1
  fi

  signal_package_owned_studio_processes TERM
  deadline=$((SECONDS + 5))
  while studio_processes_present; do
    (( SECONDS < deadline )) || break
    sleep 0.1
  done

  if studio_processes_present; then
    if studio_app_running; then
      echo 'WordPress Studio opened a window again; removal was cancelled.' >&2
      return 1
    fi
    signal_package_owned_studio_processes KILL
    deadline=$((SECONDS + 5))
    while studio_processes_present; do
      (( SECONDS < deadline )) || break
      sleep 0.1
    done
  fi

  if studio_processes_present; then
    echo 'A WordPress Studio background process did not stop; removal was cancelled.' >&2
    return 1
  fi
}

run_bounded_stop_cli() {
  local active_state actual_pgid actual_sid actual_uid cli_status control_group expected_nonce
  local id kill_mode property published_nonce runtime_max send_sigkill timeout_stop unit_properties
  local verification_deadline worker_cgroup worker_pid attempt extra value

  cli_runtime_root=$(mktemp -d)
  chmod 700 "$cli_runtime_root"
  expected_nonce="$current_uid-$$-$RANDOM$RANDOM"
  cli_unit="studio-remove-$expected_nonce.scope"
  cli_ready_file="$cli_runtime_root/ready"
  cli_go_file="$cli_runtime_root/go"
  trap stop_cli_on_signal HUP INT TERM

  # The systemd user scope is the independent cleanup owner for Studio's CLI,
  # its detached daemon, and managed site processes. A bounded filesystem gate
  # keeps the fixed runner closed until this parent verifies the scope, cgroup,
  # UID, session, process group, and exact nonce on both sides of the boundary.
  # shellcheck disable=SC2016
  timeout --signal=TERM --kill-after=2s 80s \
    systemd-run --user --scope --quiet --collect --expand-environment=no --unit="$cli_unit" \
    --property=KillMode=control-group --property=RuntimeMaxSec=70s \
    --property=TimeoutStopSec=5s --property=SendSIGKILL=yes \
    setsid --fork --wait bash -c '
    umask 077
    expected_nonce=$5
    [[ $expected_nonce =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] || exit 125
    [[ ${3%/*} == "${4%/*}" && -d ${3%/*} ]] || exit 125
    supervisor_pid=$$
    supervisor_pgid=$(ps -o pgid= -p "$supervisor_pid" | tr -d " ")
    supervisor_sid=$(ps -o sid= -p "$supervisor_pid" | tr -d " ")
    supervisor_uid=$(ps -o uid= -p "$supervisor_pid" | tr -d " ")
    [[ $supervisor_pid == "$supervisor_pgid" && $supervisor_pid == "$supervisor_sid" &&
      $supervisor_uid == "$6" ]] || exit 125
    printf "%s %s %s %s\n" "$expected_nonce" "$supervisor_pid" \
      "$supervisor_pgid" "$supervisor_sid" >"$3.$supervisor_pid"
    mv -- "$3.$supervisor_pid" "$3"
    permission=""
    for (( attempt = 0; attempt < 100; attempt++ )); do
      if [[ -f $4 ]]; then
        IFS= read -r permission <"$4" || true
        [[ $permission == "$expected_nonce" ]] && break
      fi
      sleep 0.05
    done
    [[ $permission == "$expected_nonce" ]] || exit 125
    timeout --signal=TERM --kill-after=5s 60s \
      "$1" --experimental-wasm-jspi "$2" site stop --all --avoid-telemetry &
    task_pid=$!
    if wait "$task_pid"; then
      task_status=0
    else
      task_status=$?
    fi
    exit "$task_status"
  ' studio-remove-worker "$bundled_node" "$bundled_cli" "$cli_ready_file" \
    "$cli_go_file" "$expected_nonce" "$current_uid" &
  cli_controller_pid=$!

  verification_deadline=$((SECONDS + 10))
  for (( attempt = 0; SECONDS < verification_deadline; attempt++ )); do
    if [[ -s $cli_ready_file ]]; then
      read -r published_nonce worker_pid actual_pgid actual_sid extra <"$cli_ready_file" || true
      actual_uid=$(ps -o uid= -p "${worker_pid:-0}" 2>/dev/null | tr -d ' ' || true)
      id=''
      active_state=''
      control_group=''
      runtime_max=''
      timeout_stop=''
      kill_mode=''
      send_sigkill=''
      unit_properties=$(systemctl_user show "$cli_unit" --property=Id --property=ActiveState \
        --property=ControlGroup --property=RuntimeMaxUSec --property=TimeoutStopUSec \
        --property=KillMode --property=SendSIGKILL 2>/dev/null || true)
      while IFS='=' read -r property value; do
        case $property in
          Id) id=$value ;;
          ActiveState) active_state=$value ;;
          ControlGroup) control_group=$value ;;
          RuntimeMaxUSec) runtime_max=$value ;;
          TimeoutStopUSec) timeout_stop=$value ;;
          KillMode) kill_mode=$value ;;
          SendSIGKILL) send_sigkill=$value ;;
        esac
      done <<<"$unit_properties"
      worker_cgroup=$(awk -F: '$1 == "0" { print $3 }' "/proc/${worker_pid:-0}/cgroup" 2>/dev/null || true)
      if [[ $published_nonce == "$expected_nonce" && -z ${extra:-} &&
        $worker_pid =~ ^[0-9]+$ && $worker_pid == "$actual_pgid" && $worker_pid == "$actual_sid" &&
        $actual_uid == "$current_uid" && $id == "$cli_unit" && $active_state == "active" &&
        $control_group == /user.slice/*/"$cli_unit" && $control_group != *..* &&
        $worker_cgroup == "$control_group" && -n $runtime_max && $runtime_max != "infinity" &&
        -n $timeout_stop && $timeout_stop != "infinity" && $kill_mode == "control-group" &&
        $send_sigkill == "yes" ]] &&
        pid_cmdline_has_token "$worker_pid" studio-remove-worker &&
        pid_cmdline_has_token "$worker_pid" "$expected_nonce"; then
        cli_control_group=$control_group
        cli_verified=true
        break
      fi
    fi
    if ! kill -0 "$cli_controller_pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done

  if [[ $cli_verified != true ]]; then
    echo 'WordPress Studio site shutdown containment could not be verified; removal was cancelled.' >&2
    false
  fi

  printf '%s\n' "$expected_nonce" >"$cli_go_file.tmp"
  mv -- "$cli_go_file.tmp" "$cli_go_file"
  if wait "$cli_controller_pid"; then
    cli_status=0
  else
    cli_status=$?
  fi
  cli_controller_pid=''
  trap - HUP INT TERM

  if (( cli_status != 0 )) || scope_has_runnable_processes; then
    echo 'WordPress Studio sites could not be stopped; removal was cancelled.' >&2
    false
  fi

  systemctl_user --no-block stop "$cli_unit" >/dev/null 2>&1 || true
  cli_unit=''
  cli_control_group=''
  cli_verified=false
  cleanup_cli_runtime
}

trap show_failure ERR

if studio_app_running; then
  echo 'Quit WordPress Studio normally before removing it so active Sync work can finish or be cancelled safely.' >&2
  false
fi

if [[ -x $bundled_node && -f $bundled_cli ]]; then
  run_bounded_stop_cli
fi

if studio_processes_present; then
  terminate_hidden_studio_processes
fi

"$script_dir/cleanup-user-trust.sh"
omarchy-pkg-drop wordpress-studio-omarchy
