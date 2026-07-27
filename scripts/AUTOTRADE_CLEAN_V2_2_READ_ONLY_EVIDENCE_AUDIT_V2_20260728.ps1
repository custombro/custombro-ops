#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$LabRoot = Join-Path $ControlRoot 'FACT_DASHBOARD_V2_2_LAB'
$EvidenceRoot = Join-Path $LabRoot 'evidence'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunRoot = Join-Path $EvidenceRoot ('AUDIT_V2_' + $Stamp)
$Report = Join-Path $RunRoot 'READ_ONLY_EVIDENCE_AUDIT_V2.txt'
$Manifest = Join-Path $RunRoot 'READ_ONLY_EVIDENCE_AUDIT_V2.json'
$Helper = Join-Path $RunRoot 'read_only_evidence_auditor_v2.py'
$Database = Join-Path $Root 'state\autotrade.db'

New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null

$Results = New-Object System.Collections.Generic.List[string]

function Add-Result {
    param([string]$Key, [object]$Value)

    if ($Value -is [bool]) {
        $Text = $Value.ToString().ToUpperInvariant()
    }
    elseif ($Value -is [string]) {
        $Text = $Value
    }
    else {
        $Text = $Value | ConvertTo-Json -Depth 30 -Compress
    }

    [void]$Results.Add($Key + '=' + $Text)
}

function Get-PythonPath {
    $Known = 'C:\Program Files\Python312\python.exe'
    if (Test-Path -LiteralPath $Known) {
        return $Known
    }
    return (Get-Command python.exe -ErrorAction Stop).Source
}

function Get-RuntimeProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^pythonw?\.exe$' -and
            [string]$_.CommandLine -like '*C:\AUTOTRADE_CLEAN\app\stage12_runtime_bootstrap.py*' -and
            [string]$_.CommandLine -like '*--mode persistent*'
        }
    )
}

