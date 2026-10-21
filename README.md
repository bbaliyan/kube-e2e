# kube-e2e

The end-to-end harness for the kube-stack spokes. It is small shell code that
makes an end-to-end run safe to start, easy to debug and certain to clean up.

This repo is public and holds code only. It holds no address, token or cap.
Every value comes from the environment of the runner. Consume the repo by
commit SHA.

## What it does

`bin/e2e run <scenario> -- <command>` runs one scenario in this order:

1. Take the Lease. If another run holds it, stop with exit 3.
2. Run the preflight. If the request is over a cap, stop with exit 1.
3. Make a run id and a one-time SSH key.
4. Run the scenario command with a hard limit of 90 minutes.
5. If the scenario failed, capture logs first.
6. If `E2E_KEEP_ON_FAILURE=1` and the scenario failed, hold the guests for 2 hours. Skip the teardown.
7. Otherwise run the teardown hook and verify that no guest with the run tag remains.
8. Delete the SSH key and release the Lease.
9. If the scenario failed and `E2E_ISSUE_REPO` is set, open or update one failure issue.

If a guest with the run tag remains after teardown, the run fails and keeps the
Lease. The next run cannot start beside the leftovers. The janitor deletes the
guests, then releases the stale Lease.

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
| `E2E_AUDIT_TOKEN` | Read-only audit token, `user@realm!name=secret`. Used to read |
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
| `E2E_KEY_ROOT` | Optional. Parent directory of the one-time SSH key. Default `TMPDIR` |
| `E2E_ISSUE_REPO`, `E2E_ISSUE_TOKEN` | Optional. Spoke that owns the scenario, and an issue-only token |
| `E2E_RUN_URL` | Optional. Link to the run, put in the failure issue |

The scenario command gets `E2E_RUN_ID` and `E2E_KEY_DIR`. It must tag every
guest with the tags from `lib/tags.sh`: `kube-e2e`, the run id and
`created-<epoch>`.

## The rules

- The e2e guests, existing and requested, stay within the four caps.
- RAM committed by all running guests, plus the request, stays within 75% of the host RAM.
- Provisioned disk of every volume on the storage, plus the request, stays within 90% of the storage size. Sizes are in bytes from the API.
- One Lease serialises runs from GitHub and GitLab. It expires 2 hours after the last renewal. A hold renews it.
- A run takes at most 90 minutes. A hold takes at most 2 hours.

## Tags

Every guest carries `kube-e2e;<run id>;created-<epoch>`. A held guest also
carries `hold-until-<epoch>`. The janitor reads the same tags.

## Tests

Run all checks in the kube-devenv image:

```text
docker run --rm -v "$PWD:/w" -w /w ghcr.io/bbaliyan/kube-devenv:0.11.1 make test-commit
```

The tests run against fake `curl`, `kubectl` and `gh` commands in
`tests/fakes`. No Proxmox or cluster is needed. Real Proxmox behaviour is tested
only by the end-to-end scenarios.

Run `make hooks` once to run the format check and secret scan before each commit.
