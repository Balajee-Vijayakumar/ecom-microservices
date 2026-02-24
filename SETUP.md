# E-Commerce Microservices Platform - Setup Guide

## Prerequisites
- AWS Account with admin access
- EC2 instance (Amazon Linux 2) with AWS CLI, kubectl, helm, git installed
- GitHub account with a repository created

## Step 1: Export Environment Variables

Run these on your EC2 instance BEFORE anything else:

```bash
export PROD_ACCOUNT_ID="YOUR_AWS_ACCOUNT_ID"        # e.g. 451124812411
export DEV_ACCOUNT_ID="YOUR_AWS_ACCOUNT_ID"         # same as prod if single account
export GITHUB_OWNER="YOUR_GITHUB_USERNAME"           # e.g. Balajee-Vijayakumar
export GITHUB_REPO="ecom-microservices"
export ALERT_EMAIL="your@email.com"
export DB_PASSWORD='YourStr0ng!Pass#2024'
export PROJECT_NAME="ecom-microservices"
export ENVIRONMENT="prod"
export REGION="us-east-2"
```

## Step 2: Push Code to GitHub

```bash
cd ~
# If repo doesn't exist, extract from zip:
unzip ecom-microservices-PERFECT.zip
mv ecom-microservices ecom-microservices-repo
cd ecom-microservices-repo

git init
git config --global user.name "YOUR_NAME"
git config --global user.email "your@email.com"
git remote add origin https://YOUR_GITHUB_TOKEN@github.com/YOUR_GITHUB_OWNER/ecom-microservices.git
git add .
git commit -m "initial: complete ecom microservices platform"
git branch -M main
git push origin main --force
```

## Step 3: Run Bootstrap Script

```bash
cd ~/ecom-microservices-repo
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

This will automatically:
- Deploy all CloudFormation stacks (VPC, EKS, RDS, ECR, CodePipeline)
- Configure EKS (kubectl, add-ons, OIDC, ALB controller)
- Deploy RabbitMQ
- Create all Secrets Manager entries
- Configure IAM permissions

## Step 4: Authorize GitHub Connection (MANUAL - Required Once)

1. Go to: https://us-east-2.console.aws.amazon.com/codesuite/settings/connections
2. Find `ecom-microservices-github`
3. Click "Update pending connection"
4. Authorize with GitHub
5. Status should change to "Available"

## Step 5: Add GitHub Token

```bash
aws ssm put-parameter \
  --name '/ecom-microservices/github/token' \
  --value 'YOUR_GITHUB_PERSONAL_ACCESS_TOKEN' \
  --type SecureString \
  --region us-east-2
```

## Step 6: Trigger Pipeline

```bash
aws codepipeline start-pipeline-execution \
  --name ecom-microservices-prod-pipeline \
  --region us-east-2
```

## Step 7: Monitor Pipeline

```bash
watch -n 10 'aws codepipeline get-pipeline-state \
  --name ecom-microservices-prod-pipeline \
  --region us-east-2 \
  --query "stageStates[*].{Stage:stageName,Status:latestExecution.status}" \
  --output table'
```

Expected progression:
- Source → Succeeded (2 min)
- Test → Succeeded (5 min)
- Build → Succeeded (15 min)
- DeployStaging → Succeeded (10 min)
- ApproveProduction → **YOU MUST APPROVE IN AWS CONSOLE**
- DeployProduction → Succeeded (10 min)

## Step 8: Approve Production Deployment

Either:
- Go to AWS Console → CodePipeline → approve manually
- Or run:
```bash
TOKEN=$(aws codepipeline get-pipeline-state \
  --name ecom-microservices-prod-pipeline \
  --region us-east-2 \
  --query "stageStates[4].actionStates[0].latestExecution.token" \
  --output text)

aws codepipeline put-approval-result \
  --pipeline-name ecom-microservices-prod-pipeline \
  --stage-name ApproveProduction \
  --action-name ManualApproval \
  --result summary="Approved",status=Approved \
  --token $TOKEN \
  --region us-east-2
```

## Step 9: Get Your Website URL

```bash
kubectl get svc frontend -n ecom-microservices-prod
```

Open the EXTERNAL-IP in your browser!

## Troubleshooting

### Pipeline fails at Build stage
Check logs:
```bash
BUILD_ID=$(aws codebuild list-builds-for-project \
  --project-name ecom-microservices-prod-build --region us-east-2 --query "ids[0]" --output text)
LOG_STREAM=$(aws codebuild batch-get-builds --ids $BUILD_ID --region us-east-2 \
  --query "builds[0].logs.streamName" --output text)
aws logs get-log-events \
  --log-group-name /aws/codebuild/ecom-microservices-prod-build \
  --log-stream-name $LOG_STREAM --region us-east-2 \
  --query "events[*].message" --output text | grep -i error | head -20
```

### Pods in CrashLoopBackOff
```bash
kubectl logs -l app=SERVICE_NAME -n ecom-microservices-prod | tail -20
```

### Website LoadBalancer pending
```bash
# Fix node security group
NODE_SG=$(aws ec2 describe-security-groups --region us-east-2 \
  --filters "Name=tag:aws:eks:cluster-name,Values=ecom-microservices-prod" \
  --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $NODE_SG --protocol tcp --port 80 --cidr 0.0.0.0/0 --region us-east-2
```
