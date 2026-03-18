# 🏗️ B3 Data Lake - Infraestrutura AWS
**MBA Engenharia de Dados — Universidade Presbiteriana Mackenzie**

---

## ⚠️ ORDEM CORRETA DOS COMANDOS

O `terraform plan` vai falhar se rodar antes do apply porque o pip install
das Lambda Layers só roda durante o `apply`. Siga essa ordem:

```bash
terraform init
terraform apply   # ← direto, sem plan antes
```

Se quiser ver o plan sem erro, rode após o primeiro apply:
```bash
terraform plan    # funciona após o primeiro apply (layers já existem)
```

---

## 🚀 Deploy completo do zero

### 1. Abrir Cloud Shell na AWS
Console AWS → ícone Cloud Shell (canto superior direito)

### 2. Instalar Terraform
```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install terraform -y
terraform -version
```

### 3. Clonar e aplicar
```bash
git clone https://github.com/rocribeiro/mack-project-infra.git
cd mack-project-infra
terraform init
terraform apply
```
> Digite `yes` quando pedir confirmação.
> Aguarde ~5-10 minutos — o pip install das layers roda aqui.

### 4. Verificar recursos criados
```bash
terraform output
aws s3 ls | grep b3-datalake
aws lambda list-functions \
  --query 'Functions[?starts_with(FunctionName, `b3-datalake`)].FunctionName' \
  --output table
```

### 5. Acompanhar carga histórica (dispara automático)
```bash
aws logs tail /aws/lambda/b3-datalake-dev-b3-historico --follow
```

### 6. Testar Lambdas manualmente
```bash
# Yahoo Finance
aws lambda invoke \
  --function-name b3-datalake-dev-yahoo-to-kinesis \
  --payload '{"tickers": ["PETR4.SA", "VALE3.SA", "BOVA11.SA"]}' \
  --cli-binary-format raw-in-base64-out response.json && cat response.json

# Fechamento diário (forçando)
aws lambda invoke \
  --function-name b3-datalake-dev-b3-fechamento-diario \
  --payload '{"forcar_dia_util": true}' \
  --cli-binary-format raw-in-base64-out response.json && cat response.json
```

### Destruir tudo
```bash
terraform destroy
```

---

## ⚠️ Toda vez que reabrir o laboratório (credenciais expiram a cada 4h)
```bash
cd mack-project-infra
git pull
terraform apply
```
