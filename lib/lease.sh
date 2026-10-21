#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# One Kubernetes Lease serialises end-to-end runs from GitHub and GitLab. Source this file.
#
# Inputs: E2E_LEASE_NAME E2E_LEASE_NAMESPACE E2E_HOLDER (the run id).
# The Lease expires 2 hours after the last renewal. A hold keeps it past that
# until the hold-until time, so the next run cannot start beside held machines.
# The logic reads two annotations, so it does not parse Lease timestamps:
#   kube-e2e/renew-epoch       when the holder last renewed
#   kube-e2e/hold-until-epoch  0, or the end of a hold
# Create fails when the Lease exists and replace fails on a stale
# resourceVersion, so two runs cannot both win.

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

readonly E2E_LEASE_TTL=7200
readonly E2E_HOLD_MAX=7200

e2e_kubectl() {
  kubectl -n "$E2E_LEASE_NAMESPACE" "$@"
}

e2e_lease_env() {
  e2e_require_env E2E_LEASE_NAME E2E_LEASE_NAMESPACE E2E_HOLDER
}

e2e_lease_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000000Z
}

# e2e_lease_manifest <holder> <now> <hold-until> [resourceVersion]
e2e_lease_manifest() {
  jq -n --arg name "$E2E_LEASE_NAME" --arg ns "$E2E_LEASE_NAMESPACE" --arg holder "$1" \
    --argjson now "$2" --argjson hold "$3" --arg rv "${4:-}" \
    --arg stamp "$(e2e_lease_iso "$2")" --argjson ttl "$E2E_LEASE_TTL" '
    {apiVersion: "coordination.k8s.io/v1", kind: "Lease",
     metadata: ({name: $name, namespace: $ns,
                 annotations: {"kube-e2e/renew-epoch": ($now | tostring), "kube-e2e/hold-until-epoch": ($hold | tostring)}}
                + (if $rv == "" then {} else {resourceVersion: $rv} end)),
     spec: {holderIdentity: $holder, leaseDurationSeconds: $ttl, acquireTime: $stamp, renewTime: $stamp}}'
}

e2e_lease_holder() {
  jq -r '.spec.holderIdentity // ""' <<<"$1"
}

e2e_lease_hold_until() {
  jq -r '(.metadata.annotations["kube-e2e/hold-until-epoch"] // "0")' <<<"$1"
}

# The later of "last renewal + TTL" and the hold-until time.
e2e_lease_expiry() {
  jq -r '[((.metadata.annotations["kube-e2e/renew-epoch"] // "0") | tonumber) + (.spec.leaseDurationSeconds // 0),
          ((.metadata.annotations["kube-e2e/hold-until-epoch"] // "0") | tonumber)] | max' <<<"$1"
}

e2e_lease_acquire() {
  e2e_lease_env
  local now json holder expiry version hold=0
  now="$(e2e_now)"
  if ! json="$(e2e_kubectl get lease "$E2E_LEASE_NAME" -o json 2>/dev/null)"; then
    if e2e_lease_manifest "$E2E_HOLDER" "$now" 0 | e2e_kubectl create -f - >/dev/null 2>&1; then
      echo "lease: acquired"
      return 0
    fi
    echo "lease: could not create it, another run won or the cluster is unreachable" >&2
    return 1
  fi
  holder="$(e2e_lease_holder "$json")"
  expiry="$(e2e_lease_expiry "$json")"
  if [ -n "$holder" ] && [ "$holder" != "$E2E_HOLDER" ] && [ "$now" -lt "$expiry" ]; then
    echo "lease: held by $holder for $((expiry - now)) more seconds" >&2
    return 1
  fi
  [ "$holder" != "$E2E_HOLDER" ] || hold="$(e2e_lease_hold_until "$json")"
  version="$(jq -r '.metadata.resourceVersion' <<<"$json")"
  if e2e_lease_manifest "$E2E_HOLDER" "$now" "$hold" "$version" | e2e_kubectl replace -f - >/dev/null 2>&1; then
    echo "lease: acquired"
    return 0
  fi
  echo "lease: another run took it first" >&2
  return 1
}

# e2e_lease_renew [hold-until]: only the holder can renew.
e2e_lease_renew() {
  e2e_lease_env
  local json version hold
  json="$(e2e_kubectl get lease "$E2E_LEASE_NAME" -o json 2>/dev/null)" || {
    echo "lease: not found" >&2
    return 1
  }
  if [ "$(e2e_lease_holder "$json")" != "$E2E_HOLDER" ]; then
    echo "lease: held by someone else" >&2
    return 1
  fi
  hold="${1:-$(e2e_lease_hold_until "$json")}"
  version="$(jq -r '.metadata.resourceVersion' <<<"$json")"
  e2e_lease_manifest "$E2E_HOLDER" "$(e2e_now)" "$hold" "$version" | e2e_kubectl replace -f - >/dev/null 2>&1 || {
    echo "lease: renew conflicted" >&2
    return 1
  }
}

# e2e_lease_hold <seconds>: keeps the Lease for a failed run. Prints the hold-until epoch.
e2e_lease_hold() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] || e2e_usage_die "hold needs a number of seconds"
  [ "$1" -le "$E2E_HOLD_MAX" ] || e2e_usage_die "a hold is at most $E2E_HOLD_MAX seconds"
  local hold_until=$(($(e2e_now) + $1))
  e2e_lease_renew "$hold_until" || return 1
  echo "$hold_until"
}

e2e_lease_release() {
  e2e_lease_env
  local json now
  now="$(e2e_now)"
  json="$(e2e_kubectl get lease "$E2E_LEASE_NAME" -o json 2>/dev/null)" || return 0
  if [ "$(e2e_lease_holder "$json")" != "$E2E_HOLDER" ]; then
    echo "lease: not ours, left alone" >&2
    return 1
  fi
  if [ "$(e2e_lease_hold_until "$json")" -gt "$now" ] && [ "${E2E_FORCE_RELEASE:-0}" != 1 ]; then
    echo "lease: a hold is active, not released" >&2
    return 1
  fi
  e2e_kubectl delete lease "$E2E_LEASE_NAME" >/dev/null
}

# For the janitor: delete the Lease only when it has expired and no hold is active.
e2e_lease_release_stale() {
  e2e_require_env E2E_LEASE_NAME E2E_LEASE_NAMESPACE
  local json now
  now="$(e2e_now)"
  json="$(e2e_kubectl get lease "$E2E_LEASE_NAME" -o json 2>/dev/null)" || return 0
  if [ "$now" -lt "$(e2e_lease_expiry "$json")" ]; then
    echo "lease: still valid"
    return 0
  fi
  e2e_kubectl delete lease "$E2E_LEASE_NAME" >/dev/null && echo "lease: stale, deleted"
}

e2e_lease_status() {
  e2e_require_env E2E_LEASE_NAME E2E_LEASE_NAMESPACE
  local json
  json="$(e2e_kubectl get lease "$E2E_LEASE_NAME" -o json 2>/dev/null)" || {
    echo "lease: free"
    return 0
  }
  echo "lease: held by $(e2e_lease_holder "$json") until $(e2e_lease_expiry "$json") (hold until $(e2e_lease_hold_until "$json"))"
}
