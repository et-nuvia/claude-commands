#!/bin/bash
# =============================================================================
# ECR Helper Library
# =============================================================================
# Shared functions for ECR image and tag management.
# Supports single-repo (e.g., intake-form) and multi-repo (e.g., n1-consult)
# projects via common.sh config.
#
# Tag Rotation Scheme:
#   Staging:    staging, staging-previous-1 through staging-previous-4
#   Production: production, production-previous-1 through production-previous-4
#
# Single-repo usage (backward-compatible):
#   ecr_rotate_staging_tags "staging-abc1234"
#
# Multi-repo usage:
#   ecr_rotate_tags_all staging "staging-abc1234"
#   ecr_promote_all "staging-abc1234"
# =============================================================================

# Source common config if not already loaded
SCRIPT_DIR_ECR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${_COMMON_SH_LOADED:-}" != "true" ]] && [[ -f "$SCRIPT_DIR_ECR/common.sh" ]]; then
  source "$SCRIPT_DIR_ECR/common.sh"
fi

# Defaults — use common.sh values or env vars
ECR_REGION="${ECR_REGION:-${REGION:-us-west-1}}"
ECR_PROJECT="${ECR_PROJECT:-}"  # Set from ECR_REPOS if single-repo, or per-function
PRODUCTION_KEEP_COUNT="${PRODUCTION_KEEP_COUNT:-4}"
STAGING_KEEP_COUNT="${STAGING_KEEP_COUNT:-4}"

# If ECR_REPOS has exactly one repo and ECR_PROJECT isn't set, use it as default
if [[ -z "$ECR_PROJECT" ]] && [[ -n "${ECR_REPOS:-}" ]]; then
  local_count=$(echo "$ECR_REPOS" | wc -w | tr -d ' ')
  if [[ "$local_count" -eq 1 ]]; then
    ECR_PROJECT="$ECR_REPOS"
  fi
fi

# =============================================================================
# Per-repo functions — accept optional $repo parameter (defaults to ECR_PROJECT)
# =============================================================================

# =============================================================================
# ecr_get_manifest - Get image manifest for a tag
# =============================================================================
# Arguments:
#   $1 - Tag name
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_get_manifest() {
  local tag="$1"
  local repo="${2:-$ECR_PROJECT}"

  aws ecr batch-get-image \
    --repository-name "${repo}" \
    --region "${ECR_REGION}" \
    --image-ids imageTag="${tag}" \
    --query 'images[].imageManifest' \
    --output text 2>/dev/null || echo ""
}

# =============================================================================
# ecr_put_tag - Add a tag to an existing image
# =============================================================================
# Arguments:
#   $1 - Image manifest
#   $2 - New tag name
#   $3 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_put_tag() {
  local manifest="$1"
  local new_tag="$2"
  local repo="${3:-$ECR_PROJECT}"

  if [[ -z "$manifest" ]] || [[ "$manifest" == "None" ]]; then
    return 1
  fi

  aws ecr put-image \
    --repository-name "${repo}" \
    --region "${ECR_REGION}" \
    --image-tag "${new_tag}" \
    --image-manifest "$manifest" 2>/dev/null || true
}

# =============================================================================
# ecr_tag_exists - Check if a tag exists
# =============================================================================
# Arguments:
#   $1 - Tag name
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_tag_exists() {
  local tag="$1"
  local repo="${2:-$ECR_PROJECT}"

  aws ecr describe-images \
    --repository-name "${repo}" \
    --region "${ECR_REGION}" \
    --image-ids imageTag="${tag}" \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null | grep -qv "None"
}

