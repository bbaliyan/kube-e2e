#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for the per-run SSH key.
set -euo pipefail
# shellcheck source=tests/helper.sh
. "$(dirname "$0")/helper.sh"
# shellcheck source=lib/sshkey.sh
. "$root/lib/sshkey.sh"

dir="$(e2e_sshkey_create e2e-1-aaa)"
[ "$dir" = "$work/keys/e2e-1-aaa-key" ] || fail "the key is made under the key root" "$dir"
[ "$(stat -c %a "$dir")" = 700 ] || fail "the directory is private"
[ "$(stat -c %a "$dir/id")" = 600 ] || fail "the private key is private"
grep -q '^ssh-ed25519 ' "$dir/id.pub" || fail "the public key is an ed25519 key"
grep -q ' e2e-1-aaa$' "$dir/id.pub" || fail "the key comment is the run id"
ok "a key pair is made in a private directory"

other="$(e2e_sshkey_create e2e-1-bbb)"
[ "$other" != "$dir" ] || fail "each run gets its own key directory"
[ "$(ssh-keygen -lf "$dir/id.pub" | cut -d' ' -f2)" != "$(ssh-keygen -lf "$other/id.pub" | cut -d' ' -f2)" ] || fail "the keys differ"
ok "each run gets its own key"

run_status e2e_sshkey_create e2e-1-aaa
[ "$status" -ne 0 ] || fail "a run id cannot reuse a key directory"
ok "a key directory is never reused"

e2e_sshkey_delete e2e-1-aaa
[ ! -e "$dir" ] || fail "the key is deleted"
e2e_sshkey_delete e2e-1-aaa
ok "teardown deletes the key, and deleting twice is fine"
