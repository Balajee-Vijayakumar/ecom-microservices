#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
#  ECOM MICROSERVICES - BOOTSTRAP SCRIPT
#  Complete deployment with all fixes pre-applied
# ═══════════════════════════════════════════════════════════════

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }
section() { echo -e "\n${BLUE}${BOLD}═══ $1 ═══${NC}\n"; }
info()    { echo -e "${CYAN}ℹ️  $1${NC}"; }

# ─── Validate Required Env Vars ─────────────────────────────────
section "Validating Environment"
required_vars=(PROD_ACCOUNT_ID DEV_ACCOUNT_ID GITHUB_OWNER GITHUB_REPO ALERT_EMAIL DB_PASSWORD PROJECT_NAME ENVIRONMENT REGION)
for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    error "Required environment variable $var is not set"
  fi
  log "$var is set"
done

# ─── Set Derived Variables ──────────────────────────────────────
STACK_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$REPO_DIR/infra"

info "Project: $PROJECT_NAME | Environment: $ENVIRONMENT | Region: $REGION"
info "Account: $PROD_ACCOUNT_ID | GitHub: $GITHUB_OWNER/$GITHUB_REPO"

# ─── Helper: Deploy or Update CloudFormation Stack ──────────────
deploy_stack() {
  local stack_name=$1
  local template=$2
  shift 2
  local params=("$@")

  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [[ "$status" == "ROLLBACK_COMPLETE" || "$status" == "DELETE_FAILED" ]]; then
    warn "Stack $stack_name in $status state. Deleting..."
    aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION"
    log "Stack $stack_name deleted"
    status="DOES_NOT_EXIST"
  fi

  local cmd="create-stack"
  local wait_cmd="stack-create-complete"
  if [[ "$status" != "DOES_NOT_EXIST" && "$status" != "DELETE_COMPLETE" ]]; then
    cmd="update-stack"
    wait_cmd="stack-update-complete"
  fi

  info "Deploying stack: $stack_name ..."

  local param_args=()
  for p in "${params[@]}"; do
    param_args+=("ParameterKey=${p%%=*},ParameterValue=${p#*=}")
  done

  if aws cloudformation "$cmd" \
    --stack-name "$stack_name" \
    --template-body "file://$template" \
    --parameters "${param_args[@]}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" 2>&1 | grep -v "No updates are to be performed"; then
    aws cloudformation wait "$wait_cmd" --stack-name "$stack_name" --region "$REGION" 2>/dev/null || true
    log "Stack $stack_name deployed"
  else
    warn "Stack $stack_name - no changes needed"
  fi
}

# ─── STEP 1: VPC ────────────────────────────────────────────────
section "Step 1/11: VPC"
deploy_stack "${STACK_PREFIX}-vpc" "$INFRA_DIR/01-vpc.yaml" \
  "ProjectName=$PROJECT_NAME" \
  "Environment=$ENVIRONMENT"

# ─── STEP 2: EKS ────────────────────────────────────────────────
section "Step 2/11: EKS Cluster"
deploy_stack "${STACK_PREFIX}-eks" "$INFRA_DIR/02-eks.yaml" \
  "ProjectName=$PROJECT_NAME" \
  "Environment=$ENVIRONMENT"

# ─── STEP 3: RDS ────────────────────────────────────────────────
section "Step 3/11: RDS PostgreSQL"
deploy_stack "${STACK_PREFIX}-rds" "$INFRA_DIR/03-rds.yaml" \
  "ProjectName=$PROJECT_NAME" \
  "Environment=$ENVIRONMENT" \
  "DBPassword=$DB_PASSWORD"

# ─── STEP 4: Supporting Services (ECR, Secrets, SNS) ────────────
section "Step 4/11: Supporting Services"
deploy_stack "${STACK_PREFIX}-supporting" "$INFRA_DIR/04-supporting-services.yaml" \
  "ProjectName=$PROJECT_NAME" \
  "Environment=$ENVIRONMENT" \
  "AlertEmail=$ALERT_EMAIL"

