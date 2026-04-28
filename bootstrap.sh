#!/usr/bin/env bash
#
# bootstrap.sh — one-time scaffolding step run after cloning this template.
#
#   gh repo create my-app --template <org>/quickship-app-template --clone
#   cd my-app
#   ./bootstrap.sh
#
# Prompts for app config, substitutes placeholders across files, deletes
# itself, runs `git init` + an initial commit. Designed to run once.

set -euo pipefail

# ---- prompts ---------------------------------------------------------------

default_app_name=$(basename "$PWD")
read -r -p "App name [${default_app_name}]: " app_name
app_name=${app_name:-$default_app_name}

if ! [[ "$app_name" =~ ^[a-z][a-z0-9-]{1,30}[a-z0-9]$ ]]; then
  echo "Error: app name must be 3-32 chars, lowercase letters/digits/hyphens, start with a letter, end alphanumeric." >&2
  exit 1
fi

# Derive AWS account ID from the configured profile (the developer onboarding
# done by the platform admin set this up). No prompting — this also doubles
# as a credentials sanity check.
aws_profile="${AWS_PROFILE:-quickship}"
aws_account_id=$(aws sts get-caller-identity --profile "$aws_profile" --query Account --output text 2>/dev/null || true)
if ! [[ "$aws_account_id" =~ ^[0-9]{12}$ ]]; then
  cat <<EOF >&2
Error: couldn't get the AWS account ID via the '$aws_profile' profile.

This usually means AWS credentials aren't set up yet on this machine.
See the "Set up AWS access" section in the template README — your
platform admin should have given you an access key and an ~/.aws/config
snippet. Once configured, this command should work:

    aws sts get-caller-identity --profile $aws_profile

Then re-run ./bootstrap.sh.
EOF
  exit 1
fi
echo "✓ AWS account: $aws_account_id (via profile '$aws_profile')"

# Region also derived from the configured profile — same source-of-truth as
# the account ID. `aws configure get region` reads ~/.aws/config for that
# profile (which the user set when they ran `aws configure --profile ...`).
aws_region=$(aws configure get region --profile "$aws_profile" 2>/dev/null || true)
if [[ -z "$aws_region" ]]; then
  echo "Error: profile '$aws_profile' has no region set. Run: aws configure set region <region> --profile $aws_profile" >&2
  exit 1
fi
echo "✓ AWS region:  $aws_region (via profile '$aws_profile')"

read -r -p "Platform repo (owner/repo) [your-org/quickship-platform]: " platform_repo
platform_repo=${platform_repo:-your-org/quickship-platform}

read -r -p "Platform module ref (tag or branch) [main]: " platform_version
platform_version=${platform_version:-main}

