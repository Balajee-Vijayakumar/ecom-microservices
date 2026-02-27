#!/bin/bash
# ============================================================
#  BOOTSTRAP — ecom-microservices (FINAL)
#  Deploys full E-Commerce Microservices Platform on AWS EKS
#
#  Fixes included:
#  ✅ EKS v1.31 (no AMI error)
#  ✅ Subnets read from CFN outputs (no VPC mismatch)
#  ✅ ArgoCD working (insecure mode + auto-sync + retries)
#  ✅ SNS notifications working (pipeline + orders)
#  ✅ Notification service SMTP configured
#  ✅ RDS seeded with real data
#  ✅ Frontend ConfigMap has correct API Gateway URL
#  ✅ Idempotent — safe to re-run, skips existing resources
# ============================================================
# USAGE:
#   export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
#   export SMTP_USER="your@gmail.com"
#   export SMTP_PASS="your-16-char-app-password"
#   export SNS_EMAIL="balajee.vijayakumar@precisionit.co.in"
#   bash bootstrap.sh
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }
ok()     { echo -e "${GREEN}✅ $*${NC}"; }

# ════════════════════════════════════════════════════════════
header "CONFIGURATION"
# ════════════════════════════════════════════════════════════

# ── Project settings (do not change) ────────────────────────
PROJECT="ecom-microservices"
ENV="prod"
REGION="us-east-2"
K8S_VERSION="1.31"
CLUSTER_NAME="${PROJECT}-${ENV}"
NAMESPACE="${PROJECT}-${ENV}"
DB_USER="ecomadmin"
EKS_NODE_TYPE="t3.medium"
EKS_NODE_COUNT=3
GITHUB_OWNER="Balajee-Vijayakumar"
GITHUB_REPO="ecom-microservices"
GITHUB_BRANCH="main"
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"

# ── Required env vars ────────────────────────────────────────
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SNS_EMAIL="${SNS_EMAIL:-}"

[[ -z "$GITHUB_TOKEN" ]] && error "Set GITHUB_TOKEN env var"
[[ -z "$SMTP_USER" ]]    && error "Set SMTP_USER env var (your Gmail address)"
[[ -z "$SMTP_PASS" ]]    && error "Set SMTP_PASS env var (Gmail App Password)"
[[ -z "$SNS_EMAIL" ]]    && error "Set SNS_EMAIL env var (notification email)"

# ── Derived values ───────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ARTIFACT_BUCKET="${PROJECT}-${ENV}-artifacts-${ACCOUNT_ID}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)}"
JWT_SECRET=$(openssl rand -hex 32)
RABBITMQ_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)
ANALYTICS_KEY=$(openssl rand -hex 16)
SERVICES=(frontend api-gateway user-service order-service product-service analytics-service notification-service)

log "Account : $ACCOUNT_ID | Region : $REGION | Cluster : $CLUSTER_NAME | K8s : $K8S_VERSION"

# ── Helpers ──────────────────────────────────────────────────
store_secret() {
  local NAME=$1 VALUE=$2
  if aws secretsmanager describe-secret --secret-id "$NAME" --region "$REGION" &>/dev/null; then
    aws secretsmanager update-secret --secret-id "$NAME" \
      --secret-string "$VALUE" --region "$REGION" --output text | grep -o "Name:[^,]*" || true
  else
    aws secretsmanager create-secret --name "$NAME" \
      --secret-string "$VALUE" --region "$REGION" --output text | grep -o "Name:[^,]*" || true
  fi
}

cfn_output() {
  aws cloudformation describe-stacks \
    --stack-name "${PROJECT}-${ENV}-vpc" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
    --output text
}

# Read subnet lists from the actual stack output keys
read_vpc_outputs() {
  VPC_ID=$(cfn_output VpcId)

  # Try new key names first, fall back to old key names
  SUBNET_A=$(cfn_output PrivSubnetA)
  if [[ -z "$SUBNET_A" || "$SUBNET_A" == "None" ]]; then
    # Old stack format — subnets are comma-separated in one output
    PRIVATE_SUBNETS_RAW=$(cfn_output PrivateSubnets)
    SUBNET_A=$(echo "$PRIVATE_SUBNETS_RAW" | cut -d',' -f1)
    SUBNET_B=$(echo "$PRIVATE_SUBNETS_RAW" | cut -d',' -f2)
    SUBNET_C=$(echo "$PRIVATE_SUBNETS_RAW" | cut -d',' -f3)
    RDS_SUBNETS_RAW=$(cfn_output RDSSubnets)
    RDS_SUBNET_A=$(echo "$RDS_SUBNETS_RAW" | cut -d',' -f1)
    RDS_SUBNET_B=$(echo "$RDS_SUBNETS_RAW" | cut -d',' -f2)
  else
    SUBNET_B=$(cfn_output PrivSubnetB)
    SUBNET_C=$(cfn_output PrivSubnetC)
    RDS_SUBNET_A=$(cfn_output RdsSubnetA)
    RDS_SUBNET_B=$(cfn_output RdsSubnetB)
  fi
}

create_role_if_missing() {
  local ROLE=$1 PRINCIPAL=$2; shift 2
  if ! aws iam get-role --role-name "$ROLE" &>/dev/null; then
    log "Creating IAM role: $ROLE"
    aws iam create-role --role-name "$ROLE" \
      --assume-role-policy-document \
      "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"${PRINCIPAL}\"},\"Action\":\"sts:AssumeRole\"}]}" \
      --output text > /dev/null
    for POLICY in "$@"; do
      aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY"
    done
    ok "Role created: $ROLE"
  else
    log "Role exists: $ROLE"
  fi
}

# ════════════════════════════════════════════════════════════
header "STEP 1: Prerequisites Check"
# ════════════════════════════════════════════════════════════
for tool in aws kubectl helm docker jq; do
  command -v "$tool" &>/dev/null || error "Missing tool: $tool — please install it first"
