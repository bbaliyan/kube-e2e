#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# One Kubernetes Lease serialises end-to-end runs from GitHub and GitLab. Source this file.
#
# Inputs: E2E_LEASE_NAME E2E_LEASE_NAMESPACE E2E_HOLDER (the run id).
# The logic reads three annotations, so it does not parse Lease timestamps:
#   kube-e2e/renew-epoch       when the holder last renewed
#   kube-e2e/hold-until-epoch  0, or the end of a hold
#   kube-e2e/leftovers         "true" while guests of the run may exist
# A run sets leftovers=true before the scenario starts and clears it only after
# the check that nothing tagged remains. A killed run therefore keeps the Lease:
# no other run can take it, whatever the clock says. Only the holder after a
# clean teardown, or release-stale after the guests are gone, clears it. A hold
# also sets leftovers=true. While leftovers=true, a renew never lowers hold-until.
# The TTL (2 hours after the last renewal) only frees a Lease with leftovers=false.
# Create fails when the Lease exists and replace fails on a stale resourceVersion,
# so two runs cannot both win. Delete carries uid and resourceVersion
# preconditions, so a newer Lease is never deleted.
#
# Exit codes of acquire: 0 acquired, 1 held or lost a race, 4 the cluster is unreachable.

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

readonly E2E_LEASE_TTL=7200
readonly E2E_HOLD_MAX=7200
readonly E2E_LEFTOVERS_UNTIL=9999999999

e2e_kubectl() {
  kubectl -n "$E2E_LEASE_NAMESPACE" "$@"
}

e2e_lease_env() {
  e2e_require_env E2E_LEASE_NAME E2E_LEASE_NAMESPACE E2E_HOLDER
}

# jq formats the time, so this does not depend on GNU date.
e2e_lease_iso() {
  jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%S.000000Z")'
}

# e2e_retry <command...>: three tries, for a conflict with another writer.
e2e_retry() {
  local n
  for n in 1 2 3; do
    "$@" && return 0
    [ "$n" -eq 3 ] || sleep "${E2E_RETRY_SLEEP_SECONDS:-1}"
  done
  return 1
}

# Prints the Lease. Returns 3 when it does not exist and 4 when the cluster cannot be read.
e2e_lease_get() {
  local out err_file err
  err_file="$(mktemp)"
  if out="$(e2e_kubectl get lease "$E2E_LEASE_NAME" -o json 2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s
' "$out"
    return 0
  fi
  err="$(cat "$err_file")"
  rm -f "$err_file"
  if grep -q 'NotFound' <<<"$err"; then
    return 3
  fi
  echo "lease: cannot reach the cluster: $err" >&2
  return 4
}

# e2e_lease_manifest <holder> <now> <hold-until> <leftovers true|false> [resourceVersion]
e2e_lease_manifest() {
  jq -n --arg name "$E2E_LEASE_NAME" --arg ns "$E2E_LEASE_NAMESPACE" --arg holder "$1" \
    --argjson now "$2" --argjson hold "$3" --arg left "$4" --arg rv "${5:-}" \
    --arg stamp "$(e2e_lease_iso "$2")" --argjson ttl "$E2E_LEASE_TTL" '
    {apiVersion: "coordination.k8s.io/v1", kind: "Lease",
     metadata: ({name: $name, namespace: $ns,
                 annotations: {"kube-e2e/renew-epoch": ($now | tostring),
                               "kube-e2e/hold-until-epoch": ($hold | tostring),
                               "kube-e2e/leftovers": $left}}
                + (if $rv == "" then {} else {resourceVersion: $rv} end)),
     spec: {holderIdentity: $holder, leaseDurationSeconds: $ttl, acquireTime: $stamp, renewTime: $stamp}}'
}

e2e_lease_holder() {
  jq -r '.spec.holderIdentity // ""' <<<"$1"
}

e2e_lease_hold_until() {
  jq -r '(.metadata.annotations["kube-e2e/hold-until-epoch"] // "0")' <<<"$1"
}

e2e_lease_leftovers() {
  jq -r '(.metadata.annotations["kube-e2e/leftovers"] // "false")' <<<"$1"
}