read -r -p "Allowed principals (comma-separated emails / *@domain) [*@${platform_repo%%/*}.com]: " allowed_principals_raw
allowed_principals_raw=${allowed_principals_raw:-*@${platform_repo%%/*}.com}

# JSON-encode the comma-separated list
allowed_principals_json=$(python3 -c "
import json, sys
items = [p.strip() for p in '''$allowed_principals_raw'''.split(',') if p.strip()]
print(json.dumps(items))
")

prompt_bool() {
  local prompt="$1" default="$2" answer
  read -r -p "${prompt} [${default}]: " answer
  answer=${answer:-$default}
  case "${answer,,}" in
    y|yes|true) echo "true" ;;
    *) echo "false" ;;
  esac
}

database_enabled=$(prompt_bool "Database (Postgres)? [y/n]" "y")
storage_enabled=$(prompt_bool "S3 storage? [y/n]" "n")
email_enabled=$(prompt_bool "SES email? [y/n]" "n")
ai_models_enabled=$(prompt_bool "Bedrock AI models? [y/n]" "n")

read -r -p "DynamoDB table names (comma-separated, blank for none): " dynamodb_tables_raw
dynamodb_tables_json=$(python3 -c "
import json, sys
items = [t.strip() for t in '''$dynamodb_tables_raw'''.split(',') if t.strip()]
print(json.dumps(items))
")

read -r -p "Developer names with access to this app (comma-separated, blank for none): " developers_raw
developers_json=$(python3 -c "
import json, sys
items = [d.strip() for d in '''$developers_raw'''.split(',') if d.strip()]
print(json.dumps(items))
")

# ---- substitutions ---------------------------------------------------------

# Cross-platform sed -i (macOS needs '' arg, GNU sed doesn't).
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

substitute() {
  local file="$1"
  sedi "s|__APP_NAME__|${app_name}|g" "$file"
  sedi "s|__AWS_ACCOUNT_ID__|${aws_account_id}|g" "$file"
  sedi "s|__AWS_REGION__|${aws_region}|g" "$file"
  sedi "s|__PLATFORM_REPO__|${platform_repo}|g" "$file"
  sedi "s|__PLATFORM_VERSION__|${platform_version}|g" "$file"
  sedi "s|__ALLOWED_PRINCIPALS__|${allowed_principals_json}|g" "$file"
  sedi "s|__DATABASE_ENABLED__|${database_enabled}|g" "$file"
  sedi "s|__STORAGE_ENABLED__|${storage_enabled}|g" "$file"
  sedi "s|__DYNAMODB_TABLES__|${dynamodb_tables_json}|g" "$file"
  sedi "s|__EMAIL_ENABLED__|${email_enabled}|g" "$file"
  sedi "s|__AI_MODELS_ENABLED__|${ai_models_enabled}|g" "$file"
  sedi "s|__DEVELOPERS__|${developers_json}|g" "$file"
}

# Files that contain placeholders.
files=(
  README.md
  CLAUDE.md
  docker-compose.yml
  backend/app/main.py
  frontend/index.html
  frontend/package.json
  frontend/src/App.tsx
  infra/main.tf
  infra/providers.tf
  infra/versions.tf
  infra/terraform.tfvars
)

for f in "${files[@]}"; do
  if [[ -f "$f" ]]; then
    substitute "$f"
  fi
done

# Strip <!-- TEMPLATE-ONLY:START --> ... <!-- TEMPLATE-ONLY:END --> blocks
# from the README. These hold the "how to bootstrap from the template"
# instructions that don't apply once the template has been bootstrapped.
if [[ -f README.md ]]; then
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path("README.md")
text = p.read_text()
text = re.sub(
    r"<!-- TEMPLATE-ONLY:START -->.*?<!-- TEMPLATE-ONLY:END -->\n*",
    "",
    text,
    flags=re.DOTALL,
)
p.write_text(text)
PY
fi

# ---- finalise --------------------------------------------------------------

# Self-destruct so the bootstrap step is one-time.
rm -- "$0"

# Fresh git history rooted at this template instantiation. The clone's
# .git (origin points at the template repo) is discarded — Claude
# guides the user to set their own remote on the first /deploy.
rm -rf .git
git init -q -b main
git add -A

if ! git commit -q -m "init: scaffold ${app_name} from quickship-app-template" 2>/dev/null; then
  cat <<EOF
⚠️  bootstrap could not commit (git is missing user identity).
Set it once, globally:
    git config --global user.name  "Your Name"
    git config --global user.email "you@example.com"
Then commit manually:
    git add -A
    git commit -m "init: scaffold ${app_name}"
EOF
fi

cat <<EOF

✅ Bootstrap complete.

Next steps:

1. Open this folder in Claude Code:
       claude .

2. Verify the scaffold runs locally (optional):
       docker compose up

3. When you're ready to ship, ask Claude "/deploy". It will walk you
   through creating your app's repo (GitHub or GitLab — whatever your
   platform admin set up), pushing the code, and running the first
   deploy. After that, every git push ships your app automatically.

EOF
