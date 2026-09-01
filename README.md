# ECS CI/CD Lab — Infrastructure

CloudFormation templates for a highly-available, containerized ECS Fargate app
behind a public ALB, with blue/green deployments via CodeDeploy triggered by
EventBridge on ECR image pushes. Meant to be connected via **CloudFormation
Git sync** — one stack per template below.

Full design rationale is in [`../ARCHITECTURE.md`](../ARCHITECTURE.md). This
file is just the quick-start.

## Stacks, in deploy order

| # | Template | Key parameters | Depends on |
|---|---|---|---|
| 0 | `templates/00-iam-roles.yaml` | `RepositoryName`, `GitHubOrg`, `GitHubAppRepo`, `GitHubInfraRepo`, `GitHubBranch`, `CreateOidcProvider` | — |
| 1 | `templates/01-network.yaml` | `VpcCidr`, subnet CIDRs | — |
| 2 | `templates/02-ecr.yaml` | `RepositoryName` | — |
| 3 | `templates/03-security-endpoints.yaml` | `ContainerPort` | Stack 1 |
| 4 | `templates/04-ecs-alb.yaml` | `ImageUri` **(required, see below)** | Stacks 0, 1, 3 |
| 5 | `templates/05-cicd-pipeline.yaml` | — | Stacks 0, 2, 4 |

Every IAM role in the lab — ECS task roles, CodePipeline/CodeDeploy/EventBridge
service roles, and both GitHub OIDC roles (app repo push, infra repo cascade) —
lives in `00-iam-roles.yaml`. Its policies build ARNs deterministically
(account/region/name convention) instead of importing them from the stacks
that would otherwise own them, specifically so this stack has **no dependency
on 01-05** — deploy it first, and both GitHub Actions roles exist from minute
one, before the network or the ECR repo even exist.

All templates share `EnvironmentName` (default `ecs-cicd-lab`) — keep it identical
across every stack, since that's the string used to build every cross-stack
`Export`/`Fn::ImportValue` name.

Parameter values for all six stacks live in `params/<template>.json`, one file
per template, in the same `[{ "ParameterKey": ..., "ParameterValue": ... }]` shape
CloudFormation's own CLI commands expect. A few fields are placeholders you must
fill in before first use — `04-ecs-alb.json`'s `ImageUri` (the bootstrap image, see
below) and the `GitHubOrg`/`GitHubAppRepo`/`GitHubInfraRepo` fields in
`00-iam-roles.json`.

### The one manual step: bootstrap image

Stack 4 creates the ECS service, which needs a real image in ECR to reach a
healthy steady state. On a brand-new account ECR is empty, so before deploying
stack 4 (stacks 0-3 must already be up, since `docker push` needs a real ECR
repository to push into):

```bash
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
docker build -t <account>.dkr.ecr.<region>.amazonaws.com/ecs-cicd-lab-app:bootstrap ../app-repo
docker push <account>.dkr.ecr.<region>.amazonaws.com/ecs-cicd-lab-app:bootstrap
```

then pass that URI as stack 4's `ImageUri` parameter. Every deployment after
this one is handled by the CodeDeploy blue/green pipeline, not by this stack.

## On-demand full resync (`00-iam-roles`'s `InfraDeployRole` + `scripts/deploy-cascade.sh`)

CloudFormation Git sync deploys each stack when *that stack's own template file*
changes — it doesn't know (or need to know) that `03-security-endpoints.yaml`
imports values from `01-network.yaml`. If you change something `01-network.yaml`
exports, GitSync alone won't redeploy the stacks downstream of it; you'd have
to remember which ones import it and redeploy each by hand.

`scripts/deploy-cascade.sh`, run via the `Deploy Infra (on-demand cascade resync)`
GitHub Actions workflow (`workflow_dispatch` — trigger it manually from the Actions
tab whenever you've changed an `Export`), walks all six stacks in dependency
order and lets CloudFormation's own change-set diffing figure out which ones
actually need an update. It also doubles as the bootstrap tool for a brand-new
account — it detects whether each stack already exists and uses a `CREATE` or
`UPDATE` change set accordingly. It supplements GitSync, it doesn't replace it —
GitSync's per-file auto-deploy trigger stays on.

Two things it does that a plain `deploy` loop wouldn't:
- Before touching `04-ecs-alb`, it looks up whatever task definition CodeDeploy
  currently has live and pins `ImageUri` to that — otherwise a routine resync would
  silently revert every blue/green deployment CodeDeploy has promoted since the
  one-time bootstrap image.
- If a change would force a resource **replacement** (not an in-place update), it
  stops and asks you to review the change set in the console rather than executing
  it unattended.

Repository secret this workflow needs: `AWS_INFRA_DEPLOY_ROLE_ARN` ←
`00-iam-roles.yaml` output `InfraDeployRoleArn`. This is a separate,
broader-permission role from the app repo's — it's the one thing this workflow
actually needs beyond what GitSync already does, since GitHub Actions has no
credentials of its own to call `aws cloudformation` with.

## After stack 5: wire up the app repo

Copy these stack outputs into the app repo's GitHub Actions **repository
secrets**:

- `00-iam-roles` → `GitHubActionsRoleArn` → app repo secret `AWS_ROLE_ARN`
- `02-ecr` → `EcrRepositoryName` → `ECR_REPOSITORY`
- `05-cicd-pipeline` → `ArtifactBucketName` → `ARTIFACT_BUCKET`
- `00-iam-roles` → `TaskExecutionRoleArn`, `TaskRoleArn` → `TASK_EXECUTION_ROLE_ARN`, `TASK_ROLE_ARN`

Full list and the reasoning behind every design choice: see
[`../ARCHITECTURE.md`](../ARCHITECTURE.md).
