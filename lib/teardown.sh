#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Teardown verification, the opt-in hold and the stale Lease release. Source this file.
#
# Inputs: E2E_API_URL E2E_AUDIT_TOKEN (verify), E2E_TOKEN (hold, the e2e token).
# The audit token needs VM.Audit and Sys.Audit on /. Without them the API
# returns a shorter guest list and no error, and a leftover would go unseen.

# shellcheck source=lib/tags.sh
. "$(dirname "${BASH_SOURCE[0]}")/tags.sh"
# shellcheck source=lib/lease.sh
. "$(dirname "${BASH_SOURCE[0]}")/lease.sh"

# e2e_run_guests <run id>: prints "<node> <vmid> <type> <tags>" for each guest with the run tag.
# It fails when the audit token cannot see every guest, or when the list is empty.
e2e_run_guests() {
  local guests
  e2e_audit_check || exit 1
  guests="$(e2e_api E2E_AUDIT_TOKEN GET '/cluster/resources?type=vm')" || e2e_die "cannot read the guest list"
  if [ "$(jq -r '.data | length' <<<"$guests")" = 0 ]; then
    e2e_die "the guest list is empty, so the audit token may not see the guests"
  fi
  jq -r '.data[] | [.node, .vmid, (.type // "qemu"), (.tags // "")] | @tsv' <<<"$guests" |
    while IFS=$'\t' read -r node vmid type tags; do
      if e2e_has_tag "$1" "$tags"; then
        printf '%s %s %s %s\n' "$node" "$vmid" "$type" "$tags"
      fi
    done
}

# e2e_verify_clean <run id>: exit 1 and list the guests when anything with the run tag remains.
e2e_verify_clean() {
  e2e_require_env E2E_API_URL E2E_AUDIT_TOKEN
  local left
  left="$(e2e_run_guests "$1")" || return 1
  if [ -n "$left" ]; then
    echo "kube-e2e: guests with run tag $1 remain:" >&2
    echo "$left" | awk '{print "  vmid " $2 " on " $1}' >&2
    return 1
  fi
  echo "teardown: nothing tagged $1 remains"
}

# e2e_hold <run id> <seconds>: tags every guest of the run with hold-until and
# holds the Lease (leftovers=true), so the janitor and the next run honour it.
# The Lease is held even when the guest list cannot be read. It tries every
# guest, and it fails if the list could not be read or any tag failed.
e2e_hold() {
  e2e_is_uint "${2:-}" && [ "$2" -ge 1 ] || e2e_usage_die "hold needs a number of seconds"
  [ "$2" -le "$E2E_HOLD_MAX" ] || e2e_usage_die "a hold is at most $E2E_HOLD_MAX seconds"
  e2e_require_env E2E_API_URL E2E_AUDIT_TOKEN E2E_TOKEN
  local hold_until list node vmid type tags rest failed=0 unread=0
  hold_until=$(($(e2e_now) + $2))
  if ! list="$(e2e_run_guests "$1")"; then
    echo "hold: cannot read the guest list, no guest was tagged" >&2
    unread=1
    list=""
  fi
  while read -r node vmid type tags; do
    [ -n "$vmid" ] || continue
    case "$type" in qemu | lxc) ;; *)
      echo "hold: vmid $vmid has an unknown type" >&2
      failed=$((failed + 1))
      continue
      ;;
    esac
    rest="$(tr ';' '\n' <<<"$tags" | grep -v '^hold-until-' | paste -sd ';' -)"
    if ! e2e_api E2E_TOKEN PUT "/nodes/$node/$type/$vmid/config" \
      --data-urlencode "tags=$rest;hold-until-$hold_until" >/dev/null; then
      echo "hold: cannot tag vmid $vmid" >&2
      failed=$((failed + 1))
    fi
  done <<<"$list"
  if ! e2e_retry e2e_lease_renew "$hold_until" true; then
    echo "hold: cannot hold the Lease" >&2
    return 1
  fi
  [ "$unread" -eq 0 ] || return 1
  if [ "$failed" -ne 0 ]; then
    echo "hold: $failed guests are not tagged, the janitor may delete them" >&2
    return 1
  fi
  echo "hold: until $hold_until"
}

# For the janitor. Deletes the Lease only when it is safe:
#   normal Lease: expired, and no hold is active
#   leftovers Lease: the guests of the run are gone, and the audit token can see them
# The delete has uid and resourceVersion preconditions, so a newer Lease stays.
e2e_lease_release_stale() {
  e2e_require_env E2E_LEASE_NAME E2E_LEASE_NAMESPACE
  local json now rc=0
  now="$(e2e_now)"
  json="$(e2e_lease_get)" || rc=$?
  [ "$rc" -ne 3 ] || return 0
  [ "$rc" -eq 0 ] || return 1
  if [ "$(e2e_lease_leftovers "$json")" = true ]; then
    if ! e2e_verify_clean "$(e2e_lease_holder "$json")" >/dev/null 2>&1; then
      echo "lease: guests of $(e2e_lease_holder "$json") remain or cannot be read, kept"
      return 0
    fi
  elif [ "$now" -lt "$(e2e_lease_expiry "$json")" ]; then
    echo "lease: still valid"
    return 0
  fi
  if e2e_lease_delete_cas "$json"; then
    echo "lease: stale, deleted"
    return 0
  fi
  return 1
}
