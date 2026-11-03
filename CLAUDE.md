# CLAUDE.md

## Working agreement

- Carry out requested actions end to end without asking the repo owner for input or confirmation.
- Once a PR's checks pass, merge it without asking. This covers the current PR and future ones.
- If checks fail, fix the problem and re-run before merging. Do not merge a PR with failing checks.

## Repo contents

- `.github/workflows/civo-cluster-cleanup.yml` deletes every billable Civo resource except reserved IPs (clusters, instances, databases, object stores, orphaned load balancers, detached volumes) in every region, scheduled daily for 1:00 AM America/Los_Angeles (GitHub often starts it hours late). It uses the `CIVO_TOKEN` secret. A PR that changes this workflow runs it in dry-run mode.
