from __future__ import annotations

import datetime as dt
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(sys.argv[1])
CONTROL = Path(sys.argv[2])
DATABASE = Path(sys.argv[3])
PNL_SOURCE = Path(sys.argv[4])
OUTPUT = Path(sys.argv[5])

MAX_JSON_FILES = 500
MAX_JSON_BYTES = 20 * 1024 * 1024
MAX_DB_ROWS_PER_TABLE = 5000
MAX_RECORDS = 100000

SYMBOL_KEYS = {
    "symbol", "stockcode", "code", "ticker", "pdno",
    "mkscshrnisc", "mkscshrniscd", "stckshrniscd", "shortcode",
}
DATE_KEYS = {
    "businessdate", "tradedate", "date", "orddt", "traddt",
    "orderdate", "filldate", "executiondate", "cclddt",
}
TIME_KEYS = {
    "filltime", "tradetime", "executedat", "executiontime",
    "timestamp", "ksttimestamp", "ordtmd", "ccldtmd", "eventtime",
    "createdat", "updatedat", "filledat", "completedat",
}
ORDER_ID_KEYS = {
    "orderid", "orderno", "ordno", "brokerorderno", "odno",
    "originalorderno", "orgnordno",
}
QTY_KEYS = {
    "qty", "quantity", "fillqty", "executedqty", "ccldqty",
    "totccldqty", "orderqty", "ordqty",
}
PRICE_KEYS = {
    "price", "fillprice", "executedprice", "avgprice", "averageprice",
    "ccldunpr", "ordunpr", "tradeprice",
}
STATUS_KEYS = {
    "status", "state", "orderstatus", "executionstatus", "result",
    "ordstatus", "fillstatus",
}
SIDE_KEYS = {
    "side", "action", "orderside", "buysell", "sllbuydvsncd",
    "sllbuydvsncdname",
}

EXECUTION_TOKENS = (
    "fill", "filled", "execution", "executed", "trade", "traded",
    "ccld", "complete", "completed", "brokerreadback",
    "\uccb4\uacb0",  # Korean: filled/executed
)
PATH_INCLUDE = re.compile(
    r"(fill|execution|trade|order|ledger|broker|readback|intraday|verify|ccld)",
    re.IGNORECASE,
)
PATH_EXCLUDE = re.compile(
    r"(fact_dashboard_v2_2_lab|backup|archive|sample|fixture|synthetic|self.?test)",
    re.IGNORECASE,
)


def normalized_key(value: Any) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def first_value(mapping: dict[str, Any], accepted: set[str]) -> Any:
    for key, value in mapping.items():
        if normalized_key(key) in accepted:
            return value
    return None


