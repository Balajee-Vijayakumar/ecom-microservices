# 🛒 E-Commerce Microservices on AWS EKS

> Full GitOps architecture on AWS EKS | us-east-2 | Multi-AZ | AWS Well-Architected 6 Pillars

---

## 🏗 Architecture

```
Account A (Developer EC2)              Account B (Production - us-east-2)
────────────────────────               ─────────────────────────────────────────────────
EC2 Dev Machine
    │
    │ git push
    ▼
GitHub Repo
├── /infra         CloudFormation
├── /services      App source code
├── /helm          Helm charts
├── /pipeline      Buildspecs
└── /argocd        ArgoCD apps
    │
    ├─── CodePipeline ──────────────────────────────────────────────────►
    │         │
    │    ┌────▼────┐   ┌──────────┐   ┌──────┐   ┌─────────┐   ┌──────────┐   ┌──────┐
    │    │  BUILD  │──►│  SCAN    │──►│ TEST │──►│ STAGING │──►│ APPROVE  │──►│ PROD │
    │    │ Docker  │   │Inspector │   │ Unit │   │  Auto   │   │ Manual   │   │ArgoCD│
    │    │ → ECR   │   │ (fail on │   │ Intg │   │ Deploy  │   │ Approval │   │ Sync │
    │    └─────────┘   │CRITICAL) │   └──────┘   └─────────┘   └──────────┘   └──────┘
    │                  └──────────┘
    │
    └── ArgoCD detects Helm values.yaml change
              ↓
        Syncs to EKS (staging or prod namespace)
              ↓
        ALB auto-updated

Infrastructure (Multi-AZ: us-east-2a/b/c):
┌─────────────────────────────────────────────────────────────┐
│  VPC 10.0.0.0/16                                            │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐           │
│  │ Public      │ │ Public      │ │ Public      │           │
│  │ 10.0.1/24   │ │ 10.0.2/24   │ │ 10.0.3/24   │           │
│  │ (ALB/NAT)   │ │ (ALB/NAT)   │ │ (ALB/NAT)   │           │
│  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘           │
│         │               │               │                   │
│  ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐           │
│  │ Private     │ │ Private     │ │ Private     │           │
│  │ 10.0.11/24  │ │ 10.0.12/24  │ │ 10.0.13/24  │           │
│  │ EKS Nodes   │ │ EKS Nodes   │ │ EKS Nodes   │           │
│  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘           │
│         │               │               │                   │
│  ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐           │
│  │ Data        │ │ Data        │ │ Data        │           │
│  │ 10.0.21/24  │ │ 10.0.22/24  │ │ 10.0.23/24  │           │
│  │ RDS Primary │ │ RDS Standby │ │ RDS Replica │           │
│  └─────────────┘ └─────────────┘ └─────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

---

## 📁 Repository Structure

```
ecom-microservices/
├── infra/
│   ├── 01-vpc.yaml               Multi-AZ VPC, subnets, NAT, security groups, AWS Config
│   ├── 02-eks.yaml               EKS cluster, node groups (on-demand + spot), OIDC, KMS
│   ├── 03-rds.yaml               PostgreSQL Multi-AZ, read replica, auto-rotation
│   ├── 04-supporting-services.yaml  ECR, S3, Secrets Manager, SNS, GuardDuty, CloudWatch
│   └── 05-codepipeline.yaml      CodePipeline with 7 stages, CodeBuild projects
│
├── services/
│   ├── api-gateway/              Node.js — JWT auth, rate limiting, reverse proxy
│   ├── user-service/             Node.js — Registration, login, profiles
│   ├── order-service/            Node.js — Orders, RabbitMQ publisher
│   ├── product-service/          Python FastAPI — Product catalog, stock
│   ├── analytics-service/        Python FastAPI — Events, metrics, dashboard
│   └── notification-service/     Python FastAPI — RabbitMQ consumer, emails
│
├── helm/
│   ├── api-gateway/
│   │   ├── Chart.yaml
│   │   ├── values-staging.yaml   ← CodePipeline updates image tag here
│   │   ├── values-prod.yaml      ← CodePipeline updates image tag here
│   │   └── templates/
│   │       └── deployment.yaml   Deployment + Service + HPA + PDB + Ingress
│   └── [same for all 6 services]
│
├── pipeline/
│   ├── buildspec-build.yml       Docker build + ECR push (all 6 services)
│   ├── buildspec-scan.yml        Inspector vulnerability scan (fail on CRITICAL)
│   ├── buildspec-test.yml        Unit + Integration tests
│   └── buildspec-deploy.yml      Update Helm values → push to Git → ArgoCD syncs
│
├── argocd/
│   └── applications.yaml         AppProject + 12 ArgoCD apps (6 services × 2 envs)
│
└── scripts/
    └── bootstrap.sh              One-time setup script (run from Developer EC2)
