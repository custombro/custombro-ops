from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(sys.argv[1])
CONTROL = Path(sys.argv[2])
DAILY_CONTRACT = Path(sys.argv[3])
SEMANTIC_CONTRACT = Path(sys.argv[4])
LINKAGE_CONTRACT = Path(sys.argv[5])
PNL_SOURCE = Path(sys.argv[6])
SNAPSHOT_SOURCE = Path(sys.argv[7])
OUTPUT_DIR = Path(sys.argv[8])

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
HTML_PATH = OUTPUT_DIR / "index.html"
DATA_PATH = OUTPUT_DIR / "preview_data.js"
MANIFEST_PATH = OUTPUT_DIR / "PREVIEW_BUILD_MANIFEST_V7.json"

VALID_ACTIONS = {"BUY", "HOLD", "SELL_ALL", "SWITCH", "WAIT"}


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def norm_key(value: Any) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


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


def clean_text(value: Any, limit: int = 1200) -> str | None:
    if value is None:
        return None
    text = str(value).replace("\r", " ").replace("\n", " ").strip()
    if not text:
        return None
    return text[:limit]


def walk(value: Any, path: str = "$") -> Iterable[tuple[str, Any]]:
    yield path, value
    if isinstance(value, dict):
        for key, item in value.items():
            yield from walk(item, path + "." + str(key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from walk(item, path + "[" + str(index) + "]")


def mapping_value(mapping: dict[str, Any], keys: set[str]) -> tuple[str | None, Any]:
    normalized = {norm_key(key): str(key) for key in mapping.keys()}
    for key in keys:
        actual = normalized.get(norm_key(key))
        if actual is not None:
            return actual, mapping.get(actual)
    return None, None


def parse_json_path(root: Any, path: str) -> Any:
    if not isinstance(path, str) or not path.startswith("$"):
        return None
    current = root
    tokens = re.findall(r"\.([^\.\[\]]+)|\[(\d+)\]", path[1:])
    for key_token, index_token in tokens:
        if key_token:
            if not isinstance(current, dict):
                return None
            actual = None
            wanted = norm_key(key_token)
            for key in current.keys():
                if norm_key(key) == wanted:
                    actual = key
                    break
            if actual is None:
                return None
            current = current[actual]
        else:
            if not isinstance(current, list):
                return None
            index = int(index_token)
            if index < 0 or index >= len(current):
                return None
            current = current[index]
    return current


def exact_metric_candidates(payload: Any, accepted_keys: set[str]) -> list[dict[str, Any]]:
    accepted = {norm_key(key) for key in accepted_keys}
    candidates: list[dict[str, Any]] = []
    for path, value in walk(payload):
        if "." not in path:
            continue
        final = re.sub(r"\[\d+\]$", "", path).rsplit(".", 1)[-1]
        if norm_key(final) not in accepted:
            continue
        numeric_value = number(value)
        if numeric_value is None:
            continue
        lower_path = path.lower()
        positive = sum(
            30
            for token in [
                "official", "account", "balance", "holding", "position",
                "readback", "broker", "summary", "snapshot",
            ]
            if token in lower_path
        )
        negative = sum(
            80
            for token in [
                "candidate", "research", "history", "proof", "test",
                "sample", "market", "strategy", "daily_points",
                "summary_candidates", "pnl_fact",
            ]
            if token in lower_path
        )
        candidates.append(
            {
                "path": path,
                "value": numeric_value,
                "score": positive - negative,
            }
        )
    candidates.sort(key=lambda row: (row["score"], row["path"]), reverse=True)
    return candidates


def select_metric(payload: Any, accepted_keys: set[str]) -> dict[str, Any]:
    candidates = exact_metric_candidates(payload, accepted_keys)
    if not candidates:
        return {"ready": False, "value": None, "path": None, "conflict": False}
    best_score = candidates[0]["score"]
    best = [item for item in candidates if item["score"] == best_score]
    values = {str(item["value"]) for item in best}
    if best_score < 0 or len(values) != 1:
        return {
            "ready": False,
            "value": None,
            "path": None,
            "conflict": len(values) > 1,
            "candidate_count": len(candidates),
        }
    return {
        "ready": True,
        "value": best[0]["value"],
        "path": best[0]["path"],
        "conflict": False,
        "candidate_count": len(candidates),
    }


def find_best_record_list(
    payload: Any,
    symbol_keys: set[str],
    required_other_keys: list[set[str]],
    positive_tokens: list[str],
    negative_tokens: list[str],
) -> tuple[str | None, list[dict[str, Any]]]:
    candidates: list[tuple[int, str, list[dict[str, Any]]]] = []
    for path, value in walk(payload):
        if not isinstance(value, list) or not value:
            continue
        rows = [item for item in value if isinstance(item, dict)]
        if not rows:
            continue
        matched = 0
        for row in rows:
            symbol_key, symbol_value = mapping_value(row, symbol_keys)
            if symbol_key is None or clean_text(symbol_value) is None:
                continue
            if all(mapping_value(row, keys)[0] is not None for keys in required_other_keys):
                matched += 1
        if matched == 0:
            continue
        ratio = matched / max(len(rows), 1)
        if ratio < 0.5:
            continue
        lower_path = path.lower()
        score = int(ratio * 100) + min(len(rows), 50)
        score += sum(40 for token in positive_tokens if token in lower_path)
        score -= sum(100 for token in negative_tokens if token in lower_path)
        candidates.append((score, path, rows))
    if not candidates:
        return None, []
    candidates.sort(key=lambda item: (item[0], len(item[2])), reverse=True)
    return candidates[0][1], candidates[0][2]


def holdings_contract(snapshot: Any) -> dict[str, Any]:
    symbol_keys = {"symbol", "stockCode", "code", "ticker", "pdno", "mkscShrnIscd"}
    qty_keys = {"qty", "quantity", "holdingQty", "hldgQty", "hldg_qty"}
    path, rows = find_best_record_list(
        snapshot,
        symbol_keys,
        [qty_keys],
        ["holding", "position", "account", "balance", "readback"],
        ["candidate", "research", "market", "history", "test", "sample"],
    )
    result: list[dict[str, Any]] = []
    key_sets = {
        "name": {"name", "stockName", "symbolName", "prdtName", "prdt_name"},
        "qty": qty_keys,
        "sellable_qty": {"sellableQty", "ordPsblQty", "ord_psbl_qty", "availableQty"},
        "avg_price": {"avgPrice", "averagePrice", "pchsAvgPric", "pchs_avg_pric"},
        "current_price": {"currentPrice", "price", "prpr", "stckPrpr", "stck_prpr"},
        "evaluation_amount": {"evaluationAmount", "evluAmt", "evlu_amt"},
        "unrealized_pnl": {"unrealizedPnl", "evaluationPnl", "evluPflsAmt", "evlu_pfls_amt"},
        "unrealized_rate": {"unrealizedRate", "evaluationRate", "evluPflsRt", "evlu_pfls_rt"},
    }
    for row in rows[:100]:
        symbol_key, symbol = mapping_value(row, symbol_keys)
        if symbol_key is None:
            continue
        item: dict[str, Any] = {
            "symbol": clean_text(symbol, 50),
            "source_path": path,
        }
        for name, keys in key_sets.items():
            _, value = mapping_value(row, keys)
            item[name] = number(value) if name not in {"name"} else clean_text(value, 200)
        if item["qty"] is None:
            continue
        result.append(item)
    return {"ready": bool(result), "source_path": path, "items": result}


def candidates_contract(snapshot: Any) -> dict[str, Any]:
    direct = None
    direct_path = None
    if isinstance(snapshot, dict):
        candidates_obj = snapshot.get("candidates")
        if isinstance(candidates_obj, dict) and isinstance(candidates_obj.get("items"), list):
            direct = [item for item in candidates_obj["items"] if isinstance(item, dict)]
            direct_path = "$.candidates.items"

    symbol_keys = {"symbol", "stockCode", "code", "ticker", "pdno"}
    reason_keys = {"promotionReason", "candidateReason", "selectionReason", "reason", "rationale"}
    score_keys = {"score", "candidateScore", "rankingScore", "totalScore"}

    if direct is None:
        direct_path, direct = find_best_record_list(
            snapshot,
            symbol_keys,
            [reason_keys, score_keys],
            ["candidate", "ranking", "top5", "research", "market"],
            ["account_authority", "history", "backup", "test", "sample"],
        )

    result: list[dict[str, Any]] = []
    name_keys = {"name", "stockName", "symbolName", "prdtName", "prdt_name"}
    action_keys = {"action", "strategyAction", "decisionAction", "recommendedAction"}
    rank_keys = {"rank", "ranking", "position"}

    for row in (direct or [])[:50]:
        _, symbol = mapping_value(row, symbol_keys)
        _, reason = mapping_value(row, reason_keys)
        _, score = mapping_value(row, score_keys)
        _, name = mapping_value(row, name_keys)
        _, action = mapping_value(row, action_keys)
        _, rank = mapping_value(row, rank_keys)
        symbol_text = clean_text(symbol, 50)
        reason_text = clean_text(reason, 2000)
        score_number = number(score)
        if not symbol_text or not reason_text or score_number is None:
            continue
        result.append(
            {
                "symbol": symbol_text,
                "name": clean_text(name, 200),
                "score": score_number,
                "reason": reason_text,
                "action": clean_text(action, 80),
                "rank": number(rank),
                "source_path": direct_path,
            }
        )
    result.sort(
        key=lambda item: (
            item["rank"] is not None,
            -(item["rank"] or 10**9),
            item["score"],
        ),
        reverse=True,
    )
    return {"ready": bool(result), "source_path": direct_path, "items": result}


def find_section(root: Any, section_names: set[str]) -> tuple[str | None, Any]:
    accepted = {norm_key(name) for name in section_names}
    for path, value in walk(root):
        if "." not in path:
            continue
        key = re.sub(r"\[\d+\]$", "", path).rsplit(".", 1)[-1]
        if norm_key(key) in accepted and isinstance(value, dict):
            return path, value
    return None, None


def find_scalar_in_section(
    section: Any,
    section_path: str,
    keys: set[str],
    validator,
) -> tuple[Any, str | None]:
    accepted = {norm_key(key) for key in keys}
    for relative_path, value in walk(section, section_path):
        if "." not in relative_path:
            continue
        key = re.sub(r"\[\d+\]$", "", relative_path).rsplit(".", 1)[-1]
        if norm_key(key) in accepted and validator(value):
            return value, relative_path
    return None, None


def strategy_contract(snapshot: Any, semantic: dict[str, Any]) -> dict[str, Any]:
    section_path, section = find_section(
        snapshot,
        {"stage13L", "strategy", "currentStrategy", "decision", "strategyDecision"},
    )
    action = None
    action_path = None
    reason = None
    reason_path = None
    timestamp = None
    time_path = None

    if isinstance(section, dict) and section_path:
        action, action_path = find_scalar_in_section(
            section,
            section_path,
            {"executionAction", "strategyAction", "decisionAction", "action"},
            lambda value: str(value).strip().upper() in VALID_ACTIONS,
        )
        reason, reason_path = find_scalar_in_section(
            section,
            section_path,
            {"strategyReason", "decisionReason", "executionReason", "rationale", "reason", "explanation"},
            lambda value: clean_text(value) is not None,
        )
        timestamp, time_path = find_scalar_in_section(
            section,
            section_path,
            {"kstTimestamp", "timestamp", "createdAt", "capturedAt", "decisionTime", "strategyTime"},
            lambda value: clean_text(value) is not None,
        )

    if action is None and isinstance(semantic, dict):
        current = semantic.get("strategy", {}).get("current")
        if isinstance(current, dict):
            source_file = Path(str(current.get("file", "")))
            if source_file.exists():
                source_payload = load_json(source_file)
                candidate_action = parse_json_path(source_payload, str(current.get("action_field", "")))
                if str(candidate_action).strip().upper() in VALID_ACTIONS:
                    action = candidate_action
                    action_path = str(current.get("action_field"))
                candidate_time = parse_json_path(source_payload, str(current.get("time_field", "")))
                if clean_text(candidate_time):
                    timestamp = candidate_time
                    time_path = str(current.get("time_field"))

    if timestamp is None and isinstance(snapshot, dict):
        for key in ["kstTimestamp", "capturedAt", "timestamp"]:
            actual = next((item for item in snapshot if norm_key(item) == norm_key(key)), None)
            if actual is not None and clean_text(snapshot.get(actual)):
                timestamp = snapshot.get(actual)
                time_path = "$." + str(actual)
                break

    return {
        "action_ready": action is not None,
        "reason_ready": reason is not None,
        "time_ready": timestamp is not None,
        "action": str(action).strip().upper() if action is not None else None,
        "reason": clean_text(reason, 3000),
        "timestamp": clean_text(timestamp, 200),
        "action_path": action_path,
        "reason_path": reason_path,
        "time_path": time_path,
        "source_file": str(SNAPSHOT_SOURCE),
        "history_linked_to_graph_points": False,
        "history_fallback_text": "해당 거래일 전략 연결 근거 미확정",
    }


def account_contract(snapshot: Any) -> dict[str, Any]:
    metrics = {
        "total_evaluation": select_metric(
            snapshot,
            {"totalEvaluationAmount", "totalEvaluation", "totEvluAmt", "tot_evlu_amt"},
        ),
        "unrealized_pnl": select_metric(
            snapshot,
            {
                "unrealizedPnl", "evaluationPnl", "evaluationProfit",
                "evluPflsSmtlAmt", "evlu_pfls_smtl_amt", "totEvluPflsAmt",
            },
        ),
        "cash": select_metric(
            snapshot,
            {"cash", "deposit", "depositAmount", "dncaTotAmt", "dnca_tot_amt"},
        ),
        "buyable_amount": select_metric(
            snapshot,
            {
                "buyableAmount", "orderableAmount", "ordPsblCash",
                "ord_psbl_cash", "nrcvbBuyAmt", "nrcvb_buy_amt",
            },
        ),
    }
    return {
        "metrics": metrics,
        "holdings": holdings_contract(snapshot),
    }


def daily_contract(daily: dict[str, Any]) -> dict[str, Any]:
    if not daily.get("financial_daily_contract_ready"):
        raise RuntimeError("DAILY_CONTRACT_NOT_READY")
    points = daily.get("daily_points")
    if not isinstance(points, list) or not points:
        raise RuntimeError("DAILY_POINTS_MISSING")

    normalized_points: list[dict[str, Any]] = []
    for point in points:
        if not isinstance(point, dict):
            continue
        business_date = clean_text(point.get("business_date"), 20)
        net = number(point.get("net"))
        if not business_date or net is None:
            continue
        fee = number(point.get("fee")) if point.get("fee_complete") else None
        tax = number(point.get("tax")) if point.get("tax_complete") else None
        interest = number(point.get("interest")) if point.get("interest_complete") else None
        gross_official = number(point.get("gross")) if point.get("gross_complete") else None
        total_cost = None
        derived_gross = None
        if fee is not None and tax is not None and interest is not None:
            total_cost = fee + tax + interest
            derived_gross = net + total_cost
        normalized_points.append(
            {
                "business_date": business_date,
                "trade_row_count": number(point.get("trade_row_count")),
                "net": net,
                "fee": fee,
                "tax": tax,
                "interest": interest,
                "total_cost": total_cost,
                "gross_official": gross_official,
                "gross_derived": derived_gross,
                "gross_display_type": (
                    "OFFICIAL" if gross_official is not None else
                    "AUTO_DERIVED_FROM_NET_AND_CONFIRMED_COSTS" if derived_gross is not None else
                    "UNCONFIRMED"
                ),
            }
        )
    if not normalized_points:
        raise RuntimeError("NO_NORMALIZED_DAILY_POINTS")

    normalized_points.sort(key=lambda row: row["business_date"])
    latest = normalized_points[-1]
    latest_date = clean_text(daily.get("latest_business_date"), 20)
    if latest_date != latest["business_date"]:
        raise RuntimeError("LATEST_DATE_MISMATCH")

    return {
        "ready": True,
        "source_file": str(daily.get("source")),
        "contract_file": str(DAILY_CONTRACT),
        "trade_rows_path": daily.get("trade_rows_path"),
        "field_names": daily.get("field_names", {}),
        "latest_business_date": latest_date,
        "latest": latest,
        "points": normalized_points,
        "point_count": len(normalized_points),
        "summary_latest_day_usable": bool(daily.get("summary_latest_day_usable")),
        "excluded_summary": daily.get("suspected_period_or_unknown_summary", []),
        "canonical_latest_day_source": daily.get("canonical_latest_day_source"),
        "accounting_mismatch_count": number(daily.get("accounting_mismatch_count")) or 0,
        "day_graph_ready": True,
        "week_graph_ready": True,
        "month_graph_ready": True,
    }


def build_html() -> str:
    return r'''<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>자동매매 V2.2 오프라인 검증 미리보기</title>
<style>
:root{
  color-scheme:dark;
  --bg:#08101f;--panel:#111a2e;--panel2:#0d1527;--line:#263654;
  --text:#edf4ff;--muted:#91a4c5;--blue:#66a8ff;--green:#50d890;
  --red:#ff707d;--amber:#ffc766;--cyan:#63d9e6;--shadow:0 16px 45px rgba(0,0,0,.28)
}
*{box-sizing:border-box}
body{margin:0;background:linear-gradient(180deg,#07101f 0%,#0a1222 100%);color:var(--text);font-family:"Malgun Gothic","Noto Sans KR",system-ui,sans-serif}
button{font:inherit}
.wrap{width:min(1260px,calc(100% - 32px));margin:0 auto;padding:24px 0 72px}
.top{display:flex;justify-content:space-between;gap:20px;align-items:flex-start;margin-bottom:18px}
h1{font-size:28px;margin:0 0 8px}.sub{color:var(--muted);font-size:14px;line-height:1.6}
.badge{padding:8px 12px;border-radius:999px;border:1px solid #3e577f;background:#101d34;color:var(--amber);font-weight:800;white-space:nowrap}
.grid{display:grid;grid-template-columns:repeat(12,1fr);gap:14px}.panel{background:rgba(17,26,46,.96);border:1px solid var(--line);border-radius:18px;box-shadow:var(--shadow);padding:18px}
.summary{grid-column:span 3;min-height:142px}.label{font-size:13px;color:var(--muted);margin-bottom:9px}.value{font-size:28px;font-weight:900;letter-spacing:-.5px}.value.small{font-size:20px}.negative{color:var(--red)}.positive{color:var(--green)}.neutral{color:var(--text)}
.note{font-size:12px;color:var(--muted);line-height:1.55;margin-top:8px;word-break:break-all}.source{font-size:11px;color:#7387aa;margin-top:8px;word-break:break-all}
.chart-panel{grid-column:span 8}.detail-panel{grid-column:span 4}.section-title{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}.section-title h2{font-size:19px;margin:0}.tabs{display:flex;gap:6px;flex-wrap:wrap}.tab{border:1px solid var(--line);background:#0d172a;color:var(--muted);padding:7px 11px;border-radius:10px;cursor:pointer}.tab.active{color:#fff;border-color:#4f7fc1;background:#18345a}
#chart{height:310px;position:relative;border:1px solid #223353;border-radius:14px;background:linear-gradient(180deg,#0b1426,#0a1220);overflow:hidden}svg{width:100%;height:100%;display:block}.axis{stroke:#263654;stroke-width:1}.zero{stroke:#607797;stroke-width:1;stroke-dasharray:5 5}.lineGraph{fill:none;stroke:var(--blue);stroke-width:3}.dot{fill:#0e1728;stroke:var(--blue);stroke-width:3;cursor:pointer}.dot.selected{fill:var(--blue)}.axisText{fill:#7f93b6;font-size:11px}.chartEmpty{display:grid;place-items:center;height:100%;color:var(--muted)}
.detailBox{border:1px solid #2b3d60;background:#0b1425;border-radius:14px;padding:14px;min-height:310px}.detailDate{font-size:17px;font-weight:900;margin-bottom:13px}.detailRows{display:grid;gap:9px}.row{display:flex;justify-content:space-between;gap:14px;padding-bottom:8px;border-bottom:1px solid #1f2d47}.row:last-child{border-bottom:0}.row span:first-child{color:var(--muted)}
.strategy{grid-column:span 5}.candidates{grid-column:span 7}.account{grid-column:span 12}.holdingTable,.candidateTable{width:100%;border-collapse:collapse}.holdingTable th,.holdingTable td,.candidateTable th,.candidateTable td{padding:11px 10px;border-bottom:1px solid #22324e;text-align:left;font-size:13px}.holdingTable th,.candidateTable th{color:#9db3d6;font-weight:700}.candidateTable tbody tr{cursor:pointer}.candidateTable tbody tr:hover{background:#16223a}.pill{display:inline-flex;align-items:center;padding:4px 8px;border-radius:999px;background:#142641;border:1px solid #2c466f;color:#a9c9f7;font-size:11px}
.strategyBox{background:#0b1425;border:1px solid #293b5c;border-radius:14px;padding:15px}.strategyAction{font-size:24px;font-weight:900;color:var(--blue);margin:5px 0 12px}.reason{line-height:1.75;color:#dce7fa;white-space:pre-wrap}.missing{color:var(--amber)}
.safety{grid-column:span 12}.safetyGrid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}.safeItem{background:#0b1425;border:1px solid #253856;border-radius:12px;padding:12px}.safeItem b{display:block;color:var(--green);margin-bottom:5px}.safeItem span{font-size:12px;color:var(--muted)}
.modalBack{position:fixed;inset:0;background:rgba(0,0,0,.64);display:none;align-items:center;justify-content:center;padding:20px;z-index:10}.modalBack.open{display:flex}.modal{width:min(720px,100%);max-height:84vh;overflow:auto;background:#101a2f;border:1px solid #35517d;border-radius:18px;padding:20px;box-shadow:0 24px 80px rgba(0,0,0,.55)}.modalTop{display:flex;justify-content:space-between;gap:16px}.close{border:1px solid #3b5074;background:#15243c;color:#dce8fb;border-radius:10px;padding:7px 11px;cursor:pointer}.modalReason{line-height:1.8;white-space:pre-wrap;margin-top:16px}.footer{margin-top:18px;color:#7186a9;font-size:11px;line-height:1.7;word-break:break-all}
@media(max-width:900px){.summary{grid-column:span 6}.chart-panel,.detail-panel,.strategy,.candidates{grid-column:span 12}.safetyGrid{grid-template-columns:1fr 1fr}}
@media(max-width:560px){.wrap{width:min(100% - 18px,1260px)}.top{display:block}.badge{display:inline-block;margin-top:10px}.summary{grid-column:span 12}.safetyGrid{grid-template-columns:1fr}.value{font-size:24px}.holdingTable{min-width:720px}.tableScroll{overflow:auto}}
</style>
</head>
<body>
<div class="wrap">
  <div class="top">
    <div><h1>자동매매 V2.2 오프라인 검증 미리보기</h1><div class="sub" id="subtitle"></div></div>
    <div class="badge">라이브 미적용 · 수동 값 입력 없음</div>
  </div>

  <section class="grid" id="summaryGrid"></section>

  <section class="grid" style="margin-top:14px">
    <article class="panel chart-panel">
      <div class="section-title"><h2>확정 순실현손익 그래프</h2><div class="tabs" id="tabs"></div></div>
      <div id="chart"></div>
      <div class="note">보유 미실현 평가손익은 그래프에서 제외됩니다. 각 점은 공식 거래행을 거래일별로 자동 합산한 순실현손익입니다.</div>
    </article>
    <article class="panel detail-panel">
      <div class="section-title"><h2>선택 거래일 상세</h2></div>
      <div class="detailBox" id="detail"></div>
    </article>
  </section>

  <section class="grid" style="margin-top:14px">
    <article class="panel strategy">
      <div class="section-title"><h2>현재 전략 판단</h2></div>
      <div id="strategy"></div>
    </article>
    <article class="panel candidates">
      <div class="section-title"><h2>후보종목과 자동 선정 근거</h2><span class="pill" id="candidateCount"></span></div>
      <div class="tableScroll"><table class="candidateTable"><thead><tr><th>순서</th><th>종목</th><th>점수</th><th>자동 판단</th></tr></thead><tbody id="candidateBody"></tbody></table></div>
    </article>
  </section>

  <section class="grid" style="margin-top:14px">
    <article class="panel account">
      <div class="section-title"><h2>공식 계좌·보유종목</h2><span class="pill" id="holdingCount"></span></div>
      <div class="tableScroll"><table class="holdingTable"><thead><tr><th>종목</th><th>수량</th><th>매도가능</th><th>평균단가</th><th>현재가</th><th>평가금액</th><th>미실현 평가손익</th></tr></thead><tbody id="holdingBody"></tbody></table></div>
    </article>
  </section>

  <section class="grid" style="margin-top:14px">
    <article class="panel safety">
      <div class="section-title"><h2>안전·출처 검증</h2></div>
      <div class="safetyGrid" id="safetyGrid"></div>
      <div class="footer" id="footer"></div>
    </article>
  </section>
</div>

<div class="modalBack" id="modalBack"><div class="modal"><div class="modalTop"><div><div class="label">후보종목 상세</div><h2 id="modalTitle" style="margin:0"></h2></div><button class="close" id="modalClose">닫기</button></div><div class="modalReason" id="modalReason"></div><div class="source" id="modalSource"></div></div></div>

<script src="preview_data.js"></script>
<script>
(()=>{
 const d=window.__AUTOTRADE_PREVIEW__;
 const won=v=>v===null||v===undefined?'공식 자료 미확정':new Intl.NumberFormat('ko-KR',{style:'currency',currency:'KRW',maximumFractionDigits:0}).format(v);
 const num=v=>v===null||v===undefined?'—':new Intl.NumberFormat('ko-KR',{maximumFractionDigits:2}).format(v);
 const pnlClass=v=>v>0?'positive':v<0?'negative':'neutral';
 const text=(el,value)=>{el.textContent=value??''};
 const metricCard=(label,value,note,source,kind='money')=>{const card=document.createElement('article');card.className='panel summary';const l=document.createElement('div');l.className='label';text(l,label);const v=document.createElement('div');v.className='value '+(typeof value==='number'?pnlClass(value):'neutral');text(v,kind==='money'?won(value):String(value??'공식 자료 미확정'));const n=document.createElement('div');n.className='note';text(n,note);const s=document.createElement('div');s.className='source';text(s,source);card.append(l,v,n,s);return card;};
 const latest=d.financial.latest;
 text(document.getElementById('subtitle'),`${d.financial.latest_business_date} 공식 거래행 기준 · 생성 ${d.generated_at} · 모든 숫자는 원본에서 자동 계산`);
 const summary=document.getElementById('summaryGrid');
 summary.append(
   metricCard('오늘 확정 순손익',latest.net,'미실현 평가손익 제외','출처: '+d.financial.trade_rows_path),
   metricCard('비용 전 매매손익',latest.gross_official??latest.gross_derived,latest.gross_display_type==='OFFICIAL'?'공식 원본':'순손익 + 확인된 비용으로 자동계산','계산방식: '+latest.gross_display_type),
   metricCard('수수료·세금·이자',latest.total_cost,'수수료 '+won(latest.fee)+' · 세금 '+won(latest.tax)+' · 이자 '+won(latest.interest),'공식 거래행 자동 합산'),
   metricCard('보유 미실현 평가손익',d.account.metrics.unrealized_pnl.ready?d.account.metrics.unrealized_pnl.value:null,'확정손익과 분리 표시',d.account.metrics.unrealized_pnl.path?'출처: '+d.account.metrics.unrealized_pnl.path:'정확한 공식 필드 연결 미확정')
 );
 const periods=[['day','당일'],['week','1주'],['month','1개월'],['all','전체']];
 let period='month',selected=null;
 const tabs=document.getElementById('tabs');
 periods.forEach(([key,label])=>{const b=document.createElement('button');b.className='tab';b.dataset.key=key;text(b,label);b.onclick=()=>{period=key;draw();};tabs.append(b);});
 function pointsFor(){const pts=d.financial.points;const latestDate=new Date(d.financial.latest_business_date+'T00:00:00');if(period==='day')return pts.slice(-1);if(period==='week'){const min=new Date(latestDate);min.setDate(min.getDate()-7);return pts.filter(p=>new Date(p.business_date+'T00:00:00')>=min);}if(period==='month'){const min=new Date(latestDate);min.setDate(min.getDate()-31);return pts.filter(p=>new Date(p.business_date+'T00:00:00')>=min);}return pts;}
 function renderDetail(p){selected=p;const box=document.getElementById('detail');box.replaceChildren();const date=document.createElement('div');date.className='detailDate';text(date,p.business_date);const rows=[['확정 순손익',won(p.net)],['비용 전 손익',won(p.gross_official??p.gross_derived)],['수수료',won(p.fee)],['세금',won(p.tax)],['대출이자',won(p.interest)],['거래행 수',num(p.trade_row_count)],['전략 연결',d.strategy.history_fallback_text]];const wrap=document.createElement('div');wrap.className='detailRows';rows.forEach(([a,b])=>{const r=document.createElement('div');r.className='row';const x=document.createElement('span');const y=document.createElement('span');text(x,a);text(y,b);r.append(x,y);wrap.append(r);});box.append(date,wrap);}
 function draw(){document.querySelectorAll('.tab').forEach(b=>b.classList.toggle('active',b.dataset.key===period));const pts=pointsFor();const chart=document.getElementById('chart');chart.replaceChildren();if(!pts.length){const e=document.createElement('div');e.className='chartEmpty';text(e,'표시할 공식 거래일 자료가 없습니다.');chart.append(e);return;}const width=900,height=310,pad={l:78,r:26,t:24,b:48};const vals=pts.map(p=>Number(p.net));let min=Math.min(...vals,0),max=Math.max(...vals,0);if(min===max){min-=1;max+=1;}const x=i=>pad.l+(pts.length===1?(width-pad.l-pad.r)/2:i*(width-pad.l-pad.r)/(pts.length-1));const y=v=>pad.t+(max-v)*(height-pad.t-pad.b)/(max-min);const ns='http://www.w3.org/2000/svg';const svg=document.createElementNS(ns,'svg');svg.setAttribute('viewBox',`0 0 ${width} ${height}`);for(let i=0;i<5;i++){const value=max-(max-min)*i/4;const yy=y(value);const line=document.createElementNS(ns,'line');line.setAttribute('x1',pad.l);line.setAttribute('x2',width-pad.r);line.setAttribute('y1',yy);line.setAttribute('y2',yy);line.setAttribute('class',Math.abs(value)<1e-9?'zero':'axis');svg.append(line);const t=document.createElementNS(ns,'text');t.setAttribute('x',pad.l-10);t.setAttribute('y',yy+4);t.setAttribute('text-anchor','end');t.setAttribute('class','axisText');t.textContent=new Intl.NumberFormat('ko-KR',{notation:'compact',maximumFractionDigits:1}).format(value);svg.append(t);}if(pts.length>1){const poly=document.createElementNS(ns,'polyline');poly.setAttribute('class','lineGraph');poly.setAttribute('points',pts.map((p,i)=>`${x(i)},${y(p.net)}`).join(' '));svg.append(poly);}pts.forEach((p,i)=>{const c=document.createElementNS(ns,'circle');c.setAttribute('cx',x(i));c.setAttribute('cy',y(p.net));c.setAttribute('r',6);c.setAttribute('class','dot'+(selected&&selected.business_date===p.business_date?' selected':''));c.addEventListener('click',()=>{renderDetail(p);draw();});svg.append(c);if(pts.length<=12||i===0||i===pts.length-1){const t=document.createElementNS(ns,'text');t.setAttribute('x',x(i));t.setAttribute('y',height-18);t.setAttribute('text-anchor','middle');t.setAttribute('class','axisText');t.textContent=p.business_date.slice(5);svg.append(t);}});chart.append(svg);if(!selected||!pts.some(p=>p.business_date===selected.business_date))renderDetail(pts[pts.length-1]);}
 draw();
 const strategy=document.getElementById('strategy');const sb=document.createElement('div');sb.className='strategyBox';const action=document.createElement('div');action.className='strategyAction';text(action,d.strategy.action_ready?d.strategy.action:'전략 행동 미확정');const reason=document.createElement('div');reason.className=d.strategy.reason_ready?'reason':'reason missing';text(reason,d.strategy.reason_ready?d.strategy.reason:'전략 근거를 정확한 전략 필드에서 자동 연결하지 못했습니다. 임의 문구를 표시하지 않습니다.');const ts=document.createElement('div');ts.className='source';text(ts,'판단 시각: '+(d.strategy.timestamp??'미확정')+' · 행동 필드: '+(d.strategy.action_path??'미확정')+' · 근거 필드: '+(d.strategy.reason_path??'미확정'));sb.append(action,reason,ts);strategy.append(sb);
 const cb=document.getElementById('candidateBody');text(document.getElementById('candidateCount'),d.candidates.items.length+'개 자동 연결');d.candidates.items.forEach((c,i)=>{const tr=document.createElement('tr');const cells=[String(c.rank??i+1),(c.name?c.name+' ':'')+c.symbol,num(c.score),c.action??'상세 보기'];cells.forEach(v=>{const td=document.createElement('td');text(td,v);tr.append(td);});tr.onclick=()=>{text(document.getElementById('modalTitle'),(c.name?c.name+' ':'')+c.symbol+' · '+num(c.score)+'점');text(document.getElementById('modalReason'),c.reason);text(document.getElementById('modalSource'),'출처: '+(c.source_path??'미확정'));document.getElementById('modalBack').classList.add('open');};cb.append(tr);});if(!d.candidates.items.length){const tr=document.createElement('tr');const td=document.createElement('td');td.colSpan=4;td.className='missing';text(td,'정확한 후보 이유·점수 연결 자료가 없습니다.');tr.append(td);cb.append(tr);}
 const hb=document.getElementById('holdingBody');text(document.getElementById('holdingCount'),d.account.holdings.items.length+'개 자동 연결');d.account.holdings.items.forEach(h=>{const tr=document.createElement('tr');const values=[(h.name?h.name+' ':'')+h.symbol,num(h.qty),num(h.sellable_qty),won(h.avg_price),won(h.current_price),won(h.evaluation_amount),won(h.unrealized_pnl)];values.forEach((v,i)=>{const td=document.createElement('td');if(i===6&&typeof h.unrealized_pnl==='number')td.className=pnlClass(h.unrealized_pnl);text(td,v);tr.append(td);});hb.append(tr);});if(!d.account.holdings.items.length){const tr=document.createElement('tr');const td=document.createElement('td');td.colSpan=7;td.className='missing';text(td,'정확한 공식 보유종목 목록 연결이 미확정입니다.');tr.append(td);hb.append(tr);}
 const safety=[['수동 값 입력','사용하지 않음'],['라이브 설치','금지 상태'],['장중 그래프',d.intraday.ready?'정확 연결 완료':'모호한 체결시각 때문에 표시 안 함'],['일·주·월 그래프',d.financial.point_count+'개 거래일 자동 생성']];const sg=document.getElementById('safetyGrid');safety.forEach(([a,b])=>{const box=document.createElement('div');box.className='safeItem';const x=document.createElement('b');const y=document.createElement('span');text(x,a);text(y,b);box.append(x,y);sg.append(box);});
 text(document.getElementById('footer'),'금융 원본: '+d.sources.pnl+' · 일별 계약: '+d.sources.daily_contract+' · 전략·후보 계약: '+d.sources.semantic_contract+' · 체결시각 계약: '+d.sources.linkage_contract+' · 계좌 스냅샷: '+d.sources.snapshot+' · 원본 해시: '+JSON.stringify(d.source_hashes));
 const mb=document.getElementById('modalBack');document.getElementById('modalClose').onclick=()=>mb.classList.remove('open');mb.onclick=e=>{if(e.target===mb)mb.classList.remove('open');};
})();
</script>
</body>
</html>'''


def main() -> int:
    for path in [DAILY_CONTRACT, SEMANTIC_CONTRACT, LINKAGE_CONTRACT, PNL_SOURCE, SNAPSHOT_SOURCE]:
        if not path.exists():
            raise RuntimeError("REQUIRED_SOURCE_MISSING:" + str(path))

    daily_raw = load_json(DAILY_CONTRACT)
    semantic_raw = load_json(SEMANTIC_CONTRACT)
    linkage_raw = load_json(LINKAGE_CONTRACT)
    pnl_raw = load_json(PNL_SOURCE)
    snapshot_raw = load_json(SNAPSHOT_SOURCE)

    if daily_raw.get("manual_value_override_allowed") is not False:
        raise RuntimeError("DAILY_CONTRACT_MANUAL_OVERRIDE_POLICY_INVALID")
    if daily_raw.get("zero_when_unconfirmed_allowed") is not False:
        raise RuntimeError("DAILY_CONTRACT_ZERO_POLICY_INVALID")
    if linkage_raw.get("manual_timestamp_override_allowed") is not False:
        raise RuntimeError("LINKAGE_MANUAL_TIMESTAMP_POLICY_INVALID")

    financial = daily_contract(daily_raw)
    strategy = strategy_contract(snapshot_raw, semantic_raw)
    candidates = candidates_contract(snapshot_raw)
    account = account_contract(snapshot_raw)

    latest_date = financial["latest_business_date"]
    linkage_date = clean_text(linkage_raw.get("latest_business_date"), 20)
    if linkage_date != latest_date:
        raise RuntimeError("LINKAGE_DATE_MISMATCH")

    intraday_ready = bool(linkage_raw.get("intraday_graph_ready"))
    link_counts = linkage_raw.get("link_counts", {})

    source_hashes = {
        "daily_contract": file_hash(DAILY_CONTRACT),
        "semantic_contract": file_hash(SEMANTIC_CONTRACT),
        "linkage_contract": file_hash(LINKAGE_CONTRACT),
        "pnl_source": file_hash(PNL_SOURCE),
        "snapshot_source": file_hash(SNAPSHOT_SOURCE),
    }

    payload = {
        "preview_type": "AUTOTRADE_CLEAN_V2_2_OFFLINE_PREVIEW_V7",
        "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "preview_only": True,
        "live_install_allowed": False,
        "manual_value_input_used": False,
        "manual_value_override_allowed": False,
        "hardcoded_financial_values_used": False,
        "zero_when_unconfirmed_allowed": False,
        "financial": financial,
        "strategy": strategy,
        "candidates": candidates,
        "account": account,
        "intraday": {
            "ready": intraday_ready,
            "rendered": intraday_ready,
            "link_counts": link_counts,
            "fallback": linkage_raw.get("fallback_when_not_ready"),
        },
        "sources": {
            "daily_contract": str(DAILY_CONTRACT),
            "semantic_contract": str(SEMANTIC_CONTRACT),
            "linkage_contract": str(LINKAGE_CONTRACT),
            "pnl": str(PNL_SOURCE),
            "snapshot": str(SNAPSHOT_SOURCE),
        },
        "source_hashes": source_hashes,
        "source_lineage": pnl_raw.get("lineage") if isinstance(pnl_raw, dict) else None,
        "safety": {
            "live_dashboard_modified": False,
            "strategy_modified": False,
            "order_path_modified": False,
            "database_direct_write_used": False,
            "broker_order_attempted": False,
            "order_transport_calls": 0,
            "scheduled_task_modified": False,
            "runtime_restarted": False,
        },
    }

    if not intraday_ready:
        payload["intraday"]["rendered"] = False

    html = build_html()
    forbidden_html_literals = [
        "-8617", "-8,617", "8300", "8,300", "-7140", "-7,140",
        "73원", "1404", "1,404", "935005", "935,005",
    ]
    found_forbidden = [item for item in forbidden_html_literals if item in html]
    if found_forbidden:
        raise RuntimeError("HARDCODED_FINANCIAL_LITERAL_IN_HTML:" + ",".join(found_forbidden))
    if re.search(r"<input\b|contenteditable\s*=", html, re.IGNORECASE):
        raise RuntimeError("MANUAL_INPUT_UI_PRESENT")

    javascript = "window.__AUTOTRADE_PREVIEW__ = " + json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        default=str,
    ).replace("</", "<\\/") + ";\n"

    HTML_PATH.write_text(html, encoding="utf-8-sig")
    DATA_PATH.write_text(javascript, encoding="utf-8-sig")

    build_manifest = {
        "contract_type": "AUTOTRADE_CLEAN_V2_2_OFFLINE_PREVIEW_BUILD_MANIFEST_V7",
        "created_at": payload["generated_at"],
        "preview_only": True,
        "live_install_allowed": False,
        "manual_value_input_used": False,
        "hardcoded_financial_values_used": False,
        "html_has_manual_input": False,
        "html_hardcoded_financial_literal_count": 0,
        "latest_business_date": latest_date,
        "latest_net_source": "DAILY_SCOPE_CONTRACT_V5.daily_points/latest",
        "latest_net_value": financial["latest"]["net"],
        "latest_fee_value": financial["latest"]["fee"],
        "latest_tax_value": financial["latest"]["tax"],
        "latest_interest_value": financial["latest"]["interest"],
        "latest_gross_display_type": financial["latest"]["gross_display_type"],
        "daily_point_count": financial["point_count"],
        "intraday_graph_ready": intraday_ready,
        "intraday_graph_rendered": payload["intraday"]["rendered"],
        "strategy_action_ready": strategy["action_ready"],
        "strategy_reason_ready": strategy["reason_ready"],
        "candidate_record_count": len(candidates["items"]),
        "holding_record_count": len(account["holdings"]["items"]),
        "unrealized_pnl_ready": account["metrics"]["unrealized_pnl"]["ready"],
        "source_hashes": source_hashes,
        "output_hashes": {
            "index_html": file_hash(HTML_PATH),
            "preview_data_js": file_hash(DATA_PATH),
        },
        "preview_html": str(HTML_PATH),
        "preview_data": str(DATA_PATH),
    }
    MANIFEST_PATH.write_text(
        json.dumps(build_manifest, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8-sig",
    )

    print("FINAL_STATUS=PASS_OFFLINE_PREVIEW_BUILD_V7")
    print("PREVIEW_ONLY=TRUE")
    print("LIVE_INSTALL_ALLOWED=FALSE")
    print("MANUAL_VALUE_INPUT_USED=FALSE")
    print("HARDCODED_FINANCIAL_VALUES_USED=FALSE")
    print("HTML_HAS_MANUAL_INPUT=FALSE")
    print("HTML_HARDCODED_FINANCIAL_LITERAL_COUNT=0")
    print("LATEST_BUSINESS_DATE=" + latest_date)
    print("LATEST_NET_SOURCE=DAILY_SCOPE_CONTRACT_V5_TRADE_ROWS_GROUPED_BY_BUSINESS_DATE")
    print("LATEST_NET_VALUE=" + str(financial["latest"]["net"]))
    print("LATEST_FEE_VALUE=" + str(financial["latest"]["fee"]))
    print("LATEST_TAX_VALUE=" + str(financial["latest"]["tax"]))
    print("LATEST_INTEREST_VALUE=" + str(financial["latest"]["interest"]))
    print("LATEST_GROSS_DISPLAY_TYPE=" + str(financial["latest"]["gross_display_type"]))
    print("DAILY_POINT_COUNT=" + str(financial["point_count"]))
    print("DAY_GRAPH_READY=TRUE")
    print("WEEK_GRAPH_READY=TRUE")
    print("MONTH_GRAPH_READY=TRUE")
    print("INTRADAY_GRAPH_READY=" + str(intraday_ready).upper())
    print("INTRADAY_GRAPH_RENDERED=" + str(payload["intraday"]["rendered"]).upper())
    print("STRATEGY_ACTION_READY=" + str(strategy["action_ready"]).upper())
    print("STRATEGY_REASON_READY=" + str(strategy["reason_ready"]).upper())
    print("CANDIDATE_RECORD_COUNT=" + str(len(candidates["items"])))
    print("HOLDING_RECORD_COUNT=" + str(len(account["holdings"]["items"])))
    print("UNREALIZED_PNL_READY=" + str(account["metrics"]["unrealized_pnl"]["ready"]).upper())
    print("PREVIEW_HTML=" + str(HTML_PATH))
    print("PREVIEW_DATA=" + str(DATA_PATH))
    print("BUILD_MANIFEST=" + str(MANIFEST_PATH))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
