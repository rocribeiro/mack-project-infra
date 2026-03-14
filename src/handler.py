"""
Lambda: Yahoo Finance → Kinesis Data Stream
Projeto: B3 DataLake - MBA Mackenzie

Usa yfinance.Ticker.fast_info (retorna dict puro, SEM pandas/numpy)
Layer size: ~20MB (vs ~200MB com pandas+numpy)
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

STREAM_NAME       = os.environ["KINESIS_STREAM_NAME"]
AWS_REGION        = os.environ.get("AWS_REGION_NAME", "us-east-1")
KINESIS_BATCH     = int(os.environ.get("KINESIS_BATCH_SIZE", "500"))
MAX_WORKERS       = int(os.environ.get("YF_MAX_WORKERS", "10"))
TICKERS_S3_BUCKET = os.environ.get("TICKERS_S3_BUCKET", "")
TICKERS_S3_KEY    = os.environ.get("TICKERS_S3_KEY", "config/tickers_b3.json")

B3_API_BASE = "https://sistemaswebb3-listados.b3.com.br/listedCompaniesProxy/CompanyCall"
B3_HEADERS  = {"User-Agent": "Mozilla/5.0", "Accept": "application/json"}

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

def fetch_tickers_from_b3() -> list:
    tickers = set()
    page, page_size, total_pages = 1, 120, None
    logger.info("Buscando tickers na B3...")
    while True:
        url = f"{B3_API_BASE}/GetInitialCompanies/{page}/{page_size}/pt-br"
        try:
            resp = requests.get(url, headers=B3_HEADERS, timeout=10)
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            logger.warning(f"Erro B3 pag {page}: {e}")
            break
        companies = data.get("results", [])
        if not companies:
            break
        if total_pages is None:
            total      = data.get("page", {}).get("totalRecords", 0)
            total_pages = -(-total // page_size)
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
        if total_pages and page >= total_pages:
            break
        page += 1
        time.sleep(0.15)
    tickers.update({"^BVSP", "^IBX50"})
    result = sorted(tickers)
    logger.info(f"Total tickers B3: {len(result)}")
    return result

def get_tickers(event):
    if event.get("tickers"):
        return event["tickers"]
    try:
        tickers = fetch_tickers_from_b3()
        if len(tickers) > 50:
            _save_cache(tickers)
            return tickers
    except Exception as e:
        logger.warning(f"Falha B3: {e}")
    return _load_cache()

def _save_cache(tickers):
    if not TICKERS_S3_BUCKET:
        return
    try:
        get_s3().put_object(
            Bucket=TICKERS_S3_BUCKET, Key=TICKERS_S3_KEY,
            Body=json.dumps({"tickers": tickers, "total": len(tickers),
                             "updated_at": datetime.now(timezone.utc).isoformat()}),
            ContentType="application/json",
        )
    except Exception as e:
        logger.warning(f"Cache save error: {e}")

def _load_cache():
    if not TICKERS_S3_BUCKET:
        raise RuntimeError("B3 inacessivel e sem cache")
    obj  = get_s3().get_object(Bucket=TICKERS_S3_BUCKET, Key=TICKERS_S3_KEY)
    data = json.loads(obj["Body"].read())
    logger.info(f"Cache: {data['total']} tickers")
    return data["tickers"]

def fetch_one(ticker, timestamp_utc):
    """Usa fast_info - dict puro sem pandas."""
    try:
        info  = yf.Ticker(ticker).fast_info
        price = _safe_float(info.get("lastPrice") or info.get("regularMarketPrice"))
        if price is None:
            return None
        ticker_clean = ticker.replace(".SA", "").replace("^", "")
        return {
            "ticker":           ticker_clean,
            "ticker_original":  ticker,
            "categoria":        _classify(ticker),
            "timestamp_utc":    timestamp_utc,
            "preco_fechamento": price,
            "preco_abertura":   _safe_float(info.get("open")),
            "preco_maximo":     _safe_float(info.get("dayHigh")),
            "preco_minimo":     _safe_float(info.get("dayLow")),
            "preco_anterior":   _safe_float(info.get("previousClose")),
            "volume":           _safe_int(info.get("lastVolume") or info.get("regularMarketVolume")),
            "variacao_pct":     _safe_float(info.get("regularMarketChangePercent")),
            "source":           "yahoo_finance",
            "lambda_version":   os.environ.get("AWS_LAMBDA_FUNCTION_VERSION", "local"),
        }
    except Exception as e:
        logger.debug(f"Erro {ticker}: {e}")
        return None

def fetch_quotes_parallel(tickers):
    timestamp_utc = datetime.now(timezone.utc).isoformat()
    records       = []
    logger.info(f"Coletando {len(tickers)} tickers ({MAX_WORKERS} workers)...")
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(fetch_one, t, timestamp_utc): t for t in tickers}
        for future in as_completed(futures):
            result = future.result()
            if result:
                records.append(result)
    logger.info(f"Coletados: {len(records)}/{len(tickers)}")
    return records

def send_to_kinesis(records):
    client     = get_kinesis()
    total_ok   = 0
    total_fail = 0
    for i in range(0, len(records), KINESIS_BATCH):
        batch = records[i:i + KINESIS_BATCH]
        kinesis_records = [
            {"Data": json.dumps(r, ensure_ascii=False, default=str), "PartitionKey": r["ticker"]}
            for r in batch
        ]
        try:
            resp     = client.put_records(StreamName=STREAM_NAME, Records=kinesis_records)
            n_failed = resp.get("FailedRecordCount", 0)
            if n_failed > 0:
                retry      = [kinesis_records[j] for j, rec in enumerate(resp["Records"]) if "ErrorCode" in rec]
                time.sleep(1)
                retry_resp = client.put_records(StreamName=STREAM_NAME, Records=retry)
                total_ok  += len(batch) - retry_resp.get("FailedRecordCount", 0)
                total_fail += retry_resp.get("FailedRecordCount", 0)
            else:
                total_ok += len(batch)
        except ClientError as e:
            logger.error(f"Kinesis erro: {e}")
            total_fail += len(batch)
        if i + KINESIS_BATCH < len(records):
            time.sleep(0.05)
    return {"total_enviados": total_ok, "total_falhas": total_fail}

def _safe_float(v):
    try:
        f = float(v)
        return round(f, 4) if f == f else None
    except (TypeError, ValueError):
        return None

def _safe_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None

def _classify(ticker):
    if ticker.startswith("^"):
        return "indice"
    code = ticker.replace(".SA", "")
    if code.endswith("11") and len(code) == 6:
        return "fii_ou_etf"
    if code[-1:] in ("3", "5", "6"):
        return "acao_on"
    if code[-1:] == "4":
        return "acao_pn"
    return "acao"

def lambda_handler(event, context):
    start = time.time()
    logger.info(f"Iniciando | Stream: {STREAM_NAME}")
    try:
        tickers = get_tickers(event)
        quotes  = fetch_quotes_parallel(tickers)
        if not quotes:
            return {"statusCode": 200, "body": {"message": "Sem cotacoes", "total": 0}}
        result  = send_to_kinesis(quotes)
        elapsed = round(time.time() - start, 2)
        logger.info(f"Concluido {elapsed}s | OK: {result['total_enviados']}")
        return {"statusCode": 200, "body": {"elapsed_seconds": elapsed,
                "tickers_resolvidos": len(tickers), "cotacoes_coletadas": len(quotes), **result}}
    except Exception as e:
        logger.exception(f"Erro fatal: {e}")
        return {"statusCode": 500, "body": {"error": str(e)}}
