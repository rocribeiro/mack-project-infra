# 🏗️ Terraform - B3 Data Lake
## Solução de Consulta Financeira para Sugestão de Alocação de Carteira
**MBA Engenharia de Dados — Universidade Presbiteriana Mackenzie**

---

## 📐 Arquitetura Implementada

```
Fontes de Dados
├── B3 Séries Históricas (CSV) ──► DMS ──────────────────────┐
└── API Yahoo Finance (live) ─────► Kinesis Data Stream       │
                                        └─► Kinesis Firehose  │
                                                              ▼
                                              S3 Bronze / SOR
                                              (dados brutos)
                                                    │
                                              AWS Glue ETL
                                          (bronze_to_silver.py)
                                                    │
                                              S3 Silver / SOT
                                              (dados tratados)
                                                    │
                                              AWS Glue ETL
                                          (silver_to_gold.py)
                                                    │
                                              S3 Gold / SPEC
                                          (features, agregações)
                                            ┌──────┴──────┐
                                         Athena       SageMaker
                                       (queries)     (modelos ML)
                                            │              │
                                        QuickSight    Recomendações
                                       (dashboards)  de Carteira
```

**Glue Data Catalog** — Centraliza metadados de todas as camadas

---

## 📁 Estrutura do Projeto

```
terraform-b3-datalake/
├── main.tf                     # Entry point - chama todos os módulos
├── variables.tf                # Variáveis globais
├── outputs.tf                  # Outputs de todos os módulos
├── terraform.tfvars            # Valores para ambiente dev
└── modules/
    ├── iam/                    # Roles e policies (Glue, Kinesis, DMS, SageMaker)
    ├── s3/                     # Buckets: SOR, SOT, SPEC, scripts, athena-results
    ├── glue/                   # Data Catalog, Crawlers, Jobs ETL, Workflow
    ├── kinesis/                # Data Stream + Firehose (cotações ao vivo)
    ├── athena/                 # Workgroup + queries salvas de análise
    ├── sagemaker/              # Notebook Instance para modelagem preditiva
    └── dms/                    # Replication Instance + Tasks (ingestão B3)
```

---

## 🚀 Como Usar

### Pré-requisitos

```bash
# Instalar Terraform >= 1.5.0
brew install terraform   # macOS
# ou baixe em: https://developer.hashicorp.com/terraform/downloads

# Configurar credenciais AWS
aws configure
# AWS Access Key ID: <sua-key>
# AWS Secret Access Key: <seu-secret>
# Default region: us-east-1
```

### Deploy

```bash
# 1. Entrar na pasta do projeto
cd terraform-b3-datalake

# 2. Inicializar o Terraform
terraform init

# 3. Verificar o plano de execução
terraform plan

# 4. Aplicar a infraestrutura
terraform apply

# 5. Confirmar digitando "yes"
```

### Destruir (ambiente dev)

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
| `dms_replication_instance_class` | dms.t3.micro | dms.r5.large |

---

## 📦 Recursos Criados

| Recurso | Nome | Descrição |
|---|---|---|
| S3 | `b3-datalake-dev-sor` | Camada Bronze - dados brutos |
| S3 | `b3-datalake-dev-sot` | Camada Silver - dados tratados |
| S3 | `b3-datalake-dev-spec` | Camada Gold - dados analíticos |
| S3 | `b3-datalake-dev-glue-scripts` | Scripts ETL Glue |
| S3 | `b3-datalake-dev-athena-results` | Resultados de queries Athena |
| Glue DB | `b3_datalake_dev_catalog` | Catálogo de dados central |
| Glue Job | `b3-datalake-dev-bronze-to-silver` | ETL Bronze → Silver |
| Glue Job | `b3-datalake-dev-silver-to-gold` | ETL Silver → Gold |
| Glue Crawler | `b3-datalake-dev-crawler-bronze/silver/gold` | Catalogação automática |
| Kinesis Stream | `b3-datalake-dev-cotacoes-stream` | Cotações ao vivo |
| Kinesis Firehose | `b3-datalake-dev-firehose` | Entrega ao S3 |
| Athena WG | `b3-datalake-dev-workgroup` | Workgroup de queries |
| SageMaker | `b3-datalake-dev-notebook` | Modelagem preditiva |
| DMS Instance | `b3-datalake-dev-dms` | Replicação B3 → S3 |

---

## 📝 Próximos Passos Manuais

### 1. Upload dos Scripts Glue
Após o `terraform apply`, faça upload dos scripts ETL:
```bash
aws s3 cp scripts/bronze_to_silver.py s3://b3-datalake-dev-glue-scripts/scripts/
aws s3 cp scripts/silver_to_gold.py   s3://b3-datalake-dev-glue-scripts/scripts/
```

### 2. Download e Ingestão das Séries B3
```bash
# Baixe os arquivos ZIP em:
# https://www.b3.com.br/pt_br/market-data-e-indices/servicos-de-dados/market-data/historico/mercado-a-vista/series-historicas/

# Descompacte e faça upload para o bucket staging:
aws s3 cp COTAHIST_A2023.TXT s3://b3-datalake-dev-sor/b3-series-historicas/
```

### 3. Configurar QuickSight
O QuickSight não é gerenciado por Terraform neste projeto (requer subscription manual).
- Acesse o console AWS → QuickSight
- Conecte ao Athena workgroup `b3-datalake-dev-workgroup`
- Crie os dashboards de análise de carteiras

### 4. Produção em Python para Kinesis
```python
import boto3, yfinance as yf, json
from datetime import datetime

kinesis = boto3.client('kinesis', region_name='us-east-1')

def enviar_cotacao(ticker):
    dados = yf.Ticker(ticker).history(period='1d')
    record = {
        "ticker": ticker,
        "preco": float(dados['Close'].iloc[-1]),
        "timestamp": datetime.now().isoformat()
    }
    kinesis.put_record(
        StreamName='b3-datalake-dev-cotacoes-stream',
        Data=json.dumps(record),
        PartitionKey=ticker
    )
```

---

## 💰 Estimativa de Custo (Dev/Mês)

| Serviço | Custo Estimado |
|---|---|
| S3 (5 buckets, ~10GB) | ~$0.25 |
| Glue (2 jobs, 2h/mês) | ~$2.20 |
| Kinesis Stream (1 shard) | ~$10.80 |
| Kinesis Firehose | ~$0.029/GB |
| Athena (por TB escaneado) | ~$5/TB |
| SageMaker ml.t3.medium (parado) | $0 |
| DMS t3.micro (20GB) | ~$20 |
| **Total estimado** | **~$35-50/mês** |

> 💡 Ligue o SageMaker apenas quando for trabalhar. Desligue o DMS quando não estiver fazendo ingestão.