# The later of "last renewal + TTL" and the hold-until time.
e2e_lease_expiry() {
  jq -r '[((.metadata.annotations["kube-e2e/renew-epoch"] // "0") | tonumber) + (.spec.leaseDurationSeconds // 0),
          ((.metadata.annotations["kube-e2e/hold-until-epoch"] // "0") | tonumber)] | max' <<<"$1"
}

# Deletes the Lease only if it is still the object we read. e2e_lease_delete_cas <lease json>
# Returns 1 when the Lease changed, 4 when the delete failed for another reason.
e2e_lease_delete_cas() {
  local result
  if result="$(jq -n --arg uid "$(jq -r '.metadata.uid // ""' <<<"$1")" --arg rv "$(jq -r '.metadata.resourceVersion' <<<"$1")" \
    '{kind: "DeleteOptions", apiVersion: "v1", preconditions: ({resourceVersion: $rv} + (if $uid == "" then {} else {uid: $uid} end))}' |
    kubectl delete --raw "/apis/coordination.k8s.io/v1/namespaces/$E2E_LEASE_NAMESPACE/leases/$E2E_LEASE_NAME" -f - 2>&1)"; then
    return 0
  fi
  if grep -q 'Conflict' <<<"$result"; then
    echo "lease: changed since it was read, left alone" >&2
    return 1
  fi
  echo "lease: cannot delete it: $result" >&2
  return 4
}

e2e_lease_acquire() {
  e2e_lease_env
  local now json holder expiry version hold=0 left=false result rc=0
  now="$(e2e_now)"
  json="$(e2e_lease_get)" || rc=$?
  if [ "$rc" -eq 4 ]; then
    return 4
  fi
  if [ "$rc" -eq 3 ]; then
    if result="$(e2e_lease_manifest "$E2E_HOLDER" "$now" 0 false | e2e_kubectl create -f - 2>&1)"; then
      echo "lease: acquired"
      return 0
    fi
    if grep -q 'AlreadyExists' <<<"$result"; then
      echo "lease: another run took it first" >&2
      return 1
    fi
    echo "lease: cannot reach the cluster: $result" >&2
    return 4
  fi
  holder="$(e2e_lease_holder "$json")"
  expiry="$(e2e_lease_expiry "$json")"
  if [ -n "$holder" ] && [ "$holder" != "$E2E_HOLDER" ]; then
    if [ "$(e2e_lease_leftovers "$json")" = true ]; then
      echo "lease: held by $holder, which may have guests left; the janitor clears it" >&2
      return 1
    fi
    if [ "$now" -lt "$expiry" ]; then
      echo "lease: held by $holder for $((expiry - now)) more seconds" >&2
      return 1
    fi
  fi
  if [ "$holder" = "$E2E_HOLDER" ]; then
    hold="$(e2e_lease_hold_until "$json")"
    left="$(e2e_lease_leftovers "$json")"
  fi
  version="$(jq -r '.metadata.resourceVersion' <<<"$json")"
  if result="$(e2e_lease_manifest "$E2E_HOLDER" "$now" "$hold" "$left" "$version" | e2e_kubectl replace -f - 2>&1)"; then
    echo "lease: acquired"
    return 0
  fi
  if grep -q 'Conflict' <<<"$result"; then
    echo "lease: another run took it first" >&2
    return 1
  fi
  echo "lease: cannot reach the cluster: $result" >&2
  return 4
}

# e2e_lease_renew [hold-until [leftovers]]: only the holder can renew.
# While the Lease has leftovers=true and stays so, hold-until is never lowered.
e2e_lease_renew() {
  e2e_lease_env
  local json version hold left cur_hold cur_left rc=0
  json="$(e2e_lease_get)" || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "lease: not found" >&2
    return 1
  elif [ "$rc" -ne 0 ]; then
    return 1
  fi
  if [ "$(e2e_lease_holder "$json")" != "$E2E_HOLDER" ]; then
    echo "lease: held by someone else" >&2
    return 1
  fi
  cur_hold="$(e2e_lease_hold_until "$json")"
  cur_left="$(e2e_lease_leftovers "$json")"
  hold="${1:-$cur_hold}"
  left="${2:-$cur_left}"
  if [ "$cur_left" = true ] && [ "$left" = true ] && [ "$hold" -lt "$cur_hold" ]; then
    hold="$cur_hold"
  fi
  version="$(jq -r '.metadata.resourceVersion' <<<"$json")"
  e2e_lease_manifest "$E2E_HOLDER" "$(e2e_now)" "$hold" "$left" "$version" | e2e_kubectl replace -f - >/dev/null 2>&1 || {
    echo "lease: renew conflicted" >&2
    return 1
  }
}

# e2e_lease_hold <seconds>: keeps the Lease for a failed run. Prints the hold-until epoch.
e2e_lease_hold() {
  e2e_is_uint "${1:-}" && [ "$1" -ge 1 ] || e2e_usage_die "hold needs a number of seconds"
  [ "$1" -le "$E2E_HOLD_MAX" ] || e2e_usage_die "a hold is at most $E2E_HOLD_MAX seconds"
  local hold_until=$(($(e2e_now) + $1))
  e2e_retry e2e_lease_renew "$hold_until" true || return 1
  echo "$hold_until"
}

# Guests of the run may exist from now on. Only a clean check or release-stale clears it.
e2e_lease_mark_leftovers() {
  e2e_retry e2e_lease_renew "$E2E_LEFTOVERS_UNTIL" true
}

e2e_lease_clear_leftovers() {
  e2e_retry e2e_lease_renew 0 false
}

e2e_lease_release() {
  e2e_lease_env
  local json now rc=0
  now="$(e2e_now)"
  json="$(e2e_lease_get)" || rc=$?
  [ "$rc" -ne 3 ] || return 0
  [ "$rc" -eq 0 ] || return 1
  if [ "$(e2e_lease_holder "$json")" != "$E2E_HOLDER" ]; then
    echo "lease: not ours, left alone" >&2
    return 1
  fi
  if [ "${E2E_FORCE_RELEASE:-0}" != 1 ]; then
    if [ "$(e2e_lease_leftovers "$json")" = true ]; then
      echo "lease: guests may be left, not released" >&2
      return 1
    fi
    if [ "$(e2e_lease_hold_until "$json")" -gt "$now" ]; then
      echo "lease: a hold is active, not released" >&2
      return 1
    fi
  fi
  e2e_lease_delete_cas "$json"
}

e2e_lease_status() {
  e2e_require_env E2E_LEASE_NAME E2E_LEASE_NAMESPACE
  local json rc=0
  json="$(e2e_lease_get)" || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "lease: free"
    return 0
  fi
  [ "$rc" -eq 0 ] || return 1
  echo "lease: held by $(e2e_lease_holder "$json") until $(e2e_lease_expiry "$json") (hold until $(e2e_lease_hold_until "$json"), leftovers $(e2e_lease_leftovers "$json"))"
}
