#!/bin/bash -p

set -euo pipefail

readonly STUDIO_CA_NICKNAME='WordPress Studio CA'
readonly CALL_TIMEOUT='6s'
readonly CALL_KILL_GRACE='2s'
readonly MAX_FIREFOX_PROFILE_DBS=24
readonly TRUSTED_PATH='/usr/bin:/usr/sbin'
readonly TIMEOUT_BIN='/usr/bin/timeout'
readonly FIND_BIN='/usr/bin/find'
readonly MKTEMP_BIN='/usr/bin/mktemp'
readonly CHMOD_BIN='/usr/bin/chmod'
readonly RM_BIN='/usr/bin/rm'
readonly CERTUTIL_BIN='/usr/bin/certutil'
readonly OPENSSL_BIN='/usr/bin/openssl'
readonly ID_BIN='/usr/bin/id'
readonly GETENT_BIN='/usr/bin/getent'
readonly HEAD_BIN='/usr/bin/head'
readonly STAT_BIN='/usr/bin/stat'
readonly TRUST_TEMP_PARENT='/tmp'
readonly MAX_PASSWD_RECORD_BYTES=4096
readonly MAX_CERTIFICATE_BYTES=65536

PATH=$TRUSTED_PATH
LC_ALL=C
export PATH LC_ALL
readonly PATH LC_ALL

warn() {
  printf 'WordPress Studio: %s\n' "$1" >&2
}

run_bounded() {
  "$TIMEOUT_BIN" --foreground --signal=TERM --kill-after="$CALL_KILL_GRACE" "$CALL_TIMEOUT" "$@"
}

require_tool() {
  local tool=$1 label=$2

  if [[ ! -f $tool || ! -x $tool ]]; then
    warn "cannot clean browser trust because the trusted $label tool is unavailable"
    exit 1
  fi
}

