---
description: Plan and apply the Terraform deploy in infra/
---

Deploy this app to the platform's AWS account.

## Pre-flight (do these in order, stop early on any failure)

0. **Run `/review` first** if there are app-code changes since the last deploy. Don't ship code that hasn't been through the security and platform review — the user is relying on this checkpoint.

1. **Check `infra/terraform.tfvars` for `git_repo`.** If it's empty (`git_repo = ""`), the pipeline is disabled. We want it set so CodePipeline gets created and the app deploys via CI on every push.

   - Run `git remote get-url origin 2>/dev/null` to see if a remote exists.
   - **If a remote URL is found**: parse out `owner/repo` from common forms:
     - `https://github.com/alice/hello-world.git` → `alice/hello-world`
     - `https://github.com/alice/hello-world` → `alice/hello-world`
     - `git@github.com:alice/hello-world.git` → `alice/hello-world`
     - `git@gitlab.com:alice/hello-world.git` → `alice/hello-world`
     Update `infra/terraform.tfvars` to set `git_repo = "<owner>/<repo>"`.
   - **If no remote exists** (the common case after a fresh `bootstrap.sh`): the user needs to create the destination repo. Ask them which host they want and offer the right command:
     - **GitHub**: `gh repo create <username>/<app-name> --source . --private --push`. If `gh` isn't authenticated, prompt them to run `gh auth login` first.
     - **GitLab / other**: have them create an empty repo via the host's web UI (no auto-init / README), then run `git remote add origin <url> && git push -u origin main`.
     Do not run repo-creation commands yourself unless the user explicitly says go — repo creation is publicly visible and their call to make. Once the remote is configured, re-derive `git_repo` from `git remote get-url origin` and update `terraform.tfvars`.

2. **Verify the AWS profile works**:
   `aws --profile tinyapp sts get-caller-identity`
   If this fails (Unable to locate credentials / ExpiredToken), point the user at the developer-onboarding section of CLAUDE.md ("AWS access for debugging") and stop. Don't try to deploy with broken credentials.

## Deploy

3. `cd infra`.

4. Run `terraform init` if `.terraform/` doesn't exist or providers look stale (use `-upgrade` if version pins changed). Otherwise skip.

5. Run `terraform plan -out=plan.tfplan` and show the user the diff.

6. Stop and ask the user to confirm before applying. **Never apply without explicit confirmation** — `terraform apply` is in the "ask" permission list for a reason; it changes real cloud resources.

7. After confirmation, run `terraform apply plan.tfplan` and show the final outputs.

## Post-apply

8. **First apply**: CloudFront takes ~5 minutes to propagate. Tell the user the URL from `terraform output app_url` won't respond until the distribution is `Deployed` — they can re-check in a few minutes.

9. **Pipeline first run**: when `git_repo` was just set, the pipeline was created but hasn't run. The CodeStarSourceConnection's "Detect changes" hook fires on the next push to `git_branch`. To kick it manually:
   `aws --profile tinyapp codepipeline start-pipeline-execution --name $(terraform output -raw function_name)`
   Watch progress: `terraform output -raw pipeline_console_url` (paste in browser).

10. **If the build fails** with `Repository not found`: the platform's CodeConnection isn't authorized for the repo's owner. Tell the user to go to the AWS Console → Developer Tools → Settings → Connections → click the platform connection → "Configure" the GitHub App and grant access to the repo's owner (their personal account or the org).

## Notes

- If `terraform plan` shows surprising destroys, **stop and explain** before suggesting apply.
- `terraform apply` is a guarded action — do not chain it after plan automatically. The whole point is to give the user a moment to review.
- `pipeline_enabled` on the module flips on automatically when `git_repo` is non-empty (set in `infra/main.tf`). No separate flag for the user to remember.
