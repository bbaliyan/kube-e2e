#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Preflight: refuse a run that would overcommit the host. Source this file.
#
# Reads sizes in bytes from the Proxmox API with the read-only audit token. The
# token needs VM.Audit and Sys.Audit on /, and the preflight checks that.
# Inputs (all required, none has a default):
#   E2E_API_URL E2E_AUDIT_TOKEN E2E_NODE E2E_STORAGE E2E_POOL
#   E2E_VMID_MIN E2E_VMID_MAX               the reserved VMID range of the e2e guests
#   E2E_CAP_VMS E2E_CAP_VCPU E2E_CAP_RAM_BYTES E2E_CAP_DISK_BYTES
#   E2E_REQ_VMS E2E_REQ_VCPU E2E_REQ_RAM_BYTES E2E_REQ_DISK_BYTES   what the scenario will create
#   E2E_DISK_RULE_VERIFIED=1                set only after the owner compared the disk numbers with lvs
# Rules:
#   a guest is an e2e guest when it is in the pool OR its VMID is in the range
#   guests, vCPU, RAM and disk of the e2e guests, existing plus requested, stay within the caps
#   RAM committed by running guests on the node, plus the request, stays within 75% of host RAM
#   provisioned disk plus the request stays within 90% of the storage size. Provisioned is the
#   larger of the sum of volume sizes and the real pool usage, because the content list may miss
#   thin snapshots. The rule fails closed until E2E_DISK_RULE_VERIFIED=1.
# Exit 0 pass, 1 refused or the API could not be read, 2 missing or bad input.

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Checks every input. "run" calls this before it takes the Lease.
e2e_preflight_inputs() {
  e2e_require_env E2E_API_URL E2E_AUDIT_TOKEN E2E_NODE E2E_STORAGE E2E_POOL
  e2e_require_uint E2E_VMID_MIN E2E_VMID_MAX \
    E2E_CAP_VMS E2E_CAP_VCPU E2E_CAP_RAM_BYTES E2E_CAP_DISK_BYTES \
    E2E_REQ_VMS E2E_REQ_VCPU E2E_REQ_RAM_BYTES E2E_REQ_DISK_BYTES
  [ "$E2E_VMID_MIN" -le "$E2E_VMID_MAX" ] || e2e_usage_die "E2E_VMID_MIN must not be above E2E_VMID_MAX"
}

e2e_preflight_row() { # name need limit
  local verdict=PASS
  [ "$2" -le "$3" ] || verdict=FAIL
  printf '%-34s need=%-14s limit=%-14s %s\n' "$1" "$2" "$3" "$verdict"
  [ "$verdict" = PASS ]
}

e2e_preflight() {
  e2e_preflight_inputs
  e2e_audit_check || return 1

  local guests node_status storage_status content
  guests="$(e2e_api E2E_AUDIT_TOKEN GET '/cluster/resources?type=vm')" || e2e_die "cannot read the guest list"
  if [ "$(jq -r '.data | length' <<<"$guests")" = 0 ]; then
    e2e_die "the guest list is empty, so the audit token may not see the guests"
  fi
  node_status="$(e2e_api E2E_AUDIT_TOKEN GET "/nodes/$E2E_NODE/status")" || e2e_die "cannot read the host status"
  storage_status="$(e2e_api E2E_AUDIT_TOKEN GET "/nodes/$E2E_NODE/storage/$E2E_STORAGE/status")" || e2e_die "cannot read the storage status"
  content="$(e2e_api E2E_AUDIT_TOKEN GET "/nodes/$E2E_NODE/storage/$E2E_STORAGE/content")" || e2e_die "cannot read the storage content"

  local have_vms have_vcpu have_ram committed ids host_ram pool_size pool_used provisioned have_disk
  read -r have_vms have_vcpu have_ram committed ids < <(jq -er \
    --arg pool "$E2E_POOL" --arg node "$E2E_NODE" --argjson lo "$E2E_VMID_MIN" --argjson hi "$E2E_VMID_MAX" '
      [.data[] | select(.template != 1)] as $g
      | [$g[] | select(.pool == $pool or (.vmid >= $lo and .vmid <= $hi))] as $e
      | [($e | length), ($e | map(.maxcpu) | add // 0), ($e | map(.maxmem) | add // 0),
         ([$g[] | select(.status == "running" and .node == $node) | .maxmem] | add // 0),
         ($e | map(.vmid) | @json)] | @tsv' <<<"$guests") ||
    e2e_die "the guest list has an unexpected shape"
  host_ram="$(jq -er '.data.memory.total' <<<"$node_status")" || e2e_die "the host status has no memory total"
  pool_size="$(jq -er '.data.total' <<<"$storage_status")" || e2e_die "the storage status has no total"
  pool_used="$(jq -er '.data.used' <<<"$storage_status")" || e2e_die "the storage status has no used size"
  provisioned="$(jq -er '[.data[].size] | add // 0' <<<"$content")" || e2e_die "the storage content has an unexpected shape"
  have_disk="$(jq -er --argjson ids "$ids" --argjson lo "$E2E_VMID_MIN" --argjson hi "$E2E_VMID_MAX" '
    [.data[] | select(.vmid != null and ((.vmid >= $lo and .vmid <= $hi) or (.vmid as $v | $ids | index($v) != null))) | .size]
    | add // 0' <<<"$content")" || e2e_die "the storage content has an unexpected shape"
  [ "$pool_used" -le "$provisioned" ] || provisioned="$pool_used"

  local status=0
  e2e_preflight_row "e2e guests (cap)" $((have_vms + E2E_REQ_VMS)) "$E2E_CAP_VMS" || status=1
  e2e_preflight_row "e2e vCPU (cap)" $((have_vcpu + E2E_REQ_VCPU)) "$E2E_CAP_VCPU" || status=1
  e2e_preflight_row "e2e RAM bytes (cap)" $((have_ram + E2E_REQ_RAM_BYTES)) "$E2E_CAP_RAM_BYTES" || status=1
  e2e_preflight_row "host RAM committed bytes (75%)" $((committed + E2E_REQ_RAM_BYTES)) $((host_ram * 75 / 100)) || status=1
  e2e_preflight_row "e2e disk bytes (cap)" $((have_disk + E2E_REQ_DISK_BYTES)) "$E2E_CAP_DISK_BYTES" || status=1
  e2e_preflight_row "provisioned disk bytes (90%)" $((provisioned + E2E_REQ_DISK_BYTES)) $((pool_size * 90 / 100)) || status=1
  if [ "${E2E_DISK_RULE_VERIFIED:-}" != 1 ]; then
    echo "disk rule NOT VERIFIED: compare the numbers above with lvs, then set E2E_DISK_RULE_VERIFIED=1" >&2
    status=1
  fi
  if [ "$status" -ne 0 ]; then
    echo "kube-e2e: preflight refused the run" >&2
  fi
  return "$status"
}
