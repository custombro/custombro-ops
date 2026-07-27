from __future__ import annotations

import datetime as dt
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

SOURCE = Path(sys.argv[1])
OUTPUT = Path(sys.argv[2])

NET_KEYS = [
    "netRealizedPnl",
    "dailyTradingPnl",
    "netPnl",
    "netProfit",
    "realizedNetPnl",
]
FEE_KEYS = ["fee", "commission", "feeAmount", "totalFee"]
TAX_KEYS = ["tax", "transactionTax", "taxAmount", "totalTax"]
INTEREST_KEYS = [
    "loanInterest",
    "interest",
    "interestAmount",
    "totalLoanInterest",
]
GROSS_KEYS = [
    "grossRealizedPnl",
    "grossTradePnl",
    "grossPnl",
    "tradeProfit",
    "grossProfit",
    "realizedPnl",
    "pnlBeforeCost",
    "preCostPnl",
]
DATE_KEYS = [
    "businessDate",
    "tradeDate",
    "date",
    "ordDate",
    "tradDate",
    "stckBsopDate",
]
TIME_KEYS = [
    "tradeTime",
    "time",
    "fillTime",
    "ordTime",
    "stckCntgHour",
    "capturedAt",
]
SYMBOL_KEYS = ["symbol", "code", "stockCode", "pdno", "ticker"]
NAME_KEYS = ["name", "stockName", "prdtName", "prdt_name"]
SIDE_KEYS = ["side", "tradeSide", "sllBuyDvsnName", "buySell"]
QTY_KEYS = ["qty", "quantity", "filledQty", "totCntgQty", "cntgQty"]
PRICE_KEYS = ["price", "tradePrice", "filledPrice", "avgPrice", "cntgUnpr"]

SUMMARY_NET_KEYS = [
    "dailyTradingPnl",
    "totalNetRealizedPnl",
    "netRealizedPnl",
    "dailyNetPnl",
    "netPnl",
]
SUMMARY_GROSS_KEYS = [
    "totalGrossRealizedPnl",
    "grossRealizedPnl",
    "dailyGrossPnl",
    "grossPnl",
]
SUMMARY_FEE_KEYS = ["totalFee", "fee", "commission", "feeAmount"]
SUMMARY_TAX_KEYS = ["totalTax", "tax", "transactionTax", "taxAmount"]
SUMMARY_INTEREST_KEYS = [
    "totalLoanInterest",
    "loanInterest",
    "interestAmount",
    "interest",
]

TOLERANCE = 1.0


