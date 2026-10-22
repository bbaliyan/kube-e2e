#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Shared helpers. Source this file. Do not run it.
#
# Every address, token and cap comes from the environment. This repo is public,
# so it holds no value of its own. A missing value stops the run (exit 2).

e2e_die() {
  echo "kube-e2e: $*" >&2
  exit 1
}

e2e_usage_die() {
  echo "kube-e2e: $*" >&2
  exit 2
}

e2e_require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || e2e_usage_die "$name is not set"
  done
}

# A whole number without a leading zero, so bash never reads it as octal.
e2e_is_uint() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]
}

e2e_require_uint() {
  local name
  for name in "$@"; do
    e2e_require_env "$name"
    e2e_is_uint "${!name}" || e2e_usage_die "$name must be a whole number without a leading zero"
  done
}

# E2E_NOW lets a test pin the clock.
e2e_now() {
  echo "${E2E_NOW:-$(date +%s)}"
}

# e2e_api <token-variable-name> <method> <path> [curl options]
# The token goes to curl on standard input, so it never shows in a process list.
e2e_api() {
  local token_var="$1" method="$2" path="$3"
  shift 3
  e2e_require_env E2E_API_URL "$token_var"
  local ca=()
  [ -z "${E2E_CA_FILE:-}" ] || ca=(--cacert "$E2E_CA_FILE")
  printf 'header = "Authorization: PVEAPIToken=%s"\n' "${!token_var}" |
    curl -fsS "${ca[@]}" -K - -X "$method" "$@" "${E2E_API_URL%/}$path"
}

# The audit token must see every guest. A token without VM.Audit and Sys.Audit
# on / gets a shorter guest list and no error, so teardown would pass wrongly.
e2e_audit_check() {
  local perms
  perms="$(e2e_api E2E_AUDIT_TOKEN GET '/access/permissions?path=/')" || {
    echo "kube-e2e: cannot read the permissions of the audit token" >&2
    return 1
  }
  jq -e '.data["/"]["VM.Audit"] == 1 and .data["/"]["Sys.Audit"] == 1' <<<"$perms" >/dev/null || {
    echo "kube-e2e: the audit token needs VM.Audit and Sys.Audit on / to see every guest" >&2
    return 1
  }
}
