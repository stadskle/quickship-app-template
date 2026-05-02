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
# Two lists: files copied as-is (no substitution) and files where placeholders
# need substituting from the local app config. Bias toward NOT adding —
# anything app-Claude or the developer might reasonably edit should stay out.
#
# Why two lists: this script runs `sed s/__APP_NAME__/<name>/` on every file in
# the SUBSTITUTE list. If we run that on this very script (which contains
# `__APP_NAME__` as a literal sed pattern below), the script's substitution
# function self-corrupts on the first --apply run. Same risk for any file
# that doesn't actually use the placeholders.

# Copied verbatim from template — no placeholders, no substitution.
PLATFORM_FILES_VERBATIM=(
  scripts/upgrade.sh
  .claude/agents/quickship-reviewer.md
  .claude/commands/local.md
  .claude/commands/migrate.md
  .claude/commands/review.md
  .claude/commands/route.md
)

# Has __APP_NAME__ / __AWS_PROFILE__ / __AWS_REGION__ placeholders that need
# the local app's values substituted in.
PLATFORM_FILES_SUBSTITUTE=(
  scripts/initialize.sh
  scripts/destroy.sh
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

# Self-update FIRST, via atomic mv (not cp). `cp` overwrites the running
# script's inode in place, which corrupts bash's chunked-file reads
# mid-run. `mv` swaps the inode atomically; bash keeps reading from the
# old inode it already opened (POSIX guarantees), and the new script is
# on disk for next invocation. Doing this first means the new version is
# in place immediately even if the rest of the run fails.
SELF_SRC="$TMP/tmpl/scripts/upgrade.sh"
if [[ -f "$SELF_SRC" ]] && ! diff -q scripts/upgrade.sh "$SELF_SRC" >/dev/null 2>&1; then
  echo "  ~ scripts/upgrade.sh"
  CHANGED+=("scripts/upgrade.sh")
  SELF_CHANGED=1
  if [[ "$mode" == "apply" ]]; then
    cp "$SELF_SRC" scripts/upgrade.sh.new
    chmod +x scripts/upgrade.sh.new
    mv scripts/upgrade.sh.new scripts/upgrade.sh
  else
    diff -u scripts/upgrade.sh "$SELF_SRC" | sed -n '1,30p'
    echo
  fi
fi

process_file() {
  local f="$1"
  local apply_subst="$2"   # "true" / "false"
  [[ "$f" == "scripts/upgrade.sh" ]] && return 0   # handled above
  local src="$TMP/tmpl/$f"
  [[ -f "$src" ]] || return 0   # template doesn't ship this file

  local scratch="$TMP/proc/$f"
  mkdir -p "$(dirname "$scratch")"
  cp "$src" "$scratch"
  if [[ "$apply_subst" == "true" ]]; then
    substitute_in "$scratch"
  fi

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
    if [[ "$mode" == "apply" ]]; then
      cp "$scratch" "$f"
      [[ "$f" == scripts/* ]] && chmod +x "$f"
    else
      diff -u "$f" "$scratch" | sed -n '1,30p'
      echo
    fi
  fi
}

for f in "${PLATFORM_FILES_VERBATIM[@]}";   do process_file "$f" "false"; done
for f in "${PLATFORM_FILES_SUBSTITUTE[@]}"; do process_file "$f" "true";  done

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
