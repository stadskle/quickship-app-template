---
description: Permanently destroy this app's AWS resources via the orchestrator
---

Tear down everything `/deploy` created for this app: Lambda function, CloudFront distribution, ACM cert, Cloudflare Access app, DNS record, Neon role + database (and all data), S3 bucket (and all objects), DynamoDB tables (and all rows), pipeline, IAM roles. **Irreversible. Data is gone.**

This invokes the platform orchestrator in destroy mode. The dev's IAM user does not have terraform-destroy permissions directly; the orchestrator (admin-permissioned) does it on their behalf.

## When to use

- The app is genuinely no longer wanted and the data should be deleted.
- You want to free up the `app_name` for a different repo to claim.
- You need to recover from a stuck Terraform state and start fresh.

**Don't use** `/destroy` to:
- "Pause" the app — instead, set the developers list to empty (revokes access without destroying data).
- Save costs — the platform's running cost is tiny; deleting and recreating is more expensive in time than the savings.

## The flow

0. **Confirm with the user — strongly**. The dev probably typed `/destroy` casually; treat this with the seriousness of `terraform destroy` against production. Show:
   ```
   ⚠ This will PERMANENTLY destroy quickship-<app_name> and all its data:
     - Lambda function quickship-<app_name>
     - CloudFront distribution
     - Postgres database (if database_enabled)
     - S3 storage bucket and contents (if storage_enabled)
     - DynamoDB tables and contents (if any)
     - IAM roles, secrets, log groups, the pipeline

   This cannot be undone. Cloud-side data is gone for good.

   Type the app name (<app_name>) to confirm:
   ```
   Wait for input. If it doesn't exactly match the app_name from `infra/terraform.tfvars`, abort with "input did not match — destroy cancelled" and stop.

1. **Verify AWS profile**:
   ```bash
   aws --profile __AWS_PROFILE__ sts get-caller-identity
   ```

2. **Look up orchestrator handles** (same as `/deploy` step 4):
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

3. **Zip + upload + start-build with MODE=destroy**:
   ```bash
   APP_NAME=$(grep -E '^app_name\b' infra/terraform.tfvars | head -1 | cut -d'"' -f2)
   STAMP=$(date +%Y%m%d-%H%M%S)
   ZIP_KEY="${APP_NAME}-destroy-${STAMP}.zip"
   zip -rq /tmp/${ZIP_KEY} . -x '.git/*' 'node_modules/*' '.terraform/*' '*.tfstate*' 'frontend/dist/*' '__pycache__/*' '.venv/*' '.idea/*' '.vscode/*' 'uploads/*' 'local.db*'
   aws --profile __AWS_PROFILE__ s3 cp /tmp/${ZIP_KEY} s3://${INPUT_BUCKET}/${ZIP_KEY}
   rm /tmp/${ZIP_KEY}

   REPO_URL=$(git remote get-url origin)
   BUILD_ID=$(aws --profile __AWS_PROFILE__ codebuild start-build \
     --project-name $ORCHESTRATOR_PROJECT \
     --source-type-override S3 \
     --source-location-override "${INPUT_BUCKET}/${ZIP_KEY}" \
     --environment-variables-override \
       name=MODE,value=destroy \
       name=REPO_URL,value="$REPO_URL" \
     --query 'build.id' --output text)
   ```

4. **Tail logs until the build finishes** (same loop as `/deploy` step 7).

5. **On success**: the orchestrator removes the SSM `app_owners/<app_name>` entry, freeing the name. Tell the user:
   - "App `<app_name>` is destroyed. The name is now available for re-registration."
   - "If you want to recreate the app, you can re-run `bootstrap.sh` (in a fresh checkout) or just edit `infra/terraform.tfvars` here and `/deploy` again. Same name OK."

6. **On partial failure** (orchestrator destroyed some but not all resources): the SSM owner entry is NOT cleared. You can `/destroy` again to retry — Terraform's destroy is idempotent and will only target what's still in state.

## Edge cases

- **`app_name` no longer matches a registered owner**: the orchestrator's destroy still runs; nothing in the registry to clean up. Harmless.
- **Stuck destroy** (resource AWS won't delete, e.g., S3 bucket with objects): orchestrator's `terraform destroy` will error out. Fix manually — usually `aws s3 rm s3://... --recursive` to empty a bucket — then re-run `/destroy`. The platform admin may need to assist.
- **Renaming an app** isn't supported; this is the data-loss path. If you need to keep the data, ask the platform admin about state migration.