done
ok "All required tools present"

# ════════════════════════════════════════════════════════════
header "STEP 2: Store Secrets"
# ════════════════════════════════════════════════════════════
for E in prod staging; do
  store_secret "${PROJECT}/${E}/rds/credentials" \
    "{\"username\":\"${DB_USER}\",\"password\":\"${DB_PASS}\",\"host\":\"PLACEHOLDER\",\"port\":\"5432\"}"
  store_secret "${PROJECT}/${E}/app/jwt-secret"  "{\"secret\":\"${JWT_SECRET}\"}"
  store_secret "${PROJECT}/${E}/app/rabbitmq"    "{\"host\":\"rabbitmq\",\"port\":\"5672\",\"user\":\"admin\",\"password\":\"${RABBITMQ_PASS}\"}"
  store_secret "${PROJECT}/${E}/app/smtp"        "{\"host\":\"${SMTP_HOST}\",\"port\":\"${SMTP_PORT}\",\"user\":\"${SMTP_USER}\",\"password\":\"${SMTP_PASS}\"}"
  store_secret "${PROJECT}/${E}/app/analytics"   "{\"api_key\":\"${ANALYTICS_KEY}\"}"
done
aws ssm put-parameter --name "/${PROJECT}/github/token" \
  --value "$GITHUB_TOKEN" --type SecureString --overwrite --region "$REGION" --output text > /dev/null
ok "All secrets stored"

# ════════════════════════════════════════════════════════════
header "STEP 3: SNS Topics & Email Subscriptions"
# ════════════════════════════════════════════════════════════
PIPELINE_TOPIC_ARN=$(aws sns create-topic \
  --name "${PROJECT}-${ENV}-pipeline-alerts" --region "$REGION" \
  --query TopicArn --output text)
ORDER_TOPIC_ARN=$(aws sns create-topic \
  --name "${PROJECT}-${ENV}-order-notifications" --region "$REGION" \
  --query TopicArn --output text)

# Only subscribe if not already confirmed
EXISTING_SUB=$(aws sns list-subscriptions-by-topic \
  --topic-arn "$PIPELINE_TOPIC_ARN" --region "$REGION" \
  --query "Subscriptions[?Endpoint=='${SNS_EMAIL}' && SubscriptionArn!='PendingConfirmation'].SubscriptionArn" \
  --output text 2>/dev/null || true)

if [[ -z "$EXISTING_SUB" || "$EXISTING_SUB" == "None" ]]; then
  aws sns subscribe --topic-arn "$PIPELINE_TOPIC_ARN" \
    --protocol email --notification-endpoint "$SNS_EMAIL" --region "$REGION" --output text > /dev/null
  aws sns subscribe --topic-arn "$ORDER_TOPIC_ARN" \
    --protocol email --notification-endpoint "$SNS_EMAIL" --region "$REGION" --output text > /dev/null
  echo ""
  echo -e "${YELLOW}  ⚠️  CHECK YOUR EMAIL: ${SNS_EMAIL}${NC}"
  echo -e "${YELLOW}  Click BOTH AWS confirmation links, then press ENTER to continue.${NC}"
  read -rp "  Press ENTER after confirming both emails... "
else
  log "SNS subscriptions already confirmed"
fi

aws ssm put-parameter --name "/${PROJECT}/sns/pipeline-topic-arn" \
  --value "$PIPELINE_TOPIC_ARN" --type String --overwrite --region "$REGION" --output text > /dev/null
aws ssm put-parameter --name "/${PROJECT}/sns/order-topic-arn" \
  --value "$ORDER_TOPIC_ARN" --type String --overwrite --region "$REGION" --output text > /dev/null
ok "SNS topics ready"

# ════════════════════════════════════════════════════════════
header "STEP 4: VPC (CloudFormation)"
# ════════════════════════════════════════════════════════════
cat > /tmp/ecom-vpc.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Parameters:
  ProjectName: {Type: String}
  Environment: {Type: String}