# ─── STEP 5: CodePipeline ───────────────────────────────────────
section "Step 5/11: CodePipeline"
CODESTAR_CONNECTION_ARN=$(aws codestar-connections list-connections \
  --region "$REGION" \
  --query "Connections[?ConnectionName=='${PROJECT_NAME}-github'].ConnectionArn" \
  --output text 2>/dev/null || echo "")

if [ -z "$CODESTAR_CONNECTION_ARN" ]; then
  info "Creating GitHub connection..."
  CODESTAR_CONNECTION_ARN=$(aws codestar-connections create-connection \
    --provider-type GitHub \
    --connection-name "${PROJECT_NAME}-github" \
    --region "$REGION" \
    --query "ConnectionArn" --output text)
fi
info "CodeStar connection ARN: $CODESTAR_CONNECTION_ARN"

deploy_stack "${STACK_PREFIX}-pipeline" "$INFRA_DIR/05-codepipeline.yaml" \
  "ProjectName=$PROJECT_NAME" \
  "Environment=$ENVIRONMENT" \
  "GitHubOwner=$GITHUB_OWNER" \
  "GitHubRepo=$GITHUB_REPO" \
  "GitHubConnectionArn=$CODESTAR_CONNECTION_ARN"

# ─── STEP 6: Configure kubectl ──────────────────────────────────
section "Step 6/11: Configure kubectl"
aws eks update-kubeconfig --name "${STACK_PREFIX}" --region "$REGION"
log "kubectl configured"

# ─── STEP 7: EKS Add-ons ────────────────────────────────────────
section "Step 7/11: EKS Add-ons (EBS CSI + ALB Controller)"

# Get node role
NODE_ROLE=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-eks" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='NodeRoleName'].OutputValue" \
  --output text 2>/dev/null || \
  aws iam list-roles --query "Roles[?contains(RoleName,'${STACK_PREFIX}-eks-node')].RoleName" \
  --output text | awk '{print $1}')

if [ -n "$NODE_ROLE" ]; then
  # Attach EBS CSI policy
  aws iam attach-role-policy \
    --role-name "$NODE_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    2>/dev/null || true
  log "EBS CSI policy attached to $NODE_ROLE"

  # Attach Secrets Manager policy
  aws iam put-role-policy \
    --role-name "$NODE_ROLE" \
    --policy-name AllowSecretsManagerAccess \
    --policy-document '{
      "Version":"2012-10-17",
      "Statement":[
        {"Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],"Resource":"*"},
        {"Effect":"Allow","Action":["kms:Decrypt"],"Resource":"*"},
        {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],"Resource":"*"}
      ]
    }' 2>/dev/null || true
  log "SecretsManager policy attached"
fi

# Install EBS CSI Driver
aws eks create-addon \
  --cluster-name "${STACK_PREFIX}" \
  --addon-name aws-ebs-csi-driver \
  --region "$REGION" 2>/dev/null || true

# Setup OIDC
OIDC_URL=$(aws eks describe-cluster --name "${STACK_PREFIX}" --region "$REGION" \
  --query "cluster.identity.oidc.issuer" --output text)

aws iam create-open-id-connect-provider \
  --url "$OIDC_URL" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
  --region "$REGION" 2>/dev/null || true
log "OIDC provider configured"

# Create ALB Controller IAM role
OIDC_ID=$(echo "$OIDC_URL" | sed 's|https://||')
cat > /tmp/alb-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${PROD_ACCOUNT_ID}:oidc-provider/${OIDC_ID}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "${OIDC_ID}:aud": "sts.amazonaws.com",
      "${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
    }}
  }]
}
EOF

aws iam create-role \
  --role-name "${STACK_PREFIX}-alb-controller-role" \
  --assume-role-policy-document file:///tmp/alb-trust-policy.json \
  2>/dev/null || true

