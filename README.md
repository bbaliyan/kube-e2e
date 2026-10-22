# kube-e2e

The end-to-end harness for the kube-stack spokes. It is small shell code that
makes an end-to-end run safe to start, easy to debug and certain to clean up.

This repo is public and holds code only. It holds no address, token or cap.
Every value comes from the environment of the runner. Consume the repo by
commit SHA.

## What it does

`bin/e2e run <scenario> -- <command>` runs one scenario in this order:

1. Check every input. A missing or bad input stops the run with exit 2, before any Lease is taken. A number with a leading zero is refused, not read as octal.
2. Take the Lease. If another run holds it, stop with exit 3. If the cluster cannot be reached, stop with exit 4.
3. Run the preflight. If the request is over a cap, or the audit token cannot see every guest, stop with exit 1.
4. Make a run id and a one-time SSH key.
5. Mark the Lease `leftovers` with a hold far in the future. From now on, guests may exist, and a killed run keeps the Lease.
6. Run the scenario command with a hard limit of 90 minutes. A loop renews the Lease every 10 minutes. A failed renew is retried with a growing wait. If it keeps failing, the run no longer owns the Lease: the loop stops the scenario, and the run tears down without touching the Lease.
7. If the scenario failed, capture logs first. The hook has at most 10 minutes.
8. If `E2E_KEEP_ON_FAILURE=1` and the scenario failed, hold the guests for 2 hours. Skip the teardown. The Lease stays marked.
9. Otherwise stop the renew loop, run the teardown hook (at most 30 minutes) and verify that no guest with the run tag remains.
10. If the check is clean, clear the mark, delete the SSH key and release the Lease.
11. If the scenario failed and `E2E_ISSUE_REPO` is set, open or update one failure issue.

INT and TERM stop the scenario, and the run still tears down. A second signal
does not cut the teardown short. Any early exit tears down, releases the Lease
first and then deletes the key.

The mark is the key rule. While a Lease is marked `leftovers`, no other run can
take it, whatever the clock says, and a renew never lowers its hold-until time.
Only the holder after a clean check, or `bin/e2e lease release-stale` after the
janitor deleted the guests, clears it. `release-stale` checks that the audit
token can see the guests and that none of the run remains. It deletes with uid
and resourceVersion preconditions, so it never deletes a newer Lease. A Lease
that is not marked is freed by its TTL, 2 hours after the last renewal.

Exit codes: 0 pass, 1 refused or leftovers, 2 bad input, 3 the Lease is held,
4 the cluster is unreachable. The status of a failing scenario is passed on as
it is, so a scenario that exits with 1 to 4 looks like one of these codes. The
`run:` lines in the output say which it was.

## Commands

| Command | Use |
|---|---|
| `bin/e2e preflight` | Check the request against the caps and the host rules |
| `bin/e2e lease acquire\|renew\|hold <seconds>\|release\|release-stale\|status` | Work with the Lease |
| `bin/e2e verify-clean <run id>` | Fail if a guest with the run tag remains |
| `bin/e2e hold <run id> <seconds>` | Tag the guests and the Lease for debugging, at most 7200 seconds |
| `bin/e2e issue <scenario> <run id> [run url]` | Open or update the failure issue |
| `bin/e2e run <scenario> -- <command>` | Do the whole sequence |

## Inputs

Every input is required unless it says optional. A missing input stops the run
with exit 2. There are no defaults for caps or addresses.

