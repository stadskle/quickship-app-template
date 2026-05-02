#!/usr/bin/env bash
#
# scripts/upgrade.sh — sync platform-owned files from template@main into this
# app. Run when the platform announces an update to Claude's instructions
# (CLAUDE.md, agents, commands) or to the bootstrap-flow scripts.
#
#   ./scripts/upgrade.sh             # dry-run, shows diff
#   ./scripts/upgrade.sh --apply     # overwrites; review with `git diff`
#   ./scripts/upgrade.sh --ref v0.4  # pin to a specific git ref / tag
#
# Never touches app code, infra config, or dependency files. Manifest at the
# top spells out exactly which paths are platform-owned. App-owned files
# (infra/, backend/app/main.py, backend/app/routes/, frontend/src/App.tsx,
# requirements.txt, package.json, etc.) are NEVER overwritten.
#
# After --apply, this script does NOT auto-commit. Review with `git diff`,
# stage selectively if you've customised any of the synced files, commit,
# push.

set -euo pipefail

TEMPLATE_REPO="https://github.com/stadskle/quickship-app-template.git"
TEMPLATE_REF="${UPGRADE_REF:-main}"

# ---- manifest -----------------------------------------------------------
#
# Add to this list when the platform decides another file is platform-owned
# enough to sync. Bias toward NOT adding — anything app-Claude or the
# developer might reasonably edit should stay out.

PLATFORM_FILES=(
  scripts/upgrade.sh
  scripts/initialize.sh
  scripts/destroy.sh
  .claude/agents/quickship-reviewer.md
  .claude/commands/local.md
  .claude/commands/migrate.md
  .claude/commands/review.md
  .claude/commands/route.md
)

# ---- args ---------------------------------------------------------------

mode="diff"
while (( $# )); do
  case "$1" in
    --apply) mode="apply"; shift ;;
    --diff)  mode="diff";  shift ;;
    --ref)   TEMPLATE_REF="${2:?--ref needs a value}"; shift 2 ;;
    -h|--help|*)
      cat >&2 <<EOF
Usage: $0 [--diff (default) | --apply] [--ref <git-ref>]

Sync platform-owned files from $TEMPLATE_REPO@<ref>.
EOF
      exit 1 ;;
  esac
done

# ---- locate repo + read app config --------------------------------------

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Error: not inside a git repo." >&2; exit 1;
}
cd "$REPO_ROOT"

[[ -f infra/terraform.tfvars ]] || {
  echo "Error: this doesn't look like a quickship app (no infra/terraform.tfvars)." >&2
  exit 1
}

read_tfvar() { grep -E "^$1\b" infra/terraform.tfvars | head -1 | cut -d'"' -f2; }

APP_NAME=$(read_tfvar app_name)
AWS_PROFILE=$(read_tfvar aws_profile)
AWS_REGION=$(read_tfvar aws_region)
[[ -n "$APP_NAME" && -n "$AWS_PROFILE" ]] || {
  echo "Error: couldn't read app_name / aws_profile from infra/terraform.tfvars." >&2
  exit 1
}

# ---- fetch template -----------------------------------------------------

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
echo "→ Fetching ${TEMPLATE_REPO}@${TEMPLATE_REF}..."
git clone --quiet --depth 1 --branch "$TEMPLATE_REF" "$TEMPLATE_REPO" "$TMP/tmpl"

# ---- substitution helper -------------------------------------------------
#
# Platform-owned files use only these three placeholders. App-config
# placeholders (allowed_principals, capability flags, account_id, …) live
# in app-owned files and aren't touched here.

sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then sed -i '' "$@"; else sed -i "$@"; fi
}

substitute_in() {
  sedi "s|__APP_NAME__|${APP_NAME}|g" "$1"
  sedi "s|__AWS_PROFILE__|${AWS_PROFILE}|g" "$1"
  sedi "s|__AWS_REGION__|${AWS_REGION}|g" "$1"
}

# ---- compare and (optionally) copy --------------------------------------

CHANGED=()
SELF_CHANGED=0

for f in "${PLATFORM_FILES[@]}"; do
  src="$TMP/tmpl/$f"
  [[ -f "$src" ]] || continue   # template doesn't ship this file

  scratch="$TMP/proc/$f"
  mkdir -p "$(dirname "$scratch")"
  cp "$src" "$scratch"
  substitute_in "$scratch"

  if [[ ! -f "$f" ]]; then
    echo "  + $f (new)"
    CHANGED+=("$f")
    if [[ "$mode" == "apply" ]]; then
      mkdir -p "$(dirname "$f")"
      cp "$scratch" "$f"
      [[ "$f" == scripts/* ]] && chmod +x "$f"
    fi
  elif ! diff -q "$f" "$scratch" >/dev/null 2>&1; then
    echo "  ~ $f"
    CHANGED+=("$f")
    [[ "$f" == "scripts/upgrade.sh" ]] && SELF_CHANGED=1
    if [[ "$mode" == "apply" ]]; then
      cp "$scratch" "$f"
      [[ "$f" == scripts/* ]] && chmod +x "$f"
    else
      diff -u "$f" "$scratch" | sed -n '1,30p'
      echo
    fi
  fi
done

# ---- summary -------------------------------------------------------------

echo
if [[ ${#CHANGED[@]} -eq 0 ]]; then
  echo "✓ Already in sync with template@${TEMPLATE_REF}."
  exit 0
fi

if [[ "$mode" == "apply" ]]; then
  echo "✓ Updated ${#CHANGED[@]} file(s)."
  echo
  echo "Next: review and commit."
  echo "  git diff"
  echo "  git add -p              # selectively stage if you've customised any"
  echo "  git commit -m 'platform upgrade'"
  echo "  git push"
  if (( SELF_CHANGED )); then
    echo
    echo "Note: scripts/upgrade.sh itself was updated — the new version takes"
    echo "effect on the next invocation."
  fi
else
  echo "${#CHANGED[@]} file(s) differ from template@${TEMPLATE_REF}."
  echo "Re-run with --apply to overwrite. (Dry run; no files modified.)"
fi