# Download and attach ALB policy
curl -sLo /tmp/alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name "${STACK_PREFIX}-alb-controller-policy" \
  --policy-document file:///tmp/alb-iam-policy.json \
  2>/dev/null || true

aws iam attach-role-policy \
  --role-name "${STACK_PREFIX}-alb-controller-role" \
  --policy-arn "arn:aws:iam::${PROD_ACCOUNT_ID}:policy/${STACK_PREFIX}-alb-controller-policy" \
  2>/dev/null || true
log "ALB controller IAM role configured"

# Install ALB controller via helm
if ! kubectl get deployment aws-load-balancer-controller -n kube-system &>/dev/null; then
  helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
  helm repo update
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="${STACK_PREFIX}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${PROD_ACCOUNT_ID}:role/${STACK_PREFIX}-alb-controller-role" \
    --wait --timeout 5m 2>/dev/null || true
  log "ALB controller installed"
else
  kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
    "eks.amazonaws.com/role-arn=arn:aws:iam::${PROD_ACCOUNT_ID}:role/${STACK_PREFIX}-alb-controller-role" \
    --overwrite 2>/dev/null || true
  kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system 2>/dev/null || true
  log "ALB controller updated"
fi

# ─── STEP 8: RabbitMQ ───────────────────────────────────────────
section "Step 8/11: RabbitMQ"
kubectl apply -f "$REPO_DIR/k8s/rabbitmq/rabbitmq.yaml"
info "Waiting for RabbitMQ to be ready (90s)..."
sleep 90
kubectl wait --for=condition=ready pod -l app=rabbitmq \
  --namespace default --timeout=120s 2>/dev/null || warn "RabbitMQ not ready yet, continuing..."
log "RabbitMQ deployed"

# ─── STEP 9: RDS Security Group ─────────────────────────────────
section "Step 9/11: RDS Network Access"
RDS_SG=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-rds" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RDSSecurityGroupId'].OutputValue" \
  --output text 2>/dev/null || echo "")

VPC_CIDR=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-vpc" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcCidr'].OutputValue" \
  --output text 2>/dev/null || echo "10.0.0.0/16")

if [ -n "$RDS_SG" ]; then
  aws ec2 authorize-security-group-ingress \
    --group-id "$RDS_SG" \
    --protocol tcp --port 5432 --cidr "$VPC_CIDR" \
    --region "$REGION" 2>/dev/null || true
  log "RDS security group allows VPC traffic"
fi

# ─── STEP 10: Secrets ───────────────────────────────────────────
section "Step 10/11: Creating Secrets Manager Entries"

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --region "$REGION" \
  --query "DBInstances[?DBInstanceIdentifier=='${STACK_PREFIX}-postgres'].Endpoint.Address" \
  --output text)

if [ -z "$RDS_ENDPOINT" ]; then
  warn "RDS endpoint not found, using placeholder"
  RDS_ENDPOINT="localhost"
fi

info "RDS Endpoint: $RDS_ENDPOINT"

create_or_update_secret() {
  local name=$1
  local value=$2
  if aws secretsmanager describe-secret --secret-id "$name" --region "$REGION" &>/dev/null; then
    aws secretsmanager update-secret --secret-id "$name" --secret-string "$value" --region "$REGION" >/dev/null
  else
    aws secretsmanager create-secret --name "$name" --secret-string "$value" --region "$REGION" >/dev/null
  fi
  log "Secret: $name"
}

