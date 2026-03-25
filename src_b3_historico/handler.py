"""
Lambda: Carga Histórica B3 → S3 SOR (Bronze)
Projeto: B3 DataLake - MBA Mackenzie

FIX: Out of Memory
  Problema anterior: ZIP (~55MB) era descompactado em io.BytesIO na RAM.
  O TXT resultante tem ~500-600MB — estourava o heap com Lambda de 1024MB.

  Solução: usa /tmp (512MB de disco grátis na Lambda) como intermediário.
    1. Baixa ZIP em streaming direto para /tmp  → sem RAM extra
    2. Descompacta para /tmp                   → sem RAM extra
    3. upload_file() do boto3 (multipart auto)  → sem RAM extra
    4. Limpa /tmp após upload

  Memória efetiva utilizada: ~150MB (runtime + boto3 + requests)
  /tmp utilizado: ~600MB por ano (ZIP + TXT, apagados logo após upload)

  Para processar múltiplos anos em paralelo com MAX_WORKERS > 1,
  cada worker usa arquivos com sufixo de PID para evitar conflito.

Variáveis de ambiente:
  S3_BUCKET_SOR   — bucket destino (Bronze/SOR)
  ANOS_HISTORICO  — quantos anos atrás (default: 10)
  S3_PREFIX       — prefixo no bucket (default: b3-series-historicas)
  FORCE_DOWNLOAD  — "true" para ignorar cache e re-baixar tudo
  MAX_WORKERS     — paralelismo (default: 2; >2 pode esgotar /tmp)
"""

import io
import json
import logging
import os
import tempfile
import threading
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

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
# ATENÇÃO: mantenha MAX_WORKERS <= 2 para não esgotar /tmp (512MB).
# Cada ano ocupa ~600MB em /tmp durante o processamento.
# Com 2 workers: pico de ~1.2GB → seguro dentro do limite de /tmp da Lambda.
MAX_WORKERS    = int(os.environ.get("MAX_WORKERS", "2"))
AWS_REGION     = os.environ.get("AWS_REGION", "us-east-1")

B3_URL_TEMPLATE  = "https://bvmf.bmfbovespa.com.br/InstDados/SerHist/COTAHIST_A{ano}.ZIP"
DOWNLOAD_TIMEOUT = 300   # segundos
CHUNK_SIZE       = 8 * 1024 * 1024  # 8 MB — tamanho do chunk de stream

# Lock para log de progresso de download (múltiplos threads)
_log_lock = threading.Lock()

# ─── Cliente S3 (thread-safe singleton por thread) ────────────
_s3_local = threading.local()

def get_s3():
    if not hasattr(_s3_local, "client"):
        _s3_local.client = boto3.client("s3", region_name=AWS_REGION)
    return _s3_local.client


# ─── Helpers ──────────────────────────────────────────────────

def s3_key_for_year(ano: int) -> str:
    return f"{S3_PREFIX}/ano={ano}/COTAHIST_A{ano}.TXT"


def arquivo_existe_no_s3(ano: int) -> bool:
    if FORCE_DOWNLOAD:
        return False
    try:
        get_s3().head_object(Bucket=S3_BUCKET_SOR, Key=s3_key_for_year(ano))
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey"):
            return False
        raise


def salvar_metadata(ano: int, tamanho_bytes: int, status: str, mensagem: str = ""):
    meta_key = f"{S3_PREFIX}/ano={ano}/metadata.json"
    meta = {
        "ano":           ano,
        "status":        status,
        "tamanho_bytes": tamanho_bytes,
        "mensagem":      mensagem,
        "atualizado_em": datetime.now(timezone.utc).isoformat(),
        "s3_key":        s3_key_for_year(ano),
    }
    get_s3().put_object(
        Bucket=S3_BUCKET_SOR,
        Key=meta_key,
        Body=json.dumps(meta, ensure_ascii=False),
        ContentType="application/json",
    )


def _tmp_path(suffix: str) -> Path:
    """Retorna um caminho único em /tmp usando thread id para evitar colisões."""
    tid = threading.get_ident()
    return Path(tempfile.gettempdir()) / f"b3_{tid}_{suffix}"


def _free_tmp_mb() -> float:
    """Retorna espaço livre em /tmp em MB."""
    st = os.statvfs(tempfile.gettempdir())
    return st.f_bavail * st.f_frsize / 1024 / 1024


# ─── Processamento de um ano ──────────────────────────────────

