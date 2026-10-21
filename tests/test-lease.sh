#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for the Lease lock, against a fake kubectl that behaves like the API server.
set -euo pipefail
# shellcheck source=tests/helper.sh
. "$(dirname "$0")/helper.sh"

t0="$E2E_NOW"
as() { # holder seconds-after-start command...
  local holder="$1" at="$2"
  shift 2
  env E2E_HOLDER="$holder" E2E_NOW=$((t0 + at)) "$e2e" lease "$@"
}

expect_status "a free Lease is acquired" 0 as run-a 0 acquire
[ -f "$work/k8s/lease.json" ] || fail "the Lease exists"
ok "a free Lease is acquired"

expect_status "a second run is blocked" 1 as run-b 10 acquire
grep -q 'held by run-a' <<<"$out" || fail "the message names the holder" "$out"
ok "the Lease blocks a second run"

expect_status "the holder can acquire again" 0 as run-a 20 acquire
ok "the holder can acquire again"

# The holder renewed at 20 seconds, so the Lease ends at 7220.
expect_status "blocked just before the TTL ends" 1 as run-b 7219 acquire
expect_status "taken over after the TTL" 0 as run-b 7221 acquire
[ "$(jq -r .spec.holderIdentity "$work/k8s/lease.json")" = run-b ] || fail "the new holder is recorded"
ok "an expired Lease can be taken over, and not before"

rm "$work/k8s/lease.json"
as run-a 0 acquire >/dev/null
expect_status "a renew by the holder works" 0 as run-a 3600 renew
expect_status "a renew by another run fails" 1 as run-b 3600 renew
expect_status "still blocked at the old expiry" 1 as run-b 7201 acquire
expect_status "free after the renewed TTL" 0 as run-b 10801 acquire
ok "a renew pushes the expiry out, and only the holder can renew"

rm "$work/k8s/lease.json"
as run-a 0 acquire >/dev/null
expect_status "a hold of one hour" 0 as run-a 100 hold 3600
[ "$out" = "$((t0 + 3700))" ] || fail "the hold prints its end" "$out"
[ "$(jq -r '.metadata.annotations["kube-e2e/hold-until-epoch"]' "$work/k8s/lease.json")" = "$((t0 + 3700))" ] || fail "the hold is recorded"
expect_status "a hold longer than two hours" 2 as run-a 100 hold 7201
expect_status "a hold by another run" 1 as run-b 100 hold 60
expect_status "release is refused during a hold" 1 as run-a 200 release
grep -q 'hold is active' <<<"$out" || fail "the refusal says why" "$out"
[ -f "$work/k8s/lease.json" ] || fail "the Lease is still there"
expect_status "a forced release works" 0 env E2E_FORCE_RELEASE=1 E2E_HOLDER=run-a E2E_NOW=$((t0 + 200)) "$e2e" lease release
[ ! -f "$work/k8s/lease.json" ] || fail "the Lease is gone"
ok "a hold is capped at two hours and blocks a normal release"

as run-a 0 acquire >/dev/null
expect_status "release by another run" 1 as run-b 10 release
[ -f "$work/k8s/lease.json" ] || fail "another run cannot delete it"
expect_status "release by the holder" 0 as run-a 10 release
expect_status "release when it is already gone" 0 as run-a 10 release
ok "only the holder releases the Lease"

as run-a 0 acquire >/dev/null
# Another writer changes the Lease between our read and our write.
expect_status "a lost race is refused" 1 env FAKE_K8S_BUMP_AFTER_GET=1 E2E_HOLDER=run-b E2E_NOW=$((t0 + 7201)) "$e2e" lease acquire
grep -q 'took it first' <<<"$out" || fail "the message says the race was lost" "$out"
ok "a stale resourceVersion refuses the takeover"

rm -f "$work/k8s/lease.json"
as run-a 0 acquire >/dev/null
expect_status "a valid Lease is not stale" 0 as run-z 100 release-stale
grep -q 'still valid' <<<"$out" || fail "the Lease is kept" "$out"
[ -f "$work/k8s/lease.json" ] || fail "the Lease is kept"
expect_status "an expired Lease is deleted" 0 as run-z 7201 release-stale
[ ! -f "$work/k8s/lease.json" ] || fail "the stale Lease is deleted"
ok "the janitor call deletes only an expired Lease"

as run-a 0 acquire >/dev/null
expect_status "status of a held Lease" 0 as run-z 5 status
grep -q 'held by run-a until' <<<"$out" || fail "status names the holder" "$out"
rm "$work/k8s/lease.json"
expect_status "status of a free Lease" 0 as run-z 5 status
grep -q 'free' <<<"$out" || fail "status says free" "$out"
ok "status reports the holder or free"

expect_status "a missing holder stops the run" 2 env -u E2E_HOLDER "$e2e" lease acquire
ok "a missing input stops the run"

# --- Added after review ---

rm -f "$work/k8s/lease.json"
expect_status "an unreachable cluster is not a held Lease" 4 env FAKE_K8S_DOWN=1 E2E_HOLDER=run-a "$e2e" lease acquire
grep -q 'cannot reach the cluster' <<<"$out" || fail "the message says the cluster is unreachable" "$out"
ok "acquire answers exit 4 when the cluster is unreachable"

rm -f "$work/k8s/lease.json"
as run-a 0 acquire >/dev/null
expect_status "release survives a change after the read" 1 env FAKE_K8S_BUMP_AFTER_GET=1 E2E_HOLDER=run-a E2E_NOW=$((t0 + 10)) "$e2e" lease release
[ -f "$work/k8s/lease.json" ] || fail "a Lease that changed after the read is not deleted"
grep -q 'changed since it was read' <<<"$out" || fail "the message says why" "$out"
ok "release deletes only the Lease it read, so a newer Lease stays"

# The time comes from jq, not from GNU date -d. This date fails like BSD date.
mkdir -p "$work/bsd"
printf '#!/usr/bin/env bash\nfor arg; do [ "$arg" != -d ] || exit 1; done\nexec /usr/bin/date "$@"\n' >"$work/bsd/date"
chmod +x "$work/bsd/date"
run_status env PATH="$work/bsd:$PATH" bash -c ". '$root/lib/lease.sh'; e2e_lease_iso 1700000000"
[ "$out" = "2023-11-14T22:13:20.000000Z" ] || fail "the Lease time is formatted without GNU date" "$out"
ok "the Lease time does not depend on GNU date"
