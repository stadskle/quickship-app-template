#!/usr/bin/env bash
#
# initialize.sh — set up or update this app's cloud resources via the
# platform orchestrator. Used both for first-time provisioning and for
# applying subsequent infra changes (tfvars edits).
#
# This is a guided, host-agnostic flow. The dev never has terraform-apply
# permissions; the orchestrator (a CodeBuild project at the platform level)
# does the apply on their behalf.
#
# Lifecycle:
#   - First run: full provisioning of Lambda, CloudFront, pipeline, etc.
#     Walks through git remote setup if missing.
#   - Subsequent runs: applies tfvars changes (capability flag toggles,
#     developer additions, secret_names changes). Quick, no remote dance.
#
# Run from the app's root directory (the one containing infra/).

set -euo pipefail

# ---- helpers ----------------------------------------------------------------

err() { echo "Error: $*" >&2; exit 1; }

confirm() {
  # Returns 0 (success) for yes, 1 for no
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
  case "$answer" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- config -----------------------------------------------------------------

# AWS profile baked in at scaffold time by bootstrap.sh.
AWS_PROFILE_NAME="__AWS_PROFILE__"

# ---- pre-flight -------------------------------------------------------------

[[ -d infra ]] || err "no infra/ directory — run from the app root."
[[ -f infra/terraform.tfvars ]] || err "no infra/terraform.tfvars."

APP_NAME=$(grep -E '^app_name\b' infra/terraform.tfvars | head -1 | cut -d'"' -f2)
[[ -n "$APP_NAME" ]] || err "could not parse app_name from infra/terraform.tfvars."

echo "→ App: $APP_NAME"
echo "→ AWS profile: $AWS_PROFILE_NAME"

# Verify AWS profile authenticates.
if ! aws --profile "$AWS_PROFILE_NAME" sts get-caller-identity >/dev/null 2>&1; then
  err "AWS profile '$AWS_PROFILE_NAME' isn't configured or credentials are expired.
       Run: aws configure --profile $AWS_PROFILE_NAME"
fi
echo "✓ AWS authenticated"

# ---- git remote -------------------------------------------------------------

# ---- gate on PRE-EXISTING uncommitted work ----------------------------------
#
# Default: refuse to deploy with the user's own uncommitted changes (audit /
# surprise protection). Override with `ALLOW_DIRTY=1 ./scripts/initialize.sh`.
# Note: this runs BEFORE the script's own tfvars edits, so its own changes
# don't trip this gate — they get auto-committed below.
if [[ -n "$(git status --porcelain)" ]] && [[ "${ALLOW_DIRTY:-0}" != "1" ]]; then
  cat <<EOF >&2

Error: uncommitted changes in your working tree:

$(git status --short)

The orchestrator deploys what's in your working tree (NOT your remote),
so uncommitted changes ship without an audit trail. Refusing to proceed
by default.

Either:
  - Commit (and push) your changes:
      git add -A && git commit -m "..." && git push
    Then re-run ./scripts/initialize.sh.
  - Or, if you really mean it (testing, can lose work):
      ALLOW_DIRTY=1 ./scripts/initialize.sh
EOF
  exit 1
fi

# ---- remote setup -----------------------------------------------------------

REMOTE_JUST_ADDED=false

if ! git remote get-url origin >/dev/null 2>&1; then
  cat <<EOF

This app needs a git remote before it can be deployed. The orchestrator
records 'app_name -> repo URL' so two repos can't claim the same name.

Steps:
  1. Create an EMPTY repository on your git host (GitHub, GitLab, Bitbucket,
     self-hosted — any host your platform admin set up). Don't initialize
     it with a README, LICENSE, or .gitignore — must be completely empty.

  2. Paste the URL below. Either form works:
       https://gitlab.com/your-org/your-app.git
       git@github.com:your-org/your-app.git

EOF
  while [[ -z "${repo_url_input:-}" ]]; do
    read -r -p "Repository URL: " repo_url_input
    # Strip trailing whitespace, '#' (Markdown-link copy artefact),
    # trailing slash, and surrounding quotes if any.
    repo_url_input=$(echo "$repo_url_input" | sed -E 's/[[:space:]#]+$//; s|/$||; s/^[\"'"'"']//; s/[\"'"'"']$//')
  done
  echo "→ Adding origin: $repo_url_input"
  git remote add origin "$repo_url_input"
  REMOTE_JUST_ADDED=true
fi

REPO_URL=$(git remote get-url origin)
echo "→ Repo: $REPO_URL"

# ---- update tfvars's git_repo if blank, auto-commit if changed --------------

CURRENT_GIT_REPO=$(grep -E '^git_repo\b' infra/terraform.tfvars | head -1 | cut -d'"' -f2 || echo "")

if [[ -z "$CURRENT_GIT_REPO" ]]; then
  # Strip protocol / git@ / .git suffix to derive owner/repo.
  parsed=$(echo "$REPO_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||; s|/$||')
  echo "→ Setting git_repo = \"$parsed\" in infra/terraform.tfvars"

  # Cross-platform sed -i (BSD on macOS, GNU on Linux).
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^git_repo *= *\".*\"|git_repo = \"$parsed\"|" infra/terraform.tfvars
  else
    sed -i "s|^git_repo *= *\".*\"|git_repo = \"$parsed\"|" infra/terraform.tfvars
  fi

  # Auto-commit the single tfvars change so the working tree stays clean
  # for the orchestrator. Avoids leaving the user with a "you're dirty
  # because the script edited a file" surprise.
  echo "→ Committing the tfvars update..."
  git add infra/terraform.tfvars
  git commit -q -m "init: set git_repo from origin URL"
fi

# ---- push (initial push if remote was just added; otherwise skip) -----------

if [[ "$REMOTE_JUST_ADDED" == "true" ]]; then
  echo "→ Pushing initial commit..."
  PUSH_OUTPUT=$(git push -u origin main 2>&1) || PUSH_FAILED=true

  if [[ -n "${PUSH_FAILED:-}" ]]; then
    echo "$PUSH_OUTPUT"
    echo

    if echo "$PUSH_OUTPUT" | grep -q 'rejected.*fetch first\|non-fast-forward'; then
      cat <<EOF
The remote already has commits — your repo wasn't created empty.
Most likely it was auto-initialized with a README / LICENSE / .gitignore.

To merge the existing commits and keep them:
    git pull origin main --allow-unrelated-histories --no-rebase --no-edit
    git push -u origin main
    ./scripts/initialize.sh

Or to overwrite (only if you don't care what's currently on the remote):
    git push -f -u origin main
    ./scripts/initialize.sh

EOF
    elif echo "$PUSH_OUTPUT" | grep -qiE '403|401|authentication|password'; then
      cat <<EOF
Auth failure. GitHub/GitLab require a Personal Access Token (not a
password) for HTTPS git operations. If you have an SSH key registered,
use the SSH form instead:
       git@github.com:owner/repo.git
       git@gitlab.com:owner/repo.git
    Retry: git remote remove origin && ./scripts/initialize.sh

EOF
    else
      cat <<EOF
Push failed for a reason I don't recognize. Possibilities:
  - Repo doesn't exist, or you don't have write access.
  - SSH key not configured for this host.
  - Network / firewall issue.
Read the output above and adjust. Then:
    git remote remove origin && ./scripts/initialize.sh

EOF
    fi
    exit 1
  fi
  echo "✓ Remote set up"
elif [[ -n "$(git log @{u}.. --oneline 2>/dev/null)" ]]; then
  # Remote exists but local is ahead — push the auto-commit (and any other
  # local commits) before deploying so remote is consistent with what the
  # orchestrator deploys.
  echo "→ Pushing local commits..."
  git push
fi

# ---- test branch (if test_environment_enabled) ------------------------------

# When the test env is on, the test pipeline will source from the 'test' git
# branch. Both pipelines exist after orchestrator's apply, but the test one
# fails its first run if the branch doesn't exist on the remote yet. Create
# it locally + push so the pipeline has a valid source.
TEST_ENV=$(grep -E '^test_environment_enabled\b' infra/terraform.tfvars | head -1 | cut -d'=' -f2 | tr -d ' "')
if [[ "$TEST_ENV" == "true" ]]; then
  if ! git rev-parse --verify --quiet refs/heads/test >/dev/null; then
    echo
    echo "→ Test environment is enabled. Creating 'test' branch from 'main'..."
    git branch test main
    git push -u origin test
    echo "✓ 'test' branch created and pushed."
  elif ! git ls-remote --exit-code --heads origin test >/dev/null 2>&1; then
    echo "→ Pushing local 'test' branch to remote..."
    git push -u origin test
  fi
fi

# ---- look up orchestrator ---------------------------------------------------

ssm_get() {
  aws --profile "$AWS_PROFILE_NAME" ssm get-parameter \
    --name "$1" --query Parameter.Value --output text 2>/dev/null
}

ORCHESTRATOR_PROJECT=$(ssm_get "/$AWS_PROFILE_NAME/_platform/orchestrator_project") \
  || err "couldn't read orchestrator handle from SSM. The platform may not be bootstrapped."
INPUT_BUCKET=$(ssm_get "/$AWS_PROFILE_NAME/_platform/orchestrator_input_bucket") \
  || err "couldn't read orchestrator input bucket."
LOG_GROUP=$(ssm_get "/$AWS_PROFILE_NAME/_platform/orchestrator_log_group") \
  || err "couldn't read orchestrator log group."

echo "✓ Orchestrator: $ORCHESTRATOR_PROJECT"

# ---- zip working tree -------------------------------------------------------

STAMP=$(date +%Y%m%d-%H%M%S)
ZIP_KEY="${APP_NAME}-${STAMP}.zip"
ZIP_PATH="/tmp/${ZIP_KEY}"

echo "→ Zipping working tree..."
zip -rq "$ZIP_PATH" . \
  -x '.git/*' 'node_modules/*' '.terraform/*' '*.tfstate*' \
     'frontend/dist/*' '__pycache__/*' '.venv/*' \
     '.idea/*' '.vscode/*' 'uploads/*' 'local.db*' \
     'scripts/*'
SIZE=$(du -h "$ZIP_PATH" | cut -f1)
echo "✓ Zipped ($SIZE)"

# ---- upload to S3 -----------------------------------------------------------

echo "→ Uploading to s3://${INPUT_BUCKET}/${ZIP_KEY}..."
aws --profile "$AWS_PROFILE_NAME" s3 cp "$ZIP_PATH" "s3://${INPUT_BUCKET}/${ZIP_KEY}" --quiet
rm "$ZIP_PATH"
echo "✓ Uploaded"

# ---- start build ------------------------------------------------------------

echo "→ Starting orchestrator..."
BUILD_ID=$(aws --profile "$AWS_PROFILE_NAME" codebuild start-build \
  --project-name "$ORCHESTRATOR_PROJECT" \
  --source-type-override S3 \
  --source-location-override "${INPUT_BUCKET}/${ZIP_KEY}" \
  --environment-variables-override \
    "name=MODE,value=apply" \
    "name=REPO_URL,value=$REPO_URL" \
  --query 'build.id' --output text)
echo "✓ Build started: $BUILD_ID"

# ---- tail logs --------------------------------------------------------------

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

# Poll status. CodeBuild's tail filter may not catch every line; we poll for
# terminal status separately.
while true; do
  STATUS=$(aws --profile "$AWS_PROFILE_NAME" codebuild batch-get-builds \
    --ids "$BUILD_ID" \
    --query 'builds[0].buildStatus' --output text 2>/dev/null || echo "UNKNOWN")
  case "$STATUS" in
    SUCCEEDED|FAILED|FAULT|TIMED_OUT|STOPPED)
      sleep 2  # let any final log lines stream
      cleanup
      echo
      echo "─────────────────────────────────────────────────────────"
      if [[ "$STATUS" == "SUCCEEDED" ]]; then
        echo "✓ Build $STATUS"
        echo
        echo "Infrastructure is ready. The app pipeline (CodePipeline) is now"
        echo "watching '$REPO_URL' for pushes."
        echo
        echo "Next: write some code, then 'git push' to deploy."
        echo "  - Each push triggers the pipeline → builds → updates Lambda."
        echo "  - First push after this also kicks off the initial code deploy."
        echo "  - Watch it: aws --profile $AWS_PROFILE_NAME codepipeline get-pipeline-state --name ${AWS_PROFILE_NAME}-${APP_NAME}"
        echo
        echo "When the pipeline is green, your app is live at the URL printed"
        echo "above (gated by Cloudflare Access using your allow-list)."
        if [[ "$TEST_ENV" == "true" ]]; then
          echo
          echo "Test environment is on:"
          echo "  - Switch to it locally: git checkout test"
          echo "  - Push to 'test' branch deploys to <app>-test.<apex>"
          echo "  - Push to 'main' deploys to prod (and re-applies infra)"
          echo "  - See CLAUDE.md \"Working with the test environment\" for the workflow."
        fi
        exit 0
      else
        echo "✗ Build $STATUS"
        echo "  See full logs: aws --profile $AWS_PROFILE_NAME logs tail $LOG_GROUP --since 30m"
        exit 1
      fi
      ;;
    *)
      sleep 5
      ;;
  esac
done
