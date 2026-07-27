from __future__ import annotations

import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any

EVIDENCE_ROOT = Path(sys.argv[1])
LAB_ROOT = Path(sys.argv[2])
OUTPUT = Path(sys.argv[3])

VALID_ACTIONS = {"BUY", "HOLD", "SELL_ALL", "SWITCH", "WAIT"}


def latest_manifest() -> Path:
    items = sorted(
        EVIDENCE_ROOT.glob("AUDIT_V2_*/READ_ONLY_EVIDENCE_AUDIT_V2.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not items:
        raise RuntimeError("LATEST_EVIDENCE_MANIFEST_NOT_FOUND")
    return items[0]


def latest_selection() -> Path | None:
    items = sorted(
        LAB_ROOT.glob("source_selection_v2_*/OFFLINE_SOURCE_CONTRACT_V2.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    return items[0] if items else None


def normalize_group(value: Any) -> str:
    return str(value or "").strip().lower()


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


def nonempty_text(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    return text if text else None


def parse_time(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).isoformat()
    except Exception:
        if re.fullmatch(r"\d{8}", text):
            return text
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            return text
    return None


def parent_path(path: str) -> str:
    text = str(path)
    if "." in text:
        return text.rsplit(".", 1)[0]
    return "$"


def path_score(text: str, positive: list[str], negative: list[str]) -> int:
    lower = text.lower()
    score = 0
    for token in positive:
        if token.lower() in lower:
            score += 20
    for token in negative:
        if token.lower() in lower:
            score -= 60
    return score


def normalize_items(payload: dict[str, Any]) -> list[dict[str, Any]]:
    raw = payload.get("json_evidence", [])
    if not isinstance(raw, list):
        raise RuntimeError("INVALID_JSON_EVIDENCE")

    result: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        copy = dict(item)
        copy["group"] = normalize_group(copy.get("group"))
        copy["file"] = str(copy.get("file", ""))
        copy["field"] = str(copy.get("field", ""))
        copy["parent"] = parent_path(copy["field"])
        result.append(copy)
    return result


def financial_contract(items: list[dict[str, Any]]) -> dict[str, Any]:
    wanted = {
        "realized_net_pnl",
        "gross_trade_pnl",
        "fee",
        "tax",
        "loan_interest",
    }
    rows: dict[tuple[str, str], dict[str, Any]] = {}
    duplicate_conflicts: list[dict[str, Any]] = []

    for item in items:
        group = item["group"]
        if group not in wanted:
            continue

        file_path = item["file"]
        field = item["field"]
        combined = (file_path + "|" + field).lower()

        if "fact_dashboard_v2" not in combined:
            continue
        if "official_pnl_fact_latest.json" not in combined:
            continue
        if ".apicalls" in combined or "api_calls" in combined:
            continue

        value = numeric(item.get("value"))
        if value is None:
            continue

        key = (file_path, item["parent"])
        record = rows.setdefault(
            key,
            {
                "file": file_path,
                "parent": item["parent"],
                "values": {},
                "fields": {},
            },
        )

        previous = record["values"].get(group)
        if previous is not None and previous != value:
            duplicate_conflicts.append(
                {
                    "file": file_path,
                    "parent": item["parent"],
                    "group": group,
                    "values": [previous, value],
                }
            )

        record["values"][group] = value
        record["fields"][group] = field

    valid_rows: list[dict[str, Any]] = []
    for record in rows.values():
        values = record["values"]
        if {"realized_net_pnl", "fee", "tax"}.issubset(values):
            valid_rows.append(record)

    valid_rows.sort(
        key=lambda row: (
            path_score(
                row["file"] + "|" + row["parent"],
                ["official", "latest", "traderows"],
                ["backup", "audit", "sample", "synthetic"],
            ),
            row["parent"],
        ),
        reverse=True,
    )

    field_templates: dict[str, str] = {}
    if valid_rows:
        for group, field in valid_rows[0]["fields"].items():
            field_templates[group] = re.sub(r"\[\d+\]", "[*]", field)

    return {
        "ready": bool(valid_rows) and not duplicate_conflicts,
        "source_file": valid_rows[0]["file"] if valid_rows else None,
        "valid_trade_row_count": len(valid_rows),
        "duplicate_same_row_conflict_count": len(duplicate_conflicts),
        "duplicate_same_row_conflicts": duplicate_conflicts[:20],
        "field_templates": field_templates,
        "different_trade_rows_are_not_conflicts": True,
    }


def strategy_contract(items: list[dict[str, Any]]) -> dict[str, Any]:
    groups_by_file: dict[str, dict[str, list[dict[str, Any]]]] = {}

    for item in items:
        group = item["group"]
        if group not in {"strategy_action", "strategy_reason", "strategy_time"}:
            continue

        combined = (item["file"] + "|" + item["field"]).lower()
        if any(
            token in combined
            for token in [
                "account_authority",
                "canonical_account_authority",
                "official_pnl_fact",
                ".reconciliation",
                "authorityreason",
            ]
        ):
            continue

        bucket = groups_by_file.setdefault(
            item["file"],
            {
                "strategy_action": [],
                "strategy_reason": [],
                "strategy_time": [],
            },
        )
        bucket[group].append(item)

    current_candidates: list[dict[str, Any]] = []
    history_sources: list[dict[str, Any]] = []

    for file_path, groups in groups_by_file.items():
        actions = [
            item
            for item in groups["strategy_action"]
            if str(item.get("value", "")).strip().upper() in VALID_ACTIONS
        ]
        reasons = [
            item
            for item in groups["strategy_reason"]
            if nonempty_text(item.get("value"))
        ]
        times = [
            item
            for item in groups["strategy_time"]
            if parse_time(item.get("value"))
        ]

        if actions and reasons and times:
            score = path_score(
                file_path,
                [
                    "main_market_validation",
                    "strategy",
                    "decision",
                    "intraday",
                    "stage13l",
                    "latest",
                ],
                [
                    "backup",
                    "archive",
                    "audit",
                    "sample",
                    "synthetic",
                    "failed",
                    "rollback",
                ],
            )
            score += 100
            current_candidates.append(
                {
                    "file": file_path,
                    "action_field": actions[0]["field"],
                    "reason_field": reasons[0]["field"],
                    "time_field": times[0]["field"],
                    "action": str(actions[0].get("value", "")).strip().upper(),
                    "score": score,
                }
            )

        lower_path = file_path.lower()
        if any(
            token in lower_path
            for token in ["decision_history", "strategy_history", "decision", "strategy"]
        ):
            distinct_times = {
                parse_time(item.get("value"))
                for item in groups["strategy_time"]
                if parse_time(item.get("value"))
            }
            if distinct_times:
                history_sources.append(
                    {
                        "file": file_path,
                        "distinct_time_count": len(distinct_times),
                        "has_action": any(
                            str(item.get("value", "")).strip().upper() in VALID_ACTIONS
                            for item in groups["strategy_action"]
                        ),
                        "has_reason": any(
                            nonempty_text(item.get("value"))
                            for item in groups["strategy_reason"]
                        ),
                    }
                )

    current_candidates.sort(key=lambda row: row["score"], reverse=True)
    current = current_candidates[0] if current_candidates else None

    history_ready = any(
        row["has_action"] and row["has_reason"]
        for row in history_sources
    ) or len(current_candidates) >= 2

    return {
        "current_ready": current is not None,
        "history_ready": history_ready,
        "current": current,
        "history_sources": history_sources[:20],
        "rejected_reconciliation_reason": True,
        "rejected_pnl_capture_time_as_strategy_time": True,
    }


def candidate_contract(items: list[dict[str, Any]]) -> dict[str, Any]:
    records: dict[tuple[str, str], dict[str, list[dict[str, Any]]]] = {}

    for item in items:
        group = item["group"]
        if group not in {"candidate_reason", "candidate_score"}:
            continue

        combined = (item["file"] + "|" + item["field"]).lower()
        if any(
            token in combined
            for token in [
                "account_authority",
                "authoritativeaccountcandidate",
                "authorityscore",
                "authorityreasons",
                "reconciliation",
            ]
        ):
            continue

        key = (item["file"], item["parent"])
        bucket = records.setdefault(
            key,
            {"candidate_reason": [], "candidate_score": []},
        )
        bucket[group].append(item)

    candidates: list[dict[str, Any]] = []

    for (file_path, parent), groups in records.items():
        reasons = [
            item
            for item in groups["candidate_reason"]
            if nonempty_text(item.get("value"))
        ]
        scores = [
            item
            for item in groups["candidate_score"]
            if numeric(item.get("value")) is not None
        ]

        if not reasons or not scores:
            continue

        score = path_score(
            file_path + "|" + parent,
            ["candidate", "top5", "ranking", "market", "research", "latest"],
            ["account_authority", "backup", "archive", "audit", "sample", "synthetic"],
        )
        score += 100

        candidates.append(
            {
                "file": file_path,
                "parent": parent,
                "reason_field": reasons[0]["field"],
                "score_field": scores[0]["field"],
                "selection_score": score,
            }
        )

    candidates.sort(key=lambda row: row["selection_score"], reverse=True)

    return {
        "ready": bool(candidates),
        "canonical_record": candidates[0] if candidates else None,
        "candidate_record_count": len(candidates),
        "rejected_account_authority_candidates": True,
    }


def generation_contract(items: list[dict[str, Any]]) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []

    for item in items:
        if item["group"] != "generation":
            continue

        combined = (item["file"] + "|" + item["field"]).lower()
        score = 0

        if "accountgeneration" in combined or "account_generation" in combined:
            score += 100
        if "canonical_account_authority_v9" in combined:
            score += 60
        if "verify_latest.json" in combined:
            score += 40
        if "lineage" in combined:
            score += 20
        if any(token in combined for token in ["backup", "archive", "audit", "sample"]):
            score -= 50

        candidates.append(
            {
                "file": item["file"],
                "field": item["field"],
                "score": score,
            }
        )

    candidates.sort(key=lambda row: row["score"], reverse=True)

    return {
        "ready": bool(candidates),
        "canonical": candidates[0] if candidates else None,
    }


def main() -> int:
    manifest_path = latest_manifest()
    previous_selection = latest_selection()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    items = normalize_items(manifest)

    financial = financial_contract(items)
    strategy = strategy_contract(items)
    candidate = candidate_contract(items)
    generation = generation_contract(items)

    ready = (
        financial["ready"]
        and strategy["current_ready"]
        and strategy["history_ready"]
        and candidate["ready"]
        and generation["ready"]
    )

    output = {
        "contract_type": "AUTOTRADE_CLEAN_V2_2_SEMANTIC_SOURCE_CONTRACT_V3",
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "read_only": True,
        "live_install_allowed": False,
        "manual_value_override_allowed": False,
        "zero_when_unconfirmed_allowed": False,
        "source_manifest": str(manifest_path),
        "previous_selection_contract": (
            str(previous_selection) if previous_selection else None
        ),
        "financial": financial,
        "strategy": strategy,
        "candidate": candidate,
        "generation": generation,
        "all_offline_preview_inputs_ready": ready,
    }

    OUTPUT.write_text(
        json.dumps(output, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8-sig",
    )

    print("FINAL_STATUS=PASS_SEMANTIC_SOURCE_REVIEW_V3")
    print(f"FINANCIAL_SEMANTIC_READY={str(financial['ready']).upper()}")
    print(f"FINANCIAL_VALID_TRADE_ROW_COUNT={financial['valid_trade_row_count']}")
    print(
        "FINANCIAL_SAME_ROW_CONFLICT_COUNT="
        + str(financial["duplicate_same_row_conflict_count"])
    )
    print(f"STRATEGY_CURRENT_READY={str(strategy['current_ready']).upper()}")
    print(f"STRATEGY_HISTORY_READY={str(strategy['history_ready']).upper()}")

    if strategy["current"]:
        current = strategy["current"]
        print(f"STRATEGY_CURRENT_FILE={current['file']}")
        print(f"STRATEGY_ACTION_FIELD={current['action_field']}")
        print(f"STRATEGY_REASON_FIELD={current['reason_field']}")
        print(f"STRATEGY_TIME_FIELD={current['time_field']}")

    print(f"CANDIDATE_SEMANTIC_READY={str(candidate['ready']).upper()}")
    print(f"CANDIDATE_RECORD_COUNT={candidate['candidate_record_count']}")

    if candidate["canonical_record"]:
        selected = candidate["canonical_record"]
        print(f"CANDIDATE_FILE={selected['file']}")
        print(f"CANDIDATE_PARENT={selected['parent']}")
        print(f"CANDIDATE_REASON_FIELD={selected['reason_field']}")
        print(f"CANDIDATE_SCORE_FIELD={selected['score_field']}")

    print(f"GENERATION_READY={str(generation['ready']).upper()}")
    print(f"ALL_OFFLINE_PREVIEW_INPUTS_READY={str(ready).upper()}")
    print(f"SEMANTIC_CONTRACT={OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
