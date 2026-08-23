#!/bin/bash

set -euo pipefail

readonly STUDIO_CA_NICKNAME='WordPress Studio CA'
readonly CALL_TIMEOUT='6s'
readonly CALL_KILL_GRACE='2s'
readonly MAX_FIREFOX_PROFILE_DBS=24

warn() {
  printf 'WordPress Studio: %s\n' "$1" >&2
}

run_bounded() {
  timeout --foreground --signal=TERM --kill-after="$CALL_KILL_GRACE" "$CALL_TIMEOUT" "$@"
}

take_nul_records() {
  local limit=$1 count=0 record

  while (( count < limit )) && IFS= read -r -d '' record; do
    printf '%s\0' "$record"
    ((count += 1))
  done
}

write_bounded_firefox_profiles() {
  local root=$1 limit=$2 output=$3 producer_status consumer_status
  local -a pipeline_status

  set +e
  run_bounded find "$root" -mindepth 1 -maxdepth 1 \
    \( -name '*.default' -o -name '*.default-*' \) -print0 |
    take_nul_records "$limit" >"$output"
  pipeline_status=("${PIPESTATUS[@]}")
  producer_status=${pipeline_status[0]}
  consumer_status=${pipeline_status[1]}
  set -e

  (( consumer_status == 0 )) || return 1
  (( producer_status == 0 || producer_status == 141 ))
}

