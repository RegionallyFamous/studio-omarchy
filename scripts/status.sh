#!/bin/bash

set -uo pipefail

readonly package_name='wordpress-studio-omarchy'
readonly raw_limit=96
readonly package_prefix_hex='776f726470726573732d73747564696f2d6f6d617263687920'
raw_hex=''
version=''

# GNU timeout owns the package query's process group. If this controller is
# terminated, timeout remains an independent cleanup owner and gives the whole
# query group a fixed TERM-to-KILL lifetime without any temporary files.
# Encode before crossing the command-substitution boundary so Bash cannot
# normalize trailing newlines or discard NUL bytes before the byte ceiling and
# exact one-line grammar are checked.
# shellcheck disable=SC2016
raw_hex=$(
  timeout --signal=TERM --kill-after=1s 3s \
    bash -c '
      set -o pipefail
      trap "" HUP INT TERM
      LC_ALL=C pacman -Q -- "$1" 2>/dev/null | head -c "$2" | od -An -v -tx1 | tr -d " \n"
    ' studio-status-query "$package_name" "$((raw_limit + 1))"
)
query_status=$?

if (( query_status != 0 )); then
  if (( query_status == 1 )); then
    printf 'missing\n'
  else
    printf 'error\n'
  fi
  exit 0
fi

if [[ ! $raw_hex =~ ^[0-9a-f]*$ ]] || (( ${#raw_hex} > raw_limit * 2 || ${#raw_hex} % 2 != 0 )); then
  printf 'error\n'
  exit 0
fi

if [[ $raw_hex != "$package_prefix_hex"*0a ]]; then
  printf 'error\n'
  exit 0
fi

version_hex=${raw_hex:${#package_prefix_hex}:${#raw_hex}-${#package_prefix_hex}-2}
if (( ${#version_hex} < 2 || ${#version_hex} > 128 || ${#version_hex} % 2 != 0 )); then
  printf 'error\n'
  exit 0
fi

for (( offset = 0; offset < ${#version_hex}; offset += 2 )); do
  printf -v version_byte '%b' "\\x${version_hex:offset:2}"
  if [[ ! $version_byte =~ ^[A-Za-z0-9._+:-]$ ]]; then
    printf 'error\n'
    exit 0
  fi
  version+=$version_byte
done

printf 'installed\t%s\n' "$version"
