#!/bin/bash
# ============================================================
#  TEARDOWN — ecom-microservices
#  Deletes ALL resources: EKS, RDS, VPC, ECR, Secrets,
#  IAM, SNS, CodePipeline, CloudWatch, ArgoCD
#  Safe to re-run. Handles stuck/failed stacks.
# ============================================================
# USAGE:  bash teardown.sh

set -uo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
header() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }
ok()     { echo -e "${GREEN}✅ $*${NC}"; }

# ── Config ───────────────────────────────────────────────────
PROJECT="ecom-microservices"
ENV="prod"
REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "451124812411")
CLUSTER_NAME="${PROJECT}-${ENV}"
NAMESPACE="${PROJECT}-${ENV}"

# ── Confirmation ─────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║   ⚠️   COMPLETE TEARDOWN — ALL DATA WILL BE LOST  ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Project : $PROJECT  |  Env : $ENV  |  Region : $REGION"
echo "  Account : $ACCOUNT_ID"
echo ""
read -rp "  Type DELETE to confirm: " CONFIRM
[[ "$CONFIRM" != "DELETE" ]] && { echo "Cancelled."; exit 0; }

# ════════════════════════════════════════════════════════════
header "STEP 1: Configure kubectl"
# ════════════════════════════════════════════════════════════
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null && \
    log "kubeconfig updated" || warn "Could not update kubeconfig"
else
  warn "EKS cluster not found — skipping kubeconfig"
fi

# ════════════════════════════════════════════════════════════
header "STEP 2: Delete Kubernetes Resources (releases ELBs)"
# ════════════════════════════════════════════════════════════
if kubectl get namespace "$NAMESPACE" &>/dev/null 2>&1; then
  log "Deleting all LoadBalancer services to release ELBs..."
  kubectl delete svc --all -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  log "Waiting 30s for ELBs to deregister..."
  sleep 30
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  ok "App namespace deleted"
else
  warn "Namespace $NAMESPACE not found — skipping"
fi

if kubectl get namespace argocd &>/dev/null 2>&1; then
  log "Deleting ArgoCD namespace..."
  kubectl delete namespace argocd --ignore-not-found=true 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════
header "STEP 3: Delete EKS Node Groups & Cluster"
# ════════════════════════════════════════════════════════════
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  # Delete all node groups first
  NODEGROUPS=$(aws eks list-nodegroups \
    --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --query "nodegroups[]" --output text 2>/dev/null || true)
  for NG in $NODEGROUPS; do
    log "Deleting node group: $NG"
    aws eks delete-nodegroup \
      --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$NG" \
      --region "$REGION" 2>/dev/null || true
    log "Waiting for node group deletion (~5 min)..."
    aws eks wait nodegroup-deleted \
      --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$NG" \
      --region "$REGION" 2>/dev/null || true
    ok "Node group $NG deleted"
  done

  log "Deleting EKS cluster: $CLUSTER_NAME"
  aws eks delete-cluster --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null || true
  log "Waiting for cluster deletion (~5 min)..."
  aws eks wait cluster-deleted --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null || true
  ok "EKS cluster deleted"
else
  warn "EKS cluster not found — skipping"
fi

# ════════════════════════════════════════════════════════════
header "STEP 4: Delete RDS Instance"
# ════════════════════════════════════════════════════════════
RDS_ID="${PROJECT}-${ENV}-postgres"
if aws rds describe-db-instances \
    --db-instance-identifier "$RDS_ID" --region "$REGION" &>/dev/null; then
  log "Deleting RDS: $RDS_ID"
  aws rds delete-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "$REGION" --output text
  log "Waiting for RDS deletion (~10 min)..."
  aws rds wait db-instance-deleted \
    --db-instance-identifier "$RDS_ID" --region "$REGION" 2>/dev/null || true
  ok "RDS deleted"
else
  warn "RDS not found — skipping"
fi

# Delete subnet group
aws rds delete-db-subnet-group \
  --db-subnet-group-name "${PROJECT}-${ENV}-subnet-group" \
  --region "$REGION" 2>/dev/null && log "RDS subnet group deleted" || true

# ════════════════════════════════════════════════════════════
header "STEP 5: Delete CloudFormation Stacks"
# ════════════════════════════════════════════════════════════

