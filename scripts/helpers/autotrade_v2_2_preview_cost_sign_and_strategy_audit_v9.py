# -*- coding: utf-8 -*-
from __future__ import annotations

import datetime as dt
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(sys.argv[1])
DATABASE = Path(sys.argv[2])
SOURCE_PREVIEW = Path(sys.argv[3])
OUTPUT_DIR = Path(sys.argv[4])

SOURCE_HTML = SOURCE_PREVIEW / "index.html"
SOURCE_DATA = SOURCE_PREVIEW / "preview_data.js"
OUTPUT_HTML = OUTPUT_DIR / "index.html"
OUTPUT_DATA = OUTPUT_DIR / "preview_data.js"
OUTPUT_AUDIT = OUTPUT_DIR / "STRATEGY_PROVENANCE_AUDIT_V9.json"
OUTPUT_MANIFEST = OUTPUT_DIR / "PREVIEW_CORRECTION_MANIFEST_V9.json"

VALID_ACTIONS = {"BUY", "HOLD", "SELL_ALL", "SWITCH", "WAIT"}
ACTION_KO = {
    "BUY": "매수",
    "HOLD": "보유 유지",
    "SELL_ALL": "전량 매도",
    "SWITCH": "종목 전환",
    "WAIT": "대기",
}
TOKEN_KO = {
    "sixCyclePersistence": "최근 6개 평가 주기에서 조건이 연속 유지됨",
    "entryPriceStructure": "진입 가격 구조 조건을 충족함",
    "instrumentRoleClassified": "시장 내 종목 역할 분류가 완료됨",
    "relativeFalseSignalCheck": "상대 비교 오신호 점검을 통과함",
    "currentVolumeStructure": "현재 거래량 구조 조건을 확인함",
    "marketRegimeAligned": "현재 장세와 종목 방향이 일치함",
    "liquidityReady": "주문 가능한 유동성 조건을 충족함",
    "riskGatePassed": "위험 제한 조건을 통과함",
    "momentumConfirmed": "가격 추진력 조건을 확인함",
    "trendPersistence": "추세 지속 조건을 확인함",
}
COARSE_TERMS = {
    "상승장", "하락장", "보합장", "매수", "매도", "보유", "대기",
    "BUY", "HOLD", "SELL", "WAIT", "SWITCH",
}


def load_js_payload(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8-sig")
    match = re.search(r"window\.__AUTOTRADE_PREVIEW__\s*=\s*(\{.*\})\s*;\s*$", text, re.S)
    if not match:
        raise RuntimeError("PREVIEW_DATA_PAYLOAD_NOT_FOUND")
    payload = json.loads(match.group(1))
    if not isinstance(payload, dict):
        raise RuntimeError("PREVIEW_DATA_ROOT_NOT_OBJECT")
    return payload


def write_js_payload(path: Path, payload: dict[str, Any]) -> None:
    content = "window.__AUTOTRADE_PREVIEW__ = " + json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        default=str,
    ).replace("</", "<\\/") + ";\n"
    path.write_text(content, encoding="utf-8-sig")


