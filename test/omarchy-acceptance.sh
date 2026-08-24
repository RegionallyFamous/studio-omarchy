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
CHROMIUM_EXE='/usr/lib/chromium/chromium'
STUDIO_CONFIG="$HOME/.studio/cli.json"
BUNDLED_NODE='/usr/lib/studio/resources/bin/node'
BUNDLED_CLI='/usr/lib/studio/resources/cli/main.mjs'
QMLLINT_BIN=$(command -v qmllint || true)
containment_root="/tmp/studio-status-containment-$$"
SITE_ONE_NAME='Omarchy Acceptance One'
SITE_ONE_DOMAIN='omarchy-acceptance-one.local'
SITE_TWO_NAME='Omarchy Acceptance Two'
SITE_ONE_ID=''
SITE_ONE_PATH=''
SITE_ONE_PORT=''
SITE_TWO_ID=''
SITE_TWO_PATH=''
SITE_TWO_PORT=''
SITE_REMOVAL_NAME='Omarchy Removal Preserve'
SITE_REMOVAL_PATH=''
SITE_REMOVAL_PORT=''
SITE_REMOVAL_RECORD_INVARIANTS=''
SITE_REMOVAL_SENTINEL_HASH=''
SITE_REMOVAL_WP_CONFIG_HASH=''
SITE_REMOVAL_WP_LOAD_HASH=''
SITE_REMOVAL_DATABASE_HASH=''
STUDIO_CA_PATH="$HOME/.studio/certificates/studio-ca.crt"
STUDIO_CA_KEY_PATH="$HOME/.studio/certificates/studio-ca.key"
STUDIO_SYSTEM_CA_PATH='/etc/ca-certificates/trust-source/anchors/studio-ca.crt'
STUDIO_NSS_NICKNAME='WordPress Studio CA'
UNRELATED_NSS_NICKNAME='Omarchy Acceptance Unrelated CA'
STANDARD_NSS_DB="$HOME/.pki/nssdb"
FIREFOX_NSS_DB="$HOME/.mozilla/firefox/omarchy-acceptance.default-release"
TRUST_FIXTURE_DIR="$containment_root/browser-trust"
STUDIO_CA_HASH=''
installed_package_before_update=''
studio_hash_before_update=''
pacman_log_line_before_update=''
PACKAGE_HANDOFF_BASELINE_IDENTITIES=''
bar_widget_click_index=0
: "${QMLLINT_BIN:=/usr/lib/qt6/bin/qmllint}"

# Visual evidence is part of the acceptance contract. Capture atomically and
# fail a passing step if its required screenshot cannot be written.
screenshot() {
  local name=$1 target="$ARTIFACTS/$1.png" temporary="$ARTIFACTS/.$1-${BASHPID}.png"

  rm -f "$temporary"
  if timeout 10 grim "$temporary" 2>/dev/null && [[ -s $temporary ]]; then
    mv -- "$temporary" "$target"
  else
    rm -f "$temporary"
    printf 'required screenshot failed: %s\n' "$name" >&2
    return 1
  fi
}

