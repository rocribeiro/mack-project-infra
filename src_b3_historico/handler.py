"""
Lambda: Carga Histórica B3 → S3 SOR (Bronze)
Projeto: B3 DataLake - MBA Mackenzie

Descrição:
  Baixa os arquivos COTAHIST_A{YYYY}.ZIP da B3 para os últimos N anos
  (padrão: 10 anos) e salva os arquivos .TXT descompactados no S3 SOR,
  particionados por ano.

  URL padrão B3:
    https://bvmf.bmfbovespa.com.br/InstDados/SerHist/COTAHIST_A{YYYY}.ZIP

Execução:
  - Invocação manual (one-shot) ou via EventBridge (carga inicial)
  - Usa ThreadPoolExecutor para baixar vários anos em paralelo
  - Idempotente: verifica se o arquivo já existe no S3 antes de baixar

Variáveis de ambiente:
  S3_BUCKET_SOR   — bucket destino (Bronze/SOR)
  ANOS_HISTORICO  — quantos anos atrás (default: 10)
  S3_PREFIX       — prefixo no bucket (default: b3-series-historicas)
  FORCE_DOWNLOAD  — "true" para ignorar cache e re-baixar tudo
"""

import io
import json
import logging
import os
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import boto3
import requests
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── Configurações ────────────────────────────────────────────
S3_BUCKET_SOR  = os.environ["S3_BUCKET_SOR"]
ANOS_HISTORICO = int(os.environ.get("ANOS_HISTORICO", "10"))
S3_PREFIX      = os.environ.get("S3_PREFIX", "b3-series-historicas")
FORCE_DOWNLOAD = os.environ.get("FORCE_DOWNLOAD", "false").lower() == "true"
MAX_WORKERS    = int(os.environ.get("MAX_WORKERS", "4"))  # paralelo por ano
AWS_REGION     = os.environ.get("AWS_REGION", "us-east-1")

B3_URL_TEMPLATE = "https://bvmf.bmfbovespa.com.br/InstDados/SerHist/COTAHIST_A{ano}.ZIP"

DOWNLOAD_TIMEOUT = 300  # segundos — arquivos anuais são ~100MB
CHUNK_SIZE       = 8 * 1024 * 1024  # 8 MB por chunk no stream

# ─── Cliente S3 (singleton) ───────────────────────────────────
_s3 = None

def get_s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=AWS_REGION)
    return _s3


# ─── Helpers ──────────────────────────────────────────────────

def s3_key_for_year(ano: int) -> str:
    """Caminho no S3 onde o arquivo do ano será salvo."""
    return f"{S3_PREFIX}/ano={ano}/COTAHIST_A{ano}.TXT"


def arquivo_existe_no_s3(ano: int) -> bool:
    """Verifica se o arquivo do ano já foi carregado no S3."""
    if FORCE_DOWNLOAD:
        return False
    try:
        get_s3().head_object(Bucket=S3_BUCKET_SOR, Key=s3_key_for_year(ano))
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "404":
            return False
        raise


def salvar_metadata(ano: int, tamanho_bytes: int, status: str, mensagem: str = ""):
    """Salva um arquivo JSON de metadados ao lado do TXT."""
    meta_key = f"{S3_PREFIX}/ano={ano}/metadata.json"
    meta = {
        "ano":            ano,
        "status":         status,
        "tamanho_bytes":  tamanho_bytes,
        "mensagem":       mensagem,
        "atualizado_em":  datetime.now(timezone.utc).isoformat(),
        "s3_key":         s3_key_for_year(ano),
    }
    get_s3().put_object(
        Bucket=S3_BUCKET_SOR,
        Key=meta_key,
        Body=json.dumps(meta, ensure_ascii=False),
        ContentType="application/json",
    )


# ─── Download e upload de um ano ──────────────────────────────

