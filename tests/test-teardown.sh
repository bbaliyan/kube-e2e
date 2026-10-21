#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for the teardown check and the hold, against the fake Proxmox API.
set -euo pipefail
# shellcheck source=tests/helper.sh
. "$(dirname "$0")/helper.sh"

baseline
expect_status "a clean host passes" 0 "$e2e" verify-clean e2e-1-aaa
ok "nothing tagged remains: pass"

guests
expect_status "an empty guest list passes" 0 "$e2e" verify-clean e2e-1-aaa
fixture /cluster/resources?type=vm '{"nope":[]}'
expect_status "an unexpected shape fails closed" 1 "$e2e" verify-clean e2e-1-aaa
ok "an empty guest list passes and an unexpected shape fails"

guests "$(guest 100 running $((20 * GIB)) 4 home '')" \
  "$(guest 9001 running $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-aaa;created-1')" \
  "$(guest 9002 stopped $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-aaa;created-1')" \
  "$(guest 9003 running $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-aaab;created-1')" \
  "$(guest 9004 running $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-zzz;created-1')"
expect_status "leftovers are found" 1 "$e2e" verify-clean e2e-1-aaa
{ grep -q 'vmid 9001' <<<"$out" && grep -q 'vmid 9002' <<<"$out"; } || fail "both leftovers are listed" "$out"
! grep -q 'vmid 9003\|vmid 9004' <<<"$out" || fail "other runs are not listed" "$out"
ok "teardown check finds the leftovers of the run, running or stopped, and only those"

expect_status "a prefix of a run id matches nothing" 0 "$e2e" verify-clean e2e-1-aa
ok "a run id that is a prefix of another does not match it"

rm "$work/api/_cluster_resources_type_vm.json"
expect_status "an unreadable API fails closed" 1 "$e2e" verify-clean e2e-1-aaa
ok "an API failure is a failure, not a pass"

# The hold.
guests "$(guest 9001 running $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-aaa;created-1;hold-until-5')" \
  "$(guest 9002 stopped $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-aaa;created-1')" \
  "$(guest 9003 running $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-other;created-1')"
env E2E_HOLDER=e2e-1-aaa "$e2e" lease acquire >/dev/null
: >"$FAKE_API/requests.log"
: >"$FAKE_API/tokens.log"
expect_status "a hold of two hours" 0 env E2E_HOLDER=e2e-1-aaa "$e2e" hold e2e-1-aaa 7200
hold_until=$((E2E_NOW + 7200))
grep -qx "PUT /nodes/node1/qemu/9001/config tags=kube-e2e;e2e-1-aaa;created-1;hold-until-$hold_until" "$FAKE_API/requests.log" ||
  fail "guest 9001 gets one hold-until tag" "$(cat "$FAKE_API/requests.log")"
grep -qx "PUT /nodes/node1/qemu/9002/config tags=kube-e2e;e2e-1-aaa;created-1;hold-until-$hold_until" "$FAKE_API/requests.log" ||
  fail "guest 9002 gets the hold-until tag" "$(cat "$FAKE_API/requests.log")"
! grep -q '9003/config' "$FAKE_API/requests.log" || fail "another run's guest is not touched"
[ "$(jq -r '.metadata.annotations["kube-e2e/hold-until-epoch"]' "$work/k8s/lease.json")" = "$hold_until" ] ||
  fail "the Lease holds until the same time"
ok "a hold tags every guest of the run, replaces an old hold, and holds the Lease to the same time"

grep -qx 'e2e@pve!e2e=fake-e2e-secret' "$FAKE_API/tokens.log" || fail "the e2e token tags the guests"
grep -qx 'audit@pve!audit=fake-audit-secret' "$FAKE_API/tokens.log" || fail "the audit token reads the guests"
ok "the hold writes with the e2e token and reads with the audit token"

expect_status "a hold over two hours" 2 env E2E_HOLDER=e2e-1-aaa "$e2e" hold e2e-1-aaa 7201
expect_status "a hold of zero seconds" 2 env E2E_HOLDER=e2e-1-aaa "$e2e" hold e2e-1-aaa 0
ok "a hold is at most two hours"

# --- Added after review ---

