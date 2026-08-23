#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
action=${1:-}

shell_quote() {
  printf "'%s'" "${1//\'/\'\"\'\"\'}"
}

case $action in
  update)
    updater=$(shell_quote "$repo_root/packaging/arch/studio-omarchy-update")
    exec omarchy-launch-floating-terminal-with-presentation "$updater"
    ;;
  launch)
    exec uwsm-app -- /usr/bin/studio
    ;;
  remove)
    cleanup_user_trust=$(shell_quote "$repo_root/scripts/cleanup-user-trust.sh")
    exec omarchy-launch-floating-terminal-with-presentation \
      "$cleanup_user_trust && omarchy-pkg-drop wordpress-studio-omarchy"
    ;;
  *)
    echo 'Usage: action.sh update|launch|remove' >&2
    exit 2
    ;;
esac