# Preserve the shared failure format while ensuring a screenshot failure never
# hides the actual assertion that failed.
fail() {
  local description=$1 detail=${2:-} step=${1,,}

  step=${step// /-}
  step=${step//[^a-z0-9-]/}
  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  screenshot "failure-$step" || true
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

screen_absent() {
  ! screen_contains "$1"
}

active_region_contains() {
  local text=$1 region=$2
  local left_pct top_pct right_pct bottom_pct window win_x win_y win_w win_h
  local crop_x crop_y crop_w crop_h snapshot scaled_snapshot status psm

  read -r left_pct top_pct right_pct bottom_pct <<<"$region"
  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || return 1
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  crop_x=$((win_x + win_w * left_pct / 100))
  crop_y=$((win_y + win_h * top_pct / 100))
  crop_w=$((win_w * (right_pct - left_pct) / 100))
  crop_h=$((win_h * (bottom_pct - top_pct) / 100))
  (( crop_w > 0 && crop_h > 0 )) || return 1
  snapshot="/tmp/omarchy-acceptance-active-region-${BASHPID}.png"
  scaled_snapshot="/tmp/omarchy-acceptance-active-region-scaled-${BASHPID}.png"

  if ! timeout 10 grim -g "$crop_x,$crop_y ${crop_w}x${crop_h}" "$snapshot" 2>/dev/null; then
    rm -f "$snapshot" "$scaled_snapshot"
    return 1
  fi

  status=1
  if tesseract "$snapshot" stdout --psm 11 2>/dev/null | grep -Fi -- "$text" >/dev/null; then
    status=0
  elif timeout 10 magick "$snapshot" -resize 200% "$scaled_snapshot" 2>/dev/null; then
    for psm in 11 6; do
      if tesseract "$scaled_snapshot" stdout --psm "$psm" 2>/dev/null | grep -Fi -- "$text" >/dev/null; then
        status=0
        break
      fi
    done
  fi
  rm -f "$snapshot" "$scaled_snapshot"
  return "$status"
}

active_region_absent() {
  ! active_region_contains "$1" "$2"
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

active_studio_update_notice() {
  hyprctl -j activewindow | jq -e --arg class "$STUDIO_CLASS" --arg title 'New Version Available' '
    .xwayland == false and .floating == true and
    ((.class // "") | test($class)) and (.title // "") == $title
  ' >/dev/null
}

studio_update_notice_present() {
  hyprctl -j clients | jq -e --arg class "$STUDIO_CLASS" --arg title 'New Version Available' '
    any(.[];
      .xwayland == false and .floating == true and
      ((.class // "") | test($class)) and (.title // "") == $title
    )
  ' >/dev/null
}

studio_update_notice_absent() {
  ! studio_update_notice_present
}

studio_welcome_or_update_notice_present() {
  studio_update_notice_present || screen_contains 'WordPress Studio'
}

dismiss_studio_update_notice_if_present() {
  local address

  if ! studio_update_notice_present; then
    return 0
  fi

  address=$(hyprctl -j clients | jq -er --arg class "$STUDIO_CLASS" --arg title 'New Version Available' '
    [.[] | select(
      .xwayland == false and .floating == true and
      ((.class // "") | test($class)) and (.title // "") == $title
    )]
    | if length == 1 then .[0].address else empty end
  ') || fail 'Studio exposes one update notice'
  hyprctl dispatch focuswindow "address:$address" >/dev/null ||
    fail 'the Studio update notice receives focus'
  wait_until 'the Studio update notice receives focus' 10 active_studio_update_notice
  active_region_contains 'New Version Available' '20 0 80 30' ||
    fail 'the Studio update notice paints its exact heading'
  click_active_phrase 'Later' '50 70 100 100' \
    'the optional Studio update notice Later button is clicked with the pointer'
  wait_until 'the Studio update notice closes through its safe Later action' 20 studio_update_notice_absent
  wait_until 'focus returns to Studio after the update notice' 20 active_window_matches "$STUDIO_CLASS"
}

active_chromium_browser() {
  local active pid executable

  active=$(hyprctl -j activewindow) || return 1
  pid=$(jq -er '.pid // empty' <<<"$active") || return 1
  executable=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  [[ $executable == "$CHROMIUM_EXE" ]]
}

browser_window_present() {
  local pid executable

  while read -r pid; do
    executable=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    [[ $executable == "$CHROMIUM_EXE" ]] && return 0
  done < <(hyprctl -j clients | jq -r '.[] | .pid // empty')
  return 1
}

browser_window_absent() {
  ! browser_window_present
}

active_chromium_terms() {
  active_chromium_browser &&
    hyprctl -j activewindow | jq -e '
      .xwayland == false and (.title // "") == "Chromium Additional Terms of Service"
    ' >/dev/null
}

chromium_terms_absent() {
  ! active_chromium_terms
}

dismiss_chromium_terms_if_needed() {
  local site_name=$1

  wait_until 'the browser activates its first-run terms or the requested site' 30 \
    browser_terms_or_site_active "$site_name"
  if active_chromium_terms; then
    click_active_bottom_right_control 'the Chromium first-run terms are accepted with the pointer'
    wait_until 'the Chromium first-run terms close' 30 chromium_terms_absent
  fi
}

active_native_browser_for_site() {
  local site_name=$1

  active_chromium_browser &&
    hyprctl -j activewindow | jq -e --arg site "$site_name" '
      .xwayland == false and ((.title // "") | contains($site))
    ' >/dev/null
}

browser_terms_or_site_active() {
  active_chromium_terms || active_native_browser_for_site "$1"
}

close_browser_windows() {
  local address pid executable

  while IFS=$'\t' read -r address pid; do
    executable=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    if [[ $executable == "$CHROMIUM_EXE" ]]; then
      hyprctl dispatch "hl.dsp.window.close({ window = \"address:$address\" })" >/dev/null 2>&1 ||
        hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1 || true
    fi
  done < <(hyprctl -j clients | jq -r '.[] | [(.address // ""), (.pid // 0)] | @tsv')
}

studio_processes_absent() {
  ! pgrep -f '^/usr/lib/studio/' >/dev/null
}

studio_remover_process_absent() {
  ! pgrep -u "$(id -u)" -f "^/bin/bash -p $PLUGIN_DIR/scripts/remove[.]sh( |$)" >/dev/null
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
  if [[ $button == "right" ]]; then
    park_pointer
  fi
  pass "$label"
}

click_screen_phrase() {
  click_phrase screen "$1" "${2:-0 0 100 100}" "$3"
}

click_active_phrase() {
  click_phrase active "$1" "${2:-0 0 100 100}" "$3"
}

# The agentic Studio sidebar uses source-fixed 34px rows with a 1px gap. Target
# the stable body of each row after exact visible-name waits, while keeping OCR
# for controls whose position or order can change.
click_active_site_row() {
  local row_index=$1 label=$2 button=${3:-left} park_after_click=${4:-true}
  local window win_x win_y win_w win_h target_x target_y click_code='0xC0' ready_name

  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || fail "$label"
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  (( row_index >= 0 && row_index < 20 && win_w >= 320 && win_h >= 180 )) ||
    fail "$label" 'the active Studio geometry or row index is outside the acceptance contract'
  target_x=$((win_x + 150))
  target_y=$((win_y + 49 + row_index * 35))
  move_pointer_exactly "$target_x" "$target_y" "$label"
  pointer_is_near "$target_x" "$target_y" || fail "$label" 'cursor assertion failed immediately before click'
  ready_name=${label,,}
  ready_name=${ready_name// /-}
  ready_name=${ready_name//[^a-z0-9-]/}
  screenshot "ready-studio-$ready_name-$button"
  [[ $button == "right" ]] && click_code='0xC1'
  ydotool click "$click_code" >/dev/null || fail "$label"
  if [[ $button == "right" && $park_after_click == "true" ]]; then
    park_pointer
  fi
  pass "$label"
}

# The destructive menu label is red and can disappear from Tesseract even when
# it is plainly rendered. The source-fixed site menu is anchored to the row and
# places Delete site in its final 35px item, centered 355px below that anchor.
click_active_site_delete_action() {
  local row_index=$1 label=$2
  local window win_x win_y win_w win_h target_x target_y ready_name

  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || fail "$label"
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  (( row_index >= 0 && row_index < 20 && win_w >= 320 && win_h >= 500 )) ||
    fail "$label" 'the active Studio geometry or row index is outside the acceptance contract'
  target_x=$((win_x + 190))
  target_y=$((win_y + 49 + row_index * 35 + 355))
  (( target_y <= win_y + win_h )) || fail "$label" 'the Delete site target falls outside the active window'
  move_pointer_exactly "$target_x" "$target_y" "$label"
  pointer_is_near "$target_x" "$target_y" || fail "$label" 'cursor assertion failed immediately before click'
  ready_name=${label,,}
  ready_name=${ready_name// /-}
  ready_name=${ready_name//[^a-z0-9-]/}
  screenshot "ready-studio-$ready_name-left"
  ydotool click 0xC0 >/dev/null || fail "$label"
  pass "$label"
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

click_active_relative_control() {
  local x_percent=$1 y_percent=$2 label=$3
  local window win_x win_y win_w win_h target_x target_y ready_name

  window=$(hyprctl -j activewindow | jq -ce '{at,size}') || fail "$label"
  read -r win_x win_y win_w win_h < <(jq -r '.at[0],.at[1],.size[0],.size[1]' <<<"$window" | xargs)
  target_x=$((win_x + win_w * x_percent / 100))
  target_y=$((win_y + win_h * y_percent / 100))
  move_pointer_exactly "$target_x" "$target_y" "$label"
  pointer_is_near "$target_x" "$target_y" || fail "$label" 'cursor assertion failed immediately before click'
  ready_name=${label,,}
  ready_name=${ready_name// /-}
  ready_name=${ready_name//[^a-z0-9-]/}
  screenshot "ready-studio-$ready_name-left"
  ydotool click 0xC0 >/dev/null || fail "$label"
  pass "$label"
}

# KeyboardPanel's layer surface intentionally spans the monitor, while its
# source-fixed 330px card is anchored at the top-right. Target the center of
# the third 40px action row directly: dark monospace button text is not a
# reliable Tesseract target even when the control is plainly rendered.
click_quattro_remove_control() {
  local label=$1
  local monitor target_x target_y ready_name

  monitor=$(hyprctl -j monitors | jq -ce 'if length == 1 then .[0] else empty end') ||
    fail "$label" 'the Quattro action requires exactly one guest monitor'
  target_x=$(jq -nr --argjson m "$monitor" '$m.x + ($m.width / $m.scale) - 170 | round')
  target_y=$(jq -nr --argjson m "$monitor" '$m.y + 188 | round')
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
  local verify_tooltip=${1:-true}
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
  if [[ $verify_tooltip == "true" ]]; then
    sleep 1
    resolve_phrase screen 'WordPress Studio' '80 0 100 10' 'the real Studio bar widget exposes its tooltip' >/dev/null
    pass 'the real Studio bar widget exposes its tooltip'
  fi
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
    # Base UI tooltips open after 600ms by default. Dwell beyond that contract
    # so the OCR check never races the popup animation on a fast guest.
    sleep 0.8
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

group_nonrunnable() {
  local pgid=$1
  ! ps -eo pgid=,stat= | awk -v target="$pgid" '$1 == target && $2 !~ /^Z/ { found = 1 } END { exit found ? 0 : 1 }'
}

pid_nonrunnable() {
  local pid=$1 state

  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  [[ -z $state || $state == Z* ]]
}

pids_nonrunnable() {
  local pid

  for pid in "$@"; do
    pid_nonrunnable "$pid" || return 1
  done
}

pid_cmdline_has_argument() {
  local pid=$1 expected=$2 argument

  [[ -r /proc/$pid/cmdline ]] || return 1
  while IFS= read -r -d '' argument; do
    [[ $argument == "$expected" ]] && return 0
  done <"/proc/$pid/cmdline"
  return 1
}

find_remove_outer_controller_pid() {
  local parent_pid=$1 candidate executable

  while read -r candidate; do
    [[ $candidate =~ ^[0-9]+$ ]] || continue
    executable=$(readlink -f "/proc/$candidate/exe" 2>/dev/null || true)
    [[ $executable == "/usr/bin/timeout" ]] || continue
    pid_cmdline_has_argument "$candidate" '--signal=TERM' || continue
    pid_cmdline_has_argument "$candidate" '--kill-after=2s' || continue
    pid_cmdline_has_argument "$candidate" '80s' || continue
    pid_cmdline_has_argument "$candidate" 'systemd-run' || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(pgrep -P "$parent_pid" || true)
  return 1
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
  sed "s|/usr/bin/pacman|$run_root/bin/pacman|" \
    "$FIXTURE/scripts/status.sh" >"$run_root/status.sh"
  chmod 755 "$run_root/status.sh"
  PATH="$run_root/bin:$PATH" STUDIO_STATUS_CHILD_PID="$run_root/child.pid" \
    "$run_root/status.sh" >"$run_root/output" 2>"$run_root/error" &
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
  : >"$run_root/child.pid"
  : >"$run_root/controller.pid"
}

exercise_status_pre_ready_containment() {
  local run_root="$containment_root/status-pre-ready-sigkill"
  local controller_pid controller_status

  mkdir -p "$run_root/bin"
  mkfifo "$run_root/hold-before-query"
  sed "s|/usr/bin/pacman|$run_root/bin/pacman|" \
    "$FIXTURE/scripts/status.sh" >"$run_root/status.base.sh"
  awk '
    $0 == "raw_hex=$(" {
      print "if [[ -n ${STUDIO_STATUS_HOLD_BEFORE_QUERY:-} ]]; then"
      print "  printf \"%s\\n\" \"$$\" >\"$STUDIO_STATUS_CONTROLLER_HELD\""
      print "  IFS= read -r _ <\"$STUDIO_STATUS_HOLD_BEFORE_QUERY\""
      print "fi"
    }
    { print }
  ' "$run_root/status.base.sh" >"$run_root/status.sh"
  chmod 755 "$run_root/status.sh"
  cat >"$run_root/bin/pacman" <<'STUB'
#!/bin/bash
printf '%s\n' "$$" >"$STUDIO_STATUS_CHILD_PID"
while :; do sleep 1; done
STUB
  chmod 755 "$run_root/bin/pacman"

  PATH="$run_root/bin:$PATH" \
    STUDIO_STATUS_HOLD_BEFORE_QUERY="$run_root/hold-before-query" \
    STUDIO_STATUS_CONTROLLER_HELD="$run_root/controller-held" \
    STUDIO_STATUS_CHILD_PID="$run_root/child.pid" \
    "$run_root/status.sh" >"$run_root/output" 2>"$run_root/error" &
  controller_pid=$!
  printf '%s\n' "$controller_pid" >"$run_root/controller.pid"
  wait_until 'the status controller is held before its bounded query starts' 5 \
    test -s "$run_root/controller-held"
  ps -o pid,ppid,pgid,sid,stat,comm -p "$controller_pid" \
    >>"$ARTIFACTS/studio-status-topology.log"

  kill -KILL "$controller_pid"
  if wait "$controller_pid" 2>/dev/null; then
    controller_status=0
  else
    controller_status=$?
  fi
  (( controller_status == 137 )) || fail 'the pre-query status SIGKILL records its controller death'
  [[ ! -e $run_root/child.pid ]] || fail 'pre-query status controller death never starts pacman'
  pass 'pre-query status controller death remains fail-closed'
  : >"$run_root/controller.pid"
}

exercise_remove_runtime_resolution() {
  local run_root="$containment_root/remove-runtime-resolution"
  local injected_status=0

  mkdir -p "$run_root/scripts" "$run_root/bin" "$run_root/injected-omarchy/bin"
  cp -- "$FIXTURE/scripts/remove.sh" "$run_root/scripts/remove.sh"
  chmod 755 "$run_root/scripts/remove.sh"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"$run_root/scripts/cleanup-user-trust.sh"
  chmod 755 "$run_root/scripts/cleanup-user-trust.sh"
  cat >"$run_root/bin/omarchy-pkg-drop" <<'STUB'
#!/bin/bash
printf 'PATH-injected helper ran\n' >>"$STUDIO_REMOVE_INJECTED_LOG"
STUB
  chmod 755 "$run_root/bin/omarchy-pkg-drop"
  cat >"$run_root/injected-omarchy/bin/omarchy-pkg-drop" <<'STUB'
#!/bin/bash
printf 'OMARCHY_PATH-injected helper ran\n' >>"$STUDIO_REMOVE_INJECTED_LOG"
STUB
  chmod 755 "$run_root/injected-omarchy/bin/omarchy-pkg-drop"

  if ! OMARCHY_PATH='/usr/share/omarchy' PATH="$run_root/bin:$PATH" \
    STUDIO_REMOVE_INJECTED_LOG="$run_root/injected.log" \
    "$run_root/scripts/remove.sh" >"$run_root/path-output" 2>"$run_root/path-error" </dev/null; then
    fail 'the package-absent remover accepts the configured Omarchy runtime' \
      "$(<"$run_root/path-error")"
  fi
  [[ ! -e $run_root/injected.log ]] || fail 'the remover ignores a PATH-injected package helper'
  pass 'the remover ignores a PATH-injected package helper'

  if OMARCHY_PATH="$run_root/injected-omarchy" PATH="$run_root/bin:$PATH" \
    STUDIO_REMOVE_INJECTED_LOG="$run_root/injected.log" \
    "$run_root/scripts/remove.sh" >"$run_root/config-output" 2>"$run_root/config-error" </dev/null; then
    fail 'the remover rejects an OMARCHY_PATH that differs from the root-managed configuration'
  else
    injected_status=$?
  fi
  (( injected_status == 130 )) ||
    fail 'the OMARCHY_PATH-injected remover returns its fail-closed status'
  grep -qF 'does not match its system configuration' "$run_root/config-error" ||
    fail 'the OMARCHY_PATH-injected remover reports its configuration mismatch'
  [[ ! -e $run_root/injected.log ]] || fail 'the remover never executes an OMARCHY_PATH-injected helper'
  pass 'the remover rejects an OMARCHY_PATH-injected package helper'
}

exercise_remove_pre_ready_containment() {
  local run_root="$containment_root/remove-pre-ready-sigkill"
  local controller_pid controller_status outer_pid worker_cgroup worker_pid

  mkdir -p "$run_root/scripts" "$run_root/studio/resources/bin" "$run_root/studio/resources/cli" "$run_root/bin"
  sed -e "s|studio_root='/usr/lib/studio'|studio_root='$run_root/studio'|" \
    -e 's/RuntimeMaxSec=70s/RuntimeMaxSec=8s/' \
    -e 's/TimeoutStopSec=5s/TimeoutStopSec=1s/' \
    -e 's/--kill-after=5s 60s/--kill-after=1s 4s/' \
    "$FIXTURE/scripts/remove.sh" >"$run_root/scripts/remove.base.sh"
  awk '
    { print }
    $0 == "    umask 077" {
      print "    if [[ -n ${STUDIO_REMOVE_TEST_PRE_READY_PID:-} ]]; then"
      print "      printf \"%s\\n\" \"$$\" >\"$STUDIO_REMOVE_TEST_PRE_READY_PID\""
      print "      while :; do sleep 1; done"
      print "    fi"
    }
  ' "$run_root/scripts/remove.base.sh" >"$run_root/scripts/remove.sh"
  chmod 755 "$run_root/scripts/remove.sh"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"$run_root/scripts/cleanup-user-trust.sh"
  chmod 755 "$run_root/scripts/cleanup-user-trust.sh"
  : >"$run_root/studio/resources/cli/main.mjs"
  cat >"$run_root/studio/resources/bin/node" <<'STUB'
#!/bin/bash
printf 'unexpected node start\n' >"$STUDIO_REMOVE_TEST_NODE_STARTED"
while :; do sleep 1; done
STUB
  chmod 755 "$run_root/studio/resources/bin/node"
  cat >"$run_root/bin/omarchy-pkg-drop" <<'STUB'
#!/bin/bash
printf 'unexpected package removal\n' >>"$STUDIO_REMOVE_PACKAGE_LOG"
STUB
  chmod 755 "$run_root/bin/omarchy-pkg-drop"

  PATH="$run_root/bin:$PATH" \
    STUDIO_REMOVE_TEST_PRE_READY_PID="$run_root/worker.pid" \
    STUDIO_REMOVE_TEST_NODE_STARTED="$run_root/node-started" \
    STUDIO_REMOVE_PACKAGE_LOG="$run_root/package.log" \
    "$run_root/scripts/remove.sh" >"$run_root/output" 2>"$run_root/error" </dev/null &
  controller_pid=$!
  printf '%s\n' "$controller_pid" >"$run_root/controller.pid"
  wait_until 'the pre-ready removal worker starts behind its closed gate' 12 test -s "$run_root/worker.pid"
  worker_pid=$(<"$run_root/worker.pid")
  wait_until 'the pre-ready removal controller owns its bounded direct child' 5 \
    find_remove_outer_controller_pid "$controller_pid"
  outer_pid=$(find_remove_outer_controller_pid "$controller_pid")
  worker_cgroup=$(awk -F: '$1 == "0" { print $3 }' "/proc/$worker_pid/cgroup")
  [[ $worker_cgroup == /user.slice/*/studio-remove-*.scope ]] ||
    fail 'the pre-ready removal worker is contained before its gate can open'
  pass 'the pre-ready removal worker is contained before its gate can open'
  ps -o pid,ppid,pgid,sid,stat,comm -p "$controller_pid,$outer_pid,$worker_pid" \
    >>"$ARTIFACTS/studio-remove-topology.log"
  printf '%s %s\n' "$worker_pid" "$worker_cgroup" >>"$ARTIFACTS/studio-remove-cgroups.log"

  kill -KILL "$controller_pid"
  if wait "$controller_pid" 2>/dev/null; then
    controller_status=0
  else
    controller_status=$?
  fi
  (( controller_status == 137 )) || fail 'the pre-ready SIGKILL records its controller death'
  wait_until 'pre-ready controller death leaves no runnable removal worker or direct child' 15 \
    pids_nonrunnable "$worker_pid" "$outer_pid"
  [[ ! -e $run_root/node-started ]] || fail 'pre-ready controller death never opens the Node start gate'
  [[ ! -e $run_root/package.log ]] || fail 'pre-ready controller death never reaches package removal'
  pass 'pre-ready controller death remains fail-closed'
  : >"$run_root/controller.pid"
  : >"$run_root/worker.pid"
}

exercise_remove_containment() {
  local mode=$1 run_root="$containment_root/remove-$1"
  local controller_pid node_pid nested_pid detached_pid controller_status pid
  local expected_cgroup='' worker_cgroup

  mkdir -p "$run_root/scripts" "$run_root/studio/resources/bin" "$run_root/studio/resources/cli" "$run_root/bin"
  sed -e "s|studio_root='/usr/lib/studio'|studio_root='$run_root/studio'|" \
    -e 's/RuntimeMaxSec=70s/RuntimeMaxSec=8s/' \
    -e 's/TimeoutStopSec=5s/TimeoutStopSec=1s/' \
    -e 's/--kill-after=5s 60s/--kill-after=1s 4s/' \
    "$FIXTURE/scripts/remove.sh" >"$run_root/scripts/remove.sh"
  chmod 755 "$run_root/scripts/remove.sh"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"$run_root/scripts/cleanup-user-trust.sh"
  chmod 755 "$run_root/scripts/cleanup-user-trust.sh"
  : >"$run_root/studio/resources/cli/main.mjs"
  cat >"$run_root/studio/resources/bin/node" <<'STUB'
#!/bin/bash
trap '' HUP INT TERM
set -m
bash -c 'trap "" HUP INT TERM; while :; do sleep 1; done' &
nested_pid=$!
set +m
setsid bash -c 'trap "" HUP INT TERM; while :; do sleep 1; done' &
detached_pid=$!
printf '%s %s %s\n' "$$" "$nested_pid" "$detached_pid" >"$STUDIO_REMOVE_TEST_PIDS"
while :; do sleep 1; done
STUB
  chmod 755 "$run_root/studio/resources/bin/node"
  cat >"$run_root/bin/omarchy-pkg-drop" <<'STUB'
#!/bin/bash
printf 'unexpected package removal\n' >>"$STUDIO_REMOVE_PACKAGE_LOG"
STUB
  chmod 755 "$run_root/bin/omarchy-pkg-drop"

  PATH="$run_root/bin:$PATH" STUDIO_REMOVE_TEST_PIDS="$run_root/pids" \
    STUDIO_REMOVE_PACKAGE_LOG="$run_root/package.log" \
    "$run_root/scripts/remove.sh" >"$run_root/output" 2>"$run_root/error" </dev/null &
  controller_pid=$!
  printf '%s\n' "$controller_pid" >"$run_root/controller.pid"
  wait_until "the remover $mode containment worker starts" 12 test -s "$run_root/pids"
  read -r node_pid nested_pid detached_pid <"$run_root/pids"
  ps -o pid,ppid,pgid,sid,stat,comm -p "$controller_pid,$node_pid,$nested_pid,$detached_pid" \
    >>"$ARTIFACTS/studio-remove-topology.log"
  for pid in "$node_pid" "$nested_pid" "$detached_pid"; do
    printf '%s ' "$pid" >>"$ARTIFACTS/studio-remove-cgroups.log"
    cat "/proc/$pid/cgroup" >>"$ARTIFACTS/studio-remove-cgroups.log"
    worker_cgroup=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
    [[ $worker_cgroup == /user.slice/*/studio-remove-*.scope ]] ||
      fail "the remover $mode worker is inside a Studio removal scope"
    if [[ -z $expected_cgroup ]]; then
      expected_cgroup=$worker_cgroup
    else
      [[ $worker_cgroup == "$expected_cgroup" ]] ||
        fail "the remover $mode descendants share one verified scope"
    fi
  done
  pass "the remover $mode descendants share one verified scope"

  if [[ $mode == "term" ]]; then
    kill -TERM "$controller_pid"
  else
    kill -KILL "$controller_pid"
  fi
  if wait "$controller_pid" 2>/dev/null; then
    controller_status=0
  else
    controller_status=$?
  fi
  if [[ $mode == "term" ]]; then
    (( controller_status == 130 )) || fail 'the TERM-cancelled remover returns its cancellation status'
  else
    (( controller_status == 137 )) || fail 'the SIGKILLed remover records its controller death'
  fi
  wait_until "the remover $mode cgroup contains no runnable test descendants" 15 \
    pids_nonrunnable "$node_pid" "$nested_pid" "$detached_pid"
  [[ ! -e $run_root/package.log ]] || fail "the remover $mode containment path never reaches package removal"
  pass "the remover $mode containment path never reaches package removal"
  : >"$run_root/controller.pid"
  : >"$run_root/pids"
}

package_handoff_process_identity() {
  local pid=$1 start_time

  [[ -r /proc/$pid/stat ]] || return 1
  start_time=$(awk '{ print $22 }' "/proc/$pid/stat") || return 1
  [[ $start_time =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s\n' "$pid" "$start_time"
}

record_package_handoff_baseline() {
  local pid identity

  PACKAGE_HANDOFF_BASELINE_IDENTITIES=''
  while IFS= read -r pid; do
    identity=$(package_handoff_process_identity "$pid") || continue
    PACKAGE_HANDOFF_BASELINE_IDENTITIES+="$identity"$'\n'
  done < <(pgrep -f '[s]udo /usr/bin/bash -c .*wordpress-studio-omarchy-' || true)
}

find_current_package_handoff_pid() {
  local pid identity match='' count=0

  while IFS= read -r pid; do
    identity=$(package_handoff_process_identity "$pid") || continue
    if [[ -n $PACKAGE_HANDOFF_BASELINE_IDENTITIES ]] &&
      grep -Fxq "$identity" <<<"$PACKAGE_HANDOFF_BASELINE_IDENTITIES"; then
      continue
    fi
    match=$pid
    (( count += 1 ))
  done < <(pgrep -f '[s]udo /usr/bin/bash -c .*wordpress-studio-omarchy-' || true)
  (( count == 1 )) || return 1
  printf '%s\n' "$match"
}

real_root_handoff_present() {
  local run_root=$1

  pgrep -f "[s]udo /usr/bin/bash -p -s -- $run_root" >/dev/null
}

verified_package_handoff_present() {
  find_current_package_handoff_pid >/dev/null
}

verify_package_handoff_contract() {
  local pid root_script package_path package_name actual_hash hash_limit
  local staged_path_literal="\$staged_path"
  local copy_limit_assignment="copy_limit=\$((max_bytes + 1))"
  local copy_limit_argument="count=\"\$copy_limit\""
  local staged_hash_guard="[[ \$staged_hash == \"\$expected_hash\" ]]"
  local metadata_guard="[[ \$staged_type == \"regular file\" && \$staged_uid == 0 && \$staged_gid == 0 &&"
  local bounded_hash_script="set -o pipefail; /usr/bin/head -c \"\$1\" \"\$2\" | /usr/bin/sha256sum | /usr/bin/cut -d \" \" -f 1"
  local cleanup_rm="/usr/bin/rm -rf -- \"\$staging_dir\""
  local -a arguments

  pid=$(find_current_package_handoff_pid) || return 1
  mapfile -d '' -t arguments <"/proc/$pid/cmdline" || return 1
  (( ${#arguments[@]} == 9 )) || return 1
  [[ ${arguments[0]##*/} == "sudo" && ${arguments[1]} == "/usr/bin/bash" &&
    ${arguments[2]} == "-c" && ${arguments[4]} == "bash" && ${arguments[5]} == /* &&
    ${arguments[7]} =~ ^[0-9a-f]{64}$ && ${arguments[8]} == "2147483648" ]] || return 1
  root_script=${arguments[3]}
  package_path=${arguments[5]}
  package_name=${arguments[6]}
  [[ ${package_path##*/} == "$package_name" ]] || return 1
  [[ $package_name =~ ^wordpress-studio-omarchy-([0-9]+\.[0-9]+\.[0-9]+)-[1-9][0-9]*-x86_64\.pkg\.tar\.zst$ ]] || return 1
  [[ ${BASH_REMATCH[1]} == "$PLUGIN_VERSION" ]] || return 1
  [[ -f $package_path && ! -L $package_path && -s $package_path ]] || return 1
  hash_limit=$(( arguments[8] + 1 ))
  actual_hash=$(
    /usr/bin/timeout --signal=TERM --kill-after=5s 120s \
      /usr/bin/bash -c "$bounded_hash_script" \
      bash "$hash_limit" "$package_path"
  ) || return 1
  [[ $actual_hash == "${arguments[7]}" ]] || return 1
  grep -qF '/usr/bin/mktemp -d /var/tmp/studio-omarchy-install.XXXXXXXXXX' <<<"$root_script" &&
    grep -qF 'trap cleanup EXIT' <<<"$root_script" &&
    grep -qF "$cleanup_rm" <<<"$root_script" &&
    grep -qF "$copy_limit_assignment" <<<"$root_script" &&
    (( $(grep -cF '/usr/bin/timeout --signal=TERM --kill-after=5s 120s' <<<"$root_script") >= 2 )) &&
    grep -qF '/usr/bin/dd' <<<"$root_script" &&
    grep -qF 'iflag=nofollow,nonblock,fullblock,count_bytes' <<<"$root_script" &&
    grep -qF "$copy_limit_argument" <<<"$root_script" &&
    grep -qF "/usr/bin/chmod 600 -- \"$staged_path_literal\"" <<<"$root_script" &&
    grep -qF '/usr/bin/stat -c "%F|%u|%g|%a|%h|%s"' <<<"$root_script" &&
    grep -qF "$metadata_guard" <<<"$root_script" &&
    grep -qF "/usr/bin/sha256sum \"$staged_path_literal\"" <<<"$root_script" &&
    grep -qF "$staged_hash_guard" <<<"$root_script" &&
    grep -qF "/usr/bin/pacman -U --needed --noconfirm -- \"$staged_path_literal\"" <<<"$root_script"
}

extract_installer_privileged_handoff() {
  local installer=$1 line collecting=false complete=false

  while IFS= read -r line; do
    if [[ $collecting == "false" ]]; then
      if [[ $line == "  /usr/bin/sudo /usr/bin/bash -c '" ]]; then
        collecting=true
      fi
    elif [[ $line == "' bash \"\$source_path\" \"\$package_name\" \"\$expected_hash\" \"\$max_bytes\"" ]]; then
      complete=true
      break
    else
      printf '%s\n' "$line"
    fi
  done <"$installer"

  [[ $collecting == "true" && $complete == "true" ]]
}

verify_installed_runtime_contract() {
  local operation=$1 integrity='/usr/lib/studio/.omarchy-runtime-integrity'
  local sandbox_metadata node_metadata integrity_metadata sandbox_hash node_hash capability
  local -a records=()

  [[ -f /usr/lib/studio/chrome-sandbox && ! -L /usr/lib/studio/chrome-sandbox &&
    -f $BUNDLED_NODE && ! -L $BUNDLED_NODE &&
    -f $integrity && ! -L $integrity ]] ||
    fail "$operation installs only regular privileged runtime files"
  sandbox_metadata=$(LC_ALL=C /usr/bin/stat -c '%F|%u|%g|%a|%h' -- /usr/lib/studio/chrome-sandbox) ||
    fail "$operation exposes the Chromium sandbox metadata"
  node_metadata=$(LC_ALL=C /usr/bin/stat -c '%F|%u|%g|%a|%h' -- "$BUNDLED_NODE") ||
    fail "$operation exposes the bundled Node metadata"
  integrity_metadata=$(LC_ALL=C /usr/bin/stat -c '%F|%u|%g|%a|%h' -- "$integrity") ||
    fail "$operation exposes the runtime integrity metadata"
  [[ $sandbox_metadata == 'regular file|0|0|4755|1' &&
    $node_metadata == 'regular file|0|0|755|1' &&
    $integrity_metadata == 'regular file|0|0|644|1' ]] ||
    fail "$operation preserves exact root ownership, modes, and single links for privileged runtime files"

  mapfile -t records <"$integrity"
  (( ${#records[@]} == 2 )) || fail "$operation installs exactly two runtime integrity records"
  [[ ${records[0]} =~ ^([0-9a-f]{64})\ \ chrome-sandbox$ ]] ||
    fail "$operation installs the exact Chromium sandbox integrity record"
  sandbox_hash=${BASH_REMATCH[1]}
  [[ ${records[1]} =~ ^([0-9a-f]{64})\ \ resources/bin/node$ ]] ||
    fail "$operation installs the exact bundled Node integrity record"
  node_hash=${BASH_REMATCH[1]}
  [[ $(/usr/bin/sha256sum -- /usr/lib/studio/chrome-sandbox) == "$sandbox_hash  /usr/lib/studio/chrome-sandbox" &&
    $(/usr/bin/sha256sum -- "$BUNDLED_NODE") == "$node_hash  $BUNDLED_NODE" ]] ||
    fail "$operation privileged runtime bytes match the root-owned integrity manifest"

  capability=$(/usr/bin/getcap "$BUNDLED_NODE") ||
    fail "$operation reads the bundled Node file capability"
  [[ $capability == "$BUNDLED_NODE cap_net_bind_service=ep" ]] ||
    fail "$operation grants only the exact privileged-port capability to bundled Node"
  [[ -z $(/usr/bin/getcap /usr/lib/studio/studio) &&
    -z $(/usr/bin/getcap /usr/lib/studio/chrome-sandbox) ]] ||
    fail "$operation does not grant file capabilities to Electron or the Chromium sandbox"
  pass "$operation installs exact root-owned runtime bytes and the bounded Node capability"
}

exercise_real_privileged_handoff() {
  local run_root="$containment_root/privileged-handoff" installer="$PLUGIN_DIR/install.sh"
  local package_name='wordpress-studio-omarchy-0.0.1-1-x86_64.pkg.tar.zst'
  local safe_source safe_bytes safe_hash oversize_hash handoff_script handoff_encoded handoff_hash
  local fake_pacman fake_pacman_encoded root_driver root_driver_encoded terminal_command result
  local acceptance_uid acceptance_gid installed_package_before_handoff launcher_pid

  safe_source="$run_root/safe/$package_name"
  result="$run_root/result"
  mkdir -p "$run_root/safe" "$run_root/symlink" "$run_root/fifo" "$run_root/oversize"
  chmod 700 "$run_root" "$run_root/safe" "$run_root/symlink" "$run_root/fifo" "$run_root/oversize"
  printf '%s' 'exact-root-handoff' >"$safe_source"
  safe_bytes=$(/usr/bin/wc -c <"$safe_source")
  safe_hash=$(/usr/bin/sha256sum "$safe_source")
  safe_hash=${safe_hash%% *}
  /usr/bin/ln -s -- "$safe_source" "$run_root/symlink/$package_name"
  /usr/bin/mkfifo "$run_root/fifo/$package_name"
  /usr/bin/cp -- "$safe_source" "$run_root/oversize/$package_name"
  printf 'x' >>"$run_root/oversize/$package_name"
  oversize_hash=$(/usr/bin/sha256sum "$run_root/oversize/$package_name")
  oversize_hash=${oversize_hash%% *}

  handoff_script=$(extract_installer_privileged_handoff "$installer") ||
    fail 'the guest extracts the exact installer privileged handoff without rewriting it'
  # shellcheck disable=SC2016 # Match the literal production staged-path variable.
  [[ $handoff_script == *'/usr/bin/dd'* &&
    $handoff_script == *'iflag=nofollow,nonblock,fullblock,count_bytes'* &&
    $handoff_script == *'/usr/bin/pacman -U --needed --noconfirm -- "$staged_path"'* ]] ||
    fail 'the extracted installer handoff retains its nofollow copy and fixed package boundary'
  handoff_encoded=$(printf '%s\n' "$handoff_script" | /usr/bin/base64 --wrap=0)
  handoff_hash=$(printf '%s\n' "$handoff_script" | /usr/bin/sha256sum)
  handoff_hash=${handoff_hash%% *}

  IFS= read -r -d '' fake_pacman <<'FAKE_PACMAN' || true
#!/bin/bash -p
set -Eeuo pipefail
readonly PATH='/usr/bin:/usr/sbin'
export PATH
unset BASH_ENV ENV CDPATH

[[ $# == 5 && $1 == '-U' && $2 == '--needed' && $3 == '--noconfirm' && $4 == '--' ]]
staged_path=$5
staging_dir=${staged_path%/*}
[[ $staging_dir == /var/tmp/studio-omarchy-install.* &&
  $staged_path == "$staging_dir/$STUDIO_HANDOFF_PACKAGE_NAME" ]]
directory_metadata=$(/usr/bin/stat -c '%F|%u|%g|%a' -- "$staging_dir")
file_metadata=$(/usr/bin/stat -c '%F|%u|%g|%a|%h|%s' -- "$staged_path")
actual_hash=$(/usr/bin/sha256sum -- "$staged_path")
actual_hash=${actual_hash%% *}
[[ $directory_metadata == 'directory|0|0|700' &&
  $file_metadata == "regular file|0|0|600|1|$STUDIO_HANDOFF_EXPECTED_BYTES" &&
  $actual_hash == "$STUDIO_HANDOFF_EXPECTED_HASH" ]]
printf 'safe|%s|%s|%s|%s\n' \
  "$directory_metadata" "$file_metadata" "$actual_hash" "$staged_path" \
  >"$STUDIO_HANDOFF_RESULT"
/usr/bin/chown "$STUDIO_HANDOFF_ACCEPTANCE_UID:$STUDIO_HANDOFF_ACCEPTANCE_GID" \
  "$STUDIO_HANDOFF_RESULT"
FAKE_PACMAN
  fake_pacman_encoded=$(printf '%s\n' "$fake_pacman" | /usr/bin/base64 --wrap=0)

  IFS= read -r -d '' root_driver <<'ROOT_DRIVER' || true
set -Eeuo pipefail
readonly PATH='/usr/bin:/usr/sbin'
export PATH
unset BASH_ENV ENV CDPATH

run_root=$1
handoff_encoded=$2
handoff_hash=$3
fake_pacman_encoded=$4
acceptance_uid=$5
acceptance_gid=$6
package_name=$7
safe_hash=$8
safe_bytes=$9
oversize_hash=${10}
result="$run_root/result"
root_fixture=''

report_exit() {
  local status=$? line=${BASH_LINENO[0]:-0} command=${BASH_COMMAND:-unknown}

  if (( status != 0 )); then
    /usr/bin/printf 'FAIL status=%s line=%s command=%q\n' "$status" "$line" "$command" >"$result" || true
    /usr/bin/chown "$acceptance_uid:$acceptance_gid" "$result" 2>/dev/null || true
  fi
  if [[ -n $root_fixture && $root_fixture == /var/tmp/studio-omarchy-handoff-test.* ]]; then
    /usr/bin/rm -rf -- "$root_fixture"
  fi
  exit "$status"
}
trap report_exit EXIT

[[ $run_root == /tmp/studio-status-containment-*/privileged-handoff &&
  $acceptance_uid =~ ^[1-9][0-9]*$ && $acceptance_gid =~ ^[0-9]+$ &&
  $package_name =~ ^wordpress-studio-omarchy-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*-x86_64\.pkg\.tar\.zst$ &&
  $safe_hash =~ ^[0-9a-f]{64}$ && $oversize_hash =~ ^[0-9a-f]{64}$ &&
  $handoff_hash =~ ^[0-9a-f]{64}$ && $safe_bytes =~ ^[1-9][0-9]*$ ]]
root_fixture=$(/usr/bin/mktemp -d /var/tmp/studio-omarchy-handoff-test.XXXXXXXXXX)
[[ $root_fixture == /var/tmp/studio-omarchy-handoff-test.* &&
  $(/usr/bin/stat -c '%F|%u|%g|%a' -- "$root_fixture") == 'directory|0|0|700' ]]
/usr/bin/printf '%s' "$handoff_encoded" | /usr/bin/base64 --decode >"$root_fixture/handoff.sh"
/usr/bin/printf '%s' "$fake_pacman_encoded" | /usr/bin/base64 --decode >"$root_fixture/pacman"
/usr/bin/chmod 700 "$root_fixture/handoff.sh" "$root_fixture/pacman"
[[ $(/usr/bin/sha256sum "$root_fixture/handoff.sh") == "$handoff_hash  $root_fixture/handoff.sh" &&
  $(/usr/bin/stat -c '%F|%u|%g|%a|%h' -- "$root_fixture/handoff.sh") == 'regular file|0|0|700|1' &&
  $(/usr/bin/stat -c '%F|%u|%g|%a|%h' -- "$root_fixture/pacman") == 'regular file|0|0|700|1' ]]
host_pacman_hash=$(/usr/bin/sha256sum /usr/bin/pacman)
host_pacman_hash=${host_pacman_hash%% *}

run_case() {
  local source_path=$1 expected_hash=$2 max_bytes=$3 marker=$4 ready="$4.namespace-ready"
  local status=0

  /usr/bin/rm -f -- "$marker" "$ready"
  # shellcheck disable=SC2016 # Expanded only by the isolated namespace Bash.
  /usr/bin/timeout --signal=TERM --kill-after=2s 20s \
    /usr/bin/env -i \
      PATH=/usr/bin:/usr/sbin \
      LC_ALL=C \
      STUDIO_HANDOFF_ACCEPTANCE_GID="$acceptance_gid" \
      STUDIO_HANDOFF_ACCEPTANCE_UID="$acceptance_uid" \
      STUDIO_HANDOFF_EXPECTED_BYTES="$safe_bytes" \
      STUDIO_HANDOFF_EXPECTED_HASH="$expected_hash" \
      STUDIO_HANDOFF_NAMESPACE_READY="$ready" \
      STUDIO_HANDOFF_PACKAGE_NAME="$package_name" \
      STUDIO_HANDOFF_RESULT="$marker" \
      /usr/bin/unshare --mount --propagation private \
        /usr/bin/bash -p -c '
          set -Eeuo pipefail
          /usr/bin/mount --bind "$1" /usr/bin/pacman
          /usr/bin/cmp --silent -- "$1" /usr/bin/pacman
          /usr/bin/printf "%s\n" ready >"$STUDIO_HANDOFF_NAMESPACE_READY"
          /usr/bin/chown "$STUDIO_HANDOFF_ACCEPTANCE_UID:$STUDIO_HANDOFF_ACCEPTANCE_GID" \
            "$STUDIO_HANDOFF_NAMESPACE_READY"
          root_script=$(/usr/bin/base64 --decode "$2")
          /usr/bin/bash -c "$root_script" bash "$3" "$4" "$5" "$6"
        ' bash "$root_fixture/pacman" "$root_fixture/handoff.sh" \
          "$source_path" "$package_name" "$expected_hash" "$max_bytes" || status=$?
  [[ -f $ready && ! -L $ready &&
    $(/usr/bin/stat -c '%u:%g:%h:%F' -- "$ready") == "$acceptance_uid:$acceptance_gid:1:regular file" ]] ||
    return 90
  /usr/bin/rm -f -- "$ready"
  return "$status"
}

safe_marker="$run_root/safe-pacman"
run_case "$run_root/safe/$package_name" "$safe_hash" "$safe_bytes" "$safe_marker"
IFS='|' read -r label directory_type directory_uid directory_gid directory_mode \
  file_type file_uid file_gid file_mode file_links file_bytes recorded_hash staged_path \
  <"$safe_marker"
[[ $label == 'safe' && $directory_type == 'directory' && $directory_uid == 0 &&
  $directory_gid == 0 && $directory_mode == 700 && $file_type == 'regular file' &&
  $file_uid == 0 && $file_gid == 0 && $file_mode == 600 && $file_links == 1 &&
  $file_bytes == "$safe_bytes" && $recorded_hash == "$safe_hash" &&
  $staged_path == /var/tmp/studio-omarchy-install.*/* &&
  ! -e $staged_path && ! -L $staged_path ]]

expect_rejection() {
  local source_path=$1 expected_hash=$2 max_bytes=$3 marker=$4 status=0

  run_case "$source_path" "$expected_hash" "$max_bytes" "$marker" || status=$?
  [[ $status == 1 && ! -e $marker && ! -L $marker ]]
}

expect_rejection "$run_root/symlink/$package_name" "$safe_hash" "$safe_bytes" \
  "$run_root/symlink-pacman"
expect_rejection "$run_root/fifo/$package_name" "$safe_hash" "$safe_bytes" \
  "$run_root/fifo-pacman"
expect_rejection "$run_root/oversize/$package_name" "$oversize_hash" "$safe_bytes" \
  "$run_root/oversize-pacman"
[[ $(/usr/bin/sha256sum /usr/bin/pacman) == "$host_pacman_hash  /usr/bin/pacman" ]]

/usr/bin/printf '%s\n' PASS >"$result"
/usr/bin/chown "$acceptance_uid:$acceptance_gid" "$result"
ROOT_DRIVER
  root_driver_encoded=$(printf '%s\n' "$root_driver" | /usr/bin/base64 --wrap=0)
  acceptance_uid=$(id -u)
  acceptance_gid=$(id -g)
  installed_package_before_handoff=$(pacman -Q "$PACKAGE_NAME")
  printf -v terminal_command \
    "/usr/bin/printf '%%s' %q | /usr/bin/base64 --decode | /usr/bin/sudo /usr/bin/bash -p -s -- %q %q %q %q %q %q %q %q %q %q" \
    "$root_driver_encoded" "$run_root" "$handoff_encoded" "$handoff_hash" \
    "$fake_pacman_encoded" "$acceptance_uid" "$acceptance_gid" "$package_name" \
    "$safe_hash" "$safe_bytes" "$oversize_hash"

  sudo -K
  "$OMARCHY_PATH/bin/omarchy-launch-floating-terminal-with-presentation" "$terminal_command" \
    >/dev/null 2>&1 &
  launcher_pid=$!
  wait_until 'the real-root installer handoff terminal opens' 30 window_present "$TERMINAL_CLASS"
  wait_until 'the real-root installer handoff terminal owns focus' 30 active_window_matches "$TERMINAL_CLASS"
  wait_until 'the real-root installer reaches its exact sudo handoff' 30 \
    real_root_handoff_present "$run_root"
  wtype 'omarchy'
  wtype -k Return
  wait_until 'the exact installer handoff completes its isolated real-root cases' 90 test -s "$result"
  [[ $(<"$result") == 'PASS' ]] ||
    fail 'the exact installer handoff passes its isolated real-root cases' "$(<"$result")"
  pass 'the exact installer handoff uses real root-owned staging and rejects unsafe inputs'
  wait_until 'the real-root installer handoff presents its completion screen' 30 screen_contains 'Done! Press any key'
  screenshot 'success-studio-03b-real-root-handoff'
  wtype -k space
  wait_until 'the real-root installer handoff terminal closes' 30 window_absent "$TERMINAL_CLASS"
  wait_until 'the real-root installer presentation process exits' 30 pid_nonrunnable "$launcher_pid"
  wait "$launcher_pid"
  [[ $(pacman -Q "$PACKAGE_NAME") == "$installed_package_before_handoff" ]] ||
    fail 'the isolated real-root handoff leaves the installed package state unchanged'
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

installed_package_matches_plugin_version() {
  local installed_name installed_version extra

  read -r installed_name installed_version extra < <(pacman -Q "$PACKAGE_NAME") || return 1
  [[ $installed_name == "$PACKAGE_NAME" &&
    $installed_version == "$PLUGIN_VERSION-"* &&
    -z $extra ]]
}

finish_package_install_or_update() {
  local operation=$1 shot=$2

  wait_until "the $operation reaches its checksum-verified pacman handoff" 1900 verified_package_handoff_present
  wait_until "the $operation prepares one verified package and fixed root-staging contract" 135 verify_package_handoff_contract
  screenshot "success-studio-$operation-checksum"
  wait_until "the $operation password prompt owns the active terminal" 10 active_window_matches "$TERMINAL_CLASS"
  wtype 'omarchy'
  wtype -k Return
  wait_until "$operation installs the exact Studio package version" 300 \
    installed_package_matches_plugin_version
  wait_until "$operation updater process completes" 120 studio_updater_process_absent
  wait_until "$operation presents its exact successful completion screen" 30 screen_contains 'Done! Press any key'
  screenshot "$shot"
  wtype -k space
  wait_until "$operation terminal closes" 30 window_absent "$TERMINAL_CLASS"
  installed_package_matches_plugin_version ||
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

removal_fixture_invariants() {
  jq -cer --arg name "$SITE_REMOVAL_NAME" --arg path "$SITE_REMOVAL_PATH" '
    [.sites[]? | select(.name == $name and .path == $path)]
    | if length == 1 then .[0] else error("expected exactly one removal fixture") end
    | {id, name, path, port, phpVersion}
  ' "$STUDIO_CONFIG"
}

removal_fixture_is_preserved_exactly() {
  [[ $(removal_fixture_invariants) == "$SITE_REMOVAL_RECORD_INVARIANTS" ]] &&
    [[ $(sha256sum "$SITE_REMOVAL_PATH/.omarchy-removal-preservation") == "$SITE_REMOVAL_SENTINEL_HASH" ]] &&
    [[ $(sha256sum "$SITE_REMOVAL_PATH/wp-load.php") == "$SITE_REMOVAL_WP_LOAD_HASH" ]] &&
    [[ $(sha256sum "$SITE_REMOVAL_PATH/wp-config.php") == "$SITE_REMOVAL_WP_CONFIG_HASH" ]] &&
    [[ $(sha256sum "$SITE_REMOVAL_PATH/wp-content/database/.ht.sqlite") == "$SITE_REMOVAL_DATABASE_HASH" ]]
}

plugin_status_is_missing() {
  [[ $("$PLUGIN_DIR/scripts/status.sh") == "missing" ]]
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
  local name=$1 expected_path=$2 expected_id=${3:-}

  [[ ! -e $STUDIO_CONFIG ]] ||
    jq -e --arg name "$name" --arg path "$expected_path" --arg id "$expected_id" \
      'all(.sites[]?; .name != $name and .path != $path and ($id == "" or .id != $id))' \
      "$STUDIO_CONFIG" >/dev/null
}

studio_config_has_no_sites() {
  [[ ! -e $STUDIO_CONFIG ]] ||
    jq -e '(.sites // []) | length == 0' "$STUDIO_CONFIG" >/dev/null
}

same_version_update_log_is_idempotent() {
  local start_line=$((pacman_log_line_before_update + 1)) segment="$ARTIFACTS/studio-update-pacman.log"
  local invocation_count

  tail -n "+$start_line" /var/log/pacman.log >"$segment" || return 1
  invocation_count=$(grep -Ec "\[PACMAN\] Running '/usr/bin/pacman -U --needed --noconfirm -- .*/wordpress-studio-omarchy-${PLUGIN_VERSION//./\\.}-[1-9][0-9]*-x86_64\\.pkg\\.tar\\.zst'" "$segment" || true)
  (( invocation_count == 1 )) || return 1
  ! grep -E "\[ALPM\] (installed|upgraded|downgraded) ${PACKAGE_NAME}([[:space:]]|$)" "$segment" >/dev/null
}

certificate_fingerprint() {
  local certificate=$1 output fingerprint

  output=$(openssl x509 -in "$certificate" -noout -fingerprint -sha256 2>/dev/null) || return 1
  fingerprint=${output#*=}
  fingerprint=${fingerprint//:/}
  fingerprint=${fingerprint//[[:space:]]/}
  [[ $fingerprint =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf '%s\n' "${fingerprint,,}"
}

nss_certificate_fingerprint() {
  local database=$1 nickname=$2 output fingerprint

  output=$(certutil -L -d "sql:$database" -n "$nickname" -a 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
  fingerprint=${output#*=}
  fingerprint=${fingerprint//:/}
  fingerprint=${fingerprint//[[:space:]]/}
  [[ $fingerprint =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf '%s\n' "${fingerprint,,}"
}

nss_has_certificate() {
  certutil -L -d "sql:$1" -n "$2" >/dev/null 2>&1
}

nss_certificate_matches_file() {
  local database=$1 nickname=$2 certificate=$3 database_fingerprint file_fingerprint

  database_fingerprint=$(nss_certificate_fingerprint "$database" "$nickname") || return 1
  file_fingerprint=$(certificate_fingerprint "$certificate") || return 1
  [[ $database_fingerprint == "$file_fingerprint" ]]
}

prepare_browser_trust_fixture() {
  local database unrelated_certificate="$TRUST_FIXTURE_DIR/unrelated-ca.crt"
  local unrelated_key="$TRUST_FIXTURE_DIR/unrelated-ca.key"

  command -v certutil >/dev/null 2>&1 || fail 'the Studio package provides certutil for browser trust coverage'
  command -v openssl >/dev/null 2>&1 || fail 'the guest provides openssl for certificate coverage'
  mkdir -p "$STANDARD_NSS_DB" "$FIREFOX_NSS_DB" "$TRUST_FIXTURE_DIR"
  chmod 700 "$STANDARD_NSS_DB" "$FIREFOX_NSS_DB" "$TRUST_FIXTURE_DIR"
  if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
    -subj '/CN=Omarchy Acceptance Unrelated CA' \
    -keyout "$unrelated_key" -out "$unrelated_certificate" \
    >"$ARTIFACTS/studio-unrelated-ca.log" 2>&1; then
    fail 'the acceptance lane creates its unrelated browser certificate fixture'
  fi
  chmod 600 "$unrelated_key" "$unrelated_certificate"

  for database in "$STANDARD_NSS_DB" "$FIREFOX_NSS_DB"; do
    if [[ ! -f $database/cert9.db ]]; then
      certutil -N --empty-password -d "sql:$database" >/dev/null 2>&1 ||
        fail 'the acceptance lane initializes its user-owned NSS fixture'
    fi
    certutil -D -d "sql:$database" -n "$UNRELATED_NSS_NICKNAME" >/dev/null 2>&1 || true
    certutil -A -d "sql:$database" -t 'C,,' -n "$UNRELATED_NSS_NICKNAME" \
      -i "$unrelated_certificate" >/dev/null 2>&1 ||
      fail 'the acceptance lane imports its unrelated NSS certificate fixture'
    nss_has_certificate "$database" "$UNRELATED_NSS_NICKNAME" ||
      fail 'the unrelated NSS certificate fixture is readable before Studio trust'
  done
  pass 'the user-owned Chromium and Firefox NSS fixtures are ready'
}

studio_hosts_entries_present() {
  local domain=$1 port=$2

  [[ $(grep -Fxc "127.0.0.1 $domain # Port $port" /etc/hosts) == "1" &&
    $(grep -Fxc "::1 $domain # Port $port" /etc/hosts) == "1" ]]
}

studio_hosts_entries_absent() {
  local domain=$1

  ! awk -v domain="$domain" \
    '($1 == "127.0.0.1" || $1 == "::1") && $2 == domain { found = 1 } END { exit found ? 0 : 1 }' \
    /etc/hosts
}

site_https_record_ready() {
  local name=$1 expected_path=$2 domain=$3

  [[ -s $STUDIO_CONFIG ]] &&
    jq -e --arg name "$name" --arg path "$expected_path" --arg domain "$domain" '
      [.sites[]? | select(
        .name == $name and
        .path == $path and
        .customDomain == $domain and
        .enableHttps == true
      )] | length == 1
    ' "$STUDIO_CONFIG" >/dev/null
}

site_https_rest_ready() {
  local domain=$1

  curl --noproxy '*' --resolve "$domain:443:127.0.0.1" -fsSL --max-time 10 \
    "https://$domain/wp-json/" |
    jq -e '(.namespaces | index("wp/v2")) != null'
}

studio_https_certificates_ready() {
  local domain=$1 site_certificate="$HOME/.studio/certificates/domains/$1.crt"
  local site_key="$HOME/.studio/certificates/domains/$1.key"

  [[ -f $STUDIO_CA_PATH && ! -L $STUDIO_CA_PATH && -O $STUDIO_CA_PATH &&
    -f $STUDIO_CA_KEY_PATH && ! -L $STUDIO_CA_KEY_PATH && -O $STUDIO_CA_KEY_PATH &&
    -f $site_certificate && ! -L $site_certificate && -O $site_certificate &&
    -f $site_key && ! -L $site_key && -O $site_key ]] || return 1
  openssl verify -CAfile "$STUDIO_CA_PATH" -verify_hostname "$domain" \
    "$site_certificate" >/dev/null 2>&1
}

studio_system_and_browser_trust_ready() {
  [[ -f $STUDIO_SYSTEM_CA_PATH && ! -L $STUDIO_SYSTEM_CA_PATH &&
    $(stat -c %U "$STUDIO_SYSTEM_CA_PATH") == "root" ]] || return 1
  cmp -s "$STUDIO_CA_PATH" "$STUDIO_SYSTEM_CA_PATH" || return 1
  openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$STUDIO_CA_PATH" >/dev/null 2>&1 ||
    return 1
  nss_certificate_matches_file "$STANDARD_NSS_DB" "$STUDIO_NSS_NICKNAME" "$STUDIO_CA_PATH" ||
    return 1
  nss_certificate_matches_file "$FIREFOX_NSS_DB" "$STUDIO_NSS_NICKNAME" "$STUDIO_CA_PATH"
}

revoke_polkit_temporary_authorizations() {
  pkcheck --revoke-temp >/dev/null 2>&1 ||
    fail 'the guest revokes cached polkit authorization before a privilege-boundary check'
}

submit_polkit_password() {
  local operation=$1 sequence=$2

  screenshot "ready-studio-$operation-polkit-$sequence"
  wtype 'omarchy'
  wtype -k Return
  wait_until "the $operation polkit request $sequence closes" 30 layer_absent omarchy-polkit
}

finish_https_site_creation() {
  local name=$1 expected_path=$2 deadline prompt_count=0

  deadline=$((SECONDS + 180))
  while :; do
    if layer_on_screen omarchy-polkit; then
      prompt_count=$((prompt_count + 1))
      submit_polkit_password 'custom-domain-create' "$prompt_count"
    elif site_https_record_ready "$name" "$expected_path" "$SITE_ONE_DOMAIN" &&
      screen_contains 'Welcome to WordPress Studio'; then
      break
    fi
    (( SECONDS < deadline )) ||
      fail 'the custom-domain HTTPS site completes its privileged creation flow'
    sleep 1
  done
  (( prompt_count >= 1 )) || fail 'custom-domain creation crosses the visible polkit boundary'
  pass 'custom-domain creation crosses the visible polkit boundary'
}

finish_custom_domain_site_deletion() {
  local name=$1 path=$2 id=$3 deadline prompt_count=0

  deadline=$((SECONDS + 120))
  while :; do
    if layer_on_screen omarchy-polkit; then
      prompt_count=$((prompt_count + 1))
      submit_polkit_password 'custom-domain-delete' "$prompt_count"
    elif site_record_absent "$name" "$path" "$id"; then
      break
    fi
    (( SECONDS < deadline )) ||
      fail 'the custom-domain site completes its privileged deletion flow'
    sleep 1
  done
  (( prompt_count >= 1 )) || fail 'custom-domain deletion crosses the visible polkit boundary'
  pass 'custom-domain deletion crosses the visible polkit boundary'
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

create_https_site_with_pointer() {
  local name=$1 ordinal=$2 expected_path=$3 domain=$4 attempt name_entered=false

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
  click_active_phrase 'Advanced settings' '20 35 100 100' \
    "the $ordinal Advanced settings are expanded with the pointer"
  wait_until "the $ordinal advanced custom-domain control renders" 20 screen_contains 'Use custom domain'
  click_active_phrase 'Use custom domain' '20 45 100 100' \
    "the $ordinal custom-domain checkbox is clicked with the pointer"
  # The field mounts below the fold after the checkbox state commits. Let that
  # reflow settle before tabbing from the focused checkbox into the new input;
  # OCR cannot reliably see the clipped label at the bottom of the viewport.
  sleep 1
  wtype -k tab
  wtype -M ctrl -k a -m ctrl
  wtype -d 75 "$domain"
  wait_until "the $ordinal custom domain is entered exactly" 15 \
    active_region_contains "$domain" '20 35 100 100'
  wtype -k tab
  wait_until "the $ordinal HTTPS control scrolls into view" 15 screen_contains 'Enable HTTPS'
  wtype -k space
  revoke_polkit_temporary_authorizations
  click_active_bottom_right_control "the $ordinal Create site button is clicked"
  finish_https_site_creation "$name" "$expected_path"
  pass "the $ordinal HTTPS site is persisted after its privileged setup"
}

complete_first_site_orientation() {
  # Studio keeps all three guide pages mounted in one fixed centered dialog.
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
  close_browser_windows || true
  close_windows "$STUDIO_CLASS" || true
  close_windows "$TERMINAL_CLASS" || true
  for path in "$SITE_ONE_PATH" "$SITE_TWO_PATH" "$SITE_REMOVAL_PATH"; do
    if [[ $path == "$HOME/Studio/omarchy-acceptance-one" ||
      $path == "$HOME/Studio/omarchy-acceptance-two" ||
      $path == "$HOME/Studio/omarchy-removal-preserve" ]]; then
      if [[ -x $BUNDLED_NODE && -f $BUNDLED_CLI ]]; then
        if [[ $path == "$HOME/Studio/omarchy-acceptance-one" ]]; then
          # Deleting the custom-domain fixture requires interactive polkit for
          # /etc/hosts. On failure, stop it without starting a hidden prompt;
          # the disposable guest owns the remaining system fixture state.
          timeout 20 "$BUNDLED_NODE" --experimental-wasm-jspi "$BUNDLED_CLI" site stop \
            --path "$path" --avoid-telemetry >/dev/null 2>&1 || true
        else
          timeout 30 "$BUNDLED_NODE" --experimental-wasm-jspi "$BUNDLED_CLI" site delete \
            --path "$path" --avoid-telemetry >/dev/null 2>&1 || true
        fi
      fi
      [[ ! -e $path ]] || rm -rf -- "$path"
    fi
  done
  if [[ -d $FIREFOX_NSS_DB && ! -L $FIREFOX_NSS_DB &&
    $FIREFOX_NSS_DB == "$HOME/.mozilla/firefox/omarchy-acceptance.default-release" ]]; then
    rm -rf -- "$FIREFOX_NSS_DB"
  fi
  if [[ -d $STANDARD_NSS_DB && ! -L $STANDARD_NSS_DB ]]; then
    certutil -D -d "sql:$STANDARD_NSS_DB" -n "$UNRELATED_NSS_NICKNAME" >/dev/null 2>&1 || true
  fi
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
exercise_status_pre_ready_containment
exercise_remove_runtime_resolution
exercise_remove_pre_ready_containment
exercise_remove_containment term
exercise_remove_containment sigkill

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
record_package_handoff_baseline
click_screen_phrase 'Install Studio' '70 0 100 40' 'the Install Studio button is clicked with the pointer'
wait_until 'the visible Studio installer terminal opens' 30 window_present "$TERMINAL_CLASS"
finish_package_install_or_update 'installer' 'success-studio-02-installed-terminal'
verify_installed_runtime_contract 'the installer'

click_bar_widget
wait_until 'the installed Studio panel opens' 20 layer_on_screen omarchy-keyboard-panel
wait_until 'the plugin reports its installed version' 30 screen_contains "Installed $PLUGIN_VERSION"
wait_until 'the installed panel exposes Native Wayland' 20 screen_contains 'Native Wayland'
screenshot 'success-studio-03-installed-panel'
wtype -k Escape
wait_until 'Escape closes the installed Studio panel' 20 layer_absent omarchy-keyboard-panel
park_pointer
wait_until 'the escaped Studio panel clears visually' 20 screen_absent 'Launch Studio'
wait_until 'the escaped Studio bar tooltip clears visually' 20 screen_absent 'WordPress Studio'
screenshot 'success-studio-03a-escape-closed'
exercise_real_privileged_handoff
click_bar_widget
wait_until 'the installed Studio panel reopens after Escape' 20 layer_on_screen omarchy-keyboard-panel
wait_until 'the reopened Studio panel reports its version' 20 screen_contains "Installed $PLUGIN_VERSION"
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
record_package_handoff_baseline
click_screen_phrase 'Update Studio' '70 0 100 40' 'the Update Studio button is clicked with the pointer'
wait_until 'the visible Studio updater terminal opens' 30 window_present "$TERMINAL_CLASS"
finish_package_install_or_update 'updater' 'success-studio-04-updated-terminal'
verify_installed_runtime_contract 'the same-version updater'
[[ $(pacman -Q "$PACKAGE_NAME") == "$installed_package_before_update" ]] || fail 'the same-version update preserves the exact installed package version'
[[ $(sha256sum /usr/lib/studio/studio) == "$studio_hash_before_update" ]] || fail 'the same-version update preserves the installed Studio binary checksum'
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
park_pointer
screenshot 'success-studio-04b-disabled-widget-absent'
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
# The upstream release endpoint can advance while an exact-tree VM run is in
# flight. Give its launch-time request a short settle, then dismiss only the
# exact native update child through its visible Later action before onboarding.
wait_until 'fresh Studio renders onboarding or its native update notice' 60 studio_welcome_or_update_notice_present
sleep 5
dismiss_studio_update_notice_if_present
wait_until 'fresh Studio shows its welcome title' 60 screen_contains 'WordPress Studio'
wait_until 'fresh Studio shows its top-right Skip control' 20 screen_contains 'Skip'
dismiss_studio_update_notice_if_present
wait_until 'fresh Studio still shows its welcome title after update handling' 20 screen_contains 'WordPress Studio'
wait_until 'fresh Studio still shows its top-right Skip control after update handling' 20 screen_contains 'Skip'
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
# Account login/signup and remote connection/import deliberately stay out of
# this offline local-site lifecycle lane. Custom domains and HTTPS stay local
# and cross the guest's real polkit, hosts-file, system-trust, and browser-NSS
# boundaries below.
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

prepare_browser_trust_fixture
studio_hosts_entries_absent "$SITE_ONE_DOMAIN" || fail 'the custom domain is absent from hosts before creation'
[[ ! -e $STUDIO_SYSTEM_CA_PATH && ! -L $STUDIO_SYSTEM_CA_PATH ]] ||
  fail 'the Studio system trust anchor is absent before HTTPS setup'
create_https_site_with_pointer "$SITE_ONE_NAME" 'first' \
  "$HOME/Studio/omarchy-acceptance-one" "$SITE_ONE_DOMAIN"
load_site_record "$SITE_ONE_NAME" "$HOME/Studio/omarchy-acceptance-one" SITE_ONE
complete_first_site_orientation
[[ $SITE_ONE_PATH == "$HOME/Studio/omarchy-acceptance-one" ]] || fail 'the first site uses its isolated default path'
wait_until 'the first site writes WordPress and SQLite files' 120 site_files_ready "$SITE_ONE_PATH"
wait_until 'the first site reports online through the bundled CLI' 120 site_cli_state "$SITE_ONE_PATH" true
wait_until 'the first site exposes the WordPress REST API' 120 site_rest_ready "$SITE_ONE_PORT"
wait_until 'the first site serves visible HTML' 120 site_frontend_ready "$SITE_ONE_PORT"
wait_until 'the first site writes a CA and domain-matched HTTPS certificate' 30 \
  studio_https_certificates_ready "$SITE_ONE_DOMAIN"
wait_until 'the custom domain has one canonical IPv4 and IPv6 hosts entry' 30 \
  studio_hosts_entries_present "$SITE_ONE_DOMAIN" "$SITE_ONE_PORT"
wait_until 'the Studio CA reaches the Arch system bundle and both browser NSS databases' 30 \
  studio_system_and_browser_trust_ready
wait_until 'the trusted custom-domain HTTPS endpoint exposes the WordPress REST API' 120 \
  site_https_rest_ready "$SITE_ONE_DOMAIN"
for database in "$STANDARD_NSS_DB" "$FIREFOX_NSS_DB"; do
  nss_has_certificate "$database" "$UNRELATED_NSS_NICKNAME" ||
    fail 'Studio trust preserves the unrelated NSS certificate fixture'
done
pass 'Studio trust preserves unrelated Chromium and Firefox certificates'
STUDIO_CA_HASH=$(sha256sum "$STUDIO_CA_PATH" | cut -d ' ' -f 1)
screenshot 'success-studio-07-first-site-running'

click_active_phrase 'Settings' '20 5 50 25' 'the visible site Settings tab is clicked'
wait_until 'the Settings tab renders PHP version controls' 20 screen_contains 'PHP version'
wait_until 'the Settings tab renders the custom HTTPS domain' 20 screen_contains "$SITE_ONE_DOMAIN"
wait_until 'the Settings tab reports HTTPS enabled' 20 screen_contains 'Enabled'
screen_absent 'Trust Certificate' || fail 'the fully trusted HTTPS site exposes no stale Trust Certificate action'
pass 'the Settings tab reports the custom domain as fully trusted HTTPS'
screenshot 'success-studio-08-settings-tab'
click_active_phrase 'Debugging' '20 5 50 25' 'the visible site Debugging tab is clicked'
wait_until 'the Debugging tab renders Xdebug controls' 20 screen_contains 'Xdebug'
screenshot 'success-studio-09-debugging-tab'
click_active_phrase 'Overview' '20 5 50 25' 'the visible site Overview tab is clicked'
wait_until 'the Overview tab renders Studio 1.19 Shortcuts' 20 screen_contains 'Shortcuts'

click_active_tooltip 'Hide preview' 95 60 50 \
  'the initially visible in-app preview Hide preview control is clicked with the pointer'
wait_until 'the initial in-app preview pane is hidden' 20 \
  active_region_absent 'Hello world' '55 12 100 90'
click_active_tooltip 'Show preview' 95 100 90 \
  'the hidden in-app preview exposes and clicks its Show preview control'
wait_until 'the in-app preview renders the site in its right pane' 60 active_region_contains "$SITE_ONE_NAME" '55 12 100 95'
screenshot 'success-studio-10-preview-shown'
click_active_tooltip 'Refresh' 7 55 65 \
  'the visible in-app preview Refresh control is clicked with the pointer'
wait_until 'the refreshed preview keeps the site serving' 30 site_frontend_ready "$SITE_ONE_PORT"
wait_until 'the refreshed preview keeps the site title in its right pane' 30 \
  active_region_contains "$SITE_ONE_NAME" '55 12 100 95'
click_active_tooltip 'Hide preview' 95 60 50 \
  'the visible in-app preview Hide preview control is clicked with the pointer'
wait_until 'the in-app preview returns to its hidden state' 20 \
  active_region_absent 'Hello world' '55 12 100 90'
hover_active_tooltip 'Show preview' 95 100 90 \
  'the hidden in-app preview returns to its Show preview control' >/dev/null
pass 'the hidden in-app preview returns to its Show preview control'
screenshot 'success-studio-11-preview-hidden'

click_active_phrase 'Open site' '25 10 60 75' 'the external Open site control is clicked with the pointer'
wait_until 'Open site launches the external browser' 60 browser_window_present
dismiss_chromium_terms_if_needed "$SITE_ONE_NAME"
wait_until 'the native Wayland browser is active with the first site in its title' 60 active_native_browser_for_site "$SITE_ONE_NAME"
site_frontend_ready "$SITE_ONE_PORT" || fail 'the externally opened site remains reachable'
site_https_rest_ready "$SITE_ONE_DOMAIN" || fail 'the externally opened custom domain remains trusted over HTTPS'
pass 'the externally opened site remains reachable'
screenshot 'success-studio-12-external-site'
close_browser_windows
wait_until 'the external browser closes' 30 browser_window_absent
wait_until 'focus returns to Studio' 20 active_window_matches "$STUDIO_CLASS"

click_active_tooltip 'Add site' 3 25 12 \
  'the sidebar Add site icon button is identified and clicked with the pointer'
wait_until 'the second Add a site screen appears' 20 screen_contains 'Create a new site'
create_site_with_pointer "$SITE_TWO_NAME" 'second' "$HOME/Studio/omarchy-acceptance-two"
wait_until 'the second site creation leaves its progress form' 120 screen_absent 'Creating site'
wait_until 'the second site workbench renders' 60 screen_contains 'Overview'
wait_until 'the first site name renders in the sidebar' 30 \
  active_region_contains "$SITE_ONE_NAME" '0 0 28 100'
wait_until 'the second site name renders in the sidebar' 30 \
  active_region_contains "$SITE_TWO_NAME" '0 0 28 100'
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

click_active_site_row 0 'the first sidebar site is selected with the pointer'
wait_until 'the first sidebar selection binds the main workbench to site one' 20 active_region_contains "$SITE_ONE_NAME" '28 0 100 35'
wait_until 'the first sidebar selection remains online' 20 site_cli_state "$SITE_ONE_PATH" true
screenshot 'success-studio-13a-first-site-selected'
click_active_site_row 1 'the second sidebar site is selected with the pointer'
wait_until 'the second sidebar selection binds the main workbench to site two' 20 active_region_contains "$SITE_TWO_NAME" '28 0 100 35'
wait_until 'the second sidebar selection remains online' 20 site_cli_state "$SITE_TWO_PATH" true
screenshot 'success-studio-13b-second-site-selected'

click_active_site_row 1 'the second site context menu is opened with the pointer' right
wait_until 'the running site menu exposes Stop site' 15 \
  active_region_contains 'Stop site' '0 0 35 100'
click_active_phrase 'Stop site' '0 0 35 100' 'Stop site is clicked with the pointer'
wait_until 'the bundled CLI reports the second site stopped' 120 site_cli_state "$SITE_TWO_PATH" false
wait_until 'the stopped second site refuses HTTP' 30 site_http_offline "$SITE_TWO_PORT"
wait_until 'stopping site two leaves site one online in the bundled CLI' 30 site_cli_state "$SITE_ONE_PATH" true
wait_until 'stopping site two leaves site one REST available' 30 site_rest_ready "$SITE_ONE_PORT"
wait_until 'stopping site two leaves site one frontend available' 30 site_frontend_ready "$SITE_ONE_PORT"
click_active_site_row 1 'the stopped site context menu is opened with the pointer' right
wait_until 'the stopped site menu exposes Start site' 15 \
  active_region_contains 'Start site' '0 0 35 100'
screenshot 'success-studio-14-site-stopped-menu'
click_active_phrase 'Start site' '0 0 35 100' 'Start site is clicked with the pointer'
wait_until 'the bundled CLI reports the second site restarted' 120 site_cli_state "$SITE_TWO_PATH" true
wait_until 'the restarted second site restores REST' 120 site_rest_ready "$SITE_TWO_PORT"
wait_until 'both sites serve concurrently after restarting site two' 60 bash -c \
  "curl --noproxy '*' -fsSL --max-time 8 'http://localhost:$SITE_ONE_PORT/wp-json/' | jq -e '(.namespaces | index(\"wp/v2\")) != null' >/dev/null && curl --noproxy '*' -fsSL --max-time 8 'http://localhost:$SITE_TWO_PORT/wp-json/' | jq -e '(.namespaces | index(\"wp/v2\")) != null' >/dev/null"
wait_until 'the restarted site leaves its stopped UI state' 60 \
  active_region_absent 'Start site' '28 0 100 100'
wait_until 'the restarted site restores its live preview' 60 \
  active_region_contains 'Hello world!' '28 0 100 100'
screenshot 'success-studio-14a-site-restarted-workbench'
click_active_site_row 1 'the second site menu opens for WP admin' right
wait_until 'the restarted site menu returns to Stop site' 15 \
  active_region_contains 'Stop site' '0 0 35 100'
wait_until 'the site menu exposes Open WP admin' 15 \
  active_region_contains 'Open WP admin' '0 0 35 100'
screenshot 'success-studio-15-site-restarted-menu'
click_active_phrase 'Open WP admin' '0 0 35 100' 'Open WP admin is clicked with the pointer'
wait_until 'WP admin opens in the external browser' 60 browser_window_present
dismiss_chromium_terms_if_needed "$SITE_TWO_NAME"
wait_until 'the native Wayland browser is active with site two in its admin title' 60 active_native_browser_for_site "$SITE_TWO_NAME"
wait_until 'the external WP admin renders Dashboard' 90 screen_contains 'Dashboard'
screenshot 'success-studio-16-wp-admin'
close_browser_windows
wait_until 'the WP admin browser closes' 30 browser_window_absent
wait_until 'focus returns to Studio after WP admin' 20 active_window_matches "$STUDIO_CLASS"

for site_name in "$SITE_TWO_NAME" "$SITE_ONE_NAME"; do
  if [[ $site_name == "$SITE_TWO_NAME" ]]; then
    site_id=$SITE_TWO_ID
    site_path=$SITE_TWO_PATH
    site_port=$SITE_TWO_PORT
    site_row=1
  else
    site_id=$SITE_ONE_ID
    site_path=$SITE_ONE_PATH
    site_port=$SITE_ONE_PORT
    site_row=0
    click_active_site_row "$site_row" 'the first site is selected for deletion'
  fi
  click_active_site_row "$site_row" "the $site_name menu is opened for deletion" right false
  click_active_site_delete_action "$site_row" "the $site_name Delete site menu action is clicked"
  wait_until "the Delete $site_name confirmation appears" 20 screen_contains "Delete $site_name"
  wait_until "Studio remains active for the $site_name confirmation" 20 \
    active_window_matches "$STUDIO_CLASS"
  screenshot "ready-delete-${site_name// /-}"
  if [[ $site_name == "$SITE_ONE_NAME" ]]; then
    revoke_polkit_temporary_authorizations
  fi
  # Restrict OCR to the dialog footer's lower-right quadrant. The checkbox also
  # begins with "Delete site", but it lives left of this region; the destructive
  # button is therefore the only exact visible target accepted here.
  click_screen_phrase 'Delete site' '50 50 75 80' \
    "the $site_name visible bottom-right Delete site button is clicked with the pointer"
  if [[ $site_name == "$SITE_ONE_NAME" ]]; then
    finish_custom_domain_site_deletion "$site_name" "$site_path" "$site_id"
  else
    wait_until "$site_name leaves Studio config" 30 site_record_absent "$site_name" "$site_path" "$site_id"
  fi
  wait_until "$site_name files are deleted" 30 test ! -e "$site_path"
  wait_until "$site_name stops serving after deletion" 30 site_http_offline "$site_port"
  wait_until "the Delete $site_name confirmation closes" 30 screen_absent "Delete $site_name"
  if [[ $site_name == "$SITE_ONE_NAME" ]]; then
    wait_until 'custom-domain deletion removes both hosts entries' 30 \
      studio_hosts_entries_absent "$SITE_ONE_DOMAIN"
    [[ ! -e $HOME/.studio/certificates/domains/$SITE_ONE_DOMAIN.crt &&
      ! -L $HOME/.studio/certificates/domains/$SITE_ONE_DOMAIN.crt &&
      ! -e $HOME/.studio/certificates/domains/$SITE_ONE_DOMAIN.key &&
      ! -L $HOME/.studio/certificates/domains/$SITE_ONE_DOMAIN.key ]] ||
      fail 'custom-domain deletion removes its domain certificate and private key'
    [[ $(sha256sum "$STUDIO_CA_PATH" | cut -d ' ' -f 1) == "$STUDIO_CA_HASH" ]] ||
      fail 'custom-domain deletion preserves the exact user CA for other future sites'
    studio_system_and_browser_trust_ready ||
      fail 'custom-domain deletion preserves the matching system and browser root trust'
    for database in "$STANDARD_NSS_DB" "$FIREFOX_NSS_DB"; do
      nss_has_certificate "$database" "$UNRELATED_NSS_NICKNAME" ||
        fail 'custom-domain deletion preserves the unrelated NSS certificate fixture'
    done
    pass 'custom-domain deletion cleans site-specific state and preserves root trust'
  fi
done
wait_until 'Studio config contains no sites after both deletions' 30 studio_config_has_no_sites
wait_until 'the first deleted site leaves the visible sidebar' 30 \
  active_region_absent "$SITE_ONE_NAME" '0 0 28 100'
wait_until 'the second deleted site leaves the visible sidebar' 30 \
  active_region_absent "$SITE_TWO_NAME" '0 0 28 100'
screenshot 'success-studio-17-sites-deleted'

# Create one final disposable site to prove package removal stops background
# serving while preserving the site's registry record and files.
create_site_with_pointer "$SITE_REMOVAL_NAME" 'removal-fixture' "$HOME/Studio/omarchy-removal-preserve"
wait_until 'the removal-fixture site creation leaves its progress form' 120 screen_absent 'Creating site'
wait_until 'the removal-fixture site workbench renders' 60 screen_contains 'Overview'
load_site_record "$SITE_REMOVAL_NAME" "$HOME/Studio/omarchy-removal-preserve" SITE_REMOVAL
wait_until 'the removal-fixture site writes WordPress and SQLite files' 120 site_files_ready "$SITE_REMOVAL_PATH"
wait_until 'the removal-fixture site reports online through the bundled CLI' 120 \
  site_cli_state "$SITE_REMOVAL_PATH" true
wait_until 'the removal-fixture site exposes the WordPress REST API' 120 site_rest_ready "$SITE_REMOVAL_PORT"
screenshot 'success-studio-18-removal-site-running'

# Removal must fail closed while Studio is open so the app retains control of
# active Sync confirmation/cancellation. Exercise the actual Quattro action,
# dismiss its bounded failure presentation, then quit Studio normally.
guarded_package=$(pacman -Q "$PACKAGE_NAME")
guarded_studio_hash=$(sha256sum /usr/lib/studio/studio)
click_bar_widget false
wait_until 'the guarded Studio removal panel opens' 20 layer_on_screen omarchy-keyboard-panel
click_quattro_remove_control 'the guarded Remove Studio action is clicked with the pointer'
wait_until 'the guarded removal terminal opens' 30 window_present "$TERMINAL_CLASS"
wait_until 'the guarded removal terminal owns focus' 30 active_window_matches "$TERMINAL_CLASS"
wait_until 'the guarded remover exits after refusing an open Studio app' 30 studio_remover_process_absent
[[ $(pacman -Q "$PACKAGE_NAME") == "$guarded_package" &&
  $(sha256sum /usr/lib/studio/studio) == "$guarded_studio_hash" ]] ||
  fail 'guarded removal preserves the exact installed Studio package'
pass 'guarded removal preserves the installed Studio package'
pgrep -u "$(id -u)" -f '^/usr/lib/studio/studio( |$)' >/dev/null ||
  fail 'guarded removal leaves Studio running for its normal quit flow'
pass 'guarded removal leaves Studio running for its normal quit flow'
site_rest_ready "$SITE_REMOVAL_PORT" || fail 'guarded removal leaves the preservation site online'
pass 'guarded removal leaves the preservation site online'
screenshot 'success-studio-19-open-app-removal-guard'
wtype -k space
wait_until 'the guarded removal terminal closes' 30 window_absent "$TERMINAL_CLASS"
wait_until 'focus returns to Studio after guarded removal' 20 active_window_matches "$STUDIO_CLASS"
click_active_relative_control 2 2 'the Studio application menu is opened with the pointer'
wait_until 'the Studio application submenu is visible' 20 screen_contains 'Studio'
click_screen_phrase 'Studio' '0 0 20 20' 'the Studio application submenu is opened with the pointer'
wait_until 'the Studio application submenu exposes Quit' 20 screen_contains 'Quit'
click_screen_phrase 'Quit' '0 0 55 100' 'the Studio Quit action is clicked with the pointer'
# Electron keeps this native modal inside the existing Studio window, so its
# compositor identity does not change. Give it one render tick, capture it for
# mandatory visual review, and let the close-plus-site-serving invariants below
# prove that the intended native action was reached and accepted.
sleep 1
screenshot 'success-studio-20-native-quit-dialog'
click_active_centered_control 0 68 \
  'the running removal fixture is kept online through the native quit dialog'
wait_until 'the WordPress Studio window closes normally' 30 window_absent "$STUDIO_CLASS"
pgrep -u "$(id -u)" -f '^/usr/lib/studio/studio( |$)' >/dev/null ||
  fail 'keeping the removal fixture online retains Studio background supervision'
pass 'keeping the removal fixture online retains Studio background supervision'
wait_until 'the preserved removal-fixture site remains online after Studio quits' 30 \
  site_rest_ready "$SITE_REMOVAL_PORT"

printf '%s\n' 'Omarchy removal preservation sentinel v1' >"$SITE_REMOVAL_PATH/.omarchy-removal-preservation"
SITE_REMOVAL_RECORD_INVARIANTS=$(removal_fixture_invariants)
SITE_REMOVAL_SENTINEL_HASH=$(sha256sum "$SITE_REMOVAL_PATH/.omarchy-removal-preservation")
SITE_REMOVAL_WP_LOAD_HASH=$(sha256sum "$SITE_REMOVAL_PATH/wp-load.php")
SITE_REMOVAL_WP_CONFIG_HASH=$(sha256sum "$SITE_REMOVAL_PATH/wp-config.php")
SITE_REMOVAL_DATABASE_HASH=$(sha256sum "$SITE_REMOVAL_PATH/wp-content/database/.ht.sqlite")

click_bar_widget false
wait_until 'the Studio removal panel opens' 20 layer_on_screen omarchy-keyboard-panel
click_quattro_remove_control 'the Remove Studio button is clicked with the pointer'
wait_until 'the visible Studio removal terminal opens' 30 window_present "$TERMINAL_CLASS"
wait_until 'the removal terminal owns focus' 30 active_window_matches "$TERMINAL_CLASS"
wait_until 'the remover completes browser trust cleanup and reaches the package transaction' 60 \
  pgrep -f '[s]udo pacman -Rns --noconfirm wordpress-studio-omarchy'
for database in "$STANDARD_NSS_DB" "$FIREFOX_NSS_DB"; do
  nss_has_certificate "$database" "$STUDIO_NSS_NICKNAME" &&
    fail 'browser trust cleanup removes the matching Studio CA before package removal'
  nss_has_certificate "$database" "$UNRELATED_NSS_NICKNAME" ||
    fail 'browser trust cleanup preserves the unrelated NSS certificate before package removal'
done
[[ -f $STUDIO_SYSTEM_CA_PATH && ! -L $STUDIO_SYSTEM_CA_PATH ]] ||
  fail 'the system trust anchor remains package-owned until the package transaction'
cmp -s "$STUDIO_CA_PATH" "$STUDIO_SYSTEM_CA_PATH" ||
  fail 'the package-owned trust anchor still matches the preserved user CA at handoff'
pass 'browser trust cleanup is exact and completes before the package transaction'
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
wait_until 'package removal stops the preserved background site' 30 site_http_offline "$SITE_REMOVAL_PORT"
removal_fixture_is_preserved_exactly || fail 'package removal preserves the exact removal-fixture record and files'
pass 'package removal preserves the exact removal-fixture record and files'
wait_until 'the remover presents its completion screen' 60 screen_contains 'Done! Press any key'
screenshot 'success-studio-20-removed-terminal'
wtype -k space
wait_until 'the removal terminal closes' 30 window_absent "$TERMINAL_CLASS"
wait_until 'the remover terminates every Studio process' 30 studio_processes_absent
wait_until 'the Studio executable is removed' 30 test ! -e /usr/bin/studio
[[ ! -e /usr/bin/studio-omarchy-cleanup-user-trust ]] ||
  fail 'the standalone browser trust cleanup helper is removed with the package'
[[ ! -e $STUDIO_SYSTEM_CA_PATH && ! -L $STUDIO_SYSTEM_CA_PATH ]] ||
  fail 'the Studio trust anchor is removed with the package'
[[ $(sha256sum "$STUDIO_CA_PATH" | cut -d ' ' -f 1) == "$STUDIO_CA_HASH" ]] ||
  fail 'package removal preserves the exact user-owned Studio CA'
if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$STUDIO_CA_PATH" >/dev/null 2>&1; then
  fail 'package removal extracts the system trust bundle without the Studio CA'
fi
for database in "$STANDARD_NSS_DB" "$FIREFOX_NSS_DB"; do
  certutil -L -d "sql:$database" >/dev/null 2>&1 ||
    fail 'package removal leaves each browser NSS database readable'
  nss_has_certificate "$database" "$STUDIO_NSS_NICKNAME" &&
    fail 'package removal leaves no matching Studio CA in browser trust'
  nss_has_certificate "$database" "$UNRELATED_NSS_NICKNAME" ||
    fail 'package removal preserves unrelated browser trust'
done
pass 'the Studio trust anchor is removed with the package'

click_bar_widget false
wait_until 'the Studio panel reports the package missing' 30 plugin_status_is_missing
screenshot 'success-studio-21-package-not-installed-panel'
omarchy-shell shell hide "$PLUGIN_ID" >/dev/null
wait_until 'the final Studio panel hides' 20 layer_absent omarchy-keyboard-panel
omarchy plugin disable "$PLUGIN_ID" >/dev/null
wait_until 'WordPress Studio is disabled after cleanup' 15 bar_widget_absent
omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null
wait_until 'WordPress Studio plugin is removed from disk' 15 test ! -e "$PLUGIN_DIR"
wait_until 'WordPress Studio plugin leaves the registry' 15 plugin_absent
removal_fixture_is_preserved_exactly || fail 'plugin removal preserves the exact removal-fixture record and files'
pass 'plugin removal preserves the exact removal-fixture record and files'
park_pointer
screenshot 'success-studio-22-plugin-removed-widget-absent'

pass 'WordPress Studio pointer-driven guest acceptance passed'