reset_lease() { rm -f "$work/k8s/lease.json"; }
t0="$E2E_NOW"
mark_leftovers() { # holder
  reset_lease
  env E2E_HOLDER="$1" "$e2e" lease acquire >/dev/null
  # shellcheck source=lib/lease.sh
  (. "$root/lib/lease.sh" && E2E_HOLDER="$1" e2e_lease_mark_leftovers)
}

# A guest list that cannot be read fails the hold and tags nothing.
reset_lease
env E2E_HOLDER=e2e-1-aaa "$e2e" lease acquire >/dev/null
rm -f "$work/api/_cluster_resources_type_vm.json"
: >"$FAKE_API/requests.log"
expect_status "a hold with an unreadable guest list" 1 env E2E_HOLDER=e2e-1-aaa "$e2e" hold e2e-1-aaa 3600
grep -q 'cannot read the guest list' <<<"$out" || fail "the failure is loud" "$out"
! grep -q '^PUT' "$FAKE_API/requests.log" || fail "nothing was tagged"
ok "a guest list read failure fails the hold instead of exiting 0"

# One failing tag does not stop the others, holds the Lease, and fails the hold.
guests "$(guest 9001 running $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-aaa;created-1')" \
  "$(guest 9002 running $((4 * GIB)) 2 e2e 'kube-e2e;e2e-1-aaa;created-1')"
: >"$FAKE_API/requests.log"
expect_status "a hold where one tag fails" 1 env FAKE_API_FAIL_PUT=9001 E2E_HOLDER=e2e-1-aaa "$e2e" hold e2e-1-aaa 3600
grep -q 'cannot tag vmid 9001' <<<"$out" || fail "the failed guest is named" "$out"
grep -q 'PUT /nodes/node1/qemu/9002/config' "$FAKE_API/requests.log" || fail "the other guest is still tagged" "$(cat "$FAKE_API/requests.log")"
[ "$(jq -r '.metadata.annotations["kube-e2e/hold-until-epoch"]' "$work/k8s/lease.json")" = "$((t0 + 3600))" ] || fail "the Lease is held anyway"
ok "a failed tag is reported after every guest was tried, and the Lease is still held"

# A failed Lease renew is a failure even when the hold is used in an && list.
run_status env E2E_HOLDER=someone-else bash -c ". '$root/lib/teardown.sh'; e2e_hold e2e-1-aaa 3600 && echo held"
! grep -q '^held$' <<<"$out" || fail "a failed renew is not reported as a hold" "$out"
ok "a hold whose Lease renew fails does not count as held"

# release-stale
mark_leftovers e2e-1-aaa
expect_status "release-stale with the guests still there" 0 env E2E_HOLDER=janitor E2E_NOW=$((t0 + 100000)) "$e2e" lease release-stale
grep -q 'remain' <<<"$out" || fail "the leftovers are named" "$out"
[ -f "$work/k8s/lease.json" ] || fail "the Lease stays while the guests remain"
guests
expect_status "release-stale after the guests are gone" 0 env E2E_HOLDER=janitor E2E_NOW=$((t0 + 100000)) "$e2e" lease release-stale
[ ! -f "$work/k8s/lease.json" ] || fail "the Lease is deleted once the guests are gone"
ok "release-stale clears a leftovers Lease only after the guests are gone"

mark_leftovers e2e-1-aaa
guests
expect_status "a leftovers Lease changed after the read" 1 env FAKE_K8S_BUMP_AFTER_GET=1 E2E_HOLDER=janitor "$e2e" lease release-stale
[ -f "$work/k8s/lease.json" ] || fail "release-stale does not delete a Lease that changed after the read"
ok "release-stale deletes only the Lease it read"

reset_lease
env E2E_HOLDER=e2e-1-aaa "$e2e" lease acquire >/dev/null
expect_status "release-stale on a valid Lease" 0 env E2E_HOLDER=janitor E2E_NOW=$((t0 + 100)) "$e2e" lease release-stale
[ -f "$work/k8s/lease.json" ] || fail "a valid Lease stays"
expect_status "release-stale on an expired Lease" 0 env E2E_HOLDER=janitor E2E_NOW=$((t0 + 7201)) "$e2e" lease release-stale
[ ! -f "$work/k8s/lease.json" ] || fail "an expired Lease is deleted"
ok "release-stale keeps a valid Lease and deletes an expired one"