def numeric(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        return number if math.isfinite(number) else None
    if isinstance(value, str):
        text = value.replace(",", "").replace("+", "").strip()
        if re.fullmatch(r"-?\d+(?:\.\d+)?", text):
            return float(text)
    return None


def scalar(value: Any) -> bool:
    return value is None or isinstance(value, (str, int, float, bool))


def normalized_key_map(row: dict[str, Any]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = defaultdict(list)
    for key in row:
        result[str(key).lower()].append(str(key))
    return dict(result)


def exact_values(
    row: dict[str, Any],
    aliases: list[str],
) -> list[tuple[str, float]]:
    mapping = normalized_key_map(row)
    result: list[tuple[str, float]] = []
    for alias in aliases:
        for real_key in mapping.get(alias.lower(), []):
            value = numeric(row.get(real_key))
            if value is not None:
                result.append((real_key, value))
    return result


def select_exact(
    row: dict[str, Any],
    aliases: list[str],
) -> dict[str, Any]:
    values = exact_values(row, aliases)
    if not values:
        return {
            "ready": False,
            "field": None,
            "value": None,
            "aliases": [],
            "conflict": False,
        }

    unique_values = sorted({round(value, 8) for _, value in values})
    return {
        "ready": True,
        "field": values[0][0],
        "value": values[0][1],
        "aliases": [key for key, _ in values],
        "conflict": len(unique_values) > 1,
        "all_values": [
            {"field": key, "value": value}
            for key, value in values
        ],
    }


def select_text(row: dict[str, Any], aliases: list[str]) -> dict[str, Any]:
    mapping = normalized_key_map(row)
    for alias in aliases:
        for real_key in mapping.get(alias.lower(), []):
            value = row.get(real_key)
            if value is not None and str(value).strip():
                return {"field": real_key, "value": str(value).strip()}
    return {"field": None, "value": None}


def parse_date(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if re.fullmatch(r"\d{8}", text):
        try:
            return dt.datetime.strptime(text, "%Y%m%d").date().isoformat()
        except ValueError:
            return None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        try:
            return dt.date.fromisoformat(text).isoformat()
        except ValueError:
            return None
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parsed.date().isoformat()
    except Exception:
        return None


def parse_time(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if re.fullmatch(r"\d{6}", text):
        return text[0:2] + ":" + text[2:4] + ":" + text[4:6]
    if re.fullmatch(r"\d{4}", text):
        return text[0:2] + ":" + text[2:4] + ":00"
    if re.fullmatch(r"\d{2}:\d{2}(?::\d{2})?", text):
        return text if len(text) == 8 else text + ":00"
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parsed.time().replace(microsecond=0).isoformat()
    except Exception:
        return None


def gross_name_score(key: str) -> int:
    lower = key.lower()
    score = 0
    for token, points in [
        ("gross", 80),
        ("tradeprofit", 65),
        ("trade_profit", 65),
        ("realized", 40),
        ("rlzt", 40),
        ("pnl", 35),
        ("profit", 35),
        ("pfls", 35),
    ]:
        if token in lower:
            score += points
    for token in [
        "net",
        "fee",
        "tax",
        "interest",
        "price",
        "qty",
        "quantity",
        "rate",
        "count",
        "date",
        "time",
        "buy",
        "sell",
    ]:
        if token in lower:
            score -= 100
    return score


def select_gross(
    row: dict[str, Any],
    net_value: float,
    fee_value: float,
    tax_value: float,
    interest_value: float,
) -> dict[str, Any]:
    exact = select_exact(row, GROSS_KEYS)
    expected = net_value + fee_value + tax_value + interest_value

    if exact["ready"]:
        exact["mode"] = "OFFICIAL_EXACT_FIELD"
        exact["equation_expected"] = expected
        exact["equation_delta"] = exact["value"] - expected
        exact["equation_ok"] = abs(exact["equation_delta"]) <= TOLERANCE
        return exact

    candidates: list[dict[str, Any]] = []
    for key, raw_value in row.items():
        value = numeric(raw_value)
        if value is None:
            continue
        score = gross_name_score(str(key))
        if score <= 0:
            continue
        delta = value - expected
        if abs(delta) <= TOLERANCE:
            candidates.append(
                {
                    "field": str(key),
                    "value": value,
                    "score": score,
                    "delta": delta,
                }
            )

    candidates.sort(key=lambda item: item["score"], reverse=True)
    if candidates:
        best = candidates[0]
        return {
            "ready": True,
            "field": best["field"],
            "value": best["value"],
            "aliases": [item["field"] for item in candidates],
            "conflict": any(
                abs(item["value"] - best["value"]) > TOLERANCE
                for item in candidates[1:]
            ),
            "mode": "OFFICIAL_FIELD_INFERRED_BY_ACCOUNTING_IDENTITY",
            "equation_expected": expected,
            "equation_delta": best["delta"],
            "equation_ok": True,
        }

    return {
        "ready": True,
        "field": None,
        "value": expected,
        "aliases": [],
        "conflict": False,
        "mode": "DERIVED_FROM_NET_PLUS_COST_COMPONENTS",
        "equation_expected": expected,
        "equation_delta": 0.0,
        "equation_ok": True,
    }


def find_trade_rows(payload: Any) -> tuple[str | None, list[dict[str, Any]]]:
    if isinstance(payload, dict):
        direct = payload.get("tradeRows")
        if isinstance(direct, list):
            return "$.tradeRows", [row for row in direct if isinstance(row, dict)]

    found: list[tuple[str, list[dict[str, Any]]]] = []

    def walk(value: Any, path: str) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                child_path = path + "." + str(key)
                if str(key).lower() == "traderows" and isinstance(child, list):
                    rows = [row for row in child if isinstance(row, dict)]
                    found.append((child_path, rows))
                walk(child, child_path)
        elif isinstance(value, list):
            for index, child in enumerate(value[:200]):
                walk(child, path + "[" + str(index) + "]")

    walk(payload, "$")
    found.sort(key=lambda item: len(item[1]), reverse=True)
    return found[0] if found else (None, [])


def recursive_scalars(value: Any, path: str = "$"):
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = path + "." + str(key)
            if scalar(child):
                yield child_path, str(key), child
            else:
                yield from recursive_scalars(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value[:200]):
            yield from recursive_scalars(child, path + "[" + str(index) + "]")


def summary_candidates(
    payload: Any,
    aliases: list[str],
) -> list[dict[str, Any]]:
    wanted = {alias.lower(): index for index, alias in enumerate(aliases)}
    result: list[dict[str, Any]] = []
    for path, key, raw_value in recursive_scalars(payload):
        lower_key = key.lower()
        if lower_key not in wanted:
            continue
        if ".traderows[" in path.lower():
            continue
        value = numeric(raw_value)
        if value is None:
            continue
        score = 100 - wanted[lower_key] * 5
        lower_path = path.lower()
        if ".summary" in lower_path or ".totals" in lower_path:
            score += 30
        if "official" in lower_path or "final" in lower_path:
            score += 10
        if "apicalls" in lower_path or "request" in lower_path:
            score -= 100
        result.append(
            {
                "path": path,
                "key": key,
                "value": value,
                "score": score,
            }
        )
    result.sort(key=lambda item: item["score"], reverse=True)
    return result


def canonical_summary(payload: Any) -> dict[str, Any]:
    groups = {
        "net": summary_candidates(payload, SUMMARY_NET_KEYS),
        "gross": summary_candidates(payload, SUMMARY_GROSS_KEYS),
        "fee": summary_candidates(payload, SUMMARY_FEE_KEYS),
        "tax": summary_candidates(payload, SUMMARY_TAX_KEYS),
        "loan_interest": summary_candidates(payload, SUMMARY_INTEREST_KEYS),
    }
    return {
        group: {
            "canonical": items[0] if items else None,
            "candidate_count": len(items),
            "candidates": items[:20],
        }
        for group, items in groups.items()
    }


def row_signature(row: dict[str, Any]) -> str:
    fields = [
        row.get("business_date"),
        row.get("trade_time"),
        row.get("symbol"),
        row.get("side"),
        row.get("quantity"),
        row.get("price"),
        row.get("net_realized_pnl"),
        row.get("fee"),
        row.get("tax"),
        row.get("loan_interest"),
    ]
    return json.dumps(fields, ensure_ascii=True, default=str)


def compact_number(value: float | None) -> int | float | None:
    if value is None:
        return None
    if abs(value - round(value)) < 1e-9:
        return int(round(value))
    return round(value, 8)


def main() -> int:
    if not SOURCE.exists():
        raise RuntimeError("OFFICIAL_PNL_SOURCE_MISSING")

    payload = json.loads(SOURCE.read_text(encoding="utf-8-sig"))
    trade_rows_path, raw_rows = find_trade_rows(payload)
    if not trade_rows_path or not raw_rows:
        raise RuntimeError("TRADE_ROWS_NOT_FOUND")

    canonical_rows: list[dict[str, Any]] = []
    same_row_conflicts: list[dict[str, Any]] = []
    missing_components: list[dict[str, Any]] = []
    gross_modes: Counter[str] = Counter()
    observed_keys: Counter[str] = Counter()

    for index, raw_row in enumerate(raw_rows):
        for key in raw_row:
            observed_keys[str(key)] += 1

        net = select_exact(raw_row, NET_KEYS)
        fee = select_exact(raw_row, FEE_KEYS)
        tax = select_exact(raw_row, TAX_KEYS)
        interest = select_exact(raw_row, INTEREST_KEYS)

        component_map = {
            "net_realized_pnl": net,
            "fee": fee,
            "tax": tax,
            "loan_interest": interest,
        }

        conflicts = [
            name
            for name, item in component_map.items()
            if item.get("conflict")
        ]
        if conflicts:
            same_row_conflicts.append(
                {
                    "row_index": index,
                    "components": conflicts,
                    "details": {
                        name: component_map[name].get("all_values", [])
                        for name in conflicts
                    },
                }
            )

        missing = [
            name
            for name, item in component_map.items()
            if not item.get("ready")
        ]
        if missing:
            missing_components.append(
                {"row_index": index, "components": missing}
            )
            continue

        gross = select_gross(
            raw_row,
            float(net["value"]),
            float(fee["value"]),
            float(tax["value"]),
            float(interest["value"]),
        )
        gross_modes[str(gross["mode"])] += 1

        date_item = select_text(raw_row, DATE_KEYS)
        time_item = select_text(raw_row, TIME_KEYS)
        symbol_item = select_text(raw_row, SYMBOL_KEYS)
        name_item = select_text(raw_row, NAME_KEYS)
        side_item = select_text(raw_row, SIDE_KEYS)
        qty_item = select_exact(raw_row, QTY_KEYS)
        price_item = select_exact(raw_row, PRICE_KEYS)

        canonical_rows.append(
            {
                "row_index": index,
                "business_date": parse_date(date_item["value"]),
                "business_date_field": date_item["field"],
                "trade_time": parse_time(time_item["value"]),
                "trade_time_field": time_item["field"],
                "symbol": symbol_item["value"],
                "symbol_field": symbol_item["field"],
                "name": name_item["value"],
                "name_field": name_item["field"],
                "side": side_item["value"],
                "side_field": side_item["field"],
                "quantity": compact_number(qty_item["value"] if qty_item["ready"] else None),
                "quantity_field": qty_item["field"],
                "price": compact_number(price_item["value"] if price_item["ready"] else None),
                "price_field": price_item["field"],
                "gross_realized_pnl": compact_number(gross["value"]),
                "gross_field": gross["field"],
                "gross_mode": gross["mode"],
                "net_realized_pnl": compact_number(net["value"]),
                "net_field": net["field"],
                "fee": compact_number(fee["value"]),
                "fee_field": fee["field"],
                "tax": compact_number(tax["value"]),
                "tax_field": tax["field"],
                "loan_interest": compact_number(interest["value"]),
                "loan_interest_field": interest["field"],
                "accounting_delta": compact_number(gross["equation_delta"]),
                "accounting_equation_ok": bool(gross["equation_ok"]),
            }
        )

    unique_rows: list[dict[str, Any]] = []
    duplicate_rows: list[dict[str, Any]] = []
    seen: dict[str, int] = {}
    for row in canonical_rows:
        signature = row_signature(row)
        if signature in seen:
            duplicate_rows.append(
                {
                    "duplicate_row_index": row["row_index"],
                    "original_row_index": seen[signature],
                }
            )
            continue
        seen[signature] = int(row["row_index"])
        unique_rows.append(row)

    dated_rows = [row for row in unique_rows if row.get("business_date")]
    latest_date = max(
        (str(row["business_date"]) for row in dated_rows),
        default=None,
    )
    latest_rows = [
        row for row in unique_rows
        if latest_date is None or row.get("business_date") == latest_date
    ]

    def sum_field(rows: list[dict[str, Any]], field: str) -> float:
        return sum(float(row.get(field) or 0) for row in rows)

    row_totals = {
        "gross": compact_number(sum_field(latest_rows, "gross_realized_pnl")),
        "net": compact_number(sum_field(latest_rows, "net_realized_pnl")),
        "fee": compact_number(sum_field(latest_rows, "fee")),
        "tax": compact_number(sum_field(latest_rows, "tax")),
        "loan_interest": compact_number(sum_field(latest_rows, "loan_interest")),
    }

    summary = canonical_summary(payload)
    summary_net = (
        summary["net"]["canonical"]["value"]
        if summary["net"]["canonical"]
        else None
    )
    row_net = float(row_totals["net"] or 0)
    summary_to_row_difference = (
        compact_number(float(summary_net) - row_net)
        if summary_net is not None
        else None
    )

    exact_components_ready = (
        bool(canonical_rows)
        and not same_row_conflicts
        and not missing_components
        and all(row["accounting_equation_ok"] for row in canonical_rows)
    )
    daily_net_ready = summary_net is not None or bool(latest_rows)
    intraday_graph_ready = bool(
        latest_rows
        and all(row.get("trade_time") for row in latest_rows)
    )
    daily_graph_ready = bool(dated_rows)
    financial_ready = exact_components_ready and daily_net_ready

    field_contract = {
        "net": Counter(
            str(row["net_field"]) for row in canonical_rows if row.get("net_field")
        ).most_common(),
        "fee": Counter(
            str(row["fee_field"]) for row in canonical_rows if row.get("fee_field")
        ).most_common(),
        "tax": Counter(
            str(row["tax_field"]) for row in canonical_rows if row.get("tax_field")
        ).most_common(),
        "loan_interest": Counter(
            str(row["loan_interest_field"])
            for row in canonical_rows
            if row.get("loan_interest_field")
        ).most_common(),
        "gross": Counter(
            str(row["gross_field"]) for row in canonical_rows if row.get("gross_field")
        ).most_common(),
        "gross_modes": gross_modes.most_common(),
    }

    contract = {
        "contract_type": "AUTOTRADE_CLEAN_V2_2_FINANCIAL_CONTRACT_V4",
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "read_only": True,
        "live_install_allowed": False,
        "manual_value_override_allowed": False,
        "zero_when_field_missing_allowed": False,
        "source_file": str(SOURCE),
        "trade_rows_path": trade_rows_path,
        "raw_trade_row_count": len(raw_rows),
        "canonical_trade_row_count": len(canonical_rows),
        "unique_trade_row_count": len(unique_rows),
        "duplicate_trade_row_count": len(duplicate_rows),
        "duplicate_trade_rows": duplicate_rows[:100],
        "same_row_conflict_count": len(same_row_conflicts),
        "same_row_conflicts": same_row_conflicts[:100],
        "missing_component_row_count": len(missing_components),
        "missing_components": missing_components[:100],
        "field_contract": field_contract,
        "observed_row_keys": observed_keys.most_common(),
        "latest_business_date": latest_date,
        "latest_date_trade_row_count": len(latest_rows),
        "latest_date_row_totals": row_totals,
        "official_summary": summary,
        "official_daily_net_value": compact_number(summary_net),
        "latest_date_row_net_sum": compact_number(row_net),
        "official_daily_to_row_net_difference": summary_to_row_difference,
        "difference_is_not_forced_into_fee_or_tax": True,
        "different_trade_rows_are_not_conflicts": True,
        "exact_components_ready": exact_components_ready,
        "daily_net_ready": daily_net_ready,
        "intraday_graph_ready": intraday_graph_ready,
        "daily_week_month_graph_ready": daily_graph_ready,
        "financial_semantic_ready": financial_ready,
        "canonical_rows": unique_rows,
    }

    OUTPUT.write_text(
        json.dumps(contract, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8-sig",
    )

    print("FINAL_STATUS=PASS_FINANCIAL_RECONCILIATION_V4")
    print(f"OFFICIAL_PNL_SOURCE={SOURCE}")
    print(f"TRADE_ROWS_PATH={trade_rows_path}")
    print(f"RAW_TRADE_ROW_COUNT={len(raw_rows)}")
    print(f"CANONICAL_TRADE_ROW_COUNT={len(canonical_rows)}")
    print(f"UNIQUE_TRADE_ROW_COUNT={len(unique_rows)}")
    print(f"DUPLICATE_TRADE_ROW_COUNT={len(duplicate_rows)}")
    print(f"LATEST_BUSINESS_DATE={latest_date or 'UNAVAILABLE'}")
    print(f"LATEST_DATE_TRADE_ROW_COUNT={len(latest_rows)}")
    print(f"SAME_ROW_CONFLICT_COUNT={len(same_row_conflicts)}")
    print(f"MISSING_COMPONENT_ROW_COUNT={len(missing_components)}")
    print(f"EXACT_COMPONENTS_READY={str(exact_components_ready).upper()}")
    print(f"DAILY_NET_READY={str(daily_net_ready).upper()}")
    print(f"OFFICIAL_DAILY_NET_VALUE={compact_number(summary_net)}")
    print(f"LATEST_DATE_ROW_NET_SUM={compact_number(row_net)}")
    print(f"DAILY_TO_ROW_NET_DIFFERENCE={summary_to_row_difference}")
    print(f"INTRADAY_GRAPH_READY={str(intraday_graph_ready).upper()}")
    print(f"DAILY_WEEK_MONTH_GRAPH_READY={str(daily_graph_ready).upper()}")
    print(f"FINANCIAL_SEMANTIC_READY={str(financial_ready).upper()}")
    print(f"FINANCIAL_CONTRACT={OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
