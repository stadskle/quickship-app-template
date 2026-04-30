---
description: Apply this app's infra changes via the platform orchestrator
---

Deploy this app to the platform's AWS account by invoking the platform orchestrator. The dev's IAM user does not have terraform-apply permissions — the orchestrator (a single shared CodeBuild project at the platform level) does. We zip the app, upload it, kick off a build, tail the logs.

## When to use this

- **You changed something in `infra/`** (capability flag, secret name, developer list, etc.) → run `/deploy`.
- **You only changed code** (routes, migrations, frontend) → just `git push`. The per-app pipeline picks it up automatically. `/deploy` not needed.
- **First time setting up the app** (no resources exist yet) → run `/deploy`. This creates the Lambda, CloudFront, the per-app pipeline, etc. After that, code changes flow via push.

## Pre-flight (stop early on any failure)

0. **Run `/review` first** if there are app or infra changes since the last deploy. The reviewer flags both code-side issues (IDOR, SQL injection, etc.) and infra-side issues (`database_enabled: true → false` will destroy data, etc.). Don't bypass.

1. **Verify the AWS profile works**:
   ```bash
   aws --profile __AWS_PROFILE__ sts get-caller-identity
   ```
   If this fails, point the user at CLAUDE.md "AWS access for debugging" and stop.

2. **Verify a git remote exists** (so the orchestrator can record ownership). If `git remote get-url origin` errors, ask the user to create the destination repo:
   - **GitHub**: `gh repo create <username>/<app-name> --source . --private --push` (prompt for `gh auth login` if needed).
   - **GitLab / other**: have them create an empty repo via the host's web UI (no auto-init/README), then `git remote add origin <url> && git push -u origin main`.
   Don't run repo-creation commands yourself unless the user explicitly says go.

3. **Verify everything is committed and pushed**. The orchestrator will deploy what's *currently in your working tree* (not what's in the remote — but having an out-of-sync remote is confusing and breaks the audit trail). Run `git status` and `git log origin/$(git branch --show-current)..HEAD` and warn the user if they have unpushed/uncommitted work.

## Deploy

4. **Look up the orchestrator handles** (one-time-per-session, can be cached):
   ```bash
   ORCHESTRATOR_PROJECT=$(aws --profile __AWS_PROFILE__ ssm get-parameter \
     --name /__AWS_PROFILE__/_platform/orchestrator_project \
     --query Parameter.Value --output text)
   INPUT_BUCKET=$(aws --profile __AWS_PROFILE__ ssm get-parameter \
     --name /__AWS_PROFILE__/_platform/orchestrator_input_bucket \
     --query Parameter.Value --output text)
   LOG_GROUP=$(aws --profile __AWS_PROFILE__ ssm get-parameter \
     --name /__AWS_PROFILE__/_platform/orchestrator_log_group \
     --query Parameter.Value --output text)
   ```

5. **Zip the working tree and upload**:
   ```bash
   APP_NAME=$(grep -E '^app_name\b' infra/terraform.tfvars | head -1 | cut -d'"' -f2)
   STAMP=$(date +%Y%m%d-%H%M%S)
   ZIP_KEY="${APP_NAME}-${STAMP}.zip"
   zip -rq /tmp/${ZIP_KEY} . -x '.git/*' 'node_modules/*' '.terraform/*' '*.tfstate*' 'frontend/dist/*' '__pycache__/*' '.venv/*' '.idea/*' '.vscode/*' 'uploads/*' 'local.db*'
   aws --profile __AWS_PROFILE__ s3 cp /tmp/${ZIP_KEY} s3://${INPUT_BUCKET}/${ZIP_KEY}
   rm /tmp/${ZIP_KEY}
   ```

6. **Start the build**:
   ```bash
   REPO_URL=$(git remote get-url origin)
   BUILD_ID=$(aws --profile __AWS_PROFILE__ codebuild start-build \
     --project-name $ORCHESTRATOR_PROJECT \
     --source-type-override S3 \
     --source-location-override "${INPUT_BUCKET}/${ZIP_KEY}" \
     --environment-variables-override \
       name=MODE,value=apply \
       name=REPO_URL,value="$REPO_URL" \
     --query 'build.id' --output text)
   echo "Started build: $BUILD_ID"
   ```

7. **Tail the logs until the build finishes**:
   ```bash
   aws --profile __AWS_PROFILE__ logs tail $LOG_GROUP --follow --format short \
     --filter-pattern "{ $.codebuild_build_id = \"${BUILD_ID}\" }" &
   TAIL_PID=$!
   while true; do
     STATUS=$(aws --profile __AWS_PROFILE__ codebuild batch-get-builds --ids $BUILD_ID --query 'builds[0].buildStatus' --output text)
     case "$STATUS" in
       SUCCEEDED|FAILED|FAULT|TIMED_OUT|STOPPED) kill $TAIL_PID 2>/dev/null; echo "Build $STATUS"; break ;;
       *) sleep 5 ;;
     esac
   done
   ```
   (If the user prefers, link them to the AWS console URL for the build instead — but they may not have console access.)

## Post-deploy

8. **First-app deploy**: CloudFront takes ~5 minutes to propagate. The app URL won't respond until the distribution is "Deployed". The build itself returns earlier; the wait is on AWS side.

9. **Subsequent code changes** flow via `git push` (per-app pipeline picks it up). Only re-run `/deploy` for `infra/` changes.

## Failure modes

| Build error | Likely cause |
|---|---|
| `app_name 'X' is already owned by repo Y` | Someone else (or you, in a different repo) already claimed that name. Pick a different `app_name` in `infra/terraform.tfvars`, or `/destroy` the existing app first. |
| Terraform error during apply | Read the orchestrator log output — same errors as `terraform apply` locally. Fix the TF and re-run `/deploy`. |
| `AccessDenied` on `start-build` | The dev's IAM user is missing `codebuild:StartBuild` on the orchestrator. Should be auto-granted; if missing, the platform admin needs to re-apply the developer module. |

## Notes

- The orchestrator deploys whatever is in your **working tree**, not your git remote. Commit + push first as a discipline.
- The orchestrator is a single principal with admin-ish AWS perms. Anyone with `codebuild:StartBuild` on it can deploy any app whose source they upload — but the app-name registry prevents cross-app interference.
- For destroying an app entirely, see `/destroy`.
