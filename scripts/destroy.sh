#!/usr/bin/env bash
#
# destroy.sh — permanently destroy this app's cloud resources via the
# platform orchestrator. IRREVERSIBLE: data in the per-app DB, S3 bucket,
# DynamoDB tables is gone for good.
#
# Strong confirmation: dev must type the exact app_name to proceed.
# After successful destroy, the orchestrator clears the SSM ownership
# entry, freeing the app_name for re-claiming.
#
# Run from the app's root directory.

set -euo pipefail

err() { echo "Error: $*" >&2; exit 1; }

AWS_PROFILE_NAME="__AWS_PROFILE__"

[[ -d infra ]] || err "no infra/ directory — run from the app root."

APP_NAME=$(grep -E '^app_name\b' infra/terraform.tfvars | head -1 | cut -d'"' -f2)
[[ -n "$APP_NAME" ]] || err "could not parse app_name from infra/terraform.tfvars."

cat <<EOF

⚠  PERMANENT DESTROY ⚠

This will tear down all cloud resources for: $APP_NAME

  - Lambda function
  - CloudFront distribution
  - ACM certificate
  - Cloudflare Access app + DNS record
  - Per-app pipeline + CodeBuild
  - IAM roles and policies
  - Postgres database (if database_enabled)  ← all data lost
  - S3 storage bucket and contents (if storage_enabled)  ← all files lost
  - DynamoDB tables and rows (if any)  ← all rows lost
  - SSM secrets

This cannot be undone. Cloud-side data is gone for good.

EOF

read -r -p "Type the app name ($APP_NAME) to confirm: " confirmation
if [[ "$confirmation" != "$APP_NAME" ]]; then
  echo "Input did not match. Destroy cancelled."
  exit 1
fi

# Verify AWS profile.
if ! aws --profile "$AWS_PROFILE_NAME" sts get-caller-identity >/dev/null 2>&1; then
  err "AWS profile '$AWS_PROFILE_NAME' isn't configured."
fi

# Look up orchestrator handles.
ssm_get() {
  aws --profile "$AWS_PROFILE_NAME" ssm get-parameter \
    --name "$1" --query Parameter.Value --output text 2>/dev/null
}

ORCHESTRATOR_PROJECT=$(ssm_get "/$AWS_PROFILE_NAME/_platform/orchestrator_project") \
  || err "couldn't read orchestrator handle from SSM."
INPUT_BUCKET=$(ssm_get "/$AWS_PROFILE_NAME/_platform/orchestrator_input_bucket") \
  || err "couldn't read orchestrator input bucket."
LOG_GROUP=$(ssm_get "/$AWS_PROFILE_NAME/_platform/orchestrator_log_group") \
  || err "couldn't read orchestrator log group."

# Get repo URL (for logging — orchestrator's destroy doesn't strictly need
# it, but the buildspec expects REPO_URL env var to be set).
REPO_URL=$(git remote get-url origin 2>/dev/null || echo "unknown")

# Zip working tree (for the infra/ that terraform-destroy needs).
STAMP=$(date +%Y%m%d-%H%M%S)
ZIP_KEY="${APP_NAME}-destroy-${STAMP}.zip"
ZIP_PATH="/tmp/${ZIP_KEY}"

echo "→ Zipping working tree..."
zip -rq "$ZIP_PATH" . \
  -x '.git/*' 'node_modules/*' '.terraform/*' '*.tfstate*' \
     'frontend/dist/*' '__pycache__/*' '.venv/*' \
     '.idea/*' '.vscode/*' 'uploads/*' 'local.db*' \
     'scripts/*'

echo "→ Uploading..."
aws --profile "$AWS_PROFILE_NAME" s3 cp "$ZIP_PATH" "s3://${INPUT_BUCKET}/${ZIP_KEY}" --quiet
rm "$ZIP_PATH"

echo "→ Starting orchestrator (destroy mode)..."
BUILD_ID=$(aws --profile "$AWS_PROFILE_NAME" codebuild start-build \
  --project-name "$ORCHESTRATOR_PROJECT" \
  --source-type-override S3 \
  --source-location-override "${INPUT_BUCKET}/${ZIP_KEY}" \
  --environment-variables-override \
    "name=MODE,value=destroy" \
    "name=REPO_URL,value=$REPO_URL" \
  --query 'build.id' --output text)
echo "✓ Build started: $BUILD_ID"

echo
echo "Streaming orchestrator logs..."
echo "─────────────────────────────────────────────────────────"

aws --profile "$AWS_PROFILE_NAME" logs tail "$LOG_GROUP" \
  --follow --format short \
  --filter-pattern "{ \$.codebuild_build_id = \"${BUILD_ID}\" }" &
TAIL_PID=$!

cleanup() {
  kill "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while true; do
  STATUS=$(aws --profile "$AWS_PROFILE_NAME" codebuild batch-get-builds \
    --ids "$BUILD_ID" \
    --query 'builds[0].buildStatus' --output text 2>/dev/null || echo "UNKNOWN")
  case "$STATUS" in
    SUCCEEDED|FAILED|FAULT|TIMED_OUT|STOPPED)
      sleep 2
      cleanup
      echo
      echo "─────────────────────────────────────────────────────────"
      if [[ "$STATUS" == "SUCCEEDED" ]]; then
        echo "✓ App '$APP_NAME' destroyed. The name is now available for re-registration."
        exit 0
      else
        echo "✗ Destroy $STATUS"
        echo "  Some resources may have been destroyed; some may remain."
        echo "  Re-run /destroy to retry — terraform destroy is idempotent."
        echo "  Full logs: aws --profile $AWS_PROFILE_NAME logs tail $LOG_GROUP --since 30m"
        exit 1
      fi
      ;;
    *)
      sleep 5
      ;;
  esac
done
