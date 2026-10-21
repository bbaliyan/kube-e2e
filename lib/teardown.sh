#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Teardown verification and the opt-in hold. Source this file.
#
# Inputs: E2E_API_URL E2E_AUDIT_TOKEN (verify), E2E_TOKEN (hold, the e2e token).

# shellcheck source=lib/tags.sh
. "$(dirname "${BASH_SOURCE[0]}")/tags.sh"
# shellcheck source=lib/lease.sh
. "$(dirname "${BASH_SOURCE[0]}")/lease.sh"

# e2e_run_guests <run id>: prints "<node> <vmid> <tags>" for each guest with the run tag.
e2e_run_guests() {
  local guests
  guests="$(e2e_api E2E_AUDIT_TOKEN GET '/cluster/resources?type=vm')" || e2e_die "cannot read the guest list"
  jq -r '.data[] | [.node, .vmid, (.tags // "")] | @tsv' <<<"$guests" |
    while IFS=$'\t' read -r node vmid tags; do
      if e2e_has_tag "$1" "$tags"; then
        printf '%s %s %s\n' "$node" "$vmid" "$tags"
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
# renews the Lease to the same time, so the janitor and the next run honour it.
e2e_hold() {
  [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] || e2e_usage_die "hold needs a number of seconds"
  [ "$2" -le "$E2E_HOLD_MAX" ] || e2e_usage_die "a hold is at most $E2E_HOLD_MAX seconds"
  e2e_require_env E2E_API_URL E2E_AUDIT_TOKEN E2E_TOKEN
  local hold_until node vmid tags rest
  hold_until=$(($(e2e_now) + $2))
  while read -r node vmid tags; do
    rest="$(tr ';' '\n' <<<"$tags" | grep -v '^hold-until-' | paste -sd ';' -)"
    e2e_api E2E_TOKEN PUT "/nodes/$node/qemu/$vmid/config" \
      --data-urlencode "tags=$rest;hold-until-$hold_until" >/dev/null || e2e_die "cannot tag vmid $vmid"
  done < <(e2e_run_guests "$1")
  e2e_lease_renew "$hold_until"
  echo "hold: until $hold_until"
}