def walk(value: Any, path: str = "$") -> Iterable[tuple[str, Any]]:
    yield path, value
    if isinstance(value, dict):
        for key, item in value.items():
            yield from walk(item, path + "." + str(key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from walk(item, path + "[" + str(index) + "]")


def normalized_key(path: str) -> str:
    final = re.sub(r"\[\d+\]$", "", path).rsplit(".", 1)[-1]
    return re.sub(r"[^a-z0-9]", "", final.lower())


def is_scalar(value: Any) -> bool:
    return value is None or isinstance(value, (str, int, float, bool))


def clean_text(value: Any, limit: int = 1200) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.replace("\r", " ").replace("\n", " ").strip()
    return text[:limit] if text else None


def strategy_related(path: str) -> bool:
    lower = path.lower()
    return any(token in lower for token in [
        "stage13l", "strategy", "decision", "marketregime", "marketcontext",
        "risk", "gate", "candidate", "executionaction", "promotionreason",
    ])


def reason_related(path: str) -> bool:
    key = normalized_key(path)
    return any(token in key for token in ["reason", "rationale", "evidence", "basis", "explanation", "why"])


def action_related(path: str) -> bool:
    key = normalized_key(path)
    return key in {"action", "executionaction", "strategyaction", "decisionaction", "recommendedaction"}


def time_related(path: str) -> bool:
    key = normalized_key(path)
    return key in {"timestamp", "ksttimestamp", "capturedat", "createdat", "decisiontime", "strategytime"}


def meaningful_reason(text: str | None) -> bool:
    if not text:
        return False
    compact = re.sub(r"[\s,;|/]+", "", text).upper()
    if not compact:
        return False
    if text.strip() in COARSE_TERMS:
        return False
    return len(compact) >= 12


def collect_current_strategy(snapshot: Any) -> dict[str, Any]:
    actions: list[dict[str, Any]] = []
    reasons: list[dict[str, Any]] = []
    times: list[dict[str, Any]] = []
    context: list[dict[str, Any]] = []

    for path, value in walk(snapshot):
        if not strategy_related(path) or not is_scalar(value):
            continue
        if action_related(path):
            action = str(value).strip().upper() if value is not None else ""
            if action in VALID_ACTIONS:
                actions.append({"path": path, "value": action})
        elif reason_related(path):
            text = clean_text(value, 2500)
            if text:
                reasons.append({"path": path, "value": text, "detailed": meaningful_reason(text)})
        elif time_related(path):
            text = clean_text(value, 200)
            if text:
                times.append({"path": path, "value": text})
        elif isinstance(value, (int, float, bool)) and not isinstance(value, str):
            context.append({"path": path, "value": value})

    actions.sort(key=lambda row: ("stage13l" in row["path"].lower(), row["path"]), reverse=True)
    reasons.sort(key=lambda row: (row["detailed"], "stage13l" in row["path"].lower(), len(row["value"])), reverse=True)
    times.sort(key=lambda row: ("stage13l" in row["path"].lower(), row["path"]), reverse=True)

    selected_action = actions[0] if actions else None
    selected_reason = next((row for row in reasons if row["detailed"]), reasons[0] if reasons else None)
    detailed_ready = bool(selected_action and selected_reason and selected_reason.get("detailed") and len(context) >= 3)

    return {
        "action": selected_action,
        "reason": selected_reason,
        "timestamp": times[0] if times else None,
        "reason_candidate_count": len(reasons),
        "numeric_boolean_context_count": len(context),
        "context_examples": context[:80],
        "all_reason_candidates": reasons[:80],
        "detailed_current_ready": detailed_ready,
        "coarse_only": bool(selected_action and not detailed_ready),
    }


def parse_json_cell(value: Any) -> Any:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text or text[0] not in "[{":
        return None
    try:
        return json.loads(text)
    except Exception:
        return None


def inspect_mapping(mapping: dict[str, Any], location: str) -> dict[str, Any] | None:
    action = None
    reason = None
    timestamp = None
    numeric_context = 0

    for key, value in mapping.items():
        path = location + "." + str(key)
        key_norm = normalized_key(path)
        if key_norm in {"action", "executionaction", "strategyaction", "decisionaction", "recommendedaction"}:
            candidate = str(value).strip().upper() if value is not None else ""
            if candidate in VALID_ACTIONS:
                action = {"field": str(key), "value": candidate}
        elif any(token in key_norm for token in ["reason", "rationale", "evidence", "basis", "explanation"]):
            text = clean_text(value, 3000)
            if meaningful_reason(text):
                reason = {"field": str(key), "value": text}
        elif key_norm in {"timestamp", "ksttimestamp", "capturedat", "createdat", "decisiontime", "strategytime"}:
            text = clean_text(value, 200)
            if text:
                timestamp = {"field": str(key), "value": text}
        elif isinstance(value, (int, float, bool)):
            numeric_context += 1

        nested = parse_json_cell(value)
        if isinstance(nested, dict):
            nested_result = inspect_mapping(nested, path)
            if nested_result:
                action = action or nested_result.get("action")
                reason = reason or nested_result.get("reason")
                timestamp = timestamp or nested_result.get("timestamp")
                numeric_context += int(nested_result.get("numeric_context", 0))

    if action or reason or timestamp:
        return {
            "action": action,
            "reason": reason,
            "timestamp": timestamp,
            "numeric_context": numeric_context,
        }
    return None


def audit_history(database: Path) -> dict[str, Any]:
    table_results: list[dict[str, Any]] = []
    detailed_records: list[dict[str, Any]] = []

    connection = sqlite3.connect("file:" + str(database) + "?mode=ro", uri=True, timeout=5)
    connection.row_factory = sqlite3.Row
    try:
        tables = [str(row[0]) for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()]
        for table in tables:
            quoted = '"' + table.replace('"', '""') + '"'
            columns = [str(row[1]) for row in connection.execute("PRAGMA table_info(" + quoted + ")").fetchall()]
            combined = (table + "|" + "|".join(columns)).lower()
            if not any(token in combined for token in ["strategy", "decision", "history", "research", "snapshot"]):
                continue
            try:
                rows = connection.execute("SELECT * FROM " + quoted + " ORDER BY rowid DESC LIMIT 300").fetchall()
            except Exception:
                rows = connection.execute("SELECT * FROM " + quoted + " LIMIT 300").fetchall()
            detailed_count = 0
            coarse_count = 0
            for index, row in enumerate(rows):
                mapping = {str(key): row[key] for key in row.keys()}
                inspected = inspect_mapping(mapping, table + "[" + str(index) + "]")
                if not inspected:
                    continue
                is_detailed = bool(
                    inspected.get("action")
                    and inspected.get("reason")
                    and inspected.get("timestamp")
                    and int(inspected.get("numeric_context", 0)) >= 3
                )
                if is_detailed:
                    detailed_count += 1
                    if len(detailed_records) < 30:
                        detailed_records.append({"table": table, **inspected})
                else:
                    coarse_count += 1
            table_results.append({
                "table": table,
                "row_count_inspected": len(rows),
                "detailed_record_count": detailed_count,
                "coarse_or_incomplete_record_count": coarse_count,
                "columns": columns,
            })
    finally:
        connection.close()

    detailed_total = sum(row["detailed_record_count"] for row in table_results)
    return {
        "tables": table_results,
        "detailed_record_count": detailed_total,
        "detailed_history_ready": detailed_total > 0,
        "examples": detailed_records,
    }


def translate_candidate_reason(reason: Any) -> str:
    text = clean_text(reason, 3000)
    if not text:
        return "자동 선정 근거 원문이 없습니다."
    tokens = [item.strip() for item in re.split(r"[,;|]", text) if item.strip()]
    translated: list[str] = []
    unknown: list[str] = []
    for token in tokens:
        if token in TOKEN_KO:
            translated.append(TOKEN_KO[token])
        else:
            unknown.append(token)
    if translated and unknown:
        return "\n".join("• " + item for item in translated) + "\n• 추가 원본 조건: " + ", ".join(unknown)
    if translated:
        return "\n".join("• " + item for item in translated)
    return "원본 자동 판단 조건: " + text


def patch_html(html: str) -> str:
    html = html.replace("자동매매 V2.2 오프라인 검증 미리보기", "자동매매 V2.2 오프라인 검증 미리보기 V9")
    old_summary = "metricCard('수수료·세금·이자',latest.total_cost,'수수료 '+won(latest.fee)+' · 세금 '+won(latest.tax)+' · 이자 '+won(latest.interest),'공식 거래행 자동 합산')"
    new_summary = "metricCard('총비용',latest.total_cost===null?null:-Math.abs(latest.total_cost),'수수료 '+won(latest.fee===null?null:-Math.abs(latest.fee))+' · 세금 '+won(latest.tax===null?null:-Math.abs(latest.tax))+' · 이자 '+won(latest.interest===null?null:-Math.abs(latest.interest)),'공식 거래행에서 자동 합산한 차감 비용')"
    if old_summary not in html:
        raise RuntimeError("COST_SUMMARY_PATCH_TARGET_NOT_FOUND")
    html = html.replace(old_summary, new_summary)

    old_detail = "['수수료',won(p.fee)],['세금',won(p.tax)],['대출이자',won(p.interest)]"
    new_detail = "['수수료',won(p.fee===null?null:-Math.abs(p.fee))],['세금',won(p.tax===null?null:-Math.abs(p.tax))],['대출이자',won(p.interest===null?null:-Math.abs(p.interest))]"
    if old_detail not in html:
        raise RuntimeError("COST_DETAIL_PATCH_TARGET_NOT_FOUND")
    html = html.replace(old_detail, new_detail)

    old_action = "text(action,d.strategy.action_ready?d.strategy.action:'전략 행동 미확정');"
    new_action = "text(action,d.strategy.action_korean??(d.strategy.action_ready?d.strategy.action:'전략 행동 미확정'));"
    if old_action not in html:
        raise RuntimeError("STRATEGY_ACTION_PATCH_TARGET_NOT_FOUND")
    html = html.replace(old_action, new_action)

    old_reason = "text(reason,d.strategy.reason_ready?d.strategy.reason:'전략 근거를 정확한 전략 필드에서 자동 연결하지 못했습니다. 임의 문구를 표시하지 않습니다.');"
    new_reason = "text(reason,d.strategy.detailed_reason_text??(d.strategy.reason_ready?d.strategy.reason:'전략 근거를 정확한 전략 필드에서 자동 연결하지 못했습니다. 임의 문구를 표시하지 않습니다.'));"
    if old_reason not in html:
        raise RuntimeError("STRATEGY_REASON_PATCH_TARGET_NOT_FOUND")
    html = html.replace(old_reason, new_reason)

    html = html.replace("text(document.getElementById('modalReason'),c.reason);", "text(document.getElementById('modalReason'),c.reason_korean??c.reason);")
    html = html.replace("['수동 값 입력','사용하지 않음']", "['수동 값 입력','사용하지 않음'],['상세 전략 기록',d.strategy.recording_audit?.future_detailed_recording_confirmed?'상세 기록 확인':'상세 기록 보강 필요']")
    return html


def main() -> int:
    for required in [SOURCE_HTML, SOURCE_DATA, DATABASE]:
        if not required.exists():
            raise RuntimeError("REQUIRED_SOURCE_MISSING:" + str(required))

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    payload = load_js_payload(SOURCE_DATA)
    snapshot_path = Path(str(payload.get("sources", {}).get("snapshot", "")))
    if not snapshot_path.exists():
        raise RuntimeError("SNAPSHOT_SOURCE_MISSING:" + str(snapshot_path))
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8-sig"))

    current = collect_current_strategy(snapshot)
    history = audit_history(DATABASE)
    future_confirmed = bool(current["detailed_current_ready"] and history["detailed_history_ready"])
    audit = {
        "contract_type": "AUTOTRADE_CLEAN_STRATEGY_PROVENANCE_AUDIT_V9",
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "read_only": True,
        "manual_value_input_used": False,
        "live_strategy_modified": False,
        "current": current,
        "history": history,
        "future_detailed_recording_confirmed": future_confirmed,
        "required_future_fields": [
            "판단시각", "전략행동", "전략근거 원문", "시장 장세 원본 수치",
            "후보 점수와 선정근거", "위험 게이트별 결과", "계좌 세대와 자료 해시",
            "주문 실행 또는 미실행 사유", "체결 결과와 확정손익 연결",
        ],
        "coarse_label_only_is_forbidden": True,
    }
    OUTPUT_AUDIT.write_text(json.dumps(audit, ensure_ascii=False, indent=2, default=str), encoding="utf-8-sig")

    strategy = payload.setdefault("strategy", {})
    selected_action = current.get("action") or {}
    selected_reason = current.get("reason") or {}
    if selected_action.get("value"):
        strategy["action"] = selected_action["value"]
        strategy["action_ready"] = True
        strategy["action_path"] = selected_action.get("path")
        strategy["action_korean"] = ACTION_KO.get(selected_action["value"], selected_action["value"])
    if selected_reason.get("value") and selected_reason.get("detailed"):
        strategy["reason"] = selected_reason["value"]
        strategy["reason_ready"] = True
        strategy["reason_path"] = selected_reason.get("path")
        strategy["detailed_reason_text"] = selected_reason["value"]
    else:
        strategy["detailed_reason_text"] = "현재 원본에서 수치·위험조건·후보근거를 포함한 전용 전략 사유 필드가 확정되지 않았습니다. 단순 장세명이나 행동명만으로 전략을 설명하지 않습니다."
    strategy["recording_audit"] = {
        "current_detailed_ready": current["detailed_current_ready"],
        "history_detailed_ready": history["detailed_history_ready"],
        "future_detailed_recording_confirmed": future_confirmed,
        "audit_file": str(OUTPUT_AUDIT),
    }

    for candidate in payload.get("candidates", {}).get("items", []):
        if isinstance(candidate, dict):
            candidate["reason_korean"] = translate_candidate_reason(candidate.get("reason"))
            action = str(candidate.get("action") or "").strip().upper()
            if action in ACTION_KO:
                candidate["action_korean"] = ACTION_KO[action]

    html = patch_html(SOURCE_HTML.read_text(encoding="utf-8-sig"))
    forbidden_literals = ["-8617", "-8,617", "-7140", "-7,140", "1477", "1,477", "1404", "1,404"]
    found = [item for item in forbidden_literals if item in html]
    if found:
        raise RuntimeError("HARDCODED_FINANCIAL_LITERAL_IN_HTML:" + ",".join(found))
    if re.search(r"<input\b|contenteditable\s*=", html, re.I):
        raise RuntimeError("MANUAL_INPUT_UI_PRESENT")

    OUTPUT_HTML.write_text(html, encoding="utf-8-sig")
    write_js_payload(OUTPUT_DATA, payload)

    manifest = {
        "contract_type": "AUTOTRADE_CLEAN_V2_2_PREVIEW_CORRECTION_MANIFEST_V9",
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "preview_only": True,
        "live_install_allowed": False,
        "manual_value_input_used": False,
        "hardcoded_financial_values_used": False,
        "cost_sign_display_corrected": True,
        "fee_display_policy": "NEGATIVE_ABSOLUTE_FROM_SOURCE",
        "tax_display_policy": "NEGATIVE_ABSOLUTE_FROM_SOURCE",
        "interest_display_policy": "NEGATIVE_ABSOLUTE_FROM_SOURCE",
        "strategy_audit_file": str(OUTPUT_AUDIT),
        "future_detailed_recording_confirmed": future_confirmed,
        "current_detailed_strategy_ready": current["detailed_current_ready"],
        "historical_detailed_strategy_ready": history["detailed_history_ready"],
        "source_preview": str(SOURCE_PREVIEW),
        "output_html": str(OUTPUT_HTML),
    }
    OUTPUT_MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8-sig")

    print("FINAL_STATUS=PASS_PREVIEW_COST_SIGN_AND_STRATEGY_AUDIT_V9")
    print("COST_SIGN_DISPLAY_CORRECTED=TRUE")
    print("FEE_DISPLAY_NEGATIVE=TRUE")
    print("TAX_DISPLAY_NEGATIVE=TRUE")
    print("INTEREST_DISPLAY_NEGATIVE=TRUE")
    print("MANUAL_VALUE_INPUT_USED=FALSE")
    print("HARDCODED_FINANCIAL_VALUES_USED=FALSE")
    print("CURRENT_DETAILED_STRATEGY_READY=" + str(current["detailed_current_ready"]).upper())
    print("HISTORICAL_DETAILED_STRATEGY_READY=" + str(history["detailed_history_ready"]).upper())
    print("FUTURE_DETAILED_RECORDING_CONFIRMED=" + str(future_confirmed).upper())
    print("CURRENT_STRATEGY_REASON_CANDIDATE_COUNT=" + str(current["reason_candidate_count"]))
    print("CURRENT_STRATEGY_CONTEXT_FIELD_COUNT=" + str(current["numeric_boolean_context_count"]))
    print("HISTORICAL_DETAILED_RECORD_COUNT=" + str(history["detailed_record_count"]))
    print("STRATEGY_AUDIT=" + str(OUTPUT_AUDIT))
    print("PREVIEW_HTML=" + str(OUTPUT_HTML))
    print("PREVIEW_MANIFEST=" + str(OUTPUT_MANIFEST))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
