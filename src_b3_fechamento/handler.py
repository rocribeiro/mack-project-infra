"""
Lambda: Atualização Diária B3 → S3 SOR (Bronze)
Projeto: B3 DataLake - MBA Mackenzie

Descrição:
  Roda todo dia útil após o fechamento da B3 (~19h BRT / 22h UTC).
  Baixa o ZIP do ano corrente (ex: COTAHIST_A2026.ZIP), que a B3
  atualiza com os dados do pregão do dia, e substitui o arquivo
  no S3 SOR.

  Diferente da Lambda histórica:
    - Sempre re-baixa (não usa cache)
    - Só processa 1 arquivo (ano corrente)
    - Mais rápido — executa em segundos

  Após o upload, dispara o Glue Workflow para atualizar Silver e Gold.

Variáveis de ambiente:
  S3_BUCKET_SOR     — bucket destino (Bronze/SOR)
  S3_PREFIX         — prefixo no bucket (default: b3-series-historicas)
  GLUE_WORKFLOW     — nome do Glue Workflow a disparar após upload
  AWS_REGION        — região AWS (default: us-east-1)
"""

import io
import json
import logging
import os
import time
import zipfile
from datetime import datetime, timezone

import boto3
import requests
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── Configurações ────────────────────────────────────────────
S3_BUCKET_SOR  = os.environ["S3_BUCKET_SOR"]
S3_PREFIX      = os.environ.get("S3_PREFIX", "b3-series-historicas")
GLUE_WORKFLOW  = os.environ.get("GLUE_WORKFLOW", "")
AWS_REGION     = os.environ.get("AWS_REGION", "us-east-1")

B3_URL_TEMPLATE  = "https://bvmf.bmfbovespa.com.br/InstDados/SerHist/COTAHIST_A{ano}.ZIP"
DOWNLOAD_TIMEOUT = 300   # segundos
CHUNK_SIZE       = 8 * 1024 * 1024  # 8 MB

# ─── Clientes AWS (singletons) ────────────────────────────────
_s3   = None
_glue = None

def get_s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=AWS_REGION)
    return _s3

def get_glue():
    global _glue
    if _glue is None:
        _glue = boto3.client("glue", region_name=AWS_REGION)
    return _glue


# ─── Verifica se hoje é dia útil (B3 fechada nos feriados) ───

FERIADOS_NACIONAIS = {
    # Feriados nacionais fixos (MM-DD)
    "01-01",  # Confraternização Universal
    "04-21",  # Tiradentes
    "05-01",  # Dia do Trabalho
    "09-07",  # Independência do Brasil
    "10-12",  # N. Sra. Aparecida
    "11-02",  # Finados
    "11-15",  # Proclamação da República
    "11-20",  # Consciência Negra
    "12-25",  # Natal
}

def is_dia_util() -> bool:
    """
    Verifica se hoje é dia útil (seg-sex) e não é feriado nacional fixo.
    Feriados móveis (Carnaval, Sexta-Santa, Corpus Christi) não são
    verificados aqui — nesse caso a Lambda roda mas a B3 não atualizou
    o arquivo, o que é tratado graciosamente.
    """
    agora = datetime.now(timezone.utc)
    # Converte para BRT (UTC-3)
    from datetime import timedelta
    agora_brt = agora - timedelta(hours=3)

    # Fim de semana
    if agora_brt.weekday() >= 5:  # 5=sábado, 6=domingo
        return False

    # Feriados fixos
    data_mmdd = agora_brt.strftime("%m-%d")
    if data_mmdd in FERIADOS_NACIONAIS:
        return False

    return True


# ─── Download, descompactação e upload ───────────────────────

