# CLAUDE.md

## Working agreement

- Carry out requested actions end to end without asking the repo owner for input or confirmation.
- Once a PR's checks pass, merge it without asking. This covers the current PR and future ones.
- If checks fail, fix the problem and re-run before merging. Do not merge a PR with failing checks.

## Repo contents

- `.github/workflows/civo-cluster-cleanup.yml` deletes every Civo Kubernetes cluster in every region daily at 1:00 AM America/Los_Angeles. It uses the `CIVO_TOKEN` secret. A PR that changes this workflow runs it in dry-run mode.