# =============================================================================
# ecr_rotate_production_tags - Rotate production previous tags for one repo
# =============================================================================
# Arguments:
#   $1 - New tag to promote to production
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_rotate_production_tags() {
  local new_tag="$1"
  local repo="${2:-$ECR_PROJECT}"

  echo "Rotating production tags for ${repo}..."

  # Rotate previous tags (N-1 → N, N-2 → N-1, etc.)
  for i in $(seq $((PRODUCTION_KEEP_COUNT - 1)) -1 1); do
    local from_tag="production-previous-$i"
    local to_tag="production-previous-$((i + 1))"

    local manifest
    manifest=$(ecr_get_manifest "$from_tag" "$repo")

    if [[ -n "$manifest" ]] && [[ "$manifest" != "None" ]]; then
      ecr_put_tag "$manifest" "$to_tag" "$repo"
      echo "  Rotated $from_tag -> $to_tag"
    fi
  done

  # Current production → production-previous-1
  local prod_manifest
  prod_manifest=$(ecr_get_manifest "production" "$repo")

  if [[ -n "$prod_manifest" ]] && [[ "$prod_manifest" != "None" ]]; then
    ecr_put_tag "$prod_manifest" "production-previous-1" "$repo"
    echo "  Backed up current production to production-previous-1"
  fi

  # New tag → production
  local new_manifest
  new_manifest=$(ecr_get_manifest "$new_tag" "$repo")

  if [[ -n "$new_manifest" ]] && [[ "$new_manifest" != "None" ]]; then
    ecr_put_tag "$new_manifest" "production" "$repo"
    echo "  Tagged ${new_tag} as production"
  else
    echo "  Error: Could not get manifest for ${new_tag} in ${repo}" >&2
    return 1
  fi

  echo "  Tag rotation complete"
}

# =============================================================================
# ecr_rotate_staging_tags - Rotate staging previous tags for one repo
# =============================================================================
# Arguments:
#   $1 - New tag to promote to staging
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_rotate_staging_tags() {
  local new_tag="$1"
  local repo="${2:-$ECR_PROJECT}"

  echo "Rotating staging tags for ${repo}..."

  for i in $(seq $((STAGING_KEEP_COUNT - 1)) -1 1); do
    local from_tag="staging-previous-$i"
    local to_tag="staging-previous-$((i + 1))"

    local manifest
    manifest=$(ecr_get_manifest "$from_tag" "$repo")

    if [[ -n "$manifest" ]] && [[ "$manifest" != "None" ]]; then
      ecr_put_tag "$manifest" "$to_tag" "$repo"
      echo "  Rotated $from_tag -> $to_tag"
    fi
  done

  local staging_manifest
  staging_manifest=$(ecr_get_manifest "staging" "$repo")

  if [[ -n "$staging_manifest" ]] && [[ "$staging_manifest" != "None" ]]; then
    ecr_put_tag "$staging_manifest" "staging-previous-1" "$repo"
    echo "  Backed up current staging to staging-previous-1"
  fi

  local new_manifest
  new_manifest=$(ecr_get_manifest "$new_tag" "$repo")

  if [[ -n "$new_manifest" ]] && [[ "$new_manifest" != "None" ]]; then
    ecr_put_tag "$new_manifest" "staging" "$repo"
    echo "  Tagged ${new_tag} as staging"
  else
    echo "  Error: Could not get manifest for ${new_tag} in ${repo}" >&2
    return 1
  fi

  echo "  Tag rotation complete"
}

# =============================================================================
# ecr_restore_production_previous - Restore a previous production image
# =============================================================================
# Arguments:
#   $1 - Steps back (default: 1)
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_restore_production_previous() {
  local steps="${1:-1}"
  local repo="${2:-$ECR_PROJECT}"
  local rollback_tag="production-previous-${steps}"

  echo "Restoring ${rollback_tag} to production in ${repo}..."

  local manifest
  manifest=$(ecr_get_manifest "$rollback_tag" "$repo")

  if [[ -z "$manifest" ]] || [[ "$manifest" == "None" ]]; then
    echo "  Error: No image found with tag ${rollback_tag} in ${repo}" >&2
    return 1
  fi

  ecr_put_tag "$manifest" "production" "$repo"
  echo "  Restored ${rollback_tag} to production"
}

