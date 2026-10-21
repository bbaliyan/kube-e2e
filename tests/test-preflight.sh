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

guests "$(guest 100 running $((20 * GIB)) 4 home '')" \
  "$(guest 9001 running $((8 * GIB)) 4 e2e 'kube-e2e;e2e-1-aaa;created-1')" \
  "$(guest 9002 running $((8 * GIB)) 4 e2e 'kube-e2e;e2e-1-aaa;created-1')" \
  "$(guest 9500 running $((8 * GIB)) 4 e2e '')" \
  "$(guest 9003 running $((8 * GIB)) 4 home '')"
expect_status "existing e2e guests count" 1 env E2E_REQ_VMS=3 "$e2e" preflight
grep -q 'e2e guests (cap).*need=5 ' <<<"$out" || fail "two existing guests plus three requested make five" "$out"
ok "existing e2e guests count, and guests outside the pool or the VMID range do not"

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
