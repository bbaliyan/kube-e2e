#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for the deduplicated failure issue, against a fake gh.
set -euo pipefail
# shellcheck source=tests/helper.sh
. "$(dirname "$0")/helper.sh"

export E2E_ISSUE_REPO=example/spoke E2E_ISSUE_TOKEN=fake-issue-token

expect_status "the first failure opens an issue" 0 "$e2e" issue s1-image-bake e2e-1-aaa https://ci.example.test/run/1
grep -q 'issue create --repo example/spoke --title \[e2e\] s1-image-bake failed' "$FAKE_GH/calls.log" ||
  fail "the title names the scenario" "$(cat "$FAKE_GH/calls.log")"
grep -q 'token=fake-issue-token' "$FAKE_GH/calls.log" || fail "the issue token is used"
grep -q 'https://ci.example.test/run/1' "$FAKE_GH/bodies.log" || fail "the body links the run"
ok "the first failure opens an issue with the issue token"

: >"$FAKE_GH/calls.log"
echo '[{"number":42,"title":"[e2e] s1-image-bake failed"}]' >"$FAKE_GH/list.json"
expect_status "the second failure adds a comment" 0 "$e2e" issue s1-image-bake e2e-1-bbb
grep -q 'issue comment 42 ' "$FAKE_GH/calls.log" || fail "a comment goes on issue 42" "$(cat "$FAKE_GH/calls.log")"
! grep -q 'issue create' "$FAKE_GH/calls.log" || fail "no second issue is opened"
ok "a repeat failure comments on the open issue"

: >"$FAKE_GH/calls.log"
echo '[{"number":7,"title":"[e2e] s2-single-node failed"}]' >"$FAKE_GH/list.json"
expect_status "another scenario gets its own issue" 0 "$e2e" issue s1-image-bake e2e-1-ccc
grep -q 'issue create' "$FAKE_GH/calls.log" || fail "an issue is opened" "$(cat "$FAKE_GH/calls.log")"
ok "an issue of another scenario does not match"

expect_status "a scenario name with quotes" 2 "$e2e" issue 'bad"name' e2e-1-aaa
expect_status "no issue repo" 2 env -u E2E_ISSUE_REPO "$e2e" issue s1 e2e-1-aaa
expect_status "no issue token" 2 env -u E2E_ISSUE_TOKEN "$e2e" issue s1 e2e-1-aaa
ok "a bad name or a missing input stops the run"