# =============================================================================
# ecr_restore_staging_previous - Restore a previous staging image
# =============================================================================
# Arguments:
#   $1 - Steps back (default: 1)
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_restore_staging_previous() {
  local steps="${1:-1}"
  local repo="${2:-$ECR_PROJECT}"
  local rollback_tag="staging-previous-${steps}"

  echo "Restoring ${rollback_tag} to staging in ${repo}..."

  local manifest
  manifest=$(ecr_get_manifest "$rollback_tag" "$repo")

  if [[ -z "$manifest" ]] || [[ "$manifest" == "None" ]]; then
    echo "  Error: No image found with tag ${rollback_tag} in ${repo}" >&2
    return 1
  fi

  ecr_put_tag "$manifest" "staging" "$repo"
  echo "  Restored ${rollback_tag} to staging"
}

# =============================================================================
# ecr_verify_tag - Verify a tag exists in one repo
# =============================================================================
# Arguments:
#   $1 - Tag name
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_verify_tag() {
  local tag="$1"
  local repo="${2:-$ECR_PROJECT}"

  if ! ecr_tag_exists "$tag" "$repo"; then
    echo "Error: Tag ${tag} not found in ${repo}" >&2
    return 1
  fi

  return 0
}

# =============================================================================
# ecr_list_previous_tags - List available previous tags for an environment
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_list_previous_tags() {
  local environment="$1"
  local repo="${2:-$ECR_PROJECT}"

  echo "Available rollback tags for ${environment} in ${repo}:"

  aws ecr describe-images \
    --repository-name "${repo}" \
    --region "${ECR_REGION}" \
    --query 'imageDetails[*].imageTags' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -E "^${environment}-previous" | sort -V || echo "  (none found)"
}

# =============================================================================
# ecr_ensure_repo - Ensure ECR repository exists, create if not
# =============================================================================
# Arguments:
#   $1 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_ensure_repo() {
  local repo="${1:-$ECR_PROJECT}"

  if aws ecr describe-repositories --repository-names "${repo}" --region "${ECR_REGION}" &>/dev/null; then
    echo "ECR repository exists: ${repo}"
    return 0
  fi

  echo "Creating ECR repository: ${repo}"
  aws ecr create-repository \
    --repository-name "${repo}" \
    --region "${ECR_REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE

  echo "Repository created: ${repo}"
}

# =============================================================================
# ecr_login - Login to ECR
# =============================================================================
ecr_login() {
  local registry="${ECR_REGISTRY:-}"

  if [[ -z "$registry" ]]; then
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

    if [[ -z "$account_id" ]]; then
      echo "Error: Failed to get AWS account ID" >&2
      return 1
    fi

    registry="${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com"
  fi

  echo "Logging in to ECR: ${registry}"
  aws ecr get-login-password --region "${ECR_REGION}" | \
    docker login --username AWS --password-stdin "${registry}"
}

# =============================================================================
# ecr_get_registry - Get ECR registry URL
# =============================================================================
ecr_get_registry() {
  if [[ -n "${ECR_REGISTRY:-}" ]]; then
    echo "$ECR_REGISTRY"
    return
  fi

  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

  if [[ -z "$account_id" ]]; then
    echo "Error: Failed to get AWS account ID" >&2
    return 1
  fi

  echo "${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com"
}

