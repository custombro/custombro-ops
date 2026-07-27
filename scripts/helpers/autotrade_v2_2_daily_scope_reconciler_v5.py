from __future__ import annotations

import datetime as dt
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

SOURCE = Path(sys.argv[1])
OUTPUT = Path(sys.argv[2])

DATE_KEYS = [
    "businessDate",
    "tradeDate",
    "date",
    "bsopDate",
    "tradDate",
    "business_date",
]
TIME_KEYS = [
    "executionTime",
    "fillTime",
    "tradeTime",
    "time",
    "ordTmd",
    "cnclTmd",
    "execution_time",
    "fill_time",
]
NET_KEYS = [
    "netRealizedPnl",
    "netPnl",
    "netProfit",
    "realizedNetPnl",
    "net_realized_pnl",
]
GROSS_KEYS = [
    "grossRealizedPnl",
    "grossTradePnl",
    "grossPnl",
    "tradeProfit",
    "gross_profit",
]
FEE_KEYS = ["fee", "commission", "totalFee", "feeAmount", "fees"]
TAX_KEYS = ["tax", "transactionTax", "taxAmount", "taxes"]
INTEREST_KEYS = ["loanInterest", "interest", "interestAmount", "loan_interest"]


def norm_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def key_lookup(row: dict[str, Any], candidates: list[str]) -> tuple[str | None, Any]:
    normalized = {norm_key(str(key)): str(key) for key in row.keys()}
    for candidate in candidates:
        actual = normalized.get(norm_key(candidate))
        if actual is not None:
            return actual, row.get(actual)
    return None, None


def number(value: Any) -> int | float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        text = value.replace(",", "").replace("+", "").strip()
        if re.fullmatch(r"-?\d+", text):
            return int(text)
        if re.fullmatch(r"-?\d+\.\d+", text):
            return float(text)
    return None


def date_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if re.fullmatch(r"\d{8}", text):
        return text[:4] + "-" + text[4:6] + "-" + text[6:8]
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        return text
    return None


def walk(value: Any, path: str = "$", parent: dict[str, Any] | None = None):
    if isinstance(value, dict):
        for key, item in value.items():
            child = path + "." + str(key)
            yield child, item, value
            yield from walk(item, child, value)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            child = path + "[" + str(index) + "]"
            yield child, item, parent
            yield from walk(item, child, parent)