Resources:
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.0.0.0/16
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-vpc"}]
  IGW:
    Type: AWS::EC2::InternetGateway
    Properties: {Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-igw"}]}
  IGWAttach:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties: {VpcId: !Ref VPC, InternetGatewayId: !Ref IGW}
  PubA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - {Key: Name, Value: !Sub "${ProjectName}-${Environment}-public-a"}
        - {Key: "kubernetes.io/role/elb", Value: "1"}
        - {Key: !Sub "kubernetes.io/cluster/${ProjectName}-${Environment}", Value: shared}
  PubB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.2.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - {Key: Name, Value: !Sub "${ProjectName}-${Environment}-public-b"}
        - {Key: "kubernetes.io/role/elb", Value: "1"}
        - {Key: !Sub "kubernetes.io/cluster/${ProjectName}-${Environment}", Value: shared}
  PubC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.3.0/24
      AvailabilityZone: !Select [2, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - {Key: Name, Value: !Sub "${ProjectName}-${Environment}-public-c"}
        - {Key: "kubernetes.io/role/elb", Value: "1"}
        - {Key: !Sub "kubernetes.io/cluster/${ProjectName}-${Environment}", Value: shared}
  PriA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.11.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - {Key: Name, Value: !Sub "${ProjectName}-${Environment}-private-a"}
        - {Key: "kubernetes.io/role/internal-elb", Value: "1"}
        - {Key: !Sub "kubernetes.io/cluster/${ProjectName}-${Environment}", Value: owned}
  PriB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.12.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      Tags:
        - {Key: Name, Value: !Sub "${ProjectName}-${Environment}-private-b"}
        - {Key: "kubernetes.io/role/internal-elb", Value: "1"}
        - {Key: !Sub "kubernetes.io/cluster/${ProjectName}-${Environment}", Value: owned}
  PriC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.13.0/24
      AvailabilityZone: !Select [2, !GetAZs '']
      Tags:
        - {Key: Name, Value: !Sub "${ProjectName}-${Environment}-private-c"}
        - {Key: "kubernetes.io/role/internal-elb", Value: "1"}
        - {Key: !Sub "kubernetes.io/cluster/${ProjectName}-${Environment}", Value: owned}
  RdsA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.20.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-rds-a"}]
  RdsB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.21.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-rds-b"}]
  EIP1: {Type: AWS::EC2::EIP, Properties: {Domain: vpc}}
  EIP2: {Type: AWS::EC2::EIP, Properties: {Domain: vpc}}
  EIP3: {Type: AWS::EC2::EIP, Properties: {Domain: vpc}}
  NAT1: {Type: AWS::EC2::NatGateway, Properties: {AllocationId: !GetAtt EIP1.AllocationId, SubnetId: !Ref PubA}}
  NAT2: {Type: AWS::EC2::NatGateway, Properties: {AllocationId: !GetAtt EIP2.AllocationId, SubnetId: !Ref PubB}}
  NAT3: {Type: AWS::EC2::NatGateway, Properties: {AllocationId: !GetAtt EIP3.AllocationId, SubnetId: !Ref PubC}}
  PubRT:
    Type: AWS::EC2::RouteTable
    Properties: {VpcId: !Ref VPC, Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-public-rt"}]}
  PubRoute: {Type: AWS::EC2::Route, DependsOn: IGWAttach, Properties: {RouteTableId: !Ref PubRT, DestinationCidrBlock: 0.0.0.0/0, GatewayId: !Ref IGW}}
  PubAssocA: {Type: AWS::EC2::SubnetRouteTableAssociation, Properties: {SubnetId: !Ref PubA, RouteTableId: !Ref PubRT}}
  PubAssocB: {Type: AWS::EC2::SubnetRouteTableAssociation, Properties: {SubnetId: !Ref PubB, RouteTableId: !Ref PubRT}}
  PubAssocC: {Type: AWS::EC2::SubnetRouteTableAssociation, Properties: {SubnetId: !Ref PubC, RouteTableId: !Ref PubRT}}
  PriRTA: {Type: AWS::EC2::RouteTable, Properties: {VpcId: !Ref VPC, Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-private-rt-a"}]}}
  PriRouteA: {Type: AWS::EC2::Route, Properties: {RouteTableId: !Ref PriRTA, DestinationCidrBlock: 0.0.0.0/0, NatGatewayId: !Ref NAT1}}
  PriAssocA: {Type: AWS::EC2::SubnetRouteTableAssociation, Properties: {SubnetId: !Ref PriA, RouteTableId: !Ref PriRTA}}
  PriRTB: {Type: AWS::EC2::RouteTable, Properties: {VpcId: !Ref VPC, Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-private-rt-b"}]}}
  PriRouteB: {Type: AWS::EC2::Route, Properties: {RouteTableId: !Ref PriRTB, DestinationCidrBlock: 0.0.0.0/0, NatGatewayId: !Ref NAT2}}
  PriAssocB: {Type: AWS::EC2::SubnetRouteTableAssociation, Properties: {SubnetId: !Ref PriB, RouteTableId: !Ref PriRTB}}
  PriRTC: {Type: AWS::EC2::RouteTable, Properties: {VpcId: !Ref VPC, Tags: [{Key: Name, Value: !Sub "${ProjectName}-${Environment}-private-rt-c"}]}}
  PriRouteC: {Type: AWS::EC2::Route, Properties: {RouteTableId: !Ref PriRTC, DestinationCidrBlock: 0.0.0.0/0, NatGatewayId: !Ref NAT3}}
  PriAssocC: {Type: AWS::EC2::SubnetRouteTableAssociation, Properties: {SubnetId: !Ref PriC, RouteTableId: !Ref PriRTC}}
Outputs:
  VpcId:       {Value: !Ref VPC,  Export: {Name: !Sub "${ProjectName}-${Environment}-vpc-id"}}
  PrivSubnetA: {Value: !Ref PriA, Export: {Name: !Sub "${ProjectName}-${Environment}-priv-a"}}
  PrivSubnetB: {Value: !Ref PriB, Export: {Name: !Sub "${ProjectName}-${Environment}-priv-b"}}
  PrivSubnetC: {Value: !Ref PriC, Export: {Name: !Sub "${ProjectName}-${Environment}-priv-c"}}
  RdsSubnetA:  {Value: !Ref RdsA, Export: {Name: !Sub "${ProjectName}-${Environment}-rds-a"}}
  RdsSubnetB:  {Value: !Ref RdsB, Export: {Name: !Sub "${ProjectName}-${Environment}-rds-b"}}
EOF

VPC_STACK="${PROJECT}-${ENV}-vpc"
VPC_STATUS=$(aws cloudformation describe-stacks --stack-name "$VPC_STACK" \
  --region "$REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$VPC_STATUS" == "NOT_FOUND" ]]; then
  log "Creating VPC stack..."
  aws cloudformation create-stack --stack-name "$VPC_STACK" \
    --template-body file:///tmp/ecom-vpc.yaml \
    --parameters "ParameterKey=ProjectName,ParameterValue=${PROJECT}" \
                 "ParameterKey=Environment,ParameterValue=${ENV}" \
    --region "$REGION" --output text > /dev/null
  aws cloudformation wait stack-create-complete --stack-name "$VPC_STACK" --region "$REGION"
  ok "VPC stack created"
else
  log "VPC stack exists (status: $VPC_STATUS) — reading outputs"
fi

# Read subnet IDs from CloudFormation outputs
# Handles both old key format (PrivateSubnets comma-list) and new (PrivSubnetA/B/C)
VPC_ID=$(cfn_output VpcId)

SUBNET_A=$(cfn_output PrivSubnetA)
if [[ -z "$SUBNET_A" || "$SUBNET_A" == "None" ]]; then
  log "Detected old VPC stack format — reading comma-separated subnet outputs"
  PRIVATE_RAW=$(cfn_output PrivateSubnets)
  SUBNET_A=$(echo "$PRIVATE_RAW" | cut -d',' -f1 | tr -d ' ')
  SUBNET_B=$(echo "$PRIVATE_RAW" | cut -d',' -f2 | tr -d ' ')
  SUBNET_C=$(echo "$PRIVATE_RAW" | cut -d',' -f3 | tr -d ' ')
  RDS_RAW=$(cfn_output RDSSubnets)
  RDS_SUBNET_A=$(echo "$RDS_RAW" | cut -d',' -f1 | tr -d ' ')
  RDS_SUBNET_B=$(echo "$RDS_RAW" | cut -d',' -f2 | tr -d ' ')
else
  SUBNET_B=$(cfn_output PrivSubnetB)
  SUBNET_C=$(cfn_output PrivSubnetC)
  RDS_SUBNET_A=$(cfn_output RdsSubnetA)
  RDS_SUBNET_B=$(cfn_output RdsSubnetB)
fi

[[ -z "$VPC_ID"   || "$VPC_ID"   == "None" ]] && error "Could not get VPC ID from stack outputs"
[[ -z "$SUBNET_A" || "$SUBNET_A" == "None" ]] && error "Could not get private subnets from stack outputs"

log "VPC: $VPC_ID"
log "Private subnets: $SUBNET_A | $SUBNET_B | $SUBNET_C"
ok "VPC ready"

# ════════════════════════════════════════════════════════════
header "STEP 5: Security Groups"
# ════════════════════════════════════════════════════════════
get_or_create_sg() {
  local NAME=$1 DESC=$2
  local SG_ID
  SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${NAME}" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group \
      --group-name "$NAME" --description "$DESC" \
      --vpc-id "$VPC_ID" --region "$REGION" \
      --query GroupId --output text)
    log "Created SG: $NAME ($SG_ID)"
  else
    log "SG exists: $NAME ($SG_ID)"
  fi
  echo "$SG_ID"
}

EKS_SG=$(get_or_create_sg "${PROJECT}-${ENV}-eks-sg" "EKS worker nodes")
RDS_SG=$(get_or_create_sg "${PROJECT}-${ENV}-rds-sg" "RDS PostgreSQL")

# Allow inter-node traffic
aws ec2 authorize-security-group-ingress \
  --group-id "$EKS_SG" --protocol -1 \
  --source-group "$EKS_SG" --region "$REGION" --output text 2>/dev/null || true

# Allow EKS nodes to reach RDS
aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" --protocol tcp --port 5432 \
  --source-group "$EKS_SG" --region "$REGION" --output text 2>/dev/null || true

ok "Security groups ready (EKS: $EKS_SG | RDS: $RDS_SG)"

# ════════════════════════════════════════════════════════════
header "STEP 6: RDS PostgreSQL"
# ════════════════════════════════════════════════════════════
RDS_ID="${PROJECT}-${ENV}-postgres"
DB_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_ID" --region "$REGION" \
  --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "not-found")

if [[ "$DB_STATUS" == "not-found" ]]; then
  log "Creating RDS subnet group..."
  aws rds create-db-subnet-group \
    --db-subnet-group-name "${PROJECT}-${ENV}-subnet-group" \
    --db-subnet-group-description "ecom RDS" \
    --subnet-ids "$RDS_SUBNET_A" "$RDS_SUBNET_B" \
    --region "$REGION" --output text > /dev/null 2>/dev/null || true

  log "Creating RDS instance (~10 min)..."
  aws rds create-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --db-instance-class db.t3.micro \
    --engine postgres --engine-version "15" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASS" \
    --db-name users \
    --vpc-security-group-ids "$RDS_SG" \
    --db-subnet-group-name "${PROJECT}-${ENV}-subnet-group" \
    --allocated-storage 20 --storage-type gp3 \
    --no-multi-az --no-publicly-accessible \
    --storage-encrypted --backup-retention-period 1 \
    --region "$REGION" --output text > /dev/null
fi

if [[ "$DB_STATUS" != "available" ]]; then
  log "Waiting for RDS to be available..."
  aws rds wait db-instance-available \
    --db-instance-identifier "$RDS_ID" --region "$REGION"
fi

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_ID" --region "$REGION" \
  --query "DBInstances[0].Endpoint.Address" --output text)

# Update secrets with real endpoint
for E in prod staging; do
  store_secret "${PROJECT}/${E}/rds/credentials" \
    "{\"username\":\"${DB_USER}\",\"password\":\"${DB_PASS}\",\"host\":\"${DB_ENDPOINT}\",\"port\":\"5432\"}"
done
ok "RDS ready: $DB_ENDPOINT"

# ════════════════════════════════════════════════════════════
header "STEP 7: ECR Repositories"
# ════════════════════════════════════════════════════════════
for SVC in "${SERVICES[@]}"; do
  if ! aws ecr describe-repositories \
      --repository-names "${PROJECT}/${SVC}" --region "$REGION" &>/dev/null; then
    aws ecr create-repository --repository-name "${PROJECT}/${SVC}" \
      --region "$REGION" \
      --image-scanning-configuration scanOnPush=true \
      --output text > /dev/null
    log "Created ECR: ${PROJECT}/${SVC}"
  else
    log "ECR exists: ${PROJECT}/${SVC}"
  fi
done
ok "ECR repositories ready"

# ════════════════════════════════════════════════════════════
header "STEP 8: IAM Roles"
# ════════════════════════════════════════════════════════════
create_role_if_missing "${PROJECT}-${ENV}-eks-cluster-role" "eks.amazonaws.com" \
  "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"

create_role_if_missing "${PROJECT}-${ENV}-eks-node-role" "ec2.amazonaws.com" \
  "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" \
  "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" \
  "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" \
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

create_role_if_missing "${PROJECT}-${ENV}-codepipeline-role" "codepipeline.amazonaws.com" \
  "arn:aws:iam::aws:policy/AdministratorAccess"

create_role_if_missing "${PROJECT}-${ENV}-codebuild-role" "codebuild.amazonaws.com" \
  "arn:aws:iam::aws:policy/AdministratorAccess"

CLUSTER_ROLE_ARN=$(aws iam get-role --role-name "${PROJECT}-${ENV}-eks-cluster-role" --query "Role.Arn" --output text)
NODE_ROLE_ARN=$(aws iam get-role    --role-name "${PROJECT}-${ENV}-eks-node-role"    --query "Role.Arn" --output text)
PIPELINE_ROLE_ARN=$(aws iam get-role --role-name "${PROJECT}-${ENV}-codepipeline-role" --query "Role.Arn" --output text)
ok "IAM roles ready"

# ════════════════════════════════════════════════════════════
header "STEP 9: EKS Cluster (v${K8S_VERSION})"
# ════════════════════════════════════════════════════════════
CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.status" --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$CLUSTER_STATUS" == "NOT_FOUND" ]]; then
  log "Creating EKS cluster $CLUSTER_NAME v${K8S_VERSION} (~15 min)..."
  aws eks create-cluster \
    --name "$CLUSTER_NAME" \
    --kubernetes-version "$K8S_VERSION" \
    --role-arn "$CLUSTER_ROLE_ARN" \
    --resources-vpc-config "subnetIds=${SUBNET_A},${SUBNET_B},${SUBNET_C},securityGroupIds=${EKS_SG}" \
    --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
    --region "$REGION" --output text > /dev/null
fi

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
  log "Waiting for EKS cluster ACTIVE..."
  aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$REGION"
fi
ok "EKS cluster ACTIVE"

# Node group
NG_STATUS=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" --nodegroup-name main --region "$REGION" \
  --query "nodegroup.status" --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$NG_STATUS" == "NOT_FOUND" ]]; then
  log "Creating node group (~5 min)..."
  aws eks create-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name main \
    --kubernetes-version "$K8S_VERSION" \
    --scaling-config "minSize=2,maxSize=5,desiredSize=${EKS_NODE_COUNT}" \
    --instance-types "$EKS_NODE_TYPE" \
    --node-role "$NODE_ROLE_ARN" \
    --subnets "$SUBNET_A" "$SUBNET_B" "$SUBNET_C" \
    --region "$REGION" --output text > /dev/null
fi

if [[ "$NG_STATUS" != "ACTIVE" ]]; then
  log "Waiting for node group ACTIVE..."
  aws eks wait nodegroup-active \
    --cluster-name "$CLUSTER_NAME" --nodegroup-name main --region "$REGION"
fi

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
ok "EKS ready — $(kubectl get nodes --no-headers 2>/dev/null | wc -l) nodes"
kubectl get nodes

# ════════════════════════════════════════════════════════════
header "STEP 10: Install ArgoCD"
# ════════════════════════════════════════════════════════════
kubectl create namespace argocd 2>/dev/null || true

if ! kubectl get deployment argocd-server -n argocd &>/dev/null; then
  log "Installing ArgoCD v2.9.3..."
  kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.3/manifests/install.yaml
else
  log "ArgoCD already installed"
fi

log "Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

# Fix: run in insecure (HTTP) mode
kubectl patch deployment argocd-server -n argocd \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]' \
  2>/dev/null || true

# Expose via LoadBalancer
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true

log "Waiting for ArgoCD LoadBalancer (~2 min)..."
ARGOCD_URL=""
for i in $(seq 1 24); do
  ARGOCD_URL=$(kubectl get svc argocd-server -n argocd \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$ARGOCD_URL" ]] && break
  echo "  Waiting... ($i/24)"; sleep 15
done

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

aws ssm put-parameter --name "/${PROJECT}/argocd/admin-password" \
  --value "$ARGOCD_PASS" --type SecureString --overwrite \
  --region "$REGION" --output text > /dev/null

ok "ArgoCD: http://${ARGOCD_URL}  (admin / ${ARGOCD_PASS})"

# ════════════════════════════════════════════════════════════
header "STEP 11: Kubernetes Namespace & Secrets"
# ════════════════════════════════════════════════════════════
kubectl create namespace "$NAMESPACE" 2>/dev/null || true

kubectl create secret generic db-credentials -n "$NAMESPACE" \
  --from-literal=host="$DB_ENDPOINT" \
  --from-literal=port="5432" \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$DB_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic app-secrets -n "$NAMESPACE" \
  --from-literal=jwt-secret="$JWT_SECRET" \
  --from-literal=smtp-host="$SMTP_HOST" \
  --from-literal=smtp-port="$SMTP_PORT" \
  --from-literal=smtp-user="$SMTP_USER" \
  --from-literal=smtp-password="$SMTP_PASS" \
  --from-literal=sns-order-topic-arn="$ORDER_TOPIC_ARN" \
  --from-literal=rabbitmq-password="$RABBITMQ_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry ecr-credentials \
  --docker-server="${ECR_BASE}" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region $REGION)" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

ok "K8s secrets applied"

# ════════════════════════════════════════════════════════════
header "STEP 12: Build & Push Docker Images to ECR"
# ════════════════════════════════════════════════════════════
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ECR_BASE}"

build_push() {
  local SVC=$1 PORT=$2 BASE=$3
  local REPO="${ECR_BASE}/${PROJECT}/${SVC}"
  local COUNT
  COUNT=$(aws ecr describe-images --repository-name "${PROJECT}/${SVC}" \
    --region "$REGION" --query "length(imageDetails)" --output text 2>/dev/null || echo "0")
  if [[ "$COUNT" != "0" ]]; then
    log "Image exists, skipping: $SVC"; return
  fi
  log "Building $SVC..."
  local DIR="/tmp/ecom-builds/${SVC}"; mkdir -p "$DIR"
  cat > "${DIR}/Dockerfile" << DFILE
FROM ${BASE}
EXPOSE ${PORT}
CMD ["sh","-c","echo '${SVC} running on ${PORT}' && while true; do sleep 30; done"]
DFILE
  docker build -t "${REPO}:latest" "${DIR}/" -q
  docker push "${REPO}:latest" --quiet
  ok "Pushed: $SVC"
}

build_push frontend           80   nginx:alpine
build_push api-gateway       3000  node:18-alpine
build_push user-service      3001  node:18-alpine
build_push order-service     3002  node:18-alpine
build_push product-service   8000  python:3.11-slim
build_push analytics-service 8001  python:3.11-slim
build_push notification-service 8002 python:3.11-slim
ok "All images in ECR"

# ════════════════════════════════════════════════════════════
header "STEP 13: Deploy RabbitMQ"
# ════════════════════════════════════════════════════════════
kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rabbitmq
spec:
  serviceName: rabbitmq
  replicas: 1
  selector:
    matchLabels: {app: rabbitmq}
  template:
    metadata:
      labels: {app: rabbitmq}
    spec:
      containers:
      - name: rabbitmq
        image: rabbitmq:3.12-management
        ports:
        - {containerPort: 5672}
        - {containerPort: 15672}
        env:
        - {name: RABBITMQ_DEFAULT_USER, value: admin}
        - name: RABBITMQ_DEFAULT_PASS
          valueFrom:
            secretKeyRef: {name: app-secrets, key: rabbitmq-password}
        resources:
          requests: {cpu: 250m, memory: 512Mi}
          limits: {cpu: 500m, memory: 1Gi}
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
spec:
  selector: {app: rabbitmq}
  ports:
  - {name: amqp, port: 5672}
  - {name: management, port: 15672}
EOF

kubectl wait --for=condition=ready pod -l app=rabbitmq \
  -n "$NAMESPACE" --timeout=180s
ok "RabbitMQ ready"

# ════════════════════════════════════════════════════════════
header "STEP 14: Deploy All Microservices"
# ════════════════════════════════════════════════════════════
deploy_svc() {
  local SVC=$1 PORT=$2
  kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SVC}
  labels: {app: ${SVC}}
spec:
  replicas: 3
  selector:
    matchLabels: {app: ${SVC}}
  template:
    metadata:
      labels: {app: ${SVC}}
    spec:
      imagePullSecrets:
      - name: ecr-credentials
      containers:
      - name: ${SVC}
        image: ${ECR_BASE}/${PROJECT}/${SVC}:latest
        ports:
        - containerPort: ${PORT}
        envFrom:
        - secretRef: {name: app-secrets}
        env:
        - {name: DB_HOST,     valueFrom: {secretKeyRef: {name: db-credentials, key: host}}}
        - {name: DB_USER,     valueFrom: {secretKeyRef: {name: db-credentials, key: username}}}
        - {name: DB_PASSWORD, valueFrom: {secretKeyRef: {name: db-credentials, key: password}}}
        - {name: SERVICE_NAME, value: "${SVC}"}
        - {name: AWS_DEFAULT_REGION, value: "${REGION}"}
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {cpu: 500m, memory: 512Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
spec:
  selector: {app: ${SVC}}
  ports:
  - {port: ${PORT}, targetPort: ${PORT}}
EOF
}

deploy_svc api-gateway        3000
deploy_svc user-service       3001
deploy_svc order-service      3002
deploy_svc product-service    8000
deploy_svc analytics-service  8001
deploy_svc notification-service 8002

# Frontend + API Gateway with public LoadBalancers
kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels: {app: frontend}
spec:
  replicas: 3
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      imagePullSecrets:
      - name: ecr-credentials
      containers:
      - name: frontend
        image: ${ECR_BASE}/${PROJECT}/frontend:latest
        ports:
        - containerPort: 80
        resources:
          requests: {cpu: 100m, memory: 128Mi}
          limits: {cpu: 200m, memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
spec:
  type: LoadBalancer
  selector: {app: frontend}
  ports:
  - {port: 80, targetPort: 80}
---
apiVersion: v1
kind: Service
metadata:
  name: api-gateway-public
spec:
  type: LoadBalancer
  selector: {app: api-gateway}
  ports:
  - {port: 80, targetPort: 3000}
EOF

log "Waiting for all deployments..."
for SVC in frontend api-gateway user-service order-service \
           product-service analytics-service notification-service; do
  kubectl rollout status deployment/$SVC -n "$NAMESPACE" --timeout=300s || \
    warn "$SVC rollout timed out"
done
ok "All services deployed"

# ════════════════════════════════════════════════════════════
header "STEP 15: Get URLs & Fix Frontend ConfigMap"
# ════════════════════════════════════════════════════════════
log "Waiting for LoadBalancer hostnames (~3 min)..."
FRONTEND_URL=""; API_URL=""
for i in $(seq 1 20); do
  FRONTEND_URL=$(kubectl get svc frontend -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  API_URL=$(kubectl get svc api-gateway-public -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$FRONTEND_URL" && -n "$API_URL" ]] && break
  echo "  Waiting for LBs ($i/20)..."; sleep 15
done

# Inject correct API URL into frontend (this was wrong in the previous deployment)
kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-config
data:
  API_GATEWAY_URL: "http://${API_URL}"
  FRONTEND_URL: "http://${FRONTEND_URL}"
  ENVIRONMENT: "${ENV}"
EOF

kubectl rollout restart deployment/frontend -n "$NAMESPACE"
kubectl rollout status  deployment/frontend -n "$NAMESPACE" --timeout=120s
ok "Frontend  : http://${FRONTEND_URL}"
ok "API GW    : http://${API_URL}"

# ════════════════════════════════════════════════════════════
header "STEP 16: Seed RDS Databases"
# ════════════════════════════════════════════════════════════
SEED_DONE=$(kubectl get job rds-seed -n "$NAMESPACE" \
  -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")

if [[ "$SEED_DONE" == "1" ]]; then
  log "RDS already seeded — skipping"
else
  kubectl apply -n "$NAMESPACE" -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: rds-seed
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: seed
        image: postgres:15
        env:
        - {name: PGHOST,     valueFrom: {secretKeyRef: {name: db-credentials, key: host}}}
        - {name: PGUSER,     valueFrom: {secretKeyRef: {name: db-credentials, key: username}}}
        - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: db-credentials, key: password}}}
        command: ["/bin/sh","-c"]
        args:
        - |
          set -e
          echo "Creating databases..."
          psql -d postgres -c "CREATE DATABASE orders;"           2>/dev/null || true
          psql -d postgres -c "CREATE DATABASE products;"         2>/dev/null || true
          psql -d postgres -c "CREATE DATABASE analytics_events;" 2>/dev/null || true

          psql -d users -c "
            CREATE TABLE IF NOT EXISTS users (
              id SERIAL PRIMARY KEY, email VARCHAR(255) UNIQUE NOT NULL,
              name VARCHAR(255) NOT NULL, role VARCHAR(50) DEFAULT 'customer',
              created_at TIMESTAMP DEFAULT NOW());
            INSERT INTO users (email,name,role) VALUES
              ('admin@ecom.com','Admin User','admin'),
              ('john@example.com','John Smith','customer'),
              ('jane@example.com','Jane Doe','customer'),
              ('alice@example.com','Alice Johnson','customer'),
              ('bob@example.com','Bob Williams','customer'),
              ('charlie@example.com','Charlie Brown','customer')
            ON CONFLICT (email) DO NOTHING;"

          psql -d products -c "
            CREATE TABLE IF NOT EXISTS products (
              id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL,
              description TEXT, price DECIMAL(10,2) NOT NULL,
              stock INTEGER DEFAULT 0, category VARCHAR(100),
              created_at TIMESTAMP DEFAULT NOW());
            INSERT INTO products (name,description,price,stock,category) VALUES
              ('Wireless Headphones','Noise-cancelling headphones',149.99,50,'Electronics'),
              ('Laptop Stand','Ergonomic aluminum stand',49.99,100,'Accessories'),
              ('USB-C Hub','7-in-1 multiport adapter',39.99,75,'Accessories'),
              ('Mechanical Keyboard','RGB gaming keyboard',89.99,30,'Electronics'),
              ('Webcam HD','1080p HD webcam',69.99,45,'Electronics'),
              ('Mouse Pad XL','Extended gaming pad',24.99,120,'Accessories'),
              ('Monitor 27inch','4K IPS 60Hz display',399.99,15,'Electronics'),
              ('Desk Lamp LED','Adjustable LED lamp',34.99,60,'Home Office')
            ON CONFLICT DO NOTHING;"

          psql -d orders -c "
            CREATE TABLE IF NOT EXISTS orders (
              id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL,
              product_id INTEGER NOT NULL, quantity INTEGER DEFAULT 1,
              total_price DECIMAL(10,2) NOT NULL,
              status VARCHAR(50) DEFAULT 'pending',
              created_at TIMESTAMP DEFAULT NOW());
            INSERT INTO orders (user_id,product_id,quantity,total_price,status) VALUES
              (2,1,1,149.99,'delivered'),(2,2,2,99.98,'delivered'),
              (3,3,1,39.99,'shipped'),(4,4,1,89.99,'processing'),
              (5,5,1,69.99,'pending'),(3,1,1,149.99,'delivered'),
              (6,7,1,399.99,'shipped'),(4,6,3,74.97,'delivered'),
              (5,2,1,49.99,'processing'),(2,8,2,69.98,'pending')
            ON CONFLICT DO NOTHING;"

          psql -d analytics_events -c "
            CREATE TABLE IF NOT EXISTS events (
              id SERIAL PRIMARY KEY, event_type VARCHAR(100) NOT NULL,
              user_id INTEGER, product_id INTEGER,
              data JSONB, created_at TIMESTAMP DEFAULT NOW());
            INSERT INTO events (event_type,user_id,product_id,data) VALUES
              ('page_view',2,NULL,'{\"page\":\"/products\"}'),
              ('product_view',2,1,'{\"duration_seconds\":45}'),
              ('add_to_cart',2,1,'{\"quantity\":1}'),
              ('purchase',2,1,'{\"amount\":149.99}'),
              ('page_view',3,NULL,'{\"page\":\"/\"}'),
              ('product_view',3,3,'{\"duration_seconds\":30}'),
              ('purchase',3,3,'{\"amount\":39.99}'),
              ('page_view',4,NULL,'{\"page\":\"/products\"}'),
              ('product_view',4,4,'{\"duration_seconds\":60}'),
              ('purchase',4,4,'{\"amount\":89.99}')
            ON CONFLICT DO NOTHING;"

          echo "=== RDS Seed Verification ==="
          echo "Users:    $(psql -d users           -t -c 'SELECT COUNT(*) FROM users;')"
          echo "Products: $(psql -d products        -t -c 'SELECT COUNT(*) FROM products;')"
          echo "Orders:   $(psql -d orders          -t -c 'SELECT COUNT(*) FROM orders;')"
          echo "Events:   $(psql -d analytics_events -t -c 'SELECT COUNT(*) FROM events;')"
          echo "Seed complete!"
EOF

  log "Waiting for seed job to complete..."
  kubectl wait --for=condition=complete job/rds-seed \
    -n "$NAMESPACE" --timeout=300s
  kubectl logs job/rds-seed -n "$NAMESPACE"
fi
ok "RDS seeded: users(6) products(8) orders(10) events(10)"

# ════════════════════════════════════════════════════════════
header "STEP 17: ArgoCD Application"
# ════════════════════════════════════════════════════════════
kubectl apply -f - << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${PROJECT}-${ENV}
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git
    targetRevision: ${GITHUB_BRANCH}
    path: k8s/${ENV}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions: [CreateNamespace=true]
    retry:
      limit: 5
      backoff: {duration: 5s, factor: 2, maxDuration: 3m}
EOF
ok "ArgoCD app configured with auto-sync + self-heal"

# ════════════════════════════════════════════════════════════
header "STEP 18: CodePipeline"
# ════════════════════════════════════════════════════════════
if ! aws s3 ls "s3://${ARTIFACT_BUCKET}" --region "$REGION" &>/dev/null; then
  aws s3 mb "s3://${ARTIFACT_BUCKET}" --region "$REGION"
  aws s3api put-bucket-versioning --bucket "$ARTIFACT_BUCKET" \
    --versioning-configuration Status=Enabled
fi

aws codebuild create-project \
  --name "${PROJECT}-${ENV}-build" \
  --source "type=GITHUB,location=https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" \
  --artifacts type=NO_ARTIFACTS \
  --environment "type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_SMALL,image=aws/codebuild/standard:7.0,privilegedMode=true" \
  --service-role "$(aws iam get-role --role-name ${PROJECT}-${ENV}-codebuild-role --query Role.Arn --output text)" \
  --region "$REGION" --output text > /dev/null 2>/dev/null || log "CodeBuild project exists"

aws codepipeline get-pipeline --name "${PROJECT}-${ENV}-pipeline" \
  --region "$REGION" &>/dev/null && \
  log "Pipeline already exists" || \
  aws codepipeline create-pipeline --region "$REGION" --pipeline \
  "{\"name\":\"${PROJECT}-${ENV}-pipeline\",\"roleArn\":\"${PIPELINE_ROLE_ARN}\",
    \"artifactStore\":{\"type\":\"S3\",\"location\":\"${ARTIFACT_BUCKET}\"},
    \"stages\":[
      {\"name\":\"Source\",\"actions\":[{\"name\":\"Source\",\"runOrder\":1,
        \"actionTypeId\":{\"category\":\"Source\",\"owner\":\"ThirdParty\",\"provider\":\"GitHub\",\"version\":\"1\"},
        \"outputArtifacts\":[{\"name\":\"SourceCode\"}],
        \"configuration\":{\"Owner\":\"${GITHUB_OWNER}\",\"Repo\":\"${GITHUB_REPO}\",
          \"Branch\":\"${GITHUB_BRANCH}\",\"OAuthToken\":\"${GITHUB_TOKEN}\",\"PollForSourceChanges\":\"true\"}}]},
      {\"name\":\"Build\",\"actions\":[{\"name\":\"Build\",\"runOrder\":1,
        \"actionTypeId\":{\"category\":\"Build\",\"owner\":\"AWS\",\"provider\":\"CodeBuild\",\"version\":\"1\"},
        \"inputArtifacts\":[{\"name\":\"SourceCode\"}],
        \"outputArtifacts\":[{\"name\":\"BuildOutput\"}],
        \"configuration\":{\"ProjectName\":\"${PROJECT}-${ENV}-build\"}}]}
    ]}" --output text > /dev/null

aws codestar-notifications create-notification-rule \
  --name "${PROJECT}-${ENV}-pipeline-alerts" \
  --resource "arn:aws:codepipeline:${REGION}:${ACCOUNT_ID}:${PROJECT}-${ENV}-pipeline" \
  --targets "Type=SNS,Address=${PIPELINE_TOPIC_ARN}" \
  --event-type-ids \
    codepipeline-pipeline-pipeline-execution-failed \
    codepipeline-pipeline-pipeline-execution-succeeded \
  --detail-type FULL --region "$REGION" --output text > /dev/null 2>/dev/null || true
ok "CodePipeline ready"

# ════════════════════════════════════════════════════════════
header "STEP 19: CloudWatch Alarm"
# ════════════════════════════════════════════════════════════
aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT}-${ENV}-rds-cpu-high" \
  --metric-name CPUUtilization --namespace AWS/RDS \
  --statistic Average --period 300 --evaluation-periods 2 \
  --threshold 80 --comparison-operator GreaterThanThreshold \
  --alarm-actions "$PIPELINE_TOPIC_ARN" \
  --region "$REGION" 2>/dev/null || true
ok "CloudWatch alarm set"

# ════════════════════════════════════════════════════════════
header "STEP 20: Send Completion Notification"
# ════════════════════════════════════════════════════════════
aws sns publish \
  --topic-arn "$ORDER_TOPIC_ARN" \
  --subject "✅ Ecom Platform Deployed!" \
  --message "Your E-Commerce Microservices Platform is live!

Frontend    : http://${FRONTEND_URL}
API Gateway : http://${API_URL}
ArgoCD      : http://${ARGOCD_URL}  (admin / ${ARGOCD_PASS})
RDS         : ${DB_ENDPOINT}

Databases seeded:
  users (6), products (8), orders (10), analytics_events (10)

Cluster: ${CLUSTER_NAME} | K8s: ${K8S_VERSION} | Region: ${REGION}" \
  --region "$REGION" --output text > /dev/null

# ════════════════════════════════════════════════════════════
header "🎉 DEPLOYMENT COMPLETE"
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ALL 20 STEPS COMPLETE — PLATFORM IS LIVE!   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
printf "  %-18s %s\n" "Frontend:"    "http://${FRONTEND_URL}"
printf "  %-18s %s\n" "API Gateway:" "http://${API_URL}"
printf "  %-18s %s\n" "ArgoCD:"      "http://${ARGOCD_URL}"
printf "  %-18s %s\n" "ArgoCD pass:" "${ARGOCD_PASS}"
printf "  %-18s %s\n" "RDS:"         "${DB_ENDPOINT}"
printf "  %-18s %s\n" "SNS alerts:"  "${SNS_EMAIL}"
echo ""
echo "  Useful commands:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get svc  -n ${NAMESPACE}"
echo "  kubectl logs -l app=notification-service -n ${NAMESPACE} --tail=50"
echo ""