delete_stack() {
  local STACK=$1
  local STATUS
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")

  [[ "$STATUS" == "NOT_FOUND" ]] && { warn "Stack $STACK not found — skipping"; return 0; }

  log "Deleting stack: $STACK (status: $STATUS)"

  if [[ "$STATUS" == "DELETE_FAILED" ]]; then
    # Retain stuck resources and retry
    STUCK=$(aws cloudformation describe-stack-resources \
      --stack-name "$STACK" --region "$REGION" \
      --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
      --output text 2>/dev/null | tr '\t' ' ')
    if [[ -n "$STUCK" ]]; then
      warn "Retaining stuck resources: $STUCK"
      # shellcheck disable=SC2086
      aws cloudformation delete-stack \
        --stack-name "$STACK" --retain-resources $STUCK \
        --region "$REGION" 2>/dev/null || true
    fi
  else
    aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
  fi

  # Wait up to 25 min
  local attempts=0
  while true; do
    STATUS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK" --region "$REGION" \
      --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")
    [[ "$STATUS" == "NOT_FOUND" ]] && { ok "Stack $STACK deleted"; return 0; }
    [[ "$STATUS" == "DELETE_FAILED" ]] && { warn "Stack $STACK DELETE_FAILED — check console"; return 1; }
    printf "  [%02d] %s ...\n" "$attempts" "$STATUS"
    sleep 20
    (( attempts++ ))
    [[ $attempts -gt 75 ]] && { warn "Timeout on $STACK"; return 1; }
  done
}

# Delete in reverse creation order
for STACK in \
  "${PROJECT}-${ENV}-pipeline" \
  "${PROJECT}-${ENV}-supporting" \
  "${PROJECT}-${ENV}-rds" \
  "${PROJECT}-${ENV}-eks" \
  "${PROJECT}-${ENV}-vpc"; do
  delete_stack "$STACK" || true
done

