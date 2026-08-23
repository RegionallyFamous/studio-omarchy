#!/bin/bash
# omarchy-test-lab:requires=pointer
# omarchy-test-lab:timeout=2400

set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

FIXTURE="$ROOT/test/acceptance.d/fixtures/plugin"
MANIFEST="$FIXTURE/manifest.json"
PLUGIN_ID=$(jq -er '.id' "$MANIFEST")
PLUGIN_VERSION=$(jq -er '.version' "$MANIFEST")
PACKAGE_NAME='wordpress-studio-omarchy'
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
TERMINAL_CLASS='org\.omarchy\.terminal|foot|Alacritty'
STUDIO_CLASS='(?i)studio'
BROWSER_CLASS='(?i)chromium'
STUDIO_CONFIG="$HOME/.studio/cli.json"
BUNDLED_NODE='/usr/lib/studio/resources/bin/node'
BUNDLED_CLI='/usr/lib/studio/resources/cli/main.mjs'
QMLLINT_BIN=$(command -v qmllint || true)
containment_root="/tmp/studio-status-containment-$$"
SITE_ONE_NAME='Omarchy Acceptance One'
SITE_TWO_NAME='Omarchy Acceptance Two'
SITE_ONE_ID=''
SITE_ONE_PATH=''
SITE_ONE_PORT=''
SITE_TWO_ID=''
SITE_TWO_PATH=''
SITE_TWO_PORT=''
installed_package_before_update=''
studio_hash_before_update=''
pacman_log_line_before_update=''
bar_widget_click_index=0
: "${QMLLINT_BIN:=/usr/lib/qt6/bin/qmllint}"

screen_absent() {
  ! screen_contains "$1"
}

browser_cleanup_success_visible() {
  screen_contains 'no current-user browser NSS database needs cleanup' ||
    screen_contains 'no matching current-user browser trust entry found' ||
    screen_contains 'matching current-user browser trust entr'
}

active_region_contains() {
  local text=$1 region=$2
  local left_pct top_pct right_pct bottom_pct window win_x win_y win_w win_h
  local crop_x crop_y crop_w crop_h snapshot status

  read -r left_pct top_pct right_pct bottom_pct <<<"$region"
  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || return 1
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  crop_x=$((win_x + win_w * left_pct / 100))
  crop_y=$((win_y + win_h * top_pct / 100))
  crop_w=$((win_w * (right_pct - left_pct) / 100))
  crop_h=$((win_h * (bottom_pct - top_pct) / 100))
  (( crop_w > 0 && crop_h > 0 )) || return 1
  snapshot="/tmp/omarchy-acceptance-active-region-${BASHPID}.png"

  if ! timeout 10 grim -g "$crop_x,$crop_y ${crop_w}x${crop_h}" "$snapshot" 2>/dev/null; then
    rm -f "$snapshot"
    return 1
  fi
  tesseract "$snapshot" stdout --psm 11 2>/dev/null | grep -Fi -- "$text" >/dev/null
  status=$?
  rm -f "$snapshot"
  return "$status"
}

plugin_absent() {
  local plugins

  plugins=$(omarchy plugin list --json) || return 1
  jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id) | not' <<<"$plugins"
}

bar_widget_present() {
  omarchy-shell shell debugBarGeometry | jq -e --arg id "$PLUGIN_ID" \
    'any(.[]; .id == $id and .visible == true and .itemVisible == true and .width > 0 and .height > 0)'
}

bar_widget_absent() {
  local geometry

  geometry=$(omarchy-shell shell debugBarGeometry) || return 1
  jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .visible == true and .itemVisible == true) | not' <<<"$geometry"
}

active_window_matches() {
  hyprctl -j activewindow | jq -e --arg class "$1" '(.class // "") | test($class)'
}