normalize_fingerprint() {
  local fingerprint=${1#*=}

  fingerprint=${fingerprint//:/}
  fingerprint=${fingerprint//[[:space:]]/}

  [[ $fingerprint =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf '%s\n' "$fingerprint"
}

validate_nss_db() {
  local db=$1 db_real file

  if [[ ! -e $db && ! -L $db ]]; then
    return 2
  fi

  if [[ ! -d $db || -L $db || ! -O $db ]]; then
    warn "refusing unsafe NSS database path: $db"
    return 1
  fi

  db_real=$(cd -- "$db" 2>/dev/null && pwd -P) || {
    warn "unable to resolve NSS database path: $db"
    return 1
  }
  if [[ $db_real != "$home_real/"* ]]; then
    warn "refusing NSS database outside the current user's home: $db"
    return 1
  fi

  for file in cert9.db key4.db pkcs11.txt; do
    file="$db_real/$file"
    if [[ -e $file || -L $file ]]; then
      if [[ ! -f $file || -L $file || ! -O $file ]]; then
        warn "refusing unsafe NSS database file: $file"
        return 1
      fi
    fi
  done

  if [[ ! -f $db_real/cert9.db ]]; then
    return 2
  fi

  printf '%s\n' "$db_real"
}

validate_firefox_root() {
  local root=$1 root_real

  if [[ ! -e $root && ! -L $root ]]; then
    return 2
  fi

  if [[ ! -d $root || -L $root || ! -O $root ]]; then
    warn "refusing unsafe Firefox profile root: $root"
    return 1
  fi

  root_real=$(cd -- "$root" 2>/dev/null && pwd -P) || {
    warn "unable to resolve Firefox profile root: $root"
    return 1
  }
  if [[ $root_real != "$home_real/"* ]]; then
    warn "refusing Firefox profile root outside the current user's home: $root"
    return 1
  fi

  printf '%s\n' "$root_real"
}

nss_db_is_readable() {
  run_bounded certutil -L -d "sql:$1" >/dev/null 2>&1
}

nss_has_studio_ca() {
  run_bounded certutil -L -d "sql:$1" -n "$STUDIO_CA_NICKNAME" >/dev/null 2>&1
}

nss_studio_fingerprint() {
  local output

  output=$(
    set -o pipefail
    run_bounded certutil -L -d "sql:$1" -n "$STUDIO_CA_NICKNAME" -a 2>/dev/null |
      run_bounded openssl x509 -noout -fingerprint -sha256 2>/dev/null
  ) || return 1

  normalize_fingerprint "$output"
}

if [[ -z ${HOME:-} || $HOME != /* || $HOME == "/" || ! -d $HOME || -L $HOME || ! -O $HOME ]]; then
  warn 'refusing to guess or use an unsafe current-user home directory'
  exit 1
fi

home_real=$(cd -- "$HOME" 2>/dev/null && pwd -P) || {
  warn 'unable to resolve the current-user home directory'
  exit 1
}

for dependency in timeout find mktemp; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    warn "cannot enumerate browser trust databases because $dependency is unavailable"
    exit 1
  fi
done

cleanup_temp=$(mktemp -d) || {
  warn 'cannot create a private browser trust cleanup directory'
  exit 1
}
chmod 700 "$cleanup_temp"
trap 'rm -rf -- "$cleanup_temp"' EXIT

failures=0
nss_candidates=(
  "$HOME/.pki/nssdb"
  "$HOME/snap/chromium/current/.pki/nssdb"
)

firefox_candidate_count=0
firefox_candidate_overflow=false
firefox_root_index=0
for firefox_root in \
  "$HOME/.mozilla/firefox" \
  "$HOME/snap/firefox/common/.mozilla/firefox" \
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
  if firefox_root_real=$(validate_firefox_root "$firefox_root"); then
    firefox_profile_list="$cleanup_temp/firefox-$firefox_root_index"
    ((firefox_root_index += 1))
    remaining_profile_slots=$((MAX_FIREFOX_PROFILE_DBS - firefox_candidate_count))
    if ! write_bounded_firefox_profiles "$firefox_root_real" \
      "$((remaining_profile_slots + 1))" "$firefox_profile_list"; then
      warn "cannot safely enumerate Firefox profiles in: $firefox_root_real"
      ((failures += 1))
      continue
    fi
    while IFS= read -r -d '' profile; do
      if (( firefox_candidate_count >= MAX_FIREFOX_PROFILE_DBS )); then
        firefox_candidate_overflow=true
        break 2
      fi
      nss_candidates+=("$profile")
      ((firefox_candidate_count += 1))
    done <"$firefox_profile_list"
  else
    validation_status=$?
    if (( validation_status != 2 )); then
      ((failures += 1))
    fi
  fi
done

if [[ $firefox_candidate_overflow == true ]]; then
  warn "refusing to inspect more than $MAX_FIREFOX_PROFILE_DBS Firefox profile databases"
  ((failures += 1))
fi

nss_dbs=()
for candidate in "${nss_candidates[@]}"; do
  if db_real=$(validate_nss_db "$candidate"); then
    duplicate=false
    if (( ${#nss_dbs[@]} > 0 )); then
      for existing in "${nss_dbs[@]}"; do
        if [[ $existing == "$db_real" ]]; then
          duplicate=true
          break
        fi
      done
    fi
    if [[ $duplicate == false ]]; then
      nss_dbs+=("$db_real")
    fi
  else
    validation_status=$?
    if (( validation_status != 2 )); then
      ((failures += 1))
    fi
  fi
done

if (( ${#nss_dbs[@]} == 0 )); then
  if (( failures > 0 )); then
    warn 'browser trust cleanup was incomplete'
    exit 1
  fi
  printf 'WordPress Studio: no current-user browser NSS database needs cleanup.\n'
  exit 0
fi

for dependency in timeout certutil; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    warn "cannot clean browser trust because $dependency is unavailable"
    exit 1
  fi
done

studio_dbs=()
for db in "${nss_dbs[@]}"; do
  if nss_has_studio_ca "$db"; then
    studio_dbs+=("$db")
  elif ! nss_db_is_readable "$db"; then
    warn "cannot inspect NSS database: $db"
    ((failures += 1))
  fi
done

if (( ${#studio_dbs[@]} == 0 )); then
  if (( failures > 0 )); then
    warn 'browser trust cleanup was incomplete'
    exit 1
  fi
  printf 'WordPress Studio: no matching current-user browser trust entry found.\n'
  exit 0
fi

ca_dir="$HOME/.studio/certificates"
ca_file="$ca_dir/studio-ca.crt"
if [[ ! -d $ca_dir || -L $ca_dir || ! -O $ca_dir ]]; then
  warn 'cannot fingerprint the Studio CA from a safe current-user certificate directory'
  exit 1
fi
ca_dir_real=$(cd -- "$ca_dir" 2>/dev/null && pwd -P) || {
  warn 'unable to resolve the Studio certificate directory'
  exit 1
}
if [[ $ca_dir_real != "$home_real/"* || ! -f $ca_file || -L $ca_file || ! -O $ca_file ]]; then
  warn 'cannot fingerprint a safe, regular current-user Studio CA file'
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  warn 'cannot clean browser trust because openssl is unavailable'
  exit 1
fi
if ! ca_output=$(run_bounded openssl x509 -in "$ca_file" -noout -fingerprint -sha256 2>/dev/null) ||
  ! ca_fingerprint=$(normalize_fingerprint "$ca_output"); then
  warn 'cannot read a valid SHA-256 fingerprint from the Studio CA file'
  exit 1
fi

removed=0
for db in "${studio_dbs[@]}"; do
  if ! db_fingerprint=$(nss_studio_fingerprint "$db"); then
    warn "cannot fingerprint the Studio trust entry in: $db"
    ((failures += 1))
    continue
  fi

  if [[ $db_fingerprint != "$ca_fingerprint" ]]; then
    warn "preserving a different certificate named '$STUDIO_CA_NICKNAME' in: $db"
    continue
  fi

  if ! run_bounded certutil -D -d "sql:$db" -n "$STUDIO_CA_NICKNAME" >/dev/null 2>&1; then
    warn "failed to remove the matching Studio trust entry from: $db"
    ((failures += 1))
    continue
  fi
  if nss_has_studio_ca "$db" || ! nss_db_is_readable "$db"; then
    warn "could not verify Studio trust removal from: $db"
    ((failures += 1))
    continue
  fi

  ((removed += 1))
done

if (( failures > 0 )); then
  warn 'the package was removed, but current-user browser trust cleanup was incomplete'
  exit 1
fi

if (( removed == 1 )); then
  entry_suffix=y
else
  entry_suffix=ies
fi
printf 'WordPress Studio: removed %d matching current-user browser trust entr%s.\n' \
  "$removed" "$entry_suffix"
