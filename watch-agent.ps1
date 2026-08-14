<#
.SYNOPSIS
  Claude Code と Codex CLI(ChatGPT) の利用制限状態を自動でチェックし、
  data.json を更新 → git push → (回復検知時)Gmail通知 まで行う無人監視スクリプト。
  Windowsタスクスケジューラから定期実行される想定（setup-task.ps1 参照）。

.重要な前提・限界（正直に書いておきます）
  - Claude/OpenAIとも「残り使用量をAPIで問い合わせる」公式手段は現時点で存在しません。
    このスクリプトは「ごく軽いプロンプトを実際に送ってみて、制限メッセージが返るかどうか」
    を見る"ping方式"で判定します（Codex側は非対話でのレート情報取得が未サポートである
    ことがOpenAI公式リポジトリのissueで確認済みです）。
  - そのためチェック自体が極小ですが実際の利用量を消費します。既定は10分間隔です。
  - 制限メッセージの文言はプラン・言語・時期によって変わる可能性があります。
    誤検知に気づいたら下の $claudeLimitPattern / $codexLimitPattern を調整してください。
  - Geminiはブラウザ版のみのためこの自動チェック対象外です（gemini-log.ps1で手動記録）。
#>

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
. (Join-Path $PSScriptRoot "send-gmail.ps1")

$dataPath = Join-Path $PSScriptRoot "data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json
$now = Get-Date
$nowIso = $now.ToString("yyyy-MM-ddTHH:mm:sszzz")

# 検知用の正規表現は「制限に達した」ことの判定と、reset目安時刻の抽出を分離している。
# reset目安の文言（"resets at ..." / "resets ..." / "resets in ..." 等）は将来変わりうるため、
# 抽出に失敗しても depleted 判定自体は妥当なままにするための設計。
# 2026-08-14 実機検証: claude.exe バイナリ内の文字列から、実際の表示は
#   "<Type> limit reached · resets <time>" / "resets in <duration>" のように
#   "resets" の直後に "at" が付かないケースがあることを確認した。
#   旧正規表現は "resets? \s+ at \s+" を必須としていたため、このケースで
#   reset目安の抽出は失敗するが、下記の分離設計により depleted 判定自体には影響しない。
$claudeLimitPattern = '(?is)usage limit reached'
$claudeResetHintPattern = '(?is)resets?\s*(?:at|in)?\s*([^,."\r\n]{1,60})'
# codex CLI はこの環境に未インストールのため、下記パターンは実機検証できていない。
# README/AGENT_PROMPT記載の通りOpenAI公式でも非対話でのレート情報取得は未サポートであり、
# 実際のメッセージ文言は "codex exec" 経由で制限に当たった際に必ず一度目視確認すること。
$codexLimitPattern = '(?is)usage limit reached|rate limit'
$codexResetHintPattern = '(?is)(try again[^\r\n."]*|resets?\s*(?:at|in)?\s*[^,."\r\n]{1,60})'

function Get-ResetHint($raw, $hintPattern) {
  if ($raw -match $hintPattern) { return $Matches[1].Trim() }
  return $null
}