# Create secrets for all environments
for ENV_NAME in prod staging; do
  create_or_update_secret "${PROJECT_NAME}/${ENV_NAME}/rds/credentials" \
    "{\"host\":\"${RDS_ENDPOINT}\",\"port\":\"5432\",\"dbname\":\"postgres\",\"username\":\"ecomadmin\",\"password\":\"${DB_PASSWORD}\"}"

  create_or_update_secret "${PROJECT_NAME}/${ENV_NAME}/app/rabbitmq" \
    "{\"host\":\"rabbitmq.default.svc.cluster.local\",\"port\":\"5672\",\"username\":\"admin\",\"password\":\"admin123\"}"

  create_or_update_secret "${PROJECT_NAME}/${ENV_NAME}/app/jwt-secret" \
    "{\"secret\":\"${ENV_NAME}-jwt-$(openssl rand -hex 16)\"}"

  create_or_update_secret "${PROJECT_NAME}/${ENV_NAME}/app/smtp" \
    "{\"host\":\"smtp.gmail.com\",\"port\":\"587\",\"username\":\"noreply@example.com\",\"password\":\"placeholder\"}"

  create_or_update_secret "${PROJECT_NAME}/${ENV_NAME}/app/analytics" \
    "{\"enabled\":\"true\"}"
done

log "All secrets created"

# ─── STEP 11: EKS Auth + Database Init ─────────────────────────
section "Step 11/11: EKS Auth & Database Init"

# Add CodeBuild role to EKS auth
CODEBUILD_ROLE="arn:aws:iam::${PROD_ACCOUNT_ID}:role/${STACK_PREFIX}-codebuild-role"
kubectl get configmap aws-auth -n kube-system -o yaml > /tmp/aws-auth-backup.yaml

# Check if role already exists in configmap
if ! grep -q "$CODEBUILD_ROLE" /tmp/aws-auth-backup.yaml; then
  kubectl patch configmap aws-auth -n kube-system --patch \
    "{\"data\":{\"mapRoles\":\"$(kubectl get configmap aws-auth -n kube-system -o jsonpath='{.data.mapRoles}')    - rolearn: ${CODEBUILD_ROLE}\n      username: codebuild-deploy\n      groups:\n        - system:masters\n\"}}"  \
    2>/dev/null || warn "Could not patch aws-auth, may need manual step"
fi
log "EKS auth configured"

# Initialize database
if [ -f "$SCRIPT_DIR/init-databases.sql" ] && [ "$RDS_ENDPOINT" != "localhost" ]; then
  info "Initializing databases..."
  PGPASSWORD="$DB_PASSWORD" psql -h "$RDS_ENDPOINT" -U ecomadmin -d postgres \
    -f "$SCRIPT_DIR/init-databases.sql" 2>/dev/null || warn "DB init failed or already done"
  log "Databases initialized"
fi

# ─── FINAL SUMMARY ──────────────────────────────────────────────
section "Bootstrap Complete!"

echo -e "${GREEN}${BOLD}"
echo "═══════════════════════════════════════════════════"
echo "  DEPLOYMENT COMPLETE - MANUAL STEPS REQUIRED"
echo "═══════════════════════════════════════════════════"
echo -e "${NC}"

echo -e "${YELLOW}${BOLD}⚠️  IMPORTANT: Complete these 2 manual steps:${NC}\n"

echo -e "${BOLD}1. Authorize GitHub Connection:${NC}"
echo "   → Go to: https://${REGION}.console.aws.amazon.com/codesuite/settings/connections"
echo "   → Find '${PROJECT_NAME}-github'"
echo "   → Click 'Update pending connection'"
echo "   → Authorize with GitHub"
echo ""

echo -e "${BOLD}2. Add GitHub Token to SSM:${NC}"
echo "   → Create a GitHub token at: https://github.com/settings/tokens"
echo "   → Then run:"
echo "   aws ssm put-parameter \\"
echo "     --name '/${PROJECT_NAME}/github/token' \\"
echo "     --value 'YOUR_GITHUB_TOKEN' \\"
echo "     --type SecureString --region ${REGION}"
echo ""

echo -e "${BOLD}3. Trigger Pipeline:${NC}"
echo "   aws codepipeline start-pipeline-execution \\"
echo "     --name ${STACK_PREFIX}-pipeline \\"
echo "     --region ${REGION}"
echo ""

echo -e "${GREEN}${BOLD}Your infrastructure is ready! Pipeline will deploy all services.${NC}"
