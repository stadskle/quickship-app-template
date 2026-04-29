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

# Platform prefix — this is also the AWS profile name (per convention).
# Default 'quickship' covers the canonical install. Platforms with a custom
# name_prefix on their bootstrap module set the matching value here.
read -r -p "Platform prefix [quickship]: " aws_profile
aws_profile=${aws_profile:-quickship}
if ! [[ "$aws_profile" =~ ^[a-z][a-z0-9-]{1,30}[a-z0-9]$ ]]; then
  echo "Error: platform prefix must be 3-32 chars, lowercase letters/digits/hyphens, start with a letter, end alphanumeric." >&2
  exit 1
fi

# Validate the AWS profile of that name actually authenticates.
aws_account_id=$(aws sts get-caller-identity --profile "$aws_profile" --query Account --output text 2>/dev/null || true)
if ! [[ "$aws_account_id" =~ ^[0-9]{12}$ ]]; then
  cat <<EOF >&2
Error: couldn't authenticate via the '$aws_profile' profile.

Set up the profile if you haven't:
    aws configure --profile $aws_profile
…and paste the access key + secret your platform admin sent.

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

# Platform source URL — published to SSM by bootstrap module. No prompt;
# every app under this platform points at the same modules repo.
platform_source=$(aws ssm get-parameter --profile "$aws_profile" --region "$aws_region" \
  --name "/$aws_profile/_platform/source" \
  --query Parameter.Value --output text 2>/dev/null || true)
if [[ -z "$platform_source" ]]; then
  cat <<EOF >&2
Error: couldn't read /$aws_profile/_platform/source from SSM.

The platform doesn't appear to be bootstrapped yet (or the bootstrap module
needs an apply to publish this fact). Ask your platform admin to run
'terraform apply' on the bootstrap module with platform_source set.
EOF
  exit 1
fi
echo "✓ Platform source: $platform_source (via SSM)"


# Auto-detect this developer's name from the IAM user ARN. The convention
# is <prefix>-developer-<name>; if the caller matches, pre-populate the
# developers list. Otherwise leave empty (the user can add manually later).
caller_arn=$(aws sts get-caller-identity --profile "$aws_profile" --query Arn --output text 2>/dev/null || true)
caller_user=${caller_arn##*/}  # strip everything before last '/'
if [[ "$caller_user" == "$aws_profile-developer-"* ]]; then
  developer_name=${caller_user#"$aws_profile-developer-"}
  developers_json=$(printf '["%s"]' "$developer_name")
  echo "✓ Developer: $developer_name (auto-detected from IAM user)"
else
  developers_json="[]"
  echo "  (No developer auto-detected. Add names to 'developers' in infra/terraform.tfvars later.)"
fi

echo
echo "Who can access this app? Comma-separated list. Each entry is either:"
echo "  - a single email address  (e.g.  alice@example.com)"
echo "  - everyone at a domain    (e.g.  *@example.com)"
while true; do
  read -r -p "Allowed users: " allowed_principals_raw
  [[ -n "$allowed_principals_raw" ]] && break
  echo "  At least one entry is required."
done

# JSON-encode the comma-separated list
allowed_principals_json=$(python3 -c "
import json, sys
items = [p.strip() for p in '''$allowed_principals_raw'''.split(',') if p.strip()]
print(json.dumps(items))
")

# Capabilities default off — Claude turns them on as it learns what the app
# actually needs (see CLAUDE.md "Enabling capabilities"). No prompts here:
# the user typing bootstrap.sh hasn't talked to Claude yet and shouldn't
# have to predict their app's needs upfront.
database_enabled="false"
storage_enabled="false"
email_enabled="false"
ai_models_enabled="false"
dynamodb_tables_json="[]"

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
  sedi "s|__AWS_PROFILE__|${aws_profile}|g" "$file"
  sedi "s|__PLATFORM_SOURCE__|${platform_source}|g" "$file"
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
  .claude/commands/deploy.md
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
