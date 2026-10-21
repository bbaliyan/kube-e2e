#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run tag and guest tags. Source this file. Do not run it.
#
# Proxmox keeps tags as one string split on ";". Every guest of a run carries:
#   kube-e2e            marks the guest as ours
#   <run id>            finds the guest at teardown
#   created-<epoch>     age, for the janitor
#   hold-until-<epoch>  only while a failed run is held for debugging
# The janitor in the consumer repo reads the same tags. Keep the format stable.

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

E2E_TAG_MARK="kube-e2e"

e2e_new_run_id() {
  printf 'e2e-%s-%s' "$(e2e_now)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
}

# e2e_guest_tags <run id> <created epoch> [hold-until epoch]
e2e_guest_tags() {
  local tags="$E2E_TAG_MARK;$1;created-$2"
  [ -z "${3:-}" ] || tags="$tags;hold-until-$3"
  echo "$tags"
}

# e2e_tag_epoch <prefix> <tags>: prints the number after "<prefix>-", or nothing.
e2e_tag_epoch() {
  local prefix="$1" tag
  IFS=';,' read -ra parts <<<"$2"
  for tag in "${parts[@]}"; do
    if [[ "$tag" =~ ^${prefix}-([0-9]+)$ ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done
}

# e2e_has_tag <tag> <tags>: whole-tag match, so "e2e-1-ab" does not match "e2e-1-abc".
e2e_has_tag() {
  local want="$1" tag
  IFS=';,' read -ra parts <<<"$2"
  for tag in "${parts[@]}"; do
    [ "$tag" != "$want" ] || return 0
  done
  return 1
}
