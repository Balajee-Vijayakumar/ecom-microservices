#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# update-account-ids.sh
# Replace the AWS_ACCOUNT_ID placeholder in all Helm values files
# Run this ONCE before pushing to GitHub
# Usage: PROD_ACCOUNT_ID=123456789012 GITHUB_OWNER=your-username ./scripts/update-account-ids.sh
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

PROD_ACCOUNT_ID="${PROD_ACCOUNT_ID:?Set PROD_ACCOUNT_ID env var (Account B / Production account ID)}"
GITHUB_OWNER="${GITHUB_OWNER:?Set GITHUB_OWNER env var (your GitHub username or org)}"
REGION="${REGION:-us-east-2}"
PROJECT_NAME="${PROJECT_NAME:-ecom-microservices}"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[UPDATE]${NC} $1"; }

log "Replacing AWS_ACCOUNT_ID → ${PROD_ACCOUNT_ID} in all Helm values files..."
find helm/ -name "values-*.yaml" | while read -r FILE; do
  sed -i "s/AWS_ACCOUNT_ID/${PROD_ACCOUNT_ID}/g" "$FILE"
  log "  ✅ $FILE"
done

log "Replacing YOUR_GITHUB_OWNER → ${GITHUB_OWNER} in ArgoCD applications..."
sed -i "s/YOUR_GITHUB_OWNER/${GITHUB_OWNER}/g" argocd/applications.yaml
log "  ✅ argocd/applications.yaml"

log "Replacing REPO_OWNER placeholder in deploy buildspec..."
sed -i "s/\${REPO_OWNER}/${GITHUB_OWNER}/g" pipeline/buildspec-deploy.yml 2>/dev/null || true

echo ""
log "✅ All placeholders replaced!"
log "   Account ID : ${PROD_ACCOUNT_ID}"
log "   GitHub Owner: ${GITHUB_OWNER}"
echo ""
log "Next step: git add . && git commit -m 'chore: set account ids' && git push"