def processar_ano(ano: int) -> dict:
    """
    1. Verifica cache no S3
    2. Baixa ZIP em streaming para /tmp  (sem RAM)
    3. Descompacta TXT em /tmp           (sem RAM)
    4. Faz upload multipart para S3      (sem RAM)
    5. Remove arquivos temporários
    """
    url      = B3_URL_TEMPLATE.format(ano=ano)
    s3_key   = s3_key_for_year(ano)
    zip_path = _tmp_path(f"{ano}.zip")
    txt_path = _tmp_path(f"{ano}.txt")
    resultado = {"ano": ano, "status": "pendente", "tamanho_bytes": 0}

    try:
        # ── 0. Cache ──────────────────────────────────────────
        if arquivo_existe_no_s3(ano):
            logger.info(f"[{ano}] Já existe no S3, pulando. (FORCE_DOWNLOAD=true para re-baixar)")
            return {**resultado, "status": "ignorado_cache"}

        livre_mb = _free_tmp_mb()
        logger.info(f"[{ano}] /tmp livre: {livre_mb:.0f} MB | Iniciando: {url}")

        if livre_mb < 700:
            logger.warning(f"[{ano}] /tmp com pouco espaço ({livre_mb:.0f}MB). Pode falhar na descompactação.")

        t0 = time.time()

        # ── 1. Download ZIP → /tmp (streaming, sem RAM) ───────
        try:
            resp = requests.get(url, stream=True, timeout=DOWNLOAD_TIMEOUT)
            resp.raise_for_status()
        except requests.exceptions.HTTPError:
            if resp.status_code == 404:
                logger.warning(f"[{ano}] HTTP 404 — arquivo não disponível na B3.")
                return {**resultado, "status": "nao_encontrado",
                        "mensagem": f"HTTP 404 em {url}"}
            raise
        except requests.exceptions.RequestException as e:
            return {**resultado, "status": "erro_download", "mensagem": str(e)}

        tamanho_zip = 0
        with open(zip_path, "wb") as f_zip:
            for chunk in resp.iter_content(chunk_size=CHUNK_SIZE):
                if chunk:
                    f_zip.write(chunk)
                    tamanho_zip += len(chunk)

        elapsed_dl = round(time.time() - t0, 1)
        with _log_lock:
            logger.info(f"[{ano}] ZIP salvo em /tmp: {tamanho_zip / 1024**2:.1f} MB em {elapsed_dl}s")

        # ── 2. Descompacta ZIP → TXT em /tmp (sem RAM) ────────
        t1 = time.time()
        try:
            with zipfile.ZipFile(zip_path) as zf:
                nomes_txt = [n for n in zf.namelist() if n.upper().endswith(".TXT")]
                if not nomes_txt:
                    raise ValueError(f"Nenhum .TXT no ZIP. Conteúdo: {zf.namelist()}")

                nome_txt = nomes_txt[0]
                logger.info(f"[{ano}] Extraindo: {nome_txt}")

                # Extrai direto para /tmp sem passar pela RAM
                with zf.open(nome_txt) as src, open(txt_path, "wb") as dst:
                    while True:
                        bloco = src.read(CHUNK_SIZE)
                        if not bloco:
                            break
                        dst.write(bloco)

        except zipfile.BadZipFile as e:
            logger.error(f"[{ano}] ZIP corrompido: {e}")
            return {**resultado, "status": "erro_zip_corrompido", "mensagem": str(e)}
        finally:
            # Remove o ZIP imediatamente — libera /tmp antes do upload
            if zip_path.exists():
                zip_path.unlink()
                logger.info(f"[{ano}] ZIP removido de /tmp")

        tamanho_txt = txt_path.stat().st_size
        elapsed_ex  = round(time.time() - t1, 1)
        logger.info(
            f"[{ano}] TXT extraído: {tamanho_txt / 1024**2:.1f} MB em {elapsed_ex}s | "
            f"/tmp livre após extração: {_free_tmp_mb():.0f} MB"
        )

        # ── 3. Upload multipart S3 (boto3 gerencia chunks) ────
        t2 = time.time()
        get_s3().upload_file(
            str(txt_path),
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
        elapsed_up = round(time.time() - t2, 1)
        elapsed    = round(time.time() - t0, 1)
        logger.info(f"[{ano}] ✅ Upload concluído em {elapsed_up}s | Total: {elapsed}s")

        salvar_metadata(ano, tamanho_txt, "sucesso")

        return {
            **resultado,
            "status":         "sucesso",
            "tamanho_zip_mb": round(tamanho_zip / 1024**2, 2),
            "tamanho_txt_mb": round(tamanho_txt / 1024**2, 2),
            "elapsed_s":      elapsed,
            "s3_key":         s3_key,
        }

    finally:
        # Garante limpeza de /tmp mesmo em caso de erro
        for p in (zip_path, txt_path):
            if p.exists():
                p.unlink()
                logger.debug(f"[{ano}] Limpeza /tmp: {p.name} removido")


# ─── Handler ──────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Parâmetros aceitos no event:
      anos        — lista explícita de anos (ex: [2020, 2021, 2022])
      anos_atras  — quantos anos baixar a partir do ano atual
      force       — true para re-baixar mesmo que já exista no S3
    """
    global FORCE_DOWNLOAD

    if event.get("force"):
        FORCE_DOWNLOAD = True

    ano_atual = datetime.now().year

    if event.get("anos"):
        anos_para_processar = sorted(event["anos"])
    else:
        n = int(event.get("anos_atras", ANOS_HISTORICO))
        anos_para_processar = list(range(ano_atual - n, ano_atual))

    logger.info(
        f"Iniciando carga histórica B3 | "
        f"Anos: {anos_para_processar} | "
        f"Workers: {MAX_WORKERS} | "
        f"Bucket: {S3_BUCKET_SOR} | "
        f"Force: {FORCE_DOWNLOAD} | "
        f"/tmp livre: {_free_tmp_mb():.0f} MB"
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
                logger.info(f"[{ano}] → {res['status']}")
            except Exception as e:
                logger.exception(f"[{ano}] Erro não tratado: {e}")
                resultados.append({"ano": ano, "status": "erro_fatal", "mensagem": str(e)})

    resultados.sort(key=lambda r: r["ano"])

    resumo = {
        "total":           len(resultados),
        "sucesso":         sum(1 for r in resultados if r["status"] == "sucesso"),
        "ignorados":       sum(1 for r in resultados if r["status"] == "ignorado_cache"),
        "erros":           sum(1 for r in resultados if "erro" in r["status"] or r["status"] == "nao_encontrado"),
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