# =============================================================================
# ecr_cleanup - Delete untagged images and old images beyond retention limit
# =============================================================================
# Arguments:
#   $1 - (optional) Environment name (for logging)
#   $2 - (optional) Repository name (default: ECR_PROJECT)
# =============================================================================
ecr_cleanup() {
  local environment="${1:-}"
  local repo="${2:-$ECR_PROJECT}"
  local keep_count="${ECR_KEEP_COUNT:-25}"

  if [[ -n "$environment" ]]; then
    echo "Cleaning up ECR repository: ${repo} (environment: ${environment})"
  else
    echo "Cleaning up ECR repository: ${repo}"
  fi

  # 1. Delete all untagged images
  local untagged
  untagged=$(aws ecr list-images \
    --repository-name "${repo}" \
    --region "${ECR_REGION}" \
    --filter tagStatus=UNTAGGED \
    --query 'imageIds[*]' \
    --output json 2>/dev/null || echo "[]")

  local untagged_count
  untagged_count=$(echo "$untagged" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "$untagged_count" -gt 0 ]]; then
    echo "  Deleting ${untagged_count} untagged images..."
    echo "$untagged" | python3 -c "
import sys, json, subprocess
ids = json.load(sys.stdin)
repo = '${repo}'
region = '${ECR_REGION}'
for i in range(0, len(ids), 100):
    batch = ids[i:i+100]
    batch_json = json.dumps(batch)
    subprocess.run([
        'aws', 'ecr', 'batch-delete-image',
        '--repository-name', repo,
        '--region', region,
        '--image-ids', batch_json
    ], capture_output=True)
print(f'  Deleted {len(ids)} untagged images')
" 2>/dev/null || echo "  Warning: Failed to delete some untagged images"
  else
    echo "  No untagged images to clean up"
  fi

  # 2. Remove old tagged images beyond retention limit
  local all_images
  all_images=$(aws ecr describe-images \
    --repository-name "${repo}" \
    --region "${ECR_REGION}" \
    --query 'imageDetails[*].{digest:imageDigest,tags:imageTags,pushed:imagePushedAt}' \
    --output json 2>/dev/null || echo "[]")

  local to_delete
  to_delete=$(echo "$all_images" | python3 -c "
import sys, json
images = json.load(sys.stdin)
tagged = [img for img in images if img.get('tags')]
tagged.sort(key=lambda x: x.get('pushed', ''), reverse=True)
if len(tagged) > ${keep_count}:
    old = tagged[${keep_count}:]
    protected_prefixes = ('staging', 'production', 'staging-previous', 'production-previous')
    deletable = []
    for img in old:
        tags = img.get('tags', [])
        if any(t.startswith(p) for t in tags for p in protected_prefixes if t == p or t.startswith(p + '-')):
            continue
        deletable.append({'imageDigest': img['digest']})
    print(json.dumps(deletable))
else:
    print('[]')
" 2>/dev/null || echo "[]")

  local delete_count
  delete_count=$(echo "$to_delete" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "$delete_count" -gt 0 ]]; then
    echo "  Deleting ${delete_count} old images (keeping ${keep_count} most recent)..."
    echo "$to_delete" | python3 -c "
import sys, json, subprocess
ids = json.load(sys.stdin)
repo = '${repo}'
region = '${ECR_REGION}'
for i in range(0, len(ids), 100):
    batch = ids[i:i+100]
    batch_json = json.dumps(batch)
    subprocess.run([
        'aws', 'ecr', 'batch-delete-image',
        '--repository-name', repo,
        '--region', region,
        '--image-ids', batch_json
    ], capture_output=True)
print(f'  Deleted {len(ids)} old images')
" 2>/dev/null || echo "  Warning: Failed to delete some old images"
  else
    echo "  No old images to clean up (within retention limit of ${keep_count})"
  fi

  echo "  ECR cleanup complete"
}

# =============================================================================
# Multi-repo functions — iterate over ECR_REPOS from common.sh
# =============================================================================

