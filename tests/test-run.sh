#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for "e2e run", the whole sequence, with stand-in scenario and hooks.
set -euo pipefail
# shellcheck source=tests/helper.sh
. "$(dirname "$0")/helper.sh"

order="$work/order.log"
guest_file="$work/api/_cluster_resources_type_vm.json"
mkdir -p "$work/bin"

# The scenario "creates" a guest tagged with the run id. $SCENARIO_EXIT is its result.
cat >"$work/bin/scenario" <<'EOF'
#!/usr/bin/env bash
echo scenario >>"$ORDER"
printf '{"data":[{"vmid":9001,"node":"node1","status":"running","maxmem":1,"maxcpu":1,"pool":"e2e","tags":"kube-e2e;%s;created-1"}]}\n' "$E2E_RUN_ID" >"$GUEST_FILE"
[ -z "${SCENARIO_SLEEP:-}" ] || exec sleep "$SCENARIO_SLEEP"
exit "${SCENARIO_EXIT:-0}"
EOF
cat >"$work/bin/capture" <<'EOF'
#!/usr/bin/env bash
echo "capture $1" >>"$ORDER"
EOF
# The teardown hook "destroys" the guests unless LEAVE_GUESTS=1.
cat >"$work/bin/teardown" <<'EOF'
#!/usr/bin/env bash
echo teardown >>"$ORDER"
[ "${LEAVE_GUESTS:-0}" = 1 ] || echo '{"data":[]}' >"$GUEST_FILE"
EOF
chmod +x "$work/bin/"*
export ORDER="$order" GUEST_FILE="$guest_file"
export E2E_CAPTURE_HOOK="$work/bin/capture" E2E_TEARDOWN_HOOK="$work/bin/teardown"

fresh() {
  baseline
  : >"$order"
  rm -rf "$work/keys" "$work/k8s/lease.json"
  mkdir -p "$work/keys"
  : >"$FAKE_GH/calls.log"
  : >"$FAKE_API/requests.log"
  unset SCENARIO_EXIT SCENARIO_SLEEP LEAVE_GUESTS E2E_KEEP_ON_FAILURE E2E_ISSUE_REPO E2E_ISSUE_TOKEN E2E_RUN_LIMIT_SECONDS || true
}
lease_free() { [ ! -f "$work/k8s/lease.json" ]; }
keys_gone() { [ -z "$(ls -A "$work/keys")" ]; }

fresh
expect_status "a passing run" 0 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ "$(paste -sd' ' "$order")" = "scenario teardown" ] || fail "a pass runs the scenario, then teardown, and no log capture" "$(cat "$order")"
lease_free || fail "the Lease is released"
keys_gone || fail "the SSH key is deleted"
[ ! -s "$FAKE_GH/calls.log" ] || fail "a pass files no issue"
ok "a passing run tears down, deletes the key and releases the Lease"

fresh
export E2E_ISSUE_REPO=example/spoke E2E_ISSUE_TOKEN=fake-issue-token SCENARIO_EXIT=7
expect_status "a failing run keeps its exit code" 7 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ "$(paste -sd' ' "$order")" = "scenario capture $E2E_LOG_DIR teardown" ] || fail "logs are captured before teardown" "$(cat "$order")"
lease_free || fail "the Lease is released after teardown"
keys_gone || fail "the SSH key is deleted"
grep -q 'issue create' "$FAKE_GH/calls.log" || fail "a failure files the issue" "$(cat "$FAKE_GH/calls.log")"
ok "a failure captures logs first, then tears down, releases and files one issue"

fresh
export SCENARIO_EXIT=7 LEAVE_GUESTS=1
expect_status "leftovers fail the run" 7 "$e2e" run s1-image-bake -- "$work/bin/scenario"
grep -q 'guests with run tag' <<<"$out" || fail "the leftovers are reported" "$out"
[ -f "$work/k8s/lease.json" ] || fail "the Lease stays so the next run cannot start beside the leftovers"
keys_gone || fail "the SSH key is deleted anyway"
fresh
export LEAVE_GUESTS=1
expect_status "leftovers fail a passing scenario" 1 "$e2e" run s1-image-bake -- "$work/bin/scenario"
ok "leftovers after teardown fail even a passing scenario, and keep the Lease"

fresh
export SCENARIO_SLEEP=30 E2E_RUN_LIMIT_SECONDS=1
expect_status "the hard limit stops a hang" 124 "$e2e" run s1-image-bake -- "$work/bin/scenario"
grep -q 'capture' "$order" && grep -q 'teardown' "$order" || fail "a timeout still captures and tears down" "$(cat "$order")"
ok "the hard time limit stops a hung scenario and still tears down"

fresh
expect_status "a limit over 90 minutes is refused" 2 env E2E_RUN_LIMIT_SECONDS=5401 "$e2e" run s1 -- "$work/bin/scenario"
[ ! -s "$order" ] || fail "nothing ran"
ok "the time limit cannot be raised past 90 minutes"

fresh
export SCENARIO_EXIT=7 E2E_KEEP_ON_FAILURE=1
expect_status "keep on failure holds the guests" 7 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ "$(paste -sd' ' "$order")" = "scenario capture $E2E_LOG_DIR" ] || fail "no teardown during a hold" "$(cat "$order")"
grep -q 'PUT /nodes/node1/qemu/9001/config tags=kube-e2e;e2e-.*;created-1;hold-until-1700007200' "$FAKE_API/requests.log" || fail "the guest is tagged with the hold" "$(cat "$FAKE_API/requests.log")"
[ -f "$work/k8s/lease.json" ] || fail "the Lease is kept during a hold"
[ "$(jq -r '.metadata.annotations["kube-e2e/hold-until-epoch"]' "$work/k8s/lease.json")" = 1700007200 ] || fail "the Lease holds for two hours"
! keys_gone || fail "the SSH key stays for debugging"
ok "an opt-in hold keeps the guests, the key and the Lease for two hours"

fresh
export SCENARIO_EXIT=0 E2E_KEEP_ON_FAILURE=1
expect_status "a pass is never held" 0 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ "$(paste -sd' ' "$order")" = "scenario teardown" ] || fail "a pass tears down even when a hold is allowed" "$(cat "$order")"
ok "a hold applies to failures only"

fresh
env E2E_HOLDER=someone-else "$e2e" lease acquire >/dev/null
expect_status "a held Lease blocks the run" 3 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ ! -s "$order" ] || fail "the scenario did not run" "$(cat "$order")"
ok "a second run does not start while the Lease is held"

fresh
expect_status "an over-cap request is refused" 1 env E2E_REQ_VMS=9 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ ! -s "$order" ] || fail "the scenario did not run"
lease_free || fail "the Lease is released after a refusal"
ok "preflight refuses before anything is created, and gives the Lease back"

fresh
expect_status "a missing log directory" 2 env -u E2E_LOG_DIR "$e2e" run s1-image-bake -- "$work/bin/scenario"
expect_status "no command" 2 "$e2e" run s1-image-bake --
expect_status "no scenario name" 2 "$e2e" run
ok "a missing input stops the run"