def baixar_e_salvar_ano(ano: int) -> dict:
    """
    Baixa COTAHIST_A{ano}.ZIP da B3, extrai o TXT e faz upload para o S3.
    Sempre sobrescreve o arquivo existente (sem verificação de cache).
    """
    url    = B3_URL_TEMPLATE.format(ano=ano)
    s3_key = f"{S3_PREFIX}/ano={ano}/COTAHIST_A{ano}.TXT"
    t0     = time.time()

    logger.info(f"Baixando {url}...")

    # ── Download streaming ──
    try:
        resp = requests.get(url, stream=True, timeout=DOWNLOAD_TIMEOUT)
        resp.raise_for_status()
    except requests.exceptions.HTTPError as e:
        if hasattr(resp, "status_code") and resp.status_code == 404:
            return {
                "status":   "nao_encontrado",
                "mensagem": f"HTTP 404 — B3 ainda não publicou o arquivo de {ano}",
                "ano":      ano,
            }
        raise
    except requests.exceptions.RequestException as e:
        return {"status": "erro_download", "mensagem": str(e), "ano": ano}

    # ── Lê chunks para buffer ──
    buffer_zip = io.BytesIO()
    for chunk in resp.iter_content(chunk_size=CHUNK_SIZE):
        if chunk:
            buffer_zip.write(chunk)

    tamanho_zip = buffer_zip.tell()
    logger.info(f"ZIP baixado: {tamanho_zip / 1024 / 1024:.1f} MB")

    # ── Descompacta em memória ──
    buffer_zip.seek(0)
    try:
        with zipfile.ZipFile(buffer_zip) as zf:
            nomes_txt = [n for n in zf.namelist() if n.upper().endswith(".TXT")]
            if not nomes_txt:
                raise ValueError(f"Nenhum .TXT no ZIP. Conteúdo: {zf.namelist()}")
            nome_txt    = nomes_txt[0]
            buffer_txt  = io.BytesIO(zf.read(nome_txt))
            tamanho_txt = buffer_txt.getbuffer().nbytes
            logger.info(f"TXT extraído: {nome_txt} ({tamanho_txt / 1024 / 1024:.1f} MB)")
    except zipfile.BadZipFile as e:
        return {"status": "erro_zip_corrompido", "mensagem": str(e), "ano": ano}

    # ── Upload para o S3 ──
    buffer_txt.seek(0)
    agora_iso = datetime.now(timezone.utc).isoformat()

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
                "processado_em": agora_iso,
                "tipo":          "fechamento_diario",
            },
        },
    )

    elapsed = round(time.time() - t0, 1)
    logger.info(f"Upload concluído: s3://{S3_BUCKET_SOR}/{s3_key} em {elapsed}s")

    # ── Salva metadata ──
    meta_key = f"{S3_PREFIX}/ano={ano}/metadata.json"
    get_s3().put_object(
        Bucket=S3_BUCKET_SOR,
        Key=meta_key,
        Body=json.dumps({
            "ano":             ano,
            "status":          "sucesso",
            "tipo":            "fechamento_diario",
            "tamanho_zip_mb":  round(tamanho_zip / 1024 / 1024, 2),
            "tamanho_txt_mb":  round(tamanho_txt / 1024 / 1024, 2),
            "s3_key":          s3_key,
            "atualizado_em":   agora_iso,
        }, ensure_ascii=False),
        ContentType="application/json",
    )

    return {
        "status":          "sucesso",
        "ano":             ano,
        "s3_key":          s3_key,
        "tamanho_zip_mb":  round(tamanho_zip / 1024 / 1024, 2),
        "tamanho_txt_mb":  round(tamanho_txt / 1024 / 1024, 2),
        "elapsed_s":       elapsed,
    }


# ─── Dispara o Glue Workflow ──────────────────────────────────

def disparar_glue_workflow() -> str | None:
    """
    Dispara o pipeline Glue (Bronze → Silver → Gold) após atualização.
    Retorna o run_id do workflow ou None se não configurado.
    """
    if not GLUE_WORKFLOW:
        logger.info("GLUE_WORKFLOW não configurado — pulando trigger do Glue.")
        return None

    try:
        resp   = get_glue().start_workflow_run(Name=GLUE_WORKFLOW)
        run_id = resp["RunId"]
        logger.info(f"Glue Workflow '{GLUE_WORKFLOW}' disparado. Run ID: {run_id}")
        return run_id
    except ClientError as e:
        logger.warning(f"Erro ao disparar Glue Workflow: {e}")
        return None


# ─── Handler ──────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Parâmetros aceitos no event:
      ano           — ano específico para baixar (default: ano atual)
      forcar_dia_util — false para rodar mesmo em feriado/fim de semana (testes)
    """
    ano_alvo     = int(event.get("ano", datetime.now().year))
    forcar       = event.get("forcar_dia_util", False)

    # ── Verifica dia útil ──
    if not forcar and not is_dia_util():
        logger.info("Hoje não é dia útil. Encerrando sem ação.")
        return {
            "statusCode": 200,
            "body": {"message": "Não é dia útil — nenhuma ação executada."},
        }

    logger.info(
        f"Atualização diária B3 | "
        f"Ano: {ano_alvo} | "
        f"Bucket: {S3_BUCKET_SOR} | "
        f"Glue: {GLUE_WORKFLOW or 'não configurado'}"
    )

    # ── Baixa e salva no S3 ──
    resultado = baixar_e_salvar_ano(ano_alvo)

    # ── Dispara pipeline Glue se download teve sucesso ──
    glue_run_id = None
    if resultado["status"] == "sucesso":
        glue_run_id = disparar_glue_workflow()

    return {
        "statusCode": 200 if resultado["status"] == "sucesso" else 500,
        "body": {
            **resultado,
            "glue_workflow_run_id": glue_run_id,
        },
    }
