---
description: Set up or update this app's cloud resources (first-time provisioning + occasional infra changes)
---

Run `./scripts/initialize.sh` and stream the output to the user.

The script handles the entire flow:
- Verifies the AWS profile authenticates.
- Walks the user through git-remote setup if `origin` isn't configured (host-agnostic — GitHub, GitLab, Bitbucket, self-hosted, anything).
- Pushes the initial commit if needed.
- Auto-fills `git_repo` in `infra/terraform.tfvars` from the remote URL.
- Warns if the working tree has uncommitted changes (the orchestrator deploys what's in your tree, not what's in the remote).
- Looks up the orchestrator's CodeBuild project from SSM.
- Zips the working tree, uploads it, starts a build with `MODE=apply`.
- Tails the build logs until the build resolves.

## When this is called

- **First-time setup of an app**: provisions Lambda, CloudFront, the per-app pipeline, IAM, ACM cert, Cloudflare Access, etc. ~10 min.
- **Subsequent infra changes**: when `terraform.tfvars` was edited (capability flag toggled, secret_names updated, developers added). Quick.
- **Not** for code changes — those flow via `git push` to the per-app pipeline. `/initialize` is only for infrastructure config.

## What you (Claude) do

1. Confirm with the user that they want to proceed (especially for first-time runs — explain what will happen).
2. Run `./scripts/initialize.sh`. The script is interactive (prompts for repo URL if needed, asks confirmation on uncommitted changes).
3. **Don't** wrap the script's output in summarization mid-run — the user wants to see live progress.
4. After the script exits:
   - **Success**: tell the user the build succeeded. If this was the first deploy, mention CloudFront takes ~5 min to propagate before the app URL responds.
   - **Failure**: read the orchestrator's log output (the script printed it). Help the user diagnose. Common issues:
     - `app_name 'X' is already owned by repo Y` → another repo claimed the same name. Pick a different `app_name` in `terraform.tfvars`, or `/destroy` the existing app first.
     - Terraform error during apply → same errors as `terraform apply` locally; fix the TF and re-run `/initialize`.
     - `AccessDenied` on a specific action → the orchestrator's IAM is missing that permission. Surface the action name; this is a platform-side fix.

## Gating

Run `/review` first if there are any uncommitted changes to `infra/terraform.tfvars`, `infra/main.tf`, migrations, or app code. The reviewer flags destructive infra changes (capability disables, app_name changes, etc.) before they hit the orchestrator.
