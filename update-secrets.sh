#!/bin/bash
###############################################################
# update-secrets.sh
# Atualiza os Secrets do GitHub com as credenciais do AWS Academy
#
# Pré-requisito: GitHub CLI instalado
#   sudo dnf install gh -y   (no Cloud Shell)
#   gh auth login
#
# Como usar:
#   1. No AWS Academy → AWS Details → AWS CLI
#   2. Copie as 3 linhas de export e cole no terminal
#   3. Execute: bash update-secrets.sh
###############################################################

set -e

REPO="rocribeiro/mack-project-infra"

echo "=== Atualizando Secrets AWS Academy no GitHub ==="
echo ""

# Verifica se as variáveis de ambiente estão definidas
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
  echo "❌ Credenciais AWS não encontradas no ambiente."
  echo ""
  echo "Por favor:"
  echo "  1. Acesse o AWS Academy → AWS Details → AWS CLI"
  echo "  2. Copie as 3 linhas de export:"
  echo "       export AWS_ACCESS_KEY_ID=..."
  echo "       export AWS_SECRET_ACCESS_KEY=..."
  echo "       export AWS_SESSION_TOKEN=..."
  echo "  3. Cole no terminal e execute esse script novamente"
  exit 1
fi

# Verifica se o GitHub CLI está instalado
if ! command -v gh &> /dev/null; then
  echo "❌ GitHub CLI não encontrado. Instalando..."
  sudo dnf install gh -y
  echo ""
  echo "Após instalar, autentique:"
  echo "  gh auth login"
  exit 1
fi

# Verifica autenticação
if ! gh auth status &> /dev/null; then
  echo "❌ Não autenticado no GitHub CLI."
  echo "Execute: gh auth login"
  exit 1
fi

echo "Atualizando AWS_ACCESS_KEY_ID..."
gh secret set AWS_ACCESS_KEY_ID     --body "$AWS_ACCESS_KEY_ID"     --repo "$REPO"

echo "Atualizando AWS_SECRET_ACCESS_KEY..."
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY" --repo "$REPO"

echo "Atualizando AWS_SESSION_TOKEN..."
gh secret set AWS_SESSION_TOKEN     --body "$AWS_SESSION_TOKEN"     --repo "$REPO"

echo ""
echo "✅ Secrets atualizados com sucesso!"
echo ""
echo "Agora você pode:"
echo "  1. Ir no GitHub → Actions → 'CI — Validação e Plan' → Run workflow"
echo "  2. Ou aplicar diretamente: terraform apply -auto-approve"
