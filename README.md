# 🏗️ B3 Data Lake - Infraestrutura AWS
## Solução de Consulta Financeira para Sugestão de Alocação de Carteira
**MBA Engenharia de Dados — Universidade Presbiteriana Mackenzie**

---

## 📐 Arquitetura Completa 

```
╔══════════════════════════════════════════════════════════════════╗
║                      FONTES DE DADOS                            ║
╠══════════════════╦═══════════════════════════════════════════════╣
║  B3 Site         ║  API Yahoo Finance                           ║
║  COTAHIST_A{ANO} ║  Todos ativos ativos (~400-500 tickers)      ║
╚═════════╤════════╩═══════════════╤═══════════════════════════════╝
          │                        │
          ▼                        ▼
  ┌───────────────┐     ┌──────────────────────┐
  │ Lambda        │     │ Lambda               │
  │ B3 Histórico  │     │ Yahoo Finance        │
  │ (10 anos,     │     │ (a cada 5min         │
  │  one-shot)    │     │  no pregão)          │
  │               │     └──────────┬───────────┘
  │ Lambda        │                │
  │ B3 Fechamento │                ▼
  │ (todo dia     │     ┌──────────────────────┐
  │  19h BRT)     │     │ Kinesis Data Stream  │
  └──────┬────────┘     └──────────┬───────────┘
         │                         │
         │              ┌──────────▼───────────┐
         │              │ Kinesis Firehose      │
         │              └──────────┬───────────┘
         │                         │
         └─────────────────────────▼
                    ┌──────────────────────┐
                    │   S3 Bronze / SOR    │  ← dados brutos
                    │  b3-series-historicas│
                    │  cotacoes-live/      │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  Glue Data Catalog   │  ← metadados
                    │  Glue Crawler Bronze │
                    └──────────┬───────────┘
                               │  Glue Job: bronze_to_silver.py
                               │  • limpa dados corrompidos
                               │  • padroniza tipos e datas
                               │  • remove cabeçalho/trailer B3
                               ▼
                    ┌──────────────────────┐
                    │   S3 Silver / SOT    │  ← dados tratados
                    └──────────┬───────────┘
                               │  Glue Job: silver_to_gold.py
                               │  • calcula retorno diário
                               │  • calcula volatilidade
                               │  • classifica perfil de risco
                               │  • gera features para ML
                               ▼
                    ┌──────────────────────┐
                    │   S3 Gold / SPEC     │  ← dados analíticos
                    └────────┬─────┬───────┘
                             │     │
               ┌─────────────▼┐   ┌▼──────────────┐
               │    Athena    │   │   SageMaker   │
               │  (queries    │   │  (notebooks   │
               │   SQL)       │   │   ML)         │
               └─────────────┬┘   └┬──────────────┘
                             │     │
                    ┌────────▼─────▼────────┐
                    │      QuickSight       │
                    │  (dashboards e KPIs)  │
                    └───────────────────────┘
```

---

## 📁 Estrutura do Projeto

```
mack-project-infra/
│
├── main.tf                         # Entry point — chama todos os módulos
├── variables.tf                    # Variáveis globais
├── outputs.tf                      # Outputs de todos os módulos
├── terraform.tfvars                # Valores para ambiente DEV
│
├── src/                            # Lambda 1 — Yahoo Finance → Kinesis
│   ├── handler.py                  #   Busca ~400-500 tickers da B3 dinamicamente
│   └── requirements.txt            #   yfinance, pandas, requests, boto3
│
├── src_b3_historico/               # Lambda 2 — Carga Histórica B3
│   ├── handler.py                  #   Baixa 10 anos de COTAHIST em paralelo
│   └── requirements.txt            #   requests, boto3
│
├── src_b3_fechamento/              # Lambda 3 — Fechamento Diário B3
│   ├── handler.py                  #   Atualiza ano corrente todo dia útil 19h
│   └── requirements.txt            #   requests, boto3
│
└── modules/
    ├── s3/                         # 6 Buckets: SOR, SOT, SPEC, Scripts, Athena, SageMaker
    ├── glue/                       # Data Catalog, 3 Crawlers, 2 Jobs ETL, Workflow
    ├── kinesis/                    # Data Stream + Firehose
    ├── athena/                     # Workgroup + 4 queries salvas
    ├── sagemaker/                  # Notebook Instance
    ├── lambda/                     # Lambda Yahoo Finance + Layer + EventBridge
    └── lambda_b3/                  # Lambda Histórico + Lambda Fechamento + Layer
```

