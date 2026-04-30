---
description: Permanently destroy this app's AWS resources via the orchestrator
---

Run `./scripts/destroy.sh` and stream the output.

The script:
- Reads `app_name` from `infra/terraform.tfvars`.
- Shows the user what will be destroyed (Lambda, CloudFront, DB, S3, etc.) with explicit warnings about irreversibility.
- Requires the user to type the exact `app_name` to confirm.
- Verifies AWS authentication.
- Looks up the orchestrator from SSM, zips + uploads the working tree.
- Starts the orchestrator with `MODE=destroy`.
- Tails the build logs until done.
- On success, the orchestrator clears the SSM `app_owners/<app_name>` entry, freeing the name for re-claiming.

## What you (Claude) do

1. Reinforce with the user that this is irreversible and asks for explicit confirmation INSIDE the script (typed app name match).
2. Run `./scripts/destroy.sh`. Don't try to bypass the typed-confirm prompt — that's the safety gate.
3. **Don't summarize the script's output mid-run** — let it stream.
4. After exit:
   - **Success**: app is destroyed and name is free for re-registration. If the user wants to recreate later, they can edit `terraform.tfvars` (or re-run bootstrap on a fresh checkout) and `/initialize`.
   - **Partial failure** (some resources destroyed, some remain): the SSM owner entry is left in place. Re-running `/destroy` retries the remaining destroys — terraform destroy is idempotent.