# ════════════════════════════════════════════════════════════
header "STEP 6: Delete VPC & Networking (if stack left it behind)"
# ════════════════════════════════════════════════════════════
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-${ENV}-vpc" \
  --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  log "Cleaning up VPC: $VPC_ID"

  # NAT Gateways
  for NAT in $(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || true); do
    log "Deleting NAT gateway: $NAT"
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" --output text 2>/dev/null || true
  done
  # Wait for NAT deletion
  sleep 60

  # Internet Gateways
  for IGW in $(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null || true); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" --output text 2>/dev/null || true
  done

  # Subnets
  for SUBNET in $(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[].SubnetId" --output text 2>/dev/null || true); do
    aws ec2 delete-subnet --subnet-id "$SUBNET" --region "$REGION" 2>/dev/null || true
  done

  # Route tables (non-main)
  for RT in $(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "RouteTables[?length(Associations[?Main==\`true\`])==\`0\`].RouteTableId" \
    --output text 2>/dev/null || true); do
    aws ec2 delete-route-table --route-table-id "$RT" --region "$REGION" 2>/dev/null || true
  done

  # Security groups (non-default)
  for SG in $(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || true); do
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null || true
  done
  # Second pass (dependency order)
  for SG in $(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || true); do
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null || true
  done

  # Elastic IPs (unassociated)
  for EIP in $(aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[?AssociationId==null].AllocationId" \
    --output text 2>/dev/null || true); do
    aws ec2 release-address --allocation-id "$EIP" --region "$REGION" 2>/dev/null || true
  done

  # Delete VPC
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" && ok "VPC deleted" || warn "Could not delete VPC yet"
else
  log "VPC not found — already deleted"
fi

# ════════════════════════════════════════════════════════════
header "STEP 7: Delete ECR Repositories"
# ════════════════════════════════════════════════════════════
for SVC in frontend api-gateway user-service order-service \
           product-service analytics-service notification-service; do
  REPO="${PROJECT}/${SVC}"
  if aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" &>/dev/null; then
    aws ecr delete-repository --repository-name "$REPO" \
      --region "$REGION" --force --output text && log "Deleted ECR: $REPO"
  fi
done
ok "ECR repositories deleted"

# ════════════════════════════════════════════════════════════
header "STEP 8: Delete Secrets Manager & SSM"
# ════════════════════════════════════════════════════════════
for SECRET in \
  "${PROJECT}/prod/rds/credentials"    "${PROJECT}/prod/app/jwt-secret" \
  "${PROJECT}/prod/app/rabbitmq"       "${PROJECT}/prod/app/smtp" \
  "${PROJECT}/prod/app/analytics" \
  "${PROJECT}/staging/rds/credentials" "${PROJECT}/staging/app/jwt-secret" \
  "${PROJECT}/staging/app/rabbitmq"    "${PROJECT}/staging/app/smtp" \
  "${PROJECT}/staging/app/analytics"; do
  aws secretsmanager delete-secret --secret-id "$SECRET" \
    --force-delete-without-recovery --region "$REGION" \
    --output text 2>/dev/null && log "Deleted secret: $SECRET" || true
done

for PARAM in \
  "/${PROJECT}/github/token" \
  "/${PROJECT}/sns/pipeline-topic-arn" \
  "/${PROJECT}/sns/order-topic-arn" \
  "/${PROJECT}/argocd/admin-password"; do
  aws ssm delete-parameter --name "$PARAM" \
    --region "$REGION" 2>/dev/null && log "Deleted SSM: $PARAM" || true
done
ok "Secrets deleted"

# ════════════════════════════════════════════════════════════
header "STEP 9: Delete SNS Topics"
# ════════════════════════════════════════════════════════════
for TOPIC in $(aws sns list-topics --region "$REGION" \
  --query "Topics[?contains(TopicArn,'${PROJECT}')].TopicArn" \
  --output text 2>/dev/null || true); do
  aws sns delete-topic --topic-arn "$TOPIC" --region "$REGION" && log "Deleted SNS: $TOPIC"
done
ok "SNS topics deleted"

# ════════════════════════════════════════════════════════════
header "STEP 10: Delete IAM Roles"
# ════════════════════════════════════════════════════════════
delete_role() {
  local ROLE=$1
  aws iam get-role --role-name "$ROLE" &>/dev/null || return 0
  log "Deleting role: $ROLE"
  # Detach managed policies
  for ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null | tr '\t' '\n'); do
    [[ -n "$ARN" ]] && aws iam detach-role-policy \
      --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
  done
  # Delete inline policies
  for POL in $(aws iam list-role-policies --role-name "$ROLE" \
    --query "PolicyNames[]" --output text 2>/dev/null | tr '\t' '\n'); do
    [[ -n "$POL" ]] && aws iam delete-role-policy \
      --role-name "$ROLE" --policy-name "$POL" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && ok "Role deleted: $ROLE" || warn "Could not delete: $ROLE"
}

for ROLE in \
  "${PROJECT}-${ENV}-eks-cluster-role" \
  "${PROJECT}-${ENV}-eks-node-role" \
  "${PROJECT}-${ENV}-codepipeline-role" \
  "${PROJECT}-${ENV}-codebuild-role"; do
  delete_role "$ROLE"
done

# ════════════════════════════════════════════════════════════
header "STEP 11: Delete CodePipeline & CodeBuild"
# ════════════════════════════════════════════════════════════
aws codepipeline delete-pipeline \
  --name "${PROJECT}-${ENV}-pipeline" --region "$REGION" \
  2>/dev/null && ok "Pipeline deleted" || true

aws codebuild delete-project \
  --name "${PROJECT}-${ENV}-build" --region "$REGION" \
  2>/dev/null && ok "CodeBuild deleted" || true

# Artifact bucket
ARTIFACT_BUCKET="${PROJECT}-${ENV}-artifacts-${ACCOUNT_ID}"
if aws s3 ls "s3://${ARTIFACT_BUCKET}" --region "$REGION" &>/dev/null; then
  log "Emptying and deleting S3 bucket: $ARTIFACT_BUCKET"
  aws s3 rm "s3://${ARTIFACT_BUCKET}" --recursive --region "$REGION" 2>/dev/null || true
  aws s3 rb "s3://${ARTIFACT_BUCKET}" --force --region "$REGION" 2>/dev/null || true
  ok "S3 artifact bucket deleted"
fi

# ════════════════════════════════════════════════════════════
header "STEP 12: Delete CloudWatch Log Groups & Alarms"
# ════════════════════════════════════════════════════════════
for LG in $(aws logs describe-log-groups --region "$REGION" \
  --query "logGroups[?contains(logGroupName,'${PROJECT}')].logGroupName" \
  --output text 2>/dev/null | tr '\t' '\n'); do
  [[ -n "$LG" ]] && aws logs delete-log-group \
    --log-group-name "$LG" --region "$REGION" 2>/dev/null && log "Deleted log group: $LG" || true
done

aws cloudwatch delete-alarms \
  --alarm-names "${PROJECT}-${ENV}-rds-cpu" \
  --region "$REGION" 2>/dev/null || true

ok "CloudWatch cleaned up"

# ════════════════════════════════════════════════════════════
header "STEP 13: Remove kubectl Context"
# ════════════════════════════════════════════════════════════
CTX="arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
kubectl config delete-context "$CTX" 2>/dev/null || true
kubectl config delete-cluster  "$CTX" 2>/dev/null || true

# ════════════════════════════════════════════════════════════
header "FINAL: Verification"
# ════════════════════════════════════════════════════════════
echo ""
echo "  EKS cluster:"
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.status" --output text 2>/dev/null || echo "  ✅ Deleted"

echo ""
echo "  VPC:"
aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-${ENV}-vpc" \
  --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "  ✅ Deleted"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         TEARDOWN COMPLETE ✅                     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  If any stacks still show DELETE_FAILED, go to:"
echo "  https://us-east-2.console.aws.amazon.com/cloudformation"
echo ""
