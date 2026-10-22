#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for the preflight, against the fake Proxmox API.
set -euo pipefail
# shellcheck source=tests/helper.sh
. "$(dirname "$0")/helper.sh"

baseline
expect_status "a request within every limit passes" 0 "$e2e" preflight
grep -q 'PASS' <<<"$out" && ! grep -q FAIL <<<"$out" || fail "every row passes" "$out"
ok "a request within every limit passes"

expect_status "too many guests" 1 env E2E_REQ_VMS=5 "$e2e" preflight
grep -q 'e2e guests (cap).*FAIL' <<<"$out" || fail "the guest row fails" "$out"
ok "too many guests is refused"

expect_status "too many vCPU" 1 env E2E_REQ_VCPU=17 "$e2e" preflight
grep -q 'e2e vCPU (cap).*FAIL' <<<"$out" || fail "the vCPU row fails" "$out"
ok "too many vCPU is refused"

expect_status "RAM over the cap" 1 env E2E_REQ_RAM_BYTES=$((33 * GIB)) "$e2e" preflight
grep -q 'e2e RAM bytes (cap).*FAIL' <<<"$out" || fail "the RAM cap row fails" "$out"
ok "RAM over the cap is refused"

# 20 GiB committed + 29 GiB requested is 49 GiB, over 75% of 64 GiB, while the cap allows it.
expect_status "RAM over 75 percent of the host" 1 env E2E_CAP_RAM_BYTES=$((64 * GIB)) E2E_REQ_RAM_BYTES=$((29 * GIB)) "$e2e" preflight
grep -q 'host RAM committed bytes (75%).*FAIL' <<<"$out" || fail "the host RAM row fails" "$out"
grep -q 'e2e RAM bytes (cap).*PASS' <<<"$out" || fail "the RAM cap row still passes" "$out"
ok "the 75 percent host RAM rule refuses a request the cap allows"

expect_status "disk over the cap" 1 env E2E_REQ_DISK_BYTES=$((201 * GIB)) "$e2e" preflight
grep -q 'e2e disk bytes (cap).*FAIL' <<<"$out" || fail "the disk cap row fails" "$out"
ok "disk over the cap is refused"

# 300 GiB provisioned + 650 GiB requested is 950 GiB, over 90% of 1000 GiB.
expect_status "provisioned disk over 90 percent" 1 env E2E_CAP_DISK_BYTES=$((1000 * GIB)) E2E_REQ_DISK_BYTES=$((650 * GIB)) "$e2e" preflight
grep -q 'provisioned disk bytes (90%).*FAIL' <<<"$out" || fail "the pool ceiling row fails" "$out"
ok "the 90 percent provisioned disk ceiling is enforced in bytes"

guests "$(guest 100 running $((20 * GIB)) 4 home '')" "$(guest 9001 running $((8 * GIB)) 4 e2e 'kube-e2e;e2e-1-aaa;created-1')" "$(guest 9002 running $((8 * GIB)) 4 e2e 'kube-e2e;e2e-1-aaa;created-1')" "$(guest 9500 running $((8 * GIB)) 4 e2e '')" "$(guest 9003 running $((8 * GIB)) 4 home '')" "$(guest 8000 running $((8 * GIB)) 4 home '')"
expect_status "existing e2e guests count" 1 env E2E_REQ_VMS=1 "$e2e" preflight
grep -q 'e2e guests (cap).*need=5 ' <<<"$out" || fail "the pool and the VMID range are joined: four existing plus one requested" "$out"
ok "a guest counts when it is in the pool or in the VMID range, and a guest in neither does not"

baseline
guests "$(guest 100 running $((20 * GIB)) 4 home '')" "$(guest 101 running $((40 * GIB)) 4 home '' 0 node2)"
expect_status "guests on another node are not committed here" 0 "$e2e" preflight
ok "committed RAM counts only the running guests of the node"

baseline
expect_status "a bad VMID range" 2 env E2E_VMID_MIN=9100 E2E_VMID_MAX=9000 "$e2e" preflight
ok "a VMID range with the minimum above the maximum stops the run"