---

## 🚀 Deploy no AWS Cloud Shell

### 1. Abrir o Cloud Shell
No console AWS, clique no ícone do Cloud Shell (canto superior direito).

### 2. Clonar o projeto
```bash
git clone https://github.com/rocribeiro/mack-project-infra.git
cd mack-project-infra
```

### 3. Instalar o Terraform
```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install terraform -y
terraform -version
```

### 4. Aplicar a infraestrutura
```bash
terraform init
terraform plan
terraform apply    # confirmar com "yes"
```

> ⚠️ O `terraform apply` vai:
> 1. Criar toda a infraestrutura AWS
> 2. Instalar dependências Python via `pip` e empacotar as Layers
> 3. **Disparar automaticamente a carga histórica** dos últimos 10 anos da B3 em background

### 5. Destruir (ambiente dev)
```bash
terraform destroy
```

---

## ⚙️ Configurações por Ambiente

Edite o `terraform.tfvars` conforme o ambiente:

| Variável | Dev | Prod |
|---|---|---|
| `kinesis_stream_shard_count` | 1 | 4+ |
| `glue_worker_type` | G.1X | G.2X |
| `glue_number_of_workers` | 2 | 10 |
| `sagemaker_instance_type` | ml.t3.medium | ml.m5.xlarge |
| `anos_historico` | 10 | 10 |
| `lambda_yf_max_workers` | 8 | 8 |

---

## 📦 Recursos Criados

| Recurso | Nome | Descrição |
|---|---|---|
| **S3** | `b3-datalake-dev-sor` | Bronze — dados brutos B3 + cotações live |
| **S3** | `b3-datalake-dev-sot` | Silver — dados limpos e padronizados |
| **S3** | `b3-datalake-dev-spec` | Gold — features e dados analíticos |
| **S3** | `b3-datalake-dev-glue-scripts` | Scripts ETL do Glue |
| **S3** | `b3-datalake-dev-athena-results` | Resultados de queries Athena |
| **S3** | `b3-datalake-dev-sagemaker` | Dados e modelos SageMaker |
| **S3** | `b3-datalake-dev-lambda-code` | Pacotes .zip das Lambdas Yahoo |
| **S3** | `b3-datalake-dev-lambda-b3-code` | Pacotes .zip das Lambdas B3 |
| **Lambda** | `b3-datalake-dev-yahoo-to-kinesis` | Cotações ao vivo → Kinesis |
| **Lambda** | `b3-datalake-dev-b3-historico` | Carga histórica 10 anos |
| **Lambda** | `b3-datalake-dev-b3-fechamento-diario` | Atualização diária pós-pregão |
| **Lambda Layer** | `b3-datalake-dev-yahoo-deps` | yfinance + pandas |
| **Lambda Layer** | `b3-datalake-dev-b3-deps` | requests + boto3 |
| **Kinesis Stream** | `b3-datalake-dev-cotacoes-stream` | Stream de cotações ao vivo |
| **Kinesis Firehose** | `b3-datalake-dev-firehose` | Entrega cotações no S3 |
| **Glue DB** | `b3_datalake_dev_catalog` | Catálogo central de dados |
| **Glue Job** | `b3-datalake-dev-bronze-to-silver` | ETL Bronze → Silver |
| **Glue Job** | `b3-datalake-dev-silver-to-gold` | ETL Silver → Gold |
| **Glue Crawler** | `b3-datalake-dev-crawler-bronze/silver/gold` | Catalogação automática |
| **Glue Workflow** | `b3-datalake-dev-pipeline` | Orquestra todo o pipeline |
| **Athena WG** | `b3-datalake-dev-workgroup` | Workgroup de queries SQL |
| **SageMaker** | `b3-datalake-dev-notebook` | Notebook ML |
| **EventBridge** | `b3-datalake-dev-coleta-pregao` | Schedule Yahoo (5min/pregão) |
| **EventBridge** | `b3-datalake-dev-b3-fechamento-diario` | Schedule B3 (19h BRT) |
| **SQS DLQ** | `*-dlq` | Dead Letter Queue por Lambda |
| **CloudWatch** | `*-errors / *-duration` | Alarmes de monitoramento |