| Variable | Meaning |
|---|---|
| `E2E_API_URL` | Proxmox API base URL, ending in `/api2/json` |
| `E2E_CA_FILE` | Optional. CA file for the API |
| `E2E_AUDIT_TOKEN` | Read-only audit token, `user@realm!name=secret`. It needs `VM.Audit` and `Sys.Audit` on `/`, or the guest list is shorter and no error shows. The harness checks this and refuses to go on |
| `E2E_TOKEN` | The end-to-end token. Used to tag guests |
| `E2E_NODE`, `E2E_STORAGE` | Node name and thin-pool storage id |
| `E2E_POOL` | Resource pool of the end-to-end guests |
| `E2E_VMID_MIN`, `E2E_VMID_MAX` | Reserved VMID range of the end-to-end guests |
| `E2E_CAP_VMS`, `E2E_CAP_VCPU` | Caps on guests and vCPU |
| `E2E_CAP_RAM_BYTES`, `E2E_CAP_DISK_BYTES` | Caps on RAM and disk, in bytes |
| `E2E_REQ_VMS`, `E2E_REQ_VCPU`, `E2E_REQ_RAM_BYTES`, `E2E_REQ_DISK_BYTES` | What the scenario will create |
| `E2E_LEASE_NAME`, `E2E_LEASE_NAMESPACE` | The Kubernetes Lease. `kubectl` must reach the cluster |
| `E2E_HOLDER` | Holder of the Lease. `run` sets it to the run id |
| `E2E_LOG_DIR` | Where logs are captured |
| `E2E_CAPTURE_HOOK` | Optional. Program called as `hook <log dir>` after a failure |
| `E2E_TEARDOWN_HOOK` | Optional. Program that destroys the guests |
| `E2E_KEEP_ON_FAILURE` | Optional. `1` holds a failed run for 2 hours |
| `E2E_RUN_LIMIT_SECONDS` | Optional. Hard limit, at most 5400 |
| `E2E_CAPTURE_LIMIT_SECONDS`, `E2E_TEARDOWN_LIMIT_SECONDS` | Optional. Limits of the hooks, at most 600 and 1800 |
| `E2E_RENEW_INTERVAL_SECONDS` | Optional. Lease renewal every so many seconds, at most 3600. Default 600 |
| `E2E_RENEW_RETRIES`, `E2E_RENEW_RETRY_SECONDS` | Optional. Failed renews before the run gives up the Lease (at most 10, default 5), and the first wait, doubled each time (at most 120, default 15) |
| `E2E_DISK_RULE_VERIFIED` | Set to `1` after you compared the disk numbers with `lvs`. See the rules |
| `E2E_KEY_ROOT` | Optional. Parent directory of the one-time SSH key. Default `TMPDIR` |
| `E2E_ISSUE_REPO`, `E2E_ISSUE_TOKEN` | Optional. Spoke that owns the scenario, and an issue-only token |
| `E2E_RUN_URL` | Optional. Link to the run, put in the failure issue |

The scenario command and the hooks do not get `E2E_AUDIT_TOKEN` or
`E2E_ISSUE_TOKEN`. They get `E2E_RUN_ID` and `E2E_KEY_DIR`. The scenario must tag every
guest with the tags from `lib/tags.sh`: `kube-e2e`, the run id and
`created-<epoch>`.

## Lease timing

The worst case of one run is the run limit, the capture limit and the teardown
limit together: about 7900 seconds with the kill delays. That is more than the
2 hour TTL. The TTL does not need to cover it, because the Lease is marked
`leftovers` for the whole run, and a marked Lease is never freed by the clock.
The TTL frees only an unmarked Lease, for example one left by a run that never
reached the scenario.

## The rules

- A guest is an e2e guest when it is in the pool or its VMID is in the reserved range.
- The e2e guests, existing and requested, stay within the four caps.
- RAM committed by the running guests of the node, plus the request, stays within 75% of the host RAM.
- Provisioned disk, plus the request, stays within 90% of the storage size. Sizes are in bytes from the API. Provisioned is the larger of the sum of volume sizes and the real pool usage, because the content list may miss thin snapshots.
- **The disk rule fails closed.** Until `E2E_DISK_RULE_VERIFIED=1`, every preflight is refused. Compare the numbers the preflight prints with `lvs` on the host, including snapshots, then set the variable.
- One Lease serialises runs from GitHub and GitLab. It expires 2 hours after the last renewal. A hold renews it.
- A run takes at most 90 minutes. A hold takes at most 2 hours.
- An empty guest list is an error, because a host always has guests. Teardown never passes on a list the audit token may not see.

## Tags

Every guest carries `kube-e2e;<run id>;created-<epoch>`. A held guest also
carries `hold-until-<epoch>`. The janitor reads the same tags.

## Cautions

- Never run these scripts with `set -x` or `bash -x`. The tokens are in the environment, and a trace prints them.
- The failure issue is deduplicated by a search on the title. GitHub's search index can lag by a minute or more, so two failures close together can open two issues. Close the extra by hand.
- `e2e lease release-stale` needs `kubectl delete --raw` with a body on standard input. Verify it against your cluster once.
- The Lease time uses `jq`, so no GNU `date` is needed. The scripts still expect `bash` 4.4 or newer, `curl`, `jq`, `kubectl` and `timeout`.

## Tests

Run all checks in the kube-devenv image:

```text
docker run --rm -v "$PWD:/w" -w /w ghcr.io/bbaliyan/kube-devenv:0.11.1 make test-commit
```

The tests run against fake `curl`, `kubectl` and `gh` commands in
`tests/fakes`. No Proxmox or cluster is needed. Real Proxmox behaviour is tested
only by the end-to-end scenarios.

Run `make hooks` once to run the format check and secret scan before each commit.
