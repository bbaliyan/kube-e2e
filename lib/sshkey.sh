#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Per-run SSH key pair. Source this file. Do not run it.
#
# The private key lives in a 700 directory for one run and is deleted at
# teardown, so no long-lived node key exists. E2E_KEY_ROOT is the parent
# directory, and defaults to TMPDIR.

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

e2e_key_dir() {
  echo "${E2E_KEY_ROOT:-${TMPDIR:-/tmp}}/$1-key"
}

# e2e_sshkey_create <run id>: prints the directory. The files are id and id.pub.
e2e_sshkey_create() {
  local dir
  dir="$(e2e_key_dir "$1")"
  mkdir -m 700 "$dir" || e2e_die "key directory already exists: $dir"
  ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$dir/id"
  echo "$dir"
}

# Deletes the pair and fails if anything is left.
e2e_sshkey_delete() {
  local dir
  dir="$(e2e_key_dir "$1")"
  rm -rf "$dir"
  [ ! -e "$dir" ] || e2e_die "key directory is still there: $dir"
}