def find_trade_rows(payload: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    direct = payload.get("tradeRows")
    if isinstance(direct, list) and all(isinstance(item, dict) for item in direct):
        return "$.tradeRows", list(direct)

    best_path = ""
    best_rows: list[dict[str, Any]] = []
    for path, value, _ in walk(payload):
        if not isinstance(value, list) or not value:
            continue
        if not all(isinstance(item, dict) for item in value):
            continue
        first = value[0]
        _, net_value = key_lookup(first, NET_KEYS)
        _, date_value = key_lookup(first, DATE_KEYS)
        if number(net_value) is None or date_text(date_value) is None:
            continue
        if len(value) > len(best_rows):
            best_path = path
            best_rows = list(value)

    if not best_rows:
        raise RuntimeError("TRADE_ROWS_NOT_FOUND")
    return best_path, best_rows


def parent_dates(parent: dict[str, Any] | None) -> dict[str, str]:
    result: dict[str, str] = {}
    if not isinstance(parent, dict):
        return result
    for key, value in parent.items():
        lower = str(key).lower()
        if "date" not in lower and "dt" not in lower:
            continue
        parsed = date_text(value)
        if parsed:
            result[str(key)] = parsed
    return result


def main() -> int:
    payload = json.loads(SOURCE.read_text(encoding="utf-8-sig"))
    if not isinstance(payload, dict):
        raise RuntimeError("SOURCE_ROOT_NOT_OBJECT")

    trade_rows_path, raw_rows = find_trade_rows(payload)
    canonical_rows: list[dict[str, Any]] = []
    field_names: dict[str, str | None] = {
        "date": None,
        "time": None,
        "net": None,
        "gross": None,
        "fee": None,
        "tax": None,
        "interest": None,
    }

    for index, row in enumerate(raw_rows):
        date_key, date_value = key_lookup(row, DATE_KEYS)
        time_key, time_value = key_lookup(row, TIME_KEYS)
        net_key, net_value = key_lookup(row, NET_KEYS)
        gross_key, gross_value = key_lookup(row, GROSS_KEYS)
        fee_key, fee_value = key_lookup(row, FEE_KEYS)
        tax_key, tax_value = key_lookup(row, TAX_KEYS)
        interest_key, interest_value = key_lookup(row, INTEREST_KEYS)

        business_date = date_text(date_value)
        net = number(net_value)
        if business_date is None or net is None:
            continue

        values = {
            "net": net,
            "gross": number(gross_value),
            "fee": number(fee_value),
            "tax": number(tax_value),
            "interest": number(interest_value),
        }
        canonical_rows.append(
            {
                "source_index": index,
                "business_date": business_date,
                "time": str(time_value).strip() if time_value not in (None, "") else None,
                "values": values,
            }
        )

        for name, key in [
            ("date", date_key),
            ("time", time_key),
            ("net", net_key),
            ("gross", gross_key),
            ("fee", fee_key),
            ("tax", tax_key),
            ("interest", interest_key),
        ]:
            if field_names[name] is None and key is not None:
                field_names[name] = key

    if not canonical_rows:
        raise RuntimeError("NO_CANONICAL_TRADE_ROWS")

    daily: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "trade_row_count": 0,
            "net": 0,
            "gross": 0,
            "fee": 0,
            "tax": 0,
            "interest": 0,
            "gross_complete": True,
            "fee_complete": True,
            "tax_complete": True,
            "interest_complete": True,
        }
    )

    intraday_rows = 0
    accounting_mismatches: list[dict[str, Any]] = []

    for row in canonical_rows:
        day = daily[row["business_date"]]
        day["trade_row_count"] += 1
        values = row["values"]
        day["net"] += values["net"]

        for component in ["gross", "fee", "tax", "interest"]:
            value = values[component]
            if value is None:
                day[component + "_complete"] = False
            else:
                day[component] += value

        if row["time"]:
            intraday_rows += 1

        if all(values[name] is not None for name in ["gross", "fee", "tax", "interest"]):
            expected = values["gross"] - values["fee"] - values["tax"] - values["interest"]
            if abs(float(expected) - float(values["net"])) > 0.000001:
                accounting_mismatches.append(
                    {
                        "source_index": row["source_index"],
                        "business_date": row["business_date"],
                        "expected_net": expected,
                        "actual_net": values["net"],
                    }
                )

    daily_points = []
    for business_date in sorted(daily.keys()):
        item = dict(daily[business_date])
        item["business_date"] = business_date
        daily_points.append(item)

    latest_date = daily_points[-1]["business_date"]
    latest = daily[latest_date]

    summary_candidates = []
    for path, value, parent in walk(payload):
        numeric_value = number(value)
        if numeric_value is None:
            continue
        lower_path = path.lower()
        if not any(token in lower_path for token in ["pnl", "profit", "realized", "pfls"]):
            continue
        summary_candidates.append(
            {
                "path": path,
                "value": numeric_value,
                "parent_dates": parent_dates(parent),
                "matches_latest_trade_row_sum": numeric_value == latest["net"],
            }
        )

    suspected = [item for item in summary_candidates if item["value"] == -935005]
    if not suspected:
        suspected = [
            item for item in summary_candidates
            if not item["matches_latest_trade_row_sum"]
        ][:20]

    summary_latest_usable = any(
        item["matches_latest_trade_row_sum"]
        and (
            not item["parent_dates"]
            or latest_date in set(item["parent_dates"].values())
        )
        for item in summary_candidates
    )

    contract = {
        "contract_type": "AUTOTRADE_CLEAN_V2_2_DAILY_SCOPE_CONTRACT_V5",
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "read_only": True,
        "live_install_allowed": False,
        "manual_value_override_allowed": False,
        "zero_when_unconfirmed_allowed": False,
        "source": str(SOURCE),
        "trade_rows_path": trade_rows_path,
        "raw_trade_row_count": len(raw_rows),
        "canonical_trade_row_count": len(canonical_rows),
        "field_names": field_names,
        "latest_business_date": latest_date,
        "latest_date": dict(latest),
        "daily_points": daily_points,
        "summary_candidates": summary_candidates[:300],
        "suspected_period_or_unknown_summary": suspected[:50],
        "summary_latest_day_usable": summary_latest_usable,
        "canonical_latest_day_source": "TRADE_ROWS_GROUPED_BY_BUSINESS_DATE",
        "accounting_mismatch_count": len(accounting_mismatches),
        "accounting_mismatches": accounting_mismatches[:20],
        "daily_week_month_graph_ready": len(daily_points) >= 1,
        "intraday_timestamp_row_count": intraday_rows,
        "intraday_graph_ready": intraday_rows == len(canonical_rows) and intraday_rows > 0,
        "intraday_linkage_required": intraday_rows < len(canonical_rows),
        "financial_daily_contract_ready": (
            latest["trade_row_count"] > 0
            and len(accounting_mismatches) == 0
        ),
    }

    OUTPUT.write_text(
        json.dumps(contract, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8-sig",
    )

    print("FINAL_STATUS=PASS_DAILY_SCOPE_RECONCILIATION_V5")
    print(f"TRADE_ROWS_PATH={trade_rows_path}")
    print(f"RAW_TRADE_ROW_COUNT={len(raw_rows)}")
    print(f"CANONICAL_TRADE_ROW_COUNT={len(canonical_rows)}")
    print(f"LATEST_BUSINESS_DATE={latest_date}")
    print(f"LATEST_DATE_TRADE_ROW_COUNT={latest['trade_row_count']}")
    print(f"LATEST_DATE_NET={latest['net']}")
    print(f"LATEST_DATE_GROSS={latest['gross'] if latest['gross_complete'] else 'UNCONFIRMED'}")
    print(f"LATEST_DATE_FEE={latest['fee'] if latest['fee_complete'] else 'UNCONFIRMED'}")
    print(f"LATEST_DATE_TAX={latest['tax'] if latest['tax_complete'] else 'UNCONFIRMED'}")
    print(f"LATEST_DATE_LOAN_INTEREST={latest['interest'] if latest['interest_complete'] else 'UNCONFIRMED'}")
    print(f"ACCOUNTING_MISMATCH_COUNT={len(accounting_mismatches)}")
    print(f"PERIOD_OR_UNKNOWN_SUMMARY_CANDIDATE_COUNT={len(suspected)}")
    if suspected:
        print(f"PERIOD_OR_UNKNOWN_SUMMARY_PATH={suspected[0]['path']}")
        print(f"PERIOD_OR_UNKNOWN_SUMMARY_VALUE={suspected[0]['value']}")
    print(f"SUMMARY_LATEST_DAY_USABLE={str(summary_latest_usable).upper()}")
    print("CANONICAL_LATEST_DAY_SOURCE=TRADE_ROWS_GROUPED_BY_BUSINESS_DATE")
    print(f"DAILY_POINT_COUNT={len(daily_points)}")
    print(f"DAILY_WEEK_MONTH_GRAPH_READY={str(contract['daily_week_month_graph_ready']).upper()}")
    print(f"INTRADAY_TIMESTAMP_ROW_COUNT={intraday_rows}")
    print(f"INTRADAY_GRAPH_READY={str(contract['intraday_graph_ready']).upper()}")
    print(f"INTRADAY_LINKAGE_REQUIRED={str(contract['intraday_linkage_required']).upper()}")
    print(f"FINANCIAL_DAILY_CONTRACT_READY={str(contract['financial_daily_contract_ready']).upper()}")
    print(f"DAILY_SCOPE_CONTRACT={OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