cleanup_private_temp() {
  if [[ ! -e $cleanup_temp_real && ! -L $cleanup_temp_real ]]; then
    return
  fi

  if [[ $cleanup_temp_real != "$temp_parent_real/wordpress-studio-trust."* ||
    ! -d $cleanup_temp_real || -L $cleanup_temp_real || ! -O $cleanup_temp_real ]]; then
    warn 'refusing an unsafe browser trust cleanup trap target'
    return
  fi

  "$RM_BIN" -rf -- "$cleanup_temp_real"
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
  run_bounded "$FIND_BIN" "$root" -mindepth 1 -maxdepth 1 \
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

bounded_file_size() {
  local file=$1 size

  if ! size=$(run_bounded "$STAT_BIN" -c '%s' -- "$file") || [[ ! $size =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$size"
}

snapshot_bounded_certificate() {
  local source=$1 destination=$2 label=$3 size

  if ! run_bounded "$HEAD_BIN" -c "$((MAX_CERTIFICATE_BYTES + 1))" -- "$source" \
    >"$destination"; then
    warn "cannot read a bounded $label snapshot"
    return 1
  fi
  if [[ ! -f $destination || -L $destination || ! -O $destination ]] ||
    ! size=$(bounded_file_size "$destination"); then
    warn "cannot validate the bounded $label snapshot"
    return 1
  fi
  if (( size > MAX_CERTIFICATE_BYTES )); then
    warn "refusing a $label larger than $MAX_CERTIFICATE_BYTES bytes"
    return 1
  fi
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
  run_bounded "$CERTUTIL_BIN" -L -d "sql:$1" >/dev/null 2>&1
}

nss_has_studio_ca() {
  local status

  if run_bounded "$CERTUTIL_BIN" -L -d "sql:$1" -n "$STUDIO_CA_NICKNAME" \
    >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi

  if (( status == 1 || status == 255 )); then
    return 1
  fi
  return 2
}

nss_studio_fingerprint() {
  local output certificate_file="$cleanup_temp/nss-studio-ca.pem" size
  local producer_status consumer_status
  local -a pipeline_status

  set +e
  run_bounded "$CERTUTIL_BIN" -L -d "sql:$1" -n "$STUDIO_CA_NICKNAME" -a 2>/dev/null |
    run_bounded "$HEAD_BIN" -c "$((MAX_CERTIFICATE_BYTES + 1))" >"$certificate_file"
  pipeline_status=("${PIPESTATUS[@]}")
  producer_status=${pipeline_status[0]}
  consumer_status=${pipeline_status[1]}
  set -e

  (( consumer_status == 0 )) || return 1
  if [[ ! -f $certificate_file || -L $certificate_file || ! -O $certificate_file ]] ||
    ! size=$(bounded_file_size "$certificate_file"); then
    return 1
  fi
  if (( size > MAX_CERTIFICATE_BYTES )); then
    warn "refusing a browser Studio certificate larger than $MAX_CERTIFICATE_BYTES bytes"
    return 1
  fi
  (( producer_status == 0 )) || return 1

  output=$(run_bounded "$OPENSSL_BIN" x509 -noout -fingerprint -sha256 \
    <"$certificate_file" 2>/dev/null) || return 1

  normalize_fingerprint "$output"
}

for tool_spec in \
  "$TIMEOUT_BIN:timeout" \
  "$FIND_BIN:find" \
  "$MKTEMP_BIN:mktemp" \
  "$CHMOD_BIN:chmod" \
  "$RM_BIN:rm" \
  "$ID_BIN:id" \
  "$GETENT_BIN:getent" \
  "$HEAD_BIN:head" \
  "$STAT_BIN:stat"; do
  require_tool "${tool_spec%%:*}" "${tool_spec#*:}"
done

if ! current_uid=$(run_bounded "$ID_BIN" -u) || [[ ! $current_uid =~ ^[0-9]+$ ]]; then
  warn 'cannot determine the current user ID safely'
  exit 1
fi

passwd_record=$(
  run_bounded "$GETENT_BIN" passwd "$current_uid" |
    "$HEAD_BIN" -c "$((MAX_PASSWD_RECORD_BYTES + 1))"
) || {
  warn 'cannot resolve the current user through the system account database'
  exit 1
}
if (( ${#passwd_record} == 0 || ${#passwd_record} > MAX_PASSWD_RECORD_BYTES )) ||
  [[ $passwd_record == *$'\n'* ]]; then
  warn 'refusing an invalid or oversized current-user account record'
  exit 1
fi
IFS=: read -r -a passwd_fields <<<"$passwd_record"
if (( ${#passwd_fields[@]} != 7 )); then
  warn 'refusing a malformed current-user account record'
  exit 1
fi
passwd_uid=${passwd_fields[2]}
passwd_home=${passwd_fields[5]}
if [[ $passwd_uid != "$current_uid" || $passwd_home != /* ||
  $passwd_home == "/" || ! -d $passwd_home || -L $passwd_home || ! -O $passwd_home ]]; then
  warn 'refusing an unsafe current-user home from the system account database'
  exit 1
fi

home_real=$(cd -- "$passwd_home" 2>/dev/null && pwd -P) || {
  warn 'unable to resolve the system current-user home directory'
  exit 1
}
if [[ $home_real != /* || $home_real == "/" || ! -d $home_real || -L $home_real ||
  ! -O $home_real ]]; then
  warn 'refusing an unsafe canonical current-user home directory'
  exit 1
fi
HOME=$home_real
export HOME
readonly HOME home_real

if [[ ! -d $TRUST_TEMP_PARENT || -L $TRUST_TEMP_PARENT ]]; then
  warn 'cannot use the fixed browser trust cleanup directory parent'
  exit 1
fi
temp_parent_real=$(cd -- "$TRUST_TEMP_PARENT" 2>/dev/null && pwd -P) || {
  warn 'cannot resolve the fixed browser trust cleanup directory parent'
  exit 1
}

cleanup_temp=$("$MKTEMP_BIN" -d --tmpdir="$temp_parent_real" \
  'wordpress-studio-trust.XXXXXXXXXX') || {
  warn 'cannot create a private browser trust cleanup directory'
  exit 1
}
if [[ $cleanup_temp != "$temp_parent_real/wordpress-studio-trust."* ||
  ! -d $cleanup_temp || -L $cleanup_temp || ! -O $cleanup_temp ]]; then
  warn 'refusing an unsafe private browser trust cleanup directory'
  exit 1
fi
cleanup_temp_real=$(cd -- "$cleanup_temp" 2>/dev/null && pwd -P) || {
  warn 'cannot resolve the private browser trust cleanup directory'
  exit 1
}
if [[ $cleanup_temp_real != "$cleanup_temp" ]]; then
  warn 'refusing a non-canonical private browser trust cleanup directory'
  exit 1
fi
readonly temp_parent_real cleanup_temp cleanup_temp_real
"$CHMOD_BIN" 700 "$cleanup_temp_real"
trap cleanup_private_temp EXIT

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

require_tool "$CERTUTIL_BIN" certutil

studio_dbs=()
for db in "${nss_dbs[@]}"; do
  if nss_has_studio_ca "$db"; then
    studio_dbs+=("$db")
  else
    lookup_status=$?
    if (( lookup_status == 1 )); then
      if ! nss_db_is_readable "$db"; then
        warn "cannot inspect NSS database: $db"
        ((failures += 1))
      fi
    else
      warn "Studio certificate lookup timed out or failed in NSS database: $db"
      ((failures += 1))
    fi
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

require_tool "$OPENSSL_BIN" openssl
ca_snapshot="$cleanup_temp/studio-ca.crt"
if ! snapshot_bounded_certificate "$ca_file" "$ca_snapshot" 'Studio CA'; then
  exit 1
fi
if ! ca_output=$(run_bounded "$OPENSSL_BIN" x509 -in "$ca_snapshot" -noout -fingerprint -sha256 2>/dev/null) ||
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

  if ! run_bounded "$CERTUTIL_BIN" -D -d "sql:$db" -n "$STUDIO_CA_NICKNAME" >/dev/null 2>&1; then
    warn "failed to remove the matching Studio trust entry from: $db"
    ((failures += 1))
    continue
  fi
  if nss_has_studio_ca "$db"; then
    warn "could not verify Studio trust removal from: $db"
    ((failures += 1))
    continue
  else
    lookup_status=$?
    if (( lookup_status != 1 )) || ! nss_db_is_readable "$db"; then
      warn "could not verify Studio trust removal from: $db"
      ((failures += 1))
      continue
    fi
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