function Get-HttpProbe {
    param([string]$Path)

    $Watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $Response = Invoke-WebRequest `
            -Uri ('http://127.0.0.1:3100' + $Path) `
            -UseBasicParsing `
            -TimeoutSec 12
        $Watch.Stop()
        return [ordered]@{
            status = [int]$Response.StatusCode
            milliseconds = [int]$Watch.ElapsedMilliseconds
        }
    }
    catch {
        $Watch.Stop()
        return [ordered]@{
            status = 0
            milliseconds = [int]$Watch.ElapsedMilliseconds
        }
    }
}

function Get-OrderLedgerCount {
    $Python = Get-PythonPath
    $Code = @'
import sqlite3
import sys
path = sys.argv[1]
con = sqlite3.connect('file:' + path + '?mode=ro', uri=True)
try:
    print(int(con.execute('SELECT COUNT(*) FROM order_ledger').fetchone()[0]))
finally:
    con.close()
'@
    $Temporary = Join-Path $env:TEMP (
        'autotrade_readonly_order_count_' +
        [guid]::NewGuid().ToString('N') +
        '.py'
    )
    [IO.File]::WriteAllText(
        $Temporary,
        $Code,
        (New-Object System.Text.ASCIIEncoding)
    )
    try {
        $Output = @(& $Python $Temporary $Database 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ('ORDER_LEDGER_READ_FAILED:' + ($Output -join ' '))
        }
        return [int]([string]($Output | Select-Object -Last 1)).Trim()
    }
    finally {
        Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-CriticalFingerprint {
    $Patterns = @(
        'strategy',
        'stage13l',
        'order',
        'sender',
        'transport',
        'runtime_bootstrap',
        'dashboard.py',
        'index.html'
    )

    $Files = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $Lower = $_.FullName.ToLowerInvariant()
            $Matched = $false
            foreach ($Pattern in $Patterns) {
                if ($Lower.Contains($Pattern)) {
                    $Matched = $true
                    break
                }
            }
            $Matched
        } |
        Sort-Object FullName |
        Select-Object -First 1000
    )

    $Builder = New-Object System.Text.StringBuilder
    foreach ($File in $Files) {
        $Hash = (
            Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256
        ).Hash.ToUpperInvariant()
        [void]$Builder.AppendLine($File.FullName + '|' + $Hash)
    }

    $Bytes = [Text.Encoding]::UTF8.GetBytes($Builder.ToString())
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash($Bytes)
    }
    finally {
        $Sha.Dispose()
    }

    return [ordered]@{
        count = $Files.Count
        sha256 = ([BitConverter]::ToString($Digest)).Replace('-', '')
    }
}

$PythonAuditor = @'
from __future__ import annotations

import datetime as dt
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

ROOT = Path(sys.argv[1])
CONTROL = Path(sys.argv[2])
DATABASE = Path(sys.argv[3])
OUTPUT = Path(sys.argv[4])

MAX_JSON_FILES = 500
MAX_JSON_BYTES = 20 * 1024 * 1024
MAX_SQL_ROWS = 5
MAX_TEXT = 500

SENSITIVE = re.compile(
    r'(app.?secret|secret|token|authorization|account.?number|cano|acct)',
    re.IGNORECASE,
)
TARGET_FILE = re.compile(
    r'(pnl|profit|trade|fill|fee|tax|commission|settlement|verify|snapshot|strategy|decision|candidate|authority|ledger|account)',
    re.IGNORECASE,
)
GROUPS = {
    'realized_net_pnl': re.compile(
        r'(daily.?trading.?pnl|net.?realized|realized.?net|net.?pnl|net.?profit|tot.*rlzt.*pfls|rlzt.*pfls.*amt)',
        re.IGNORECASE,
    ),
    'gross_trade_pnl': re.compile(
        r'(gross.?pnl|gross.?profit|trade.?profit)',
        re.IGNORECASE,
    ),
    'fee': re.compile(r'(fee|commission)', re.IGNORECASE),
    'tax': re.compile(r'(tax|transaction.?tax)', re.IGNORECASE),
    'loan_interest': re.compile(r'(interest|loan.?interest)', re.IGNORECASE),
    'strategy_action': re.compile(
        r'(strategy.*action|execution.*action|decision.*action|(^|\.)action$)',
        re.IGNORECASE,
    ),
    'strategy_reason': re.compile(
        r'(strategy.*reason|decision.*reason|rationale|(^|\.)reason$)',
        re.IGNORECASE,
    ),
    'strategy_time': re.compile(
        r'(strategy.*time|decision.*time|created.?at|captured.?at|timestamp)',
        re.IGNORECASE,
    ),
    'candidate_reason': re.compile(
        r'(candidate.*reason|selection.*reason|promotion.*evidence|ranking.*reason)',
        re.IGNORECASE,
    ),
    'candidate_score': re.compile(
        r'(candidate.*score|ranking.*score|(^|\.)score$)',
        re.IGNORECASE,
    ),
    'generation': re.compile(
        r'(generation|lineage|proof.?hash|source.?hash|account.?generation)',
        re.IGNORECASE,
    ),
}


def is_scalar(value: Any) -> bool:
    return value is None or isinstance(value, (str, int, float, bool))


def clean(path: str, value: Any) -> Any:
    if SENSITIVE.search(path):
        return '[REDACTED]'
    if isinstance(value, str):
        return value.replace('\r', ' ').replace('\n', ' ')[:MAX_TEXT]
    return value


def walk(value: Any, path: str = '$'):
    if isinstance(value, dict):
        for key, item in value.items():
            child = path + '.' + str(key)
            if is_scalar(item):
                yield child, clean(child, item)
            else:
                yield from walk(item, child)
    elif isinstance(value, list):
        for index, item in enumerate(value[:100]):
            child = path + '[' + str(index) + ']'
            if is_scalar(item):
                yield child, clean(child, item)
            else:
                yield from walk(item, child)


def json_candidates() -> list[Path]:
    result: list[Path] = []
    for base in (CONTROL, ROOT / 'state'):
        if not base.exists():
            continue
        for path in base.rglob('*.json'):
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_size > MAX_JSON_BYTES:
                continue
            if TARGET_FILE.search(path.name) or TARGET_FILE.search(str(path.parent)):
                result.append(path)
    result.sort(
        key=lambda item: item.stat().st_mtime if item.exists() else 0,
        reverse=True,
    )
    return result[:MAX_JSON_FILES]


def audit_json() -> tuple[list[dict[str, Any]], dict[str, int], list[dict[str, str]]]:
    evidence: list[dict[str, Any]] = []
    counts = {key: 0 for key in GROUPS}
    errors: list[dict[str, str]] = []

    for file_path in json_candidates():
        try:
            value = json.loads(file_path.read_text(encoding='utf-8-sig'))
        except Exception as exc:
            errors.append({'file': str(file_path), 'error': str(exc)[:300]})
            continue

        for field_path, field_value in walk(value):
            for group, pattern in GROUPS.items():
                if pattern.search(field_path):
                    counts[group] += 1
                    evidence.append(
                        {
                            'group': group,
                            'file': str(file_path),
                            'field': field_path,
                            'value': field_value,
                            'modified': dt.datetime.fromtimestamp(
                                file_path.stat().st_mtime
                            ).isoformat(timespec='seconds'),
                        }
                    )
                    break

    return evidence, counts, errors


def quote_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def audit_sqlite() -> dict[str, Any]:
    result: dict[str, Any] = {
        'path': str(DATABASE),
        'tables': [],
        'samples': [],
        'error': None,
    }

    if not DATABASE.exists():
        result['error'] = 'DATABASE_MISSING'
        return result

    try:
        con = sqlite3.connect(
            'file:' + str(DATABASE) + '?mode=ro',
            uri=True,
            timeout=5,
        )
        con.row_factory = sqlite3.Row
        try:
            rows = con.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            ).fetchall()

            for row in rows:
                table = str(row[0])
                quoted = quote_identifier(table)
                columns = [
                    str(item[1])
                    for item in con.execute('PRAGMA table_info(' + quoted + ')').fetchall()
                ]
                try:
                    row_count = int(
                        con.execute('SELECT COUNT(*) FROM ' + quoted).fetchone()[0]
                    )
                except Exception:
                    row_count = -1

                result['tables'].append(
                    {'name': table, 'columns': columns, 'row_count': row_count}
                )

                if re.search(
                    r'(strategy|decision|candidate|order|fill|trade|profit|pnl|event|snapshot|ledger)',
                    table,
                    re.IGNORECASE,
                ):
                    try:
                        sample_rows = con.execute(
                            'SELECT * FROM ' + quoted +
                            ' ORDER BY rowid DESC LIMIT ' + str(MAX_SQL_ROWS)
                        ).fetchall()
                    except Exception:
                        try:
                            sample_rows = con.execute(
                                'SELECT * FROM ' + quoted +
                                ' LIMIT ' + str(MAX_SQL_ROWS)
                            ).fetchall()
                        except Exception as exc:
                            result['samples'].append(
                                {'table': table, 'error': str(exc)[:300]}
                            )
                            continue

                    samples = []
                    for sample_row in sample_rows:
                        item = {}
                        for key in sample_row.keys():
                            item[str(key)] = clean(
                                table + '.' + str(key),
                                sample_row[key],
                            )
                        samples.append(item)
                    result['samples'].append({'table': table, 'rows': samples})
        finally:
            con.close()
    except Exception as exc:
        result['error'] = str(exc)[:500]

    return result


def quality(counts: dict[str, int]) -> dict[str, str]:
    return {
        'realized_net_pnl': (
            'EVIDENCE_CANDIDATE_FOUND'
            if counts['realized_net_pnl']
            else 'NO_EVIDENCE_CANDIDATE'
        ),
        'fees': (
            'EVIDENCE_CANDIDATE_FOUND'
            if counts['fee']
            else 'NO_EVIDENCE_CANDIDATE'
        ),
        'tax': (
            'EVIDENCE_CANDIDATE_FOUND'
            if counts['tax']
            else 'NO_EVIDENCE_CANDIDATE'
        ),
        'strategy_timeline': (
            'EVIDENCE_CANDIDATE_FOUND'
            if counts['strategy_action'] and counts['strategy_time']
            else 'ACTION_TIME_LINK_INSUFFICIENT'
        ),
        'candidate_explanation': (
            'EVIDENCE_CANDIDATE_FOUND'
            if counts['candidate_reason']
            else 'NO_HUMAN_REASON_EVIDENCE'
        ),
    }


def main() -> int:
    evidence, counts, errors = audit_json()
    sqlite_result = audit_sqlite()
    payload = {
        'audit_type': 'AUTOTRADE_CLEAN_V2_2_READ_ONLY_EVIDENCE_AUDIT_V2',
        'captured_at': dt.datetime.now().astimezone().isoformat(timespec='seconds'),
        'read_only': True,
        'manual_pnl_input_used': False,
        'database_direct_write_used': False,
        'broker_order_attempted': False,
        'order_transport_calls': 0,
        'field_counts': counts,
        'source_quality': quality(counts),
        'json_evidence': evidence[:3000],
        'json_parse_errors': errors[:200],
        'sqlite': sqlite_result,
    }

    OUTPUT.write_text(
        json.dumps(payload, ensure_ascii=True, indent=2, default=str),
        encoding='utf-8',
    )

    print('FINAL_STATUS=PASS_READ_ONLY_EVIDENCE_AUDIT_V2')
    for key, value in counts.items():
        print('FIELD_COUNT_' + key.upper() + '=' + str(value))
    for key, value in payload['source_quality'].items():
        print('SOURCE_QUALITY_' + key.upper() + '=' + value)
    print('JSON_EVIDENCE_COUNT=' + str(len(evidence)))
    print('JSON_PARSE_ERROR_COUNT=' + str(len(errors)))
    print('SQLITE_TABLE_COUNT=' + str(len(sqlite_result.get('tables', []))))
    print('MANIFEST=' + str(OUTPUT))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
'@

[IO.File]::WriteAllText(
    $Helper,
    $PythonAuditor,
    (New-Object System.Text.ASCIIEncoding)
)

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'V2_2_READ_ONLY_EVIDENCE_AUDIT_V2_ASCII_SAFE'
Add-Result 'ASCII_ONLY_EMBEDDED_PYTHON' $true
Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'SCHEDULED_TASK_MODIFIED' $false
Add-Result 'RUNTIME_RESTARTED' $false

$Success = $false

try {
    foreach ($Required in @($Root, $ControlRoot, $Database)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw ('REQUIRED_PATH_MISSING:' + $Required)
        }
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $RootBefore = Get-HttpProbe '/'
    $HealthBefore = Get-HttpProbe '/api/v1/health'
    $SnapshotBefore = Get-HttpProbe '/api/v1/snapshot'
    $OrderBefore = Get-OrderLedgerCount
    $FingerprintBefore = Get-CriticalFingerprint

    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'DASHBOARD_HTTP_ROOT_BEFORE' $RootBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_BEFORE' $RootBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_BEFORE' $HealthBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_HEALTH_BEFORE' $HealthBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_BEFORE' $SnapshotBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_SNAPSHOT_BEFORE' $SnapshotBefore.milliseconds
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Result 'CRITICAL_FILE_COUNT_BEFORE' $FingerprintBefore.count
    Add-Result 'CRITICAL_FINGERPRINT_BEFORE' $FingerprintBefore.sha256

    if ($RuntimeBefore -ne 1) {
        throw 'RUNTIME_COUNT_NOT_ONE'
    }
    if ($OrderBefore -lt 0) {
        throw 'ORDER_LEDGER_UNREADABLE'
    }

    $Python = Get-PythonPath
    $CompileOutput = @(& $Python -m py_compile $Helper 2>&1)
    $CompileExit = $LASTEXITCODE
    Add-Result 'AUDITOR_COMPILE_EXIT_CODE' $CompileExit
    if ($CompileExit -ne 0) {
        throw ('AUDITOR_COMPILE_FAILED:' + ($CompileOutput -join ' '))
    }
    Add-Result 'AUDITOR_COMPILE' 'PASS'

    $AuditOutput = @(
        & $Python $Helper $Root $ControlRoot $Database $Manifest 2>&1
    )
    $AuditExit = $LASTEXITCODE
    $AuditText = $AuditOutput -join [Environment]::NewLine

    Add-Result 'AUDITOR_EXIT_CODE' $AuditExit
    if ($AuditExit -ne 0) {
        throw ('AUDITOR_FAILED:' + $AuditText)
    }
    if (-not $AuditText.Contains('FINAL_STATUS=PASS_READ_ONLY_EVIDENCE_AUDIT_V2')) {
        throw ('AUDITOR_PASS_MARKER_MISSING:' + $AuditText)
    }

    foreach ($Line in $AuditOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('FIELD_COUNT_') -or
            $Text.StartsWith('SOURCE_QUALITY_') -or
            $Text.StartsWith('JSON_EVIDENCE_COUNT=') -or
            $Text.StartsWith('JSON_PARSE_ERROR_COUNT=') -or
            $Text.StartsWith('SQLITE_TABLE_COUNT=')
        ) {
            [void]$Results.Add($Text)
        }
    }

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $RootAfter = Get-HttpProbe '/'
    $HealthAfter = Get-HttpProbe '/api/v1/health'
    $SnapshotAfter = Get-HttpProbe '/api/v1/snapshot'
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-CriticalFingerprint

    if ($RuntimeAfter -ne $RuntimeBefore) {
        throw 'RUNTIME_COUNT_CHANGED'
    }
    if ($OrderAfter -ne $OrderBefore) {
        throw 'ORDER_LEDGER_COUNT_CHANGED'
    }
    if ($FingerprintAfter.sha256 -ne $FingerprintBefore.sha256) {
        throw 'CRITICAL_FILE_FINGERPRINT_CHANGED'
    }

    Add-Result 'RUNTIME_PROCESS_COUNT_AFTER' $RuntimeAfter
    Add-Result 'DASHBOARD_HTTP_ROOT_AFTER' $RootAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_AFTER' $RootAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_AFTER' $HealthAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_HEALTH_AFTER' $HealthAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_AFTER' $SnapshotAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_SNAPSHOT_AFTER' $SnapshotAfter.milliseconds
    Add-Result 'ORDER_LEDGER_COUNT_AFTER' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'CRITICAL_FILE_COUNT_AFTER' $FingerprintAfter.count
    Add-Result 'CRITICAL_FINGERPRINT_AFTER' $FingerprintAfter.sha256
    Add-Result 'CRITICAL_FILES_UNCHANGED' $true
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'NEXT_STAGE' 'OFFLINE_V2_2_BUILD_FROM_CONFIRMED_EVIDENCE_ONLY'
    Add-Result 'MANIFEST' $Manifest
    Add-Result 'FINAL_STATUS' 'PASS_V2_2_READ_ONLY_EVIDENCE_AUDIT_V2_NO_LIVE_MUTATION'
    $Success = $true
}
catch {
    Add-Result 'AUDIT_ERROR' $_.Exception.Message
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    try {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount)
    }
    catch {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED'
    }
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'FINAL_STATUS' 'FAIL_V2_2_READ_ONLY_EVIDENCE_AUDIT_V2_NO_LIVE_MUTATION'
}

Add-Result 'REPORT' $Report

$CopyStatus = 'FAILED'
try {
    Set-Clipboard -Value ($Results -join [Environment]::NewLine)
    $CopyStatus = 'SUCCESS'
}
catch {
    $CopyStatus = 'FAILED'
}
Add-Result 'COPY_STATUS' $CopyStatus

$OutputText = ($Results -join [Environment]::NewLine) + [Environment]::NewLine
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($Report, $OutputText, $Utf8Bom)
Write-Output $OutputText

if ($Success) {
    exit 0
}
exit 1
