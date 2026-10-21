#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Shared setup for the tests. Source it. Every test runs in a temporary
# directory with fake curl, kubectl and gh first on PATH.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/api" "$work/k8s" "$work/gh" "$work/keys" "$work/logs"
echo '[]' >"$work/gh/list.json"

export PATH="$root/tests/fakes:$PATH"
export FAKE_API="$work/api" FAKE_K8S="$work/k8s" FAKE_GH="$work/gh"
export E2E_KEY_ROOT="$work/keys" E2E_LOG_DIR="$work/logs"
export E2E_NOW=1700000000

# Fake values only. The real ones come from the environment of the runner.
export E2E_API_URL="https://pve.example.test:8006/api2/json"
export E2E_AUDIT_TOKEN="audit@pve!audit=fake-audit-secret"
export E2E_TOKEN="e2e@pve!e2e=fake-e2e-secret"
export E2E_NODE=node1 E2E_STORAGE=thin1 E2E_POOL=e2e
export E2E_VMID_MIN=9000 E2E_VMID_MAX=9099
export E2E_LEASE_NAME=kube-e2e E2E_LEASE_NAMESPACE=ci
export E2E_HOLDER=run-a

# shellcheck disable=SC2034 # used by the tests that source this file
GIB=$((1024 * 1024 * 1024))

# shellcheck disable=SC2034 # used by the tests that source this file
e2e="$root/bin/e2e"

ok() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  [ -z "${2:-}" ] || echo "$2"
  exit 1
}

# fixture <api path> <json>
fixture() {
  printf '%s\n' "$2" >"$work/api/$(tr '/?=&' '____' <<<"$1").json"
}

# guest <vmid> <status> <maxmem> <maxcpu> <pool> <tags> [template [node]]
guest() {
  jq -n --argjson vmid "$1" --arg status "$2" --argjson mem "$3" --argjson cpu "$4" \
    --arg pool "$5" --arg tags "$6" --argjson tpl "${7:-0}" --arg node "${8:-node1}" \
    '{vmid: $vmid, node: $node, status: $status, maxmem: $mem, maxcpu: $cpu, pool: $pool, tags: $tags, template: $tpl}'
}

# guests <guest json>...: writes the guest list the fake API serves.
guests() {
  fixture '/cluster/resources?type=vm' "$(jq -s '{data: .}' <<<"$*")"
}

# volumes <vmid:bytes>...: writes the storage content the fake API serves.
volumes() {
  local entry rows=()
  for entry in "$@"; do
    rows+=("$(jq -n --argjson v "${entry%%:*}" --argjson s "${entry##*:}" '{vmid: $v, size: $s}')")
  done
  fixture "/nodes/node1/storage/thin1/content" "$(jq -s '{data: .}' <<<"${rows[*]:-}")"
}

# A host with 64 GiB RAM, a 1000 GiB pool, one running home guest of 20 GiB,
# one template, 300 GiB provisioned, and no e2e guests.
baseline() {
  guests "$(guest 100 running $((20 * GIB)) 4 home '')" "$(guest 90 stopped $((64 * GIB)) 4 home '' 1)"
  fixture /nodes/node1/status "{\"data\":{\"memory\":{\"total\":$((64 * GIB))}}}"
  fixture /nodes/node1/storage/thin1/status "{\"data\":{\"total\":$((1000 * GIB)),\"used\":$((100 * GIB))}}"
  volumes "100:$((300 * GIB))"
  export E2E_CAP_VMS=4 E2E_CAP_VCPU=16 E2E_CAP_RAM_BYTES=$((32 * GIB)) E2E_CAP_DISK_BYTES=$((200 * GIB))
  export E2E_DISK_RULE_VERIFIED=1
  export E2E_REQ_VMS=2 E2E_REQ_VCPU=8 E2E_REQ_RAM_BYTES=$((16 * GIB)) E2E_REQ_DISK_BYTES=$((100 * GIB))
}

# run_status <command...>: runs it, sets $out and $status, never stops the test.
run_status() {
  status=0
  out="$("$@" 2>&1)" || status=$?
}

# expect_status <name> <expected> <command...>
expect_status() {
  local name="$1" want="$2"
  shift 2
  run_status "$@"
  [ "$status" -eq "$want" ] || fail "$name (wanted exit $want, got $status)" "$out"
}
