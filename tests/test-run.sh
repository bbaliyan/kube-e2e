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
[ -z "${HANG_CAPTURE:-}" ] || exec sleep 30
EOF
# The teardown hook "destroys" the guests unless LEAVE_GUESTS=1.
cat >"$work/bin/teardown" <<'EOF'
#!/usr/bin/env bash
echo teardown >>"$ORDER"
[ -z "${HANG_TEARDOWN:-}" ] || exec sleep 30
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
  : >"$FAKE_K8S/calls.log"
  unset FAKE_K8S_DOWN E2E_RENEW_INTERVAL_SECONDS E2E_TEARDOWN_LIMIT_SECONDS E2E_CAPTURE_LIMIT_SECONDS HANG_TEARDOWN HANG_CAPTURE FAKE_API_FAIL_PUT
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

# --- Added after review ---

fresh
export E2E_RENEW_INTERVAL_SECONDS=1 SCENARIO_SLEEP=3
expect_status "a run longer than the renew interval" 0 "$e2e" run s1-image-bake -- "$work/bin/scenario"
renews="$(grep -c ' replace ' "$FAKE_K8S/calls.log" || true)"
[ "$renews" -ge 2 ] || fail "the Lease is renewed while the scenario runs (replace calls: $renews)" "$(cat "$FAKE_K8S/calls.log")"
lease_free || fail "the Lease is released at the end"
ok "the Lease is renewed while the scenario runs"

fresh
export SCENARIO_EXIT=7 HANG_CAPTURE=1 E2E_CAPTURE_LIMIT_SECONDS=1
run_status timeout 25 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ "$status" -eq 7 ] || fail "a hung capture hook is cut off and the scenario status is kept (got $status)" "$out"
grep -q teardown "$order" || fail "teardown still runs after a hung capture hook"
ok "a hung log capture hook is cut off and does not block teardown"

fresh
export HANG_TEARDOWN=1 E2E_TEARDOWN_LIMIT_SECONDS=1
run_status timeout 25 "$e2e" run s1-image-bake -- "$work/bin/scenario"
[ "$status" -eq 1 ] || fail "a hung teardown hook is cut off and the run fails (got $status)" "$out"
grep -q 'guests with run tag' <<<"$out" || fail "the leftovers are still checked after a hung hook" "$out"
ok "a hung teardown hook is cut off, the leftovers check still runs"

fresh
export SCENARIO_EXIT=7 LEAVE_GUESTS=1
"$e2e" run s1-image-bake -- "$work/bin/scenario" >/dev/null 2>&1 || true
expect_status "the leftovers Lease is far in the future" 0 "$e2e" lease status
grep -q 'leftovers true' <<<"$out" || fail "the Lease is marked with the leftovers" "$out"
expect_status "a later run is still refused" 1 env E2E_HOLDER=later-run E2E_NOW=$((E2E_NOW + 100000)) "$e2e" lease acquire
ok "leftovers keep the Lease long after the original TTL"

fresh
export FAKE_K8S_DOWN=1
expect_status "an unreachable cluster has its own exit code" 4 "$e2e" run s1-image-bake -- "$work/bin/scenario"
grep -q 'cannot reach the cluster' <<<"$out" || fail "the message says the cluster is unreachable" "$out"
[ ! -s "$order" ] || fail "the scenario did not run"
unset FAKE_K8S_DOWN
ok "an unreachable cluster is told apart from a held Lease"

fresh
expect_status "a missing cap stops the run before the Lease" 2 env -u E2E_CAP_VCPU "$e2e" run s1-image-bake -- "$work/bin/scenario"
expect_status "a bad VMID range stops the run" 2 env E2E_VMID_MIN=9100 E2E_VMID_MAX=9000 "$e2e" run s1-image-bake -- "$work/bin/scenario"
expect_status "a missing node stops the run" 2 env -u E2E_NODE "$e2e" run s1-image-bake -- "$work/bin/scenario"
! grep -q ' create ' "$FAKE_K8S/calls.log" || fail "no Lease was created for a bad input" "$(cat "$FAKE_K8S/calls.log")"
ok "every input is checked before the Lease is taken"

fresh
rm "$work/api/_nodes_node1_status.json"
expect_status "an API read failure after the Lease" 1 "$e2e" run s1-image-bake -- "$work/bin/scenario"
lease_free || fail "the Lease is released when the preflight cannot read the API"
[ ! -s "$order" ] || fail "the scenario did not run"
ok "an API failure after the Lease is taken gives the Lease back"

fresh
export SCENARIO_SLEEP=30
"$e2e" run s1-cancel -- "$work/bin/scenario" >"$work/cancel.out" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  grep -q scenario "$order" && break
  sleep 0.1
done
kill -TERM "$pid"
status=0
wait "$pid" || status=$?
[ "$status" -ne 0 ] || fail "a cancelled run fails"
grep -q teardown "$order" || fail "a cancelled run still tears down" "$(cat "$order")"
lease_free || fail "a cancelled run gives the Lease back"
keys_gone || fail "a cancelled run deletes the SSH key"
grep -q 'cancelled' "$work/cancel.out" || fail "the run says it was cancelled" "$(cat "$work/cancel.out")"
ok "a cancelled run stops the scenario, tears down, deletes the key and releases the Lease"

fresh
export SCENARIO_EXIT=7 E2E_KEEP_ON_FAILURE=1 FAKE_API_FAIL_PUT=9001
expect_status "an incomplete hold still fails with the scenario status" 7 "$e2e" run s1-image-bake -- "$work/bin/scenario"
grep -q 'hold is incomplete' <<<"$out" || fail "the incomplete hold is reported" "$out"
[ -f "$work/k8s/lease.json" ] || fail "the Lease is still held"
ok "a hold that cannot tag a guest says so and keeps the Lease"