function Test-ClaudeStatus {
  try {
    $raw = (& claude -p "Reply with only the single word OK." --output-format json 2>&1) -join "`n"
  } catch {
    return [PSCustomObject]@{ status = "unknown"; raw = "$_" }
  }

  # --output-format json は1行のJSONを出力する想定だが、フック等の余計な行が
  # 混ざることがあるため、JSONとして読める行を後ろから探して優先的に見る。
  $jsonLine = ($raw -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
  $parsed = $null
  if ($jsonLine) {
    try { $parsed = $jsonLine | ConvertFrom-Json } catch { $parsed = $null }
  }

  if ($raw -match $claudeLimitPattern) {
    return [PSCustomObject]@{ status = "depleted"; resetHint = (Get-ResetHint $raw $claudeResetHintPattern); raw = $raw }
  }
  if ($parsed) {
    if ($parsed.is_error -eq $true) {
      # 制限メッセージにはマッチしなかったが is_error=true → 他のエラー(認証切れ、
      # ネットワーク不通等)の可能性があるため、readyと誤判定せず unknown にする。
      return [PSCustomObject]@{ status = "unknown"; raw = $raw }
    }
    if ($parsed.is_error -eq $false) {
      return [PSCustomObject]@{ status = "ready"; raw = $raw }
    }
  }
  # JSONが解釈できず制限文言にも一致しない場合は判定不能として扱う。
  return [PSCustomObject]@{ status = "unknown"; raw = $raw }
}

function Test-CodexStatus {
  try {
    $raw = (& codex exec "Reply with only the single word OK." --json --skip-git-repo-check --ephemeral 2>&1) -join "`n"
  } catch {
    return [PSCustomObject]@{ status = "unknown"; raw = "$_" }
  }
  if ($raw -match $codexLimitPattern) {
    return [PSCustomObject]@{ status = "depleted"; resetHint = (Get-ResetHint $raw $codexResetHintPattern); raw = $raw }
  }
  return [PSCustomObject]@{ status = "ready"; raw = $raw }
}

function Get-LastEvent($svc) {
  $sorted = $svc.events | Sort-Object { [datetime]$_.timestamp }
  if ($sorted.Count -eq 0) { return $null }
  return $sorted[$sorted.Count - 1]
}

$changed = $false
$notifications = @()

foreach ($cfg in @(
    @{ id = "claude";  test = { Test-ClaudeStatus } },
    @{ id = "chatgpt"; test = { Test-CodexStatus } }
  )) {

  $svc = $data.services | Where-Object { $_.id -eq $cfg.id }
  if (-not $svc) { continue }

  $result = & $cfg.test
  if ($result.status -eq "unknown") {
    Write-Host "[$($cfg.id)] 状態を確認できませんでした（コマンド未導入 or 未ログインの可能性）: $($result.raw)" -ForegroundColor Yellow
    continue
  }

  $last = Get-LastEvent $svc
  $pendingRecovery = ($last -and $last.type -eq "depleted")

  if ($result.status -eq "depleted" -and -not $pendingRecovery) {
    $svc.events = @($svc.events) + [PSCustomObject]@{
      timestamp = $nowIso
      type      = "depleted"
      resetHint = $result.resetHint
    }
    Write-Host "[$($cfg.id)] 上限到達を検知 ($nowIso) 目安: $($result.resetHint)" -ForegroundColor Red
    $changed = $true
  }
  elseif ($result.status -eq "ready" -and $pendingRecovery) {
    $lastDepletedAt = [datetime]$last.timestamp
    $expected = $lastDepletedAt.AddHours($svc.resetCycleHours)
    $irregular = $now -lt $expected.AddMinutes(-15)

    $svc.events = @($svc.events) + [PSCustomObject]@{
      timestamp = $nowIso
      type      = "recovered"
      irregular = $irregular
    }
    Write-Host "[$($cfg.id)] 回復を検知 ($nowIso) irregular=$irregular" -ForegroundColor Green
    $changed = $true

    $subject = if ($irregular) { "[$($svc.name)] 通常より早く回復しました" } else { "[$($svc.name)] 利用制限が回復しました" }
    $body = @"
$($svc.name) の利用制限が回復しました。

回復時刻: $nowIso
上限到達時刻: $($last.timestamp)
通常のリセット目安: $($svc.resetCycleHours)時間後 ($($expected.ToString('yyyy-MM-dd HH:mm')))
イレギュラー回復: $(if ($irregular) { 'はい（通常より早い）' } else { 'いいえ（通常どおり）' })
"@
    $notifications += @{ subject = $subject; body = $body }
  }
  # 状態変化なし（変わらずready、または変わらずdepleted）の場合は何もしない
}

if ($changed) {
  $data | ConvertTo-Json -Depth 10 | Set-Content $dataPath -Encoding UTF8

  git add data.json | Out-Null
  git commit -m "auto: recovery check @ $nowIso" | Out-Null
  git push | Out-Null

  foreach ($n in $notifications) {
    Send-RecoveryGmail -Subject $n.subject -Body $n.body | Out-Null
  }
} else {
  Write-Host "変化なし ($nowIso)"
}
