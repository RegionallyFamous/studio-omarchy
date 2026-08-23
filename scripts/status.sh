#!/bin/bash

set -euo pipefail

readonly package_name='wordpress-studio-omarchy'
readonly raw_limit=96
status_root=$(mktemp -d)
status_file="$status_root/status"
start_gate="$status_root/start"
worker_pid=''
worker_pgid=''
worker_verified=false

mkfifo "$start_gate"
exec 9<>"$start_gate"

stop_worker() {
  [[ -n $worker_pid ]] || return 0

  worker_target_alive() {
    if [[ $worker_verified == true && -n $worker_pgid ]]; then
      kill -0 -- "-$worker_pgid" 2>/dev/null
    else
      kill -0 "$worker_pid" 2>/dev/null
    fi
  }

  if [[ $worker_verified == true && -n $worker_pgid ]]; then
    kill -TERM -- "-$worker_pgid" 2>/dev/null || true
  else
    kill -TERM "$worker_pid" 2>/dev/null || true
  fi

  for (( attempt = 0; attempt < 20; attempt++ )); do
    if ! worker_target_alive; then
      break
    fi
    sleep 0.05
  done

  if worker_target_alive; then
    if [[ $worker_verified == true && -n $worker_pgid ]]; then
      kill -KILL -- "-$worker_pgid" 2>/dev/null || true
    else
      kill -KILL "$worker_pid" 2>/dev/null || true
    fi
  fi

  wait "$worker_pid" 2>/dev/null || true
  worker_pid=''
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  exec 9>&- 2>/dev/null || true
  stop_worker
  rm -rf -- "$status_root"
  exit "$status"
}

cancel() {
  stop_worker
  exit 143
}

trap cleanup EXIT
trap cancel HUP INT TERM

# The worker script is intentionally single-quoted so package data can only
# enter through positional arguments, never through shell interpolation.
# shellcheck disable=SC2016
setsid bash -c '
  set -o pipefail
  IFS= read -r ready <&9
  [[ $ready == "go" ]] || exit 125

  worker_pgid=$$
  watchdog_pid=""
  stop_watchdog() {
    [[ -n $watchdog_pid ]] || return 0
    printf "cancel\n" >&9 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  }
  trap stop_watchdog EXIT

  (
    trap "" HUP INT TERM
    if IFS= read -r -t 3 cancel <&9 && [[ $cancel == "cancel" ]]; then
      exit 0
    fi
    kill -KILL -- "-$worker_pgid"
  ) &
  watchdog_pid=$!

  LC_ALL=C pacman -Q -- "$1" 2>/dev/null | head -c "$2"
' studio-status-worker "$package_name" "$((raw_limit + 1))" >"$status_file" &
worker_pid=$!

for (( attempt = 0; attempt < 20; attempt++ )); do
  worker_pgid=$(ps -o pgid= -p "$worker_pid" 2>/dev/null | tr -d ' ' || true)
  if [[ $worker_pgid == "$worker_pid" ]] && kill -0 "$worker_pid" 2>/dev/null; then
    worker_verified=true
    break
  fi
  sleep 0.01
done

if [[ $worker_verified != true ]]; then
  printf 'error\n'
  exit 0
fi

printf 'go\n' >&9
exec 9>&-

set +e
wait "$worker_pid"
pacman_status=$?
set -e
worker_pid=''

status_bytes=$(wc -c <"$status_file")
if (( status_bytes > raw_limit )); then
  printf 'error\n'
  exit 0
fi

if (( pacman_status != 0 )); then
  if (( pacman_status == 1 )); then
    printf 'missing\n'
  else
    printf 'error\n'
  fi
  exit 0
fi

IFS=' ' read -r reported_name reported_version extra <"$status_file" || true
if [[ $reported_name == "$package_name" && -z ${extra:-} &&
  ${reported_version:-} =~ ^[A-Za-z0-9._+:-]{1,64}$ ]]; then
  printf 'installed\t%s\n' "$reported_version"
else
  printf 'error\n'
fi
