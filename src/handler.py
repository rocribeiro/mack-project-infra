"""
Lambda: Yahoo Finance → Kinesis Data Stream
Projeto: B3 DataLake - MBA Mackenzie

Fluxo:
  1. Busca lista completa de ativos ativos da B3 via API pública
  2. Enriquece cada ticker com sufixo .SA para o Yahoo Finance
  3. Faz download das cotações em chunks paralelos (ThreadPoolExecutor)
  4. Publica no Kinesis Data Stream em batches de 500 (limite da API)

Suporta ~400-500 tickers ativos sem timeout de Lambda (2 min).
"""

import json
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import Any

import boto3
import requests
import yfinance as yf
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── Configurações via variáveis de ambiente ──────────────────────────────
STREAM_NAME       = os.environ["KINESIS_STREAM_NAME"]
AWS_REGION        = os.environ.get("AWS_REGION", "us-east-1")
KINESIS_BATCH     = int(os.environ.get("KINESIS_BATCH_SIZE", "500"))   # máx Kinesis PutRecords
YF_CHUNK_SIZE     = int(os.environ.get("YF_CHUNK_SIZE", "50"))         # tickers por chamada yfinance
YF_MAX_WORKERS    = int(os.environ.get("YF_MAX_WORKERS", "8"))         # threads paralelas
FETCH_PERIOD      = os.environ.get("FETCH_PERIOD", "1d")
FETCH_INTERVAL    = os.environ.get("FETCH_INTERVAL", "1m")
TICKERS_S3_BUCKET = os.environ.get("TICKERS_S3_BUCKET", "")           # fallback cache no S3
TICKERS_S3_KEY    = os.environ.get("TICKERS_S3_KEY", "config/tickers_b3.json")

# ─── URLs da API pública B3 ───────────────────────────────────────────────
B3_API_BASE = "https://sistemaswebb3-listados.b3.com.br/listedCompaniesProxy/CompanyCall"
B3_HEADERS  = {
    "User-Agent": "Mozilla/5.0 (compatible; B3DataLake/1.0)",
    "Accept":     "application/json",
}

# ─── Clientes AWS (singletons) ────────────────────────────────────────────
_kinesis = None
_s3      = None

def get_kinesis():
    global _kinesis
    if _kinesis is None:
        _kinesis = boto3.client("kinesis", region_name=AWS_REGION)
    return _kinesis

def get_s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=AWS_REGION)
    return _s3


# ─── 1. Busca dinâmica de tickers na B3 ──────────────────────────────────