```

---

## ✅ AWS Well-Architected 6 Pillars

| Pillar | Implementation |
|--------|---------------|
| 🔒 **Security** | KMS encryption (EKS, RDS, ECR, SNS), GuardDuty, Inspector image scanning, Secrets Manager with auto-rotation, IAM least-privilege, VPC flow logs, AWS Config rules, non-root containers |
| 💰 **Cost Optimization** | Spot node group, S3 lifecycle policies, ECR lifecycle (keep 10 images), RDS right-sizing, CloudWatch billing alarms |
| 🔁 **Reliability** | Multi-AZ (3 AZs), Multi-AZ RDS + Read Replica, NAT per AZ, HPA + PDB, rolling deployments (maxUnavailable=0), ArgoCD self-heal, RDS auto backup |
| ⚡ **Performance** | ALB with target group health checks, HPA (CPU + Memory), EKS managed node groups, RDS Performance Insights, read replica for analytics |
| 🏆 **Operational Excellence** | GitOps (ArgoCD), full CloudWatch dashboard, SNS alerts, AWS Config compliance rules, pipeline stage separation (test → staging → prod), RDS enhanced monitoring |
| 🌱 **Sustainability** | Spot instances for burst workloads, S3 GLACIER tiering, scale-to-zero staging pods at night, efficient t3 instance family |

---

## 🚀 Quick Start

### Prerequisites (Developer EC2 - Account A)
```bash
# Install tools
sudo yum install -y git
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Configure AWS credentials for Account B (prod)
aws configure  # use Account B credentials
```

### One-Time Bootstrap
```bash
git clone https://github.com/YOUR_OWNER/ecom-microservices.git
cd ecom-microservices

export GITHUB_OWNER="your-github-username"
export ALERT_EMAIL="devops@yourcompany.com"
export DB_PASSWORD="YourStrongPassword123!"
export PROD_ACCOUNT_ID="123456789012"  # Account B ID

chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

### After Bootstrap — Just Push!
```bash
# Any code change
git add .
git commit -m "feat: update product service"
git push origin main
# ↓ CodePipeline triggers automatically
# ↓ Docker builds → ECR
# ↓ Inspector scans
# ↓ Tests run
# ↓ Staging deploys
# ↓ Manual approval email sent
# ↓ Prod deploys via ArgoCD
```

---

## 🔧 Environment Variables to Update

Before running bootstrap, update these in the files:

| File | Variable | Description |
|------|----------|-------------|
| `helm/*/values-*.yaml` | `AWS_ACCOUNT_ID` | Your Account B ID |
| `helm/*/values-*.yaml` | `host:` | Your actual domain |
| `argocd/applications.yaml` | `YOUR_GITHUB_OWNER` | Your GitHub username |
| `scripts/bootstrap.sh` | `ALERT_EMAIL` | Your email for alerts |

---

## 📊 Monitoring

- **CloudWatch Dashboard**: `https://console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=ecom-microservices-prod`
- **ArgoCD UI**: Run `kubectl get svc argocd-server -n argocd` to get the URL
- **GuardDuty**: Findings published every 15 minutes, high severity → SNS alert

---

## 🔐 Secrets Managed

| Secret Path | Contents |
|-------------|----------|
| `ecom-microservices/prod/rds/credentials` | DB host, user, password, port |
| `ecom-microservices/prod/app/jwt-secret` | JWT signing key (auto-generated) |
| `ecom-microservices/prod/app/smtp` | SMTP host, user, password |
| `ecom-microservices/prod/app/rabbitmq` | RabbitMQ connection URL |