baseline
expect_status "an unverified disk rule fails closed" 1 env -u E2E_DISK_RULE_VERIFIED "$e2e" preflight
grep -q 'NOT VERIFIED' <<<"$out" || fail "the message says the disk rule is not verified" "$out"
ok "the disk rule fails closed until the owner has compared it with lvs"

# 300 GiB of volumes, but the pool really holds 950 GiB: the larger number counts.
fixture /nodes/node1/storage/thin1/status "{\"data\":{\"total\":$((1000 * GIB)),\"used\":$((950 * GIB))}}"
expect_status "real pool usage above the volume sizes" 1 "$e2e" preflight
grep -q 'provisioned disk bytes (90%).*FAIL' <<<"$out" || fail "the pool usage is used when it is larger" "$out"
ok "real pool usage counts when it is larger than the volume sizes, so missed snapshots cannot hide"

baseline
guests "$(guest 100 running $((20 * GIB)) 4 home '')" "$(guest 9500 stopped $((1 * GIB)) 1 e2e '')"
volumes "100:$((300 * GIB))" "9500:$((150 * GIB))"
expect_status "disk of a pool guest outside the range" 1 "$e2e" preflight
grep -q 'e2e disk bytes (cap).*need=268435456000 ' <<<"$out" || fail "the disk of a pool guest counts" "$out"
ok "the disk of a pool guest outside the VMID range counts"

baseline
for name in E2E_CAP_VMS E2E_CAP_VCPU E2E_CAP_RAM_BYTES E2E_CAP_DISK_BYTES E2E_REQ_VMS E2E_VMID_MIN E2E_POOL E2E_AUDIT_TOKEN; do
  expect_status "a missing $name stops the run" 2 env -u "$name" "$e2e" preflight
  grep -q "$name is not set" <<<"$out" || fail "the message names $name" "$out"
done
expect_status "a cap that is not a number" 2 env E2E_CAP_VMS=four "$e2e" preflight
ok "a missing or non-numeric input stops the run before any API call"

rm "$work/api/_nodes_node1_status.json"
expect_status "an unreadable API fails closed" 1 "$e2e" preflight
baseline
rm "$work/api/_nodes_node1_storage_thin1_content.json"
expect_status "unreadable storage content fails closed" 1 "$e2e" preflight
ok "an API call that fails refuses the run"

baseline
fixture /nodes/node1/status '{"data":{}}'
expect_status "a status without memory fails closed" 1 "$e2e" preflight
ok "an unexpected API shape refuses the run"

baseline
"$e2e" preflight >/dev/null
[ -s "$FAKE_API/tokens.log" ] || fail "the API was called"
! grep -qv '^audit@pve!audit=fake-audit-secret$' "$FAKE_API/tokens.log" || fail "only the audit token is used" "$(cat "$FAKE_API/tokens.log")"
! grep -q -v '^GET ' "$FAKE_API/requests.log" || fail "the preflight only reads" "$(cat "$FAKE_API/requests.log")"
ok "the preflight uses the read-only audit token and only reads"

# --- Added after the second review ---

baseline
expect_status "a leading zero is not octal" 2 env E2E_CAP_VMS=08 "$e2e" preflight
grep -q 'leading zero' <<<"$out" || fail "the message names the leading zero" "$out"
ok "a number with a leading zero is refused, not read as octal"

baseline
fixture /access/permissions '{"data":{"/":{"VM.Audit":1}}}'
expect_status "an audit token without Sys.Audit" 1 "$e2e" preflight
grep -q 'VM.Audit and Sys.Audit' <<<"$out" || fail "the message names the permissions" "$out"
fixture /access/permissions '{"data":{}}'
expect_status "an audit token with no permissions on /" 1 "$e2e" preflight
rm "$work/api/_access_permissions.json"
expect_status "permissions that cannot be read" 1 "$e2e" preflight
ok "the preflight refuses an audit token that cannot see every guest"

baseline
guests
expect_status "an empty guest list" 1 "$e2e" preflight
grep -q 'guest list is empty' <<<"$out" || fail "the message says the list is empty" "$out"
ok "an empty guest list is refused, since the token may not see the guests"
