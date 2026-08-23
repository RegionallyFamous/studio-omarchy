#!/bin/bash
# omarchy-test-lab:timeout=2400

set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

FIXTURE="$ROOT/test/acceptance.d/fixtures/plugin"
MANIFEST="$FIXTURE/manifest.json"
PLUGIN_ID=$(jq -er '.id' "$MANIFEST")
PLUGIN_VERSION=$(jq -er '.version' "$MANIFEST")
PACKAGE_NAME='wordpress-studio-omarchy'
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
TERMINAL_CLASS='org\.omarchy\.terminal|foot|Alacritty'
containment_root="/tmp/studio-status-containment-$$"

cleanup() {
  close_windows '(?i)studio' || true
  close_windows "$TERMINAL_CLASS" || true
  if [[ -d $containment_root ]]; then
    while read -r pid; do
      [[ -n $pid ]] && kill -KILL "$pid" 2>/dev/null || true
    done < <(find "$containment_root" -type f -name '*.pid' -exec cat {} \; 2>/dev/null)
    rm -rf "$containment_root"
  fi
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1 || true
  omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  if [[ -d $PLUGIN_DIR ]]; then
    rm -rf "$PLUGIN_DIR"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

screen_absent() {
  ! screen_contains "$1"
}

dismiss_startup_notifications() {
  omarchy-shell notifications dismissAll >/dev/null 2>&1 || return 1
  screen_absent 'Learn Keybindings'
}

group_nonrunnable() {
  local pgid="$1"
  ! ps -eo pgid=,stat= | awk -v target="$pgid" '$1 == target && $2 !~ /^Z/ { found = 1 } END { exit found ? 0 : 1 }'
}

exercise_status_containment() {
  local mode="$1"
  local run_root="$containment_root/$mode"
  local controller_pid child_pid child_pgid

  mkdir -p "$run_root/bin"
  cat >"$run_root/bin/pacman" <<'STUB'
#!/bin/bash
trap '' TERM
printf '%s\n' "$$" >"$STUDIO_STATUS_CHILD_PID"
while :; do sleep 1; done
STUB
  chmod 755 "$run_root/bin/pacman"

  PATH="$run_root/bin:$PATH" STUDIO_STATUS_CHILD_PID="$run_root/child.pid" \
    "$FIXTURE/scripts/status.sh" >"$run_root/output" 2>"$run_root/error" &
  controller_pid=$!
  printf '%s\n' "$controller_pid" >"$run_root/controller.pid"
  wait_until "the $mode containment worker starts" 5 test -s "$run_root/child.pid"
  child_pid=$(<"$run_root/child.pid")
  child_pgid=$(ps -o pgid= -p "$child_pid" | tr -d ' ')
  ps -o pid,ppid,pgid,sid,stat,comm -p "$controller_pid,$child_pid" >>"$ARTIFACTS/studio-status-topology.log"

  if [[ $mode == term ]]; then
    kill -TERM "$controller_pid"
  else
    kill -KILL "$controller_pid"
  fi
  wait "$controller_pid" 2>/dev/null || true

  wait_until "the $mode containment group becomes non-runnable" 8 group_nonrunnable "$child_pgid"
  pass "the $mode containment path reaps or makes every status descendant non-runnable"
}

[[ ! -e $PLUGIN_DIR ]] || fail 'WordPress Studio is absent before plugin installation'
[[ ! -e /usr/bin/studio ]] || fail 'WordPress Studio package is absent before installation'
"$OMARCHY_PATH/bin/omarchy-plugin-validate" "$FIXTURE" || fail 'WordPress Studio passes the host validator'
pass 'WordPress Studio passes the host validator'

exercise_status_containment term
exercise_status_containment sigkill

mkdir -p "$(dirname "$PLUGIN_DIR")"
cp -a "$FIXTURE" "$PLUGIN_DIR"
omarchy-shell shell rescanPlugins >/dev/null
wait_until 'WordPress Studio is discovered' 15 \
  bash -c "omarchy plugin list --json | jq -e --arg id '$PLUGIN_ID' 'any(.[]; .id == \$id)'"

omarchy plugin enable "$PLUGIN_ID" >/dev/null
wait_until 'WordPress Studio is enabled' 15 \
  bash -c "omarchy plugin list --json | jq -e --arg id '$PLUGIN_ID' 'any(.[]; .id == \$id and .enabled)'"

wait_until 'startup notifications clear the panel test area' 30 dismiss_startup_notifications

omarchy-shell shell summon "$PLUGIN_ID" '{}' >/dev/null
wait_until 'WordPress Studio panel identifies itself' 60 screen_contains 'WordPress Studio'
wait_until 'WordPress Studio panel opens' 5 layer_on_screen omarchy-keyboard-panel
wait_until 'WordPress Studio reports its initial state' 20 screen_contains 'Not installed'
screenshot 'success-studio-01-not-installed'

wtype -k Return
wait_until 'the visible Omarchy installer terminal opens' 30 window_present "$TERMINAL_CLASS"
wait_until 'the installer reaches its checksum-verified sudo handoff' 1900 \
  pgrep -f '[s]udo pacman -U --needed --noconfirm -- .*/wordpress-studio-omarchy-'
wtype 'omarchy'
wtype -k Return
wait_until 'pacman starts the verified native package install' 30 \
  pgrep -f '[p]acman -U --needed --noconfirm -- .*/wordpress-studio-omarchy-'
wait_until 'the checksum-verified native package installs' 300 \
  pacman -Q "$PACKAGE_NAME"
wait_until 'the installer presents its completion screen' 60 screen_contains 'Done! Press any key'
screenshot 'success-studio-02-installed-terminal'
wtype -k space
wait_until 'the installer terminal closes' 30 window_absent "$TERMINAL_CLASS"

omarchy-shell shell summon "$PLUGIN_ID" '{}' >/dev/null
wait_until 'the plugin reports the installed version' 30 screen_contains "Installed $PLUGIN_VERSION"
wait_until 'the installed Studio panel reopens' 5 layer_on_screen omarchy-keyboard-panel
wait_until 'the plugin exposes the native Wayland launch action' 20 screen_contains 'Native Wayland'
screenshot 'success-studio-03-installed-panel'

wtype -k Down -k Return
launch_deadline=$((SECONDS + 90))
until window_present '(?i)studio' >/dev/null 2>&1; do
  if (( SECONDS >= launch_deadline )); then
    {
      echo '== package files =='
      stat /usr/bin/studio /usr/lib/studio/studio /usr/lib/studio/chrome-sandbox || true
      ldd /usr/lib/studio/studio || true
      echo '== desktop entry =='
      sed -n '1,120p' /usr/share/applications/studio.desktop || true
      echo '== processes =='
      pgrep -af 'studio|gtk-launch|uwsm-app' || true
      echo '== user journal =='
      journalctl --user --since '-3 minutes' --no-pager | tail -n 300 || true
      echo '== coredumps =='
      coredumpctl --no-pager --since '-3 minutes' list 2>/dev/null || true
      echo '== direct launch probe =='
      set +e
      timeout --signal=TERM --kill-after=5s 20s \
        env ELECTRON_ENABLE_LOGGING=1 /usr/bin/studio --enable-logging=stderr
      probe_status=$?
      set -e
      echo "direct launch status: $probe_status"
      echo '== processes after direct launch probe =='
      pgrep -af 'studio|gtk-launch|uwsm-app' || true
    } >"$ARTIFACTS/studio-launch-failure.log" 2>&1
    fail 'WordPress Studio launches' 'timed out after 90s waiting for the native application window'
  fi
  sleep 1
done
pass 'WordPress Studio launches'
hyprctl -j clients | jq -e '[.[] | select(.class | test("(?i)studio")) | select(.xwayland == false)] | length > 0' >/dev/null ||
  fail 'WordPress Studio runs as a native Wayland client'
pass 'WordPress Studio runs as a native Wayland client'
wait_until 'WordPress Studio renders its application window' 60 screen_contains 'Studio'
screenshot 'success-studio-04-native-wayland-app'
close_windows '(?i)studio'
wait_until 'WordPress Studio closes cleanly' 30 window_absent '(?i)studio'

omarchy-shell shell summon "$PLUGIN_ID" '{}' >/dev/null
wait_until 'the Studio panel is ready for removal' 30 screen_contains "Installed $PLUGIN_VERSION"
wait_until 'the Studio panel opens for removal' 5 layer_on_screen omarchy-keyboard-panel
wtype -k Down -k Down -k Return
wait_until 'the visible Omarchy removal terminal opens' 30 window_present "$TERMINAL_CLASS"
remove_deadline=$((SECONDS + 180))
remove_password_sent=false
until ! pacman -Q "$PACKAGE_NAME" >/dev/null 2>&1; do
  if [[ $remove_password_sent == false ]] && \
    pgrep -f '[s]udo pacman -Rns --noconfirm wordpress-studio-omarchy' >/dev/null && \
    ! pgrep -x pacman >/dev/null; then
    wtype 'omarchy'
    wtype -k Return
    remove_password_sent=true
  fi
  if (( SECONDS >= remove_deadline )); then
    {
      pgrep -af 'studio|pacman|sudo|omarchy-pkg-drop' || true
      journalctl --user --since '-3 minutes' --no-pager | tail -n 300 || true
    } >"$ARTIFACTS/studio-remove-failure.log" 2>&1
    fail 'the native Studio package removes cleanly' 'timed out waiting for the fixed package removal'
  fi
  sleep 1
done
pass 'the native Studio package removes cleanly'
wait_until 'the remover presents its completion screen' 60 screen_contains 'Done! Press any key'
screenshot 'success-studio-05-removed-terminal'
wtype -k space
wait_until 'the removal terminal closes' 30 window_absent "$TERMINAL_CLASS"
wait_until 'the Studio executable is removed' 30 bash -c '[[ ! -e /usr/bin/studio ]]'
[[ ! -e /etc/ca-certificates/trust-source/anchors/studio-ca.crt ]] ||
  fail 'the Studio trust anchor is removed with the package'
pass 'the Studio trust anchor is removed with the package'

omarchy-shell shell summon "$PLUGIN_ID" '{}' >/dev/null
wait_until 'the plugin returns to its not-installed state' 30 screen_contains 'Not installed'
screenshot 'success-studio-06-removed-panel'
wtype -k Escape
wait_until 'the Studio panel layer closes' 20 layer_absent omarchy-keyboard-panel
wait_until 'the Studio panel pixels clear' 20 screen_absent 'WordPress Studio'

omarchy plugin disable "$PLUGIN_ID" >/dev/null
wait_until 'WordPress Studio is disabled' 15 \
  bash -c "omarchy plugin list --json | jq -e --arg id '$PLUGIN_ID' 'any(.[]; .id == \$id and (.enabled | not))'"

pass 'WordPress Studio guest acceptance passed'