active_native_browser_for_site() {
  local site_name=$1

  hyprctl -j activewindow | jq -e --arg class "$BROWSER_CLASS" --arg site "$site_name" '
    ((.class // "") | test($class)) and .xwayland == false and ((.title // "") | contains($site))
  '
}

studio_processes_absent() {
  ! pgrep -f '^/usr/lib/studio/' >/dev/null
}

pointer_is_near() {
  local expected_x=$1 expected_y=$2
  local actual_x actual_y

  actual_x=$(hyprctl -j cursorpos | jq -er '.x | round') || return 1
  actual_y=$(hyprctl -j cursorpos | jq -er '.y | round') || return 1
  (( actual_x >= expected_x - 3 && actual_x <= expected_x + 3
    && actual_y >= expected_y - 3 && actual_y <= expected_y + 3 ))
}

move_pointer_exactly() {
  local target_x=$1 target_y=$2 description=$3
  local current_x current_y delta_x delta_y attempt

  for (( attempt = 0; attempt < 8; attempt++ )); do
    if pointer_is_near "$target_x" "$target_y"; then
      return 0
    fi
    current_x=$(hyprctl -j cursorpos | jq -er '.x | round')
    current_y=$(hyprctl -j cursorpos | jq -er '.y | round')
    delta_x=$((target_x - current_x))
    delta_y=$((target_y - current_y))
    ydotool mousemove -- "$delta_x" "$delta_y" >/dev/null || fail "$description"
    sleep 0.2
  done
  fail "$description" "cursor did not settle at $target_x,$target_y"
}

park_pointer() {
  local monitor target_x target_y

  monitor=$(hyprctl -j monitors | jq -ce 'if length == 1 then .[0] else empty end') ||
    fail 'the pointer lane has exactly one guest monitor'
  target_x=$(jq -nr --argjson m "$monitor" '$m.x + ($m.width / $m.scale) - 30 | floor')
  target_y=$(jq -nr --argjson m "$monitor" '$m.y + ($m.height / $m.scale) - 30 | floor')
  move_pointer_exactly "$target_x" "$target_y" 'the pointer parks away from Studio controls'
}

# Emit exact normalized phrase matches from a Tesseract TSV. Words may be
# fragmented by OCR, but must remain contiguous on one painted line.
ocr_phrase_candidates() {
  local tsv=$1 target=$2 left_pct=$3 top_pct=$4 right_pct=$5 bottom_pct=$6

  awk -F '\t' -v target="$target" -v lp="$left_pct" -v tp="$top_pct" \
    -v rp="$right_pct" -v bp="$bottom_pct" '
    function norm(value, out) {
      out = tolower(value)
      gsub(/[^[:alnum:]]/, "", out)
      return out
    }
    function flush(   i,j,s,x1,y1,x2,y2,c,n,cx,cy) {
      for (i = 1; i <= count; i++) {
        s = ""; x1 = left[i]; y1 = top[i]; x2 = left[i] + width[i]; y2 = top[i] + height[i]; c = 0; n = 0
        for (j = i; j <= count && j < i + 12; j++) {
          s = s norm(word[j]);
          if (left[j] < x1) x1 = left[j]
          if (top[j] < y1) y1 = top[j]
          if (left[j] + width[j] > x2) x2 = left[j] + width[j]
          if (top[j] + height[j] > y2) y2 = top[j] + height[j]
          if (conf[j] >= 0) { c += conf[j]; n++ }
          if (s == wanted) {
            cx = (x1 + x2) / 2; cy = (y1 + y2) / 2
            if (n && c / n >= 35 && cx >= pagew * lp / 100 && cx <= pagew * rp / 100 && cy >= pageh * tp / 100 && cy <= pageh * bp / 100)
              printf "%d %d %d %d %.1f %d %d\n", x1, y1, x2-x1, y2-y1, c/n, pagew, pageh
            break
          }
          if (index(wanted, s) != 1) break
        }
      }
      delete word; delete left; delete top; delete width; delete height; delete conf; count = 0
    }
    BEGIN { wanted = norm(target); previous = "" }
    $1 == 1 { pagew = $9; pageh = $10; next }
    $1 == 5 && norm($12) != "" {
      key = $2 FS $3 FS $4 FS $5
      if (previous != "" && key != previous) flush()
      previous = key
      count++
      left[count] = $7; top[count] = $8; width[count] = $9; height[count] = $10; conf[count] = $11; word[count] = $12
    }
    END { flush() }
  ' "$tsv" | awk '!seen[$1 FS $2 FS $3 FS $4]++'
}

resolve_phrase() {
  local scope=$1 target=$2 region=$3 label=$4
  local left_pct top_pct right_pct bottom_pct snapshot scaled_snapshot tsv candidates geometry fingerprint
  local win_x=0 win_y=0 win_w=0 win_h=0 page_w page_h box_x box_y box_w box_h
  local monitor logical_w logical_h cursor_x cursor_y count psm ocr_id

  read -r left_pct top_pct right_pct bottom_pct <<<"$region"
  ocr_id="${BASHPID}-${RANDOM}"
  snapshot="$ARTIFACTS/studio-ocr-${ocr_id}.png"
  scaled_snapshot="/tmp/studio-ocr-scaled-${ocr_id}.png"
  tsv="$ARTIFACTS/studio-ocr-${ocr_id}.tsv"
  candidates="$ARTIFACTS/studio-ocr-${ocr_id}-candidates.txt"

  if [[ $scope == "active" ]]; then
    fingerprint=$(hyprctl -j activewindow | jq -ce \
      '{address,at,size,monitor,class,title}') || fail "$label" 'there is no active window to inspect'
    read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$fingerprint" | xargs)
    (( win_w > 0 && win_h > 0 )) || fail "$label" 'the active window has invalid geometry'
    timeout 10 grim -g "$win_x,$win_y ${win_w}x${win_h}" "$snapshot" 2>/dev/null ||
      fail "$label" 'the active-window target screenshot could not be captured'
  else
    monitor=$(hyprctl -j monitors | jq -ce 'if length == 1 then .[0] else empty end') ||
      fail "$label" 'pointer OCR requires exactly one guest monitor'
    timeout 10 grim "$snapshot" 2>/dev/null || fail "$label" 'the screen target screenshot could not be captured'
  fi

  : >"$candidates"
  for psm in 11 6; do
    tesseract "$snapshot" stdout --psm "$psm" tsv >"$tsv" 2>/dev/null || true
    ocr_phrase_candidates "$tsv" "$target" "$left_pct" "$top_pct" "$right_pct" "$bottom_pct" >"$candidates"
    [[ -s $candidates ]] && break
  done
  if [[ ! -s $candidates ]]; then
    timeout 10 magick "$snapshot" -resize 200% "$scaled_snapshot" 2>/dev/null || true
    if [[ -s $scaled_snapshot ]]; then
      for psm in 6 11; do
        tesseract "$scaled_snapshot" stdout --psm "$psm" tsv >"$tsv" 2>/dev/null || true
        ocr_phrase_candidates "$tsv" "$target" "$left_pct" "$top_pct" "$right_pct" "$bottom_pct" >"$candidates"
        [[ -s $candidates ]] && break
      done
    fi
    rm -f "$scaled_snapshot"
  fi
  count=$(wc -l <"$candidates" | tr -d ' ')
  (( count == 1 )) || fail "$label" "OCR expected one '$target' candidate in $region but found $count; see $candidates"
  read -r box_x box_y box_w box_h _ page_w page_h <"$candidates"
  [[ $page_w =~ ^[0-9]+$ && $page_h =~ ^[0-9]+$ ]] || fail "$label" 'OCR did not report page geometry'

  if [[ $scope == "active" ]]; then
    geometry=$(hyprctl -j activewindow | jq -ce '{address,at,size,monitor,class,title}')
    [[ $geometry == "$fingerprint" ]] || fail "$label" 'the active window changed while its target was resolved'
    cursor_x=$((win_x + (box_x + box_w / 2) * win_w / page_w))
    cursor_y=$((win_y + (box_y + box_h / 2) * win_h / page_h))
    (( cursor_x >= win_x && cursor_x <= win_x + win_w && cursor_y >= win_y && cursor_y <= win_y + win_h )) ||
      fail "$label" 'the OCR coordinate mapped outside the active window'
  else
    logical_w=$(jq -nr --argjson m "$monitor" '$m.width / $m.scale | round')
    logical_h=$(jq -nr --argjson m "$monitor" '$m.height / $m.scale | round')
    cursor_x=$(jq -nr --argjson m "$monitor" --arg px "$((box_x + box_w / 2))" --arg pw "$page_w" --arg lw "$logical_w" '$m.x + ($px|tonumber) * ($lw|tonumber) / ($pw|tonumber) | round')
    cursor_y=$(jq -nr --argjson m "$monitor" --arg py "$((box_y + box_h / 2))" --arg ph "$page_h" --arg lh "$logical_h" '$m.y + ($py|tonumber) * ($lh|tonumber) / ($ph|tonumber) | round')
  fi
  printf '%s %s\n' "$cursor_x" "$cursor_y"
}

click_phrase() {
  local scope=$1 target=$2 region=$3 label=$4 button=${5:-left}
  local cursor_x cursor_y click_code='0xC0' ready_name

  read -r cursor_x cursor_y < <(resolve_phrase "$scope" "$target" "$region" "$label")
  move_pointer_exactly "$cursor_x" "$cursor_y" "$label"
  pointer_is_near "$cursor_x" "$cursor_y" || fail "$label" 'cursor assertion failed immediately before click'
  ready_name=${label,,}
  ready_name=${ready_name// /-}
  ready_name=${ready_name//[^a-z0-9-]/}
  screenshot "ready-studio-$ready_name-$button"
  [[ $button == "right" ]] && click_code='0xC1'
  ydotool click "$click_code" >/dev/null || fail "$label"
  pass "$label"
}

click_screen_phrase() {
  click_phrase screen "$1" "${2:-0 0 100 100}" "$3"
}

click_active_phrase() {
  click_phrase active "$1" "${2:-0 0 100 100}" "$3"
}

click_active_centered_control() {
  local x_offset=$1 y_offset=$2 label=$3
  local window win_x win_y win_w win_h target_x target_y ready_name

  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || fail "$label"
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  target_x=$((win_x + win_w / 2 + x_offset))
  target_y=$((win_y + win_h / 2 + y_offset))
  move_pointer_exactly "$target_x" "$target_y" "$label"
  pointer_is_near "$target_x" "$target_y" || fail "$label" 'cursor assertion failed immediately before click'
  ready_name=${label,,}
  ready_name=${ready_name// /-}
  ready_name=${ready_name//[^a-z0-9-]/}
  screenshot "ready-studio-$ready_name-left"
  ydotool click 0xC0 >/dev/null || fail "$label"
  pass "$label"
}

click_active_bottom_right_control() {
  local label=$1
  local window win_x win_y win_w win_h target_x target_y ready_name

  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || fail "$label"
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  target_x=$((win_x + win_w - 50))
  target_y=$((win_y + win_h - 38))
  move_pointer_exactly "$target_x" "$target_y" "$label"
  pointer_is_near "$target_x" "$target_y" || fail "$label" 'cursor assertion failed immediately before click'
  ready_name=${label,,}
  ready_name=${ready_name// /-}
  ready_name=${ready_name//[^a-z0-9-]/}
  screenshot "ready-studio-$ready_name-left"
  ydotool click 0xC0 >/dev/null || fail "$label"
  pass "$label"
}

right_click_active_phrase() {
  click_phrase active "$1" "${2:-0 0 100 100}" "$3" right
}

click_bar_widget() {
  local slot layer monitor target_x target_y

  bar_widget_click_index=$((bar_widget_click_index + 1))

  slot=$(omarchy-shell shell debugBarGeometry | jq -ce --arg id "$PLUGIN_ID" \
    '[.[] | select(.id == $id and .visible == true and .itemVisible == true and .width > 0 and .height > 0)] | if length == 1 then .[0] else empty end') ||
    fail 'the Studio bar widget has one visible click target'
  layer=$(hyprctl -j layers | jq -ce '
    [to_entries[] | .key as $monitor | (.value | .. | objects | select(.namespace? == "omarchy-bar")) | {monitor:$monitor,x:.x,y:.y,w:.w,h:.h}]
    | if length == 1 then .[0] else empty end') || fail 'the Omarchy bar has one visible layer surface'
  monitor=$(hyprctl -j monitors | jq -ce --arg name "$(jq -r '.monitor' <<<"$layer")" '.[] | select(.name == $name)')
  target_x=$(jq -nr --argjson s "$slot" --argjson l "$layer" --argjson m "$monitor" '$m.x + $l.x + $s.x + $s.width / 2 | round')
  target_y=$(jq -nr --argjson s "$slot" --argjson l "$layer" --argjson m "$monitor" '$m.y + $l.y + $s.y + $s.height / 2 | round')
  move_pointer_exactly "$target_x" "$target_y" 'the pointer reaches the Studio bar widget'
  pointer_is_near "$target_x" "$target_y" || fail 'the Studio bar widget cursor coordinate is asserted'
  sleep 1
  resolve_phrase screen 'WordPress Studio' '80 0 100 10' 'the real Studio bar widget exposes its tooltip' >/dev/null
  pass 'the real Studio bar widget exposes its tooltip'
  screenshot "ready-studio-bar-widget-$bar_widget_click_index"
  pointer_is_near "$target_x" "$target_y" || fail 'the Studio bar widget cursor coordinate is asserted immediately before click'
  ydotool click 0xC0 >/dev/null || fail 'the real Studio bar widget is clicked'
  pass 'the real Studio bar widget is clicked'
}

hover_active_tooltip() {
  local tooltip=$1 y_pct=$2 start_pct=$3 end_pct=$4 label=$5
  local window win_x win_y win_w win_h y x start end step ready_name

  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || fail "$label"
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  y=$((win_y + win_h * y_pct / 100))
  start=$((win_x + win_w * start_pct / 100))
  end=$((win_x + win_w * end_pct / 100))
  if (( start > end )); then step=-14; else step=14; fi
  for (( x = start; step < 0 ? x >= end : x <= end; x += step )); do
    move_pointer_exactly "$x" "$y" "$label"
    sleep 0.35
    if screen_contains "$tooltip"; then
      pointer_is_near "$x" "$y" || fail "$label" 'cursor moved after the tooltip appeared'
      ready_name=${label,,}
      ready_name=${ready_name// /-}
      screenshot "ready-studio-tooltip-$ready_name"
      printf '%s %s\n' "$x" "$y"
      return 0
    fi
  done
  fail "$label" "could not expose the '$tooltip' tooltip along the expected control strip"
}

click_active_tooltip() {
  local tooltip=$1 y_pct=$2 start_pct=$3 end_pct=$4 label=$5
  local x y

  read -r x y < <(hover_active_tooltip "$tooltip" "$y_pct" "$start_pct" "$end_pct" "$label")
  pointer_is_near "$x" "$y" || fail "$label" 'cursor assertion failed immediately before tooltip control click'
  ydotool click 0xC0 >/dev/null || fail "$label"
  pass "$label"
}

hover_theme_thumbnail_and_open() {
  local theme_x theme_y hover_x label='the external Open site control is clicked with the pointer'

  read -r theme_x theme_y < <(resolve_phrase active 'Theme' '25 10 85 75' 'the Theme row locates the site thumbnail')
  hover_x=$((theme_x - 55))
  move_pointer_exactly "$hover_x" "$theme_y" 'the pointer hovers the site thumbnail'
  wait_until 'the thumbnail reveals its Open site control' 10 screen_contains 'Open site'
  pointer_is_near "$hover_x" "$theme_y" || fail "$label" 'cursor moved after the thumbnail control appeared'
  screenshot 'ready-studio-the-external-open-site-control-is-clicked-with-the-pointer-left'
  ydotool click 0xC0 >/dev/null || fail "$label"
  pass "$label"
}

group_nonrunnable() {
  local pgid=$1
  ! ps -eo pgid=,stat= | awk -v target="$pgid" '$1 == target && $2 !~ /^Z/ { found = 1 } END { exit found ? 0 : 1 }'
}

exercise_status_containment() {
  local mode=$1 run_root="$containment_root/$1"
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
  if [[ $mode == "term" ]]; then
    kill -TERM "$controller_pid"
  else
    kill -KILL "$controller_pid"
  fi
  wait "$controller_pid" 2>/dev/null || true
  wait_until "the $mode containment group becomes non-runnable" 8 group_nonrunnable "$child_pgid"
}

verified_package_handoff_present() {
  pgrep -f '[s]udo pacman -U --needed --noconfirm -- .*/wordpress-studio-omarchy-' >/dev/null ||
    pgrep -f '[p]acman -U --needed --noconfirm -- .*/wordpress-studio-omarchy-' >/dev/null
}

verify_staged_package_handoff() {
  local pid package_path='' package_name checksum_path checksum_name expected_hash expected_name extra actual_hash argument
  local -a arguments

  pid=$(pgrep -f '[s]udo pacman -U --needed --noconfirm -- .*/wordpress-studio-omarchy-' | head -n 1) || return 1
  mapfile -d '' -t arguments <"/proc/$pid/cmdline" || return 1
  (( ${#arguments[@]} == 7 )) || return 1
  [[ ${arguments[0]##*/} == "sudo" && ${arguments[1]} == "pacman" && ${arguments[2]} == "-U" &&
    ${arguments[3]} == "--needed" && ${arguments[4]} == "--noconfirm" && ${arguments[5]} == "--" ]] || return 1
  argument=${arguments[6]}
  [[ $argument == /* ]] || return 1
  package_path=$argument
  package_name=${package_path##*/}
  [[ $package_name =~ ^wordpress-studio-omarchy-([0-9]+\.[0-9]+\.[0-9]+)-[1-9][0-9]*-x86_64\.pkg\.tar\.zst$ ]] || return 1
  [[ ${BASH_REMATCH[1]} == "$PLUGIN_VERSION" ]] || return 1
  checksum_path="$package_path.sha256"
  checksum_name="$package_name.sha256"
  [[ -f $package_path && ! -L $package_path && -s $package_path && -f $checksum_path && ! -L $checksum_path && -s $checksum_path ]] || return 1
  IFS=' ' read -r expected_hash expected_name extra <"$checksum_path" || return 1
  [[ $expected_hash =~ ^[0-9a-f]{64}$ && $expected_name == "$package_name" && -z $extra ]] || return 1
  actual_hash=$(sha256sum "$package_path" | cut -d ' ' -f 1) || return 1
  [[ $actual_hash == "$expected_hash" && ${checksum_path##*/} == "$checksum_name" ]]
}

studio_updater_process_absent() {
  local proc_dir
  local -a arguments

  for proc_dir in /proc/[0-9]*; do
    [[ -r $proc_dir/cmdline ]] || continue
    mapfile -d '' -t arguments <"$proc_dir/cmdline" || continue
    (( ${#arguments[@]} >= 2 )) || continue
    if [[ ${arguments[0]##*/} == "bash" && ${arguments[1]} == "$PLUGIN_DIR/packaging/arch/studio-omarchy-update" ]]; then
      return 1
    fi
  done
  return 0
}

finish_package_install_or_update() {
  local operation=$1 shot=$2

  wait_until "the $operation reaches its checksum-verified pacman handoff" 1900 verified_package_handoff_present
  wait_until "the $operation stages one independently verified release package" 15 verify_staged_package_handoff
  screenshot "success-studio-$operation-checksum"
  wait_until "the $operation password prompt owns the active terminal" 10 active_window_matches "$TERMINAL_CLASS"
  wtype 'omarchy'
  wtype -k Return
  wait_until "$operation installs the expected native package" 300 pacman -Q "$PACKAGE_NAME"
  wait_until "$operation updater process completes" 120 studio_updater_process_absent
  wait_until "$operation reports the exact installed Studio version" 30 \
    screen_contains "WordPress Studio $PLUGIN_VERSION is installed"
  wait_until "$operation presents its exact successful completion screen" 30 screen_contains 'Done! Press any key'
  screenshot "$shot"
  wtype -k space
  wait_until "$operation terminal closes" 30 window_absent "$TERMINAL_CLASS"
  pacman -Q "$PACKAGE_NAME" | awk -v version="$PLUGIN_VERSION" '$2 ~ "^" version "([.-]|$)" { found=1 } END { exit found ? 0 : 1 }' ||
    fail "$operation leaves the package at the plugin version"
  pass "$operation leaves the package at the plugin version"
}

site_record_exists() {
  local name=$1 expected_path=$2

  [[ -s $STUDIO_CONFIG ]] &&
    jq -e --arg name "$name" --arg path "$expected_path" '
      .version == 1 and
      ([.sites[]? | select(
        .name == $name and
        .path == $path and
        (.id | type) == "string" and
        (.id | length) > 0 and
        (.port | type) == "number" and
        .port > 0 and
        (.phpVersion | type) == "string" and
        (.phpVersion | length) > 0
      )] | length == 1)
    ' "$STUDIO_CONFIG" >/dev/null
}

load_site_record() {
  local name=$1 expected_path=$2 prefix=$3 record

  record=$(jq -cer --arg name "$name" --arg path "$expected_path" '
    [.sites[]? | select(
      .name == $name and
      .path == $path and
      (.id | type) == "string" and
      (.id | length) > 0 and
      (.port | type) == "number" and
      .port > 0
    )] | if length == 1 then .[0] else error("expected exactly one site") end
  ' "$STUDIO_CONFIG") || fail "$name has exactly one valid persisted registry record"
  printf -v "${prefix}_ID" '%s' "$(jq -er '.id' <<<"$record")"
  printf -v "${prefix}_PATH" '%s' "$(jq -er '.path' <<<"$record")"
  printf -v "${prefix}_PORT" '%s' "$(jq -er '.port' <<<"$record")"
}

site_files_ready() {
  local path=$1
  [[ -f $path/wp-load.php && -f $path/wp-config.php && -s $path/wp-content/database/.ht.sqlite ]]
}

site_cli_state() {
  local path=$1 expected=$2 status

  status=$("$BUNDLED_NODE" --experimental-wasm-jspi "$BUNDLED_CLI" site status \
    --path "$path" --format json --avoid-telemetry 2>/dev/null) || return 1
  jq -e --argjson expected "$expected" '.isOnline == $expected' <<<"$status"
}

site_rest_ready() {
  local port=$1
  curl --noproxy '*' -fsSL --max-time 8 "http://localhost:$port/wp-json/" |
    jq -e '(.namespaces | index("wp/v2")) != null'
}

site_frontend_ready() {
  local port=$1 headers body status content_type
  headers=$(mktemp)
  body=$(mktemp)
  status=$(curl --noproxy '*' -sSL --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' "http://localhost:$port/") || {
    rm -f "$headers" "$body"
    return 1
  }
  content_type=$(awk 'BEGIN{IGNORECASE=1} /^content-type:/ {gsub("\r",""); print tolower($0)}' "$headers" | tail -n 1)
  [[ $status == 200 || $status == 302 ]] && [[ $content_type == *text/html* ]] && grep -Eqi 'wordpress|wp-content|<title' "$body"
  local result=$?
  rm -f "$headers" "$body"
  return "$result"
}

site_http_offline() {
  local port=$1
  ! curl --noproxy '*' -fsS --max-time 3 "http://localhost:$port/" >/dev/null
}

site_record_absent() {
  local name=$1 expected_path=$2

  [[ ! -e $STUDIO_CONFIG ]] ||
    jq -e --arg name "$name" --arg path "$expected_path" \
      'all(.sites[]?; .name != $name and .path != $path)' "$STUDIO_CONFIG" >/dev/null
}

same_version_update_log_is_idempotent() {
  local start_line=$((pacman_log_line_before_update + 1)) segment="$ARTIFACTS/studio-update-pacman.log"
  local invocation_count

  tail -n "+$start_line" /var/log/pacman.log >"$segment" || return 1
  invocation_count=$(grep -Ec "\[PACMAN\] Running 'pacman -U --needed --noconfirm -- .*/wordpress-studio-omarchy-${PLUGIN_VERSION//./\\.}-[1-9][0-9]*-x86_64\\.pkg\\.tar\\.zst'" "$segment" || true)
  (( invocation_count == 1 )) || return 1
  ! grep -E "\[ALPM\] (installed|upgraded|downgraded) ${PACKAGE_NAME}([[:space:]]|$)" "$segment" >/dev/null
}

create_site_with_pointer() {
  local name=$1 ordinal=$2 expected_path=$3 deadline attempt name_entered=false

  click_active_phrase 'Create a new site' '20 5 100 95' "the $ordinal site creation card is clicked"
  wait_until "the $ordinal create-site form is visible" 20 screen_contains 'Site name'
  click_active_phrase 'Site name' '20 5 100 70' "the $ordinal site name field is focused"
  for (( attempt = 0; attempt < 3; attempt++ )); do
    wtype -M ctrl -k a -m ctrl
    wtype -d 75 "$name"
    sleep 1
    if active_region_contains "$name" '20 20 80 70'; then
      name_entered=true
      break
    fi
  done
  [[ $name_entered == "true" ]] || fail "the $ordinal site name is entered exactly"
  pass "the $ordinal site name is entered exactly"
  click_active_bottom_right_control "the $ordinal Create site button is clicked"
  deadline=$((SECONDS + 120))
  until site_record_exists "$name" "$expected_path"; do
    if (( SECONDS >= deadline )); then
      collect_diagnostics
      fail "the $ordinal site is persisted" "timed out waiting for the exact Studio registry record: $name at $expected_path"
    fi
    sleep 1
  done
  pass "the $ordinal site is persisted"
}

complete_first_site_orientation() {
  # Studio 1.18 keeps all three guide pages mounted in one fixed centered dialog.
  # Tesseract drops its tiny white-on-blue labels, so target the fixed dialog
  # from the active-window center and guard every click
  # with the exact heading before it and the exact next state after it.
  wait_until 'the first-site orientation guide opens' 45 screen_contains 'Welcome to WordPress Studio'
  screenshot 'success-studio-07a-orientation-welcome'
  click_active_centered_control 150 158 'the orientation Welcome step advances with the pointer'
  wait_until 'the orientation guide shows Manage your site' 20 screen_contains 'Manage your site'
  click_active_centered_control -150 158 'the orientation Manage your site Back control is clicked with the pointer'
  wait_until 'the orientation guide Back control returns to Welcome' 20 screen_contains 'Welcome to WordPress Studio'
  click_active_centered_control 150 158 'the orientation Welcome step advances again with the pointer'
  wait_until 'the orientation guide returns to Manage your site' 20 screen_contains 'Manage your site'
  click_active_centered_control 150 158 'the orientation Manage your site step advances with the pointer'
  wait_until 'the orientation guide shows See your site inline' 20 screen_contains 'See your site inline'
  click_active_centered_control -150 158 'the orientation inline-preview Back control is clicked with the pointer'
  wait_until 'the orientation guide Back control returns to Manage your site' 20 screen_contains 'Manage your site'
  click_active_centered_control 150 158 'the orientation Manage your site step advances again with the pointer'
  wait_until 'the orientation guide returns to See your site inline' 20 screen_contains 'See your site inline'
  click_active_centered_control 150 158 'the orientation inline-preview step completes with the pointer'
  wait_until 'the first-site orientation guide disappears' 20 screen_absent 'See your site inline'
  screenshot 'success-studio-07b-orientation-complete'
}

dismiss_startup_notifications() {
  omarchy-shell notifications dismissAll >/dev/null 2>&1 || return 1
  screen_absent 'Learn Keybindings'
}

collect_diagnostics() {
  {
    echo '== Studio config (credentials omitted) =='
    jq '{version, sites: [.sites[]? | {id, name, path, port, phpVersion, url}], snapshotCount: (.snapshots // [] | length)}' "$STUDIO_CONFIG" 2>&1 || true
    echo '== Studio site files =='
    find "$HOME/Studio" -maxdepth 4 -type f \
      \( -name wp-load.php -o -name wp-config.php -o -name .ht.sqlite \) \
      -printf '%p %s bytes\n' 2>&1 || true
    echo '== clients =='
    hyprctl -j clients 2>&1 || true
    echo '== layers =='
    hyprctl -j layers 2>&1 || true
    echo '== processes =='
    pgrep -af 'studio|pacman|sudo|chromium|ydotool' 2>&1 || true
    echo '== package =='
    pacman -Q "$PACKAGE_NAME" 2>&1 || true
    echo '== shell log =='
    quickshell --no-color log -p "$OMARCHY_PATH/shell" --any-display --tail 260 2>&1 || true
    echo '== user journal =='
    journalctl --user --since '-15 minutes' --no-pager 2>&1 | tail -n 500 || true
  } >"$ARTIFACTS/studio-diagnostics.log"
}

cleanup() {
  local exit_status=$? path

  trap - ERR
  if (( exit_status != 0 )); then
    collect_diagnostics
  fi
  close_windows "$BROWSER_CLASS" || true
  close_windows "$STUDIO_CLASS" || true
  close_windows "$TERMINAL_CLASS" || true
  for path in "$SITE_ONE_PATH" "$SITE_TWO_PATH"; do
    if [[ $path == "$HOME/Studio/omarchy-acceptance-one" || $path == "$HOME/Studio/omarchy-acceptance-two" ]]; then
      if [[ -x $BUNDLED_NODE && -f $BUNDLED_CLI ]]; then
        "$BUNDLED_NODE" --experimental-wasm-jspi "$BUNDLED_CLI" site delete --path "$path" --avoid-telemetry >/dev/null 2>&1 || true
      fi
      [[ ! -e $path ]] || rm -rf -- "$path"
    fi
  done
  if [[ -d $containment_root ]]; then
    while read -r pid; do
      [[ -n $pid ]] && kill -KILL "$pid" 2>/dev/null || true
    done < <(find "$containment_root" -type f -name '*.pid' -exec sh -c 'cat "$1"' _ {} \; 2>/dev/null)
    rm -rf -- "$containment_root"
  fi
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1 || true
  omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  if [[ -d $PLUGIN_DIR ]]; then
    rm -rf -- "$PLUGIN_DIR"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

handle_unexpected_error() {
  local status=$? line=$1 command=$2

  trap - ERR
  collect_diagnostics
  printf 'line=%s status=%s command=%s\n' "$line" "$status" "$command" >>"$ARTIFACTS/studio-diagnostics.log"
  screenshot 'failure-studio-unexpected-command'
  printf 'not ok - WordPress Studio guest acceptance stopped unexpectedly\n' >&2
  exit "$status"
}
trap 'handle_unexpected_error "$LINENO" "$BASH_COMMAND"' ERR

[[ $PLUGIN_ID =~ ^[a-z0-9][a-z0-9._-]*$ && $PLUGIN_ID != *".."* ]] || fail 'the Studio plugin id is safe'
[[ ! -e $PLUGIN_DIR ]] || fail 'WordPress Studio is absent before plugin installation'
[[ ! -e /usr/bin/studio ]] || fail 'WordPress Studio package is absent before installation'
command -v ydotool >/dev/null 2>&1 || fail 'the pointer-enabled test lane provides ydotool'
hyprctl -j monitors | jq -e 'length == 1 and .[0].transform == 0' >/dev/null ||
  fail 'the pointer-enabled test lane has one untransformed guest monitor'
[[ -x $QMLLINT_BIN ]] || fail 'the Quattro guest provides qmllint'
for qml in BarWidget.qml Panel.qml; do
  if ! "$QMLLINT_BIN" -I "$OMARCHY_PATH/shell" "$FIXTURE/$qml" >"$ARTIFACTS/studio-${qml,,}-qmllint.log" 2>&1; then
    fail "$qml passes guest qmllint" "$(<"$ARTIFACTS/studio-${qml,,}-qmllint.log")"
  fi
  pass "$qml passes guest qmllint"
done
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
wait_until 'the Studio bar widget is visibly placed' 20 bar_widget_present
wait_until 'startup notifications clear the panel test area' 30 dismiss_startup_notifications

click_bar_widget
wait_until 'the not-installed Studio panel opens' 20 layer_on_screen omarchy-keyboard-panel
wait_until 'the Studio panel reports Not installed' 20 screen_contains 'Not installed'
screenshot 'success-studio-01-not-installed'
sudo -K
click_screen_phrase 'Install Studio' '70 0 100 40' 'the Install Studio button is clicked with the pointer'
wait_until 'the visible Studio installer terminal opens' 30 window_present "$TERMINAL_CLASS"
finish_package_install_or_update 'installer' 'success-studio-02-installed-terminal'

click_bar_widget
wait_until 'the installed Studio panel opens' 20 layer_on_screen omarchy-keyboard-panel
wait_until 'the plugin reports its installed version' 30 screen_contains "Installed $PLUGIN_VERSION"
wait_until 'the installed panel exposes Native Wayland' 20 screen_contains 'Native Wayland'
screenshot 'success-studio-03-installed-panel'
[[ -x /usr/bin/studio-omarchy-cleanup-user-trust &&
  ! -L /usr/bin/studio-omarchy-cleanup-user-trust &&
  $(stat -c %a /usr/bin/studio-omarchy-cleanup-user-trust) == "755" ]] ||
  fail 'the package installs the regular standalone browser trust cleanup helper with mode 755'
cmp -s /usr/bin/studio-omarchy-cleanup-user-trust "$PLUGIN_DIR/scripts/cleanup-user-trust.sh" ||
  fail 'the packaged and Quattro browser trust cleanup helpers are byte-identical'
pass 'the standalone and Quattro browser trust cleanup paths are identical'
installed_package_before_update=$(pacman -Q "$PACKAGE_NAME")
studio_hash_before_update=$(sha256sum /usr/lib/studio/studio)
pacman_log_line_before_update=$(wc -l </var/log/pacman.log)
sudo -K
click_screen_phrase 'Update Studio' '70 0 100 40' 'the Update Studio button is clicked with the pointer'
wait_until 'the visible Studio updater terminal opens' 30 window_present "$TERMINAL_CLASS"
finish_package_install_or_update 'updater' 'success-studio-04-updated-terminal'
[[ $(pacman -Q "$PACKAGE_NAME") == "$installed_package_before_update" ]] || fail 'the same-version update preserves the exact installed package version'
[[ $(sha256sum /usr/lib/studio/studio) == "$studio_hash_before_update" ]] || fail 'the same-version update preserves the installed Studio binary checksum'
[[ -f /usr/lib/studio/chrome-sandbox && ! -L /usr/lib/studio/chrome-sandbox && $(stat -c %a /usr/lib/studio/chrome-sandbox) == "4755" ]] ||
  fail 'the same-version update preserves the regular setuid Chromium sandbox helper'
same_version_update_log_is_idempotent || fail 'the same-version --needed update logs its invocation without an ALPM package-state change'
pass 'the same-version checksum-verified update is idempotent'

omarchy-shell shell summon "$PLUGIN_ID" '{}' >/dev/null
wait_until 'shell summon opens the installed Studio panel' 20 layer_on_screen omarchy-keyboard-panel
wait_until 'the summoned Studio panel reports its version' 20 screen_contains "Installed $PLUGIN_VERSION"
screenshot 'success-studio-04a-shell-summon'
omarchy-shell shell hide "$PLUGIN_ID" >/dev/null
wait_until 'the Studio panel hides through shell IPC' 20 layer_absent omarchy-keyboard-panel
omarchy plugin disable "$PLUGIN_ID" >/dev/null
wait_until 'disabling Studio removes its bar widget' 20 bar_widget_absent
omarchy plugin enable "$PLUGIN_ID" >/dev/null
wait_until 're-enabling Studio restores its bar widget' 20 bar_widget_present
omarchy-restart-shell
wait_until 'the Omarchy shell restarts' 30 omarchy-shell shell ping
wait_until 'the Studio bar widget survives shell restart' 30 bar_widget_present
wait_until 'startup notifications clear after shell restart' 30 dismiss_startup_notifications

click_bar_widget
wait_until 'the Studio launch panel opens after shell restart' 20 layer_on_screen omarchy-keyboard-panel
wait_until 'the Studio launch panel finishes rendering after shell restart' 20 screen_contains 'Launch Studio'
click_screen_phrase 'Launch Studio' '70 0 100 40' 'the Launch Studio button is clicked with the pointer'
wait_until 'WordPress Studio launches' 120 window_present "$STUDIO_CLASS"
hyprctl -j clients | jq -e '[.[] | select((.class // "") | test("(?i)studio")) | select(.xwayland == false)] | length > 0' >/dev/null ||
  fail 'WordPress Studio runs as a native Wayland client'
pass 'WordPress Studio runs as a native Wayland client'
wait_until 'the Studio app receives focus' 30 active_window_matches "$STUDIO_CLASS"
wait_until 'fresh Studio shows its welcome title' 60 screen_contains 'WordPress Studio'
wait_until 'fresh Studio shows its top-right Skip control' 20 screen_contains 'Skip'
screenshot 'success-studio-05-fresh-welcome'

click_active_phrase 'anonymous' '20 45 100 100' 'the analytics checkbox is toggled through its visible label'
wait_until 'Studio persists analytics opt-out' 15 bash -c "jq -e '.analyticsOptOut == true' '$HOME/.studio/shared.json'"
park_pointer
click_active_phrase 'anonymous' '20 45 100 100' 'the analytics checkbox is toggled back on through its visible label'
wait_until 'Studio persists analytics sharing restored' 15 bash -c "jq -e '.analyticsOptOut == false' '$HOME/.studio/shared.json'"
click_active_phrase 'Skip' '70 0 100 25' 'the welcome Skip button is clicked'
wait_until 'Studio shows the local-sites tour step' 20 screen_contains 'Sites run right on your machine'
click_active_phrase 'Back' '0 55 55 100' 'the tour Back button returns to welcome'
wait_until 'tour Back returns to the welcome screen' 20 screen_contains 'WordPress Studio'
click_active_phrase 'Skip' '70 0 100 25' 'welcome Skip re-enters the tour'
wait_until 'Studio returns to the local-sites tour step' 20 screen_contains 'Sites run right on your machine'
click_active_bottom_right_control 'the first tour Continue button is clicked'
wait_until 'Studio shows the Studio Code tour step' 20 screen_contains 'Build with Studio Code'
click_active_phrase 'Back' '0 55 55 100' 'the second tour Back button is clicked'
wait_until 'second-step Back returns to local sites' 20 screen_contains 'Sites run right on your machine'
click_active_bottom_right_control 'the local-sites Continue button is clicked again'
wait_until 'Studio Code tour step returns' 20 screen_contains 'Build with Studio Code'
# Account login/signup, remote connection/import, custom domains, and HTTPS
# deliberately stay out of this offline local-site lifecycle lane.
click_active_bottom_right_control 'the offline-safe Skip log in button is clicked'
wait_until 'fresh Studio reaches Add a site' 30 screen_contains 'Add a site'

click_active_phrase 'Create a new site' '20 5 100 95' 'the create-site card opens for form-control coverage'
wait_until 'the create-site form renders' 20 screen_contains 'Advanced settings'
click_active_phrase 'Advanced settings' '20 35 100 100' 'Advanced settings expands with the pointer'
wait_until 'advanced Local path settings are visible' 15 screen_contains 'Local path'
screenshot 'success-studio-06-advanced-settings'
click_active_phrase 'Advanced settings' '20 20 100 90' 'Advanced settings collapses with the pointer'
wait_until 'advanced Local path settings collapse' 15 screen_absent 'Local path'
click_active_phrase 'Back' '0 45 55 100' 'the create-site form Back button is clicked'
wait_until 'form Back returns without creating a site' 20 screen_contains 'Add a site'
site_record_absent "$SITE_ONE_NAME" "$HOME/Studio/omarchy-acceptance-one" || fail 'form Back does not create the first acceptance site'
site_record_absent "$SITE_TWO_NAME" "$HOME/Studio/omarchy-acceptance-two" || fail 'form Back does not create the second acceptance site'
pass 'form Back creates no acceptance site'

create_site_with_pointer "$SITE_ONE_NAME" 'first' "$HOME/Studio/omarchy-acceptance-one"
load_site_record "$SITE_ONE_NAME" "$HOME/Studio/omarchy-acceptance-one" SITE_ONE
complete_first_site_orientation
[[ $SITE_ONE_PATH == "$HOME/Studio/omarchy-acceptance-one" ]] || fail 'the first site uses its isolated default path'
wait_until 'the first site writes WordPress and SQLite files' 120 site_files_ready "$SITE_ONE_PATH"
wait_until 'the first site reports online through the bundled CLI' 120 site_cli_state "$SITE_ONE_PATH" true
wait_until 'the first site exposes the WordPress REST API' 120 site_rest_ready "$SITE_ONE_PORT"
wait_until 'the first site serves visible HTML' 120 site_frontend_ready "$SITE_ONE_PORT"
screenshot 'success-studio-07-first-site-running'

click_active_phrase 'Settings' '20 0 100 35' 'the site Settings tab is clicked'
wait_until 'the Settings tab renders PHP version controls' 20 screen_contains 'PHP version'
screenshot 'success-studio-08-settings-tab'
click_active_phrase 'Debugging' '20 0 100 35' 'the site Debugging tab is clicked'
wait_until 'the Debugging tab renders Xdebug controls' 20 screen_contains 'Xdebug'
screenshot 'success-studio-09-debugging-tab'
click_active_phrase 'Overview' '20 0 100 35' 'the site Overview tab is clicked'
wait_until 'the Overview tab renders About' 20 screen_contains 'About'

click_active_tooltip 'Show preview' 96 98 45 'the in-app Show preview control is clicked with the pointer'
wait_until 'the in-app preview renders the site in its right pane' 60 active_region_contains "$SITE_ONE_NAME" '55 12 100 95'
screenshot 'success-studio-10-preview-shown'
click_active_tooltip 'Refresh' 7 45 95 'the in-app preview Refresh control is clicked with the pointer'
wait_until 'the refreshed preview keeps the site serving' 30 site_frontend_ready "$SITE_ONE_PORT"
click_active_tooltip 'Hide preview' 96 80 25 'the in-app Hide preview control is clicked with the pointer'
read -r _ _ < <(hover_active_tooltip 'Show preview' 96 98 45 'the preview toggle returns to Show preview after hiding')
pass 'the in-app preview returns to its hidden state'
screenshot 'success-studio-11-preview-hidden'

hover_theme_thumbnail_and_open
wait_until 'Open site launches the external browser' 60 window_present "$BROWSER_CLASS"
wait_until 'the native Wayland browser is active with the first site in its title' 60 active_native_browser_for_site "$SITE_ONE_NAME"
site_frontend_ready "$SITE_ONE_PORT" || fail 'the externally opened site remains reachable'
pass 'the externally opened site remains reachable'
screenshot 'success-studio-12-external-site'
close_windows "$BROWSER_CLASS"
wait_until 'the external browser closes' 30 window_absent "$BROWSER_CLASS"
hyprctl dispatch focuswindow "class:$STUDIO_CLASS" >/dev/null
wait_until 'focus returns to Studio' 20 active_window_matches "$STUDIO_CLASS"

click_active_tooltip 'Add site' 3 27 15 'the sidebar Add site icon button is clicked through its visible tooltip'
wait_until 'the second Add a site screen appears' 20 screen_contains 'Create a new site'
create_site_with_pointer "$SITE_TWO_NAME" 'second' "$HOME/Studio/omarchy-acceptance-two"
load_site_record "$SITE_TWO_NAME" "$HOME/Studio/omarchy-acceptance-two" SITE_TWO
[[ $SITE_TWO_PATH == "$HOME/Studio/omarchy-acceptance-two" ]] || fail 'the second site uses its isolated default path'
[[ $SITE_ONE_ID != "$SITE_TWO_ID" && $SITE_ONE_PATH != "$SITE_TWO_PATH" && $SITE_ONE_PORT != "$SITE_TWO_PORT" ]] ||
  fail 'the two sites have distinct ids, paths, and ports'
pass 'the two sites have distinct ids, paths, and ports'
wait_until 'the second site writes WordPress and SQLite files' 120 site_files_ready "$SITE_TWO_PATH"
wait_until 'the second site reports online through the bundled CLI' 120 site_cli_state "$SITE_TWO_PATH" true
wait_until 'the second site exposes the WordPress REST API' 120 site_rest_ready "$SITE_TWO_PORT"
wait_until 'both sites serve concurrently on distinct ports' 60 bash -c \
  "curl --noproxy '*' -fsSL --max-time 8 'http://localhost:$SITE_ONE_PORT/wp-json/' | jq -e '(.namespaces | index(\"wp/v2\")) != null' >/dev/null && curl --noproxy '*' -fsSL --max-time 8 'http://localhost:$SITE_TWO_PORT/wp-json/' | jq -e '(.namespaces | index(\"wp/v2\")) != null' >/dev/null"
screenshot 'success-studio-13-two-sites-running'

click_active_phrase "$SITE_ONE_NAME" '0 0 28 100' 'the first sidebar site is selected with the pointer'
wait_until 'the first sidebar selection binds the main workbench to site one' 20 active_region_contains "$SITE_ONE_NAME" '28 0 100 35'
wait_until 'the first sidebar selection remains online' 20 site_cli_state "$SITE_ONE_PATH" true
screenshot 'success-studio-13a-first-site-selected'
click_active_phrase "$SITE_TWO_NAME" '0 0 28 100' 'the second sidebar site is selected with the pointer'
wait_until 'the second sidebar selection binds the main workbench to site two' 20 active_region_contains "$SITE_TWO_NAME" '28 0 100 35'
wait_until 'the second sidebar selection remains online' 20 site_cli_state "$SITE_TWO_PATH" true
screenshot 'success-studio-13b-second-site-selected'

right_click_active_phrase "$SITE_TWO_NAME" '0 0 28 100' 'the second site context menu is opened with the pointer'
wait_until 'the running site menu exposes Stop site' 15 screen_contains 'Stop site'
click_active_phrase 'Stop site' '0 0 35 100' 'Stop site is clicked with the pointer'
wait_until 'the bundled CLI reports the second site stopped' 120 site_cli_state "$SITE_TWO_PATH" false
wait_until 'the stopped second site refuses HTTP' 30 site_http_offline "$SITE_TWO_PORT"
wait_until 'stopping site two leaves site one online in the bundled CLI' 30 site_cli_state "$SITE_ONE_PATH" true
wait_until 'stopping site two leaves site one REST available' 30 site_rest_ready "$SITE_ONE_PORT"
wait_until 'stopping site two leaves site one frontend available' 30 site_frontend_ready "$SITE_ONE_PORT"
screenshot 'success-studio-14-site-stopped'
right_click_active_phrase "$SITE_TWO_NAME" '0 0 28 100' 'the stopped site context menu is opened with the pointer'
wait_until 'the stopped site menu exposes Start site' 15 screen_contains 'Start site'
click_active_phrase 'Start site' '0 0 35 100' 'Start site is clicked with the pointer'
wait_until 'the bundled CLI reports the second site restarted' 120 site_cli_state "$SITE_TWO_PATH" true
wait_until 'the restarted second site restores REST' 120 site_rest_ready "$SITE_TWO_PORT"
wait_until 'both sites serve concurrently after restarting site two' 60 bash -c \
  "curl --noproxy '*' -fsSL --max-time 8 'http://localhost:$SITE_ONE_PORT/wp-json/' | jq -e '(.namespaces | index(\"wp/v2\")) != null' >/dev/null && curl --noproxy '*' -fsSL --max-time 8 'http://localhost:$SITE_TWO_PORT/wp-json/' | jq -e '(.namespaces | index(\"wp/v2\")) != null' >/dev/null"
screenshot 'success-studio-15-site-restarted'

right_click_active_phrase "$SITE_TWO_NAME" '0 0 28 100' 'the second site menu opens for WP admin'
wait_until 'the site menu exposes Open WP admin' 15 screen_contains 'Open WP admin'
click_active_phrase 'Open WP admin' '0 0 35 100' 'Open WP admin is clicked with the pointer'
wait_until 'WP admin opens in the external browser' 60 window_present "$BROWSER_CLASS"
wait_until 'the native Wayland browser is active with site two in its admin title' 60 active_native_browser_for_site "$SITE_TWO_NAME"
wait_until 'the external WP admin renders Dashboard' 90 screen_contains 'Dashboard'
screenshot 'success-studio-16-wp-admin'
close_windows "$BROWSER_CLASS"
wait_until 'the WP admin browser closes' 30 window_absent "$BROWSER_CLASS"
hyprctl dispatch focuswindow "class:$STUDIO_CLASS" >/dev/null
wait_until 'focus returns to Studio after WP admin' 20 active_window_matches "$STUDIO_CLASS"

for site_name in "$SITE_TWO_NAME" "$SITE_ONE_NAME"; do
  if [[ $site_name == "$SITE_TWO_NAME" ]]; then
    site_path=$SITE_TWO_PATH
  else
    site_path=$SITE_ONE_PATH
    click_active_phrase "$SITE_ONE_NAME" '0 0 28 100' 'the first site is selected for deletion'
  fi
  right_click_active_phrase "$site_name" '0 0 28 100' "the $site_name menu is opened for deletion"
  wait_until "the $site_name menu exposes Delete site" 15 screen_contains 'Delete site'
  click_active_phrase 'Delete site' '0 0 35 100' "the $site_name Delete site menu action is clicked"
  wait_until "the Delete $site_name confirmation appears" 20 screen_contains "Delete $site_name"
  wait_until "the $site_name file-deletion checkbox label is visible and left at its default" 10 screen_contains 'Delete site files from my computer'
  screenshot "ready-delete-${site_name// /-}"
  click_active_phrase 'Delete site' '60 45 100 75' "the $site_name deletion is confirmed with the pointer"
  wait_until "$site_name leaves Studio config" 30 site_record_absent "$site_name" "$site_path"
  wait_until "$site_name files are deleted" 30 test ! -e "$site_path"
done
screenshot 'success-studio-17-sites-deleted'

close_windows "$STUDIO_CLASS"
wait_until 'WordPress Studio closes cleanly' 30 window_absent "$STUDIO_CLASS"
"$BUNDLED_NODE" --experimental-wasm-jspi "$BUNDLED_CLI" site stop --all --avoid-telemetry >/dev/null
wait_until 'all bundled Studio daemon and server processes stop before removal' 60 studio_processes_absent
click_bar_widget
wait_until 'the Studio removal panel opens' 20 layer_on_screen omarchy-keyboard-panel
wait_until 'the Studio removal action is visible' 20 screen_contains 'Remove Studio'
click_screen_phrase 'Remove Studio' '70 0 100 40' 'the Remove Studio button is clicked with the pointer'
wait_until 'the visible Studio removal terminal opens' 30 window_present "$TERMINAL_CLASS"
wait_until 'the removal password prompt owns the active terminal' 30 active_window_matches "$TERMINAL_CLASS"
wait_until 'the remover completes current-user browser trust cleanup before package removal' 60 \
  browser_cleanup_success_visible
remove_deadline=$((SECONDS + 180))
remove_password_sent=false
until ! pacman -Q "$PACKAGE_NAME" >/dev/null 2>&1; do
  if [[ $remove_password_sent == "false" ]] && pgrep -f '[s]udo pacman -Rns --noconfirm wordpress-studio-omarchy' >/dev/null && ! pgrep -x pacman >/dev/null; then
    wtype 'omarchy'
    wtype -k Return
    remove_password_sent=true
  fi
  (( SECONDS < remove_deadline )) || fail 'the native Studio package removes cleanly'
  sleep 1
done
pass 'the native Studio package removes cleanly'
wait_until 'the remover presents its completion screen' 60 screen_contains 'Done! Press any key'
screenshot 'success-studio-18-removed-terminal'
wtype -k space
wait_until 'the removal terminal closes' 30 window_absent "$TERMINAL_CLASS"
wait_until 'the Studio executable is removed' 30 test ! -e /usr/bin/studio
[[ ! -e /usr/bin/studio-omarchy-cleanup-user-trust ]] ||
  fail 'the standalone browser trust cleanup helper is removed with the package'
[[ ! -e /etc/ca-certificates/trust-source/anchors/studio-ca.crt ]] || fail 'the Studio trust anchor is removed with the package'
pass 'the Studio trust anchor is removed with the package'

click_bar_widget
wait_until 'the plugin returns to Not installed' 30 screen_contains 'Not installed'
screenshot 'success-studio-19-removed-panel'
omarchy-shell shell hide "$PLUGIN_ID" >/dev/null
wait_until 'the final Studio panel hides' 20 layer_absent omarchy-keyboard-panel
omarchy plugin disable "$PLUGIN_ID" >/dev/null
wait_until 'WordPress Studio is disabled after cleanup' 15 bar_widget_absent
omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null
wait_until 'WordPress Studio plugin is removed from disk' 15 test ! -e "$PLUGIN_DIR"
wait_until 'WordPress Studio plugin leaves the registry' 15 plugin_absent

pass 'WordPress Studio pointer-driven guest acceptance passed'
