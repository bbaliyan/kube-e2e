#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for lib/tags.sh.
set -euo pipefail
# shellcheck source=tests/helper.sh
. "$(dirname "$0")/helper.sh"
# shellcheck source=lib/tags.sh
. "$root/lib/tags.sh"

id="$(e2e_new_run_id)"
[[ "$id" =~ ^e2e-1700000000-[0-9a-f]{6}$ ]] || fail "run id has the expected shape" "$id"
[ "$id" != "$(e2e_new_run_id)" ] || fail "two run ids differ"
ok "run id has the time and a random part"

[ "$(e2e_guest_tags e2e-1-aaa 1700000000)" = "kube-e2e;e2e-1-aaa;created-1700000000" ] || fail "tags without a hold"
[ "$(e2e_guest_tags e2e-1-aaa 1700000000 1700007200)" = "kube-e2e;e2e-1-aaa;created-1700000000;hold-until-1700007200" ] || fail "tags with a hold"
ok "guest tags carry the mark, the run id, the age and an optional hold"

tags="kube-e2e;e2e-1-aaa;created-1700000000;hold-until-1700007200"
[ "$(e2e_tag_epoch created "$tags")" = 1700000000 ] || fail "created epoch"
[ "$(e2e_tag_epoch hold-until "$tags")" = 1700007200 ] || fail "hold-until epoch"
[ -z "$(e2e_tag_epoch hold-until "kube-e2e;created-5")" ] || fail "no hold prints nothing"
[ "$(e2e_tag_epoch created "a,created-7,b")" = 7 ] || fail "comma separated tags"
ok "epochs are read from the tags"

e2e_has_tag e2e-1-aaa "$tags" || fail "the run tag is found"
! e2e_has_tag e2e-1-aa "$tags" || fail "a prefix of a run id does not match"
! e2e_has_tag e2e-1-aaaa "$tags" || fail "a longer run id does not match"
ok "the run tag matches as a whole tag only"
