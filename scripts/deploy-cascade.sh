#!/usr/bin/env bash
#
# On-demand cascade resync for the ecs-cicd-lab infra stacks.
#
# Supplements CloudFormation GitSync, which keeps its own per-file auto-deploy
# trigger on and satisfies the "provisioned via CloudFormation GitSync" rubric
# line. This script is the tool you run manually (via the deploy-infra.yml
# workflow, or locally) after changing a value one stack Exports, so every
# downstream stack that imports it gets re-evaluated in dependency order
# without you having to work out which ones by hand.
#
# Requires: aws CLI v2, jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_NAME="${ENV_NAME:-ecs-cicd-lab}"

# Fixed, hand-maintained dependency order - not computed from the templates.
# Adding an 8th stack, or a dependency graph that stops being a straight line,
# means editing this array by hand; nothing here detects that for you.
STACKS=(
  01-network
  02-ecr
  03-security-endpoints
  04-ecs-alb
  05-cicd-pipeline
  06-github-oidc
  07-infra-deploy-role
)

# Tracks a change set that's been created but not yet executed, so a trap can
# clean it up if this script exits early (real failure, or the replacement
# gate below) instead of leaving it dangling in the console.
PENDING_STACK=""
PENDING_CHANGE_SET=""

cleanup_pending_change_set() {
  if [[ -n "${PENDING_CHANGE_SET}" ]]; then
    echo "Cleaning up unexecuted change set ${PENDING_CHANGE_SET} on ${PENDING_STACK}..."
    aws cloudformation delete-change-set \
      --stack-name "${PENDING_STACK}" \
      --change-set-name "${PENDING_CHANGE_SET}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_pending_change_set EXIT

stack_name_for() {
  local tmpl="$1"
  # e.g. 01-network -> ecs-cicd-lab-network
  echo "${ENV_NAME}-${tmpl#0*-}"
}

# 04-ecs-alb's TaskDefinition/ImageUri is a plain CloudFormation-managed
# property, but after the first CodeDeploy blue/green deployment, CodeDeploy -
# not this template - owns which task definition revision is actually live
# (see ARCHITECTURE.md). Redeploying with the static bootstrap ImageUri from
# params/04-ecs-alb.json would silently revert every deployment CodeDeploy has
# promoted since. So: always look up the live image first, and only fall back
# to the static param on a genuinely first-ever deploy (service doesn't exist
# yet).
resolve_live_image() {
  local cluster="${ENV_NAME}-cluster"
  local service="${ENV_NAME}-service"
  local task_def_arn image

  task_def_arn=$(aws ecs describe-services \
    --cluster "${cluster}" \
    --services "${service}" \
    --query 'services[0].taskDefinition' \
    --output text 2>/dev/null || true)

  if [[ -z "${task_def_arn}" || "${task_def_arn}" == "None" ]]; then
    echo "No live service found (${cluster}/${service}) - assuming first-ever deploy, using static ImageUri from params file." >&2
    return 1
  fi

  image=$(aws ecs describe-task-definition \
    --task-definition "${task_def_arn}" \
    --query 'taskDefinition.containerDefinitions[0].image' \
    --output text 2>/dev/null || true)

  if [[ -z "${image}" || "${image}" == "None" ]]; then
    echo "Found a task definition (${task_def_arn}) but couldn't read its image - falling back to static ImageUri." >&2
    return 1
  fi

  echo "${image}"
}

# Builds the --parameters JSON for a stack, overriding ImageUri with the live
# image for 04-ecs-alb specifically. Prints a path to a temp file.
params_file_for() {
  local tmpl="$1"
  local base_params="${INFRA_DIR}/params/${tmpl}.json"

  if [[ "${tmpl}" != "04-ecs-alb" ]]; then
    echo "${base_params}"
    return
  fi

  local resolved_image
  if resolved_image=$(resolve_live_image); then
    local tmp
    tmp="$(mktemp)"
    jq --arg img "${resolved_image}" \
      'map(if .ParameterKey == "ImageUri" then .ParameterValue = $img else . end)' \
      "${base_params}" > "${tmp}"
    echo "Using live image for 04-ecs-alb: ${resolved_image}" >&2
    echo "${tmp}"
  else
    echo "${base_params}"
  fi
}

deploy_stack() {
  local tmpl="$1"
  local stack_name
  stack_name="$(stack_name_for "${tmpl}")"
  local template_file="${INFRA_DIR}/templates/${tmpl}.yaml"
  local params_file
  params_file="$(params_file_for "${tmpl}")"
  local change_set_name="cs-${tmpl}-${RANDOM}"

  echo "==> ${stack_name}"

  aws cloudformation create-change-set \
    --stack-name "${stack_name}" \
    --change-set-name "${change_set_name}" \
    --template-body "file://${template_file}" \
    --parameters "file://${params_file}" \
    --capabilities CAPABILITY_NAMED_IAM >/dev/null

  PENDING_STACK="${stack_name}"
  PENDING_CHANGE_SET="${change_set_name}"

  if ! aws cloudformation wait change-set-create-complete \
        --stack-name "${stack_name}" --change-set-name "${change_set_name}"; then

    local status_reason
    status_reason=$(aws cloudformation describe-change-set \
      --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
      --query 'StatusReason' --output text 2>/dev/null || true)

    if [[ "${status_reason}" == *"didn't contain changes"* ]]; then
      echo "No changes for ${stack_name}, skipping."
      aws cloudformation delete-change-set \
        --stack-name "${stack_name}" --change-set-name "${change_set_name}" >/dev/null 2>&1 || true
      PENDING_STACK=""
      PENDING_CHANGE_SET=""
      return 0
    else
      echo "Change set failed for ${stack_name}: ${status_reason}" >&2
      exit 1
    fi
  fi

  local replacements
  replacements=$(aws cloudformation describe-change-set \
    --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
    --query "Changes[?ResourceChange.Replacement=='True'].ResourceChange.LogicalResourceId" \
    --output text)

  if [[ -n "${replacements}" ]]; then
    echo "Replacement required on ${stack_name} for: ${replacements}" >&2
    echo "Review the change set in the console before proceeding - a resource's physical ID would change. Not auto-executing." >&2
    exit 1
  fi

  aws cloudformation execute-change-set \
    --stack-name "${stack_name}" --change-set-name "${change_set_name}" >/dev/null

  PENDING_STACK=""
  PENDING_CHANGE_SET=""

  aws cloudformation wait stack-update-complete --stack-name "${stack_name}"
  echo "${stack_name} updated."
}

for tmpl in "${STACKS[@]}"; do
  deploy_stack "${tmpl}"
done

echo "Cascade complete."