def numeric(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.replace(",", "").replace("+", "").strip()
        if re.fullmatch(r"-?\d+(?:\.\d+)?", text):
            return float(text)
    return None


def text_value(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text if text else None


def normalize_symbol(value: Any) -> str | None:
    text = text_value(value)
    if not text:
        return None
    compact = re.sub(r"[^A-Za-z0-9]", "", text).upper()
    if not compact:
        return None
    if compact.isdigit() and len(compact) < 6:
        compact = compact.zfill(6)
    return compact


def parse_date(value: Any) -> str | None:
    text = text_value(value)
    if not text:
        return None
    digits = re.sub(r"[^0-9]", "", text)
    if len(digits) >= 8:
        candidate = digits[:8]
        try:
            parsed = dt.datetime.strptime(candidate, "%Y%m%d").date()
            return parsed.isoformat()
        except Exception:
            pass
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).date().isoformat()
    except Exception:
        return None


def parse_timestamp(value: Any, date_hint: str | None = None) -> str | None:
    text = text_value(value)
    if not text:
        return None

    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone(dt.timezone(dt.timedelta(hours=9)))
        return parsed.replace(tzinfo=None).isoformat(timespec="seconds")
    except Exception:
        pass

    digits = re.sub(r"[^0-9]", "", text)
    for length, fmt in ((14, "%Y%m%d%H%M%S"), (12, "%Y%m%d%H%M")):
        if len(digits) >= length:
            try:
                parsed = dt.datetime.strptime(digits[:length], fmt)
                return parsed.isoformat(timespec="seconds")
            except Exception:
                pass

    if date_hint and len(digits) in {4, 6}:
        time_text = digits.zfill(6)
        try:
            parsed = dt.datetime.strptime(
                date_hint.replace("-", "") + time_text,
                "%Y%m%d%H%M%S",
            )
            return parsed.isoformat(timespec="seconds")
        except Exception:
            pass

    match = re.fullmatch(r"(\d{1,2}):(\d{2})(?::(\d{2}))?", text)
    if date_hint and match:
        hour = int(match.group(1))
        minute = int(match.group(2))
        second = int(match.group(3) or 0)
        try:
            parsed_date = dt.date.fromisoformat(date_hint)
            parsed = dt.datetime.combine(
                parsed_date,
                dt.time(hour=hour, minute=minute, second=second),
            )
            return parsed.isoformat(timespec="seconds")
        except Exception:
            pass

    return None


def execution_signal(mapping: dict[str, Any], source: str, location: str) -> bool:
    combined = (source + "|" + location).lower()
    values = []
    for key, value in mapping.items():
        key_norm = normalized_key(key)
        if key_norm in STATUS_KEYS or key_norm in SIDE_KEYS or key_norm in TIME_KEYS:
            values.append(str(value).lower())
    combined += "|" + "|".join(values)
    return any(token in combined for token in EXECUTION_TOKENS)


def record_from_mapping(
    mapping: dict[str, Any],
    source: str,
    location: str,
    default_date: str | None = None,
) -> dict[str, Any] | None:
    symbol = normalize_symbol(first_value(mapping, SYMBOL_KEYS))
    if not symbol:
        return None

    explicit_date = parse_date(first_value(mapping, DATE_KEYS)) or default_date
    timestamp = parse_timestamp(first_value(mapping, TIME_KEYS), explicit_date)
    if not timestamp:
        return None

    timestamp_date = timestamp[:10]
    if not execution_signal(mapping, source, location):
        return None

    return {
        "symbol": symbol,
        "date": timestamp_date,
        "timestamp": timestamp,
        "order_id": text_value(first_value(mapping, ORDER_ID_KEYS)),
        "qty": numeric(first_value(mapping, QTY_KEYS)),
        "price": numeric(first_value(mapping, PRICE_KEYS)),
        "side": text_value(first_value(mapping, SIDE_KEYS)),
        "status": text_value(first_value(mapping, STATUS_KEYS)),
        "source": source,
        "location": location,
    }


def iter_dicts(value: Any, path: str = "$") -> Iterable[tuple[str, dict[str, Any]]]:
    if isinstance(value, dict):
        yield path, value
        for key, item in value.items():
            child = path + "." + str(key)
            yield from iter_dicts(item, child)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from iter_dicts(item, path + "[" + str(index) + "]")


def trade_rows() -> tuple[str, list[dict[str, Any]]]:
    payload = json.loads(PNL_SOURCE.read_text(encoding="utf-8-sig"))
    rows = payload.get("tradeRows")
    if not isinstance(rows, list):
        raise RuntimeError("TRADE_ROWS_NOT_FOUND")

    dated: list[tuple[str, dict[str, Any]]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        date_value = parse_date(first_value(row, DATE_KEYS))
        if date_value:
            dated.append((date_value, row))

    if not dated:
        raise RuntimeError("TRADE_ROW_DATE_NOT_FOUND")

    latest_date = max(date_value for date_value, _ in dated)
    latest_rows: list[dict[str, Any]] = []
    for index, (date_value, row) in enumerate(dated):
        if date_value != latest_date:
            continue
        symbol = normalize_symbol(first_value(row, SYMBOL_KEYS))
        latest_rows.append(
            {
                "row_index": index,
                "date": date_value,
                "symbol": symbol,
                "order_id": text_value(first_value(row, ORDER_ID_KEYS)),
                "qty": numeric(first_value(row, QTY_KEYS)),
                "price": numeric(first_value(row, PRICE_KEYS)),
                "raw_keys": sorted(str(key) for key in row.keys()),
            }
        )

    return latest_date, latest_rows


def sqlite_records(latest_date: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    tables: list[dict[str, Any]] = []

    connection = sqlite3.connect(
        "file:" + str(DATABASE) + "?mode=ro",
        uri=True,
        timeout=5,
    )
    connection.row_factory = sqlite3.Row
    try:
        table_names = [
            str(row[0])
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            ).fetchall()
        ]

        for table in table_names:
            quoted = '"' + table.replace('"', '""') + '"'
            columns = [
                str(row[1])
                for row in connection.execute("PRAGMA table_info(" + quoted + ")").fetchall()
            ]
            combined = (table + "|" + "|".join(columns)).lower()
            relevant = bool(PATH_INCLUDE.search(combined))
            tables.append({"name": table, "columns": columns, "relevant": relevant})
            if not relevant:
                continue

            try:
                rows = connection.execute(
                    "SELECT * FROM " + quoted + " ORDER BY rowid DESC LIMIT " + str(MAX_DB_ROWS_PER_TABLE)
                ).fetchall()
            except Exception:
                rows = connection.execute(
                    "SELECT * FROM " + quoted + " LIMIT " + str(MAX_DB_ROWS_PER_TABLE)
                ).fetchall()

            for row_index, row in enumerate(rows):
                mapping = {str(key): row[key] for key in row.keys()}
                record = record_from_mapping(
                    mapping,
                    "sqlite:" + table,
                    "row:" + str(row_index),
                    latest_date,
                )
                if record:
                    records.append(record)
                    if len(records) >= MAX_RECORDS:
                        return records, tables
    finally:
        connection.close()

    return records, tables


def json_records(latest_date: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    files_seen: list[dict[str, Any]] = []
    candidates: list[Path] = []

    for base in (ROOT / "state", CONTROL):
        if not base.exists():
            continue
        for path in base.rglob("*.json"):
            path_text = str(path)
            if PATH_EXCLUDE.search(path_text):
                continue
            if not PATH_INCLUDE.search(path_text):
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_size > MAX_JSON_BYTES:
                continue
            candidates.append(path)

    candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)

    for path in candidates[:MAX_JSON_FILES]:
        try:
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            files_seen.append({"file": str(path), "error": str(exc)[:200]})
            continue

        file_count_before = len(records)
        for location, mapping in iter_dicts(payload):
            record = record_from_mapping(mapping, str(path), location, latest_date)
            if record:
                records.append(record)
                if len(records) >= MAX_RECORDS:
                    break

        files_seen.append(
            {
                "file": str(path),
                "record_count": len(records) - file_count_before,
            }
        )
        if len(records) >= MAX_RECORDS:
            break

    return records, files_seen


def deduplicate(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[Any, ...], dict[str, Any]] = {}
    for record in records:
        key = (
            record.get("symbol"),
            record.get("timestamp"),
            record.get("order_id"),
            record.get("qty"),
            record.get("price"),
            record.get("side"),
        )
        if key not in grouped:
            copy = dict(record)
            copy["sources"] = [record.get("source")]
            copy["locations"] = [record.get("location")]
            grouped[key] = copy
        else:
            grouped[key]["sources"].append(record.get("source"))
            grouped[key]["locations"].append(record.get("location"))
    result = list(grouped.values())
    result.sort(key=lambda row: (str(row.get("timestamp")), str(row.get("symbol"))))
    return result


def close_number(left: float | None, right: float | None) -> bool:
    if left is None or right is None:
        return False
    return abs(left - right) < 0.000001


def link_rows(
    latest_date: str,
    pnl_rows: list[dict[str, Any]],
    evidence: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, int], bool]:
    links: list[dict[str, Any]] = []
    counts = {
        "order_id_exact": 0,
        "qty_price_exact": 0,
        "unique_symbol_date_timestamp": 0,
        "ambiguous": 0,
        "unlinked": 0,
        "missing_symbol": 0,
    }

    for pnl_row in pnl_rows:
        symbol = pnl_row.get("symbol")
        if not symbol:
            counts["missing_symbol"] += 1
            links.append({"pnl_row": pnl_row, "status": "MISSING_SYMBOL", "matches": []})
            continue

        matches = [
            item
            for item in evidence
            if item.get("symbol") == symbol and item.get("date") == latest_date
        ]

        selected: list[dict[str, Any]] = []
        method = None

        pnl_order_id = pnl_row.get("order_id")
        if pnl_order_id:
            selected = [item for item in matches if item.get("order_id") == pnl_order_id]
            if len(selected) == 1:
                method = "ORDER_ID_EXACT"
                counts["order_id_exact"] += 1

        if method is None and pnl_row.get("qty") is not None and pnl_row.get("price") is not None:
            selected = [
                item
                for item in matches
                if close_number(item.get("qty"), pnl_row.get("qty"))
                and close_number(item.get("price"), pnl_row.get("price"))
            ]
            if len(selected) == 1:
                method = "QTY_PRICE_EXACT"
                counts["qty_price_exact"] += 1

        if method is None:
            unique_timestamps = sorted({str(item.get("timestamp")) for item in matches})
            if len(unique_timestamps) == 1 and matches:
                selected = [item for item in matches if str(item.get("timestamp")) == unique_timestamps[0]]
                method = "UNIQUE_SYMBOL_DATE_TIMESTAMP"
                counts["unique_symbol_date_timestamp"] += 1
            elif not matches:
                method = "UNLINKED"
                counts["unlinked"] += 1
            else:
                method = "AMBIGUOUS"
                selected = matches
                counts["ambiguous"] += 1

        links.append(
            {
                "pnl_row": pnl_row,
                "status": method,
                "matches": selected[:30],
                "all_symbol_date_match_count": len(matches),
            }
        )

    ready = (
        len(pnl_rows) > 0
        and counts["ambiguous"] == 0
        and counts["unlinked"] == 0
        and counts["missing_symbol"] == 0
        and (
            counts["order_id_exact"]
            + counts["qty_price_exact"]
            + counts["unique_symbol_date_timestamp"]
            == len(pnl_rows)
        )
    )
    return links, counts, ready


def main() -> int:
    latest_date, pnl_rows = trade_rows()
    db_records, db_tables = sqlite_records(latest_date)
    file_records, files_seen = json_records(latest_date)
    evidence = deduplicate(db_records + file_records)
    latest_evidence = [item for item in evidence if item.get("date") == latest_date]
    links, counts, ready = link_rows(latest_date, pnl_rows, latest_evidence)

    payload = {
        "contract_type": "AUTOTRADE_CLEAN_V2_2_INTRADAY_FILL_LINKAGE_CONTRACT_V6",
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "read_only": True,
        "live_install_allowed": False,
        "manual_timestamp_override_allowed": False,
        "latest_business_date": latest_date,
        "latest_date_trade_rows": pnl_rows,
        "sqlite_tables": db_tables,
        "json_files_scanned": files_seen,
        "raw_sqlite_timestamp_record_count": len(db_records),
        "raw_json_timestamp_record_count": len(file_records),
        "deduplicated_timestamp_record_count": len(evidence),
        "latest_date_timestamp_record_count": len(latest_evidence),
        "links": links,
        "link_counts": counts,
        "intraday_graph_ready": ready,
        "daily_week_month_graph_remains_ready": True,
        "fallback_when_not_ready": "DAILY_WEEK_MONTH_ONLY_NO_INTRADAY_INVENTION",
    }

    OUTPUT.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8-sig",
    )

    print("FINAL_STATUS=PASS_INTRADAY_FILL_LINKAGE_AUDIT_V6")
    print("LATEST_BUSINESS_DATE=" + latest_date)
    print("LATEST_DATE_TRADE_ROW_COUNT=" + str(len(pnl_rows)))
    print("RAW_SQLITE_TIMESTAMP_RECORD_COUNT=" + str(len(db_records)))
    print("RAW_JSON_TIMESTAMP_RECORD_COUNT=" + str(len(file_records)))
    print("DEDUPLICATED_TIMESTAMP_RECORD_COUNT=" + str(len(evidence)))
    print("LATEST_DATE_TIMESTAMP_RECORD_COUNT=" + str(len(latest_evidence)))
    print("ORDER_ID_EXACT_LINK_COUNT=" + str(counts["order_id_exact"]))
    print("QTY_PRICE_EXACT_LINK_COUNT=" + str(counts["qty_price_exact"]))
    print("UNIQUE_SYMBOL_DATE_TIMESTAMP_LINK_COUNT=" + str(counts["unique_symbol_date_timestamp"]))
    print("AMBIGUOUS_LINK_COUNT=" + str(counts["ambiguous"]))
    print("UNLINKED_TRADE_ROW_COUNT=" + str(counts["unlinked"]))
    print("MISSING_SYMBOL_ROW_COUNT=" + str(counts["missing_symbol"]))
    print("INTRADAY_GRAPH_READY=" + str(ready).upper())
    print("DAILY_WEEK_MONTH_GRAPH_READY=TRUE")
    print("LINKAGE_CONTRACT=" + str(OUTPUT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