# =============================================================================
# ecr_rotate_tags_all - Rotate tags across all repos atomically
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#   $2 - New tag to rotate in
# =============================================================================
ecr_rotate_tags_all() {
  local environment="$1"
  local new_tag="$2"
  local repos="${ECR_REPOS:-$ECR_PROJECT}"
  local failed=0

  echo "Rotating ${environment} tags across all repos..."

  for repo in $repos; do
    case "$environment" in
      staging)
        ecr_rotate_staging_tags "$new_tag" "$repo" || { failed=1; break; }
        ;;
      production)
        ecr_rotate_production_tags "$new_tag" "$repo" || { failed=1; break; }
        ;;
      *)
        echo "Error: Unknown environment: $environment" >&2
        return 1
        ;;
    esac
  done

  if [[ "$failed" -eq 1 ]]; then
    echo "Error: Tag rotation failed — some repos may be inconsistent" >&2
    return 1
  fi

  echo "All repos rotated successfully"
}

# =============================================================================
# ecr_promote_all - Promote staging images to production across all repos
# =============================================================================
# Re-tags staging images as production without rebuilding.
# This is the "build once, deploy many" pattern.
#
# Arguments:
#   $1 - Source tag (e.g., "staging" or "staging-abc1234")
# =============================================================================
ecr_promote_all() {
  local source_tag="${1:-staging}"
  local repos="${ECR_REPOS:-$ECR_PROJECT}"
  local failed=0

  echo "Promoting ${source_tag} -> production across all repos..."

  for repo in $repos; do
    echo "  Promoting ${repo}..."

    # Verify source exists
    if ! ecr_tag_exists "$source_tag" "$repo"; then
      echo "  Error: Source tag ${source_tag} not found in ${repo}" >&2
      failed=1
      break
    fi

    # Rotate production tags (backup current production)
    ecr_rotate_production_tags "$source_tag" "$repo" || { failed=1; break; }
  done

  if [[ "$failed" -eq 1 ]]; then
    echo "Error: Promotion failed — some repos may be inconsistent" >&2
    echo "Consider rolling back with: ecr_restore_all production 1" >&2
    return 1
  fi

  echo "Promotion complete: ${source_tag} -> production"
}

# =============================================================================
# ecr_restore_all - Restore previous images across all repos
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#   $2 - Steps back (default: 1)
# =============================================================================
ecr_restore_all() {
  local environment="$1"
  local steps="${2:-1}"
  local repos="${ECR_REPOS:-$ECR_PROJECT}"
  local failed=0

  echo "Restoring ${environment}-previous-${steps} across all repos..."

  for repo in $repos; do
    case "$environment" in
      staging)
        ecr_restore_staging_previous "$steps" "$repo" || { failed=1; break; }
        ;;
      production)
        ecr_restore_production_previous "$steps" "$repo" || { failed=1; break; }
        ;;
      *)
        echo "Error: Unknown environment: $environment" >&2
        return 1
        ;;
    esac
  done

  if [[ "$failed" -eq 1 ]]; then
    echo "Error: Restore failed — some repos may be inconsistent" >&2
    return 1
  fi

  echo "Restore complete across all repos"
}

# =============================================================================
# ecr_verify_tag_all - Verify a tag exists in all repos
# =============================================================================
# Arguments:
#   $1 - Tag name
# =============================================================================
ecr_verify_tag_all() {
  local tag="$1"
  local repos="${ECR_REPOS:-$ECR_PROJECT}"
  local failed=0

  for repo in $repos; do
    if ! ecr_tag_exists "$tag" "$repo"; then
      echo "Error: Tag ${tag} not found in ${repo}" >&2
      failed=1
    fi
  done

  return $failed
}

# =============================================================================
# ecr_ensure_repos_all - Ensure all ECR repositories exist
# =============================================================================
ecr_ensure_repos_all() {
  local repos="${ECR_REPOS:-$ECR_PROJECT}"

  for repo in $repos; do
    ecr_ensure_repo "$repo"
  done
}

# =============================================================================
# ecr_cleanup_all - Clean up all repos
# =============================================================================
# Arguments:
#   $1 - (optional) Environment name
# =============================================================================
ecr_cleanup_all() {
  local environment="${1:-}"
  local repos="${ECR_REPOS:-$ECR_PROJECT}"

  for repo in $repos; do
    ecr_cleanup "$environment" "$repo"
  done
}
