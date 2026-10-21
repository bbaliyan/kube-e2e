#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# One failure issue per scenario, not one per run. Source this file.
#
# Inputs: E2E_ISSUE_REPO (owner/name of the spoke that owns the scenario),
# E2E_ISSUE_TOKEN (a token that can only open issues there).
# A second failure of the same scenario adds a comment to the open issue.

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# e2e_failure_issue <scenario> <run id> [run url]
e2e_failure_issue() {
  e2e_require_env E2E_ISSUE_REPO E2E_ISSUE_TOKEN
  local scenario="$1" run_id="$2" url="${3:-not given}" title existing body
  title="[e2e] $scenario failed"
  body="Run $run_id failed at $(date -u +%Y-%m-%dT%H:%M:%SZ).

Run: $url

Logs are in the run artifacts. The run tag is $run_id."
  [[ "$scenario" =~ ^[A-Za-z0-9._\ -]+$ ]] || e2e_usage_die "the scenario name has characters that are not allowed"
  existing="$(GH_TOKEN="$E2E_ISSUE_TOKEN" gh issue list --repo "$E2E_ISSUE_REPO" --state open \
    --search "\"$title\" in:title" --json number,title)" || e2e_die "cannot list issues"
  existing="$(jq -r --arg t "$title" '[.[] | select(.title == $t)][0].number // empty' <<<"$existing")"
  if [ -n "$existing" ]; then
    printf '%s\n' "$body" | GH_TOKEN="$E2E_ISSUE_TOKEN" gh issue comment "$existing" --repo "$E2E_ISSUE_REPO" --body-file - >/dev/null
    echo "issue: commented on $existing"
  else
    printf '%s\n' "$body" | GH_TOKEN="$E2E_ISSUE_TOKEN" gh issue create --repo "$E2E_ISSUE_REPO" --title "$title" --body-file - >/dev/null
    echo "issue: opened"
  fi
}