def fetch_tickers_from_b3() -> list[str]:
    """
    Busca todos os ativos negociados na B3 via API pública.
    Retorna lista de tickers no formato Yahoo Finance (ex: PETR4.SA).

    Endpoints usados:
      - /GetInitialCompanies/{page}/{pageSize}/{language}
        Retorna empresas listadas com seus códigos de negociação.
      - /GetListedETF/{page}/{pageSize}/{language}
        Retorna ETFs listados.
      - /GetListedFunds/{page}/{pageSize}/{language}
        Retorna FIIs listados.
    """
    tickers = set()

    # ── Passo 1: empresas paginadas ──
    page = 1
    page_size = 120  # máximo aceito pelo endpoint
    total_pages = None

    logger.info("Buscando lista de empresas na B3...")

    while True:
        url = f"{B3_API_BASE}/GetInitialCompanies/{page}/{page_size}/pt-br"
        try:
            resp = requests.get(url, headers=B3_HEADERS, timeout=10)
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            logger.warning(f"Erro na página {page} da B3: {e}")
            break

        companies = data.get("results", [])
        if not companies:
            break

        if total_pages is None:
            total = data.get("page", {}).get("totalRecords", 0)
            total_pages = -(-total // page_size)  # ceil
            logger.info(f"Total de empresas na B3: {total} ({total_pages} páginas)")

        for company in companies:
            codes = company.get("codes", [])
            if isinstance(codes, list):
                for code in codes:
                    if code and len(code.strip()) <= 8:
                        tickers.add(f"{code.strip()}.SA")
            else:
                code = company.get("code", "")
                if code:
                    tickers.add(f"{code.strip()}.SA")

        logger.info(f"Página {page}/{total_pages} — {len(tickers)} tickers acumulados")

        if total_pages and page >= total_pages:
            break
        page += 1
        time.sleep(0.2)  # respeita rate limit da B3

    # ── Passo 2: ETFs ──
    tickers.update(_fetch_etfs_b3())

    # ── Passo 3: FIIs ──
    tickers.update(_fetch_fiis_b3())

    # ── Passo 4: índices principais (não têm .SA) ──
    indices = {"^BVSP", "^IBX50", "^IVBX"}
    tickers.update(indices)

    result = sorted(tickers)
    logger.info(f"Total de tickers coletados da B3: {len(result)}")
    return result


def _fetch_etfs_b3() -> set[str]:
    """Busca ETFs listados na B3."""
    etfs = set()
    url = f"{B3_API_BASE}/GetListedETF/1/200/pt-br"
    try:
        resp = requests.get(url, headers=B3_HEADERS, timeout=10)
        resp.raise_for_status()
        for item in resp.json().get("results", []):
            code = item.get("code", "")
            if code:
                etfs.add(f"{code.strip()}.SA")
        logger.info(f"ETFs encontrados: {len(etfs)}")
    except Exception as e:
        logger.warning(f"Erro ao buscar ETFs: {e}")
        etfs = {
            "BOVA11.SA", "SMAL11.SA", "IVVB11.SA", "HASH11.SA",
            "XFIX11.SA", "BBSD11.SA", "DIVO11.SA", "SPXI11.SA",
            "GOLD11.SA", "MATB11.SA", "ECOO11.SA",
        }
    return etfs


def _fetch_fiis_b3() -> set[str]:
    """Busca FIIs listados na B3 (paginado)."""
    fiis = set()
    page, page_size = 1, 120

    while True:
        url = f"{B3_API_BASE}/GetListedFunds/{page}/{page_size}/pt-br"
        try:
            resp = requests.get(url, headers=B3_HEADERS, timeout=10)
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            logger.warning(f"Erro ao buscar FIIs página {page}: {e}")
            break

        items = data.get("results", [])
        if not items:
            break

        for item in items:
            code = item.get("fundTicker", "") or item.get("code", "")
            if code:
                fiis.add(f"{code.strip()}.SA")

        total = data.get("page", {}).get("totalRecords", 0)
        if page * page_size >= total:
            break
        page += 1
        time.sleep(0.2)

    logger.info(f"FIIs encontrados: {len(fiis)}")
    return fiis


def get_tickers(event: dict) -> list[str]:
    """
    Resolve a lista de tickers com a seguinte prioridade:
      1. Tickers explícitos no event (invocação manual/teste)
      2. Busca dinâmica na API da B3
      3. Cache no S3 (fallback se a B3 estiver fora)
    """
    if event.get("tickers"):
        logger.info(f"Usando tickers do event: {len(event['tickers'])}")
        return event["tickers"]

    try:
        tickers = fetch_tickers_from_b3()
        if len(tickers) > 50:
            _save_tickers_cache(tickers)
            return tickers
        logger.warning("B3 retornou poucos tickers, caindo para cache S3")
    except Exception as e:
        logger.warning(f"Falha na API B3: {e}. Usando cache S3.")

    return _load_tickers_cache()


def _save_tickers_cache(tickers: list[str]):
    if not TICKERS_S3_BUCKET:
        return
    try:
        get_s3().put_object(
            Bucket=TICKERS_S3_BUCKET,
            Key=TICKERS_S3_KEY,
            Body=json.dumps({
                "tickers":    tickers,
                "updated_at": datetime.now(timezone.utc).isoformat(),
                "total":      len(tickers),
            }),
            ContentType="application/json",
        )
        logger.info(f"Cache de tickers salvo: s3://{TICKERS_S3_BUCKET}/{TICKERS_S3_KEY}")
    except Exception as e:
        logger.warning(f"Erro ao salvar cache: {e}")


def _load_tickers_cache() -> list[str]:
    if not TICKERS_S3_BUCKET:
        raise RuntimeError("TICKERS_S3_BUCKET não configurado e B3 inacessível.")
    try:
        obj  = get_s3().get_object(Bucket=TICKERS_S3_BUCKET, Key=TICKERS_S3_KEY)
        data = json.loads(obj["Body"].read())
        logger.info(f"Cache carregado: {data['total']} tickers (atualizado {data.get('updated_at')})")
        return data["tickers"]
    except Exception as e:
        raise RuntimeError(f"Falha ao carregar cache S3: {e}")


# ─── 2. Download em chunks paralelos ─────────────────────────────────────

def fetch_quotes_parallel(tickers: list[str]) -> list[dict]:
    """
    Divide os tickers em chunks de YF_CHUNK_SIZE e processa em paralelo.
    50 tickers/chunk × 8 workers → ~400 tickers em ~15-20s.
    """
    chunks = [tickers[i:i + YF_CHUNK_SIZE] for i in range(0, len(tickers), YF_CHUNK_SIZE)]
    logger.info(
        f"Processando {len(tickers)} tickers | "
        f"{len(chunks)} chunks de {YF_CHUNK_SIZE} | "
        f"{YF_MAX_WORKERS} workers"
    )

    timestamp_utc = datetime.now(timezone.utc).isoformat()
    all_records: list[dict] = []

    with ThreadPoolExecutor(max_workers=YF_MAX_WORKERS) as executor:
        futures = {
            executor.submit(_fetch_chunk, chunk, idx, timestamp_utc): idx
            for idx, chunk in enumerate(chunks)
        }
        for future in as_completed(futures):
            idx = futures[future]
            try:
                records = future.result()
                all_records.extend(records)
                logger.info(f"Chunk {idx + 1}/{len(chunks)}: {len(records)} cotações OK")
            except Exception as e:
                logger.warning(f"Chunk {idx + 1} falhou completamente: {e}")

    logger.info(f"Total coletado: {len(all_records)} cotações de {len(tickers)} tickers")
    return all_records


def _fetch_chunk(tickers_chunk: list[str], chunk_idx: int, timestamp_utc: str) -> list[dict]:
    """Baixa um chunk de tickers via yfinance e retorna lista de records."""
    records = []

    try:
        raw = yf.download(
            tickers=tickers_chunk,
            period=FETCH_PERIOD,
            interval=FETCH_INTERVAL,
            group_by="ticker",
            auto_adjust=True,
            progress=False,
            threads=False,  # já estamos em thread pool externo
        )
    except Exception as e:
        logger.warning(f"yf.download falhou no chunk {chunk_idx}: {e}")
        return []

    if raw is None or raw.empty:
        return []

    for ticker in tickers_chunk:
        try:
            if len(tickers_chunk) > 1:
                if ticker not in raw.columns.get_level_values(0):
                    continue
                df = raw[ticker].dropna(how="all")
            else:
                df = raw.dropna(how="all")

            if df.empty:
                continue

            row          = df.iloc[-1]
            ticker_clean = ticker.replace(".SA", "").replace("^", "")

            records.append({
                "ticker":           ticker_clean,
                "ticker_original":  ticker,
                "categoria":        _classify_ticker(ticker),
                "timestamp_utc":    timestamp_utc,
                "data_pregao":      str(df.index[-1].date()),
                "hora_candle":      str(df.index[-1].time()),
                "preco_abertura":   _safe_float(row.get("Open")),
                "preco_maximo":     _safe_float(row.get("High")),
                "preco_minimo":     _safe_float(row.get("Low")),
                "preco_fechamento": _safe_float(row.get("Close")),
                "volume":           _safe_int(row.get("Volume")),
                "source":           "yahoo_finance",
                "lambda_version":   os.environ.get("AWS_LAMBDA_FUNCTION_VERSION", "local"),
            })

        except Exception as e:
            logger.debug(f"Erro ao processar {ticker}: {e}")

    return records


def _classify_ticker(ticker: str) -> str:
    if ticker.startswith("^"):
        return "indice"
    code = ticker.replace(".SA", "")
    if code.endswith("11") and len(code) == 6:
        return "fii_ou_etf"
    if code[-1] in ("3", "5", "6"):
        return "acao_on"
    if code[-1] == "4":
        return "acao_pn"
    return "acao"


# ─── 3. Publica no Kinesis ────────────────────────────────────────────────

def send_to_kinesis(records: list[dict]) -> dict:
    """
    Kinesis PutRecords: máx 500 registros por chamada.
    Faz 1 retry automático nos registros que falharem.
    """
    client     = get_kinesis()
    total_ok   = 0
    total_fail = 0
    failed     = []

    for i in range(0, len(records), KINESIS_BATCH):
        batch = records[i:i + KINESIS_BATCH]
        kinesis_records = [
            {
                "Data":         json.dumps(r, ensure_ascii=False, default=str),
                "PartitionKey": r["ticker"],
            }
            for r in batch
        ]

        try:
            resp     = client.put_records(StreamName=STREAM_NAME, Records=kinesis_records)
            n_failed = resp.get("FailedRecordCount", 0)

            if n_failed > 0:
                retry_recs = [
                    kinesis_records[j]
                    for j, rec in enumerate(resp["Records"])
                    if "ErrorCode" in rec
                ]
                logger.warning(f"Batch {i // KINESIS_BATCH + 1}: {n_failed} falhas — retry...")
                time.sleep(1)
                retry_resp     = client.put_records(StreamName=STREAM_NAME, Records=retry_recs)
                n_fail_retry   = retry_resp.get("FailedRecordCount", 0)
                total_ok      += len(batch) - n_fail_retry
                total_fail    += n_fail_retry
                for j, rec in enumerate(retry_resp["Records"]):
                    if "ErrorCode" in rec:
                        failed.append({
                            "ticker":     retry_recs[j]["PartitionKey"],
                            "error_code": rec["ErrorCode"],
                        })
            else:
                total_ok += len(batch)

        except ClientError as e:
            logger.error(f"ClientError batch {i // KINESIS_BATCH + 1}: {e}")
            total_fail += len(batch)

        if i + KINESIS_BATCH < len(records):
            time.sleep(0.05)

    return {
        "total_enviados": total_ok,
        "total_falhas":   total_fail,
        "falhas_detalhe": failed[:20],
    }


# ─── Helpers ──────────────────────────────────────────────────────────────

def _safe_float(value) -> float | None:
    try:
        v = float(value)
        return round(v, 4) if v == v else None
    except (TypeError, ValueError):
        return None

def _safe_int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


# ─── Handler ──────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context: Any) -> dict:
    start = time.time()
    logger.info(f"Iniciando | Stream: {STREAM_NAME}")

    try:
        tickers = get_tickers(event)
        logger.info(f"Tickers a processar: {len(tickers)}")

        quotes = fetch_quotes_parallel(tickers)

        if not quotes:
            return {"statusCode": 200, "body": {"message": "Sem cotações disponíveis", "total": 0}}

        result  = send_to_kinesis(quotes)
        elapsed = round(time.time() - start, 2)

        logger.info(
            f"Concluído em {elapsed}s | "
            f"Tickers: {len(tickers)} | Cotações: {len(quotes)} | "
            f"Kinesis OK: {result['total_enviados']} | Falhas: {result['total_falhas']}"
        )

        return {
            "statusCode": 200,
            "body": {
                "elapsed_seconds":    elapsed,
                "tickers_resolvidos": len(tickers),
                "cotacoes_coletadas": len(quotes),
                **result,
            },
        }

    except Exception as e:
        logger.exception(f"Erro fatal: {e}")
        return {"statusCode": 500, "body": {"error": str(e)}}
