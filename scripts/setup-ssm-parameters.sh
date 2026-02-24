#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# setup-ssm-parameters.sh
# Run this ONCE after bootstrap.sh to populate SSM Parameter Store
# with all required application config values
# Usage: ENVIRONMENT=prod ./scripts/setup-ssm-parameters.sh
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-prod}"
PROJECT_NAME="${PROJECT_NAME:-ecom-microservices}"
REGION="${REGION:-us-east-2}"
PREFIX="/${PROJECT_NAME}/${ENVIRONMENT}/config"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[SSM]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

put_param() {
  local NAME=$1
  local VALUE=$2
  local TYPE="${3:-String}"
  aws ssm put-parameter \
    --name "${PREFIX}/${NAME}" \
    --value "${VALUE}" \
    --type "${TYPE}" \
    --overwrite \
    --region "${REGION}" \
    --tags "Key=Project,Value=${PROJECT_NAME}" "Key=Environment,Value=${ENVIRONMENT}" \
    >/dev/null
  log "  ✅ ${PREFIX}/${NAME}"
}

echo ""
log "Setting up SSM Parameters for [${ENVIRONMENT}] in [${REGION}]..."
echo ""

# ── App Config ────────────────────────────────────────────────────────────────
log "App config parameters..."
put_param "environment"  "${ENVIRONMENT}"
put_param "region"       "${REGION}"
put_param "log-level"    "INFO"

# ── Service URLs (internal cluster DNS) ───────────────────────────────────────
log "Service URL parameters..."
NS="${PROJECT_NAME}-${ENVIRONMENT}"
put_param "user-service-url"         "http://user-service.${NS}.svc.cluster.local:3001"
put_param "order-service-url"        "http://order-service.${NS}.svc.cluster.local:3002"
put_param "product-service-url"      "http://product-service.${NS}.svc.cluster.local:8000"
put_param "analytics-service-url"    "http://analytics-service.${NS}.svc.cluster.local:8001"
put_param "notification-service-url" "http://notification-service.${NS}.svc.cluster.local:8002"

# ── RabbitMQ URL (stored as SecureString) ─────────────────────────────────────
log "RabbitMQ config..."
RABBITMQ_NS="rabbitmq"
put_param "rabbitmq-url" "amqp://guest:guest@rabbitmq.${RABBITMQ_NS}.svc.cluster.local:5672/" "SecureString"

# ── GitHub Token for pipeline (needed by buildspec-deploy.yml) ────────────────
log "GitHub token parameter..."
warn "You must set the GitHub token manually:"
warn "  Run: aws ssm put-parameter --name /${PROJECT_NAME}/github/token --value YOUR_GITHUB_TOKEN --type SecureString --region ${REGION}"
warn "  This token needs 'repo' scope to push Helm values back to GitHub"

# ── SMTP credentials reminder ─────────────────────────────────────────────────
warn ""
warn "Remember to update SMTP credentials in Secrets Manager:"
warn "  Secret name: ${PROJECT_NAME}/${ENVIRONMENT}/app/smtp"
warn "  Set: host, port, user, password"
warn ""
warn "For Gmail, use an App Password:"
warn "  https://myaccount.google.com/apppasswords"

echo ""
log "✅ SSM Parameters set successfully!"
log "   View them at: https://console.aws.amazon.com/systems-manager/parameters/?region=${REGION}&tab=Table"
echo ""