def processar_ano(ano: int) -> dict:
    """
    Baixa o ZIP da B3 para um ano específico, descompacta em memória
    e faz upload do .TXT para o S3 SOR.

    Retorna dict com resultado da operação.
    """
    url      = B3_URL_TEMPLATE.format(ano=ano)
    s3_key   = s3_key_for_year(ano)
    resultado = {"ano": ano, "status": "pendente", "tamanho_bytes": 0}

    # ── Verifica cache ──
    if arquivo_existe_no_s3(ano):
        logger.info(f"[{ano}] Arquivo já existe no S3, pulando. (use FORCE_DOWNLOAD=true para re-baixar)")
        resultado["status"]   = "ignorado_cache"
        return resultado

    logger.info(f"[{ano}] Iniciando download: {url}")
    t_inicio = time.time()

    # ── Download do ZIP em streaming para memória ──
    try:
        resp = requests.get(url, stream=True, timeout=DOWNLOAD_TIMEOUT)
        resp.raise_for_status()
    except requests.exceptions.HTTPError as e:
        # 404 = arquivo do ano ainda não disponível (ex: ano futuro)
        if resp.status_code == 404:
            logger.warning(f"[{ano}] Arquivo não encontrado na B3 (HTTP 404). Ano disponível?")
            resultado["status"]  = "nao_encontrado"
            resultado["mensagem"] = f"HTTP 404 em {url}"
            return resultado
        raise
    except requests.exceptions.RequestException as e:
        logger.error(f"[{ano}] Erro de conexão: {e}")
        resultado["status"]  = "erro_download"
        resultado["mensagem"] = str(e)
        return resultado

    # ── Lê o ZIP em memória chunk a chunk ──
    buffer_zip = io.BytesIO()
    total_baixado = 0
    for chunk in resp.iter_content(chunk_size=CHUNK_SIZE):
        if chunk:
            buffer_zip.write(chunk)
            total_baixado += len(chunk)

    tamanho_zip = buffer_zip.tell()
    logger.info(f"[{ano}] ZIP baixado: {tamanho_zip / 1024 / 1024:.1f} MB em {time.time() - t_inicio:.1f}s")

    # ── Descompacta o ZIP em memória ──
    buffer_zip.seek(0)
    try:
        with zipfile.ZipFile(buffer_zip) as zf:
            # O ZIP da B3 contém exatamente 1 arquivo .TXT
            nomes = [n for n in zf.namelist() if n.upper().endswith(".TXT")]
            if not nomes:
                raise ValueError(f"Nenhum .TXT encontrado no ZIP de {ano}. Conteúdo: {zf.namelist()}")

            nome_txt = nomes[0]
            logger.info(f"[{ano}] Extraindo: {nome_txt}")

            buffer_txt = io.BytesIO(zf.read(nome_txt))
            tamanho_txt = buffer_txt.getbuffer().nbytes
    except zipfile.BadZipFile as e:
        logger.error(f"[{ano}] ZIP corrompido: {e}")
        resultado["status"]  = "erro_zip_corrompido"
        resultado["mensagem"] = str(e)
        return resultado

    # ── Upload do TXT para o S3 ──
    logger.info(f"[{ano}] Fazendo upload para s3://{S3_BUCKET_SOR}/{s3_key} ({tamanho_txt / 1024 / 1024:.1f} MB)...")

    buffer_txt.seek(0)
    get_s3().upload_fileobj(
        buffer_txt,
        S3_BUCKET_SOR,
        s3_key,
        ExtraArgs={
            "ContentType": "text/plain",
            "Metadata": {
                "ano":           str(ano),
                "fonte":         url,
                "tamanho_zip":   str(tamanho_zip),
                "tamanho_txt":   str(tamanho_txt),
                "processado_em": datetime.now(timezone.utc).isoformat(),
            },
        },
    )

    elapsed = round(time.time() - t_inicio, 1)
    logger.info(f"[{ano}] ✅ Upload concluído em {elapsed}s")

    # Salva metadados
    salvar_metadata(ano, tamanho_txt, "sucesso")

    resultado.update({
        "status":         "sucesso",
        "tamanho_zip_mb": round(tamanho_zip / 1024 / 1024, 2),
        "tamanho_txt_mb": round(tamanho_txt / 1024 / 1024, 2),
        "elapsed_s":      elapsed,
        "s3_key":         s3_key,
    })
    return resultado


# ─── Handler ──────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Parâmetros aceitos no event:
      anos       — lista explícita de anos (ex: [2020, 2021, 2022])
      anos_atras — quantos anos baixar a partir do ano atual (default: var de ambiente)
      force      — true para re-baixar mesmo que já exista no S3
    """
    global FORCE_DOWNLOAD

    # Override via event
    if event.get("force"):
        FORCE_DOWNLOAD = True

    ano_atual = datetime.now().year

    if event.get("anos"):
        anos_para_processar = sorted(event["anos"])
    else:
        n = int(event.get("anos_atras", ANOS_HISTORICO))
        # Ex: ano_atual=2026, n=10 → [2016, 2017, ..., 2025]
        # Não inclui o ano atual aqui (a outra Lambda cuida disso)
        anos_para_processar = list(range(ano_atual - n, ano_atual))

    logger.info(
        f"Iniciando carga histórica B3 | "
        f"Anos: {anos_para_processar} | "
        f"Workers: {MAX_WORKERS} | "
        f"Bucket: {S3_BUCKET_SOR} | "
        f"Force: {FORCE_DOWNLOAD}"
    )

    resultados = []
    t_total = time.time()

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(processar_ano, ano): ano for ano in anos_para_processar}
        for future in as_completed(futures):
            ano = futures[future]
            try:
                res = future.result()
                resultados.append(res)
                logger.info(f"[{ano}] Resultado: {res['status']}")
            except Exception as e:
                logger.exception(f"[{ano}] Erro não tratado: {e}")
                resultados.append({"ano": ano, "status": "erro_fatal", "mensagem": str(e)})

    # Ordena por ano para facilitar leitura
    resultados.sort(key=lambda r: r["ano"])

    resumo = {
        "total":      len(resultados),
        "sucesso":    sum(1 for r in resultados if r["status"] == "sucesso"),
        "ignorados":  sum(1 for r in resultados if r["status"] == "ignorado_cache"),
        "erros":      sum(1 for r in resultados if "erro" in r["status"] or r["status"] == "nao_encontrado"),
        "elapsed_total_s": round(time.time() - t_total, 1),
    }

    logger.info(f"Carga histórica concluída: {resumo}")

    return {
        "statusCode": 200,
        "body": {
            "resumo":     resumo,
            "resultados": resultados,
        },
    }