---

## ⏰ Schedules Automáticos

| Lambda | Horário | Frequência |
|---|---|---|
| Yahoo Finance | 09h30 BRT | Uma vez (abertura) |
| Yahoo Finance | 10h–18h BRT | A cada 5 minutos |
| B3 Fechamento | 19h00 BRT | Todo dia útil |
| B3 Histórico | — | Uma vez (no `terraform apply`) |

---

## 📝 Próximos Passos após o Deploy

### 1. Upload dos Scripts Glue ETL
```bash
aws s3 cp scripts/bronze_to_silver.py s3://b3-datalake-dev-glue-scripts/scripts/
aws s3 cp scripts/silver_to_gold.py   s3://b3-datalake-dev-glue-scripts/scripts/
```

### 2. Testar as Lambdas manualmente
```bash
# Testar Yahoo Finance (3 tickers)
aws lambda invoke \
  --function-name b3-datalake-dev-yahoo-to-kinesis \
  --payload '{"tickers": ["PETR4.SA", "VALE3.SA", "BOVA11.SA"]}' \
  --cli-binary-format raw-in-base64-out response.json && cat response.json

# Re-rodar carga histórica forçando re-download
aws lambda invoke \
  --function-name b3-datalake-dev-b3-historico \
  --payload '{"force": true}' \
  --invocation-type Event \
  --cli-binary-format raw-in-base64-out /dev/null

# Testar fechamento diário (ignorando verificação de dia útil)
aws lambda invoke \
  --function-name b3-datalake-dev-b3-fechamento-diario \
  --payload '{"forcar_dia_util": true}' \
  --cli-binary-format raw-in-base64-out response.json && cat response.json
```

### 3. Acompanhar logs em tempo real
```bash
aws logs tail /aws/lambda/b3-datalake-dev-b3-historico --follow
aws logs tail /aws/lambda/b3-datalake-dev-yahoo-to-kinesis --follow
```

### 4. Configurar QuickSight
- Console AWS → QuickSight → conectar ao Athena workgroup `b3-datalake-dev-workgroup`

---

## 💰 Estimativa de Custo (Dev/Mês)

| Serviço | Custo Estimado |
|---|---|
| S3 (8 buckets, ~50GB histórico) | ~$1.20 |
| Lambda Yahoo (5min × 8h × 22 dias) | ~$0.05 |
| Lambda B3 Fechamento (22 execuções/mês) | ~$0.02 |
| Lambda B3 Histórico (one-shot) | ~$0.10 |
| Kinesis Stream (1 shard) | ~$10.80 |
| Kinesis Firehose | ~$0.029/GB |
| Glue (2 jobs, 2h/mês) | ~$2.20 |
| Athena (~1TB escaneado) | ~$5.00 |
| SageMaker ml.t3.medium (parado) | $0.00 |
| **Total estimado** | **~$20-25/mês** |

> 💡 Sem o DMS (~$20/mês), o custo total caiu pela metade.
> Desligue o SageMaker quando não estiver usando.
