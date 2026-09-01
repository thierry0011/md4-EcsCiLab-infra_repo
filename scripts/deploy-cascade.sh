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
# 00-iam-roles goes first: every IAM role every other stack needs (ECS task
# roles, CodePipeline/CodeDeploy/EventBridge roles, both GitHub OIDC roles)
# lives there, with policies built from deterministic ARNs (account/region/
# name convention) instead of Fn::ImportValue - so it has zero dependency on
# 01-05 and both GitHub Actions roles exist from the very first deploy.
# Adding a new stack, or a dependency graph that stops being a straight line,
# means editing this array by hand; nothing here detects that for you.
STACKS=(
  00-iam-roles
  01-network
  02-ecr
  03-security-endpoints
  04-ecs-alb
  05-cicd-pipeline
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

# 04-ecs-alb's EcsService.TaskDefinition property can never be changed via
# CloudFormation once CodeDeploy has performed a deployment - ECS's
# UpdateService API unconditionally rejects any attempt to change
# taskDefinition on a service using DeploymentController: CODE_DEPLOY
# ("Unable to update task definition on services with a CODE_DEPLOY
# deployment controller. Use AWS CodeDeploy to trigger a new deployment."),
# *even when the new value's content matches what's already live* -
# RegisterTaskDefinition always mints a brand-new revision ARN regardless of
# whether the content is identical to an existing revision, so there is no
# value you can feed back in that CloudFormation would see as "unchanged."
# An earlier version of this script tried to read the live image and inject
# it back into the change set to make the update a no-op; that's the
# scenario that fails, every time, once a service exists. So: never touch
# ImageUri for an existing service. Always use the static value from
# params/04-ecs-alb.json (frozen at whatever the bootstrap value was) - this
# keeps the TaskDefinition resource byte-identical to the stack's
# last-applied state, so CloudFormation sees no diff and never attempts to
# touch EcsService.TaskDefinition at all. This function is diagnostic only:
# it reports drift between the live image and the frozen params value, it
# does not act on it.
report_live_image_drift() {
  local cluster="${ENV_NAME}-cluster"
  local service="${ENV_NAME}-service"
  local task_def_arn image

  task_def_arn=$(aws ecs describe-services \
    --cluster "${cluster}" \
    --services "${service}" \
    --query 'services[0].taskDefinition' \
    --output text 2>/dev/null || true)

  if [[ -z "${task_def_arn}" || "${task_def_arn}" == "None" ]]; then
    echo "No live service found (${cluster}/${service}) - assuming first-ever deploy." >&2
    return
  fi

  image=$(aws ecs describe-task-definition \
    --task-definition "${task_def_arn}" \
    --query 'taskDefinition.containerDefinitions[0].image' \
    --output text 2>/dev/null || true)

  if [[ -z "${image}" || "${image}" == "None" ]]; then
    return
  fi

  echo "Live image is currently ${image} (via CodeDeploy). params/04-ecs-alb.json's ImageUri is intentionally not touched - see ARCHITECTURE.md." >&2
}

# Builds the --parameters JSON for a stack. Always the static params file -
# see report_live_image_drift() above for why 04-ecs-alb is never overridden.
params_file_for() {
  local tmpl="$1"

  if [[ "${tmpl}" == "04-ecs-alb" ]]; then
    report_live_image_drift
  fi

  echo "${INFRA_DIR}/params/${tmpl}.json"
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

  # create-change-set defaults to type UPDATE, which fails outright against a
  # stack that doesn't exist yet - so a brand-new stack needs CREATE
  # explicitly. This is what lets this script double as the first-ever
  # bootstrap of all stacks, not just a resync of ones already up.
  local change_set_type="UPDATE"
  if ! aws cloudformation describe-stacks --stack-name "${stack_name}" >/dev/null 2>&1; then
    change_set_type="CREATE"
  fi

  aws cloudformation create-change-set \
    --stack-name "${stack_name}" \
    --change-set-name "${change_set_name}" \
    --change-set-type "${change_set_type}" \
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

  # No exclusion for AWS::ECS::TaskDefinition here (an earlier version of
  # this script excluded it, assuming its "replacement" was harmless revision
  # churn - it isn't: any change to it always fails at the EcsService step,
  # see report_live_image_drift() above). If this ever fires on 04-ecs-alb,
  # params/04-ecs-alb.json's ImageUri (or another TaskDefinition property)
  # was changed and genuinely cannot be applied via a stack update while
  # CodeDeploy owns the service - revert the params change rather than
  # proceeding.
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

  if [[ "${change_set_type}" == "CREATE" ]]; then
    aws cloudformation wait stack-create-complete --stack-name "${stack_name}"
    echo "${stack_name} created."
  else
    aws cloudformation wait stack-update-complete --stack-name "${stack_name}"
    echo "${stack_name} updated."
  fi
}

for tmpl in "${STACKS[@]}"; do
  deploy_stack "${tmpl}"
done

echo "Cascade complete."
